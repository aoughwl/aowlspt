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
## THE SERVER HALF IS COMPLETE. THE CLIENT HALF CANNOT BE.
## ---------------------------------------------------------------------------
##
## **Server.** Upstream's server mod is one loader and one route: read
## `Config/settings.jsonc`, serve it at `/OldTarkovMovement/GetConfig`. That is
## ported whole and behaves identically, down to the JSON member names, so a
## client built against the original protocol gets the response it expects.
##
## **Client.** Upstream's client half is six Harmony patches, and every one of
## them is a `[PatchPrefix]` that takes `MovementContext __instance`, reads or
## writes its private state, and `return false`s so the original never runs:
##
##   | upstream patch | what it needs |
##   |---|---|
##   | `StateReplacer` on `MovementContext::GetNewState` | read the `EPlayerState` argument, construct a replacement state object, write it to `ref __result`, suppress the original |
##   | `SmoothSpeedFix` on `MovementContext::ManualUpdate` | read the private `_player` field, read `ClampedSpeed`, write `SmoothedCharacterMovementSpeed` |
##   | `BushSpeedStateRemover` on `::OnEnterObstacle` | read the private `_enteredObstacles` list, read the argument's `HasSwampSpeedLimit`, suppress |
##   | `OldTiltingFix` on `::InertiaSmoothTilt` | forward the two float arguments to `LegacySmoothTilt` on the same instance, suppress |
##   | `AimingSlowdownPatch` on `::SetAimingSlowdown` | suppress conditionally |
##   | `RemoveJitteryRotationPatch` on `::PlayerAnimatorSetDeltaRotation` | read `IsAI`, suppress; and write `EFTHardSettings.Instance.TRANSFORM_ROTATION_LERP_SPEED` |
##
## Post-1.0 Tarkov is IL2CPP: no managed assemblies, no Harmony, no reflection.
## What this host gives a client mod is `resolve` (a type handle by name),
## `call` (a **static** member with scalar arguments) and `patch` (a detour
## that **cannot read the method's arguments and cannot suppress the
## original** — docs/MODDING.md states both, and the host refuses rather than
## approximating). Not one of the six rows above fits inside that. There is no
## instance pointer, no field accessor, no way to replace a body.
##
## So the client half applies **no movement change**. It is not disabled and it
## is not faked; it does the one client-side job that is both possible and
## worth having, described below.
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

const
  ModGuid = "aowl.classicmovement"
  ModName = "Classic Movement"
  ModAuthor = "TheBoogle (ported by savannt)"
  ModVersion = "1.2.0"
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

  # The movement state types are not used to build anything -- there is no way
  # to construct a managed object from here -- but resolving them is the
  # cheapest possible check that the rename map this port was written against
  # still matches the build that is running.
  reportType(MovementContext)
  reportType(IdlePlayerState)
  reportType(MovePlayerState)
  reportType(SprintPlayerState)
  reportType(JumpPlayerState)
  reportType(PronePlayerState)
  reportType(SideStepPlayerState)
  reportType(EFTHardSettings)
  reportType(ProceduralWeaponAnimation)

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours"
    return

  # Only the targets the config actually asks for, exactly as upstream's
  # `Awake` only calls `Enable()` on the patches its config enables. There are
  # 16 patch slots; this uses at most seven.
  if cfgNoInertia:
    watch("EFT.MovementContext::GetNewState",
          "StateReplacer -- where the inertia-less states would be swapped in")
  watch("EFT.MovementContext::ManualUpdate",
        "SmoothSpeedFix -- per-frame speed smoothing")
  if not cfgDoBushesSlowYouDown:
    watch("EFT.MovementContext::OnEnterObstacle",
          "BushSpeedStateRemover -- the SWAMP speed limit on bushes")
  if cfgQuickTilting:
    watch("EFT.MovementContext::InertiaSmoothTilt",
          "OldTiltingFix -- the slow lean that would be redirected to " &
          "LegacySmoothTilt")
    watch("EFT.MovementContext::LegacySmoothTilt",
          "OldTiltingFix -- the fast lean it would be redirected to")
  if cfgRemoveJitteryRotation:
    watch("EFT.MovementContext::PlayerAnimatorSetDeltaRotation",
          "RemoveJitteryRotationPatch -- the look fidget")
    watch("EFT.Animations.ProceduralWeaponAnimation::InitTransforms",
          "RemoveStupidMotionSicknessBSGMade -- camera input intensity")
  if cfgDoesAimingSlowYouDown:
    info "DoesAimingSlowYouDown is on, which is the game's own behaviour; " &
         "upstream's patch only ever suppressed the method, so with the " &
         "setting on there is nothing to watch"
  else:
    watch("EFT.MovementContext::SetAimingSlowdown",
          "AimingSlowdownPatch -- the aim speed penalty that would be skipped")

proc reportWatch() =
  if gWatchNames.len == 0:
    return
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
  warn "no movement behaviour was changed: this host's client API is " &
       "resolve + static call + observe-only detour, and every one of " &
       "upstream's patches needs an instance pointer, a private field, or a " &
       "suppressed original. See the table in the module comment."

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
    info "BotsUseOldMovement only matters inside the GetNewState replacement, " &
         "which is not expressible here; it is carried in config and on the wire"
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
  if not gReported and gWatchNames.len > 0 and gElapsedMs > 60_000:
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
