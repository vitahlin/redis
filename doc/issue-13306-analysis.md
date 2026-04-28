# Redis 7.2.4 集群升级 hang 死分析

> Issue: [redis/redis#13306 — [BUG] Redis hangs during upgrade from v7.0.10 to v7.2.4](https://github.com/redis/redis/issues/13306)

## 1. 现象

从 Redis Cluster 7.0.10 滚动升级到 7.2.4 的过程中，部分被故障切换（failover）后的实例在完成 partial resync 之后**完全无响应**：

- `redis-cli PING / INFO` 等命令均无返回；
- `strace -p <pid>` **完全没有任何系统调用输出**（说明进程没卡在 syscall 上，而是卡在用户态死循环里）；
- 只能 `SIGKILL` 才能停掉进程。

关键日志片段（hang 之前的最后几行）：

```
Configuration change detected. Reconfiguring myself as a replica of ...
Before turning into a replica, using my own master parameters to synthesize a cached master ...
Trying a partial resynchronization (request ...).
Successful partial resynchronization with master.
Master replication ID changed to ...
MASTER <-> REPLICA sync: Master accepted a Partial Resynchronization.
--> hang
```

触发条件归纳：**cluster + activedefrag + replica-lazy-flush + 角色切换（master → replica）**。

## 2. 根因分析

### 2.1 7.2 引入的关键变化

Redis 7.2 把 cluster 的 slot-to-key 映射从单一 radix tree 改成了**每槽一个独立的 dict（kvstore）**。维护这个映射的入口是：

- `slotToKeyInit(db)` / `slotToKeyDestroy(db)`：创建/销毁 16384 个槽字典；
- `slotToKeyReplaceEntry(...)`：每次 active defrag 移动 key 后更新槽字典里的指针。

### 2.2 漏掉的初始化（issue #13205 的根因）

`emptyDbAsync()` 在 lazy flush 数据库时，会重建 `db->dict` 与 `db->expires`，但在 7.2.4 及更早版本中**漏掉了对 slot-to-key 字典的重建**：

```c
void emptyDbAsync(redisDb *db) {
    db->dict    = dictCreate(&dbDictType);
    db->expires = dictCreate(&dbExpiresDictType);
    // ❌ 7.2.4: 没有重建 slotToKey
    ...
}
```

### 2.3 与本 hang 的因果链

用户配置 `replica-lazy-flush yes` + `activedefrag yes`，故障切换后 `Configuration change detected. Reconfiguring myself as a replica` 这一步会：

1. 异步清空 db（走 `emptyDbAsync`） → slot-to-key 字典指针失效但**未重新初始化**；
2. 紧接着 partial resync 完成，新数据写入 `db->dict`；
3. 下一次 `serverCron → databasesCron → activeDefragCycle → defragKey → slotToKeyReplaceEntry` 触发：
   - **运气差时直接 SIGSEGV**：访问 `0x50` 等小地址 → issue [#13205](https://github.com/redis/redis/issues/13205) 的 crash 报告；
   - **运气"好"时**所读到的内存恰好是另一段合法但语义错乱的 dict 结构，`dictFind / rehash` 在错乱的桶链上无限循环 → **用户态死循环、strace 无输出、必须 SIGKILL**，正是本 issue #13306 的表现。

两种现象本质上是同一个 bug 的两种结局。

### 2.4 配套的第二个 bug（issue #13307）

`activeDefragCycle` 中途被打断时漏置 `expires_cursor`：

```c
defrag_later_cursor = 0;
current_db = -1;
cursor = 0;
// ❌ 漏：expires_cursor = 0;
db = NULL;
```

下次重启 active defrag 时 `db == NULL` 但 `expires_cursor != 0`，进入 `defragLaterStep(db, …)` 解引用 NULL → 崩溃。角色切换前后 active defrag 恰好会经历"停 → 再启"，因此也容易踩中。

## 3. 修复情况

### 3.1 PR #13315（已合入 7.2.6）

PR：[#13315 — Fixed crashes due to missed slotToKeyInit() and missed expires_cursor reset](https://github.com/redis/redis/pull/13315)
backport commit: `2ad254874`，包含的 tag：

```
7.2.6  7.2.7  7.2.8  7.2.9  7.2.10  7.2.11  7.2.12  7.2.13
```

核心修改：

```c
// src/lazyfree.c
void emptyDbAsync(redisDb *db) {
    db->dict    = dictCreate(&dbDictType);
    db->expires = dictCreate(&dbExpiresDictType);
    if (server.cluster_enabled) {
        slotToKeyDestroy(db);
        slotToKeyInit(db);          // ✅ 补上
    }
    ...
}
```

```c
// src/defrag.c — activeDefragCycle()
defrag_later_cursor = 0;
current_db = -1;
cursor = 0;
expires_cursor = 0;                 // ✅ 补上
db = NULL;
```

### 3.2 与本 issue 的关系

| Issue | 类型 | 状态 | 关系 |
|---|---|---|---|
| [#13205](https://github.com/redis/redis/issues/13205) | crash @ `slotToKeyReplaceEntry` | **已修（7.2.6, PR #13315）** | 与本 hang 同根因，触发链一致 |
| [#13307](https://github.com/redis/redis/issues/13307) | crash @ defrag NULL deref | **已修（7.2.6, PR #13315）** | 同次提交一起修 |
| [#13306](https://github.com/redis/redis/issues/13306) | **hang**（本 issue） | 仓库中仍为 Open | 维护者无稳定复现，未单独再发修复；从代码路径看，已被 PR #13315 一并消除 |

**结论**：从源码层面看，#13306 描述的 hang 路径在 7.2.6 之后已不再存在，可以认为与 #13205 同因同治。

## 4. 受影响版本与建议

| 版本 | 状态 |
|---|---|
| 7.2.0 ~ 7.2.5 | 受影响 |
| **7.2.6+** | 已修复 |
| 7.4 / 8.x | 不受影响（重写为 kvstore 时已规避） |

### 升级建议

1. **不要把 7.2.4 作为升级目标**，直接选用 7.2 系列最新补丁版本（写本文时为 **7.2.13**），其中已包含：
   - #13315（本文 root cause）
   - #13311（slot 迁移期间 unblock client 崩溃）
   - #13443、#13422、#13465 等 cluster 相关修复

2. **临时缓解（无法立即升级时）**：rolling upgrade 前在所有节点上：
   ```
   CONFIG SET activedefrag no
   ```
   全部节点升级、failover、稳定运行一段时间后再打开。该开关可以完全规避 #13205 / #13306 / #13307 的触发路径。

3. **可选加固**：在生产场景里 `io-threads-do-reads yes` + `activedefrag yes` 这种组合在 7.2 早期版本里历史问题较多，升级到补丁版后再启用更稳妥。

## 5. 参考

- Issue: <https://github.com/redis/redis/issues/13306>
- Related crash: <https://github.com/redis/redis/issues/13205>
- Related crash: <https://github.com/redis/redis/issues/13307>
- Fix PR: <https://github.com/redis/redis/pull/13315>
- 7.2 release notes: <https://raw.githubusercontent.com/redis/redis/7.2/00-RELEASENOTES>
