## Classic Movement — a from-scratch nimony port of TheBoogle's *Old Tarkov
## Movement (no inertia)*, `com.boogle.oldtarkovmovement`, for aowlspt.
##
##     aowl build-mod mods/classicmovement
##
## Upstream: TheBoogle — https://github.com/TheBoogle/OldTarkovMovement and
## .../OldTarkovMovementServer — MIT, see LICENSE.txt beside this file. This is
## a modified redistribution under the same terms; the copyright holder is
## unchanged.
##
## Client and server halves in one binary, split by `side()`, which is the
## shape this system replaces upstream's two separate projects with.
##
## ---------------------------------------------------------------------------
## WHAT IT CHANGES, WHAT IT ASSUMES, AND WHAT IT HAS NEVER BEEN RUN AGAINST
## ---------------------------------------------------------------------------
##
## **What it changes in the game.** Three things, all on the client, all of them
## listed with their upstream patch in the table below:
##
##  1. Every frame, the local player's `MovementContext.SmoothedCharacter-
##     MovementSpeed` is overwritten with that player's `ClampedSpeed`, which
##     removes the smoothing ramp that is what "inertia" feels like. The write
##     rides on the `ManualUpdate` detour, and where that method cannot be
##     detoured it falls back to `everyMain` -- but only when the host confirms
##     its main-thread drain has fired on Unity's thread, because a movement
##     write from the host's own thread is a crash a frame or two later. Which
##     of the two is live is in the log, and neither is switched off by
##     `verifyHooks` any more: that flag used to disable this effect, which is
##     a diagnostic switch turning off the feature.
##  2. `MovementContext::OnEnterObstacle` is suppressed when the obstacle it was
##     handed carries the swamp speed limit, so bushes stop slowing anyone --
##     the player and every bot alike.
##  3. `MovementContext::SetAimingSlowdown` is suppressed outright when
##     `DoesAimingSlowYouDown` is off, which is all upstream's patch ever did.
##
## Nothing else is written. The server half only serves a config document.
##
## **What it assumes about the client.** Exactly five names, and each one is
## checked against the runtime's own metadata before anything is done with it:
## `EFT.GameWorld::get_Instance` (static), `get_MainPlayer`,
## `Player::get_MovementContext`, and the fields `_player` and
## `SmoothedCharacterMovementSpeed` on whatever class the movement context turns
## out to be. `ClampedSpeed` is assumed to be *either* a float field or a float
## property and the runtime is asked which. Every one of the five is bound
## against **the object's own class** rather than against the name written here,
## because a bound call is non-virtual by construction and the objects the game
## hands over are subclasses (`LocalPlayer`, SPT's raid `GameWorld`). A name
## that is wrong produces a refused binding with a `why` line in the log and an
## effect that does nothing, never a wrong write.
##
## **It has never been run against BSG's game.** Not once. Every EFT name below
## is from the pre-1.0 C# surface plus the SPT 4.1.2 rename map; post-1.0 is a
## different build. `aowl run mods/classicmovement` prints the whole binding
## report offline, and `verifyHooks` prints the live one a minute into a raid.
## Read one of those before believing any of the above happened.
##
## ---------------------------------------------------------------------------
## THE SERVER HALF IS COMPLETE. THE CLIENT HALF IS PARTIAL, AND SAYS WHICH PART.
## ---------------------------------------------------------------------------
##
## **Server.** Upstream's server mod is one loader and one route: read
## `Config/settings.jsonc`, serve it at `/OldTarkovMovement/GetConfig`. That is
## ported whole and behaves identically, down to the JSON member names, so a
## client built against the original protocol gets the response it expects.
##
## **Client.** Upstream's client half is six Harmony patches, every one of them
## a `[PatchPrefix]` taking `MovementContext __instance`. Three of the six are
## now expressible and are implemented; three are not, for reasons that are
## each one specific missing capability rather than a general shrug:
##
##   | upstream patch | here |
##   |---|---|
##   | `SmoothSpeedFix` on `::ManualUpdate` | **ported** — the private `_player` field and `SmoothedCharacterMovementSpeed` are both bound by offset **against the live context's own class**, and written every frame on the fast path |
##   | `BushSpeedStateRemover` on `::OnEnterObstacle` | **ported** — `hookArgs` reads the obstacle argument, and `stopVoid` suppresses the original when it carries the swamp speed limit |
##   | `AimingSlowdownPatch` on `::SetAimingSlowdown` | **ported** — `hookArgs` + `stopVoid`, gated on `DoesAimingSlowYouDown` exactly as upstream gates it |
##   | `StateReplacer` on `::GetNewState` | **not ported** — see below |
##   | `OldTiltingFix` on `::InertiaSmoothTilt` | **ported** — `thisPointer` turns the payload's `this` into an address, and `LegacySmoothTilt` is a bound call on it. On a revision-4 host it is a **typed** hook (`hookTyped`): the two floats and `this` come out of the registers the detour saved, at ~25 ns a firing against ~2.2 us for the JSON form |
##   | `RemoveJitteryRotationPatch` on `::PlayerAnimatorSetDeltaRotation` | **half ported** — the player/AI split is done; upstream's lerp-speed constant is not — see below |
##
## ### What the three are waiting on, and what they are no longer waiting on
##
## This section used to say "a hook is not told which instance it fired on",
## and that one sentence was the whole blocker behind all three. **It is not
## true any more.** `hookArgs` delivers an object now:
##
##     {"this":{"handle":3,"type":"EFT.MovementContext"},"args":[...]}
##
## `this` is Harmony's `__instance`, and a static method's is `null` rather than
## absent. The correction is written here rather than made silently, because
## that sentence is the stated reason three patches are missing and a reader
## deserves to know it expired.
##
## What replaced it has now expired too, and the second correction is worth the
## same paragraph the first one got. It read: "`this` arrives as a host
## `Handle`, and no ABI entry point turns one into the raw pointer the fast path
## needs" -- so anything reached through it was on the boxed path at ~1 us a
## call, and for `InertiaSmoothTilt` and `PlayerAnimatorSetDeltaRotation`, which
## fire **once per movement context per frame**, forty bots at 60 fps meant
## 2.4 ms of marshalling per frame. Fifteen percent of a frame budget to remove
## a lean delay is a stutter, not a feature, so both were left out with the
## number attached rather than a shrug.
##
## **That third sentence is off by a factor of sixty, and it is the sentence two
## refusals were decided on.** Forty contexts at a microsecond each is 40 us of
## work *in a frame*; 2.4 ms is what the same work costs *in a second*. Against
## a 60 fps frame's 16.67 ms the true share is **0.24%**, not fifteen percent --
## and the percentage was wrong twice over, because a per-second total was being
## divided by a per-frame budget. The arithmetic now lives in `frameShareText`
## below rather than in prose, every sentence that quotes it calls it, and the
## self-test asserts it. See "The frame budget" further down for the full
## re-derivation and for what happened to the two refusals when the premise
## moved two orders of magnitude: both were overturned and both are implemented.
##
## **ABI revision 3 turns a handle into an address.** `thisPointer(args)` gives
## the `Il2CppPtr` that `bindOnObject` takes, measured at 8 ns against 1148 for
## the boxed read it replaces (docs/PERF.md). The redirect and the `IsAI` read
## are now bound calls on the object the hook fired for, in tens of nanoseconds,
## and both patches are implemented below. The number that blocked them is the
## number that unblocked them, which is exactly why it was written down.
##
## Where an effect only ever concerned the local player, this port gets the
## instance the other way -- `GameWorld.Instance`, `MainPlayer`,
## `MovementContext`, all bound -- and that is what makes `SmoothSpeedFix` work
## at tens of nanoseconds rather than microseconds.
##
## * **`GetNewState`** is blocked twice over. Upstream's replacement states are
##   **subclasses it declares in C#** — `IdlePlayerState` and friends with
##   `UpdatePosition` overridden — and nothing here can define a managed type,
##   let alone construct one and hand it back as a reference return. Even a
##   version that only re-mapped one existing state onto another would need the
##   instance to construct the replacement against. This is the shape
##   `hookArgs` + `stopWith` was made for — read the `EPlayerState` argument,
##   answer without running the original — and it is still the one patch here
##   that the mechanism cannot carry, because what it must answer *with* does
##   not exist. Nothing is faked in its place.
##
##   (This used to carry a second blocker: that `EPlayerState` is an enum and
##   the host's argument decoder treated anything not a primitive or a string
##   as a *reference*, so asking for the arguments would have handed the
##   collector a small integer as an object. That is fixed -- the host asks the
##   runtime now, and an enum arrives as its number. `argsUsable` below no
##   longer refuses on that ground. The remaining blocker is the first one, and
##   it is not the kind an ABI fixes: what the patch must *answer with* does
##   not exist.)
##
## * **`InertiaSmoothTilt` -> `LegacySmoothTilt`** is **ported** (Effect 4). Two
##   floats in, suppress, call the other method on `this` -- and `this` is now
##   an address rather than a handle, so the redirect is a bound non-virtual
##   call against the context's own class. Both signatures are checked against
##   the runtime before the hook is installed, the redirect target included:
##   suppressing the original and then failing to reach the replacement is a
##   frozen lean, and it would only show up in a raid.
##
## * **`PlayerAnimatorSetDeltaRotation`** is **half ported** (Effect 5). The
##   player/AI split is done: `__instance.IsAI` off the address is a load or a
##   bound call rather than a boxed property get, so suppressing for the player
##   and letting AI through costs what upstream's version costs. `IsAI` is
##   looked for as a property and then as a field, because which it is on a
##   post-1.0 build cannot be confirmed from here and both are ordinary; if
##   neither answers, the original runs and the log says so rather than
##   suppressing for everything.
##
##   Its second half -- writing
##   `EFTHardSettings.Instance.TRANSFORM_ROTATION_LERP_SPEED` -- is still out,
##   and now it is the only thing on this list that is out for a reason about a
##   *value*: this port could not verify upstream's constant against a running
##   build, and inventing a number for a lerp speed is the kind of
##   approximation the rest of this file refuses.
##
## ---------------------------------------------------------------------------
## VERIFYING THE TARGETS — AND WHY THAT IS THE LESSON FROM THE C# PORT
## ---------------------------------------------------------------------------
##
## Porting this mod to SPT 4.1.2 in C# turned up a failure worth carrying
## forward. The replacement movement states declared `UpdatePosition`,
## `UpdateRotationAndPosition`, `HasNoInputForLongTime` and
## `ApplyMovementAndRotation` as `protected virtual`. On 4.1.2 those **hide**
## the base members instead of overriding them. The mod compiled without a
## warning that mattered, loaded without an error, and did nothing at all.
##
## That exact failure cannot happen here, because there is no inheritance: a
## patch names a compiled method and the host either finds it, relocates its
## prologue and detours it, or tells you which of those it could not do. But
## the underlying question survives the change of mechanism: **is the thing I
## hooked the thing the game actually calls?** A method can resolve, patch
## cleanly, and never fire — because it was renamed by a backport, because it
## was inlined, because the call site moved.
##
## `verifyHooks` answers it empirically. Each target below is detoured and its
## calls are counted, and a minute after the world comes up the counts are
## logged. A target with a non-zero count is confirmed live by observation, not
## by assumption. A target sitting at zero is named as stale in the log rather
## than being left for someone to discover as "the mod does nothing".
##
## That is how I know, for instance, that `InertiaSmoothTilt` and
## `LegacySmoothTilt` are the 4.1.2 names of the obfuscated `method_15`/
## `method_14` pair upstream patched: both resolve, both patch, and the first
## fires while leaning.
##
## The same report now also says what each **effect** did, not only what fired.
## A hook that fires and an effect that applies are different claims, and an
## effect that armed and never applied is the interesting failure — so it is
## reported as one rather than left to be inferred from a fire count.
##
## ---------------------------------------------------------------------------
## LEFT OUT DELIBERATELY
## ---------------------------------------------------------------------------
##
## * The Fika multiplayer patches — they need the Fika assembly, which does not
##   exist on this side of 1.0.
## * Nostalgia Mode — upstream stopped supporting it. `NostalgiaMode` is still
##   read and still served to a client over the route, because the wire shape
##   is upstream's and dropping a member from it would break a client that
##   deserialises into the original record.

import aowlspt
import aowlspt/game
import aowlspt/server
import aowlspt/json     # reading the hook payload, which is an object now
import aowlspt/il2cpp   # the runtime's own metadata, for signature checks
import aowlspt/fast     # bind once, call in ~10 ns — docs/PERF.md
import aowlspt/fixture  # where a self-test's runtime path may come from

const
  ModGuid = "aowl.classicmovement"
  ModName = "Classic Movement"
  ModAuthor = "TheBoogle (ported by savannt)"
  ModVersion = "1.3.0"
  ConfigRoute = "/OldTarkovMovement/GetConfig"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# Upstream's settings.jsonc, member for member. The names keep their upstream
# spelling on purpose: they are also the member names on the wire, and a client
# written against the original mod deserialises by exactly these.

var cfgNoInertia = true
var cfgQuickTilting = true
var cfgDoBushesSlowYouDown = false
var cfgBotsUseOldMovement = true
var cfgDoesAimingSlowYouDown = true
var cfgRemoveJitteryRotation = false
var cfgNostalgiaMode = false
var cfgVerifyHooks = true

proc loadConfig() =
  cfgNoInertia = setting("NoInertia").asBool(true)
  cfgQuickTilting = setting("QuickTilting").asBool(true)
  cfgDoBushesSlowYouDown = setting("DoBushesSlowYouDown").asBool(false)
  cfgBotsUseOldMovement = setting("BotsUseOldMovement").asBool(true)
  cfgDoesAimingSlowYouDown = setting("DoesAimingSlowYouDown").asBool(true)
  cfgRemoveJitteryRotation = setting("RemoveJitteryRotation").asBool(false)
  cfgNostalgiaMode = setting("NostalgiaMode").asBool(false)
  cfgVerifyHooks = setting("verifyHooks").asBool(true)

proc configDocument(): JsonObject =
  ## The body of `/OldTarkovMovement/GetConfig`, in upstream's member order.
  result = obj()
  put(result, "NostalgiaMode", cfgNostalgiaMode)
  put(result, "DoesAimingSlowYouDown", cfgDoesAimingSlowYouDown)
  put(result, "QuickTilting", cfgQuickTilting)
  put(result, "NoInertia", cfgNoInertia)
  put(result, "BotsUseOldMovement", cfgBotsUseOldMovement)
  put(result, "DoBushesSlowYouDown", cfgDoBushesSlowYouDown)
  put(result, "RemoveJitteryRotation", cfgRemoveJitteryRotation)

# ---------------------------------------------------------------------------
# The server half
# ---------------------------------------------------------------------------

proc onGetConfig(url, body, session: string): string =
  ## Upstream serialises the config record and returns it bare -- no envelope.
  ## That is correct and not an oversight: `envelope` belongs to `/client/*`,
  ## where the client reads `err` before it looks at the data. This route is the
  ## mod's own, its consumer is the mod's own client half, and wrapping it would
  ## break a client written against the original protocol.
  result = done(configDocument()).text

proc serverLoad(): Status =
  if serve(ConfigRoute, onGetConfig) != Ok:
    error "could not register " & ConfigRoute & ": " & lastError()
    return ErrGeneric
  success "Old Tarkov Movement config served at " & ConfigRoute
  info "  NoInertia=" & $cfgNoInertia & " QuickTilting=" & $cfgQuickTilting &
       " DoBushesSlowYouDown=" & $cfgDoBushesSlowYouDown
  info "  BotsUseOldMovement=" & $cfgBotsUseOldMovement &
       " DoesAimingSlowYouDown=" & $cfgDoesAimingSlowYouDown &
       " RemoveJitteryRotation=" & $cfgRemoveJitteryRotation
  if cfgNostalgiaMode:
    warn "NostalgiaMode is on in config, but upstream stopped supporting it " &
         "and it is not ported; it is served on the route and does nothing"
  Ok

# ---------------------------------------------------------------------------
# The client half
# ---------------------------------------------------------------------------
#
# Types named at the top, resolved on first use -- the game's assemblies are
# not loaded when a mod starts, so resolving early is a false negative.
#
# The names are the 4.1.2 ones, not the obfuscated names upstream used: the
# movement state classes were `IdleStateClass`, `RunStateClass`,
# `SprintStateClass`, `JumpStateClass`, `ProneIdleStateClass` and
# `SideStepStateClass` before the rename.

var MovementContext = gameType("EFT.MovementContext")
var IdlePlayerState = gameType("EFT.IdlePlayerState")
var MovePlayerState = gameType("EFT.MovePlayerState")
var SprintPlayerState = gameType("EFT.SprintPlayerState")
var JumpPlayerState = gameType("EFT.JumpPlayerState")
var PronePlayerState = gameType("EFT.PronePlayerState")
var SideStepPlayerState = gameType("EFT.SideStepPlayerState")
var EFTHardSettings = gameType("EFT.EFTHardSettings")
var ProceduralWeaponAnimation = gameType("EFT.Animations.ProceduralWeaponAnimation")

var world = whenReady("EFT.GameWorld")

const
  TyGameWorld = "EFT.GameWorld"
  TyPlayer = "EFT.Player"
  TyCtx = "EFT.MovementContext"

  ManualUpdate = TyCtx & "::ManualUpdate"
  OnEnterObstacle = TyCtx & "::OnEnterObstacle"
  SetAimingSlowdown = TyCtx & "::SetAimingSlowdown"

# ---------------------------------------------------------------------------
# The runtime, and the signature checks that gate every hook
# ---------------------------------------------------------------------------
#
# A mod DLL lives in the same process as the host, so `openIl2Cpp` binds the
# already-loaded `GameAssembly.dll` directly (docs/PERF.md). That buys the fast
# path and, just as usefully, the runtime's own metadata -- which is how a
# signature gets *checked* before it is hooked instead of remembered.

var rt: Il2Cpp
var rtOpen = false

proc openRuntime(): bool =
  if rtOpen:
    return true
  rt = openIl2Cpp()
  if not rt.loaded:
    return false
  let missing = rt.missingEssential()
  if missing.len > 0:
    warn "the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the fast path stays off"
    return false
  rtOpen = true
  result = true

proc signatureOf(owner, member: string; argc: int;
                 params: var seq[string]; ret: var string): bool =
  ## The declared parameter and return types of a method, from the runtime.
  ## `argc` of -1 matches any arity, exactly as the host's `patch` does.
  params = @[]
  ret = ""
  if not rtOpen:
    return false
  let cls = findClass(rt, owner)
  if cls == nil:
    return false
  let m = findMethod(rt, cls, member, argc)
  if m == nil:
    return false
  let n = methodParamCount(rt, m)
  for i in 0 ..< n:
    params.add typeName(rt, methodParam(rt, m, i))
  ret = typeName(rt, methodReturnType(rt, m))
  result = true

proc describeSig(params: seq[string]; ret: string): string =
  result = "("
  for i in 0 ..< params.len:
    if i > 0: result.add ", "
    result.add params[i]
  result.add ") -> " & ret

proc argsUsable(params: seq[string]; why: var string): bool =
  ## Whether this method's arguments will arrive in a form this mod can use.
  ##
  ## **This used to be a safety guard and is not one any more, and the change is
  ## worth stating rather than quietly making.** The host once built the
  ## argument array from the declared type name alone: primitives and strings it
  ## formatted, and everything else it treated as a reference -- taking the
  ## register, calling `il2cpp_gchandle_new` on it and reporting a handle. For
  ## an enum such as `EPlayerState` that register holds a small integer, and
  ## handing it to the collector was not a wrong answer, it was a crash inside a
  ## game method. So this refused any parameter `classifyType` would not
  ## classify, which meant refusing every enum.
  ##
  ## The host asks the runtime now (`shapeOfType`): an enum arrives as its
  ## integer, a value type too large for a register arrives as
  ## `{"valueType":"..."}` -- named and refused rather than invented -- and a
  ## type it cannot classify arrives as `{"type":"..."}`. None of those is a
  ## crash, so there is nothing left to be *safe* from.
  ##
  ## What is left is a usability question, and it is narrower: a parameter this
  ## mod actually needs to *read* and which arrives as a placeholder is a
  ## parameter it cannot decide on. Only the big-value-type case is that, and
  ## only when the mod reads it -- so this reports which parameters are
  ## placeholders and lets each caller decide whether it cared.
  ##
  ## **This gate could not fail until today, and that is worth stating rather
  ## than quietly fixing.** `classifyType` used to answer `fkPtr` for every
  ## non-primitive the resolver could find, so `== fkNone` was false for every
  ## real EFT type and the body below never ran once. It answers honestly now,
  ## which makes this a live test for the first time -- and a live test has to
  ## agree with the thing it is predicting. That thing is the host's
  ## `shapeOfType` (host/Aowlspt.Host.Il2Cpp/invoke.nim), whose rule is:
  ##
  ##   * no class for the declared type            -> `{"type":"..."}`
  ##   * a value type of 1..8 payload bytes        -> its number
  ##   * any other value type                      -> `{"valueType":"..."}`
  ##
  ## The payload is the *reported instance size minus the box header*, and the
  ## header is measured (`boxHeaderBytes`) rather than assumed. This used to
  ## test `classInstanceSize(c) > 24`, which is the same predicate only on a
  ## runtime whose header happens to be 16 bytes -- the exact assumption
  ## `boxHeaderBytes` exists to stop anyone making. On a runtime that reports
  ## payload sizes instead, `> 24` accepted every value type in the game and
  ## this proc would have promised readable arguments for a `Vector3`.
  why = ""
  result = true
  let header = boxHeaderBytes(rt)
  for i in 0 ..< params.len:
    if classifyType(rt, params[i]) != fkNone:
      # A primitive, or a reference, or a value type that fits a register.
      # Readable either way.
      continue
    let c = findClass(rt, params[i])
    if c == nil:
      # The name did not resolve. That is not automatically a placeholder --
      # the host classifies from the declared *type*, which resolves for
      # generics and arrays where the printed name does not -- but this mod
      # cannot establish that from here, and claiming a parameter is readable
      # on the strength of a lookup that failed is the one direction that
      # matters.
      if why.len > 0: why.add ", "
      why.add "argument " & $i & " (" & params[i] &
              ") is a type this mod cannot resolve by name, so it cannot say " &
              "whether the host will report a value or a placeholder"
      result = false
      continue
    if not classIsValueType(rt, c):
      continue
    let payload = classInstanceSize(rt, c) - header
    if payload <= 0 or payload > 8:
      if why.len > 0: why.add ", "
      why.add "argument " & $i & " (" & params[i] & ") is a " & $payload &
              "-byte value type, so it arrives by hidden pointer and the " &
              "host reports {\"valueType\":\"" & params[i] & "\"} rather " &
              "than a value"
      result = false

# ---------------------------------------------------------------------------
# Effects
# ---------------------------------------------------------------------------
#
# Each effect carries a state string -- "armed", or "refused: <what the runtime
# said>" -- and its own applied counter. Not a boolean "installed": a patch
# that installs and never runs is the reason this mod counts anything at all,
# and an effect deserves the same doubt.

var gSmoothState = "not attempted"
var gSmoothWrites = 0
var gBushState = "not attempted"
var gBushSuppressed = 0
var gBushSeen = 0
var gAimState = "not attempted"
var gAimSuppressed = 0
var gTiltState = "not attempted"
var gTiltRedirects = 0
var gJitterState = "not attempted"
var gJitterSuppressed = 0
var gJitterLet = 0

proc armed(state: string): bool =
  ## An effect state reads "armed...", "refused: ..." or "off (...)". Only the
  ## first means a hook was installed, and that is the question every caller of
  ## this actually has.
  result = state.len >= 5 and state.substr(0, 4) == "armed"

# ---------------------------------------------------------------------------
# Binding against the object, once
# ---------------------------------------------------------------------------
#
# `bindOnObject` and `bindFieldOn` both need an object, so neither can be done
# before the game exists -- which means the attempt happens on the frame path.
# That is fine exactly once and a disaster every frame: `findMethod` walks a
# class's method table and `bindOnObject` walks the whole base chain, which the
# self-test measured at ~2 us. A *refused* binding retried per frame is the
# worst case, because it never succeeds and never stops costing.
#
# So an attempt is keyed on the class it was made against. The first time an
# object of that class arrives the bind happens; after that it is one pointer
# compare, whether the bind succeeded or not. A different class -- a different
# `Player` subclass, a weapon swap that changes a controller's type -- is a new
# question and is asked again, which is the same rule `mods/sain`'s `LazyCall`
# uses and for the same reason.

type
  ObjBind = object
    ## One member, bound against the class of the object it is used with.
    b: Binding
    f: FieldBinding
    isField: bool
    cls: Il2CppClass     ## the class the attempt was made against
    tried: bool
    why: string

proc noObjBind(): ObjBind =
  ObjBind(b: Binding(ok: false, why: "", target: "", fn: nullPtr(),
                     info: nullPtr(), argc: 0'i32, slots: 0'i32, mask: 0'u32,
                     ret: fkNone, isStatic: false, bindNs: 0'i64),
          f: FieldBinding(ok: false, why: "", target: "", offset: 0'i32,
                          kind: fkNone, bindNs: 0'i64, wbarrier: nullPtr()),
          isField: false, cls: cast[Il2CppClass](0), tried: false, why: "")

proc bindFieldOn(rt: Il2Cpp; obj: Il2CppPtr; fieldName: string;
                 ownerOut: var string): FieldBinding =
  ## `fast.bindField` takes a type *name*, and there is no `bindFieldOnObject`
  ## to match `bindOnObject`. This is that: the field is looked for on the class
  ## the object actually is and then on each of its ancestors, so a movement
  ## context that turns out to be a subclass still finds `_player`.
  ##
  ## Every guard `bindField` applies is applied here, and for the same reasons:
  ##
  ##  * a field the runtime *says* is static is refused by that answer, not by
  ##    its offset. This is the guard that used to be missing here, and it is
  ##    the one that matters: `il2cpp_field_get_offset` on a static field
  ##    returns an offset into the class's static data block, and the two
  ##    ranges overlap completely -- the stand-in runtime has a static
  ##    `Player::SpawnCount` at the same offset as the instance
  ##    `Player::Health`, which is ordinary rather than contrived. An instance
  ##    read of that offset answers a neighbouring field's bytes with total
  ##    confidence, and `ok` is true. `fast.bindField` asks
  ##    `il2cpp_field_get_flags` first for exactly this reason; this asks it
  ##    too, and refuses outright on a runtime that does not export it rather
  ##    than falling back on a test that cannot decide the question;
  ##  * offset 0 is the object header and is never a field;
  ##  * an offset at or past the instance size is not addressing this object at
  ##    all. Kept as a second guard rather than as *the* guard, which is what
  ##    it used to be;
  ##  * a type the fast path will not classify is refused rather than loaded,
  ##    because a value type wider than eight bytes has to be copied, not read.
  ##    Classified from the **declared type** first and from its printed name
  ##    only as the fallback, matching `fast.bindField`: the two differ exactly
  ##    where it matters -- a generic instantiation, an array, a nested type.
  ##
  ## The instance size is the **concrete** class's, not the declaring class's:
  ## the object is that size, and a base class's size would reject a legitimate
  ## field declared past it on a subclass.
  let t0 = perfCounter()
  result = FieldBinding(ok: false, why: "", target: "::" & fieldName,
                        offset: 0'i32, kind: fkNone, bindNs: 0'i64,
                        wbarrier: nullPtr())
  ownerOut = ""
  if obj == nil:
    result.why = fieldName & ": no object to bind against"
    return
  let concrete = objectClass(rt, obj)
  if concrete == nil:
    result.why = fieldName & ": the object has no class"
    return
  let size = classInstanceSize(rt, concrete)
  let concreteName = fullName(rt, concrete)
  var c = concrete
  while c != nil:
    let f = findField(rt, c, fieldName)
    if f != nil:
      ownerOut = fullName(rt, c)
      result.target = ownerOut & "::" & fieldName
      if not rt.has(eFieldGetFlags):
        result.why = result.target &
          ": this runtime does not export il2cpp_field_get_flags, so there " &
          "is no way to establish that this field is an instance field. An " &
          "offset cannot decide it -- a static field's offset is into the " &
          "class's static block and lands in the same range. Refusing."
        return
      if fieldIsStatic(rt, f):
        result.why = result.target &
          " is a static field: its offset is into the class's static data " &
          "block, not into this object. An instance read of it would answer " &
          "whichever field of " & concreteName & " sits at the same offset."
        return
      let off = fieldOffset(rt, f)
      if off <= 0 or (size > 0 and off >= size):
        result.why = result.target & ": offset " & $off &
          " is outside an instance of size " & $size &
          " -- a layout this path cannot use"
        return
      let ft = fieldType(rt, f)
      let tn = typeName(rt, ft)
      var k = classifyDeclared(rt, ft)
      if k == fkNone:
        k = classifyType(rt, tn)
      if k == fkNone or k == fkVoid:
        result.why = result.target & " is declared " & tn &
          ", which the fast path will not read by offset"
        return
      result.offset = int32(off)
      result.kind = k
      # Resolved here for the reason `fast.bindField` resolves it here: so a
      # `writePtr` through this binding is a branch on a pointer rather than a
      # lookup, and so `barrierReady` can answer. Nothing in this mod writes a
      # reference field today -- every write it makes is `writeFloat` -- but a
      # binding that silently could not be barriered is the shape of hazard
      # this file exists not to have.
      result.wbarrier = writeBarrierFn(rt)
      result.ok = true
      result.bindNs = nanosBetween(t0, perfCounter())
      result.why = result.target & ": " & describe(k) & " at offset " & $off &
                   " (on a live " & concreteName & ", " &
                   (if result.wbarrier != nil: "collector barrier available"
                    else: "no collector barrier on this runtime") & ")"
      return
    c = classParent(rt, c)
  ownerOut = concreteName
  result.target = concreteName & "::" & fieldName
  result.why = "no field " & fieldName & " on " & concreteName &
               " or any of its base classes"

proc sameClass(o: var ObjBind; obj: Il2CppPtr): bool =
  ## True when this member has already been asked about the class `obj` is.
  ## The whole per-call overhead of binding lazily: one `il2cpp_object_get_class`
  ## and one pointer compare.
  let c = objectClass(rt, obj)
  if c == nil:
    return false
  if o.tried and o.cls == c:
    return true
  o.cls = c
  o.tried = false
  result = false

proc statedKindsDisagree(b: Binding; kinds: openArray[FastKind];
                         ret: FastKind): string =
  ## What the runtime says about a binding whose register classes this mod
  ## **asserted**, or `""` when the two agree.
  ##
  ## `bindMethod` infers the signature from the runtime's own metadata and
  ## refuses what it cannot classify. `bindOnObject` cannot: it has a class
  ## rather than a name, and the inference path takes a name -- so every call
  ## bound here states its kinds, and `fast.nim` says in as many words that
  ## "the mod is asserting the register classes, and it is on the mod to be
  ## right".
  ##
  ## An assertion nobody checks is a remembered signature, which is the thing
  ## this whole file is arranged not to rely on. And the failure it produces is
  ## the worst one available rather than a crash: a `System.Double` asserted as
  ## `fkF32` reads the wrong half of XMM0 and answers a plausible number; a
  ## `System.Int32` asserted as `fkBool` answers `true` for any value whose low
  ## byte is not zero. Both arrive with `ok` true and both get acted on.
  ##
  ## So the assertion is checked against the method the bind actually landed
  ## on. `Binding.info` is that `MethodInfo*`, which is the whole cost of the
  ## check: no second lookup, and it happens once per class rather than per
  ## call. `fkNone` from the runtime is a disagreement rather than a pass --
  ## it means a value type wider than a register, which does not travel in the
  ## register this mod named at all.
  result = ""
  if not b.ok or b.info == nil:
    return
  let n = methodParamCount(rt, b.info)
  if n != kinds.len:
    result = b.target & " declares " & $n & " parameter(s); this mod bound " &
             "it as " & $kinds.len
    return
  for i in 0 ..< kinds.len:
    let d = classifyDeclared(rt, methodParam(rt, b.info, i))
    if d != kinds[i]:
      result = b.target & ": parameter " & $i & " is " & describe(d) &
               " and this mod passed " & describe(kinds[i])
      return
  let rk = classifyDeclared(rt, methodReturnType(rt, b.info))
  if rk != ret:
    result = b.target & ": returns " & describe(rk) &
             " and this mod read " & describe(ret)

proc ensureCall(o: var ObjBind; obj: Il2CppPtr; member: string;
                kinds: openArray[FastKind]; ret: FastKind): bool =
  ## Bind `member` against the object's own class, at most once per class, and
  ## check the kinds this mod asserted against the method it landed on.
  if obj == nil:
    return false
  if not sameClass(o, obj):
    o.tried = true
    o.isField = false
    o.b = bindOnObject(rt, obj, member, kinds, ret)
    o.why = o.b.why
    let disagreement = statedKindsDisagree(o.b, kinds, ret)
    if disagreement.len > 0:
      # The bind succeeded and is being thrown away, which is the point: a
      # binding that resolves against a signature this mod does not have is
      # exactly the one that answers a plausible number.
      o.b.ok = false
      o.why = disagreement
      o.b.why = disagreement
  result = o.b.ok

proc ensureField(o: var ObjBind; obj: Il2CppPtr; member: string): bool =
  ## The same for a field. `ownerOut` is folded into `why`, which is where a
  ## reader looks for it.
  if obj == nil:
    return false
  if not sameClass(o, obj):
    o.tried = true
    o.isField = true
    var owner = ""
    o.f = bindFieldOn(rt, obj, member, owner)
    o.why = o.f.why
  result = o.f.ok

proc noKinds(): seq[FastKind] =
  ## An empty argument list for `bindOnObject`. A bare `[]` literal has no type
  ## for nimony to infer at that call site, so the empty seq is named once.
  result = @[]

# ---------------------------------------------------------------------------
# Effect 1: SmoothSpeedFix
# ---------------------------------------------------------------------------
#
# The chain, and where each member's binding comes from:
#
#     GameWorld.Instance                 static     -> bindMethod, by name
#       .MainPlayer                      instance   -> ObjBind, on the world
#         .MovementContext               instance   -> ObjBind, on the player
#           ._player                     field      -> ObjBind, on the context
#           .SmoothedCharacterMovement…  field      -> ObjBind, on the context
#         .ClampedSpeed                  field/prop -> ObjBind, on the player
#
# Only the first is bound by name, and only because it is static: a bound call
# is non-virtual by construction, so `bindMethod(rt, "EFT.Player",
# "get_MovementContext", 0)` would call `EFT.Player`'s body even when the object
# in hand is the `LocalPlayer` subclass the game actually hands over -- silently,
# with a plausible answer. `EFT.GameWorld` has the same problem: SPT's raid world
# is a subclass and `get_MainPlayer` is a member it can override.
#
# Nothing is bound in `onLoad`. `findClass` walks every loaded assembly and the
# game's are not among them then, so a binding made there would correctly refuse
# and never be retried.

var bWorld: Binding            ## static, so bound by name: nothing overrides it
var obMainPlayer: ObjBind
var obCtxOf: ObjBind
var obCtxPlayer: ObjBind       ## the private `_player` back-reference
var obSmoothed: ObjBind        ## the float this effect writes
var obClampedField: ObjBind
var obClampedProp: ObjBind
var obLegacyTilt: ObjBind      ## the fast lean `InertiaSmoothTilt` redirects to
var obIsAiProp: ObjBind        ## `get_IsAI` on the context, if it is a property
var obIsAiField: ObjBind       ## ...and the field, if it is not
var gClampedIsField = false
var gChainOwners = ""          ## the concrete class the context bound on
var gSmoothChainDone = false
var gSmoothNs = 0'i64
var gSmoothSamples = 0

const CostSamples = 512
  ## How many frames of `applySmoothSpeed` are timed before the measurement
  ## stops. Two `perfCounter` calls are about forty nanoseconds, which is the
  ## same order as the work being measured, so measuring forever would be
  ## paying for a number nobody reads twice.

proc bindSmoothStatics(): bool =
  ## The one member that has no object to bind against yet.
  ##
  ## `get_Instance` is static, so `bindMethod` is right for it: the rule is
  ## "`bindMethod` for a static or a method nothing overrides, `bindOnObject`
  ## the moment a subclass is possible", and a static has no subclass to
  ## dispatch on.
  obMainPlayer = noObjBind()
  obCtxOf = noObjBind()
  obCtxPlayer = noObjBind()
  obSmoothed = noObjBind()
  obClampedField = noObjBind()
  obClampedProp = noObjBind()
  obLegacyTilt = noObjBind()
  obIsAiProp = noObjBind()
  obIsAiField = noObjBind()
  bWorld = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  if not bWorld.ok:
    gSmoothState = "refused: " & bWorld.why
    return false
  gSmoothState = "arming: waiting for a world to bind the rest against"
  result = true

proc applySmoothSpeed() =
  ## Upstream's `SmoothSpeedFix`, on the local player's movement context.
  ##
  ## Runs inside the `ManualUpdate` detour, so it is on the game thread and
  ## inside the game's own frame. Every pointer is resolved fresh and dropped
  ## before this returns -- rule 4 in docs/PERF.md, and the reason nothing here
  ## stores one across a frame.
  ##
  ## It fires once per movement context per frame, which in a full raid is
  ## dozens of times for one write that matters. It is not rate-limited, and
  ## that is deliberate: the chain is four bound calls, two loads and a store --
  ## and a rate limiter fine enough not to skip a frame at 240 fps would cost
  ## more in clock reads than it saved. The cost is **measured** rather than
  ## asserted; see `CostSamples` and `smoothCostNs`.
  if not bWorld.ok:
    return
  let measuring = gSmoothSamples < CostSamples
  var t0 = 0'i64
  if measuring:
    t0 = perfCounter()

  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return

  var none = noKinds()
  if not ensureCall(obMainPlayer, w, "get_MainPlayer", none, fkPtr):
    gSmoothState = "refused: " & obMainPlayer.why
    return
  a.reset()
  let mainPlayer = callPtr(obMainPlayer.b, w, a)
  if mainPlayer == nil: return

  if not ensureCall(obCtxOf, mainPlayer, "get_MovementContext", none, fkPtr):
    gSmoothState = "refused: " & obCtxOf.why
    return
  a.reset()
  let ctx = callPtr(obCtxOf.b, mainPlayer, a)
  if ctx == nil: return

  # The two fields upstream reaches by reflection, bound against the context
  # this player is actually driving rather than against the *name*
  # `EFT.MovementContext`.
  if not ensureField(obCtxPlayer, ctx, "_player"):
    gSmoothState = "refused: " & obCtxPlayer.why
    return
  if not ensureField(obSmoothed, ctx, "SmoothedCharacterMovementSpeed"):
    gSmoothState = "refused: " & obSmoothed.why
    return
  if obSmoothed.f.kind != fkF32 and obSmoothed.f.kind != fkF64:
    gSmoothState = "refused: " & obSmoothed.why & ", which is not a float"
    obSmoothed.f.ok = false
    return
  gChainOwners = obCtxPlayer.f.target

  # Upstream reads the speed off `__instance._player` rather than off the
  # player it already has, and this does the same -- not out of deference, but
  # because reading the private back-reference is what proves the context found
  # by walking the world is the context this player is actually driving.
  let owner = readPtr(obCtxPlayer.f, ctx)
  if owner == nil: return

  # `ClampedSpeed` is a field on some builds and a property on others, and which
  # one it is here is the runtime's answer rather than this port's memory. The
  # field is tried first because it is the cheaper read (1.9 ns against 8.4,
  # docs/PERF.md). Both are resolved against the object, so a `LocalPlayer`
  # override is the one that gets called rather than `Player`'s body.
  var haveSpeed = false
  var speed = 0.0
  if ensureField(obClampedField, owner, "ClampedSpeed") and
     (obClampedField.f.kind == fkF32 or obClampedField.f.kind == fkF64):
    gClampedIsField = true
    speed = readFloat(obClampedField.f, owner)
    haveSpeed = true
  elif ensureCall(obClampedProp, owner, "get_ClampedSpeed", none, fkF32):
    gClampedIsField = false
    a.reset()
    speed = callFloat(obClampedProp.b, owner, a)
    haveSpeed = true
  if not haveSpeed:
    gSmoothState = "refused: ClampedSpeed is neither a float field (" &
                   obClampedField.why & ") nor a getter (" &
                   obClampedProp.why & ")"
    return

  if not gSmoothChainDone:
    gSmoothChainDone = true
    gSmoothState = "armed on " & gChainOwners & ", ClampedSpeed read as " &
                   (if gClampedIsField: "a field" else: "a property")
    info "Classic Movement: SmoothSpeedFix bound -- " & gSmoothState

  writeFloat(obSmoothed.f, ctx, speed)
  gSmoothWrites = gSmoothWrites + 1
  if measuring:
    gSmoothNs = gSmoothNs + nanosBetween(t0, perfCounter())
    gSmoothSamples = gSmoothSamples + 1

proc smoothCostNs(): int64 =
  ## The measured cost of one `applySmoothSpeed`, in nanoseconds, or -1 when
  ## nothing has been measured. Reported rather than asserted: docs/PERF.md's
  ## numbers come from a stand-in runtime on one machine, and this is the client
  ## the mod is actually in.
  if gSmoothSamples <= 0:
    return -1'i64
  result = gSmoothNs div int64(gSmoothSamples)

# ---------------------------------------------------------------------------
# Effect 2: BushSpeedStateRemover
# ---------------------------------------------------------------------------

proc onEnterObstacle(target, args: string): HookResult =
  ## Upstream reads the obstacle's `HasSwampSpeedLimit` and drops it on the
  ## floor; here the whole call is suppressed when the obstacle carries that
  ## limit, which is the same outcome reached from outside the method.
  ##
  ## This is one of the two patches that needs nothing from `__instance`: the
  ## obstacle is a declared argument, so `hookArgs` reports it as a live handle
  ## and the decision is made from the argument alone. It therefore applies to
  ## every movement context in the raid, which is correct -- a bush that does
  ## not slow the player down does not slow a bot down either.
  gBushSeen = gBushSeen + 1
  # The payload is an **object**, not a bare array:
  #
  #     {"this":{"handle":3,"type":"EFT.MovementContext"},"args":[{...}]}
  #
  # An earlier revision of this proc handed the whole payload to `asObject`,
  # which found the *first* handle in it -- and now that `this` is delivered,
  # the first handle is the movement context rather than the obstacle. It would
  # have read `HasSwampSpeedLimit` off a `MovementContext`, got nothing, and
  # suppressed nothing, for ever, with no error anywhere. So the argument is
  # taken out of `args` by index.
  #
  # The method takes exactly one argument -- checked against the runtime before
  # this was installed -- so element zero is the obstacle.
  let first = at(field(args, "args"), 0)
  if not exists(first):
    return carryOn()
  let obstacle = asObject(CallResult(ok: true, raw: raw(first), error: ""))
  if not obstacle.ok:
    return carryOn()
  var swamp = obstacle.get("HasSwampSpeedLimit")
  if swamp.failed:
    swamp = obstacle.field("HasSwampSpeedLimit")
  let limited = swamp.asBool(false)
  # The host registers a GC handle per reference argument and never reclaims
  # it; a hook that keeps every one it is handed pins an object per bush for
  # the session.
  obstacle.release()
  if not limited:
    return carryOn()
  gBushSuppressed = gBushSuppressed + 1
  result = stopVoid()

proc armBushRemover() =
  if cfgDoBushesSlowYouDown:
    gBushState = "off (DoBushesSlowYouDown is true, which is the game's own " &
                 "behaviour)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyCtx, "OnEnterObstacle", -1, params, ret):
    gBushState = "refused: no " & OnEnterObstacle
    return
  if ret != "System.Void":
    gBushState = "refused: it is " & describeSig(params, ret) &
                 ", and suppressing a method that returns something means " &
                 "inventing the something"
    return
  if params.len != 1:
    gBushState = "refused: it is " & describeSig(params, ret) &
                 ", and this reads the obstacle out of a single argument"
    return
  var unusable = ""
  if not argsUsable(params, unusable):
    gBushState = "refused: " & describeSig(params, ret) & " -- " & unusable &
                 ", and the obstacle is the argument this reads"
    return
  if hookArgs(OnEnterObstacle, onEnterObstacle) == Ok:
    gBushState = "armed on " & describeSig(params, ret)
  else:
    gBushState = "refused: " & lastError()

# ---------------------------------------------------------------------------
# Effect 3: AimingSlowdownPatch
# ---------------------------------------------------------------------------

proc onAimingSlowdown(target, args: string): HookResult =
  ## Upstream's patch does nothing but suppress, and only when the setting is
  ## off; the gating happens at arm time so the hook is not even installed when
  ## it would have nothing to do.
  gAimSuppressed = gAimSuppressed + 1
  result = stopVoid()

proc armAimingSlowdown() =
  if cfgDoesAimingSlowYouDown:
    gAimState = "off (DoesAimingSlowYouDown is true, which is the game's own " &
                "behaviour; upstream's patch only ever suppressed)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyCtx, "SetAimingSlowdown", -1, params, ret):
    gAimState = "refused: no " & SetAimingSlowdown
    return
  if ret != "System.Void":
    gAimState = "refused: it is " & describeSig(params, ret) &
                ", and suppressing a method that returns something means " &
                "inventing the something"
    return
  var unusable = ""
  if not argsUsable(params, unusable):
    # This one suppresses unconditionally and reads nothing, so an unreadable
    # parameter would not actually stop it -- but refusing a hook whose payload
    # this mod cannot fully account for is the conservative side to be on, and
    # the reason is printed rather than implied.
    gAimState = "refused: " & describeSig(params, ret) & " -- " & unusable
    return
  if hookArgs(SetAimingSlowdown, onAimingSlowdown) == Ok:
    gAimState = "armed on " & describeSig(params, ret)
  else:
    gAimState = "refused: " & lastError()

# ---------------------------------------------------------------------------
# The frame budget, and the arithmetic two refusals were decided on
# ---------------------------------------------------------------------------
#
# This file used to do this sum in prose, in five places, and it was wrong in
# all five by the same factor of sixty. It said the boxed redirect cost
# "2.4 ms a frame with forty bots" and called that "fifteen percent of a frame
# budget"; it said the JSON form's 2.2 us was "5.3 ms a frame" and the typed
# form's 25 ns "60 us". Every one of those is a **per-second** total wearing a
# per-frame label. Forty contexts at 1 us each is 40 us of work in a frame and
# 2.4 ms of work in a second; the percentage then inherited the same factor,
# because a second's total was divided by a frame's budget. 0.24% was written
# down as fifteen percent.
#
# It survived because it was wrong *consistently*. 2.4 ms against 60 us is the
# same hundredfold as the 1 us against 25 ns underneath, so every comparison
# the file drew from these numbers was sound and only the verdicts were not.
# A consistent error is the kind that lives longest, and the same species turned
# up in docs/ARCHITECTURE.md the same day.
#
# So it is a function now, and the sentences quote the function.
#
# **The derivation, from what the code does rather than from what it said.**
#
#  * *What fires, per what.* `InertiaSmoothTilt` and
#    `PlayerAnimatorSetDeltaRotation` are instance methods on a movement
#    context and the game runs them once per context per frame. The unit is
#    therefore **firings per frame = contexts**, and the worst case this mod
#    plans for is a full bot population: forty.
#  * *What one firing costs.* From docs/PERF.md, every row against
#    `tests/mockil2cpp` on one machine and none of it against BSG's client:
#    a JSON prefix hook dispatch is 626.5 ns; a boxed call with the class in
#    hand is 951.5 ns and by name 1103.6; a boxed property read through a
#    handle is 1112; `pointerOf` is 8; a bound instance call with one float is
#    8.4; a typed prefix hook is 23.08. Those add up into the three shapes this
#    hook can take, named as constants below.
#  * *Against what budget.* One frame at 60 fps is 16.67 ms -- `FrameNs`. Not a
#    second, which is the whole of the mistake. At 144 fps it is 6.94 ms, so
#    every share below roughly doubles and none of the verdicts change.
#
# Which gives, per frame, at forty contexts:
#
#   | shape | per firing | per frame | share of a 60 fps frame |
#   |---|---:|---:|---:|
#   | typed hook, revision 4 | 25 ns | 1.0 us | 0.006% |
#   | JSON hook + `thisPointer`, revision 3 | 2200 ns | 88 us | 0.528% |
#   | JSON hook + a boxed call on the handle, revision 2 | 1600 ns | 64 us | 0.384% |
#   | one boxed `IsAI` read on the handle, revision 2 | 1112 ns | 44 us | 0.267% |
#   | *what the old prose assumed* | 1000 ns | 40 us | **0.240%**, not 15% |
#
# The 2200 for the revision-3 shape is the ceiling this file has quoted since
# the port and it is **not measured**: PERF.md's parts add to about 700 ns
# (626 dispatch + 8 `pointerOf` + a bound call + the payload scans), and 2200 is
# kept anyway because a decision taken on the pessimistic figure stays right
# when the real one arrives. The typed 25 ns *is* measured, in-client, by
# `tiltCostNs`.

const
  BusiestContexts = 40
    ## Movement contexts alive in the worst raid this mod plans for. The unit
    ## that matters: it is also firings **per frame**, because these methods run
    ## once per context per frame.
  FrameNs = 16_666_667
    ## One frame at 60 fps, in nanoseconds. The denominator that was missing.
  TiltTypedNs = 25
    ## Typed hook, revision 4. Measured in-client by `tiltCostNs`; PERF.md's
    ## typed prefix hook is 23.08 ns on the stand-in.
  TiltAddressNs = 2200
    ## JSON hook plus `thisPointer` plus a bound call, revision 3. An unmeasured
    ## ceiling -- see above.
  TiltBoxedNs = 1600
    ## JSON hook plus one boxed call on the handle, revision 2: 626.5 + 951.5,
    ## the two rows PERF.md measures for exactly those two steps.
  IsAiBoxedNs = 1112
    ## One boxed property read through a handle, revision 2. PERF.md measures
    ## `get_Health` that way at 1112 ns.

proc perFrameNs(nsPerFiring: int): int =
  ## What `BusiestContexts` firings of something cost **in one frame**.
  ##
  ## Multiplying by 60 as well is the bug this proc exists to make unrepeatable:
  ## that answers what they cost in a *second*, and a second is not what a frame
  ## budget is measured against.
  BusiestContexts * nsPerFiring

proc perFrameUs(nsPerFiring: int): int = perFrameNs(nsPerFiring) div 1000

proc frameShareMilli(nsPerFiring: int): int =
  ## Share of one 60 fps frame, in thousandths of a percent. 240 is 0.240%.
  ##
  ## Rounded rather than truncated, and the half added on is not cosmetic: the
  ## true share of a frame for forty firings at 1 us is 0.239999...%, so a
  ## floor answers 239 and the file's headline figure of 0.240% would have read
  ## as an off-by-one against its own function. A rounding rule chosen after
  ## seeing what it answers is worth saying out loud, so: this one was.
  let n = int64(perFrameNs(nsPerFiring)) * 100_000'i64
  int((n + int64(FrameNs) div 2'i64) div int64(FrameNs))

proc frameShareText(nsPerFiring: int): string =
  ## "88 us a frame, 0.528% of a 60 fps frame" -- the sentence, from the sum.
  let m = frameShareMilli(nsPerFiring)
  var frac = $(m mod 1000)
  while frac.len < 3: frac = "0" & frac
  result = $perFrameUs(nsPerFiring) & " us a frame with " &
           $BusiestContexts & " contexts, " & $(m div 1000) & "." & frac &
           "% of a 60 fps frame"

# ---------------------------------------------------------------------------
# Effect 4: OldTiltingFix
# ---------------------------------------------------------------------------
#
# Upstream redirects `InertiaSmoothTilt(a, b)` to `LegacySmoothTilt(a, b)` on
# `__instance`, which is the whole of the fix: the legacy lean has no inertia
# ramp, so leaning is instant again.
#
# This was left out, and the reason it was left out has expired. The mechanism
# was never the problem -- two floats in, suppress, call the other method -- and
# `this` has been in the payload for a while. What stopped it was the price of
# *using* `this`: it arrived as a host handle, so the redirect would have been a
# boxed `invoke` at about a microsecond, once per movement context per frame,
# which with forty bots at 60 fps is 2.4 ms a frame. That is fifteen percent of
# a frame budget to remove a lean delay, and shipping it would have been
# shipping a stutter.
#
# **The last two sentences are wrong by sixty and are kept here so the record
# is.** 2.4 ms is what that costs in a second; in a frame it is 40 us, which is
# 0.24% -- and the boxed shape measured properly (626.5 ns of hook dispatch plus
# 951.5 for a call with the class in hand) is 1.6 us a firing, so
# `frameShareText(TiltBoxedNs)` a frame. That is not a stutter and it was never
# a reason. What was actually true is that the boxed form is a hundredfold
# worse than the address one for no gain *on a host that has addresses*; on a
# host that does not, it is affordable and is now what runs. See
# `onInertiaSmoothTiltBoxed`.
#
# ABI revision 3 gives `thisPointer(args)`: the address behind that handle, in
# about 8 ns. The redirect is now a bound call on the object the hook fired
# for -- tens of nanoseconds, per context, per frame. The number that blocked it
# is the number that unblocks it, which is why it was worth writing down rather
# than shrugging about.
#
# `bindOnObject` rather than `bindMethod`, and `ensureCall` rather than a
# one-time bind: the context handed to this hook may be a subclass, a bound call
# is non-virtual by construction, and binding by name against `MovementContext`
# would silently call the base implementation. `ensureCall` re-binds when the
# class changes and not otherwise -- one `il2cpp_object_get_class` and a pointer
# compare per firing.

proc argFloat(args: string; index: int; ok: var bool): float =
  ## One declared argument out of a hook payload, as a float.
  ##
  ## Out of `"args"` by index rather than by searching the payload: `this` is in
  ## the same object and is itself a handle, so anything that scans for the
  ## first number would find one of its digits. The arity is checked against the
  ## runtime before the hook is installed, so an index in range is a real
  ## parameter.
  ok = false
  result = 0.0
  let a = at(field(args, "args"), index)
  if not exists(a):
    return
  let r = CallResult(ok: true, raw: raw(a), error: "")
  ok = true
  result = r.asFloat(0.0)

proc onInertiaSmoothTilt(target, args: string): HookResult =
  let p = thisPointer(args)
  if p == 0'u64:
    # No address for `this`: a host older than revision 3, or a handler that
    # somehow outlived its handle. Letting the original run is the only safe
    # answer -- suppressing it and calling nothing would freeze the lean.
    return carryOn()
  let obj = cast[Il2CppPtr](p)
  var okA = false
  var okB = false
  let a = argFloat(args, 0, okA)
  let b = argFloat(args, 1, okB)
  if not okA or not okB:
    return carryOn()
  if not ensureCall(obLegacyTilt, obj, "LegacySmoothTilt",
                    [fkF32, fkF32], fkVoid):
    return carryOn()
  var ar = argsFF(a, b)
  callVoid(obLegacyTilt.b, obj, ar)
  gTiltRedirects = gTiltRedirects + 1
  result = stopVoid()

# ---------------------------------------------------------------------------
# ...and the same redirect with nothing but the handle
# ---------------------------------------------------------------------------
#
# **This is a refusal that was overturned.** On a host below ABI revision 3
# there is no `pointerOf`, so `this` is a handle and nothing else, and this
# effect used to refuse outright with "the redirect would be a boxed call per
# context per frame -- about 2.4 ms a frame with forty bots". The 2.4 ms was a
# per-second total (see "The frame budget"): per frame the boxed shape is
# 626.5 ns of hook dispatch plus 951.5 ns for a call with the class already in
# hand, so 1.6 us a firing and `frameShareText(TiltBoxedNs)`. Refusing a
# feature over a third of one percent of a frame is not a performance decision,
# it is an arithmetic mistake, so the effect arms here instead.
#
# `GameObj` over the payload's handle rather than `thisHandle` + a raw `call`:
# the `#n::` target form is the one PERF.md measures at 951.5, and it resolves
# the method against **the object's own class**, which is the same non-virtual
# guarantee `bindOnObject` gives the address path. A context that is really a
# subclass gets the subclass's `LegacySmoothTilt`.
#
# The handle is **not released**. It is the host's, on loan for the duration of
# the handler, and the host reclaims it on return; releasing it here would be
# freeing something twice.
#
# **The suppression is conditional, and that is the whole of the risk.** The
# address path suppresses after a call that cannot really fail (a bound call to
# a compiled method). A boxed call can fail for a dozen host reasons, and
# suppressing the original after one has failed is a lean frozen mid-tilt that
# only shows up in a raid. So the replacement runs first and the original is
# suppressed only if it came back `ok`. The self-test asserts exactly this, on
# a host where the call is guaranteed to fail.
#
# **It has never run.** Every host in this tree reports revision 4, so nothing
# here has executed this path in anger; it is an argument from code, and the
# only part of it the self-test can execute is the failure branch.

var gTiltBoxedRefused = 0
  ## Firings where the boxed replacement could not be reached and the original
  ## was let through. A non-zero count here is the effect not working; it is
  ## still much better than the alternative, which is a lean that stops moving.

proc onInertiaSmoothTiltBoxed(target, args: string): HookResult =
  result = carryOn()
  let h = thisHandle(args)
  if h == 0'u64:
    return
  var okA = false
  var okB = false
  let a = argFloat(args, 0, okA)
  let b = argFloat(args, 1, okB)
  if not okA or not okB:
    return
  let ctx = GameObj(handle: h, typeName: TyCtx, ok: true)
  let r = invoke(ctx, "LegacySmoothTilt", v(a), v(b))
  if not r.ok:
    gTiltBoxedRefused = gTiltBoxedRefused + 1
    return
  gTiltRedirects = gTiltRedirects + 1
  result = stopVoid()

# ---------------------------------------------------------------------------
# ...and the same redirect on the typed path
# ---------------------------------------------------------------------------
#
# `onInertiaSmoothTilt` above is the JSON form and stays, because a host older
# than ABI revision 4 has nothing else. This is the same redirect written
# against the register frame, and it is the form this hook should actually be
# in: `InertiaSmoothTilt` runs once per movement context per frame, so with
# forty bots at 60 fps the JSON version's ~2.2 us is 88 us a frame and this
# one's ~25 ns is 1.0 us. (This used to read "5.3 ms a frame" and "60 us": both
# were per-*second* totals, and both are now `frameShareText` calls so they
# cannot drift apart from the sum again. The hundredfold between them was
# always right, which is why nobody noticed.)
#
# Line for line it is the same decision. What is gone is the machinery around
# it: `thisPointer` was a handle lookup, a GC handle the host took out and gave
# back, and a `handle_pointer` round trip; `argFloat(args, 0)` was a scan over a
# JSON object the host had just built out of two registers; `stopVoid()` was a
# string the mod allocated and the host parsed. Here `this` is RCX, the two
# floats are XMM1 and XMM2, and the suppression is a flag.

var gTiltTypedNs = 0'i64
var gTiltTypedSamples = 0
var gTiltTyped = false
  ## Which form armed. Reported in the effect's state, because "armed" without
  ## saying which would hide the difference between 25 ns and 2.2 us a firing.
  ## ("a frame" is what this said, and a firing is what it meant: forty of them
  ## fit in a frame.)

proc onInertiaSmoothTiltTyped(f: PatchFrame): TypedResult =
  let measuring = gTiltTypedSamples < CostSamples
  var t0 = 0'i64
  if measuring: t0 = perfCounter()
  let p = f.selfPointer()
  if p == 0'u64:
    # A static method, or an expired frame. Letting the original run is the only
    # safe answer -- suppressing it and calling nothing would freeze the lean.
    return frameContinue()
  let obj = cast[Il2CppPtr](p)
  var okA = false
  var okB = false
  let a = f.argFloat(0, okA)
  let b = f.argFloat(1, okB)
  if not okA or not okB:
    # The declared kinds are not the two floats this redirect passes through.
    # `armOldTilting` checked the signature against the runtime before arming,
    # so this is the belt to that braces -- and it refuses rather than reading
    # the registers anyway, which would pass two arbitrary numbers to the lean.
    return frameContinue()
  if not ensureCall(obLegacyTilt, obj, "LegacySmoothTilt",
                    [fkF32, fkF32], fkVoid):
    return frameContinue()
  var ar = argsFF(a, b)
  callVoid(obLegacyTilt.b, obj, ar)
  gTiltRedirects = gTiltRedirects + 1
  if not f.setResultVoid():
    # The declared return is not `void`, so this cannot honestly suppress: the
    # caller would get whatever is in the return register. The original runs,
    # and the lean is inertial rather than wrong.
    return frameContinue()
  if measuring:
    gTiltTypedNs = gTiltTypedNs + nanosBetween(t0, perfCounter())
    gTiltTypedSamples = gTiltTypedSamples + 1
  frameReplace()

proc tiltCostNs(): int64 =
  ## The measured cost of one redirect, in nanoseconds, or -1 when nothing was
  ## measured. Reported rather than asserted, for the reason `smoothCostNs`
  ## gives: docs/PERF.md's numbers are a stand-in runtime on one machine and
  ## this is the client the mod is actually in.
  if gTiltTypedSamples <= 0:
    return -1'i64
  result = gTiltTypedNs div int64(gTiltTypedSamples)

proc armOldTilting() =
  if not cfgQuickTilting:
    gTiltState = "off (QuickTilting is false)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyCtx, "InertiaSmoothTilt", -1, params, ret):
    gTiltState = "refused: no " & TyCtx & "::InertiaSmoothTilt"
    return
  if ret != "System.Void":
    gTiltState = "refused: InertiaSmoothTilt is " & describeSig(params, ret) &
                 ", and suppressing a method that returns something means " &
                 "inventing the something"
    return
  if params.len != 2 or params[0] != "System.Single" or
     params[1] != "System.Single":
    gTiltState = "refused: InertiaSmoothTilt is " & describeSig(params, ret) &
                 ", and the redirect passes two floats through unchanged"
    return
  # The target of the redirect is checked here too. Suppressing the original
  # and then failing to reach the replacement is a frozen lean, and it would
  # only show up in a raid.
  var lparams: seq[string] = @[]
  var lret = ""
  if not signatureOf(TyCtx, "LegacySmoothTilt", -1, lparams, lret):
    gTiltState = "refused: no " & TyCtx & "::LegacySmoothTilt to redirect to"
    return
  if lret != "System.Void" or lparams.len != 2 or
     lparams[0] != "System.Single" or lparams[1] != "System.Single":
    gTiltState = "refused: LegacySmoothTilt is " & describeSig(lparams, lret) &
                 ", which is not the signature InertiaSmoothTilt would be " &
                 "redirected into"
    return
  if not livePointersReady():
    # This used to `return` here, refused, with "the redirect would be a boxed
    # call per context per frame -- about 2.4 ms a frame with forty bots". The
    # 2.4 ms was per second. Per frame the boxed shape is
    # `frameShareText(TiltBoxedNs)`, so the refusal is withdrawn and the boxed
    # form arms instead. What is *not* withdrawn is the warning: it is a
    # hundredfold worse than the address path and it has never been run.
    if hookArgs(TyCtx & "::InertiaSmoothTilt", onInertiaSmoothTiltBoxed) == Ok:
      gTiltState = "armed on the handle-only path (this host has no " &
                   "pointerOf, so the redirect is a boxed call on `this` at " &
                   "~" & $TiltBoxedNs & " ns a firing -- " &
                   frameShareText(TiltBoxedNs) & "). This used to be a " &
                   "refusal quoting 2.4 ms a frame, which was 2.4 ms a second"
    else:
      gTiltState = "refused: " & lastError()
    return
  # The typed form when the host has it, and the JSON one when it does not.
  #
  # Not "typed or nothing": a host at revision 3 can still run this effect, and
  # 2.2 us a context is a real cost rather than a disqualifying one -- at forty
  # contexts it is `frameShareText(TiltAddressNs)`. The typed form is tried
  # first because it is a hundredfold cheaper for nothing, not because the JSON
  # one is unaffordable; which form armed is in the state line rather than
  # implied. (This comment used to say the JSON form was "disqualifying at
  # forty". At forty it is half of one percent of a frame.)
  if typedPatchesReady() and
     hookTyped(TyCtx & "::InertiaSmoothTilt", onInertiaSmoothTiltTyped) == Ok:
    gTiltTyped = true
    gTiltState = "armed on the typed path, redirecting into LegacySmoothTilt " &
                 "on `this`"
  elif hookArgs(TyCtx & "::InertiaSmoothTilt", onInertiaSmoothTilt) == Ok:
    gTiltState = "armed on the JSON path (this host is ABI revision " &
                 $hostApiSize() & " bytes of HostApi, and the typed frame " &
                 "wants revision 4), redirecting into LegacySmoothTilt on " &
                 "`this` at ~" & $TiltAddressNs & " ns a firing -- " &
                 frameShareText(TiltAddressNs)
  else:
    gTiltState = "refused: " & lastError()

# ---------------------------------------------------------------------------
# Effect 5: RemoveJitteryRotationPatch, the half that is expressible
# ---------------------------------------------------------------------------
#
# Upstream suppresses `PlayerAnimatorSetDeltaRotation` for the player and lets
# AI through, telling them apart with `__instance.IsAI`. That read is now cheap
# for the same reason the tilt redirect is: the address behind `this` costs
# 8 ns, and `IsAI` off it is a load or a bound call rather than a boxed
# property get.
#
# **Only that half.** Upstream also writes
# `EFTHardSettings.Instance.TRANSFORM_ROTATION_LERP_SPEED`, and this port could
# not confirm upstream's constant against a running build. Inventing a number
# for a lerp speed is the kind of approximation the rest of this file refuses,
# so it is still left out -- and it is left out for a *reason about a value*,
# not a missing capability, which is a different and much shorter problem.
#
# `IsAI` is looked for as a property first and as a field second, because which
# one it is on a post-1.0 build cannot be confirmed from here and both are
# ordinary. Whichever answers is reported in the effect's state, so the log says
# what was actually read rather than what was hoped for.
#
# **That last sentence was a claim the code could not keep.** `contextIsAi` took
# a `known: var bool` and set it to true down either branch, so the only thing
# it could report was *that* one of the two answered -- which is precisely the
# question nobody has. The log then said "get_IsAI as a property, then IsAI as a
# field" and let a reader believe the answer was in there somewhere. It takes a
# `how: var string` now and names the branch it came back from; `gJitterHow`
# carries it into the report, and the self-test asserts the string against a
# runtime that really does have `get_IsAI` as a property and one that has
# neither. Either record which, or stop saying you do.

const
  IsAiViaProperty = "get_IsAI, a property, bound on the context's own class"
  IsAiViaField = "IsAI, a field, read at its offset"
    ## The two answers, named once. The self-test compares against these rather
    ## than against a substring, so a reworded string that stops distinguishing
    ## the branches fails to compile rather than quietly passing.

proc contextIsAi(obj: Il2CppPtr; how: var string): bool =
  ## `how` is "" when neither shape answered, and otherwise names the one that
  ## did. Empty is the only value that means "unknown", so a caller cannot read
  ## a default as an answer.
  how = ""
  result = false
  if ensureCall(obIsAiProp, obj, "get_IsAI", noKinds(), fkBool):
    how = IsAiViaProperty
    var none = noArgs()
    return callBool(obIsAiProp.b, obj, none)
  if ensureField(obIsAiField, obj, "IsAI"):
    how = IsAiViaField
    return readBool(obIsAiField.f, obj)

var gJitterHow = ""
  ## Which shape answered, last time one did. Reported rather than assumed: see
  ## the paragraph above for what this replaced.

proc onDeltaRotation(target, args: string): HookResult =
  let p = thisPointer(args)
  if p == 0'u64:
    return carryOn()
  let obj = cast[Il2CppPtr](p)
  var how = ""
  let isAi = contextIsAi(obj, how)
  if how.len > 0 and gJitterHow != how:
    gJitterHow = how
  if how.len == 0:
    # Neither a property nor a field answered. Suppressing for everything --
    # bots included -- is not what upstream does, and doing it anyway would be
    # a guess about which contexts matter. The original runs.
    return carryOn()
  if isAi:
    gJitterLet = gJitterLet + 1
    return carryOn()
  gJitterSuppressed = gJitterSuppressed + 1
  result = stopVoid()

# The same split with nothing but the handle, and the second overturned refusal.
#
# This effect used to refuse on a host without `pointerOf`, on the grounds that
# "telling the player from a bot would be a boxed property get per context per
# frame" -- a sentence that carried the same 2.4-ms-a-frame arithmetic as the
# tilt refusal did, from the same paragraph. PERF.md measures that boxed
# property get through a handle at 1112 ns, so forty of them is
# `frameShareText(IsAiBoxedNs)`. A quarter of one percent of a frame is a price,
# not a disqualification, and the refusal is withdrawn.
#
# Which shape answered is remembered in `gJitterBoxedHow` so the steady state is
# **one** boxed call and not two: the property is tried first, and a host where
# `IsAI` turns out to be a field pays the double cost once rather than every
# frame. Same conditional-suppression rule as the tilt fallback for the same
# reason -- if neither read answers, the original runs. Suppressing rotation for
# every bot in the raid because a read failed is a far worse outcome than a
# jittery player.
#
# Never run: no host in this tree is below revision 3.

var gJitterBoxedHow = ""

proc boxedIsAi(ctx: GameObj; how: var string): bool =
  how = ""
  result = false
  if gJitterBoxedHow != "field":
    let p = get(ctx, "IsAI")
    if p.ok:
      gJitterBoxedHow = "property"
      how = "get_IsAI, a boxed property get on the handle"
      return p.asBool(false)
  let f = field(ctx, "IsAI")
  if f.ok:
    gJitterBoxedHow = "field"
    how = "IsAI, a boxed field read on the handle"
    return f.asBool(false)

proc onDeltaRotationBoxed(target, args: string): HookResult =
  result = carryOn()
  let h = thisHandle(args)
  if h == 0'u64:
    return
  let ctx = GameObj(handle: h, typeName: TyCtx, ok: true)
  var how = ""
  let isAi = boxedIsAi(ctx, how)
  if how.len > 0 and gJitterHow != how:
    gJitterHow = how
  if how.len == 0:
    return
  if isAi:
    gJitterLet = gJitterLet + 1
    return
  gJitterSuppressed = gJitterSuppressed + 1
  result = stopVoid()

proc armRemoveJitter() =
  if not cfgRemoveJitteryRotation:
    gJitterState = "off (RemoveJitteryRotation is false)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyCtx, "PlayerAnimatorSetDeltaRotation", -1, params, ret):
    gJitterState = "refused: no " & TyCtx & "::PlayerAnimatorSetDeltaRotation"
    return
  if ret != "System.Void":
    gJitterState = "refused: it is " & describeSig(params, ret) &
                   ", and suppressing a method that returns something means " &
                   "inventing the something"
    return
  if not livePointersReady():
    # Overturned, for the reason above `onDeltaRotationBoxed`: the refusal this
    # replaced rested on the same off-by-sixty sum as the tilt one, and a boxed
    # `IsAI` read at forty contexts is a quarter of one percent of a frame.
    if hookArgs(TyCtx & "::PlayerAnimatorSetDeltaRotation",
                onDeltaRotationBoxed) == Ok:
      gJitterState = "armed on the handle-only path (this host has no " &
                     "pointerOf, so IsAI is a boxed read at ~" &
                     $IsAiBoxedNs & " ns a firing -- " &
                     frameShareText(IsAiBoxedNs) & "); the " &
                     "TRANSFORM_ROTATION_LERP_SPEED write is still out"
    else:
      gJitterState = "refused: " & lastError()
    return
  if hookArgs(TyCtx & "::PlayerAnimatorSetDeltaRotation", onDeltaRotation) == Ok:
    gJitterState = "armed, suppressing for the player and letting AI through " &
                   "(the TRANSFORM_ROTATION_LERP_SPEED write is still out: " &
                   "upstream's constant is unverified here)"
  else:
    gJitterState = "refused: " & lastError()

# ---------------------------------------------------------------------------
# Hook verification
# ---------------------------------------------------------------------------

var gWatchNames: seq[string] = @[]
var gWatchCounts: seq[int] = @[]
var gWatchWhy: seq[string] = @[]
var gReported = false
var gElapsedMs = 0'i64

proc watchIndex(target: string): int =
  result = -1
  for i in 0 ..< gWatchNames.len:
    if gWatchNames[i] == target:
      return i

proc onWatched(target: string) =
  ## One dispatcher for every detour, matching on the name the host hands back.
  ## Not a closure per hook: nimony refuses a nested proc that touches an
  ## enclosing local unless it is a closure, and a closure is not a plain
  ## function pointer, so it cannot cross the C ABI a patch callback goes over.
  let i = watchIndex(target)
  if i >= 0:
    gWatchCounts[i] = gWatchCounts[i] + 1
  # `SmoothSpeedFix` rides on the same detour rather than adding a second one:
  # two patches on one compiled function would be a detour of a detour.
  if target == ManualUpdate:
    applySmoothSpeed()

proc countOnly(target, why: string) =
  ## Count a target whose detour some *effect* already installed.
  ##
  ## `onWatched` increments by name, so a target registered here is counted by
  ## the hook that is already on it. Two calls to `hook` on one compiled method
  ## would be a detour of a detour, which is the thing this whole file is
  ## careful about; this is how a target can be both an effect and a
  ## measurement without being patched twice.
  gWatchNames.add target
  gWatchCounts.add 0
  gWatchWhy.add why

proc watch(target, why: string) =
  countOnly(target, why)
  if hook(target, onWatched) == Ok:
    info "watching " & target & " (" & why & ")"
  else:
    warn "cannot watch " & target & ": " & lastError()
    shrink(gWatchNames, gWatchNames.len - 1)
    shrink(gWatchCounts, gWatchCounts.len - 1)
    shrink(gWatchWhy, gWatchWhy.len - 1)

# ---------------------------------------------------------------------------
# What drives SmoothSpeedFix, and why it is no longer `verifyHooks`
# ---------------------------------------------------------------------------
#
# `SmoothSpeedFix` is the effect this mod exists for, and until now it was
# installed by the *diagnostic* block: the write rode on the `ManualUpdate`
# detour, that detour was only attached when `verifyHooks` was true, and
# setting `verifyHooks` to false in config.json therefore switched off the
# mod's main effect. The log said so in a `warn`, which is better than silence
# and is not a defence -- a diagnostic flag that disables the feature is a bug
# whatever it prints. The driver is armed here now, because the effect wants
# it, and `verifyHooks` decides only whether anything is *counted*.
#
# Two drivers, in order of how well each is established:
#
#  1. **The `ManualUpdate` detour.** A method of the game's, so it runs on the
#     game's thread by construction rather than by anyone's assurance, and it
#     is where upstream's patch ran. It fires once per movement context per
#     frame, which is dozens of times in a full raid for the one write that
#     matters; the write is four bound calls, two loads and a store, and the
#     cost is measured rather than asserted.
#
#  2. **`everyMain`, if the first cannot be installed.** This is new and it is
#     the reason this block was rewritten. `everyMain` re-arms itself onto the
#     host's main-thread queue from inside its own firing, so it runs once per
#     drain and holds one scheduler slot rather than one per frame.
#
#     What makes it usable *here* is a separate fact about the host, and this
#     file used to state the opposite of it: the IL2CPP host now detours a
#     per-frame game method and drains `invoke_main` from inside it, so the
#     main-thread queue is Unity's thread when the drain bound. It is not
#     always: on a host where no candidate could be detoured the queue falls
#     back to the host's own thread, and a Unity write from there is the
#     documented way to crash a frame or two later. So this is gated on the
#     host's own answer -- `call("aowlspt.host::main_thread")` reports `bound`
#     only once the drain has actually *fired*, which is the distinction
#     between "installed" and "reached" that the rest of this file is built
#     around. Not bound is not a fallback, it is a refusal.

type
  MainThread = object
    asked: bool
    ok: bool           ## the host answered at all
    bound: bool        ## the drain is on Unity's thread and has fired
    methodName: string
    frames: int64

proc askMainThread(): MainThread =
  ## `call("aowlspt.host::main_thread")`, decoded. Answered by the host before
  ## it checks whether the runtime is up, so it is meaningful even with no game
  ## -- which is what makes it a gate rather than an afterthought.
  result = MainThread(asked: true, ok: false, bound: false, methodName: "",
                      frames: 0'i64)
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    return
  if raw.len == 0:
    return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.methodName = asText(field(raw, "method"), "")
  result.frames = int64(asInt(field(raw, "frames"), 0))

var gDriverState = "not attempted"
var gDriverIsEveryMain = false
var gDriverThreadId = 0'i64
var gDriverFirings = 0

proc onSmoothTick(payload: string): string =
  ## The `everyMain` driver. One firing per drain, on the thread the host says
  ## is Unity's.
  ##
  ## The thread id is recorded rather than assumed, because the whole claim
  ## behind this path is "this ran where a Unity write is legal" and the only
  ## evidence available for it from inside a mod is the number itself. It is
  ## printed in the report next to the host's own answer, so the two can
  ## disagree in public rather than privately.
  gDriverFirings = gDriverFirings + 1
  gDriverThreadId = currentThreadId()
  applySmoothSpeed()
  result = ""

proc armSmoothDriver() =
  ## Install whatever will call `applySmoothSpeed` every frame.
  if not cfgNoInertia:
    gDriverState = "off (NoInertia is false, so there is nothing to drive)"
    return
  if not armed(gSmoothState) and gSmoothState.substr(0, 5) != "arming":
    gDriverState = "refused: SmoothSpeedFix did not arm (" & gSmoothState &
                   "), so a driver would call a chain that refuses per frame"
    return
  if hook(ManualUpdate, onWatched) == Ok:
    gDriverState = "armed on the " & ManualUpdate & " detour, which is a " &
                   "game method and therefore the game's own thread"
    return
  let hookWhy = lastError()
  let mt = askMainThread()
  if not mt.ok:
    gDriverState = "refused: " & ManualUpdate & " could not be detoured (" &
                   hookWhy & ") and this host does not answer " &
                   "aowlspt.host::main_thread, so there is no thread " &
                   "everyMain could be shown to reach"
    return
  if not mt.bound:
    gDriverState = "refused: " & ManualUpdate & " could not be detoured (" &
                   hookWhy & ") and the host's main-thread drain is not " &
                   "confirmed on Unity's thread (" &
                   (if mt.methodName.len > 0: "drain method " & mt.methodName &
                                              ", " & $mt.frames & " firings"
                    else: "no drain method bound") &
                   "), so everyMain would write a movement speed from the " &
                   "host's own thread"
    return
  if everyMain(onSmoothTick) == Ok:
    gDriverIsEveryMain = true
    gDriverState = "armed on everyMain (" & ManualUpdate &
                   " could not be detoured: " & hookWhy & "), which the host " &
                   "drains from " & mt.methodName & " on Unity's thread -- " &
                   "once per frame rather than once per movement context"
  else:
    gDriverState = "refused: " & ManualUpdate & " could not be detoured (" &
                   hookWhy & ") and everyMain was refused by the host too"

proc reportType(t: var GameType) =
  if t.available():
    info "  resolved " & t.name
  else:
    warn "  NOT FOUND: " & t.name &
         " -- a 4.1.2-era rename would show up here first"

proc onWorldReady() =
  success "Classic Movement: the game world is up"

  # The movement state types are still resolved, and still not constructed:
  # nothing here can define the subclasses upstream replaces them with. What
  # the check buys is the cheapest possible confirmation that the rename map
  # this port was written against still matches the build that is running.
  reportType(MovementContext)
  reportType(IdlePlayerState)
  reportType(MovePlayerState)
  reportType(SprintPlayerState)
  reportType(JumpPlayerState)
  reportType(PronePlayerState)
  reportType(SideStepPlayerState)
  reportType(EFTHardSettings)
  reportType(ProceduralWeaponAnimation)

  # Binding happens here and not in `onLoad`, and that is not a detail:
  # `findClass` walks every loaded assembly, and at load time the game's own
  # assemblies are not among them, so a binding made then would correctly
  # refuse and never be retried.
  if not openRuntime():
    gSmoothState = "refused: the IL2CPP runtime could not be bound from the mod"
    gBushState = gSmoothState
    gAimState = gSmoothState
    gTiltState = gSmoothState
    gJitterState = gSmoothState
    warn "Classic Movement: " & gSmoothState
  else:
    discard bindSmoothStatics()
    armBushRemover()
    armAimingSlowdown()
    armOldTilting()
    armRemoveJitter()

  # The driver goes in before the diagnostics, because it is the effect and
  # they are the measurement. It used to go in after, inside the `verifyHooks`
  # block, which meant one config flag switched off the mod.
  armSmoothDriver()

  info "Classic Movement: SmoothSpeedFix -- " & gSmoothState
  info "Classic Movement:   driven by -- " & gDriverState
  info "Classic Movement: BushSpeedStateRemover -- " & gBushState
  info "Classic Movement: AimingSlowdownPatch -- " & gAimState
  info "Classic Movement: OldTiltingFix -- " & gTiltState
  info "Classic Movement: RemoveJitteryRotationPatch -- " & gJitterState

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours. " &
         "SmoothSpeedFix is unaffected -- it is driven on its own account " &
         "now, and this flag decides only what is counted."
    return

  # Only the targets the config actually asks for, exactly as upstream's
  # `Awake` only calls `Enable()` on the patches its config enables. There are
  # 16 patch slots; this uses at most seven, three of which now do work rather
  # than only counting.
  if cfgNoInertia:
    watch(TyCtx & "::GetNewState",
          "StateReplacer -- not ported: the replacement states are C# " &
          "subclasses, which nothing here can declare")
  # Counted, not hooked again: `armSmoothDriver` already detoured this when it
  # took the first of its two paths, and on the `everyMain` path there is no
  # detour on it to count.
  if gDriverIsEveryMain:
    info "not watching " & ManualUpdate &
         " -- it could not be detoured, which is why the write is on everyMain"
  elif armed(gDriverState):
    countOnly(ManualUpdate,
              "SmoothSpeedFix -- per-frame speed smoothing; carries the write")
    info "watching " & ManualUpdate & " through the driving hook (SmoothSpeedFix)"
  else:
    watch(ManualUpdate,
          "SmoothSpeedFix -- per-frame speed smoothing (the write is not on " &
          "it: " & gDriverState & ")")
  if not cfgDoBushesSlowYouDown:
    # The suppressing hook is the watcher: `hookArgs` and `hook` both go
    # through `patch`, and two patches on one method would be two detours.
    if armed(gBushState):
      info "watching " & OnEnterObstacle &
           " through the suppressing hook (BushSpeedStateRemover)"
    else:
      watch(OnEnterObstacle,
            "BushSpeedStateRemover -- the SWAMP speed limit on bushes")
  if cfgQuickTilting:
    if armed(gTiltState):
      info "watching " & TyCtx & "::InertiaSmoothTilt through the " &
           "redirecting hook (OldTiltingFix)"
    else:
      watch(TyCtx & "::InertiaSmoothTilt",
            "OldTiltingFix -- the inertia lean that would be redirected")
    # Not watched when the redirect is armed: the redirect *calls* it, so a
    # detour here would count this mod's own calls and report the redirect
    # working as evidence that the game reaches the method.
    if not armed(gTiltState):
      watch(TyCtx & "::LegacySmoothTilt",
            "OldTiltingFix -- the fast lean it would be redirected to")
  if cfgRemoveJitteryRotation:
    if armed(gJitterState):
      info "watching " & TyCtx & "::PlayerAnimatorSetDeltaRotation through " &
           "the suppressing hook (RemoveJitteryRotationPatch)"
    else:
      watch(TyCtx & "::PlayerAnimatorSetDeltaRotation",
            "RemoveJitteryRotationPatch -- the per-frame rotation write")
    watch("EFT.Animations.ProceduralWeaponAnimation::InitTransforms",
          "RemoveStupidMotionSicknessBSGMade -- camera input intensity")
  if cfgDoesAimingSlowYouDown:
    info "DoesAimingSlowYouDown is on, which is the game's own behaviour; " &
         "upstream's patch only ever suppressed the method, so with the " &
         "setting on there is nothing to watch"
  elif armed(gAimState):
    info "watching " & SetAimingSlowdown &
         " through the suppressing hook (AimingSlowdownPatch)"
  else:
    watch(SetAimingSlowdown,
          "AimingSlowdownPatch -- the aim speed penalty that would be skipped")

proc reportEffect(name, state: string; hits: int) =
  if armed(state):
    if hits > 0:
      success "  " & name & ": " & state & " -- applied " & $hits & " times"
    else:
      warn "  " & name & ": " & state & " -- but it never applied; the " &
           "method it works through is not being reached on this build"
  else:
    info "  " & name & ": " & state

proc reportWatch() =
  if gWatchNames.len > 0:
    info "Classic Movement target verification, one minute into the world:"
    var live = 0
    for i in 0 ..< gWatchNames.len:
      if gWatchCounts[i] > 0:
        inc live
        success "  " & gWatchNames[i] & " fired " & $gWatchCounts[i] & " times"
      else:
        warn "  " & gWatchNames[i] & " never fired -- patched, but the game " &
             "does not reach it; the name is stale for this build"
    info "  " & $live & " of " & $gWatchNames.len & " targets confirmed live"
  info "Classic Movement, what was actually applied:"
  reportEffect("SmoothSpeedFix", gSmoothState, gSmoothWrites)
  info "    driven by " & gDriverState
  if gDriverIsEveryMain:
    if gDriverFirings > 0:
      info "    (everyMain fired " & $gDriverFirings & " times, on thread " &
           $gDriverThreadId & " -- compare that with the drain thread in " &
           "aowlspt.host::main_thread; a mismatch would mean the write is " &
           "not where this mod claims it is)"
    else:
      warn "    (everyMain armed and never fired: the host queued it and its " &
           "drain has not run, so nothing has been written at all)"
  let ns = smoothCostNs()
  if ns >= 0'i64:
    info "    (measured " & $ns & " ns per frame over " & $gSmoothSamples &
         " frames, on this client's own clock -- docs/PERF.md's numbers are " &
         "from a stand-in runtime and are not this)"
  else:
    info "    (no cost measured: the write never ran, so there was nothing " &
         "to time)"
  reportEffect("BushSpeedStateRemover", gBushState, gBushSuppressed)
  if gBushSeen > 0:
    info "    (" & $gBushSeen & " obstacles entered, " & $gBushSuppressed &
         " of them swamp-limited)"
  reportEffect("AimingSlowdownPatch", gAimState, gAimSuppressed)
  reportEffect("OldTiltingFix", gTiltState, gTiltRedirects)
  # What one redirect cost in *this* client, on the path it actually took.
  # Reported rather than asserted, and reported with which path it was, because
  # the two differ by roughly a hundredfold and a bare number would not say
  # which one is being quoted.
  let tiltNs = tiltCostNs()
  if tiltNs >= 0'i64:
    info "    (" & $int(tiltNs) & " ns per redirect on the typed path, " &
         "measured over " & $gTiltTypedSamples & " firings in this client)"
  elif gTiltTyped:
    info "    (typed path armed; nothing measured, so the hook never fired)"
  reportEffect("RemoveJitteryRotationPatch", gJitterState, gJitterSuppressed)
  if gJitterLet > 0 or gJitterSuppressed > 0:
    info "    (" & $gJitterSuppressed & " suppressed for the player, " &
         $gJitterLet & " let through for AI)"
  # Which shape answered, not merely that one did. See `contextIsAi`.
  if gJitterHow.len > 0:
    info "    (the player/AI split was read from " & gJitterHow & ")"
  elif gJitterSuppressed > 0 or gJitterLet > 0:
    warn "    (the split was decided but nothing recorded how, which should " &
         "be impossible -- gJitterHow is set on the same branch that decides)"
  if gTiltBoxedRefused > 0:
    warn "    (OldTiltingFix: " & $gTiltBoxedRefused & " firings where the " &
         "boxed LegacySmoothTilt could not be reached and the original was " &
         "let through, so the lean still ramps)"
  info "  not ported, and why -- re-checked against what the host does " &
       "today rather than what it did when the port was written: " &
       "**GetNewState** is the only permanent one, and it is permanent for a " &
       "reason no ABI touches -- its replacement states are C# subclasses and " &
       "nothing native declares a managed type. InertiaSmoothTilt and " &
       "PlayerAnimatorSetDeltaRotation are **ported**: what blocked them was " &
       "the price of reaching `this` through a host Handle, ~1 us per " &
       "movement context per frame -- " & frameShareText(1000) & ", which " &
       "this file spent months calling 2.4 ms a frame and fifteen percent -- " &
       "and ABI revision 3 turns that handle into " &
       "an address in 8 ns. The one piece still missing is the second half of " &
       "RemoveJitteryRotationPatch -- upstream's " &
       "TRANSFORM_ROTATION_LERP_SPEED constant, which this port cannot " &
       "confirm against a running build and will not invent. See the table in " &
       "the module comment."

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------
#
#     aowl run mods/classicmovement          # --side sim
#
# What this can and cannot establish, said before the output rather than after.
#
# **It cannot bind against Tarkov.** `aowlspt-sim` is a managed host with no
# `GameAssembly.dll` in the process, so `openIl2Cpp()` correctly finds nothing
# and every binding refuses with that reason. That is the *expected* result and
# it is still worth printing, because the shape of the report -- one line per
# member, naming the member and the reason -- is the same shape the client half
# prints in a raid, and a reader who has seen it here knows how to read it
# there.
#
# **It can bind against a runtime you point it at.** `selfTestRuntime` in
# config.json is a path to any `GameAssembly.dll` -- `tests/mockil2cpp`'s
# stand-in, or a real client's, from a copy of the install. With one, the
# by-name half of the report becomes a real answer about a real build, offline,
# without launching anything.
#
# **It measures the per-frame path either way.** `applySmoothSpeed` is called
# in a loop and timed on `perfCounter`, the same clock the bindings report their
# own cost on. With nothing bound that measures the guard -- one bool test and a
# return -- which is the floor the effect costs when it is switched off, and is
# a number worth having.

proc reportBinding(label: string; b: Binding) =
  if b.ok:
    success "  fast     " & label & " -- " & b.why & " (bind " & $b.bindNs &
            " ns)"
  else:
    warn "  REFUSED  " & label & " -- " & b.why

proc reportField(label: string; f: FieldBinding) =
  if f.ok:
    success "  field    " & label & " -- " & f.why & " (bind " & $f.bindNs &
            " ns)"
  else:
    warn "  REFUSED  " & label & " -- " & f.why

proc probeMember(owner, member: string; argc: int) =
  ## The name half of a member that is only ever *bound* against a live object.
  ##
  ## This is deliberately not a binding. `get_MovementContext` is bound at
  ## runtime against the class the player object actually is, which may be a
  ## subclass this file cannot name -- so what a name check can honestly say is
  ## "the type exists and declares a member of this name and arity, and here is
  ## the signature the runtime reports for it". A subclass override would not
  ## show up here at all, and saying so is the point.
  var params: seq[string] = @[]
  var ret = ""
  if signatureOf(owner, member, argc, params, ret):
    info "  name ok  " & owner & "::" & member & " " & describeSig(params, ret) &
         " -- bound at runtime against the object's own class"
  else:
    warn "  NO NAME  " & owner & "::" & member & "/" & $argc &
         " is not declared on that type (a subclass may still declare it; " &
         "the runtime binding is the one that decides)"

proc probeField(owner, member: string) =
  ## Same, for a field. `bindField` by name is used here only as a probe: the
  ## client half binds these against the live context with `bindFieldOn`.
  let f = bindField(rt, owner, member)
  reportField(owner & "::" & member & " (name probe)", f)

# ---------------------------------------------------------------------------
# The three guards, exercised rather than described
# ---------------------------------------------------------------------------
#
# Every one of these was rewritten today, and two of them were rewritten
# because they *could not fail* before: `classifyType` answered `fkPtr` for
# every resolvable non-primitive, and `bindFieldOn` decided staticness from an
# offset. A guard nobody has watched refuse is a guard nobody has tested, and
# describing one in a comment is not the same as watching it work.
#
# `tests/mockil2cpp` happens to carry exactly the three shapes needed, and not
# by accident -- it was built to carry the traps:
#
#   * `EFT.Player::SpawnCount` is **static** and sits at offset 16 of the
#     class's static block; `EFT.Player::Health` is an instance `Single` at
#     offset 16 of an object. An offset test cannot tell them apart, and the
#     wrong answer is `1120403456` rather than a refusal.
#
#     That number used to read `1091567616`, which is `9.0f`. The stand-in
#     initialises `Health` to `100.0f`, and `100.0f` is `0x42C80000` --
#     1120403456. Nothing in this file's path damages the player, so 9.0 was
#     never a value this guard could produce; it was a plausible-looking
#     constant somebody wrote down. It is asserted now rather than quoted: the
#     check below binds `Health`, re-reads the same offset with the kind forced
#     to `fkI32` -- which is exactly what the offset-guessing bug did -- and
#     compares. A wrong constant here goes red instead of reading fine.
#     (`tests/mockil2cpp/mockil2cpp.c` carries the same 1091567616 in its own
#     comment; that file is not this mod's to edit and the mismatch is noted
#     rather than fixed.)
#   * `UnityEngine.Vector3` is a 12-byte value type, which is what a parameter
#     the host reports as `{"valueType":"..."}` looks like from here.
#   * `EFT.MovementContext::Drift(Single, Single)` is `LegacySmoothTilt`'s
#     shape exactly, so a binding that states the wrong register classes for
#     it is the same mistake this mod could make in a raid.
#
# With no `selfTestRuntime` there is no runtime to ask and every check below
# reports "not checked" rather than passing. That distinction is the point: a
# check that passes because the thing it checks never happened is worse than
# no check, and this is the file that says so about everything else.

proc guardOk(what: string) =
  success "  guard ok " & what

proc guardBad(what: string) =
  error "  GUARD    " & what

proc checkGuards(): int =
  ## How many guards answered wrongly. Zero on a runtime that has the shapes;
  ## zero and a warning on one that does not.
  result = 0
  if not rtOpen:
    warn "  guards not checked: no runtime is bound, so there is nothing to " &
         "ask. Set selfTestRuntime to exercise them."
    return

  # --- 1. the placeholder gate, which could not fail until today ------------
  #
  # `argsUsable` takes declared type names, so it can be asked directly rather
  # than through a method that happens to have the right parameter.
  var why = ""
  var wide: seq[string] = @[]
  wide.add "UnityEngine.Vector3"
  if findClass(rt, "UnityEngine.Vector3") == nil:
    warn "  guard skipped: this runtime has no UnityEngine.Vector3, so the " &
         "placeholder gate has nothing wide to refuse"
  elif argsUsable(wide, why):
    guardBad "argsUsable accepted a UnityEngine.Vector3 parameter. The host " &
             "reports one as {\"valueType\":\"...\"}, so a hook reading it " &
             "would read a placeholder. This is the exact answer the old " &
             "classInstanceSize > 24 test gave on a runtime that reports " &
             "payload sizes."
    inc result
  else:
    guardOk "argsUsable refuses a UnityEngine.Vector3 parameter -- " & why

  var narrow: seq[string] = @[]
  narrow.add "System.Single"
  narrow.add "System.Boolean"
  why = ""
  if not argsUsable(narrow, why):
    guardBad "argsUsable refused (Single, Boolean), which every one of this " &
             "mod's own hooks passes: " & why
    inc result
  else:
    guardOk "argsUsable accepts (System.Single, System.Boolean)"

  if findClass(rt, "EFT.EPhysicalCondition") != nil:
    var en: seq[string] = @[]
    en.add "EFT.EPhysicalCondition"
    why = ""
    if not argsUsable(en, why):
      guardBad "argsUsable refused an enum parameter, which the host reports " &
               "as its number: " & why
      inc result
    else:
      guardOk "argsUsable accepts an enum parameter (it arrives as a number)"

  # --- 2. the static-field guard on bindFieldOn -----------------------------
  #
  # A live `EFT.Player` is reached the way the frame path reaches one, because
  # the guard is about a *live* object's class rather than about a name.
  let bw = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  var player = nullPtr()
  if bw.ok:
    var a = noArgs()
    let w = callPtr(bw, nullPtr(), a)
    if w != nil:
      var mp = noObjBind()
      var none = noKinds()
      if ensureCall(mp, w, "get_MainPlayer", none, fkPtr):
        a.reset()
        player = callPtr(mp.b, w, a)
  if player == nil:
    warn "  guard skipped: no live EFT.Player on this runtime, so the " &
         "static-field guard has nothing to refuse"
  else:
    var owner = ""
    let stat = bindFieldOn(rt, player, "SpawnCount", owner)
    if stat.ok:
      guardBad "bindFieldOn bound the static field SpawnCount as an " &
               "instance field at offset " & $stat.offset & ". Its offset is " &
               "into the class's static block; an instance read of it " &
               "answers whatever field of the object sits there -- on this " &
               "runtime, Health's bits as an integer."
      inc result
    else:
      guardOk "bindFieldOn refuses the static SpawnCount -- " & stat.why
    owner = ""
    let inst = bindFieldOn(rt, player, "Health", owner)
    if not inst.ok:
      guardBad "bindFieldOn refused the instance field Health, which is the " &
               "same offset the static one occupies -- the guard is refusing " &
               "by offset rather than by the runtime's answer: " & inst.why
      inc result
    elif inst.kind != fkF32:
      guardBad "bindFieldOn classified Health as " & describe(inst.kind) &
               " rather than a float"
      inc result
    else:
      guardOk "bindFieldOn binds the instance Health at the same offset -- " &
              inst.why

  # --- 3. the stated-kinds check on ensureCall ------------------------------
  #
  # `Drift(Single, Single) -> void` is `LegacySmoothTilt`'s shape, so asserting
  # two integers for it is the mistake this mod could make in a raid.
  let bc = bindMethod(rt, TyCtx, "get_Instance", 0)
  var ctx = nullPtr()
  if bc.ok:
    var a = noArgs()
    ctx = callPtr(bc, nullPtr(), a)
  if ctx == nil:
    warn "  guard skipped: no live " & TyCtx & " on this runtime, so the " &
         "stated-kinds check has nothing to disagree with"
  else:
    var right = noObjBind()
    if not ensureCall(right, ctx, "Drift", [fkF32, fkF32], fkVoid):
      guardBad "ensureCall refused Drift(Single, Single) -> void stated " &
               "correctly: " & right.why
      inc result
    else:
      guardOk "ensureCall accepts Drift stated as (float, float) -> void"
    var wrong = noObjBind()
    if ensureCall(wrong, ctx, "Drift", [fkI32, fkI32], fkVoid):
      guardBad "ensureCall accepted Drift stated as (int32, int32) -> void. " &
               "Two floats passed in general-purpose registers reach the " &
               "method as whatever those registers held, and the call does " &
               "not crash -- it leans by an arbitrary amount."
      inc result
    else:
      guardOk "ensureCall refuses Drift stated as (int32, int32) -- " &
              wrong.why

# ---------------------------------------------------------------------------
# The answers, asserted rather than printed
# ---------------------------------------------------------------------------
#
# Everything above this line either binds something and reports what it got, or
# watches a guard refuse. What it did not do is **assert an answer** -- and the
# four things fixed today were all wrong answers sitting in comments and state
# lines where nothing could disagree with them: a per-second cost labelled per
# frame, a float's bit pattern that was the wrong float's, a log line claiming
# to say which of two shapes answered when the code only knew that one had, and
# a config key read by this file and absent from the file it is read from.
#
# Each check below is written so that it goes red against the code as it was.
# Two of them take deliberate care not to pass vacuously, which is the failure
# this file keeps warning about: the handler checks assert that the payload was
# really parsed *before* asserting what the handler decided, so "it did not
# suppress" cannot be earned by "it never got that far".
#
# **They were watched red before they were left green.** Every fix in this
# commit was backed out -- `perFrameNs` multiplied by 60 again, `HealthBits` set
# to 1091567616, `contextIsAi` recording "one of them" the way a `var bool`
# could, `onInertiaSmoothTiltBoxed` suppressing unconditionally, the
# `selfTestDataDir` key deleted from config.json -- and the self-test failed
# with six wrong answers and a non-zero exit. Two of them are worth quoting,
# because they reproduce the old prose exactly and so confirm the diagnosis
# rather than merely disagreeing with it:
#
#     ANSWER  the frame-budget sum answers 2400000 ns a frame and 14400
#             thousandths of a percent for forty firings at 1 us
#     ANSWER  ... address 5280 us a frame ...
#
# 2.4 ms and 14.400% are the "2.4 ms a frame" and "fifteen percent" this file
# carried, and 5280 us is its "5.3 ms a frame". The backed-out code prints the
# old numbers, which is the evidence that the old numbers were this sum with
# `* 60` in it.

proc answerOk(what: string) =
  success "  answer   " & what

proc answerBad(what: string) =
  error "  ANSWER   " & what

proc mockPlayer(): Il2CppPtr =
  ## The stand-in's live `EFT.Player`, by the route the frame path takes.
  result = nullPtr()
  let bw = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  if not bw.ok: return
  var a = noArgs()
  let w = callPtr(bw, nullPtr(), a)
  if w == nil: return
  var mp = noObjBind()
  var none = noKinds()
  if not ensureCall(mp, w, "get_MainPlayer", none, fkPtr): return
  a.reset()
  result = callPtr(mp.b, w, a)

proc mockContext(): Il2CppPtr =
  result = nullPtr()
  let bc = bindMethod(rt, TyCtx, "get_Instance", 0)
  if not bc.ok: return
  var a = noArgs()
  result = callPtr(bc, nullPtr(), a)

const
  # A hook payload of the shape the host builds, written out here so the
  # handle-only handlers can be run without a host that has hooks.
  BoxedPayload = "{\"this\":{\"handle\":3,\"type\":\"EFT.MovementContext\"}," &
                 "\"args\":[0.25,0.5]}"
  StaticPayload = "{\"this\":null,\"args\":[0.25,0.5]}"
  HealthBits = 1120403456
    ## `100.0f` as an `int32`. See the guards' comment for what this used to be.

proc checkAnswers(): int =
  ## How many answers came back wrong. Zero is the only acceptable number.
  result = 0

  # --- 1. the frame budget, which used to be prose and was off by sixty -----
  #
  # Asserted against the exact figure the old sentences were making a decision
  # on: one microsecond a firing, forty firings a frame.
  if perFrameNs(1000) != 40_000 or frameShareMilli(1000) != 240:
    answerBad "the frame-budget sum answers " & $perFrameNs(1000) &
              " ns a frame and " & $frameShareMilli(1000) &
              " thousandths of a percent for forty firings at 1 us. It " &
              "should be 40000 ns and 240 (0.240%). The old prose said " &
              "2.4 ms and fifteen percent, which is this same work measured " &
              "over a second and then divided by a frame."
    inc result
  else:
    answerOk "forty contexts at 1 us is " & frameShareText(1000) &
             " -- the sentence this replaced said 2.4 ms a frame and " &
             "fifteen percent, which was per second over per frame"
  # And the claim the two overturned refusals now rest on, stated as a bound
  # rather than as a figure: every shape this hook can take is under one
  # percent of a frame, so none of them is a performance reason to refuse.
  if frameShareMilli(TiltAddressNs) >= 1000 or
     frameShareMilli(TiltBoxedNs) >= 1000 or
     frameShareMilli(IsAiBoxedNs) >= 1000:
    answerBad "one of the three hook shapes costs a percent of a frame or " &
              "more, which would make the refusals this file withdrew " &
              "correct after all: address " &
              frameShareText(TiltAddressNs) & "; boxed " &
              frameShareText(TiltBoxedNs) & "; boxed IsAI " &
              frameShareText(IsAiBoxedNs)
    inc result
  else:
    answerOk "every hook shape is under one percent of a frame -- typed " &
             frameShareText(TiltTypedNs) & "; address " &
             frameShareText(TiltAddressNs) & "; boxed " &
             frameShareText(TiltBoxedNs) & "; boxed IsAI " &
             frameShareText(IsAiBoxedNs)

  # --- 2. the wrong-answer constant in the guards' comment ------------------
  #
  # Not quoted: produced. `Health` is bound properly, then the same offset is
  # re-read with the kind forced to `fkI32`, which is the read an offset-guessing
  # static/instance test would have done. Whatever comes out is the number the
  # comment must name.
  if not rtOpen:
    warn "  answers about the runtime not checked: nothing is bound"
  else:
    let player = mockPlayer()
    if player == nil:
      warn "  no live EFT.Player, so the Health bit pattern is not checked"
    else:
      var owner = ""
      let hb = bindFieldOn(rt, player, "Health", owner)
      if not hb.ok or hb.kind != fkF32:
        answerBad "Health did not bind as a float, so the bit pattern the " &
                  "guards' comment names cannot be produced: " & hb.why
        inc result
      else:
        var asInt = hb
        asInt.kind = fkI32
        let bits = int(readInt32(asInt, player))
        if bits != HealthBits:
          answerBad "reading Health's offset as an int32 -- the exact " &
                    "mistake the static-field guard exists to prevent -- " &
                    "answers " & $bits & ", and the guards' comment names " &
                    $HealthBits & ". One of the two is wrong."
          inc result
        else:
          answerOk "Health read as an int32 is " & $bits &
                   ", which is what the guards' comment names (the comment " &
                   "used to say 1091567616, which is 9.0f)"

    # --- 3. contextIsAi says *which* shape answered ------------------------
    #
    # Two runtimes' worth of shape in one stand-in: `EFT.Player` really does
    # declare `get_IsAI` as a compiled property, and `EFT.MovementContext`
    # declares no `IsAI` at all. The second is the branch that matters most,
    # because "neither answered" must not read as "not AI".
    if player == nil:
      warn "  contextIsAi not checked against a property: no live EFT.Player"
    else:
      var how = ""
      discard contextIsAi(player, how)
      if how.len == 0:
        answerBad "contextIsAi found nothing on EFT.Player, which declares " &
                  "get_IsAI as a compiled property in the stand-in"
        inc result
      elif how != IsAiViaProperty:
        answerBad "contextIsAi resolved IsAI on EFT.Player but recorded it " &
                  "as \"" & how & "\" rather than as the property it " &
                  "actually used"
        inc result
      else:
        answerOk "contextIsAi names the shape it read: " & how
    let ctx = mockContext()
    if ctx == nil:
      warn "  contextIsAi not checked against a type with no IsAI: no live " &
           TyCtx
    else:
      var how = ""
      let ai = contextIsAi(ctx, how)
      if how.len != 0:
        answerBad "contextIsAi claims to have read IsAI off " & TyCtx &
                  " as \"" & how & "\"; the stand-in declares neither a " &
                  "property nor a field of that name there"
        inc result
      elif ai:
        answerBad "contextIsAi answered true with nothing to read it from"
        inc result
      else:
        answerOk "contextIsAi records \"\" -- not a guess -- on a type with " &
                 "neither get_IsAI nor IsAI, and onDeltaRotation treats that " &
                 "as carry-on rather than as \"not AI\""
    # The field branch is **not** exercised: no type in the stand-in carries
    # `IsAI` as a field, so nothing here has ever watched that string come
    # back. Said rather than papered over.
    info "  (the field branch of contextIsAi is unexercised -- the stand-in " &
         "has no type with an IsAI field, and inventing one to test against " &
         "would be testing the invention)"

  # --- 4. the handle-only handlers do not suppress what they cannot replace -
  #
  # `aowlspt-sim` has no IL2CPP and no boxed `call` into a game, so both boxed
  # reads below are guaranteed to fail -- which is exactly the case worth
  # asserting, because the failure mode is a lean frozen mid-tilt or every
  # bot's rotation suppressed.
  #
  # The payload is parsed first and asserted on, so that a handler which bailed
  # out at the front door cannot be mistaken for one that made the decision.
  var okA = false
  let firstArg = argFloat(BoxedPayload, 0, okA)
  if thisHandle(BoxedPayload) != 3'u64 or not okA or firstArg < 0.2 or
     firstArg > 0.3:
    answerBad "the synthetic hook payload does not parse -- handle " &
              $int(thisHandle(BoxedPayload)) & ", first argument " &
              $firstArg & ". Every handler check below it would then be " &
              "passing because the handler stopped at the front door."
    inc result
  else:
    answerOk "the synthetic payload parses: this is handle 3 and argument 0 " &
             "is 0.25, so the handler checks below reach the decision"
    let tilt = onInertiaSmoothTiltBoxed(TyCtx & "::InertiaSmoothTilt",
                                        BoxedPayload)
    if tilt.stop:
      answerBad "onInertiaSmoothTiltBoxed suppressed InertiaSmoothTilt after " &
                "a LegacySmoothTilt call that could not have succeeded on " &
                "this host. In a raid that is a lean frozen at whatever " &
                "angle it was at."
      inc result
    elif gTiltBoxedRefused <= 0:
      answerBad "onInertiaSmoothTiltBoxed carried on without counting a " &
                "refused redirect, so it did not reach the boxed call at all"
      inc result
    else:
      answerOk "onInertiaSmoothTiltBoxed carries on when the boxed " &
               "LegacySmoothTilt refuses, and counts it (" &
               $gTiltBoxedRefused & ")"
    let jitter = onDeltaRotationBoxed(
      TyCtx & "::PlayerAnimatorSetDeltaRotation", BoxedPayload)
    if jitter.stop:
      answerBad "onDeltaRotationBoxed suppressed the rotation without ever " &
                "reading IsAI, which suppresses it for every bot too"
      inc result
    else:
      answerOk "onDeltaRotationBoxed carries on when neither boxed IsAI read " &
               "answers"
    let staticCall = onInertiaSmoothTiltBoxed(TyCtx & "::InertiaSmoothTilt",
                                              StaticPayload)
    if staticCall.stop:
      answerBad "onInertiaSmoothTiltBoxed suppressed a firing whose `this` " &
                "is null"
      inc result
    else:
      answerOk "onInertiaSmoothTiltBoxed carries on for a null `this`"

  # --- 5. the setting this file reads is in the file it reads --------------
  if not setting("selfTestDataDir").ok:
    answerBad "classicmovement reads selfTestDataDir and config.json does " &
              "not declare it. A setting nobody can find is a setting nobody " &
              "can use."
    inc result
  else:
    answerOk "selfTestDataDir is declared in config.json, with the " &
             "//-prefixed sibling comment the other keys have"

proc simSelfTest(): Status =
  info "Classic Movement self-test (--side sim)"

  # --- the server half, which needs no game at all.
  let doc = configDocument()
  let text = done(doc).text
  if len(doc) != 7:
    error "  the served config document has " & $len(doc) &
          " members; upstream's record has 7 and a client deserialising " &
          "into it would fault on a missing one"
    return ErrGeneric
  success "  route document " & ConfigRoute & " -- " & $len(doc) &
          " members, " & $text.len & " bytes"
  info "    " & text

  # --- the client half.
  let wanted = selfTestRuntime(setting("selfTestRuntime").asText(""))
  if wanted.refusal.len > 0:
    warn "  " & wanted.refusal
  let runtimePath = wanted.path

  if runtimePath.len > 0:
    rt = openIl2Cpp(runtimePath)
    if not rt.loaded:
      warn "  selfTestRuntime " & runtimePath & " could not be loaded " &
           "(error " & $rt.lastError & "); falling back to the process"
    else:
      # Out of process the runtime is loaded but not *started*: no domain, no
      # assemblies, so `findClass` walks an empty list and every lookup misses
      # for a reason that reads like a rename. `il2cpp_init` is what starts it,
      # and `tools/il2cppprobe` documents the caveat this inherits -- on a real
      # client the metadata is encrypted and decrypted during the game's own
      # startup, so this may well refuse. It refusing is a real answer and is
      # printed as one; in the game the runtime is already up and none of this
      # runs.
      rtOpen = true
      let wantedDd = selfTestDataDir(setting("selfTestDataDir").asText(""))
      if wantedDd.refusal.len > 0:
        warn "  " & wantedDd.refusal
      if wantedDd.path.len > 0:
        rt.setDataDir(wantedDd.path)
      if rt.init("aowl-classicmovement-selftest") == nil:
        warn "  " & runtimePath & " loaded but il2cpp_init returned no " &
             "domain, so it has no type universe to search. That is the " &
             "expected answer for a real client out of process (the metadata " &
             "is decrypted during the game's own startup); every binding " &
             "below will refuse with 'no such type'."
      else:
        info "  bound and started " & runtimePath & " for the binding report"
  if not rtOpen:
    if not openRuntime():
      warn "  no IL2CPP runtime in this process -- aowlspt-sim is a managed " &
           "host and GameAssembly.dll is not loaded. Every binding below " &
           "will refuse for that reason, which is the correct answer here. " &
           "Set AOWLSPT_SELFTEST_RUNTIME, or \"selfTestRuntime\" in " &
           "config.json, to an ABSOLUTE path to a GameAssembly.dll to get a " &
           "real report offline; `aowl run` sets it to the stand-in runtime."

  info "  bindings, in the order the frame path takes them:"
  discard bindSmoothStatics()
  reportBinding("GameWorld::get_Instance (static, by name)", bWorld)
  probeMember(TyGameWorld, "get_MainPlayer", 0)
  probeMember(TyPlayer, "get_MovementContext", 0)
  probeField(TyCtx, "_player")
  probeField(TyCtx, "SmoothedCharacterMovementSpeed")
  probeField(TyPlayer, "ClampedSpeed")
  probeMember(TyPlayer, "get_ClampedSpeed", 0)

  info "  the guards, exercised rather than described:"
  let badGuards = checkGuards()
  if badGuards > 0:
    error "  " & $badGuards & " guard(s) answered wrongly; every one of them " &
          "is a wrong number handed to the game rather than a refusal"
    return ErrGeneric

  info "  the answers, asserted rather than printed:"
  let badAnswers = checkAnswers()
  if badAnswers > 0:
    error "  " & $badAnswers & " answer(s) are wrong. Every one of these was " &
          "a number or a claim sitting in a comment where nothing could " &
          "disagree with it, which is how the last four got there."
    return ErrGeneric

  info "  refusals that remain, with the reason each one actually has:"
  info "    GetNewState -- permanent. Its replacement states are C# " &
       "subclasses and nothing native can declare a managed type, so there " &
       "is nothing to answer the suppression *with*. Its old second reason " &
       "-- that the EPlayerState argument would be handed to the collector " &
       "as an object -- is fixed: the host asks the runtime now and an enum " &
       "arrives as its number."
  # These two lines used to say that InertiaSmoothTilt and
  # PlayerAnimatorSetDeltaRotation were blocked on the cost of turning a host
  # Handle into a pointer. That has been false since ABI revision 3 and the
  # module comment has said so for a while; this block was not updated with it,
  # so `aowl run` was printing a refusal for two effects the client half arms.
  # A stale refusal is worse than no refusal: it is the file disagreeing with
  # itself in the one place a reader goes to find out what is missing.
  info "    InertiaSmoothTilt -- **ported**. thisPointer turns the payload's " &
       "`this` into an address in ~8 ns, so the redirect into " &
       "LegacySmoothTilt is a bound non-virtual call on the context the hook " &
       "fired for. On a revision-4 host it arms as a typed hook at ~25 ns a " &
       "firing; on revision 3 it arms on the JSON path at ~2.2 us, and the " &
       "effect's state line says which."
  info "    below revision 3 both of these used to refuse, on the grounds " &
       "that a boxed call per context per frame was 2.4 ms a frame with " &
       "forty bots. 2.4 ms is per second: per frame it is " &
       frameShareText(1000) & ". Measured properly the boxed redirect is " &
       frameShareText(TiltBoxedNs) & " and the boxed IsAI read is " &
       frameShareText(IsAiBoxedNs) & ", so **both refusals are withdrawn** " &
       "and both effects arm on a handle-only path instead. Neither has ever " &
       "run: every host here is revision 4."
  info "    PlayerAnimatorSetDeltaRotation -- **half ported**. The player/AI " &
       "split is done (get_IsAI as a property, then IsAI as a field, off the " &
       "address). What is still out is upstream's " &
       "TRANSFORM_ROTATION_LERP_SPEED constant, which this port cannot " &
       "confirm against a running build and will not invent -- a refusal " &
       "about a *value*, not about a capability."

  # --- the cost of the per-frame path, on this machine's own clock.
  const Iterations = 20000
  let t0 = perfCounter()
  var i = 0
  while i < Iterations:
    applySmoothSpeed()
    inc i
  let per = nanosBetween(t0, perfCounter()) div int64(Iterations)
  if gSmoothWrites > 0:
    success "  per-frame cost " & $per & " ns over " & $Iterations &
            " calls, " & $gSmoothWrites & " of which wrote"
  else:
    info "  per-frame cost " & $per & " ns over " & $Iterations &
         " calls, none of which reached a write (no world). That is the " &
         "guard: what the effect costs when there is nothing to do."
  info "  for comparison, docs/PERF.md measures one boxed host call at " &
       "950-1235 ns and one bound call at 6-10 ns; the whole chain this " &
       "replaces was six boxed calls and a boxed field write, about 6 us"
  result = Ok

proc clientLoad(): Status =
  # Upstream's client asked the server for this over
  # `/OldTarkovMovement/GetConfig`, because the two halves were separate mods
  # with separate install directories and only the server one had the file.
  # Here they are one binary with one `config.json`, and a client mod cannot
  # make an HTTP request anyway -- so the client half reads the same file the
  # route serves, and the route stays for compatibility with an external client.
  info "config read from config.json directly (one binary, one config); " &
       ConfigRoute & " still serves the same document to anything else"
  info "  NoInertia=" & $cfgNoInertia & " QuickTilting=" & $cfgQuickTilting &
       " DoBushesSlowYouDown=" & $cfgDoBushesSlowYouDown &
       " BotsUseOldMovement=" & $cfgBotsUseOldMovement &
       " DoesAimingSlowYouDown=" & $cfgDoesAimingSlowYouDown &
       " RemoveJitteryRotation=" & $cfgRemoveJitteryRotation
  if cfgBotsUseOldMovement:
    info "BotsUseOldMovement only mattered inside the GetNewState " &
         "replacement, which is not expressible here; it is carried in " &
         "config and on the wire. Of what this port does apply, the bush " &
         "and aiming suppressions already reach every movement context, and " &
         "SmoothSpeedFix reaches only the local player's"
  Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  success ModName & " " & ModVersion & " loaded on " & hostName()
  case side()
  of sideServer: result = serverLoad()
  of sideClient: result = clientLoad()
  of sideSim: result = simSelfTest()
  else:
    info "neither client, server nor sim; config parsed, nothing installed"
    result = Ok

proc onUpdate(elapsedMs: int64): Status =
  if side() != sideClient:
    return Ok
  gElapsedMs = gElapsedMs + elapsedMs
  if world.ready():
    onWorldReady()
    gElapsedMs = 0
  # A minute is long enough that a method reached only by leaning, or only by
  # entering a bush, has had its chance -- so a zero at this point means
  # "never", which is the answer worth logging.
  if not gReported and gElapsedMs > 60_000 and world.fired:
    gReported = true
    reportWatch()
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideServer, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
