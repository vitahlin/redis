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
$ ping -c 2 10.200.1.2
PING 10.200.1.2 (10.200.1.2) 56(84) bytes of data.
64 bytes from 10.200.1.2: icmp_seq=1 ttl=64 time=0.404 ms
64 bytes from 10.200.1.2: icmp_seq=2 ttl=64 time=0.045 ms

--- 10.200.1.2 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1030ms
rtt min/avg/max/mdev = 0.045/0.224/0.404/0.179 ms

$ sudo ip netns exec srv ping -c 2 10.200.1.1
PING 10.200.1.1 (10.200.1.1) 56(84) bytes of data.
64 bytes from 10.200.1.1: icmp_seq=1 ttl=64 time=0.016 ms
64 bytes from 10.200.1.1: icmp_seq=2 ttl=64 time=0.043 ms

--- 10.200.1.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1018ms
rtt min/avg/max/mdev = 0.016/0.029/0.043/0.013 ms
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
$ sudo ip netns exec srv ./src/redis-cli -h 10.200.1.2 -p 6379 ping
PONG
```

期望输出：

```text
PONG
```

---

## 7. 准备 Sentinel 目录和配置文件

Sentinel 会重写自己的配置文件，所以一定要给它一个可写目录和一份专用配置。

这份“调试版”文档默认采用：

- `daemonize no`
- 单独开一个终端让 Sentinel **前台运行**
- 在启动前由 shell 手动写入 `/tmp/redis-9956-sentinel/sentinel.pid`

这样做的好处是：

- 不会因为 daemonize/fork 搞乱 PID
- 新开终端时可以直接 `cat /tmp/redis-9956-sentinel/sentinel.pid`
- 更适合配合 `pidstat`、`ss`、`strace` 做调试

```bash
mkdir -p /tmp/redis-9956-sentinel
cat >/tmp/redis-9956-sentinel/sentinel.conf <<'EOF'
port 26379
bind 127.0.0.1
protected-mode no
daemonize no
# 这个 pid 文件由启动 Sentinel 的 shell 手动写入，避免 daemonize/fork
# 造成的 PID 混乱。
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

建议这里使用一个**专门的终端 A**，让 Sentinel 独占这个终端前台运行。

```bash
cd /path/to/redis

# 在 exec 之前先把“当前 shell 的 PID”写入文件。
# 因为下面会 exec 成 redis-sentinel，所以这个 PID 会直接变成 Sentinel 的 PID。
echo $$ >/tmp/redis-9956-sentinel/sentinel.pid
exec ./src/redis-sentinel /tmp/redis-9956-sentinel/sentinel.conf
```

如果你更习惯兼容启动方式，也可以用：

```bash
echo $$ >/tmp/redis-9956-sentinel/sentinel.pid
exec ./src/redis-server /tmp/redis-9956-sentinel/sentinel.conf --sentinel
```

> 注意：执行 `exec` 后，这个终端就会被 Sentinel 占用。后面的 `redis-cli`、`pidstat`、`iptables`、`ss`、`strace` 等命令，请在*
*新的终端 B / C / D** 中执行。

确认 Sentinel 已起来：

```bash
vitah@homeubu:~/redis$ ./src/redis-cli -p 26379 ping
PONG
vitah@homeubu:~/redis$ ./src/redis-cli -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster
1) "10.200.1.2"
2) "6379"
```

建议再把 ping 周期调小一点，让异常更快打到读路径：

```bash
./src/redis-cli -p 26379 SENTINEL DEBUG ping-period 100
```

你也可以看日志确认监控已建立：

```bash
vitah@homeubu:~/redis$ tail -f /tmp/redis-9956-sentinel/sentinel.log
2347329:X 25 Apr 2026 13:36:41.265 # WARNING Memory overcommit must be enabled! Without it, a background save or replication may fail under low memory condition. To fix this issue add 'vm.overcommit_memory = 1' to /etc/sysctl.conf and then reboot or run the command 'sysctl vm.overcommit_memory=1' for this to take effect.
2347329:X 25 Apr 2026 13:36:41.265 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
2347329:X 25 Apr 2026 13:36:41.265 * Redis version=255.255.255, bits=64, commit=b70384f7, modified=0, pid=2347329, just started
2347329:X 25 Apr 2026 13:36:41.265 * Configuration loaded
2347329:X 25 Apr 2026 13:36:41.266 * Increased maximum number of open files to 10032 (it was originally set to 1024).
2347329:X 25 Apr 2026 13:36:41.266 * monotonic clock: POSIX clock_gettime
2347329:X 25 Apr 2026 13:36:41.266 * Running mode=sentinel, port=26379.
2347329:X 25 Apr 2026 13:36:41.277 * Sentinel new configuration saved on disk
2347329:X 25 Apr 2026 13:36:41.277 * Sentinel ID is fcd9234c6ee0644e925ea4eb987ba079c66afbab
2347329:X 25 Apr 2026 13:36:41.277 # +monitor master mymaster 10.200.1.2 6379 quorum 1
```

对应的

- SENTINEL_PID=2347329
- SENTINEL_PORT=26379
- MASTER_NAME=mymaster
- MASTER_IP=10.200.1.2
- MASTER_PORT=6379

```shell
# 获取SENTINEL_SPORT
$ while true; do
  SPORT=$(sudo ss -tanp | awk -v pid="$(cat /tmp/redis-9956-sentinel/sentinel.pid)" -v dst="10.200.1.2:6379" '$1=="ESTAB" && $5==dst && $0~("pid=" pid ","){n=split($4,a,":"); print a[n]; exit}')
  [ -n "$SPORT" ] && break
  sleep 0.1
done
printf 'SENTINEL_SPORT=%s\n' "$SPORT"
```

---

## 9. 需要记录的信息（给新终端直接复用）

在这个实验里，建议你明确记录下面这些运行时信息。它们在排错、跨终端复用、以及重新注入旧连接时都很重要：

- `SENTINEL_PID`
   - 当前 Sentinel 进程 PID
   - 用于 `pidstat`、`ss`、`strace`、`kill`
   - 只要 Sentinel 重启，这个值就会变化
- `SENTINEL_PORT`
   - Sentinel 监听端口
   - 本文默认是 `26379`
   - 用于 `redis-cli -p <port>`
- `MASTER_NAME`
   - Sentinel 监控的 master 名称
   - 本文默认是 `mymaster`
   - 用于 `SENTINEL GET-MASTER-ADDR-BY-NAME`
- `MASTER_IP`
   - 当前 `mymaster` 指向的 master IP
   - 用于 `iptables` 注入、`ss` 过滤、连接确认
   - 如果 Sentinel 的视图变化，这个值也要重新获取
- `MASTER_PORT`
   - 当前 `mymaster` 指向的 master 端口
   - 通常是 `6379`
   - 用于 `iptables` 注入、`ss` 过滤、连接确认
- `SENTINEL_SPORT`
   - Sentinel 到 master 的“当前旧连接”的本地源端口
   - `iptables` 用 `--sport "$SENTINEL_SPORT"` 只毒化这条旧连接
   - 只要 Sentinel 重连，这个值就会变化，注入前建议重新获取

补充说明：`sudo ss -tanp` 往往会看到 Sentinel 对同一个 master 存在不止一条 `ESTAB` 连接，这是正常的。本文中的
`SENTINEL_SPORT` 指的是**你本次准备注入的那条旧连接**。

建议在**终端 B**里执行下面这段，拿到当前实验上下文，并把它保存成环境文件：

```bash
SENTINEL_PORT=26379
MASTER_NAME=mymaster
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
MASTER_IP=$(./src/redis-cli --raw -p "$SENTINEL_PORT" SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_NAME" | awk 'NR==1{gsub(/\r/, ""); print; exit}')
MASTER_PORT=$(./src/redis-cli --raw -p "$SENTINEL_PORT" SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_NAME" | awk 'NR==2{gsub(/\r/, ""); print; exit}')

while true; do
  SENTINEL_SPORT=$(sudo ss -tanp | awk -v pid="$SENTINEL_PID" -v dst="$MASTER_IP:$MASTER_PORT" '$1=="ESTAB" && $5==dst && $0~("pid=" pid ","){n=split($4,a,":"); print a[n]; exit}')
  [ -n "$SENTINEL_SPORT" ] && break
  sleep 0.1
done

cat >/tmp/redis-9956-sentinel/context.env <<EOF
export SENTINEL_PORT=$SENTINEL_PORT
export MASTER_NAME=$MASTER_NAME
export SENTINEL_PID=$SENTINEL_PID
export MASTER_IP=$MASTER_IP
export MASTER_PORT=$MASTER_PORT
export SENTINEL_SPORT=$SENTINEL_SPORT
EOF

$ printf 'Saved /tmp/redis-9956-sentinel/context.env\n'
Saved /tmp/redis-9956-sentinel/context.env

$ printf 'SENTINEL_PID=[%s]\nMASTER_IP=[%s]\nMASTER_PORT=[%s]\nSENTINEL_SPORT=[%s]\n' \
  "$SENTINEL_PID" "$MASTER_IP" "$MASTER_PORT" "$SENTINEL_SPORT"
```

### 新开一个终端后怎么直接用

```bash
source /tmp/redis-9956-sentinel/context.env
printf 'PID=%s MASTER=%s:%s SPORT=%s\n' \
  "$SENTINEL_PID" "$MASTER_IP" "$MASTER_PORT" "$SENTINEL_SPORT"
```

### 哪些值需要重新获取

- `SENTINEL_PID`
   - 只要你重启了 Sentinel，就要重新记录
- `SENTINEL_SPORT`
   - 只要 Sentinel 重连了 master，就要重新记录
- `MASTER_IP` / `MASTER_PORT`
   - 如果 `mymaster` 指向发生变化，也要重新记录

一个简单原则是：

- 只要你**重启了 Sentinel**，重新取一次 `SENTINEL_PID`
- 只要你准备**重新注入旧连接**，重新取一次 `SENTINEL_SPORT`
- 只要你怀疑 Sentinel 视图变化，重新取一次 `MASTER_IP` / `MASTER_PORT`

---

## 10. 记录 Sentinel PID 和目标连接的 source port

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

## 11. 先看注入前的 baseline

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

## 12. 注入 `ICMP port-unreachable`

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

$ printf 'MASTER_IP=[%s]\nMASTER_PORT=[%s]\nSENTINEL_PID=[%s]\nSENTINEL_SPORT=[%s]\n' \
  "$MASTER_IP" "$MASTER_PORT" "$SENTINEL_PID" "$SENTINEL_SPORT"
MASTER_IP=[10.200.1.2]
MASTER_PORT=[6379]
SENTINEL_PID=[2347329]
SENTINEL_SPORT=[57346]

$ sudo iptables -I OUTPUT \
  -p tcp \
  -d "$MASTER_IP" \
  --dport "$MASTER_PORT" \
  --sport "$SENTINEL_SPORT" \
  -j REJECT --reject-with icmp-port-unreachable
```

确认规则存在：

```bash
vitah@homeubu:~/redis$ sudo iptables -L OUTPUT -n --line-numbers
Chain OUTPUT (policy ACCEPT)
num  target     prot opt source               destination         
1    REJECT     6    --  0.0.0.0/0            10.200.1.2           tcp spt:57346 dpt:6379 reject-with icmp-port-unreachable
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

## 13. 预期现象：修复前（buggy hiredis）

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

## 14. 预期现象：修复后

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

## 15. 如果修复前卡死了，怎么人工恢复

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

## 16. 完整重置环境并重新开始

如果你要从头重新验证，最稳妥的方式不是只“停掉几个进程”，而是把：

- `iptables` 规则
- Sentinel / master 进程
- namespace / veth 网络拓扑
- `/tmp/redis-9956-sentinel` 里的上下文文件

都一起清掉。下面这段命令可以直接复制执行。

### 一键完整重置

```bash
export REDIS_ROOT=/path/to/redis
cd "$REDIS_ROOT"

echo '== 1) 删除实验插入的 REJECT 规则 =='
sudo iptables -L OUTPUT -n --line-numbers || true
while read -r n rest; do
  sudo iptables -D OUTPUT "$n" || true
done < <(sudo iptables -L OUTPUT -n --line-numbers | awk '/icmp-port-unreachable/ {print $1}' | sort -rn)

echo '== 2) 停掉 Sentinel 和 master =='
pkill -f 'redis-sentinel|redis-server .*--sentinel' 2>/dev/null || true
sudo ip netns exec srv pkill -f 'redis-server.*10.200.1.2' 2>/dev/null || true

echo '== 3) 删除网络拓扑 =='
sudo ip link del veth0 2>/dev/null || true
sudo ip netns del srv 2>/dev/null || true

echo '== 4) 删除临时文件 =='
rm -rf /tmp/redis-9956-sentinel
rm -f /tmp/redis-9956-master.pid /tmp/redis-9956-master.log

echo '== 5) （可选）重新构建 =='
make MALLOC=libc
```

### 重置后重新开始的顺序

执行完上面的完整重置后，建议按这个顺序重新开始：

1. 重新创建 `srv` namespace 和 `veth`
2. 重新启动 namespace 内的 master
3. 重新生成 Sentinel 配置
4. 用 `daemonize no` 在终端 A 前台启动 Sentinel
5. 在终端 B 重新记录：
   - `SENTINEL_PID`
   - `MASTER_IP`
   - `MASTER_PORT`
   - `SENTINEL_SPORT`
6. 再执行 `iptables` 注入
7. 再观察 `pidstat` / `ss` / `strace`

### 只做收尾清理时的最小步骤

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

## 17. 如果没有复现出高 CPU，优先检查这些点

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

## 18. 这个文档和现有回归测试的关系

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

## 19. 推荐的验证顺序

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

## 20. 复制即用：一套 end-to-end 命令清单

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
daemonize no
pidfile /tmp/redis-9956-sentinel/sentinel.pid
logfile /tmp/redis-9956-sentinel/sentinel.log
dir /tmp/redis-9956-sentinel
sentinel monitor mymaster 10.200.1.2 6379 1
sentinel down-after-milliseconds mymaster 60000
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1
EOF
```

在**终端 A**里前台启动 Sentinel：

```bash
echo $$ >/tmp/redis-9956-sentinel/sentinel.pid
exec "$REDIS_ROOT"/src/redis-sentinel /tmp/redis-9956-sentinel/sentinel.conf
```

在**终端 B**里继续执行下面这些确认命令：

```bash
"$REDIS_ROOT"/src/redis-cli -p 26379 ping
"$REDIS_ROOT"/src/redis-cli -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster
"$REDIS_ROOT"/src/redis-cli -p 26379 SENTINEL DEBUG ping-period 100
```

### 6) 拿 pid 和旧连接 sport

```bash
SENTINEL_PID=$(cat /tmp/redis-9956-sentinel/sentinel.pid)
MASTER_NAME=mymaster
MASTER_IP=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_NAME" | awk 'NR==1{gsub(/\r/, ""); print; exit}')
MASTER_PORT=$("$REDIS_ROOT"/src/redis-cli --raw -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME "$MASTER_NAME" | awk 'NR==2{gsub(/\r/, ""); print; exit}')

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

cat >/tmp/redis-9956-sentinel/context.env <<EOF
export SENTINEL_PORT=26379
export MASTER_NAME=$MASTER_NAME
export SENTINEL_PID=$SENTINEL_PID
export MASTER_IP=$MASTER_IP
export MASTER_PORT=$MASTER_PORT
export SENTINEL_SPORT=$SENTINEL_SPORT
EOF

echo "SENTINEL_PID=$SENTINEL_PID"
echo "MASTER_IP=$MASTER_IP"
echo "MASTER_PORT=$MASTER_PORT"
echo "SENTINEL_SPORT=$SENTINEL_SPORT"
echo "Saved /tmp/redis-9956-sentinel/context.env"
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

## 21. 补充观测命令

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