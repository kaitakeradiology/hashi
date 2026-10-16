## HTTP access logging: one line per request, e.g.
##
##   Jun 05 04:25:40.658 TRACE (httplog:NN) 203.0.113.5 200 GET /path 87us
##
## The log level is status-aware so problems surface at the default `info`
## level while successful traffic stays at `trace`:
##   2xx / 3xx -> trace  (quiet unless the level is lowered)
##   4xx       -> warn   (client error)
##   5xx       -> error  (server error)
##
## Timing renders as `Nus` under a millisecond, else `N.Nms` (integer math,
## so the hot path stays float-free).
##
## The request target is logged verbatim unless the application installs an
## `AccessLogTarget` with `setAccessLogTarget`. A target can carry a patient
## or account identifier in its path or query, so what a log line may say
## about it is the application's decision.

import hashi/log
import hashi/bootcfg

type
  AccessLogTarget* = proc (target: string): string {.nimcall.}
    ## Receives the whole request target (path and query) and returns what
    ## the access log writes in its place.

var gTarget: Frozen[nil AccessLogTarget]   # unset: the target verbatim

proc setAccessLogTarget*(f: AccessLogTarget) =
  ## Install the target rewrite for every access-log line, whatever the
  ## status. Call before `serve`.
  publish(gTarget, f)

proc loggedTarget(target: string): string =
  let f = snapshot(gTarget)
  result = if f == nil: target else: f(target)

proc sanitizePrintable*(s: string; maxLen = 64): string =
  ## Untrusted text made safe for a log line or error message: printable
  ## ASCII kept, every other byte replaced by '.', and the result cut to
  ## `maxLen` with "..." appended when it was longer.
  let n = (if s.len > maxLen: maxLen else: s.len)
  result = ""
  var i = 0
  while i < n:
    let c = s[i]
    if c >= ' ' and c <= '~': result.add c
    else: result.add '.'
    i = i + 1
  if s.len > maxLen: result.add "..."

proc levelFor(status: int): LogLevel =
  ## Status-aware access-log level: 5xx error, 4xx warn, everything else trace.
  if status >= 500: error
  elif status >= 400: warn
  else: trace

proc fmtTiming(micros: int): string =
  ## `Nus` under a millisecond, else `N.Nms` (one decimal).
  if micros < 1000:
    result = $micros & "us"
  else:
    let whole = micros div 1000
    let tenths = (micros mod 1000) div 100
    result = $whole & "." & $tenths & "ms"

proc accessLog*(ip: string; status: int; meth, target: string; micros: int) =
  ## One access-log line at a status-aware level, the target passed through
  ## the `AccessLogTarget` when one is installed. `micros` is the request's
  ## processing time.
  log(levelFor(status),
      ip & " " & $status & " " & meth & " " & loggedTarget(target) & " " & fmtTiming(micros))
