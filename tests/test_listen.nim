## Unit tests for clean listen-socket setup + port-in-use failure.
##
## `tryListenTcp` must bind+listen without asserting, and on a port already in
## use return a structured failure (errno EADDRINUSE at the bind stage) rather
## than crashing — the basis for `serve()`'s clean "port in use" exit.

import std/syncio
import hashi/net
from std/posix/posix import close
import testkit

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

# Convention (the Mummy-patch model): ""/"::" dual-stack wildcard, "::0"
# v6-only wildcard, "0.0.0.0" v4 wildcard, any other literal = that specific
# address; never a hostname. Distinct port per case.
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

finish()
