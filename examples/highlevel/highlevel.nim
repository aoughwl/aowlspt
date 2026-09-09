## The client host's **regression test**, written against the high-level API.
##
##     aowl build-mod examples/highlevel
##
## Read it side by side with `clientprobe` to see the two levels: that one is
## the raw interface -- `resolve` into a `Handle`, build a JSON argument string,
## `call`, parse the result out of a string -- and this one is the same ground
## covered through `aowlspt/game` and `aowlspt/fast`.
##
## **This is not the file to copy from.** `checkLog` in `tools/hostharness.nim`
## makes **twenty-four** verdicts about a run of the gate's stage, and
## **eighteen** of them are greps for exact strings this file prints -- `field
## agrees with get_`, `an enum parameter binds on the fast path`, `refused the
## other's binding`, `everyMain fired`. **Three** of those eighteen
## (`Add(17, 25) = 42`, the Unity version, a patch firing) it prints alongside
## `clientprobe`, which can satisfy them too, leaving **fifteen** that only this
## file can satisfy. Of the other six, two are `clientprobe`'s alone (the
## `resolved ` line and the Unity version) and four are the host's own log.
##
## This header said "twenty-three assertions and seventeen of them" until
## 2026-08-19, when the split was re-derived by matching every `find(l, "...")`
## in `checkLog` against what each mod actually prints. Do not count it by
## grepping `^ok` over the harness's output: that answers twenty-seven, because
## three `ok` lines belong to the "Mock runtime" and "Loading" sections and are
## about the staging rather than about the host. Count under `Result`.
##
## So it is organised around covering the host, not
## around teaching anyone: it hooks nearly every compiled method the stand-in
## runtime has, measures things a mod would not measure, and keeps a raw `this`
## address well past the handler it came from in order to compare two paths.
##
## **`examples/lesson` is the one to copy from.** Nothing greps it, it is
## ordered from what every mod does to what only a fast mod does, and it says
## why each API is shaped the way it is. The header of that file explains the
## split.
##
## Do not edit this one without moving those assertions with you.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import aowlspt/fast

# Types are named at the top and resolved on first use. Naming them here and
# resolving them here would not work -- the game's assemblies arrive later --
# and that gap is the thing `GameType` exists to close.
var Player = gameType("EFT.Player")
var Application = gameType("UnityEngine.Application")

var GameWorld = gameType("EFT.GameWorld")
var world = whenReady("EFT.GameWorld")
var ticks = 0
var hookFires = 0
var hooked = false
var argHooked = false
var skipHooked = false
var argHookFires = 0
var lastArgs = ""
var slotsAfterFirst = 0
var slotsChecked = false
var readySeen = -1
var enumHooked = false
var enumArgs = ""
var tiltArgs = ""

# The mod's own binding of the runtime. A mod DLL is in the host's process, so
# `openIl2Cpp` binds the already-loaded `GameAssembly.dll` directly -- which is
# what the address from `thisPointer` is *for*. Opened in a proc, never as a
# global initialiser: in an `--app:lib` build a global initialised by a call is
# left zeroed.
var rt: Il2Cpp
var rtOpen = false
var fTilt: FieldBinding
var staticsChecked = false
var fSpawn: StaticFieldBinding

# The per-frame chain on the game's thread. Counted here rather than trusted,
# because "it fired" and "it fired once a frame on the right thread" are
# different claims and only the second one is worth having.
var mainFires = 0
var mainThread = 0'i64
var mainThreadWobbled = false
var worldUp = false
var mainSlotsPeak = 0
var mainStarted = false
var mainReported = false
var mainStopTried = false
var mainStopChecked = false
var mainFiresAtStop = 0
var mainStopSaid = 0

# The `this`-on-the-fast-path checks.
var tiltViaPtr = -1.0        ## Tilt read through the raw `this`, in the hook
var tiltPtrSeen = 0'u64      ## the address itself, to prove it was not null
var tiltHandleSeen: Handle = 0'u64
var tiltFires = 0

# The postfix checks.
var sensHooked = false
var sensPayload = ""
var aimHooked = false
var aimPayload = ""
var aimThisPtr = 0'u64
var wideRefusal = ""

# What the two new paths cost, measured rather than claimed. A capability whose
# price is not re-checked is a capability that quietly stops being worth using.
var bareSensNs = 0'i64
var postSensNs = 0'i64
var ptrNs = 0'i64
var boxedNs = 0'i64
var pingBareNs = 0'i64
var pingPostNs = 0'i64
var pingFires = 0

proc openRuntime(): bool =
  if rtOpen:
    return true
  rt = openIl2Cpp()
  if not rt.loaded:
    return false
  rtOpen = true
  result = true

# ---------------------------------------------------------------------------
# `this`, on the fast path
# ---------------------------------------------------------------------------
#
# A named proc rather than an inline one, because it does real work: it turns
# the handle in the payload into the address of the object the game is about to
# act on, and reads a field straight off it.
#
# That is the whole point of the bridge. Before it, a hook that wanted anything
# from `this` had to go back through `call` on the handle -- a name lookup, a
# JSON build, a boxed invoke and a JSON parse, about a microsecond -- which on a
# method the game runs per entity per frame is a frame tax rather than a
# feature. Two mods measured exactly that and left five features out.

proc onSetTilt(target, args: string): HookResult =
  tiltArgs = args
  inc tiltFires
  tiltHandleSeen = thisHandle(args)
  let p = thisPointer(args)
  tiltPtrSeen = p
  if p != 0'u64 and openRuntime():
    if not fTilt.ok:
      fTilt = bindField(rt, "EFT.MovementContext", "Tilt")
    if fTilt.ok:
      tiltViaPtr = readFloat(fTilt, cast[Il2CppPtr](p))
  carryOn()

# ---------------------------------------------------------------------------
# Postfix hooks
# ---------------------------------------------------------------------------

proc onSensitivity(target, payload: string): HookResult =
  ## Scales what the original returned. The value it hands back is the whole
  ## assertion: 4.0 * 1.5 (the original) * 2 (here) is 12.0, and nothing this
  ## handler could do without having seen the original produces that number.
  sensPayload = payload
  let r = hookResult(payload)
  if not r.ok:
    return keepResult()
  replaceResult($(r.asFloat() * 2.0))

proc onAim(target, payload: string): HookResult =
  ## An **instance** postfix: `this` is in the payload alongside the result, so
  ## the same address bridge works after the original as before it.
  aimPayload = payload
  aimThisPtr = thisPointer(payload)
  keepResult()

proc onPing(target, payload: string): HookResult =
  ## The cheap postfix: no arguments asked for, nothing replaced. Only here to
  ## be timed against the expensive one -- a mod that just wants to watch a
  ## return value should know what that costs before it reaches for the version
  ## that also builds `this` and the argument list.
  inc pingFires
  keepResult()

# ---------------------------------------------------------------------------
# Typed hooks (ABI revision 4)
# ---------------------------------------------------------------------------
#
# The same two hooks the JSON path already proves -- a prefix that reads `this`
# and its arguments and suppresses, and a postfix that scales what the original
# returned -- written against the register frame instead of a payload.
#
# They are on *different* mock methods (`MovementContext::Drift`,
# `Player::Sway`) because the detour engine allows one hook per method, and
# because a typed hook proved on a method the JSON hook was never on is a
# stronger statement than one that shares a target.

var typedPrefixArmed = false
var typedPostfixArmed = false
var typedSuppress = true

## What the typed prefix saw. Held in globals for the reason every other hook in
## this file does: a `{.cdecl.}` callback cannot carry a closure.
var driftSelf = 0'u64
var driftA = -1.0
var driftB = -1.0
var driftAOk = false
var driftBOk = false
var driftKind0 = akNone
var driftKind1 = akNone
var driftArgc = -1
var driftFires = 0
var driftStatic = true
var driftPostfixFlag = true

## The frame, kept deliberately past the handler. Reading it afterwards is the
## mistake this path exists to refuse, so the test makes it.
var keptFrame = PatchFrame(p: cast[pointer](0))
var keptWhy = ""
var keptLiveInside = false

var swayFires = 0
var swaySeen = -1.0
var swaySeenOk = false
var swayIntRefused = false
var swaySetOk = false

## The allocation proof. `allocatedBytes()` is cumulative -- a free does not
## lower it -- so an unchanged number across a loop means the loop allocated
## nothing at all rather than nothing net.
var allocProbe = false
var typedAllocDelta = -1'i64
var jsonAllocDelta = -1'i64
var typedHostPayload = -1'i64
var typedHostHandles = -1'i64
var jsonHostPayload = -1'i64
var jsonHostHandles = -1'i64
var typedFireDelta = -1'i64
var typedPostNs = 0'i64
var swayBareNs = 0'i64

proc onDriftTyped(f: PatchFrame): TypedResult =
  ## A typed prefix. Everything it reads is a register the thunk already saved:
  ## no payload is built, no GC handle is registered, and nothing is parsed.
  inc driftFires
  keptFrame = f
  keptLiveInside = f.frameLive()
  driftArgc = f.argCount()
  driftStatic = f.frameStatic()
  driftPostfixFlag = f.framePostfix()
  driftKind0 = f.kindOf(0)
  driftKind1 = f.kindOf(1)
  driftSelf = f.selfPointer()
  driftA = f.argFloat(0, driftAOk)
  driftB = f.argFloat(1, driftBOk)
  if not typedSuppress:
    return frameContinue()
  if not f.setResultVoid():
    # The declared return is not `void` after all, so this handler cannot
    # honestly suppress. Letting the original run is the only safe answer.
    return frameContinue()
  frameReplace()

proc onSwayTyped(f: PatchFrame): TypedResult =
  ## A typed postfix that scales the original's result. `Sway` multiplies by
  ## 1.5 and this doubles, so 4.0 must come back as 12.0 -- a number that needs
  ## the original to have run *and* its result to have reached here in XMM0.
  inc swayFires
  var ok = false
  let got = f.resultFloat(ok)
  swaySeen = got
  swaySeenOk = ok
  # And the negative half: reading a float return as an integer must be
  # refused rather than reinterpreted, because reinterpreting answers a number.
  var iok = true
  discard f.resultInt(iok)
  swayIntRefused = not iok
  if not ok:
    return frameContinue()
  swaySetOk = f.setResultFloat(got * 2.0)
  if not swaySetOk:
    return frameContinue()
  frameReplace()

proc numberIn(text: string; key: string): int64 =
  ## One integer member out of a flat JSON object, for reading the host's patch
  ## counters. Deliberately tiny: the payload is the host's own and has no
  ## nesting, and pulling in a parser to read six integers would be the sort of
  ## thing this example exists to argue against.
  result = -1'i64
  let needle = "\"" & key & "\":"
  let at1 = find(text, needle)
  if at1 < 0: return
  var i = at1 + needle.len
  var neg = false
  if i < text.len and text[i] == '-':
    neg = true
    inc i
  var v = 0'i64
  var any = false
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    v = v * 10'i64 + int64(ord(text[i]) - ord('0'))
    any = true
    inc i
  if not any: return
  result = (if neg: -v else: v)

proc hostPatchStat(key: string): int64 =
  ## A counter out of `call("aowlspt.host::patch_stats")`. -1 when the host does
  ## not answer, which is a different thing from zero and must read differently.
  var text = ""
  if call("aowlspt.host::patch_stats", "[]", text) != Ok:
    return -1'i64
  result = numberIn(text, key)

proc onLoad(): Status =
  success "highlevel loaded on " & hostName()
  if side() != sideClient:
    info "this mod only does anything on the client"
  Ok

proc onWorldReady() =
  ## Runs once, the first tick the game world exists.
  success "the world is up"

  let version = Application.get("unityVersion")
  if version.ok:
    info "Unity " & version.asText()
  else:
    warn "no Unity version: " & version.error

  # Arguments are ordinary values. No JSON, no quoting, no argument array.
  #
  # Every one of these checks the value rather than `ok`. A call that reached
  # the wrong register file does not fail -- it answers a plausible number, and
  # `ok` stays true the whole time. The four here are one per register class the
  # host has to get right: two integers, a `System.Single` in XMM, a
  # `System.String` that crosses a managed allocation each way, and a
  # `System.Boolean` that is one byte in AL with the rest of RAX undefined.
  let sum = Player.invoke("Add", 17, 25)
  if sum.ok and sum.asInt() == 42:
    success "Add(17, 25) = " & $sum.asInt()
  else:
    warn "Add(17, 25) answered " & sum.raw & " (" & sum.error & "), expected 42"

  let scaled = Player.invoke("Scale", 2.5)
  if scaled.ok and scaled.asFloat() == 5.0:
    success "Scale(2.5) = " & $scaled.asFloat()
  else:
    warn "Scale(2.5) answered " & scaled.raw & " (" & scaled.error &
         "), expected 5.0"

  let greeting = Player.invoke("Greet", "operator")
  if greeting.ok and greeting.asText() == "hello operator":
    success "Greet -> " & greeting.asText()
  else:
    warn "Greet answered " & greeting.raw & " (" & greeting.error &
         "), expected \"hello operator\""

  # The mock negates what it is given, so `true` must come back `false`. "It
  # returned true" is what a host reading the whole return register answers for
  # very nearly any bool-returning method, so the *false* is the assertion.
  let flag = Player.invoke("SetFlag", true)
  if flag.ok and flag.raw == "false":
    success "SetFlag(true) = " & $flag.asBool()
  else:
    warn "SetFlag(true) answered " & flag.raw & " (" & flag.error &
         "), expected false"

  # A wrong argument *type* is refused, and the reason still arrives -- the
  # high level API hides the plumbing, not the errors.
  #
  # Both arguments are passed, and that is the point of the line: one argument
  # to a two-argument method is refused by *arity*, which is a different
  # refusal and one that would go on passing on a host that had stopped
  # checking types entirely. `v("seventeen")` puts a string where the method
  # declares `System.Int32`.
  let bad = Player.invoke("Add", v("seventeen"), v(25))
  if bad.failed:
    success "a mistyped argument was refused: " & bad.error
  else:
    warn "a mistyped argument was accepted and answered " & bad.raw &
         ", which it should not be"

  # Live objects. Everything above this line is static -- the half of the game
  # that needs no `this`. What a mod actually wants is on the other half: this
  # world, this player, this player's health.
  let instanceCall = GameWorld.get("Instance")
  let gameWorld = instanceCall.asObject()
  if gameWorld.ok:
    success "the world instance is a " & gameWorld.typeName
    let player = gameWorld.child("MainPlayer")
    if player.ok:
      success "and its main player is a " & player.typeName
      # Every one of the three calls is checked for `ok` as well as for its
      # value, and that is not belt and braces. `asFloat()` on a *failed* call
      # answers its default of 0.0, so a run where none of these three reached
      # the game at all leaves `before`, `after` and `again` all zero -- and
      # `again == after` is then true, and the success line below prints, and
      # the gate assertion that greps for it passes on a run that established
      # nothing. Compare the numbers only once they are known to be numbers.
      let beforeCall = player.get("Health")
      let damageCall = player.invoke("Damage", 25.0)
      let before = beforeCall.asFloat()
      let after = damageCall.asFloat()
      let healthRead = beforeCall.ok and damageCall.ok
      if healthRead and after == before - 25.0:
        success "Damage(25) took this player from " & $before & " to " & $after
      else:
        warn "health went from " & $before & " to " & $after &
             ", which is not what damaging this player should do (" &
             beforeCall.error & damageCall.error & ")"
      # A second read proves it stuck on the object rather than on a copy.
      let againCall = player.get("Health")
      let again = againCall.asFloat()
      if healthRead and againCall.ok and again == after and after != before:
        success "and the change is on the object, not a copy"
      else:
        warn "the object did not keep the change: " & againCall.raw &
             " (" & againCall.error & ")"
      # A field, which no property getter reaches. `Level` is a plain field on
      # the mock exactly as half the game's interesting state is on the real
      # thing.
      # The strong version of the check: the field and the property getter must
      # agree. They read the same storage by two different mechanisms, so a
      # wrong field offset shows up here rather than as a number that merely
      # looks plausible.
      #
      # `againCall.ok` is part of the condition for the reason above: two
      # readers agreeing on 0.0 because neither of them read anything is not
      # agreement, and it is the shape this check would otherwise take on a
      # host where reflection had stopped working altogether.
      let byField = player.field("Health")
      if byField.ok and againCall.ok and byField.asFloat() == again:
        success "the Health field agrees with get_Health: " & $byField.asFloat()
      else:
        warn "the Health field says " & byField.raw & " but get_Health said " &
             againCall.raw

      let lvl = player.field("Level")
      if lvl.ok:
        success "the Level field reads " & $lvl.asInt()
        if player.setField("Level", v(7)).ok and
           player.field("Level").asInt() == 7:
          success "and writing it stuck"
        else:
          warn "writing the Level field did not stick"
      else:
        warn "could not read the Level field: " & lvl.error

      player.release()
    else:
      warn "no main player: " & gameWorld.get("MainPlayer").error
    gameWorld.release()
  else:
    warn "no world instance: " & (if instanceCall.ok: "returned " &
                                  instanceCall.raw else: instanceCall.error)

  # A hook that reads the arguments. `Hurt(amount, kind)` is a compiled
  # instance method in the stand-in, with the signature a real one has, so this
  # exercises the whole path: this in RCX, the float in XMM1, the int in R8.
  if not argHooked:
    argHooked = true
    if hookArgs("EFT.Player::Hurt",
                proc (target, args: string): HookResult =
                  lastArgs = args
                  inc argHookFires
                  carryOn()) == Ok:
      success "hooked EFT.Player::Hurt with arguments"
      let player2 = GameWorld.instanceOf().child("MainPlayer")
      if player2.ok:
        discard player2.invoke("Hurt", v(12.5), v(2))
        # The payload is an object now, not a bare array: `this` is delivered
        # alongside the declared arguments, and a static method's is null. Both
        # halves are checked -- the arguments alone would pass against a host
        # that dropped the instance, which is exactly what it used to do.
        if find(lastArgs, "\"args\":[12.5,2]") >= 0:
          success "the hook saw its arguments: " & lastArgs
        else:
          warn "the hook saw " & lastArgs & ", expected args [12.5,2]"
        if find(lastArgs, "\"this\":{\"handle\"") >= 0:
          success "and it was told which object the call was on"
        else:
          warn "the hook was not given `this`: " & lastArgs
        player2.release()
    else:
      warn "could not hook with arguments: " & lastError()

  # An **enum** argument, and an **instance** method that is not the one above.
  #
  # Both of these were live bugs rather than hypotheticals. An enum arrives in a
  # register as a plain integer with no object anywhere in the call, and the
  # host used to classify it by "is it a value type?" answered from the wrong
  # side -- so it handed `il2cpp_gchandle_new` the number 2 and the game got a
  # handle to whatever lives at address 2. And a patched instance method used to
  # drop `this` entirely, which the `Hurt` check above now also covers; keeping
  # a second instance method here means the two cannot both be broken by one
  # change that happens to suit `Hurt`.
  if not enumHooked:
    enumHooked = true
    var Context = gameType("EFT.MovementContext")
    let ctx = Context.instanceOf()
    if not ctx.ok:
      info "no EFT.MovementContext on this build; skipping the enum check"
    else:
      if hookArgs("EFT.MovementContext::ApplyCondition",
                  proc (target, args: string): HookResult =
                    enumArgs = args
                    carryOn()) == Ok and
         hookArgs("EFT.MovementContext::SetTilt", onSetTilt) == Ok:
        let ac = ctx.invoke("ApplyCondition", v(2))
        if not ac.ok:
          warn "ApplyCondition refused: " & ac.error
        discard ctx.invoke("SetTilt", v(0.5))
        # Twice, and that is the check rather than a repetition. The mock's
        # SetTilt doubles what it is given, so the first call leaves Tilt at
        # 1.0 -- and the second firing's handler reads 1.0 *through the raw
        # address*, before the original has run again. A null address reads
        # 0.0 and the initial value is 0.0, so only a real address can produce
        # the number the previous call left.
        discard ctx.invoke("SetTilt", v(0.25))
        # The enum must arrive as the number it is. Anything else -- a handle,
        # an object, a null -- means it was taken for a reference.
        if find(enumArgs, "\"args\":[2]") >= 0:
          success "an enum argument arrived as a plain 2: " & enumArgs
        else:
          warn "the enum argument came back as " & enumArgs & ", expected [2]"
        if find(enumArgs, "\"this\":{\"handle\"") >= 0 and
           find(tiltArgs, "\"this\":{\"handle\"") >= 0:
          success "and both instance hooks were told their object"
        else:
          warn "an instance hook lost `this`: " & enumArgs & " / " & tiltArgs
        # An enum on the **fast path**, which is a different question from the
        # boxed one below. `bindMethod` infers every register class from the
        # runtime's own metadata, and it used to refuse an enum outright: the
        # C API does not name an enum's underlying type, and guessing `Int32`
        # is wrong for the `long` enums that exist. The width is not a guess
        # though -- it is the instance size minus the object header, and the
        # header is measured rather than assumed. So this binds now, and a mod
        # no longer has to assert the shape with `bindMethodAs` to call one.
        if openRuntime():
          let bEnum = bindMethod(rt, "EFT.MovementContext", "ApplyCondition", 1)
          if bEnum.ok:
            success "an enum parameter binds on the fast path: " & bEnum.why
          else:
            warn "the fast path refused an enum parameter: " & bEnum.why

        # A typed postfix reporting an **integer** result, which had nothing
        # to stand on until the stand-in grew an instance method that both
        # returns one and can be detoured. `resultInt` reads RAX where
        # `resultFloat` reads XMM0, and a host that confused the two would
        # answer a plausible number rather than fail.
        if typedPatchesReady():
          if hookReturnTyped("EFT.MovementContext::Ready",
                             proc (f: PatchFrame): TypedResult =
                               var got = false
                               let v = resultInt(f, got)
                               if got: readySeen = int(v)
                               frameContinue()) == Ok:
            let r = ctx.invoke("Ready")
            if readySeen >= 0 and r.ok and readySeen == (if r.asBool(): 1 else: 0):
              success "a typed postfix read an integer result out of RAX: " &
                      $readySeen
            else:
              warn "the typed postfix saw " & $readySeen & " and the call " &
                   "returned " & r.raw
          else:
            warn "could not install a typed postfix on Ready: " & lastError()

        # A **reference** field, written through the collector's write
        # barrier. `writePtr` used to be the plain store, documented as unsafe
        # and left to the caller; storing a young object into an old one's
        # field that way gets it collected while still referenced, and the
        # crash lands at the next collection with nothing on the stack to
        # connect it to the write.
        #
        # `barrierReady` is half the assertion: it says the runtime's entry was
        # found at bind time, so this store went through the collector rather
        # than around it. The harness checks the runtime's own counter for the
        # other half, because a mod cannot see the collector.
        #
        # The *store* is asserted separately, and it has to be. Writing back the
        # pointer the field already held reads correctly whether or not the
        # store happened at all -- so this clears the field, checks it really is
        # clear, puts the pointer back, and checks it is back. Two writes, two
        # different correct answers, neither reachable by a `writePtr` that did
        # nothing.
        #
        # (Restoring a pointer the object already reachably held is the one case
        # `writePtrRaw` is for -- the unbarriered store. Both go through
        # `writePtr` here because the barrier is what is being proved.)
        let fPlayer = bindField(rt, "EFT.MovementContext", "_player")
        let ctxAddr = cast[Il2CppPtr](tiltPtrSeen)
        if not fPlayer.ok:
          warn "no _player field to write: " & fPlayer.why
        elif not fPlayer.barrierReady():
          warn "the runtime exports no write barrier, so writePtr stored " &
               "directly; a fresh allocation put here could be collected"
        elif tiltPtrSeen == 0'u64:
          warn "no MovementContext address to write a field on"
        else:
          let had = readPtr(fPlayer, ctxAddr)
          writePtr(fPlayer, ctxAddr, nullPtr())
          let cleared = readPtr(fPlayer, ctxAddr)
          writePtr(fPlayer, ctxAddr, had)
          let restored = readPtr(fPlayer, ctxAddr)
          if had == nullPtr():
            warn "the _player field was already null, so writing it back " &
                 "would prove nothing"
          elif cleared != nullPtr():
            warn "clearing the reference field did not land"
          elif restored != had:
            warn "the barriered store did not land"
          else:
            success "a reference field was written through the write barrier"

        # And an enum coming *back*. This used to answer a handle to a boxed
        # integer, so `asInt()` said 0 with `ok` true -- and leaked the handle.
        let cond = ctx.get("Condition")
        if cond.ok and cond.asInt() == 2:
          success "an enum return read back as 2"
        else:
          warn "the enum return came back as " & cond.raw & ", expected 2"
        if find(tiltArgs, "\"args\":[0.25]") >= 0:
          success "a float argument to an instance method read 0.25"
        else:
          warn "SetTilt saw " & tiltArgs & ", expected [0.25]"

        # ---- `this` as an address, for the fast path -------------------
        #
        # Three things are asserted and each one fails differently, which is
        # why they are three: that an address came back at all, that reading
        # through it produced the value the previous call left (a null address
        # or a wrong one reads 0.0, which is also the field's initial value --
        # hence two calls), and that the boxed read of the same field now
        # disagrees, because the second call has since moved it. Two readers,
        # two mechanisms, two different correct answers.
        if not livePointersReady():
          warn "this host does not report handle_pointer; the ABI revision " &
               "is " & $hostApiSize() & " bytes of HostApi"
        elif tiltPtrSeen == 0'u64:
          warn "`this` produced no address inside the hook: " & lastError()
        elif tiltViaPtr != 1.0:
          warn "reading Tilt through the raw `this` gave " & $tiltViaPtr &
               ", expected 1.0 (what the previous SetTilt left)"
        else:
          success "`this` came back as an address and reading Tilt off it " &
                  "gave 1.0, the value the previous call left"
          let boxed = ctx.field("Tilt")
          if boxed.ok and boxed.asFloat() == 0.5:
            success "and the boxed read of the same field now says 0.5, " &
                    "which the second call left -- two mechanisms, two " &
                    "correct answers"
          else:
            warn "the boxed read of Tilt says " & boxed.raw & ", expected 0.5"

        # The lifetime, which is the part a mod can get wrong silently. The
        # handle was live inside the handler and is not now; asking again must
        # be a refusal rather than the address it used to have.
        if tiltHandleSeen == 0'u64:
          warn "the hook payload carried no `this` handle"
        else:
          var stale = 0'u64
          let st = pointerOf(tiltHandleSeen, stale)
          if st == Ok:
            warn "the host still gave an address for a patch argument whose " &
                 "handler has returned: " & $int(stale)
          else:
            success "and asking for that address after the handler returned " &
                    "was refused: " & lastError()
      else:
        warn "could not hook EFT.MovementContext: " & lastError()

      # ---- alive(), which used to lie -------------------------------
      #
      # `alive()` is a `GetType` call: an object the collector has taken
      # cannot answer one, so a call that comes back `Ok` is the object
      # saying it is still there. Against the stand-in runtime it answered
      # **false about this very object**, because nothing in that universe
      # implemented `GetType` -- the mock's shape arrived at the mod as a
      # statement about the object, and "dead" is the one answer a liveness
      # predicate must never give by accident, since a mod acts on it.
      #
      # Both directions, and they have to be both: a predicate that always
      # answers true is exactly as useless and reads exactly as well here.
      # The handle is live for the first call and released for the second.
      let liveSays = ctx.alive()
      # Taken here, not after the second call: `lastError` is the last one, and
      # reporting the *released* handle's refusal as the reason the live object
      # answered false sent one reader looking at the handle table.
      let liveWhy = lastError()
      ctx.release()
      let deadSays = ctx.alive()
      if liveSays and not deadSays:
        success "alive() said true for a live object and false for a " &
                "released one"
      elif not liveSays:
        warn "alive() said false about an object that was plainly there; " &
             "either the runtime cannot answer GetType or the call path " &
             "is broken: " & liveWhy
      else:
        warn "alive() said true for a handle that had been released, so it " &
             "is answering something other than whether the object is there"

  # ---- what the address bridge costs ---------------------------------
  #
  # The whole argument for `pointerOf` is a number, so the number is taken here
  # rather than asserted elsewhere. Both loops ask the same question -- "what is
  # on this object" -- one through a handle and `call`, one through the address.
  if openRuntime():
    let world2 = GameWorld.instanceOf()
    let player3 = world2.child("MainPlayer")
    if player3.ok:
      var sink = 0'u64
      for i in 0 ..< 200:
        discard pointerOf(player3.handle, sink)
      let p0 = perfCounter()
      for i in 0 ..< 20000:
        discard pointerOf(player3.handle, sink)
      ptrNs = nanosBetween(p0, perfCounter()) div 20000'i64

      for i in 0 ..< 50:
        discard player3.get("Health")
      let b0 = perfCounter()
      for i in 0 ..< 2000:
        discard player3.get("Health")
      boxedNs = nanosBetween(b0, perfCounter()) div 2000'i64
      success "an address out of a handle costs " & $int(ptrNs) &
              " ns; the boxed read it replaces costs " & $int(boxedNs) & " ns"
      player3.release()
    world2.release()

  # ---- what a postfix costs ------------------------------------------
  #
  # Timed on the same method twice, side by side and before the hook exists, so
  # the difference is the postfix and not the harness. A bound call goes to the
  # compiled function directly, which is exactly where the detour sits, so this
  # measures the thunk, the payload and the handler and nothing else.
  if openRuntime() and bareSensNs == 0'i64:
    var bSens = bindMethod(rt, "EFT.Player", "Sensitivity", 1)
    if bSens.ok:
      var sa = argsF(4.0)
      for i in 0 ..< 1000:
        discard callFloat(bSens, nullPtr(), sa)
      let t0 = perfCounter()
      for i in 0 ..< 20000:
        discard callFloat(bSens, nullPtr(), sa)
      bareSensNs = nanosBetween(t0, perfCounter()) div 20000'i64
    else:
      warn "could not bind Sensitivity for timing: " & bSens.why

  # `Sway` is the typed postfix's target and it has to be timed *before* the
  # hook lands: a detour rewrites the first fourteen bytes of the function, so
  # an "unpatched" figure taken after removing one would be measuring a restored
  # function rather than an untouched one -- and taken while the hook is still on
  # some other method it would be measuring that method instead. This used to
  # read `Ping`, which by this point already carries the watching postfix, and
  # reported 443 ns as the cost of an unpatched call.
  if openRuntime() and swayBareNs == 0'i64:
    var bSwayPre = bindMethod(rt, "EFT.Player", "Sway", 1)
    if bSwayPre.ok:
      var wa = argsF(4.0)
      for i in 0 ..< 1000:
        discard callFloat(bSwayPre, nullPtr(), wa)
      let w0 = perfCounter()
      for i in 0 ..< 20000:
        discard callFloat(bSwayPre, nullPtr(), wa)
      swayBareNs = nanosBetween(w0, perfCounter()) div 20000'i64
    else:
      warn "could not bind Sway for the unpatched baseline: " & bSwayPre.why

  if openRuntime() and pingBareNs == 0'i64:
    var bPing = bindMethod(rt, "EFT.Player", "Ping", 1)
    if bPing.ok:
      var pa = argsF(1.0)
      for i in 0 ..< 1000:
        discard callFloat(bPing, nullPtr(), pa)
      let pt0 = perfCounter()
      for i in 0 ..< 20000:
        discard callFloat(bPing, nullPtr(), pa)
      pingBareNs = nanosBetween(pt0, perfCounter()) div 20000'i64
      if hookReturn("EFT.Player::Ping", onPing, withArgs = false) == Ok:
        for i in 0 ..< 1000:
          discard callFloat(bPing, nullPtr(), pa)
        let pt1 = perfCounter()
        for i in 0 ..< 20000:
          discard callFloat(bPing, nullPtr(), pa)
        pingPostNs = nanosBetween(pt1, perfCounter()) div 20000'i64
        if pingFires > 20000:
          success "a postfix that only watches costs " & $int(pingPostNs) &
                  " ns a call against " & $int(pingBareNs) &
                  " ns unpatched, and fired " & $pingFires & " times"
        else:
          warn "the watching postfix fired only " & $pingFires & " times"
      else:
        warn "could not install a watching postfix: " & lastError()

  # ---- postfix: seeing, and changing, a return value -----------------
  #
  # The one thing a prefix cannot express. `stopWith` can replace a result, but
  # only by reimplementing the method; anything that *scales* what the original
  # produced needs to have seen it.
  #
  # `Sensitivity` multiplies by 1.5 and the handler doubles what it is given, so
  # 4.0 must come back as 12.0. That single number is the whole assertion, and
  # it is chosen because each way the feature could be broken produces a
  # different one: a prefix would give the handler's own answer, a postfix that
  # never saw the result would double a zero, and reading the return out of RAX
  # instead of XMM0 would give a very large number rather than a plausible one.
  if not sensHooked:
    sensHooked = true
    if hookReturn("EFT.Player::Sensitivity", onSensitivity) == Ok:
      success "installed a postfix on EFT.Player::Sensitivity"
      let sens = Player.invoke("Sensitivity", 4.0)
      if sens.ok and sens.asFloat() == 12.0:
        success "the postfix scaled the original's result: 4.0 -> 6.0 -> 12.0"
      else:
        warn "the postfix returned " & sens.raw & ", expected 12.0"
      # And that the handler was told both halves rather than guessing one.
      if find(sensPayload, "\"result\":6.0") >= 0:
        success "and it was handed the original's own result: " & sensPayload
      else:
        warn "the postfix payload was " & sensPayload &
             ", expected a result of 6.0"
      if find(sensPayload, "\"args\":[4.0]") >= 0:
        success "with the arguments the method was entered with"
      else:
        warn "the postfix payload carried no arguments: " & sensPayload

      # The same loop as above, now with the hook in place. The difference is
      # what a postfix costs per call: the thunk's extra call and return, the
      # payload, the trip into the mod, and parsing the replacement back.
      if bareSensNs > 0'i64:
        var bSens2 = bindMethod(rt, "EFT.Player", "Sensitivity", 1)
        if bSens2.ok:
          var sa2 = argsF(4.0)
          for i in 0 ..< 1000:
            discard callFloat(bSens2, nullPtr(), sa2)
          let t1 = perfCounter()
          for i in 0 ..< 20000:
            discard callFloat(bSens2, nullPtr(), sa2)
          postSensNs = nanosBetween(t1, perfCounter()) div 20000'i64
          success "a bound call costs " & $int(bareSensNs) &
                  " ns unpatched and " & $int(postSensNs) &
                  " ns with a postfix that reads the arguments and replaces " &
                  "the result"
    else:
      warn "could not install a postfix: " & lastError()

  # An **instance** postfix, and a shape the host must refuse. Both here because
  # they are the two halves of "which methods can carry one": `Aim` has `this`
  # plus one float plus IL2CPP's MethodInfo* -- three slots -- and `Wide` has
  # four declared arguments plus MethodInfo*, which is five, and the fifth
  # arrives on the stack where a *called* original cannot find it.
  if not aimHooked:
    aimHooked = true
    var Context2 = gameType("EFT.MovementContext")
    let ctx2 = Context2.instanceOf()
    if ctx2.ok:
      if hookReturn("EFT.MovementContext::Aim", onAim) == Ok:
        # Tilt is 0.5 by now, so Aim(0.25) returns 0.75 -- a value that depends
        # on the instance, so a postfix told the wrong `this` cannot produce it.
        let aim = ctx2.invoke("Aim", v(0.25))
        # Compared as the host printed it rather than through `asFloat`: 0.75
        # does not survive a decimal-digit parse into a binary double intact
        # (0.7 + 0.05 is 0.7500000000000001), and an equality test that fails on
        # rounding would read as a broken postfix. The digits are the assertion.
        if aim.ok and aim.raw == "0.75":
          success "an instance postfix left its result alone: 0.75"
        else:
          warn "the instance postfix returned " & aim.raw & ", expected 0.75"
        if find(aimPayload, "\"result\":0.75") >= 0 and
           find(aimPayload, "\"this\":{\"handle\"") >= 0:
          success "and was given both `this` and the result: " & aimPayload
        else:
          warn "the instance postfix payload was " & aimPayload
        if aimThisPtr != 0'u64:
          success "with `this` reachable as an address after the original ran"
        else:
          warn "no address for `this` in a postfix: " & lastError()
      else:
        warn "could not install an instance postfix: " & lastError()
      ctx2.release()

    # The refusal. It must be a refusal *and* say why, because a postfix
    # installed here would read its fifth argument out of the thunk's frame --
    # a plausible number rather than a crash, which is the failure mode this
    # whole path is built to avoid.
    if hookReturn("EFT.Player::Wide", onAim) == Ok:
      warn "a postfix on a method with stack arguments was accepted; it " &
           "should have been refused"
    else:
      wideRefusal = lastError()
      if find(wideRefusal, "register slots") >= 0:
        success "a postfix on a 5-slot method was refused, and said why: " &
                wideRefusal
      else:
        warn "the refusal did not name the reason: " & wideRefusal
      # A prefix on the same method still works: the refusal is about the
      # postfix path, not about the method.
      if hookArgs("EFT.Player::Wide",
                  proc (target, args: string): HookResult = carryOn()) == Ok:
        success "and a prefix on that same method is unaffected"
      else:
        warn "a prefix on EFT.Player::Wide was refused too: " & lastError()

  # And suppression: a static method, patched to answer without running.
  if not skipHooked:
    skipHooked = true
    if hookArgs("EFT.Player::Boost",
                proc (target, args: string): HookResult =
                  stopWith("99.0")) == Ok:
      let scaled2 = Player.invoke("Boost", 2.5)
      if scaled2.ok and scaled2.asFloat() == 99.0:
        success "the patch suppressed the original and returned 99.0"
      else:
        warn "suppression returned " & scaled2.raw & ", expected 99.0"
    else:
      warn "could not install the suppressing patch: " & lastError()

  # ---- typed hooks: the register frame, not a payload ------------------
  #
  # The whole argument for ABI revision 4 is a pair of numbers and a pair of
  # counters, so both are taken here rather than asserted in a document.
  if not typedPatchesReady():
    warn "this host does not report patch_typed; HostApi is " &
         $hostApiSize() & " bytes, and revision 4 is " & $expectedApiSize()
  else:
    if not typedPrefixArmed:
      typedPrefixArmed = true
      var Context3 = gameType("EFT.MovementContext")
      let ctx3 = Context3.instanceOf()
      if not ctx3.ok:
        info "no EFT.MovementContext on this build; skipping the typed prefix"
      else:
        if hookTyped("EFT.MovementContext::Drift", onDriftTyped) == Ok:
          success "installed a typed prefix on EFT.MovementContext::Drift"
          # Tilt is 0.5 by now, left there by the second SetTilt. Drift would
          # set it to a*10+b, so a suppressed Drift leaves 0.5 and a Drift that
          # ran leaves 7.75 -- two firings, two different correct answers, and
          # neither is reachable by a hook that did nothing.
          typedSuppress = true
          discard ctx3.invoke("Drift", v(0.75), v(0.25))
          let afterSkip = ctx3.field("Tilt")
          if driftFires == 1:
            success "the typed prefix fired"
          else:
            warn "the typed prefix fired " & $driftFires & " times, expected 1"
          if afterSkip.ok and afterSkip.asFloat() == 0.5:
            success "and it suppressed the original: Tilt is still 0.5"
          else:
            warn "the typed prefix did not suppress; Tilt is " & afterSkip.raw &
                 ", expected 0.5"
          # The arguments, by index and by declared kind. Two floats at register
          # positions 1 and 2 -- position 0 is `this` -- so a frame that counted
          # the floating-point file separately would report the first argument
          # twice and still answer numbers.
          if driftAOk and driftBOk and driftA == 0.75 and driftB == 0.25:
            success "it read both float arguments by index: 0.75 and 0.25"
          else:
            warn "the typed prefix read " & $driftA & " / " & $driftB &
                 " (ok " & $driftAOk & "/" & $driftBOk & "), expected 0.75/0.25"
          if driftKind0 == akFloat and driftKind1 == akFloat and driftArgc == 2:
            success "with both declared kinds reported as akFloat"
          else:
            warn "the declared kinds came back as " & $ord(driftKind0) & "/" &
                 $ord(driftKind1) & " over " & $driftArgc & " argument(s)"
          if not driftStatic and not driftPostfixFlag:
            success "and the frame knew it was an instance prefix"
          else:
            warn "the frame's flags are wrong: static=" & $driftStatic &
                 " postfix=" & $driftPostfixFlag
          # `this`, as an address, with no handle anywhere in the call. The
          # comparison is against the address the *JSON* hook obtained for the
          # same object through `thisPointer` -- a handle, a GC handle and a
          # `handle_pointer` round trip -- so this asserts the two paths name
          # the same object rather than merely that a number came back.
          if driftSelf != 0'u64 and driftSelf == tiltPtrSeen:
            success "and `this` came straight out of RCX, the same address " &
                    "the JSON hook needed a handle to reach"
          else:
            warn "the typed prefix saw `this` as " & $int(driftSelf) &
                 ", and the JSON hook saw " & $int(tiltPtrSeen)

          # The lifetime, which is the part a mod gets wrong silently. The frame
          # was live inside the handler; asking it anything now must be a
          # refusal that names the mistake, not the previous firing's registers.
          if keptLiveInside and not keptFrame.frameLive():
            var stale = false
            let staleA = keptFrame.argFloat(0, stale)
            keptWhy = frameWhyText()
            if stale or staleA != 0.0:
              warn "a stored frame still answered after its handler returned: " &
                   $staleA
            elif find(keptWhy, "must not be stored") >= 0:
              success "and reading that frame after the handler returned was " &
                      "refused: " & keptWhy
            else:
              warn "the refusal did not name the reason: " & keptWhy
          else:
            warn "the frame's liveness is wrong: live inside " &
                 $keptLiveInside & ", live after " & $keptFrame.frameLive()

          # And the other half of the suppression: with the handler carrying on,
          # the original runs and leaves the number only it can produce.
          typedSuppress = false
          discard ctx3.invoke("Drift", v(0.75), v(0.25))
          let afterRun = ctx3.field("Tilt")
          if afterRun.ok and afterRun.asFloat() == 7.75:
            success "and letting it carry on ran the original: Tilt is 7.75"
          else:
            warn "the unsuppressed Drift left Tilt at " & afterRun.raw &
                 ", expected 7.75"
          typedSuppress = true
        else:
          warn "could not install a typed prefix: " & lastError()
        ctx3.release()

    if not typedPostfixArmed:
      typedPostfixArmed = true
      if hookReturnTyped("EFT.Player::Sway", onSwayTyped) == Ok:
        success "installed a typed postfix on EFT.Player::Sway"
        let sway = Player.invoke("Sway", 4.0)
        if sway.ok and sway.asFloat() == 12.0:
          success "the typed postfix scaled the original: 4.0 -> 6.0 -> 12.0"
        else:
          warn "the typed postfix returned " & sway.raw & ", expected 12.0"
        if swaySeenOk and swaySeen == 6.0:
          success "and it was handed the original's own result out of XMM0: 6.0"
        else:
          warn "the typed postfix read the result as " & $swaySeen &
               " (ok " & $swaySeenOk & "), expected 6.0"
        if swayIntRefused:
          success "while reading that float return as an integer was refused"
        else:
          warn "reading a float return as an integer was answered rather " &
               "than refused, which returns a number instead of an error"
      else:
        warn "could not install a typed postfix: " & lastError()

  # ---- what a typed hook costs, and what it allocates -------------------
  #
  # Two claims, two measurements. The price is a timing loop against the same
  # method unpatched. "Allocation-free" is three counters that must not move:
  # this mod's own allocator, and the host's tally of payload bytes and GC
  # handles -- and the same loop through a JSON hook must move all three, or
  # the counters are not measuring anything.
  if openRuntime() and typedAllocDelta < 0'i64 and typedPatchesReady() and
     swayFires > 0:
    allocProbe = allocProbeOk()
    if not allocProbe:
      warn "the allocation counter is not reading the allocator, so the " &
           "allocation-free claim below cannot be checked"
    var bSway = bindMethod(rt, "EFT.Player", "Sway", 1)
    # The JSON control is `Sensitivity` -- the *full* postfix, with arguments
    # and a replacement -- and not `Ping`, which is the watching one.
    #
    # `Ping`'s payload is `{"result":5.0}`, fourteen bytes, and a nimony string
    # that short lives inside the string object with no heap block at all. So
    # the watching JSON hook really does allocate nothing on this side, and
    # using it as the control made the counter report zero for both paths --
    # which proves nothing rather than proving the typed path is free. The
    # expensive form's payload is `{"this":null,"args":[4.0],"result":6.0}`,
    # and the replacement it hands back is another string, and both are real
    # blocks.
    var bSens3 = bindMethod(rt, "EFT.Player", "Sensitivity", 1)
    if not bSway.ok or not bSens3.ok:
      warn "could not bind Sway/Sensitivity for the typed measurement: " &
           (if bSway.ok: bSens3.why else: bSway.why)
    else:
      var sa3 = argsF(4.0)
      # The unpatched figure for this very method was taken further up, before
      # the hook was installed. The typed postfix, timed and counted in one loop.
      for i in 0 ..< 1000:
        discard callFloat(bSway, nullPtr(), sa3)
      # The host counters are read *outside* the allocation window, in both
      # directions. Reading one is a `call` through the ABI: the host allocates
      # a JSON buffer, this side copies it into a string and builds a key to
      # search for, and that is five allocations that have nothing to do with
      # the hook. Leaving them inside reported "20000 typed firings made 5
      # allocations", which is the measurement instrumenting itself.
      let hp0 = hostPatchStat("payloadBytes")
      let hh0 = hostPatchStat("handlesTaken")
      let hf0 = hostPatchStat("typedFires")
      let a0 = allocationCount()
      let t2 = perfCounter()
      for i in 0 ..< 20000:
        discard callFloat(bSway, nullPtr(), sa3)
      let t2end = perfCounter()
      let a1 = allocationCount()
      typedPostNs = nanosBetween(t2, t2end) div 20000'i64
      typedAllocDelta = a1 - a0
      typedHostPayload = hostPatchStat("payloadBytes") - hp0
      typedHostHandles = hostPatchStat("handlesTaken") - hh0
      typedFireDelta = hostPatchStat("typedFires") - hf0

      # And the same twenty thousand firings through the JSON postfix already
      # on `Ping`, which is the control. Without it, three zeroes would only
      # prove that the counters are constants.
      for i in 0 ..< 1000:
        discard callFloat(bSens3, nullPtr(), sa3)
      let jp0 = hostPatchStat("payloadBytes")
      let jh0 = hostPatchStat("handlesTaken")
      let b0 = allocationCount()
      for i in 0 ..< 20000:
        discard callFloat(bSens3, nullPtr(), sa3)
      let b1 = allocationCount()
      jsonAllocDelta = b1 - b0
      jsonHostPayload = hostPatchStat("payloadBytes") - jp0
      jsonHostHandles = hostPatchStat("handlesTaken") - jh0

      if typedFireDelta != 20000'i64:
        warn "the typed postfix fired " & $int(typedFireDelta) &
             " times over 20000 calls; the numbers below are not measuring it"
      else:
        success "a typed postfix that reads the result and replaces it costs " &
                $int(typedPostNs) & " ns a call against " & $int(swayBareNs) &
                " ns unpatched, and " & $int(postSensNs) &
                " ns for the JSON form of the same hook"

      if not allocProbe:
        info "allocation counts: typed " & $int(typedAllocDelta) &
             ", JSON " & $int(jsonAllocDelta) & " (unverified)"
      elif typedAllocDelta == 0'i64 and jsonAllocDelta > 0'i64:
        success "20000 typed firings made 0 allocations in this mod; the same " &
                "20000 through the JSON hook made " & $int(jsonAllocDelta)
      elif typedAllocDelta != 0'i64:
        warn "20000 typed firings made " & $int(typedAllocDelta) &
             " allocations in this mod, and the typed path is supposed to " &
             "make none"
      else:
        warn "the JSON hook made " & $int(jsonAllocDelta) &
             " allocations over 20000 firings, so the counter is not " &
             "measuring the path and the typed zero above proves nothing"

      if typedHostPayload == 0'i64 and typedHostHandles == 0'i64 and
         jsonHostPayload > 0'i64:
        success "and the host built 0 payload bytes and took 0 GC handles for " &
                "them, against " & $int(jsonHostPayload) &
                " bytes for the JSON hook's 20000"
      else:
        warn "host counters over 20000 firings: typed " &
             $int(typedHostPayload) & " payload bytes / " &
             $int(typedHostHandles) & " handles, JSON " &
             $int(jsonHostPayload) & " / " & $int(jsonHostHandles)

  if not hooked:
    hooked = true
    if hook("EFT.Player::Tick",
            proc (target: string) =
              inc hookFires) == Ok:
      success "hooked EFT.Player::Tick"
      for i in 0 ..< 3:
        discard Player.invoke("Tick")
      if hookFires == 3:
        success "the hook fired on all 3 calls"
      else:
        warn "the hook fired " & $hookFires & " times, expected 3"
    else:
      warn "could not hook: " & lastError()

proc checkStaticFields() =
  ## A **static** field, which `bindField` refused outright until now.
  ##
  ## The refusal was honest and it was also the end of the road: for a static
  ## field `il2cpp_field_get_offset` answers an offset into the class's static
  ## data block, and reaching that block needs
  ## `il2cpp_class_get_static_field_data`. That entry has been bound in
  ## `il2cpp.nim` the whole time and had one caller -- `mods/sway`, which walks
  ## the field list by hand to find a singleton. It is an API now.
  ##
  ## What makes this worth four checks rather than one is that the two kinds of
  ## field **share an offset space**. The stand-in has `Player::SpawnCount`
  ## (static, `Int32`) and `Player::Health` (instance, `Single`) both at offset
  ## 16, which is not a contrivance -- neither offset knows about the other. So
  ## a wrong binding here does not fail: it reads a float's bits as an integer,
  ## answers 1091567616, and sets `ok`.
  ##
  ## The four:
  ##
  ##   * `bindField` refuses the static one -- and refuses it because the
  ##     runtime says it is static, not because the offset looked odd; the
  ##     offset here is perfectly plausible inside an instance.
  ##   * `bindStaticField` refuses the instance one, which is the same mistake
  ##     in the other direction and would read the static block's bytes.
  ##   * the read agrees with the boxed path, which reaches the same storage
  ##     through `il2cpp_field_static_get_value`. Either alone can be
  ##     plausibly wrong; agreeing is what makes the address right rather than
  ##     lucky.
  ##   * the write lands where the *runtime* can see it. The harness reads
  ##     `mock_player_spawn_count()` afterwards, because a write that went into
  ##     some object at offset 16 would read back correctly through the same
  ##     wrong address.
  if staticsChecked or not openRuntime():
    return
  staticsChecked = true

  let instOfStatic = bindField(rt, "EFT.Player", "SpawnCount")
  fSpawn = bindStaticField(rt, "EFT.Player", "SpawnCount")
  let staticOfInstance = bindStaticField(rt, "EFT.Player", "Health")

  if instOfStatic.ok:
    warn "bindField bound the static field SpawnCount as an instance field " &
         "at offset " & $int(instOfStatic.offset) & "; an instance read of " &
         "that offset answers Health's bits"
  elif staticOfInstance.ok:
    warn "bindStaticField bound the instance field Health against the " &
         "static block"
  else:
    success "a static field and an instance field at the same offset each " &
            "refused the other's binding: " & instOfStatic.why

  if not fSpawn.ok:
    warn "no static field binding: " & fSpawn.why
    return

  # Two readers of one storage. The boxed one goes through the host, by name,
  # into `il2cpp_field_static_get_value`; this one is a load from the block.
  let boxed = Player.field("SpawnCount")
  let direct = fSpawn.readInt()
  if not boxed.ok:
    warn "the boxed path would not read the static field: " & boxed.error
  elif direct == 0'i64:
    # Zero is what an unbound read, an uninitialised block and a wrong address
    # all answer, so it cannot be allowed to pass as agreement.
    warn "the static field read 0, which is what reading nothing looks like"
  elif $direct != boxed.raw:
    warn "the static field read " & $direct & " directly and " & boxed.raw &
         " through the boxed path; one of the two is not reading the " &
         "class's static block"
  else:
    success "a static field read " & $direct & " and the boxed path agrees"

  # And a static `Single` off the same block, because a float read at the
  # wrong width is the failure this file exists to catch elsewhere.
  let fRate = bindStaticField(rt, "EFT.Player", "SpawnRate")
  if fRate.ok and fRate.readFloat() == 2.5:
    success "a static float read 2.5 off the same block"
  elif fRate.ok:
    warn "the static float read " & $fRate.readFloat() & ", expected 2.5"
  else:
    warn "no binding for the static float: " & fRate.why

  # The write. 4242 is arbitrary and the harness knows it: it asks the runtime
  # for the value afterwards, which is the only witness that can tell this
  # apart from a write into an object at the same offset.
  fSpawn.writeInt(4242'i64)
  let after = Player.field("SpawnCount")
  if after.ok and after.raw == "4242":
    success "a static field write landed: the boxed path now reads 4242"
  else:
    warn "the static write did not land; the boxed path reads " & after.raw

proc pumpMain(payload: string): string =
  ## One firing of `everyMain`, on the game's thread.
  ##
  ## Records the thread rather than assuming it. A chain that ran on the host's
  ## own thread would fire just as often and count just as well, and every
  ## Unity object a mod touched from it would be touched from the wrong thread.
  let t = currentThreadId()
  if mainFires == 0:
    mainThread = t
  elif t != mainThread:
    mainThreadWobbled = true
  inc mainFires
  # The high-water mark only. A baseline taken *here*, on the first firing,
  # was a race and read as a leak: the chain is queued onto the game's thread
  # and can fire while `onUpdate` is still arming the batch of timers below it,
  # so the first sample was sometimes taken before the batch existed and every
  # later one was legitimately higher. The baseline is taken on the host's own
  # thread, after the batch, where it is a fixed number.
  let n = scheduledSlots()
  if n > mainSlotsPeak:
    mainSlotsPeak = n
  result = ""

proc scheduleBatch(n: int) =
  ## `n` one-shot callbacks that do nothing. What matters is the slots they
  ## take, not what they do.
  for i in 0 ..< n:
    discard after(1, proc (payload: string): string = "")

proc onUpdate(elapsedMs: int64): Status =
  inc ticks
  if side() != sideClient:
    return Ok
  if world.ready():
    worldUp = true
    onWorldReady()
  if worldUp:
    checkStaticFields()

  # The scheduler hands a fired one-shot's slot back.
  #
  # It did not, and nothing could see that from inside a mod: `after` and
  # `onMainThread` took a slot per call and kept it, so a mod queueing work onto
  # the main thread every frame -- the documented way to touch Unity from a
  # worker thread -- grew that table for the length of the session. This is the
  # check that would have caught it: two identical batches, the second after the
  # first has certainly fired, and the table must not have doubled.
  if ticks == 3:
    # The per-frame chain on the game's thread, started **before** the batch
    # below so that the slot it holds is counted in `slotsAfterFirst` rather
    # than appearing between the two samples and reading as a leak.
    #
    # `everyMain` is what `mods/perf` writes by hand: a one-shot that queues
    # itself again before it returns. That it is a per-frame callback and not
    # an infinite loop inside one frame is a property of the host -- `drainDue`
    # snapshots the queue under the lock and runs the callbacks outside it, so
    # a re-arm lands after the snapshot the current drain is walking. This mod
    # is where that stops being a paragraph in one mod's source and becomes a
    # thing with a name.
    if everyMain(pumpMain) == Ok:
      mainStarted = true
    else:
      warn "everyMain was refused: " & lastError()
    scheduleBatch(32)
    slotsAfterFirst = scheduledSlots()
  elif ticks >= 50 and mainStarted and not mainReported:
    mainReported = true
    # Reported here rather than at 60, because the second batch of timers lands
    # at 60 and would move the slot count for reasons that have nothing to do
    # with this chain.
    if mainFires <= 0:
      warn "everyMain was accepted and never fired; either the host has no " &
           "main-thread drain or the chain did not re-arm"
    elif mainThreadWobbled:
      warn "everyMain fired on more than one thread, so it is not the " &
           "game's thread it is reaching"
    elif slotsAfterFirst <= 0:
      warn "the scheduler holds no slots at all, so there is nothing here " &
           "for everyMain to have grown and this check proved nothing"
    elif mainSlotsPeak > slotsAfterFirst:
      warn "everyMain grew the scheduler from " & $slotsAfterFirst &
           " slots to " & $mainSlotsPeak & "; a per-frame chain that takes " &
           "a slot per firing is a session-length leak"
    else:
      success "everyMain fired " & $mainFires & " times on thread " &
              $int(mainThread) & ", holding " & $mainSlotsPeak & " slots " &
              "throughout"
  elif ticks == 55 and mainReported and not mainStopTried:
    # Stopping it. An API to start a per-frame chain and no way to stop one is
    # half an API, and an untested stop is a mod that cannot be unloaded --
    # a chain still re-arming after its mod's library is gone is a jump into
    # freed code on the game's thread.
    #
    # The stop is deferred by one firing on purpose (the chain is queued on
    # another thread and yanking its slot is the one way a stop could crash),
    # so what is checked is that the firings *stop*, not that they stop
    # instantly.
    mainStopTried = true
    mainFiresAtStop = mainFires
    mainStopSaid = stopMainRepeats()
  elif ticks >= 70 and mainStopTried and not mainStopChecked:
    mainStopChecked = true
    let since = mainFires - mainFiresAtStop
    if mainStopSaid != 1:
      warn "stopMainRepeats said it stopped " & $mainStopSaid & " chains, " &
           "expected exactly 1"
    elif since > 1:
      warn "the chain kept going after stopMainRepeats: " & $since &
           " more firing(s); it is still re-arming"
    else:
      success "stopMainRepeats stopped the chain: " & $since &
              " further firing(s) over 15 ticks, against " & $mainFires &
              " before it"
  elif ticks == 60 and not slotsChecked:
    slotsChecked = true
    scheduleBatch(32)
    let now = scheduledSlots()
    if slotsAfterFirst <= 0:
      # Zero slots after arming 32 timers means `after` never took one --
      # no host, or a scheduler that refused -- and `0 <= 0` would otherwise
      # print the success line for a check that never happened.
      warn "the scheduler holds no slots at all after 32 timers, so there " &
           "is nothing here to reuse and this check proved nothing"
    elif now <= slotsAfterFirst:
      success "the scheduler reused its slots: " & $slotsAfterFirst &
              " after 32 timers, " & $now & " after 64"
    else:
      warn "the scheduler leaked slots: " & $slotsAfterFirst &
           " after 32 timers, " & $now & " after 64"
  Ok

exportMod(
  guid = "aowl.highlevel",
  name = "High Level",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
