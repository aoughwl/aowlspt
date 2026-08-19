## MoreBots — the bot-type and faction API other mods build on.
##
## A from-scratch rewrite for aowlspt of **MoreBotsAPI** by TacticalToaster
## (https://discord.gg/nxa3W7w4rJ), whose original C# client plugin, prepatcher
## and SPT server mod this replaces. Upstream is licensed **CC BY-NC-SA 4.0**;
## that licence travels with this port and its text is in `LICENSE` beside this
## file. Same terms, same author to credit, different language and a different
## runtime.
##
##     aowl build-mod mods/morebots
##
## ---------------------------------------------------------------------------
## WHAT IT CHANGES, WHAT IT ASSUMES, AND WHAT IT HAS NEVER BEEN RUN AGAINST
## ---------------------------------------------------------------------------
##
## **What it changes.** On the **server**, three things, all in the shared
## database and all through `dbWrite`, which merges:
##
##   * a bot type document per registered type, plus whatever loadout overlay a
##     dependent sends for it;
##   * the four difficulty documents' `ENEMY_BOT_TYPES` lists, which is what a
##     faction relation actually *is*;
##   * `bots.config.maxBotCap` on every map, by a flat amount, and only when
##     `increaseBotCapAmount` says so (it is 0 by default: a server quietly
##     running more AI than the user asked for is not a feature).
##
## Plus five routes, four of them under `/morebotsapi/`.
##
## On the **client**, nothing. Not "nothing yet" — the client half is read-only
## by design and writes nothing into the game. What it *does* is count: every
## few seconds it walks the world's alive-player list on the fast path, tallies
## the AI by spawn type, measures how far the nearest and farthest are from the
## player, and publishes the result as `morebots.client.census`. See
## `bots/census.nim` for why that is the useful thing rather than the consolation
## prize: the server writes spawn tables and caps, and whether the client
## honoured them is a fact that can only be observed in the client's process.
##
## An earlier revision of this file had a client half that logged one line about
## what could not be done and then did nothing at all. That line was true about
## the original's client half and it was being used as a reason to ship an inert
## side, which is a different claim.
##
## **What it assumes about the client.** Ten members, every one of them bound
## against the object it is reached on rather than against a name — because the
## chain is nothing but subclasses and generics (`List<IPlayer>` has no name
## `findClass` accepts at all). Two things are asserted rather than inferred and
## both are guarded by asking the runtime first: `get_Position` returns a
## twelve-byte `Vector3` that Win64 hands back through a hidden pointer
## (`bindRaw`), and `get_Role` returns an enum asserted as `Int32` only after the
## runtime confirms a four-byte value type. Even the header size in that
## calculation is calibrated from `System.Int32` and `System.Double` rather than
## assumed. A wrong name or an unconfirmable size is a refused binding, a `why`
## line, and a census that reports fewer facts — never a wrong number.
##
## **It has never been run against BSG's game.** Not once. Every `EFT.` name in
## `bots/census.nim` is from the pre-1.0 C# surface; post-1.0 is a different
## build. `aowl run mods/morebots` prints the whole binding report offline and
## exercises the Win64 shape rule exhaustively; it establishes that the
## machinery is right and establishes nothing whatever about the names.
##
## ---------------------------------------------------------------------------
## What an API looks like here
## ---------------------------------------------------------------------------
##
## Upstream was an API in the C# sense: other mods took a hard assembly
## reference on `MoreBotsServer.dll`, injected `FactionService` through the DI
## container and called methods on it. None of that exists across a C ABI, and
## inventing a private channel for it would put one mod in a privileged position
## the plugin API does not otherwise grant.
##
## So the API is **events and the database**, which is what aowlspt already
## gives every mod:
##
## | event | what it does |
## |---|---|
## | `morebots.ready` *(emitted)* | morebots is up; register now |
## | `morebots.hello` | "are you there?" — answered with `morebots.ready` |
## | `morebots.type.register` | one custom bot type: identity, template, config |
## | `morebots.type.overlay` | a partial document merged onto existing types |
## | `morebots.faction.define` | a named set of roles, possibly nesting |
## | `morebots.faction.relate` | who shoots whom, in one direction |
## | `morebots.registered` *(emitted)* | a type landed, for anything watching |
##
## and the shared database underneath, where `dbWrite` **merges**. That is what
## makes the design work at all: a bot type document, a loadout overlay and a
## faction's enemy list are three mods writing three parts of the same object,
## and none of them clobbers the others.
##
## Mods load in an order nobody controls, so the handshake covers both
## directions and does not depend on a timer to do it:
##
##  * morebots broadcasts `morebots.ready` at the end of its own `onLoad`. That
##    reaches every dependent that loaded **before** it and was already
##    subscribed.
##  * a dependent that loads **after** morebots finds that announcement already
##    gone, so it says `morebots.hello` at the end of *its* load; morebots is
##    subscribed by then and answers with another `morebots.ready`.
##  * and once more from `afterMs(0)`, for anything that manages to miss both.
##    Belt, braces and a third thing — but note that timers run from the
##    server's main loop, which a `--selftest` run never reaches, so the timer
##    is the backstop rather than the mechanism.
##
## Everything a dependent sends is idempotent by name, so being told twice costs
## a few string comparisons and removes an entire class of "works on my machine,
## depending on directory order" bug.
##
## ---------------------------------------------------------------------------
## Which half runs where
## ---------------------------------------------------------------------------
##
## One binary, both sides, split by `side()`.
##
## **Server (`sideServer`, and `sideSim` for testing).** Everything above: the
## registry, the faction graph, the four routes, the revenge counters, the bot
## cap. This is where essentially all of the original's value was, and it ports
## across cleanly, because it is data manipulation and HTTP.
##
## **Client (`sideClient`).** A read-only census of the bots that actually
## arrived — see `bots/census.nim`. It changes nothing in the game, because
## everything the original changed there needs a mechanism post-1.0 does not
## have; the reasons are below and none of them is a limitation of this port.
## What it does instead is answer the question the mod exists for, which is
## whether the server's spawn tables and cap reached the raid.
##
## ---------------------------------------------------------------------------
## What is deliberately missing, and why
## ---------------------------------------------------------------------------
##
## Upstream's client half had three pieces, and post-1.0 none of them can exist.
## They are left out rather than faked:
##
## **The prepatcher is gone.** Its entire job was `Utils.AddEnumValue` — open
## `Assembly-CSharp.dll` with Mono.Cecil before the runtime loads it and append
## a field to `EFT.WildSpawnType`, so that `848421` became a real enum member
## the game's own dictionaries and `Enum.GetName` would accept. Post-1.0 Tarkov
## is IL2CPP: there is no `Assembly-CSharp.dll`, the enum is compile-time
## constants baked into native code with the switch tables already emitted
## around them, and there is nothing to edit before load because nothing is
## loaded. **New `WildSpawnType` values cannot be added to the client.** A
## custom role id therefore reaches the client only if some future path teaches
## it one; the registry keeps and serves the mapping (`/morebotsapi/bottypes`)
## so the data is not lost, but no shipped client reads it.
##
## **The Harmony patches are gone.** Nine of them, and eight need something this
## ABI cannot do — though not the thing an earlier revision of this comment
## claimed. `hookArgs` *does* read a method's declared arguments and `stopWith`
## *does* suppress the original and answer in its place; that sentence was
## stale and is corrected here rather than quietly deleted. What is still
## missing is narrower and it is the same thing eight times: **a hook is not
## told which instance it fired on.** `BotsGroup::IsPlayerEnemy` needs to change
## a return value *for one group*, and the group is `this`;
## `BotGroupWarnData::ShallBossAttack` the same; `SuitableFollowersList` needs
## to mutate a list it is handed; `BaseStatisticsManager::OnDeath` needs the
## dead player; `StandartBotBrain::Activate` needs to swap a live brain object,
## which means constructing a managed type and nothing native can declare one.
## None of that is expressible, so none of it is here. The two that
## *would* have worked (`TarkovApplication::Init` and `BotsController::Init`,
## which only need to know *that* something happened) existed solely to
## construct the managers below, so they have nothing left to do.
##
## **The hunt behaviour is gone.** `HuntManager`, `BotHuntManager`,
## `HuntTargetLayer` and its three actions are Unity `MonoBehaviour`s plus
## custom BigBrain layers. There is no BepInEx to host a plugin, no BigBrain to
## register a layer with, and `invoke_main` reaches the host's own thread rather
## than Unity's — which the ABI documents rather than implies. The SAIN interop
## goes with it; upstream's own `AddSAINLayers` was already a stub in 2.0.3
## because SAIN's `BigBrainHandler.BrainAssignment` API had been removed.
##
## What survives is the part that was always the useful part: a place to declare
## bot types, a faction graph with real hostility semantics, and a server that
## writes both into the game's tables without two mods standing on each other.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import bots/spawntypes
import bots/dbpath
import bots/registry
import bots/factions
import bots/revenge
import bots/spawnscale
import bots/census
import aowlspt/game    # `whenReady` -- the client half waits for a world
import aowlspt/fast    # `perfCounter` -- the clock the census reports on

const
  ModGuid = "aowl.morebots"
  ModVersion = "1.0.0"

var gDebugLogs = false
var gBotCapBump = 0
var gRegistrations = 0

# Declared empty and filled in `readScale`, not initialised here: a global in a
# `--app:lib` build whose initialiser is a *call* is silently left zeroed, so
# `= defaultScaleConfig()` would read back as every multiplier 0 and every map
# capped at nothing, with no error anywhere.
var gScale: ScaleConfig

proc debugLog(m: string) =
  if gDebugLogs:
    info "morebots: " & m

# ---------------------------------------------------------------------------
# Writing what has been buffered
# ---------------------------------------------------------------------------
#
# Every database write this mod makes is buffered by `bots/pending.nim` and
# folded into two `dbWrite` calls, because a `dbWrite` costs the size of the
# database (41 MB on an imported one) rather than the size of the patch. That
# module's header has the measurement.
#
# The three triggers below are redundant on purpose, and each covers a case the
# others do not:
#
#   * `morebots.flush` -- a dependent saying it has finished registering. This
#     is the one that matters, because it lands *inside* the load burst and so
#     the database is complete before the backend starts listening.
#   * every route -- an HTTP caller must never be able to read around the
#     buffer, whatever else has or has not happened.
#   * a zero-delay timer -- a dependent that has never heard of
#     `morebots.flush` still gets its work written, one server tick later.

var gLastBufNs = 0'i64
var gLastFoldNs = 0'i64
var gLastWriteNs = 0'i64

proc flushNow(where: string) =
  if not dirty():
    return
  # The three counters are cumulative over the process, so what is reported is
  # the delta across this flush. A running total printed as if it were this
  # flush's cost reads as a regression that is not there -- and did, once.
  let buf0 = gLastBufNs
  let fold0 = gLastFoldNs
  let wr0 = gLastWriteNs
  let t0 = perfCounter()
  let n = flush()
  let ms = nanosBetween(t0, perfCounter()) div 1_000_000'i64
  if n > 0:
    info "morebots: " & $n & " database write(s) carrying " &
         $bufferedWrites() & " buffered change(s), " & $int(ms) & " ms (" &
         where & ") [buffer " &
         $int((bufferNanos() - buf0) div 1_000_000'i64) & " ms, fold " &
         $int((foldNanos() - fold0) div 1_000_000'i64) & " ms, dbWrite " &
         $int((writeNanos() - wr0) div 1_000_000'i64) & " ms]"
  gLastBufNs = bufferNanos()
  gLastFoldNs = foldNanos()
  gLastWriteNs = writeNanos()

proc flushTick(payload: string): string =
  ## The safety net. Armed by `armFlush` and disarmed by `flush` itself.
  flushNow("timer")
  result = ""

proc armFlush() =
  ## One timer per burst, not one per write.
  if dirty() and not armed():
    arm()
    discard afterMs(0, flushTick)

proc onFlush(payload: string): string =
  ## `morebots.flush`: "I have finished registering; write it."
  ##
  ## A dependent that sends this gets its contribution into the database before
  ## the server starts answering. One that does not still gets it, on the next
  ## tick — so this is an optimisation a dependent may take, not a protocol it
  ## must follow.
  flushNow("morebots.flush")
  result = okJson()

# ---------------------------------------------------------------------------
# Events — the registration surface
# ---------------------------------------------------------------------------

proc onTypeRegister(payload: string): string =
  if registerType(payload):
    inc gRegistrations
    let name = field(payload, "name").asText("")
    debugLog "registered bot type " & name
    armFlush()
    discard broadcast("morebots.registered", objOf("name", name))
    return okJson()
  result = errJson("the registration was refused; see the log")

proc onTypeOverlay(payload: string): string =
  let n = overlayType(payload)
  debugLog "overlay applied to " & $n & " type(s)"
  armFlush()
  result = okJson()

proc onFactionDefine(payload: string): string =
  if define(payload):
    debugLog "faction " & field(payload, "name").asText("") & " defined"
    return okJson()
  result = errJson("the faction definition was refused; see the log")

proc onFactionRelate(payload: string): string =
  let n = relate(payload)
  debugLog "relation applied to " & $n & " bot type(s)"
  armFlush()
  result = okJson()

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onGetFactions(url, body, session: string): string =
  ## Not enveloped. `/morebotsapi/*` is this mod's own namespace rather than one
  ## of the game's `/client/*` endpoints, and the `{"err":0,...}` wrapper is a
  ## contract with the game client specifically.
  flushNow("route")
  result = factionsJson()

proc onGetRevenges(url, body, session: string): string =
  flushNow("route")
  result = revengesJson()

proc onUpdateRevenge(url, body, session: string): string =
  let n = updateRevenge(body)
  debugLog "revenge updated for " & $n & " profile(s)"
  flushNow("route")
  result = okJson()

proc onBotTypes(url, body, session: string): string =
  flushNow("route")
  result = bottypesJson()

proc onDifficulties(url, body, session: string): string =
  ## The one route the *game* asks for. Vanilla difficulties come from whatever
  ## else serves this path; what is added here is the registered custom types,
  ## read back out of the database so the faction edits are included.
  flushNow("route")
  result = difficultiesJson()

# ---------------------------------------------------------------------------
# The bot cap
# ---------------------------------------------------------------------------

proc scalePopulation() =
  ## The part of this mod that its name is actually about.
  ##
  ## `bots/spawnscale.nim` has the whole of the reasoning; the short version is
  ## that it raises `BotMax`, `MaxBotPerZone` and every scav wave's slot count
  ## in `locations.<map>.base`, computed from a shipped vanilla baseline rather
  ## than from the live values, so turning the knob twice is not turning it
  ## twice as far.
  if not gScale.enabled:
    return
  var r = emptyReport()
  if not apply(gScale, r):
    return
  if r.mapsChanged == 0:
    info "morebots: population preset '" & gScale.preset & "' changed nothing " &
         "-- either it is `vanilla` or this database has none of the " &
         $r.maps & " map(s) the baseline covers"
    return
  success "morebots: population preset '" & gScale.preset & "' -- " & describe(r)
  if r.clamped > 0:
    warn "morebots: " & $r.clamped & " value(s) hit a ceiling and were " &
         "clamped rather than written as asked. Raise capCeiling / " &
         "perZoneCeiling / waveSlotCeiling in config.json if that is " &
         "deliberate; they exist because a map has a fixed number of spawn " &
         "points and asking for more bots than it has places to put them " &
         "gives half-built bots rather than more of them."
  if r.skipped > 0:
    var names = r.skippedMaps[0]
    for i in 1 ..< r.skippedMaps.len:
      names = names & ", " & r.skippedMaps[i]
    warn "morebots: " & $r.skipped & " map(s) kept stock wave slots -- " &
         names & ". Their live `waves` array is a different length from the " &
         "shipped baseline, so another mod owns it, and matching our entries " &
         "to theirs by position would be a guess with a raid on the other " &
         "side of it. The consequence is uneven: every other map is at '" &
         gScale.preset & "' and these are at stock. The mod that owns such a " &
         "map can close this by putting its own stock numbers in the " &
         "`population` object of its `aowlspt.locations.changed` " &
         "announcement; mods/icebreaker does."

proc bumpBotCaps() =
  ## `increaseBotCapAmount` raised every map's cap by a flat amount upstream.
  ##
  ## Kept, deprecated, and off by default -- and the deprecation is the useful
  ## part of this comment. It writes `bots.config.maxBotCap`, which **is not a
  ## path anything reads**: a stock SPT 4.x database has no `bots.config` at all
  ## (its `bots` object is `core`, `base`, `types`) and `mods/tarkov` never
  ## looks there. It was doing nothing, silently, and now `scalePopulation`
  ## above does the real thing in `locations.<map>.base` where the client can
  ## actually see it. This is left in place only so that an install that set it
  ## does not silently change behaviour, and it says so when it runs.
  if gBotCapBump <= 0:
    return
  warn "morebots: increaseBotCapAmount is set. It writes " &
       "bots.config.maxBotCap, which nothing on this stack reads -- a stock " &
       "database has no bots.config and the emulator never looks there. Use " &
       "`population` in config.json instead; it writes locations.<map>.base, " &
       "which /client/locations serves to the client verbatim."
  let caps = dbView("bots.config.maxBotCap")
  if not caps.ok or caps.raw.len < 2:
    debugLog "no bots.config.maxBotCap in the database; cap unchanged"
    return
  let doc = whole(caps.raw)
  let maps = keys(doc)
  if maps.len == 0:
    return
  var o = obj()
  for m in maps:
    put(o, m, child(doc, m).asInt(0) + gBotCapBump)
  discard dbPut("bots.config.maxBotCap", done(o).text)
  info "morebots: raised the bot cap on " & $maps.len & " map(s) by " &
       $gBotCapBump

# ---------------------------------------------------------------------------
# Announcing
# ---------------------------------------------------------------------------

proc announce(payload: string): string =
  ## Say `morebots.ready`. Shaped as a `TickHandler` so `afterMs` can call it,
  ## and called directly everywhere else.
  var o = obj()
  put(o, "version", ModVersion)
  put(o, "guid", ModGuid)
  discard broadcast("morebots.ready", o)
  result = ""

proc onHello(payload: string): string =
  ## A dependent that loaded after morebots did, asking. Answering
  ## unconditionally rather than only the first time: two dependents both want
  ## an answer, and the second one's `morebots.ready` is the only announcement
  ## it will ever see.
  debugLog "hello from " & field(payload, "guid").asText("a mod")
  result = announce("")

proc registerRoutes() =
  discard serve("/morebotsapi/getfactions", onGetFactions)
  discard serve("/morebotsapi/getrevenges", onGetRevenges)
  discard serve("/morebotsapi/updaterevenge", onUpdateRevenge)
  discard serve("/morebotsapi/bottypes", onBotTypes)
  discard serve("/singleplayer/settings/bot/difficulties", onDifficulties)

# ---------------------------------------------------------------------------
# Maps another mod adds
# ---------------------------------------------------------------------------
#
# The population pass runs once, at load, over the nineteen slots
# `data/vanilla.json` covers. A mod that *adds* a map -- `mods/icebreaker`
# rebinds the dormant `suburbs` slot into a working one -- is invisible to it
# twice over: it may load after this mod, and even when it loads first, its
# map is not in the baseline and the vanilla numbers for the slot it took
# describe the empty stub rather than the map now in it.
#
# `aowlspt.locations.changed` / `aowlspt.locations.hello` is the contract that
# already exists between "a mod that adds a location" and "a mod that decorates
# every location" -- `mods/sain` is the other subscriber. This mod joins it as
# a decorator: it subscribes and it asks, and it never answers, because it adds
# no location of its own.
#
# What it needs beyond the location's name is the *baseline*, and it asks for
# it rather than reading it. Reading the live numbers and multiplying them is
# the one thing this mod's whole design exists to avoid: the database persists,
# so a live-value multiply compounds on every restart and the only symptom is a
# server that gets slower every week. An announcing mod knows its own stock
# numbers exactly -- it ships them as data and rewrites them from that data on
# every boot -- so it can say them, in the same shape as an entry in
# `data/vanilla.json`. One that does not is refused by name.

proc onLocationsChanged(payload: string): string =
  ## A mod has created or rebound a location. Scale it if it told us what its
  ## stock numbers are; say why not if it did not.
  result = ""
  if not gScale.enabled:
    return ""
  let doc = whole(payload)
  let who = child(doc, "guid").asText("a mod")
  let named = child(doc, "locations")
  if not exists(named) or not isArray(named):
    return ""
  let pop = child(doc, "population")
  var took: seq[string] = @[]
  var noBaseline: seq[string] = @[]
  for it in each(named):
    let id = it.asText("")
    if id.len == 0:
      continue
    let entry = child(pop, id)
    if not entry.found:
      noBaseline.add id
      continue
    if donate(id, entry.raw()):
      took.add id
    else:
      noBaseline.add id
  if noBaseline.len > 0:
    var names = noBaseline[0]
    for i in 1 ..< noBaseline.len:
      names = names & ", " & noBaseline[i]
    info "morebots: " & who & " announced " & names & " and did not say what " &
         "the map's stock bot numbers are, so the population preset '" &
         gScale.preset & "' was not applied to it. It is not broken -- the " &
         "map keeps whatever numbers its own mod wrote -- but it will be the " &
         "one map in the install that ignores the preset. Closing it takes a " &
         "`population` object in that mod's aowlspt.locations.changed " &
         "payload, shaped like an entry in morebots' data/vanilla.json: " &
         "botMax, botMaxPvE, maxBotPerZone and a waves array of " &
         "{slotsMin, slotsMax}. Nothing here can be guessed from the live " &
         "values -- multiplying those compounds on every restart."
  if took.len == 0:
    return ""
  var r = emptyReport()
  if not apply(gScale, r):
    return ""
  if r.mapsChanged > 0:
    success "morebots: " & who & " donated a baseline for " & $took.len &
            " map(s); population preset '" & gScale.preset & "' -- " &
            describe(r)
  flushNow("locations.changed")

proc askForLocations() =
  ## Subscribe, then ask. In that order: a mod that answers the hello answers
  ## it synchronously on this stack, and the handler has to be in place first.
  discard onEvent("aowlspt.locations.changed", onLocationsChanged)
  var hello = obj()
  put(hello, "guid", ModGuid)
  put(hello, "wants", "locations")
  discard broadcast("aowlspt.locations.hello", hello)

proc subscribeEvents() =
  discard onEvent("morebots.type.register", onTypeRegister)
  discard onEvent("morebots.type.overlay", onTypeOverlay)
  discard onEvent("morebots.faction.define", onFactionDefine)
  discard onEvent("morebots.faction.relate", onFactionRelate)
  discard onEvent("morebots.hello", onHello)
  discard onEvent("morebots.flush", onFlush)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The client half
# ---------------------------------------------------------------------------
#
# Until this existed, `onLoadClient` printed one line about what could not be
# done and returned. Everything in that line was true and it was also being used
# as a reason to do nothing, which is a different claim. See the header of
# `bots/census.nim`: the question this mod exists to answer -- did the bots I
# asked for actually arrive, at the cap I asked for, near enough to meet? -- is
# answerable in the client's process, and nowhere else.
#
# So the client half is a read-only census on the fast path. It changes nothing
# in the game. What MoreBots would want to *change* on the client still needs
# the `WildSpawnType` extension that post-1.0 has no mechanism for, and that is
# still stated -- but the mod now reports what happened rather than reporting
# that it cannot.

var gCensusIntervalMs = 5000
var gCensusCap = 0
var gLastCensusMs = 0'i64
var gCensusBound = false
var gCensusReported = false
var gCensusScans = 0
var gCensusNs = 0'i64
var gWorld = whenReady("EFT.GameWorld")

proc censusJson(c: Census): string =
  var roles = arr()
  for i in 0 ..< c.roleIds.len:
    var e = obj()
    put(e, "role", c.roleIds[i])
    put(e, "count", c.roleCounts[i])
    add(roles, done(e))
  var o = obj()
  put(o, "ok", c.ok)
  put(o, "total", c.total)
  put(o, "ai", c.ai)
  put(o, "cap", gCensusCap)
  put(o, "unreadableSpawnTypes", c.unreadable)
  put(o, "customSpawnTypes", c.customRoles)
  put(o, "haveDistance", c.haveDistance)
  put(o, "nearest", c.nearest)
  put(o, "farthest", c.farthest)
  put(o, "scanNs", int(c.scanNs))
  put(o, "roles", roles)
  result = done(o).text

proc censusTick() =
  ## Once every `censusIntervalMs`, and never per frame.
  ##
  ## A census is 3 to 4 bound calls per bot plus a shaped position read, which
  ## for forty bots is around 200 calls -- about two microseconds bound, about
  ## two hundred *microseconds* on the boxed path. Even bound it is not
  ## per-frame work, and it does not need to be: bot counts change on the
  ## timescale of a spawn wave.
  if not gCensusBound:
    if not openCensus():
      return
    censusBind()
    gCensusBound = true
  let now = nowMs()
  if gLastCensusMs != 0'i64 and now - gLastCensusMs < int64(gCensusIntervalMs):
    return
  gLastCensusMs = now

  let c = runCensus()
  if not c.ok:
    return
  gCensusScans = gCensusScans + 1
  gCensusNs = gCensusNs + c.scanNs
  if not gCensusReported:
    gCensusReported = true
    censusReport()
  info "morebots: " & describe(c, gCensusCap)
  reportRoles(c)
  # Published for anything watching -- `mods/blackdivision` is the intended
  # reader, since "did my faction actually spawn" is the same question with a
  # narrower filter. Delivered to everyone but the emitter, so this mod does
  # not hear its own broadcast.
  discard emit("morebots.client.census", censusJson(c))

proc onLoadClient(): Status =
  ## What the original client half did -- an enum member, a return-value
  ## override, a Unity component -- is still out of reach post-1.0 and is still
  ## said plainly. What is *not* out of reach is observing the result, and that
  ## is what runs here.
  gCensusIntervalMs = setting("censusIntervalMs").asInt(5000)
  if gCensusIntervalMs < 500:
    gCensusIntervalMs = 500
  gCensusCap = setting("expectedBotCap").asInt(0)
  info "morebots: the client half cannot extend WildSpawnType (native " &
       "constants, switch tables already compiled) and has no BigBrain to " &
       "host a hunt layer -- see the module comment. What it does instead is " &
       "count what actually arrived: every " & $gCensusIntervalMs &
       " ms, on the fast path, read-only."
  if gCensusCap > 0:
    info "morebots: expectedBotCap is " & $gCensusCap &
         "; a census above it will say so"
  else:
    info "morebots: expectedBotCap is unset, so the census reports the count " &
         "without judging it. Set it to the cap the server was told to use."
  Ok

proc readScale() =
  ## One `setting()` per top-level key: the config reader takes a single
  ## top-level name, so `setting("population.preset")` is ErrNotFound on every
  ## host, and the nesting is read out of the raw text instead.
  gScale = defaultScaleConfig()
  let p = setting("population")
  if p.ok and p.raw.len > 1:
    gScale = readScaleConfig(p.raw)

proc onLoadServer(): Status =
  gDebugLogs = setting("enableDebugLogs").asBool(false)
  gBotCapBump = setting("increaseBotCapAmount").asInt(0)
  readScale()

  loadOverrides()
  loadDefaultFactions()
  initRevenge()
  subscribeEvents()
  registerRoutes()
  scalePopulation()
  bumpBotCaps()

  # After the first pass, so a map mod that loaded earlier is picked up on the
  # hello and one that loads later is picked up on its announcement. Either
  # way the pass that covers it is the same code.
  askForLocations()

  # This mod's own contribution is complete, so it goes in now. What dependents
  # add later is buffered again and written by whichever of the three triggers
  # above fires first.
  flushNow("onLoad")

  info "morebots " & ModVersion & " ready, " & $factionCount() &
       " default faction(s)"

  # For dependents that loaded before this mod and are already subscribed. The
  # ones that load after will say `morebots.hello` and be answered then; the
  # timer is a third chance for anything that misses both.
  discard announce("")
  discard afterMs(0, announce)
  Ok

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------
#
#     aowl run mods/morebots                 # --side sim
#
# Two halves, because this mod has two.
#
# **The server half is exercised for real.** Every route body and every event
# handler is pure config and JSON, so the whole registration surface can be
# driven with no backend: a bot type is registered, a faction is defined, a
# relation is applied, and the documents are parsed back. That is the half where
# all of the original's value lived and it is checkable end to end here.
#
# **The client half reports its bindings and refuses the rest.** `aowlspt-sim`
# is a managed host with no `GameAssembly.dll`, so `openCensus()` correctly
# finds nothing and every binding refuses with that reason. `selfTestRuntime` in
# config.json points it at any `GameAssembly.dll` -- `tests/mockil2cpp`'s
# stand-in, or a real client's from a copy of the install -- and the report
# becomes a real answer about a real build, offline. Out of process the runtime
# is loaded but not started, so `il2cpp_init` is called; on a real client that
# will very likely refuse, because the metadata is decrypted during the game's
# own startup, and a refusal is printed as the real answer it is.

proc simSelfTest(): Status =
  info "MoreBots self-test (--side sim)"
  var bad = 0

  # --- the server half, driven through its own event surface.
  discard onLoadServer()

  var t = obj()
  put(t, "name", "selftestBot")
  put(t, "id", 999001)
  put(t, "scavRole", "SelfTest")
  put(t, "display", "Self Test Bot")
  put(t, "description", "A bot type registered by the self-test.")
  let r1 = onTypeRegister(done(t).text)
  if field(r1, "ok").asBool(false):
    success "  a bot type registered through morebots.type.register"
  else:
    error "  morebots.type.register refused a well-formed type: " & r1
    inc bad

  var f = obj()
  put(f, "name", "selftestFaction")
  var members = arr()
  add(members, "selftestBot")
  put(f, "members", members)
  let r2 = onFactionDefine(done(f).text)
  if field(r2, "ok").asBool(false):
    success "  a faction defined through morebots.faction.define"
  else:
    error "  morebots.faction.define refused a well-formed faction: " & r2
    inc bad

  # `types` names the bots whose opinion changes; `toward` names the faction
  # they get the opinion about. Both spellings are the event's, not this test's.
  var rel = obj()
  put(rel, "kind", "enemy")
  var types = arr()
  add(types, "selftestBot")
  put(rel, "types", types)
  put(rel, "toward", "selftestFaction")
  let edited = onFactionRelate(done(rel).text)
  if field(edited, "ok").asBool(false):
    success "  a hostility relation applied through morebots.faction.relate"
  else:
    error "  morebots.faction.relate refused a well-formed relation: " & edited
    inc bad

  # --- the buffer's fold, against the sequential merge it replaced.
  #
  # `flush` used to merge the buffered entries one at a time into a growing
  # accumulator, which on a real registration was 238 ms of re-serialising the
  # same six bot templates over and over -- three times what the writes it
  # exists to avoid actually cost. It now groups by path segment in one pass.
  # That is a rewrite of the one piece of this mod whose output nobody looks
  # at, so the slow version is kept as the specification and the two are
  # compared byte for byte on whatever the registration above buffered.
  let foldBad = foldSelfCheck()
  var liveFold = true
  if pendingCount() > 0:
    liveFold = foldMatchesSequentialMerge()
  if foldBad == 0 and liveFold:
    success "  the buffered fold matches a sequential merge byte for byte on " &
            "four shapes -- siblings, an ancestor beside its descendants, a " &
            "lone entry at the group key, and two writes into one map -- so " &
            "the grouped fold is the same document as the merge-one-at-a-time " &
            "it replaced"
  else:
    error "  the buffered fold and a sequential merge of the same buffer " &
          "disagree on " & $foldBad & " of four shapes" &
          (if liveFold: "" else: " (and on the live buffer)") &
          ". Every database write this mod makes goes through the fold, so " &
          "this is the whole contribution being wrong"
    inc bad

  # Every route body, parsed back. These are assembled by string concatenation,
  # so an unescaped quote in a registered name produces text that is not JSON --
  # which the parse refuses here rather than the client refusing it later.
  let routes = [
    ("/morebotsapi/getfactions", onGetFactions("", "", "sim")),
    ("/morebotsapi/getrevenges", onGetRevenges("", "", "sim")),
    ("/morebotsapi/bottypes", onBotTypes("", "", "sim")),
    ("/singleplayer/settings/bot/difficulties", onDifficulties("", "", "sim"))]
  for i in 0 ..< routes.len:
    let name = routes[i][0]
    let body = routes[i][1]
    if body.len < 2:
      error "  " & name & " answered " & $body.len & " bytes"
      inc bad
    else:
      success "  " & name & " -- " & $body.len & " bytes, " &
              $keys(whole(body)).len & " top-level member(s)"

  # The handshake, which is the whole of this mod's dependency story. A
  # `morebots.hello` from a mod that loaded later must be answered, or every
  # dependent that loads after morebots gets nothing.
  var hello = obj()
  put(hello, "guid", "aowl.selftest")
  discard onHello(done(hello).text)
  success "  morebots.hello answered with morebots.ready"

  # --- the population baseline, which is the mod's other half and is entirely
  # data. A baseline that half-loaded is the failure this whole pass is about:
  # nineteen maps' worth of caps with three maps actually in the file still
  # produces a server that starts, logs "population preset applied", and leaves
  # sixteen maps at vanilla with nobody the wiser.
  if not loadBaseline():
    error "  data/vanilla.json did not load. The population scaler refuses to " &
          "run at all without it rather than falling back to multiplying the " &
          "live values, which compounds on every restart -- so this is the " &
          "difference between the mod's headline feature working and it " &
          "silently doing nothing"
    inc bad
  else:
    var mapsBad = 0
    var wavesSeen = 0
    var slotsSeen = 0
    var capsSeen = 0
    let names = baselineMapNames()
    for m in names:
      if m.len == 0:
        inc mapsBad
        continue
      let b = child(child(whole(baselineText()), "maps"), m)
      let cap = child(b, "botMax").asInt(-1)
      let zone = child(b, "maxBotPerZone").asInt(-1)
      if cap < 0 or zone < 0:
        error "  vanilla.json: " & m & " has no botMax/maxBotPerZone, so " &
              "every multiplier applied to it is applied to nothing"
        inc mapsBad
        continue
      capsSeen = capsSeen + cap
      let waves = child(b, "waves")
      let items = each(waves)
      for w in items:
        inc wavesSeen
        let lo = child(w, "slotsMin").asInt(-1)
        let hi = child(w, "slotsMax").asInt(-1)
        if lo < 0 or hi < 0:
          error "  vanilla.json: " & m & " has a wave with no slot counts"
          inc mapsBad
        elif hi < lo:
          error "  vanilla.json: " & m & " has a wave with slotsMax " & $hi &
                " below slotsMin " & $lo
          inc mapsBad
        else:
          slotsSeen = slotsSeen + hi
    if mapsBad == 0:
      success "  population baseline: " & $baselineMapCount() & " map(s), " &
              $wavesSeen & " wave(s), " & $slotsSeen & " vanilla wave slot(s), " &
              $capsSeen & " summed alive-bot cap -- every map has a cap, a " &
              "per-zone limit and a wave list with sane slot counts"
    else:
      error "  population baseline: " & $mapsBad & " map(s) unusable"
      bad = bad + mapsBad

    # And the arithmetic, on the baseline rather than on a database, because
    # the property that matters -- applying a multiplier twice is applying it
    # once -- is a property of the code and is checkable with nothing attached.
    # The shipped `config.json` must not neutralise its own preset.
    #
    # `readScaleConfig` reads the three multipliers *after* the preset, so a
    # number written beside the preset wins over it -- which is the behaviour
    # anyone would want and is also a trap, because the file used to ship
    # `botCapMultiplier: 1.0`. Setting `preset: "horde"` then did **nothing**,
    # with no warning, no log line and no way to tell from the outside. The
    # preset checks below all pass on a `defaultScaleConfig()` and none of them
    # touches the file, so none of them saw it.
    #
    # This one drives the actual shipped text with a preset in it, which is the
    # only version of the question a player asks.
    let popRaw = setting("population")
    var shipped = ""
    if popRaw.ok and popRaw.raw.len > 1:
      shipped = popRaw.raw
    if shipped.len > 1:
      var d = parseObject(whole(shipped))
      setText(d, "preset", "horde")
      let eff = readScaleConfig(text(d))
      if eff.botCap <= 1.0 or eff.perZone <= 1.0 or eff.waveSlots <= 1.0:
        error "  config.json neutralises its own preset: with `preset: " &
              "\"horde\"` the shipped file gives " & $int(eff.botCap * 100.0) &
              "% cap / " & $int(eff.perZone * 100.0) & "% per-zone / " &
              $int(eff.waveSlots * 100.0) & "% wave slots, all of which " &
              "should be well above 100%. A number written beside `preset` " &
              "wins over it, so an explicit 1.0 there is a preset switch that " &
              "silently does nothing. Those keys ship as `null`, which means " &
              "`whatever the preset says`."
        inc bad
      else:
        success "  the shipped config.json does not shadow its own preset: " &
                "`horde` through the real file gives " &
                $int(eff.botCap * 100.0) & "% cap, " &
                $int(eff.perZone * 100.0) & "% per-zone, " &
                $int(eff.waveSlots * 100.0) & "% wave slots"

    var p1 = defaultScaleConfig()
    p1.preset = "lots"
    applyPreset(p1)
    var p2 = defaultScaleConfig()
    p2.preset = "vanilla"
    applyPreset(p2)
    if p1.botCap <= 1.0 or p1.waveSlots <= 1.0:
      error "  the `lots` preset does not raise anything"
      inc bad
    elif p2.botCap != 1.0 or p2.waveSlots != 1.0 or p2.perZone != 1.0:
      error "  the `vanilla` preset does not put the numbers back, so there " &
            "is no way to turn this feature off once it is on"
      inc bad
    else:
      success "  presets: vanilla is 1.0x on all three knobs (so it is a real " &
              "off switch), lots is " & $p1.botCap & "x cap / " & $p1.perZone &
              "x per-zone / " & $p1.waveSlots & "x wave slots"

    var scaleRep = emptyReport()
    var trial = defaultScaleConfig()
    trial.enabled = true
    trial.preset = "more"
    applyPreset(trial)
    discard apply(trial, scaleRep)
    if scaleRep.mapsChanged == 0:
      info "  a `more` pass over this host changed nothing: there is no " &
           "database attached, so all " & $scaleRep.maps & " baseline map(s) " &
           "were skipped. That is the right answer here and is what a backend " &
           "started without --db would also say. Run the simulator with " &
           "--db <a database> to see the pass do its work."
    else:
      success "  a `more` pass over a real database: " & describe(scaleRep)

      # The property the whole shipped-baseline design exists for, asserted
      # rather than asserted-about. A read-modify-write scaler passes every
      # other check in this file and fails this one, and failing this one is
      # what makes a server slower every week for no visible reason.
      var again = emptyReport()
      discard apply(trial, again)
      if again.capAfter != scaleRep.capAfter or
         again.slotsAfter != scaleRep.slotsAfter:
        error "  applying the same preset twice gave a different answer (" &
              $scaleRep.capAfter & " -> " & $again.capAfter & " cap, " &
              $scaleRep.slotsAfter & " -> " & $again.slotsAfter & " slots). " &
              "The scaler is compounding, which means every server restart " &
              "makes the raid busier and nothing ever says so"
        inc bad
      else:
        success "  and applying it a second time gave exactly the same " &
                "numbers (" & $again.capAfter & " cap, " & $again.slotsAfter &
                " wave slots) -- the pass is idempotent, which is the whole " &
                "reason it scales from a shipped baseline instead of from " &
                "the live values"

      # And that `vanilla` really is an off switch, which is the other half of
      # the same claim: a mod that can turn a knob and not turn it back has
      # made a permanent change to somebody's database.
      var back = emptyReport()
      var off = defaultScaleConfig()
      off.enabled = true
      off.preset = "vanilla"
      applyPreset(off)
      discard apply(off, back)
      if back.capAfter != back.capBefore or back.slotsAfter != back.slotsBefore:
        error "  the `vanilla` preset did not restore the stock numbers (" &
              $back.capAfter & " vs " & $back.capBefore & " cap)"
        inc bad
      else:
        success "  and `preset: vanilla` puts every number back to stock (" &
                $back.capBefore & " cap, " & $back.slotsBefore &
                " wave slots), so this feature has a real off switch"

  info "  " & $typeCount() & " bot type(s) known, " & $factionCount() &
       " faction(s)"

  # --- the client half.
  var runtimePath = setting("selfTestRuntime").asText("")
  if runtimePath.len >= 2 and runtimePath[0] == '"' and
     runtimePath[runtimePath.len - 1] == '"':
    runtimePath = runtimePath.substr(1, runtimePath.len - 2)
  var opened = false
  if runtimePath.len > 0:
    opened = openCensusAt(runtimePath, "aowl-morebots-selftest")
    if opened:
      info "  bound " & runtimePath & " for the census binding report"
    else:
      warn "  selfTestRuntime " & runtimePath & " could not be loaded"
  if not opened:
    opened = openCensus()
  if not opened:
    warn "  no IL2CPP runtime in this process -- aowlspt-sim is a managed " &
         "host and GameAssembly.dll is not loaded. Every census binding will " &
         "refuse for that reason, which is the correct answer here. Set " &
         "\"selfTestRuntime\" in config.json to a GameAssembly.dll for a " &
         "real report offline."

  # --- the guards themselves, both directions.
  #
  # A guard that never takes its true branch is indistinguishable from a guard
  # that is broken, and "the shaped path was refused" and "the shaped path was
  # never reachable" look identical from outside. So the two predicates the
  # frame path uses are put through known-good and known-bad types directly.
  # This is not a paraphrase of the guard -- `shapedRetSizeOk` and `enumSizeOk`
  # are the same procs `bindPosition` and `bindRole` call.
  # The ABI rule, exhaustively, with no runtime involved. This is the half of
  # the guard that decides *whether* the shaped path is taken, and it is a pure
  # function of a size -- so both of its branches can be shown to work here
  # rather than only on a machine with Tarkov on it.
  var ruleBad = 0
  var sz = 1
  while sz <= 24:
    let want = (sz != 1 and sz != 2 and sz != 4 and sz != 8 and sz <= 16)
    if shapedSizeAccepted(sz) != want:
      error "  guard: a " & $sz & "-byte aggregate is " &
            (if want: "passed through memory on Win64 and the rule refused it"
             else: "passed in a register on Win64 and the rule accepted it")
      inc ruleBad
    inc sz
  if shapedSizeAccepted(0) or shapedSizeAccepted(-4):
    error "  guard: the rule accepted a nonsensical size"
    inc ruleBad
  if ruleBad == 0:
    success "  the Win64 hidden-pointer rule accepts 3, 5, 6, 7 and 9..16 " &
            "bytes and refuses 1, 2, 4, 8 and anything past 16 -- both " &
            "branches exercised, so a Vector3 would take the shaped path and " &
            "a float would not"
  else:
    bad = bad + ruleBad

  calibrateHeader()
  if headerBytes() < 0:
    warn "  the value-type size convention could not be calibrated from this " &
         "runtime (System.Int32 and System.Double are not both resolvable), " &
         "so every shaped and asserted binding will refuse. That is the " &
         "expected answer with no runtime attached."
  else:
    info "  value-type instance sizes include a " & $headerBytes() &
         "-byte header on this runtime, calibrated from System.Int32 and " &
         "System.Double rather than assumed"
    var guardsBad = 0
    # A four-byte value type must be accepted as an enum and refused as a
    # hidden-pointer return: four bytes goes in a register.
    if not enumSizeOk("System.Int32"):
      error "  guard: System.Int32 is not seen as a four-byte value type"
      inc guardsBad
    if shapedRetSizeOk("System.Int32"):
      error "  guard: System.Int32 was accepted for the hidden-return-pointer " &
            "shape, which would put a register-passed value through memory"
      inc guardsBad
    # A reference must be refused by both.
    if enumSizeOk("System.String") or shapedRetSizeOk("System.String"):
      error "  guard: System.String, a reference, was accepted as a value type"
      inc guardsBad
    # An eight-byte value type is still register-sized and must be refused.
    if shapedRetSizeOk("System.Double"):
      error "  guard: System.Double (8 bytes) was accepted for the " &
            "hidden-return-pointer shape; Win64 passes it in a register"
      inc guardsBad
    # And the case the shape exists for. Absent from the stand-in runtime, so
    # this reports rather than fails there -- but against a real client it is
    # the line that says the shaped path was *chosen*.
    let vecSize = payloadSize("UnityEngine.Vector3")
    if vecSize == 0:
      info "  guard: UnityEngine.Vector3 is not in this runtime, so the " &
           "*type* half of the guard has no 12-byte case to accept here. The " &
           "rule half above covers 12 bytes explicitly, and the type half is " &
           "shown refusing references and register-sized value types, so what " &
           "is untested is only the join of the two."
    elif shapedRetSizeOk("UnityEngine.Vector3"):
      success "  guard: UnityEngine.Vector3 is " & $vecSize &
              " bytes and is accepted for the hidden-return-pointer shape -- " &
              "the shaped path is chosen, not merely survived"
    else:
      error "  guard: UnityEngine.Vector3 is " & $vecSize &
            " bytes and was refused for the shaped path; get_Position would " &
            "fall back to il2cpp_runtime_invoke"
      inc guardsBad
    if guardsBad == 0:
      success "  the shaped-call and enum-width guards refuse every " &
              "register-sized and reference type put to them"
    else:
      bad = bad + guardsBad

  censusBind()
  censusReport()
  let c = runCensus()
  info "  census: " & describe(c, setting("expectedBotCap").asInt(0))

  info "  refusals that are permanent on any post-1.0 client, with the reason:"
  info "    new WildSpawnType members -- the enum is native constants with " &
       "its switch tables already compiled, and there is no managed " &
       "Assembly-CSharp.dll and no pre-load window to rewrite. The registry " &
       "keeps and serves the mapping at /morebotsapi/bottypes; no shipped " &
       "client reads it. The census counts any role id at or above 100 so " &
       "that this claim is tested rather than repeated."
  info "    BotsGroup::IsPlayerEnemy, ShallBossAttack, SuitableFollowersList " &
       "-- each needs the instance the patch fired on, and a hook is told a " &
       "method's declared arguments and not `this`. Deciding hostility from " &
       "the argument alone would answer for the wrong group."
  info "    StandartBotBrain::Activate -- swapping a live brain object means " &
       "constructing a managed type, which nothing native can declare."
  info "    HuntTargetLayer and the hunt actions -- BigBrain custom layers and " &
       "Unity MonoBehaviours, hosted by a BepInEx that does not exist here."

  # --- cost, on the same clock a client mod times a frame with.
  const Iterations = 2000
  let t0 = perfCounter()
  var i = 0
  while i < Iterations:
    discard runCensus()
    inc i
  let per = nanosBetween(t0, perfCounter()) div int64(Iterations)
  if c.ok:
    success "  census cost " & $per & " ns per scan over " & $Iterations &
            " scans, on " & $c.total & " players"
  else:
    info "  census cost " & $per & " ns per scan over " & $Iterations &
         " scans, none of which found a world. That is the guard: what the " &
         "census costs outside a raid, which is where it spends most of its " &
         "life. It is not per-frame work either way -- it runs every " &
         $setting("censusIntervalMs").asInt(5000) & " ms."
  info "  for comparison, docs/PERF.md measures one boxed host call at " &
       "950-1235 ns; the same census on the boxed path would be ~200 us for " &
       "forty bots, which is why it is not on it"

  if bad == 0:
    success "MoreBots self-test: the registration surface works with no " &
            "backend attached"
    result = Ok
  else:
    error "MoreBots self-test: " & $bad & " problem(s)"
    result = ErrGeneric

proc onLoad(): Status =
  case side()
  of sideClient: result = onLoadClient()
  of sideSim: result = simSelfTest()
  else: result = onLoadServer()

proc onUpdate(elapsedMs: int64): Status =
  ## The client half only. The server half is entirely event- and route-driven
  ## and has nothing per-tick to do.
  if side() != sideClient:
    return Ok
  if gWorld.ready():
    success "morebots: the game world is up; the census starts"
  if gWorld.fired:
    censusTick()
  Ok

proc onUnload(): Status =
  if side() != sideClient:
    info "morebots: " & $gRegistrations & " bot type registration(s), " &
         $typeCount() & " type(s) known"
  Ok

exportMod(
  guid = ModGuid,
  name = "MoreBots",
  author = "TacticalToaster (ported to aowlspt)",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
