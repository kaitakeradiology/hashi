## Unit tests for client-IP attribution (attributedClientIp): the trusted-proxy
## gate, X-Real-IP authority, and the rightmost-untrusted X-Forwarded-For
## fallback. Guards against the 2026-07-23 spoof regression where a forged XFF
## first entry was trusted.

import std/syncio
import hashi/http/forwarded
import testkit

# Direct-peer (untrusted) — forwarded headers ignored entirely.
section "untrusted peer: headers ignored"
setTrustedProxies(@[])
block: check attributedClientIp("9.9.9.9", "1.2.3.4", "6.6.6.6") == "9.9.9.9",
  "no trusted proxies configured → socket peer authoritative"
setTrustedProxies(@["127.0.0.1"])
block: check attributedClientIp("9.9.9.9", "1.2.3.4", "6.6.6.6") == "9.9.9.9",
  "peer not in trusted list → headers ignored"

# X-Real-IP is authoritative when the peer is trusted.
section "X-Real-IP authority"
block: check attributedClientIp("127.0.0.1", "203.0.113.5", "6.6.6.6, 127.0.0.1") == "203.0.113.5",
  "X-Real-IP wins over a forged XFF first entry"
block: check attributedClientIp("127.0.0.1", "203.0.113.5", "6.6.6.6, 203.0.113.5") == "203.0.113.5",
  "client forging BOTH headers: nginx-overwritten X-Real-IP still wins"

# X-Forwarded-For fallback: rightmost-untrusted.
section "XFF rightmost-untrusted fallback"
block: check attributedClientIp("127.0.0.1", "", "6.6.6.6, 203.0.113.5") == "203.0.113.5",
  "single edge: forged first entry, real peer appended → real peer"
block: check attributedClientIp("127.0.0.1", "", " 6.6.6.6 , 203.0.113.5 ") == "203.0.113.5",
  "whitespace around entries tolerated"

section "XFF multi-hop"
setTrustedProxies(@["127.0.0.1", "10.0.0.7"])
block: check attributedClientIp("127.0.0.1", "", "203.0.113.5, 10.0.0.7") == "203.0.113.5",
  "two trusted hops: skip the trusted tail, return the real client"
block: check attributedClientIp("127.0.0.1", "", "6.6.6.6, 203.0.113.5, 10.0.0.7") == "203.0.113.5",
  "forged prefix + real client + trusted tail → real client"

# Documented limitation: a lone forged XFF with no X-Real-IP and no appended
# peer is unrecoverable — which is precisely why X-Real-IP is mandatory.
section "documented limitation"
setTrustedProxies(@["127.0.0.1"])
block: check attributedClientIp("127.0.0.1", "", "6.6.6.6") == "6.6.6.6",
  "lone untrusted XFF entry is indistinguishable from a legit forward"

echo "client-ip attribution: all cases pass"
