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
import ".." / core / types
import ".." / preset / preset      # roleName only; no cycle (preset imports core/*)
import "." / dispatch

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

  RoleCount* = 8
    ## Must match the number of `BotRole` members. `preset.roleDifficulty` is
    ## indexed by `ord(BotRole)` and so is `gRoleScale`.

type
  Tracked = object
    id: int
    seen: bool
    x, y, z: float
    lastCensus: int
    moved: bool     ## has this bot EVER changed position between two sightings
    role: int       ## `ord(BotRole)`, classified from the census WildSpawnType
    roleKnown: bool ## false until a census actually named this bot's type
    roleSent: bool  ## has a per-bot role row ever gone out for this bot

func roleOfSpawnType*(w: int): int =
  ## `WildSpawnType` (a raw int32 off the census) -> `ord(BotRole)`.
  ##
  ## The numbers are the vanilla table documented in
  ## `mods/morebots/bots/spawntypes.nim`, which read them out of
  ## `EFT.WildSpawnType` in the shipped assemblies rather than from memory. They
  ## are DATA, not truth: BSG renumbers this enum between wipes, and a wrong
  ## number here shows up as a boss moving at scav speed -- visible, and not
  ## dangerous, which is why this is a pure `case` over an integer we were
  ## handed and not a lookup that touches the client.
  ##
  ## Anything unrecognised falls to scav, matching `preset.roleFromText`: a
  ## build with a type this table does not have must still drive that bot at
  ## SOME honest speed rather than be excluded from the feature silently.
  ##
  ## The gaps at 31, 54, 55 and 56 are real -- those values were removed
  ## upstream -- and they are absent here rather than folded into a neighbour.
  case w
  of 9, 24, 51, 52: ord(brPmc)                # pmcBot exUsec pmcBEAR pmcUSEC
  of 34, 35: ord(brRaider)                    # arenaFighter(+Event)
  of 26, 27, 28: ord(brGoon)                  # bossKnight BigPipe BirdEye
  of 2, 3, 6, 7, 11, 17, 22, 29, 32, 36, 43, 47, 65, 66:
    ord(brBoss)                               # boss*, incl. the Agro variants
  of 4, 5, 8, 12, 13, 14, 15, 16, 23, 30, 33, 41, 42, 44, 45, 67:
    ord(brFollower)                           # follower*, tagillaHelperAgro
  of 60, 61, 62, 63, 64: ord(brZombie)        # infected*
  else: ord(brScav)                           # marksman assault cursed sectant

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
  gNoPlanSaid = false
  gRoleScale: array[RoleCount, float]
  gRolesDiffer = false
    ## Whether any role's band differs from the global one. When false this
    ## file emits exactly the one BotNavAll row it always did -- no per-bot
    ## rows, no rotation, no extra wire traffic. A knob nobody set costs
    ## nothing.
  gRoleCursor = 0   ## where the per-bot override rotation resumes
  gRoleRows = 0     ## per-bot role rows emitted this session (coverage, not a check)
  gRoleCovered = 0  ## DISTINCT bots that have had a role row sent at least once

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

proc note(id: int; x, y, z: float; spawnType: int) =
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
                            lastCensus: 0, moved: false, role: ord(brScav),
                            roleKnown: false, roleSent: false)
    else:
      idx = gTrackLen
      inc gTrackLen
      gTrack[idx] = Tracked(id: id, seen: false, x: 0.0, y: 0.0, z: 0.0,
                            lastCensus: 0, moved: false, role: ord(brScav),
                            roleKnown: false, roleSent: false)
  if gTrack[idx].seen:
    inc gPairs
    let dx = x - gTrack[idx].x
    let dy = y - gTrack[idx].y
    let dz = z - gTrack[idx].z
    if dx * dx + dy * dy + dz * dz > 0.0:
      if not gTrack[idx].moved:
        gTrack[idx].moved = true
        inc gMovers
  # The role is recorded from the census, not assumed. `roleKnown` stays false
  # for a bot no census has typed yet, and an untyped bot gets NO per-bot row --
  # it keeps the BotNavAll baseline. Defaulting an unknown to scav here would be
  # a check that cannot fail: it would look like full role coverage while
  # actually reporting our own default back to us.
  if spawnType >= 0:
    gTrack[idx].role = roleOfSpawnType(spawnType)
    gTrack[idx].roleKnown = true
  gTrack[idx].id = id
  gTrack[idx].seen = true
  gTrack[idx].x = x
  gTrack[idx].y = y
  gTrack[idx].z = z
  gTrack[idx].lastCensus = gCensuses

proc roleSpeedRows(baseline: float): seq[BotCommand] =
  ## One `speed` row per TRACKED bot whose role band differs from the global
  ## one, resuming from `gRoleCursor` so successive censuses cover every bot
  ## rather than re-sending the same first few forever.
  ##
  ## Capped twice: by `MaxTracked` (the walk) and by `BotNavMaxCommands` (the
  ## set). Neither cap can be exceeded by a corrupt census, because the census
  ## contributes ids to `gTrack` and nothing else here.
  result = @[]
  if not gRolesDiffer:
    return
  var k = 0
  while k < MaxTracked and k < gTrackLen and result.len < BotNavMaxCommands:
    let i = (gRoleCursor + k) mod (if gTrackLen > 0: gTrackLen else: 1)
    inc k
    if not gTrack[i].roleKnown:
      continue
    var ri = gTrack[i].role
    if ri < 0 or ri >= RoleCount:
      continue
    let want = speedForScale(gRoleScale[ri])
    if want == baseline:
      # Already covered by the BotNavAll row. Spending one of sixteen command
      # slots to repeat the baseline would starve a bot that actually differs.
      continue
    result.add moveSpeed(gTrack[i].id, want)
    if not gTrack[i].roleSent:
      gTrack[i].roleSent = true
      inc gRoleCovered
  if gTrackLen > 0:
    gRoleCursor = (gRoleCursor + k) mod gTrackLen

proc send(speed: float; orders: seq[BotCommand];
          roleRows: seq[BotCommand]): bool =
  ## ONE command set, carrying both halves of what this mod has to say.
  ##
  ## The MoveSpeed row is addressed to `BotNavAll` rather than per bot on
  ## purpose: the census is PARTIAL and ROTATES, so a per-bot speed would only
  ## ever steer the five bots that happened to fit in the last payload and
  ## would leave the rest vanilla -- precisely the "a setting that changes
  ## nothing" failure this work exists to remove.
  ##
  ## `orders` is `server/dispatch`'s per-bot ORBIT destinations, and they are
  ## appended HERE rather than sent from there because `botnav` is LAST WRITER
  ## WINS over one command set: a second `sendBotCommands` would replace this
  ## MoveSpeed row and the difficulty band would stop reaching anything with no
  ## error anywhere. One set, assembled once, is the only shape that cannot do
  ## that silently.
  ## PER-ROLE ROWS ride the same single set, for exactly the same reason
  ## `orders` do: a second `sendBotCommands` would REPLACE this one and the
  ## global row would stop reaching anything, silently. The BotNavAll row goes
  ## FIRST and the per-bot rows after it, because the host applies a set in
  ## order -- so a bot named by a role row takes the role speed and every bot
  ## that is not named keeps the global one. That ordering is what makes the
  ## partial, rotating census survivable: a bot the rotation has not reached
  ## yet is at the global speed, not at no speed.
  var set: seq[BotCommand] = @[moveSpeed(BotNavAll, speed)]
  var i = 0
  while i < orders.len and set.len < BotNavMaxCommands:
    set.add orders[i]
    inc i
  var r = 0
  while r < roleRows.len and set.len < BotNavMaxCommands:
    set.add roleRows[r]
    inc r
  gRoleRows = gRoleRows + r
  let st = sendBotCommands(set)
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
      note(b.id, b.x, b.y, b.z, b.role)
    inc i

  let want = speedForScale(gScale)
  # The ORBIT orders for this census. Computed before the send decision because
  # whether there ARE orders is part of that decision: a destination is only
  # useful while the bot is still where the order assumed, so once the
  # dispatcher is armed the set goes out every census rather than on the
  # value-changed / every-tenth schedule that a single global speed can live
  # with.
  var orders: seq[BotCommand] = @[]
  if dispatchArmed():
    orders = dispatchFor(bots)
  elif not gNoPlanSaid:
    # THE GAP THIS CLOSES. A census arriving while no ORBIT plan is loaded used
    # to take this branch and print nothing at all, so a raid in which orbit's
    # "Bots will be dispatched on the next census" was never followed by
    # anything looked identical to a raid in which the dispatcher ran and
    # declined everyone. Said once, because the condition is per-raid, not
    # per-census.
    gNoPlanSaid = true
    warn "sain: a bot census arrived with " & $bots.len & " bots but NO " &
         "ORBIT plan is loaded, so no destination will be sent this raid -- " &
         "only MoveSpeed. Either emu/orbit never built a plan for this map " &
         "(check /aowlspt/orbit/plan) or it built one and the broadcast on " &
         "`tarkov.orbit.plan` did not reach this mod. Those are different " &
         "bugs and that route tells them apart"
  # The role rows are rebuilt every census the set goes out, because the
  # rotation is the whole point: a set that was not rebuilt would re-send the
  # same bots' rows and never reach the rest.
  var roleRows = roleSpeedRows(want)
  if gSpeed < 0.0 or want != gSpeed or gSinceSend >= RefreshEvery or
     orders.len > 0 or roleRows.len > 0:
    var why = " [refresh]"
    if gSpeed < 0.0 or want != gSpeed:
      why = " [value changed]"
    if orders.len > 0:
      why = " [" & $orders.len & " ORBIT order(s)]"
    if roleRows.len > 0:
      why = why & " [" & $roleRows.len & " per-role row(s)]"
    if send(want, orders, roleRows):
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
    info "sain: " & roleCoverage()
    # Unconditional now. Gating this on `dispatchArmed()` meant the one case
    # worth reporting -- armed=false, so nothing was ever dispatched -- was the
    # one case that printed nothing. `dispatchCheck` returns a specific
    # INCONCLUSIVE for exactly that, which is the answer.
    info "sain: dispatch check " & dispatchCheck()

proc roleCoverage*(): string =
  ## COVERAGE, and deliberately not called a check.
  ##
  ## It counts how many distinct tracked bots have had a per-role row sent.
  ## That is a property of OUR OWN WRITE, so under CLAUDE.md 9b it cannot be a
  ## verification and is not presented as one -- a row that went out and was
  ## dropped by the host, or applied to the wrong offset, counts here exactly
  ## the same. The falsifiable statement about the finished state is still
  ## `driveCheck`'s ("no commanded bot is frozen"), plus the two-band raid
  ## comparison a human runs; this line exists only so that comparison can be
  ## set up without guessing whether the rotation ever reached the bots.
  if not gRolesDiffer:
    return "per-role difficulty: every role is on the global band, so no " &
           "per-bot rows are sent and this session is byte-for-byte the " &
           "single-speed behaviour"
  result = "per-role difficulty: " & $gRoleCovered & " of " & $gTrackLen &
           " tracked bots have had a role row sent (" & $gRoleRows &
           " rows total). This says what was SENT, not what took effect"

proc startDrive*(difficultyScale: float; roleScales: seq[float];
                 logDecisions: bool) =
  ## Wire the drive. Called from the server half's `startServer`, which already
  ## refuses to run at all when `enabled` is false -- so `enabled` gates this
  ## too, without a second read of it.
  gScale = difficultyScale
  gLog = logDecisions
  # Per-role bands. A short or absent `roleScales` is not an error: it means the
  # caller has no per-role opinion, and every role inherits the global band --
  # which reproduces the exact single-speed behaviour this file had before.
  var ri = 0
  while ri < RoleCount:
    if ri < roleScales.len:
      gRoleScale[ri] = roleScales[ri]
    else:
      gRoleScale[ri] = difficultyScale
    if speedForScale(gRoleScale[ri]) != speedForScale(difficultyScale):
      gRolesDiffer = true
    inc ri
  if onBotCensus(onCensus) != Ok:
    gOff = true
    warn "sain: could not subscribe to the bot census; difficulty will not " &
         "reach any bot this session"
    return
  # Say which roles differ, and say it as NUMBERS. "per-role difficulty is on"
  # would be a line that cannot be wrong; the resolved MoveSpeed per role can
  # be, and a wrong band shows up here before any raid is spent on it.
  if gRolesDiffer:
    var line = "sain: per-role difficulty is ACTIVE ->"
    var q = 0
    while q < RoleCount:
      if speedForScale(gRoleScale[q]) != speedForScale(gScale):
        line = line & " " & roleName(BotRole(q)) & "=" &
               $round3(speedForScale(gRoleScale[q]))
      inc q
    line = line & " (every other role stays at the global " &
           $round3(speedForScale(gScale)) & ")"
    info line
  else:
    info "sain: per-role difficulty: every role inherits the global band, so " &
         "only the one BotNavAll row is sent"
  info "sain: difficulty resolves to scale " & $round3(gScale) &
       " -> MoveSpeed " & $round3(speedForScale(gScale)) &
       ", and will be sent to every bot on the first census. NOTE: the " &
       "client host's `botNav` flag must be ON in aowlspt-host.json (it is " &
       "off by default) or this reaches nothing and says so at the check"

proc stopDrive*() =
  ## Hand every bot back to its own brain. A mod that is switched off must not
  ## leave a raid full of bots running at a speed nobody set.
  stopDispatch()
  if gArmed and not gOff:
    discard clearBotNav()

proc driveState*(): string =
  var what = "waiting for a census"
  if gOff:
    what = "OFF (self-disabled)"
  elif gArmed:
    what = "armed"
  result = "drive: " & what & ", " & $gCensuses & " censuses, " & $gTrackLen &
           " bots, speed " & $round3(gSpeed) & "; " & roleCoverage()
