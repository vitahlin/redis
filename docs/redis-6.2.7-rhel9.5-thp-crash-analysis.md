# Redis 6.2.7 崩溃分析:RHEL 9.5 内核 THP 竞态踩坏用户态堆

对应上游 issue:[redis/redis#14084](https://github.com/redis/redis/issues/14084)

相关旁证:[redis/redis#13832](https://github.com/redis/redis/issues/13832)、[ClickHouse/ClickHouse#78509](https://github.com/ClickHouse/ClickHouse/issues/78509)、[Red Hat KCS 7107907](https://access.redhat.com/solutions/7107907)

## 1. 三个崩溃栈翻译

| # | 崩溃点 | 调用路径 | 进程 |
|---|---|---|---|
| 1 | `0x4c8c7d`(`activeExpireCycle+0x253` 之前的内联段) | `serverCron → databasesCron → activeExpireCycle → activeExpireCycleTryExpire` | 主进程 |
| 2 | `raxRemove+0x284` | `activeExpireCycle → deleteExpiredKeyAndPropagate → dbAsyncDelete → slotToKeyUpdateKey → raxRemove` | 主进程,cluster 模式 slot→key 树 |
| 3 | `rdbSaveObject+0x4b8` | `serverCron → rewriteAppendOnlyFileBackground → rdbSaveRio → rdbSaveKeyValuePair → rdbSaveObject` | **`redis-aof-rewrite` 子进程** |

栈 1/2 都是过期扫描时引爆,栈 3 是 AOF rewrite 子进程在序列化 value 时引爆。三条调用链在 `src/expire.c`、`src/db.c`、`src/aof.c`、`src/rdb.c` 中均存在,**没有任何逻辑缺陷**。

## 2. 寄存器/地址的关键证据

| 现象 | 含义 |
|---|---|
| 栈 1 中 `RAX/RBX/RDI/RSI = 0`,但崩溃地址是 `0xffffffffffffffff` | 从某结构体读出来的字段已经是 `-1`,做指针运算后落到非法地址 |
| `RBP = 0xfffffe695deb90e3`、`R15 = 0x00000196a2146f1d` | 完全不像合法的栈/堆指针,寄存器里装着已经被随机改写过的字 |
| 栈 2 访问 `(nil)` | rax 节点指针被改成 NULL |
| 栈 3 在 fork 出来的子进程里同样访问 `0xffffffffffffffff` | 父进程被破坏的页通过 COW 一起带进了子进程 |
| 崩前几分钟无任何 Redis 日志活动,堆用量仅 20–30% | 不是负载尖刺,不是 OOM,是"早就被改坏、之后第一次读到时才显形" |

## 3. 判定:这是堆腐蚀,且**不是 Redis 自身造成**

1. 三条栈**没有共同的逻辑路径**——一个走 dict 遍历,一个走 cluster slot rax,一个走 fork 子进程序列化对象;Redis 侧的 bug 几乎不可能同时命中这三条。
2. **AOF 子进程也崩**(栈 3)。fork 之后子进程页表来自父进程,父进程内存里被改坏的内容会一比一映射到子进程,所以同一份损坏会在父子进程都引爆。
3. **强烈的内核版本相关性**(用户自己确认):同镜像、同二进制、同负载,
   - 跑在 `5.14.0-383.el9.x86_64`(RHEL 9.4)的宿主上,**完全不崩**;
   - 跑在 `5.14.0-533.el9.x86_64`(RHEL 9.5)的宿主上,**1–2 天必崩一次**。
   如果是 Redis bug,不可能挑内核。

## 4. 真正的根因:RHEL 9.5 `__split_huge_pmd_locked()` / GUP-fast 竞态

证据链:

| 来源 | 内容 |
|---|---|
| Red Hat KCS 7107907 | "Kernel panic with BUG: unable to handle page fault for address in `split_huge_pmd_locked()`",根因是上游补丁 *"mm: fix race between `__split_huge_pmd_locked()` and GUP-fast"* 描述的 PMD 竞态。**官方修复:升级到 `kernel-5.14.0-570.12.1.el9_6` 或更新;临时绕过:关闭 THP/HugePages**。 |
| redis/redis#13832 | 同样是 RHEL 9.4 → 9.5 之后 Redis 6.2.6 开始崩,栈也是 `activeExpireCycleTryExpire → sdslen(s=0x0)`,维护者结论是"OS/jemalloc 兼容性问题",升级 Redis 到 7.2.7 后好了——但**没合入任何 Redis 侧 fix**。 |
| ClickHouse#78509 | 同一批 RHEL 9.5 (`5.14.0-503.23.2.el9_5`) 内核上,ClickHouse 出现"随机 segfault、栈各异、磁盘和数据校验都查不到问题",**降级回 9.4 内核就全好**。同一个内核坑,不同受害者。 |
| redis/redis#14084 | 你的现场,issue 仍 Open,无 assignee,无关联 PR。 |

为什么 Redis 特别容易中招:

- jemalloc 大量使用 `mmap` + `madvise` 管理大块匿名内存,与 THP/`khugepaged` 交互密集;
- `activeExpireCycle`、`raxRemove`、`rdbSaveObject` 都是**高频随机访问**用户态堆的小对象,任何一个 4KB 物理页错乱都会被快速放大成崩溃;
- Docker 多容器 bin-pack 到同一裸机 → 内存压力大、`khugepaged` / `kswapd` 频繁动 PMD → 触发竞态的概率远高于单机轻负载。
- 这恰好对应了"多容器同宿主、跑 1–2 天后必崩、堆才用 20–30%"的全部现象。

## 5. 这个 bug 现在还在吗

- **Redis 侧不存在可合入的修复**。issue #14084 维持 Open,没有任何 PR 关联;历史相似 issue (#13832) 维护者也明确判定为 OS 兼容性问题。
- **内核侧已经修了**。Red Hat 在 `5.14.0-570.12.1.el9_6` 开始的 RHEL 9.6 内核里 backport 了上游 `__split_huge_pmd_locked()` 的竞态修复。
- 所以这个崩溃当前 **只能从 OS 这一层解决**,Redis 这边等不到补丁。

## 6. 建议(按性价比从高到低)

1. **首选:升级宿主内核到 `kernel-5.14.0-570.12.1.el9_6` 或更新**(RHEL 9.6+)。先升一台,跑满 3–4 天(> 已知 1–2 天崩溃间隔)再批量铺。
2. **过渡期:关闭 THP**。容器内的 THP 由宿主决定,在宿主上执行:
   ```bash
   echo never > /sys/kernel/mm/transparent_hugepage/enabled
   echo never > /sys/kernel/mm/transparent_hugepage/defrag
   ```
   再加 `transparent_hugepage=never` 到 grub 持久化。这一步顺便能消掉 Redis 启动日志里一直存在的 THP 警告和延迟抖动。
3. **降级路线**:如果业务允许,直接把宿主回滚到 9.4 (`5.14.0-427.x` / `-383.x`) 也可立刻止血——这是 ClickHouse 同事采用的方案。
4. **顺手升 Redis**:6.2.7 已超出 6.2 维护窗口,推荐升到 7.2.x / 7.4.x。**这一步并不能单独解决该问题**(根因在内核),但能拿掉一批 6.2 老坑,后续再有崩溃也更容易获得上游支持。
5. **抓证据(可选)**:宿主 `dmesg` 搜 `split_huge_pmd`、`BUG: unable to handle page fault`、`general protection fault`;能跑一台 ASan/Valgrind 编译版 Redis 跑同样负载的话,大概率第一次踩到坏页时就被逮住,且栈会与上面三条都不同——这正是"症状不是病因"的直接证明。

## 7. 一句话总结

> 这不是 Redis 6.2.7 的 bug,而是 RHEL 9.5(`5.14.0-503/-533`)内核 `__split_huge_pmd_locked()` 与 GUP-fast 之间的竞态破坏了 jemalloc 管理的用户态匿名页。Redis 只是"运气最差"的受害者:`activeExpireCycle`、`raxRemove(slot→key)`、AOF 子进程的 `rdbSaveObject` 都是高频访问堆的热点,所以总在这几个点引爆。**把宿主内核升到 `5.14.0-570.12.1.el9_6` 或更新版本(或暂时关闭 THP)即可解决,Redis 侧不存在能合入的修复。**
