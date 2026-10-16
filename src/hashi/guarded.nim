## `Guarded[T]` and `guarded`: lock-protected shared state under Nimony's
## restricted-globals check (nim-lang/nimony#2609).
##
## A routine may touch a mutable module-level `var` only through a `.sync`
## routine or inside `{.cast(assumeSync).}`. A lock-guarded global is the case
## where the cast is honest, and this module is the one place it is written.
##
## `Guarded[T]` owns a value and the `TicketLock` that protects it. The value
## is reachable only through `withLock`, so a `Guarded` can be a plain
## module-level `var` and no caller writes a cast:
##
##   var gCount: Guarded[int]
##   gCount = initGuarded(0)
##
##   proc bump*() =
##     withLock gCount:         # `it` is a `var int` alias of the value
##       it = it + 1
##
## When the shared state is several globals under one lock, or a structure
## that is not a single value, use `guarded` with a `TicketLock`:
##
##   var gLock: TicketLock
##   var gHead, gTail: int      # only under gLock
##
##   guarded gLock:
##     gHead = gHead + 1
##
## The alias is always named `it`, not a name the caller picks: Nimony's
## templates do not substitute a parameter into a declaration's name (checked
## at 6c64e9d7 for `template`, `var`, `for` and `proc` parameters). A nested
## `withLock` shadows the outer `it`; copy what you need out first.
##
## Rules for both bodies:
## - The body must not `return` (or `break`/`continue` out of it) and must not
##   raise: the lock would stay held. There is no try/finally on purpose, so
##   realtime callers do not grow unwinding code.
## - Do not suspend in the body (a `.passive` call): every other user of the
##   lock would block its worker thread. Copy what you need out, leave the
##   body, then suspend.
## - The cast holds only if every access to the guarded state is under the
##   same lock. That is the caller's promise; `Guarded[T]` makes it by
##   construction, `guarded` does not.
##
## A `Guarded[T]` must not be copied while shared; initialise it once, before
## other threads can see it.

import std/ticketlocks

type
  Guarded*[T] = object
    lock*: TicketLock  ## exported only so `withLock` can expand in the caller's
    val*: T            ## module; touch them only through `withLock`

proc initGuarded*[T](v: sink T): Guarded[T] =
  ## A guarded `v`. Call it before the value is shared.
  result = Guarded[T](lock: TicketLock(), val: v)

template withLock*[T](g: var Guarded[T]; body: untyped) =
  ## Acquires `g`'s lock, runs `body` with `it` as a `var T` alias of the
  ## value, and releases. The body must not `return` or raise; see the module
  ## header.
  acquire(g.lock)
  {.cast(assumeSync).}: # g.val: under g.lock
    block:
      template it(): untyped {.inject.} = g.val
      body
  release(g.lock)

template guarded*(lock: var TicketLock; body: untyped) =
  ## Acquires `lock`, runs `body` with the cast that lets it touch the globals
  ## `lock` protects, and releases. The body must not `return` or raise.
  acquire(lock)
  {.cast(assumeSync).}: # the globals `lock` guards
    body
  release(lock)
