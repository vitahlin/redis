# RDB 流程调用链路

这份笔记聚焦 replication full sync 场景下的 RDB 流程，尤其是 `repl-diskless-sync yes` 时，master 通过 RDB child pipe 把 RDB 流式转发给多个 replica 的路径。

## 总览

```text
replica 发起 SYNC/PSYNC
  -> master: syncCommand()
  -> master: startBgsaveForReplication()
  -> diskless: rdbSaveToSlavesSockets()
  -> child: rdbSaveRioWithEOFMark()
  -> child: rdbSaveRio()
  -> parent: rdbPipeReadHandler()
  -> parent: rdbPipeWriteHandler()          # replica socket 写不完时
  -> replica: readSyncBulkPayload()
```

## Master 侧入口

### 1. replica 发起同步

入口函数：

```text
src/replication.c
syncCommand(client *c)
```

`syncCommand()` 处理 `SYNC` / `PSYNC`。它会先尝试 partial resync；如果不能部分同步，就进入 full sync 流程，把 replica 放入等待 BGSAVE 的状态。

### 2. master 启动 replication BGSAVE

入口函数：

```text
src/replication.c
startBgsaveForReplication(int mincapa, int req)
```

这个函数决定本次 full sync 的 RDB 目标：

- disk-based：调用 `rdbSaveBackground()`，生成磁盘 RDB 文件。
- diskless：调用 `rdbSaveToSlavesSockets()`，通过 socket/pipe 流式发送 RDB。

判断 diskless 的关键条件：

```text
server.repl_diskless_sync && replica 支持 EOF capability
```

如果当前还没到 `repl-diskless-sync-delay`，replica 会先等待，后续由 server cron 调用：

```text
src/replication.c
replicationStartPendingFork()
  -> shouldStartChildReplication()
  -> startBgsaveForReplication()
```

## Diskless RDB 生成与转发

### 3. 创建 RDB child 和 pipe

入口函数：

```text
src/rdb.c
rdbSaveToSlavesSockets(int req, rdbSaveInfo *rsi)
```

这个函数做几件事：

- 创建 RDB pipe：child 写，parent 读。
- 创建 `safe_to_exit_pipe`：parent 用来通知 child 可以安全退出。
- 收集处于 `SLAVE_STATE_WAIT_BGSAVE_START` 的 replica 连接。
- fork RDB child。
- parent 注册 `rdbPipeReadHandler()`，监听 RDB pipe readable 事件。

为什么 child 不直接写 replica socket？

因为 TLS 场景下 socket/TLS 状态需要由 parent 持续维护。child 负责生成 RDB，parent 负责把 RDB 数据写到 replica socket。

### 4. child 生成 RDB

入口函数：

```text
src/rdb.c
rdbSaveRioWithEOFMark(int req, rio *rdb, int *error, rdbSaveInfo *rsi)
  -> rdbSaveRio(int req, rio *rdb, int *error, int rdbflags, rdbSaveInfo *rsi)
```

`rdbSaveRioWithEOFMark()` 是 diskless replication 的包装层。它会写入：

```text
$EOF:<40 bytes eof mark>\r\n
<RDB payload>
<same eof mark>
```

这样 replica 不需要提前知道 RDB 文件大小，也能通过 EOF mark 判断流什么时候结束。

`rdbSaveRio()` 是真正写 RDB 内容的函数，主要流程：

- 写 RDB magic header。
- 写 AUX 字段。
- 写 functions。
- 遍历所有 DB，写 key/value。
- 写 RDB EOF opcode。
- 写 CRC64 checksum。

### 5. parent 从 pipe 读数据并写给 replica

入口函数：

```text
src/replication.c
rdbPipeReadHandler(struct aeEventLoop *eventLoop, int fd, void *clientData, int mask)
```

它是 diskless RDB parent 侧最关键的状态机：

```text
read RDB chunk from child pipe
  -> for each replica:
       connWrite(replica socket)
  -> all replicas wrote full chunk:
       read next chunk immediately
  -> any replica wrote partial chunk:
       set rdbPipeWriteHandler()
       stop reading child pipe
  -> pipe EOF:
       notify child safe to exit
  -> no replica alive:
       kill RDB child
```

关键点：

- `server.rdb_pipe_buff` 是共享 buffer。
- 如果某个 replica 没写完整个 buffer，不能继续读下一块 pipe 数据。
- `server.rdb_pipe_numconns_writing` 记录还有多少 replica 正在补写当前 buffer。
- 只要 `rdb_pipe_numconns_writing > 0`，parent 会移除 `server.rdb_pipe_read` 的 readable event。

这也是 slow replica 会拖慢所有 replica 的原因：一个 replica socket 写不动，parent 就暂停读取 RDB child pipe，child 可能继续被 pipe buffer 卡住。

### 6. partial write 后继续写

入口函数：

```text
src/replication.c
rdbPipeWriteHandler(struct connection *conn)
```

当某个 replica socket 重新可写时，这个 handler 继续写当前共享 buffer 中剩余的数据。

写完后调用：

```text
src/replication.c
rdbPipeWriteHandlerConnRemoved(struct connection *conn)
```

如果所有 pending write 都完成，即：

```text
server.rdb_pipe_numconns_writing == 0
```

parent 会重新注册 `rdbPipeReadHandler()`，继续从 RDB child pipe 读取下一块数据。

## Replica 侧接收入口

入口函数：

```text
src/replication.c
readSyncBulkPayload(connection *conn)
```

replica 从 master 读取 full sync payload。它支持两种格式：

- `$<size>`：传统已知长度 RDB。
- `$EOF:<mark>`：diskless 流式 RDB，用 EOF mark 判断结束。

diskless 场景下，replica 会：

- 读取 `$EOF:<mark>` header。
- 持续读取 RDB 数据。
- 检测末尾 EOF mark。
- 根据配置选择写临时 RDB 文件，或直接 diskless load 到内存/parser。
- 加载完成后切换为 connected/online 状态，继续接收后续命令流。

## 异常与边界路径

### replica socket 写不完

```text
rdbPipeReadHandler()
  -> connWrite() partial / EAGAIN
  -> set rdbPipeWriteHandler()
  -> aeDeleteFileEvent(server.rdb_pipe_read)
```

结果：parent 暂停读 child pipe，直到该 replica 的当前 buffer 写完。

### replica 断开

```text
rdbPipeReadHandler()
  -> connWrite() real error
  -> freeClient(slave)
  -> server.rdb_pipe_conns[i] = NULL
```

这个 replica 后续不再参与本次 RDB pipe 传输。

### 所有 replica 都断开

```text
rdbPipeReadHandler()
  -> stillAlive == 0
  -> "Diskless rdb transfer, last replica dropped, killing fork child"
  -> killRDBChild()
```

这就是 `tests/integration/replication.tcl` 中 `all` 子场景要覆盖的路径。

### RDB pipe 正常结束

```text
rdbPipeReadHandler()
  -> read() returns 0
  -> "Diskless rdb transfer, done reading from pipe, N replicas still up"
  -> close(server.rdb_child_exit_pipe)
```

`server.rdb_child_exit_pipe` 关闭后，child 知道 parent 已经消费完 pipe，可以安全退出。

### full sync replica 超时

server cron 会检查：

```text
src/replication.c
slave->replstate == SLAVE_STATE_WAIT_BGSAVE_END
server.rdb_child_type == RDB_CHILD_TYPE_SOCKET
slave->repl_last_partial_write != 0
server.unixtime - slave->repl_last_partial_write > server.repl_timeout
```

命中后断开 replica，并记录：

```text
Disconnecting timedout replica (full sync)
```

## 测试对应关系

测试位置：

```text
tests/integration/replication.tcl
diskless $all_drop replicas drop during rdb pipe
```

子场景含义：

- `no`：两个 replica 都存活，期望 `2 replicas still up`。
- `fast`：kill fast replica，slow replica 存活，期望 `1 replicas still up`。
- `slow`：kill slow replica，fast replica 存活，期望 `1 replicas still up`。
- `all`：两个 replica 都 kill，期望 `last replica dropped, killing fork child`。
- `timeout`：slow replica 被 full sync timeout 断开，fast replica 存活，期望 `1 replicas still up`。

这个测试的核心不是只验证“最终通过”，而是通过日志确认具体代码路径被覆盖。
