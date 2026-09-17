## Unit tests for the WebSocket session handle + registry (the pure surface).
## The passive I/O (wsRecv/wsSend/wsClose) is covered end-to-end by the RFC 6455
## conformance harness (tests/conformance/ws_conformance.py) against examples/ws_echo.nim.

import std/syncio
import hashi/ws/session
import testkit

section "ws session — handler registry"
check not hasWsHandler(), "no handler registered initially"

section "ws session — newWsConn"
let ws = newWsConn(7.cint, "abc")
check ws.fd == 7.cint, "newWsConn sets the fd"
check ws.acc == "abc", "newWsConn seeds acc with the post-handshake bytes"
check ws.open, "a fresh connection starts open"

let ws2 = newWsConn(9.cint, "")
check ws2.acc.len == 0, "empty initial leftover → empty acc"
check ws2.open, "second connection also starts open"

finish()
