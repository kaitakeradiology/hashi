## Minimal WebSocket echo server using hashi's sequential `.passive` handler
## API. Demonstrates the seam: register a `proc(ws: WsConn) {.passive.}`, loop
## `wsRecv` → `wsSend` until the peer closes.
##
## `import hashi` brings in `setWsHandler`, the `WsConn` type and the passive
## `wsRecv`/`wsSend` ops.

import hashi

proc onWs(ws: WsConn) {.passive.} =
  while ws.open:
    let m = wsRecv(ws)
    if m.kind == wmClose:
      ws.open = false
    else:
      # echo the message back, preserving text/binary
      if not wsSend(ws, m.data, m.kind == wmBinary):
        ws.open = false

setWsHandler(onWs)
serve(8080'u16)
