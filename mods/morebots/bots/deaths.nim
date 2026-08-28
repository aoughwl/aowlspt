## A ledger of deaths, kept per concrete receiver class.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## `bots/census.nim` answers "did the bots I asked for actually show up?" by
## walking the world's alive-player list every few seconds. That is the right
## shape for a *population* question and it has one blind spot that no interval
## can close: **a bot that spawned and died between two scans was never there.**
## On a map where the server raised the cap and the client is churning through
## spawns, the census reports a steady twenty-two and the raid is in fact
## turning over sixty, and the two readings are indistinguishable from the log.
##
## A death is an event, and the only way to count events is to be told about
## each one. That is a hook, and it is one of the nine upstream Harmony patches
## this port refused. It was refused on the grounds that a hook is not told
## which instance it fired on — which was false, and `bots/instance.nim` says
## exactly what the payload does and does not carry. This is the first thing in
## this mod to use it.
##
## ---------------------------------------------------------------------------
## WHAT IT IS AND IS NOT
## ---------------------------------------------------------------------------
##
## **Read-only, unconditionally.** The handler returns `carryOn()` on every
## path, including every failure path. It never suppresses, never replaces a
## return value and never writes anything into the game. That is not modesty:
## it is what makes an unverified `EFT.` name safe here. If the target name is
## wrong the hook never arms and the ledger reads zero; if the name is right
## but the shape is not what is assumed, the worst case is a count grouped
## under a class nobody expected. Neither of those can make a raid wrong, which
## is the only reason it is defensible to ship a hook against a name nothing in
## this tree can check.
##
## **Grouped by the receiver's concrete class, and by nothing else.** The
## payload's `this` carries `fullName(rt, objectClass(rt, self))` — the real
## class of the object in front of the hook. Grouping on that needs no field
## offset, no property name and no member chain, so it is the one per-instance
## fact this mod can act on without adding a second hypothesis on top of the
## target name. What it deliberately does **not** do is say *which bot* died:
## that needs a member read off the receiver, every candidate name for it is a
## pre-1.0 guess, and a role attribution that is quietly wrong is worse than no
## role attribution at all. The census already reports roles, from a chain that
## is guarded binding by binding.
##
## **It has never run against BSG's client.** Not once. `EFT.
## BaseStatisticsManager::OnDeath` is a pre-1.0 name and post-1.0 is a
## different build. Everything below is an argument from code. What *is*
## checked offline is the whole of the arming decision and the whole of the
## tally, because both are functions of a string.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import instance

const
  DeathTarget* = "EFT.BaseStatisticsManager::OnDeath"
    ## Upstream patched this. The name travels with the port so that the day
    ## somebody dumps a post-1.0 client there is one string to change and a
    ## `refused:` line in the log that already names it.

# ---------------------------------------------------------------------------
# The ledger
# ---------------------------------------------------------------------------
#
# Two parallel `seq`s rather than a table, which is this project's habit
# everywhere and is not an accident: a raid produces a handful of distinct
# receiver classes, a linear scan over five strings is faster than hashing one,
# and the insertion order is the order they were first seen, which is a more
# useful thing to print than an arbitrary one.

var gClasses: seq[string] = @[]
var gCounts: seq[int] = @[]
var gFirings = 0
var gNoInstance = 0
var gUnnamed = 0

proc resetLedger*() =
  ## Between raids. Not called from the handler, obviously.
  gClasses = @[]
  gCounts = @[]
  gFirings = 0
  gNoInstance = 0
  gUnnamed = 0

proc noteDeath*(payload: string) =
  ## The tally, split out of the handler so that it is a pure function of the
  ## payload and can be driven from a self-test with no game and no hook.
  ##
  ## Every counter it moves is monotone, which is what makes an assertion on it
  ## meaningful: an unchanged count after a drive means the drive did nothing,
  ## and cannot be confused with a count that went up and came back down. This
  ## project keeps producing checks that pass because the thing they check
  ## never happened, and a monotone counter is the cheapest defence against
  ## writing another one.
  inc gFirings
  let i = instanceOf(payload)
  if not i.said or i.isStatic:
    # Either not a prefix payload, or a static method — in both cases there is
    # no receiver to group under. Counted separately rather than dropped: a
    # ledger that is all firings and no classes is a target whose shape is not
    # what this file assumes, and that is a fact worth seeing in a log.
    inc gNoInstance
    return
  if i.typeName.len == 0:
    inc gUnnamed
    return
  for k in 0 ..< gClasses.len:
    if gClasses[k] == i.typeName:
      gCounts[k] = gCounts[k] + 1
      return
  gClasses.add i.typeName
  gCounts.add 1

proc deathFirings*(): int = gFirings
proc deathClasses*(): int = gClasses.len
proc deathsWithoutInstance*(): int = gNoInstance
proc deathsUnnamed*(): int = gUnnamed

proc deathsOf*(typeName: string): int =
  ## How many deaths were seen on that concrete class.
  result = 0
  for k in 0 ..< gClasses.len:
    if gClasses[k] == typeName:
      return gCounts[k]

proc describeDeaths*(): string =
  ## Counts, never a verdict — "ok" cannot tell one death from sixty.
  if gFirings == 0:
    return "0 death(s) observed"
  result = $gFirings & " death(s) over " & $gClasses.len & " receiver class(es)"
  for k in 0 ..< gClasses.len:
    result = result & "; " & gClasses[k] & " " & $gCounts[k]
  if gNoInstance > 0:
    result = result & "; " & $gNoInstance &
             " firing(s) carried no receiver at all"
  if gUnnamed > 0:
    result = result & "; " & $gUnnamed &
             " firing(s) had a receiver the runtime would not name"

# ---------------------------------------------------------------------------
# Arming it
# ---------------------------------------------------------------------------

proc onDeath(target, args: string): HookResult =
  ## Read-only on every path, including the ones that give up.
  noteDeath(args)
  carryOn()

var gState = "not armed"

proc deathState*(): string = gState

proc armDeaths*(rt: Il2Cpp; live: bool): bool =
  ## Install the ledger's hook, or refuse and say what the refusal costs.
  ##
  ## The guard is `mods/fov`'s discipline and every clause of it earns its
  ## place. What is checked, in order, is: is there a runtime at all; does the
  ## class exist; does the method exist; **is it an instance method** — because
  ## a static one has no receiver and this whole file is a grouping by
  ## receiver, so arming on one would produce a ledger of firings under no
  ## class and look like a target that never fires; and finally, are any
  ## declared arguments going to be silently absent from the payload.
  ##
  ## That last clause is checked even though this handler reads no argument.
  ## The cost of checking it is one subtraction and the cost of not checking it
  ## is a future edit that starts reading argument 3 of a four-argument
  ## instance method and gets a decision made on a value that was never there.
  ## `bots/instance.nim`'s `argsTruncated` has the whole argument.
  gState = "not armed"
  if not live:
    gState = "refused: no IL2CPP runtime in this process, so " & DeathTarget &
             " cannot even be looked up. The cost is the census's blind " &
             "spot: a bot that spawns and dies between two scans is never " &
             "counted, and a raid turning over sixty bots reads the same as " &
             "one holding twenty-two"
    return false
  let sep = find(DeathTarget, "::")
  if sep < 0:
    gState = "refused: " & DeathTarget & " is not `Type::Member`"
    return false
  let owner = DeathTarget.substr(0, sep - 1)
  let member = DeathTarget.substr(sep + 2)

  # THE MOD-SIDE `findClass` PRE-FLIGHT THAT USED TO SIT HERE IS GONE.
  #
  # It was `findClass(rt, owner)` -> `findMethod` -> `methodIsStatic` ->
  # `methodParamCount`, and it existed to produce nicer refusal strings. Every
  # one of those four dereferences the handle `il2cpp_class_from_name` hands
  # back, and that export is TOKEN-GATED on this build: on mismatch it answers
  # a uniform random NON-ZERO uint64, so `if cls == nil` cannot fire and the
  # first dereference is 0xC0000005 (fact #198). Measured in this repo, out of
  # the game: opening `D:\Games\Tarkov\GameAssembly.dll` in `aowlspt-sim` and
  # calling `findClass("System.Int32")` kills the process with no diagnostic.
  # Better error text is not worth that, and the pre-flight bought nothing the
  # host does not already answer.
  #
  # WHAT IT DOES NOT FIX, STATED PLAINLY. `hookArgs` below is still a BY-NAME
  # target, and the host's `installPatch` resolves a bare `Type::Method` spec
  # with `findClass` + `findMethod` FIRST and only consults the offline
  # `aowlspt-names.idx` afterwards, as a fallback for the CODE POINTER when
  # `MethodInfo.methodPointer` came back null. So a by-name `hook`/`patch`
  # goes through the GATED EXPORTS, in the host, on the host's thread. The
  # name index does not remove that hop; it only rescues the address.
  #
  # The safe form is the `@0xRVA/<shape>` spec, which takes `installPatch`'s
  # `resolveByRva` branch and never calls `findClass` at all. This target is
  # HALF-derived toward it and is deliberately not finished:
  #
  #   EFT.BaseStatisticsManager::OnDeath  RVA 0x92C610  ('unique', 1)
  #   prologue  48 89 5C 24 10 48 89 74 24 18 57 41 56 41 57 48
  #   signature void OnDeath(Player, IPlayer, DamageInfo, EBodyPart)
  #
  # The shape string needs one letter PER DECLARED ARGUMENT, and argument 3's
  # type `DamageInfo` does not resolve as a type name in this build's metadata
  # (`fldoff.py` searched all 31,282 type names exhaustively for a zero hit),
  # so its width -- and therefore `v` versus `V` -- is NOT derived. CLAUDE.md 5
  # requires a patch frame shape to be derived, never inferred from a name, so
  # the spec is left unwritten rather than guessed. Finish that one lookup and
  # this target stops being by-name.
  # `declared` is now UNKNOWN rather than read from the runtime, and -1 is what
  # this file already means by that. `argsTruncated` answers 0 for it, so the
  # note below is skipped instead of printing a number nobody measured -- which
  # is the right trade: the old number came from `methodParamCount` on a handle
  # that could not be trusted to exist.
  let declared = -1
  let cut = argsTruncated(declared, false)
  if cut > 0:
    # Not fatal for *this* handler, which reads no argument. Named anyway, and
    # named with the number, because the next person to touch this file will
    # want it and will not go looking for it.
    info "morebots: " & DeathTarget & " declares " & $declared &
         " parameter(s) and the payload will carry " &
         $argsReportable(declared, false) & " of them -- `this` takes " &
         "register position 0 and the last " & $cut &
         " are on the stack. Nothing here reads an argument, so this costs " &
         "nothing today; it would cost a wrong answer to anything that did"
  if hookArgs(DeathTarget, onDeath) != Ok:
    gState = "refused: " & lastError()
    return false
  gState = "armed on " & DeathTarget & ", read-only, grouping by the " &
           "receiver's concrete class"
  result = true
