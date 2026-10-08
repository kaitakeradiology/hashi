## Unit tests for client-IP attribution (`hashi/http/forwarded`) and the
## IP-literal parser beneath it (`parseIpLiteral`, `hashi/net`): the
## trusted-proxy gate and its boot-time faults, X-Real-IP authority, the
## right-most-untrusted X-Forwarded-For walk that stops at the first hop it
## cannot use, unattributed (`""`) results, and the proxy-misconfiguration
## warning. Guards against the 2026-07-23 spoof regression where a forged
## XFF first entry was trusted.

{.feature: "assumeSync".}   # single-threaded: the warning capture is only called from this thread
import std/[syncio, strutils]
import hashi/net
import hashi/http/request
import hashi/http/forwarded
import hashi/log
import testkit

proc lit(s, want, msg: string) =
  let got = parseIpLiteral(s)
  check got == want, msg & " (got \"" & got & "\")"

proc att(peer: string; xri: seq[string]; xff, want, msg: string) =
  let got = attributedClientIp(peer, xri, xff)
  check got == want, msg & " (got \"" & got & "\")"

proc warnOf(peer: string; xri: seq[string]; xff: string): string =
  forwardedWarning(peer, xri, xff)

proc hasControl(s: string): bool =
  result = false
  for c in s:
    if c < ' ' or c > '~': result = true

# ── parseIpLiteral ─────────────────────────────────────────────────────────

section "parseIpLiteral: accepted, canonical text"
lit("1.2.3.4", "1.2.3.4", "IPv4 dotted quad")
lit("::", "::", "IPv6 unspecified")
lit("::1", "::1", "IPv6 loopback")
lit("0:0:0:0:0:0:0:1", "::1", "uncompressed IPv6 is compressed")
lit("2001:DB8::1", "2001:db8::1", "IPv6 is lower-cased")
lit("::ffff:1.2.3.4", "1.2.3.4", "IPv4-mapped IPv6 is a dotted quad, as peerAddress renders it")
lit("::FFFF:1.2.3.4", "1.2.3.4", "IPv4-mapped prefix in upper case")
lit(" 1.2.3.4\t", "1.2.3.4", "leading/trailing spaces and tabs are trimmed")
# glibc's inet_ntop renderings, pinned.
lit("::1.2.3.4", "::1.2.3.4", "IPv4-compatible form: glibc keeps the dotted tail")
lit("::ffff:0:1.2.3.4", "::ffff:0:102:304", "SIIT form: glibc prints hex groups")
lit("64:ff9b::1.2.3.4", "64:ff9b::102:304", "NAT64 well-known prefix: glibc prints hex groups")

section "parseIpLiteral: canonical text is a fixed point"
for s in ["1.2.3.4", "::", "::1", "2001:DB8::1", "::ffff:1.2.3.4", "::1.2.3.4",
          "::ffff:0:1.2.3.4", "64:ff9b::1.2.3.4", "fe80::1", "ff02::1",
          "1:2:3:4:5:6:7:8"]:
  let c = parseIpLiteral(s)
  check c.len > 0 and parseIpLiteral(c) == c, "round trip of " & s & " → " & c

section "parseIpLiteral: rejected"
lit("01.2.3.4", "", "leading zero in an IPv4 octet")
lit("256.1.1.1", "", "IPv4 octet over 255")
lit("1.2.3", "", "three-part IPv4")
lit("1:2:3:4:5:6:7:8:9", "", "nine IPv6 groups")
lit("1::2::3", "", "two '::'")
lit("fe80::1%eth0", "", "zone id")
lit("1.2.3.4/24", "", "CIDR")
lit("[::1]", "", "brackets")
lit("1.2.3.4:80", "", "IPv4 with a port")
lit("1111:2222:3333:4444:5555:6666:7777:8888:9999:aaaa", "", "more than 45 characters")
lit("", "", "empty")
lit(" \t ", "", "only whitespace")
lit("1.2.3.4\0junk", "", "NUL byte (C-string truncation)")
lit("1.2.3.4\r", "", "trailing CR")
lit("1.2.3.4\n", "", "trailing LF")
lit("1.2.3.4\tx", "", "embedded tab")
lit("1.2.3.4\xC3\xA9", "", "non-ASCII bytes")
lit("1.2.3.4\xFF", "", "invalid UTF-8")
lit("unknown", "", "a word")
lit("localhost", "", "a hostname")

# ── trusted proxies ────────────────────────────────────────────────────────

section "trusted proxies: canonical matching"
setTrustedProxies(@["0:0:0:0:0:0:0:1"])
check trustedProxyFaults() == "", "uncompressed ::1 is a valid entry"
check isTrustedProxy("::1"), "configured 0:0:0:0:0:0:0:1 matches peer ::1"
setTrustedProxies(@["::ffff:127.0.0.1"])
check isTrustedProxy("127.0.0.1"), "configured ::ffff:127.0.0.1 matches peer 127.0.0.1"
setTrustedProxies(@["127.0.0.1"])
check isTrustedProxy("::ffff:127.0.0.1"), "a mapped peer spelling matches a dotted entry"
check isTrustedProxy("127.0.0.1"), "a listed proxy is trusted"
check not isTrustedProxy("9.9.9.9"), "any other peer is not"
check not isTrustedProxy(""), "\"\" is never trusted"
check not isTrustedProxy("?"), "an unavailable peer is never trusted"
setTrustedProxies(@[])
check not isTrustedProxy("127.0.0.1"), "an empty list trusts no one"

section "trusted proxies: empty entries"
setTrustedProxies(@[""])
check trustedProxyFaults() == "", "@[\"\"] is not a fault"
check not isTrustedProxy(""), "@[\"\"] does not trust \"\""
setTrustedProxies(@["  "])
check trustedProxyFaults() == "", "@[\"  \"] is not a fault"
check not isTrustedProxy(""), "@[\"  \"] trusts nothing"
setTrustedProxies(@[" 127.0.0.1 ", ""])
check trustedProxyFaults() == "" and isTrustedProxy("127.0.0.1"),
  "a padded entry is trimmed, a blank one dropped"

section "trusted proxies: faults"
for bad in ["127.0.0.l", "0.0.0.0", "::", "224.0.0.1", "ff02::1",
            "239.255.255.255", "ff00::", "::ffff:0.0.0.0", "::ffff:224.0.0.1",
            "10.0.0.0/8", "proxy.example", "127.0.0.1:8080", "[::1]"]:
  setTrustedProxies(@["127.0.0.1", bad])
  let f = trustedProxyFaults()
  check f.len > 0 and find(f, bad) >= 0, "refused and named: " & bad & " (\"" & f & "\")"
  check not isTrustedProxy(bad), "a refused entry trusts nothing: " & bad
setTrustedProxies(@["127.0.0.1\nINJECT"])
check find(trustedProxyFaults(), "\n") < 0, "a fault names the entry sanitised"
for good in ["223.255.255.255", "240.0.0.1", "ff::1", "fe80::1"]:
  setTrustedProxies(@[good])
  check trustedProxyFaults() == "", "unicast, specified: " & good
setTrustedProxies(@["127.0.0.1", "::1"])
check trustedProxyFaults() == "", "127.0.0.1, ::1: no fault"
setTrustedProxies(@["127.0.0.1", "0.0.0.0"])
setTrustedProxies(@["127.0.0.1"])
check trustedProxyFaults() == "", "a later valid call clears an earlier fault"

# ── attribution ────────────────────────────────────────────────────────────

section "attribution: untrusted peer"
setTrustedProxies(@[])
att("9.9.9.9", @["1.2.3.4"], "6.6.6.6", "9.9.9.9",
    "no trusted proxies configured → socket peer authoritative")
setTrustedProxies(@["127.0.0.1"])
att("9.9.9.9", @["1.2.3.4"], "6.6.6.6", "9.9.9.9", "peer not in trusted list → headers ignored")
att("::ffff:9.9.9.9", @[], "", "9.9.9.9", "an untrusted peer is canonicalised")
att("?", @["1.2.3.4"], "", "?", "an unparseable peer is returned as is")
att("bad\npeer", @[], "", "bad.peer", "an unparseable peer is sanitised")

section "attribution: trusted peer (127.0.0.1)"
setTrustedProxies(@["127.0.0.1"])
att("127.0.0.1", @[], "", "127.0.0.1", "no forwarded headers → the peer (on-host / direct)")
att("127.0.0.1", @[""], "", "127.0.0.1", "headers present but empty → the peer")
att("127.0.0.1", @["203.0.113.5"], "6.6.6.6, 203.0.113.5", "203.0.113.5", "canonical: X-Real-IP")
att("127.0.0.1", @["203.0.113.5"], "6.6.6.6, 127.0.0.1", "203.0.113.5",
    "X-Real-IP wins over a forged XFF first entry")
att("127.0.0.1", @["not-an-ip"], "203.0.113.5", "203.0.113.5", "junk X-Real-IP → XFF walk")
att("127.0.0.1", @[], "6.6.6.6, 203.0.113.5:4431", "",
    "stop-not-skip: an unusable right-most hop is unattributed, never the forged prefix")
att("127.0.0.1", @[], "6.6.6.6, unknown", "", "stop-not-skip: 'unknown'")
att("127.0.0.1", @["not-an-ip"], "bogus", "", "junk in both → unattributed, not the peer")
att("127.0.0.1", @[], "127.0.0.1", "", "only trusted hops → unattributed")
att("127.0.0.1", @["1.1.1.1", "2.2.2.2"], "203.0.113.5", "203.0.113.5",
    "multiple X-Real-IP lines are ignored → XFF walk")
att("127.0.0.1", @["1.1.1.1", "2.2.2.2"], "", "", "multiple X-Real-IP lines, no XFF → unattributed")
att("127.0.0.1", @["not-an-ip"], "", "", "junk X-Real-IP, no XFF → unattributed")
att("127.0.0.1", @[], "6.6.6.6,203.0.113.5", "203.0.113.5", "two XFF lines, joined")
att("127.0.0.1", @["2001:DB8::1"], "", "2001:db8::1", "X-Real-IP is canonicalised")
att("127.0.0.1", @[], "6.6.6.6, 2001:DB8::1", "2001:db8::1", "an XFF hop is canonicalised")
att("127.0.0.1", @[], "6.6.6.6, 203.0.113.5", "203.0.113.5",
    "single edge: forged first entry, real peer appended → real peer")
att("127.0.0.1", @[], " 6.6.6.6 , 203.0.113.5 ", "203.0.113.5", "whitespace around entries tolerated")
att("127.0.0.1", @[], "6.6.6.6", "6.6.6.6",
    "a lone untrusted XFF entry is indistinguishable from a legitimate forward")
att("127.0.0.1", @[], "6.6.6.6, 203.0.113.5,", "", "an empty right-most hop is unattributed")
att("::ffff:127.0.0.1", @["203.0.113.5"], "", "203.0.113.5", "a mapped trusted peer is trusted")

section "attribution: trusted chain"
setTrustedProxies(@["127.0.0.1", "10.0.0.2"])
att("127.0.0.1", @[], "198.51.100.7, 10.0.0.2", "198.51.100.7", "skip the trusted tail")
att("127.0.0.1", @[], "6.6.6.6, 198.51.100.7, 10.0.0.2", "198.51.100.7",
    "forged prefix + real client + trusted tail → real client")
att("127.0.0.1", @[], "6.6.6.6, bogus, 10.0.0.2", "",
    "junk behind a trusted hop stops the walk")
att("127.0.0.1", @[], "198.51.100.7, ::ffff:a00:2", "198.51.100.7",
    "a trusted hop matches in any spelling")

section "attribution: the result is printable"
setTrustedProxies(@["127.0.0.1"])
for (xri, xff) in [("1.2.3.4\0x", "6.6.6.6\r\nX: y"), ("\x1b[31m", "\x00"),
                   ("", "1.2.3.4\n"), ("::1\t", "\xFF")]:
  check not hasControl(attributedClientIp("127.0.0.1", @[xri], xff)),
    "no control or non-ASCII byte in the result"
check not hasControl(attributedClientIp("\x1b[0m\n", @[], "")), "nor from an odd peer"

# ── warnings ───────────────────────────────────────────────────────────────

section "forwardedWarning"
setTrustedProxies(@["127.0.0.1"])
check warnOf("127.0.0.1", @["203.0.113.5"], "6.6.6.6, 203.0.113.5") == "", "canonical: none"
check warnOf("127.0.0.1", @["127.0.0.1"], "127.0.0.1") == "", "on-host client: none"
check warnOf("127.0.0.1", @["127.0.0.1"], "6.6.6.6, 127.0.0.1") == "",
  "on-host client with its own XFF: none"
let notOverwriting = warnOf("127.0.0.1", @["6.6.6.6"], "203.0.113.5")
check find(notOverwriting, "6.6.6.6") >= 0 and find(notOverwriting, "203.0.113.5") >= 0 and
      find(notOverwriting, "without overwriting X-Real-IP") >= 0,
  "X-Real-IP not overwritten: mismatch warning naming both (\"" & notOverwriting & "\")"
check warnOf("127.0.0.1", @[], "203.0.113.5") == "", "X-Real-IP absent: none"
check warnOf("127.0.0.1", @["203.0.113.5"], "") == "", "XFF absent: none"
check warnOf("127.0.0.1", @["203.0.113.5"], "bogus") == "",
  "last hop junk: no mismatch claim on an unparseable hop"
let junkXri = warnOf("127.0.0.1", @["not-an-ip"], "203.0.113.5")
check find(junkXri, "not an IP literal") >= 0 and find(junkXri, "not-an-ip") < 0,
  "unparseable X-Real-IP: warned, raw value not echoed (\"" & junkXri & "\")"
check find(warnOf("127.0.0.1", @["1.1.1.1", "2.2.2.2"], ""), "multiple X-Real-IP") >= 0,
  "multiple X-Real-IP lines: warned"
check warnOf("9.9.9.9", @["6.6.6.6"], "203.0.113.5") == "", "untrusted peer: none"
check warnOf("127.0.0.1", @["::1"], "0:0:0:0:0:0:0:1") == "", "spelling differs, address same: none"
check find(warnOf("127.0.0.1", @["2001:DB8::1"], "2001:db8::2"), "2001:db8::1") >= 0,
  "values in the warning are canonical"
setTrustedProxies(@["127.0.0.1", "10.0.0.2"])
check warnOf("127.0.0.1", @["198.51.100.7"], "198.51.100.7, 10.0.0.2") == "",
  "multi-hop canon (inner proxy carries the edge's X-Real-IP): none"
check warnOf("127.0.0.1", @["6.6.6.6"], "198.51.100.7, 10.0.0.2") != "",
  "multi-hop, X-Real-IP matches neither the last hop nor the walk: warned"
setTrustedProxies(@["127.0.0.1"])
check warnOf("127.0.0.1", @["6.6.6.6"], "203.0.113.5") != "" and
      attributedClientIp("127.0.0.1", @["6.6.6.6"], "203.0.113.5") == "6.6.6.6",
  "the warning never changes the result"

# ── the Request wrapper ────────────────────────────────────────────────────

proc reqWith(fields: seq[(string, string)]): Request =
  result = default(Request)
  for (n, v) in fields:
    result.headers.add Header(name: n, value: v)

section "clientIp: gathers every line"
setTrustedProxies(@["127.0.0.1"])
check clientIp(reqWith(@[("X-Forwarded-For", "6.6.6.6"), ("X-Forwarded-For", "203.0.113.5")]),
               "127.0.0.1") == "203.0.113.5", "two XFF lines are joined in order"
check clientIp(reqWith(@[("x-real-ip", "1.1.1.1"), ("X-Real-IP", "2.2.2.2"),
                         ("X-Forwarded-For", "203.0.113.5")]), "127.0.0.1") == "203.0.113.5",
  "two X-Real-IP lines are an anomaly → XFF walk"
check clientIp(reqWith(@[("X-Real-IP", "203.0.113.5")]), "127.0.0.1") == "203.0.113.5",
  "one X-Real-IP line"
check clientIp(reqWith(@[]), "127.0.0.1") == "127.0.0.1", "no headers → the peer"
check clientIp(reqWith(@[("X-Real-IP", "not-an-ip"), ("X-Forwarded-For", "bogus")]),
               "127.0.0.1") == "", "junk → unattributed"
check clientIp(reqWith(@[("X-Real-IP", "1.2.3.4")]), "9.9.9.9") == "9.9.9.9",
  "untrusted peer → the peer"

section "clientIp: warnings are logged, rate-limited"
var gWarnings: seq[string] = @[]
proc capture(level: LogLevel; file: string; line: int; msg: string) {.nimcall.} =
  if level == LogLevel.warn: gWarnings.add msg
setLogCallback(capture)
# Fresh proxies: the sections above already logged kinds for 127.0.0.1.
setTrustedProxies(@["10.0.0.3", "10.0.0.4"])
let mismatch = reqWith(@[("X-Real-IP", "6.6.6.6"), ("X-Forwarded-For", "203.0.113.5")])
discard clientIp(mismatch, "10.0.0.3")
check gWarnings.len == 1 and find(gWarnings[0], "without overwriting X-Real-IP") >= 0,
  "a mismatch is logged at warn"
discard clientIp(mismatch, "10.0.0.3")
discard clientIp(mismatch, "::ffff:10.0.0.3")
check gWarnings.len == 1, "the same (proxy, kind) again within a minute is not"
discard clientIp(reqWith(@[("X-Real-IP", "junk")]), "10.0.0.3")
check gWarnings.len == 2, "another kind from the same proxy is"
discard clientIp(mismatch, "10.0.0.4")
check gWarnings.len == 3, "the same kind from another proxy is"
discard clientIp(reqWith(@[("X-Real-IP", "203.0.113.5"),
                           ("X-Forwarded-For", "6.6.6.6, 203.0.113.5")]), "10.0.0.4")
check gWarnings.len == 3, "the canonical headers log nothing"

finish()
