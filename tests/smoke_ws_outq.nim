## Outbound-queue SMOKE test — the writer loop over a REAL socket.
##
## `tests/test_ws_outq.nim` covers the locked queue state machine with no I/O.
## What it cannot show is the property the design actually exists for: that a
## control reply beats a deep stream backlog **on the wire**, where bytes already
## handed to the kernel can no longer be reordered. That needs a live fd, a
## running reactor, and the `.passive` writer.
##
## No listener and no `serve()` loop (a serve loop can't run in a unit test —
## see the note atop test_ws_multilistener.nim). Instead a `socketpair` gives a
## connected pair: the writer half is wrapped in a `WsConn` and driven by
## `wsWriterLoop` on the pool, while the main thread plays the client on the
## peer half and reads the frames back.
##
## `SO_SNDBUF` is deliberately tiny on the writer half. That is not a shortcut:
## it is the pacing lever the writer's doc-comment names. With a big kernel
## buffer the whole backlog would be accepted by the kernel before the control
## message was ever enqueued, and no queue could reorder it — small-buffer
## pacing is what keeps the backlog in the lane-aware queue.
##
## Named `smoke_*` rather than `test_*`: `tests/run` globs `test_*.nim`, and this
## one binds sockets' worth of real I/O and a worker pool. Run it explicitly:
##   ../nimony/bin/nimony c -r tests/smoke_ws_outq.nim

import std/syncio
from std/posix/posix import read, close
import hashi/loop
import hashi/log
import hashi/http/request     # ParseStatus (psOk / psIncomplete / psError)
import hashi/ws/frame
import hashi/ws/session
import hashi/ws/outq
import testkit

import hashi/ws/session_io    # wsSend / wsWriteAll
import hashi/ws/outq_writer   # the .passive writer

# ── raw POSIX bits the test needs and hashi does not wrap ────────────────────

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cSetsockopt(fd, level, optname: cint; optval: pointer; optlen: cuint): cint {.
  importc: "setsockopt", header: "<sys/socket.h>".}
proc cUsleep(usec: cuint): cint {.importc: "usleep", header: "<unistd.h>".}

const
  AfUnix = 1.cint
  SockStream = 1.cint
  SolSocket = 1.cint
  SoSndBuf = 7.cint

  SmallSndBuf = 2048
    ## Below the kernel floor (it clamps up to ~4 KB), which is the point: the
    ## writer must block in `waitWrite` after a few KB so the backlog stays in
    ## the queue where lanes mean something.
  PadTo = 1024
    ## Chunk payload size. Must exceed the socket buffer in aggregate, or the
    ## kernel swallows the whole backlog and there is nothing left to prioritise.

proc newPair(writerFd, peerFd: var cint): bool =
  ## Connected AF_UNIX pair. The writer half is non-blocking and reactor-owned;
  ## the peer half is non-blocking too so the reader can poll with a deadline
  ## instead of hanging the suite when a frame never arrives.
  var sv = default(array[2, cint])
  result = cSocketpair(AfUnix, SockStream, 0.cint, addr sv[0]) == 0
  if result:
    writerFd = sv[0]
    peerFd = sv[1]
    var sz = SmallSndBuf.cint
    discard cSetsockopt(writerFd, SolSocket, SoSndBuf, addr sz, cuint(sizeof(cint)))
    setNonBlocking(writerFd)
    setNonBlocking(peerFd)

proc readSome(fd: cint; wire: var string): int =
  ## One non-blocking read, appended to `wire`. <=0 means nothing right now.
  var buf = default(array[8192, byte])
  result = read(fd, addr buf[0], 8192)
  var i = 0
  while i < result:
    wire.add char(buf[i])
    i = i + 1

proc drainFor(fd: cint; wire: var string; ms: int) =
  ## Poll the peer for `ms` milliseconds, restarting the budget on every byte —
  ## so a slow writer is waited out but a finished one is not.
  var idle = 0
  while idle < ms:
    let n = readSome(fd, wire)
    if n > 0:
      idle = 0
    else:
      discard cUsleep(1000'u32)
      idle = idle + 1

proc settle(q: OutQueue; ms: int): int =
  ## Wait until the STREAM lane stops shrinking, i.e. the writer has drained what
  ## the socket would take and is parked in `waitWrite`. Returns the resting
  ## depth. Without this the overtaking test is worthless: enqueue a control
  ## message before the writer has run at all and it "wins" by default.
  result = queuedBytes(q)
  var idle = 0
  while idle < ms:
    discard cUsleep(1000'u32)
    let now = queuedBytes(q)
    if now == result:
      idle = idle + 1
    else:
      result = now
      idle = 0

proc padded(label: string): string =
  ## `label` followed by filler to PadTo bytes. The label stays a prefix so the
  ## reader can identify a chunk without carrying a side table.
  result = label
  while result.len < PadTo:
    result.add 'x'

proc hasPrefix(s, p: string): bool =
  result = s.len >= p.len
  var i = 0
  while result and i < p.len:
    if s[i] != p[i]: result = false
    i = i + 1

proc parseAll(wire: string; payloads: var seq[string]): bool =
  ## Split the accumulated wire bytes into complete server→client frames.
  ## False if a frame is malformed (a trailing partial frame is fine).
  result = true
  var off = 0
  var more = true
  while more:
    var f = default(Frame)
    let pr = parseFrame(wire, off, f)
    if pr[0] == psOk:
      payloads.add f.payload
      off = off + pr[1]
    else:
      if pr[0] == psError: result = false
      more = false

# ── A + B: a control reply overtakes a deep stream backlog, in order ─────────

initLoop()

section "control overtakes a deep stream backlog on the wire"
var wFd = 0.cint
var pFd = 0.cint
check newPair(wFd, pFd), "socketpair created"

let ws = newWsConn(wFd, "", "127.0.0.1")
# High enough that nothing is refused here — this section is about ORDER, not
# backpressure (which is section C's job).
let q = newOutQueue(highBytes = 4 * 1024 * 1024, lowBytes = 1024 * 1024)
useOutQueue(ws, q)
spawnTask wsWriterLoop(ws, q)

const ChunkCount = 100
var enqueued = 0
var i = 0
while i < ChunkCount:
  if wsEnqueue(q, lnStream, padded("chunk-" & $i & "|"), true, 1) == eqOk:
    enqueued = enqueued + 1
  i = i + 1
check enqueued == ChunkCount, "all " & $ChunkCount & " stream chunks queued"

# Let the writer run to a standstill FIRST. Nothing is read from the peer, so it
# fills the socket buffer and parks — leaving a real, deep backlog in the queue
# for the reply to overtake. Skipping this wait would let the reply "win" merely
# by being enqueued before the writer ever woke up.
let resting = settle(q, 60)
check resting > 0, "a real backlog is parked in the queue (" & $resting & " bytes)"
check resting < ChunkCount * PadTo,
      "and the writer genuinely ran — some chunks are already past the queue"
check wsEnqueue(q, lnControl, "series-reply", false) == eqOk, "control reply queued last"

var wire = ""
drainFor(pFd, wire, 400)
var msgs: seq[string] = @[]
check parseAll(wire, msgs), "wire parses as well-formed frames"

var ctlAt = -1
var j = 0
while j < msgs.len:
  if msgs[j] == "series-reply": ctlAt = j
  j = j + 1
check ctlAt >= 0, "control reply reached the wire"
# The chunks the kernel had already taken when the reply was queued cannot be
# reordered; how many that is depends on the kernel's socket accounting, not
# on hashi. What must hold is that the reply beat every chunk still parked in
# the queue: `settle` measured those, so the reply's index is the number of
# chunks that had left the queue, give or take the one mid-write.
let parked = resting div PadTo
check ctlAt >= 0 and ctlAt <= ChunkCount - parked + 1,
      "control reply overtook the parked backlog (arrived at index " & $ctlAt &
      " with " & $parked & " chunks parked)"

section "stream lane keeps enqueue order"
var seen = 0
var ordered = true
var k = 0
while k < msgs.len:
  if msgs[k] != "series-reply":
    if not hasPrefix(msgs[k], "chunk-" & $seen & "|"): ordered = false
    seen = seen + 1
  k = k + 1
check ordered, "chunk-0 .. chunk-" & $(seen - 1) & " arrived in order"
check seen > 10, "enough chunks observed to mean something (" & $seen & ")"

submitAll(closeQueue(q))
drainFor(pFd, wire, 50)
closeFd(wFd)
discard close(pFd)

# ── C: backpressure is bounded, distinguishable from close, and recovers ─────

section "backpressure returns eqFull (never eqClosed) and recovers"
var wFd2 = 0.cint
var pFd2 = 0.cint
check newPair(wFd2, pFd2), "socketpair created"

let ws2 = newWsConn(wFd2, "", "127.0.0.1")
let q2 = newOutQueue(highBytes = 4096, lowBytes = 1024)
useOutQueue(ws2, q2)
spawnTask wsWriterLoop(ws2, q2)

# Nothing is read from pFd2 here, so the writer parks in waitWrite once the
# socket buffer fills and the queue backs up to its high mark.
var res = eqOk
var pushed = 0
var n = 0
while n < 500 and res == eqOk:
  res = wsEnqueue(q2, lnStream, padded("fill-" & $n & "|"), true, 2)
  if res == eqOk: pushed = pushed + 1
  n = n + 1
check res == eqFull, "stream lane refused with eqFull after " & $pushed & " messages"
check res != eqClosed, "eqFull is NOT eqClosed — a slow client is not a dead one"
check not wsQueueClosed(q2), "a full queue is a healthy queue"
# `eqFull` is the proof the bound was hit; the depth read here races the
# writer, which may have popped a chunk since, so only the ceiling is exact.
check queuedBytes(q2) < 4096 + PadTo,
      "queue never exceeds its byte bound (" & $queuedBytes(q2) & " bytes)"

# Draining the peer lets the writer run again; the low mark then re-opens the lane.
var wire2 = ""
drainFor(pFd2, wire2, 400)
var recovered = false
var tries = 0
while tries < 200 and not recovered:
  if wsEnqueue(q2, lnStream, padded("after|"), true, 2) == eqOk:
    recovered = true
  else:
    discard cUsleep(5000'u32)
    drainFor(pFd2, wire2, 10)
  tries = tries + 1
check recovered, "enqueue succeeds again once the backlog drains"

submitAll(closeQueue(q2))
drainFor(pFd2, wire2, 100)
var msgs2: seq[string] = @[]
check parseAll(wire2, msgs2), "backpressure wire parses"
check msgs2.len > 0, "the backlog really was written, not dropped (" &
      $msgs2.len & " frames)"
closeFd(wFd2)
discard close(pFd2)

# ── D: a raw message is emitted verbatim ────────────────────────────────────

section "raw messages are emitted un-reframed"
var wFd3 = 0.cint
var pFd3 = 0.cint
check newPair(wFd3, pFd3), "socketpair created"

let ws3 = newWsConn(wFd3, "", "127.0.0.1")
let q3 = newOutQueue()
useOutQueue(ws3, q3)
spawnTask wsWriterLoop(ws3, q3)

# PONG is neither text nor binary, so `wsSend` cannot express it — `raw` is the
# only way a control opcode reaches the wire through the queue.
let pong = serializeFrame(opPong, "")
check wsEnqueue(q3, lnUrgent, pong, false, -1, true) == eqOk, "raw PONG queued"

var wire3 = ""
drainFor(pFd3, wire3, 300)
check wire3 == pong, "raw bytes appear verbatim (" & $wire3.len & " bytes, expected " &
      $pong.len & ")"
var f3 = default(Frame)
let pr3 = parseFrame(wire3, 0, f3)
check pr3[0] == psOk and f3.opcode == opPong, "and parse back as a PONG frame"

submitAll(closeQueue(q3))
closeFd(wFd3)
discard close(pFd3)

shutdownPool()
finish()
