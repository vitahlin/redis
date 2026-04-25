# PR: Fix Sentinel 100% CPU busy-loop on async socket error (EPOLLERR)

## Title

```
hiredis: fix busy-loop on EPOLLERR by consuming SO_ERROR in redisNetRead
```

## Description

```
Fix 100% CPU busy-loop in Redis Sentinel caused by unconsumed SO_ERROR on non-blocking sockets.

When a monitored Redis instance becomes unreachable (e.g. after a Kubernetes pod IP rotation), the kernel stores an asynchronous error in the socket's SO_ERROR field and raises EPOLLERR. Because EPOLLERR is level-triggered and ae_epoll.c maps it to AE_READABLE, hiredis's read callback is invoked repeatedly. However, recv() does not consume SO_ERROR — it only drains the receive queue — so it returns EAGAIN. The old code treated EAGAIN as "try again later" and returned 0 without clearing the error, causing epoll_wait to fire again immediately in an infinite loop.

The fix adds a getsockopt(SO_ERROR) check in redisNetRead() when recv() returns EWOULDBLOCK on a non-blocking socket. If a pending socket error is found, it is consumed (which clears EPOLLERR) and reported to the caller as REDIS_ERR_IO, allowing the async layer to tear down the dead connection. Sentinel then reconnects normally.

The check is zero-cost on healthy connections: the EWOULDBLOCK branch is only reached when epoll says "readable" but recv finds nothing, which does not happen during normal data flow.

Fixes #9956
```

## Root Cause Analysis

### The problem

Redis Sentinel enters a 100% CPU busy-loop after the monitored Redis instance becomes network-unreachable. This is most commonly triggered by Kubernetes pod rolling updates, but can occur in any environment where an established TCP connection's destination suddenly disappears.

### The four-layer chain

The bug requires four layers to interact — remove any one and the loop breaks:

```
 Kernel: sets sk_err on the TCP socket (hard error)
   ↓
 epoll:  EPOLLERR is level-triggered, fires every epoll_wait
   ↓
 ae:     ae_epoll.c maps EPOLLERR → AE_READABLE|AE_WRITABLE
   ↓
 hiredis: recv() returns EAGAIN, redisNetRead returns 0 (BUG)
   ↓
 Loop:   SO_ERROR never consumed → EPOLLERR persists → repeat
```

### Layer 1 — Kernel: async error on the socket

When the destination IP becomes unreachable the kernel sets `sk_err` (the "hard error" field) on the TCP socket. This happens through several paths:

- **Route disappears** — The pod's IP is no longer in any routing table. `ip_route_output_flow()` fails with `EHOSTUNREACH` during `tcp_transmit_skb()`, which directly sets `sk->sk_err`.

- **Network namespace destroyed** — Kubernetes tears down the pod's network namespace; the veth pair is removed, ARP entries expire, and subsequent sends fail at the routing layer.

- **ICMP unreachable with `IP_RECVERR`** — `tcp_v4_err()` in the Linux kernel ([net/ipv4/tcp_ipv4.c]) handles incoming ICMP errors for established connections:

  ```c
  /* rfc1122 4.2.3.9 — treat as hard error only if IP_RECVERR */
  if (!sock_owned_by_user(sk) && inet_test_bit(RECVERR, sk)) {
      WRITE_ONCE(sk->sk_err, err);       /* hard error */
  } else {
      WRITE_ONCE(sk->sk_err_soft, err);  /* soft error */
  }
  ```

  When `IP_RECVERR` is not set (the default for Redis), ICMP errors on ESTABLISHED connections only set `sk_err_soft` — which does **not** trigger `EPOLLERR`. This is why local `iptables REJECT` cannot reproduce the bug. In the Kubernetes pod-deletion path, the error comes from the **send path** (routing failure), not from an incoming ICMP, so it always sets `sk_err` regardless of `IP_RECVERR`.

**References:**
- Linux kernel `tcp_v4_err()`: https://github.com/torvalds/linux/blob/v6.13-rc6/net/ipv4/tcp_ipv4.c
- Linux kernel `tcp_poll()`: https://github.com/torvalds/linux/blob/v6.4/net/ipv4/tcp.c
- RFC 5461 "TCP's Reaction to Soft Errors": https://datatracker.ietf.org/doc/html/rfc5461
- RFC 1122 §4.2.3.9 — ICMP on established connections are soft errors

### Layer 2 — epoll: EPOLLERR is level-triggered

`tcp_poll()` returns `EPOLLERR` whenever `sk->sk_err != 0`:

```c
/* net/ipv4/tcp.c — tcp_poll() */
if (sk->sk_err || !skb_queue_empty_lockless(&sk->sk_error_queue))
    mask |= EPOLLERR;
```

`EPOLLERR` is **always level-triggered** even in edge-triggered mode (per `epoll(7)` man page). As long as `SO_ERROR` is not consumed via `getsockopt()`, every `epoll_wait()` call returns immediately.

### Layer 3 — Redis event loop: EPOLLERR mapped to readable

`src/ae_epoll.c`:

```c
if (e->events & EPOLLERR) mask |= AE_WRITABLE|AE_READABLE;
```

This dispatches hiredis's read handler (`redisAsyncHandleRead`).

### Layer 4 — hiredis: EAGAIN swallowed without checking SO_ERROR

`deps/hiredis/net.c` — `redisNetRead()` (before fix):

```c
ssize_t nread = recv(c->fd, buf, bufcap, 0);
if (nread == -1) {
    if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || ...) {
        return 0;  // ← BUG: "try later", SO_ERROR not consumed
    }
}
```

`recv()` only drains the receive queue; it does not inspect `SO_ERROR`. An empty receive queue returns `EAGAIN` regardless of any pending socket error. By returning `0`, hiredis tells the async layer "nothing happened, connection is fine" — no disconnect, no reconnect.

### Why Sentinel's reconnect logic does not help

Sentinel has reconnection logic (`sentinelReconnectInstance()`), but it only triggers when hiredis reports an error via its disconnect callback. Since `redisNetRead` returns `0` (not `-1`), `redisAsyncRead` sees `REDIS_OK` and never calls `__redisAsyncDisconnect`. The reconnect precondition is bypassed.

## Why this is most common in Kubernetes

Kubernetes pod rolling updates create the exact conditions for this bug ([kubernetes#86280], [kubernetes#104098]):

1. The old pod is marked Terminating; kubelet sends SIGTERM.
2. kube-proxy removes the endpoint from iptables/IPVS rules.
3. After the grace period (default 30s), the pod is killed and its network namespace is destroyed.
4. **kube-proxy does not flush TCP conntrack entries** for the deleted pod ([kubernetes#104098]) — by design, to allow graceful shutdown.
5. Sentinel still holds TCP connections to the old pod IP.
6. The next `send()` from Sentinel hits a routing failure → `sk_err = EHOSTUNREACH` → `EPOLLERR` → busy-loop.

Sentinel maintains two connections per master:
- `cc` (commands): periodic PINGs cause `send()` to consume `SO_ERROR` → normal disconnect → **not stuck**.
- `pc` (pubsub): read-only after SUBSCRIBE, no writes → `SO_ERROR` is **never consumed** → **busy-loop persists**.

**References:**
- https://github.com/kubernetes/kubernetes/issues/86280
- https://github.com/kubernetes/kubernetes/issues/104098
- https://github.com/kubernetes/kubernetes/issues/108523

## The fix

```diff
 ssize_t redisNetRead(redisContext *c, char *buf, size_t bufcap) {
     ssize_t nread = recv(c->fd, buf, bufcap, 0);
     if (nread == -1) {
-        if ((errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) || (errno == EINTR)) {
-            /* Try again later */
+        if (errno == EWOULDBLOCK && !(c->flags & REDIS_BLOCK)) {
+            /* ... (see redis/redis#9956) ... */
+            int so_error = 0;
+            socklen_t errlen = sizeof(so_error);
+            if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR,
+                           &so_error, &errlen) == 0 && so_error != 0)
+            {
+                errno = so_error;
+                __redisSetError(c, REDIS_ERR_IO, strerror(errno));
+                return -1;
+            }
+            /* No pending socket error — try again later. */
+            return 0;
+        } else if (errno == EINTR) {
+            /* Signal interrupted — retry. */
             return 0;
         } else if(errno == ETIMEDOUT && (c->flags & REDIS_BLOCK)) {
```

### How the fix works

1. **`getsockopt(SOL_SOCKET, SO_ERROR)`** atomically reads and clears `sk_err`. Once cleared, `tcp_poll()` no longer returns `EPOLLERR` — the trigger for the loop is removed.

2. **Returns `-1` with `REDIS_ERR_IO`** — the async layer calls `__redisAsyncDisconnect()`, which fires Sentinel's disconnect callback → `link->disconnected = 1` → `sentinelReconnectInstance()` establishes a fresh connection.

3. **When `SO_ERROR == 0`** (genuine spurious wakeup), the function falls through to the existing `return 0` — behavior unchanged.

### Why the check is only for non-blocking + EWOULDBLOCK

- `EINTR` (signal interrupted) is not a socket error.
- Blocking mode `EWOULDBLOCK` comes from `SO_RCVTIMEO` timeout, not from epoll wakeup.
- The non-blocking + `EWOULDBLOCK` combination is the only path that the Sentinel/event-loop scenario can reach.

## Behavior before and after

| Scenario | Before | After |
|----------|--------|-------|
| Normal data read | recv returns data → process | Unchanged |
| Peer graceful close (FIN) | recv returns 0 → EOF → disconnect | Unchanged |
| Peer RST | recv returns ECONNRESET → disconnect | Unchanged |
| **Async error (ICMP/route)** | **recv EAGAIN → busy-loop 100% CPU** | **getsockopt → disconnect → reconnect** |
| Spurious EAGAIN (rare) | return 0, retry later | getsockopt finds SO_ERROR=0 → return 0 |

## Why no automated test case is included

This bug requires the kernel to set `sk_err` (hard error) on an ESTABLISHED TCP socket. On Linux, this only happens when:

- The **send path** encounters a routing failure (destination unreachable), or
- `IP_RECVERR` is enabled and an ICMP error arrives.

Standard test tooling (`iptables REJECT/DROP`) cannot produce this condition on ESTABLISHED connections — the kernel treats ICMP errors as soft errors (`sk_err_soft`) for established TCP per RFC 1122 §4.2.3.9, which does not trigger `EPOLLERR`.

The bug is reliably triggered in Kubernetes environments during pod rolling updates, where network namespace destruction causes route removal → `sk_err` on the sending socket. A unit test would require either:

- A real Kubernetes cluster with pod lifecycle management, or
- Kernel-level fault injection (e.g. BPF to force `sk_err`), or
- Invasive code-level test hooks in hiredis.

None of these are appropriate for the existing Redis test suite. The fix is verified by:

1. **Code inspection**: the logic is straightforward — one `getsockopt` call in a well-defined error path.
2. **Regression safety**: when `SO_ERROR == 0`, the function returns the same `0` as before; all normal paths are unchanged.
3. **Production validation**: the issue is reproduced and confirmed fixed in Kubernetes environments where the original bug occurs.