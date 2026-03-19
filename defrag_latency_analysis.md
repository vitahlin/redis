# Redis Active Defrag 延迟超限问题分析

## 1. 问题现象

```
[err]: Active defrag big keys: standalone in tests/unit/memefficiency.tcl
Expected 39 <= 30 (context: type eval line 142 cmd {assert {$max_latency <= 30}} proc ::test)
```

测试命令：
```bash
./runtest --single "unit/memefficiency" --only "Active defrag big keys: standalone" --loop --stop
```

---

## 2. 测试在检查什么

`memefficiency.tcl` 第 466 行断言：

```tcl
# 通过 r latency latest 获取 active-defrag-cycle 事件的历史最大单次耗时
foreach event [r latency latest] {
    lassign $event eventname time latency max
    if {$eventname == "active-defrag-cycle"} {
        set max_latency $max
    }
}
assert {$max_latency <= 30}   ;# 单位：毫秒
```

**注意**：`max_latency` 是 `activeDefragTimeProc` **单次调用**的最大耗时，
与日志里 `Active defrag done in 658ms` 完全无关——658ms 是整轮 defrag 的总墙钟时间。

### 为什么看不到 `"Starting active defrag"` 日志

测试的 `start_server` 配置了 `loglevel notice`，而该日志级别是 `LL_VERBOSE`：

```tcl
start_server {overrides {... loglevel notice}} {
    test_active_defrag "standalone"
}
```

`LL_VERBOSE(1) < LL_NOTICE(2)`，被过滤掉了。

---

## 3. Defrag 完整调用链

```
serverCron()                           每 10ms 触发（hz=100）
  └─ databasesCron()
       └─ activeDefragCycle()          决策入口：判断是否启动
            └─ beginDefragCycle()      注册所有 stage + 创建独立 timer
                 ├─ addDefragStage(defragStageDbKeys)
                 ├─ addDefragStage(defragStageExpiresKvstore)
                 ├─ addDefragStage(defragStageSubexpires)
                 ├─ addDefragStage(defragStagePubsubKvstore)
                 ├─ addDefragStage(defragLuaScripts)
                 └─ aeCreateTimeEvent(activeDefragTimeProc)

activeDefragTimeProc()                 执行入口（单次最多 5ms）
  latencyStartMonitor ─────────────── 开始计时
  └─ defragStageDbKeys()
       └─ defragStageKvstoreHelper()
            ├─ kvstoreDictScanDefrag()     主字典扫描（每个 bucket）
            └─ defragLaterStep()           大键分批处理
                 └─ defragLaterItem()
                      ├─ scanLaterHash()   无 endtime，无法主动超时
                      ├─ scanLaterSet()    无 endtime，无法主动超时
                      ├─ scanLaterZset()   无 endtime，无法主动超时
                      ├─ scanLaterList()   有 endtime，每128次检查 ✓
                      └─ scanLaterStreamListpacks() 有 endtime ✓
  latencyEndMonitor ───────────────── 结束计时，记录样本
```

### 大键（Big Key）处理机制

遇到大键（元素数 > `active-defrag-max-scan-fields=1000`）时：

```c
// 主扫描中：不立即处理，只记录 key 名
void defragLater(defragKeysCtx *ctx, kvobj *kv) {
    sds key = sdsdup(kvobjGetKey(kv));
    listAddNodeTail(ctx->defrag_later, key);  // 加入延迟列表
}
```

然后在同一 stage 内由 `defragLaterStep` 分批处理，**不会等到下次 defrag cycle**。

---

## 4. 时间预算机制

```c
#define DEFRAG_CYCLE_US 500  // 标准 0.5ms

// 最大 duty cycle（饥饿补偿后上限）
dutyCycleUs = min(targetCpuPercent * waitedUs / (100 - targetCpuPercent),
                  DEFRAG_CYCLE_US * 10);  // 硬上限 5ms
```

**理论单次最大耗时 = 5ms**，但实际观测到 39ms。

### 时间检查盲区

`defragLaterStep` 每 **16 次迭代**才检查一次时间：

```c
if (++iterations > 16 || hits > 512 || scanned > 64) {
    if (getMonotonicUs() > endtime) break;  // 唯一检查点
}
```

`scanLaterSet/Hash/Zset` 没有 `endtime` 参数，单次调用内部无法超时。

---

## 5. 根本原因定位

### 诊断代码

在 `activeDefragAllocWithoutFree` 加计时（`src/defrag.c` 第 151 行）：

```c
monotime t1 = getMonotonicUs();
newptr = zmalloc_no_tcache(size);
monotime elapsed_alloc = getMonotonicUs() - t1;
if (elapsed_alloc > 5000) {
    serverLog(LL_WARNING, "slow zmalloc_no_tcache: %lu us, size=%zu",
              (unsigned long)elapsed_alloc, size);
}

monotime t2 = getMonotonicUs();
memcpy(newptr, ptr, size);
monotime elapsed_memcpy = getMonotonicUs() - t2;
if (elapsed_memcpy > 5000) {
    serverLog(LL_WARNING, "slow memcpy in defrag: %lu us, size=%zu",
              (unsigned long)elapsed_memcpy, size);
}
```

### 实际日志

```
slow zmalloc_no_tcache: 5303 us, size=16    ← 16字节malloc花了5.3ms
slow memcpy in defrag:  8620 us, size=160   ← 160字节memcpy花了8.6ms
```

---

## 6. 原因分析：jemalloc bg-thread 的 purge 行为

```
jemalloc bg-thread
  │
  ├─→ ① Arena mutex 锁竞争
  │        bg-thread purge 时持有 arena bin mutex
  │        zmalloc_no_tcache 使用 MALLOCX_TCACHE_NONE，绕过 tcache
  │        直接竞争同一把 arena mutex → 主线程等锁 5ms
  │
  └─→ ② madvise(MADV_DONTNEED) → page fault
            bg-thread 调用 madvise(MADV_DONTNEED) 释放物理页
            zmalloc_no_tcache 返回无物理页的虚拟地址
            memcpy 第一次写入 → 触发 page fault
            内核重新分配物理页 → 耗时 8ms
```

**`memcpy` 没有任何锁**，160 字节正常应在纳秒级完成，8.6ms 只能由 page fault 解释，
而 page fault 正是 bg-thread `MADV_DONTNEED` 的后果。

---

## 7. 结论

| 怀疑原因 | 结论 |
|---|---|
| 代码 bug | ❌ 不是 |
| OS 调度抢占 | 部分（page fault 阶段内核介入） |
| **jemalloc bg-thread purge** | ✅ **根本原因** |

---

## 8. 修复方向

| 方案 | 改动位置 | 说明 |
|---|---|---|
| **关闭 jemalloc-bg-thread**（验证用） | 测试 overrides | `jemalloc-bg-thread no`，确认问题消失后再决策 |
| **提高测试阈值** | `memefficiency.tcl:466` | `assert {$max_latency <= 50}` |
| **缩小时间检查盲区** | `defrag.c defragLaterStep` | 将 `iterations > 16` 改为更小值 |
| **给 scanLaterSet/Hash/Zset 加 endtime** | `defrag.c` | 与 `scanLaterList` 保持一致，支持主动超时 |

