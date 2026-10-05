## Per-fd deadline registry for the idle-connection reaper, and the
## process-wide count of buffered-but-unconsumed bytes the acceptor gates on.
##
## The connection driver arms a deadline on an fd immediately before it blocks
## on a read and disarms it the instant the read returns, so a connection is
## watched only while blocked with no inbound bytes — never while a handler
## runs, and any inbound byte resets it. A recurring reaper sweep calls
## `reapExpired`, which `shutdown()`s any fd still armed past its deadline;
## that routes through the normal completion path, so the parked read returns
## <=0 and the driver's existing unwind closes the fd. Two exceptions arm a
## deadline around a write rather than a read, both in the WebSocket
## keepalive: the idle close arms one as a backstop for its own CLOSE and
## leaves it armed for teardown's `clearConn`, and with `userTimeoutMs` at 0
## the reader arms one while its own PING, PONG or CLOSE waits behind
## another writer, disarming it when the write returns.
##
## The byte count is the aggregate bound the per-connection caps cannot give:
## every read adds (`addInflight`), every consumed or dropped byte subtracts
## (`subInflight`), and the acceptor refuses new connections at
## `ServerConfig.maxInflightBytes` so many part-buffered requests cannot
## outgrow the machine. It covers the bytes a connection holds unparsed (an
## HTTP connection's read buffer, a WebSocket's inbound frame buffer) and
## the payload of a fragmented WebSocket message while it is assembled, up
## to `maxWsMessage` per connection, until the message is delivered,
## refused or the connection ends. Transient copies made while those bytes
## are still counted (a request body, a delivered message) are not.
##
## Writes are intentionally not timed. A write blocks under TCP flow control
## until the peer's window reopens, which for a slow-but-alive reader can be
## much slower than its read cadence, so an app-layer write deadline cannot
## tell "slow but alive" from "stalled". Write-stall / dead-peer detection is
## the kernel's job (`TCP_USER_TIMEOUT`); see `hashi/http/server`. The
## WebSocket exceptions above apply only once the idle timeout has passed.
##
## Lock-free: the connection worker writes its slot's deadline and the reaper
## reads it, both via aligned 64-bit atomics. fd reuse needs no generation
## counter because deadlines are monotonic-nanosecond values (effectively
## unique): the reaper commits a reap with a compare-and-swap of the exact
## deadline it saw, which fails if teardown cleared the slot or a new
## connection re-armed it with a different value.

import std/atomics

const MaxFds* = 8192
  ## Bound on the fd numbers this registry can track: `gDeadline` below is a
  ## flat fd-indexed array, so an fd at or past this cannot be armed and the
  ## acceptor refuses it (see `hashi/http/server`). Raising it costs 8 bytes
  ## of BSS per fd; it should stay at or above the process's `RLIMIT_NOFILE`,
  ## since that is what actually bounds the fds this registry can be handed.

proc shutdownRaw(fd: cint; how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
const SHUT_RDWR = 2.cint

var gDeadline: array[MaxFds, int64]   ## 0 = not watched; else the deadline in monotonic ticks.
var gReapCount: int64                 ## Total connections reaped, for `reapedTotal`.
var gWsIdleCloseCount: int64          ## WebSocket idle closes, for `wsIdleClosedTotal`.
var gInflight: int64                  ## Bytes buffered across connections, not yet consumed.

proc addInflight*(n: int) =
  ## Count `n` bytes read into a connection buffer.
  if n > 0: discard atomicFetchAdd(gInflight, int64(n))

proc subInflight*(n: int) =
  ## Stop counting `n` bytes: consumed by a parser, or dropped at teardown.
  if n > 0: discard atomicFetchSub(gInflight, int64(n))

proc inflightBytes*(): int64 =
  ## Total bytes buffered across all connections and not yet consumed by a
  ## parser, plus fragmented WebSocket messages being assembled. The
  ## per-connection caps bound one connection; this bounds all
  ## of them at once, and the acceptor refuses new connections at
  ## `ServerConfig.maxInflightBytes`.
  atomicLoad(gInflight)

proc setDeadline*(fd: cint; deadlineNanos: int64) =
  ## Arm (deadlineNanos > 0) or disarm (0) the reap deadline for `fd`.
  if fd >= 0.cint and fd.int < MaxFds:
    atomicStore(gDeadline[fd.int], deadlineNanos)

proc deadlineOf*(fd: cint): int64 =
  ## The reap deadline armed for `fd`, or 0 when none is.
  result = 0'i64
  if fd >= 0.cint and fd.int < MaxFds:
    result = atomicLoad(gDeadline[fd.int])

proc clearConn*(fd: cint) =
  ## Disarm on connection teardown (belt-and-suspenders; the driver also disarms
  ## after each wait returns).
  if fd >= 0.cint and fd.int < MaxFds:
    atomicStore(gDeadline[fd.int], 0'i64)

proc reapExpired*(nowNanos: int64): int =
  ## Sweep the table; `shutdown()` every fd armed past `nowNanos`. Returns the
  ## number reaped this pass. Called on the reactor from the reaper loop.
  result = 0
  var fd = 0
  while fd < MaxFds:
    let dl = atomicLoad(gDeadline[fd])
    if dl != 0'i64 and nowNanos > dl:
      var expected = dl
      # Claim the reap atomically: only shutdown if the slot still holds the
      # exact expired deadline we saw (guards teardown / fd reuse).
      if atomicCompareExchange(gDeadline[fd], expected, 0'i64):
        discard shutdownRaw(fd.cint, SHUT_RDWR)
        discard atomicFetchAdd(gReapCount, 1'i64)
        result = result + 1
    fd = fd + 1

proc reapedTotal*(): int64 =
  ## Cumulative connections reaped since boot (for app /metrics).
  atomicLoad(gReapCount)

proc countWsIdleClose*() =
  ## Record one WebSocket closed by its keepalive for inbound silence.
  discard atomicFetchAdd(gWsIdleCloseCount, 1'i64)

proc wsIdleClosedTotal*(): int64 =
  ## Cumulative WebSockets closed for inbound silence (`wsIdleTimeoutMs`)
  ## since boot, for app /metrics. Counted apart from `reapedTotal`: the
  ## keepalive closes these itself, with a CLOSE 1001.
  atomicLoad(gWsIdleCloseCount)
