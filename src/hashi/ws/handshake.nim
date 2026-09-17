## WebSocket opening handshake (RFC 6455 §4).
##
## The client sends an HTTP/1.1 GET with `Upgrade: websocket`,
## `Connection: Upgrade`, `Sec-WebSocket-Key: <base64 16 bytes>` and
## `Sec-WebSocket-Version: 13`. The server replies `101 Switching Protocols`
## with `Sec-WebSocket-Accept = base64(SHA-1(key + GUID))`.

import std/[sha1, base64, strutils]
import hashi/http/request

const wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # RFC 6455 §1.3

proc acceptKey*(key: string): string =
  ## `Sec-WebSocket-Accept` for a given `Sec-WebSocket-Key` (RFC 6455 §4.2.2).
  var ctx = newSha1State()
  ctx.update(key)
  ctx.update(wsGuid)
  result = encode(ctx.finalize())

proc listHasToken(v: string; token: string): bool =
  ## Is `token` (case-insensitive) a member of the comma-separated list `v`?
  result = false
  for part in split(v, ','):
    if cmpIgnoreCase(strip(part), token) == 0: return true

proc isWebSocketUpgrade*(req: Request): bool =
  ## A valid RFC 6455 §4.1 client opening handshake: GET, `Upgrade: websocket`,
  ## `Connection` list containing `upgrade`, version 13, and a key present.
  result = req.httpMethod == "GET" and
           cmpIgnoreCase(header(req, "Upgrade"), "websocket") == 0 and
           listHasToken(header(req, "Connection"), "upgrade") and
           header(req, "Sec-WebSocket-Version") == "13" and
           header(req, "Sec-WebSocket-Key").len > 0

proc handshakeResponse*(req: Request): string =
  ## The `101 Switching Protocols` response for a valid upgrade (caller checks
  ## `isWebSocketUpgrade` first).
  result = "HTTP/1.1 101 Switching Protocols\r\n" &
           "Upgrade: websocket\r\n" &
           "Connection: Upgrade\r\n" &
           "Sec-WebSocket-Accept: " & acceptKey(header(req, "Sec-WebSocket-Key")) &
           "\r\n\r\n"
