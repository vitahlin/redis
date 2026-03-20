#!/bin/bash
# defrag_latency_test.sh
# 验证 jemalloc bg-thread 锁竞争对 active defrag 延迟的影响
# 用法: ./defrag_latency_test.sh [host] [port]

HOST=${1:-127.0.0.1}
PORT=${2:-6379}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/redis-cli -h $HOST -p $PORT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $1"; }

check_redis() {
    if ! $CLI ping > /dev/null 2>&1; then
        err "Redis not reachable at $HOST:$PORT"
        exit 1
    fi
    log "Redis connected: $HOST:$PORT"
}

setup_defrag_config() {
    log "Configuring defrag..."
    $CLI config set hz 100
    $CLI config set active-defrag-enabled no
    $CLI config set active-defrag-ignore-bytes 10mb
    $CLI config set active-defrag-threshold-lower 5
    $CLI config set active-defrag-threshold-upper 100
    $CLI config set active-defrag-cycle-min 65
    $CLI config set active-defrag-cycle-max 75
    $CLI config set latency-monitor-threshold 5
    $CLI latency reset
}

create_fragmentation() {
    local num_keys=${1:-300000}
    log "Writing $num_keys keys (this may take a while)..."

    # 用 awk 生成 RESP pipeline，避免 bash 循环 fork 子进程，速度快且可移植
    awk -v n="$num_keys" 'BEGIN {
        sizes[0] = 16; sizes[1] = 32; sizes[2] = 64
        for (i = 1; i <= n; i++) {
            sz = sizes[(i - 1) % 3]
            val = ""
            for (j = 0; j < sz; j++) val = val "x"
            key = sprintf("key:%012d", i)
            printf "*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", \
                length(key), key, sz, val
        }
    }' | $CLI --pipe 2>/dev/null

    log "Done writing. Now deleting half to create fragmentation..."

    # 删除奇数 key，制造碎片
    $CLI eval "
        local deleted = 0
        for i = 1, $num_keys, 2 do
            redis.call('del', 'key:' .. string.format('%012d', i))
            deleted = deleted + 1
        end
        return deleted
    " 0

    local frag=$($CLI info memory | grep mem_allocator_frag_ratio | awk -F: '{print $2}' | tr -d '\r')
    log "Fragmentation ratio: ${frag}"
}

monitor_latency() {
    local duration=${1:-30}
    local label=${2:-""}
    local max_lat=0
    local count=0
    local end_time=$(( $(date +%s) + duration ))

    warn "Monitoring for ${duration}s [${label}]..."

    while [ $(date +%s) -lt $end_time ]; do
        local lat=$($CLI latency latest 2>/dev/null | grep "active-defrag-cycle" | awk '{print $4}')
        if [ -n "$lat" ] && [ "$lat" -gt 0 ] 2>/dev/null; then
            if [ "$lat" -gt "$max_lat" ]; then
                max_lat=$lat
            fi
            count=$((count + 1))
        fi

        local frag=$($CLI info memory | grep mem_allocator_frag_ratio | awk -F: '{print $2}' | tr -d '\r')
        printf "\r  frag=%-6s  max_latency=%-6s ms  samples=%-4d" "$frag" "$max_lat" "$count"
        sleep 1
    done
    echo ""
    echo "$max_lat"
}

run_test() {
    local bg_thread=$1
    local label=$2

    log "=== Test: $label ==="
    $CLI config set jemalloc-bg-thread $bg_thread
    $CLI latency reset
    $CLI config set active-defrag-enabled yes

    local max_lat=$(monitor_latency 30 "$label")

    $CLI config set active-defrag-enabled no
    $CLI latency reset

    echo "$max_lat"
}

print_result() {
    local max_with=$1
    local max_without=$2

    echo ""
    log "========== 结果对比 =========="
    echo "  jemalloc-bg-thread yes: max_latency = ${max_with} ms"
    echo "  jemalloc-bg-thread no:  max_latency = ${max_without} ms"

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
create_fragmentation 300000

log "Step 2: bg-thread ON 测试"
max_with=$(run_test yes "bg-thread ON")

log "Step 3: 重置碎片"
$CLI flushall
create_fragmentation 300000

log "Step 4: bg-thread OFF 测试"
max_without=$(run_test no "bg-thread OFF")

print_result "$max_with" "$max_without"

