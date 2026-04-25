# `Interactive CLI: should be ok if there is no result` 偶发失败分析

## 失败现象

CI job: `test-sanitizer-address`

```
[err]: Interactive CLI: should be ok if there is no result in tests/integration/redis-cli.tcl
Expected '1' to be equal to '0'
(context: type eval line 10 cmd
 {assert_equal 1 [regexp {.*(empty array).*} $result2]} proc ::test)
```

测试位置：`tests/integration/redis-cli.tcl` 第 186–196 行。

```tcl
test_interactive_cli_with_prompt "should be ok if there is no result" {
    puts $fd "\x12" ;# CTRL+R
    set now [clock seconds]
    puts $fd "\x12" ;# CTRL+R
    set result [read_cli $fd]
    assert_equal 1 [regexp {\(reverse-i-search\):} $result]   ;# 通过

    set result2 [run_command $fd "keys \"$now\"\x0D"]
    assert_equal 1 [regexp {.*(empty array).*} $result2]      ;# ← 失败
}
```

第 192 行通过，证明 reverse‑i‑search 模式正确进入；
失败的是 195 行：`result2` 中没有 `(empty array)` 字样。

## 根因

测试辅助函数 `read_cli` 用的是"50 ms 静默期"启发式来判定输出读完了：

```tcl
proc read_cli {fd} {
    set ret [read $fd]
    while {[string length $ret] == 0} { after 10; set ret [read $fd] }
    set empty_reads 0
    while {$empty_reads < 5} {        ;# 连续 5 × 10ms = 50ms 没新数据就返回
        set buf [read $fd]
        if {[string length $buf] == 0} { after 10; incr empty_reads }
        else { append ret $buf; set empty_reads 0 }
    }
    return $ret
}
```

而本测试的 `run_command "keys \"$now\"\x0D"` 是在 reverse‑i‑search 模式下执行的，
linenoise 在该模式下每收到一个字符都会触发 `refreshLine` → `refreshSearchResult`，
持续向 stdout 输出 ANSI 重绘序列。等到处理 `\r` (ENTER)：

1. linenoise 再做一次 `refreshLine` + `disableReverseSearchMode`（仍是本地 stdout 输出）；
2. 退出 `linenoiseEdit` 把 `keys "<ts>"` 返回给 redis‑cli；
3. redis‑cli 才把 KEYS 发给服务端，等服务端回包；
4. 收到空数组后，redis‑cli 才会打印 `(empty array)\n` 以及下一个 prompt。

时间线：

```
本地重绘输出 ───┐
              │  连续输出，read_cli 持续 reset empty_reads
ENTER 处理   ───┘
                   ↓ 进入 send→server→reply→print 的网络往返空档
                   ↓ 在 ASAN 下这段空档可能 > 50 ms
                   ↓ ── read_cli 在这里"静默期"耗尽提前返回 ──
(empty array) 才被 redis-cli 输出 ❌ 漏掉了
```

服务端日志佐证测试本身确实变慢：

```
19.874  Accepted 127.0.0.1:42544       (测试启动)
20.202  Client closed (age=1, tot-cmds=4)
```

单测耗时 ~328 ms，普通环境通常 50–100 ms。

### 为什么是偶发

- 普通 CI 服务端响应 << 50 ms，几乎踩不到这个窗口。
- `test-sanitizer-address` 下 redis‑server 和 redis‑cli 都被 ASAN 插桩，调度/系统调用/分配都明显变慢；这次"按完 ENTER → 收到 reply"是否超过 50 ms 取决于运行机的 CPU 抖动 → **偶发**。
- 紧邻的用例 `upon submitting search, (reverse-i-search) prompt should go away`（198 行）只断言"prompt 已恢复"，那个 prompt 是在发 KEYS 之前由 `disableReverseSearchMode`/`refreshLine` 直接输出的，不依赖网络往返，所以不容易踩到这个窗口。

## 修复方案

核心思路：**不要再用"静默期"作为输出读完的判据，改成读到"下一个 prompt"或服务端响应字样为止**。

### 方案 A（推荐，最小改动）：增强 `read_cli`，等到 prompt 再现

让 `run_command` 走一条更鲁棒的读取：读到回到普通 prompt（`127.0.0.1:port[db]> `）之前都不返回。

伪代码：

```tcl
proc read_until_prompt {fd {timeout_ms 5000}} {
    set ret ""
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    while {[clock milliseconds] < $deadline} {
        set buf [read $fd]
        if {[string length $buf] > 0} {
            append ret $buf
            if {[regexp {127\.0\.0\.1:[0-9]+(\[[0-9]+\])?>\s*$} $ret]} { return $ret }
        } else { after 10 }
    }
    return $ret
}
```

把 `run_command` 中的 `read_cli` 替换为 `read_until_prompt`（或在 `read_cli` 里加上"看到 prompt 立即返回"的快捷路径，并把超时拉到几秒）。

收益：

- 不再依赖墙钟静默；ASAN 慢化也不影响。
- 已有的"prompt 已恢复"类断言无需改动。

### 方案 B（简单但治标）：增大 `read_cli` 静默阈值

把 `while {$empty_reads < 5}` 改成 `< 50`（500 ms 静默）或者在 ASAN 环境下再放大。
能压低概率但治标不治本，单测时间也会被拉长。

### 方案 C：在断言前显式再 `read_cli` 一次兜底

```tcl
set result2 [run_command $fd "keys \"$now\"\x0D"]
if {![regexp {empty array} $result2]} {
    append result2 [read_cli $fd]      ;# 再多吸一次输出
}
assert_equal 1 [regexp {.*(empty array).*} $result2]
```

属于打补丁，不推荐做最终方案，可作为快速止血。

## 建议落地

1. 用 **方案 A** 把 `tests/integration/redis-cli.tcl` 里 `read_cli` / `run_command` 改造成"读到 prompt 为止 + 显式超时"。
2. 改完之后在本地以 `make test-sanitizer-address` 或对应 CI 配置反复跑该用例（建议 100+ 次）确认稳定。
3. 顺带审视同文件下其他基于 `read_cli` 的交互式用例（如 198、210、226 行起的几个），它们在 ASAN 下都有同类风险。

## 一句话结论

**不是 `(empty array)` 没产生，而是 `read_cli` 用 50 ms 静默期判断输出结束，在 ASAN 慢化下"按 ENTER → 收到服务端回包"的空档超过了 50 ms，导致 `read_cli` 在 `(empty array)` 输出之前就提前返回了。**
