## The write path over a real socket pair: `writeNow` takes what the kernel
## accepts without waiting, and `writeAll` delivers everything, parking on the
## ring only for what did not fit.
import std/[syncio, atomics]
from std/posix/posix import read, close
import hashi/loop
import hashi/net
import testkit

proc cSocketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.
  importc: "socketpair", header: "<sys/socket.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a write that never completes fails the run instead of
  ## hanging it.
const AfUnix = 1.cint
const SockStream = 1.cint

proc pair(): array[2, cint] =
  result = default(array[2, cint])
  if cSocketpair(AfUnix, SockStream, 0.cint, addr result[0]) != 0:
    echo "  socketpair failed"; quit(1)
  setNonBlocking(result[0])
  setNonBlocking(result[1])

proc pattern(n: int): string =
  result = newString(n)
  var i = 0
  while i < n:
    result[i] = char(ord('a') + i mod 26)
    i = i + 1

proc drain(fd: cint; want: int): string =
  ## Read until `want` bytes arrived, pumping the main lane between reads.
  result = ""
  var buf = default(array[65536, char])
  var spins = 0
  while result.len < want and spins < 100_000:
    let n = read(fd, addr buf[0], buf.len)
    if n > 0:
      var k = 0
      while k < n: result.add buf[k]; k = k + 1
    else:
      discard workTurn()
      spins = spins + 1

var gOk: int       # accessed atomically: 1 true, 0 false, -1 not yet
var gDone: bool    # accessed atomically

proc writer(fd: cint; data: string) {.passive.} =
  let ok = writeAll(fd, data)
  atomicStore(gOk, (if ok: 1 else: 0), moRelaxed)
  atomicStore(gDone, true, moRelease)

proc awaitWriter() =
  var spins = 0
  while not atomicLoad(gDone, moAcquire) and spins < 100_000:
    discard workTurn()
    spins = spins + 1

proc main() =
  discard cAlarm(20)
  ignoreSigpipe()
  initLoop()

  section "writeNow takes what fits, without waiting"
  block:
    let sv = pair()
    let small = pattern(100)
    check writeNow(sv[0], small, 0) == 100, "an empty socket takes a small write whole"
    check writeNow(sv[0], small, 60) == 40, "a write from an offset takes the rest"
    check drain(sv[1], 140) == small & small[60 ..< 100], "the bytes arrive in order"
    let big = pattern(8 * 1024 * 1024)
    let n = writeNow(sv[0], big, 0)
    check n > 0 and n < big.len, "a write larger than the socket buffer is partial (" & $n & ")"
    check writeNow(sv[0], big, n) == 0, "a full socket takes nothing more, and that is not an error"
    discard close(sv[1])
    check writeNow(sv[0], small, 0) == -1, "a closed peer is an error"
    discard close(sv[0])

  section "writeAll delivers everything"
  block:
    let sv = pair()
    let big = pattern(1024 * 1024)
    atomicStore(gOk, -1, moRelaxed)
    atomicStore(gDone, false, moRelaxed)
    spawnTask writer(sv[0], big)
    let got = drain(sv[1], big.len)
    awaitWriter()
    check atomicLoad(gOk, moRelaxed) == 1, "writeAll reports success"
    check got.len == big.len and got == big, "1 MiB arrives intact (" & $got.len & " bytes)"
    discard close(sv[0])
    discard close(sv[1])

  section "writeAll reports a closed peer"
  block:
    let sv = pair()
    discard close(sv[1])
    atomicStore(gOk, -1, moRelaxed)
    atomicStore(gDone, false, moRelaxed)
    spawnTask writer(sv[0], pattern(1000))
    awaitWriter()
    check atomicLoad(gOk, moRelaxed) == 0, "writeAll returns false"
    discard close(sv[0])

  shutdownPool()
  finish()

main()
