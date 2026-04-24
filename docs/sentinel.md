---
title: sentinel
slug: ""
excerpt: ""
postType: ""
categories: [ ]
tags: [ ]
featuredImg: ""
galleryImgs: [ ]
published: false
draft: true
archived: false
created: 2026-02-13T16:49
updated: 2026-04-24T16:03
---

# Issue #9956 问题解析

## 现象

Redis Sentinel 进程 CPU 占用率长期维持在 100%，通过 `strace` 观察到一个高频重复的系统调用模式：

```
recvfrom(11, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
recvfrom(10, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
epoll_pwait(5, [{events=EPOLLERR, data={u32=11}}, {events=EPOLLERR, data={u32=10}}], ...) = 2
```

每秒上百次，且在 Kubernetes 环境下 Pod 滚动更新后特别容易出现，手动执行 `SENTINEL RESET` 可以临时恢复。

---

## 根因分析

整条死循环链条涉及**内核 / epoll / Redis 事件循环 / hiredis** 四层，缺一不可。

### 1. 内核侧：异步错误被挂在 SO_ERROR 上

Sentinel 通过 hiredis 与目标 Redis 实例建立了长连接。在 K8s 场景下，Service 的 ClusterIP 指向的 Pod 被重建后，旧 Pod 的 IP
不再可达。此时：

- TCP 协议本身**不会立刻断开连接**（没有收到 RST，只是路由不通）；
- 内核收到一个 ICMP "Host/Port Unreachable"，将错误码（如 `EHOSTUNREACH`、`ECONNREFUSED`）**存入 socket 的 `SO_ERROR` 字段
  **；
- 同时在该 fd 上升起 `EPOLLERR` 事件。

关键点：`EPOLLERR` 是 **level-triggered（水平触发）**的——只要 `SO_ERROR` 上的错误没被消费掉，`epoll_wait` 每次调用都会返回这个事件。

### 2. recv() 返回 EAGAIN 而不是错误

这是最反直觉的一环。很多人以为 socket 有 `SO_ERROR` 时 `recv()` 会返回那个错误，但实际上：

- `recv()` 只从**接收队列（receive queue）**读数据；
- 接收队列是空的 → 返回 `-1` 且 `errno = EWOULDBLOCK/EAGAIN`；
- `SO_ERROR` 只能通过 `getsockopt()` 消费，**`recv()` 根本不会去碰它**。

所以出现了一种"分裂"状态：epoll 说"这个 fd 有事件（错误）"，但 `recv()` 却说"没数据可读"。

### 3. Redis 事件循环：EPOLLERR 被映射成可读 / 可写

`src/ae_epoll.c`:

```c
if (e->events & EPOLLERR) mask |= AE_WRITABLE|AE_READABLE;
if (e->events & EPOLLHUP) mask |= AE_WRITABLE|AE_READABLE;
```

于是事件循环"尽职尽责"地调用了 hiredis 的读回调 `redisAeReadEvent` → `redisAsyncHandleRead` → `redisBufferRead` →
`redisNetRead`。

### 4. hiredis：吞掉了 EAGAIN，既不消费错误也不断开（BUG 所在）

修复前的 `redisNetRead`：

```c
ssize_t nread = recv(c->fd, buf, bufcap, 0);
if (nread == -1) {
    if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || (errno == EINTR)) {
        /* Try again later */
        return 0;            // ← 就是这里，直接当作"稍后重试"返回
    }
    ...
}
```

hiredis 返回 `0` 表示"没事，下次再读"，**既没有设置 `c->err`，也没有触发异步断开**。`SO_ERROR` 仍然挂在内核那里没人消费。

### 5. 死循环形成

于是整个闭环变成：

```
  ┌─→ epoll_wait 返回 EPOLLERR  ──→ ae 派发 AE_READABLE
  │                                         │
  │                                         ▼
  │                                 redisNetRead → recv() 返回 EAGAIN
  │                                         │
  │                                         ▼
  │                                 返回 0，什么都不做
  │                                         │
  └────────── SO_ERROR 依然在 ←───────────────┘
```

每一轮 `epoll_wait` 因为有事件立即返回（timeout 形同虚设），CPU 100% 烧在这个循环里。

---

## 修复思路

修复必须在这个闭环的某一处打破：**要么消费掉 `SO_ERROR`，要么让上层把连接断开**。最理想的是**两者同时做**——这正是
`getsockopt(SO_ERROR)` 的天然效果：

- `getsockopt(SOL_SOCKET, SO_ERROR, ...)` **读取并清零** `SO_ERROR`；清零后内核不再对该 fd 报 `EPOLLERR`（循环的"源"被切断）；
- 把拿到的错误码塞给 hiredis 的 `c->err`，返回 `-1`；
- 上层 `redisBufferRead` 收到 `REDIS_ERR`，`redisProcessCallbacks` 最终走到 `__redisAsyncDisconnect`，**死连接被释放**
  ，Sentinel 下一轮重新发起连接，自愈。

### 为什么选择在 `redisNetRead` 这里加检查

1. **语义精准**：能走到 `EWOULDBLOCK` 分支，说明"事件循环叫我来读，结果读不到数据"——这本身就是水平触发 epoll 下的异常路径（正常情况
   recv 一次就返回一批数据，不会到 EAGAIN）。
2. **性能无损**：健康连接下这个分支几乎不会进入，多出来的 `getsockopt` 只在"病态路径"上发生一次。
3. **修复闭环完整**：同时做了"消费错误"和"通知上层断开"两件事，比单纯在 `ae_epoll.c` 里清 `SO_ERROR`（还得想办法让 hiredis
   断开）要干净。

### 为什么只在非阻塞模式下检查

```c
if (errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) { ... }
```

- 阻塞模式下 `EWOULDBLOCK` 通常是 `SO_RCVTIMEO` 超时导致，语义是"等了很久没数据"，不是 epoll 虚假唤醒；
- `EINTR`（被信号打断）也不是 socket 错误，不应触发这个检查。

只针对非阻塞 + `EWOULDBLOCK` 的组合，这正是 Sentinel / 事件循环用户的场景，也是 bug 出现的唯一路径。

---

## 为什么以前 `SENTINEL RESET` 能救命

`SENTINEL RESET mymaster` 会清空 Sentinel 对该 master 的全部已知信息，附带关闭所有相关 hiredis 连接。连接一关，`close()` 把死
fd 从 epoll 摘除，死循环自然就停了。之后 Sentinel 重新发现并建立新连接，指向正确的新 Pod IP。

所以"手动 RESET 能解决"这个现象本身就强烈暗示了：**问题在于死连接没有被自动清理**——与本次修复的方向完全一致。

---

## 修复前后行为对比

| 场景                  | 修复前                              | 修复后                                     |
|---------------------|----------------------------------|-----------------------------------------|
| 正常读数据               | recv 返回数据，正常处理                   | 同上，路径未改变                                |
| 对端正常关闭 (FIN)        | recv 返回 0 → `REDIS_ERR_EOF` → 断开 | 同上                                      |
| 对端 RST              | recv 返回 -1 ECONNRESET → 断开       | 同上                                      |
| **ICMP 不可达 / 异步错误** | **recv 返回 EAGAIN，循环 100% CPU**   | **getsockopt 取出错误 → 断开 → Sentinel 重连**  |
| 偶发 EAGAIN (罕见虚假唤醒)  | return 0 重试                      | getsockopt 发现 SO_ERROR=0，照常 return 0 重试 |

修复只改变了病态场景的行为，对所有正常路径完全透明。

# 修复方案

```
diff --git a/deps/hiredis/net.c b/deps/hiredis/net.c
index 33fe0b94f..d8f14f453 100644
--- a/deps/hiredis/net.c
+++ b/deps/hiredis/net.c
@@ -63,6 +63,25 @@ ssize_t redisNetRead(redisContext *c, char *buf, size_t bufcap) {
     ssize_t nread = recv(c->fd, buf, bufcap, 0);
     if (nread == -1) {
         if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || (errno == EINTR)) {
+            /* If recv() reports EWOULDBLOCK on a non-blocking socket the event
+             * loop told us to read from, the socket may still have a pending
+             * asynchronous error (e.g. ICMP unreachable stored in SO_ERROR)
+             * that is causing epoll to raise EPOLLERR in a level-triggered
+             * fashion. Returning 0 here without consuming that error would
+             * make epoll_wait fire again immediately, busy-looping the event
+             * loop at ~100% CPU (see redis/redis#9956). Peek at SO_ERROR so
+             * the caller can tear the dead connection down. */
+            if (errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) {
+                int so_error = 0;
+                socklen_t errlen = sizeof(so_error);
+                if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &so_error, &errlen) == 0 &&
+                    so_error != 0)
+                {
+                    errno = so_error;
+                    __redisSetError(c, REDIS_ERR_IO, strerror(errno));
+                    return -1;
+                }
+            }
             /* Try again later */
             return 0;
         } else if(errno == ETIMEDOUT && (c->flags & REDIS_BLOCK)) {

```