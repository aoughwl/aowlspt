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
## **Client (`sideClient`).** Nothing but a line in the log, and that is not this
## port being lazy. See below.
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
## nothing to port, and `hook()` could not override a return value if there were.
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

const
  ModGuid = "aowl.blackdivision"
  ModVersion = "1.2.3"

var gRegistered = false
var gDebug = false
var gArmory = false
var gCsGas = false
var gAchievements = true
var gSawMorebots = false

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

proc applyRelations() =
  ## Eleven relations, and the order within them does not matter — but both
  ## directions of each pairing do. Black Division against the world, and the
  ## world against Black Division.
  let enemies = ["savage", "rogues", "usec", "bear", "infected"]
  for f in enemies:
    discard broadcast("morebots.faction.relate", relationTypesToward(f))
    discard broadcast("morebots.faction.relate", relationFactionTowardBd(f))
  discard broadcast("morebots.faction.relate", relationRevengeOwn())
  # Optional, and asked for unconditionally: a relation naming a faction that
  # does not exist is a warning in morebots' log and nothing else, which is a
  # better trade than this mod trying to detect another mod it cannot see.
  discard broadcast("morebots.faction.relate", relationTypesToward("ruaf"))

# ---------------------------------------------------------------------------
# The things morebots is not responsible for
# ---------------------------------------------------------------------------

proc applyLocales() =
  ## `ScavRole/BlackDiv` is what the kill feed and the end-of-raid screen show
  ## instead of the raw role name. One string, and without it a player sees
  ## `ScavRole/BlackDiv` written out literally.
  let en = readData("locales/en.json")
  if en.len > 2:
    discard dbPut("locales.global.en", en)
  if gAchievements:
    let ach = readData("locales/achievements-en.json")
    if ach.len > 2:
      discard dbPut("locales.global.en", ach)

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
  discard broadcast("morebots.faction.define", factionDefinition())
  registerTypes()
  applyLoadouts()
  applyRelations()
  applyLocales()
  applyAchievements()
  rerollSpawns("load")
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

  let spawns = setting("spawns")
  if spawns.ok and spawns.raw.len > 1:
    gConfig = readSpawnConfig(spawns.raw)
  else:
    warn "blackdivision: no 'spawns' in config.json; using the defaults"

proc onLoadClient(): Status =
  info "blackdivision: nothing runs on the client post-1.0 — the six roles " &
       "cannot be added to WildSpawnType without managed assemblies, and the " &
       "hunt layer needs BigBrain. The faction is entirely server-side."
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

proc onLoad(): Status =
  if side() == sideClient:
    return onLoadClient()
  result = onLoadServer()

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
  onUnload = onUnload)
