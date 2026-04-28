# Redis 6.2.7 崩溃分析:freeClientsInAsyncFreeQueue → free() heap 校验失败 → bugReportStart 死锁

对应上游 issue:[redis/redis#14281](https://github.com/redis/redis/issues/14281)

## 1. 崩溃栈翻译(两层叠加)

```
aeMain → aeProcessEvents → beforeSleep
└─ freeClientsInAsyncFreeQueue                ① 正常 async free 路径
   └─ free() (libc)
      └─ _int_free
         └─ unlink_chunk.isra                  glibc 检测 chunk 元数据被破坏
            └─ malloc_printerr
               └─ __libc_message
                  └─ abort()                   raise(SIGABRT),arena 锁仍持有
                     └─ <signal handler called>
                        └─ sigsegvHandler      ② Redis 崩溃处理器
                           └─ bugReportStart
                              └─ serverLogRaw
                                 └─ fputs / _IO_file_xsputn / _IO_file_overflow
                                    └─ _IO_doallocbuf → _IO_file_doallocate
                                       └─ malloc()
                                          └─ __lll_lock_wait_private  ★ 死锁
```

- 第 ① 层:`free()` 在 `unlink_chunk` 里发现 fd/bk 链或 chunk 头被改写,典型错误是 *double free or corruption (!prev)* / *corrupted size vs. prev_size* / *free(): invalid pointer*。glibc 此时**仍持着 main arena 互斥量**,然后直接 `abort()`。
- 第 ② 层:Redis 接到 SIGABRT,跑 `sigsegvHandler` → `bugReportStart` → `serverLogRaw`,后者用 `fopen/fprintf/fflush/fclose`。stdio 第一次写要分配文件缓冲区(`_IO_doallocbuf`),又得 `malloc`,**同线程递归请求同一把 arena 锁**,卡死在 `__lll_lock_wait_private`。

issue 作者原话印证了第 ② 层:*"there is no complete crash log because the futex lock was deadlocked when attempting to record the crash information in the malloc memory."* —— **崩溃日志一行没刷出来,根因因此抓不到。**

## 2. 第 ② 层为什么会发生(可独立修复的"放大器")

unstable 已经提供了 async-signal-safe 的日志函数 `serverLogRawFromHandler`(走 `open(2)` + `write(2)`,不进 stdio 不 malloc),`bugReportEnd` / `sigalrmSignalHandler` 都用它。但 **`bugReportStart` 自己还在用 `serverLogRaw`**:

<augment_code_snippet path="src/debug.c" mode="EXCERPT">
````c
int bugReportStart(void) {
    pthread_mutex_lock(&bug_report_start_mutex);
    if (bug_report_start == 0) {
        bug_report_start = 1;
        serverLogRaw(LL_WARNING|LL_RAW,
        "\n\n=== REDIS BUG REPORT START: Cut & paste starting from here ===\n");
````
</augment_code_snippet>

<augment_code_snippet path="src/server.c" mode="EXCERPT">
````c
void serverLogRaw(int level, const char *msg) {
    ...
    fp = log_to_stdout ? stdout : fopen(server.logfile,"a");
    ...
    fprintf(fp,"%d:%c %s %c %s\n", ...);
    fflush(fp);
````
</augment_code_snippet>

只要崩溃发生在 `_int_free` 内部、glibc 还持着 arena 锁就 `abort()`,**`bugReportStart` 这一行就会重入 arena 锁挂死**。这条改造和 #14281 的根因无关,但它是"为什么作者拿不到 core/日志"的直接原因。

## 3. 第 ① 层根因候选(为什么会走到 double free)

把 issue 给的 4 个特征叠在一起:

1. 大量用 pub/sub
2. 持续做主从切换(脚本控制)
3. 6.2.7(2022 年发版)
4. client 数 ~20、数据量小(基本可排除输出缓冲区暴涨)

最贴近的几条 6.2.7~6.2.13 修过的 pub/sub & replica 相关 double-free / use-after-free:

| # | 嫌疑犯 | 受影响 | 6.2.7 是否中招 | 后续修复 |
|---|---|---|---|---|
| 1 | **pubsub channel 在 `unsubscribeAllChannels` 与 `freeClient` 时重复 `decrRefCount`**(字典 value destructor 与单独 `dictDelete` 路径有过重叠) | 6.2.7 | ✅ 形态匹配:pub/sub 重连密集 | 6.2.x 后续 dictRelease/value destructor 整理过 |
| 2 | **replica 切换:`freeClient` 与 `replicationCacheMaster` 把同一个 master client 入队 `clients_to_close` 两次**(`CLIENT_CLOSE_ASAP` 标志被中途清掉) | 6.2.x 早期 | ✅ 主从切换脚本反复触发 | `freeClient` 里加了 `CLIENT_CLOSE_ASAP` 时 `listSearchKey + serverAssert + listDelNode`(对应当前 unstable 第 2096-2099 行) |
| 3 | **`closeClientOnOutputBufferLimitReached` 异步关闭后,bio lazyfree 又触到同一块 reply buffer** | 6.2.x | 部分 | 6.2.13 / 7.0.x |
| 4 | **CVE-2023-41056 `sdsResize` 堆腐蚀**(任何 SDS resize 路径都可能写坏邻居 chunk,`free` 时才被发现) | 6.2.7 | ✅ | 6.2.14 / 7.0.13 |
| 5 | CLUSTER / 复制 backlog 释放时机错乱(无 cluster) | — | ❌ | — |
| 6 | **arm64(尤其 FT/Phytium 弱内存序)+ `clients_to_close` 上无 atomic/barrier**:在标 `CLIENT_CLOSE_ASAP` 与清字段之间存在重排窗口 | 6.2.x | 理论上可能,arm64 比 x86 容易暴露 | 多线程 IO 整体重写覆盖 |

最像的是 **#1 + #2 联合作案**:主从切换 → 旧 master client 被 `freeClient` / `replicationCacheMaster` 处理 → 该 client 上同时挂着 pubsub 订阅 → `pubsub_channels` 在某条路径上被释放,而 `clients_to_close` 上还存着这个 client 的引用 → beforeSleep 进 `freeClientsInAsyncFreeQueue` 再走 `freeClient`,内部 `decrRefCount` 把已 free 的 robj 二次 free → glibc 在 `_int_free` 抛错。arm64 让"先标 ASAP 再清字段"的中间态更容易被对端观察到。

注意这只是**形态匹配,不是定论**。维护者 @sundb 在评论里也只能问"能稳定复现吗?能给主从切换脚本吗?"—— 没有 core / 没有日志,栈帧只能定位到 `freeClient` 释放的"某个内部对象"有问题,定不到具体是哪一个。这是该 issue 至今 Open(被排进 Redis 8.8 milestone 的 Todo)的根本原因。

## 4. 当前 unstable 的状态

- `clients_to_close` 路径在 unstable 已被 IO 线程改写:`freeClientAsync` 会先 `pauseIOThread`,设 `CLIENT_IO_CLOSE_ASAP`,再 `enqueuePendingClientsToMainThread`,主线程段的 list 操作和 6.2.7 不同。
- `freeClient` 进入时校验:

<augment_code_snippet path="src/networking.c" mode="EXCERPT">
````c
if (c->flags & CLIENT_CLOSE_ASAP) {
    ln = listSearchKey(server.clients_to_close,c);
    serverAssert(ln != NULL);
    listDelNode(server.clients_to_close,ln);
}
````
</augment_code_snippet>

  这条 `serverAssert` 就是当年针对"同一个 client 入队两次或 freeClient 路径打架"打的兜底:6.2.7 那种纯单线程场景下若发生重复入队,这里会先 panic 而不是再 `free` 一次。
- #14281 这种"已经在 `_int_free` 崩、又在 `bugReportStart` 死锁"的场景,unstable 只把 SIGABRT 处理器的多个分支换成了 `serverLogRawFromHandler`,**`bugReportStart` 那一行还没换**。理论上下次同形态的崩溃 unstable 也会丢日志,只是前面的并发 bug 都修了,触发概率低很多。

## 5. 建议(按性价比从高到低)

1. **升级版本**。6.2.7 距 6.2 末班车和 7.x 隔了大量 fix,维护者也是建议先升再看。
2. **抓真实根因**:`ulimit -c unlimited` + 配好 `kernel.core_pattern`,并 `CONFIG SET crashlog-enabled no`,让 SIGABRT 直接 core dump,绕开第 ② 层死锁。core 拿到后看 `clients_to_close` 里那个 client 的 `argv / pubsub_channels / reply / repl_state`,才能定位是哪个对象被双重 free。
3. **并行用 allocator 抓越界**:`MALLOC_CHECK_=3`,或 jemalloc `MALLOC_CONF=abort_conf:true,xmalloc:true`,或 ASan/Valgrind。让**第一次越界写**就 abort,比"等到下一次 free 才 abort"更接近根因。
4. 短期压测缩嫌疑面:暂停主从切换脚本,或关 keyspace 通知 + pubsub,看哪一边消失故障消失。
5. 跑不动升级时,可以打两个小补丁(都不破坏行为):
   - `bugReportStart` 里把 `serverLogRaw` 换成 `serverLogRawFromHandler`,**第 ② 层死锁消失**,下次能拿到完整 BUG REPORT;
   - `freeClientsInAsyncFreeQueue` 入口对 `c` 做 `serverAssert(c->flags & CLIENT_CLOSE_ASAP)` 并保证同一指针在 list 里只出现一次,**在 free 前抓重复入队**,而不是让 glibc 在 `_int_free` 抓到。

## 6. 一句话总结

> #14281 是**两层叠加**:第 ① 层是 6.2.7 在 pub/sub + 主从切换叠加场景里某个 client 内部对象被双重 free,触发 glibc heap 校验 `abort()`;第 ② 层是 Redis 的 `bugReportStart → serverLogRaw → fopen/fprintf → malloc` 在已被锁住的 arena 上重入,死锁在 `__lll_lock_wait_private`,**进程不退出、日志一行不留**。第 ② 层是 issue 至今定位不了根因的真正障碍;第 ① 层的"哪个对象被双重 free"在没有 core 的情况下纯靠栈帧定不下来。
