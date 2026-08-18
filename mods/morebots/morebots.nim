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
## **Client (`sideClient`).** A diagnostic, and nothing else. The reason is
## below, and it is not a limitation of this port.
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
## **The Harmony patches are gone.** Nine of them, and eight need something
## `aowlspt`'s `hook()` cannot do. A hook is a prefix detour that cannot read the
## method's arguments and cannot suppress the original — both refused by the ABI
## rather than approximated. `BotsGroup::IsPlayerEnemy` needs to *change a return
## value*; `BotGroupWarnData::ShallBossAttack` the same; `SuitableFollowersList`
## needs to mutate a list it is handed; `BaseStatisticsManager::OnDeath` needs
## the dead player; `StandartBotBrain::Activate` needs to swap a live brain
## object. None of that is expressible, so none of it is here. The two that
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

const
  ModGuid = "aowl.morebots"
  ModVersion = "1.0.0"

var gDebugLogs = false
var gBotCapBump = 0
var gRegistrations = 0

proc debugLog(m: string) =
  if gDebugLogs:
    info "morebots: " & m

# ---------------------------------------------------------------------------
# Events — the registration surface
# ---------------------------------------------------------------------------

proc onTypeRegister(payload: string): string =
  if registerType(payload):
    inc gRegistrations
    let name = field(payload, "name").asText("")
    debugLog "registered bot type " & name
    discard broadcast("morebots.registered", objOf("name", name))
    return okJson()
  result = errJson("the registration was refused; see the log")

proc onTypeOverlay(payload: string): string =
  let n = overlayType(payload)
  debugLog "overlay applied to " & $n & " type(s)"
  result = okJson()

proc onFactionDefine(payload: string): string =
  if define(payload):
    debugLog "faction " & field(payload, "name").asText("") & " defined"
    return okJson()
  result = errJson("the faction definition was refused; see the log")

proc onFactionRelate(payload: string): string =
  let n = relate(payload)
  debugLog "relation applied to " & $n & " bot type(s)"
  result = okJson()

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onGetFactions(url, body, session: string): string =
  ## Not enveloped. `/morebotsapi/*` is this mod's own namespace rather than one
  ## of the game's `/client/*` endpoints, and the `{"err":0,...}` wrapper is a
  ## contract with the game client specifically.
  result = factionsJson()

proc onGetRevenges(url, body, session: string): string =
  result = revengesJson()

proc onUpdateRevenge(url, body, session: string): string =
  let n = updateRevenge(body)
  debugLog "revenge updated for " & $n & " profile(s)"
  result = okJson()

proc onBotTypes(url, body, session: string): string =
  result = bottypesJson()

proc onDifficulties(url, body, session: string): string =
  ## The one route the *game* asks for. Vanilla difficulties come from whatever
  ## else serves this path; what is added here is the registered custom types,
  ## read back out of the database so the faction edits are included.
  result = difficultiesJson()

# ---------------------------------------------------------------------------
# The bot cap
# ---------------------------------------------------------------------------

proc bumpBotCaps() =
  ## `increaseBotCapAmount` raised every map's cap by a flat amount upstream. It
  ## is off by default here: a mod that adds a squad of six to a map wants the
  ## room, and a mod that adds nothing does not want a server quietly running
  ## more AI than the player asked for.
  if gBotCapBump <= 0:
    return
  let caps = dbRead("bots.config.maxBotCap")
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

proc subscribeEvents() =
  discard onEvent("morebots.type.register", onTypeRegister)
  discard onEvent("morebots.type.overlay", onTypeOverlay)
  discard onEvent("morebots.faction.define", onFactionDefine)
  discard onEvent("morebots.faction.relate", onFactionRelate)
  discard onEvent("morebots.hello", onHello)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoadClient(): Status =
  ## Everything the original did on the client needed to add an enum member, to
  ## override a method's return value, or to attach a Unity component. See the
  ## module comment: post-1.0 none of the three is reachable, and saying so once
  ## at load beats a mod that appears to be running and does nothing.
  info "morebots: the client half is a diagnostic only on post-1.0 Tarkov — " &
       "WildSpawnType cannot be extended without managed assemblies, and the " &
       "hunt behaviour needs BigBrain. The registry and factions are served " &
       "from the server side."
  Ok

proc onLoadServer(): Status =
  gDebugLogs = setting("enableDebugLogs").asBool(false)
  gBotCapBump = setting("increaseBotCapAmount").asInt(0)

  loadOverrides()
  loadDefaultFactions()
  initRevenge()
  subscribeEvents()
  registerRoutes()
  bumpBotCaps()

  info "morebots " & ModVersion & " ready, " & $factionCount() &
       " default faction(s)"

  # For dependents that loaded before this mod and are already subscribed. The
  # ones that load after will say `morebots.hello` and be answered then; the
  # timer is a third chance for anything that misses both.
  discard announce("")
  discard afterMs(0, announce)
  Ok

proc onLoad(): Status =
  if side() == sideClient:
    return onLoadClient()
  result = onLoadServer()

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
  onUnload = onUnload)
