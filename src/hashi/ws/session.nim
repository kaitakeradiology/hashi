## WebSocket session: the app-facing connection handle and handler registry
## for the sequential `.passive` API.
##
## The app writes `proc(ws: WsConn) {.passive.}` and registers it with
## `setWsHandler`. After a successful upgrade the server's connection driver
## calls it directly (awaited) with a fresh `WsConn`; the handler loops
## `wsRecv(ws)` / `wsSend(ws, …)` until it sees a `wmClose`.
##
## This module holds only the shared types and the registry, so `WsConn` is
## one type across the server and the app. The passive I/O ops
## (`wsRecv`/`wsSend`/`wsClose`) live in `hashi/ws/session_io`, imported
## alongside this module.

{.feature: "lenientnils".}   # `outq` is nil until `useOutQueue`

import std/[uri, strutils]
import hashi/ws/protocol
import hashi/ws/outq
import hashi/ws/outq_pacing

type
  WsMsgKind* = enum
    wmText      ## a complete text message (valid UTF-8, validated by the protocol layer)
    wmBinary    ## a complete binary message
    wmClose     ## the peer closed, an error closed, or the socket hit EOF — stop
    wmNone      ## wsPeek only: no complete message buffered

  WsMessage* = object
    ## One delivery from `wsRecv`. Control frames (ping/pong) and the close
    ## handshake are handled inside `wsRecv`; only these reach the handler.
    kind*: WsMsgKind
    data*: string         ## message payload (wmText/wmBinary); close reason (wmClose)

  WsConn* = ref object
    ## Per-connection handle, passed to the app handler and to every I/O op
    ## in `hashi/ws/session_io`. A `ref` so passive ops (which cannot take
    ## `var` params) mutate it in place.
    fd*: cint                     ## the client socket
    acc*: string                  ## buffered, not-yet-parsed inbound bytes
    st*: WsState                  ## fragmentation / protocol state
    open*: bool                   ## false once closed or EOF — the handler's loop guard
    clientIp*: string             ## peer / X-Forwarded-For IP, for app-level logging
    cookie*: string               ## raw `Cookie` header from the upgrade — app auth on connect
    path*: string                 ## request-target of the upgrade — app path-dispatch (>1 WS endpoint)
    rbuf*: array[4096, byte]      ## reusable read buffer
    # Per-connection send instrumentation, for app-side telemetry.
    sendBlockedNs*: int64         ## cumulative ns suspended in waitWrite (backpressure)
    bytesSent*: int64             ## cumulative data-message payload bytes sent
    writeSyscalls*: int           ## cumulative waitWrite calls (validates send coalescing)
    sbuf*: seq[byte]              ## reusable [header|payload] buffer for coalesced wsSend
    # wsPeek stash: a message drained by wsPeek but not yet skipped/delivered.
    peeked*: WsMessage            ## the complete data message wsPeek last stashed (valid iff hasPeeked)
    hasPeeked*: bool              ## true while `peeked` holds a stashed message awaiting wsSkip/wsRecv
    # Opt-in outbound queue; see `hashi/ws/outq`.
    outq*: OutQueue               ## nil until `useOutQueue` installs one; valid iff `hasOutq`
    hasOutq*: bool                ## true once queued mode is on: all writes go through the
                                  ## queue's single writer instead of the fd directly

  WsHandler* = proc(ws: WsConn) {.passive.}
    ## App handler. Called once per upgraded connection; owns it until it returns.

var gWsHandler*: WsHandler
  ## The registered app handler. A passive proc-value has no nil form, so
  ## `gHasWsHandler` tracks whether it was actually set.
var gHasWsHandler = false

proc setWsHandler*(h: WsHandler) =
  ## Register the WebSocket handler. Call before `serve`.
  gWsHandler = h
  gHasWsHandler = true

proc hasWsHandler*(): bool =
  ## True once `setWsHandler` has been called.
  result = gHasWsHandler

proc newWsConn*(fd: cint; initial: string; clientIp = "";
                cookie = ""; path = ""): WsConn =
  ## A fresh connection handle after upgrade; `initial` is any post-handshake
  ## bytes already read (the start of the first frame); `clientIp` is the
  ## resolved peer address for app logging. `cookie`/`path` carry the upgrade
  ## request's `Cookie` header + request-target so the handler can authenticate
  ## the connection and route by path (passive handlers never see the Request).
  result = WsConn(fd: fd, acc: initial, st: default(WsState), open: true,
                  clientIp: clientIp, cookie: cookie, path: path, sbuf: @[],
                  peeked: WsMessage(kind: wmNone, data: ""), hasPeeked: false,
                  hasOutq: false)

proc useOutQueue*(ws: WsConn; q: OutQueue) =
  ## Put this connection into queued mode: `wsRecv`/`wsPeek`/`wsSend`/`wsClose`
  ## stop writing to the socket directly and enqueue onto `q` instead, so the
  ## writer loop is the only task that ever touches the fd. The caller must
  ## then run `wsWriterLoop(ws, q)` (see `hashi/ws/outq_writer`) as its own
  ## task and join it before the driver closes the fd.
  ##
  ## Also applies `q.pacingBytes` as the socket's `SO_SNDBUF` (see
  ## `setWsSendBuf`), since bytes already handed to the kernel cannot be
  ## reordered — a queue without a paced socket still lets a control message
  ## wait behind whatever is already in the send buffer. Call before any byte
  ## flows, i.e. at accept, and before the writer loop starts. A failed
  ## `setWsSendBuf` is ignored: the connection is then unpaced but still
  ## correct.
  ws.outq = q
  ws.hasOutq = true
  discard setWsSendBuf(ws.fd, q.pacingBytes)

var gAllowedOrigins: seq[string] = @[]
  ## The WS-upgrade `Origin` allowlist, checked by the server before the 101
  ## response (see `originAllowed`).

proc setAllowedOrigins*(origins: seq[string]) =
  ## Configure the WS-upgrade `Origin` allowlist. Call before `serve`.
  gAllowedOrigins = origins

proc originAllowed*(origin: string): bool =
  ## A WS upgrade is allowed when it carries no `Origin` (a native, non-browser
  ## client — not a cross-site WebSocket-hijack vector) or an `Origin` on the
  ## allowlist. An empty allowlist therefore admits only no-Origin clients.
  if origin.len == 0: return true
  var i = 0
  while i < gAllowedOrigins.len:
    if gAllowedOrigins[i] == origin: return true
    i = i + 1
  result = false

proc originMatchesHost*(origin, host: string): bool =
  ## True when an `Origin`'s authority (host[:port]) case-insensitively equals the
  ## request `Host` — i.e. a same-origin WS upgrade. Lets a browser connect to the
  ## page's own server with no explicit allowlist entry, while cross-origin upgrades
  ## still require `setAllowedOrigins`. Defence-in-depth alongside cookie auth on
  ## connect (a SameSite=Lax session cookie isn't sent on cross-site WS anyway).
  if origin.len == 0 or host.len == 0: return false
  let u = parseUri(origin)
  if u.scheme.len == 0 or u.opaque or u.hostname.len == 0: return false
  var authority = if u.isIpv6: "[" & u.hostname & "]" else: u.hostname
  if u.port.len > 0:
    authority.add ':'
    authority.add u.port
  result = cmpIgnoreCase(authority, host) == 0
