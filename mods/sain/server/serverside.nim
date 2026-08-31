## The server half.
##
## SAIN is two mods. The client plugin is the AI; the server mod does three
## small things that the client cannot do for itself, and all three are here.
##
## **1. Brain forcing.** SAIN replaces a bot's decision making by inserting
## BigBrain layers over a known base brain, and it only knows how to do that for
## a few brain types. The server therefore rewrites the weighted brain tables so
## that PMCs always get `pmcBot`, scavs always `assault`, and player scavs
## `pmcBot` — otherwise a bot spawns with a brain SAIN does not recognise and
## the client tears its own component down for that bot with a loud error.
##
## **2. Neutralising the per-map difficulty skew.** BSG ships a
## `BotLocationModifier` per map that scales accuracy, sight gain, scattering
## and vision distance. SAIN does its own difficulty maths and those multipliers
## fight it, so the server sets all four to 1 and makes SAIN's numbers
## authoritative. On **every** location, including the ones a mod that loads
## after this one creates -- which is why there is a handshake here rather than
## a single pass at load; see the block comment above
## `neutraliseLocationModifiers`.
##
## **3. Serving the preset.** SAIN's server mod hosts the preset store and a web
## editor. This port serves the resolved preset as JSON on one route, which is
## what the editor was for; there is no editor here and inventing one would be
## inventing a GUI rather than porting bot AI.
##
## Every write goes through `dbWrite`, which **merges**. That matters more here
## than anywhere else in the mod: another mod editing a sibling field of the
## same location must not be clobbered by this one setting four numbers.

import aowlspt
import aowlspt/server
import aowlspt/json
import ".." / core / types
import ".." / core / objective
import ".." / preset / preset
import "." / drive
import "." / dispatch

var gPreset: Preset

proc brainPatch(): Json =
  ## The weight table SAIN expects. A weight of zero is a brain the generator
  ## will never pick, so writing the whole table is how "only this one" is said.
  raw("""{"pmcBot":1,"assault":0,"exUsec":0,"followerBully":0,"bossBully":0}""")

proc patchBrains() =
  ## `dbWrite` merges, so each of these replaces only the keys it names.
  ##
  ## The paths are SPT's config layout. A database that does not carry them --
  ## the emulator's, for instance, or a fresh install with no dump -- answers
  ## `ErrNotFound`, and that is reported once rather than treated as a failure:
  ## a server with no bot config is a server with no bots to mis-brain.
  #
  # The three tables go in as **one** write, and the reason is the cost model
  # rather than tidiness: the backend holds the database as one text document
  # and a patch splices into it, so a `dbWrite` costs the size of the database
  # -- around 130 ms on a 41 MB import -- however small the patch is. Three
  # writes of forty bytes cost four hundred milliseconds of boot. One patch
  # shaped like the paths reaches the same three members, because a merge
  # recurses into an object member present on both sides.
  var applied = 0
  var missing = 0

  # Reads, not writes, decide what the log says. `dbWrite` *creates* a path the
  # database has never held and reports Ok either way, so the old count of Ok
  # statuses said "forced 3" on a database that carried none of the three. A
  # probe can tell the difference between forcing a table and inventing one.
  let probes = ["configs.pmc.pmcType", "configs.bot.assaultBrainType",
                "configs.bot.playerScavBrainType"]
  for p in probes:
    if not dbRead(p).ok:
      inc missing
  applied = probes.len

  let patch = "{\"pmc\":{\"pmcType\":" & brainPatch().text &
              "},\"bot\":{\"assaultBrainType\":{\"assault\":1,\"pmcBot\":0}," &
              "\"playerScavBrainType\":{\"pmcBot\":1,\"assault\":0}}}"
  if dbWrite("configs", patch) != Ok:
    warn "sain: could not write the brain tables"
    applied = 0
    missing = probes.len

  if applied > 0:
    info "sain: forced " & $applied & " brain table(s) to a brain Bot AI drives"
  if missing > 0:
    info "sain: " & $missing & " of those table(s) were not in this database " &
         "and were created. That is the normal case on the emulator and on " &
         "the 39 MiB import this was checked against -- neither carries a " &
         "top-level `configs` object at all -- and it means the brain forcing " &
         "reaches nothing here: it is SPT's bot generator that reads these " &
         "paths, and there is not one on this server. The write is kept " &
         "because an install that does have the tables is one where it works, " &
         "and this is the only honest thing to say about the one that does not."

# ---------------------------------------------------------------------------
# The per-map difficulty skew
# ---------------------------------------------------------------------------
#
# This used to be one procedure that read `locations`, wrote
# `BotLocationModifier` onto every map it found, and was finished. That is
# correct exactly once -- at the instant it runs -- and the instant it runs is
# decided by the host's load order, which is a directory walk. A mod that
# *adds* a location loads before or after this one by accident, and when it
# loads after, its map has no modifier, no line is logged, and a player raiding
# it gets BSG's difficulty skew fighting SAIN's own maths. `tools/allmods.nim`
# found exactly that against `mods/icebreaker`: `locations.suburbs` is created
# three positions later in the load order and never got one.
#
# The property that has to hold is "every location carries a neutral modifier,
# whoever made it and whenever they made it", and it has to hold under any
# order, because the order is not a thing either mod can see. So the work is
# split in two:
#
#   * a **sweep** over whatever locations exist when this mod loads, which is
#     the old behaviour and covers every mod that loaded first; and
#   * a **subscription** to `aowlspt.locations.changed`, which covers every mod
#     that loads afterwards. A mod that creates or rebinds a location says so,
#     and every decorator that cares hears it.
#
# Plus the other half of the handshake, `aowlspt.locations.hello`: this mod
# asks once at load, and anything that owns a location answers by announcing
# it. That covers the third case -- a map mod that loaded first but wrote its
# location later than its own `on_load` -- and it makes the contract symmetric,
# so neither side has to be the one that loads first. It is the same shape as
# `morebots.hello` / `morebots.ready`, deliberately: this repository already
# has one order-independent handshake and a second one that worked differently
# would be a second thing to learn.
#
# The handler runs on the announcing mod's stack, inside its `on_load`. That is
# supported -- events are synchronous and nest -- and it is also why the
# handler does the targeted thing rather than the cheap-to-write thing: it
# reads only the locations the announcement names and writes one patch,
# instead of pulling the whole `locations` subtree (tens of MB on an imported
# database) back through a nested delivery.

proc neutralPatch(): string =
  result = """{"AccuracySpeed":1,"GainSight":1,"Scattering":1,""" &
           """"VisibleDistance":1,"MarksmanAccuratyCoef":1}"""

proc isNeutral(base1: JsonRef): bool =
  ## Does this location's base already carry the five neutralised numbers?
  ##
  ## Only used to decide whether a *re*-announcement is worth a write. The
  ## sweep at load does not ask: keeping "every map has this field" true by
  ## construction is worth one merge, and reasoning about what a previous run
  ## left behind is how the bug above happened in the first place.
  result = false
  let m = child(base1, "BotLocationModifier")
  if not exists(m) or not isObject(m):
    return false
  let names = ["AccuracySpeed", "GainSight", "Scattering", "VisibleDistance",
               "MarksmanAccuratyCoef"]
  for n in names:
    let f = child(m, n)
    if not exists(f) or f.asFloat(0.0) != 1.0:
      return false
  result = true

var gNeutralised: seq[string] = @[]
  ## Every location id this mod has written a modifier onto. `/sain/status`
  ## serves the count, so "which maps did SAIN actually reach" is answerable
  ## from outside instead of inferred from the log -- which is the question the
  ## missing `suburbs` modifier could not be asked.

proc recorded(id: string): bool =
  result = false
  for k in gNeutralised:
    if k == id:
      return true

proc neutralisedCount*(): int = gNeutralised.len
proc neutralisedAt*(i: int): string =
  ## By index rather than as a seq: returning the sequence and iterating the
  ## result is not a borrow nimony will take.
  result = ""
  if i >= 0 and i < gNeutralised.len:
    result = gNeutralised[i]

proc writeModifiers(ids: seq[string]): int =
  ## One `dbWrite` for however many maps, and the reason is the cost model
  ## rather than tidiness: the backend holds the database as one text document
  ## and a patch splices into it, so a `dbWrite` costs the size of the database
  ## -- around 130 ms on a 41 MB import -- however small the patch is. Nineteen
  ## maps used to be nineteen calls and 2.5 seconds of boot. A single
  ## `locations` patch nesting all nineteen reaches exactly the same members,
  ## because a merge recurses into an object member present on both sides.
  result = 0
  if ids.len == 0:
    return 0
  var patch = obj()
  for id in ids:
    var base1 = obj()
    put(base1, "BotLocationModifier", raw(neutralPatch()))
    var m = obj()
    put(m, "base", base1)
    put(patch, id, m)
  if dbWrite("locations", done(patch).text) != Ok:
    warn "sain: could not write the per-map difficulty modifiers"
    return 0
  for id in ids:
    if not recorded(id):
      gNeutralised.add id
  result = ids.len

proc neutraliseLocationModifiers() =
  ## Set the `BotLocationModifier` to 1 on every map that exists right now.
  ##
  ## Enumerating the locations from the database rather than hard-coding a map
  ## list: a server with a modded map gets the same treatment, and a server with
  ## no locations at all does nothing instead of writing to paths that are not
  ## there.
  let locations = dbRead("locations")
  if not locations.ok or locations.raw.len == 0:
    info "sain: no locations in the database yet; per-map modifiers will be " &
         "applied to each map as the mod that owns it announces it"
    return
  let doc = whole(locations.raw)
  if not doc.isObject:
    return
  var ids: seq[string] = @[]
  var notMaps = 0
  for id in doc.keys():
    # `locations` is a table this mod did not write and does not own, and the
    # only thing it may assume about a member is what it can check. A member
    # with no `base` object is not a map, and writing
    # `locations.<x>.base.BotLocationModifier` onto one invents a path nothing
    # will ever read -- the same class of mistake as writing a bot relation
    # toward a faction the database has never heard of.
    let entry = child(doc, id)
    if not isObject(entry):
      inc notMaps
      continue
    let base1 = child(entry, "base")
    if not exists(base1) or not isObject(base1):
      inc notMaps
      continue
    ids.add id
  let n = writeModifiers(ids)
  if n > 0:
    info "sain: neutralised the difficulty skew on " & $n & " map(s)"
  if notMaps > 0:
    info "sain: " & $notMaps & " member(s) of `locations` carry no `base` " &
         "object and were left alone; they are not maps"

proc onLocationsChanged(payload: string): string =
  ## `aowlspt.locations.changed`: a mod has created or rebound a location.
  ##
  ## The payload names them -- `{"guid":...,"locations":["suburbs"]}` -- and an
  ## announcement that names none is answered with a full sweep, so a mod that
  ## only manages to say "something changed" still gets its map decorated.
  result = ""
  let doc = whole(payload)
  let named = child(doc, "locations")
  var announced: seq[string] = @[]
  if exists(named) and isArray(named):
    for it in each(named):
      let s = it.asText("")
      if s.len > 0:
        announced.add s
  let who = child(doc, "guid").asText("a mod")
  if announced.len == 0:
    neutraliseLocationModifiers()
    return ""
  var todo: seq[string] = @[]
  var absent = 0
  for id in announced:
    let b = dbRead("locations." & id & ".base")
    if not b.ok or b.raw.len == 0:
      # Announced and not there: the announcing mod has buffered its write and
      # not flushed it. Nothing to decorate yet, and saying so is better than a
      # write that creates half a location out of one field.
      inc absent
      continue
    if isNeutral(whole(b.raw)):
      continue
    todo.add id
  let n = writeModifiers(todo)
  if n > 0:
    info "sain: " & who & " announced " & $announced.len & " location(s); " &
         "neutralised the difficulty skew on " & $n & " of them"
  if absent > 0:
    warn "sain: " & who & " announced " & $absent & " location(s) that are " &
         "not in the database, so they were left alone. A mod that buffers " &
         "its database writes should announce after it flushes them."

proc watchForNewLocations() =
  ## Subscribe first, then sweep, then ask. In that order, because a mod that
  ## answers the hello answers it synchronously on this stack, and the handler
  ## has to be in place before the question is asked.
  discard onEvent("aowlspt.locations.changed", onLocationsChanged)
  neutraliseLocationModifiers()
  var hello = obj()
  put(hello, "guid", "aowl.sain")
  put(hello, "wants", "locations")
  discard broadcast("aowlspt.locations.hello", hello)

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onStatus(url, body, session: string): string =
  var o = obj()
  put(o, "ok", true)
  put(o, "enabled", gPreset.enabled)
  put(o, "engageDistance", gPreset.base.engageDistance)
  put(o, "timeBeforeSearch", gPreset.base.timeBeforeSearch)
  put(o, "roles", gPreset.byRole.len)
  # How many maps actually carry a neutralised modifier, rather than how many
  # existed when this mod loaded. A map created by a mod that loads later shows
  # up here once it has announced itself, so the number answers "did SAIN reach
  # every map on this install" instead of "did SAIN run".
  put(o, "mapsNeutralised", neutralisedCount())
  # What the drive path is doing, and its PASS/FAIL/INCONCLUSIVE verdict on the
  # live census. Served rather than only logged so the two-band comparison in
  # README.md can be run with curl instead of by reading a log.
  put(o, "drive", driveState())
  put(o, "driveCheck", driveCheck())
  # The ORBIT half. Two separate verdicts on purpose: `driveCheck` is about the
  # MoveSpeed channel and `dispatchCheck` about the GoToPoint one, and folding
  # them into one line would let a live speed channel mask a dead order channel.
  put(o, "dispatch", dispatchState())
  put(o, "dispatchCheck", dispatchCheck())
  # The objectives half, and a THIRD verdict rather than a folding-in, for the
  # same reason as above. `oneWriter` is the one that carries the claim this
  # feature exists to make -- that exactly one thing issues destinations -- and
  # it is stated as a negative over the OTHER writer's own counter, so it FAILS
  # if the retired path fires even once.
  put(o, "objectives", objectiveState())
  put(o, "catalogCheck", catalogCheck())
  put(o, "oneWriter", oneWriterCheck(objectivesOwnDestinations()))
  put(o, "objectivesSuppressedCensuses", suppressedCensuses())
  var maps = arr()
  var i = 0
  while i < neutralisedCount():
    add(maps, neutralisedAt(i))
    inc i
  put(o, "maps", maps)
  result = done(o).text

proc onPreset(url, body, session: string): string =
  ## The resolved preset, per role. This is what SAIN's `/sain/config` served,
  ## minus the editing half: a client asking "what settings am I running" gets
  ## an answer, and so does anyone with curl.
  var a = arr()
  var i = 0
  while i < gPreset.byRole.len:
    let s = gPreset.byRole[i]
    var o = obj()
    put(o, "role", roleName(BotRole(i)))
    put(o, "engageDistance", s.engageDistance)
    put(o, "timeBeforeSearch", s.timeBeforeSearch)
    put(o, "runAwayHealthThreshold", s.runAwayHealthThreshold)
    put(o, "maxCoverPathLength", s.maxCoverPathLength)
    put(o, "willSearchForEnemy", s.willSearchForEnemy)
    a.add o
    inc i
  result = done(a).text

proc publishBotLoot(p: Preset) =
  ## Hand the Bot AI > Loadout knobs to the server's own bot generator.
  ##
  ## The generator lives in `mods/tarkov/emu/bots.nim` and reads
  ## `configs.botLoot.richnessMultiplier` off the shared database. This is the
  ## bridge: one `dbWrite` at load creates that path, and every bot generated
  ## for the rest of the session reads it. Unlike `patchBrains`, whose consumer
  ## is SPT's generator (absent here), THIS write's consumer is present -- the
  ## emulator's generator is the thing making the bots -- so the knob genuinely
  ## reaches a raid, and a player who kills a scav can see the difference.
  let patch = "{\"botLoot\":{\"richnessMultiplier\":" & $p.lootRichness & "}}"
  if dbWrite("configs", patch) != Ok:
    warn "sain: could not publish bot-loot richness; bots use stock loot"
  else:
    info "sain: bot-loot richness published to the generator at " &
         $p.lootRichness & "x"

proc startServer*(p: Preset) =
  ## Called from `onLoad` on the server side only.
  gPreset = p
  if not p.enabled:
    info "sain: disabled by config; the server half is doing nothing"
    return
  if p.patchBrains:
    patchBrains()
  publishBotLoot(p)
  if p.neutraliseLocationModifiers:
    # Not `neutraliseLocationModifiers()` on its own any more: that decorates
    # the maps that exist at this instant, and which maps those are is decided
    # by a directory walk. See the block comment above.
    watchForNewLocations()
  # The one path in this mod that reaches a bot. It resolves no name and binds
  # no RVA: it rides `aowlspt/botnav`, whose host side is the already
  # byte-verified kind=15 detour on `EFT.BotOwner::UpdateManual`. See
  # `server/drive.nim` for why that is the whole of the reach, and for the
  # arming gate (the first census, not `whenReady`).
  # ORBIT: subscribe to the high-level plan BEFORE the drive arms, so a plan
  # broadcast by mods/tarkov during a load that races this one is not missed.
  if not startDispatch(p.forcePersonality, p.logDecisions):
    warn "sain: could not subscribe to `tarkov.orbit.plan`; no bot will be " &
         "sent to an objective this session, and /sain/status says so"
  startDrive(p.difficulty, p.roleDifficulty, p.logDecisions)
  discard serve("/sain/status", onStatus)
  discard serve("/sain/preset", onPreset)
  success "sain: server half ready"

proc stopServer*() =
  ## Hand every bot back to its own brain. A mod that unloads mid-raid must not
  ## leave a squad running at a MoveSpeed nobody set for the rest of the
  ## session -- that is the exact shape of a change that outlives the thing
  ## that made it.
  stopDrive()
