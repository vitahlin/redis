# Ubuntu 上直接用 Sentinel 复现 `EPOLLERR -> recv(EAGAIN)` busy-loop

这份文档给出一套 **直接使用 Redis Sentinel** 的手工复现方案，用来验证 `docs/sentinel.md` 中描述的 issue #9956：

- Sentinel 监控的 Redis master 所在连接挂上异步错误（`SO_ERROR`）
- `epoll` 持续返回 `EPOLLERR`
- `recv()` 却返回 `EAGAIN`
- 修复前 hiredis 不消费 `SO_ERROR`，导致事件循环 busy-loop，Sentinel 单核 CPU 接近 100%

和 `docs/hiredis-async-epollerr-reproducer.md` 相比，这份文档更接近真实业务场景，因为它直接运行的是 **Sentinel 进程**。

---

## 1. 适用范围

建议环境：

- 原生 Ubuntu 22.04 / 24.04
- root 权限
- 原生 Linux 内核网络栈

不建议一开始就在 OrbStack / Docker Desktop / WSL2 上验证，因为这种 bug 非常依赖：

- `iptables REJECT`
- `ICMP port-unreachable`
- `SO_ERROR`
- `epoll`

这些行为在额外虚拟化网络层下可能和原生 Linux 不一致。

---

## 2. 方案思路

拓扑尽量简单：

- root namespace：运行 `redis-sentinel`
- `srv` namespace：运行一个被 Sentinel 监控的 `redis-server`（master）

然后：

1. 等 Sentinel 与 master 建立连接
2. 找到 **Sentinel -> master** 这条 TCP 连接的本地 `sport`
3. 用 `iptables -I OUTPUT ... --sport <sport> -j REJECT --reject-with icmp-port-unreachable` 只毒化这一条现有连接
4. 观察 Sentinel：
   - 修复前：CPU 高、`strace` 出现 `epoll_wait + recv(EAGAIN)` 高频循环
   - 修复后：很快断链重连，CPU 不再持续升高

---

## 3. 先安装依赖

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  iproute2 \
  iptables \
  strace \
  sysstat
```

---

## 4. 构建 Redis（建议用 libc allocator）

在仓库根目录执行：

```bash
cd /path/to/redis
make distclean
make MALLOC=libc
```

这样后续：

- `./src/redis-server`
- `./src/redis-cli`
- `./src/redis-sentinel`

都会处于同一套构建产物下，便于你做“修复前 / 修复后”的直接对比。

---

## 5. 创建最小网络拓扑

下面命令会创建：

- root namespace：`veth0` = `10.200.1.1/24`
- `srv` namespace：`veth1` = `10.200.1.2/24`

```bash
sudo ip netns add srv

sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns srv

sudo ip addr add 10.200.1.1/24 dev veth0
sudo ip link set veth0 up

sudo ip netns exec srv ip link set lo up
sudo ip netns exec srv ip addr add 10.200.1.2/24 dev veth1
sudo ip netns exec srv ip link set veth1 up
```

确认网络通：

```bash
ping -c 2 10.200.1.2
sudo ip netns exec srv ping -c 2 10.200.1.1
```

---

## 6. 启动被监控的 master

这一步只起一个 Redis master，不起 replica。这样可以把实验焦点锁定在 **Sentinel 到 master 的监控连接** 上，避免 failover 拓扑带来的额外变量。

```bash
cd /path/to/redis

sudo ip netns exec srv ./src/redis-server \
  --bind 10.200.1.2 \
  --port 6379 \
  --protected-mode no \
  --save '' \
  --appendonly no \
  --daemonize yes \
  --pidfile /tmp/redis-9956-master.pid \
  --logfile /tmp/redis-9956-master.log
```

确认 master 正常：

```bash
sudo ip netns exec srv ./src/redis-cli -h 10.200.1.2 -p 6379 ping
```

期望输出：

```text
PONG
```

---

## 7. 准备 Sentinel 目录和配置文件

Sentinel 会重写自己的配置文件，所以一定要给它一个可写目录和一份专用配置。

```bash
mkdir -p /tmp/redis-9956-sentinel
cat >/tmp/redis-9956-sentinel/sentinel.conf <<'EOF'
port 26379
bind 127.0.0.1
protected-mode no
daemonize yes
pidfile /tmp/redis-9956-sentinel/sentinel.pid
logfile /tmp/redis-9956-sentinel/sentinel.log
dir /tmp/redis-9956-sentinel

sentinel monitor mymaster 10.200.1.2 6379 1

# 这里刻意把 down-after 调大，避免 Sentinel 自己太快触发
# “低活跃连接重连”逻辑，把你想观察的 busy-loop 现象冲淡。
sentinel down-after-milliseconds mymaster 60000
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1
EOF
```

### 为什么这里不用测试框架里的 2000ms

仓库里的 Sentinel 测试初始化脚本会把：

- `down-after-milliseconds` 调成 `2000`

这对回归测试是有利的，但对“手工复现老 bug”反而可能不利，因为 Sentinel 自己可能很快就把坏连接关掉了。这里把它拉大到 `60000`，是为了给病态 socket 更多存活时间，让 busy-loop 更容易暴露。

---

## 8. 启动 Sentinel

```bash
cd /path/to/redis

./src/redis-sentinel /tmp/redis-9956-sentinel/sentinel.conf
```

确认 Sentinel 已起来：

```bash
./src/redis-cli -p 26379 ping
./src/redis-cli -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster
```

建议再把 ping 周期调小一点，让异常更快打到读路径：

```bash
./src/redis-cli -p 26379 SENTINEL DEBUG ping-period 100
```

你也可以看日志确认监控已建立：

```bash
tail -f /tmp/redis-9956-sentinel/sentinel.log
```

---

## 9. 记录 Sentinel PID 和目标连接的 source port

先拿到 Sentinel 的 pid，并从 Sentinel 自己的视图里读取当前 master 地址：

```bash
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
MASTER_IP=$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '1p')
MASTER_PORT=$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '2p')

echo "SENTINEL_PID=$SENTINEL_PID"
echo "MASTER_IP=$MASTER_IP"
echo "MASTER_PORT=$MASTER_PORT"
```

然后等待 Sentinel 到 master 的连接真正建立，并提取这条连接的本地 `sport`：

```bash
while true; do
  SENTINEL_SPORT=$(sudo ss -tanp | awk \
    -v pid="$SENTINEL_PID" \
    -v dst="$MASTER_IP:$MASTER_PORT" '
      $1 == "ESTAB" && $5 == dst && $0 ~ ("pid=" pid ",") {
        n = split($4, a, ":");
        print a[n];
        exit;
      }')

  if [ -n "$SENTINEL_SPORT" ]; then
    break
  fi
  sleep 0.1
done

echo "SENTINEL_SPORT=$SENTINEL_SPORT"
```

### 你应该看到什么

这说明当前机器上已经存在一条：

- 本地进程：Sentinel
- 远端：当前 `mymaster` 指向的地址
- 本地临时端口：`$SENTINEL_SPORT`

后面注入规则时，我们只毒化这一条 flow。

---

## 10. 先看注入前的 baseline

### 看 CPU

```bash
pidstat -p "$(cat /tmp/redis-9956-sentinel/sentinel.pid)" 1
```

空闲 Sentinel 一般应该处于很低 CPU。

### 看系统调用

另开一个终端：

```bash
sudo strace -tt -p "$(cat /tmp/redis-9956-sentinel/sentinel.pid)" \
  -e trace=epoll_wait,epoll_pwait,recv,recvfrom,getsockopt
```

注入前你通常只会看到零星的 `epoll_wait`、`recv`、`send`，不会有持续高频刷屏。

---

## 11. 注入 `ICMP port-unreachable`

现在只对这条 Sentinel 现有连接动刀：

```bash
MASTER_IP=$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | awk 'NR==1{gsub(/\r/, ""); print; exit}')
MASTER_PORT=$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | awk 'NR==2{gsub(/\r/, ""); print; exit}')
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
while true; do
  SENTINEL_SPORT=$(sudo ss -tanp | awk -v pid="$SENTINEL_PID" -v dst="$MASTER_IP:$MASTER_PORT" '$1=="ESTAB" && $5==dst && $0~("pid=" pid ","){n=split($4,a,":"); print a[n]; exit}')
  [ -n "$SENTINEL_SPORT" ] && break
  sleep 0.1
done
SENTINEL_SPORT=$(printf '%s' "$SENTINEL_SPORT" | tr -d '\r')

printf 'MASTER_IP=[%s]\nMASTER_PORT=[%s]\nSENTINEL_PID=[%s]\nSENTINEL_SPORT=[%s]\n' \
  "$MASTER_IP" "$MASTER_PORT" "$SENTINEL_PID" "$SENTINEL_SPORT"

sudo iptables -I OUTPUT \
  -p tcp \
  -d "$MASTER_IP" \
  --dport "$MASTER_PORT" \
  --sport "$SENTINEL_SPORT" \
  -j REJECT --reject-with icmp-port-unreachable
```

确认规则存在：

```bash
sudo iptables -L OUTPUT -n --line-numbers
```

然后等待 3~5 秒：

```bash
sleep 5
```

### 为什么用 `--sport`

这和现有回归测试 `tests/sentinel/tests/16-busy-loop-on-epollerr.tcl` 的思路一致：

- 只毒化 **当前这条旧连接**
- 如果修复正确，Sentinel 会断开旧 socket 并用新 `sport` 重连
- 新连接不会再命中这条规则

---

## 12. 预期现象：修复前（buggy hiredis）

### 1) `pidstat`

你应该能看到 Sentinel 单核 CPU 明显升高，典型现象是：

- 持续很高
- 接近 100%

### 2) `strace`

应该能观察到非常密集的循环，类似：

```text
epoll_pwait(...) = 1
recvfrom(fd, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
epoll_pwait(...) = 1
recvfrom(fd, ..., 16384, 0, ...) = -1 EAGAIN (Resource temporarily unavailable)
```

这就是 `docs/sentinel.md` 里分析的核心症状：

- `EPOLLERR` 持续存在
- hiredis 读路径读到 `EAGAIN`
- 却没有消费 `SO_ERROR`
- event loop 因此忙循环

### 3) Sentinel 日志

日志里可能会看到异常监控输出，但关键不是日志，而是：

- CPU 飙高
- `strace` 出现 `epoll_wait + recv(EAGAIN)` 高频模式

---

## 13. 预期现象：修复后

当你把 `docs/sentinel.md` 里 `getsockopt(SO_ERROR)` 的修复打进去、重新构建、再跑同样步骤后：

### 1) CPU

Sentinel 不应再持续维持高 CPU。

### 2) `strace`

你更容易观察到：

- `getsockopt(SO_ERROR)`
- 之后 Sentinel 断开旧连接
- 然后恢复到正常等待 / 重连节奏

### 3) 连接会换新 `sport`

你可以再执行一次：

```bash
sudo ss -tanp | awk \
  -v pid="$(cat /tmp/redis-9956-sentinel/sentinel.pid)" \
  -v dst="$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | paste -sd: -)" '
    $1 == "ESTAB" && $5 == dst && $0 ~ ("pid=" pid ",") { print }'
```

修复后的常见现象是：

- 旧 `sport` 不见了
- 又出现一条新的 ESTAB 连接
- 新的本地临时端口不同于旧 `SENTINEL_SPORT`

这说明 Sentinel 已经释放死连接并完成自愈。

---

## 14. 如果修复前卡死了，怎么人工恢复

文档里分析过，`SENTINEL RESET` 会把死连接摘掉，所以可以作为恢复手段：

```bash
./src/redis-cli -p 26379 SENTINEL RESET mymaster
```

通常这会让：

- busy-loop 停下来
- CPU 恢复正常
- Sentinel 重新发现并重建连接

如果你只是想验证“老 bug 是否存在”，这一招很适合在观察完现象后收尾。

---

## 15. 做完实验后清理环境

### 1) 删掉 `iptables` 规则

先列出规则：

```bash
sudo iptables -L OUTPUT -n --line-numbers
```

找到命中 `10.200.1.2:6379` 且 `spt=$SENTINEL_SPORT` 的那条规则，然后删除：

```bash
sudo iptables -D OUTPUT <line-number>
```

### 2) 停掉 Sentinel

```bash
kill "$(cat /tmp/redis-9956-sentinel/sentinel.pid)"
```

### 3) 停掉 master

```bash
sudo ip netns exec srv pkill -f 'redis-server.*10.200.1.2'
```

### 4) 删除 namespace 和 veth

```bash
sudo ip link del veth0 || true
sudo ip netns del srv || true
```

### 5) 删除临时目录（可选）

```bash
rm -rf /tmp/redis-9956-sentinel
rm -f /tmp/redis-9956-master.pid /tmp/redis-9956-master.log
```

---

## 16. 如果没有复现出高 CPU，优先检查这些点

### 1) 你是不是在原生 Ubuntu 上跑

先排除：

- OrbStack
- Docker Desktop
- WSL2

这些环境可能打不到文档里那条精确内核路径。

### 2) 规则是不是只命中了旧连接

本方案故意使用：

- `--sport $SENTINEL_SPORT`

如果你把规则写宽了，比如只写 `--dport 6379`，那修复后的新连接也可能一起被毒化，结果就会变得难解释。

### 3) `down-after-milliseconds` 是否太小

如果你把它设回 `2000` 之类的小值，Sentinel 可能会因为自己的“慢连接回收逻辑”太快介入，导致你来不及观察到稳定的 busy-loop。

### 4) `ping-period` 是否太大

本方案建议：

```bash
./src/redis-cli -p 26379 SENTINEL DEBUG ping-period 100
```

这样更容易在短时间内触发到出问题的读路径。

### 5) 修复前 / 修复后是不是在同一台机器上比较

最佳做法是：

- 同一台 Ubuntu 主机
- 同一套 namespace 拓扑
- 同样的注入规则
- 只替换 `deps/hiredis/net.c` 的修复逻辑

否则很容易把环境差异误认为代码差异。

---

## 17. 这个文档和现有回归测试的关系

仓库里已经有一个回归测试：

- `tests/sentinel/tests/16-busy-loop-on-epollerr.tcl`

它的核心思路和本文一致：

- 找到 Sentinel 到 master 的旧连接
- 只毒化这一条 flow
- 看是否出现 busy-loop

但测试框架中的环境参数更偏向“自动化回归检查”，而这份文档更偏向“手工复现 / 人工观察 / 调试定位”。

尤其是这里刻意把：

- `down-after-milliseconds`

调大到 `60000`，就是为了减少 Sentinel 自己的自愈逻辑对复现窗口的干扰。

---

## 18. 推荐的验证顺序

建议你按下面顺序做：

1. 用当前未修复代码按本文跑一遍
2. 记录：
   - `pidstat`
   - `strace`
   - Sentinel 日志
3. 打入 `docs/sentinel.md` 里的修复
4. `make distclean && make MALLOC=libc`
5. 用同样步骤再跑一次
6. 对比：
   - 修复前：高 CPU + `recv(EAGAIN)` 高频循环
   - 修复后：断链重连、CPU 恢复正常

如果这个对比成立，就基本能从 Sentinel 实际运行层面证明修复是有效的。

---

## 19. 复制即用：一套 end-to-end 命令清单

如果你想最少切换上下文，可以直接按下面顺序执行。假设仓库根目录是：

```bash
export REDIS_ROOT=/path/to/redis
cd "$REDIS_ROOT"
```

### 1) 构建

```bash
make distclean
make MALLOC=libc
```

### 2) 清理旧环境（可重复执行）

```bash
sudo iptables -L OUTPUT -n --line-numbers || true
kill "$(cat /tmp/redis-9956-sentinel/sentinel.pid 2>/dev/null)" 2>/dev/null || true
sudo ip netns exec srv pkill -f 'redis-server.*10.200.1.2' 2>/dev/null || true
sudo ip link del veth0 2>/dev/null || true
sudo ip netns del srv 2>/dev/null || true
rm -rf /tmp/redis-9956-sentinel
rm -f /tmp/redis-9956-master.pid /tmp/redis-9956-master.log
```

### 3) 建网络

```bash
sudo ip netns add srv
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns srv
sudo ip addr add 10.200.1.1/24 dev veth0
sudo ip link set veth0 up
sudo ip netns exec srv ip link set lo up
sudo ip netns exec srv ip addr add 10.200.1.2/24 dev veth1
sudo ip netns exec srv ip link set veth1 up
```

### 4) 起 master

```bash
sudo ip netns exec srv "$REDIS_ROOT"/src/redis-server \
  --bind 10.200.1.2 \
  --port 6379 \
  --protected-mode no \
  --save '' \
  --appendonly no \
  --daemonize yes \
  --pidfile /tmp/redis-9956-master.pid \
  --logfile /tmp/redis-9956-master.log

sudo ip netns exec srv "$REDIS_ROOT"/src/redis-cli -h 10.200.1.2 -p 6379 ping
```

### 5) 写 sentinel 配置并启动

```bash
mkdir -p /tmp/redis-9956-sentinel
cat >/tmp/redis-9956-sentinel/sentinel.conf <<'EOF'
port 26379
bind 127.0.0.1
protected-mode no
daemonize yes
pidfile /tmp/redis-9956-sentinel/sentinel.pid
logfile /tmp/redis-9956-sentinel/sentinel.log
dir /tmp/redis-9956-sentinel
sentinel monitor mymaster 10.200.1.2 6379 1
sentinel down-after-milliseconds mymaster 60000
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1
EOF

"$REDIS_ROOT"/src/redis-sentinel /tmp/redis-9956-sentinel/sentinel.conf
"$REDIS_ROOT"/src/redis-cli -p 26379 ping
"$REDIS_ROOT"/src/redis-cli -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster
"$REDIS_ROOT"/src/redis-cli -p 26379 SENTINEL DEBUG ping-period 100
```

### 6) 拿 pid 和旧连接 sport

```bash
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
MASTER_IP=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '1p')
MASTER_PORT=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '2p')

while true; do
  SENTINEL_SPORT=$(sudo ss -tanp | awk \
    -v pid="$SENTINEL_PID" \
    -v dst="$MASTER_IP:$MASTER_PORT" '
      $1 == "ESTAB" && $5 == dst && $0 ~ ("pid=" pid ",") {
        n = split($4, a, ":"); print a[n]; exit;
      }')
  [ -n "$SENTINEL_SPORT" ] && break
  sleep 0.1
done

echo "SENTINEL_PID=$SENTINEL_PID"
echo "SENTINEL_SPORT=$SENTINEL_SPORT"
```

### 7) 注入故障

```bash
MASTER_IP=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | awk 'NR==1{gsub(/\r/, ""); print; exit}')
MASTER_PORT=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | awk 'NR==2{gsub(/\r/, ""); print; exit}')
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
while true; do
  SENTINEL_SPORT=$(sudo ss -tanp | awk -v pid="$SENTINEL_PID" -v dst="$MASTER_IP:$MASTER_PORT" '$1=="ESTAB" && $5==dst && $0~("pid=" pid ","){n=split($4,a,":"); print a[n]; exit}')
  [ -n "$SENTINEL_SPORT" ] && break
  sleep 0.1
done
SENTINEL_SPORT=$(printf '%s' "$SENTINEL_SPORT" | tr -d '\r')

printf 'MASTER_IP=[%s]\nMASTER_PORT=[%s]\nSENTINEL_PID=[%s]\nSENTINEL_SPORT=[%s]\n' \
  "$MASTER_IP" "$MASTER_PORT" "$SENTINEL_PID" "$SENTINEL_SPORT"

sudo iptables -I OUTPUT \
  -p tcp \
  -d "$MASTER_IP" \
  --dport "$MASTER_PORT" \
  --sport "$SENTINEL_SPORT" \
  -j REJECT --reject-with icmp-port-unreachable

sleep 5
```

### 8) 观察

```bash
pidstat -p "$(cat /tmp/redis-9956-sentinel/sentinel.pid)" 1
```

另开终端：

```bash
sudo strace -tt -p "$(cat /tmp/redis-9956-sentinel/sentinel.pid)" \
  -e trace=epoll_wait,epoll_pwait,recv,recvfrom,getsockopt
```

### 9) 恢复/清理

```bash
"$REDIS_ROOT"/src/redis-cli -p 26379 SENTINEL RESET mymaster || true
sudo iptables -L OUTPUT -n --line-numbers
kill "$(cat /tmp/redis-9956-sentinel/sentinel.pid)" 2>/dev/null || true
sudo ip netns exec srv pkill -f 'redis-server.*10.200.1.2' 2>/dev/null || true
sudo ip link del veth0 2>/dev/null || true
sudo ip netns del srv 2>/dev/null || true
```

---

## 20. 补充观测命令

除了 `pidstat` 和 `strace`，下面这些命令也很有帮助。

### 1) 查看 Sentinel 对 master 的视图

```bash
./src/redis-cli -p 26379 SENTINEL MASTER mymaster
./src/redis-cli -p 26379 INFO sentinel
```

可以重点看：

- `flags`
- `last-ok-ping-reply`
- `last-ping-reply`
- `s-down-time`

### 2) 从 master 侧看 Sentinel 客户端

```bash
sudo ip netns exec srv ./src/redis-cli \
  -h "$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '1p')" \
  -p "$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '2p')" \
  CLIENT LIST
```

你通常能看到 Sentinel 的连接，注入前后可以对比：

- 旧连接是否还在
- 是否出现了新的源端口

### 3) 只过滤和 Sentinel 相关的 master 端客户端

```bash
sudo ip netns exec srv ./src/redis-cli \
  -h "$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '1p')" \
  -p "$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | sed -n '2p')" \
  CLIENT LIST | \
  grep -E 'cmd=(ping|info|publish)|name=sentinel'
```

### 4) 快速确认新旧 `sport` 是否切换

```bash
sudo ss -tanp | awk \
  -v pid="$(cat /tmp/redis-9956-sentinel/sentinel.pid)" \
  -v dst="$(./src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster | paste -sd: -)" '
    $1 == "ESTAB" && $5 == dst && $0 ~ ("pid=" pid ",") { print $0 }'
```

修复后更常见的是：

- 旧 `SENTINEL_SPORT` 不再出现
- 出现一个新的本地临时端口

### 5) 直接盯日志里的异常事件

```bash
tail -f /tmp/redis-9956-sentinel/sentinel.log | \
  grep -E --line-buffered 'sdown|odown|tilt|reset|reconnect|monitor'
```

### 6) 如果 `redis-sentinel` 不存在，使用兼容启动方式

某些环境里你可能更习惯用：

```bash
./src/redis-server /tmp/redis-9956-sentinel/sentinel.conf --sentinel
```

它和 `./src/redis-sentinel /tmp/redis-9956-sentinel/sentinel.conf` 的目标是一致的；二选一即可。