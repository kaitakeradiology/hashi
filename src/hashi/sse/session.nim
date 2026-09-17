## Server-Sent Events: the handler registry and the match helpers the
## connection driver uses.
##
## An SSE response is a stream: the server holds the connection open and
## pushes `text/event-stream` events over time, so the handler takes over the
## socket rather than returning one `Response`. Register a
## `proc(req: Request; fd: cint) {.passive.}` with `setSseHandler`, paired
## with an `SseMatch` predicate that says which requests are streams. For a
## matching request the driver runs the pre-dispatch middleware first, so the
## endpoint is gated like any route, and on a clean pass hands the fd to the
## handler. The handler writes the `200 text/event-stream` head and the events
## itself, using `waitWrite` from `hashi/loop`, and owns the
## connection until it returns.

import hashi/http/request

type
  SseHandler* = proc(req: Request; fd: cint) {.passive.}
    ## The stream handler. Called with the raw client fd once the request has
    ## matched and passed the middleware; the driver closes the fd when it
    ## returns.

  SseMatch* = proc(req: Request): bool {.nimcall.}
    ## Predicate selecting the requests served as SSE streams.

# A passive proc value has no nil form, so a separate flag records whether
# one is registered.
var gSseHandler*: SseHandler
var gSseMatch: SseMatch
var gHasSse = false

proc setSseHandler*(match: SseMatch; h: SseHandler) =
  ## Register the match predicate and the handler. Call before `serve`. There
  ## is one handler; an app with several SSE endpoints dispatches inside it.
  gSseMatch = match
  gSseHandler = h
  gHasSse = true

proc hasSseHandler*(): bool =
  ## True once `setSseHandler` has been called.
  result = gHasSse

proc sseMatches*(req: Request): bool =
  ## Whether `req` should be served by the registered SSE handler. False when
  ## none is registered.
  result = gHasSse and gSseMatch(req)
