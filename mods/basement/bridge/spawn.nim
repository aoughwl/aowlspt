## bridge/spawn.nim -- ALWAYS IN RAID: ASK THE BACKEND WHERE, ASK AUTORAID TO GO.
##
## At MENU, `GET /aowlspt/basement/spawn` and hand the answer to `mods/autoraid`
## as the bus event `autoraid.arm {map, side, source}` (added there in commit
## 53c7398; it answers on `autoraid.armed {source, map, accepted, why}`).
##
## THE TWO RULES THAT KEEP THIS FROM BECOMING A LOOP, both enforced by state
## rather than by a comment:
##
##   1. **Never re-arm while `autoraid.armed` has not answered.** A request
##      dropped into silence would otherwise be retried every poll, and the
##      raid machine would be armed several times over.
##   2. **Never arm while the phase is not MENU.** `raid_phase` is asked EVERY
##      time, immediately before arming, and `asked = false` (an older host)
##      REFUSES rather than guessing -- driving the menu while a raid is
##      loading does not produce an error, it produces presses into a UI that
##      is not there.
##
## The latch clears when the phase is observed away from MENU (we left, so the
## next MENU is a new opportunity) or when `autoraid.armed` says `accepted:
## false` (nothing was armed, so nothing is pending).

import aowlspt
import aowlspt/server
import aowlspt/json
import core

const SpawnPollMs* = 5000'i64
  ## A bounded cadence, not every frame. The verb is cheap, not free.

var gLastPoll = 0'i64
var gRequestPending = false   ## a GET /spawn is in flight
var gArmPending = false       ## autoraid.arm sent, autoraid.armed not back
var gArmed = false            ## autoraid accepted; wait for the phase to move
var gArmedMap = ""
var gArms = 0
var gRefusals = 0
var gLastWhy = ""
var gLastPhase = "UNKNOWN"
var gSubscribed = false

proc armedMap*(): string = gArmedMap
proc arms*(): int = gArms
proc spawnRefusals*(): int = gRefusals
proc spawnWhy*(): string = gLastWhy
proc phaseSeen*(): string = gLastPhase
proc busy*(): bool = gRequestPending or gArmPending or gArmed

proc onArmed(payload: string): string =
  ## AutoRaid's answer. Both outcomes clear the pending latch -- the whole
  ## point of the reply is that a refusal is heard, not waited on forever.
  result = ""
  let source = asText(field(payload, "source"), "")
  if source != "basement": return
  gArmPending = false
  let ok = asBool(field(payload, "accepted"), false)
  let why = asText(field(payload, "why"), "")
  gLastWhy = why
  if ok:
    gArmed = true
    gArms = gArms + 1
    success "basement spawn: autoraid ACCEPTED the raid request (map " &
            gArmedMap & "). No further /spawn will be asked for until the " &
            "phase leaves MENU and comes back."
  else:
    gArmed = false
    gRefusals = gRefusals + 1
    warn "basement spawn: autoraid REFUSED the raid request for map \"" &
         gArmedMap & "\" -- " & why & ". Nothing is retried behind your back " &
         "on this poll; the next MENU is the next opportunity."

proc subscribe*() =
  if gSubscribed: return
  if on("autoraid.armed", onArmed) != Ok:
    warn "basement spawn: could NOT subscribe to `autoraid.armed`, so a raid " &
         "request would be sent into silence and the pending latch would " &
         "never clear. The /spawn gesture is DISABLED for this session " &
         "rather than looping."
    return
  gSubscribed = true

proc onSpawnBody*(status: int; body: string) =
  ## The completion of our `GET /spawn`. Called by the link, by id prefix.
  gRequestPending = false
  if status != 200:
    gRefusals = gRefusals + 1
    gLastWhy = "GET /spawn answered HTTP " & $status
    if not saidOnce("spawn-http:" & $status):
      warn "basement spawn: " & gLastWhy & ". The route may not exist on this " &
           "backend yet; nothing is armed."
    return
  if not asBool(field(body, "ok"), false):
    gRefusals = gRefusals + 1
    gLastWhy = asText(field(body, "err"), "the backend answered ok:false")
    if not saidOnce("spawn-notok:" & gLastWhy):
      warn "basement spawn: the backend declined to place the player -- " &
           gLastWhy
    return
  # The backend answers `{ok, spawn:{map,x,y,z,reason}, raidRequested}`
  # (basement.nim::onSpawn); a top-level `map` is accepted too so an older
  # or hand-written answer still works. MEASURED 2026-09-06 by the SPT plugin
  # agent: this read the top level only and would have refused every answer.
  var map = asText(field(body, "spawn.map"), "")
  if map.len == 0: map = asText(field(body, "map"), "")
  if map.len == 0:
    gRefusals = gRefusals + 1
    gLastWhy = "the answer carried no `map`"
    warn "basement spawn: " & gLastWhy & ", and there is no default map worth " &
         "guessing at -- entering the wrong raid is worse than entering none."
    return
  if not gSubscribed:
    gRefusals = gRefusals + 1
    gLastWhy = "not subscribed to autoraid.armed"
    return
  gArmedMap = map
  var d = newDoc()
  d.setText("map", map)
  var side = asText(field(body, "spawn.side"), "")
  if side.len == 0: side = asText(field(body, "side"), "pmc")
  d.setText("side", side)
  d.setText("source", "basement")
  if emit("autoraid.arm", d.text) != Ok:
    gArmPending = false
    gRefusals = gRefusals + 1
    gLastWhy = "emit(autoraid.arm) failed"
    warn "basement spawn: could not EMIT `autoraid.arm`, so nothing asked " &
         "for a raid. Is mods/autoraid loaded on this side?"
    return
  gArmPending = true
  info "basement spawn: asked autoraid for map \"" & map & "\" (source " &
       "basement). Waiting for `autoraid.armed`; nothing else will be asked " &
       "for until it answers."

proc tick*(nowMsValue: int64) =
  if not spawnOnMenu(): return
  if not gSubscribed: return
  if busy():
    if gArmed:
      # The latch clears only when the client is provably somewhere else.
      if nowMsValue - gLastPoll < SpawnPollMs: return
      gLastPoll = nowMsValue
      let p = raidPhase()
      if p.asked:
        gLastPhase = p.phase
        if p.phase != "MENU" or p.gameWorld:
          gArmed = false
    return
  if nowMsValue - gLastPoll < SpawnPollMs: return
  gLastPoll = nowMsValue
  let p = raidPhase()
  if not p.asked:
    # INCONCLUSIVE, already announced once by `core.raidPhase`. Refusing here
    # is the safe direction: a press into a UI that is not there is worse than
    # a raid not entered.
    return
  gLastPhase = p.phase
  if p.phase != "MENU" or p.gameWorld: return
  gRequestPending = true
  if not httpGet(nextId("bmspawn"), routeUrl("/spawn")):
    gRequestPending = false
