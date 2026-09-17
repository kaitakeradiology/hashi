## Unit tests for `hashi/buffer`: bulk append, drop and copy across the
## string's inline and heap representations.

import std/syncio
import hashi/buffer
import testkit

proc filled(n: int; c: char): string =
  result = ""
  for i in 0 ..< n: result.add c

section "appendBytes"
block:
  var s = ""
  var src = filled(5, 'a')
  appendBytes(s, readRawData(src), 5)
  check s == "aaaaa", "append into an empty string"
  appendBytes(s, readRawData(src), 0)
  check s == "aaaaa", "zero bytes is a no-op"
block:
  var s = "short"
  var big = filled(100, 'z')
  appendBytes(s, readRawData(big), 100)
  check s.len == 105 and s[0] == 's' and s[4] == 't' and s[5] == 'z' and s[104] == 'z',
        "inline string grows onto the heap with its prefix intact"
  check s == "short" & big, "equality after the transition"
block:
  var s = filled(20, 'x')
  var more = "ab"
  appendBytes(s, readRawData(more), 2)
  check s == filled(20, 'x') & "ab", "heap string appends"

section "dropPrefix"
block:
  var s = "hello world"
  dropPrefix(s, 6)
  check s == "world", "drop from an inline string"
  dropPrefix(s, 0)
  check s == "world", "zero is a no-op"
  dropPrefix(s, 99)
  check s == "" and s.len == 0, "dropping past the end empties it"
block:
  var s = filled(30, 'a') & filled(30, 'b')
  dropPrefix(s, 30)
  check s == filled(30, 'b'), "drop within a heap string"
  dropPrefix(s, 25)
  check s == "bbbbb", "drop leaving a short tail"
  check s == filled(5, 'b'), "the short tail compares as a fresh string"
block:
  var s = filled(64, 'q')
  dropPrefix(s, 64)
  check s.len == 0, "drop everything"
  var t = "again"
  appendBytes(s, readRawData(t), 5)
  check s == "again", "reusable after emptying"

section "copyOut"
block:
  var buf = default(array[8, char])
  copyOut(addr buf[0], "0123456789", 3, 4)
  check buf[0] == '3' and buf[3] == '6' and buf[4] == char(0), "copies the requested window"
  copyOut(addr buf[0], "x", 0, 0)
  check buf[0] == '3', "zero bytes leaves the target alone"

finish()
