## `serve`'s `onBound` callback and `stopServe`, on the real server.
##
## The server runs on the main thread with port 0. `onBound` receives the
## kernel's port before any accept task exists; a client task (the boot task,
## on a pool worker) is served on it; a plain thread then calls `stopServe`
## (it joins the pool workers, so it cannot be called from one); `serve`
## returns and the main thread checks that the process is still alive and a
## connect to the port, on both loopbacks, is refused (ECONNREFUSED): no
## listener lingers in LISTEN.
##
## `onBound` runs after `sealBootConfig()`, so it may only write atomics. A
## `publish` or any boot registration in it is the documented FATAL abort;
## this test does not provoke that.

import std/[syncio, strutils, atomics, rawthreads]
import hashi
import hashi/buffer
from std/posix/posix import close, SockLen, errno
import testkit

proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cInetPton(af: cint; src: cstring; dst: pointer): cint {.
  importc: "inet_pton", header: "<arpa/inet.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
proc cUsleep(us: cuint): cint {.importc: "usleep", header: "<unistd.h>".}
proc cFcntl(fd: cint; cmd: cint; arg: cint): cint {.importc: "fcntl", header: "<fcntl.h>".}

const
  AfInet = 2.cint
  AfInet6 = 10.cint
  SockStream = 1.cint
  EConnRefused = 111.cint
  FGetfl = 3.cint
  FSetfl = 4.cint
  ONonblock = 0o4000.cint

var gPort: int        # onBound's port; 0 until called (atomic)
var gBoundCalls: int  # how many times onBound ran (atomic)
var gClientDone: bool # the client task finished (atomic)
template ld(v: untyped): untyped = atomicLoad(v, moAcquire)
template st(v, x: untyped) = atomicStore(v, x, moRelease)

proc onBound(port: uint16) {.nimcall, gcsafe.} =
  ## Atomics only: this runs after the boot seal.
  st(gPort, int(port))
  discard atomicFetchAdd(gBoundCalls, 1, moAcquireRelease)

proc connectTo(text: string; port: uint16): cint =
  ## A non-blocking client socket connected to `text`:`port`, or -errno.
  ## Loopback connects complete in the kernel's backlog, so the blocking
  ## connect cannot stall.
  var sa = default(array[28, uint8])
  var t = text
  var fam = AfInet
  var len = SockLen(16)
  if cInetPton(AfInet, toCString(t), addr sa[4]) != 1:
    fam = AfInet6
    len = SockLen(28)
    if cInetPton(AfInet6, toCString(t), addr sa[8]) != 1: return -1
  var f = uint16(fam)
  copyMem(addr sa[0], addr f, 2)
  sa[2] = uint8(port shr 8)
  sa[3] = uint8(port and 0xff'u16)
  let fd = cSocket(fam, SockStream, 0.cint)
  if fd < 0: return -1
  if cConnect(fd, addr sa, len) != 0:
    result = -errno()
    discard close(fd)
  else:
    discard cFcntl(fd, FSetfl, cFcntl(fd, FGetfl, 0.cint) or ONonblock)
    result = fd

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

proc clientTask() {.passive.} =
  section "onBound and a served request"
  let port = uint16(ld(gPort))
  check port != 0'u16, "onBound gave a non-zero port before the first client"
  check ld(gBoundCalls) == 1, "onBound ran once"
  let fd = connectTo("127.0.0.1", port)
  check fd >= 0, "a client connects to the reported port"
  if fd >= 0:
    discard writeAll(fd, "GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    var acc = ""
    var buf = default(array[512, char])
    while acc.len < 12:
      let n = waitRead(fd, addr buf[0], buf.len)
      if n <= 0: break
      appendBytes(acc, addr buf[0], n)
    check startsWith(acc, "HTTP/1.1 200"), "the request is served"
    discard close(fd)
  st(gClientDone, true)

proc stopper(arg: pointer) {.nimcall.} =
  ## A plain thread: `stopServe` joins the pool workers.
  var waited = 0
  while not ld(gClientDone) and waited < 20000:
    discard cUsleep(1000)
    waited = waited + 1
  stopServe()

discard cAlarm(30)
get("/ok", ok)
setBootTask(clientTask)
var th: RawThread
try:
  create th, stopper, nil
except:
  writeLine(stderr, "test_serve_stop: cannot start the stopper thread")
  quit(1)
serve(0'u16, onBound = onBound)
join th

section "after stopServe"
check true, "serve returned and the process is alive"
let port = uint16(ld(gPort))
check connectTo("127.0.0.1", port) == -EConnRefused, "127.0.0.1 refuses: no listener in LISTEN"
check connectTo("::1", port) == -EConnRefused, "::1 refuses: no listener in LISTEN"
finish()
