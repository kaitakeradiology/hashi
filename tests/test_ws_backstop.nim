## A WebSocket whose peer stops reading is torn down by the kernel, and the
## task waiting on the write guard meanwhile parks with a capped backoff.
##
## Over a loopback TCP pair (an AF_UNIX pair has no `TCP_USER_TIMEOUT`): the
## peer shrinks its receive buffer, never reads and keeps sending PINGs; a
## server task streams large frames into the zero window, so it holds the
## direct-mode write guard parked in `waitWrite`, and the reader's PONG waits
## for the guard. `TCP_USER_TIMEOUT` (the kernel's write-side dead-peer
## detection) must abort the connection, after which both tasks see the write
## fail and the handler returns. Meanwhile the guard waiter wakes at most
## about 20 times a second, its backoff cap.
##
## With `TCP_USER_TIMEOUT` off the kernel never gives up, so the reaper must:
## a silent peer that stops reading, while the reader's keepalive PING waits
## behind the stalled writer, is shut down by the backstop the PING arms, at
## the idle timeout plus the close grace.
import std/[syncio, monotimes]
from std/posix/posix import close, write, pcall, SockLen, Sockaddr_storage
import hashi/loop
import hashi/net
import hashi/http/config
import hashi/http/connreg
import hashi/ws/frame
import hashi/ws/session
import hashi/ws/session_io
from std/ioring/core/backend import gCancelInFlight   # which backend is live
import testkit

proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cSetsockopt(fd, level, optname: cint; optval: pointer; optlen: SockLen): cint {.
  importc: "setsockopt", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cAccept(fd: cint; sa: nil pointer; len: nil pointer): cint {.importc: "accept", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
const AfInet = 2.cint
const SockStream = 1.cint
const SolSocket = 1.cint
const SoRcvBuf = 8.cint

const
  UserTimeoutMs = 500     ## the first scenario's; the second runs with it off
  IdleMs = 400
  PingMs = 100
  ReapMs = 50
  CloseGraceMs = 5000     ## the idle close's reap backstop
  FrameBytes = 64 * 1024

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

proc clientPing(): string =
  ## A masked, empty client PING.
  result = ""
  result.add char(0x80 or ord(opPing))
  result.add char(0x80)
  var k = 0
  while k < 4:
    result.add char(0)
    k = k + 1

var gDone = false
var gEndMs = 0'i64
var gStreamDone = false
var gSent = 0

proc streamTask(ws: WsConn) {.passive.} =
  let payload = newString(FrameBytes)
  var going = true
  while going:
    let ok = wsSend(ws, payload, true)
    if ok: gSent = gSent + 1
    else: going = false
    if not ws.open: going = false
  gStreamDone = true

proc serveOne(fd: cint) {.passive.} =
  let ws = newWsConn(fd, "")
  spawnTask streamTask(ws)
  var running = true
  while running:
    let m = wsRecv(ws)
    if m.kind == wmClose: running = false
  gEndMs = nowMs()
  ws.open = false
  while not gStreamDone: sleepMs(5)
  subInflight(ws.acc.len)
  clearConn(fd)
  closeFd(fd)
  gDone = true

type Outcome = object
  done: bool
  took: int64       ## ms from the start to the handler's wsRecv returning
  parks3s: int64    ## guard parks in the first 3 s, or until the end
  sent: int
  armedEarly: bool  ## a reap deadline was armed on the fd before the idle timeout

proc runPair(userTimeoutMs: int; peerPings: bool): Outcome =
  ## One loopback connection: a peer with a 4 KiB receive buffer that never
  ## reads (and, if `peerPings`, sends a PING every 50 ms), a server task
  ## streaming into its zero window, and the reaper swept every `ReapMs`.
  var cfg = defaultServerConfig()
  cfg.userTimeoutMs = userTimeoutMs
  cfg.wsIdleTimeoutMs = IdleMs
  cfg.wsPingIntervalMs = PingMs
  cfg.reapIntervalMs = ReapMs
  setServerConfig(cfg)
  gDone = false
  gEndMs = 0
  gStreamDone = false
  gSent = 0
  let lr = tryListenTcp(0'u16, bindAddr = "127.0.0.1")
  if not lr.ok:
    echo "  listen failed"; quit(1)
  let port = boundPort(lr.fd)
  let peer = cSocket(AfInet, SockStream, 0.cint)
  var rcv: cint = 4096
  discard cSetsockopt(peer, SolSocket, SoRcvBuf, addr rcv, SockLen(sizeof(rcv)))
  var sa = default(Sockaddr_storage)
  var saLen = SockLen(0)
  loopbackAddr(sa, saLen, port)
  if cConnect(peer, addr sa, saLen) != 0:
    echo "  connect failed"; quit(1)
  var srv = -1.cint
  var tries = 0
  while srv < 0 and tries < 1000:
    srv = cAccept(lr.fd, nil, nil)
    tries = tries + 1
  if srv < 0:
    echo "  accept failed"; quit(1)
  discard close(lr.fd)
  setNonBlocking(srv)
  setNonBlocking(peer)
  setNoDelay(srv)
  # What the acceptor applies to every connection.
  setKeepalive(srv, cfg.keepaliveIdleSec, cfg.keepaliveIntvlSec, cfg.keepaliveCnt,
               cfg.userTimeoutMs)
  let parks0 = wsGuardParksTotal()
  var parks3s = -1'i64
  let t0 = nowMs()
  spawnTask serveOne(srv)
  var lastPing = t0
  var lastReap = t0
  var going = true
  var armedEarly = false
  let ping = clientPing()
  while going:
    workTurn()
    let now = nowMs()
    if now - t0 < IdleMs and deadlineOf(srv) != 0'i64: armedEarly = true
    if peerPings and now - lastPing >= 50:
      discard pcall(write(peer, readRawData(ping, 0), ping.len))
      lastPing = now
    if now - lastReap >= ReapMs:
      discard reapExpired(getMonoTime().ticks)
      lastReap = now
    if parks3s < 0 and (gDone or now - t0 >= 3000):
      parks3s = wsGuardParksTotal() - parks0
    if gDone or now - t0 >= 10_000: going = false
  discard close(peer)
  result = Outcome(done: gDone, took: gEndMs - t0, parks3s: parks3s, sent: gSent,
                   armedEarly: armedEarly)

discard cAlarm(40.cuint)
ignoreSigpipe()
initLoop()
echo "  backend: ", (if gCancelInFlight != nil: "io_uring" else: "epoll")

section "a peer that stops reading is torn down by TCP_USER_TIMEOUT"
block:
  let o = runPair(UserTimeoutMs, true)
  let bound = UserTimeoutMs + IdleMs + CloseGraceMs + ReapMs
  echo "  torn down after ", o.took, " ms (bound ", bound, "); ", o.sent,
       " frames sent; guard waiter woke ", o.parks3s, " times in the first 3 s"
  check o.done, "the handler returned"
  check o.done and o.took <= bound, "torn down within userTimeout + idle + grace + one reap interval"
  check o.parks3s > 0, "the reader's PONG waited on the write guard"
  check not o.armedEarly, "with TCP_USER_TIMEOUT on, the reader arms no write backstop"
  check o.parks3s <= 3 * 20 + 10, "the guard waiter's wakeups over 3 s stay near the 50 ms backoff cap"
  check o.parks3s <= min(o.took, 3000) * 20 div 1000 + 10,
        "about 20 a second at most, for as long as the stall lasted"

section "with TCP_USER_TIMEOUT off, a ping stuck behind the writer is reaped"
block:
  let o = runPair(0, false)
  # The reaper shuts the socket at idle + grace, give or take one sweep; the
  # unwind after that costs at most one 50 ms guard park and the handler's
  # wait for the writer.
  let bound = IdleMs + CloseGraceMs + ReapMs
  let unwind = 150
  echo "  torn down after ", o.took, " ms (bound ", bound, " + ", unwind,
       " for the unwind); ", o.sent, " frames sent; guard waiter woke ",
       o.parks3s, " times in the first 3 s"
  check o.done, "the handler returned"
  check o.armedEarly, "the reader armed the write backstop while its PING waited"
  check o.done and o.took <= bound + unwind, "torn down within idle + grace + one reap interval"
  check o.done and o.took >= IdleMs + CloseGraceMs - 100, "by the backstop, not earlier"
  check o.parks3s > 0, "the PING waited on the write guard"
  check o.parks3s <= 3 * 20 + 10, "the guard waiter's wakeups over 3 s stay near the 50 ms backoff cap"

setServerConfig(defaultServerConfig())
finish()
