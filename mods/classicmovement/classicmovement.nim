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
##   | `SmoothSpeedFix` on `::ManualUpdate` | **ported** — the private `_player` field and `SmoothedCharacterMovementSpeed` are both bound by offset and written every frame on the fast path |
##   | `BushSpeedStateRemover` on `::OnEnterObstacle` | **ported** — `hookArgs` reads the obstacle argument, and `stopVoid` suppresses the original when it carries the swamp speed limit |
##   | `AimingSlowdownPatch` on `::SetAimingSlowdown` | **ported** — `hookArgs` + `stopVoid`, gated on `DoesAimingSlowYouDown` exactly as upstream gates it |
##   | `StateReplacer` on `::GetNewState` | **not ported** — see below |
##   | `OldTiltingFix` on `::InertiaSmoothTilt` | **not ported** — see below |
##   | `RemoveJitteryRotationPatch` on `::PlayerAnimatorSetDeltaRotation` | **not ported** — see below |
##
## ### The one capability three of them are all waiting on
##
## **A hook is not told which instance it fired on.** `hookArgs` hands the
## handler the method's *declared arguments*; `this` is in RCX and is not among
## them. Every upstream patch here is `Prefix(MovementContext __instance, ...)`,
## and three of them cannot do their work without knowing whose movement
## context is being updated. Where an effect only ever concerned the local
## player, this port gets the instance the other way — `GameWorld.Instance` →
## `MainPlayer` → `MovementContext` — and that is what makes `SmoothSpeedFix`
## work. Where the effect has to distinguish one caller from another, there is
## no way round it and the patch is left out.
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
##   (A second, smaller blocker sits behind it: `EPlayerState` is an enum, and
##   the host's argument decoder classifies anything that is not a primitive or
##   a string as a *reference* — so asking for this method's arguments would
##   have it call `il2cpp_gc_handle_new` on a register holding a small integer.
##   `argsSafe` below refuses on exactly that ground, which is why this mod
##   would not have installed the hook even if the rest were possible.)
##
## * **`InertiaSmoothTilt` → `LegacySmoothTilt`.** The redirect itself is
##   trivial — two floats in, suppress, call the other method — and both names
##   are confirmed live by the counters below. What is missing is the instance
##   to call `LegacySmoothTilt` *on*. Every movement context in the raid calls
##   `InertiaSmoothTilt`, so redirecting them all onto the local player's
##   context would apply your lean angle from a bot's arguments. That is not a
##   near-miss, it is the wrong object, so it is left out.
##
## * **`PlayerAnimatorSetDeltaRotation`.** Upstream suppresses it for the
##   player and lets AI through, reading `__instance.IsAI` to tell them apart.
##   Without the instance there is no way to tell them apart, and suppressing
##   for everything would take the rotation animation off every bot in the
##   raid. Its second half — writing
##   `EFTHardSettings.Instance.TRANSFORM_ROTATION_LERP_SPEED` — is reachable
##   (`EFTHardSettings` has a static `Instance`, and a field write by name is
##   an ordinary call now), but this port could not verify upstream's constant
##   against a running build, and inventing a number for a lerp speed is
##   exactly the kind of approximation the rest of this file refuses. Both
##   halves are left out and `RemoveJitteryRotation` does nothing.
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
import aowlspt/il2cpp   # the runtime's own metadata, for signature checks
import aowlspt/fast     # bind once, call in ~10 ns — docs/PERF.md

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

proc argsSafe(params: seq[string]): bool =
  ## Whether it is safe to ask the host for this method's arguments.
  ##
  ## A guard, not a nicety. The host builds the argument array from the
  ## declared type name: primitives and strings it formats, and **everything
  ## else it treats as a reference** -- it takes the register, calls
  ## `il2cpp_gc_handle_new` on it and reports a handle. For an enum such as
  ## `EPlayerState`, or a struct, that register holds a small integer or float
  ## bits, and handing it to the collector is not a wrong answer, it is a crash
  ## inside a game method.
  ##
  ## `classifyType` asks the same question the fast path asks: a primitive or a
  ## reference is a kind, and a value type -- struct or enum -- is `fkNone`. So
  ## a method with any unclassifiable parameter gets no argument hook from this
  ## mod, and the log names the type that stopped it.
  result = true
  for i in 0 ..< params.len:
    if classifyType(rt, params[i]) == fkNone:
      return false

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

proc armed(state: string): bool =
  ## An effect state reads "armed...", "refused: ..." or "off (...)". Only the
  ## first means a hook was installed, and that is the question every caller of
  ## this actually has.
  result = state.len >= 5 and state.substr(0, 4) == "armed"

# Bound once, from `onWorldReady`. Declared bare and assigned from a proc: a
# nimony `--app:lib` global initialised by a *call* is silently left zeroed,
# and a zeroed `Binding` has `ok = false` -- it fails safe, but it never
# becomes true either. fast.nim's rule 1.
var bWorld: Binding
var bMainPlayer: Binding
var bCtxOf: Binding
var fCtxPlayer: FieldBinding
var fSmoothed: FieldBinding
var fClamped: FieldBinding
var bClamped: Binding
var gClampedIsField = false

# ---------------------------------------------------------------------------
# Effect 1: SmoothSpeedFix
# ---------------------------------------------------------------------------

proc bindSmoothChain(): bool =
  ## Everything `SmoothSpeedFix` needs, or nothing. An effect that half-binds
  ## is an effect that writes a field it never checked.
  bWorld = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  if not bWorld.ok:
    gSmoothState = "refused: " & bWorld.why
    return false
  bMainPlayer = bindMethod(rt, TyGameWorld, "get_MainPlayer", 0)
  if not bMainPlayer.ok:
    gSmoothState = "refused: " & bMainPlayer.why
    return false
  bCtxOf = bindMethod(rt, TyPlayer, "get_MovementContext", 0)
  if not bCtxOf.ok:
    gSmoothState = "refused: " & bCtxOf.why
    return false

  # The two fields upstream reaches by reflection. `_player` is private, which
  # is the whole point: `bindField` resolves it to a byte offset through
  # `il2cpp_field_get_offset` and bounds that offset against the class's
  # instance size, so a static field or a moved layout is refused rather than
  # read out of a neighbouring object.
  fCtxPlayer = bindField(rt, TyCtx, "_player")
  if not fCtxPlayer.ok:
    gSmoothState = "refused: " & fCtxPlayer.why
    return false
  fSmoothed = bindField(rt, TyCtx, "SmoothedCharacterMovementSpeed")
  if not fSmoothed.ok:
    gSmoothState = "refused: " & fSmoothed.why
    return false
  if fSmoothed.kind != fkF32 and fSmoothed.kind != fkF64:
    gSmoothState = "refused: " & fSmoothed.why & ", which is not a float"
    return false

  # `ClampedSpeed` is a field on some builds and a property on others, and
  # which one it is here is the runtime's answer rather than this port's
  # memory. The field is tried first because it is the cheaper read.
  fClamped = bindField(rt, TyPlayer, "ClampedSpeed")
  if fClamped.ok and (fClamped.kind == fkF32 or fClamped.kind == fkF64):
    gClampedIsField = true
  else:
    bClamped = bindMethod(rt, TyPlayer, "get_ClampedSpeed", 0)
    if not bClamped.ok:
      gSmoothState = "refused: " & TyPlayer & "::ClampedSpeed is neither a " &
                     "float field (" & fClamped.why & ") nor a getter (" &
                     bClamped.why & ")"
      return false
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
  ## that is deliberate: the chain is six bound calls and a field write, call
  ## it 70 ns, so forty bots cost under three microseconds of a sixteen
  ## millisecond frame -- and a rate limiter fine enough not to skip a frame at
  ## 240 fps would cost more in clock reads than it saved.
  if not fSmoothed.ok:
    return
  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return
  a.reset()
  let mainPlayer = callPtr(bMainPlayer, w, a)
  if mainPlayer == nil: return
  a.reset()
  let ctx = callPtr(bCtxOf, mainPlayer, a)
  if ctx == nil: return

  # Upstream reads the speed off `__instance._player` rather than off the
  # player it already has, and this does the same -- not out of deference, but
  # because reading the private back-reference is what proves the context found
  # by walking the world is the context this player is actually driving.
  let owner = readPtr(fCtxPlayer, ctx)
  if owner == nil: return

  var speed = 0.0
  if gClampedIsField:
    speed = readFloat(fClamped, owner)
  else:
    a.reset()
    speed = callFloat(bClamped, owner, a)

  writeFloat(fSmoothed, ctx, speed)
  gSmoothWrites = gSmoothWrites + 1

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
  # The method takes exactly one argument (checked before this was installed),
  # so the args array holds exactly one handle and `asObject` finds it.
  let obstacle = asObject(CallResult(ok: true, raw: args, error: ""))
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
  if not argsSafe(params):
    gBushState = "refused: " & describeSig(params, ret) &
                 " -- that parameter is a value type, which the host would " &
                 "report as a reference and take a GC handle to"
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
  if not argsSafe(params):
    gAimState = "refused: " & describeSig(params, ret) &
                " has a value-type parameter, which the host would report " &
                "as a reference"
    return
  if hookArgs(SetAimingSlowdown, onAimingSlowdown) == Ok:
    gAimState = "armed on " & describeSig(params, ret)
  else:
    gAimState = "refused: " & lastError()

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

proc watch(target, why: string) =
  gWatchNames.add target
  gWatchCounts.add 0
  gWatchWhy.add why
  if hook(target, onWatched) == Ok:
    info "watching " & target & " (" & why & ")"
  else:
    warn "cannot watch " & target & ": " & lastError()
    shrink(gWatchNames, gWatchNames.len - 1)
    shrink(gWatchCounts, gWatchCounts.len - 1)
    shrink(gWatchWhy, gWatchWhy.len - 1)

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
    warn "Classic Movement: " & gSmoothState
  else:
    if bindSmoothChain():
      gSmoothState = "armed, ClampedSpeed read as " &
                     (if gClampedIsField: "a field" else: "a property")
    armBushRemover()
    armAimingSlowdown()

  info "Classic Movement: SmoothSpeedFix -- " & gSmoothState
  info "Classic Movement: BushSpeedStateRemover -- " & gBushState
  info "Classic Movement: AimingSlowdownPatch -- " & gAimState

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours"
    warn "SmoothSpeedFix rides on the " & ManualUpdate &
         " detour and is therefore also off"
    return

  # Only the targets the config actually asks for, exactly as upstream's
  # `Awake` only calls `Enable()` on the patches its config enables. There are
  # 16 patch slots; this uses at most seven, three of which now do work rather
  # than only counting.
  if cfgNoInertia:
    watch(TyCtx & "::GetNewState",
          "StateReplacer -- not ported: the replacement states are C# " &
          "subclasses, which nothing here can declare")
  watch(ManualUpdate,
        "SmoothSpeedFix -- per-frame speed smoothing; carries the write")
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
    watch(TyCtx & "::InertiaSmoothTilt",
          "OldTiltingFix -- not ported: the redirect needs the instance to " &
          "call LegacySmoothTilt on")
    watch(TyCtx & "::LegacySmoothTilt",
          "OldTiltingFix -- the fast lean it would be redirected to")
  if cfgRemoveJitteryRotation:
    watch(TyCtx & "::PlayerAnimatorSetDeltaRotation",
          "RemoveJitteryRotationPatch -- not ported: telling the player from " &
          "a bot needs the instance")
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
  reportEffect("BushSpeedStateRemover", gBushState, gBushSuppressed)
  if gBushSeen > 0:
    info "    (" & $gBushSeen & " obstacles entered, " & $gBushSuppressed &
         " of them swamp-limited)"
  reportEffect("AimingSlowdownPatch", gAimState, gAimSuppressed)
  info "  not ported: GetNewState (its replacement states are C# subclasses), " &
       "InertiaSmoothTilt (the redirect needs the instance it fired on), and " &
       "PlayerAnimatorSetDeltaRotation (telling the player from a bot needs " &
       "the same). See the table in the module comment."

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
  else:
    info "neither client nor server; config parsed, nothing installed"
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
