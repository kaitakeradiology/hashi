## The idle reaper never kills a request the handler has already read.
##
## A keep-alive client sends its next request at the moment the idle deadline
## expires. Either the read wins (the request is served and its response is
## delivered) or the reaper wins (the connection ends before any request is
## processed). Never both: a request that is processed must have its response
## delivered, or a retrying client sends the same request twice.
##
## `idleTimeoutMs` 20 and `reapIntervalMs` 1 put the sweep next to the
## deadline; the client's gap sweeps 19..22 ms around it.
import std/[syncio, strutils, atomics]
from std/posix/posix import Sockaddr_in, SockLen
import hashi
import hashi/buffer
import hashi/http/connreg
import testkit

proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
proc cFcntl(fd, cmd: cint; arg: cint): cint {.importc: "fcntl", header: "<fcntl.h>".}
proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cBind(fd: cint; sa: pointer; len: SockLen): cint {.importc: "bind", header: "<sys/socket.h>".}
proc cGetsockname(fd: cint; sa: pointer; len: ptr SockLen): cint {.
  importc: "getsockname", header: "<sys/socket.h>".}
proc cHtons(x: uint16): uint16 {.importc: "htons", header: "<arpa/inet.h>".}
proc cNtohs(x: uint16): uint16 {.importc: "ntohs", header: "<arpa/inet.h>".}
proc cHtonl(x: uint32): uint32 {.importc: "htonl", header: "<arpa/inet.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
const AfInet = 2.cint
const SockStream = 1.cint
const IpprotoTcp = 6.cint
const FGetfl = 3.cint
const FSetfl = 4.cint
const ONonblock = 0o4000.cint
const Loopback = 0x7F000001'u32
const Rounds = 600

proc loopbackAddr(port: uint16): Sockaddr_in =
  result = default(Sockaddr_in)
  result.sin_family = uint16(AfInet)
  result.sin_port = cHtons(port)
  result.sin_addr.s_addr = cHtonl(Loopback)

proc freePort(): uint16 =
  result = 0'u16
  let fd = cSocket(AfInet, SockStream, IpprotoTcp)
  if fd >= 0:
    var a = loopbackAddr(0'u16)
    if cBind(fd, addr a, SockLen(sizeof(a))) == 0:
      var got = default(Sockaddr_in)
      var len = SockLen(sizeof(got))
      if cGetsockname(fd, addr got, addr len) == 0:
        result = cNtohs(got.sin_port)
    discard cClose(fd)

let gPort = freePort()
var gProcessed: int64   ## requests the handler ran

proc dial(port: uint16): cint =
  result = cSocket(AfInet, SockStream, IpprotoTcp)
  if result >= 0:
    var a = loopbackAddr(port)
    if cConnect(result, addr a, SockLen(sizeof(a))) != 0:
      discard cClose(result)
      result = -1
    else:
      let flags = cFcntl(result, FGetfl, 0.cint)
      discard cFcntl(result, FSetfl, flags or ONonblock)

proc readResponse(fd: cint): string {.passive.} =
  ## Bytes up to a complete `ok` response, or up to EOF.
  result = ""
  var buf = default(array[4096, byte])
  var done = false
  while not done:
    let n = waitRead(fd, addr buf[0], buf.len)
    if n <= 0:
      done = true
    else:
      appendBytes(result, addr buf[0], n)
      let he = find(result, "\r\n\r\n")
      if he >= 0 and result.len >= he + 4 + 2: done = true

const Req = "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n"

proc run() {.passive.} =
  section "a processed request is always answered"
  var fd = dial(gPort)
  check fd >= 0, "connected"
  var delivered = 0
  var emptyEof = 0
  var partial = 0
  var i = 0
  while i < Rounds:
    if fd < 0: fd = dial(gPort)
    if not writeAll(fd, Req):
      # A write into a connection the reaper already took: nothing was read.
      discard cClose(fd)
      fd = -1
    else:
      let got = readResponse(fd)
      if startsWith(got, "HTTP/1.1 200") and endsWith(got, "ok"):
        delivered = delivered + 1
        sleepMs(19 + (i mod 4))
      else:
        if got.len == 0: emptyEof = emptyEof + 1 else: partial = partial + 1
        discard cClose(fd)
        fd = -1
    i = i + 1
  if fd >= 0: discard cClose(fd)
  let processed = int(atomicLoad(gProcessed))
  echo "rounds=", Rounds, " processed=", processed, " delivered=", delivered,
       " emptyEof=", emptyEof, " partial=", partial, " reaped=", reapedTotal()
  check partial == 0, "no truncated response"
  check processed == delivered, "every processed request was answered"
  check reapedTotal() > 0, "the reaper ran in the window"
  finish()

proc ok(req: Request): Response {.nimcall, raises.} =
  discard atomicFetchAdd(gProcessed, 1'i64)
  newResponse(200, "ok")

discard cAlarm(60)
if gPort == 0'u16:
  writeLine(stderr, "test_idle_reap_race: no free loopback port")
  quit(1)
var cfg = defaultServerConfig()
cfg.idleTimeoutMs = 20
cfg.reapIntervalMs = 1
get("/ok", ok)
setBootTask(run)
serve(gPort, cfg, bindAddr = "127.0.0.1")
