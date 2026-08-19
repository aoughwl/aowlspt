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
##     model/vec.nim          Vec3 and the scalar helpers Mathf used to provide
##     model/fmt.nim          numbers as text, for a log line
##     model/noise.nim        band-limited value noise
##     model/filters.nim      one-pole low-pass and the DC blocker
##     model/tuning.nim       every tunable, and the presets
##     model/limits.nim       the range each tunable may hold, and the clamp
##     model/state.nim        the shooter, as data
##     model/sources.nim      the five sources
##     model/director.nim     the signal chain
##     model/spring.nim       BSG's rotation spring, as arithmetic, and the
##                            closed form of what it does with a step
##     model/characterise.nim what the model does, measured — including the
##                            spring's own transient and the limiter's clamp
##     game/binding.nim       one scalar on a game object: field or property
##     game/live.nim          the walk from the world to the springs, and back
##     sway.nim               this file: config, hooks, and the frame
##
## Nothing under `model/` imports `aowlspt`. That is deliberate and it is the
## whole reason the split exists: the model is pure arithmetic over two records,
## so `aowlspt-sim` can tick it with no game in the process. It is also what
## makes `model/characterise.nim` possible — the model can be driven with
## synthetic input traces and its output bounded, offline, in a second, which is
## the only way anything about this mod's *behaviour* has ever been checked.
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
## **Which patch shape, and why each.** All three of them are on this mod now,
## and they were chosen by what each firing costs:
##
## * `LerpCamera` is a **typed postfix** (`hookReturnTyped`, ~37 ns) where the
##   host offers one. That restores the BepInEx original's ordering — it used a
##   Harmony postfix, so its impulse landed after BSG's own effectors had run —
##   which the JSON patch could not buy at any acceptable price: a JSON postfix
##   is 440 ns watching and 2.2 µs with arguments, and this fires every frame.
##   The fallback on an older host is the plain **prefix** `hook`, which is a
##   name comparison and lands the impulse a frame's ordering earlier against
##   BSG's contribution. `AddAcceleration` accumulates rather than sets, so that
##   is an ordering difference and not a different result.
## * The typed frame also carries `this`, at no cost, and that fixed a real bug
##   rather than saving a microsecond. `LerpCamera` runs on *an* animator, and
##   bots have animators too; every firing used to step the whole model. The
##   handler now walks to `MainPlayer`'s animator and returns for anything else
##   — six loads and a comparison — so the model is stepped once a frame rather
##   than once per animator per frame.
## * `PhysicalConditionUpdated` is a **typed prefix**, and it hands over the
##   `EPhysicalCondition` mask it is called with. See below.
##
## **What is still not reachable, said plainly:** `LerpCamera`'s own `dt`. Not
## because it cannot be read — a typed frame would hand it over — but because
## the interval between two firings of the detour is the same delta measured on
## the same clock the fast path reports its own cost on, it costs twenty
## nanoseconds, and it is correct on the fallback path too. The list used to be
## longer; the rest of it is below, in the past tense.
##
## **What was on that list and no longer is.**
##
## * *A `Vector3` argument or return.* `bindRaw` binds a method by its native
##   slot shape rather than by its signature, which is what a 12-byte struct
##   passed and returned by hidden pointer needs. So `AddAcceleration`, the
##   camera transform's `eulerAngles` and the player's `Velocity` are ordinary
##   fast-path calls. `bindMethod` still refuses all three, and is still right
##   to: `classifyType` asks the runtime whether a type is a value type and
##   refuses every one that is, because a value type wider than eight bytes is
##   not passed in a register at all. That refusal was re-derived against the
##   current `aowlspt/fast` rather than assumed from an older mock run.
## * *The `EPhysicalCondition` mask.* This paragraph used to say that `hookArgs`
##   would encode an argument it did not recognise as a *reference* and call
##   `il2cpp_gchandle_new` on the small integer `2`, so this mod did not ask for
##   that method's arguments and `neuroTremor` stayed permanently false. **That
##   is no longer true of the host.** An enum now arrives as a plain number, in
##   both directions, on both the JSON path and the typed one. So the mask is
##   read from the hook, `neuroTremor` — the stim-and-shock tremor condition,
##   which nothing else on the player exposes — is live for the first time, and
##   the arm flags are the mask's and the health controller's together rather
##   than the health controller's alone.
##
## ---------------------------------------------------------------------------
## What is known about how this behaves, and what is not
## ---------------------------------------------------------------------------
##
## **Nothing here has ever run against Tarkov.** That has not changed and this
## file will keep saying so.
##
## What *has* changed is that "never playtested" is no longer the same sentence
## as "unknown". `model/characterise.nim` drives the model through step
## responses, flicks, sixty-second envelopes at three levels of exhaustion, four
## frame rates, a jittered frame clock, every preset, and a sweep of every
## tunable that can destabilise it — and asserts bounds in degrees of point-of-aim
## error, which convert to centimetres at a range. `aowl run mods/sway` runs all
## of it and fails loudly. Every number this mod reports about itself comes from
## that, from the model, and not from the game.
##
## The one thing that still cannot be settled offline is which way BSG's
## `Spring` integrates the acceleration this mod hands it. That is one boolean,
## `springAccelPerFrame`, it is worth a factor of sixty, and `model/spring.nim`
## sets out the dimensional argument for the default. Everything downstream of
## it — the drive gain — is derived from the spring's own `ReturnSpeed`, read
## off the live object.

import std/strutils
import aowlspt
import aowlspt/game
import model/vec
import model/fmt
import model/tuning
import model/limits
import model/state
import model/sources
import model/director
import model/spring
import model/characterise
import game/config
import game/live

const
  ModGuid = "com.savannt.sptsway"
  ModName = "SPT-SWAY"
  ModVersion = "3.2.0"

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
var gConditionMask = 0
var gConditionMaskKnown = false
var gFrames = 0
var gForeignFrames = 0

var gHooksInstalled = false
var gStarted = false
var gTicks = 0
var gLastReadoutMs = 0'i64
var gLastFrameTicks = 0'i64
var gInjuryReadable = false
var gSaidIdle = false
var gTypedFrames = false

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
    if not gInjuryReadable and not gConditionMaskKnown:
      # No health controller to ask and no mask from the hook, so all that
      # arrived is "something changed". Clearing the flags is the honest
      # response: claiming a fracture the player does not have would multiply
      # their sway by 2.4 for no reason.
      applyCondition(gState, 0, false, gTuning.injuryEnabled)

proc sampleInjury() =
  ## Arm state. From the hook's own `EPhysicalCondition` mask where the host
  ## delivered one, and from the health controller for the part the mask cannot
  ## answer.
  ##
  ## The two are not alternatives. The mask says which arms are *damaged* and
  ## whether the neurological tremor condition is set — and it is the only thing
  ## anywhere that says the second. The health controller distinguishes a
  ## fracture from a destroyed limb, which the mask's single "damaged" bit
  ## cannot. `applyCondition` owns the decoding, in `model/`, so the rule that a
  ## damaged but not destroyed arm means a fracture lives with the rest of the
  ## physics rather than here.
  var fractured = false
  var blacked = false
  gInjuryReadable = sampleArmInjury(fractured, blacked)

  var mask = 0
  if gConditionMaskKnown:
    mask = gConditionMask
  if gInjuryReadable and (fractured or blacked):
    mask = mask or PcLeftArmDamaged
  if not gInjuryReadable and not gConditionMaskKnown:
    return
  applyCondition(gState, mask, blacked, gTuning.injuryEnabled)

proc onFrame(self: uint64) =
  ## One rendered frame: reach the game, sample it, step the model, push the
  ## result into the springs.
  ##
  ## `self` is the animator this firing was for, or 0 on a host that cannot say.
  ## Anything that is not the local player's animator is dropped here, before
  ## anything is bound, written or integrated.
  if not reachFrame():
    return
  if self != 0'u64:
    let mine = localAnimator()
    if mine != 0'u64 and self != mine:
      inc gForeignFrames
      return

  inc gFrames
  finishFrame(gTuning)
  reportCalibration(gTuning)

  # The frame delta, measured between two firings of this detour on the same
  # clock the fast path reports its own cost on. Taken after the guard above,
  # so a bot's animator cannot shorten the local player's frame.
  let dt = frameDelta(gLastFrameTicks)

  drainEvents()
  sample(gState)
  sampleInjury()

  var yaw = 0.0
  var pitch = 0.0
  discard viewAngles(yaw, pitch)
  drive(gDirector.inertia, yaw, pitch, bodyVelocity(), gState, gTuning, dt)

  let o = tick(gDirector, gState, gTuning, dt)

  # `springImpulse` is in `model/` because it is arithmetic: degrees times the
  # spring's own `ReturnSpeed` times `driveGain`, which is a trim rather than
  # the unverified absolute constant it used to be. `live.handsCal` reads the
  # spring's constants off the live object; `model/spring.nim` is the
  # derivation and states the one thing still assumed.
  actuate(springImpulse(o.hands, gTuning, handsCalNow(), dt),
          springImpulse(o.camera, gTuning, cameraCalNow(), dt), gTuning)

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
#
# Each handler is a top-level proc, not a closure: nimony will not let a nested
# proc touch its enclosing scope without being made a closure, and a closure is
# not a plain function pointer so it could not cross the C ABI anyway.

proc firstInt(json: string; out1: var int): bool =
  ## The first integer in a JSON array, for the `hookArgs` fallback path.
  ##
  ## Not a parser. The payload is `[2]` or `[2,true]` and the host is its only
  ## producer, so a scan for the first run of digits is the whole job — and an
  ## enum now arrives as exactly that, which is the change this path exists to
  ## take advantage of.
  out1 = 0
  var i = 0
  var neg = false
  while i < json.len and (json[i] < '0' or json[i] > '9'):
    if json[i] == '-':
      neg = true
    elif json[i] != '[' and json[i] != ' ':
      return false
    inc i
  if i >= json.len:
    return false
  var n = 0
  while i < json.len and json[i] >= '0' and json[i] <= '9':
    n = n * 10 + (ord(json[i]) - ord('0'))
    inc i
  out1 = (if neg: -n else: n)
  result = true

proc noteCondition(mask: int) =
  inc gConditionChanges
  gConditionMask = mask
  gConditionMaskKnown = true

proc onShotFired(target: string) =
  inc gShots

proc onWeaponInit(target: string) =
  inc gWeaponChanges

proc onConditionUpdated(target: string) =
  ## The last-resort form: something changed, and nothing says what.
  inc gConditionChanges

proc onConditionArgs(target, args: string): HookResult =
  ## The JSON form. `PhysicalConditionUpdated` fires when a limb state changes,
  ## which is a handful of times a raid, so 2 µs of payload here is free — this
  ## is exactly the case `docs/MODDING.md` says to use `hookArgs` for.
  var m = 0
  if firstInt(memberRaw(args, "args"), m):
    noteCondition(m)
  else:
    inc gConditionChanges
  carryOn()

proc onConditionTyped(f: PatchFrame): TypedResult =
  ## The typed form. One register read, no payload, no handle.
  var ok = false
  let m = argInt(f, 0, ok)
  if ok:
    noteCondition(int(m))
  else:
    inc gConditionChanges
  frameContinue()

proc onLerpCamera(target: string) =
  ## The fallback frame handler: no `this`, so every animator's firing steps the
  ## model. Correct for a raid with one animator in it and wrong for any other,
  ## which is why the typed form is preferred and why installing this one says
  ## so.
  onFrame(0'u64)

proc onLerpTyped(f: PatchFrame): TypedResult =
  ## The frame, with `this` in hand. A postfix: the original has run, BSG's own
  ## effectors have had their say, and this mod's impulse lands after them —
  ## which is what the BepInEx build did and what the JSON patch could not
  ## afford.
  onFrame(selfPointer(f))
  frameContinue()

proc installHooks() =
  ## Four detours, each reported individually, each taking the cheapest shape
  ## this host offers. A method that cannot be patched costs that one signal;
  ## the C# original would have failed to load.
  if gHooksInstalled:
    return
  gHooksInstalled = true

  gTypedFrames = typedPatchesReady()
  if gTypedFrames:
    info "sway  the host offers typed patches; using them on the frame and " &
         "on the condition mask"
  else:
    warn "sway  this host has no typed patches (ABI revision 4). Falling back " &
         "to the JSON forms, and the frame handler cannot tell the local " &
         "player's animator from a bot's"

  if hook("EFT.Player::OnMakingShot", onShotFired) == Ok:
    info "hooked EFT.Player::OnMakingShot"
  else:
    warn "no shot disturbance: " & lastError()

  if hook("EFT.Animations.ProceduralWeaponAnimation::InitWeaponData",
          onWeaponInit) == Ok:
    info "hooked ProceduralWeaponAnimation::InitWeaponData"
  else:
    warn "weapon changes will not reset the inertia state: " & lastError()

  # The condition mask, in order of preference. All three end at the same
  # place; only the first two carry the mask, and only the mask carries the
  # neurological tremor condition.
  const CondTarget =
    "EFT.Animations.ProceduralWeaponAnimation::PhysicalConditionUpdated"
  var condOk = false
  if gTypedFrames:
    if hookTyped(CondTarget, onConditionTyped) == Ok:
      condOk = true
      info "hooked PhysicalConditionUpdated (typed; the mask is read from " &
           "the register it arrives in)"
  if not condOk:
    if hookArgs(CondTarget, onConditionArgs) == Ok:
      condOk = true
      info "hooked PhysicalConditionUpdated (JSON arguments; the mask arrives " &
           "as a number)"
  if not condOk:
    if hook(CondTarget, onConditionUpdated) == Ok:
      condOk = true
      warn "hooked PhysicalConditionUpdated without its argument: arm injury " &
           "comes from the health controller only, and the stim tremor " &
           "condition cannot be seen at all"
  if not condOk:
    warn "arm injury will not be noticed: " & lastError()

  # LerpCamera runs every rendered frame, on Unity's main thread, and this is
  # where the whole mod happens: sample, step, actuate. A typed postfix first,
  # because that is the shape the BepInEx original had and it is now affordable;
  # the prefix if the host cannot.
  const FrameTarget = "EFT.Animations.ProceduralWeaponAnimation::LerpCamera"
  var frameOk = false
  if gTypedFrames:
    if hookReturnTyped(FrameTarget, onLerpTyped) == Ok:
      frameOk = true
      success "hooked LerpCamera as a typed postfix — the impulse lands after " &
              "BSG's own effectors, as it did under BepInEx"
    elif hookTyped(FrameTarget, onLerpTyped) == Ok:
      frameOk = true
      info "hooked LerpCamera as a typed prefix (a postfix was refused: " &
           lastError() & ")"
  if not frameOk:
    if hook(FrameTarget, onLerpCamera) == Ok:
      frameOk = true
      info "hooked LerpCamera as a plain prefix"
  if not frameOk:
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
  var payload = "{\"hands\":[" & fmt3(o.hands.x) & "," & fmt3(o.hands.y) & "," &
                fmt3(o.hands.z) & "],\"camera\":[" & fmt3(o.camera.x) & "," &
                fmt3(o.camera.y) & "," & fmt3(o.camera.z) & "],\"multiplier\":" &
                fmt3(o.multiplier) & ",\"clipped\":" &
                (if o.clipped: "true" else: "false") & ",\"actuating\":" &
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
       "  support " & fmt3(s.supportFactor) &
       "  handling " & fmt3(s.handlingFactor)
  info "sway  stamina " & fmt3(s.stamina) & "  oxy " & fmt3(s.oxygen) &
       "  arms " & fmt3(s.armStamina) & "  exertion " & fmt3(s.exertion)
  info "sway  ergo " & fmt3(s.ergonomics) & "  weight " & fmt3(s.weightKg) &
       " kg  recoil " & fmt3(s.recoilStat) &
       "  fracture " & (if s.armFractured: "yes" else: "no") &
       "  tremor " & (if s.neuroTremor: "yes" else: "no")
  info "sway  breath " & fmt3(d.breath.rateBpm) & " bpm  phase " &
       fmt3(d.breath.phase) & "  pulse " & fmt3(d.heart.bpm) & " bpm"
  info "sway  multiplier " & fmt3(d.last.multiplier) &
       (if d.last.clipped: "  (output at its ceiling)" else: "")
  info "sway  hands  " & fmtVec(d.last.hands)
  info "sway  camera " & fmtVec(d.last.camera)
  if gForeignFrames > 0:
    info "sway  frames driven " & $gFrames & ", firings for another " &
         "animator dropped " & $gForeignFrames

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

  # Every value, brought inside the range the offline characterisation found it
  # is stable in — and every one that had to move, said out loud. A JSON file
  # has no slider to constrain it, so this is the only thing standing between a
  # typo and a spring integrating a NaN.
  let clamps = clampTuning(gTuning)
  for m in clamps:
    warn "sway  " & m

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
  ## `aowl run mods/sway` ends here, and this is the only thing that has ever
  ## established anything about how this mod behaves.
  ##
  ## It is not a demo and it is not a smoke test. It drives the model through
  ## `model/characterise.nim` — step responses against the closed form of the
  ## oscillator the inertia source claims to be *and* of the game's own rotation
  ## spring, the spring's clamp and saturation, the 131-entry limiter tables and
  ## what the clamp does to a config full of infinities, a mouse flick,
  ## sixty-second envelopes at three levels of exhaustion, four frame rates, a
  ## jittered frame clock, a thirty-round burst, every shipped preset, the
  ## spring calibration, and a sweep of every tunable that can destabilise it —
  ## and it fails if any measured number leaves its band.
  ##
  ## It ends with a block that asserts nothing: the model's behaviour in the
  ## units a raid can contradict — settling time, overshoot, steady-state
  ## amplitude at rest and at full exertion — and the short list of what one
  ## raid would settle. That block exists so that a player can say which number
  ## is wrong instead of saying that it feels off.
  ##
  ## Note what it does *not* touch: nothing in `game/`. The model takes a state
  ## record and a tuning record and returns two vectors, and that is still true
  ## now that something is on the other end of it.
  let cal = defaultCal()
  info "sim  characterising the model against the shipped tuning"
  info "sim  spring assumed: ReturnSpeed " & fmtNum(cal.returnSpeed) &
       ", Damping " & fmtNum(cal.damping) &
       ", acceleration " &
       (if cal.perFrameAccel: "per frame" else: "per second") &
       " (see model/spring.nim)"

  var rep = characterise(cal, true)

  var i = 0
  while i < rep.summaryFrom:
    let c = rep.checks[i]
    if c.banded and not c.ok:
      error "sim  " & line(c)
    else:
      info "sim  " & line(c)
    inc i

  info "sim  stable ranges, swept:"
  for p in rep.ranges:
    if p.ok:
      info "sim    " & line(p)
    else:
      error "sim    " & line(p)

  # And last, because it is the part written for a reader rather than for a
  # gate: the model's behaviour in the units a raid can contradict, and the
  # short list of what one raid would settle. Nothing here is asserted.
  info "sim  ================ the model, as numbers a raid can argue with ==="
  while i < rep.checks.len:
    info "sim  " & line(rep.checks[i])
    inc i

  if rep.failures == 0 and rep.rangeFailures == 0:
    success "sim  " & $rep.checks.len & " measurements and " &
            $rep.ranges.len & " parameter sweeps, all inside their bounds. " &
            "This is the model, not the game: nothing here has run against " &
            "BSG's client."
  else:
    error "sim  " & $rep.failures & " measurement(s) and " &
          $rep.rangeFailures & " parameter range(s) outside their bounds"

proc onUpdate(elapsedMs: int64): Status =
  inc gTicks

  if side() == sideSim:
    if not gStarted:
      gStarted = true
      simSelfTest()
    return Ok

  if side() != sideClient:
    return Ok

  # The static-field probe, above the raid gate on purpose. It needs a runtime
  # and nothing else, and everything below `world.ready()` waits for an
  # animator that only exists in a raid — so put here it runs on every client
  # boot, and put below it would go on being a code path nothing had executed.
  # `openRuntime` is idempotent and is called again below for the hooks.
  if openRuntime():
    probeStaticRoot()

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
       " rendered frames (" & $gForeignFrames & " firings were another " &
       "animator's and were dropped)"
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
