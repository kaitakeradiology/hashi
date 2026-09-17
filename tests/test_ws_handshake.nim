## WebSocket handshake unit tests (RFC 6455 §1.3 / §4.2.2).

import std/syncio
import hashi/http/request   # Header, Request, Http11
import std/base64
import hashi/ws/handshake
import testkit

# ── base64 (RFC 4648 test vectors) ─────────────────────────────────────
section "base64"

proc b64(s: string): string =
  var bytes = default(seq[uint8])
  var i = 0
  while i < s.len:
    bytes.add uint8(s[i])
    i = i + 1
  result = encode(bytes)

block:
  check b64("") == "", "empty"
  check b64("f") == "Zg==", "1 byte -> 2 pad"
  check b64("fo") == "Zm8=", "2 bytes -> 1 pad"
  check b64("foo") == "Zm9v", "3 bytes -> no pad"
  check b64("foob") == "Zm9vYg==", "4 bytes"
  check b64("fooba") == "Zm9vYmE=", "5 bytes"
  check b64("foobar") == "Zm9vYmFy", "6 bytes"

# ── Sec-WebSocket-Accept (RFC 6455 §1.3 canonical example) ─────────────
section "accept key"

block:
  # RFC 6455: key "dGhlIHNhbXBsZSBub25jZQ==" -> "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
  check acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    "RFC 6455 canonical accept key"

# ── upgrade detection ──────────────────────────────────────────────────
section "upgrade detection"

proc upgradeReq(hs: seq[Header]; meth = "GET"): Request =
  result = default(Request)
  result.httpMethod = meth
  result.target = "/chat"
  result.version = Http11
  result.headers = hs

block:
  let r = upgradeReq(@[
    Header(name: "Upgrade", value: "websocket"),
    Header(name: "Connection", value: "Upgrade"),
    Header(name: "Sec-WebSocket-Key", value: "dGhlIHNhbXBsZSBub25jZQ=="),
    Header(name: "Sec-WebSocket-Version", value: "13")])
  check isWebSocketUpgrade(r), "valid upgrade detected"
  check handshakeResponse(r) ==
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" &
    "Connection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n",
    "101 response built"

block:
  # case-insensitive header names + Connection token list
  let r = upgradeReq(@[
    Header(name: "upgrade", value: "WebSocket"),
    Header(name: "connection", value: "keep-alive, Upgrade"),
    Header(name: "sec-websocket-key", value: "x"),
    Header(name: "sec-websocket-version", value: "13")])
  check isWebSocketUpgrade(r), "case-insensitive + Connection list accepted"

block:
  let r = upgradeReq(@[
    Header(name: "Upgrade", value: "websocket"),
    Header(name: "Connection", value: "Upgrade"),
    Header(name: "Sec-WebSocket-Key", value: "x"),
    Header(name: "Sec-WebSocket-Version", value: "8")])
  check not isWebSocketUpgrade(r), "wrong version rejected"

block:
  let r = upgradeReq(@[
    Header(name: "Upgrade", value: "websocket"),
    Header(name: "Connection", value: "Upgrade"),
    Header(name: "Sec-WebSocket-Version", value: "13")])
  check not isWebSocketUpgrade(r), "missing key rejected"

block:
  let r = upgradeReq(@[
    Header(name: "Upgrade", value: "websocket"),
    Header(name: "Connection", value: "Upgrade"),
    Header(name: "Sec-WebSocket-Key", value: "x"),
    Header(name: "Sec-WebSocket-Version", value: "13")], meth = "POST")
  check not isWebSocketUpgrade(r), "non-GET rejected"

finish()
