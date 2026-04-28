# Redis 7.4.0 崩溃分析:Cygwin + select() → aeApiPoll EBADF (panic)

对应上游 issue:[redis/redis#13899](https://github.com/redis/redis/issues/13899)

## 1. 崩溃栈翻译

```
beforeSleep / aeProcessEvents
└─ aeApiPoll                            (ae_select.c)
   └─ select(maxfd+1, &_rfds, &_wfds, NULL, tvp)
      └─ retval == -1, errno == EBADF
         └─ panic("aeApiPoll: select, Bad file descriptor")  ★ SIGABRT
```

崩溃发生在事件循环的 `aeApiPoll`:`select()` 返回 -1,`errno = EBADF`("Bad file descriptor"),Redis 按不可恢复处理,直接 `panic`。

## 2. 平台关键证据

INFO 里几条决定性字段:

| 字段 | 值 | 含义 |
|---|---|---|
| `os` | `CYGWIN_NT-10.0-17763` | Windows Server 2019 上的 **Cygwin**,不是真正的 Linux |
| `multiplexing_api` | `select` | Cygwin 没有 epoll/kqueue/evport,**只剩 `select`** 这条退路 |
| `redis_version` | `7.4.0` | 自编译,`gcc 12.4.0` |
| `executable` | `/Redis-7.4.0/redis-server` | Cygwin 路径 |
| `config_file` | `/cygdrive/D/Redis/...redis.conf` | 典型 Cygwin 路径 |
| `uptime_in_seconds` | `213253` (≈2.5 天) | 长时间运行 |
| `connected_clients` | `170` | 其中 `pubsub_clients:94` |
| `maxclients` | `3168` | 远超 Linux 默认 `FD_SETSIZE=1024`,意味着编译期把 `FD_SETSIZE` 拉得很大 |

CLIENT LIST 里能看到 `fd` 飚到 `1089`,且大量订阅连接 `idle` 高达 13–17 小时(`idle=48685 / 49921 / 60048 / 59839 ...`)。

> Redis 官方**不支持** Windows / Cygwin。Cygwin 的 socket 是用户态把 POSIX 翻译成 Winsock 的兼容层,长跑可靠性远不如内核实现。

## 3. 直接原因 vs 根因

- **直接原因**:`select()` 入参的 `fd_set` 里有一个 fd 在内核(此处是 Winsock)看来已经不是合法的 socket,系统调用返回 EBADF,Redis 立刻 panic。
- **根因(在这台机器上)**:**底层 Windows `SOCKET` 句柄被 Redis 不感知地失效**,而 fd 仍留在 `aeApiState->rfds/wfds` 里。常见触发:
  - 长时间空闲(13–17h)的 pubsub 连接被 Windows TCP 栈/中间设备/防火墙静默回收;
  - 安全软件/LSP(360、火绒、Symantec 等)劫持或注销 socket;
  - NIC 禁/启、IP 漂移、VPN 断连、Winsock catalog 被重置;
  - Cygwin 对 `SO_KEEPALIVE` 间隔参数的支持本身就不完整,keepalive 没真正发出去。
- **放大因素**:`FD_SETSIZE` 被编到很大(支撑 `maxclients=3168`),`select()` 扫描的 fd 范围相应变大,**踩中一个失效句柄的概率成倍上升**。

## 4. 嫌疑犯逐一核对

| # | 嫌疑路径 | 在本案的角色 |
|---|---|---|
| 1 | **Cygwin `select()` 模拟层** 把失效的 Winsock 句柄翻成 EBADF | ✅ 主嫌,平台行为差异 |
| 2 | 长寿命 pubsub 连接 + Cygwin keepalive 不到位,底层 socket 静默失效 | ✅ 触发条件 |
| 3 | 编译期 `FD_SETSIZE` 拉大 → `select` 扫描面变大 | ✅ 放大器,不是根因 |
| 4 | Redis 应用层泄漏:`aeDeleteFileEvent → FD_CLR` 没走到 | ⚠️ 在 Linux 上才是首选解释,本案 Cygwin 上次级嫌疑 |
| 5 | I/O threads 与主线程竞态导致 fd 状态错位 | ⚠️ 仅 `io-threads:6` 时有理论可能,无证据 |
| 6 | Redis 自身在 7.4.0 在该路径有回归 | ❌ `ae_select.c` 这段逻辑多年未变,Linux 上未见同样栈 |

> 同样代码 `ae_select.c` 在 Linux 测试机上几乎不会崩;**差异的全部来自 Cygwin 这一层**。

## 5. 这个 bug 现在还在吗

- **上游不会"修"这条路径**:在 Linux/POSIX 语义里,`select` 返回 EBADF 就是状态机已经坏了,`panic` 是正确反应。Redis 不会为了 Cygwin/Windows 去放宽这条断言。
- **平台支持现状**:redis/redis 官方支持 Linux / macOS / *BSD / Solaris;`MSOpenTech/redis`(微软早年 Windows 端口)已停更近 10 年;Cygwin 一直是社区自编译,不在 CI 覆盖范围。
- **复现概率**:只要继续在 Cygwin 上跑、又有大量长寿命连接,**本质上是不可避免的偶发崩溃**,只是触发频率取决于网络/安全软件环境。

## 6. 建议(按性价比从高到低)

1. **换平台,首选**:
   - **WSL2**:真正的 Linux 内核 + epoll,行为与原生 Linux 一致;
   - **Docker Desktop / Linux VM**:同上;
   - **Memurai**:商业 Windows 原生 Redis 兼容产品,适合不能上 Linux 的场景;
   - 不要再用 `MSOpenTech/redis` 老端口。
2. **短期还要留在 Cygwin 时,降低触发概率**:
   - 让所有连接(包括 pubsub)都有定期心跳,避免 Windows 静默回收 idle socket;
   - 把 `maxclients` 从 3168 调到与实际负载匹配(本机峰值才 170),从而压缩 `FD_SETSIZE` 与 `select` 扫描面;
   - 设置 `tcp-keepalive 60`,即使 Cygwin keepalive 间隔不完美也至少有动作;
   - 检查 Windows 防火墙/杀软/LSP,把 redis-server 加白名单;
   - 计划性重启,别赌 Cygwin 上的长跑。
3. **应急 patch(不推荐进生产)**:本地改 `src/ae_select.c`,EBADF 时不 panic,而是用 `fcntl(F_GETFD)` 扫一遍 `eventLoop->events`,把那个坏 fd 从 `rfds/wfds` 里 `FD_CLR` 后继续。能让进程不挂,但偏离上游设计,出问题无人 debug,只适合临时撑场。
4. **保留现场**:Cygwin 下也能开 core(`ulimit -c unlimited` + `cygwin: error_start`),下次崩前 `eventLoop->maxfd`、`rfds/wfds` 位图能进一步定位是哪个 fd。

## 7. 一句话总结

> 这次崩溃不是 Redis 7.4.0 的代码缺陷,而是 **Redis 跑在 Cygwin、用 `select()` 多路复用、又挂着大量长寿命 pubsub 连接** 这套组合下,底层 Winsock 句柄被外部因素失效后,`select()` 返回 EBADF,Redis 按 Linux 约定把它当成不可恢复的状态机错误而 panic。**上游不会修这条路径,正确解法是把生产 Redis 从 Cygwin/Windows 迁到 Linux/WSL2/容器。**
