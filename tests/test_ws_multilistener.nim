## Unit tests for addWsListener — the secondary WS-only listener registry.
## This covers the pure registration surface (slot accounting + the table cap).
## The live behaviour (101 on a WS upgrade, 426 on a plain HTTP request to a
## WS-only port, both listeners on one reactor) is verified end to end — a
## serve() loop can't run in a unit test.

import std/syncio
import hashi/http/server
import hashi/ws/session
import testkit

proc dummyWs(ws: WsConn) {.passive.} =
  ws.open = false

section "addWsListener — registration + table cap"
# Written against `MaxExtraListeners`, not a hardcoded 3: the slots became an
# array walked by index (the three named globals and their two `case` arms are
# gone), so raising the cap is now editing one number — and a test that pins the
# old number would fail for the wrong reason when someone does.
check addWsListener(9001'u16, dummyWs, "127.0.0.1"), "first extra listener registers"
var p = 1
while p < MaxExtraListeners:
  check addWsListener((9001 + p).uint16, dummyWs), "listener " & $p & " registers (below the cap)"
  p = p + 1
check not addWsListener((9001 + MaxExtraListeners).uint16, dummyWs),
      "the one past MaxExtraListeners is refused — table full"
check not addWsListener((9002 + MaxExtraListeners).uint16, dummyWs),
      "still refused on a second attempt"

finish()
