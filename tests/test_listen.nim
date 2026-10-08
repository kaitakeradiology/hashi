## Unit tests for listen-socket setup: clean failure, the bind-address
## literals, and the loopback default.
##
## `tryListenTcp` must bind+listen without asserting, and on a port already in
## use return a structured failure (errno EADDRINUSE at the bind stage) rather
## than crashing — the basis for `serve()`'s clean "port in use" exit.
##
## An empty bind address is loopback only: `tryListenTcp` binds 127.0.0.1,
## `listenLoopbackPair` binds 127.0.0.1 and ::1 on one port, and `serve` and
## `addWsListener` serve both. The last section runs the real server with ""
## on a main and a WebSocket-only listener: each answers on 127.0.0.1 and on
## ::1, and a connection to one of the host's non-loopback addresses is
## refused.

import std/[syncio, strutils]
import hashi
import hashi/net
import hashi/buffer
from std/posix/posix import close, SockLen
import testkit

proc cSocket(domain, typ, protocol: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc cConnect(fd: cint; sa: pointer; len: SockLen): cint {.importc: "connect", header: "<sys/socket.h>".}
proc cGetsockname(fd: cint; sa: pointer; len: ptr SockLen): cint {.
  importc: "getsockname", header: "<sys/socket.h>".}
proc cGetsockopt(fd, level, opt: cint; val: pointer; len: ptr SockLen): cint {.
  importc: "getsockopt", header: "<sys/socket.h>".}
proc cInetPton(af: cint; src: cstring; dst: pointer): cint {.
  importc: "inet_pton", header: "<arpa/inet.h>".}
proc cInetNtop(af: cint; src: pointer; dst: cstring; size: SockLen): cstring {.
  importc: "inet_ntop", header: "<arpa/inet.h>".}
proc cFcntl(fd: cint; cmd: cint; arg: cint): cint {.importc: "fcntl", header: "<fcntl.h>".}
proc cAlarm(seconds: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}
  ## The watchdog: a server run that never answers fails instead of hanging.
var cErrno {.importc: "errno", header: "<errno.h>".}: cint

const
  AfInet = 2.cint
  AfInet6 = 10.cint
  SockStream = 1.cint
  SockDgram = 2.cint
  IpprotoIpv6 = 41.cint
  Ipv6V6Only = 26.cint
  EConnRefused = 111.cint
  FGetfl = 3.cint
  FSetfl = 4.cint
  ONonblock = 0o4000.cint

# ── socket addresses as bytes ────────────────────────────────────────────

type SockAddrBuf = array[28, uint8]
  ## Room for a `sockaddr_in6`, which also holds a `sockaddr_in`. Family at
  ## 0 (host order), port at 2 (network order), the IPv4 address at 4 or the
  ## IPv6 address at 8.

proc familyOf(sa: SockAddrBuf): cint =
  var f = 0'u16
  var s = sa
  copyMem(addr f, addr s[0], 2)
  result = cint(f)

proc sockaddrFor(text: string; port: uint16; sa: var SockAddrBuf): SockLen =
  ## Fill `sa` for address literal `text` and `port`; its length, or 0 when
  ## `text` is not a literal.
  sa = default(SockAddrBuf)
  var t = text
  var fam = AfInet
  result = SockLen(16)
  if cInetPton(AfInet, toCString(t), addr sa[4]) != 1:
    fam = AfInet6
    result = SockLen(28)
    if cInetPton(AfInet6, toCString(t), addr sa[8]) != 1:
      return SockLen(0)
  var f = uint16(fam)
  copyMem(addr sa[0], addr f, 2)
  sa[2] = uint8(port shr 8)
  sa[3] = uint8(port and 0xff'u16)

proc addrText(sa: SockAddrBuf): string =
  ## The address in `sa` as `inet_ntop` text, "" if it is not one.
  result = ""
  var src = sa
  var buf = default(array[64, char])
  let fam = familyOf(sa)
  let at = if fam == AfInet6: 8 else: 4
  if fam == AfInet or fam == AfInet6:
    if cInetNtop(fam, addr src[at], cast[cstring](addr buf[0]), SockLen(64)) != nil:
      for c in buf:
        if c == char(0): break
        result.add c

proc boundTo(fd: cint): string =
  ## The listener's local address, "127.0.0.1:P" or "[::1]:P"; "?" if
  ## `getsockname` fails.
  var sa = default(SockAddrBuf)
  var len = SockLen(sizeof(sa))
  if cGetsockname(fd, addr sa, addr len) != 0: return "?"
  let port = (int(sa[2]) shl 8) or int(sa[3])
  let a = addrText(sa)
  result = (if familyOf(sa) == AfInet6: "[" & a & "]" else: a) & ":" & $port

proc portOf(fd: cint): uint16 =
  var sa = default(SockAddrBuf)
  var len = SockLen(sizeof(sa))
  result = 0'u16
  if cGetsockname(fd, addr sa, addr len) == 0:
    result = (uint16(sa[2]) shl 8) or uint16(sa[3])

proc v6Only(fd: cint): int =
  ## The socket's `IPV6_V6ONLY`, or -1 if it cannot be read.
  var v: cint = -1
  var len = SockLen(sizeof(v))
  if cGetsockopt(fd, IpprotoIpv6, Ipv6V6Only, addr v, addr len) != 0: return -1
  result = int(v)

proc closeOk(r: ListenResult) =
  if r.ok: discard close(r.fd)

# ── tryListenTcp ─────────────────────────────────────────────────────────

# A high, uncommon port. SO_REUSEADDR covers a TIME_WAIT leftover from a prior
# run; two *live* binds in one process still collide → deterministic EADDRINUSE.
const Port = 29517'u16  # below the ephemeral range, so a client socket never holds it

section "listenTcp — clean bind/listen on a free port"

let r1 = tryListenTcp(Port)
check r1.ok, "first listen on a free port succeeds"
check r1.fd >= 0, "first listen returns a valid fd"
check r1.err == 0, "first listen records no errno"

section "listenTcp — port already in use fails cleanly"

let r2 = tryListenTcp(Port)
check not r2.ok, "second listen on the same port fails (no crash, no assert)"
check r2.fd < 0, "failed listen returns no fd"
check r2.err == EADDRINUSE, "failure errno is EADDRINUSE"
check r2.stage == "bind", "failure is reported at the bind stage"

let msg = listenError(r2, Port)
check msg.len > 0, "listenError produces a human-readable message"

if r1.ok: discard close(r1.fd)

section "listenTcp — bindAddr address-literal convention"

# Convention (the Mummy-patch model, loopback by default): "" 127.0.0.1,
# "::" dual-stack wildcard, "::0" v6-only wildcard, "0.0.0.0" v4 wildcard,
# any other literal = that specific address; never a hostname. Distinct port
# per case.
var bp = 29520'u16

proc bindCase(ba: string): ListenResult =
  bp = bp + 1'u16
  result = tryListenTcp(bp, 128, ba)
  if result.ok: discard close(result.fd)

let bDual = bindCase("::")
check bDual.ok, "\"::\" binds (dual-stack wildcard)"
let bV6 = bindCase("::0")
check bV6.ok, "\"::0\" binds (v6-only wildcard)"
let bV4 = bindCase("0.0.0.0")
check bV4.ok, "\"0.0.0.0\" binds (v4 wildcard)"
let bLoop4 = bindCase("127.0.0.1")
check bLoop4.ok, "\"127.0.0.1\" binds (v4 loopback)"
let bLoop6 = bindCase("::1")
check bLoop6.ok, "\"::1\" binds (v6 loopback)"
let bHost = bindCase("localhost")
check not bHost.ok, "hostname is rejected (literals only)"
check bHost.stage == "bindaddr", "hostname rejection is stage bindaddr"
let bBad = bindCase("1.2.3.4.5")
check not bBad.ok, "malformed literal is rejected"

section "listenTcp — the address each literal binds"

let lEmpty = tryListenTcp(0'u16, 128, "")
check lEmpty.ok, "\"\" binds"
let pEmpty = portOf(lEmpty.fd)
check boundTo(lEmpty.fd) == "127.0.0.1:" & $pEmpty,
      "\"\" binds 127.0.0.1 only (got " & boundTo(lEmpty.fd) & ")"
closeOk(lEmpty)
let lDual = tryListenTcp(0'u16, 128, "::")
check boundTo(lDual.fd) == "[::]:" & $portOf(lDual.fd),
      "\"::\" binds the IPv6 wildcard (got " & boundTo(lDual.fd) & ")"
check v6Only(lDual.fd) == 0, "\"::\" is dual-stack (IPV6_V6ONLY off)"
closeOk(lDual)
let lV6 = tryListenTcp(0'u16, 128, "::0")
check boundTo(lV6.fd) == "[::]:" & $portOf(lV6.fd), "\"::0\" binds the IPv6 wildcard"
check v6Only(lV6.fd) == 1, "\"::0\" is v6-only (IPV6_V6ONLY on)"
closeOk(lV6)
let lV4 = tryListenTcp(0'u16, 128, "0.0.0.0")
check boundTo(lV4.fd) == "0.0.0.0:" & $portOf(lV4.fd), "\"0.0.0.0\" binds the IPv4 wildcard"
closeOk(lV4)
let lLit = tryListenTcp(0'u16, 128, "::1")
check boundTo(lLit.fd) == "[::1]:" & $portOf(lLit.fd), "\"::1\" binds ::1"
check v6Only(lLit.fd) == 1, "an IPv6 literal is v6-only"
closeOk(lLit)

section "listenLoopbackPair — 127.0.0.1 and ::1 on one port"

let pair = listenLoopbackPair(0'u16, 128)
check pair.v4.ok, "127.0.0.1 binds"
check pair.v6.ok, "::1 binds"
let pairPort = portOf(pair.v4.fd)
check pairPort != 0'u16, "port 0 is given a port"
check boundTo(pair.v4.fd) == "127.0.0.1:" & $pairPort,
      "v4 is 127.0.0.1 (got " & boundTo(pair.v4.fd) & ")"
check boundTo(pair.v6.fd) == "[::1]:" & $pairPort,
      "v6 is ::1 on the port v4 got (got " & boundTo(pair.v6.fd) & ")"
check v6Only(pair.v6.fd) == 1, "the ::1 socket is v6-only"
closeOk(pair.v4)
closeOk(pair.v6)

section "listenLoopbackPair — a busy ::1 is fatal and closes 127.0.0.1"

# ::1 in use by someone else is not "no IPv6": the pair fails as a whole and
# releases the 127.0.0.1 socket it had bound.
let held6 = tryListenTcp(0'u16, 128, "::1")
check held6.ok, "::1 held on a kernel-chosen port"
let busy6 = portOf(held6.fd)
let pBusy6 = listenLoopbackPair(busy6, 128)
check not pBusy6.v4.ok, "the pair fails"
check pBusy6.v4.fd < 0, "no 127.0.0.1 fd is handed back"
check pBusy6.v4.stage.len == 0, "127.0.0.1 itself did not fail"
check not pBusy6.v6.ok and pBusy6.v6.fd < 0, "::1 failed"
check pBusy6.v6.err == EADDRINUSE and pBusy6.v6.stage == "bind",
      "::1 failed at bind with EADDRINUSE"
let reuse4 = tryListenTcp(busy6, 128, "127.0.0.1")
check reuse4.ok, "127.0.0.1 on that port was released"
closeOk(reuse4)
closeOk(held6)

section "listenLoopbackPair — a busy 127.0.0.1 fails before ::1"

let held4 = tryListenTcp(0'u16, 128, "127.0.0.1")
check held4.ok, "127.0.0.1 held on a kernel-chosen port"
let busy4 = portOf(held4.fd)
let pBusy4 = listenLoopbackPair(busy4, 128)
check not pBusy4.v4.ok and pBusy4.v4.fd < 0, "the pair fails"
check pBusy4.v4.err == EADDRINUSE and pBusy4.v4.stage == "bind",
      "127.0.0.1 failed at bind with EADDRINUSE"
check not pBusy4.v6.ok and pBusy4.v6.fd < 0 and pBusy4.v6.stage.len == 0,
      "::1 was not attempted"
let reuse6 = tryListenTcp(busy4, 128, "::1")
check reuse6.ok, "::1 on that port was left free"
closeOk(reuse6)
closeOk(held4)

# ── serve and addWsListener with "" ──────────────────────────────────────

type Probe = ref object
  fd: cint
  acc: string
  eof: bool
  rbuf: array[1024, byte]

proc dialTo(text: string; port: uint16): cint =
  ## A non-blocking client socket connected to `text`:`port`, or -errno.
  ## Loopback connects complete in the kernel's backlog, so the blocking
  ## connect cannot stall.
  var sa = default(SockAddrBuf)
  let len = sockaddrFor(text, port, sa)
  if len == SockLen(0): return -1
  let fd = cSocket(familyOf(sa), SockStream, 0.cint)
  if fd < 0: return -cErrno
  if cConnect(fd, addr sa, len) != 0:
    result = -cErrno
    discard close(fd)
  else:
    discard cFcntl(fd, FSetfl, cFcntl(fd, FGetfl, 0.cint) or ONonblock)
    result = fd

proc statusLine(p: Probe): string =
  let at = find(p.acc, "\r\n")
  result = if at >= 0: substr(p.acc, 0, at - 1) else: p.acc

proc exchange(text: string; port: uint16): string {.passive.} =
  ## Send one GET to `text`:`port` and return the response's status line,
  ## or "connect failed".
  let fd = dialTo(text, port)
  if fd < 0: return "connect failed"
  let p = Probe(fd: fd, acc: "", eof: false)
  discard writeAll(p.fd, "GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  while not p.eof and find(p.acc, "\r\n") < 0:
    let n = waitRead(p.fd, addr p.rbuf[0], p.rbuf.len)
    if n > 0: appendBytes(p.acc, addr p.rbuf[0], n)
    else: p.eof = true
  discard close(p.fd)
  result = statusLine(p)

proc refused(text: string; port: uint16): bool =
  ## Whether a connect to `text`:`port` is refused.
  let fd = dialTo(text, port)
  if fd >= 0: discard close(fd)
  result = fd == -EConnRefused

proc localAddress(probe: string): string =
  ## The host address the kernel would send from to reach `probe`, found by
  ## connecting a UDP socket (nothing is sent); "" if there is no route.
  result = ""
  var sa = default(SockAddrBuf)
  let len = sockaddrFor(probe, 9'u16, sa)
  let fd = cSocket(familyOf(sa), SockDgram, 0.cint)
  if fd < 0: return
  if cConnect(fd, addr sa, len) == 0:
    var got = default(SockAddrBuf)
    var glen = SockLen(sizeof(got))
    if cGetsockname(fd, addr got, addr glen) == 0:
      result = addrText(got)
  discard close(fd)

proc freePort(): uint16 =
  ## A loopback port the kernel just handed out, for `serve` to bind.
  let r = tryListenTcp(0'u16, 16, "127.0.0.1")
  result = if r.ok: portOf(r.fd) else: 0'u16
  closeOk(r)

var gMain = 0'u16
var gWs = 0'u16

proc notReachable(fam, probe: string) =
  ## A non-loopback address of this host on family `fam` refuses both
  ## listeners; skipped with a note when the host has none.
  let a = localAddress(probe)
  if a.len == 0 or a == "127.0.0.1" or a == "::1":
    echo "   note: no non-loopback " & fam & " address, skipped"
  else:
    check refused(a, gMain), "main listener refuses " & a
    check refused(a, gWs), "ws-only listener refuses " & a

proc runServe() {.passive.} =
  section "serve and addWsListener with \"\" — loopback only"
  check startsWith(exchange("127.0.0.1", gMain), "HTTP/1.1 200"),
        "main listener answers on 127.0.0.1"
  check startsWith(exchange("::1", gMain), "HTTP/1.1 200"),
        "main listener answers on ::1"
  check startsWith(exchange("127.0.0.1", gWs), "HTTP/1.1 426"),
        "ws-only listener answers on 127.0.0.1"
  check startsWith(exchange("::1", gWs), "HTTP/1.1 426"),
        "ws-only listener answers on ::1"
  notReachable("IPv4", "192.0.2.1")
  notReachable("IPv6", "2001:db8::1")
  finish()

proc ok(req: Request): Response {.nimcall, raises.} =
  newResponse(200, "ok")

proc wsOnly(ws: WsConn) {.passive.} =
  discard wsRecv(ws)

discard cAlarm(30)
gMain = freePort()
gWs = freePort()
if gMain == 0'u16 or gWs == 0'u16 or gMain == gWs:
  writeLine(stderr, "test_listen: no free loopback ports")
  quit(1)
get("/ok", ok)
if not addWsListener(gWs, wsOnly):
  writeLine(stderr, "test_listen: no WebSocket-only listener")
  quit(1)
setBootTask(runServe)
serve(gMain)
