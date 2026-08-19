## One lock, for a mod's own state.
##
## ## Why a mod needs this at all
##
## A mod's globals are not touched by one thread. The backend serves requests on
## a pool of workers, so two route handlers in the same mod run at once; the
## client host calls `on_update` on its own thread while a detour fires on the
## game's; and a timer or an event subscriber may arrive on either. Anything a
## mod keeps between calls — a resolved selection, a cache, a counter — is
## shared mutable state, and nothing in the ABI was guarding it.
##
## That is not hypothetical. Two concurrent `/toggle` requests to the mod
## manager mutate its registry, its resolution and its selection with no
## exclusion at all, and two concurrent purchases against one profile silently
## lost updates until the backend grew per-session serialisation. The server can
## only serialise what it can *see* — a session id — and it cannot know which of
## a mod's globals a route touches.
##
## ## Why it needs no ABI call
##
## `abi/aowlspt_lock.h` is a one-time-initialised `CRITICAL_SECTION` whose
## contents are `static`, and nimony emits one translation unit per module. So
## the lock below belongs to **this module, in this mod's library** — every mod
## that links the library gets exactly one of its own, and two mods can never
## contend with each other. That is the right granularity and it costs no ABI
## revision, no host support, and nothing at all on the hosts that already have
## their own.
##
## It is not the host's lock. The host's guards the host's lists; this one
## guards the mod's. A mod holding this while calling into the host is fine; the
## reverse cannot happen, because the host has never heard of it.
##
## It is not the scheduler's lock either. `aowlspt.nim` includes the same header
## into *its* translation unit and so has a second, independent critical section
## of its own for the tick table, which is why `after`, `every`, `onMainThread`,
## `everyMain`, `scheduledSlots` and `stopMainRepeats` are safe to call from
## inside `withModLock` -- they take a different lock, not this one again. The
## scheduler never holds its lock across a call into a mod's handler, so it is
## always the innermost and there is no order to get wrong.
##
## ## Using it
##
## ```nim
## import aowlspt/sync
##
## var gCache: seq[string] = @[]
##
## proc remember(s: string) =
##   lockMod()
##   gCache.add s
##   unlockMod()
## ```
##
## `withModLock` is the same thing without the chance of forgetting the second
## line:
##
## ```nim
## withModLock:
##   gCache.add s
## ```
##
## Hold it for the shortest span that keeps the state consistent, and **never
## across a call that can block** — an HTTP fetch, a `sleep`, a route that waits
## on something else. It is not reentrant: taking it twice on one thread
## deadlocks. Windows' `CRITICAL_SECTION` is in fact recursive, so that would
## happen to work today; do not rely on it, because the guarantee here is the
## one written down, not the one the platform happens to give.

{.emit: """#include "aowlspt_lock.h" """.}

# Not `inline`, and that is not an oversight. `{.emit.}` is module-scoped: the
# `#include` above lands in *this* module's translation unit, and an inline
# body would be copied into the importing mod's, where `aowl_lock` has never
# been declared. The failure is an implicit-declaration error in generated C
# that names a function the mod never wrote. `perfCounter` in `fast.nim` hit
# the same wall.
proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

proc lockMod*() =
  ## Takes this mod's lock. Every path out of the guarded region must call
  ## `unlockMod`; prefer `withModLock`, which cannot be left by accident.
  cLock()

proc unlockMod*() =
  ## Releases it.
  cUnlock()

template withModLock*(body: untyped) =
  ## Runs `body` holding this mod's lock.
  lockMod()
  body
  unlockMod()
