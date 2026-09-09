## ar/phase.nim -- "WHERE IS THE CLIENT, REALLY?", asked of the host.
##
## The mod needs this exactly twice, and both are places where guessing has
## already cost this project time:
##
##   1. **Before arming.** Driving the main menu while a raid is loading or
##      running is not a mistake that produces a refusal; it produces presses
##      into a UI that is not there. So arming REFUSES when a live `GameWorld`
##      is readable, and the refusal says so rather than failing later.
##   2. **For the verdict.** `AutoRaid CMDLINE VERDICT PASS` is emitted when the
##      client reaches `DEPLOYED`, which is the game's own deploy signal
##      (`SpatialAudioSystem::AfterGameStarted` / `ExfiltrationTimerSound
##      Player::AfterGameStarted`, via the host's `raidphase.nim`). It is NOT
##      emitted when the last button press returned, which is not evidence that
##      anything happened.
##
## WHY THE HOST ANSWERS THIS AND NOT THE MOD. The deploy signal is two detours
## on methods the host already hooks. A mod that installed its own would be a
## SECOND detour on those functions, and the second detour overwrites the first's
## trampoline and silently kills the first feature. Riding an existing detour --
## here, by asking the host a question -- is the rule, not a compromise.
##
## THREE OUTCOMES. `asked = false` means the host has no `raid_phase` verb (an
## older host): that is INCONCLUSIVE and must never be reported as "not
## deployed", which is what a bare boolean would have said.

import aowlspt
import aowlspt/json

type
  RaidPhase* = object
    asked*: bool       ## the host answered the verb at all
    phase*: string     ## MENU | LOADING | DEPLOYED | RESULTS | UNKNOWN
    gameWorld*: bool    ## a live GameWorld is readable
    why*: string       ## the host's own explanation of how it decided

var gMissingSaid = false

proc raidPhase*(): RaidPhase =
  ## Ask once. Cheap -- the host copies integers and a short string -- but not
  ## free, so callers poll it on a bounded cadence rather than every frame.
  result = RaidPhase(asked: false, phase: "UNKNOWN", gameWorld: false, why: "")
  var raw = ""
  let empty = ""
  if call("aowlspt.host::raid_phase", empty, raw) != Ok or raw.len == 0:
    if not gMissingSaid:
      gMissingSaid = true
      warn "AutoRaid: this host has no `aowlspt.host::raid_phase` verb, so " &
           "the mod cannot tell MENU from LOADING from DEPLOYED. Arming will " &
           "NOT be blocked on that account -- refusing to arm on a question " &
           "nobody answered would be worse -- but every verdict that depends " &
           "on the phase will be INCONCLUSIVE and will say so."
    return
  result.asked = true
  result.phase = asText(field(raw, "phase"), "UNKNOWN")
  result.gameWorld = asBool(field(raw, "gameWorld"), false)
  result.why = asText(field(raw, "why"), "")

proc inRaid*(p: RaidPhase): bool =
  ## Is the client provably NOT at the menu? A NULL GameWorld is deliberately
  ## NOT claimed as proof of the menu -- it is merely the absence of proof of a
  ## raid -- so this asks the positive question only.
  p.asked and (p.gameWorld or p.phase == "LOADING" or p.phase == "DEPLOYED")

proc deployed*(p: RaidPhase): bool =
  p.asked and p.phase == "DEPLOYED"
