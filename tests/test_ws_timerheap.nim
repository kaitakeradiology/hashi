## The ring's timer heap holds only the deadlines of ops still in flight.
##
## `std/ioring` drops a deadline's heap entry when its op completes
## (`disarmDeadline`), so however many timed polls the keepalive makes, the
## heap never holds more than one entry per op that is still waiting. Before
## that, a completed op's entry stayed until it reached the top, and a
## long-lived entry there held back every stale one behind it; the keepalive's
## `MaxKeepalivePollMs` cap was what bounded the heap. This test pins the
## stronger rule.
##
## The measurement needs one lane read by its own thread, so the pool's
## workers are stopped first and the main thread runs every task and polls
## the only lane in use. One connection receives a message every 10 ms (one
## timed poll each); a second stays silent, its poll the long-lived entry.
import std/[syncio, monotimes, atomics]
from std/posix/posix import close, write, pcall
import hashi/loop
import hashi/net
import hashi/http/config
import hashi/http/connreg
import hashi/ws/frame
import hashi/ws/protocol
import hashi/ws/session
import hashi/ws/session_io
from std/ioring/core/backend import gTimers, gCancelInFlight, ioLane, len
import std/ioring/core/slots
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
const AfUnix = 1.cint
const SockStream = 1.cint

const
  Rate = 100       ## timed polls per second on the busy connection
  CapMs = 1000     ## the keepalive wait cap for this run
  HeapBound = 4
    ## Each connection's timed poll, plus a timer apiece (a pending ping or
    ## close deadline): two connections never need more.

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

proc clientFrame(op: Opcode; payload: string): string =
  result = ""
  result.add char(0x80 or ord(op))
  result.add char(0x80 or payload.len)
  var k = 0
  while k < 4:
    result.add char(0)
    k = k + 1
  result.add payload

proc peerWrite(fd: cint; s: string) =
  discard pcall(write(fd, readRawData(s, 0), s.len))

var gDone = 0   # both: accessed atomically
var gMsgs = 0

proc serveOne(fd: cint) {.passive.} =
  let ws = newWsConn(fd, "")
  var running = true
  while running:
    let m = wsRecv(ws)
    if m.kind == wmClose: running = false
    else: atomicInc(gMsgs)
  subInflight(ws.acc.len)
  clearConn(fd)
  closeFd(fd)
  atomicInc(gDone)

proc heapLen(lane: int): int = gTimers[lane].len

proc timerEntries(lane: int): int =
  ## Heap entries for pure timers (`sleepMs` and the like).
  result = 0
  var i = 0
  while i < gTimers[lane].a.len:
    if gTimers[lane].a[i].slot.op.kind == opTimeout:
      result = result + 1
    i = i + 1

proc otherLanes(lane: int): int =
  result = 0
  var l = 0
  while l < gTimers.len:
    if l != lane: result = result + gTimers[l].len
    l = l + 1

proc newPair(): array[2, cint] =
  result = default(array[2, cint])
  if cSocketpair(AfUnix, SockStream, 0.cint, addr result[0]) != 0:
    echo "  socketpair failed"; quit(1)
  setNonBlocking(result[0])
  setNonBlocking(result[1])

proc runLoad(name: string; ping, idle: int) =
  var cfg = defaultServerConfig()
  cfg.wsPingIntervalMs = ping
  cfg.wsIdleTimeoutMs = idle
  cfg.wsKeepalivePollMs = CapMs
  setServerConfig(cfg)
  let lane = ioLane()
  atomicStore(gDone, 0, moRelease)
  atomicStore(gMsgs, 0, moRelease)
  let busy = newPair()
  let quiet = newPair()
  spawnTask serveOne(quiet[0])
  spawnTask serveOne(busy[0])
  let msg = clientFrame(opText, "x")
  # Two windows of load: a message every 1000/Rate ms on the busy connection.
  let t0 = nowMs()
  var lastSend = t0
  var maxHeap = 0
  var going = true
  while going:
    workTurn()
    let now = nowMs()
    if now - lastSend >= 1000 div Rate:
      peerWrite(busy[1], msg)
      lastSend = lastSend + 1000 div Rate
    let h = heapLen(lane)
    if h > maxHeap: maxHeap = h
    if now - t0 >= 2 * CapMs: going = false
  let loadMs = nowMs() - t0
  let measured = atomicLoad(gMsgs, moAcquire) * 1000 div int(loadMs)
  # One more window with no load: every stale entry has expired by then.
  let t1 = nowMs()
  while nowMs() - t1 < CapMs + 200:
    workTurn()
  let after = heapLen(lane)
  let timers = timerEntries(lane)
  let conns = 2 - atomicLoad(gDone, moAcquire)
  section name
  echo "  ", measured, " polls/s; heap max ", maxHeap, " (bound ", HeapBound,
       "); after the load: ", after, " entries, ", timers, " timers, ",
       conns, " connections"
  check otherLanes(lane) == 0, "every timed op ran on the one lane"
  check measured * 2 >= Rate, "the load ran at about the rate (" & $measured & "/s)"
  check maxHeap <= HeapBound,
    "a completed poll's entry left the heap: it never grew with the load"
  check after <= conns + timers, "after the load: one entry per parked connection"
  peerWrite(busy[1], clientFrame(opClose, closeFrameBody(1000)))
  peerWrite(quiet[1], clientFrame(opClose, closeFrameBody(1000)))
  let t2 = nowMs()
  while atomicLoad(gDone, moAcquire) < 2 and nowMs() - t2 < 3000:
    workTurn()
  check atomicLoad(gDone, moAcquire) == 2, "both connections closed"
  discard close(busy[1])
  discard close(quiet[1])

discard cAlarm(60.cuint)
ignoreSigpipe()
initLoop()
echo "  backend: ", (if gCancelInFlight != nil: "io_uring" else: "epoll")
# Stop the workers: from here on the main thread runs every task, so every op
# lands on its lane and the heap can be read without racing its owner.
shutdownPool()

runLoad("the default keepalive", 20_000, 60_000)
runLoad("pings off, a long idle timeout", 0, 600_000)

setServerConfig(defaultServerConfig())
finish()
