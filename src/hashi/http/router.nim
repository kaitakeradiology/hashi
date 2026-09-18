## HTTP router: maps (method, request-target) to a handler.
##
## Pure — no I/O, no reactor. The matching logic (`match`/`matchRoute`) and
## the dispatch decision (`dispatch`) are independent of the connection
## driver, so they are unit-testable on their own. `hashi/http/server` owns a
## process-global `Router` that the app fills via the verb helpers (`get`,
## `post`, …), and the connection driver calls `dispatch` per request.
##
## Matching is segment-based (path split on `/`, empty segments dropped so a
## trailing slash is ignored). Per pattern segment:
##   - a literal — must equal the request segment;
##   - `:name`   — matches one segment, captured as a `PathParam`;
##   - `*`       — matches one segment, not captured;
##   - `**`      — catch-all: matches all remaining segments, including none.
## The query string (`?…`) is ignored for matching. Method is a case-sensitive
## token (RFC 9110 §3.1). Matching is on the raw, not percent-decoded, target.

import std/[opt, strutils]
import std/errorcodes/errorcodes_http
import hashi/http/request

export errorCodeToHttp

type
  Handler* = proc (req: Request): Response {.nimcall, raises.}
    ## Application request handler. `{.nimcall.}` (no closure) — route state
    ## lives in the `Router`, not captured. `{.raises.}` so a handler may
    ## `raise` an `ErrorCode` (e.g. `raise NameNotFound`); `dispatch` catches it
    ## and maps it to an HTTP status (see `errorCodeToHttp`). NB: Nimony Defects
    ## (index/overflow/nil) are NOT catchable — a handler *bug* still aborts the
    ## process (deploy under a supervisor). See doc/error-handling.md.

  ErrorHandler* = proc (req: Request; err: ErrorCode): Response {.nimcall.}
    ## Optional app hook: turn a raised `ErrorCode` into a custom `Response`
    ## (status/body/logging). Must not itself raise. If unset, `dispatch` uses
    ## `newResponse(errorCodeToHttp(err))`.

  BeforeMiddleware* = proc (req: Request): Opt[Response] {.nimcall.}
    ## Runs before the route handler, in registration order. `some(resp)`
    ## short-circuits — the handler is *not* called and `resp` is used (e.g. an
    ## auth gate returning 401 / a redirect). `none[Response]()` continues to the
    ## next middleware, then the handler. A short-circuit response still flows
    ## through the `after` chain (so e.g. security headers apply to a 401). Not
    ## `{.raises.}`: a guard denies by *returning* a response, it doesn't raise.
    ## NB: runs before route matching, so it sees no `pathParams` (it has the raw
    ## `target`); use it for cross-cutting concerns (auth, rate-limit), not
    ## per-route logic.

  AfterMiddleware* = proc (req: Request; resp: Response): Response {.nimcall.}
    ## Runs after dispatch (or after a before-chain short-circuit), in
    ## registration order, threading the response through each. Transforms every
    ## response including errors — e.g. add security headers. Must not raise.

  Route* = object
    ## One registered (method, pattern) → handler mapping.
    meth*: string          ## HTTP method, e.g. "GET" (case-sensitive token).
    path*: string          ## The registered pattern, in origin-form.
    segs*: seq[string]     ## `path` split into segments (precomputed).
    handler*: Handler

  Router* = object
    ## Holds the registered routes, error/not-found handlers and middleware
    ## chains. Filled via `addRoute`/`get`/`post`/… and read by `dispatch` or
    ## `dispatchFull`.
    routes*: seq[Route]
    errorHandler*: nil ErrorHandler   ## nil until `setErrorHandler`.
    notFound*: nil Handler            ## nil until `setNotFound`.
    before*: seq[BeforeMiddleware]  ## Pre-dispatch chain; see `dispatchFull`.
    after*: seq[AfterMiddleware]    ## Post-dispatch chain; see `dispatchFull`.

  MatchResult* = object
    ## Outcome of `matchRoute`. `found` → `idx`/`params` are valid;
    ## `methodMismatch` (with `found == false`) means a route's *path* matched
    ## but no method did → the dispatcher answers 405 rather than 404.
    found*: bool
    methodMismatch*: bool
    idx*: int
    params*: seq[PathParam]

proc splitSegments*(path: string): seq[string] =
  ## Split a path on `/`, dropping empty segments (so leading/trailing/double
  ## slashes don't create blanks). `"/"` and `""` → `@[]`.
  result = @[]
  for seg in split(path, '/'):
    if seg.len > 0: result.add seg

proc stripQuery(target: string): string =
  ## The path portion of a request-target: everything before the first `?`.
  let q = find(target, '?')
  result = if q < 0: target else: substr(target, 0, q - 1)

proc tryMatch(pattern, path: seq[string]): (bool, seq[PathParam]) =
  ## Match a pattern's segments against a request path's segments, capturing
  ## `:name` params. Returns (matched, params).
  var params: seq[PathParam] = @[]
  var i = 0   # index into pattern
  var j = 0   # index into path
  while true:
    if i >= pattern.len:
      # pattern exhausted: a match iff the path is also exhausted.
      return ((j >= path.len), params)
    let p = pattern[i]
    if p == "**":
      return (true, params)              # catch-all: rest matches (incl. none)
    if j >= path.len:
      return (false, params)             # pattern wants more, path is out
    if p.len >= 1 and p[0] == ':':
      params.add PathParam(key: substr(p, 1), val: path[j])
    elif p == "*":
      discard                            # single-segment wildcard, no capture
    elif p != path[j]:
      return (false, params)
    i = i + 1
    j = j + 1

proc addRoute*(r: var Router; meth, path: string; h: Handler) =
  ## Register `h` for `meth path`. First registration wins on a match (see
  ## `matchRoute`), so order is significant — register specific routes before
  ## wildcards.
  r.routes.add Route(meth: meth, path: path, segs: splitSegments(path), handler: h)

proc get*(r: var Router; path: string; h: Handler) = addRoute(r, "GET", path, h)
proc post*(r: var Router; path: string; h: Handler) = addRoute(r, "POST", path, h)
proc put*(r: var Router; path: string; h: Handler) = addRoute(r, "PUT", path, h)
proc delete*(r: var Router; path: string; h: Handler) = addRoute(r, "DELETE", path, h)
proc head*(r: var Router; path: string; h: Handler) = addRoute(r, "HEAD", path, h)
proc options*(r: var Router; path: string; h: Handler) = addRoute(r, "OPTIONS", path, h)
proc patch*(r: var Router; path: string; h: Handler) = addRoute(r, "PATCH", path, h)

proc matchRoute*(r: Router; meth, target: string): MatchResult =
  ## First route whose path pattern matches `target` and whose method is `meth`.
  ## If some route's path matches but no method does, `methodMismatch` is set.
  result = MatchResult(found: false, methodMismatch: false, idx: -1, params: @[])
  let pathSegs = splitSegments(stripQuery(target))
  for i in 0 ..< r.routes.len:
    let (ok, params) = tryMatch(r.routes[i].segs, pathSegs)
    if ok:
      if r.routes[i].meth == meth:
        result = MatchResult(found: true, methodMismatch: false,
                             idx: i, params: params)
        return
      else:
        result.methodMismatch = true

proc match*(r: Router; meth, target: string): int =
  ## Index of the first matching route, or -1. (Thin wrapper over `matchRoute`
  ## that drops the captured params — kept for callers that only need the index.)
  let m = matchRoute(r, meth, target)
  result = if m.found: m.idx else: -1

proc setErrorHandler*(r: var Router; h: ErrorHandler) =
  ## Register an app error handler; a raised `ErrorCode` is passed to it for a
  ## custom `Response`. Without one, `dispatch` uses `errorCodeToHttp`.
  r.errorHandler = h

proc setNotFound*(r: var Router; h: Handler) =
  ## Register a fallback handler, invoked when no route matches (and no route's
  ## path matched with a different method — that stays 405). Tried LAST by
  ## construction, independent of registration order: the right home for an SPA
  ## `index.html` fallback, vs a greedy `"/**"` route which shadows any route
  ## registered after it (`matchRoute` returns the first match).
  r.notFound = h

proc addBefore*(r: var Router; m: BeforeMiddleware) =
  ## Append a pre-dispatch middleware (runs in registration order). See
  ## `BeforeMiddleware` and `dispatchFull`.
  r.before.add m

proc addAfter*(r: var Router; m: AfterMiddleware) =
  ## Append a post-dispatch middleware (runs in registration order). See
  ## `AfterMiddleware` and `dispatchFull`.
  r.after.add m

proc setBefore*(r: var Router; m: seq[BeforeMiddleware]) =
  ## Replace the whole pre-dispatch chain (for a builder that installs at once).
  r.before = m

proc setAfter*(r: var Router; m: seq[AfterMiddleware]) =
  ## Replace the whole post-dispatch chain (for a builder that installs at once).
  r.after = m

proc guarded(r: Router; h: Handler; req: Request): Response =
  ## Run `h`; a raised `ErrorCode` becomes the app error handler's response,
  ## or the status `errorCodeToHttp` maps it to.
  try:
    result = h(req)
  except ErrorCode as e:
    if r.errorHandler != nil:
      result = r.errorHandler(req, e)
    else:
      result = newResponse(errorCodeToHttp(e))

proc dispatch*(r: Router; req: Request): Response =
  ## Route `req` to its handler (with captured path params), `405 Method Not
  ## Allowed` if the path matched but the method didn't, else `404 Not Found`.
  ## A handler that `raise`s an `ErrorCode` is caught here → the app error
  ## handler if set, else `newResponse(errorCodeToHttp(e))`. (Defects/panics
  ## are not catchable — see `Handler`.)
  var m = matchRoute(r, req.httpMethod, req.target)
  # HEAD is mandatory for any GET resource (RFC 9110 §9.1): when no explicit
  # HEAD route matched, fall back to the GET handler. The body it returns is
  # suppressed on the wire by `serialize` (the driver passes httpMethod="HEAD").
  if not m.found and req.httpMethod == "HEAD":
    m = matchRoute(r, "GET", req.target)
  if m.found:
    var rq = req
    rq.pathParams = m.params
    result = guarded(r, r.routes[m.idx].handler, rq)
  elif m.methodMismatch:
    result = newResponse(405)
  else:
    # No route matched → the registered fallback (e.g. SPA index.html), else 404.
    let fallback = r.notFound
    if fallback != nil:
      result = guarded(r, fallback, req)
    else:
      result = newResponse(404)

proc runBefore*(r: Router; req: Request): Opt[Response] =
  ## Run the before-chain in order; the first `some(resp)` short-circuits (and is
  ## returned), else `none`. Exposed so the connection driver can interpose an
  ## async route step between `before` and the route handler (see
  ## `hashi/http/server`'s `dispatchAsync`) while sharing this one chain
  ## definition with `dispatchFull`.
  for i in 0 ..< r.before.len:
    let sc = r.before[i](req)
    if sc.isSome:
      return sc
  result = none[Response]()

proc runAfter*(r: Router; req: Request; resp: Response): Response =
  ## Thread `resp` through the after-chain in order.
  result = resp
  for i in 0 ..< r.after.len:
    result = r.after[i](req, result)

proc dispatchFull*(r: Router; req: Request): Response =
  ## The full request pipeline: before-middleware (short-circuit aware) → route
  ## `dispatch` → after-middleware. The connection driver calls this per request.
  ## A before-middleware returning `some(resp)` skips dispatch but the response
  ## still passes through the after-chain. With no middleware registered this is
  ## exactly `dispatch` plus two empty-loop checks.
  let sc = runBefore(r, req)
  if sc.isSome:
    result = runAfter(r, req, sc.get(default(Response)))
  else:
    result = runAfter(r, req, dispatch(r, req))
