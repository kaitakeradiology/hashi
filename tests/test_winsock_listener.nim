## Windows only (D3-1..D3-3, F3): the listener's exclusivity, its
## non-inheritance, and handles above MaxFds. Run on the Windows builder; on
## other platforms it compiles to a no-op that says so.
##
##   - a second socket cannot bind a live listener's port, with or without
##     SO_REUSEADDR (Winsock's SO_REUSEADDR would let it hijack the port;
##     tryListenTcp sets SO_EXCLUSIVEADDRUSE);
##   - the listener's handle carries no HANDLE_FLAG_INHERIT;
##   - a handle value above MaxFds is tracked by the deadline table (the many-
##     sockets loop is bounded: at most MaxSockets creations, all closed).
import std/syncio
import testkit

when defined(windows):
  import hashi/winsock
  import hashi/net
  import hashi/http/connreg

  proc getHandleInformation(h: uint; flags: ptr uint32): int32 {.
    stdcall, importc: "GetHandleInformation", dynlib: "kernel32".}

  const
    MaxSockets = 4000      # bound on the many-handles loop
    InheritFlag = 1'u32

  proc inheritable(fd: cint): bool =
    var fl = 0'u32
    discard getHandleInformation(uint(cast[uint32](fd)), addr fl)
    (fl and InheritFlag) != 0'u32

  proc portOf(fd: cint): uint16 =
    var sa = default(array[28, uint8])
    var sl = SockLen(sizeof(sa))
    if getsockname(fd, cast[ptr CSockAddr](addr sa[0]), addr sl) != 0: return 0'u16
    result = (uint16(sa[2]) shl 8) or uint16(sa[3])

  proc tryBind(fd: cint; port: uint16): cint =
    var a = default(Sockaddr_in)
    a.sin_family = uint16(AF_INET)
    a.sin_port = htons(port)
    a.sin_addr.s_addr = 0x0100007F'u32   # 127.0.0.1
    bindSocket(fd, cast[ptr CSockAddr](addr a), SockLen(sizeof(a)))

  proc main() =
    section "the listener is exclusive and private"
    let l = tryListenTcp(0, bindAddr = "127.0.0.1")
    check l.ok, "listens on 127.0.0.1:0 (stage " & l.stage & ", err " & $l.err.int & ")"
    let port = portOf(l.fd)
    check port != 0, "has a port"
    check not inheritable(l.fd), "the listener handle has no inherit flag"

    let s1 = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    check s1 >= 0, "second socket created"
    check tryBind(s1, port) != 0, "a plain second bind to the live port fails"
    discard close(s1)

    let s2 = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var yes: cint = 1
    discard setsockopt(s2, SOL_SOCKET, SO_REUSEADDR, addr yes, SockLen(sizeof(yes)))
    check tryBind(s2, port) != 0, "and so does one with SO_REUSEADDR (no hijack)"
    check errno() != 0, "with a Winsock error (" & $errno().int & ")"
    discard close(s2)

    check claimPort(-1.cint) != 0, "claimPort on a bad handle fails (the fail-closed input)"
    discard close(l.fd)

    section "handles above MaxFds are tracked"
    var socks: seq[cint] = @[]
    var high = -1.cint
    var i = 0
    while i < MaxSockets and high < 0:
      let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      if s < 0: break
      socks.add s
      if s.int > MaxFds: high = s
      i = i + 1
    check high >= 0, "reached a handle above " & $MaxFds & " within " & $MaxSockets & " sockets"
    if high >= 0:
      check fdTracked(high), "the handle " & $high.int & " is tracked"
      setDeadline(high, 4242'i64)
      check deadlineOf(high) == 4242'i64, "its deadline reads back"
      clearConn(high)
      check deadlineOf(high) == 0'i64, "and clears"
    for s in socks: discard close(s)
    finish()

  main()
else:
  echo "test_winsock_listener: Windows only; skipped"
