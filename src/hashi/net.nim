## Sockets: listen-socket setup with structured failure, the peer's address,
## and the per-connection options the server applies at accept.
##
## `tryListenTcp` creates the listening socket and, instead of asserting on
## a failed `socket`, `bind` or `listen`, reports the failing call and its
## `errno` in a `ListenResult`, so `serve` can print a clear message and exit
## non-zero. `listenError` renders that result for an operator. The socket
## calls and constants here are Linux's; this is the module to port first
## for another platform.

from std/posix/posix import close, fcntl, F_GETFL, F_SETFL, O_NONBLOCK,
  AF_INET, AF_INET6, SOCK_STREAM, IPPROTO_TCP, IPPROTO_IPV6, SOL_SOCKET,
  SO_REUSEADDR, Sockaddr_in, SockLen
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
  INET6_ADDRSTRLEN = 46

proc socket(domain, typ, protocol: cint): cint {.importc, header: "<sys/socket.h>".}
proc setsockopt(s, level, optname: cint; optval: pointer; optlen: SockLen): cint {.
  importc, header: "<sys/socket.h>".}
proc bindSocket(s: cint; name: ptr CSockAddr; namelen: SockLen): cint {.
  importc: "bind", header: "<sys/socket.h>".}
proc listenSocket(s, backlog: cint): cint {.importc: "listen", header: "<sys/socket.h>".}
proc htons(x: uint16): uint16 {.importc, header: "<arpa/inet.h>".}
proc inet_pton(af: cint; src: cstring; dst: pointer): cint {.
  importc, header: "<arpa/inet.h>".}
proc inet_ntop(af: cint; src: pointer; dst: cstring; size: SockLen): cstring {.
  importc, header: "<arpa/inet.h>".}
proc getpeername(fd: cint; sa: ptr CSockAddr; len: ptr SockLen): cint {.
  importc, header: "<sys/socket.h>".}
proc signal(signum: cint; handler: pointer): pointer {.
  importc, header: "<signal.h>".}

var errno {.importc: "errno", header: "<errno.h>".}: cint

const EADDRINUSE* = 98.cint   ## Linux `errno`: address already in use.

type
  ListenResult* = object
    ## Outcome of `tryListenTcp`. When `ok`, `fd` is a bound, listening,
    ## non-blocking socket; otherwise `stage` and `err` name the failing call.
    ok*: bool       ## true when bound and listening
    fd*: cint       ## the listening fd when `ok`, -1 otherwise
    err*: cint      ## `errno` of the failing call, 0 when `ok`
    stage*: string  ## the failing call: "socket", "bind", "listen" or "bindaddr"

proc tryListenTcp*(port: uint16; backlog = 4096; bindAddr = ""): ListenResult =
  ## Create a non-blocking TCP listen socket on `port`. Never asserts.
  ##
  ## `backlog` is the accept queue; the kernel clamps it to `somaxconn`. A
  ## queue that is too short drops SYNs under connection churn, which the
  ## client sees as one-second retransmit stalls rather than as an error.
  ##
  ## `bindAddr` is an address literal, never a hostname:
  ##   - `""` or `"::"`: dual-stack wildcard (an IPv6 socket with
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
  let dual = bindAddr.len == 0 or bindAddr == "::"
  var a4 = default(Sockaddr_in)
  a4.sin_family = uint16(AF_INET)
  a4.sin_port = htons(port)
  var a6 = default(Sockaddr_in6)
  a6.sin6_family = uint16(AF_INET6)
  a6.sin6_port = htons(port)
  var v6 = true
  if not dual and bindAddr != "::0":
    var ba = bindAddr
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

proc peerAddress*(fd: cint): string =
  ## The socket peer's address as text: dotted quad for IPv4 and for
  ## IPv4-mapped IPv6 (what a dual-stack listener sees from IPv4 clients),
  ## full IPv6 text otherwise, "?" if unavailable.
  var sa6 = default(Sockaddr_in6)   # large enough for a sockaddr_in too
  var sl = SockLen(sizeof(sa6))
  if getpeername(fd, cast[ptr CSockAddr](addr sa6), addr sl) != 0:
    return "?"
  if sa6.sin6_family == uint16(AF_INET6):
    var mapped = true
    for i in 0 ..< 10:
      if sa6.sin6_addr[i] != 0'u8: mapped = false
    if mapped and sa6.sin6_addr[10] == 0xff'u8 and sa6.sin6_addr[11] == 0xff'u8:
      result = $int(sa6.sin6_addr[12]) & "." & $int(sa6.sin6_addr[13]) & "." &
               $int(sa6.sin6_addr[14]) & "." & $int(sa6.sin6_addr[15])
    else:
      var buf = default(array[INET6_ADDRSTRLEN, char])
      discard inet_ntop(AF_INET6, addr sa6.sin6_addr, cast[cstring](addr buf[0]),
                        SockLen(INET6_ADDRSTRLEN))
      result = ""
      for c in buf:
        if c == char(0): break
        result.add c
  else:
    let a = cast[ptr Sockaddr_in](addr sa6).sin_addr.s_addr
    result = $int(a and 0xff'u32) & "." & $int((a shr 8) and 0xff'u32) & "." &
             $int((a shr 16) and 0xff'u32) & "." & $int((a shr 24) and 0xff'u32)
