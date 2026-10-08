## Sockets: listen-socket setup with structured failure, the peer's address
## and IP-literal parsing in the same canonical text, the per-connection
## options the server applies at accept, the half-close and peek a lingering
## close needs, and the process's open-file limit.
##
## `tryListenTcp` creates the listening socket and, instead of asserting on
## a failed `socket`, `bind` or `listen`, reports the failing call and its
## `errno` in a `ListenResult`, so `serve` can print a clear message and exit
## non-zero. `listenError` renders that result for an operator.
## `listenLoopbackPair` listens on 127.0.0.1 and ::1 on one port, which is
## what `serve` does for an empty bind address. The socket calls and
## constants here are Linux's; this is the module to port first for another
## platform.

from std/posix/posix import close, fcntl, F_GETFL, F_SETFL, O_NONBLOCK,
  AF_INET, AF_INET6, SOCK_STREAM, IPPROTO_TCP, IPPROTO_IPV6, SOL_SOCKET,
  SO_REUSEADDR, Sockaddr_in, SockLen, EADDRNOTAVAIL, EAFNOSUPPORT
import std/strutils

# Socket calls and types `std/posix` does not declare yet.
type
  CSockAddr {.importc: "struct sockaddr", header: "<sys/socket.h>".} = object
    ## glibc's `struct sockaddr`; `bind`'s transparent-union argument accepts
    ## a pointer to this, not to a Nim object of the same layout.
  Sockaddr_in6 = object
    ## Linux `sockaddr_in6` layout. Not an importc of `struct in6_addr`,
    ## whose `s6_addr` member is a glibc macro that breaks codegen; the
    ## layout is fixed by the ABI, so a cast to `ptr CSockAddr` is sound.
    sin6_family: uint16
    sin6_port: uint16            ## network byte order
    sin6_flowinfo: uint32
    sin6_addr: array[16, uint8]
    sin6_scope_id: uint32

const
  IPV6_V6ONLY = 26.cint          ## `setsockopt` option: v6-only versus dual-stack
  TCP_NODELAY = 1.cint
  SO_KEEPALIVE = 9.cint
  TCP_KEEPIDLE = 4.cint
  TCP_KEEPINTVL = 5.cint
  TCP_KEEPCNT = 6.cint
  TCP_USER_TIMEOUT = 18.cint
  SHUT_WR = 1.cint
  MSG_PEEK = 2.cint
  RLIMIT_NOFILE = 7.cint
  INET6_ADDRSTRLEN = 46

proc socket(domain, typ, protocol: cint): cint {.importc, header: "<sys/socket.h>".}
proc setsockopt(s, level, optname: cint; optval: pointer; optlen: SockLen): cint {.
  importc, header: "<sys/socket.h>".}
proc bindSocket(s: cint; name: ptr CSockAddr; namelen: SockLen): cint {.
  importc: "bind", header: "<sys/socket.h>".}
proc listenSocket(s, backlog: cint): cint {.importc: "listen", header: "<sys/socket.h>".}
proc htons(x: uint16): uint16 {.importc, header: "<arpa/inet.h>".}
proc ntohs(x: uint16): uint16 {.importc, header: "<arpa/inet.h>".}
proc inet_pton(af: cint; src: cstring; dst: pointer): cint {.
  importc, header: "<arpa/inet.h>".}
proc inet_ntop(af: cint; src: pointer; dst: cstring; size: SockLen): cstring {.
  importc, header: "<arpa/inet.h>".}
proc getpeername(fd: cint; sa: ptr CSockAddr; len: ptr SockLen): cint {.
  importc, header: "<sys/socket.h>".}
proc getsockname(fd: cint; sa: ptr CSockAddr; len: ptr SockLen): cint {.
  importc, header: "<sys/socket.h>".}
proc signal(signum: cint; handler: pointer): pointer {.
  importc, header: "<signal.h>".}
proc shutdownSocket(fd, how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
proc recv(fd: cint; buf: pointer; len: csize_t; flags: cint): int {.
  importc, header: "<sys/socket.h>".}

when defined(linux):
  const MsgDontWait* = 0x40.cint    ## `MSG_DONTWAIT`: this one call does not block.
  const MsgNoSignal* = 0x4000.cint  ## `MSG_NOSIGNAL`: no SIGPIPE for this one send.
elif defined(macosx):
  const MsgDontWait* = 0x80.cint
  const MsgNoSignal* = 0.cint       ## None here: a send to a reset peer can raise SIGPIPE.
else:
  const MsgDontWait* = 0x80.cint
  const MsgNoSignal* = 0x20000.cint

type
  RLimit {.importc: "struct rlimit", header: "<sys/resource.h>".} = object
    ## The C struct itself, so the field widths follow the C headers.
    rlim_cur: uint64
    rlim_max: uint64

proc getrlimit(resource: cint; rlim: ptr RLimit): cint {.
  importc, header: "<sys/resource.h>".}

var errno {.importc: "errno", header: "<errno.h>".}: cint

const EADDRINUSE* = 98.cint   ## Linux `errno`: address already in use.

type
  ListenResult* = object
    ## Outcome of `tryListenTcp`. When `ok`, `fd` is a bound, listening,
    ## non-blocking socket; otherwise `stage` and `err` name the failing call.
    ok*: bool       ## true when bound and listening
    fd*: cint       ## the listening fd when `ok`, -1 otherwise
    err*: cint      ## `errno` of the failing call, 0 when `ok`
    stage*: string  ## the failing call: "socket", "bind", "listen", "bindaddr"
                    ## or "getsockname"

proc tryListenTcp*(port: uint16; backlog = 4096; bindAddr = ""): ListenResult =
  ## Create a non-blocking TCP listen socket on `port`. Never asserts.
  ##
  ## `backlog` is the accept queue; the kernel clamps it to `somaxconn`. A
  ## queue that is too short drops SYNs under connection churn, which the
  ## client sees as one-second retransmit stalls rather than as an error.
  ##
  ## `bindAddr` is an address literal, never a hostname:
  ##   - `""`: 127.0.0.1 only, so an unset address is reachable from this
  ##     host alone. `listenLoopbackPair` adds ::1, as `serve` does
  ##   - `"::"`: dual-stack wildcard, every interface (an IPv6 socket with
  ##     `IPV6_V6ONLY` off, so IPv4 clients arrive as v4-mapped addresses);
  ##     falls back to the IPv4 wildcard if the host has no IPv6
  ##   - `"::0"`: all IPv6 interfaces only (`IPV6_V6ONLY` on)
  ##   - `"0.0.0.0"`: all IPv4 interfaces only
  ##   - any other literal: that address; IPv6 literals get `IPV6_V6ONLY` on
  ##
  ## `::` and `::0` parse to the same address, so the spelling selects
  ## dual-stack versus v6-only. A non-literal fails with stage "bindaddr".
  ## On failure the socket is closed and `err` holds the `errno` of the
  ## failing call.
  result = ListenResult(ok: false, fd: -1, err: 0, stage: "")
  let dual = bindAddr == "::"
  var a4 = default(Sockaddr_in)
  a4.sin_family = uint16(AF_INET)
  a4.sin_port = htons(port)
  var a6 = default(Sockaddr_in6)
  a6.sin6_family = uint16(AF_INET6)
  a6.sin6_port = htons(port)
  var v6 = true
  if not dual and bindAddr != "::0":
    var ba = if bindAddr.len == 0: "127.0.0.1" else: bindAddr
    if inet_pton(AF_INET, toCString(ba), addr a4.sin_addr) == 1:
      v6 = false
    elif inet_pton(AF_INET6, toCString(ba), addr a6.sin6_addr) != 1:
      result.stage = "bindaddr"
      return
  var fd = -1.cint
  if v6:
    fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 and dual:
      v6 = false
  if not v6:
    fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  if fd < 0:
    result.err = errno
    result.stage = "socket"
    return
  var yes: cint = 1
  discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr yes, SockLen(sizeof(yes)))
  var bound = -1.cint
  if v6:
    # V6ONLY off only for the dual-stack wildcard.
    var v6only: cint = if dual: 0 else: 1
    discard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, addr v6only,
                       SockLen(sizeof(v6only)))
    bound = bindSocket(fd, cast[ptr CSockAddr](addr a6), SockLen(sizeof(a6))).cint
  else:
    bound = bindSocket(fd, cast[ptr CSockAddr](addr a4), SockLen(sizeof(a4))).cint
  if bound != 0:
    result.err = errno
    result.stage = "bind"
    discard close(fd)
    return
  if listenSocket(fd, backlog.cint) != 0:
    result.err = errno
    result.stage = "listen"
    discard close(fd)
    return
  # Non-blocking, as the accept loop expects.
  let flags = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  result.ok = true
  result.fd = fd
  result.err = 0
  result.stage = ""

type
  LoopbackPair* = object
    ## Outcome of `listenLoopbackPair`. `v4.ok` is the outcome of the pair:
    ## when it is false nothing is open, and the half whose `stage` is set
    ## names the failing call.
    v4*: ListenResult  ## 127.0.0.1
    v6*: ListenResult  ## ::1, `IPV6_V6ONLY` on

proc listenLoopbackPair*(port: uint16; backlog = 4096): LoopbackPair =
  ## Listen on 127.0.0.1 and on ::1 on `port`: the loopback interface on
  ## both families and no other. Never asserts.
  ##
  ## 127.0.0.1 is bound first, then ::1 on the port 127.0.0.1 actually got,
  ## so a `port` of 0 gives both sockets one kernel-chosen port. Outcomes:
  ##   - both `ok`: two listening, non-blocking fds on one port
  ##   - `v4` failed: nothing is open; ::1 was not attempted (`v6.stage` "")
  ##   - ::1 failed with `EADDRNOTAVAIL` or `EAFNOSUPPORT` (the host has no
  ##     IPv6 loopback): `v4` stays open and `v6` holds the failure, for the
  ##     caller to report as a warning
  ##   - ::1 failed otherwise, such as `EADDRINUSE`: the 127.0.0.1 socket is
  ##     closed, `v4.ok` is false with `v4.stage` "", and `v6` holds the
  ##     failure
  result = LoopbackPair(v4: tryListenTcp(port, backlog, "127.0.0.1"),
                        v6: ListenResult(ok: false, fd: -1, err: 0, stage: ""))
  if not result.v4.ok: return
  var got = default(Sockaddr_in)
  var gotLen = SockLen(sizeof(got))
  if getsockname(result.v4.fd, cast[ptr CSockAddr](addr got), addr gotLen) != 0:
    let e = errno
    discard close(result.v4.fd)
    result.v4 = ListenResult(ok: false, fd: -1, err: e, stage: "getsockname")
    return
  result.v6 = tryListenTcp(ntohs(got.sin_port), backlog, "::1")
  if not result.v6.ok and result.v6.err != EADDRNOTAVAIL and
      result.v6.err != EAFNOSUPPORT:
    discard close(result.v4.fd)
    result.v4 = ListenResult(ok: false, fd: -1, err: 0, stage: "")

proc listenError*(r: ListenResult; port: uint16): string =
  ## One line describing a failed `tryListenTcp`, naming the busy port in
  ## the common case.
  if r.err == EADDRINUSE and r.stage == "bind":
    result = "port " & $port.int & " already in use (EADDRINUSE)"
  elif r.stage == "bindaddr":
    result = "malformed bind address (want an IPv4/IPv6 literal, not a hostname)"
  else:
    result = r.stage & "() failed for port " & $port.int &
             " (errno " & $r.err.int & ")"

proc setsockoptInt(fd, level, opt: cint; val: int) =
  var v = val.cint
  discard setsockopt(fd, level, opt, addr v, SockLen(sizeof(v)))

proc setNoDelay*(fd: cint) =
  ## Disable Nagle on an accepted socket. Without it small request/response and
  ## WebSocket writes stall ~40ms (Nagle + delayed-ACK), which collapses single-
  ## connection round-trip throughput (Autobahn 9.7.x: ~24 -> ~60k msg/s).
  setsockoptInt(fd, IPPROTO_TCP, TCP_NODELAY, 1)

proc setKeepalive*(fd: cint; idleSec, intvlSec, cnt, userTimeoutMs: int) =
  ## Kernel dead-peer detection on one socket; a zero leaves that knob at
  ## the kernel default, and `idleSec` zero leaves keepalive off. A dead
  ## peer's socket is errored by the kernel; the fd's armed read or write op
  ## then fires and the connection driver's `<= 0` unwind closes it.
  if idleSec > 0:
    setsockoptInt(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
    setsockoptInt(fd, IPPROTO_TCP, TCP_KEEPIDLE, idleSec)
    if intvlSec > 0: setsockoptInt(fd, IPPROTO_TCP, TCP_KEEPINTVL, intvlSec)
    if cnt > 0: setsockoptInt(fd, IPPROTO_TCP, TCP_KEEPCNT, cnt)
  if userTimeoutMs > 0:
    setsockoptInt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, userTimeoutMs)

proc ignoreSigpipe*() =
  ## Make a write to a peer-closed socket return EPIPE instead of killing
  ## the process.
  discard signal(13.cint, cast[pointer](1))

proc addressText(a: array[16, uint8]): string =
  ## The canonical text of IPv6 address `a`: a dotted quad when it is
  ## IPv4-mapped (`::ffff:a.b.c.d`), otherwise `inet_ntop`'s compressed,
  ## lower-case form; "" if `inet_ntop` fails.
  var mapped = a[10] == 0xff'u8 and a[11] == 0xff'u8
  for i in 0 ..< 10:
    if a[i] != 0'u8: mapped = false
  result = ""
  if mapped:
    result = $int(a[12]) & "." & $int(a[13]) & "." & $int(a[14]) & "." & $int(a[15])
  else:
    var src = a
    var buf = default(array[INET6_ADDRSTRLEN, char])
    if inet_ntop(AF_INET6, addr src, cast[cstring](addr buf[0]),
                 SockLen(INET6_ADDRSTRLEN)) != nil:
      for c in buf:
        if c == char(0): break
        result.add c

proc mappedFrom(v4: array[4, uint8]): array[16, uint8] =
  ## IPv4 address `v4` (network byte order) as `::ffff:a.b.c.d`.
  result = default(array[16, uint8])
  result[10] = 0xff'u8
  result[11] = 0xff'u8
  for i in 0 ..< 4: result[12 + i] = v4[i]

proc peerAddress*(fd: cint): string =
  ## The socket peer's address as text, in `parseIpLiteral`'s canonical
  ## form: dotted quad for IPv4 and for IPv4-mapped IPv6 (what a dual-stack
  ## listener sees from IPv4 clients), compressed lower-case IPv6 otherwise,
  ## "?" if unavailable.
  var sa6 = default(Sockaddr_in6)   # large enough for a sockaddr_in too
  var sl = SockLen(sizeof(sa6))
  if getpeername(fd, cast[ptr CSockAddr](addr sa6), addr sl) != 0:
    return "?"
  if sa6.sin6_family == uint16(AF_INET6):
    result = addressText(sa6.sin6_addr)
  else:
    var sa4 = cast[ptr Sockaddr_in](addr sa6)[]
    var v4 = default(array[4, uint8])
    copyMem(addr v4, addr sa4.sin_addr, 4)
    result = addressText(mappedFrom(v4))
  if result.len == 0: result = "?"

const MaxIpLiteral = 45
  ## The longest IPv6 text form, `ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255`.

proc parseIpLiteral*(s: string): string =
  ## The canonical text of the IPv4 or IPv6 address literal `s`, the form
  ## `peerAddress` renders, or "" when `s` is not one. Leading and trailing
  ## spaces and tabs are ignored. What remains must be at most 45 bytes of
  ## `[0-9A-Fa-f:.]` that `inet_pton` accepts, so a CIDR suffix, port, zone
  ## id, brackets, hostname, control byte or NUL is refused. IPv4 octets
  ## take no leading zeros.
  result = ""
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t'): inc a
  while b > a and (s[b - 1] == ' ' or s[b - 1] == '\t'): dec b
  if b == a or b - a > MaxIpLiteral: return
  for i in a ..< b:
    let c = s[i]
    if not (c in {'0'..'9', 'a'..'f', 'A'..'F', ':', '.'}): return
  var t = substr(s, a, b - 1)
  var v4 = default(array[4, uint8])
  var v6 = default(array[16, uint8])
  if inet_pton(AF_INET, toCString(t), addr v4) == 1:
    result = addressText(mappedFrom(v4))
  elif inet_pton(AF_INET6, toCString(t), addr v6) == 1:
    result = addressText(v6)

proc shutdownWrite*(fd: cint) =
  ## Half-close: send FIN after whatever is already queued, and keep the
  ## read side open. The peer reads the response, then EOF; reads on `fd`
  ## still deliver what the peer sends.
  discard shutdownSocket(fd, SHUT_WR)

proc sockRecv*(fd: cint; buf: pointer; len: int; flags: cint): int {.inline.} =
  ## `recv(2)`: the bytes received, or -1 with `errno` set. With `MsgDontWait`
  ## the call does not block whatever the fd's own mode.
  recv(fd, buf, csize_t(len), flags)

proc sockSend*(fd: cint; buf: pointer; len: int; flags: cint): int {.
  importc: "send", header: "<sys/socket.h>".}
  ## `send(2)`: the bytes taken, or -1 with `errno` set (`ENOTSOCK` when `fd`
  ## is not a socket). With `MsgDontWait` the call does not block whatever
  ## the fd's own mode.

type
  MsgHdr {.importc: "struct msghdr", header: "<sys/socket.h>".} = object
    ## The C struct itself: only the gather fields are named, and the rest
    ## stay zero.
    msg_iov: nil pointer
    msg_iovlen: int

proc sendmsg(fd: cint; msg: ptr MsgHdr; flags: cint): int {.
  importc, header: "<sys/socket.h>".}

proc sockSendv*(fd: cint; iov: pointer; cnt: int; flags: cint): int =
  ## `sendmsg(2)` of the `cnt` `struct iovec`s at `iov`, with the result
  ## contract of `sockSend`.
  var msg = default(MsgHdr)
  msg.msg_iov = iov
  msg.msg_iovlen = cnt
  sendmsg(fd, addr msg, flags)

proc hasPendingInput*(fd: cint): bool =
  ## Whether the peer has sent bytes that are waiting to be read, checked
  ## without blocking and without taking them. False at EOF and on an error.
  var b = 0'u8
  result = recv(fd, addr b, csize_t(1), MSG_PEEK or MsgDontWait) > 0

proc openFileLimit*(): int =
  ## The soft `RLIMIT_NOFILE`: how many fds this process may hold open, or
  ## -1 when it cannot be read. An unlimited soft limit reads as `high(int)`.
  var r = default(RLimit)
  if getrlimit(RLIMIT_NOFILE, addr r) != 0:
    result = -1
  elif r.rlim_cur > uint64(high(int)):
    result = high(int)
  else:
    result = int(r.rlim_cur)
