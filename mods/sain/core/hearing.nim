## Hearing: what a bot can know without seeing.
##
## ## Why this file is the deepest thing in the port
##
## SAIN's hearing is a subscriber. `BotSoundPlayerComponent`, `Player.OnMakingShot`
## and BSG's own `BetterAudio` events call into it with a sound *kind*, a
## position and a range, and SAIN then decides whether the bot noticed. None of
## those subscriptions is available here: a native mod cannot hand a managed
## delegate to a C# event, and post-1.0 has no Harmony to patch the raise site.
## So the obvious port of this file is "nothing", and the previous version of
## this mod said exactly that -- `heardThisTick` was hard-coded false and every
## decision that read it was dead.
##
## But a sound event is not information the game holds privately. It is a
## *consequence* of state the mod can already read: something moved, at some
## speed, at some place. Footsteps are a function of position over time. A
## sprint is a footstep with a bigger radius and a flag we already read for
## other reasons. So this file computes the sound rather than receiving it,
## and everything downstream -- the last known place, the search, the freeze,
## the "heard from peace" personality split -- comes alive off numbers the
## fast path was already fetching.
##
## What it cannot compute is a sound with no observable cause in this mod's
## own view: a door two rooms away, a bot's own gunshot heard by a third bot,
## looting. Those stay silent, and `README.md` lists them as such. A silent
## sensor decays into "no contact", which is the correct behaviour for a sense
## that is absent rather than one that is lying.
##
## ## The model
##
## Three steps, all arithmetic:
##
##  1. **Loudness.** A sound kind has a base range in the open. Motion-derived
##     sounds scale that range with speed, because a walk is not a sprint.
##  2. **Attenuation.** Range is multiplied by the listener's acuity
##     (personality and difficulty) and, when the listener has no line of
##     sight, by one occlusion factor. One number rather than a material model:
##     a material model needs geometry and this does not.
##  3. **Localisation.** A sound that is heard is heard *approximately*. The
##     error grows with distance, so a shot at 200 m gives a bearing and a shot
##     at 5 m gives a place. This is the step that stops a hearing model from
##     being wallhacks with extra steps.
##
## Nothing here allocates and nothing here calls the game.

import vec
import types
import settings
import rng

type
  SoundEvent* = object
    ## One thing that made a noise.
    ##
    ## Built by the client layer per tick from what it can see moving, or by a
    ## test by hand. Values, not objects: a tick's worth of these lives on the
    ## stack.
    kind*: SoundKind
    position*: Vec3
    ## Who made it, keyed the same way `EnemyView` is -- so a sound can be
    ## attributed to a known enemy rather than only to a place. Zero means
    ## "nobody this bot can name", which is the `heardFromPeace` case.
    key*: uint64
    ## Absolute time it happened.
    at*: float
    ## How much louder or quieter than the kind's nominal range, 1.0 = nominal.
    ## Speed feeds this for motion sounds.
    intensity*: float

  Heard* = object
    ## What a listener made of a `SoundEvent`.
    audible*: bool
    ## Where the listener thinks it came from -- not where it came from.
    position*: Vec3
    ## 0..1: at the edge of hearing, or right on top of it. Feeds the threat
    ## bump so that a distant shot is not the same evidence as a near one.
    loudness*: float
    distance*: float

func emptySound*(): SoundEvent =
  SoundEvent(kind: skNone, position: zeroVec(), key: 0'u64, at: -9999.0,
             intensity: 0.0)

func nothingHeard*(): Heard =
  Heard(audible: false, position: zeroVec(), loudness: 0.0, distance: 9999.0)

func baseRange*(k: SoundKind): float =
  ## Metres at which a sound of this kind is audible in the open, at nominal
  ## intensity.
  ##
  ## These are SAIN's own ranges where SAIN has one (`SoundTypes` and the
  ## per-type dispersion table); the rest are judgement calls at the same
  ## scale. They are deliberately generous compared to what a *player* hears,
  ## because a bot has no headphones and the acuity multiplier is where a
  ## difficulty setting pulls them back.
  case k
  of skNone: 0.0
  of skFootStep: 22.0
  of skSprint: 45.0
  of skShot: 250.0
  of skSuppressedShot: 90.0
  of skGrenadePin: 12.0
  of skExplosion: 400.0
  of skDoor: 35.0
  of skLooting: 18.0
  of skReload: 20.0
  of skPain: 40.0
  of skHeal: 12.0
  of skConversation: 25.0
  of skBulletImpact: 60.0

func soundName*(k: SoundKind): string =
  case k
  of skNone: "None"
  of skFootStep: "FootStep"
  of skSprint: "Sprint"
  of skShot: "Shot"
  of skSuppressedShot: "SuppressedShot"
  of skGrenadePin: "GrenadePin"
  of skExplosion: "Explosion"
  of skDoor: "Door"
  of skLooting: "Looting"
  of skReload: "Reload"
  of skPain: "Pain"
  of skHeal: "Heal"
  of skConversation: "Conversation"
  of skBulletImpact: "BulletImpact"

func alerting*(k: SoundKind): bool =
  ## Whether this kind of sound is worth *going to look*, as opposed to merely
  ## worth noting. SAIN's distinction between a sound that starts a search and
  ## one that only turns a head; getting it wrong is what makes bots abandon
  ## their post because somebody healed.
  case k
  of skShot, skSuppressedShot, skExplosion, skSprint, skPain, skGrenadePin,
     skBulletImpact, skDoor: true
  else: false

# ---------------------------------------------------------------------------
# Deriving a sound from motion
# ---------------------------------------------------------------------------

const
  WalkThreshold* = 0.6
    ## Metres per second below which movement makes no useful noise. A player
    ## creeping is not silent in the game either, but they are quiet enough
    ## that the difference is inside the localisation error anyway.
  SprintThreshold* = 3.4
    ## Above this the gait is a sprint whether or not the sprint flag was read.
    ## Both are used: the flag is authoritative when the binding took, and the
    ## speed is the fallback when it did not, which is exactly the degradation
    ## rule the rest of this mod follows.

func motionSound*(prev, now1: Vec3; dt: float; sprintFlag: bool;
                  at: float; key: uint64): SoundEvent =
  ## The footstep a moving thing makes, from two positions and the time
  ## between them.
  ##
  ## This is the whole trick of the file. It is derived, not observed, and the
  ## derivation is exact for the part that matters: something that moved eight
  ## metres in one second was running, and running is loud. The part it cannot
  ## know -- the surface, whether they were on a ladder, whether the game
  ## actually played a footstep this frame -- affects the radius by less than
  ## the localisation error does.
  result = emptySound()
  if dt <= 0.0001:
    return
  let speed = flatDistance(prev, now1) / dt
  if speed < WalkThreshold:
    return
  result.position = now1
  result.key = key
  result.at = at
  if sprintFlag or speed >= SprintThreshold:
    result.kind = skSprint
    # A sprint at the threshold is a sprint; a sprint at eight metres a second
    # is not louder in the game, so the intensity saturates rather than growing
    # without bound.
    result.intensity = clampf(speed / SprintThreshold, 0.8, 1.4)
  else:
    result.kind = skFootStep
    result.intensity = clampf(speed / SprintThreshold, 0.25, 1.0)

# ---------------------------------------------------------------------------
# Listening
# ---------------------------------------------------------------------------

func hearingRange*(e: SoundEvent; s: Settings; occluded: bool;
                   occGain: float = -1.0): float =
  ## The radius at which this listener would hear this sound.
  ##
  ## `occGain` is a MEASURED acoustic transmission gain in [0, 1] -- the fraction
  ## of the sound that actually reaches the listener through whatever geometry
  ## is between them -- as produced by the host's raytraced-audio feature
  ## (`aowl_audio_occlusion`, `host/Aowlspt.Host.Il2Cpp/audioray.nim`). A
  ## NEGATIVE value means "not measured", which is the default and is the only
  ## thing every existing caller passes, so their behaviour is unchanged to the
  ## bit.
  ##
  ## The two paths are deliberately not blended. When a real gain is available
  ## it REPLACES `s.hearingOcclusionFactor` rather than multiplying it: the
  ## scalar is a stand-in FOR this measurement, and applying both would attenuate
  ## twice and make a raytraced bot deafer than a scalar one -- a regression that
  ## would look like the feature working.
  ##
  ## Note the model this preserves: occlusion scales the RADIUS, so a gain of 0.5
  ## halves the distance at which the sound is noticed. It is not a loudness
  ## multiplier. `listen` derives loudness from `d / r` afterwards, so the two
  ## stay consistent by construction.
  var r = baseRange(e.kind) * e.intensity * s.hearingAcuity
  if occGain >= 0.0:
    # A measured gain applies whether or not the caller also thought the pair was
    # occluded: the raytracer's answer is the better evidence, and 1.0 (nothing
    # in the way) correctly leaves the radius alone.
    r = r * clampf(occGain, 0.0, 1.0)
  elif occluded:
    r = r * s.hearingOcclusionFactor
  result = r

proc listen*(e: SoundEvent; listener: Vec3; s: Settings; occluded: bool;
             now: float; r1: var Rng; occGain: float = -1.0): Heard =
  ## Did this bot hear it, and where does it think it came from?
  ##
  ## `r1` is the bot's own deterministic stream, so two bots hearing the same
  ## shot guess two different places -- which is what makes a squad converge on
  ## a rough area rather than all walking to one pixel. Determinism matters
  ## more than it looks: the tests replay this.
  result = nothingHeard()
  if e.kind == skNone:
    return
  if now - e.at > s.soundMemorySeconds:
    return
  let d = distance(listener, e.position)
  result.distance = d
  let r = hearingRange(e, s, occluded, occGain)
  if r <= 0.0 or d > r:
    return
  result.audible = true
  # Loudness falls off with distance rather than with distance squared: the
  # number is a *decision* input, not a physical intensity, and a linear ramp
  # from 1 at the source to 0 at the edge of hearing is what the thresholds
  # downstream were tuned against.
  result.loudness = clampf(1.0 - d / r, 0.0, 1.0)
  # Localisation error, symmetric, growing with distance and shrinking with
  # loudness. A whisper at the edge of hearing is a direction; a shot in the
  # next room is a place.
  let err = d * s.hearingPositionError * (1.35 - result.loudness)
  let ex = rangeF(r1, -err, err)
  let ez = rangeF(r1, -err, err)
  result.position = vec3(e.position.x + ex, e.position.y, e.position.z + ez)

func threatBump*(h: Heard; k: SoundKind): float =
  ## How much a heard sound raises the threat this bot assigns to its source.
  ##
  ## A gunshot is evidence of an enemy; a footstep is evidence of *something*.
  ## SAIN reaches the same split through separate handlers per sound type.
  if not h.audible:
    return 0.0
  let weight = (if alerting(k): 0.5 else: 0.22)
  result = weight * (0.4 + 0.6 * h.loudness)
