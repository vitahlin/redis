# Ubuntu 上用最小 hiredis async reproducer 复现 `EPOLLERR -> recv(EAGAIN)` busy-loop

这份文档给出一套 **不依赖 Sentinel 状态机**、但仍然走 **真实 hiredis async + ae(epoll)** 读路径的复现方案。

目标是稳定复现 `docs/sentinel.md` 里描述的链路：

- Linux `epoll` 因 `EPOLLERR` 持续唤醒事件循环
- `hiredis async` 走到 `redisAsyncHandleRead -> redisBufferRead -> redisNetRead`
- 老版本 `redisNetRead()` 在非阻塞 `EWOULDBLOCK/EAGAIN` 时直接 `return 0`
- `SO_ERROR` 未被消费，程序进入 busy-loop，CPU 接近单核 100%

这套方案比直接跑 Sentinel 更容易定位问题；同时，它又比“纯裸 socket + epoll”更贴近真正的修复点。

---

## 1. 方案适用范围

建议在 **原生 Ubuntu** 上执行：

- Ubuntu 22.04 / 24.04
- root 权限
- 使用原生 Linux 内核网络栈

不建议先在 OrbStack / Docker Desktop / WSL2 之类额外虚拟化网络环境上验证，因为这类环境可能改变 `iptables REJECT`、`ICMP unreachable`、`SO_ERROR` 或 `epoll` 的外在表现。

---

## 2. 这份方案为什么有效

仓库里的关键路径如下：

1. `src/ae_epoll.c` 会把 `EPOLLERR` 映射成 `AE_READABLE|AE_WRITABLE`
2. `deps/hiredis/adapters/ae.h` 收到 `AE_READABLE` 后调用 `redisAsyncHandleRead()`
3. `redisAsyncHandleRead()` 会进入 `redisBufferRead()`
4. `redisBufferRead()` 再调用 `redisNetRead()`
5. 当前仓库里的 `deps/hiredis/net.c` 在非阻塞 `EWOULDBLOCK` 时仍然直接返回 `0`

所以，只要我们能让：

- 连接上挂着异步错误（`SO_ERROR`）
- `epoll` 继续上报 `EPOLLERR`
- 但 `recv()` 仍返回 `EAGAIN`

就能打到这条 bug 链路。

---

## 3. 前置依赖

先安装工具：

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  iproute2 \
  iptables \
  strace \
  sysstat
```

说明：

- `build-essential`：编译 reproducer
- `iproute2`：创建 network namespace 和 veth
- `iptables`：只毒化当前 flow
- `strace`：观察 `epoll_wait/recv/getsockopt`
- `sysstat`：提供 `pidstat`

---

## 4. 先把仓库编成适合做 reproducer 的状态

为了简化链接，建议直接用 `libc` allocator 构建 Redis 和 hiredis：

```bash
cd /path/to/redis
make distclean
make MALLOC=libc
```

这样做的好处是：

- `deps/hiredis/libhiredis.a` 会被构建出来
- `src/ae.o`、`src/zmalloc.o`、`src/monotonic.o` 也会被构建出来
- 后面编译 reproducer 时不需要再额外显式链接 jemalloc

如果你已经用默认配置构建过 Redis，也建议重新跑一遍 `make distclean && make MALLOC=libc`，这样文档里的编译命令可以直接照抄。

---

## 5. 创建最小网络拓扑

下面的命令会创建：

- root namespace 中的 `veth0`，地址 `10.200.1.1/24`
- `srv` namespace 中的 `veth1`，地址 `10.200.1.2/24`

```bash
sudo ip netns add srv

sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns srv

sudo ip addr add 10.200.1.1/24 dev veth0
sudo ip link set veth0 up

sudo ip netns exec srv ip link set lo up
sudo ip netns exec srv ip addr add 10.200.1.2/24 dev veth1
sudo ip netns exec srv ip link set veth1 up
```

可以用下面的命令确认两边互通：

```bash
ping -c 2 10.200.1.2
sudo ip netns exec srv ping -c 2 10.200.1.1
```

---

## 6. 在 `srv` namespace 里启动 Redis 服务端

```bash
cd /path/to/redis

sudo ip netns exec srv ./src/redis-server \
  --bind 10.200.1.2 \
  --port 6379 \
  --protected-mode no \
  --save '' \
  --appendonly no \
  --daemonize yes \
  --pidfile /tmp/redis-srv-ns.pid \
  --logfile /tmp/redis-srv-ns.log
```

确认服务端正常：

```bash
sudo ip netns exec srv ./src/redis-cli -h 10.200.1.2 -p 6379 ping
```

期望输出：

```text
PONG
```

---

## 7. 保存最小 `hiredis async + ae` reproducer

把下面这段代码保存成 `/tmp/hiredis_async_epollerr_repro.c`。

```c
#define _GNU_SOURCE

#include <ae.h>
#include <hiredis.h>
#include <async.h>
#include <adapters/ae.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct App {
    aeEventLoop *loop;
    redisAsyncContext *ac;
    char host[64];
    int port;
    int ping_every_ms;
    int inject_after_ms;
    int stop_after_ms;
    int sport;
    int injected;
    int ping_count;
} App;

static App *g_app = NULL;

static int run_cmd(const char *cmd) {
    int rc;
    printf("$ %s\n", cmd);
    fflush(stdout);
    rc = system(cmd);
    if (rc == -1) return -1;
    if (WIFEXITED(rc)) return WEXITSTATUS(rc);
    return rc;
}

static int get_local_port(int fd) {
    struct sockaddr_in sa;
    socklen_t len = sizeof(sa);
    if (getsockname(fd, (struct sockaddr *)&sa, &len) != 0) {
        perror("getsockname");
        return -1;
    }
    return ntohs(sa.sin_port);
}

static void remove_rule(App *app) {
    char cmd[512];
    if (!app || !app->injected || app->sport <= 0) return;

    snprintf(cmd, sizeof(cmd),
             "iptables -D OUTPUT -p tcp -d %s --dport %d --sport %d "
             "-j REJECT --reject-with icmp-port-unreachable",
             app->host, app->port, app->sport);
    run_cmd(cmd);
    app->injected = 0;
}

static void cleanup(void) {
    remove_rule(g_app);
}

static void on_pong(redisAsyncContext *ac, void *reply, void *privdata) {
    redisReply *r = reply;
    App *app = privdata;
    (void)ac;

    if (r == NULL) {
        printf("reply=NULL (likely disconnect path)\n");
        return;
    }

    if (r->type == REDIS_REPLY_STATUS && (app->ping_count <= 5 || app->ping_count % 10 == 0)) {
        printf("PING #%d -> %s\n", app->ping_count, r->str);
        fflush(stdout);
    }
}

static int ping_timer(aeEventLoop *el, long long id, void *clientData) {
    App *app = clientData;
    int rc;
    (void)el;
    (void)id;

    app->ping_count++;
    rc = redisAsyncCommand(app->ac, on_pong, app, "PING");
    if (rc != REDIS_OK) {
        printf("redisAsyncCommand(PING) failed: err=%d errstr=%s\n",
               app->ac->err, app->ac->errstr);
    }
    return app->ping_every_ms;
}

static int inject_timer(aeEventLoop *el, long long id, void *clientData) {
    App *app = clientData;
    char cmd[512];
    int rc;
    (void)el;
    (void)id;

    if (app->sport <= 0) {
        printf("source port not ready yet, retrying inject in 200ms\n");
        return 200;
    }

    snprintf(cmd, sizeof(cmd),
             "iptables -I OUTPUT -p tcp -d %s --dport %d --sport %d "
             "-j REJECT --reject-with icmp-port-unreachable",
             app->host, app->port, app->sport);

    rc = run_cmd(cmd);
    if (rc != 0) {
        fprintf(stderr, "failed to install iptables rule (rc=%d)\n", rc);
        aeStop(app->loop);
        return AE_NOMORE;
    }

    app->injected = 1;
    printf("Injected ICMP port-unreachable for sport=%d\n", app->sport);
    printf("Now watch pidstat/strace for busy-loop symptoms.\n");
    fflush(stdout);
    return AE_NOMORE;
}

static int stop_timer(aeEventLoop *el, long long id, void *clientData) {
    (void)clientData;
    (void)id;
    printf("stop timer fired; cleaning up and exiting\n");
    cleanup();
    aeStop(el);
    return AE_NOMORE;
}

static void connect_cb(const redisAsyncContext *ac, int status) {
    if (status != REDIS_OK) {
        fprintf(stderr, "connect failed: %s\n", ac->errstr);
        aeStop(g_app->loop);
        return;
    }

    g_app->sport = get_local_port(ac->c.fd);
    printf("connected: pid=%d fd=%d sport=%d -> %s:%d\n",
           getpid(), ac->c.fd, g_app->sport, g_app->host, g_app->port);
    fflush(stdout);

    aeCreateTimeEvent(g_app->loop, g_app->ping_every_ms, ping_timer, g_app, NULL);
    aeCreateTimeEvent(g_app->loop, g_app->inject_after_ms, inject_timer, g_app, NULL);
    aeCreateTimeEvent(g_app->loop, g_app->stop_after_ms, stop_timer, g_app, NULL);
}

static void disconnect_cb(const redisAsyncContext *ac, int status) {
    printf("disconnect callback: status=%d err=%d errstr=%s\n",
           status, ac->err, ac->errstr);
    fflush(stdout);
    cleanup();
    aeStop(g_app->loop);
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s <host> <port> [ping_ms] [inject_after_ms] [stop_after_ms]\n"
            "Example: %s 10.200.1.2 6379 100 1500 10000\n",
            prog, prog);
}

int main(int argc, char **argv) {
    App app;

    if (argc < 3) {
        usage(argv[0]);
        return 1;
    }

    memset(&app, 0, sizeof(app));
    snprintf(app.host, sizeof(app.host), "%s", argv[1]);
    app.port = atoi(argv[2]);
    app.ping_every_ms = (argc > 3) ? atoi(argv[3]) : 100;
    app.inject_after_ms = (argc > 4) ? atoi(argv[4]) : 1500;
    app.stop_after_ms = (argc > 5) ? atoi(argv[5]) : 10000;

    if (app.port <= 0 || app.ping_every_ms <= 0 || app.inject_after_ms <= 0 || app.stop_after_ms <= 0) {
        usage(argv[0]);
        return 1;
    }

    setlinebuf(stdout);
    signal(SIGPIPE, SIG_IGN);
    atexit(cleanup);

    g_app = &app;
    printf("pid=%d\n", getpid());

    app.ac = redisAsyncConnect(app.host, app.port);
    if (app.ac == NULL) {
        fprintf(stderr, "redisAsyncConnect returned NULL\n");
        return 1;
    }
    if (app.ac->err) {
        fprintf(stderr, "connect setup failed: %s\n", app.ac->errstr);
        return 1;
    }

    app.loop = aeCreateEventLoop(64);
    if (app.loop == NULL) {
        fprintf(stderr, "aeCreateEventLoop failed\n");
        return 1;
    }

    if (redisAeAttach(app.loop, app.ac) != REDIS_OK) {
        fprintf(stderr, "redisAeAttach failed\n");
        return 1;
    }
    if (redisAsyncSetConnectCallback(app.ac, connect_cb) != REDIS_OK) {
        fprintf(stderr, "redisAsyncSetConnectCallback failed\n");
        return 1;
    }
    if (redisAsyncSetDisconnectCallback(app.ac, disconnect_cb) != REDIS_OK) {
        fprintf(stderr, "redisAsyncSetDisconnectCallback failed\n");
        return 1;
    }

    aeMain(app.loop);
    aeDeleteEventLoop(app.loop);
    return 0;
}
```

---

## 8. 编译 reproducer

假设你当前目录在仓库根目录：

```bash
cd /path/to/redis

cc -std=gnu11 -O2 -g -Wall -Wextra \
  -I./src -I./deps/hiredis \
  /tmp/hiredis_async_epollerr_repro.c \
  ./src/ae.o ./src/anet.o ./src/monotonic.o ./src/zmalloc.o ./src/redisassert.o \
  ./deps/hiredis/libhiredis.a \
  -pthread -lm -ldl \
  -o /tmp/hiredis_async_epollerr_repro
```

如果你是在 ARM32 机器上编译，可能还需要补一个 `-latomic`。

---

## 9. 运行 reproducer

因为程序会自动插入 `iptables` 规则，所以需要 root：

```bash
cd /path/to/redis
sudo /tmp/hiredis_async_epollerr_repro 10.200.1.2 6379 100 1500 10000
```

参数说明：

- `10.200.1.2`：`srv` namespace 中 Redis 的地址
- `6379`：Redis 端口
- `100`：每 100ms 发一个 `PING`
- `1500`：连接建立 1.5s 后注入 `icmp-port-unreachable`
- `10000`：10s 后停止程序并清理规则

正常启动后，程序会打印：

- 当前进程 `pid`
- 连接使用的本地 `sport`
- 规则插入时机

---

## 10. 观测命令

另开两个终端。

### 终端 A：看 CPU

```bash
pidstat -p <PID> 1
```

### 终端 B：看系统调用

```bash
sudo strace -tt -p <PID> \
  -e trace=epoll_wait,epoll_pwait,recv,recvfrom,getsockopt
```

### 终端 C：看连接状态（可选）

```bash
sudo ss -tanp | grep <PID>
```

---

## 11. 预期现象：未修复版本

当前仓库里的 `deps/hiredis/net.c` 仍然是老逻辑，所以你应该优先在这个版本上先观察一次。

### 预期结果

1. 注入 `icmp-port-unreachable` 后，程序 **不会很快进入 disconnect callback**
2. `pidstat` 会看到进程 CPU 持续升高，接近单核 100%
3. `strace` 中会看到类似下面的重复模式：

```text
epoll_pwait(...) = 1
recvfrom(fd, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
epoll_pwait(...) = 1
recvfrom(fd, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
```

### 含义

这说明：

- `epoll` 反复因为 `EPOLLERR` 唤醒
- 但 `recv()` 读不到数据，只得到 `EAGAIN`
- hiredis 老代码把它当成“稍后重试”
- `SO_ERROR` 没被消费，事件循环被卡住

---

## 12. 预期现象：修复后版本

当你把 `docs/sentinel.md` 里描述的 `getsockopt(SO_ERROR)` 修复打进去，并重新构建后，再运行同样的步骤：

```bash
make distclean
make MALLOC=libc

cc -std=gnu11 -O2 -g -Wall -Wextra \
  -I./src -I./deps/hiredis \
  /tmp/hiredis_async_epollerr_repro.c \
  ./src/ae.o ./src/anet.o ./src/monotonic.o ./src/zmalloc.o ./src/redisassert.o \
  ./deps/hiredis/libhiredis.a \
  -pthread -lm -ldl \
  -o /tmp/hiredis_async_epollerr_repro
```

### 预期结果

1. 注入后会更快走到 `disconnect callback`
2. CPU 不再持续维持高位
3. `strace` 中更容易观察到 `getsockopt(SO_ERROR)`
4. 程序不会一直卡在 `epoll_wait -> recv(EAGAIN)` 的病态循环里

### 含义

这说明修复已经生效：

- 在 `EWOULDBLOCK/EAGAIN` 路径中额外读取了 `SO_ERROR`
- 错误被消费并清零
- 上层把连接视为失败并断开
- busy-loop 的闭环被打破

---

## 13. 推荐的对比实验顺序

建议按这个顺序操作：

1. 用当前仓库（老逻辑）跑一次
2. 记录：
   - CPU 曲线
   - `strace` 输出
   - 是否一直不触发 `disconnect callback`
3. 应用修复并重新构建
4. 用相同命令再跑一次
5. 对比差异

这样最容易证明：

- 不是环境偶发波动
- 而是 `redisNetRead()` 那个逻辑分支确实决定了结果

---

## 14. 清理命令

如果程序正常退出，会自动尝试删除 `iptables` 规则。

但如果你中途 `kill -9` 了程序，或者实验过程被异常打断，建议手动清理：

### 1) 删掉 namespace 内 Redis

```bash
sudo ip netns exec srv pkill -f 'redis-server.*10.200.1.2'
```

### 2) 查看并手动删除 OUTPUT 规则

```bash
sudo iptables -L OUTPUT -n --line-numbers
```

如果看到了类似下面的规则：

```text
REJECT  tcp  --  0.0.0.0/0  10.200.1.2  tcp spt:<sport> dpt:6379 reject-with icmp-port-unreachable
```

就执行：

```bash
sudo iptables -D OUTPUT <line-number>
```

### 3) 删除 namespace 和 veth

```bash
sudo ip link del veth0 || true
sudo ip netns del srv || true
```

---

## 15. 如果没有复现出高 CPU，优先检查这几项

### 1) 你是不是在原生 Ubuntu 上跑

优先排除：

- OrbStack
- Docker Desktop
- WSL2

这些环境经常会改变网络错误的表现方式。

### 2) 程序是否真的走的是 `ae` adapter

不要改成 `poll.h`、`libevent` 或其他 adapter；否则你就不在复现 `epoll` 那条路径了。

### 3) `iptables` 规则是否真的被插入

运行：

```bash
sudo iptables -L OUTPUT -n --line-numbers
```

确认有一条精确命中当前 `sport` 的规则。

### 4) 把参数调得更激进

可以试试：

```bash
sudo /tmp/hiredis_async_epollerr_repro 10.200.1.2 6379 50 3000 15000
```

也就是：

- 每 50ms 发一个 `PING`
- 3s 后再注入错误
- 观察窗口拉长到 15s

### 5) 确认你比较的是“修复前 / 修复后”而不是两个不同环境

最稳的做法是：

- 同一台原生 Ubuntu
- 同一套 namespace 拓扑
- 只替换 `hiredis/net.c` 修复逻辑
- 重新 `make MALLOC=libc`
- 再重新链接 reproducer

---

## 16. 这份 reproducer 和 Sentinel 测试的关系

它不是 Sentinel 场景测试的替代品，而是一个更小的“原理级复现器”：

- 它保留了真实的 hiredis async 读路径
- 它保留了真实的 `ae(epoll)` 事件循环
- 它去掉了 Sentinel 的 failover / hello / publish / reconnect 状态机干扰

所以更适合回答这两个问题：

1. **老版本 hiredis 在这个 socket 状态下会不会 busy-loop？**
2. **`getsockopt(SO_ERROR)` 修复是否真的打破了这个闭环？**

如果这两个问题都被这个 reproducer 证明了，再回头看 Sentinel 测试时，定位会容易得多。