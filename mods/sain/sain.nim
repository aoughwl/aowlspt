## SAIN, ported to aowlspt as a from-scratch rewrite in nimony.
##
##     aowl build-mod mods/sain
##     aowl run mods/sain
##
## SAIN (Solarint, maintained by ArchangelWTF) replaces Tarkov's bot AI:
## layered decisions, per-bot personalities, real cover use, searching that
## looks like searching, and squads that behave like squads. This is a port of
## that **design**, not of that code — 64,000 lines of C# built on BepInEx,
## Harmony and BigBrain cannot be transliterated onto a post-1.0 IL2CPP client
## that has none of the three.
##
## ## Layout
##
##     core/       the decision model. Pure nimony, no game calls at all.
##       vec       vectors, and the small amount of geometry needed
##       toggle    `Toggle` / `Cooldown` -- SAIN's hysteresis primitive
##       types     the three decision enums and the records a tick reads
##       settings  every threshold, resolved per personality at spawn
##       enemy     perception: seen/heard timers, last known place, threat
##       cover     scoring cover points; the raycast stays in the caller
##       search    the search state machine
##       decide    the arbiter: SAIN's 10 Hz priority cascade
##       rng       a deterministic per-bot stream
##       selftest  25 scenario tests that need no Tarkov to run
##     preset/     config.json -> a resolved Settings per bot role
##     client/     the only files that know Tarkov exists
##       live      the IL2CPP runtime, held directly; every binding
##       bridge    reading and driving a bot; the capability probe
##       driver    who thinks, when: the amortisation budget, and discovery
##     server/     brain forcing, per-map difficulty, the preset route
##
## ## What runs where
##
## One binary, three sides, chosen by `side()`:
##
##  * **server** -- forces the bot brain tables SAIN needs, neutralises BSG's
##    per-map difficulty skew, serves the resolved preset on `/sain/preset`.
##  * **client** -- probes what the IL2CPP host can reach, then drives bots.
##  * **sim** -- runs the decision core's scenario tests and reports.
##
## ## What is honestly not here
##
## Read `client/bridge.nim` before expecting bots to behave differently in a
## raid. The client half now walks the real object graph and drives real
## methods — but **nothing here has been run against Tarkov**. Every EFT member
## name in `client/live.nim` is a name from the pre-1.0 C# surface, and post-1.0
## is a different build; a wrong one refuses its binding, logs why, and falls
## back to a default. The one thing to read in the log before drawing any
## conclusion is the binding report `announce()` prints once.
##
## Three things are missing rather than wrong, and are listed at the top of
## `client/bridge.nim`: cover points have no raycast source, bleeds and
## fractures need a generic collection walk the runtime binding cannot name,
## and the squad view is a stub of one member. The decisions that read them
## therefore never fire.
##
## Not ported at all, and deliberately: the voice/taunt system, the F6 settings
## GUI and the Blazor web editor, the per-limb aiming and scatter model, door
## breaching, extraction behaviour, and the BigBrain layer plumbing (which has
## no counterpart here — the cascade emits an enum triple and `actuationFor`
## turns it into intent, with no action objects to tear down).

import aowlspt
import aowlspt/game
import aowlspt/json
import core/vec
import core/types
import core/selftest
import preset/preset
import client/bridge
import client/driver
import server/serverside

var gWorld = whenReady("EFT.GameWorld")
var gPreset: Preset
var gProbedAt = 0'i64
var gHooked = false

## The methods that might carry a newly activated bot as an argument.
##
## One name would be a guess; a short list tried in order is the same guess with
## the failures visible. The first that patches wins and the rest are not tried,
## because two hooks on the same event would register every bot twice -- which
## `spawnBot` would absorb, but silently, and a silent absorption of a wrong
## assumption is how a mod ends up with nobody able to say what it is doing.
##
## Every candidate takes the bot (or its `IPlayer`) as its **first declared
## argument**, and that is the requirement rather than a preference: `hookArgs`
## reports a method's declared arguments and *not* the instance it was called
## on, so a hook on an instance method of `BotOwner` itself would fire knowing a
## bot activated and not which one. That was the limitation the previous version
## of this file was written around; it is still there, and it is now the only
## reason the list below is a list.
const SpawnHookCandidates: array[3, string] = [
  "EFT.BotsController::AddActivePLayer",
  "EFT.BotSpawner::AddPlayer",
  "EFT.BotsController::AddActivePlayer"]

proc onBotAdded(target, args: string): HookResult =
  ## Fired by a detour on the game's own bot activation, **with the bot**.
  ##
  ## This is the whole reason `hookArgs` exists rather than `hook`: the previous
  ## version of this proc learned that *a* bot spawned and invented an id for
  ## it. Now the argument arrives as a live object and the bot's own profile id
  ## and spawn type come off it.
  ##
  ## Everything here is on the host's boxed path -- four or five calls at ~1 us
  ## each. That is the right trade for something that happens once per bot per
  ## raid, and it is why the read is here and not in the per-tick path: the id
  ## is what the whole per-bot table is keyed on and it cannot change.
  ##
  ## No IL2CPP pointer is taken. The host's `Handle` is an index into the host's
  ## own table and there is no ABI entry point that turns one into the raw
  ## pointer the fast path needs, so the bot is *registered* here and the world
  ## scan in `driver.nim` attaches its GC handle on the next pass. See the note
  ## at the top of `client/live.nim`.
  let arr = whole(args)
  let first = at(arr, 0)
  if not exists(first):
    return carryOn()
  var cr = CallResult(ok: true, raw: raw(first), error: "")
  let who = asObject(cr)
  if not who.ok:
    return carryOn()

  let id = asText(who.get("ProfileId"))
  var role = ""
  let prof = who.child("Profile")
  if prof.ok:
    let inf = prof.child("Info")
    if inf.ok:
      let cfg = inf.child("Settings")
      if cfg.ok:
        let r = cfg.child("Role")
        if r.ok:
          # `Role` is a `WildSpawnType`, an enum. The host hands a boxed enum
          # back as an object rather than a number, and `ToString` on it is the
          # member name -- which is exactly what `roleFromSpawnType` wants and
          # is stable across the ordinal renumbering that a client update does.
          role = asText(r.invoke("ToString"))
          release(r)
        release(cfg)
      release(inf)
    release(prof)
  release(who)

  if id.len > 0:
    # -1 difficulty means "the preset decides"; the game's own `BotDifficulty`
    # is a second enum read and the preset's per-role difficulty is what SAIN
    # actually tunes against.
    spawnBot(id, role, -1.0)
  carryOn()

proc installHooks() =
  ## Being told beats asking. A detour on activation costs nothing between
  ## spawns; polling the world for new bots costs the same every frame forever
  ## -- which is why the scan in `driver.nim` runs at 2 Hz and is a reconciler
  ## rather than the primary path.
  if gHooked:
    return
  gHooked = true
  var i = 0
  while i < SpawnHookCandidates.len:
    let name = SpawnHookCandidates[i]
    if hookArgs(name, onBotAdded) == Ok:
      info "sain: bot activation hooked on " & name
      return
    inc i
  # Not fatal, and worth naming: some methods cannot be detoured (a prologue
  # holding a relative branch, or one shorter than the jump), and a method that
  # does not exist under any of these names cannot be either. Without the hook
  # the mod still finds every bot -- the world scan is what makes that true --
  # but it finds them up to half a second late and without their spawn type,
  # which means scav settings for a PMC.
  warn "sain: no bot-activation hook took (last error: " & lastError() &
       "); falling back to the world scan, which cannot read a spawn type"

proc runSelfTest(): int =
  ## The decision core, exercised end to end. Runs on the simulator, and on any
  ## side when `logDecisions` is on -- a mod that can prove its own logic in the
  ## host it is loaded into is worth the 25 microseconds.
  let r = selftest.run()
  for line in r.lines:
    info line
  if r.failed == 0:
    success "sain: decision core, " & $r.passed & " checks passed"
  else:
    error "sain: decision core, " & $r.failed & " of " &
          $(r.passed + r.failed) & " checks FAILED"
  result = r.failed

proc onLoad(): Status =
  gPreset = loadPreset()
  if not gPreset.enabled:
    warn "sain: disabled in config.json"
    return Ok

  case side()
  of sideServer:
    startServer(gPreset)
  of sideSim:
    if runSelfTest() > 0:
      return ErrGeneric
    # Drive the whole pipeline once with no game attached: register a handful of
    # bots and tick them. This is what proves the driver's budget, its
    # round-robin cursor and the per-bot state plumbing outside a raid -- the
    # decision core has its own tests, and this is the layer above them.
    setPreset(gPreset)
    spawnBot("sim-pmc", "pmcUSEC", 0.7)
    spawnBot("sim-scav", "assault", 0.3)
    spawnBot("sim-boss", "bossKilla", 1.0)
    var i = 0
    while i < 20:
      tick(100'i64)
      inc i
    info "sain: " & stats()
    despawnBot("sim-scav")
    if botCount() != 2:
      error "sain: despawn did not compact the bot table"
      return ErrGeneric
    success "sain: driver pipeline exercised without a game attached"
  of sideClient:
    setPreset(gPreset)
    info "sain: client half loaded; waiting for the game world"
  else:
    discard
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if not gPreset.enabled or side() != sideClient:
    return Ok

  if gWorld.ready():
    # The world exists. Bind everything and say what took, before doing
    # anything that assumes an answer. This is the first tick on which
    # `bindMethod` can succeed -- `docs/PERF.md` is explicit that binding in
    # `onLoad` correctly refuses, because the game's assemblies are not up.
    discard probe()
    announce()
    installHooks()

  let now = nowMs()
  if capability() != capFull:
    # Re-probe occasionally rather than every frame: the answer only changes
    # when the game loads a raid, and `resolve` walks every loaded assembly.
    # Between raids this is the whole per-frame cost of the mod.
    if now - gProbedAt > 2000'i64:
      gProbedAt = now
      discard probe()
    return Ok

  # Discovery first, then decisions: a bot registered by the hook this frame
  # gets its handle before it is asked to think, so its first decision reads
  # the game rather than the defaults.
  scan(now)
  tick(elapsedMs)
  Ok

proc onUnload(): Status =
  if side() == sideClient:
    # Order matters: the stats line names how many handles were released, and
    # `releaseAll` is what makes that number true.
    releaseAll()
    info "sain: " & stats()
  Ok

exportMod(guid = "aowl.sain", name = "SAIN", author = "aowlspt port of SAIN " &
          "by Solarint and ArchangelWTF", version = "0.1.0",
          sptRange = "*", sides = {sideClient, sideServer, sideSim},
          onLoad = onLoad, onUpdate = onUpdate, onUnload = onUnload)
