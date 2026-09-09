## Suppression: a bool, integrated into something a decision can use.
##
## SAIN's suppression is a real accumulator. Every round that passes near a bot
## raises it, it decays on a timer, and two thresholds hang off it: seek cover,
## and stay down. That requires a projectile callback -- SAIN patches
## `BulletClass` -- and no such patch exists post-1.0 without Harmony.
##
## What the game *does* expose is `BotMemory.IsUnderFire`, which is a boolean.
## Reading it and mapping true to 1.0 was the previous version of this mod, and
## it made both thresholds meaningless: a level that is only ever 0 or 1 passes
## `suppressionSeekCoverLevel` and `suppressionPinnedLevel` on the same tick, so
## a bot was never merely suppressed, only pinned, and it un-pinned the instant
## the flag cleared. Every tuning number in that part of `settings.nim` was
## decoration.
##
## Integrating the bool restores the shape. Under fire for a moment is a bot
## that flinches; under fire for three seconds is a bot that will not leave
## cover. Two more inputs sharpen it, and both are things this mod can measure
## without a new binding:
##
##  * **Being hit.** The strongest suppressor there is, and it arrives two
##    ways. `feed`'s `told` parameter is an exact hit the damage postfix in
##    `sain.nim` was handed at the moment it landed; its `health` parameter is
##    the drop between two decisions, which is the whole reading on a host or a
##    build where that hook refused, and is up to four ticks late when it is.
##    Both go through the same rise, because a threshold in `settings.nim` has
##    to mean one thing whichever reading a host can produce.
##  * **An enemy who has line of sight on us.** Not the same as being shot at,
##    and it is what keeps a bot's head down after the firing stops.
##
## The one thing it deliberately does not model is a near miss that hit nothing
## and nobody, because that genuinely needs the projectile callback. A bot here
## is therefore slightly less suppressible than SAIN's. That is stated in
## `README.md` rather than papered over with a guess.
##
## Nothing here allocates and nothing here calls the game.

import types
import settings
import toggle
import vec

type
  Suppression* = object
    ## Per bot, carried between ticks.
    level*: float
    ## Set while the level is above the pinned threshold, and -- this is the
    ## point of it being a `Toggle` rather than a comparison -- held there for
    ## `suppressionPinnedMinSeconds` after the level falls back. A bot that
    ## stands up the frame the shooting pauses is a bot that dies in that
    ## frame.
    pinned*: Toggle
    ## Health at the last update, for the damage delta. -1 means "no reading
    ## yet", which is distinct from "full health" and matters on the first
    ## tick after a spawn.
    lastHealth*: float
    lastDamageAt*: float

func newSuppression*(): Suppression =
  Suppression(level: 0.0, pinned: newToggle(false), lastHealth: -1.0,
              lastDamageAt: -9999.0)

proc feed*(sup: var Suppression; underFire: bool; enemyLooking: bool;
           health: float; s: Settings; now: float; dt: float;
           told: float = 0.0): float =
  ## One tick. Returns the damage taken since the last call, as a fraction of
  ## full health, which the caller wants anyway for `SelfView.recentDamage`.
  ##
  ## `told` is damage the game reported directly -- the damage postfix in
  ## `sain.nim`, drained into this bot since its last decision. It is a
  ## *parameter of this function* rather than a second entry point, and that is
  ## the whole design decision here.
  ##
  ## The obvious shape is a separate `feedHit` that the driver calls before
  ## `feed`. It was written that way first and it was wrong, for a reason the
  ## self-test found rather than a reason anybody predicted: `feed` skips its
  ## decay on any tick where something raised the level, so crediting the hit
  ## outside `feed` left the same hit worth one decay step less than the same
  ## hit inferred from health. A bot on a host with the damage hook would then
  ## have been tuned by different numbers from one without, and every threshold
  ## in `settings.nim` would have meant two things. One function, one rise, one
  ## decay decision.
  ##
  ## **The larger of the two, never the sum.** They are two measurements of one
  ## fact: the health delta already contains the hits the hook reported. Adding
  ## them would double-count every hit on a host that has the hook -- which is
  ## exactly the sort of error that looks like tuning.
  var damage = 0.0
  if sup.lastHealth >= 0.0 and health < sup.lastHealth:
    damage = sup.lastHealth - health
  sup.lastHealth = health
  if told > damage:
    damage = told
  if damage > 0.0:
    sup.lastDamageAt = now

  var rise = 0.0
  if underFire:
    rise = rise + s.suppressionRisePerSecond * dt
  if enemyLooking:
    # A quarter rate: being looked at is pressure, not fire.
    rise = rise + s.suppressionRisePerSecond * 0.25 * dt
  if damage > 0.0:
    # Scaled by how much was taken: a graze is not a burst to the chest.
    rise = rise + s.suppressionOnHit * clampf(damage * 4.0, 0.35, 2.5)

  let decay = (if rise > 0.0: 0.0 else: s.suppressionDecayPerSecond * dt)
  sup.level = clampf(sup.level + rise - decay, 0.0, 1.0)

  # The pinned toggle, with a minimum dwell. `set` reports the edge; the dwell
  # is enforced by refusing to clear it early rather than by a second timer.
  if sup.level >= s.suppressionPinnedLevel:
    discard set(sup.pinned, true, now)
  elif sup.pinned.value and
       timeSinceChange(sup.pinned, now) >= s.suppressionPinnedMinSeconds:
    discard set(sup.pinned, false, now)

  result = damage

func effectiveLevel*(sup: Suppression; s: Settings): float =
  ## What the ladder reads.
  ##
  ## While the pinned toggle is held open by its minimum dwell the level is
  ## reported at the pinned threshold even though the accumulator has fallen
  ## below it. That is the hysteresis made visible to the one consumer that
  ## needs it, rather than requiring every consumer to know about the toggle.
  if sup.pinned.value and sup.level < s.suppressionPinnedLevel:
    return s.suppressionPinnedLevel
  result = sup.level

func timeSinceDamaged*(sup: Suppression; now: float): float =
  now - sup.lastDamageAt
