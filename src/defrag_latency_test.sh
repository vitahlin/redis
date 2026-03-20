#!/bin/bash
# defrag_latency_test.sh
# 验证 jemalloc bg-thread 锁竞争对 active defrag 延迟的影响
# 用法: ./defrag_latency_test.sh [host] [port]

HOST=${1:-127.0.0.1}
PORT=${2:-6379}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/redis-cli -h $HOST -p $PORT"

# 全部输出到 stderr，避免被 $() 捕获污染返回值
log()  { printf "[%s] %s\n"       "$(date '+%H:%M:%S')" "$1" >&2; }
warn() { printf "[%s] WARN: %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
err()  { printf "[%s] ERR:  %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }

check_redis() {
    if ! $CLI ping > /dev/null 2>&1; then
        err "Redis not reachable at $HOST:$PORT"
        exit 1
    fi
    log "Redis connected: $HOST:$PORT"

    # 检查是否支持 active defrag（需要 jemalloc 编译）
    local defrag_err
    defrag_err=$($CLI config set activedefrag no 2>&1)
    if echo "$defrag_err" | grep -q "ERR\|error"; then
        err "This Redis does not support active defrag."
        err "Please recompile with: make MALLOC=jemalloc"
        err "Or use the default make (jemalloc is the default allocator)"
        exit 1
    fi
    log "Active defrag supported: OK"
}

setup_defrag_config() {
    log "Configuring defrag..."
    $CLI config set hz 100
    $CLI config set activedefrag no
    # 设为 100kb，确保小数据集也能触发 defrag
    # 默认 100mb 远超测试数据量（~7MB），会导致 defrag 永不启动
    $CLI config set active-defrag-ignore-bytes 100kb
    # 碎片率 > 1%（frag ratio > 1.01）即触发，确保测试可以触发
    $CLI config set active-defrag-threshold-lower 1
    $CLI config set active-defrag-threshold-upper 100
    $CLI config set active-defrag-cycle-min 65
    $CLI config set active-defrag-cycle-max 75
    # 设为 1ms，捕获所有 defrag 调用样本（默认 0 表示不记录）
    $CLI config set latency-monitor-threshold 1
    $CLI config set latency-tracking yes
    $CLI latency reset
}

create_fragmentation() {
    local num_keys=${1:-2000000}
    log "Writing $num_keys keys (16G RAM, large dataset)..."

    # 混合 8 种不同大小，覆盖 jemalloc 多个 size class，加剧跨 bin 碎片
    # 总数据量约：2M × avg 96 bytes ≈ 192MB，删一半后 ~96MB 碎片
    awk -v n="$num_keys" 'BEGIN {
        sizes[0] = 32;  sizes[1] = 48;  sizes[2] = 64;  sizes[3] = 80
        sizes[4] = 96;  sizes[5] = 128; sizes[6] = 160; sizes[7] = 256
        for (i = 1; i <= n; i++) {
            sz = sizes[(i - 1) % 8]
            val = ""
            for (j = 0; j < sz; j++) val = val "x"
            key = sprintf("key:%012d", i)
            printf "*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", \
                length(key), key, sz, val
        }
    }' | $CLI --pipe 2>/dev/null

    log "Done writing. Now deleting half to create fragmentation..."

    # 删除策略：每 3 个 key 删除 2 个，保留 1 个
    # 比"删一半"更碎片化（大量小块空洞散布在 arena 各处）
    $CLI eval "
        local deleted = 0
        for i = 1, $num_keys do
            if i % 3 ~= 0 then
                redis.call('del', 'key:' .. string.format('%012d', i))
                deleted = deleted + 1
            end
        end
        return deleted
    " 0

    local frag=$($CLI info memory | grep allocator_frag_ratio | awk -F: '{print $2}' | tr -d '\r\n ')
    log "Fragmentation ratio: ${frag}"
}

# 等待 defrag 完成：连续 3 秒 hits 不再增加视为完成
wait_defrag_complete() {
    local timeout=${1:-180}
    local label=${2:-""}
    local prev_hits=0
    local stable=0
    local start
    start=$(date +%s)

    warn "Waiting for defrag to complete [${label}] (timeout=${timeout}s)..."

    while true; do
        local hits frag
        hits=$($CLI info stats 2>/dev/null | grep "^active_defrag_hits" | awk -F: '{print $2}' | tr -d '\r\n ')
        frag=$($CLI info memory 2>/dev/null | grep allocator_frag_ratio | awk -F: '{print $2}' | tr -d '\r\n ')
        hits=${hits:-0}

        printf "[%s] frag=%-6s defrag_hits=%-10s stable_secs=%d\n" \
            "$(date '+%H:%M:%S')" "${frag:-?}" "$hits" "$stable" >&2

        if [ "$hits" = "$prev_hits" ]; then
            stable=$((stable + 1))
            if [ $stable -ge 3 ]; then
                log "Defrag completed. hits=$hits frag=${frag}"
                break
            fi
        else
            stable=0
        fi
        prev_hits=$hits

        if [ $(( $(date +%s) - start )) -gt $timeout ]; then
            warn "Timeout ${timeout}s reached"
            break
        fi
        sleep 1
    done
}

run_test() {
    local bg_thread=$1
    local label=$2

    log "=== Test: $label ==="
    $CLI config set jemalloc-bg-thread $bg_thread
    $CLI latency reset
    $CLI config set activedefrag yes

    # 等 defrag 自然跑完，而不是固定时间窗口
    wait_defrag_complete 180 "$label"

    $CLI config set activedefrag no

    # --raw 模式下 latency history 每两行一组：第1行=timestamp，第2行=latency_ms
    # 非 raw 模式输出带 "(integer)" 前缀，awk 解析为 0
    local raw_history max_lat sample_count
    raw_history=$($CLI --raw latency history active-defrag-cycle 2>/dev/null)

    # 打印前5行供调试
    log "$label latency history (first 5 lines): $(echo "$raw_history" | head -5 | tr '\n' ' ')"

    # 偶数行（第2、4、6...行）是 latency 值
    max_lat=$(echo "$raw_history" | awk 'NR%2==0 && $1+0>max {max=$1+0} END{print max+0}')
    sample_count=$(echo "$raw_history" | wc -l | tr -d ' ')
    sample_count=$(( sample_count / 2 ))
    max_lat=${max_lat:-0}

    log "$label: sample_count=${sample_count} max_latency=${max_lat}ms"

    $CLI latency reset
    echo "$max_lat"
}

print_result() {
    local max_with=$1
    local max_without=$2

    printf "\n" >&2
    log "========== 结果对比 =========="
    printf "  jemalloc-bg-thread yes: max_latency = %s ms\n" "$max_with"
    printf "  jemalloc-bg-thread no:  max_latency = %s ms\n" "$max_without"

    if [ "$max_with" -gt "$max_without" ] 2>/dev/null; then
        warn "bg-thread ON 延迟更高 → 锁竞争是主要原因"
    elif [ "$max_with" -eq "$max_without" ] 2>/dev/null; then
        warn "两者延迟相同 → 锁竞争不是主因，OS调度或sync purge是根本原因"
    else
        warn "bg-thread OFF 延迟更高 → 同步 purge（epoch advance）是主因"
    fi

    if [ "$max_with" -gt 30 ] 2>/dev/null; then
        err "bg-thread ON 时 max_latency=${max_with}ms > 30ms → 生产环境存在延迟风险!"
    fi
}

# ========== main ==========
check_redis
setup_defrag_config

log "Step 1: 清空并制造碎片"
$CLI flushall
create_fragmentation 2000000

log "Step 2: bg-thread ON 测试"
max_with=$(run_test yes "bg-thread ON")

log "Step 3: 重置碎片"
$CLI flushall
create_fragmentation 2000000

log "Step 4: bg-thread OFF 测试"
max_without=$(run_test no "bg-thread OFF")

print_result "$max_with" "$max_without"

