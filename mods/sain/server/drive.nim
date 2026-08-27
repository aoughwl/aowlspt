## The one thing in this mod that actually reaches a bot.
##
## ## Why this file is on the SERVER side and contains no RVA
##
## Every other attempt to make SAIN drive bots went through `client/live.nim`,
## which resolves members by NAME at runtime. On this build that is fatal the
## moment it is USED (facts #143/#144/#145): the `il2cpp_class_*` exports are
## token-gated, a stock-shaped call returns a plausible RANDOM value rather than
## failing, and the client dies on the first dereference with a log
## byte-identical to a healthy run. Arming survived ~70 lookups and died binding
## `UnityEngine.Physics::Raycast`.
##
## So this file resolves nothing and binds nothing. It uses the channel the host
## ALREADY has: `aowlspt/botnav`, whose client-host side is a single kind=15
## detour on `EFT.BotOwner::UpdateManual` @ 0x81B7C0 -- byte-verified against a
## 16-byte prologue recorded offline, VirtualQuery on every hop, the whole body
## under one VEH guard, capped, flag-gated (`botNav`, default off) and
## self-disabling after eight trapped faults. See `abi/aowlspt_botnav.h` and
## `docs/BOTNAV.md`.
##
## **The minimum set of RVAs this feature needs is therefore ZERO NEW ONES.**
## The three it rides are already verified there:
##
##     EFT.BotOwner::UpdateManual  0x81B7C0   the tick, RCX = a live BotOwner
##     EFT.BotOwner::GoToPoint     0x81CB40   (not used here)
##     BotMover::SetTargetMoveSpeed 0x1A2B4D0 `movss [rcx+0x15C], xmm1; ret`
##
## The last of those is the whole of the observable this file drives, and it is
## the cheapest one available by a wide margin: two instructions, one float, one
## pointer hop (`[botOwner+0x3D0]`), no NavMesh, no path, no managed throw path,
## and it is visible to a human in about a second.
##
## ## The arming gate, and why it is not fact #141
##
## Nothing here arms on `whenReady("EFT.GameWorld")`. That gate tests type
## RESOLVABILITY and goes true ~47 ms after HOST RUNNING with no raid anywhere,
## which is a check that cannot fail (CLAUDE.md 9b). This file arms on the first
## BOT CENSUS -- a message the host can only produce from inside
## `BotOwner::UpdateManual`, which `BotsList::UpdateByUnity` calls only for a
## live bot in a live raid on Unity's own thread. It is positive evidence of a
## bot, read, not of a type name being spellable.
##
## ## What this does NOT claim
##
## Move speed is a PROXY for SAIN's difficulty, not a port of it. SAIN's real
## difficulty band changes a dozen coefficients inside the bot's brain, and the
## brain's decision layers cannot be subclassed without reflection. So
## `difficulty` here is honestly implemented -- read, converted, sent, and
## visible on screen -- and honestly partial, and `README.md` says so.

import aowlspt
import aowlspt/botnav

const
  MaxTracked* = 32
    ## The census rotates and is partial (~5 bots per payload, 191 chars), so
    ## rows accumulate here keyed on id. Capped: a corrupt count must not become
    ## an unbounded loop, and 32 is more bots than any census window will name
    ## before the oldest rows age out.
  MaxRowsPerCensus* = 16
    ## Hard ceiling on rows walked per payload, independent of what the payload
    ## claims. The parser already drops malformed rows; this bounds the good ones.
  RefreshEvery* = 10
    ## Re-send the command set every N censuses even when nothing changed.
    ## `botnav` is last-writer-wins across mods, so a set that is never repeated
    ## is a set another mod can silently take over.
  MaxFaults* = 8
    ## Consecutive refused sends before this path switches itself off for the
    ## session. Matches the host side's own budget.

type
  Tracked = object
    id: int
    seen: bool
    x, y, z: float
    lastCensus: int
    moved: bool     ## has this bot EVER changed position between two sightings

var
  gArmed = false
  gOff = false
  gScale = 0.5
  gLog = false
  gSpeed = -1.0
  gCensuses = 0
  gFaults = 0
  gSinceSend = 0
  gTrack: array[MaxTracked, Tracked]
  gTrackLen = 0
  gPairs = 0        ## how many times a bot was seen twice (the "could we look" number)
  gMovers = 0       ## how many DISTINCT bots were ever observed to move
  gReported = false

proc speedForScale*(scale: float): float =
  ## SAIN's 0..1 difficulty band -> `BotMover.MoveSpeed`, also 0..1.
  ##
  ## The floor is deliberate and is not a rounding artefact. `MoveSpeed` is
  ## written straight into the mover, and a bot pinned near zero is a bot that
  ## stands in a doorway for the whole raid -- which reads as "the mod broke the
  ## game", not as "easy". `easy` (0.15) lands at 0.49 and `deathwish` (1.0) at
  ## 1.0, a spread wide enough that a human can see which one is running.
  var s = scale
  if s < 0.0: s = 0.0
  if s > 1.0: s = 1.0
  result = 0.4 + 0.6 * s
  if result > 1.0: result = 1.0

proc round3(v: float): float =
  let n = int(v * 1000.0 + 0.5)
  float(n) / 1000.0

proc indexOf(id: int): int =
  result = -1
  var i = 0
  while i < gTrackLen and i < MaxTracked:
    if gTrack[i].id == id:
      return i
    inc i

proc note(id: int; x, y, z: float) =
  ## Record a sighting, and remember whether the bot has ever actually moved.
  ## This is the evidence the check below is built from; it is deliberately a
  ## property of the bot's position in the census, not of anything this file
  ## wrote.
  var idx = indexOf(id)
  if idx < 0:
    if gTrackLen >= MaxTracked:
      # Full. Recycle the least recently seen row rather than dropping the bot
      # silently -- a starved row would make the check read INCONCLUSIVE for a
      # reason that has nothing to do with the client.
      var oldest = 0
      var j = 1
      while j < MaxTracked:
        if gTrack[j].lastCensus < gTrack[oldest].lastCensus:
          oldest = j
        inc j
      idx = oldest
      gTrack[idx] = Tracked(id: id, seen: false, x: 0.0, y: 0.0, z: 0.0,
                            lastCensus: 0, moved: false)
    else:
      idx = gTrackLen
      inc gTrackLen
      gTrack[idx] = Tracked(id: id, seen: false, x: 0.0, y: 0.0, z: 0.0,
                            lastCensus: 0, moved: false)
  if gTrack[idx].seen:
    inc gPairs
    let dx = x - gTrack[idx].x
    let dy = y - gTrack[idx].y
    let dz = z - gTrack[idx].z
    if dx * dx + dy * dy + dz * dz > 0.0:
      if not gTrack[idx].moved:
        gTrack[idx].moved = true
        inc gMovers
  gTrack[idx].id = id
  gTrack[idx].seen = true
  gTrack[idx].x = x
  gTrack[idx].y = y
  gTrack[idx].z = z
  gTrack[idx].lastCensus = gCensuses

proc send(speed: float): bool =
  ## One command, addressed to every bot. `BotNavAll` is used rather than a row
  ## per bot on purpose: the census is PARTIAL and ROTATES, so a per-bot set
  ## would only ever steer the five bots that happened to fit in the last
  ## payload and would leave the rest vanilla -- which is precisely the "a
  ## setting that changes nothing" failure this work exists to remove.
  let st = sendBotCommands(@[moveSpeed(BotNavAll, speed)])
  if st == Ok:
    gFaults = 0
    gSinceSend = 0
    return true
  inc gFaults
  if gFaults >= MaxFaults and not gOff:
    gOff = true
    warn "sain: the drive path refused " & $gFaults &
         " command sets in a row and has switched itself off for this " &
         "session. Bots are back on their own brains; nothing is being " &
         "written to any mover"
  result = false

proc driveCheck*(): string =
  ## PASS / FAIL / INCONCLUSIVE on the FINISHED STATE, never on our own write.
  ##
  ## The property asserted is a negative about the live census: *no bot that
  ## this mod is commanding is frozen*. It is falsifiable, and here is the input
  ## that falsifies it -- a speed value that reaches the mover but is wrong
  ## (0.0, or a NaN, or written to the wrong offset) parks every bot, `gMovers`
  ## stays 0 while `gPairs` climbs, and this returns FAIL. A check that read
  ## back the speed we just sent could not produce that outcome, which is why it
  ## is not the check.
  ##
  ## What PASS does NOT establish: that the DIFFERENCE between two difficulty
  ## bands is real. Bots move on their own; one run cannot separate our speed
  ## from their brain's. That needs the two-run comparison in `README.md`, and
  ## this line prints the commanded speed precisely so the two runs can be
  ## compared without instrumenting anything further.
  if not gArmed:
    return "INCONCLUSIVE: no bot census has ever arrived, so this mod has " &
           "never been in a raid with a bot in it and could not look. This is " &
           "NOT evidence that driving fails"
  if gOff:
    return "FAIL: the drive path self-disabled after " & $gFaults &
           " refused command sets"
  if gPairs < 3:
    return "INCONCLUSIVE: only " & $gPairs & " of the 3 repeat sightings " &
           "needed were available (" & $gCensuses & " censuses, " & $gTrackLen &
           " bots). The census rotates; a short raid can end before any bot " &
           "is named twice"
  if gMovers == 0:
    return "FAIL: " & $gPairs & " repeat sightings across " & $gTrackLen &
           " bots and NOT ONE changed position. Every commandable bot is " &
           "frozen, which is what a bad MoveSpeed write looks like. " &
           "Commanded speed was " & $round3(gSpeed)
  result = "PASS: " & $gMovers & " of " & $gTrackLen &
           " tracked bots were observed to change position across " & $gPairs &
           " repeat sightings while commanded at MoveSpeed " & $round3(gSpeed) &
           ". This proves the channel is live and no bot was parked; it does " &
           "NOT by itself prove the difficulty band changed anything -- run " &
           "the two-band comparison for that"

proc onCensus(payload: string): string =
  result = ""
  if gOff:
    return
  let bots = botsFromEvent(payload)
  inc gCensuses
  inc gSinceSend

  if not gArmed:
    gArmed = true
    info "sain: a bot census has arrived -- " & $bots.len &
         " bots. THIS is the arming gate, not `whenReady(\"EFT.GameWorld\")`: " &
         "the host can only produce a census from inside " &
         "BotOwner::UpdateManual, which runs only for a live bot in a live " &
         "raid on Unity's thread. Driving difficulty as MoveSpeed now"

  var i = 0
  while i < bots.len and i < MaxRowsPerCensus:
    let b = bots[i]
    if b.alive:
      note(b.id, b.x, b.y, b.z)
    inc i

  let want = speedForScale(gScale)
  if gSpeed < 0.0 or want != gSpeed or gSinceSend >= RefreshEvery:
    var why = " [refresh]"
    if gSpeed < 0.0 or want != gSpeed:
      why = " [value changed]"
    if send(want):
      gSpeed = want
      if gLog:
        info "sain: drive -> every bot at MoveSpeed " & $round3(want) &
             " (difficulty scale " & $round3(gScale) & "); census " &
             $gCensuses & ", " & $gTrackLen & " bots tracked, " & $gMovers &
             " seen moving" & why

  # One check line per session, once there is enough evidence to say something
  # that is not INCONCLUSIVE. Repeating it every census would bury it.
  if not gReported and gPairs >= 3:
    gReported = true
    info "sain: drive check " & driveCheck()

proc startDrive*(difficultyScale: float; logDecisions: bool) =
  ## Wire the drive. Called from the server half's `startServer`, which already
  ## refuses to run at all when `enabled` is false -- so `enabled` gates this
  ## too, without a second read of it.
  gScale = difficultyScale
  gLog = logDecisions
  if onBotCensus(onCensus) != Ok:
    gOff = true
    warn "sain: could not subscribe to the bot census; difficulty will not " &
         "reach any bot this session"
    return
  info "sain: difficulty resolves to scale " & $round3(gScale) &
       " -> MoveSpeed " & $round3(speedForScale(gScale)) &
       ", and will be sent to every bot on the first census. NOTE: the " &
       "client host's `botNav` flag must be ON in aowlspt-host.json (it is " &
       "off by default) or this reaches nothing and says so at the check"

proc stopDrive*() =
  ## Hand every bot back to its own brain. A mod that is switched off must not
  ## leave a raid full of bots running at a speed nobody set.
  if gArmed and not gOff:
    discard clearBotNav()

proc driveState*(): string =
  var what = "waiting for a census"
  if gOff:
    what = "OFF (self-disabled)"
  elif gArmed:
    what = "armed"
  result = "drive: " & what & ", " & $gCensuses & " censuses, " & $gTrackLen &
           " bots, speed " & $round3(gSpeed)
