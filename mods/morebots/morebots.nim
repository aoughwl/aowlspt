## The bot population and bot-type/faction API half of Bot AI.
##
## User-visible everywhere as **Bot AI** (its rows render under
## `Bot AI > Population`). The guid `aowl.morebots`, this path, the dll name
## and the /morebotsapi/* routes are INTERNAL identifiers and are deliberately
## unchanged -- the registry, the selection store and deploy verification all
## key off them.
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
## **Most of the Harmony patches are gone, and one of them is not.** There were
## nine. This comment has now been wrong about them twice and both corrections
## are recorded rather than quietly made, because a refusal nobody re-checks is
## how a mod loses features for years.
##
## The first wrong version said `hookArgs` could not read a method's declared
## arguments and `stopWith` could not override a return value. Both can.
##
## The second wrong version said **a hook is not told which instance it fired
## on**, and rested eight of the nine refusals on it. That is false, and was
## false when it was written: the payload is
## `{"this":{"handle":n,"type":"..."},"args":[...]}` — Harmony's `__instance`,
## kept out of the argument array on purpose — and `thisHandle`/`thisPointer`
## read it. `mods/classicmovement` has been calling `thisPointer(args)` in
## shipped code since ABI revision 3. `bots/instance.nim` now states in code,
## and asserts in the self-test, exactly what the payload carries about the
## receiver and exactly what it does not.
##
## What the nine actually need, one by one:
##
##   * `BaseStatisticsManager::OnDeath` — **ported**, read-only, as the death
##     ledger in `bots/deaths.nim`. It never needed `this` to be *the dead
##     player*; it needed to be told about each death at all, which closes the
##     census's one blind spot: a bot that spawns and dies between two scans.
##   * `BotsGroup::IsPlayerEnemy` and `BotGroupWarnData::ShallBossAttack` —
##     expressible. `this` is the group, the player is a reference argument,
##     and `stopWith` overrides the bool. They are not here for a different
##     reason: deciding *which* group this is means reading a member off it,
##     every candidate name is a pre-1.0 guess, and hostility already works on
##     the server through `ENEMY_BOT_TYPES`, which is a mechanism that has been
##     tested. An override that is quietly wrong about which group it fired for
##     is worse than the server-side graph that is right about all of them.
##   * `SuitableFollowersList` — the list is an *argument*, not the receiver,
##     so `this` was never what stood in the way. `bindOnObject` can call
##     `Add`/`Remove` on a generic collection `findClass` cannot even name.
##     What is missing is the filter rule: nothing in this tree records what
##     upstream's version actually did, and inventing one is not a port.
##   * `StandartBotBrain::Activate` — **genuinely impossible, and `this` is
##     irrelevant to it.** Swapping a brain means supplying a *new managed
##     type* with overridden virtuals. IL2CPP has no runtime type definition;
##     `il2cpp_object_new` instantiates a class that already exists and is not
##     exposed to a mod in any case. Nothing native can declare a C# class.
##   * `TarkovApplication::Init` and `BotsController::Init` — always
##     expressible, with the plain `hook` that costs a name comparison. They
##     existed solely to construct the managers below, so they have nothing
##     left to do.
##
## That is seven. **The remaining two are not named anywhere in this tree**,
## and this comment will not invent them: the count of nine came from
## upstream's plugin and only seven of the nine were ever written down here.
## Anyone re-auditing this row should know that two of it cannot be audited.
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
import aowlspt/settings # the F12 settings schema this mod declares
import aowlspt/json
import bots/spawntypes
import bots/dbpath
import bots/registry
import bots/factions
import bots/revenge
import bots/spawnscale
import bots/census
import bots/instance
import bots/deaths
import bots/gate       # the two gates that replaced `whenReady` -- read it first
import aowlspt/game    # `whenReady` -- now only "the IL2CPP runtime is up"
import aowlspt/fast    # `perfCounter` -- the clock the census reports on
import aowlspt/fixture # where a self-test's runtime path may come from

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

# ---------------------------------------------------------------------------
# The F12 settings schema
# ---------------------------------------------------------------------------
#
# The flat top-level scalar keys this mod reads through `setting()`. The
# `population` object is the headline feature but is a nested document read
# whole out of its raw text, not a scalar control, so it is not declared here.
# `increaseBotCapAmount` is read but writes to a database path nothing on this
# stack reads, so it is declared implemented = false with that reason.

proc moreBotsSchema(): seq[Setting] =
  result = @[
    boolSetting("population.enabled", "Raise bot counts", false,
                category = "Population", subcategory = "Spawns",
                description = "Raise how many AI a map runs. Writes BotMax, BotMaxPvE, MaxBotPerZone and every scav wave's slot counts into the served database, computed from a stock baseline so it never compounds. Off means the stock numbers. Applied when the server starts, so restart the backend after changing it.",
                implemented = true),
    enumSetting("population.preset", "Population preset", "vanilla",
                @["vanilla", "more", "lots", "horde", "custom"],
                category = "Population", subcategory = "Spawns",
                description = "vanilla puts every number back to stock (that is how you undo this, since the database keeps the last run's numbers). more is 1.35x cap and waves, 1.5x per zone; lots is 1.75x/2x; horde is 2.5x/3x and is past the point where anything is balanced. custom means the three multipliers in config.json, which ship unset and therefore change nothing on their own.",
                implemented = true),
    intSetting("population.capFloor", "Cap floor", 4, lo = 1, hi = 60,
               category = "Population", subcategory = "Limits",
               description = "No map's alive-AI cap is written below this, whatever the preset works out to.",
               implemented = true),
    intSetting("population.capCeiling", "Cap ceiling", 60, lo = 4, hi = 200,
               category = "Population", subcategory = "Limits",
               description = "No map's alive-AI cap is written above this. A map has a fixed number of spawn points; asking for more bots than it has places to put them gives stuttering rather than more bots. A clamp is logged, not silent.",
               implemented = true),
    intSetting("population.perZoneCeiling", "Per-zone ceiling", 12, lo = 1, hi = 40,
               category = "Population", subcategory = "Limits",
               description = "The largest MaxBotPerZone any map may be given. The spawner will not put a fifth bot in a zone that allows four, so this is what decides whether a raised cap is ever used. Lighthouse ships at 8, the highest any stock map uses.",
               implemented = true),
    intSetting("population.waveSlotCeiling", "Wave slot ceiling", 12, lo = 1, hi = 40,
               category = "Population", subcategory = "Limits",
               description = "The largest slots_max any single scav wave may reach. A wave asking for more bots at once than the zone can place is a wave that arrives partly.",
               implemented = true),
    # `increaseBotCapAmount` was REMOVED from the settings UI (2026-08-28).
    #
    # Its own description said "deprecated and does nothing", which is exactly
    # the control that should not be drawn: a slider with a range of 0..50 that
    # the player can move and that cannot affect the game is worse than its
    # absence, because moving it looks like an action. `bots.config.maxBotCap`
    # is not a path anything on this stack reads -- a stock SPT 4.x database
    # has no `bots.config` at all.
    #
    # The KEY stays in config.json and `bumpBotCaps` still reads it and still
    # warns. That is deliberate: an install that set it years ago must keep
    # getting the line telling it to use `population` instead, and deleting
    # the key would take the warning away along with the row. What is gone is
    # only the affordance to set it anew.
    boolSetting("clientCensus", "Count the bots that arrived", false,
                category = "Advanced", subcategory = "Population diagnostics",
                description = "The in-client half, off by default: it opens the IL2CPP runtime in the game process to count live bots. Raising bot counts is the server half and needs none of this.",
                implemented = true),
    boolSetting("deferUntilUnityThread", "Defer until the Unity thread is live", true,
                category = "Advanced", subcategory = "Population diagnostics",
                description = "Hold all in-client arming until the host confirms its main-thread drain has fired. Turning this off reproduces a crash. Leave it on.",
                implemented = true),
    boolSetting("deathLedger", "Death ledger", false,
                category = "Advanced", subcategory = "Population diagnostics",
                description = "Installs a BY-NAME detour on EFT.BaseStatisticsManager::OnDeath -- a write into game code against a pre-1.0 name. Not needed for bot counts.",
                implemented = true),
    intSetting("censusIntervalMs", "Count interval (ms)", 5000,
               lo = 500, hi = 60000, step = 500,
               category = "Advanced", subcategory = "Population diagnostics",
               description = "How often the count runs; read-only, floored at 500.",
               implemented = true),
    intSetting("expectedBotCap", "Expected bot cap", 0, lo = 0, hi = 200,
               category = "Advanced", subcategory = "Population diagnostics",
               description = "The alive-bot cap the count compares against; 0 reports the number without judging it.",
               implemented = true),
    boolSetting("enableDebugLogs", "Verbose population log", false,
                category = "Advanced", subcategory = "Population diagnostics",
                description = "One line per bot-type registration, overlay and relation.",
                implemented = true)]

proc onMoreBotsSettings(url, body, session: string): string =
  ## GET serves the schema; a POST body persists one edit into config.json. The
  ## value is read fresh at the next load — this mod reads its settings inline
  ## rather than through a single reloadable config, so the write is saved but
  ## not made live here.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
  result = declaredSchemaReply(st).text

proc onMoreBotsSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  result = declaredSchemaReply(st).text

proc registerRoutes() =
  # inIndex = false: these rows are shown INSIDE the Bot AI page tree
  # (mods/sain proxies them under Bot AI > Population), so this mod must not
  # also claim a second top-level entry in the F12 nav.
  declareSettings(moreBotsSchema(), inIndex = false)
  discard serve("/aowlspt/settings/" & ModGuid, onMoreBotsSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onMoreBotsSettingsReset)
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
  ## KEPT, RENAMED IN MEANING. This is the cheap "the IL2CPP runtime is up"
  ## probe it always really was -- it goes true ~47 ms after HOST RUNNING with
  ## no raid anywhere. It is no longer a gate on anything. `bots/gate.nim` has
  ## the mechanism and the measurement.

# --- the client half's flags, all default OFF (CLAUDE.md 5) ----------------
var cfgClientCensus = false
  ## The whole client half. OFF by default: this mod was quarantined as
  ## `morebots.dll.off` for killing the client, and a fix that has never been
  ## run in a raid does not get to ship enabled.
var cfgDeferUntilUnityThread = true
  ## Hold ALL arming until the host says its main-thread drain has fired. The
  ## unsafe direction is the one that crashed, so this defaults ON and turning
  ## it off is how you reproduce the crash deliberately.
var cfgDeathLedger = false
  ## `armDeaths` installs a **by-name host detour** -- a write into game code
  ## against `EFT.BaseStatisticsManager::OnDeath`, a pre-1.0 C# name. Facts
  ## #143-145: by-name is fatal the moment it is USED, and `mods/fov` refuses
  ## by-name detours in the client outright. OFF, and separately named, so
  ## that turning the census on does not silently turn a code patch on.

const
  GatePollMs = 500'i64
    ## Asking the host every frame is a round trip per frame for an answer that
    ## changes at most once.
  GateGiveUpMs = 180_000'i64
    ## Then refuse, permanently, rather than arm anyway. A surviving FOV run
    ## confirmed the drain at 14.469 s; three minutes is not a tight bound, it
    ## is the point at which "it is coming" stops being credible.
  MaxCensusFaults = 5
    ## Consecutive failed scans after which the client half switches itself off
    ## for the rest of the run.

var gGatePassed = false
var gGateMs = 0'i64
var gGatePollMs = 0'i64
var gGateSaid = false
var gClientOff = false
var gClientState = "not started"
var gCensusFaults = 0
var gWorldSaid = false

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
    # The death ledger goes up with the census and on the same runtime, because
    # the two answer halves of one question: the census is the population and
    # the ledger is the turnover, and a raid can be steady in one while the
    # other is churning.
    #
    # It is now gated on its OWN flag, default off. `armDeaths` ends in
    # `hookArgs`, which asks the host to detour a method BY NAME, and that is a
    # write into game code -- the route facts #143-145 make fatal and the one
    # `mods/fov` refuses outright on the client. This mod's census is read-only
    # and the ledger is not; they should not share a switch.
    if cfgDeathLedger:
      warn "morebots: deathLedger is ON -- this installs a BY-NAME host " &
           "detour on " & DeathTarget & ", a write into game code against a " &
           "pre-1.0 name. It is not part of the census and is not needed for " &
           "bot counts."
      discard armDeaths(censusRuntime(), censusLive())
      info "morebots: death ledger -- " & deathState()
    else:
      info "morebots: death ledger OFF (deathLedger=false). It would patch " &
           "game code by name; the census below is read-only and does not " &
           "need it. Turnover between two scans is the cost."
    gCensusBound = true
  let now = nowMs()
  if gLastCensusMs != 0'i64 and now - gLastCensusMs < int64(gCensusIntervalMs):
    return
  gLastCensusMs = now

  let c = runCensus()
  if not c.ok:
    # Self-disable after N faults, rather than fault every interval forever.
    # Counted CONSECUTIVELY and reset on the next good scan below, so a single
    # bad frame during a map load does not spend the budget.
    gCensusFaults = gCensusFaults + 1
    if gCensusFaults >= MaxCensusFaults:
      gClientOff = true
      gClientState = "refused: " & $MaxCensusFaults & " consecutive scans " &
                     "failed, so the client half switched itself OFF for the " &
                     "rest of the run"
      warn "morebots: " & gClientState
    return
  gCensusFaults = 0
  gCensusScans = gCensusScans + 1
  gCensusNs = gCensusNs + c.scanNs
  if not gCensusReported:
    gCensusReported = true
    censusReport()
  info "morebots: " & describe(c, gCensusCap)
  reportRoles(c)
  if deathFirings() > 0:
    info "morebots: turnover -- " & describeDeaths() & ". The census above is " &
         "who is alive now; this is who has died since the raid began, and a " &
         "raid can be flat in the first while churning in the second."
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
  cfgClientCensus = setting("clientCensus").asBool(false)
  cfgDeferUntilUnityThread = setting("deferUntilUnityThread").asBool(true)
  cfgDeathLedger = setting("deathLedger").asBool(false)
  if not cfgClientCensus:
    gClientOff = true
    gClientState = "off: clientCensus=false. Nothing in this process is " &
                   "opened, bound, walked or patched. The server half -- " &
                   "which is what raises bot counts -- is unaffected."
    info "morebots: " & gClientState
    return Ok
  info "morebots: client census ON, deferUntilUnityThread=" &
       $cfgDeferUntilUnityThread & ", deathLedger=" & $cfgDeathLedger
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
  info "Bot AI population self-test (--side sim)"
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
  #
  # THE ONE PLACE `findClass` IS PERMITTED, and only because this is not the
  # client. `census.nim`'s value-type size calibration resolves `System.Int32`
  # and `System.Double` BY NAME, and `il2cpp_class_from_name` is token-gated on
  # the real build: on mismatch it answers a uniform random NON-ZERO uint64, so
  # the nil check below it cannot fire and `classInstanceSize` dereferences a
  # random address (fact #198). The census itself no longer needs any of it --
  # it reads fields -- so the calibration is default-OFF and opted into HERE,
  # in `aowlspt-sim`, against a stand-in or offline-loaded runtime with no live
  # client to kill.
  #
  # AND IT IS STILL NOT TURNED ON, BECAUSE IT WAS MEASURED.
  #
  # This line was `censusAllowReflection(true)` for exactly one run. With the
  # gate open, `aowlspt-sim mods\morebots --side sim` against
  # `D:\Games\Tarkov\GameAssembly.dll` printed the Win64-rule line, entered
  # `calibrateHeader()`, and the PROCESS DIED -- exit 5, no further output, no
  # diagnostic, the very next log line never reached. That is
  # `findClass("System.Int32")` -> `classInstanceSize`, with no game running
  # and no client to blame, and it is the clearest reproduction of fact #198
  # this repo has outside the client: the nil check passes and the dereference
  # is fatal.
  #
  # So the gate stays SHUT even here, `headerBytes()` stays -1, and the size
  # guards below report INCONCLUSIVE rather than a number. An honest "I could
  # not look" beats a self-test that has to survive a crash to pass.
  let wanted = selfTestRuntime(setting("selfTestRuntime").asText(""))
  if wanted.refusal.len > 0:
    warn "  " & wanted.refusal
  let runtimePath = wanted.path
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
         "AOWLSPT_SELFTEST_RUNTIME, or \"selfTestRuntime\" in config.json, " &
         "to an ABSOLUTE path to a GameAssembly.dll for a real report offline."

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

  # --- THE NEGATIVE CONTROL FOR THE PROLOGUE GUARD.
  #
  # `censusReport()` above prints "prologue verified 16/16" for
  # `EFT.Player::get_IsAI`. On its own that line proves nothing, because a
  # comparator that returned true unconditionally would print it too -- and a
  # check that cannot fail IS the bug (CLAUDE.md 9b). So the SAME binder is put
  # to the SAME known-good address with ONE BYTE of the expected prologue
  # changed, and is required to REFUSE.
  #
  # The byte changed is the first, `40` -> `41`. If the guard is real the bind
  # fails and its `why` names the mismatch; if it is theatre, this succeeds and
  # says so. Three outcomes, not two: with no GameAssembly.dll bound the binder
  # refuses for a DIFFERENT reason (no imagebase), and that is INCONCLUSIVE
  # rather than a pass, so it is reported as such.
  const GoodPro = "40 53 48 83 EC 20 80 3D AA 18 99 06 00 48 8B D9"
  const BadPro  = "41 53 48 83 EC 20 80 3D AA 18 99 06 00 48 8B D9"
  var noKinds: seq[FastKind] = @[]
  if not censusLive():
    warn "  prologue guard: INCONCLUSIVE -- no GameAssembly.dll is bound in " &
         "this process, so neither the positive nor the negative case was " &
         "actually executed. Set AOWLSPT_SELFTEST_RUNTIME to an absolute " &
         "path to a GameAssembly.dll to run it. 'I could not look' is not a " &
         "pass."
  else:
    let proGood = bindAtRva("negctl(good) EFT.Player::get_IsAI", 0x726890,
                            GoodPro, noKinds, fkBool, false)
    let proBad = bindAtRva("negctl(one byte wrong) EFT.Player::get_IsAI",
                           0x726890, BadPro, noKinds, fkBool, false)
    if proGood.ok and not proBad.ok:
      success "  prologue guard: the correct 16 bytes VERIFY and a " &
              "one-byte-wrong copy of them at the SAME address is REFUSED. " &
              "Both branches executed, so the comparator is real."
      info "    refusal: " & proBad.why
    elif proBad.ok:
      error "  prologue guard: a DELIBERATELY WRONG prologue was ACCEPTED at " &
            "0x726890. The 'verified 16/16' line is theatre and every RVA " &
            "call in this mod is unguarded."
      bad = bad + 1
    else:
      warn "  prologue guard: INCONCLUSIVE -- the wrong prologue was refused " &
           "but so was the CORRECT one (" & proGood.why & "), so the refusal " &
           "is not evidence that the comparator discriminates."

  # --- what a hook is told about the instance it fired on.
  #
  # Eight of this mod's nine Harmony refusals were written against the claim
  # that a hook is not told which instance it fired on. The claim was false.
  # These assertions exist so that it cannot quietly become true again, and so
  # that the *replacement* claims -- which are narrower and are the whole value
  # of the correction -- are checked rather than asserted in a comment.
  #
  # Every payload below is the host's own shape, copied from `describeArgs` in
  # host/Aowlspt.Host.Il2Cpp/invoke.nim. Nothing here needs a game, a runtime
  # or a hook: the decision is a function of a string, which is exactly why it
  # was moved into `bots/instance.nim` instead of being written inline in a
  # handler where it could only ever be tested by playing a raid.
  var instBad = 0
  const PayInst = "{\"this\":{\"handle\":3,\"type\":\"EFT.BotsGroup\"}," &
                  "\"args\":[{\"handle\":4,\"type\":\"EFT.Player\"},2.5]}"
  const PayStatic = "{\"this\":null,\"args\":[]}"
  const PayNotHook = "{\"result\":6.0}"

  let inst = instanceOf(PayInst)
  if not inst.said or inst.isStatic or inst.handle != 3'u64 or
     inst.typeName != "EFT.BotsGroup":
    error "  instance: the receiver was not read out of a hook payload -- " &
          "said=" & $inst.said & " static=" & $inst.isStatic &
          " type=`" & inst.typeName & "`. This is the exact claim eight " &
          "refusals in this file rested on, so it is checked and not assumed"
    inc instBad

  # The distinction that a `said`/`isStatic` pair exists for. An implementation
  # that folded them into one bool passes every check above and fails here, and
  # the difference matters: "the method is static" is an answer and "this is
  # not a hook payload" is a bug in the caller.
  let st = instanceOf(PayStatic)
  let nh = instanceOf(PayNotHook)
  if not (st.said and st.isStatic and st.handle == 0'u64):
    error "  instance: `\"this\":null` did not read as a static method"
    inc instBad
  if nh.said:
    error "  instance: a payload with no `this` member at all read as one " &
          "that had one; `null` and absent are being conflated"
    inc instBad

  # The concrete class is an exact match and not a prefix. `EFT.BotsGroup` and
  # `EFT.BotsGroupClass` are two classes and a startsWith test conflates them.
  if not isInstanceOf(PayInst, "EFT.BotsGroup") or
     isInstanceOf(PayInst, "EFT.BotsGroupClass") or
     isInstanceOf(PayInst, "BotsGroup") or
     isInstanceOf(PayStatic, "EFT.BotsGroup"):
    error "  instance: the receiver-class test is not an exact match"
    inc instBad

  # THE ONE THAT MATTERS. `this` takes register position 0 on an instance
  # method, so the fourth declared parameter of one is on the stack and is
  # OMITTED from the payload rather than reported as missing. A hook that read
  # argument 3 of such a method would get "" and, treating "" as a default,
  # would decide on a value the game never supplied -- silently, and only on
  # methods with four parameters, which is why it would survive every test
  # anyone wrote. An implementation that forgot the instance shift answers 0
  # here for all three cases and this check is the whole of the difference.
  if argsReportable(4, false) != 3 or argsTruncated(4, false) != 1:
    error "  instance: a 4-argument INSTANCE method should report 3 and drop " &
          "1; it says " & $argsReportable(4, false) & " and " &
          $argsTruncated(4, false) & ". `this` occupies register position 0"
    inc instBad
  if argsReportable(4, true) != 4 or argsTruncated(4, true) != 0:
    error "  instance: a 4-argument STATIC method should report all 4; it " &
          "says " & $argsReportable(4, true)
    inc instBad
  if argsTruncated(3, false) != 0 or argsTruncated(0, false) != 0 or
     argsTruncated(9, false) != 6:
    error "  instance: the truncation arithmetic is wrong at the edges"
    inc instBad

  # The arguments that are present but unreadable are NAMED, not invented. Both
  # placeholders the host can emit are exercised, and so is the case they are
  # most easily confused with -- a handle object, which also carries a `type`.
  if argsReported(PayInst) != 2 or argHandle(PayInst, 0) != 4'u64:
    error "  instance: a reference argument's handle was not read"
    inc instBad
  if argRefusal(argAt(PayInst, 0)).len != 0:
    error "  instance: a live handle was mistaken for a refused placeholder " &
          "-- `{\"handle\":n,\"type\":...}` carries a `type` too"
    inc instBad
  if argRefusal("{\"valueType\":\"UnityEngine.Vector3\"}").len == 0 or
     argRefusal("{\"type\":\"Something\"}").len == 0:
    error "  instance: an unreadable argument was not refused by name"
    inc instBad
  if argHandle(PayInst, 7) != 0'u64 or argsReported(PayStatic) != 0:
    error "  instance: an out-of-range or empty argument list misread"
    inc instBad

  # AND THE AMBIGUITY THAT IS THE WHOLE DEFECT. An argument the host never
  # reported must not read the same as one that is fine. `argRefusal("")` used
  # to answer "" -- "nothing wrong with this value" -- for a value that does
  # not exist, which is precisely how a hook ends up deciding on something the
  # game never supplied. Four positions on one hypothetical 5-argument instance
  # method, and all four have to answer differently:
  #
  #   0  reported and readable            -> ""
  #   3  declared, past the register window, ABSENT
  #   4  the same, and the last one
  #   9  not declared at all              -> an off-by-one, not an absence
  if argRefusal("").len == 0:
    error "  instance: an absent argument reported as readable. `\"\"` and " &
          "`a value that is fine` are the same answer, which is the exact " &
          "ambiguity this file exists to remove"
    inc instBad
  if argStatus(PayInst, 0, 5, false).len != 0:
    error "  instance: a readable argument was refused (" &
          argStatus(PayInst, 0, 5, false) & ")"
    inc instBad
  let st3 = argStatus(PayInst, 3, 5, false)
  let st9 = argStatus(PayInst, 9, 5, false)
  if st3.len == 0 or find(st3, "NOT REPORTED") < 0:
    error "  instance: declared parameter 3 of a 5-argument instance method " &
          "is on the stack and absent from the payload; argStatus said `" &
          st3 & "`"
    inc instBad
  if st9.len == 0 or find(st9, "no declared parameter") < 0:
    error "  instance: reading past the signature is an off-by-one and must " &
          "not be reported as a stack argument; argStatus said `" & st9 & "`"
    inc instBad
  if st3 == st9:
    error "  instance: `the host did not report it` and `there is no such " &
          "parameter` gave the same sentence. They are different bugs"
    inc instBad
  # A static method has room for all four, so position 3 there is a payload
  # that disagrees with its signature -- a third distinct answer again.
  let stS = argStatus(PayStatic, 3, 5, true)
  if stS.len == 0 or find(stS, "NOT REPORTED") >= 0:
    error "  instance: on a STATIC method position 3 fits the register " &
          "window, so an empty slot there is a payload/signature mismatch " &
          "and not a stack argument; argStatus said `" & stS & "`"
    inc instBad

  # And the same parameter as the host reports it *today*. The slot used to be
  # omitted -- that is every check above -- and is now named, so this file has
  # to read both: an old host drops it, a current one marks it, and a mod that
  # only understood one of the two would be wrong on half the hosts it runs on.
  #
  # The marker carries `type` and no `handle` on purpose, so a reader that has
  # never heard of `onStack` falls through to the unnamed-class refusal and
  # refuses rather than passing. That is asserted here rather than assumed,
  # because "it fails closed" is exactly the kind of claim that is true when
  # written and quietly stops being.
  let onStackArg = "{\"onStack\":true,\"type\":\"System.Single\"}"
  let osR = argRefusal(onStackArg)
  if osR.len == 0:
    error "  instance: a stack-argument marker was reported as readable. " &
          "The host names that slot precisely so it cannot be read as a value"
    inc instBad
  elif find(osR, "on the stack") < 0:
    error "  instance: a stack-argument marker was refused for the wrong " &
          "reason, which is worse than refusing it for none -- it tells the " &
          "reader to go looking for a runtime that would not name a class. " &
          "argRefusal said `" & osR & "`"
    inc instBad
  if find(osR, "System.Single") < 0:
    error "  instance: the refusal did not name the parameter's type, which " &
          "is the one thing the host knew and the reader cannot recover"
    inc instBad

  if instBad == 0:
    success "  instance: a hook IS told which object it fired on -- handle, " &
            "concrete runtime class, and static-vs-absent kept apart. An " &
            "instance method's 4th declared argument is never read as a " &
            "value -- omitted by an older host, named `onStack` by a current " &
            "one, and refused by its own type either way -- and `not " &
            "reported`, `no such parameter` and `payload disagrees with the " &
            "signature` are three distinct answers rather than one silence"
  else:
    bad = bad + instBad

  # --- the death ledger, driven rather than described.
  #
  # The failure species this project keeps producing is a check that passes
  # because the thing it checks never happened. So the ledger is reset, driven
  # with a known number of payloads, and asserted on the exact counts -- and
  # every counter it moves is monotone, so an unchanged one means the drive did
  # nothing and cannot be confused with a count that went up and came back.
  var ledBad = 0
  resetLedger()
  if deathFirings() != 0 or deathClasses() != 0:
    error "  deaths: the ledger did not start empty"
    inc ledBad
  noteDeath(PayInst)
  noteDeath(PayInst)
  noteDeath("{\"this\":{\"handle\":9,\"type\":\"EFT.Player\"},\"args\":[]}")
  noteDeath(PayStatic)
  noteDeath(PayNotHook)
  if deathFirings() != 5:
    error "  deaths: five payloads were fed in and the ledger counted " &
          $deathFirings() & ". The drive did not happen"
    inc ledBad
  if deathClasses() != 2 or deathsOf("EFT.BotsGroup") != 2 or
     deathsOf("EFT.Player") != 1:
    error "  deaths: deaths were not grouped by the receiver's concrete " &
          "class (" & $deathClasses() & " class(es), BotsGroup " &
          $deathsOf("EFT.BotsGroup") & ", Player " & $deathsOf("EFT.Player") &
          ")"
    inc ledBad
  if deathsWithoutInstance() != 2:
    error "  deaths: a static firing and a non-hook payload should both be " &
          "counted as carrying no receiver; " & $deathsWithoutInstance() &
          " was"
    inc ledBad
  if deathsOf("EFT.NeverSeen") != 0:
    error "  deaths: a class that was never seen reported a count"
    inc ledBad
  if ledBad == 0:
    success "  deaths: " & describeDeaths() & " -- grouped by concrete " &
            "receiver class, with no field offset and no member name, which " &
            "is the one per-instance fact this mod can act on without a " &
            "second hypothesis on top of the target name"
  else:
    bad = bad + ledBad
  resetLedger()

  # And the arming guard, which offline must refuse -- for the runtime reason
  # and no other. A guard that refused for the wrong reason would still look
  # like a pass here, so the reason is checked and not just the refusal.
  if armDeaths(censusRuntime(), censusLive()):
    if not censusLive():
      error "  deaths: the hook armed with no runtime attached, which means " &
            "the guard is not looking at anything"
      inc bad
    else:
      success "  deaths: " & deathState()
  else:
    if censusLive():
      info "  deaths: " & deathState()
    elif find(deathState(), "no IL2CPP runtime") < 0:
      error "  deaths: refused offline, but for the wrong reason (" &
            deathState() & "). The runtime clause is the one that should " &
            "fire here"
      inc bad
    else:
      success "  deaths: refused offline for the runtime reason and named " &
              "what it costs -- " & deathState()

  info "  refusals that are permanent on any post-1.0 client, with the reason:"
  info "    new WildSpawnType members -- the enum is native constants with " &
       "its switch tables already compiled, and there is no managed " &
       "Assembly-CSharp.dll and no pre-load window to rewrite. The registry " &
       "keeps and serves the mapping at /morebotsapi/bottypes; no shipped " &
       "client reads it. The census counts any role id at or above 100 so " &
       "that this claim is tested rather than repeated."
  info "    StandartBotBrain::Activate -- swapping a live brain object needs " &
       "a NEW managed type with overridden virtuals. IL2CPP has no runtime " &
       "type definition and nothing native can declare a C# class. This one " &
       "is permanent and knowing `this` does not touch it."
  info "  refusals that are NOT permanent, and were until recently recorded " &
       "as if they were:"
  info "    BotsGroup::IsPlayerEnemy, BotGroupWarnData::ShallBossAttack -- " &
       "these were refused on the grounds that a hook is not told which " &
       "instance it fired on. That was FALSE. The payload carries `this` as " &
       "Harmony's __instance and bots/instance.nim reads it. They are absent " &
       "for a different and smaller reason: naming WHICH group means reading " &
       "a member off it, every candidate name is a pre-1.0 guess, and " &
       "hostility already works server-side through ENEMY_BOT_TYPES."
  info "    SuitableFollowersList -- `this` was never the blocker; the list " &
       "is an argument and bindOnObject can call Add/Remove on it. What is " &
       "missing is upstream's filter rule, which nothing in this tree records."
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
    success "Bot AI population self-test: the registration surface works with no " &
            "backend attached"
    result = Ok
  else:
    error "Bot AI population self-test: " & $bad & " problem(s)"
    result = ErrGeneric

proc onLoad(): Status =
  case side()
  of sideClient: result = onLoadClient()
  of sideSim: result = simSelfTest()
  else: result = onLoadServer()

proc onUpdate(elapsedMs: int64): Status =
  ## The client half only. The server half is entirely event- and route-driven
  ## and has nothing per-tick to do.
  ##
  ## THE ORDER HERE IS THE FIX. It used to be `if gWorld.ready(): censusTick()`,
  ## and `bots/gate.nim` has the full mechanism; the short version is that
  ## `whenReady` is a type-resolvability probe that goes true ~47 ms after HOST
  ## RUNNING, so the mod opened the runtime, walked every loading assembly and
  ## installed a by-name detour off the Unity thread, in a menu, with no world.
  ##
  ## Three gates now, in cost order, and each one can say no:
  ##   1. the flag                     -- default OFF
  ##   2. the host's main-thread drain -- `bound` means it has FIRED
  ##   3. a GameWorld the host actually cached -- three-way, INCONCLUSIVE is
  ##      not a pass
  if side() != sideClient:
    return Ok
  if gClientOff or not cfgClientCensus:
    return Ok

  if not gGatePassed:
    if not cfgDeferUntilUnityThread:
      warn "morebots: deferUntilUnityThread is OFF -- arming on the host's " &
           "own thread, which is what killed the client ~30 ms after HOST " &
           "RUNNING and quarantined this mod. This path exists to reproduce " &
           "that deliberately."
      gGatePassed = true
    else:
      gGateMs = gGateMs + elapsedMs
      gGatePollMs = gGatePollMs + elapsedMs
      if gGatePollMs >= GatePollMs:
        gGatePollMs = 0
        let mt = askMainThread()
        if mt.ok and mt.bound:
          gGatePassed = true
          success "morebots: Unity's main thread is live after " &
                  $(gGateMs div 1000) & "s (drain " & mt.methodName & ", " &
                  $mt.frames & " firings); the world gate opens now"
        elif gGateMs >= GateGiveUpMs:
          gClientOff = true
          gClientState = "refused: the host's main-thread drain never " &
                         "confirmed within " & $(GateGiveUpMs div 1000) &
                         "s, so there is no thread on which IL2CPP work is " &
                         "legal. Nothing was opened, bound or patched."
          warn "morebots: " & gClientState & " The client half is OFF for " &
               "the rest of this run."
        elif not gGateSaid and gGateMs >= 3000:
          gGateSaid = true
          info "morebots: the IL2CPP runtime is up (" &
               (if gWorld.ready(): "whenReady true" else: "whenReady false") &
               ", which proves only that a type resolves) but the host's " &
               "main-thread drain has not fired; holding everything until " &
               "it does, up to " & $(GateGiveUpMs div 1000) & "s"
      return Ok

  # Gate 3. Re-asked every tick on purpose: a raid ends, the cache empties, and
  # the census must stop rather than keep scanning a world that is gone.
  let ws = worldState()
  if not gWorldSaid and ws != GwLive:
    gWorldSaid = true
    info "morebots: no census yet -- " & worldStateText()
  if ws != GwLive:
    return Ok
  if gWorldSaid or not gCensusBound:
    gWorldSaid = false
  censusTick()
  Ok

proc onUnload(): Status =
  if side() != sideClient:
    info "morebots: " & $gRegistrations & " bot type registration(s), " &
         $typeCount() & " type(s) known"
  Ok

exportMod(
  guid = ModGuid,
  name = "Bot AI — Population",
  author = "aowlspt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
