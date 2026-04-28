# Redis 6.2.6 崩溃分析:Lua → HSET → notifyKeyspaceEvent → sdsMakeRoomFor (SIGSEGV)

对应上游 issue:[redis/redis#13302](https://github.com/redis/redis/issues/13302)

## 1. 崩溃栈翻译

```
EVAL/EVALSHA
└─ evalGenericCommand
   └─ lua_pcall                       (运行用户脚本)
      └─ luaRedisGenericCommand       (脚本里 redis.call("HSET", ...))
         └─ call
            └─ hsetCommand            (写完 hash,准备发通知)
               └─ notifyKeyspaceEvent (+0xd6)
                  └─ sdscatlen        (+0x44)   拼接 channel 名
                     └─ sdsMakeRoomFor (+0x429)  ★ SIGSEGV
```

崩溃发生在 keyspace notification 阶段(`__keyspace@<db>__:<key>` / `__keyevent@<db>__:hset`),拼接 SDS 字符串时 `sdsMakeRoomFor` 解引用了非法地址。

## 2. 寄存器关键证据

| 寄存器 | 值 | 含义 |
|---|---|---|
| `RAX` | `0xffffffff830ff539` | 触发 SIGSEGV 的地址,**符号扩展过的负 int32**,典型的"从坏掉的 SDS header 读出 len/alloc 后做指针运算"的特征 |
| `RDI` | `0x00007f5a6abb0001` | `sdsMakeRoomFor` 的 `s` 参数 |
| `RBP` | `0x00007f5a6abb0001` | 同上,函数把 `s` 暂存到 `RBP` |
| `RSI` | `0x1` | `addlen = 1` |
| `RBX` | `0x1` | `s[-1] & SDS_TYPE_MASK = 1`,即 `SDS_TYPE_8` |
| `R13` | `0xb` (=11) | 对应 `sdsnewlen("__keyspace@", 11)` 的长度 |

`R13 = 11` 可以**确定崩溃点就是 `notifyKeyspaceEvent` 里 `__keyspace@<db>__:<key>` 这条频道的拼接**。

## 3. 直接原因 vs 根因

- **直接原因**:`sdsMakeRoomFor` 从 SDS header 读出来的 `len`/`alloc` 已经被破坏,运算后落到非法地址 `0xffffffff830ff539`,解引用即 SIGSEGV。
- **根因**:这是一次**堆已经被踩坏后的"二次崩溃"**。`chan` 是 `notifyKeyspaceEvent` 内部刚 `sdsnewlen` 出来的对象,本身没问题;真正的越界写发生在更早的某条路径上,只是症状显形于通知拼字符串这一步。
- 最可疑的上游是 **Lua 脚本里 `redis.call` 走的 `luaRedisGenericCommand` → `argv` 缓存 / SDS 拼接** 这一带,6.2.6 在这条路径上历史上确实有过 bug。

## 4. 嫌疑犯逐一核对(以及当前 unstable 的修复状态)

| # | 嫌疑犯 | 影响版本 | 当前 unstable |
|---|---|---|---|
| 1 | **#9809** Lua 脚本传大量参数引发的崩溃,**6.2.6 引入的回归** | 6.2.6 | ✅ 6.2.7 修复,`luaRedisGenericCommand` 里 `lua_pop(lua, *argc)` 仍在 |
| 2 | **#11652** Lua argv 缓存 + module command filter + libc realloc 同址不同尺寸 | 7.0.6 引入 | ✅ 7.0.7 修复,引入 `argv_len`,`freeLuaRedisArgv` 严格比对 `argv_len != lua_argv_size` |
| 3 | **CVE-2021-41099** `_sdsMakeRoomFor` 整数溢出 | <6.2.6 | ✅ 6.2.6 当版已修 |
| 4 | **#8286** `sdscatfmt` 向 `sdsMakeRoomFor` 要错空间 | <6.2.6 | ✅ 已修 |
| 5 | **CVE-2023-41056** `sdsResize` 堆腐蚀 | 6.2.6 仍有 | ✅ 6.2.14 / 7.0.13 修复 |
| 6 | `notifyKeyspaceEvent` 入口缺少类型断言 | 6.2.6 | ✅ 已加 `serverAssert(sdsEncodedObject(key))`,作为事后兜底 |

`notifyKeyspaceEvent` 的核心拼接逻辑(`sdsnewlen → sdscatlen → sdscatlen → sdscatsds`)从 6.2.6 到 unstable **没有结构性变化**,这反过来印证"问题不在通知函数本身,而在其上游已被修掉的越界"。

## 5. 这个 bug 现在还在吗

- **当前 unstable 上以同样栈复现的概率极低**:所有合理的上游嫌疑路径(Lua argv 缓存、SDS header 越界写、SDS resize 腐蚀)都已被修复,且 `notifyKeyspaceEvent` 入口加了 sanity check 兜底。
- **不能严格证明"某个 commit 就是修了 issue #13302 那一例"**:issue 当年就没定位到根因,维护者直接建议升级,没有合入针对该 issue 的 fix。
- **维护者原话**:"this is a rather old version (even for 6.2.x), skimming over the release notes I don't see anything obvious, but still maybe you should try [升级]"。

## 6. 建议(按性价比从高到低)

1. **升级 Redis**。最低升到 6.2 分支末班车,推荐直接 7.2.x / 7.4.x / 8.x。issue #13832 的同类崩溃在升到 7.2.7 后消失。
2. 短期不能升级时,做隔离实验缩小嫌疑面:
   - 临时把崩溃前后跑的 Lua 脚本下线 / 单步压测;
   - 临时把对应 key 的 `notify-keyspace-events` 关掉,确认通知路径只是放大器;
   - 用 jemalloc `MALLOC_CONF=abort_conf:true,xmalloc:true` 或 ASan / Valgrind 编译版跑相同负载,真正的越界写会被第一时间逮住。
3. **保留 core dump**:supervisord 里给 redis 进程开 `ulimit -c unlimited`,设置好 `/proc/sys/kernel/core_pattern`。下次再崩才能看到 `chan` 的真实长度、`s[-1]`、Lua 栈上的命令参数。
4. 检查崩前几秒写入的 hash 大小;6.2.6 对超大 value(几十 MB+)与改大的 `proto-max-bulk-len` 比较敏感(同 CVE-2021-41099 一脉)。

## 7. 一句话总结

> 这不是 keyspace 通知本身的 bug,而是 6.2.6 上一次更早的内存破坏在通知拼字符串时显形;首选解法是升级版本,其次才是抓 core / 用 ASan 复现真正的越界点。当前 unstable 已经累积了 4 年的相关安全补丁,以同样栈复现的可能性极低。
