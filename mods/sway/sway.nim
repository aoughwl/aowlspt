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
##     game/binding.nim    one scalar on a game object: field or property
##     game/live.nim       the walk from the world to the springs, and back
##     sway.nim            this file: config, hooks, and the frame
##
## Nothing under `model/` imports `aowlspt`. That is deliberate and it is the
## whole reason the split exists: the model is pure arithmetic over two records,
## so `aowlspt-sim` can tick it with no game in the process, and a change to the
## physics can be checked in under a second rather than by loading a raid.
##
## ---------------------------------------------------------------------------
## What reaches the game, and how
## ---------------------------------------------------------------------------
##
## An earlier revision of this mod ran the model and published its output as an
## event, because the client API of the day could not name a live object: there
## was no path from `EFT.Player` to *this* player's `Physical`, and none from
## `ProceduralWeaponAnimation` to *this* weapon's springs. That limitation is
## gone. The mod now samples the shooter and drives the springs.
##
## **Where the work happens.** Not in `onUpdate`. That runs on the host's own
## attached thread, and writing into a spring from there would race the main
## thread integrating it. The per-frame path is called from the detour on
## `ProceduralWeaponAnimation::LerpCamera`, which runs on whatever thread calls
## it — Unity's main thread — which is where the BepInEx original did it too.
## `onUpdate` is left with what is genuinely the host's: config, the readout,
## and publishing the last frame's output for other mods.
##
## **How it reaches the objects.** `game/live.nim`, directly through the IL2CPP
## runtime rather than through the host: a bound field read is 1.9 ns against
## 305, and a bound call 10 ns against 1235 (`docs/PERF.md`). Bindings are
## resolved once — per session for everything type-level, per *weapon change*
## for the hands controller, whose class differs between a rifle and a knife.
## The object chain itself is re-walked every frame, six loads, because the
## collector moves objects and a cached pointer is a use-after-free waiting for
## its moment.
##
## **What is still not reachable, said plainly:**
##
## * **The `EPhysicalCondition` mask.** It is the argument to
##   `PhysicalConditionUpdated`, and `hookArgs` would hand it over — except that
##   the host encodes an argument it does not recognise as a *reference*, and
##   an enum is a value type. It would call `il2cpp_gchandle_new` on the small
##   integer `2`. So this mod does not ask for that method's arguments. The one
##   thing the mask carried that nothing else exposes is the neurological
##   tremor condition (stims, shock), so `neuroTremor` stays false; arm
##   fractures and blacked limbs are read straight off the health controller
##   instead, which the original could not do.
## * **`LerpCamera`'s own `dt`.** Same reason it is not asked for: the frame
##   delta is measured with `perfCounter` between detour firings instead, which
##   is the same clock and costs twenty nanoseconds.
## * **The view angles and the body velocity** are `Vector2`/`Vector3`
##   properties, and a value-type *return* is unreachable on either path. They
##   are read off the backing field instead, found by scanning `MovementContext`
##   for a vector field with the right name and shape, once. The field it
##   settled on is in the log.
##
## Nothing here has ever run against Tarkov.

import std/strutils
import aowlspt
import aowlspt/game
import model/vec
import model/tuning
import model/state
import model/sources
import model/director
import game/config
import game/live

const
  ModGuid = "com.savannt.sptsway"
  ModName = "SPT-SWAY"
  ModVersion = "3.1.0"

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

# Counters written by the hook handlers and drained by the frame handler.
# Every one of those now runs on the game's own thread — the handlers are
# inline detours and the frame handler is one of them — so this is ordering,
# not synchronisation: a shot that lands mid-frame is applied at the top of the
# next one rather than in the middle of a signal chain.
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
var gLastFrameTicks = 0'i64
var gInjuryReadable = false
var gSaidIdle = false

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
# The frame
# ---------------------------------------------------------------------------
#
# Everything below this line runs inside a detour, on the game's main thread.

proc drainEvents() =
  ## Turn the hook counters into model events.
  while gShotsSeen < gShots:
    inc gShotsSeen
    onShot(gDirector, gTuning)

  if gWeaponChangesSeen < gWeaponChanges:
    gWeaponChangesSeen = gWeaponChanges
    onWeaponChanged(gDirector)
    live.onWeaponChanged()

  if gConditionChangesSeen < gConditionChanges:
    gConditionChangesSeen = gConditionChanges
    if not gInjuryReadable:
      # No health controller to ask, so all that arrived is "something
      # changed" — the mask itself is the hooked method's argument and this
      # mod does not read it (see the header). Clearing the flags is the honest
      # response: claiming a fracture the player does not have would multiply
      # their sway by 2.4 for no reason.
      applyCondition(gState, 0, false, gTuning.injuryEnabled)

proc sampleInjury() =
  ## Arm state, read rather than inferred from a hook.
  var fractured = false
  var blacked = false
  gInjuryReadable = sampleArmInjury(fractured, blacked)
  if not gInjuryReadable:
    return
  # `applyCondition` owns the decoding, in `model/`, so the rule that a damaged
  # but not destroyed arm means a fracture lives with the rest of the physics
  # rather than here. It takes BSG's bitmask, so the two booleans are put back
  # into one.
  let mask = (if fractured or blacked: PcLeftArmDamaged else: 0)
  applyCondition(gState, mask, blacked, gTuning.injuryEnabled)

proc onFrame() =
  ## One rendered frame: reach the game, sample it, step the model, push the
  ## result into the springs.
  if not beginFrame(gTuning):
    return

  # The frame delta, measured between two firings of this detour on the same
  # clock the fast path reports its own cost on.
  let dt = frameDelta(gLastFrameTicks)

  drainEvents()
  sample(gState)
  sampleInjury()

  var yaw = 0.0
  var pitch = 0.0
  discard viewAngles(yaw, pitch)
  drive(gDirector.inertia, yaw, pitch, bodyVelocity(), gState, gTuning, dt)

  let o = tick(gDirector, gState, gTuning, dt)

  # `springImpulse` is in `model/` because it is arithmetic — degrees to the
  # acceleration the springs expect, normalised to a 60 Hz frame so the mod is
  # not twice as strong at 120 fps. It carries `driveGain`, the one constant in
  # this mod that was calculated rather than measured; `live.actuate` says so
  # again at the point it first matters.
  actuate(springImpulse(o.hands, gTuning, dt),
          springImpulse(o.camera, gTuning, dt), gTuning)

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
#
# Each handler is a top-level proc, not a closure: nimony will not let a nested
# proc touch its enclosing scope without being made a closure, and a closure is
# not a plain function pointer so it could not cross the C ABI anyway.

proc onShotFired(target: string) =
  inc gShots

proc onWeaponInit(target: string) =
  inc gWeaponChanges

proc onConditionUpdated(target: string) =
  inc gConditionChanges

proc onLerpCamera(target: string) =
  inc gFrames
  onFrame()

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

  # LerpCamera runs every rendered frame, on Unity's main thread, and this is
  # where the whole mod happens: sample, step, actuate.
  #
  # Two honest differences from the BepInEx original. It used a Harmony
  # **postfix**, so its impulse landed after BSG's own effectors had run;
  # aowlspt's patch is an entry detour and the host ignores the
  # prefix/postfix distinction, so ours lands before them. `AddAcceleration`
  # accumulates rather than sets, so that is one frame of ordering against
  # BSG's contribution rather than a different result. And it resolved the
  # player from the `this` the patch handed it; this one walks from the world
  # to `MainPlayer`, which reaches the same object and is why the local player's
  # animator is the only one driven — bots run the same animator and driving
  # their sway from this model would be both wrong and expensive.
  if hook("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
          onLerpCamera) == Ok:
    info "hooked ProceduralWeaponAnimation::LerpCamera"
  else:
    error "the model has no frame to run on: " & lastError() &
          ". Nothing will move."

# ---------------------------------------------------------------------------
# Publishing the model's output
# ---------------------------------------------------------------------------

proc publish() =
  ## What the last frame produced, for anything else that wants it.
  ##
  ## This used to be the mod's *output*, because the springs were unreachable.
  ## Now it is a courtesy, so it moved to the host's tick: emitting an event and
  ## writing a file on every rendered frame would cost more than the physics.
  let o = gDirector.last
  var payload = "{\"hands\":[" & f3(o.hands.x) & "," & f3(o.hands.y) & "," &
                f3(o.hands.z) & "],\"camera\":[" & f3(o.camera.x) & "," &
                f3(o.camera.y) & "," & f3(o.camera.z) & "],\"multiplier\":" &
                f3(o.multiplier) & ",\"actuating\":" &
                (if actuating(): "true" else: "false") & "}"
  discard emit("sway.output", payload)
  if storeReady():
    discard storeSet("sway.lastOutput", payload)

proc readout() =
  ## The BepInEx build drew this with OnGUI every frame. A native client mod
  ## has no GUI to draw into, so it goes to the log on an interval instead.
  ##
  ## Read from the host's thread while the game's thread writes it. That is a
  ## torn read of a readout and nothing else: no value here is acted on, and
  ## taking a lock around the model to print a line would put the host's
  ## scheduling inside the frame.
  let s = gState
  let d = gDirector
  info "sway  aiming " & (if s.isAiming: "yes" else: "no") &
       "  support " & f3(s.supportFactor) &
       "  handling " & f3(s.handlingFactor)
  info "sway  stamina " & f3(s.stamina) & "  oxy " & f3(s.oxygen) &
       "  arms " & f3(s.armStamina) & "  exertion " & f3(s.exertion)
  info "sway  ergo " & f3(s.ergonomics) & "  weight " & f3(s.weightKg) &
       " kg  recoil " & f3(s.recoilStat) &
       "  fracture " & (if s.armFractured: "yes" else: "no")
  info "sway  breath " & f3(d.breath.rateBpm) & " bpm  phase " &
       f3(d.breath.phase) & "  pulse " & f3(d.heart.bpm) & " bpm"
  info "sway  multiplier " & f3(d.last.multiplier)
  info "sway  hands  " & fmtVec(d.last.hands)
  info "sway  camera " & fmtVec(d.last.camera)

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

  # Deliberately not opening the IL2CPP runtime here. At load the process has a
  # runtime but not yet a game, and every binding made now would be refused —
  # correctly, and permanently, since a refusal is not retried. `onUpdate` does
  # it on the first tick the animator exists.
  Ok

proc simSelfTest() =
  ## `aowl run mods/sway` ends here. It is not a demo: it is the only place the
  ## model is exercised end to end without a game, and it fails loudly if a
  ## source has been broken.
  ##
  ## Note what it does *not* touch: nothing in `game/`. The model takes a state
  ## record and a tuning record and returns two vectors, and that is still true
  ## now that something is on the other end of it.
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
  var peakImpulse = 0.0
  var i = 0
  const Frames = 600            # ten seconds at 60 fps: two full breaths
  while i < Frames:
    drive(d.inertia, float(i) * 0.7, 0.0, Zero3, s, t, 1.0 / 60.0)
    let o = tick(d, s, t, 1.0 / 60.0)
    let m = magnitude(o.hands)
    if m > peak:
      peak = m
    let im = magnitude(springImpulse(o.hands, t, 1.0 / 60.0))
    if im > peakImpulse:
      peakImpulse = im
    inc i

  info "sim  " & $Frames & " frames of a spent shooter aiming a 5.2 kg rifle"
  info "sim  peak hands deflection " & f3(peak) & " deg"
  info "sim  peak spring impulse " & f3(peakImpulse) &
       " (degrees x driveGain " & f3(t.driveGain) & ", never playtested)"
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
    gStarted = true

  if not gStarted:
    return Ok

  # Retried until it takes: the runtime is in this process from the start, but
  # a mod that loaded before `GameAssembly.dll` did would otherwise never bind.
  if not openRuntime():
    return Ok

  # Hooks go in *after* the runtime is bound, and the order is the point: a
  # detour can fire on the very next frame, on another thread, and it reads the
  # `Il2Cpp` this call fills in. Installing first would leave a window in which
  # the frame handler could see a half-written one.
  installHooks()

  # The model is stepped by the LerpCamera detour, on the game's thread. What
  # is left here is what belongs on the host's: publishing, and the readout.
  publish()

  if not actuating() and not gSaidIdle and gTicks > 300:
    gSaidIdle = true
    if rootWhy().len > 0:
      warn "sway  the weapon is not being driven: " & rootWhy()
    elif springWhy().len > 0:
      warn "sway  the weapon is not being driven: " & springWhy()
    else:
      info "sway  no frames driven yet; this is expected outside a raid"

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
