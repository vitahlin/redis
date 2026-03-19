## Active defrag 低干扰分析计划

### 目标
- 重新开始分析 `tests/unit/meme2.tcl` 中的 `Active defrag main dictionary: standalone`
- 尽量减少日志、调度竞争、测试 harness 干扰
- 先确认问题是否在低干扰条件下仍稳定存在
- 再决定是继续加 instrumentation，还是转向系统级工具

### 非目标
- 本文档不试图直接给出根因结论
- 本文档不假设必须修改 `src/defrag.c`
- 本文档不建议先继续加高频日志

## 总体原则

### 原则 1：先验证“低干扰下是否仍失败”
如果低干扰条件下问题明显减弱或消失，优先怀疑：
- 测试环境竞争
- 调度噪声
- instrumentation 本身的放大效应

如果低干扰条件下仍稳定失败，再继续深入代码路径。

### 原则 2：优先观察 wall-clock，不要急着转成 CPU-time 思维
测试失败的是：
- `active-defrag-cycle` 的 wall-clock latency 超过阈值

因此：
- 即使 CPU time 很小，wall-clock 大也是真问题
- 不要用“CPU 没高，所以可以忽略”来结束分析

### 原则 3：避免高频同步日志
分析顺序应是：
1. 无/少日志 baseline
2. 低扰动日志
3. 系统级采样（perf / off-CPU）

不要反过来。

## 预备条件

### 环境要求
- Linux 环境
- 尽量空闲机器或空闲时段
- 跑测试期间不要并行编译、刷日志、开重负载程序

### 构建要求
- 使用正常构建即可开始 baseline
- 如需后续 perf 火焰图，再考虑 debug symbols / frame pointers

## Phase 0：建立干净起点

### 0.1 清理分析方式
- 不打开 `--verbose`
- 不打开 `--dump-logs`
- 不边跑边 `tail -f tests/tmp/server.*/stdout`
- 不先加更多 debug log

### 0.2 记录本轮基线信息
至少记录：
- 当前分支/commit
- 是否带自定义 instrumentation
- Linux CPU 亲和策略
- 是否空闲机

建议命令：

```bash
git rev-parse --short HEAD
uname -a
nproc
```

## Phase 1：低干扰 baseline 复现

### 1.1 推荐命令
优先给测试 4~6 个非 0 号核，不要只给 `0,1`：

```bash
taskset -c 2-7 ./runtest \
  --dont-clean --dont-pre-clean \
  --single unit/meme2 \
  --only "Active defrag main dictionary: standalone" \
  --loop --stop > /tmp/runtest.active-defrag.baseline.log 2>&1
```

### 1.2 为什么这样跑
- `taskset -c 0,1` 太容易把 harness / server / client 挤在两个核上
- 给 `2-7` 可以减少竞争，但仍保留可复现性
- `--stop --dont-clean --dont-pre-clean` 方便失败后保留现场

### 1.3 本阶段要回答的问题
- 低干扰条件下，是否仍会出现 `max_latency > 30`
- 失败频率是否明显下降
- latency 历史是否仍维持在 `13~18ms` 的高位区间

### 1.4 停止条件
若连续多轮都无法复现，则先不要继续加细粒度日志。
优先记录：
- 原先失败命令
- 低干扰命令
- 两者失败频率差异

## Phase 2：失败后只看最小必要信息

### 2.1 先看 Tcl 输出
确认三件事：
- `active-defrag-cycle` 最大值是多少
- 失败秒附近的 latency history 是什么样
- `command` latency 是否只是伴随信息

### 2.2 再看 server log
如果当前版本仍保留前一轮 `helper-loop` instrumentation，则只抓这类：

```bash
grep 'defrag-debug helper-loop\|defrag-debug helper-end' tests/tmp/server.*/stdout
```

只看慢样本：

```bash
grep 'defrag-debug helper-loop' tests/tmp/server.*/stdout \
  | grep -E 'loop=[1-9][0-9]{3,}us|overrun=[1-9]'
```

### 2.3 只记录这些字段
- `loop`
- `cpu`
- `overrun`
- `scan_elapsed`（如果该字段还在）
- `scan_rehash`
- `scan_entries`

不要一开始就扩大范围到所有 debug 字段。

## Phase 3：结果分桶

### 桶 A：问题在低干扰下明显缓解
表现：
- fail 频率明显下降
- `active-defrag-cycle` 常态值也下降

结论方向：
- 优先怀疑环境竞争或 instrumentation 放大
- 暂缓继续修改 `src/defrag.c`

### 桶 B：问题仍稳定存在，但 `cpu << loop`
表现：
- `loop` 大
- `cpu` 小
- 常见明显 overrun

结论方向：
- 继续按 off-CPU / wall-clock 放大方向分析
- 下一步优先系统级工具，而不是继续堆日志

### 桶 C：问题仍稳定存在，且 `cpu` 也明显升高
表现：
- `loop` 大
- `cpu` 也大

结论方向：
- 才值得重回代码热点分析
- 此时再考虑更细粒度 instrumentation

## Phase 4：只在必要时加最小 instrumentation

### 何时允许继续加日志
只有在以下条件同时满足时：
- baseline 低干扰下仍可稳定复现
- 仅靠现有字段无法区分慢点位置

### 下一优先级
如果继续加 instrumentation，建议顺序：
1. `scan_cpu`
2. `pre_scan_elapsed`
3. `post_scan_elapsed`

原因：
- 这三项能直接回答“慢在 scan 内还是 scan 外”
- 不要回到早期那种每轮多条日志的做法

### 明确禁止
- 不要重新打开每轮单独 `dict-scan` 打印
- 不要恢复 `dict-bucket` 高频日志
- 不要同时加多个高频日志点

## Phase 5：转向系统级验证

### 5.1 什么时候该用 perf
满足任一条件即可：
- 低干扰下仍稳定失败
- `cpu << loop` 特征仍明显
- 仅靠日志已无法再缩小范围

### 5.2 优先级
Linux 上推荐顺序：
1. `perf sched timehist`
2. off-CPU flame graph（如 `offcputime`）
3. on-CPU flame graph

### 5.3 为什么不是先上普通火焰图
因为当前问题更像：
- wall-clock latency
- off-CPU / deschedule

不是典型“CPU hotspot first”问题。

## 建议记录模板

每轮至少记录这些信息：
- 命令行
- 是否低干扰模式
- 是否保留 instrumentation
- 是否失败
- `active-defrag-cycle` max latency
- 失败时的 3~5 条代表性 `helper-loop` 慢样本

建议格式：

```text
Run ID:
Command:
Low-interference: yes/no
Instrumentation: none/minimal/custom
Result: pass/fail
Max active-defrag-cycle latency:
Representative helper-loop samples:
Notes:
```

## 什么时候停止继续深挖

### 应停止并回到更上层判断的情况
- 新日志没有带来新的区分能力
- 继续加日志明显改变失败形态
- 多轮尝试都在重复同一结论：`cpu << loop`

此时优先改方向，不要继续围绕同一批日志打转。

## 本轮重新分析的推荐起点

### 起点 A：完全不加新日志，先跑 baseline
这是默认推荐路径。

### 起点 B：若当前分支已保留 `helper-loop` 单行日志
可以先带着它跑一轮，但不要再新增其它高频日志。

## 一句话策略

> 先确认问题是否能在低干扰条件下稳定复现；若仍复现，再用最少的字段或系统级工具区分是 wall-clock / off-CPU 放大，还是代码真实 CPU 热点。
