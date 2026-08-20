## Black Division — a PMC faction, as an aowlspt mod.
##
## A from-scratch rewrite for aowlspt of **WTT Black Division** by
## TacticalToaster / Matthew Ryan Christensen II
## (https://discord.gg/nxa3W7w4rJ), whose C# client plugin, prepatcher and SPT
## server mod this replaces. Upstream is **MIT**; that licence and its copyright
## line travel with this port and its text is in `LICENSE` beside this file.
##
##     aowl build-mod mods/blackdivision
##
## Six roles — a lead, an assault, a breacher, a support, a raider and Wedge —
## hostile to everything and everyone, hunting the player across ten maps and
## camping the Labs extracts.
##
## ---------------------------------------------------------------------------
## WHAT IT CHANGES, WHAT IT ASSUMES, AND WHAT IT HAS NEVER BEEN RUN AGAINST
## ---------------------------------------------------------------------------
##
## **What it changes.** On the **server**, through morebots and `dbWrite`:
## six bot type documents and their loadout overlays, one faction definition,
## eleven hostility relations (which are edits to the difficulty documents'
## `ENEMY_BOT_TYPES` lists), one locale string, three achievements, and the
## spawn tables on ten maps — rebuilt at the end of every raid so the next one
## is not the last one again. It writes nothing outside those paths.
##
## On the **client**, nothing at all — deliberately, and it says so out loud
## rather than by omission. The client half is a **read-only watch**: every few
## seconds it walks the world's alive-player list on the fast path and reports
## how many Black Division bots are in the raid and how far the nearest is.
## That is not a consolation prize; see `bd/watch.nim`. Every part of *making*
## the squad arrive is server data, and before this file nothing could tell a
## squad that never spawned from one that spawned 700 m away — both read as
## "the mod does nothing".
##
## An earlier revision of this file had a client half that logged one line about
## what could not be done and then did nothing. Everything in that line was true
## and it was being used as a reason to ship an inert side, which is a different
## claim.
##
## **What it assumes about the client.** Nine members, every one bound against
## the object it is reached on rather than against a name, because the chain is
## subclasses and generics throughout (`List<IPlayer>` has no name `findClass`
## accepts). One thing is asserted rather than inferred and it is guarded:
## `get_Position` returns a twelve-byte `Vector3` that Win64 hands back through
## a hidden pointer, bound with `bindRaw` only after the runtime confirms a
## value type of a non-register size — with even the object-header size
## calibrated from `System.Int32` and `System.Double` rather than assumed.
##
## The one identification assumption is stated at its call site too: a Black
## Division bot is recognised by its **first name**, from this mod's own shipped
## `data/types/*.json`, because the six role ids cannot reach the client (see
## below) and a nickname can. It is a strong signal and not a proof — another
## mod could in principle put "Anvil" in a name table — so the watch reports how
## many matched rather than asserting who they are.
##
## **It has never been run against BSG's game.** Not once. Every `EFT.` name in
## `bd/watch.nim` is from the pre-1.0 C# surface; post-1.0 is a different build.
## `aowl run mods/blackdivision` checks the data, drives the whole registration
## with no backend, exercises the Win64 shape rule exhaustively and prints the
## binding report offline — and establishes nothing whatever about the names.
##
## ---------------------------------------------------------------------------
## How this reaches morebots
## ---------------------------------------------------------------------------
##
## Through events, and only through events. There is no assembly reference, no
## DI container and no shared object: `mods/morebots` announces itself with
## `morebots.ready`, this mod answers with a `morebots.type.register` per bot, a
## `morebots.faction.define`, the loadout overlays and eleven
## `morebots.faction.relate` calls, and morebots does the writing.
##
## Upstream ordered this with DI priorities — `LoadFactions` at `PostLoad+80080`
## and `LoadBots` at `PostLoad+80085`, so factions existed before bots asked
## about them. There are no load priorities here and there should not be; the
## handshake replaces them. morebots announces twice (directly at the end of its
## own load, and again from a zero-delay timer) precisely so that neither load
## order can lose the announcement, and everything sent below is idempotent, so
## being announced to twice is harmless. `gRegistered` still short-circuits the
## second pass, because re-reading 120KB of JSON off disk for no reason is rude.
##
## The one thing that must still be ordered is *within* this mod's own
## registration: the faction is defined, then the types are registered, then the
## relations are applied. A relation names a faction and edits a bot type, and
## both have to exist first.
##
## ---------------------------------------------------------------------------
## Which half runs where
## ---------------------------------------------------------------------------
##
## One binary, and effectively one side.
##
## **Server (`sideServer`, and `sideSim` for testing).** All of it: registration,
## loadouts, hostility, the locale string, the achievements, and the spawn tables
## — including re-rolling them at the end of every raid.
##
## **Client (`sideClient`).** A read-only watch for the squad this mod spawns —
## see `bd/watch.nim`. It writes nothing into the game, because everything the
## original changed there needs a mechanism post-1.0 does not have; the reasons
## are below and none of them is this port being lazy.
##
## ---------------------------------------------------------------------------
## What is deliberately missing, and why
## ---------------------------------------------------------------------------
##
## **The prepatcher.** Its whole content was six `CustomWildSpawnType`
## registrations, each of which appended an enum member to `EFT.WildSpawnType`
## inside `Assembly-CSharp.dll` with Mono.Cecil before the CLR loaded it.
## Post-1.0 Tarkov is IL2CPP: there is no managed `Assembly-CSharp.dll` to
## rewrite, the enum is native constants with its switch tables already compiled,
## and there is no pre-load window because nothing is loaded. So the client does
## not learn that `848421` means anything. The ids are still registered on the
## server — they are what the difficulty documents' `ENEMY_BOT_TYPES` are written
## in, and the faction graph is entirely built on them — but the client half of
## that contract cannot be honoured and is not pretended at.
##
## **The hunt behaviour.** `HuntTargetLayer` at priority 10 over the PMC brains,
## `AdvAssaultTarget` removed, `HuntManager.AddHuntRoles` / `AddHuntSides`
## pointing the squad at PMCs and at the player: all of it is BigBrain custom
## layers and Unity `MonoBehaviour`s hosted by BepInEx. None of the three exists
## post-1.0. What remains of the hunt is its *timing and placement* — the squad
## still arrives, on the right maps, at a randomised point in the raid — because
## that half lives in the spawn table, which is server data. Once it spawns it
## behaves like the PMC brain it borrows rather than tracking the player.
##
## **`BDNvgPatch`.** A Harmony prefix on `BotNightVisionData::ManualUpdate` that
## suppressed night vision for Black Division bots. It was already dead upstream
## — `BotOwner_0` was removed in SPT 4.1.2, so it could no longer tell which bot
## it was looking at, and the shipped version returns unconditionally. There is
## nothing to port.
##
## This comment has since been wrong about it twice, and both corrections stay
## on the record rather than being quietly made. The first version said
## `hookArgs` + `stopWith` could not override a return value; it can. The second
## said **a hook is not told which instance it fired on**, and that is false:
## the payload is `{"this":{"handle":n,"type":"..."},"args":[...]}` — Harmony's
## `__instance`, kept out of the argument array on purpose — and `thisHandle`
## and `thisPointer` in `aowlspt/game` read it. `mods/classicmovement` has been
## calling `thisPointer(args)` in shipped code since ABI revision 3.
##
## So the real blocker is a third thing, and it is narrower and it is not going
## away: **`this` is the receiver, never its owner.** A hook on
## `BotNightVisionData::ManualUpdate` is handed the night-vision component. It
## is not handed the bot wearing it, and it cannot navigate upwards to one — a
## payload carries the object in front of the hook and nothing above it. Going
## from the component to the bot's identity is exactly what `BotOwner_0` was
## for, and it is exactly what SPT 4.1.2 removed. Nothing in this tree names a
## replacement, and nothing in this tree could check a guess at one: every
## `EFT.` name here is a pre-1.0 hypothesis.
##
## What this means for the row is that its verdict changes and its outcome does
## not. Suppressing the method is expressible (`stopVoid`); telling which bot to
## suppress it for is not — not because a hook cannot see its instance, but
## because the instance it can see is the wrong object. The identity signal this
## mod does use, its own nickname table, lives on the *player*, which is where
## `bd/watch.nim` reads it and where a night-vision component cannot reach.
##
## **The WTT libraries.** `WTT-ServerCommonLib` supplied three services and all
## three are done here directly, because each turned out to be one `dbWrite`:
## the bot-loadout overlay is `morebots.type.overlay`, the locale injector is a
## merge into `locales.global.en`, and the achievement loader is a read-append-
## write on `templates.achievements`. `WTT-ContentBackport` supplied *item and
## appearance templates* — the bodies, heads, voices, rigs and backpacks the
## data below references by id. That is content, not code: a database without
## those templates gives Black Division bots that spawn and fight with fallback
## appearance, which is a visible cosmetic gap and not a crash.
##
## **The optional integrations.** Upstream probed the installed mod list for
## `com.wtt.armory`, `com.manimal.csgas` and `com.ruafcomehome.tacticaltoaster`
## by GUID. There is no mod-list query in the plugin API, so the Armory loadout
## and the CS-gas grenade are `config.json` switches instead — the user knows
## what they installed. The RUAF hostility is applied only if a `ruaf` faction
## turns out to exist, which is a question morebots can answer.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import bd/data
import bd/dbpath
import bd/types
import bd/spawns
import bd/validate
import bd/watch
import aowlspt/game    # `whenReady` -- the client half waits for a world
import aowlspt/fast    # `perfCounter` -- the clock the watch reports on
import aowlspt/fixture # where a self-test's runtime path may come from

const
  ModGuid = "aowl.blackdivision"
  ModVersion = "1.2.3"

var gRegistered = false
var gDebug = false
var gArmory = false
var gCsGas = false
var gAchievements = true
var gSawMorebots = false
var gHostileScavs = true
var gHostileRogues = true
var gHostilePmcs = true
var gHostileInfected = true
var gHostileRuaf = true
var gRevenge = true

# Declared empty and filled in `readConfig`, not initialised here. A global in a
# `--app:lib` build whose initialiser is a *call* is silently left zeroed —
# literal initialisers are folded at compile time and nothing else survives. As
# `= defaultSpawnConfig()` this read back as zero hunt maps and no spawns at
# all, with no error anywhere.
var gConfig: SpawnConfig

proc debugLog(m: string) =
  if gDebug:
    info "blackdivision: " & m

# ---------------------------------------------------------------------------
# Registration with morebots
# ---------------------------------------------------------------------------

proc registerTypes() =
  let all = allTypes()
  var sharedTemplate = ""
  var sharedConfig = ""
  for t in all:
    var tmpl = ""
    var cfg = ""
    # The shared template is 60KB and five of the six use it. Read once.
    if t.templateFile == SharedTemplate:
      if sharedTemplate.len == 0:
        sharedTemplate = readData(SharedTemplate)
      tmpl = sharedTemplate
    else:
      tmpl = readData(t.templateFile)
    if t.configFile == SharedConfig:
      if sharedConfig.len == 0:
        sharedConfig = readData(SharedConfig)
      cfg = sharedConfig
    else:
      cfg = readData(t.configFile)
    if tmpl.len < 3:
      error "blackdivision: no template for " & t.name & "; skipping it"
      continue
    discard broadcast("morebots.type.register", registrationFor(t, tmpl, cfg))
    debugLog "registered " & t.name & " (" & $t.id & ")"

proc applyLoadouts() =
  ## The templates ship with **empty** equipment on purpose — every gun, plate
  ## and magazine comes from these overlays. That split is upstream's and it is
  ## the right one: the template is what a Black Division operator *is*, the
  ## loadout is what this particular role carries, and the four roles that share
  ## a template do not share a kit.
  let all = allTypes()
  for t in all:
    if t.loadoutFile.len == 0:
      continue
    let patch = readData(t.loadoutFile)
    if patch.len < 3:
      continue
    var one: seq[string] = @[]
    one.add t.name
    discard broadcast("morebots.type.overlay", overlayFor(one, patch))
    debugLog "loadout applied to " & t.name

  if gArmory:
    let armory = readData("loadouts/armory-blackdivassault.json")
    if armory.len > 2:
      var one: seq[string] = @[]
      one.add "blackDivAssault"
      discard broadcast("morebots.type.overlay", overlayFor(one, armory))
      info "blackdivision: WTT-Armory loadout applied to the assault role"

  if gCsGas:
    # Upstream wrote this straight into the bot table when it detected the
    # CS-gas mod. It is a bot document like any other, so it goes through the
    # same overlay rather than a special case: Wedge and the raiders carry a
    # canister at a weight high enough that they always have one.
    var pair: seq[string] = @[]
    pair.add "bossWedge"
    pair.add "blackDivIb"
    let patch = """{"inventory":{"items":{"Pockets":{"6a5d6a5f4ed8c025a0a2cff0":10000},""" &
                """"SecuredContainer":{"6a5d6a5f4ed8c025a0a2cff0":10000}}}}"""
    discard broadcast("morebots.type.overlay", overlayFor(pair, patch))
    info "blackdivision: CS-gas grenades added to Wedge and the raiders"

proc applyRelations(): int =
  ## Both directions of each pairing, and each one behind its own switch.
  ##
  ## The switches are per *faction group* rather than per relation, because
  ## "should Black Division fight the scavs" is a question a player has an
  ## opinion about and "should relation seven of eleven be applied" is not.
  ##
  ## Turning one off stops this mod asking. It does not un-ask: `ENEMY_BOT_TYPES`
  ## is a union that several mods write into and this one does not own it, so
  ## removing an id would be this mod deciding on somebody else's behalf. That
  ## is stated in config.json rather than left to be discovered.
  result = 0
  var enemies: seq[string] = @[]
  if gHostileScavs: enemies.add "savage"
  if gHostileRogues: enemies.add "rogues"
  if gHostilePmcs:
    enemies.add "usec"
    enemies.add "bear"
  if gHostileInfected: enemies.add "infected"
  for f in enemies:
    discard broadcast("morebots.faction.relate", relationTypesToward(f))
    discard broadcast("morebots.faction.relate", relationFactionTowardBd(f))
    result = result + 2
  if gRevenge:
    discard broadcast("morebots.faction.relate", relationRevengeOwn())
    inc result
  # Optional, and asked for without checking: a relation naming a faction that
  # does not exist is a warning in morebots' log and nothing else, which is a
  # better trade than this mod trying to detect another mod it cannot see.
  if gHostileRuaf:
    discard broadcast("morebots.faction.relate",
                      relationTypesToward("ruaf", optional = true))
    inc result

# ---------------------------------------------------------------------------
# The things morebots is not responsible for
# ---------------------------------------------------------------------------

proc applyLocales() =
  ## `ScavRole/BlackDiv` is what the kill feed and the end-of-raid screen show
  ## instead of the raw role name. One string, and without it a player sees
  ## `ScavRole/BlackDiv` written out literally.
  ## Both files in one write. Two writes into the same path cost twice the size
  ## of the database and produce the document a single merged patch produces --
  ## see `bd/spawns.nim` for the measurement.
  var d = newDoc()
  let en = readData("locales/en.json")
  if en.len > 2:
    for m in members(whole(en)):
      setRaw(d, m.name, m.value)
  if gAchievements:
    let ach = readData("locales/achievements-en.json")
    if ach.len > 2:
      for m in members(whole(ach)):
        setRaw(d, m.name, m.value)
  if d.fields.len > 0:
    discard dbPut("locales.global.en", text(d))

proc applyAchievements() =
  ## Three hidden kill-count achievements — 4, 12 and 50 Black Division
  ## operators — each unlocking a Ragman loyalty-4 assortment.
  ##
  ## Upstream ships this data and never loads it: the call is commented out in
  ## `Mod.cs`. The data is complete and correct, so it is loaded here behind a
  ## config switch rather than shipped dead.
  ##
  ## `templates.achievements` is an array, so this is read-append-write with our
  ## own ids filtered out first — running it twice must not give the player six
  ## achievements.
  if not gAchievements:
    return
  let mine = readData("achievements/BD_achievements.json")
  if mine.len < 3:
    return
  var ours: seq[string] = @[]
  let added = each(whole(mine))
  for a in added:
    ours.add field(a, "id").asText("")

  var list = arr()
  let cur = dbRead("templates.achievements")
  if cur.ok and cur.raw.len > 1:
    let existing = each(whole(cur.raw))
    for e in existing:
      let id = field(e, "id").asText("")
      var isOurs = false
      for o in ours:
        if o == id and id.len > 0:
          isOurs = true
      if not isOurs:
        list.add raw(e.raw())
  for a in added:
    list.add raw(a.raw())
  if dbPut("templates.achievements", done(list).text):
    info "blackdivision: " & $ours.len & " achievement(s) added"

proc rerollSpawns(reason: string) =
  let n = adjustAll(gConfig)
  info "blackdivision: spawns rebuilt on " & $n & " map(s) (" & reason & ")"

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc onMorebotsReady(payload: string): string =
  gSawMorebots = true
  if gRegistered:
    return ""
  gRegistered = true
  info "blackdivision: morebots is up; registering Black Division"
  # Order matters here and only here: the faction must exist before a relation
  # can name it, and a bot type must exist before a relation can edit it.
  let t0 = perfCounter()
  discard broadcast("morebots.faction.define", factionDefinition())
  registerTypes()
  let tTypes = perfCounter()
  applyLoadouts()
  let tLoadouts = perfCounter()
  let rel = applyRelations()
  let tRelations = perfCounter()
  debugLog $rel & " hostility relation(s) applied"

  # "I have finished registering." morebots buffers every write a dependent
  # causes and folds them into two `dbWrite` calls; this is what tells it the
  # burst is over, so the database is complete *before* the backend starts
  # listening rather than one server tick after. A morebots that has never
  # heard of this event ignores it and flushes on its own timer instead, so
  # sending it is safe against any version.
  discard broadcast("morebots.flush", objOf("guid", ModGuid))
  let tFlush = perfCounter()

  applyLocales()
  applyAchievements()
  let tData = perfCounter()
  rerollSpawns("load")
  let tSpawns = perfCounter()

  # Printed every load rather than behind the debug switch. This mod's
  # registration was fifty seconds of one 41 MB document being copied four
  # hundred times, and the only reason it went unnoticed for so long is that
  # nothing ever said how long it took.
  info "blackdivision: registered in " &
       $int(nanosBetween(t0, tSpawns) div 1_000_000'i64) & " ms (types " &
       $int(nanosBetween(t0, tTypes) div 1_000_000'i64) & ", loadouts " &
       $int(nanosBetween(tTypes, tLoadouts) div 1_000_000'i64) &
       ", relations " &
       $int(nanosBetween(tLoadouts, tRelations) div 1_000_000'i64) &
       ", flush " & $int(nanosBetween(tRelations, tFlush) div 1_000_000'i64) &
       ", locales+achievements " &
       $int(nanosBetween(tFlush, tData) div 1_000_000'i64) & ", spawns " &
       $int(nanosBetween(tData, tSpawns) div 1_000_000'i64) & ")"
  result = ""

proc onRaidEnded(payload: string): string =
  ## Re-roll, so the next raid on the same map is not the last one again.
  ## Upstream hung this off a `/client/match/local/end` router; the emulator
  ## broadcasts the fact instead, which leaves that route to whoever owns it.
  if gRegistered:
    rerollSpawns("raid ended")
  result = ""

proc checkMorebots(payload: string): string =
  ## If nothing announced itself, say so plainly. Without this the failure mode
  ## is a mod that loads, logs nothing and adds no bots, which reads as a bug in
  ## this mod rather than a missing dependency.
  if not gSawMorebots:
    error "blackdivision: mods/morebots never announced itself. Black " &
          "Division needs it and has registered nothing."
  result = ""

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc readConfig() =
  ## One `setting()` per **top-level** key, and the nesting is read out of the
  ## raw text afterwards. `setting("debug.logs")` and `setting("")` both look
  ## reasonable and neither works: the backend's config reader takes a single
  ## top-level name, so a dotted key is `ErrNotFound` and an empty one is too.
  ## Asking for `"debug"` and reading `.logs` out of the object it returns works
  ## on every host.
  gConfig = defaultSpawnConfig()
  gAchievements = setting("achievements").asBool(true)
  gArmory = setting("armoryLoadouts").asBool(false)
  gCsGas = setting("csGasGrenades").asBool(false)

  let dbg = setting("debug")
  if dbg.ok and dbg.raw.len > 1:
    gDebug = field(dbg.raw, "logs").asBool(false)

  # One `setting()` per top-level key and the nesting read out of the raw text,
  # for the same reason as `debug` above: the config reader takes a single
  # top-level name and a dotted one is ErrNotFound on every host.
  let host1 = setting("hostility")
  if host1.ok and host1.raw.len > 1:
    let h = whole(host1.raw)
    gHostileScavs = child(h, "scavs").asBool(true)
    gHostileRogues = child(h, "rogues").asBool(true)
    gHostilePmcs = child(h, "pmcs").asBool(true)
    gHostileInfected = child(h, "infected").asBool(true)
    gHostileRuaf = child(h, "ruaf").asBool(true)
    gRevenge = child(h, "revenge").asBool(true)

  let spawns = setting("spawns")
  if spawns.ok and spawns.raw.len > 1:
    gConfig = readSpawnConfig(spawns.raw)
  else:
    warn "blackdivision: no 'spawns' in config.json; using the defaults"

# ---------------------------------------------------------------------------
# The client half
# ---------------------------------------------------------------------------
#
# Read-only, and see `bd/watch.nim` for why that is the useful thing rather than
# the consolation prize. Everything that *makes* the squad arrive is server data
# in `bd/spawns.nim`; whether it arrived is a fact about a live raid, and before
# this the mod had no way to tell a squad that never spawned from one that
# spawned 700 m away on the far side of Streets. Both read as "the mod does
# nothing".

var gWatchIntervalMs = 5000
var gLastWatchMs = 0'i64
var gWatchBound = false
var gWatchReported = false
var gSeenOurs = false
var gWorld = whenReady("EFT.GameWorld")

proc sightingJson(s: Sighting): string =
  var names = arr()
  for i in 0 ..< s.names.len:
    add(names, s.names[i])
  var o = obj()
  put(o, "ok", s.ok)
  put(o, "aiAlive", s.aiAlive)
  put(o, "ours", s.ours)
  put(o, "unreadableNicknames", s.unreadable)
  put(o, "haveDistance", s.haveDistance)
  put(o, "nearest", s.nearest)
  put(o, "scanNs", int(s.scanNs))
  put(o, "names", names)
  result = done(o).text

proc watchTick() =
  if not gWatchBound:
    if not openWatch():
      return
    loadNames()
    watchBind()
    gWatchBound = true
  let now = nowMs()
  if gLastWatchMs != 0'i64 and now - gLastWatchMs < int64(gWatchIntervalMs):
    return
  gLastWatchMs = now

  let s = runWatch()
  if not s.ok:
    return
  if not gWatchReported:
    gWatchReported = true
    watchReport()
  if s.ours > 0:
    if not gSeenOurs:
      gSeenOurs = true
      success "blackdivision: the squad is in the raid -- " & describe(s)
    else:
      info "blackdivision: " & describe(s)
    discard emit("blackdivision.client.present", sightingJson(s))
  else:
    debugLog describe(s)

proc onMorebotsCensus(payload: string): string =
  ## `mods/morebots` publishes a census of every alive bot by spawn type. This
  ## mod cares about one line of it: whether any *custom* spawn type reached the
  ## client. If one ever did, the six role ids below would mean something on the
  ## client and the identification in `bd/watch.nim` could stop going through
  ## nicknames -- so it is worth noticing rather than assuming for ever.
  if field(payload, "customSpawnTypes").asInt(0) > 0:
    warn "blackdivision: morebots reports a custom spawn type reached the " &
         "client. That contradicts what both mods' module comments say is " &
         "possible post-1.0; the nickname match in bd/watch.nim could be " &
         "replaced by a role match if it holds up."
  result = ""

proc onLoadClient(): Status =
  ## What the original client half did -- six `WildSpawnType` members appended
  ## by a prepatcher, and a BigBrain hunt layer -- is still out of reach
  ## post-1.0 and is still said plainly. What is not out of reach is observing
  ## whether the squad this mod spawns actually turned up, and that is what runs
  ## here. It writes nothing into the game.
  gWatchIntervalMs = setting("watchIntervalMs").asInt(5000)
  if gWatchIntervalMs < 500:
    gWatchIntervalMs = 500
  loadNames()
  discard onEvent("morebots.client.census", onMorebotsCensus)
  info "blackdivision: the client half cannot add the six role ids to " &
       "WildSpawnType (native constants, switch tables already compiled) and " &
       "has no BigBrain to host the hunt layer -- see the module comment. " &
       "What it does instead is watch for the squad by the " & $nameCount() &
       " first name(s) in this mod's own bot templates, every " &
       $gWatchIntervalMs & " ms, read-only."
  if nameCount() == 0:
    warn "blackdivision: no first names were loaded from data/types/, so the " &
         "watch cannot recognise anything. Check that data/ shipped beside " &
         "the binary."
  Ok

proc onLoadServer(): Status =
  seedRandom(nowMs())
  readConfig()
  discard onEvent("morebots.ready", onMorebotsReady)
  discard onEvent("tarkov.raid.ended", onRaidEnded)
  info "blackdivision " & ModVersion & " loaded, waiting for morebots (" &
       $gConfig.huntMaps.len & " hunt map(s) configured)"
  # Both halves of the handshake, and neither of them a timer. If morebots
  # loaded first its `morebots.ready` is already gone, so ask; if it has not
  # loaded yet this goes nowhere and its announcement will arrive instead.
  var hello = obj()
  put(hello, "guid", ModGuid)
  discard broadcast("morebots.hello", hello)
  discard afterMs(3000, checkMorebots)
  Ok

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------
#
#     aowl run mods/blackdivision            # --side sim
#
# Before this existed the simulator ran the server half and printed "waiting for
# morebots", then unloaded with "never registered" -- which is the *correct*
# behaviour with no morebots present and is also no information at all about
# whether this mod works.
#
# Three halves are checked here, because the mod has three:
#
#  * **The data.** Six bot types, their templates, their loadouts, the locale
#    and the achievements are files shipped beside the binary. A missing or
#    malformed one is a bot that spawns with fallback appearance, and it is
#    decidable here rather than in a raid.
#  * **The registration.** morebots is not present under the simulator, so the
#    handshake is driven by hand: this mod is told `morebots.ready` and every
#    document it then broadcasts is built and parsed back.
#  * **The client watch.** Its bindings are reported, its Win64 shape rule is
#    exercised exhaustively, and its name table is checked against the files it
#    came from. `selfTestRuntime` in config.json points it at any
#    `GameAssembly.dll` for a real binding report offline.

proc simSelfTest(): Status =
  info "Black Division self-test (--side sim)"
  var bad = 0

  seedRandom(nowMs())
  readConfig()

  # --- the data files, each one named so a miss is actionable.
  let all = allTypes()
  var files: seq[string] = @[]
  for t in all:
    var have = false
    for f in files:
      if f == t.templateFile: have = true
    if not have: files.add t.templateFile
    have = false
    for f in files:
      if f == t.configFile: have = true
    if not have: files.add t.configFile
    if t.loadoutFile.len > 0:
      have = false
      for f in files:
        if f == t.loadoutFile: have = true
      if not have: files.add t.loadoutFile
  files.add "locales/en.json"
  files.add "achievements/BD_achievements.json"
  var missing = 0
  for f in files:
    let text = readData(f)
    if text.len == 0:
      error "  data/" & f & " is missing or empty"
      inc missing
    elif keys(whole(text)).len == 0 and each(whole(text)).len == 0:
      error "  data/" & f & " is not a JSON object or array"
      inc missing
  if missing == 0:
    success "  all " & $files.len & " shipped data file(s) read and parsed"
  else:
    error "  " & $missing & " of " & $files.len & " data file(s) unusable; " &
          "bots would spawn with fallback appearance and loadouts"
    bad = bad + missing

  # --- and now what is *in* them, which is the part a parse cannot answer.
  #
  # Parsing says the bytes are JSON. It says nothing about whether the faction
  # is complete, and an incomplete faction still spawns -- see the header of
  # bd/validate.nim. So: every template id checked for shape, every equipment
  # slot checked against the fourteen the game has, every pool checked for a
  # weight that can actually roll, every chance checked against a pool, every
  # name checked for a duplicate. Counts are printed rather than a verdict,
  # because "ok" cannot tell forty loadouts from three.
  var rep = Report(files: 0, equipmentSlots: 0, equipmentIds: 0, modRoots: 0,
                   modRefs: 0, ammoCalibers: 0, ammoRounds: 0, chanceKeys: 0,
                   names: 0, badIds: 0, badSlots: 0, badWeights: 0,
                   orphanChances: 0, orphanPools: 0, duplicates: 0,
                   problems: 0)

  var templates: seq[string] = @[]
  for t in all:
    if not templates.contains(t.templateFile):
      templates.add t.templateFile
  for tf in templates:
    inc rep.files
    checkTemplate("data/" & tf, readData(tf), rep)

  # A loadout is checked against the chances of the template it lands on, so
  # a chance the template already carries is not reported as missing.
  var sharedChances = chanceKeysOf(readData(SharedTemplate))
  for t in all:
    if t.loadoutFile.len == 0:
      continue
    inc rep.files
    var tmplChances = sharedChances
    if t.templateFile != SharedTemplate:
      tmplChances = chanceKeysOf(readData(t.templateFile))
    checkLoadout("data/" & t.loadoutFile, readData(t.loadoutFile),
                 tmplChances, rep)
  inc rep.files
  checkLoadout("data/loadouts/armory-blackdivassault.json",
               readData("loadouts/armory-blackdivassault.json"),
               sharedChances, rep)

  inc rep.files
  checkAchievements("data/achievements/BD_achievements.json",
                    readData("achievements/BD_achievements.json"),
                    readData("locales/achievements-en.json"), rep)

  # Every role has a distinct id and a distinct name, or the faction graph
  # disagrees with itself: `relate` resolves a name to an id, and two names
  # sharing an id makes one of them unreachable.
  var seenIds: seq[int] = @[]
  var seenNames: seq[string] = @[]
  for t in all:
    var dupId = false
    for i in seenIds:
      if i == t.id: dupId = true
    if dupId:
      error "  two roles share the WildSpawnType id " & $t.id
      inc rep.duplicates
      inc rep.problems
    else:
      seenIds.add t.id
    if seenNames.contains(t.name):
      error "  two roles are both called " & t.name
      inc rep.duplicates
      inc rep.problems
    else:
      seenNames.add t.name
    if t.loadoutFile.len == 0:
      warn "  " & t.name & " has no loadout file, so it wears whatever the " &
           "shared template carries -- which for this mod is nothing"
      inc rep.problems

  info "  data: " & summarise(rep)
  if rep.problems == 0:
    success "  every template id is well-formed, every equipment slot is one " &
            "of the " & $EquipmentSlots.len & " the game has, every pool has " &
            "a weight that can roll, and no id or name is used twice"
  else:
    error "  " & $rep.problems & " content problem(s): " & $rep.badIds &
          " malformed id(s), " & $rep.badSlots & " unknown slot(s), " &
          $rep.badWeights & " unrollable pool(s), " & $rep.duplicates &
          " duplicate(s). These do not crash anything -- they make the " &
          "faction quietly worse, which is why they are checked here"
    bad = bad + rep.problems
  if rep.orphanChances > 0 or rep.orphanPools > 0:
    info "  " & $rep.orphanChances & " chance(s) with no pool beside them " &
         "and " & $rep.orphanPools & " pool(s) with no chance beside them; " &
         "both inherit from the shared template, which is legal and is worth " &
         "seeing"

  # --- the spawn config, which is the whole of what makes the squad arrive.
  if gConfig.huntMaps.len == 0:
    error "  no hunt maps configured; the squad has nowhere to spawn and the " &
          "mod would do nothing at all"
    inc bad
  else:
    success "  " & $gConfig.huntMaps.len & " hunt map(s), " &
            $gConfig.chance & "% chance, squads of " & $gConfig.minHuntSize &
            ".." & $gConfig.maxHuntSize & ", arriving between " &
            $gConfig.minTimeTenths & "/10 and " & $gConfig.maxTimeTenths &
            "/10 of the way through the raid"

  # --- the spawn-point guard, exercised on both branches rather than described.
  #
  # An empty `SpawnPointParams` is the difference between a squad and a record.
  # A location slot that is in the database and has nowhere to put a bot takes
  # a BossLocationSpawn entry without complaint and never fires, which is the
  # failure this mod's whole self-test exists to catch: installed, silent, and
  # indistinguishable from never having reached the map.
  var withPoints = 0
  var noPoints: seq[string] = @[]
  for m in gConfig.huntMaps:
    if not locationExists(m):
      continue
    if spawnable(m):
      inc withPoints
    else:
      noPoints.add m
  if noPoints.len == 0:
    success "  every hunt map this database has can host a spawn (" &
            $withPoints & " checked); a map whose SpawnPointParams is present " &
            "and empty is refused rather than written to"
  else:
    var names = noPoints[0]
    for i in 1 ..< noPoints.len:
      names = names & ", " & noPoints[i]
    info "  " & $noPoints.len & " hunt map(s) refused for an empty " &
         "SpawnPointParams (" & names & ") and " & $withPoints & " accepted"

  # --- and the same data against a real item table, when there is one.
  #
  # The offline pass above checks id *shape*. Shape catches every typo and
  # catches nothing else: `5e00c1ad86f774747333222c` is a perfectly well-formed
  # id for an item that does not exist, and a pool full of those is a slot that
  # is always bare. That is not hypothetical for this mod -- see `config.json`
  # on `armoryLoadouts`, whose eleven weapon ids all belong to WTT-Armory.
  #
  # `attached` is the probe already done just above: if any hunt map resolved,
  # there is a database. With none, this reports *unchecked*, which is a
  # different thing from clean and is printed as a different thing.
  let dbAttached = (withPoints > 0 or noPoints.len > 0)
  var dbLabels: seq[string] = @[]
  var dbTexts: seq[string] = @[]
  for t in all:
    if t.loadoutFile.len == 0:
      continue
    dbLabels.add "data/" & t.loadoutFile
    dbTexts.add readData(t.loadoutFile)
  # The Armory loadout is checked only when it is switched on. Checking a file
  # the mod does not load would report a fault nobody has -- `armoryLoadouts`
  # is false by default and all eleven of its weapon ids are WTT-Armory's, so
  # on a default install it would fail every run against a stock database for
  # a file that never reaches a bot.
  if gArmory:
    dbLabels.add "data/loadouts/armory-blackdivassault.json"
    dbTexts.add readData("loadouts/armory-blackdivassault.json")
  let dbc = checkAgainstDatabase(dbLabels, dbTexts, dbAttached)
  info "  database: " & describeDbCheck(dbc)
  if dbc.attached:
    # The positive control, and it is not decoration. Every count this pass
    # reports is monotone, so "0 problems" and "the pass never ran" print
    # identically -- which is the failure this project keeps producing. If a
    # database is attached and not one id was put to it, the pass is broken and
    # says so rather than reporting a clean bill of health for nothing.
    if dbc.ids == 0 or dbc.pools == 0:
      error "  a database is attached and the pass probed " & $dbc.ids &
            " id(s) across " & $dbc.pools & " pool(s). It did not run, and a " &
            "check that reports no problems because it never happened is " &
            "worse than no check"
      inc bad
    if dbc.absent > 0:
      var shown = 0
      var absentLine = ""
      for a in dbc.absentIds:
        if shown >= 24:
          break
        if shown > 0: absentLine = absentLine & ", "
        absentLine = absentLine & a
        inc shown
      var howMany = ""
      if dbc.absent > shown:
        howMany = " (first " & $shown & " named)"
      info "  " & $dbc.absent & " id(s) this database does not have" &
           howMany &
           ": " & absentLine & ". Absent content is not a fault by itself -- " &
           "WTT-ContentBackport's rigs, packs and face covers live here -- " &
           "so the fault rule is asked per pool instead."
    if dbc.emptiedPools == 0:
      success "  every one of the " & $dbc.pools & " pool(s) in the shipped " &
              "loadouts still has at least one id this database can resolve, " &
              "so no slot is silently always-bare"
    else:
      # Reported at warn and NOT failed, on the same rule this file already
      # applies to a hunt map with no spawn points: it is a fact about the
      # database attached, not about this mod's data. The same loadout against
      # a database that has WTT-ContentBackport installed has no empty pool at
      # all, and a self-test whose verdict depends on which database happens to
      # be lying around is not a gate. It is still said out loud, per pool and
      # by name, because "the faction is quietly a bit worse" is precisely the
      # failure this whole file exists to make visible.
      for e in dbc.emptied:
        warn "  " & e & " -- every id in this pool is absent from THIS " &
             "database, so the slot is always bare here. A bot rolls for it, " &
             "finds nothing, and spawns without it; nothing errors and " &
             "nothing logs in a raid"
      warn "  " & $dbc.emptiedPools & " pool(s) can never roll against this " &
           "database. Install WTT-ContentBackport and they fill; without it " &
           "those bots wear nothing in those slots. NOTE: this mod's README " &
           "used to claim every slot holding a WTT id also holds a " &
           "db-verified alternative. Against a stock 4.x database that is " &
           "false for the pools named above, and this pass is how it was found"
    # The weapon slots are the exception, and they are a hard failure. A bot
    # with no rig is a worse bot; a bot with no gun is not a bot. This can only
    # fire when `armoryLoadouts` is on, because that is the only loadout whose
    # weapon pools are entirely third-party -- which is exactly the case
    # config.json warns about and nothing checked until this pass existed.
    if dbc.emptiedArmed.len > 0:
      for e in dbc.emptiedArmed:
        error "  " & e & " -- this is a WEAPON slot with nothing in it that " &
              "this database can resolve. Those bots spawn UNARMED"
      error "  " & $dbc.emptiedArmed.len & " weapon pool(s) can never roll. " &
            "`armoryLoadouts` is on and WTT-Armory is not in this database; " &
            "turn the switch off or install the mod it needs"
      bad = bad + dbc.emptiedArmed.len

  # --- the registration, driven by hand because morebots is not here.
  discard onMorebotsReady("")
  if gRegistered:
    success "  the morebots.ready handshake registered " & $all.len &
            " bot type(s), the faction, the loadouts and the relations"
  else:
    error "  the morebots.ready handshake did not register"
    inc bad

  # --- the client watch.
  let wanted = selfTestRuntime(setting("selfTestRuntime").asText(""))
  if wanted.refusal.len > 0:
    warn "  " & wanted.refusal
  let runtimePath = wanted.path
  var opened = false
  if runtimePath.len > 0:
    opened = openWatchAt(runtimePath, "aowl-blackdivision-selftest")
    if opened:
      info "  bound " & runtimePath & " for the watch binding report"
    else:
      warn "  selfTestRuntime " & runtimePath & " could not be loaded"
  if not opened:
    opened = openWatch()
  if not opened:
    warn "  no IL2CPP runtime in this process -- aowlspt-sim is a managed " &
         "host and GameAssembly.dll is not loaded. Every watch binding will " &
         "refuse for that reason, which is the correct answer here. Set " &
         "AOWLSPT_SELFTEST_RUNTIME, or \"selfTestRuntime\" in config.json, " &
         "to an ABSOLUTE path to a GameAssembly.dll for a real report offline."

  # The name table is the whole of the client half's identification, and it is
  # this mod's own data rather than a guess about the game -- so it is fully
  # checkable here, and a positive *and* a negative case are both run.
  loadNames()
  if nameCount() == 0:
    error "  the watch loaded no first names; it could not recognise a " &
          "Black Division bot if one stood in front of it"
    inc bad
  else:
    success "  the watch knows " & $nameCount() & " first name(s) from " &
            $nameFileCount() & " template file(s)"
    if not isOurName("Anvil"):
      error "  a name from this mod's own table was not recognised"
      inc bad
    if not isOurName("anvil"):
      error "  the name match is case-sensitive; the game's casing would miss"
      inc bad
    if isOurName("Nikita"):
      error "  a name that is not in this mod's table was recognised as ours"
      inc bad
    if isOurName(""):
      error "  an empty nickname was recognised as ours"
      inc bad

  # The Win64 rule, exhaustively, with no runtime involved. This is the half of
  # the shaped-call guard that decides *whether* the shaped path is taken, and
  # it is a pure function of a size -- so both branches are shown to work here
  # rather than only on a machine with Tarkov on it.
  var ruleBad = 0
  var sz = 1
  while sz <= 24:
    let want = (sz != 1 and sz != 2 and sz != 4 and sz != 8 and sz <= 16)
    if shapedSizeAccepted(sz) != want:
      error "  guard: a " & $sz & "-byte aggregate is classified wrongly"
      inc ruleBad
    inc sz
  if shapedSizeAccepted(0) or shapedSizeAccepted(-4):
    error "  guard: the rule accepted a nonsensical size"
    inc ruleBad
  if ruleBad == 0:
    success "  the Win64 hidden-pointer rule accepts 3, 5, 6, 7 and 9..16 " &
            "bytes and refuses 1, 2, 4, 8 and anything past 16 -- so a " &
            "Vector3 takes the shaped path and a float does not"
  else:
    bad = bad + ruleBad

  calibrateHeader()
  if headerBytes() < 0:
    warn "  the value-type size convention could not be calibrated from this " &
         "runtime, so get_Position will refuse the shaped path and distances " &
         "will not be reported. Expected with no runtime attached."
  else:
    info "  value-type instance sizes include a " & $headerBytes() &
         "-byte header on this runtime, calibrated from System.Int32 and " &
         "System.Double rather than assumed"
    if shapedRetSizeOk("System.Int32") or shapedRetSizeOk("System.String"):
      error "  guard: a register-sized value type or a reference was " &
            "accepted for the hidden-return-pointer shape"
      inc bad
    else:
      success "  the type half of the guard refuses System.Int32 (register " &
              "sized) and System.String (a reference)"

  watchBind()
  watchReport()
  let s = runWatch()
  info "  watch: " & describe(s)

  info "  refusals that are permanent on any post-1.0 client, with the reason:"
  info "    the six role ids -- WildSpawnType is native constants with its " &
       "switch tables already compiled; there is no managed " &
       "Assembly-CSharp.dll to rewrite and no pre-load window to do it in. " &
       "The ids stay server-side, where the difficulty documents and the " &
       "faction graph are written in them, and the client half identifies " &
       "the squad by this mod's own nickname table instead."
  info "    HuntTargetLayer, AdvAssaultTarget, HuntManager -- BigBrain custom " &
       "layers and Unity MonoBehaviours hosted by a BepInEx that does not " &
       "exist here. The timing and placement half of the hunt survives, " &
       "because that lives in the spawn table."
  info "    BDNvgPatch -- already dead upstream (BotOwner_0 was removed in " &
       "SPT 4.1.2, so it could no longer tell which bot it was looking at). " &
       "This line used to add that a hook here is told a method's declared " &
       "arguments and not `this`. That was FALSE and is corrected: the " &
       "payload carries `this` as Harmony's __instance and thisPointer turns " &
       "it into an address, as mods/classicmovement does in shipped code. " &
       "The real blocker is narrower -- `this` is the RECEIVER, never its " &
       "owner. A hook on BotNightVisionData::ManualUpdate gets the " &
       "night-vision component and cannot navigate up to the bot wearing " &
       "it, which is precisely the step BotOwner_0 used to be. Suppressing " &
       "the method is expressible; knowing which bot to suppress it for is " &
       "not."
  info "    WTT-ContentBackport's item and appearance templates -- content, " &
       "not code. Without them the bots spawn and fight with fallback " &
       "appearance, which is cosmetic rather than a crash."

  # --- cost, on the same clock a client mod times a frame with.
  const Iterations = 2000
  let t0 = perfCounter()
  var i = 0
  while i < Iterations:
    discard runWatch()
    inc i
  let per = nanosBetween(t0, perfCounter()) div int64(Iterations)
  if s.ok:
    success "  watch cost " & $per & " ns per scan over " & $Iterations &
            " scans, on " & $s.aiAlive & " AI"
  else:
    info "  watch cost " & $per & " ns per scan over " & $Iterations &
         " scans, none of which found a world. That is the guard: what the " &
         "watch costs outside a raid. It is not per-frame work either way -- " &
         "it runs every " & $gWatchIntervalMs & " ms."
  info "  for comparison, docs/PERF.md measures one boxed host call at " &
       "950-1235 ns; the same walk on the boxed path would be ~250 us for a " &
       "raid's worth of bots, which is why it is not on it"

  if bad == 0:
    success "Black Division self-test: data, registration and the client " &
            "watch all check out with no backend and no game attached"
    result = Ok
  else:
    error "Black Division self-test: " & $bad & " problem(s)"
    result = ErrGeneric

proc onLoad(): Status =
  case side()
  of sideClient: result = onLoadClient()
  of sideSim: result = simSelfTest()
  else: result = onLoadServer()

proc onUpdate(elapsedMs: int64): Status =
  ## The client half only. The server half is entirely event-driven and has
  ## nothing per-tick to do.
  if side() != sideClient:
    return Ok
  if gWorld.ready():
    success "blackdivision: the game world is up; watching for the squad"
  if gWorld.fired:
    watchTick()
  Ok

proc onUnload(): Status =
  if side() != sideClient and not gRegistered:
    warn "blackdivision: unloaded without ever registering"
  Ok

exportMod(
  guid = ModGuid,
  name = "Black Division",
  author = "TacticalToaster (ported to aowlspt)",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
