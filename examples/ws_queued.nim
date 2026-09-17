## A WebSocket connection written by two tasks: a background stream on the
## STREAM lane and echoed replies on the CONTROL lane, through the outbound
## queue so a reply never waits behind the stream's backlog.
##
## Connect with any WebSocket client: binary frames arrive continuously,
## and every text frame comes straight back.

import hashi

proc stream(ws: WsConn; q: OutQueue) {.passive.} =
  ## Saturating producer. `eqFull` is healthy backpressure on a slow client,
  ## not a dead one: park on the lane's space signal and retry.
  var chunk = newSeq[byte](32 * 1024)
  while ws.open:
    case wsEnqueue(q, lnStream, chunk, true, 1)
    of eqClosed: ws.open = false
    of eqFull: wsAwaitSpace(q, lnStream)
    of eqOk: discard

proc onWs(ws: WsConn) {.passive.} =
  let q = newOutQueue()
  useOutQueue(ws, q)                  # the writer loop now owns the socket
  spawnTask wsWriterLoop(ws, q)
  spawnTask stream(ws, q)
  while ws.open:
    let m = wsRecv(ws)
    if m.kind == wmText:
      # The CONTROL lane is bounded too; park on it the same way.
      var queued = false
      while not queued:
        case wsEnqueue(q, lnControl, m.data, false)
        of eqFull: wsAwaitSpace(q, lnControl)
        else: queued = true
    elif m.kind == wmClose:
      ws.open = false
  submitAll(closeQueue(q))
  wsAwaitWriterDone(q)                # never close the fd under a live writer

setWsHandler(onWs)
serve(8080'u16)
