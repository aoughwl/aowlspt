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
## authoritative.
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
import ".." / preset / preset

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
  var applied = 0
  var missing = 0

  if dbWrite("configs.pmc.pmcType", brainPatch().text) == Ok: inc applied
  else: inc missing
  if dbWrite("configs.bot.assaultBrainType",
             """{"assault":1,"pmcBot":0}""") == Ok: inc applied
  else: inc missing
  if dbWrite("configs.bot.playerScavBrainType",
             """{"pmcBot":1,"assault":0}""") == Ok: inc applied
  else: inc missing

  if applied > 0:
    info "sain: forced " & $applied & " brain table(s) to a brain SAIN drives"
  if missing > 0:
    info "sain: " & $missing & " brain table(s) are not in this database; " &
         "nothing to force (this is normal on the emulator)"

proc neutraliseLocationModifiers() =
  ## Set every map's `BotLocationModifier` to 1.
  ##
  ## Enumerating the locations from the database rather than hard-coding a map
  ## list: a server with a modded map gets the same treatment, and a server with
  ## no locations at all does nothing instead of writing to paths that are not
  ## there.
  let locations = dbRead("locations")
  if not locations.ok or locations.raw.len == 0:
    info "sain: no locations in the database; per-map modifiers left alone"
    return
  let doc = whole(locations.raw)
  if not doc.isObject:
    return
  let ids = doc.keys()
  const flat = """{"AccuracySpeed":1,"GainSight":1,"Scattering":1,""" &
               """"VisibleDistance":1,"MarksmanAccuratyCoef":1}"""
  var count = 0
  for id in ids:
    if dbWrite("locations." & id & ".base.BotLocationModifier", flat) == Ok:
      inc count
  info "sain: neutralised the difficulty skew on " & $count & " map(s)"

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

proc startServer*(p: Preset) =
  ## Called from `onLoad` on the server side only.
  gPreset = p
  if not p.enabled:
    info "sain: disabled by config; the server half is doing nothing"
    return
  if p.patchBrains:
    patchBrains()
  if p.neutraliseLocationModifiers:
    neutraliseLocationModifiers()
  discard serve("/sain/status", onStatus)
  discard serve("/sain/preset", onPreset)
  success "sain: server half ready"
