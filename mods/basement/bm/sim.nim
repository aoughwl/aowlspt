## bm/sim — the clock. People move, factions drift, contracts expire, ambushes
## are scheduled, and EVERY change is journaled.
##
## DECISIONS MADE HERE (the contract left them open):
##
## * **Movement is a CADENCE, not a coin flip.** DESIGN §9.3 asks for a check
##   that can fail: "advance 6 h -> at least one person changed place". A
##   per-step probability makes that check pass *almost* always, which is the
##   worst kind of check -- it would go green for months and then flake, and a
##   flake reads as a real regression. So each mobile person has a fixed
##   cadence of 1-3 hours derived from their id, and moves on the steps where
##   `(step + personIndex) mod cadence == 0`. Over six hours every mobile
##   person has moved at least twice, and the check fails honestly if the world
##   has no mobile people or no second place to move to.
## * **`simAdvance(0)` is a hard no-op before anything else runs** -- not "a
##   loop that happens to iterate zero times". The negative control has to be
##   true by construction, or it is not a control.
## * **Every step is seeded from `(worldSeed, clockMs, entity index)`**, never
##   from a running generator. Two backends that replay the same advances from
##   the same world reach the same state, and a save/load in the middle does
##   not change the future.
## * **`simCatchUp` refuses when it has no wall mark.** There is no persisted
##   wall clock (§3 keeps `clockMs`, which is world time), so the first call in
##   a process only SETS the mark and advances nothing, and says so. Inventing
##   an elapsed time would silently age the world by an arbitrary amount.

import std/strutils
import aowlspt
import util
import rng
import world
import offscreen

var gMaxCatchUpMs: int64 = 21600000'i64      ## 6 h
var gMoveEveryMs: int64 = 3600000'i64        ## 1 h
var gAmbushChance: float = 0.25
var gLastWall: int64 = 0
var gHaveWallMark: bool = false

var gRumourAfterMs: int64 = 3600000'i64   ## a fact sits this long before it is retold
var gAmbFaction: seq[string] = @[]
var gAmbCount: seq[int] = @[]
var gAmbNear: seq[string] = @[]

proc setSimConfig*(maxCatchUpMs: int64; moveEveryMs: int64;
                   ambushChance: float) =
  if maxCatchUpMs > 0: gMaxCatchUpMs = maxCatchUpMs
  if moveEveryMs > 0: gMoveEveryMs = moveEveryMs
  gAmbushChance = clampF(ambushChance, 0.0, 1.0)

proc simMoveEveryMs*(): int64 = gMoveEveryMs
proc simRumourAfterMs*(): int64 = gRumourAfterMs
proc setSimRumourAfterMs*(ms: int64) =
  if ms > 0: gRumourAfterMs = ms
proc simMaxCatchUpMs*(): int64 = gMaxCatchUpMs

proc isMobile(activity: string): bool =
  ## Exact names, not a substring test against a joined list: "trade" is a
  ## substring of nothing here today and would be tomorrow, and that is exactly
  ## how a classifier starts quietly firing on the wrong row.
  result = activity == "patrol" or activity == "travel" or
           activity == "hunt" or activity == "captive_escort"


proc stepRng(salt: string; idx: int): Rng =
  ## Deterministic per (world, clock, entity). Nothing here reads a generator
  ## that another part of the step has already advanced.
  result = initRng(worldSeed() xor
                   fnv1a64(salt & "|" & $worldClockMs() & "|" & $idx))

proc jdata(pairs: string): string = "{" & pairs & "}"

proc qs(s: string): string =
  ## A JSON string for the journal's `data` blob. The journal keeps `data` as
  ## text, so this is the only escaping it needs.
  result = "\""
  for ch in s:
    if ch == '"': result.add "\\\""
    elif ch == '\\': result.add "\\\\"
    elif ord(ch) < 0x20: result.add ' '
    else: result.add ch
  result.add "\""

proc moveOne(pi: int; step: int): bool =
  ## Relocate one person to another place on their own map. False when the map
  ## offers nowhere else to be -- which is a real answer, not a failure.
  let here = personPlace(pi)
  let options = placesOnMap(personMap(pi))
  if options.len <= 1: return false
  var r = stepRng("move", pi)
  var tries = 0
  while tries < 8:
    let cand = options[nextInt(r, 0, options.len - 1)]
    if placeId(cand) != here:
      var x = 0.0
      var y = 0.0
      var z = 0.0
      placePos(cand, x, y, z)
      setPersonPos(pi, personMap(pi), placeId(cand),
                   x + float(nextInt(r, -10, 10)), y,
                   z + float(nextInt(r, -10, 10)))
      discard journal("person.moved", personId(pi), placeId(cand),
                      jdata("\"from\":" & qs(here) & ",\"to\":" &
                            qs(placeId(cand)) & ",\"step\":" & $step))
      return true
    tries = tries + 1
  result = false

proc cadenceOf(pi: int): int =
  ## 1-3 hours, fixed per person. Part of the movement guarantee above.
  result = 1 + int(fnv1a64("cadence|" & personId(pi)) mod 3'u64)

proc scheduleAmbush(step: int) =
  ## The player is standing inside a dangerous place owned by a faction that
  ## does not like them. The sim only QUEUES it; the directive is the root's
  ## job (DESIGN §6).
  var map = ""
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  playerPos(map, px, py, pz)
  if map.len == 0: return
  let here = placesOnMap(map)
  var i = 0
  while i < here.len:
    let pl = here[i]
    var x = 0.0
    var y = 0.0
    var z = 0.0
    placePos(pl, x, y, z)
    let dx = x - px
    let dz = z - pz
    let radius = 40.0 + placeDanger(pl) * 120.0
    if dx*dx + dz*dz <= radius*radius and placeDanger(pl) >= 0.5:
      let owner = placeOwner(pl)
      let fi = findFaction(owner)
      if fi >= 0 and factionRep(fi) < 0:
        var r = stepRng("ambush", pl)
        if nextFloat(r) < gAmbushChance:
          let n = 2 + nextInt(r, 0, 2)
          gAmbFaction.add owner
          gAmbCount.add n
          gAmbNear.add placeId(pl)
          discard journal("ambush.scheduled", owner, placeId(pl),
                          jdata("\"count\":" & $n & ",\"step\":" & $step))
    i = i + 1

proc simPendingAmbush*(factionId: var string; count: var int;
                       near: var string): bool =
  if gAmbFaction.len == 0:
    factionId = ""; count = 0; near = ""
    return false
  factionId = gAmbFaction[0]
  count = gAmbCount[0]
  near = gAmbNear[0]
  var f: seq[string] = @[]
  var c: seq[int] = @[]
  var n: seq[string] = @[]
  var i = 1
  while i < gAmbFaction.len:
    f.add gAmbFaction[i]; c.add gAmbCount[i]; n.add gAmbNear[i]
    i = i + 1
  gAmbFaction = f; gAmbCount = c; gAmbNear = n
  result = true

proc simPendingAmbushCount*(): int = gAmbFaction.len


proc spreadRumours(step: int): int =
  ## One telling per person per step, at most. A person who knows a fact that
  ## has sat for `gRumourAfterMs` tells ONE group-mate who does not know it;
  ## the fact's `spreadMs` is then reset, so a rumour walks outward at a rate
  ## instead of saturating the world in a single step.
  ##
  ## Bounded by construction: the inner loops break on the first telling, and
  ## `addPersonKnows` is idempotent, so this cannot ping-pong between two
  ## people who already know.
  result = 0
  var pi = 0
  while pi < personCount():
    if personAlive(pi):
      let grp = personGroup(pi)
      if grp.len > 0:
        var told = false
        for fid in personKnows(pi):
          if told: break
          let fi = findFact(fid)
          if fi < 0: continue
          if worldClockMs() - factSpreadMs(fi) < gRumourAfterMs: continue
          for gi in peopleOfGroup(grp):
            if gi == pi or not personAlive(gi): continue
            var knows = false
            for k in personKnows(gi):
              if k == fid: knows = true
            if knows: continue
            addPersonKnows(gi, fid)
            var rk = ""
            var rid = ""
            factRef(fi, rk, rid)
            if rk == "cache" and rid.len > 0:
              let ci = findCache(rid)
              if ci >= 0: addCacheKnownBy(ci, personId(gi))
              addPersonKnows(gi, rid)
            setFactSpreadMs(fi, worldClockMs())
            remember(gi, personName(pi) & " told me: " & factText(fi))
            discard journal("rumour.spread", personId(pi), personId(gi),
                            jdata("\"fact\":" & qs(fid) & ",\"step\":" & $step))
            result = result + 1
            told = true
            break
    pi = pi + 1

proc lootedOutcomes(step: int): int =
  ## A looted cache produces exactly ONE `outcome` fact, and the owning
  ## faction's leader learns it. The existence check is what makes it once:
  ## `factsAbout` with origin `outcome` is the finished state, not a flag this
  ## code sets and then trusts.
  result = 0
  var ci = 0
  while ci < cacheCount():
    if cacheStatus(ci) == "looted":
      let cid = cacheId(ci)
      var have = false
      for fi in factsAbout("cache", cid):
        if factOrigin(fi) == "outcome": have = true
      if not have:
        let fid = cid & "-hit"
        addFactRef(fid, "outcome cache " & cid,
                   "Somebody hit " & cacheName(ci) & ". It is empty now.",
                   "cache", cid, "outcome")
        let owner = findFaction(cacheOwner(ci))
        if owner >= 0:
          for pj in peopleOfFaction(owner):
            if personAlive(pj) and personRole(pj) == "leader":
              addPersonKnows(pj, fid)
        discard journal("cache.outcome", cacheOwner(ci), cid,
                        jdata("\"fact\":" & qs(fid) & ",\"step\":" & $step))
        result = result + 1
    ci = ci + 1

proc simAdvance*(ms: int64; note: var string): int =
  ## Returns the number of world changes made; each one is journaled.
  if not worldExists():
    note = "no world loaded -- nothing advanced"
    return 0
  if ms <= 0:
    # By construction, before any loop: the negative control cannot be
    # accidentally satisfied by a loop body that "usually" does nothing.
    note = "advance of " & $ms & " ms: no steps taken, nothing changed"
    return 0

  var steps = int(ms div gMoveEveryMs)
  let remainder = ms - int64(steps) * gMoveEveryMs
  var changes = 0
  var moved = 0
  var stanceChanges = 0
  var expired = 0
  var healed = 0
  var spread = 0
  var outcomes = 0
  var offsteps = 0

  var step = 0
  while step < steps:
    advanceClock(gMoveEveryMs)
    let stepIdx = int(worldClockMs() div gMoveEveryMs)

    # people. A FROZEN map is skipped before anything reads or writes a person
    # on it: while the player is in a raid there, the client is the truth for
    # that map and a backend nudge would fight it.
    var pi = 0
    while pi < personCount():
      if offscreenFrozen(personMap(pi)):
        pi = pi + 1
        continue
      if personAlive(pi):
        if isMobile(personActivity(pi)):
          if (stepIdx + pi) mod cadenceOf(pi) == 0:
            if moveOne(pi, stepIdx):
              moved = moved + 1
              changes = changes + 1
        else:
          # The stationary ones still drift: an idle grunt picks up a patrol,
          # a sleeper wakes. Deterministic per (clock, person).
          var r = stepRng("activity", pi)
          if nextFloat(r) < 0.15:
            let before = personActivity(pi)
            let after = pick(r, @["idle", "patrol", "guard", "trade",
                                  "sleep", "hunt"])
            if after != before:
              setPersonActivity(pi, after)
              discard journal("person.activity", personId(pi), "",
                              jdata("\"from\":" & qs(before) & ",\"to\":" &
                                    qs(after)))
              changes = changes + 1
        if personHp(pi) < 1.0:
          let before = personHp(pi)
          setPersonHp(pi, before + 0.05)
          discard journal("person.healed", personId(pi), "",
                          jdata("\"from\":" & fmtF(before) & ",\"to\":" &
                                fmtF(personHp(pi))))
          healed = healed + 1
          changes = changes + 1
      pi = pi + 1

    # faction stances drift, at most one pair per step
    if factionCount() >= 2:
      var r = stepRng("stance", 0)
      if nextFloat(r) < 0.10:
        let a = nextInt(r, 0, factionCount() - 1)
        var b = nextInt(r, 0, factionCount() - 1)
        if b == a: b = (a + 1) mod factionCount()
        let before = stance(a, b)
        let ladder: seq[string] = @["allied", "neutral", "rival", "war"]
        var at = 1
        var k = 0
        while k < ladder.len:
          if ladder[k] == before: at = k
          k = k + 1
        var delta = 1
        if nextFloat(r) < 0.5: delta = -1
        var to = at + delta
        to = clampI(to, 0, ladder.len - 1)
        if ladder[to] != before:
          setStance(a, b, ladder[to])
          discard journal("faction.stance", factionId(a), factionId(b),
                          jdata("\"from\":" & qs(before) & ",\"to\":" &
                                qs(ladder[to])))
          stanceChanges = stanceChanges + 1
          changes = changes + 1

    # contracts expire
    var ci = 0
    while ci < contractCount():
      let st = contractStatus(ci)
      if (st == "offered" or st == "active") and
         contractExpiresMs(ci) > 0'i64 and
         contractExpiresMs(ci) <= worldClockMs():
        setContractStatus(ci, "expired")
        discard journal("contract.expired", contractPartyA(ci),
                        contractPartyB(ci),
                        jdata("\"id\":" & qs(contractId(ci)) & ",\"was\":" &
                              qs(st)))
        expired = expired + 1
        changes = changes + 1
      ci = ci + 1

    let sp = spreadRumours(stepIdx)
    spread = spread + sp
    changes = changes + sp
    let oc = lootedOutcomes(stepIdx)
    outcomes = outcomes + oc
    changes = changes + oc

    # The offscreen world: groups plan, march, meet and fight on every map the
    # player is NOT standing in. It runs INSIDE this loop so both clocks are
    # the same clock.
    let oc2 = offscreenStep(stepIdx)
    offsteps = offsteps + oc2
    changes = changes + oc2

    scheduleAmbush(stepIdx)
    step = step + 1

  if remainder > 0'i64:
    advanceClock(remainder)

  note = "advanced " & $ms & " ms in " & $steps & " step(s): " & $moved &
         " move(s), " & $stanceChanges & " stance change(s), " & $expired &
         " contract(s) expired, " & $healed & " heal(s), " & $spread &
         " rumour(s) spread, " & $outcomes & " loot outcome(s), " & $offsteps &
         " offscreen change(s) [frozen map: " &
         (if offscreenFrozenMap().len > 0: offscreenFrozenMap() else: "none") &
         "]; " & $changes &
         " journaled change(s); clock now " & $worldClockMs() &
         " (day " & $worldDay() & ")"
  result = changes

proc simCatchUp*(note: var string): int =
  ## Advance by the wall time since the last call, capped. The FIRST call in a
  ## process only sets the mark: with no persisted wall clock there is no
  ## honest elapsed time to use, and guessing one would age the world by an
  ## arbitrary amount without anyone being told.
  let now = wallMs()
  if not gHaveWallMark:
    gLastWall = now
    gHaveWallMark = true
    var kindNote = ""
    if not wallMsIsReal():
      kindNote = " (NO real wall clock: PowerShell did not answer, so this " &
                 "is host-uptime, not epoch)"
    note = "wall mark set" & kindNote &
           " -- nothing advanced on the first catch-up of this process"
    return 0
  var elapsed = now - gLastWall
  gLastWall = now
  if elapsed <= 0'i64:
    note = "no wall time elapsed -- nothing advanced"
    return 0
  var capped = false
  if elapsed > gMaxCatchUpMs:
    elapsed = gMaxCatchUpMs
    capped = true
  var n = ""
  let changes = simAdvance(elapsed, n)
  var capNote = ""
  if capped: capNote = " [CAPPED at " & $gMaxCatchUpMs & " ms]"
  note = "catch-up " & n & capNote
  result = changes
