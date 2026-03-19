## Active defrag latency 分析重启说明

### 背景
- 关注用例：`tests/unit/meme2.tcl`
- 关注 case：`Active defrag main dictionary: standalone`
- 失败形式：Tcl 断言 `assert {$max_latency <= 30}` 失败
- 典型失败值：`active-defrag-cycle` 最大延迟到 `37ms`

### 已确认的测试现象
- `LATENCY HISTORY active-defrag-cycle` 常见值并不低，常态约 `13~18ms`
- 失败 spike 典型值：`37ms`
- 失败事件是 `active-defrag-cycle`，不是 `command`
- 最终 `INFO` 末态通常并不异常：
  - `allocator_frag_ratio: 1.01`
  - `mem_overhead_db_hashtable_rehashing: 0`
  - `active_defrag_running: 0`

### Tcl 输出里已经能确认的点
- 失败是 wall-clock latency 超标，不是功能错误
- `command` latency 不是本次断言的直接目标
- Tcl 里打印的 `scanned:` 为空，`avg_us_per_scan: 0`
  - 说明脚本取 `active_defrag_scanned` 的逻辑当前不成立
  - 因此这两个字段当前**不要拿来推结论**

## 已做过的 instrumentation 与当前推荐观察点

### 当前最有价值的日志
如果继续沿用前一轮的 instrumentation，优先观察 `defrag-debug helper-loop` 单行日志即可。

该日志已经合并了两类信息：
- helper 外层：`loop` / `cpu` / `budget` / `overrun` / `iterations`
- 底层 scan：`scan_elapsed` / `scan_rehash` / `scan_entries` / `scan_buckets` / `scan_expanded`

重点字段：
- `loop=`：整轮 helper 的 wall-clock
- `cpu=`：整轮 helper 的 CPU time
- `overrun=`：是否超出 budget
- `scan_elapsed=`：`dictScanDefrag()` 本次调用的 wall-clock
- `scan_rehash=`：是否走 rehash 路径
- `scan_entries=`：本次 scan 处理的 entry 数

### `scan_elapsed` 的准确含义
`scan_elapsed` 是前一轮调试日志里的字段名，不是正式公共 API 名称。它表达的是：

- 一次 `dictScanDefrag()` 调用从进入到返回的 **wall-clock** 耗时

对应调用链：
- `defragStageKvstoreHelper()`
- `kvstoreDictScanDefrag()`
- `dictScanDefrag()`

需要注意：
- 它不是 `dictScanDefragBucket()` 单独的耗时
- 它不是 `dbKeysScanCallback()` 单独的耗时
- 它也不是 `activeDefragEntry()` 单独的耗时

因此：
- `scan_elapsed ~= loop` 只说明慢点大部分落在 `dictScanDefrag()` 这次调用期间
- **不等于** `dictScanDefrag()` 在 CPU 上持续忙跑了这么久
- 如果同时看到 `cpu << loop`，更应解释为该调用期间发生了明显 off-CPU 或等待

### 已经做过但后来收口/淘汰的日志
- 单独的 `dict-scan` 日志：已合并进 `helper-loop`
- `dict-bucket` / `stage-call` / `timeproc`：已证明信息价值低于干扰，后续可不作为主入口

## 到目前为止已经较可靠的结论

### 1. 不是 rehash 路径导致的主问题
慢样本多数表现为：
- `scan_rehash=0`
- `scan_expanded=0`
- `scan_buckets=1`

结论：
- 当前主要问题**不是** `dictScanDefrag()` 里 rehash 扩展 bucket 的 `do...while`

### 2. 不是“大 bucket / 很多 entry”导致
慢样本里经常只有：
- `scan_entries=1`
- `scan_entries=2`
- `scan_entries=3`

结论：
- 当前主要问题**不像** bucket 很长或 entry 太多

### 3. 不是“每 16 次才检查时间”这个阈值本身导致
慢样本出现在多种 `iterations` 值上，包括：
- `iterations=1`
- `iterations=5`
- `iterations=8`
- `iterations=10`
- `iterations=12`

结论：
- 慢点不是单纯因为 helper 外层时间检查过粗
- 单次 iteration 自己就可能变成大 wall-clock 片段

### 4. 当前更像 off-CPU / wall-clock 放大，而不是纯 CPU 热点
典型慢样本：
- `loop=15581us cpu=3us`
- `loop=23153us cpu=1007us`
- `loop=29253us cpu=1005us`

结论：
- wall-clock 很大，但 CPU time 很小
- 当前更像线程在这段期间被调度切走、等待，或遭遇其他 off-CPU 停顿
- **不像** defrag 代码持续跑满十几毫秒 CPU

### 5. 慢点分成两类
#### A. `scan_elapsed ~= loop`
例如：
- `loop=12020us cpu=1010us scan_elapsed=12020us scan_entries=3`

含义：
- 慢点大部分发生在 `dictScanDefrag()` 调用期间
- 但依然有明显 off-CPU 特征（CPU 远小于 wall-clock）
- 这里的含义是“慢在这次调用覆盖的时间范围内”，不是“这个函数连续跑满了这些 CPU 时间”

#### B. `scan_elapsed << loop`
例如：
- `loop=8014us cpu=1005us scan_elapsed=2us scan_entries=1`

含义：
- 慢点不在 `dictScanDefrag()` 本体
- 更像发生在 helper-loop 外围

### 6. 早期高频日志曾明显污染结果
之前每轮同时打印：
- 一条 `dict-scan`
- 一条 `helper-loop`

这会把日志本身的格式化/写文件/调度等待混入 `helper-loop` wall-clock。

当前做法已改为：
- 每轮只保留一条 `helper-loop`
- 将 scan 信息合并进去

## 现在仍未确认的点

### 1. 还不能精确断言 off-CPU 的根因
目前只能说“主要像 off-CPU 放大”，但还不能仅凭现有日志区分：
- Linux 调度抢占
- allocator / page fault / 内核等待
- 其他系统层面停顿

### 2. 还没有 `scan_cpu`
当前只有：
- `loop_cpu`
- `scan_elapsed`

没有：
- `scan_cpu`

因此，“scan 内是否也以 off-CPU 为主”目前是强推断，不是最终实锤。

## 当前最稳妥的工作假设

> `active-defrag-cycle` 的 spike 更像 wall-clock latency 鲁棒性问题，
> 而不是 rehash/bucket 长度/纯 CPU 热点问题。

更直白地说：
- 主线程某些 defrag 相关片段会偶发在 wall-clock 上被放大
- 放大后就触发 `active-defrag-cycle` 断言
- 当前更像调度/环境噪声或较底层停顿被放大，而不是算法复杂度问题

## 下一轮重新分析时的最小入口

### Step 1：先做低干扰复现
Linux 上建议优先用：

```bash
taskset -c 2-7 ./runtest \
  --dont-clean --dont-pre-clean \
  --single unit/meme2 \
  --only "Active defrag main dictionary: standalone" \
  --loop --stop > /tmp/runtest.baseline.log 2>&1
```

建议：
- 不开 `--verbose`
- 不开 `--dump-logs`
- 不边跑边 `tail -f` 日志

### Step 2：失败后再看 server log
建议 grep：

```bash
grep 'defrag-debug helper-loop\|defrag-debug helper-end' tests/tmp/server.*/stdout
```

只看慢样本：

```bash
grep 'defrag-debug helper-loop' tests/tmp/server.*/stdout \
  | grep -E 'loop=[1-9][0-9]{3,}us|overrun=[1-9]'
```

### Step 3：优先按这三类模式分桶
#### 模式 A
- `loop` 大
- `cpu` 小
- `scan_elapsed` 大

说明：
- 慢点发生在 `dictScanDefrag()` 期间
- 但仍偏 off-CPU

#### 模式 B
- `loop` 大
- `cpu` 小
- `scan_elapsed` 小

说明：
- 慢点发生在 helper 外围

#### 模式 C
- `loop` 大
- `cpu` 也大

说明：
- 才值得重新怀疑真实 CPU 热点

## 如果下一轮还要继续加 instrumentation

优先级建议：
1. `scan_cpu`
2. `pre_scan_elapsed`
3. `post_scan_elapsed`

原因：
- 能直接区分“慢在 scan 内”还是“慢在 scan 外”
- 能进一步判断 scan 内到底是 CPU 热点还是 off-CPU

## 如果下一轮想用系统工具而不是继续加日志

Linux 上优先级建议：
1. `perf sched timehist`
2. off-CPU flame graph（如 `offcputime`）
3. on-CPU flame graph

原因：
- 当前问题更像 latency / off-CPU，而不是纯 CPU hotspot

## 当前不建议的结论

以下结论目前证据不足，不建议直接下：
- “就是 `dictScanDefrag()` 算法有 bug”
- “就是 rehash 扩展循环导致”
- “就是 hash field callback 导致”
- “把 budget 改成按 CPU time 计算即可解决”

最后这一条尤其不建议：
- 测试关注的是 wall-clock latency
- 即使 CPU time 小，wall-clock 大仍然会真实影响 event loop

## 一句话总结

> 目前最可信的方向是：这是一个 active defrag 的 wall-clock latency spike 问题，
> 当前证据更支持 off-CPU / 调度型放大，而不是 rehash、bucket 长度或纯 CPU 热点。
