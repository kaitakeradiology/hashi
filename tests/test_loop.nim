## The passive fd operations, called BY NAME across a module boundary.
##
## Worth a running test rather than a compile check, because the risk is
## specific: each op hands `addr result` to the ring, so an ioring worker writes
## into the CALLEE's coroutine frame while the caller is parked. This asserts the
## returned count AND the bytes over a real socketpair, ten times.
##
## `spawnTask` queues the task on the pool, so its ops run on worker lanes; main
## pumps its own lane while it waits, as `runLoop` would.
import std/[syncio, monotimes]
from std/posix/posix import write, close
import hashi/loop     # imported, not included
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a `spawnTask` that waits for its task can wait forever here,
  ## and SIGALRM turns that hang into a failed run.
const AfUnix = 1.cint
const SockStream = 1.cint

var gGot = -999
var gBuf = default(array[64, char])
var gDone = false

proc reader(fd: cint) {.passive.} =
  ## Cross-module by-name passive call that PARKS in the ring.
  gGot = waitRead(fd, addr gBuf[0], 64)
  gDone = true

var gNapDone = false

proc napper() {.passive.} =
  ## Parks on a ring timer, so a caller that waits for it waits 200 ms.
  sleepMs(200)
  gNapDone = true

proc spawnReturnsAtOnce() =
  ## `spawnTask` starts the task and returns; it does not wait for the task to
  ## finish. An accept loop spawns each connection's handler this way, so a
  ## `spawnTask` that waited would serve one connection at a time.
  let t0 = getMonoTime().ticks
  spawnTask napper()
  let spentMs = (getMonoTime().ticks - t0) div 1_000_000
  var spins = 0
  while not gNapDone and spins < 200:
    discard pumpIo(10)
    spins = spins + 1
  section "spawnTask returns while the task is parked"
  check spentMs < 100, "spawnTask returned in " & $spentMs & " ms (the task parks for 200)"
  check gNapDone, "the spawned task still ran to the end"

proc main() =
  discard cAlarm(10)
  initLoop()
  spawnReturnsAtOnce()
  var ok = 0
  var i = 0
  while i < 10:
    var sv = default(array[2, cint])
    if cSocketpair(AfUnix, SockStream, 0.cint, addr sv[0]) != 0:
      echo "  socketpair failed"; quit(1)
    setNonBlocking(sv[0])
    setNonBlocking(sv[1])
    gGot = -999
    gDone = false
    var z = 0
    while z < 64: gBuf[z] = '\0'; z = z + 1

    spawnTask reader(sv[0])
    discard pumpIo(10)               # let the reader submit its op on this lane

    let msg = "hello-" & $i
    var mbuf = default(array[64, char])   # strings are not addressable in Nimony
    var w = 0
    while w < msg.len: mbuf[w] = msg[w]; w = w + 1
    discard write(sv[1], addr mbuf[0], msg.len)

    var spins = 0
    while not gDone and spins < 400:
      discard pumpIo(10)
      spins = spins + 1

    var got = ""
    var k = 0
    while k < gGot and k < 64: got.add gBuf[k]; k = k + 1
    if gGot == msg.len and got == msg: ok = ok + 1
    else: echo "  iter ", i, ": count=", gGot, " (want ", msg.len, ") body=", got

    discard close(sv[0])
    discard close(sv[1])
    i = i + 1
  section "the reactor wait wrappers work when IMPORTED"
  check ok == 10,
    "10/10 cross-module waitRead returned the right count AND the right bytes (got " &
    $ok & "/10)"
  shutdownPool()
  finish()

main()
