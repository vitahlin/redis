# Redis Sentinel CPU 100% Bug 根因总结

> Issue: [redis/redis#9956](https://github.com/redis/redis/issues/9956)
> Bug 位置: `deps/hiredis/net.c` — `redisNetRead()`

---

## 一句话总结

**K8s Pod 滚动更新导致 TCP 连接产生内核级硬错误（`sk_err`），`epoll` 持续报 `EPOLLERR`，但 hiredis 的 `recv()` 只看到 `EAGAIN` 却不检查 `SO_ERROR`，形成水平触发的无限空循环，Sentinel CPU 100%。**

---

## 现象

- Redis Sentinel 单核 CPU 持续接近 100%
- `strace` 可见高频循环模式：

```
recvfrom(11, ...) = -1 EAGAIN
recvfrom(10, ...) = -1 EAGAIN
epoll_pwait(5, [{events=EPOLLERR, data={u32=11}}, {events=EPOLLERR, data={u32=10}}], ...) = 2
```

- **Kubernetes 环境下 Pod 滚动更新后特别容易触发**
- `SENTINEL RESET` 可临时恢复

---

## 根因：四层联动

Bug 的形成需要**内核 / epoll / Redis 事件循环 / hiredis** 四层同时参与，缺一不可。

### 第 1 层：K8s 网络 → 内核设 `sk_err`（硬错误）

K8s Pod 被销毁时，旧 Pod IP 不再可达。Sentinel 继续往旧 IP 发包，**网络层返回 ICMP Host/Port Unreachable**。

关键区别：

| ICMP 来源 | 内核处理方式 | 设 `sk_err`？ | 触发 `EPOLLERR`？ |
|-----------|-----------|-------------|-----------------|
| **K8s 外部网络节点返回** | 对 ESTABLISHED TCP 设硬错误 | **✅** | **✅** |
| 本地 `iptables REJECT` | 对 ESTABLISHED TCP 只设软错误 `sk_err_soft` | ❌ | ❌ |
| 本地 `iptables DROP` | 无任何错误信号 | ❌ | ❌ |

**这就是为什么本地用 `iptables` 无法复现。**

### 第 2 层：epoll → `EPOLLERR` 水平触发

`sk_err` 被设置后，`tcp_poll()` 返回 `EPOLLERR`。

`EPOLLERR` 是 **level-triggered**——只要 `SO_ERROR` 没被消费（`getsockopt` 读取并清零），`epoll_wait` 每次调用都立即返回。

### 第 3 层：Redis 事件循环 → 映射为可读/可写

`src/ae_epoll.c`：

```c
if (e->events & EPOLLERR) mask |= AE_WRITABLE|AE_READABLE;
```

事件循环把 `EPOLLERR` 当成"有数据可读"，调用 hiredis 的读回调。

### 第 4 层：hiredis → 吞掉 EAGAIN，不检查 SO_ERROR（BUG 所在）

`deps/hiredis/net.c` — `redisNetRead()`：

```c
ssize_t nread = recv(c->fd, buf, bufcap, 0);
if (nread == -1) {
    if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || (errno == EINTR)) {
        /* Try again later */
        return 0;   // ← BUG：直接返回"没事"，不检查 SO_ERROR
    }
    ...
}
```

- `recv()` 只看接收队列，队列空就返回 `EAGAIN`
- `recv()` **不会**去碰 `SO_ERROR`
- hiredis 把 `EAGAIN` 当成"稍后重试"，不设错误、不断开连接
- `SO_ERROR` 依然挂着，`EPOLLERR` 继续触发

### 死循环闭环

```
  ┌─→ epoll_wait 返回 EPOLLERR  ──→ ae 派发 AE_READABLE
  │                                         │
  │                                         ▼
  │                                 redisNetRead → recv() 返回 EAGAIN
  │                                         │
  │                                         ▼
  │                                 return 0，什么都不做
  │                                         │
  └────────── SO_ERROR 依然在 ←───────────────┘
```

每轮 `epoll_wait` 因为有事件立即返回，CPU 100% 空转。

---

## 为什么 Sentinel 有重连逻辑却没用

Sentinel 确实设计了"连接出错就重连"的机制：

1. `instanceLinkConnectionError()` → `link->disconnected = 1`
2. `sentinelReconnectInstance()` → 重新 `redisAsyncConnectBind()`

**但这条链的前提是 hiredis 先报告错误。** Bug 恰恰让 hiredis 不报告错误：

- `redisNetRead` 返回 `0`（不是 `-1`）
- `redisAsyncRead` 收到 `REDIS_OK`，不调用 `__redisAsyncDisconnect`
- Sentinel 不知道连接已坏
- 重连逻辑的触发条件被绕过

---

## 为什么 `SENTINEL RESET` 能恢复

`SENTINEL RESET mymaster` 会关闭所有相关 hiredis 连接。`close()` 把死 fd 从 epoll 摘除，循环立即停止。之后 Sentinel 重新发现并连接新 Pod。

---

## `send()` vs `recv()` 对 SO_ERROR 的差异

排查中发现的另一个关键点：`send()` 和 `recv()` 对 `SO_ERROR` 的行为完全不同。

| 系统调用 | socket 有 SO_ERROR 时 |
|---------|---------------------|
| `recv()` | **无视 SO_ERROR**，只看接收队列。队列空返回 `EAGAIN` |
| `send()` | **消费 SO_ERROR**，返回 `-1`，`errno` 设为该错误码 |

Sentinel 对 master 有两条连接：

| 连接 | 用途 | 周期性写入？ |
|------|------|-----------|
| `cc`（commands） | 发 PING / INFO | **有** — 每 100ms PING |
| `pc`（pubsub） | 订阅 `__sentinel__:hello` | **没有** — SUBSCRIBE 后只读 |

- **cc 被毒化时**：`send()` 很快消费 `SO_ERROR` → 触发正常断开重连 → **不会 busy-loop**
- **pc 被毒化时**：没有写入机会 → `SO_ERROR` 永远不被消费 → **busy-loop 持续**

这解释了为什么 K8s 场景下 bug 容易出现：Pod 被销毁时两条连接同时中招，cc 可能被 `send()` 救了，**但 pc 必然陷入 busy-loop**。

---

## 修复方案

在 `redisNetRead()` 的 `EWOULDBLOCK` 分支增加 `getsockopt(SO_ERROR)` 检查：

```diff
 ssize_t nread = recv(c->fd, buf, bufcap, 0);
 if (nread == -1) {
     if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || (errno == EINTR)) {
+        if (errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) {
+            int so_error = 0;
+            socklen_t errlen = sizeof(so_error);
+            if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &so_error, &errlen) == 0
+                && so_error != 0)
+            {
+                errno = so_error;
+                __redisSetError(c, REDIS_ERR_IO, strerror(errno));
+                return -1;
+            }
+        }
         /* Try again later */
         return 0;
```

### 修复原理

1. **`getsockopt(SO_ERROR)` 读取并清零 `SO_ERROR`** → `EPOLLERR` 不再触发（切断循环源头）
2. **返回 `-1` 并设置错误** → 上层 `redisAsyncRead` 调用 `__redisAsyncDisconnect` → Sentinel 重连
3. **如果 `SO_ERROR == 0`**（正常的虚假唤醒）→ 照常 `return 0`，行为不变

### 修复特性

- **性能无损**：健康连接不会走到 `EWOULDBLOCK` 分支，`getsockopt` 只在病态路径执行一次
- **向后兼容**：对所有正常场景（FIN / RST / 正常数据）的行为完全不变
- **只改 hiredis**：不需要修改 Redis 事件循环或 Sentinel 逻辑

---

## 修复前后行为对比

| 场景 | 修复前 | 修复后 |
|------|-------|-------|
| 正常读数据 | recv 返回数据，正常处理 | 不变 |
| 对端正常关闭 (FIN) | recv 返回 0 → 断开 | 不变 |
| 对端 RST | recv 返回 ECONNRESET → 断开 | 不变 |
| **ICMP 不可达 / 异步错误** | **recv 返回 EAGAIN → CPU 100%** | **getsockopt 取出错误 → 断开 → 重连** |
| 偶发 EAGAIN | return 0 重试 | getsockopt 发现 SO_ERROR=0 → return 0 |

---

## K8s 滚动更新的网络机制详解

### Pod 滚动更新期间发生了什么

K8s Deployment 执行滚动更新时，按以下顺序处理旧 Pod：

1. **Pod 被标记为 Terminating** — kubelet 发送 `SIGTERM`
2. **Endpoint 被摘除** — kube-proxy 更新 iptables/IPVS 规则，新连接不再路由到旧 Pod
3. **Grace Period** — 默认 30 秒，Pod 进程可以做优雅关闭
4. **Pod 被强制销毁** — 进程被 kill，网络命名空间被回收，Pod IP 被释放

### 问题出在哪一步

**步骤 2 和步骤 4 之间存在时间差**，而且对于 **TCP 连接** 存在以下关键行为：

- kube-proxy **不会清理 TCP conntrack 条目**（[kubernetes#104098](https://github.com/kubernetes/kubernetes/issues/104098)），因为要允许优雅关闭
- Sentinel 持有的旧连接仍然指向旧 Pod IP
- 旧 Pod 进程退出后，IP 不再可达
- Sentinel 继续发包 → 网络层返回 ICMP 错误

### 为什么 K8s 的 ICMP 能设 `sk_err`（硬错误）

Linux 内核 `tcp_v4_err()` 对 ESTABLISHED TCP 连接收到 ICMP 的处理逻辑（[net/ipv4/tcp_ipv4.c](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_ipv4.c)）：

```c
/* If we've already connected we will keep trying
 * until we time out, or the user gives up.
 * rfc1122 4.2.3.9 allows to consider as hard errors
 * only PROTO_UNREACH and PORT_UNREACH */

if (!sock_owned_by_user(sk) &&
    inet_test_bit(RECVERR, sk)) {
    WRITE_ONCE(sk->sk_err, err);      // ← 硬错误
    sk_error_report(sk);
} else {
    WRITE_ONCE(sk->sk_err_soft, err); // ← 软错误
}
```

关键条件是 **`IP_RECVERR`** 是否启用。K8s 环境中可能导致硬错误的场景包括：

| 场景 | 内核行为 | `sk_err`？ |
|------|---------|-----------|
| CNI 插件清理路由/ARP → `EHOSTUNREACH` | 发送路径直接失败，不走 `tcp_v4_err` | ✅ |
| Pod 网络命名空间销毁 → 路由消失 | `ip_route_output` 返回 `-ENETUNREACH` | ✅ |
| kube-proxy 遗留的 `REJECT` 规则 | 对**无 endpoint 的 Service** 设的 `icmp-port-unreachable` | 取决于时序 |
| conntrack 条目过期后 → 包被发往不存在的 IP | 外部节点返回 ICMP | 取决于 `IP_RECVERR` |

最重要的一种：**当路由本身消失时**（Pod IP 不再存在于任何路由表中），`send()` 会在内核发送路径中直接失败，设 `sk_err = EHOSTUNREACH`。这不经过 `tcp_v4_err()`，而是在 `tcp_transmit_skb()` → `ip_route_output` 时直接报错。

### K8s 有没有配置可以避免这个问题

**没有直接的 K8s 配置能防止此 bug，因为 bug 在 hiredis 代码层。** 但以下 K8s 侧措施可以降低触发概率：

#### 1. Pod 侧：`preStop` hook 延迟

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "10"]
```

给 kube-proxy 更新 iptables 规则的时间，减少 Sentinel 连到"正在消失的 Pod"的窗口。

#### 2. Service 侧：使用 `publishNotReadyAddresses: false`（默认）

确保 Endpoint 在 Pod 未 Ready 时不被发布，减少连接到未就绪 Pod 的概率。

#### 3. Sentinel 侧：合理的 `down-after-milliseconds`

较小的值让 Sentinel 更快检测到不可用并触发超时重连，但不能根治 busy-loop。

#### 4. 运维侧：`SENTINEL RESET` 自动化

在 Pod 滚动更新后自动执行 `SENTINEL RESET`，强制清理死连接。这是 workaround，不是修复。

**根本解决方案仍然是修复 hiredis 的 `redisNetRead()`。**

---

## 除 K8s 外的其他触发场景

`EPOLLERR + recv(EAGAIN)` 这个 bug 不是 K8s 独有的。任何能让内核对 ESTABLISHED TCP 连接设 `sk_err`（硬错误）的场景都可以触发。

### 1. 网络接口突然消失

```bash
# 物理网卡被拔掉 / 虚拟网卡被删除
ip link del eth0
```

所有经过该接口的连接会收到 `ENETUNREACH`/`EHOSTUNREACH`，内核在发送路径直接设 `sk_err`。

**常见于**：虚拟机热迁移、容器网络重配、物理网络故障。

### 2. 路由表变更导致目标不可达

```bash
# 删除到目标网段的路由
ip route del 10.0.0.0/24
```

后续发包在 `ip_route_output` 时失败，设 `sk_err = ENETUNREACH`。

**常见于**：VPN 断开、SDN 控制器重配路由、BGP 路由收敛。

### 3. 设置了 `IP_RECVERR` 的 TCP socket

```c
int on = 1;
setsockopt(fd, IPPROTO_IP, IP_RECVERR, &on, sizeof(on));
```

启用后，**所有 ICMP 错误都被当成硬错误**处理（设 `sk_err` 而不是 `sk_err_soft`）。此时即使本地 `iptables REJECT` 也能触发 `EPOLLERR`。

**注意**：Redis/hiredis 默认不设 `IP_RECVERR`，但如果有中间层代理或自定义 socket 选项，可能间接启用。

### 4. 对端主机突然从网络中消失（非正常关机）

- 对端主机断电 / 内核 panic
- 中间交换机/路由器故障导致 ARP 表项过期
- 发包触发 ARP 解析失败 → `EHOSTUNREACH`

**常见于**：物理数据中心网络抖动、交换机故障。

### 5. 云厂商 VPC 网络事件

- AWS ENI 热拔插
- GCP VPC 防火墙规则变更
- Azure NSG 更新

这些操作可能在底层触发路由/ARP 变更，导致与 K8s Pod 销毁类似的效果。

### 6. TCP 重传超时（`tcp_retries2` 耗尽）

当 TCP 重传次数超过 `tcp_retries2`（默认 15，约 13-30 分钟）时，内核设 `sk_err = ETIMEDOUT`。

但这种情况下 `recv()` 通常直接返回 `ETIMEDOUT` 而不是 `EAGAIN`，所以**不一定**触发 busy-loop。是否触发取决于具体时序和内核版本。

### 总结：触发条件公式

```
EPOLLERR busy-loop =
    sk_err 被设为非零值（硬错误）
  + recv() 返回 EAGAIN（接收队列恰好为空）
  + hiredis 不检查 SO_ERROR（bug）
  + epoll level-triggered 持续唤醒（放大器）
```

**K8s 只是最常见的触发场景**，因为它的 Pod 生命周期管理天然会频繁制造"已建立连接的目标突然消失"这种状态。

---

## 本地复现方案

由于 `iptables` 无法在 ESTABLISHED TCP 上产生 `EPOLLERR`，本地复现需要**代码层故障注入**：

在 `redisNetRead` 中加入测试开关，让特定 fd 在收到信号后无条件 `return 0` 并保持读事件注册，模拟 "recv(EAGAIN) + EPOLLERR 持续存在" 的效果。这绕过了内核行为的不确定性，可以 100% 复现 busy-loop。

---

## 相关文件

| 文件 | 角色 |
|------|------|
| `deps/hiredis/net.c` | Bug 所在 / 修复点 — `redisNetRead()` |
| `deps/hiredis/async.c` | `redisAsyncRead()` → 收到 `REDIS_ERR` 后调用 `__redisAsyncDisconnect` |
| `src/ae_epoll.c` | `EPOLLERR` 映射为 `AE_READABLE \| AE_WRITABLE` |
| `src/sentinel.c` | `instanceLinkConnectionError()` → 标记断开 → `sentinelReconnectInstance()` 重连 |
| `docs/sentinel.md` | 完整的问题解析和修复 diff |
| `tests/sentinel/tests/16-busy-loop-on-epollerr.tcl` | 回归测试 |

## 参考

- [redis/redis#9956](https://github.com/redis/redis/issues/9956) — 原始 issue
- [RFC 5461](https://tools.ietf.org/html/rfc5461) — TCP's Reaction to Soft Errors
- [net/ipv4/tcp_ipv4.c](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_ipv4.c) — `tcp_v4_err()` 内核源码
- [kubernetes#104098](https://github.com/kubernetes/kubernetes/issues/104098) — K8s 不清理 TCP conntrack
- [kubernetes#108523](https://github.com/kubernetes/kubernetes/issues/108523) — Service-endpoint 生命周期讨论
- [kubernetes#86280](https://github.com/kubernetes/kubernetes/issues/86280) — 滚动更新期间 connection refused
