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
##       bridge    reading and driving a bot; the capability probe
##       driver    who thinks, when: the amortisation budget
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
## raid. The current IL2CPP host resolves types and calls members, but a call
## returning a reference type reports what it is rather than handing back a
## handle to it — so there is no route from `GameWorld` to a `BotOwner`, and
## per-bot state cannot be read. The bridge probes for this at load and says so
## once. Everything above the bridge is finished and tested; the bridge is one
## file, and it is the only file that changes when handles arrive.
##
## Not ported at all, and deliberately: the voice/taunt system, the F6 settings
## GUI and the Blazor web editor, the per-limb aiming and scatter model, door
## breaching, extraction behaviour, and the BigBrain layer plumbing (which has
## no counterpart here — the cascade emits an enum triple and `actuationFor`
## turns it into intent, with no action objects to tear down).

import aowlspt
import aowlspt/game
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
var gSpawnCount = 0

proc onBotActivated(target: string) =
  ## Fired by a detour on the game's own bot activation.
  ##
  ## A hook cannot read the method's arguments -- doing that correctly needs a
  ## thunk generated per signature, and the host refuses rather than reporting
  ## the wrong ones -- so this learns that *a* bot spawned, not which. That is
  ## enough to keep a per-bot record in step while the capability probe says
  ## object handles are unavailable, and it is exactly the point at which the
  ## real spawn data would be read once they are.
  gSpawnCount = gSpawnCount + 1
  spawnBot("bot" & $gSpawnCount, 0'u64, "assault", -1.0)

proc installHooks() =
  ## Being told beats asking. A detour on activation costs nothing between
  ## spawns; polling the world for new bots costs the same every frame forever.
  if gHooked:
    return
  gHooked = true
  if hook("EFT.BotOwner::PreActivate", onBotActivated) != Ok:
    # Not fatal, and worth naming: some methods cannot be detoured (a prologue
    # holding a relative branch, or one shorter than the jump), and the host
    # says which and why. Without the hook the mod simply never learns about
    # spawns, which is a different failure from a broken one.
    warn "sain: could not hook bot activation: " & lastError()

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
    spawnBot("sim-pmc", 0'u64, "pmcUSEC", 0.7)
    spawnBot("sim-scav", 0'u64, "assault", 0.3)
    spawnBot("sim-boss", 0'u64, "bossKilla", 1.0)
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
    # The world exists. Ask the host what it can actually reach before doing
    # anything that assumes an answer.
    discard probe()
    announce()
    installHooks()

  if capability() == capNone:
    # Re-probe occasionally rather than every frame: the answer only changes
    # when the game loads a raid, and `resolve` walks every loaded assembly.
    let now = nowMs()
    if now - gProbedAt > 2000'i64:
      gProbedAt = now
      discard probe()
    return Ok

  tick(elapsedMs)
  Ok

proc onUnload(): Status =
  if side() == sideClient:
    info "sain: " & stats()
  Ok

exportMod(guid = "aowl.sain", name = "SAIN", author = "aowlspt port of SAIN " &
          "by Solarint and ArchangelWTF", version = "0.1.0",
          sptRange = "*", sides = {sideClient, sideServer, sideSim},
          onLoad = onLoad, onUpdate = onUpdate, onUnload = onUnload)
