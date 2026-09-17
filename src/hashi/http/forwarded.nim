## Client-IP attribution behind a reverse proxy.
##
## Forwarded headers are honoured only when the socket peer is a trusted
## proxy (`setTrustedProxies`); a client connecting directly cannot spoof
## its attributed address. When the peer is trusted, `X-Real-IP` wins if
## present, since the edge proxy sets it as a single value. Otherwise the
## result is the rightmost `X-Forwarded-For` entry that is not itself a
## trusted proxy: each hop appends the address it saw, so the entries to
## the left of the trusted tail are the client's and spoofable. The result
## is sanitised so a forwarded value cannot inject control bytes into logs.

import std/strutils
import hashi/http/request
import hashi/http/httplog

var gTrustedProxies: seq[string] = @[]

proc setTrustedProxies*(proxies: seq[string]) =
  ## Direct-peer IPs whose `X-Forwarded-For` / `X-Real-IP` headers we trust.
  ## When empty (default), forwarded headers are never honoured — the socket
  ## peer is authoritative. Call before `serve`.
  gTrustedProxies = proxies

proc attributedClientIp*(peer, xRealIp, xForwardedFor: string): string =
  ## The client IP given the socket `peer` and the two forwarded headers,
  ## under the rules in the module doc. Exported for testing; `clientIp` is
  ## the `Request` wrapper.
  result = peer
  if peer in gTrustedProxies:
    let xr = strip(xRealIp)
    if xr.len > 0:
      result = xr
    else:
      let hops = split(xForwardedFor, ',')
      for i in countdown(hops.len - 1, 0):
        let hop = strip(hops[i])
        if hop.len > 0 and hop notin gTrustedProxies:
          result = hop
          break
  result = sanitizePrintable(result, 64)

proc clientIp*(req: Request; peer: string): string =
  ## `attributedClientIp` over the request's forwarded headers.
  attributedClientIp(peer, header(req, "X-Real-IP"), header(req, "X-Forwarded-For"))
