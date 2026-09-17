## Fuzzer for `hashi/buffer`: random sequences of appends, drops and copies
## against a plain-string model, across the string's inline and heap tiers.
##
##   ../nimony/bin/nimony c -r tests/fuzz_buffer.nim

import std/syncio
import hashi/buffer
import testkit
import fuzzkit

seedFuzz(0xA54FF53A5F1D36F1'i64)
const iterations = 3000

section "append/drop/copy against a model"
block:
  var bad = 0
  for it in 0 ..< iterations:
    var s = ""
    var model = ""
    for step in 0 ..< 1 + rnd(12):
      case rnd(3)
      of 0:
        let chunk = randomBytesExact(rnd(40))
        var src = chunk
        appendBytes(s, readRawData(src), chunk.len)
        model.add chunk
      of 1:
        let n = rnd(model.len + 4)
        dropPrefix(s, n)
        model = if n >= model.len: "" else: substr(model, n)
      else:
        if model.len > 0:
          let start = rnd(model.len)
          let n = min(rnd(model.len - start + 1), 64)
          var buf = default(array[64, char])
          copyOut(addr buf[0], s, start, n)
          for k in 0 ..< n:
            if buf[k] != model[start + k]: inc bad
      if s != model or s.len != model.len: inc bad
  check bad == 0, "buffer matched the model through " & $iterations & " random sequences"

finish()
