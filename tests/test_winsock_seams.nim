## The seams the Windows arm adds, checked on every platform:
##
##   - `claimPort` (SO_EXCLUSIVEADDRUSE on Windows, SO_REUSEADDR on Linux) reports
##     a failed setsockopt instead of hiding it, and `tryListenTcp` turns that
##     into a "sockopt" stage on Windows (fail CLOSED) while Linux, as always,
##     ignores it. The Linux half cannot make setsockopt fail on a live socket,
##     so the failure itself is driven with a bad fd; on Windows the same call
##     runs against Winsock (tests/run on deathstar).
##   - `listenError` renders the new stages.
##   - The deadline table is keyed by `fdSlot`: a POSIX fd is its own slot; a
##     Winsock handle (a multiple of four) is `handle shr 2`, so handles far
##     above `MaxFds` are tracked, while `MaxFds` stays the slot count.
import std/syncio
when defined(posix):
  from std/posix/posix import close
import hashi/net      # on Windows also exports `close`
import hashi/http/connreg
import testkit

proc main() =
  section "claimPort reports a failed setsockopt"
  check claimPort(-1.cint) != 0, "a bad fd fails (the error is not swallowed)"

  section "tryListenTcp still listens"
  let a = tryListenTcp(0, bindAddr = "127.0.0.1")
  check a.ok, "listens on 127.0.0.1:0"
  check a.stage == "", "no failing stage"
  when not defined(windows):
    check claimPort(a.fd) == 0, "SO_REUSEADDR on a live socket succeeds (Linux)"
  discard close(a.fd)

  section "listenError renders the sockopt and noinherit stages"
  let so = ListenResult(ok: false, fd: -1, err: 5, stage: "sockopt")
  check listenError(so, 8080) != "sockopt() failed for port 8080 (errno 5)",
        "sockopt has its own wording"
  let ni = ListenResult(ok: false, fd: -1, err: 5, stage: "noinherit")
  check listenError(ni, 8080) != "noinherit() failed for port 8080 (errno 5)",
        "noinherit has its own wording"

  section "fdSlot: a slot per fd on POSIX, per four handle values on Windows"
  check fdSlot(-1.cint) == -1, "a negative fd has no slot"
  check not fdTracked(-1.cint), "and is not tracked"
  when defined(windows):
    check fdSlot(4.cint) == 1, "handle 4 is slot 1"
    check fdSlot(20_000.cint) == 5_000, "handle 20000 is slot 5000"
    check fdTracked(20_000.cint), "a handle above MaxFds is tracked"
    check fdTracked(cint(MaxFds * 4 - 4)), "the last tracked handle"
    check not fdTracked(cint(MaxFds * 4)), "the first untracked handle"
    let h = 20_000.cint
    setDeadline(h, 777'i64)
    check deadlineOf(h) == 777'i64, "a deadline armed on a handle above MaxFds reads back"
    clearConn(h)
    check deadlineOf(h) == 0'i64, "and clears"
  else:
    check fdSlot(5.cint) == 5, "a POSIX fd is its own slot"
    check fdTracked(cint(MaxFds - 1)), "the last tracked fd"
    check not fdTracked(cint(MaxFds)), "the first untracked fd"
    let f = cint(MaxFds - 1)
    setDeadline(f, 777'i64)
    check deadlineOf(f) == 777'i64, "a deadline armed on the last fd reads back"
    clearConn(f)
    check deadlineOf(f) == 0'i64, "and clears"
    setDeadline(cint(MaxFds), 5'i64)
    check deadlineOf(cint(MaxFds)) == 0'i64, "an fd at MaxFds is never armed"
  finish()

main()
