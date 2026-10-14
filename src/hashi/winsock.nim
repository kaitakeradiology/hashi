## The Winsock surface `hashi/net` needs on Windows, under the names and
## shapes of the POSIX declarations it replaces there, so `net`'s shared code
## reads the same on both. Internal to hashi; nothing here is public API.
##
## The fd is a `SOCKET` (a 64-bit handle) narrowed to `cint`, the convention
## `std/ioring`'s Windows arm sets: socket handles are small 4-aligned kernel
## handles, and `socketOf` widens one back. A handle too large for a `cint` is
## refused where it is created (`socket`), never truncated.
##
## Bound by `dynlib` (the winlean house style) rather than through
## `<winsock2.h>`, so the generated C never has to order that header against
## winlean's `<Windows.h>`. `std/ioring` links ws2_32.

when not defined(windows):
  {.error: "hashi/winsock is the Windows arm of hashi/net".}

from std/ioring import Sockaddr_in, SockLen
export Sockaddr_in, SockLen

{.passL: "-lws2_32".}

type
  WinSocket = uint     ## `SOCKET` (UINT_PTR)
  CSockAddr* = object
    ## Winsock's `struct sockaddr`; `bind` and the name calls take a pointer to
    ## this, as the casts in `hashi/net` expect.
    sa_family: uint16
    sa_data: array[14, char]
  Sockaddr_in6* = object
    ## `SOCKADDR_IN6`: 28 bytes, the same layout as Linux's.
    sin6_family*: uint16
    sin6_port*: uint16            ## network byte order
    sin6_flowinfo*: uint32
    sin6_addr*: array[16, uint8]
    sin6_scope_id*: uint32

const
  AF_INET* = 2.cint
  AF_INET6* = 23.cint
  SOCK_STREAM* = 1.cint
  IPPROTO_TCP* = 6.cint
  IPPROTO_IPV6* = 41.cint
  SOL_SOCKET* = 0xFFFF.cint
  SO_REUSEADDR* = 4.cint
  SO_EXCLUSIVEADDRUSE* = cast[cint](0xFFFFFFFB'u32)
    ## `~SO_REUSEADDR`: nobody else may bind this port, `SO_REUSEADDR` or not.
    ## Winsock's `SO_REUSEADDR` lets a second socket bind a live listener's port
    ## and take its connections; it is not the POSIX "restart without
    ## TIME_WAIT" option.
  SO_KEEPALIVE* = 8.cint
  SO_SNDBUF* = 0x1001.cint
  IPV6_V6ONLY* = 27.cint
  TCP_NODELAY* = 1.cint
  TCP_KEEPIDLE* = 3.cint
  TCP_KEEPCNT* = 16.cint
  TCP_KEEPINTVL* = 17.cint
  SHUT_WR* = 1.cint
  SHUT_RDWR* = 2.cint
  MSG_PEEK* = 2.cint
  INET6_ADDRSTRLEN* = 46
  EADDRNOTAVAIL* = 10049.cint     ## WSAEADDRNOTAVAIL
  EAFNOSUPPORT* = 10047.cint      ## WSAEAFNOSUPPORT
  EWOULDBLOCK* = 10035.cint       ## WSAEWOULDBLOCK
  EINTR* = 10004.cint             ## WSAEINTR
  WSA_FLAG_OVERLAPPED = 0x01'u32
  WSA_FLAG_NO_HANDLE_INHERIT = 0x80'u32
  FIONBIO = cast[clong](0x8004667E'u32)   ## _IOW('f', 126, u_long)
  HANDLE_FLAG_INHERIT = 1'u32
  InvalidSocket = not 0'u

proc wsaSocketW(af, typ, protocol: cint; info: nil pointer; group: uint32;
                flags: uint32): WinSocket {.
  stdcall, importc: "WSASocketW", dynlib: "ws2_32.dll".}
proc wsSetsockopt(s: WinSocket; level, optname: cint; optval: pointer;
                  optlen: cint): cint {.
  stdcall, importc: "setsockopt", dynlib: "ws2_32.dll".}
proc wsBind(s: WinSocket; name: pointer; namelen: cint): cint {.
  stdcall, importc: "bind", dynlib: "ws2_32.dll".}
proc wsListen(s: WinSocket; backlog: cint): cint {.
  stdcall, importc: "listen", dynlib: "ws2_32.dll".}
proc wsIoctlsocket(s: WinSocket; cmd: clong; argp: ptr culong): cint {.
  stdcall, importc: "ioctlsocket", dynlib: "ws2_32.dll".}
proc wsClosesocket(s: WinSocket): cint {.
  stdcall, importc: "closesocket", dynlib: "ws2_32.dll".}
proc wsGetpeername(s: WinSocket; name: pointer; namelen: ptr cint): cint {.
  stdcall, importc: "getpeername", dynlib: "ws2_32.dll".}
proc wsGetsockname(s: WinSocket; name: pointer; namelen: ptr cint): cint {.
  stdcall, importc: "getsockname", dynlib: "ws2_32.dll".}
proc wsShutdown(s: WinSocket; how: cint): cint {.
  stdcall, importc: "shutdown", dynlib: "ws2_32.dll".}
proc wsRecv(s: WinSocket; buf: pointer; len, flags: cint): cint {.
  stdcall, importc: "recv", dynlib: "ws2_32.dll".}
proc wsSend(s: WinSocket; buf: pointer; len, flags: cint): cint {.
  stdcall, importc: "send", dynlib: "ws2_32.dll".}
proc wsInetPton(af: cint; src: cstring; dst: pointer): cint {.
  stdcall, importc: "inet_pton", dynlib: "ws2_32.dll".}
proc wsInetNtop(af: cint; src: pointer; dst: cstring; size: csize_t): cstring {.
  stdcall, importc: "inet_ntop", dynlib: "ws2_32.dll".}
proc wsaGetLastError(): cint {.
  stdcall, importc: "WSAGetLastError", dynlib: "ws2_32.dll".}
proc setHandleInformation(h: WinSocket; mask, flags: uint32): int32 {.
  stdcall, importc: "SetHandleInformation", dynlib: "kernel32".}

proc socketOf(fd: cint): WinSocket {.inline.} =
  WinSocket(cast[uint32](fd))

proc errno*(): cint =
  ## `WSAGetLastError()`, this thread's last Winsock error: the `errno` of the
  ## POSIX arm.
  wsaGetLastError()

proc htons*(x: uint16): uint16 {.inline.} = (x shl 8) or (x shr 8)
proc ntohs*(x: uint16): uint16 {.inline.} = (x shl 8) or (x shr 8)

proc socket*(domain, typ, protocol: cint): cint =
  ## A new TCP socket that is overlapped (what the ring's IOCP backend needs for
  ## `AcceptEx`) and NOT inheritable by child processes from its first moment
  ## (`WSA_FLAG_NO_HANDLE_INHERIT`), so a process spawned on another thread can
  ## never hold a copy of the listener. -1 on failure, `errno()` set; a handle
  ## that does not fit a `cint` is closed and refused.
  let s = wsaSocketW(domain, typ, protocol, nil, 0'u32,
                     WSA_FLAG_OVERLAPPED or WSA_FLAG_NO_HANDLE_INHERIT)
  if s == InvalidSocket: return -1.cint
  if s > WinSocket(high(cint)):
    discard wsClosesocket(s)
    return -1.cint
  result = cint(cast[uint32](s))

proc setNoInherit*(fd: cint): bool =
  ## Clear the inherit flag of `fd`'s handle: a child process created by this
  ## one does not receive the socket. For sockets the ring accepted (their
  ## inheritance is whatever AcceptEx left them with).
  setHandleInformation(socketOf(fd), HANDLE_FLAG_INHERIT, 0'u32) != 0

proc setsockopt*(s, level, optname: cint; optval: pointer; optlen: SockLen): cint =
  wsSetsockopt(socketOf(s), level, optname, optval, optlen)

proc bindSocket*(s: cint; name: ptr CSockAddr; namelen: SockLen): cint =
  wsBind(socketOf(s), name, namelen)

proc listenSocket*(s, backlog: cint): cint =
  wsListen(socketOf(s), backlog)

proc setNonBlockingSocket*(fd: cint) =
  var one: culong = 1
  discard wsIoctlsocket(socketOf(fd), FIONBIO, addr one)

proc close*(fd: cint): cint =
  ## `closesocket`.
  wsClosesocket(socketOf(fd))

proc getpeername*(fd: cint; sa: ptr CSockAddr; len: ptr SockLen): cint =
  wsGetpeername(socketOf(fd), sa, len)

proc getsockname*(fd: cint; sa: ptr CSockAddr; len: ptr SockLen): cint =
  wsGetsockname(socketOf(fd), sa, len)

proc shutdownSocket*(fd, how: cint): cint =
  wsShutdown(socketOf(fd), how)

proc recv*(fd: cint; buf: pointer; len: csize_t; flags: cint): int =
  int(wsRecv(socketOf(fd), buf, cint(len), flags))

proc send*(fd: cint; buf: pointer; len: int; flags: cint): int =
  int(wsSend(socketOf(fd), buf, cint(len), flags))

proc inet_pton*(af: cint; src: cstring; dst: pointer): cint =
  wsInetPton(af, src, dst)

proc inet_ntop*(af: cint; src: pointer; dst: cstring; size: SockLen): cstring =
  wsInetNtop(af, src, dst, csize_t(size))
