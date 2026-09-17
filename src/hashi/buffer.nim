## Bulk byte operations on a `string` used as an I/O buffer.
##
## The connection drivers accumulate reads into a string and hand parsers
## the front of it. Nimony's string is small-string-optimised, so bytes
## cannot be written through `addr s[i]`; these helpers use the string's
## own bulk-store primitives to append, drop and copy in one `copyMem`
## each, instead of a byte at a time.

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
