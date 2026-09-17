## Shared generators for the fuzzers: a seeded `std/random` generator, so a
## failure reproduces from the seed in the fuzzer's header, and the byte and
## token shapes the parsers are fed.

import std/random
import std/strutils

var rng = initRand(0x2545F4914F6CDD1D'i64)

proc seedFuzz*(seed: int64) =
  ## Reseed; each fuzzer calls this once so its inputs are its own.
  rng = initRand(seed)

proc rnd*(n: int): int =
  ## 0 ..< n; 0 when n <= 0.
  if n <= 0: return 0
  result = rand(rng, n - 1)

proc randomBytesExact*(n: int): string =
  ## Exactly `n` arbitrary bytes, CR/LF/NUL/high included.
  result = ""
  for i in 0 ..< n: result.add char(rnd(256))

proc randomBytes*(maxLen: int): string =
  ## 0 ..< maxLen arbitrary bytes.
  result = randomBytesExact(rnd(maxLen))

proc randomToken*(maxLen: int): string =
  ## 1 .. maxLen printable ASCII bytes with no space, colon, CR or LF.
  result = ""
  for i in 0 ..< 1 + rnd(maxLen):
    var c = char(33 + rnd(94))    # '!'..'~'
    if c == ' ' or c == ':' or c == '\r' or c == '\n':
      c = 'x'
    result.add c

const tcharSet* = "!#$%&'*+-.^_`|~0123456789" &
                  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

proc randomTchar*(maxLen: int): string =
  ## A valid RFC 9110 token (field name, method): 1 .. maxLen tchars.
  result = ""
  for i in 0 ..< 1 + rnd(maxLen):
    result.add tcharSet[rnd(tcharSet.len)]

proc randomAlnum*(maxLen: int): string =
  ## 1 .. maxLen letters and digits.
  const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = ""
  for i in 0 ..< 1 + rnd(maxLen):
    result.add alnum[rnd(alnum.len)]

proc hasCRLFCRLF*(s: string): bool =
  result = find(s, "\r\n\r\n") >= 0
