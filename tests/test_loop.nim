## The passive fd operations, called BY NAME across a module boundary.
##
## Worth a running test rather than a compile check, because the risk is
## specific: each op hands `addr result` to the ring, so an ioring worker writes
## into the CALLEE's coroutine frame while the caller is parked. This asserts the
## returned count AND the bytes over a real socketpair, ten times.
##
## NOTE main must `pumpIo` its OWN lane: `spawn` submits a task's first op on the
## calling thread's lane, and a lane is drained only by that thread (sched.nim
## runLoop/pumpIo). Sleeping instead simply hangs, with no error.
import std/syncio
from std/posix/posix import write, close
import hashi/loop     # imported, not included
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
const AfUnix = 1.cint
const SockStream = 1.cint

var gGot = -999
var gBuf = default(array[64, char])
var gDone = false

proc reader(fd: cint) {.passive.} =
  ## Cross-module by-name passive call that PARKS in the ring.
  gGot = waitRead(fd, addr gBuf[0], 64)
  gDone = true

proc main() =
  initLoop()
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
