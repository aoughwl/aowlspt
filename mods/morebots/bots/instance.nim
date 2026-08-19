## What a hook is told about the instance it fired on — and what it is not.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## Nine of MoreBots' upstream Harmony patches were refused here, and eight of
## the refusals were written against one sentence: *a hook is not told which
## instance it fired on*. That sentence was false when it was written and it is
## false now. `hookArgs` delivers
##
##     {"this":{"handle":3,"type":"EFT.BotsGroup"},"args":[{"handle":4,...}]}
##
## — Harmony's `__instance`, kept out of the argument array on purpose — and
## `thisHandle`/`thisPointer` in `aowlspt/game` read it. `mods/classicmovement`
## has been calling `thisPointer(args)` in shipped code since ABI revision 3.
##
## A false blocker is worse than a real one, because nobody re-checks it. So
## this file does not merely delete the sentence: it makes the capability
## **testable**, as pure functions over the payload string, so that the claim
## can go red in a self-test on a machine with no game attached. That is the
## only kind of check this project trusts — see the note on `argsTruncated`
## below for the failure species it is guarding against, which is a check that
## passes because the thing it checks never happened.
##
## ---------------------------------------------------------------------------
## WHAT `this` ACTUALLY GIVES A HOOK
## ---------------------------------------------------------------------------
##
## Four facts, and all four come out of the payload text with no binding, no
## call and no name that has to be guessed at:
##
##  1. **Whether there is an instance at all**, distinguishably. A static
##     method's `this` is the literal `null`, not an absent member, so "the
##     method is static" and "the host did not say" are two different answers
##     rather than one. `Instance.said` and `Instance.isStatic` keep them apart.
##  2. **A handle to it**, good for `call` and for `pointerOf`, and valid *only
##     until the handler returns*. The host frees it at that point.
##  3. **Its address**, via `thisPointer`, which is what `aowlspt/fast` binds
##     against — tens of nanoseconds against roughly a microsecond for the
##     boxed path. Same lifetime rule, and sharper, because an address cannot
##     refuse a late read the way a handle can.
##  4. **Its concrete runtime type name** — see below, because it is the one
##     that gets missed and it is worth its own section.
##
## ---------------------------------------------------------------------------
## THE CONCRETE CLASS IS THE CHEAP ONE, AND NOBODY USES IT
## ---------------------------------------------------------------------------
##
## The `type` in `{"handle":n,"type":"..."}` is not the declaring class of the
## method that was patched. The host writes
##
##     fullName(rt, objectClass(rt, self))
##
## — `describeArgs`, `host/Aowlspt.Host.Il2Cpp/invoke.nim` — which is
## `il2cpp_object_get_class` on the receiver. It is **the real class of the
## object in front of the hook**, resolved at the moment it fired.
##
## Two consequences, and the second is the one that matters here.
##
## **A hook on a base method can tell the subclasses apart.** SPT's raid world
## is a `GameWorld` subclass; bots and the local player are different `Player`
## subclasses; `bots/census.nim` binds against objects rather than names for
## exactly that reason. One patch on the base method sees every subclass go
## past and can say which is which, with no second hook and no type test.
##
## **It costs nothing and it risks nothing.** Every other way of learning
## something about a live object goes through a name this repository cannot
## check: a field offset, a property, a member chain, each one a pre-1.0
## hypothesis whose wrong answer is a number rather than an error. The class
## name is *already in the payload*. Reading it needs no `findClass`, no
## `bindField`, no offset and no guess — and if it is a name nobody expected,
## the mod has learnt a fact rather than computed a wrong one.
##
## So: **before reaching for a member, ask whether the concrete class answers
## the question.** In a tree where every `EFT.` name is a hypothesis, the one
## fact the host hands over for free is the one to build on. `bots/deaths.nim`
## is the worked example — it groups a whole ledger by concrete receiver class
## and reads not one member to do it, so the only hypothesis it carries is the
## target name, and a wrong target name arms nothing instead of counting wrong.
##
## What the class name is *not* is an identity; that limit is stated below and
## is where the honest boundary sits.
##
## ---------------------------------------------------------------------------
## WHAT IT STILL DOES NOT GIVE
## ---------------------------------------------------------------------------
##
## These are the replacement claims, and they are narrower than the one they
## replace on purpose. A replacement blocker that is also false would be the
## same mistake twice.
##
##  * **A type name is not an identity.** `this` says *what class* the object
##    is. Which bot, which group, which faction — none of that is in the
##    payload. Getting it means reading a member off the object, and every such
##    member name is a pre-1.0 hypothesis that nothing in this tree can check.
##    `this` moves those refusals from "inexpressible" to "unverifiable", which
##    is a real change and is not the same as closing them.
##  * **A hook cannot navigate upwards.** `this` is the receiver, never its
##    owner. A patch on a component that needs the entity holding it — which is
##    precisely what upstream's `BotOwner_0` was for, and precisely what SPT
##    4.1.2 removed — gets the component and nothing else.
##  * **Only three declared arguments reach an instance method's payload.**
##    `this` occupies register position 0 and pushes every parameter along by
##    one, and the host reports four register positions and stops
##    (`MaxRegArgs`). The fourth declared argument of an instance method is on
##    the stack and is **omitted from the array rather than reported as
##    missing**. `argsTruncated` below is the whole reason this file exists as
##    something other than a comment.
##  * **The handle does not outlive the handler.** No firing can be compared
##    with the previous one by handle, and an address written down is a number
##    the collector has since invalidated. `pinHandle` is the way to keep an
##    object and it says what pinning costs.
##  * **Nothing here constructs a managed object.** `il2cpp_object_new` is
##    resolved by the loader but is not exposed to a mod, and upstream's brain
##    swap needed something stronger than instantiation anyway: a *new type*
##    with overridden virtuals. IL2CPP has no runtime type definition and
##    nothing native can declare one. That refusal is untouched by any of this.
##
## Nothing in this file has ever run against BSG's client. Everything it does
## is arithmetic on a string the host produces, so it is checkable offline in
## full — which is exactly why the decision was moved into it.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/json

const
  RegisterSlots* = 4
    ## How many register positions the host reports arguments out of.
    ##
    ## This mirrors `MaxRegArgs` in `host/Aowlspt.Host.Il2Cpp/invoke.nim` and
    ## the four `kinds` slots in `abi/aowlspt_frame.h`. It is duplicated rather
    ## than imported because a mod does not link the host — and duplicated
    ## *with the citation*, so that the day the host grows a stack-argument
    ## reader there is a string to grep for.

type
  Instance* = object
    ## What the payload said about `__instance`.
    said*: bool
      ## The payload carried a top-level `this` member. False means this is
      ## not a hook payload at all — a handler registered against the wrong
      ## thing, or a malformed string — and it is kept separate from
      ## `isStatic` because "the host said there is no instance" and "the host
      ## said nothing" call for different reactions.
    isStatic*: bool
      ## `"this":null`. The method is static; there is no receiver and the
      ## host is telling you so rather than leaving it out.
    handle*: uint64
      ## Good until the handler returns, and not one instruction longer.
    typeName*: string
      ## The **concrete runtime class** of the receiver, or "".

proc noInstance*(): Instance =
  Instance(said: false, isStatic: false, handle: 0'u64, typeName: "")

proc typeIn*(json: string): string =
  ## The `"type":"..."` of a `{"handle":n,"type":"..."}`, or "".
  ##
  ## A scan rather than a parse, for the same reason `memberRaw` is one: the
  ## host is the only producer of this shape, and a game string in a sibling
  ## argument can contain anything at all. Only the *first* `"type":` is taken,
  ## which is correct because a handle object has exactly one and no nesting.
  result = ""
  let needle = "\"type\":\""
  let at = find(json, needle)
  if at < 0:
    return
  var i = at + needle.len
  var out1 = ""
  while i < json.len:
    let ch = json[i]
    if ch == '\\' and i + 1 < json.len:
      # A backslash escape is copied through verbatim. A type name has no
      # business containing one, but reading a name that ends early is how a
      # comparison silently starts answering false.
      out1.add ch
      inc i
      out1.add json[i]
      inc i
      continue
    if ch == '"':
      return out1
    out1.add ch
    inc i
  # Unterminated: no closing quote, so nothing is claimed.
  result = ""

proc instanceOf*(payload: string): Instance =
  ## Everything the payload says about the receiver, in one read.
  result = noInstance()
  let raw = memberRaw(payload, "this")
  if raw.len == 0:
    return
  result.said = true
  if raw == "null":
    result.isStatic = true
    return
  result.handle = handleIn(raw)
  result.typeName = typeIn(raw)

proc isInstanceOf*(payload, typeName: string): bool =
  ## Whether the receiver's concrete class is exactly `typeName`.
  ##
  ## Exact, not a prefix and not a suffix. `EFT.BotsGroup` and
  ## `EFT.BotsGroupClass` are different classes and a `startsWith` test would
  ## conflate them; `Foo.Player` and `Bar.Player` likewise for a suffix test.
  ## A caller that genuinely wants a family should ask for each member of it.
  let i = instanceOf(payload)
  result = i.said and not i.isStatic and i.typeName == typeName

# ---------------------------------------------------------------------------
# The arguments, and the ones that are not there
# ---------------------------------------------------------------------------

proc argsRawOf*(payload: string): string =
  ## The raw `args` array of a payload, or "".
  memberRaw(payload, "args")

proc argsReported*(payload: string): int =
  ## How many arguments the payload actually carries.
  ##
  ## Note the word *reported*. This is not the method's arity and must never be
  ## used as one — see `argsTruncated`.
  let raw = argsRawOf(payload)
  if raw.len < 2:
    return 0
  let a = whole(raw)
  if not isArray(a):
    return 0
  result = count(a)

proc argAt*(payload: string; index: int): string =
  ## The raw JSON of one reported argument, or "".
  result = ""
  let raw = argsRawOf(payload)
  if raw.len < 2:
    return
  let a = whole(raw)
  if not isArray(a):
    return
  let items = each(a)
  if index < 0 or index >= items.len:
    return
  result = items[index].raw()

proc argsReportable*(declared: int; isStatic: bool): int =
  ## How many of `declared` parameters arrive **with a value**.
  ##
  ## This said "will put in the array", and that stopped being true the day the
  ## host started naming the slots it cannot fill. The array is now `argc` long
  ## always: the parameters past the register window are present and carry
  ## `{"onStack":true,"type":"..."}` instead of a value. So the count below is
  ## still exactly right and still worth asserting on -- it is the number of
  ## *readable* entries -- but the ones past it are no longer missing, they are
  ## named. `argRefusal` says so in its own words.
  ##
  ## `this` occupies register position 0 on an instance method and pushes every
  ## parameter along by one, so an instance method reports **three** and a
  ## static one reports four. The host's loop is
  ##
  ##     let pos = (if isStatic: i else: i + 1)
  ##     if pos >= MaxRegArgs: break
  ##
  ## and this is that arithmetic, stated where a mod can assert on it.
  if declared <= 0:
    return 0
  let room = (if isStatic: RegisterSlots else: RegisterSlots - 1)
  result = (if declared < room: declared else: room)

proc argsTruncated*(declared: int; isStatic: bool): int =
  ## How many declared parameters the payload will simply not contain.
  ##
  ## **This is the check that had to exist**, and the failure it was written
  ## against has since been closed at the host rather than only guarded here. A
  ## hook that read argument 3 of a four-argument instance method used to get
  ## "" and, if it treated "" as a default, made a decision on a value the game
  ## never supplied -- nothing erroring, nothing logging, and working perfectly
  ## on every three-argument method anyone tested it against. It was the same
  ## species as the bug this mod's population baseline exists for: a wrong
  ## answer that only ever arrives in the one case nobody exercised.
  ##
  ## The host now names that slot instead of dropping it, so the silent read is
  ## gone. The count is still the honest thing to ask before arming, because a
  ## named slot is still a parameter you cannot have.
  ##
  ## So a caller that has a signature in hand asks this *before* arming, and
  ## refuses with the number, rather than discovering it one argument at a time
  ## in a live raid.
  result = declared - argsReportable(declared, isStatic)
  if result < 0:
    result = 0

proc argRefusal*(raw: string): string =
  ## Why one argument cannot be read, or "" if it can be.
  ##
  ## **An absent argument is a refusal, not a pass.** This proc used to answer
  ## "" for an empty string, which made "the host did not report this argument"
  ## and "this argument is fine" the same answer — and that exact ambiguity is
  ## the defect the whole file exists to prevent, since the host *silently
  ## omits* an instance method's fourth declared parameter. A caller that got ""
  ## back would go on to read a value that was never supplied. So "" now means
  ## one thing only: there is a value here and it can be read.
  ##
  ## Three ways it cannot be, and the host is explicit about two of them rather
  ## than inventing a number for either:
  ##
  ##   * **absent** — nothing at that position at all. Use `argStatus` below to
  ##     find out *why*, because "past the register window" and "the array was
  ##     shorter than the signature said" are different bugs.
  ##   * `{"valueType":"X"}` — a value type too wide for a register. It arrived
  ##     by hidden pointer and the register holds an address to a copy whose
  ##     layout nothing here can read.
  ##   * `{"type":"X"}` — the runtime would not name a class for it. Saying so
  ##     beats guessing that it is an object, because that guess is a crash.
  ##   * `{"onStack":true,"type":"X"}` — the parameter is real and is past the
  ##     four registers the patch frame captures. This one is newer than the
  ##     rest of this file: the host used to omit the slot entirely, which is
  ##     the absence above. It is named now, so the index no longer lies, and
  ##     the marker carries `type` without `handle` deliberately -- a reader
  ##     that has never heard of `onStack` falls into the case above and
  ##     refuses, rather than passing.
  ##
  ## An argument that is none of the three is a number, a string, `null`, or a
  ## `{"handle":n,"type":"..."}` — and a handle object carries `handle` too,
  ## which is what distinguishes it from the second placeholder.
  result = ""
  if raw.len == 0:
    return "no argument was reported at that position. It is ABSENT, which is " &
           "not the same as empty and must never be read as a default"
  if find(raw, "\"valueType\":") >= 0:
    let t = typeIn(raw)
    let named = (if t.len > 0: t else: "an unnamed value type")
    return "it is " & named & ", a value type too wide for a register: it " &
           "arrives by hidden pointer and its layout cannot be read here"
  if find(raw, "\"onStack\":") >= 0:
    let t = typeIn(raw)
    let named = (if t.len > 0: t else: "an unnamed type")
    return "it is " & named & " passed on the stack, past the four registers " &
           "the patch frame captures: `this` takes the first, so an instance " &
           "method's fourth declared parameter lands here. The host names the " &
           "slot rather than dropping it, which is why this is a refusal you " &
           "can read instead of an index that quietly is not there"
  if find(raw, "\"type\":") >= 0 and find(raw, "\"handle\":") < 0:
    let t = typeIn(raw)
    let named = (if t.len > 0: t else: "an unnamed type")
    return "the runtime would not name a class for " & named & ", so the " &
           "host reported it rather than guessing it is an object"

proc argStatus*(payload: string; index, declared: int;
                isStatic: bool): string =
  ## Why declared parameter `index` cannot be read, or "" if it can be.
  ##
  ## `argRefusal` answers about a value in hand. This answers about a
  ## *parameter*, which is the question a caller actually has, and it is the
  ## only one that can tell the three absences apart. They are three different
  ## bugs and must never print alike:
  ##
  ##   1. **There is no such parameter.** The caller is reading past the
  ##      signature — an off-by-one, or a signature that changed under it.
  ##   2. **The parameter exists and the host did not report it.** It is past
  ##      the register window and travelled on the stack. This is the silent
  ##      one: nothing is wrong with the caller, nothing is wrong with the
  ##      host, and the value is simply not there. `argsTruncated` has the
  ##      arithmetic.
  ##   3. **The parameter was reported and the array is short.** The payload
  ##      does not match the signature it was built from, which means one of
  ##      the two is not describing this method.
  ##
  ## Folding any of those into "" — or into each other — is the defect this
  ## file was written to remove. A caller that gets "" here has a value.
  if index < 0:
    return "argument index " & $index & " is not an index"
  if index >= declared:
    return "there is no declared parameter " & $index & "; this method " &
           "declares " & $declared & ". Reading past a signature is an " &
           "off-by-one, not an absent value"
  let room = argsReportable(declared, isStatic)
  if index >= room:
    var why = "`this` occupies register position 0"
    if isStatic:
      why = "the method is static, so all " & $RegisterSlots &
            " register positions are parameters"
    return "declared parameter " & $index & " was NOT REPORTED: " & why &
           " and the host reports " & $RegisterSlots & " register " &
           "positions, so parameters " & $room & ".." & $(declared - 1) &
           " travelled on the stack. They are absent from the payload, not " &
           "empty in it, and a default read here is a decision made on a " &
           "value the game never supplied"
  let raw = argAt(payload, index)
  if raw.len == 0:
    return "declared parameter " & $index & " should have been reported (" &
           $room & " of " & $declared & " fit the register window) and the " &
           "payload's args array has only " & $argsReported(payload) &
           " entry(s). The payload and the signature are not describing the " &
           "same method"
  result = argRefusal(raw)

proc argHandle*(payload: string; index: int): uint64 =
  ## The handle of one reported reference argument, or 0.
  ##
  ## Zero for a primitive, for a refused placeholder and for an out-of-range
  ## index alike — which is why `argRefusal` exists beside it. A caller that
  ## wants to know *why* it got zero has to ask; a caller that treats zero as
  ## "no object" is right in every case but is not told which one it hit.
  let raw = argAt(payload, index)
  if raw.len == 0:
    return 0'u64
  if argRefusal(raw).len > 0:
    return 0'u64
  result = handleIn(raw)

proc describeInstance*(payload: string): string =
  ## One line about the receiver, for a log or a self-test.
  let i = instanceOf(payload)
  if not i.said:
    return "no `this` member at all -- this is not a prefix hook payload"
  if i.isStatic:
    return "a static method: the host said `null` rather than omitting it"
  var name = i.typeName
  if name.len == 0:
    name = "an unnamed class"
  result = name & " (handle " & $int(i.handle) & ")"
