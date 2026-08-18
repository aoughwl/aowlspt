## SPT-SWAY, as a native aowlspt mod.
##
##     aowl build-mod mods/sway
##     aowl run mods/sway
##
## Five independent physical sources of weapon sway — respiration, cardiac,
## physiological tremor, postural drift and weapon inertia — summed, scaled by
## the shooter's condition and the weapon in their hands, and pushed into the
## game's rotation springs.
##
## This is a rewrite of the BepInEx plugin `com.savannt.sptsway`, not a
## translation of it. The physics is the valuable part and it is ported
## faithfully, constant for constant; the C# was only its previous host.
##
## Layout:
##
##     model/vec.nim       Vec3 and the scalar helpers Mathf used to provide
##     model/noise.nim     band-limited value noise
##     model/filters.nim   one-pole low-pass and the DC blocker
##     model/tuning.nim    every tunable, and the presets
##     model/state.nim     the shooter, as data
##     model/sources.nim   the five sources
##     model/director.nim  the signal chain
##     game/config.nim     config.json -> Tuning
##     sway.nim            this file: the only thing that talks to EFT
##
## Nothing under `model/` imports `aowlspt`. That is deliberate and it is the
## whole reason the split exists: the model is pure arithmetic over two records,
## so `aowlspt-sim` can tick it with no game in the process, and a change to the
## physics can be checked in under a second rather than by loading a raid.
##
## ---------------------------------------------------------------------------
## What this mod can and cannot reach on a post-1.0 client
## ---------------------------------------------------------------------------
##
## Post-1.0 Tarkov is IL2CPP. There are no managed assemblies and no Harmony,
## so everything goes through `aowlspt/game`, and that interface has one hard
## limit today: **it has no way to name a live object.** `resolve` hands back a
## handle to a *class*, `call` invokes with no `this`, and a method whose
## return type is a reference type comes back as `{"type":"..."}` with no
## handle attached. There is therefore no path from `EFT.Player` to *this*
## player's `Physical`, and none from `ProceduralWeaponAnimation` to *this*
## weapon's `HandsContainer.HandsRotation`.
##
## What that costs, precisely:
##
## * **Sampling.** Stamina, oxygen, arm stamina, pose, lean, movement speed,
##   ergonomics, weight and the recoil stat are all instance reads. They are
##   held at the rested defaults in `freshState` until the host can name an
##   object. Everything downstream of them still runs.
## * **Output.** `HandsRotation.AddAcceleration` is an instance call on an
##   instance field. The model's output is published — as an event and into the
##   mod store — rather than written into the springs.
##
## What still works, and is not a stand-in:
##
## * The model runs, in full, on the host's real frame clock.
## * `hook` detours compiled methods, so shots, weapon changes, condition
##   changes and per-frame ticks arrive as real game events. A detour needs no
##   instance; it is the *calls* that do.
##
## Nothing here fakes the difference. Attempting an instance call with a null
## `this` would not fail politely — IL2CPP would dereference it inside the
## method body and take the game down — so this mod does not attempt one, and
## says so once at load rather than looking broken in a raid.

import std/strutils
import aowlspt
import aowlspt/game
import model/vec
import model/tuning
import model/state
import model/sources
import model/director
import game/config

const
  ModGuid = "com.savannt.sptsway"
  ModName = "SPT-SWAY"
  ModVersion = "3.0.0"

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------
#
# Globals, all initialised from templates that expand to object literals. A
# global initialised by a *call* is left zeroed in a nimony `--app:lib` build —
# see the note on `defaultTuning` — so every constructor in this mod is a
# template, and this is why.

var gTuning = defaultTuning()
var gState = freshState()
var gDirector = newDirector()

# ---------------------------------------------------------------------------
# The game
# ---------------------------------------------------------------------------
#
# Named here and resolved on first use. Resolving at load time is a false
# negative: the process has an IL2CPP runtime long before the game has loaded
# its own assemblies.

var world = whenReady("EFT.Animations.ProceduralWeaponAnimation")

# Counters written by the hook handlers, which run on the game thread inside a
# patched method, and read by `onUpdate`. Each is a plain int bumped by one
# instruction: the handlers do the least possible work and the frame's actual
# consequences are worked out on the mod's own tick.
var gShots = 0
var gShotsSeen = 0
var gWeaponChanges = 0
var gWeaponChangesSeen = 0
var gConditionChanges = 0
var gConditionChangesSeen = 0
var gFrames = 0

var gHooksInstalled = false
var gStarted = false
var gTicks = 0
var gLastReadoutMs = 0'i64

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

proc f3(v: float): string =
  ## Three decimal places. `$` on a float here prints the full repr, which for
  ## a readout of a dozen numbers per line is unreadable.
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  let scaled = int(x * 1000.0 + 0.5)
  let whole = scaled div 1000
  let frac = scaled mod 1000
  var f = $frac
  while f.len < 3:
    f = "0" & f
  result = (if neg: "-" else: "") & $whole & "." & f

proc fmtVec(v: Vec3): string =
  "p " & f3(v.x) & "  y " & f3(v.y) & "  r " & f3(v.z)

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
#
# Each handler is a top-level proc, not a closure: nimony will not let a nested
# proc touch its enclosing scope without being made a closure, and a closure is
# not a plain function pointer so it could not cross the C ABI anyway.
#
# The handlers cannot read the hooked method's arguments — the host refuses to
# guess them rather than reporting the wrong ones — which is why the condition
# hook can only say *that* the physical condition changed, not what it changed
# to. See the header.

proc onShotFired(target: string) =
  inc gShots

proc onWeaponInit(target: string) =
  inc gWeaponChanges

proc onConditionUpdated(target: string) =
  inc gConditionChanges

proc onLerpCamera(target: string) =
  inc gFrames

proc installHooks() =
  ## Four detours, each reported individually. A method that cannot be patched
  ## costs that one signal; the C# original would have failed to load.
  if gHooksInstalled:
    return
  gHooksInstalled = true

  if hook("EFT.Player::OnMakingShot", onShotFired) == Ok:
    info "hooked EFT.Player::OnMakingShot"
  else:
    warn "no shot disturbance: " & lastError()

  if hook("EFT.Animations.ProceduralWeaponAnimation::InitWeaponData",
          onWeaponInit) == Ok:
    info "hooked ProceduralWeaponAnimation::InitWeaponData"
  else:
    warn "weapon changes will not reset the inertia state: " & lastError()

  if hook("EFT.Animations.ProceduralWeaponAnimation::PhysicalConditionUpdated",
          onConditionUpdated) == Ok:
    info "hooked ProceduralWeaponAnimation::PhysicalConditionUpdated"
  else:
    warn "arm injury will not be noticed: " & lastError()

  # LerpCamera runs every rendered frame, after BSG's own effectors have had
  # their say, which is where the C# added this mod's output on top. It is
  # hooked here for the frame count alone: the model is stepped from
  # `onUpdate`, on the host's clock, because a detour handler runs inside a
  # patched game method and must do as little as possible.
  if hook("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
          onLerpCamera) == Ok:
    info "hooked ProceduralWeaponAnimation::LerpCamera"
  else:
    warn "no frame signal from the weapon animator: " & lastError()

# ---------------------------------------------------------------------------
# Publishing the model's output
# ---------------------------------------------------------------------------

proc publish(o: SwayOutput; dt: float) =
  ## Where the output goes until the host can name a live object.
  ##
  ## The impulse is computed here, in the units the springs want, so that the
  ## day `AddAcceleration` becomes reachable this is the only line that changes
  ## — and so that anything reading the event today is reading exactly what the
  ## springs would have been given.
  let hands = springImpulse(o.hands, gTuning, dt)
  let camera = springImpulse(o.camera, gTuning, dt)

  var payload = "{\"hands\":[" & f3(hands.x) & "," & f3(hands.y) & "," &
                f3(hands.z) & "],\"camera\":[" & f3(camera.x) & "," &
                f3(camera.y) & "," & f3(camera.z) & "],\"multiplier\":" &
                f3(o.multiplier) & "}"
  discard emit("sway.output", payload)
  if storeReady():
    discard storeSet("sway.lastOutput", payload)

proc readout() =
  ## The BepInEx build drew this with OnGUI every frame. A native client mod
  ## has no GUI to draw into, so it goes to the log on an interval instead.
  let s = gState
  let d = gDirector
  info "sway  aiming " & (if s.isAiming: "yes" else: "no") &
       "  support " & f3(s.supportFactor) &
       "  handling " & f3(s.handlingFactor)
  info "sway  stamina " & f3(s.stamina) & "  oxy " & f3(s.oxygen) &
       "  arms " & f3(s.armStamina) & "  exertion " & f3(s.exertion)
  info "sway  breath " & f3(d.breath.rateBpm) & " bpm  phase " &
       f3(d.breath.phase) & "  pulse " & f3(d.heart.bpm) & " bpm"
  info "sway  multiplier " & f3(d.last.multiplier)
  info "sway  hands  " & fmtVec(d.last.hands)
  info "sway  camera " & fmtVec(d.last.camera)

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

proc drainEvents() =
  ## Turn the hook counters into model events. Done here rather than in the
  ## handlers because the handlers run on the game thread inside a patched
  ## method: counting is one add, and everything else can wait for our tick.
  while gShotsSeen < gShots:
    inc gShotsSeen
    onShot(gDirector, gTuning)

  if gWeaponChangesSeen < gWeaponChanges:
    gWeaponChangesSeen = gWeaponChanges
    onWeaponChanged(gDirector)

  if gConditionChangesSeen < gConditionChanges:
    gConditionChangesSeen = gConditionChanges
    # The mask itself is an argument of the hooked method and a hook cannot
    # read arguments, so what arrives is only "something changed". Clearing the
    # flags is the honest response: claiming a fracture the player does not
    # have would multiply their sway by 2.4 for no reason.
    applyCondition(gState, 0, false, gTuning.injuryEnabled)

proc step(dt: float) =
  drainEvents()

  # Inertia is driven from where the view actually ended up rather than from
  # raw mouse input, so sensitivity changes, controllers and any other mod that
  # moves the view all feed it the same way. Those are instance reads on the
  # camera transform, so until the host can name one the oscillator is driven
  # at rest: it stays centred, and every other source is unaffected.
  drive(gDirector.inertia, 0.0, 0.0, Zero3, gState, gTuning, dt)

  let o = tick(gDirector, gState, gTuning, dt)
  publish(o, dt)

# ---------------------------------------------------------------------------
# Mod entry points
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  var doc = loadConfigDoc()
  if doc.ok:
    readTuning(doc, gTuning)
    if doc.missing > 0:
      warn $doc.missing & " setting(s) were not in config.json; " &
           "the shipped defaults were used for those"
  else:
    warn "config.json could not be read; running on the shipped defaults"

  if gTuning.preset != psCustom:
    info "preset: " & presetName(gTuning.preset) &
         " (it overwrites the values in config.json)"

  reset(gDirector.heart, gTuning)

  success ModName & " " & ModVersion & " loaded on " & hostName()
  if not gTuning.enabled:
    warn "the master switch is off; the model will run but produce nothing"

  if gTuning.verboseLogging:
    info DriveGainProvenance

  if side() == sideClient:
    # Said once, at load, so that a raid where the weapon does not move has an
    # explanation somebody can read rather than a mod that looks broken.
    warn "this host cannot yet name a live object, so the model's output " &
         "cannot be written into the weapon springs and the shooter cannot " &
         "be sampled. The model runs and its output is published on the " &
         "'sway.output' event; see the header of sway.nim."
  Ok

proc simSelfTest() =
  ## `aowl run mods/sway` ends here. It is not a demo: it is the only place the
  ## model is exercised end to end without a game, and it fails loudly if a
  ## source has been broken.
  var t = defaultTuning()
  var s = freshState()
  var d = newDirector()
  reset(d.heart, t)

  # A shooter halfway through a sprint, aiming, with a heavy rifle. Exactly the
  # case where every source is contributing at once.
  s.isAiming = true
  s.stamina = 0.35
  s.oxygen = 0.55
  s.armStamina = 0.6
  s.weightKg = 5.2
  s.ergonomics = 38.0
  s.moveSpeed = 1.4

  var peak = 0.0
  var i = 0
  const Frames = 600            # ten seconds at 60 fps: two full breaths
  while i < Frames:
    drive(d.inertia, float(i) * 0.7, 0.0, Zero3, s, t, 1.0 / 60.0)
    let o = tick(d, s, t, 1.0 / 60.0)
    let m = magnitude(o.hands)
    if m > peak:
      peak = m
    inc i

  info "sim  " & $Frames & " frames of a spent shooter aiming a 5.2 kg rifle"
  info "sim  peak hands deflection " & f3(peak) & " deg"
  info "sim  breath " & f3(d.breath.rateBpm) & " bpm, pulse " &
       f3(d.heart.bpm) & " bpm, exertion " & f3(s.exertion)
  info "sim  handling " & f3(s.handlingFactor) & ", support " &
       f3(s.supportFactor) & ", multiplier " & f3(d.last.multiplier)

  if peak <= 0.0:
    error "sim  the model produced nothing; a source is broken"
  elif peak > 20.0:
    error "sim  the model produced " & f3(peak) &
          " degrees, which is not sway, it is a catapult"
  else:
    success "sim  the model is live and inside its sane band"

proc onUpdate(elapsedMs: int64): Status =
  inc gTicks

  if side() == sideSim:
    if not gStarted:
      gStarted = true
      simSelfTest()
    return Ok

  if side() != sideClient:
    return Ok

  if world.ready():
    success "the weapon animator is up"
    installHooks()
    gStarted = true

  if not gStarted:
    return Ok

  # The host's own elapsed time. Unity's `Time.deltaTime` would be the truer
  # frame delta, but reading it means calling into the engine from the host's
  # attached thread rather than Unity's main thread, and `invoke_main` queues
  # onto the host thread rather than the game's. A clock we can read safely
  # beats a slightly better one we cannot.
  let dt = float(elapsedMs) / 1000.0
  step(dt)

  if gTuning.debugOverlay:
    let now = nowMs()
    if now - gLastReadoutMs >= int64(gTuning.debugIntervalMs):
      gLastReadoutMs = now
      readout()

  Ok

proc onUnload(): Status =
  info ModName & " unloaded after " & $gTicks & " ticks and " & $gFrames &
       " rendered frames"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = "savannt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
