# Redis 7.2.10 崩溃分析:readQueryFromClient → sdsIncrLen 断言失败 (SIGABRT)

## 1. 崩溃栈翻译

```
aeMain
└─ aeProcessEvents
   └─ readQueryFromClient (+0x2d7)              src/networking.c:2694
      ├─ sdsMakeRoomFor(c->querybuf, readlen)   先扩容
      ├─ connRead(c->conn, c->querybuf+qblen, readlen)
      └─ sdsIncrLen(c->querybuf, nread)  (+0x10a) ★ 在这一步触发
         └─ assert(...)                         src/sds.c
            └─ __assert_fail → abort → SIGABRT (signal 6, si_code -6)
```

具体断言(7.2.10 `src/sds.c`,`SDS_TYPE_8/16/32/64` 四个分支文本相同):

```c
assert((incr >= 0 && sh->alloc - sh->len >= incr) ||
       (incr < 0  && sh->len >= (unsigned int)(-incr)));
```

含义:`sdsIncrLen` 准备把 `c->querybuf` 的 `len` 推进 `nread` 字节,但 SDS header 里 `alloc - len < nread`,即**剩余空间不够**,直接 `abort`。

## 2. INFO 里的关键事实

| 字段 | 值 | 含义 |
|---|---|---|
| `redis_version` | `7.2.10` | 7.2 当前末班版本(2025-07-06 发布) |
| `os` | `Linux 3.10.0-1160.49.1.el7` | CentOS/RHEL 7.9,内核较旧但稳定 |
| `multiplexing_api` | `epoll` | 走 `ae_epoll`,**不是** evport(排除 #14056) |
| `io_threads_active` | `0` | io-threads 没启用,**排除** io-threads + TLS 那条 bug 路径(#12540 / #13799 / PR #13695) |
| `listener0` / `listener1` | tcp 127.0.0.1:6379 + unix sock | **没有 TLS listener**,再次排除 io-threads + TLS |
| `process_id` / `process_supervised` | `45676` / `no` | 用户态裸跑 |
| `uptime_in_seconds` | `213248` (~2.5d) | 长跑,跟 6.2.6 那次表现一致 |
| 崩溃前 13 秒 | `Background saving terminated with success` | RDB CoW 10MB,本身正常,**不是 BGSAVE 直接触发** |
| 寄存器 `RDX=6` | | `tgkill(tid, tid, 6)` 即 `raise(SIGABRT)`,确认走 `abort()`,不是 SIGSEGV |

## 3. 直接原因 vs 根因

- **直接原因**:在 `readQueryFromClient` 主线程同步路径上,`sdsMakeRoomFor(c->querybuf, readlen)` 刚保证了至少 `readlen` 字节空闲,`connRead` 又最多只能写入 `nread ≤ readlen` 字节,但紧接着 `sdsIncrLen(c->querybuf, nread)` 看到 `alloc - len < nread`,断言失败。
- **代码自身没有这个矛盾**:7.2.10 的这条路径上,从 `sdsMakeRoomFor` 到 `sdsIncrLen` 之间**没有任何会修改 `c->querybuf` header 的调用**,也没有把 `c->querybuf` 释放/重指的分支。
- **唯一自洽的解释**:`c->querybuf` 对应那块 SDS 内存的 header(`len` / `alloc`)**被另一条路径越界写坏了**,`sdsIncrLen` 只是第一个用 `len` / `alloc` 做算术校验的人,因此首先 abort。
- 所以这次崩溃的**结构性质跟 6.2.6 那次完全一样**:**别处发生的堆越界,在 `readQueryFromClient` 的入口检查里显形**;不是网络读这一段的逻辑 bug。

## 4. 嫌疑犯逐一核对

| # | 嫌疑路径 | 在本案的角色 |
|---|---|---|
| 1 | **io-threads 主线程/工作线程并发改 `c->querybuf`** (#12540 / #13799,PR #13695 删了 `io-threads-do-reads` 文档) | ❌ `io_threads_active:0`,且没有 TLS,直接排除 |
| 2 | **TLS + io-threads 不安全组合** | ❌ 没配 TLS listener |
| 3 | **evport 多路复用相关** (#14056) | ❌ `multiplexing_api:epoll` |
| 4 | **PROTO_MBULK_BIG_ARG 大 bulk 路径** 里换 `c->querybuf`(networking.c:2368/2398) | ⚠️ 7.2.10 仍有此路径,但只在**已经解析完一段**之后换,跟当前栈所在的"读入阶段"不重叠;只有当 `c->bulklen` 已被踩坏到极大值才有可能,需要 core dump 验证 |
| 5 | **加载的 module 写越界**(RedisJSON / RedisSearch / RedisBloom / RedisTimeSeries / 自研 module) | ⚠️ 主嫌之一。INFO 截断没贴 `# Modules` 段。Module 与 `c->querybuf` 共用 jemalloc 堆,任何 OOB 写都可能落到隔壁 SDS header 上 |
| 6 | **Lua 脚本 / `redis.call` argv 缓存** 残留腐蚀(类似 #11652、PR #13725 的 cron argv 释放族) | ⚠️ 次级嫌疑。7.2 这条路径修过几轮,但和 7.4/unstable 比仍少几个补丁 |
| 7 | **物理内存/ECC** | ⚠️ 长跑 2.5 天后崩,且无并发逻辑能改 header,可顺手做 memtest 排除 |
| 8 | **glibc 2.17 (RHEL7) malloc 行为差异** | ⚠️ 极小概率,且 Redis 默认链 jemalloc,基本不走 glibc malloc |

> 一个**最便宜的现场证据**:崩溃前 13 秒刚做完一次 BGSAVE,`fork()` 之后父子进程都用 jemalloc;如果有 module 在子进程退出阶段或 fork 边界做了 OOB 写,这个时间窗会显著抬高显形概率。

## 5. 这个 bug 现在还在吗

- **7.2.10 是 7.2 分支末班车之一**,所有已知"`sdsIncrLen` abort 类"的回归都已合并,包括:
  - PR #13695:从 7.4 起明确移除 `io-threads-do-reads`(本案本来就用不到,因为 io-threads 没开);
  - PR #13725 / #14162 等大 bulk / cron argv / evport 类修复——多数在 7.4.x / unstable,**7.2.x 不会再回填新功能性修复**。
- **以同样的栈在不动 module、不动 Lua 的纯 Redis 7.2.10 上复现的概率很低**;**有 module/Lua 业务时仍可能复现**,因为根因在 Redis 之外。
- 这是为什么从 6.2.6 升到 7.2.10 之后**症状没变**:升级修掉的是"Redis 自身在哪些路径会越界",但**业务侧 module / Lua / 第三方扩展的越界没动过**,所以同样的二次显形依旧出现。

## 6. 建议(按性价比从高到低)

1. **打开 core dump,拿一次崩盘现场**(最关键的一步):
   - `ulimit -c unlimited` + 配置 `/proc/sys/kernel/core_pattern`;
   - `redis.conf` 里 `crash-log-enabled yes`、`crash-memcheck-enabled yes`;
   - 崩后用 `gdb redis-server core` 看 `c->querybuf` 的 `sh->len`、`sh->alloc`、`nread`、`readlen` 四个值,**一眼能区分**:`alloc==0 / len 异常大` → header 被踩;`nread > readlen` → `connRead` 异常(几乎不可能);否则就是别的极偶然原因。
2. **把外部攻击面砍干净再观察**:
   - **逐个卸载 module**(RedisJSON / Search / Bloom / TimeSeries / 自研),用最小可用集合跑同样负载;
   - **暂停 Lua / Function 路径**,或把 `EVAL` 入口在业务里关掉;
   - 如果停掉某个 module / 脚本后 1 周内不再崩,**根因基本就锁定了**。
3. **用排查版二进制跑一阵**:
   - jemalloc:`MALLOC_CONF=abort_conf:true,xmalloc:true`,越界第一时间炸在凶手那一帧;
   - 或者编译 ASan 版 (`make MALLOC=libc CFLAGS="-fsanitize=address -g" LDFLAGS="-fsanitize=address"`) 跑灰度;
   - 把 `proto-max-bulk-len` 调回默认 `512mb`,别再放大;`client-query-buffer-limit` 也回默认。
4. **基础环境核对**:CentOS 7.9 跑 `memtester` / EDAC 看看物理内存与 ECC,顺手排除硬件;关闭 THP(`echo never > /sys/kernel/mm/transparent_hugepage/enabled`),Redis 文档一直建议这么做。
5. **不要只升小版本**,如果业务允许,**直接升 7.4.x 或 8.x**:7.4 起 `c->querybuf` 改成 thread-local reusable buffer,对应路径有结构性重写,顺带修了一批 7.2 不会再回填的 corner case。

## 7. 一句话总结

> 这次崩溃**不是 Redis 7.2.10 自身网络读路径的逻辑 bug**:`sdsMakeRoomFor → connRead → sdsIncrLen` 三连里没有任何并发或重指机会,而 INFO 已经排除了 io-threads/TLS/evport 这些常见的"自身回归"嫌疑。**真正的元凶是别处对 `c->querybuf` 所在那块 SDS 内存的越界写**(主嫌:加载的 module / Lua 脚本路径),它把 SDS header 踩坏后,下一次 `readQueryFromClient` 走到 `sdsIncrLen` 的入口断言时第一时间 abort。这跟 6.2.6 那次"keyspace notification 拼字符串崩"是同一种**二次显形**。**升级版本治标,抓 core / 卸 module / Lua / 跑 ASan 才能定位真正越界的那一行**。
