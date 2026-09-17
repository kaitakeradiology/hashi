## Unit tests for `addAsyncHandler`: the passive handler chain's registration
## accounting. The chain has no capacity, so registration must never drop a
## handler and the count must follow every registration.
##
## The live behaviour (a registered handler claiming a request, the next one
## being tried when it returns `none`) needs a serving loop and is covered by
## the end-to-end runs; this covers the registry.

import std/syncio
import std/opt
import hashi/http/server
import hashi/http/request
import testkit

proc neverClaims(req: Request): Opt[Response] {.passive.} =
  ## Falls through to the sync router — the chain keeps trying past it.
  result = none[Response]()

section "addAsyncHandler — registration accounting"
check asyncHandlerCount() == 0, "chain starts empty"
check not hasAsyncHandler(), "hasAsyncHandler is false while empty"
addAsyncHandler(neverClaims)
check asyncHandlerCount() == 1, "the first handler registers"
check hasAsyncHandler(), "hasAsyncHandler is true once one is registered"
addAsyncHandler(neverClaims)
check asyncHandlerCount() == 2, "the count follows registration"

section "the chain has no capacity"
var i = 2
while i < 100:
  addAsyncHandler(neverClaims)
  i = i + 1
check asyncHandlerCount() == 100, "100 handlers register — no cap, no silent drop"
check hasAsyncHandler(), "…and the chain still reports itself non-empty"

finish()
