## bridge/see.nim -- THE FACTS THIS CLIENT CAN ACTUALLY MEASURE, AND ONLY THOSE.
##
## IMPLEMENTED, because there is a proven read path:
##   * `raid_started` / `raid_ended`, from transitions of
##     `aowlspt.host::raid_phase` (the host's own deploy signal; proven by
##     mods/autoraid's DEPLOYED verdict, `ar/phase.nim`).
##   * `tick`, once per second while the phase says we are in a raid, because
##     the contract makes it the sim clock.
##
## NOT IMPLEMENTED, and each names the primitive that is missing rather than
## being approximated:
##   * `player_moved` needs the local player's position. The read path exists
##     but is IL2CPP-offset work owned by another mod: `Player.MovementContext`
##     @+0x60 -> position (docs/BOTNAV.md section 1 lists the Player offsets
##     proven live). This mod has no C translation unit, resolves no name and
##     will not copy an offset table it cannot verify.
##   * `player_seen` / `player_aimed_at` need the LIVE BOT CENSUS plus the
##     camera forward vector. The census exists only inside
##     `mods/sain/client/bridge.nim`, which walks `GameWorld` with its own
##     verified offsets; it emits NO bus event and exposes nothing to another
##     mod (MEASURED 2026-09-06: `grep -rn 'emit("' mods/sain` finds nothing).
##     Without it there is no `personId -> live bot` mapping, and
##     CLIENT-CONTRACT section 6 is explicit that a person the client has not
##     mapped is simply NOT sent -- so sending nothing is the CORRECT behaviour
##     here, not a degradation.
##   * `player_fired` / `player_hit` / `npc_died` need detours the host does
##     not offer and this mod must not install (two detours on one function
##     kill the first one).
##
## The refusal is logged ONCE, at load, with those names in it. A silent gap is
## how "the NPCs never notice me" becomes an afternoon of looking in the wrong
## process.

import aowlspt
import aowlspt/server
import aowlspt/json
import core
import spawn

const
  PhasePollMs* = 2000'i64
  TickMs* = 1000'i64

var gLastPhasePoll = 0'i64
var gLastTick = 0'i64
var gPhase = "UNKNOWN"
var gInRaid = false
var gStarts = 0
var gEnds = 0
var gTicks = 0

proc phase*(): string = gPhase
proc inRaid*(): bool = gInRaid
proc raidStarts*(): int = gStarts
proc raidEnds*(): int = gEnds
proc ticksSent*(): int = gTicks

proc announceStubs*() =
  if saidOnce("see-stubs"): return
  warn "basement see: only `raid_started`, `raid_ended` and `tick` are sent. " &
       "`player_moved`, `player_seen`, `player_aimed_at`, `player_fired`, " &
       "`player_hit` and `npc_died` are NOT sent, and are not approximated. " &
       "The missing primitives, by name: the local player's position " &
       "(Player.MovementContext, an IL2CPP offset this mod does not own), the " &
       "live bot census (exists only inside mods/sain, which exposes it on no " &
       "bus event), and the fire/hit detours (the host offers none, and a " &
       "second detour on a hooked function silently kills the first). Until " &
       "one of those is exposed generically, an NPC cannot notice you."

proc sendStarted(mapName: string) =
  var d = newDoc()
  d.setText("map", mapName)
  d.setNumber("spawnX", 0.0)
  d.setNumber("spawnY", 0.0)
  d.setNumber("spawnZ", 0.0)
  d.setBool("positionKnown", false)
  d.setText("note", "spawn coordinates are NOT read from the world: this " &
            "client has no position primitive. The map name is the one this " &
            "client ASKED autoraid for, not one read back from the raid.")
  gStarts = gStarts + 1
  observe(d, "raid_started")

proc sendEnded(reason: string) =
  var d = newDoc()
  d.setText("reason", reason)
  gEnds = gEnds + 1
  observe(d, "raid_ended")

proc tick*(nowMsValue: int64) =
  if nowMsValue - gLastPhasePoll >= PhasePollMs:
    gLastPhasePoll = nowMsValue
    let p = raidPhase()
    if p.asked:
      gPhase = p.phase
      let nowIn = p.gameWorld or p.phase == "DEPLOYED"
      if nowIn and not gInRaid:
        gInRaid = true
        sendStarted(armedMap())
      elif gInRaid and not nowIn:
        gInRaid = false
        # The REASON is not knowable from the phase alone -- extract, death
        # and disconnect all land at RESULTS or MENU -- so it is reported as
        # what was actually observed, never guessed as "extract".
        sendEnded("disconnect")
  if gInRaid and nowMsValue - gLastTick >= TickMs:
    gLastTick = nowMsValue
    var d = newDoc()
    d.setNumber("nowMs", int(nowMsValue))
    gTicks = gTicks + 1
    observe(d, "tick")
