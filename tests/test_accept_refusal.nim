## The in-flight cap's 503 reaches the client.
##
## The acceptor refuses a connection while `inflightBytes()` is at or over
## `maxInflightBytes`, writing a 503 through the ring. It must set
## `O_NONBLOCK` on the accepted fd first (readiness backends require it for
## ring transfers). The refused fd is closed by the server, so this asserts
## the delivered 503 and the close, which is what a regression in that
## ordering breaks on a readiness backend; it does not read the flag itself.
import std/[syncio, strutils]
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
const Cap = 64   ## `maxInflightBytes`: below the partial head the first client holds

proc loopbackAddr(port: uint16): Sockaddr_in =
  result = default(Sockaddr_in)
  result.sin_family = uint16(AfInet)
  result.sin_port = cHtons(port)
  result.sin_addr.s_addr = cHtonl(Loopback)

proc freePort(): uint16 =
  ## A loopback port the kernel just handed out, for `serve` to bind.
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

proc dial(port: uint16): cint =
  ## A non-blocking client socket connected to the server on `port`. Loopback connects
  ## complete in the kernel's backlog, so the blocking connect cannot stall.
  result = cSocket(AfInet, SockStream, IpprotoTcp)
  if result >= 0:
    var a = loopbackAddr(port)
    if cConnect(result, addr a, SockLen(sizeof(a))) != 0:
      discard cClose(result)
      result = -1
    else:
      let flags = cFcntl(result, FGetfl, 0.cint)
      discard cFcntl(result, FSetfl, flags or ONonblock)

proc readToEof(fd: cint): string {.passive.} =
  ## Everything the server sends before it closes.
  result = ""
  var buf = default(array[4096, byte])
  var n = waitRead(fd, addr buf[0], buf.len)
  while n > 0:
    appendBytes(result, addr buf[0], n)
    n = waitRead(fd, addr buf[0], buf.len)

proc run() {.passive.} =
  section "the in-flight cap refuses with a 503"
  # The first client's unterminated head stays buffered, holding the count over the cap.
  let a = dial(gPort)
  check a >= 0, "first client connected"
  discard writeAll(a, "GET /ok HTTP/1.1\r\nHost: localhost\r\nX-Pad: " &
                      "pppppppppppppppppppppppppppppppppppppppppppppp")
  var waited = 0
  while inflightBytes() < Cap and waited < 2000:
    sleepMs(5)
    waited = waited + 5
  check inflightBytes() >= Cap, "head buffered over the cap"
  let b = dial(gPort)
  check b >= 0, "second client connected"
  let got = readToEof(b)
  check startsWith(got, "HTTP/1.1 503"), "refused with 503: " & got
  check find(got, "close") >= 0, "refusal closes"
  discard cClose(b)
  discard cClose(a)
  finish()

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

discard cAlarm(30)
if gPort == 0'u16:
  writeLine(stderr, "test_accept_refusal: no free loopback port")
  quit(1)
var cfg = defaultServerConfig()
cfg.maxInflightBytes = Cap
get("/ok", ok)
setBootTask(run)
serve(gPort, cfg, bindAddr = "127.0.0.1")
