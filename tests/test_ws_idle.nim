## WebSocket keepalive: a blocking `wsRecv` pings a quiet peer and closes one
## that stays silent.
##
## The contract (`hashi/ws/session_io`'s `recvMessage`): while parked for
## inbound bytes, the read sends a PING once `wsPingIntervalMs` passes with
## nothing inbound and nothing pinged, and after `wsIdleTimeoutMs` with
## nothing inbound it sends CLOSE 1001 and returns `wmClose`. The clock is
## inbound-only, so a server streaming to a peer that never answers still
## closes it. WebSocket reads no longer use `idleTimeoutMs`: every scenario
## below runs the reaper with a 100 ms HTTP idle timeout, shorter than the
## WebSocket ones, and a connection it touched would show up as a close with
## no CLOSE frame.
##
## Each scenario runs one connection over a socketpair: the server half
## wrapped in a `WsConn` and driven on the pool, the client half played by
## the main thread with hashi's own frame parser.
import std/[syncio, monotimes, atomics]
from std/posix/posix import close, read, write, pcall
import hashi/loop
import hashi/net        # ignoreSigpipe
import hashi/buffer
import hashi/http/config
import hashi/http/connreg
import hashi/http/request    # ParseStatus
import hashi/ws/frame
import hashi/ws/protocol     # closeFrameBody
import hashi/ws/session
import hashi/ws/session_io
import hashi/ws/outq
import hashi/ws/outq_writer
from std/ioring/core/backend import gCancelInFlight   # which backend is live
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a handler that never returns fails the run instead of
  ## hanging it.
const AfUnix = 1.cint
const SockStream = 1.cint

const BigFrame = 256 * 1024
  ## Scenario (g)'s frame size: larger than the socketpair's buffer, so each
  ## frame is written in several parts with the writer parked in between.

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

# ── the client half ─────────────────────────────────────────────────────

proc clientFrame(op: Opcode; payload: string): string =
  ## A masked client frame. The mask key is zero, so the payload goes out
  ## as is; the server still sees MASK set, as RFC 6455 requires.
  result = ""
  result.add char(0x80 or ord(op))
  result.add char(0x80 or payload.len)
  var k = 0
  while k < 4:
    result.add char(0)
    k = k + 1
  result.add payload

proc peerWrite(fd: cint; s: string) =
  var off = 0
  var spins = 0
  while off < s.len and spins < 1000:
    let n = pcall(write(fd, readRawData(s, off), s.len - off))
    if n > 0: off = off + int(n)
    spins = spins + 1

type
  PeerMode = enum
    pmSilent        ## reads everything, sends nothing
    pmAnswerPings   ## reads everything, answers each PING with a PONG
    pmSendData      ## reads everything, sends a text message every 150 ms
    pmSlowReader    ## reads at most 16 KiB per turn, sends nothing

  Peer = object
    fd: cint
    acc: string
    pings, pongs, closes, data, bad: int
    closeCode: int
    pongPayload: string
    dataOk: bool            ## every data frame had the expected length and bytes
    firstOps: seq[Opcode]   ## the opcodes of the first frames, in order
    closeAtMs: int64        ## when the CLOSE frame was parsed
    eofAtMs: int64          ## when the read side hit EOF; 0 until then
    dataAfterClose: int     ## data frames that followed a CLOSE on the wire

template ld(v: untyped): untyped = atomicLoad(v, moAcquire)
template st(v, x: untyped) = atomicStore(v, x, moRelease)


proc checkBig(f: Frame): bool =
  ## Scenario (g)'s payload: byte j is j mod 251.
  result = f.payload.len == BigFrame
  if result:
    var j = 0
    while j < BigFrame and result:
      if f.payload[j] != char(j mod 251): result = false
      j = j + 4093
    if f.payload[BigFrame - 1] != char((BigFrame - 1) mod 251): result = false

proc pump(p: var Peer; mode: PeerMode) =
  ## Read what the server sent and parse every complete frame. Reads at
  ## most 1 MiB per call, so a server that writes as fast as the peer reads
  ## cannot keep the main thread from its own worker turns.
  var readBuf = default(array[65536, char])   # main thread only
  let cap = if mode == pmSlowReader: 16384 else: readBuf.len
  var budget = 1024 * 1024
  var more = true
  while more:
    let n = pcall(read(p.fd, addr readBuf[0], cap))
    if n > 0:
      appendBytes(p.acc, addr readBuf[0], int(n))
      budget = budget - int(n)
      if mode == pmSlowReader or budget <= 0: more = false
    else:
      if n == 0 and p.eofAtMs == 0: p.eofAtMs = nowMs()
      more = false
  var parsing = true
  while parsing:
    var f = default(Frame)
    let r = parseFrame(p.acc, 0, f, 1 shl 30)
    if r[0] == psOk:
      dropPrefix(p.acc, r[1])
      if p.firstOps.len < 16: p.firstOps.add f.opcode
      if f.masked: p.bad = p.bad + 1
      case f.opcode
      of opPing:
        p.pings = p.pings + 1
        if mode == pmAnswerPings: peerWrite(p.fd, clientFrame(opPong, f.payload))
      of opPong:
        p.pongs = p.pongs + 1
        p.pongPayload = f.payload
      of opClose:
        p.closes = p.closes + 1
        p.closeAtMs = nowMs()
        if f.payload.len >= 2:
          p.closeCode = (uint8(f.payload[0]).int shl 8) or uint8(f.payload[1]).int
      of opText, opBinary:
        p.data = p.data + 1
        if p.closes > 0: p.dataAfterClose = p.dataAfterClose + 1
        if f.payload.len == BigFrame and not checkBig(f): p.dataOk = false
      of opContinuation:
        p.bad = p.bad + 1
    elif r[0] == psError:
      p.bad = p.bad + 1
      p.acc = ""
      parsing = false
    else:
      parsing = false

# ── the server half ─────────────────────────────────────────────────────

var gDone = false        # the handler has returned
var gKind = -1           # what its last wsRecv returned
var gOpen = true         # ws.open once that wsRecv returned
var gMsgs = 0            # data messages the handler received
var gLastMsg = ""        # the last one's payload
var gEndMs = 0'i64       # when wsRecv returned wmClose
var gStreamed = 0        # frames the streaming task sent
var gStreamDone = true
var gUrgent = -1         # queued mode: URGENT-lane messages at close
var gControl = -1        # queued mode: CONTROL-lane messages at close

proc payloadFor(big, steady: bool): string =
  if steady:
    result = newString(16 * 1024)
  elif big:
    result = newString(BigFrame)
    var j = 0
    while j < BigFrame:
      result[j] = char(j mod 251)
      j = j + 1
  else:
    result = newString(1024)

var gStubborn = false    # the writers ignore ws.open and stop only on a refused write
var gSendFalseMs = 0'i64 # when the streaming task's wsSend first returned false
var gRawFalseMs = 0'i64  # likewise the raw writer's wsWriteAll

proc streamTask(ws: WsConn; big, steady: bool) {.passive.} =
  ## A second task writing to the connection while its handler is parked in
  ## `wsRecv`.
  let payload = payloadFor(big, steady)
  var going = true
  while going:
    let ok = wsSend(ws, payload, true)
    if ok: atomicInc(gStreamed)
    else:
      st(gSendFalseMs, nowMs())
      going = false
    if not steady:
      let nap = if big: 10 else: 5
      sleepMs(nap)
    if not ld(gStubborn) and not ws.open: going = false
  st(gStreamDone, true)

proc drainQueue(ws: WsConn; q: OutQueue) {.passive.} =
  ## Queued mode's teardown: run the writer until the queue drains.
  spawnTask wsWriterLoop(ws, q)
  submitAll(closeQueue(q))
  wsAwaitWriterDone(q)

var gRawDone = true

proc rawStreamTask(ws: WsConn) {.passive.} =
  ## A second writer on the same connection, sending whole pre-serialized
  ## data frames through `wsWriteAll` (its own buffer, not `ws.sbuf`).
  let frame = serializeFrame(opBinary, newString(8 * 1024))
  var going = true
  while going:
    let ok = wsWriteAll(ws, frame)
    if not ok:
      st(gRawFalseMs, nowMs())
      going = false
    if not ld(gStubborn) and not ws.open: going = false
  st(gRawDone, true)

proc serveOne(fd: cint; queued, stream, big, steady, dual, closeOnText: bool) {.passive.} =
  ## The driver-shaped task: one connection, the handler's `wsRecv` loop,
  ## and teardown as `upgradeToWs`/`handleConn` do it.
  let ws = newWsConn(fd, "")
  let q = newOutQueue()
  if queued: useOutQueue(ws, q)
  if stream:
    st(gStreamDone, false)
    spawnTask streamTask(ws, big, steady)
  if dual:
    st(gRawDone, false)
    spawnTask rawStreamTask(ws)
  var running = true
  while running:
    let m = wsRecv(ws)
    if m.kind == wmClose:
      st(gKind, m.kind.int)
      st(gOpen, ws.open)
      st(gEndMs, nowMs())
      running = false
    elif closeOnText:
      st(gKind, m.kind.int)
      discard wsClose(ws, 1000)
      st(gEndMs, nowMs())
      running = false
    else:
      atomicInc(gMsgs)
      {.cast(assumeSync).}:   # written only here, read by the main thread after ld(gDone)
        gLastMsg = m.data
  ws.open = false
  while not ld(gStreamDone): sleepMs(5)
  while not ld(gRawDone): sleepMs(5)
  if queued:
    st(gUrgent, queuedCount(q, lnUrgent))
    st(gControl, queuedCount(q, lnControl))
    drainQueue(ws, q)
  subInflight(ws.acc.len)
  clearConn(fd)
  closeFd(fd)
  st(gDone, true)

# ── one scenario ────────────────────────────────────────────────────────

proc start(p: var Peer; ping, idle: int; queued = false; stream = false;
           big = false; steady = false; dual = false; closeOnText = false;
           stubborn = false): int64 =
  ## Configure, open a socketpair and start the server half on it. Returns
  ## the start time in ms.
  var cfg = defaultServerConfig()
  cfg.idleTimeoutMs = 100
  cfg.wsPingIntervalMs = ping
  cfg.wsIdleTimeoutMs = idle
  setServerConfig(cfg)
  var sv = default(array[2, cint])
  if cSocketpair(AfUnix, SockStream, 0.cint, addr sv[0]) != 0:
    echo "  socketpair failed"; quit(1)
  setNonBlocking(sv[0])
  setNonBlocking(sv[1])
  p = Peer(fd: sv[1], acc: "", pings: 0, pongs: 0, closes: 0, data: 0, bad: 0,
           closeCode: 0, pongPayload: "", dataOk: true, firstOps: @[],
           closeAtMs: 0, eofAtMs: 0, dataAfterClose: 0)
  st(gDone, false); st(gKind, -1); st(gOpen, true); st(gMsgs, 0); st(gEndMs, 0'i64)
  {.cast(assumeSync).}:   # no task of the previous scenario is running
    gLastMsg = ""
  st(gStreamed, 0); st(gUrgent, -1); st(gControl, -1)
  result = nowMs()
  st(gStubborn, stubborn)
  st(gSendFalseMs, 0)
  st(gRawFalseMs, 0)
  spawnTask serveOne(sv[0], queued, stream, big, steady, dual, closeOnText)

proc drive(p: var Peer; mode: PeerMode; forMs: int; untilDone: bool) =
  ## Take worker turns, play the peer and sweep the reaper, for `forMs` or
  ## until the handler returns.
  let t0 = nowMs()
  var lastData = t0
  var lastReap = t0
  var going = true
  while going:
    workTurn()
    pump(p, mode)
    let now = nowMs()
    if mode == pmSendData and now - lastData >= 150:
      peerWrite(p.fd, clientFrame(opText, "x"))
      lastData = now
    if now - lastReap >= 20:
      discard reapExpired(getMonoTime().ticks)
      lastReap = now
    if untilDone and ld(gDone): going = false
    if now - t0 >= forMs: going = false
  pump(p, mode)

proc finishPeer(p: var Peer; mode: PeerMode) =
  ## Close from the client side and wait for the handler to return.
  peerWrite(p.fd, clientFrame(opClose, closeFrameBody(1000)))
  drive(p, mode, 3000, true)
  discard close(p.fd)

# ── scenarios ───────────────────────────────────────────────────────────

discard cAlarm(90.cuint)
ignoreSigpipe()
initLoop()
echo "  backend: ", (if gCancelInFlight != nil: "io_uring" else: "epoll")
let base = inflightBytes()

section "(a) a silent peer is pinged, then closed with 1001"
block:
  var p = default(Peer)
  let idle0 = wsIdleClosedTotal()
  let t0 = start(p, 50, 200)
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  let took = ld(gEndMs) - t0
  check ld(gDone), "the handler returned"
  check ld(gKind) == wmClose.int, "wsRecv returned wmClose"
  check not ld(gOpen), "the connection is marked closed"
  check p.pings >= 2 and p.pings <= 4, "the peer saw 2-4 pings, not a flood (saw " & $p.pings & ")"
  check p.closes == 1 and p.closeCode == 1001, "the peer got CLOSE 1001 (code " & $p.closeCode & ")"
  check took >= 150 and took < 1000, "closed at the idle timeout (" & $took & " ms)"
  check wsIdleClosedTotal() == idle0 + 1, "counted as a WebSocket idle close"
  check p.bad == 0, "every frame parsed"

section "(b) a peer that answers pings stays open"
block:
  var p = default(Peer)
  discard start(p, 50, 200)
  drive(p, pmAnswerPings, 700, false)
  check not ld(gDone), "still open after 3x the idle timeout"
  check p.pings >= 3, "pinged and answered (" & $p.pings & " pings)"
  check p.closes == 0, "no CLOSE sent"
  finishPeer(p, pmAnswerPings)
  check ld(gDone) and ld(gKind) == wmClose.int, "the client's close ends it"
  check p.closes == 1 and p.closeCode == 1000, "the close was echoed"

section "(c) a peer sending data stays open"
block:
  var p = default(Peer)
  discard start(p, 50, 200)
  drive(p, pmSendData, 700, false)
  check not ld(gDone), "still open after 3x the idle timeout"
  check ld(gMsgs) >= 3, "the handler got the messages (" & $ld(gMsgs) & ")"
  check p.closes == 0, "no CLOSE sent"
  finishPeer(p, pmSendData)
  check ld(gDone), "the client's close ends it"

section "(d) streaming to a silent peer still closes at idle"
block:
  var p = default(Peer)
  let idle0 = wsIdleClosedTotal()
  let t0 = start(p, 50, 200, stream = true)
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  let took = ld(gEndMs) - t0
  check ld(gDone), "the handler returned"
  check ld(gKind) == wmClose.int, "wsRecv returned wmClose"
  check p.data >= 5, "the stream was flowing (" & $p.data & " frames)"
  check took >= 150 and took < 1000, "closed at the idle timeout (" & $took & " ms)"
  check wsIdleClosedTotal() == idle0 + 1, "counted as a WebSocket idle close"
  check p.bad == 0, "every frame parsed"

section "(e) zero turns pings or the idle close off"
block:
  var p = default(Peer)
  let idle0 = wsIdleClosedTotal()
  let t0 = start(p, 0, 200)
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  let took = ld(gEndMs) - t0
  check p.pings == 0, "ping 0: no pings (" & $p.pings & ")"
  check p.closes == 1 and p.closeCode == 1001, "ping 0: still closed with 1001 at idle"
  check took >= 150 and took < 1000, "ping 0: closed at the idle timeout (" & $took & " ms)"
  check wsIdleClosedTotal() == idle0 + 1, "ping 0: counted"
block:
  var p = default(Peer)
  discard start(p, 50, 0)
  drive(p, pmSilent, 1000, false)
  check not ld(gDone), "idle 0: a silent peer is never closed"
  check p.pings >= 10 and p.pings <= 25, "idle 0: pings keep coming, about one per interval (" & $p.pings & ")"
  check p.closes == 0, "idle 0: no CLOSE"
  finishPeer(p, pmSilent)
  check ld(gDone), "idle 0: the client's close ends it"
block:
  var p = default(Peer)
  discard start(p, 0, 0)
  drive(p, pmSilent, 1000, false)
  check not ld(gDone), "both 0: never closed"
  check p.pings == 0 and p.closes == 0, "both 0: nothing sent"
  finishPeer(p, pmSilent)
  check ld(gDone), "both 0: the client's close ends it"

section "(f) direct mode: a pong and then the app's close"
block:
  var p = default(Peer)
  let t0 = start(p, 50, 200, closeOnText = true)
  peerWrite(p.fd, clientFrame(opPing, "hi") & clientFrame(opText, "bye"))
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  check ld(gDone), "the handler returned (no deadlock)"
  check ld(gKind) == wmText.int, "the handler got the text"
  check p.pongs == 1 and p.pongPayload == "hi", "the ping was answered"
  check p.closes == 1 and p.closeCode == 1000, "the app's close went out"
  check ld(gEndMs) - t0 < 150, "both writes went out at once"

section "(g) direct mode: pings never land inside a streamed frame"
block:
  var p = default(Peer)
  discard start(p, 20, 0, stream = true, big = true)
  drive(p, pmSlowReader, 1500, false)
  check p.pings >= 3, "reader pings fired while streaming (" & $p.pings & ")"
  check p.data >= 3, "large frames went out (" & $p.data & ")"
  peerWrite(p.fd, clientFrame(opClose, closeFrameBody(1000)))
  drive(p, pmSlowReader, 5000, true)
  discard close(p.fd)
  check ld(gDone), "the handler returned"
  check p.bad == 0, "every frame the peer received parsed"
  check p.dataOk, "every data frame arrived whole and in order"

section "(h) queued mode: a ping does not evict a queued pong"
block:
  var p = default(Peer)
  let t0 = start(p, 50, 200, queued = true)
  peerWrite(p.fd, clientFrame(opPing, "p1"))
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  check ld(gDone), "the handler returned"
  check ld(gUrgent) == 1, "the PONG was still queued at close (" & $ld(gUrgent) & ")"
  check ld(gControl) >= 3, "pings and the CLOSE queued behind it (" & $ld(gControl) & ")"
  check p.pongs == 1 and p.pongPayload == "p1", "the PONG reached the peer"
  check p.pings >= 2, "so did the pings (" & $p.pings & ")"
  check p.closes == 1 and p.closeCode == 1001, "and the CLOSE 1001"
  check p.firstOps.len > 0 and p.firstOps[0] == opPong, "the PONG went first"
  check ld(gEndMs) - t0 >= 150, "closed at the idle timeout"

section "(i) no ping while the peer is part-way through a frame"
block:
  var p = default(Peer)
  discard start(p, 50, 400)
  let whole = clientFrame(opText, "hello, keepalive")
  peerWrite(p.fd, substr(whole, 0, 8))          # the header and 3 payload bytes
  drive(p, pmSilent, 250, false)
  check p.pings == 0, "no ping during a 250 ms pause mid-frame (" & $p.pings & ")"
  check not ld(gDone), "still open"
  let before = p.pings
  peerWrite(p.fd, substr(whole, 9))
  drive(p, pmSilent, 200, false)
  var lastMsg = ""
  {.cast(assumeSync).}:   # the handler has returned (ld(gDone) above)
    lastMsg = gLastMsg
  check ld(gMsgs) == 1 and lastMsg == "hello, keepalive", "the message arrived intact"
  check p.pings - before >= 2, "pings resumed once the frame was complete (" & $(p.pings - before) & ")"
  check p.bad == 0, "every frame parsed"
  finishPeer(p, pmSilent)
  check ld(gDone), "the client's close ends it"
block:
  var p = default(Peer)
  let idle0 = wsIdleClosedTotal()
  let t0 = start(p, 50, 400)
  peerWrite(p.fd, substr(clientFrame(opText, "never finished"), 0, 8))
  drive(p, pmSilent, 3000, true)
  discard close(p.fd)
  let took = ld(gEndMs) - t0
  check ld(gDone) and ld(gKind) == wmClose.int, "a peer stalled mid-frame is closed"
  check p.pings == 0, "and never pinged (" & $p.pings & ")"
  check p.closes == 1 and p.closeCode == 1001, "with CLOSE 1001"
  check took >= 350 and took < 1500, "at the idle timeout (" & $took & " ms)"
  check wsIdleClosedTotal() == idle0 + 1, "counted as a WebSocket idle close"

section "(j) direct mode: a saturating writer does not starve the keepalive"
block:
  var p = default(Peer)
  discard start(p, 100, 400, stream = true, steady = true)
  drive(p, pmAnswerPings, 1000, false)
  check p.pings >= 3, "at least 3 pings in 1 s while the writer streams (" & $p.pings & ")"
  drive(p, pmAnswerPings, 300, false)
  check not ld(gDone), "still open at 3x the idle timeout"
  check p.closes == 0, "no CLOSE sent"
  check p.data >= 10, "the stream kept flowing (" & $p.data & " frames)"
  check p.bad == 0, "every frame parsed"
  let tc = nowMs()
  let parks0 = wsGuardParksTotal()
  finishPeer(p, pmAnswerPings)
  echo "  close handshake: handler done after ", nowMs() - tc, " ms, ",
       wsGuardParksTotal() - parks0, " guard parks"
  check ld(gDone), "the client's close ends it"
  check p.closes == 1 and p.closeCode == 1000, "the close was echoed"
  check p.dataAfterClose == 0, "no data frame followed the CLOSE"

section "(k) direct mode: the idle CLOSE gets past a saturating writer"
block:
  var p = default(Peer)
  let idle0 = wsIdleClosedTotal()
  let t0 = start(p, 100, 400, stream = true, steady = true)
  drive(p, pmSilent, 8000, true)
  drive(p, pmSilent, 200, false)       # read up to the EOF teardown leaves
  discard close(p.fd)
  let closeAt = p.closeAtMs - t0
  let eofAt = p.eofAtMs - t0
  check p.closes == 1 and p.closeCode == 1001, "a CLOSE 1001 arrived (code " & $p.closeCode & ")"
  check p.closeAtMs > 0 and closeAt >= 350 and closeAt < 1500, "at about the idle timeout (" & $closeAt & " ms)"
  check p.eofAtMs > 0 and p.closeAtMs > 0 and p.closeAtMs <= p.eofAtMs, "before the EOF (" & $eofAt & " ms)"
  check ld(gDone) and eofAt <= 400 + WsCloseGraceMs + 500, "torn down within idle + the close grace"
  check wsIdleClosedTotal() == idle0 + 1, "counted as a WebSocket idle close"
  check p.bad == 0, "every frame parsed"
  check p.dataAfterClose == 0, "no data frame followed the CLOSE"

section "(l) two writers that ignore ws.open: nothing follows the idle CLOSE"
block:
  # Both writers keep sending until a write is refused, so each is certain
  # to try a data frame after the CLOSE has gone out.
  var p = default(Peer)
  let t0 = start(p, 100, 400, stream = true, steady = true, dual = true,
                 stubborn = true)
  drive(p, pmSilent, 8000, true)
  drive(p, pmSilent, 200, false)
  discard close(p.fd)
  let closeAt = p.closeAtMs - t0
  let sendAt = ld(gSendFalseMs) - t0
  let rawAt = ld(gRawFalseMs) - t0
  check ld(gDone), "the handler and both writers finished"
  check p.closes == 1 and p.closeCode == 1001, "a CLOSE 1001 arrived (code " & $p.closeCode & ")"
  check p.closeAtMs > 0 and closeAt < 1500, "at about the idle timeout (" & $closeAt & " ms)"
  check p.dataAfterClose == 0, "no data frame followed the CLOSE (" & $p.dataAfterClose & ")"
  check ld(gSendFalseMs) > 0 and sendAt < 1500, "wsSend returned false at the CLOSE, not at the backstop (" & $sendAt & " ms)"
  check ld(gRawFalseMs) > 0 and rawAt < 1500, "so did wsWriteAll (" & $rawAt & " ms)"
  check p.bad == 0, "every frame parsed"

section "teardown"
setServerConfig(defaultServerConfig())
check inflightBytes() == base, "teardown released every buffered byte"

finish()
