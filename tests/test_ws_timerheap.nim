## The keepalive's timed polls keep the ring's timer heap bounded.
##
## `std/ioring` never deletes a timer entry when its op completes; a stale
## entry leaves the heap only when it reaches the top. A long-lived live
## entry at the top therefore holds back every stale entry behind it, so the
## heap holds every deadline armed since that entry was armed. The keepalive
## caps each wait at `MaxKeepalivePollMs` (here lowered through
## `wsKeepalivePollMs` to keep the run short), which caps how long any entry
## can sit at the top and so bounds the heap by the poll rate times the cap.
##
## The measurement needs one lane read by its own thread, so the pool's
## workers are stopped first and the main thread runs every task and polls
## the only lane in use. One connection receives a message every 10 ms (one
## timed poll each); a second stays silent, its poll the long-lived entry.
import std/[syncio, monotimes]
from std/posix/posix import close, write, pcall
import hashi/loop
import hashi/net
import hashi/http/config
import hashi/http/connreg
import hashi/ws/frame
import hashi/ws/protocol
import hashi/ws/session
import hashi/ws/session_io
from std/ioring/core/backend import gTimers, gSlots, gCancelInFlight, ioLane, len
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

var gDone = 0
var gMsgs = 0

proc serveOne(fd: cint) {.passive.} =
  let ws = newWsConn(fd, "")
  var running = true
  while running:
    let m = wsRecv(ws)
    if m.kind == wmClose: running = false
    else: gMsgs = gMsgs + 1
  subInflight(ws.acc.len)
  clearConn(fd)
  closeFd(fd)
  gDone = gDone + 1

proc heapLen(lane: int): int = gTimers[lane].len

proc liveEntries(lane: int; timersOnly: bool): int =
  ## Heap entries whose op is still in flight: the slot is in use and holds
  ## the generation the entry was armed for. `timersOnly` counts just the
  ## pure timers (`sleepMs` and the like) among them.
  result = 0
  var i = 0
  while i < gTimers[lane].a.len:
    let e = gTimers[lane].a[i]
    let si = e.slot.int
    if si >= 0 and si < gSlots[lane].slots.len:
      if gSlots[lane].slots[si].inUse and gSlots[lane].slots[si].gen == e.gen:
        if not timersOnly or gSlots[lane].slots[si].op.kind == opTimeout:
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
  gDone = 0
  gMsgs = 0
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
  let measured = gMsgs * 1000 div int(loadMs)
  # One more window with no load: every stale entry has expired by then.
  let t1 = nowMs()
  while nowMs() - t1 < CapMs + 200:
    workTurn()
  let after = heapLen(lane)
  let live = liveEntries(lane, false)
  let timers = liveEntries(lane, true)
  let conns = 2 - gDone
  section name
  echo "  ", measured, " polls/s; heap max ", maxHeap,
       " (bound ", Rate * CapMs * 3 div 2000, "); after the load: ", after,
       " entries, ", live, " live, ", timers, " timers, ", conns, " connections"
  check otherLanes(lane) == 0, "every timed op ran on the one lane"
  check measured * 2 >= Rate, "the load ran at about the rate (" & $measured & "/s)"
  check maxHeap * 2 >= measured * CapMs div 1000,
    "the polls were timed: stale entries built up behind the quiet connection"
  check maxHeap * 2000 <= 3 * Rate * CapMs, "heap length <= 1.5 x rate x cap"
  let budget = conns + timers
  check after <= budget, "after one window: one entry per parked connection"
  check live <= budget, "and every entry left is live"
  peerWrite(busy[1], clientFrame(opClose, closeFrameBody(1000)))
  peerWrite(quiet[1], clientFrame(opClose, closeFrameBody(1000)))
  let t2 = nowMs()
  while gDone < 2 and nowMs() - t2 < 3000:
    workTurn()
  check gDone == 2, "both connections closed"
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
