## The idle reaper covers WebSocket reads, not just HTTP heads and bodies.
##
## `hashi/ws/session_io`'s blocking read must arm the connection's reap
## deadline for the duration of the wait (as the HTTP driver's `waitFill`
## does), or `idleTimeoutMs` leaves upgraded sockets unwatched and a silent
## peer holds its connection — and its buffered bytes — forever. Over a
## socketpair: a peer that sends a fragment and goes silent is closed by
## `reapExpired`, and its buffered bytes are counted until teardown frees
## them.
import std/[syncio, monotimes]
from std/posix/posix import close
from std/posix/posix import write   # the raw socket write, not syncio's
import hashi/loop
import hashi/net
import hashi/http/config
import hashi/http/connreg
import hashi/ws/session
import hashi/ws/session_io
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a read that never completes fails the run instead of
  ## hanging it.
const AfUnix = 1.cint
const SockStream = 1.cint

var gKind = -1        # the WsMsgKind wsRecv returned, once it returns
var gOpen = true      # what the handler saw as the connection's state
var gBufBytes = -1    # inflightBytes() while the fragment sat undecoded
var gBase = 0'i64     # inflightBytes() before the connection existed
var gDone = false

proc silentPeer() {.passive.} =
  ## The driver-shaped task: one connection, one `wsRecv`, teardown exactly
  ## as `upgradeToWs`/`handleConn` do it.
  var sv = default(array[2, cint])
  if cSocketpair(AfUnix, SockStream, 0.cint, addr sv[0]) != 0:
    echo "  socketpair failed"; quit(1)
  setNonBlocking(sv[0])
  setNonBlocking(sv[1])
  gBase = inflightBytes()
  let ws = newWsConn(sv[0], "")
  var frag = default(array[3, char])   # a head no further bytes will finish
  frag[0] = 'a'; frag[1] = 'b'; frag[2] = 'c'
  discard write(sv[1], addr frag[0], 3)
  let m = wsRecv(ws)
  gKind = m.kind.int
  gOpen = ws.open
  gBufBytes = inflightBytes()
  subInflight(ws.acc.len)          # what the driver's teardown does
  discard close(sv[0])
  discard close(sv[1])
  gDone = true

section "an idle WebSocket read is armed for the reaper"
var cfg = defaultServerConfig()
cfg.idleTimeoutMs = 200
setServerConfig(cfg)
initLoop()
discard cAlarm(15.cuint)
let t0 = getMonoTime().ticks
spawnTask silentPeer()
var turns = 0
while not gDone and turns < 3000:
  discard workTurn()
  if getMonoTime().ticks - t0 > 300_000_000'i64:
    discard reapExpired(getMonoTime().ticks + 1_000_000_000'i64)
  turns = turns + 1
setServerConfig(defaultServerConfig())   # restore for any later use

check gDone, "the parked read returned instead of hanging"
check gKind == wmClose.int, "a reaped read yields wmClose to the handler"
check not gOpen, "the connection is closed once reaped"
check gBufBytes == gBase + 3, "the undecoded 3 bytes were counted while buffered"
check inflightBytes() == gBase, "teardown stopped counting them"

finish()
