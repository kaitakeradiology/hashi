# Nimony issues found while building hashi

Each is worked around in the tree; the note says where. To report
upstream, with a reduced case, as time allows.

- **`std/unicode.validateUtf8` accepts surrogates and overlong three-byte
  forms**, which RFC 3629 and RFC 6455 reject and Autobahn's 6.x cases
  check. `hashi/ws/protocol` keeps its own validator.
- **`std/ioring.listenTcp` is IPv4-only and asserts on failure.**
  `hashi/net` has a dual-stack listen with structured errors.
- **Calling a proc value bound by a `for` loop variable** (`for m in procs:
  m(x)`) crashes the compiler in derefs (`fnType.isParamsTag`). Such
  loops are indexed in `hashi/http/router`.
- **A `.passive` proc value called straight off a seq element's field**
  (`xs[i].handler(ws)`) miscompiles to a call with the wrong arity. It is
  copied to a local first in `hashi/http/server`.
- **A `Request` returned in a tuple from a `.passive` proc, or passed to one
  as a `var` parameter, was corrupt after the next suspension.** Not
  isolated to one of the two shapes. The driver keeps the request on the
  connection record instead.
- **Removing an overload leaves dependants' cached NIF referring to the old
  symbol suffix** (`[Bug] could not find symbol: serve.1…`) until `nimcache`
  is cleared.
- **`nimony doc` asserts on a signature mentioning `Opt[T]`** (pages are
  still emitted; `doc/gen` tolerates it) and **fails for a module that needs
  compile-time evaluation** (`hashi/log` uses literal colour codes for this
  reason).
