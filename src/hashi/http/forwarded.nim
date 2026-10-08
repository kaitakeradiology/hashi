## Client-IP attribution behind a reverse proxy.
##
## Forwarded headers are honoured only when the socket peer is a trusted
## proxy (`setTrustedProxies`); a client connecting directly cannot spoof
## its attributed address. Every address, configured or forwarded, is
## parsed with `parseIpLiteral` and compared and returned in its canonical
## text, so `::ffff:127.0.0.1` and `127.0.0.1` are one address.
##
## For a trusted peer:
##   - with no forwarded headers, or only empty ones, the client is the
##     peer: an on-host or direct connection;
##   - exactly one `X-Real-IP` line that is an IP literal wins, since the
##     edge proxy sets it as a single value;
##   - otherwise `X-Forwarded-For` (every line, joined in order) is walked
##     right to left. Trusted hops are skipped; the first hop that is not
##     trusted is the client if it is an IP literal. A hop that is not one
##     ends the walk unattributed rather than being skipped, so a trusted
##     proxy appending `ip:port` or `unknown` cannot hand the result to the
##     client-supplied entries to its left;
##   - a walk that finds no usable hop gives "": unattributed. Once a trusted
##     peer has sent forwarded headers the result is never the peer itself,
##     which for an on-host proxy is loopback.
##
## `clientIp` also logs a warning, at most once a minute per proxy and kind
## on each worker thread, for a trusted peer that sends more than one
## `X-Real-IP` line, an `X-Real-IP` that is not an IP literal, or an
## `X-Real-IP` that equals neither the last `X-Forwarded-For` hop nor the
## right-most untrusted one. The last is what a trusted proxy that appends
## `X-Forwarded-For` without overwriting `X-Real-IP` produces. It does not
## detect a proxy that passes both client headers through unchanged; only
## the proxy overwriting `X-Real-IP` prevents that. The warning never
## changes the result. The result is sanitised so a forwarded value cannot
## inject control bytes into logs.

import std/[strutils, monotimes]
import hashi/net
import hashi/http/request
import hashi/http/httplog
import hashi/log
import hashi/bootcfg

var gTrustedProxies: Frozen[seq[string]]
var gTrustedFaults: Frozen[string]

proc isMulticastOrUnspecified(c: string): bool =
  ## Whether canonical address text `c` (`parseIpLiteral`'s output) is
  ## unspecified (`0.0.0.0`, `::`) or multicast (`224.0.0.0/4`, `ff00::/8`).
  if c == "::" or c == "0.0.0.0": return true
  let colon = find(c, ':')
  if colon >= 0:
    # inet_ntop drops leading zeros, so ff00::/8 is a first group of four
    # hex digits starting "ff".
    result = colon == 4 and c[0] == 'f' and c[1] == 'f'
  else:
    var first = 0
    var i = 0
    while i < c.len and c[i] != '.':
      first = first * 10 + (ord(c[i]) - ord('0'))
      inc i
    result = first >= 224 and first <= 239

proc setTrustedProxies*(proxies: seq[string]) =
  ## Direct-peer IPs whose `X-Forwarded-For` / `X-Real-IP` headers we trust.
  ## When empty (default), forwarded headers are never honoured — the socket
  ## peer is authoritative. Call before `serve`. Each entry is trimmed and a
  ## blank one dropped; any other entry must be a bare IPv4 or IPv6 literal
  ## that is neither unspecified nor multicast, or it is recorded in
  ## `trustedProxyFaults` and `serve` refuses to start.
  var list: seq[string] = @[]
  var faults = ""
  for p in proxies:
    let e = strip(p)
    if e.len > 0:
      let c = parseIpLiteral(e)
      var why = ""
      if c.len == 0: why = "not a bare IP literal"
      elif isMulticastOrUnspecified(c): why = "unspecified or multicast"
      if why.len > 0:
        if faults.len > 0: faults.add "; "
        faults.add "\"" & sanitizePrintable(e, 64) & "\" is " & why
      else:
        list.add c
  publish(gTrustedProxies, list)
  publish(gTrustedFaults, faults)

proc trustedProxyFaults*(): string =
  ## The entries the last `setTrustedProxies` refused, with the reason for
  ## each, or "" when it refused none.
  snapshot(gTrustedFaults)

proc isTrustedCanonical(c: string): bool =
  c.len > 0 and c in view(gTrustedProxies)[]

proc isTrustedProxy*(peer: string): bool =
  ## Whether forwarded headers from the socket `peer` are honoured. For any
  ## other peer the attributed address is the peer itself, whatever the
  ## request's headers say, so a server can settle it once per connection.
  ## "" and a peer that is not an IP literal are never trusted.
  isTrustedCanonical(parseIpLiteral(peer))

proc hasForwarded(xRealIpLines: seq[string]; xffJoined: string): bool =
  ## Whether any forwarded header carries something other than whitespace.
  result = xRealIpLines.len > 1 or strip(xffJoined).len > 0 or
           (xRealIpLines.len == 1 and strip(xRealIpLines[0]).len > 0)

proc walkForwardedFor(xffJoined: string): string =
  ## The right-most hop of `xffJoined` that is not a trusted proxy, in
  ## canonical form, or "" when that hop is not an IP literal or every hop
  ## is trusted.
  result = ""
  if strip(xffJoined).len == 0: return
  let hops = split(xffJoined, ',')
  var i = hops.len - 1
  while i >= 0:
    let h = parseIpLiteral(hops[i])
    if not isTrustedCanonical(h):
      return h
    dec i

proc attributedClientIp*(peer: string; xRealIpLines: seq[string];
                         xffJoined: string): string =
  ## The client IP given the socket `peer`, every `X-Real-IP` line and the
  ## `X-Forwarded-For` lines joined with ",", under the rules in the module
  ## doc. "" when a trusted peer's forwarded headers name no usable client.
  ## Exported for testing; `clientIp` is the `Request` wrapper.
  let pc = parseIpLiteral(peer)
  if not isTrustedCanonical(pc):
    result = if pc.len > 0: pc else: peer
  elif not hasForwarded(xRealIpLines, xffJoined):
    result = pc
  else:
    var xr = ""
    if xRealIpLines.len == 1: xr = parseIpLiteral(xRealIpLines[0])
    if xr.len > 0: result = xr
    else: result = walkForwardedFor(xffJoined)
  result = sanitizePrintable(result, 64)

type ForwardedWarning = enum
  fwNone, fwMultipleRealIp, fwRealIpNotLiteral, fwMismatch

proc checkForwarded(peer: string; xRealIpLines: seq[string]; xffJoined: string;
                    msg: var string): ForwardedWarning =
  ## The warning, if any, that `forwardedWarning` describes, with its text
  ## in `msg`.
  result = fwNone
  msg = ""
  let pc = parseIpLiteral(peer)
  if not isTrustedCanonical(pc): return
  if xRealIpLines.len > 1:
    msg = "trusted proxy " & pc & ": multiple X-Real-IP lines; ignored"
    return fwMultipleRealIp
  if xRealIpLines.len == 0 or strip(xRealIpLines[0]).len == 0: return
  let xr = parseIpLiteral(xRealIpLines[0])
  if xr.len == 0:
    msg = "trusted proxy " & pc & ": X-Real-IP is not an IP literal"
    return fwRealIpNotLiteral
  if strip(xffJoined).len == 0: return
  var comma = xffJoined.len - 1
  while comma >= 0 and xffJoined[comma] != ',': dec comma
  let last = parseIpLiteral(substr(xffJoined, comma + 1))
  if last.len == 0: return
  if xr != last and xr != walkForwardedFor(xffJoined):
    msg = "trusted proxy " & pc & ": X-Real-IP " & xr & " ≠ last X-Forwarded-For hop " &
          last & "; a trusted proxy may be appending X-Forwarded-For without " &
          "overwriting X-Real-IP (see the estate canon)"
    result = fwMismatch

proc forwardedWarning*(peer: string; xRealIpLines: seq[string];
                       xffJoined: string): string =
  ## The warning `clientIp` logs for these forwarded headers from `peer`,
  ## or "": more than one `X-Real-IP` line, an `X-Real-IP` that is not an IP
  ## literal (not echoed), or one that equals neither the last
  ## `X-Forwarded-For` hop nor the right-most untrusted one. Only for a
  ## trusted `peer`; addresses in the text are canonical.
  result = ""
  discard checkForwarded(peer, xRealIpLines, xffJoined, result)

const WarnIntervalNs = 60_000_000_000'i64
  ## Each (proxy, kind) warning is logged at most once per this interval.

type WarnMark = object
  peer: string
  kind: ForwardedWarning
  at: int64

var tWarnMarks {.threadvar.}: seq[WarnMark]
  ## This thread's last warning per (trusted proxy, kind). Bounded by the
  ## trusted entries times the warning kinds.

proc warnDue(peer: string; kind: ForwardedWarning): bool =
  ## Whether `kind` for `peer` may be logged now on this thread; records it
  ## when so.
  let now = getMonoTime().ticks
  for m in mitems(tWarnMarks):
    if m.peer == peer and m.kind == kind:
      if now - m.at < WarnIntervalNs: return false
      m.at = now
      return true
  tWarnMarks.add WarnMark(peer: peer, kind: kind, at: now)
  result = true

proc clientIp*(req: Request; peer: string): string =
  ## `attributedClientIp` over the request's forwarded headers, logging
  ## `forwardedWarning`'s warning subject to the rate limit.
  let xri = headers(req, "X-Real-IP")
  var xff = ""
  var n = 0
  for v in headers(req, "X-Forwarded-For"):
    if n > 0: xff.add ','
    xff.add v
    inc n
  result = attributedClientIp(peer, xri, xff)
  var msg = ""
  let kind = checkForwarded(peer, xri, xff, msg)
  if kind != fwNone and warnDue(parseIpLiteral(peer), kind):
    log(warn, msg)
