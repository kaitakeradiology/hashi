## Bulk byte operations on a `string` used as an I/O buffer.
##
## The connection drivers accumulate reads into a string and hand parsers
## the front of it. Nimony's string is small-string-optimised, so bytes
## cannot be written through `addr s[i]`; these helpers use the string's
## own bulk-store primitives to append, drop and copy in one `copyMem`
## each, instead of a byte at a time, and find line ends with `memchr`.

proc appendBytes*(s: var string; src: pointer; n: int) =
  ## Append the `n` bytes at `src` to `s`.
  if n <= 0: return
  let old = s.len
  let dst = beginStore(s, old + n, old)
  copyMem(dst, src, n)
  endStore(s)

proc dropPrefix*(s: var string; n: int) =
  ## Discard the first `n` bytes of `s` in place, keeping the rest.
  if n <= 0: return
  if n >= s.len:
    s.setLen(0)
    return
  let keep = s.len - n
  let p = beginStore(s, s.len, 0)
  moveMem(p, cast[pointer](cast[uint](p) + uint(n)), keep)
  s.setLen(keep)
  endStore(s)

proc copyOut*(dst: pointer; s: string; start, n: int) =
  ## Copy `n` bytes of `s` from `start` to `dst`.
  if n > 0: copyMem(dst, readRawData(s, start), n)

proc cMemchr(s: pointer; c: cint; n: csize_t): pointer {.
  importc: "memchr", header: "<string.h>".}

proc findLf(s: string; frm, to: int): int =
  ## The index of the first `\n` in `s[frm..to]`, or -1. `to` < `s.len`.
  if frm > to: return -1
  let base = readRawData(s, 0)
  let p = cMemchr(cast[pointer](cast[uint](base) + uint(frm)), cint(ord('\n')),
                  csize_t(to - frm + 1))
  if p == nil: -1 else: int(cast[uint](p) - cast[uint](base))

proc findCrlf*(s: string; start: int; last = -1): int =
  ## The index of the first `"\r\n"` lying wholly within `s[start..last]`
  ## (`last` < 0: to the end), or -1. The same answer as
  ## `strutils.find(s, "\r\n", start, last)`, found with `memchr`.
  result = -1
  let hi = if last < 0 or last >= s.len: s.len - 1 else: last
  var frm = start + 1
  while frm <= hi:
    let j = findLf(s, frm, hi)
    if j < 0: return -1
    if s[j - 1] == '\r': return j - 1
    frm = j + 1

proc findCrlfCrlf*(s: string; start: int; last = -1): int =
  ## The index of the first `"\r\n\r\n"` lying wholly within
  ## `s[start..last]` (`last` < 0: to the end), or -1. The same answer as
  ## `strutils.find(s, "\r\n\r\n", start, last)`, found with `memchr`.
  result = -1
  let hi = if last < 0 or last >= s.len: s.len - 1 else: last
  var frm = start + 3
  while frm <= hi:
    let j = findLf(s, frm, hi)
    if j < 0: return -1
    if s[j - 1] == '\r' and s[j - 2] == '\n' and s[j - 3] == '\r': return j - 3
    frm = j + 1
