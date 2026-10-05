## WebSocket session I/O: the passive `wsRecv`/`wsSend`/`wsClose`/`wsPeek`/
## `wsSkip` ops.
##
## `import` this alongside `hashi/ws/session` to write a handler
## (`proc(ws: WsConn) {.passive.}`). Protocol correctness (framing,
## fragmentation, UTF-8, close codes) lives in `hashi/ws/protocol`; this
## module is the I/O loop that drives it and surfaces complete messages to
## the handler, and runs the keepalive while `wsRecv` waits.
##
## Every write to the socket goes through one of two leaf writers,
## `wsWriteAll` and the send-buffer writer behind `wsSend`, and each holds
## the connection's write guard (`WsConn.writeGuard`) for a whole frame, so
## a control frame from the reader (PONG, PING, CLOSE) never lands inside a
## data frame another task is part-way through writing. A writer that finds
## the guard held parks, 1 ms at first and doubling to 50 ms, rather than
## spinning. The guard is fair to parked writers: a writer arriving while
## others wait parks behind them, so control frames wait their turn behind
## at most the frame being written, even against a task sending frames
## back to back. No caller of the leaf writers takes the guard, so it never
## nests. Once a CLOSE has been written, no data frame is. The guard covers
## the write, not `ws.sbuf`: two tasks calling `wsSend` at once still need
## queued mode (`useOutQueue`).

import std/[monotimes, atomics]
from std/posix/posix import pcall, EAGAIN, EINTR
import hashi/loop
import hashi/buffer
import hashi/http/request
import hashi/http/config
import hashi/http/connreg   # setDeadline, addInflight/subInflight, countWsIdleClose
import hashi/ws/frame
import hashi/ws/protocol
import hashi/ws/session
import hashi/ws/outq

proc cRecv(fd: cint; buf: pointer; len: csize_t; flags: cint): int {.importc: "recv", header: "<sys/socket.h>".}
const MsgDontWait = (when defined(macosx): 0x80.cint else: 0x40.cint)
  ## `MSG_DONTWAIT`: every recv here is non-blocking, whatever the fd's own
  ## mode. EAGAIN means nothing is buffered yet, not an error.

const WsCloseGraceMs* = 5000
  ## How long the keepalive's idle close gives its CLOSE frame before the
  ## reaper shuts the socket down: the frame's write can itself stall on a
  ## peer that stopped reading.

# ── the write guard ─────────────────────────────────────────────────────

const GuardParkCapMs = 50
  ## Longest park of a writer waiting for the guard: at most about 20
  ## wake-ups a second, however long the holder's write stalls.

var gGuardParks: int64   ## accessed atomically; see `wsGuardParksTotal`

proc wsGuardParksTotal*(): int64 =
  ## Cumulative parks of writers waiting for another's frame to finish, for
  ## tests and telemetry.
  atomicLoad(gGuardParks)

proc tryTakeWriteGuard(ws: WsConn): bool =
  var expected = 0
  result = atomicCompareExchange(ws.writeGuard, expected, 1)

proc releaseWriteGuard(ws: WsConn) =
  atomicStore(ws.writeGuard, 0)

proc takeWriteGuard(ws: WsConn) {.passive.} =
  ## Take the write guard, parking while it is held: 1 ms, doubling to
  ## `GuardParkCapMs`. A writer that arrives while others are parked does
  ## not try for the guard; it parks too, starting at the longest park so
  ## those already waiting retry first. So once the holder releases, a
  ## parked writer gets the guard before any writer arriving fresh, and a
  ## writer sending frames back to back hands over at its next frame.
  ## Parked writers are not served in strict arrival order.
  var got = false
  let parked = atomicLoad(ws.guardWaiters)
  if parked == 0:
    got = tryTakeWriteGuard(ws)
  if not got:
    let ahead = atomicFetchAdd(ws.guardWaiters, 1)
    var nap = if ahead == 0: 1 else: GuardParkCapMs
    while not got:
      discard atomicFetchAdd(gGuardParks, 1'i64)
      sleepMs(nap)
      nap = min(nap * 2, GuardParkCapMs)
      got = tryTakeWriteGuard(ws)
    discard atomicFetchSub(ws.guardWaiters, 1)

# ── the leaf writers ────────────────────────────────────────────────────

proc frameOpcode(data: string): int =
  ## The opcode of the frame `data` starts with, or -1 when it is empty.
  result = if data.len > 0: int(uint8(data[0]) and 0x0F'u8) else: -1

proc writeAllUnguarded(ws: WsConn; data: string): bool {.passive.} =
  ## `wsWriteAll`'s write, for a caller that holds the guard.
  result = true
  var wbuf = default(array[4096, char])
  var off = 0
  var cont = true
  while off < data.len and cont:
    var clen = data.len - off
    if clen > 4096: clen = 4096
    copyOut(addr wbuf[0], data, off, clen)
    var wOff = 0
    while wOff < clen and cont:
      let t0 = getMonoTime()
      let w = waitWrite(ws.fd, addr wbuf[wOff], clen - wOff)
      ws.sendBlockedNs = ws.sendBlockedNs + (getMonoTime() - t0).inNanoseconds
      ws.writeSyscalls = ws.writeSyscalls + 1
      if w <= 0:
        result = false
        cont = false
      else:
        wOff = wOff + w
    off = off + clen

proc wsWriteAll*(ws: WsConn; data: string): bool {.passive.} =
  ## Write the frame `data` in full, handling short writes, holding the
  ## write guard throughout; waits its turn while another task's frame is
  ## being written. Once a CLOSE has gone out, a data frame (text, binary or
  ## continuation) is refused without writing anything; control frames
  ## still go. Returns false on a write error or a refusal. Accumulates the
  ## connection's send counters: time suspended in `waitWrite`
  ## (backpressure) and syscall count.
  takeWriteGuard(ws)
  let op = frameOpcode(data)
  if ws.closeWritten and op >= 0 and op <= 2:
    result = false
  else:
    result = writeAllUnguarded(ws, data)
    if op == 8: ws.closeWritten = true
  releaseWriteGuard(ws)

proc wsEmitCtl(ws: WsConn; frame: string; lane = lnUrgent;
               coalesce = false): bool {.passive.} =
  ## Emit a complete, pre-serialized control frame (PONG / CLOSE). In queued
  ## mode (`ws.hasOutq`) this enqueues onto `lane` instead of writing the fd
  ## directly, so the writer loop stays the only task that touches the socket
  ## — a direct write here would race it. Not queued: `wsWriteAll`, which
  ## waits for any frame another task is writing.
  ##
  ## Callers pick the lane deliberately: PONG is liveness and must not wait
  ## behind data, so it goes `lnUrgent`. CLOSE must not jump ahead of a
  ## queued explanatory frame (e.g. an `error` message) or the client sees
  ## the disconnect without learning why, so it goes `lnControl` — ahead of
  ## the STREAM lane, behind anything already on CONTROL. A PONG `coalesce`s:
  ## only the reply to the latest PING is kept queued (RFC 6455 5.5.3).
  if ws.hasOutq:
    result = wsEnqueue(ws.outq, lane, frame, false, -1, true, 0'i64,
                       coalesce) != eqClosed
  else:
    result = wsWriteAll(ws, frame)

proc wsConsume(ws: WsConn; consumed: int) =
  ## Drop the first `consumed` (parsed) bytes from the inbound buffer. Frees the
  ## large buffer before the caller builds/echoes — keeps peak memory down —
  ## and stops counting them.
  dropPrefix(ws.acc, consumed)
  subInflight(consumed)

proc countAssembled(ws: WsConn; before: int) =
  ## Move the in-flight count with the message being assembled, whose
  ## length was `before` ahead of the last `handleFrame`: a fragment added
  ## to it is counted, and a message delivered or dropped stops being.
  let after = assembledLen(ws.st)
  if after > before: addInflight(after - before)
  elif after < before: subInflight(before - after)

proc fillSendBuf(ws: WsConn; op: Opcode; data: string): int =
  ## Non-passive: build [frame header | payload] into the connection's reusable
  ## send buffer (one heap buffer, grown to the largest frame seen, reused after).
  ## Returns the total length. Coalescing into one buffer lets wsSend issue a
  ## single write — no separate tiny-header packet, and no 4 KB chunking that with
  ## TCP_NODELAY put each slice in its own segment/syscall.
  let hdr = frameHeader(op, data.len)
  let total = hdr.len + data.len
  if ws.sbuf.len < total:
    ws.sbuf.setLen(total)
  copyOut(addr ws.sbuf[0], hdr, 0, hdr.len)
  if data.len > 0:
    copyOut(addr ws.sbuf[hdr.len], data, 0, data.len)
  result = total

proc fillSendBuf(ws: WsConn; op: Opcode; data: openArray[byte]): int =
  ## `openArray[byte]` payload variant: the payload is appended with one
  ## `copyMem`, avoiding a per-byte loop or a seq→string round-trip.
  let hdr = frameHeader(op, data.len)
  let total = hdr.len + data.len
  if ws.sbuf.len < total:
    ws.sbuf.setLen(total)
  copyOut(addr ws.sbuf[0], hdr, 0, hdr.len)
  if data.len > 0:
    copyMem(addr ws.sbuf[hdr.len], addr data[0], data.len)
  result = total

proc writeSendBuf(ws: WsConn; total: int): bool {.passive.} =
  ## Write the first `total` bytes of the send buffer in one pass, handling
  ## short writes, holding the write guard throughout; refused (false,
  ## nothing written) once a CLOSE has gone out. Updates
  ## `ws.writeSyscalls` and `ws.sendBlockedNs` on every `waitWrite`; false
  ## once the peer is gone.
  takeWriteGuard(ws)
  result = not ws.closeWritten
  var off = 0
  var cont = result
  while off < total and cont:
    let t0 = getMonoTime()
    let w = waitWrite(ws.fd, addr ws.sbuf[off], total - off)
    ws.sendBlockedNs = ws.sendBlockedNs + (getMonoTime() - t0).inNanoseconds
    ws.writeSyscalls = ws.writeSyscalls + 1
    if w <= 0:
      result = false
      cont = false
    else:
      off = off + w
  releaseWriteGuard(ws)

proc wsSend*(ws: WsConn; data: string; binary = false): bool {.passive.} =
  ## Send one data message (text by default, binary if `binary`). Header and
  ## payload are coalesced into the connection's reusable buffer and written
  ## in one pass.
  let op = if binary: opBinary else: opText
  result = writeSendBuf(ws, fillSendBuf(ws, op, data))
  if result:
    ws.bytesSent = ws.bytesSent + int64(data.len)

proc wsSend*(ws: WsConn; data: seq[byte]; binary = true): bool {.passive.} =
  ## Send one binary-payload data message, defaulting to binary. The bytes
  ## are coalesced with one `copyMem`, no seq→string copy at the send
  ## boundary. `seq[byte]`, not `openArray`: a `.passive` proc lifts its
  ## params into its CPS continuation environment, where a fat `openArray`
  ## pointer+length does not survive; a managed single-pointer `seq` does,
  ## like `string`.
  let op = if binary: opBinary else: opText
  result = writeSendBuf(ws, fillSendBuf(ws, op, data))
  if result:
    ws.bytesSent = ws.bytesSent + int64(data.len)

proc wsClose*(ws: WsConn; code = 1000; reason = ""): bool {.passive.} =
  ## Send a CLOSE frame and mark the connection closed. The handler should
  ## return after this; the driver closes the fd.
  ##
  ## Queued mode: the frame goes on the CONTROL lane — behind any control
  ## message already queued (an explanatory frame must reach the client
  ## first) but ahead of the STREAM lane, so a close never waits behind a
  ## data backlog.
  ws.open = false
  result = wsEmitCtl(ws, serializeFrame(opClose, closeFrameBody(code) & reason), lnControl)

# ── the keepalive ───────────────────────────────────────────────────────

const InboundIdle = -3
  ## `awaitInbound`'s answer when the idle close fired.

type KeepaliveStep = enum
  ksNone      ## nothing due
  ksPing      ## a keepalive PING is due
  ksIdle      ## the idle timeout has passed

proc recvNow(ws: WsConn): int =
  ## Non-blocking recv into `ws.rbuf`: the bytes read, 0 when the peer has
  ## closed, `ReadLater` when nothing has arrived, -1 on an error.
  result = ReadLater
  var done = false
  while not done:
    let n = pcall(cRecv(ws.fd, addr ws.rbuf[0], csize_t(ws.rbuf.len), MsgDontWait))
    if n >= 0:
      result = int(n)
      done = true
    elif n == -clong(EAGAIN): done = true
    elif n != -clong(EINTR):
      result = -1
      done = true

proc msLeft(since: int64; intervalMs: int; now: int64): int =
  ## Milliseconds from `now` until `intervalMs` after `since`, both
  ## monotonic ns; 0 or less once that has passed. Whole elapsed
  ## milliseconds only, so "passed" means at least `intervalMs` went by.
  let elapsedMs = (now - since) div 1_000_000'i64
  result = if elapsedMs >= int64(intervalMs): 0 else: intervalMs - int(elapsedMs)

proc keepaliveWaitMs(ws: WsConn; now: int64): int =
  ## How long a parked read may wait before its next keepalive step:
  ## the nearer of the next PING and the idle timeout, at most
  ## `MaxKeepalivePollMs`; -1 (no deadline) when both are off.
  let ping = gServerConfig.wsPingIntervalMs
  let idle = gServerConfig.wsIdleTimeoutMs
  if ping <= 0 and idle <= 0: return -1
  var cap = gServerConfig.wsKeepalivePollMs
  if cap <= 0 or cap > MaxKeepalivePollMs: cap = MaxKeepalivePollMs
  result = cap
  if ping > 0:
    result = min(result, max(0, msLeft(max(ws.lastInbound, ws.lastPingSent), ping, now)))
  if idle > 0:
    result = min(result, max(0, msLeft(ws.lastInbound, idle, now)))

proc keepaliveStep(ws: WsConn; now: int64): KeepaliveStep =
  ## What a timed-out wait owes: the idle close first, then a PING.
  let ping = gServerConfig.wsPingIntervalMs
  let idle = gServerConfig.wsIdleTimeoutMs
  if idle > 0 and msLeft(ws.lastInbound, idle, now) <= 0:
    result = ksIdle
  elif ping > 0 and msLeft(max(ws.lastInbound, ws.lastPingSent), ping, now) <= 0:
    result = ksPing
  else:
    result = ksNone

proc armWriteBackstop(ws: WsConn): bool =
  ## Before a control write of the reader's own that may wait on the write
  ## guard (direct mode), arm the reap deadline for when the idle close's
  ## backstop would fire: the idle timeout after the last inbound byte, plus
  ## `WsCloseGraceMs`, and never less than the grace from now. A writer
  ## stalled on a peer that stopped reading then cannot pin the reader past
  ## that. Only with `userTimeoutMs` at 0: otherwise `TCP_USER_TIMEOUT`
  ## already ends a stalled write, and unlike this deadline it does not
  ## cut off a slow peer that is still acknowledging. Arms nothing when the
  ## idle timeout is off, in queued mode (the write only enqueues), or when
  ## a deadline is already armed. True when it armed one, which the caller
  ## disarms once the write returns.
  result = false
  let idle = gServerConfig.wsIdleTimeoutMs
  if idle > 0 and gServerConfig.userTimeoutMs <= 0 and not ws.hasOutq and
     deadlineOf(ws.fd) == 0'i64:
    let graceNs = int64(WsCloseGraceMs) * 1_000_000'i64
    let idleNs = min(int64(idle), 1_000_000_000'i64) * 1_000_000'i64
    let now = getMonoTime().ticks
    setDeadline(ws.fd, max(ws.lastInbound + idleNs + graceNs, now + graceNs))
    result = true

proc readerEmit(ws: WsConn; frame: string; lane: WsLane;
                coalesce = false): bool {.passive.} =
  ## `wsEmitCtl` for a control frame the reader sends (PING, PONG, CLOSE),
  ## covered by `armWriteBackstop` while it waits and writes.
  let armed = armWriteBackstop(ws)
  result = wsEmitCtl(ws, frame, lane, coalesce)
  if armed: setDeadline(ws.fd, 0'i64)

proc keepalivePing(ws: WsConn): bool {.passive.} =
  ## Send a keepalive PING unless the connection is closing or the peer is
  ## part-way through a frame (`ws.acc` holds a partial one); false only when
  ## the write or the enqueue failed. In direct mode it waits its turn on the
  ## write guard; a PING stuck behind a writer stalled on a peer that stopped
  ## reading is cut off by `TCP_USER_TIMEOUT`, or, with `userTimeoutMs` at
  ## 0, by the reap backstop at idle + grace. In queued mode it goes on the
  ## CONTROL lane and does not coalesce, so it never evicts a PONG the peer
  ## is owed. The clock restarts either way, so a skipped PING is not
  ## retried at once.
  result = true
  ws.lastPingSent = getMonoTime().ticks
  if ws.open and ws.acc.len == 0:
    result = readerEmit(ws, serializeFrame(opPing, ""), lnControl)

proc idleClose(ws: WsConn): int {.passive.} =
  ## The idle timeout: arm the reap backstop (left armed; teardown's
  ## `clearConn` disarms it), mark the connection closed, then send CLOSE
  ## 1001 unless a CLOSE already went out. In direct mode the CLOSE waits
  ## its turn on the write guard; a writer stalled on a peer that stopped
  ## reading is cut off by the backstop or `TCP_USER_TIMEOUT`. Counts the
  ## close. Returns `InboundIdle`.
  setDeadline(ws.fd, getMonoTime().ticks + int64(WsCloseGraceMs) * 1_000_000'i64)
  let wasOpen = ws.open
  ws.open = false
  if wasOpen:
    discard wsEmitCtl(ws, serializeFrame(opClose, closeFrameBody(1001)), lnControl)
  countWsIdleClose()
  result = InboundIdle

proc awaitInbound(ws: WsConn): int {.passive.} =
  ## Read into `ws.rbuf`, parking while nothing has arrived, and run the
  ## keepalive while parked. Returns the bytes read, 0 when the peer has
  ## closed, -1 on an error, or `InboundIdle` once the idle close fired.
  ##
  ## Each park is a readiness wait with a deadline (`waitReadableUntil`),
  ## never a read with one: a buffer handed to the ring must not outlive the
  ## wait.
  result = recvNow(ws)
  while result == ReadLater:
    let wait = keepaliveWaitMs(ws, getMonoTime().ticks)
    let r = waitReadableUntil(ws.fd, wait)
    if r == IoTimedOut:
      let step = keepaliveStep(ws, getMonoTime().ticks)
      if step == ksIdle:
        # Bytes may have landed after the deadline; they win over the close.
        result = recvNow(ws)
        if result == ReadLater:
          result = idleClose(ws)
      elif step == ksPing:
        let sent = keepalivePing(ws)
        if not sent: result = -1
    elif r < 0:
      result = -1
    else:
      result = recvNow(ws)

proc recvMessage(ws: WsConn; blocking: bool): WsMessage {.passive.} =
  ## The receive loop behind `wsRecv` and `wsPeek`: parse frames from the
  ## inbound buffer, reading more when a frame is incomplete, until a
  ## complete data message or a close. Ping → pong and the close handshake
  ## are answered here; a protocol error sends the right close code and
  ## yields `wmClose`, with `ws.open` already false. The limits are the
  ## server config's.
  ##
  ## Every inbound byte, whichever call read it, restarts the keepalive
  ## clocks (`ws.lastInbound`). A `blocking` read parks until bytes arrive
  ## and meanwhile keeps the connection alive: once `wsPingIntervalMs` has
  ## passed since the later of the last inbound byte and the last PING, it
  ## sends a PING; once `wsIdleTimeoutMs` has passed with nothing inbound,
  ## it sends CLOSE 1001 and yields `wmClose`, with `ws.open` false. Only
  ## inbound bytes count: a successful write proves only that the kernel
  ## buffered it.
  ##
  ## A non-blocking read is a `MSG_DONTWAIT` recv: an empty socket yields
  ## `wmNone` instead of suspending, and it never pings or closes for
  ## idleness. A real recv error other than EAGAIN also yields `wmNone`
  ## there; it resurfaces on the next blocking send or recv.
  result = WsMessage(kind: wmClose, data: "")
  var done = false
  while not done:
    var f = default(Frame)
    let pr = parseFrame(ws.acc, 0, f, gServerConfig.maxWsPayload)
    if pr[0] == psIncomplete:
      var n = 0
      if blocking: n = awaitInbound(ws)
      else: n = recvNow(ws)
      if n == InboundIdle:
        result = WsMessage(kind: wmClose, data: "")
        done = true
      elif n == 0 or (n < 0 and blocking):
        ws.open = false
        result = WsMessage(kind: wmClose, data: "")
        done = true
      elif n < 0:
        result = WsMessage(kind: wmNone, data: "")
        done = true
      else:
        addInflight(n)
        appendBytes(ws.acc, addr ws.rbuf[0], n)
        ws.lastInbound = getMonoTime().ticks
    elif pr[0] == psError:
      discard readerEmit(ws, serializeFrame(opClose, closeFrameBody(1002)), lnControl)
      ws.open = false
      result = WsMessage(kind: wmClose, data: "")
      done = true
    else:
      # Consume the (masked) frame bytes before building the result — frees the
      # big inbound buffer first. Only `handleFrame`'s returned action is read
      # after this; `f` itself is not touched again.
      wsConsume(ws, pr[1])
      let before = assembledLen(ws.st)
      let act = handleFrame(ws.st, f, gServerConfig.maxWsMessage)
      countAssembled(ws, before)
      if act.kind == waPong:
        if not readerEmit(ws, serializeFrame(opPong, act.payload), lnUrgent, true):
          ws.open = false
          result = WsMessage(kind: wmClose, data: "")
          done = true
      elif act.kind == waMessage:
        let k = if act.opcode == opText: wmText else: wmBinary
        result = WsMessage(kind: k, data: act.payload)
        done = true
      elif act.kind == waClose:
        discard readerEmit(ws,
          serializeFrame(opClose, closeFrameBody(act.closeCode) & act.payload), lnControl)
        ws.open = false
        result = WsMessage(kind: wmClose, data: act.payload)
        done = true
      # waNone (buffered fragment / pong received): keep looping.

proc wsRecv*(ws: WsConn): WsMessage {.passive.} =
  ## Block until the next complete data message, or a close/EOF. On
  ## `wmClose`, `ws.open` is already false. While it waits it runs the
  ## keepalive (see `ServerConfig.wsPingIntervalMs` / `wsIdleTimeoutMs`):
  ## a quiet peer is pinged, and one silent past the idle timeout gets
  ## CLOSE 1001 and this returns `wmClose`. A message a prior `wsPeek`
  ## stashed on the connection is delivered (and cleared) before touching
  ## the socket, so a peeked-but-not-skipped message (e.g. a control message
  ## that arrived mid-stream) is returned here unchanged.
  if ws.hasPeeked:
    result = ws.peeked
    ws.hasPeeked = false
    ws.peeked = WsMessage(kind: wmNone, data: "")
  else:
    result = recvMessage(ws, true)

proc wsPeek*(ws: WsConn): WsMessage {.passive.} =
  ## Non-blocking look at the next complete data message: an empty socket
  ## yields `wmNone` (nothing complete buffered) instead of suspending. A
  ## pong reply can still suspend, under send backpressure or behind another
  ## task's frame. Bytes it reads restart the keepalive clocks like any
  ## inbound bytes, but it never pings or closes for idleness: only a parked
  ## `wsRecv` does. A complete data message is drained from the buffer and
  ## stashed on the connection: this call and every following `wsPeek`
  ## return it unchanged until `wsSkip` discards it or `wsRecv` delivers it.
  if ws.hasPeeked:
    result = ws.peeked
  else:
    result = recvMessage(ws, false)
    if result.kind == wmText or result.kind == wmBinary:
      ws.peeked = result
      ws.hasPeeked = true

proc wsSkip*(ws: WsConn) {.passive.} =
  ## Discard the message the immediately-preceding `wsPeek` stashed — the caller
  ## decided to act on it (e.g. a `cancel`) and does not want `wsRecv` to see it.
  ## A peeked message left un-skipped stays stashed for the next `wsRecv` to
  ## deliver (e.g. a mid-stream `reauth` the send loop must not swallow).
  ws.hasPeeked = false
  ws.peeked = WsMessage(kind: wmNone, data: "")
