## bm/gen — seed + preset -> a whole world.
##
## DECISIONS MADE HERE (the contract left them open):
##
## * **`loadNames` / `loadArchetypes` are added to the contract's surface.**
##   `generate` needs `data/names.json` and `data/archetypes.json`, and the
##   contract gave no way to hand them in; a library module must not read
##   `dataDir()` for itself (the root owns paths). So the root loads the text
##   and pushes it here. Both report how many rows landed.
## * **Generation with no names loaded is a REFUSAL, not a fallback.** A
##   built-in name list would make `generate` succeed with a world that is not
##   the world the data files describe, and the determinism check would pass
##   over it. `generate` returns false and `note` says which file is empty.
## * **The whole world comes from ONE `Rng`, drawn in a fixed order.** That is
##   the entire determinism argument: same seed + same preset text + same data
##   files -> same draw sequence -> byte-identical world. The seed is mixed
##   with the preset id (`seed xor fnv1a64(preset.id)`) so that seed 7 in
##   `warlords` and seed 7 in `sandbox` are different worlds rather than the
##   same one wearing a different hat.
## * **Coordinates are integers-as-floats on a 600 m square**, offset per map.
##   There is no map geometry in the backend and inventing plausible-looking
##   real coordinates would be a confidently wrong answer; these are a
##   consistent fiction the client will have to translate, and DESIGN §10 owns
##   that gap.

import std/strutils
import aowlspt
import aowlspt/json as jr
import util
import rng
import world
import items

type
  Preset* = object
    id*, name*, worldPrompt*, tone*: string
    rules*, archetypes*, maps*: seq[string]
    factionCount*, peoplePerFaction*: int
    ok*: bool
    note*: string

# ---------------------------------------------------------------------------
# name + archetype tables
# ---------------------------------------------------------------------------

var gFirst: seq[string] = @[]
var gLast: seq[string] = @[]
var gCallsign: seq[string] = @[]
var gFactionWord: seq[string] = @[]

var gArchId: seq[string] = @[]
var gArchCreed: seq[string] = @[]
var gArchBias: seq[string] = @[]
var gArchRoleA: seq[int] = @[]
var gArchRoleText: seq[string] = @[]
var gArchWantA: seq[int] = @[]
var gArchWantText: seq[string] = @[]
var gArchForbidA: seq[int] = @[]
var gArchForbidText: seq[string] = @[]
var gArchTraitA: seq[int] = @[]
var gArchTraitText: seq[string] = @[]
var gArchVoiceA: seq[int] = @[]
var gArchVoiceText: seq[string] = @[]

proc namesLoaded*(): int = gFirst.len
proc archetypesLoaded*(): int = gArchId.len

proc textList(j: JsonRef): seq[string] =
  result = @[]
  for e in jr.each(j):
    let t = jr.asText(e, "")
    if t.len > 0: result.add t

proc loadNames*(text: string): int =
  ## `{"first":[…],"last":[…],"callsigns":[…],"factionWords":[…]}`.
  gFirst = @[]; gLast = @[]; gCallsign = @[]; gFactionWord = @[]
  if text.len == 0: return 0
  let root = jr.whole(text)
  if not jr.exists(root): return 0
  gFirst = textList(jr.child(root, "first"))
  gLast = textList(jr.child(root, "last"))
  gCallsign = textList(jr.child(root, "callsigns"))
  gFactionWord = textList(jr.child(root, "factionWords"))
  result = gFirst.len

proc findArch*(id: string): int =
  result = -1
  var i = 0
  while i < gArchId.len:
    if gArchId[i] == id: return i
    i = i + 1

proc loadArchetypes*(text: string): int =
  gArchId = @[]; gArchCreed = @[]; gArchBias = @[]
  gArchRoleA = @[]; gArchRoleText = @[]
  gArchWantA = @[]; gArchWantText = @[]
  gArchForbidA = @[]; gArchForbidText = @[]
  gArchTraitA = @[]; gArchTraitText = @[]
  gArchVoiceA = @[]; gArchVoiceText = @[]
  if text.len == 0: return 0
  let root = jr.whole(text)
  if not jr.exists(root): return 0
  for key in jr.keys(root):
    # `_`-prefixed keys are the file's own commentary, the convention every
    # config.json in this repo uses. An archetype called "_comment" would
    # otherwise be a real, empty faction the moment a preset mistyped a name.
    if key.len > 0 and key[0] == '_': continue
    let a = jr.child(root, key)
    gArchId.add key
    gArchCreed.add jr.asText(jr.child(a, "creed"), "")
    gArchBias.add jr.asText(jr.child(a, "stanceBias"), "neutral")
    let idx = gArchId.len - 1
    for r in textList(jr.child(a, "roles")):
      gArchRoleA.add idx; gArchRoleText.add r
    for w in textList(jr.child(a, "wants")):
      gArchWantA.add idx; gArchWantText.add w
    for f in textList(jr.child(a, "forbids")):
      gArchForbidA.add idx; gArchForbidText.add f
    for t in textList(jr.child(a, "traits")):
      gArchTraitA.add idx; gArchTraitText.add t
    for v in textList(jr.child(a, "voices")):
      gArchVoiceA.add idx; gArchVoiceText.add v
  result = gArchId.len

proc archRoles(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gArchRoleA.len:
    if gArchRoleA[k] == i: result.add gArchRoleText[k]
    k = k + 1
proc archWants(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gArchWantA.len:
    if gArchWantA[k] == i: result.add gArchWantText[k]
    k = k + 1
proc archForbids(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gArchForbidA.len:
    if gArchForbidA[k] == i: result.add gArchForbidText[k]
    k = k + 1
proc archTraits(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gArchTraitA.len:
    if gArchTraitA[k] == i: result.add gArchTraitText[k]
    k = k + 1
proc archVoices(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gArchVoiceA.len:
    if gArchVoiceA[k] == i: result.add gArchVoiceText[k]
    k = k + 1

# ---------------------------------------------------------------------------
# presets
# ---------------------------------------------------------------------------

proc parsePreset*(text: string): Preset =
  var p = Preset(id: "", name: "", worldPrompt: "", tone: "",
                 rules: @[], archetypes: @[], maps: @[],
                 factionCount: 0, peoplePerFaction: 0,
                 ok: false, note: "")
  if text.len == 0:
    p.note = "empty preset document"
    return p
  let root = jr.whole(text)
  if not jr.exists(root) or not jr.isObject(root):
    p.note = "preset is not a JSON object"
    return p
  p.id = jr.asText(jr.child(root, "id"), "")
  p.name = jr.asText(jr.child(root, "name"), "")
  p.worldPrompt = jr.asText(jr.child(root, "worldPrompt"), "")
  p.tone = jr.asText(jr.child(root, "tone"), "neutral")
  p.rules = textList(jr.child(root, "rules"))
  p.archetypes = textList(jr.child(root, "archetypes"))
  p.maps = textList(jr.child(root, "maps"))
  p.factionCount = jr.asInt(jr.child(root, "factionCount"), 0)
  p.peoplePerFaction = jr.asInt(jr.child(root, "peoplePerFaction"), 0)
  if p.id.len == 0:
    p.note = "preset has no \"id\""
    return p
  if p.worldPrompt.len == 0:
    p.note = "preset \"" & p.id & "\" has no \"worldPrompt\" -- that string is " &
             "the top of every prompt, so an empty one is a broken world"
    return p
  if p.maps.len == 0:
    p.note = "preset \"" & p.id & "\" lists no maps"
    return p
  if p.factionCount <= 0 or p.peoplePerFaction <= 0:
    p.note = "preset \"" & p.id & "\" has factionCount=" & $p.factionCount &
             " peoplePerFaction=" & $p.peoplePerFaction
    return p
  if p.archetypes.len == 0:
    p.note = "preset \"" & p.id & "\" lists no archetypes"
    return p
  p.ok = true
  p.note = "ok"
  result = p

proc presetFromFile*(path: string): Preset =
  let text = readAll(path)
  if text.len == 0:
    result = Preset(id: "", name: "", worldPrompt: "", tone: "",
                    rules: @[], archetypes: @[], maps: @[],
                    factionCount: 0, peoplePerFaction: 0, ok: false,
                    note: "unreadable or empty: " & path)
    return
  result = parsePreset(text)
  if not result.ok:
    result.note = result.note & " (" & baseName(path) & ")"

proc listPresets*(dir: string): seq[Preset] =
  ## Directory listing goes through PowerShell: nimony's `std/dirs` has no
  ## walker here, and this runs once at load rather than per request. A
  ## PowerShell failure yields an EMPTY list plus a preset row whose `note`
  ## says so -- never a silently short catalogue.
  result = @[]
  if dir.len == 0: return
  let r = runCmd("powershell -NoProfile -NonInteractive -Command " &
                 "\"Get-ChildItem -LiteralPath " & psQuote(dir) &
                 " -Filter *.json | Sort-Object Name | " &
                 "ForEach-Object { $_.Name }\"")
  if r.failed:
    result.add Preset(id: "", name: "", worldPrompt: "", tone: "",
                      rules: @[], archetypes: @[], maps: @[],
                      factionCount: 0, peoplePerFaction: 0, ok: false,
                      note: "could not list " & dir & " (PowerShell failed)")
    return
  for line in r.output.split('\n'):
    let f = line.strip()
    if f.len == 0: continue
    if not f.endsWith(".json"): continue
    result.add presetFromFile(joinPath(dir, f))


# ---------------------------------------------------------------------------
# guards -- shared by `generate` and by the [PLANT:] tag, because a cache made
# by a person in conversation must be indistinguishable from one the world was
# born with. Two spawners would be two fictions.
# ---------------------------------------------------------------------------

proc spawnGuardGroup*(cacheId, factionId, map, placeId: string;
                      x, y, z: float; n: int; r: var Rng): string =
  ## Creates `n` living guards standing on the cache and returns their group
  ## id. With no name tables loaded it creates NOBODY and returns "" -- a guard
  ## called "" is worse than a cache with no guards, because the client would
  ## spawn it.
  if gFirst.len == 0 or gLast.len == 0: return ""
  let grp = cacheId & "-guard"
  var k = 0
  while k < n:
    let pid = cacheId & "-g" & $(k + 1)
    let nm = pick(r, gFirst) & " \"" & pick(r, gCallsign) & "\" " & pick(r, gLast)
    var traits: seq[string] = @[]
    traits.add "watches the treeline more than the conversation"
    let idx = addPerson(pid, nm, factionId, "guard", "default", map, placeId,
                        x + float(nextInt(r, -6, 6)), y,
                        z + float(nextInt(r, -6, 6)), traits)
    setPersonActivity(idx, "guard")
    setPersonGroup(idx, grp)
    setPersonAttitude(idx, nextInt(r, -25, 0))
    setPersonInventoryNote(idx, "a rifle and orders about who is expected")
    addPersonKnows(idx, cacheId)
    k = k + 1
  result = grp

# ---------------------------------------------------------------------------
# generation
# ---------------------------------------------------------------------------

proc titleCase(s: string): string =
  result = ""
  var atStart = true
  for ch in s:
    if atStart and ch >= 'a' and ch <= 'z':
      result.add char(ord(ch) - 32)
    else:
      result.add ch
    atStart = (ch == ' ' or ch == '-' or ch == '_')

proc slug(s: string): string =
  result = ""
  for ch in normalizeText(s):
    if ch == ' ': result.add '-'
    else: result.add ch

proc generate*(seed: uint64; p: Preset; worldPromptOverride: string;
               note: var string): bool =
  if not p.ok:
    note = "preset unusable: " & p.note
    return false
  if gFirst.len == 0 or gLast.len == 0:
    note = "data/names.json is empty or was never loaded -- refusing to " &
           "generate a world with invented names"
    return false
  if gArchId.len == 0:
    note = "data/archetypes.json is empty or was never loaded"
    return false

  resetWorld()
  var r = initRng(seed xor fnv1a64(p.id))

  var prompt = p.worldPrompt
  if worldPromptOverride.len > 0: prompt = worldPromptOverride
  # The world's own name is drawn first, so it is stable regardless of how many
  # factions the preset asks for.
  let wname = titleCase(pick(r, gFactionWord)) & " " &
              titleCase(pick(r, gCallsign))
  setWorldMeta(seed, p.id, prompt, wname, 0'i64)
  setWorldWeather(pick(r, @["low cloud", "sleet", "clear and cold",
                            "fog off the river", "rain since dawn"]))

  # ------------------------------------------------------------- factions
  var fi = 0
  while fi < p.factionCount:
    let archName = p.archetypes[fi mod p.archetypes.len]
    let ai = findArch(archName)
    var creed = ""
    if ai >= 0: creed = gArchCreed[ai]
    let word = titleCase(pick(r, gFactionWord))
    let sign = titleCase(pick(r, gCallsign))
    let fid = slug(archName) & "-" & $(fi + 1)
    let home = p.maps[nextInt(r, 0, p.maps.len - 1)]
    let strength = 0.35 + nextFloat(r) * 0.6
    let idx = addFaction(fid, word & " " & sign, creed,
                         "#" & hex64(next(r))[0 ..< 6], home, strength)
    if ai >= 0:
      var wants = archWants(ai)
      shuffle(r, wants)
      var k = 0
      while k < wants.len and k < 3:
        addFactionWant(idx, wants[k])
        k = k + 1
      var forbids = archForbids(ai)
      shuffle(r, forbids)
      var m = 0
      while m < forbids.len and m < 2:
        addFactionForbid(idx, forbids[m])
        m = m + 1
    fi = fi + 1

  # stances. Bias comes from the archetype; then, when there are 3+ factions,
  # AT LEAST ONE pair is forced to `war` -- DESIGN §4 requires it and a world
  # where nobody is fighting is not the pitch.
  var a = 0
  while a < factionCount():
    var b = a + 1
    while b < factionCount():
      let ai = findArch(p.archetypes[a mod p.archetypes.len])
      let bi = findArch(p.archetypes[b mod p.archetypes.len])
      var biasA = "neutral"
      var biasB = "neutral"
      if ai >= 0: biasA = gArchBias[ai]
      if bi >= 0: biasB = gArchBias[bi]
      let roll = nextFloat(r)
      var s = "neutral"
      if biasA == "war" or biasB == "war":
        if roll < 0.6: s = "war"
        else: s = "rival"
      elif biasA == "rival" or biasB == "rival":
        if roll < 0.55: s = "rival"
      elif biasA == "allied" and biasB == "allied":
        if roll < 0.5: s = "allied"
      else:
        if roll < 0.2: s = "rival"
      setStance(a, b, s)
      b = b + 1
    a = a + 1
  if factionCount() >= 3:
    var anyWar = false
    var x = 0
    while x < factionCount():
      var y = x + 1
      while y < factionCount():
        if stance(x, y) == "war": anyWar = true
        y = y + 1
      x = x + 1
    if not anyWar:
      let f1 = nextInt(r, 0, factionCount() - 1)
      var f2 = nextInt(r, 0, factionCount() - 1)
      if f2 == f1: f2 = (f1 + 1) mod factionCount()
      setStance(f1, f2, "war")

  # ------------------------------------------------------------- places
  let kinds: seq[string] = @["camp", "market", "outpost", "ruin", "cache",
                             "checkpoint", "hideout"]
  var mi = 0
  while mi < p.maps.len:
    let map = p.maps[mi]
    let n = 3 + nextInt(r, 0, 2)
    var k = 0
    while k < n:
      let kind = kinds[nextInt(r, 0, kinds.len - 1)]
      let nm = titleCase(pick(r, gFactionWord)) & " " & titleCase(kind)
      var owner = ""
      if factionCount() > 0 and nextFloat(r) < 0.75:
        owner = factionId(nextInt(r, 0, factionCount() - 1))
      let px = float(nextInt(r, -300, 300))
      let py = float(nextInt(r, -20, 40))
      let pz = float(nextInt(r, -300, 300))
      var danger = nextFloat(r) * 0.8
      if kind == "checkpoint" or kind == "outpost": danger = danger + 0.2
      discard addPlace(slug(map) & "-" & slug(kind) & "-" & $(k + 1),
                       nm, map, kind, owner, px, py, pz, danger)
      k = k + 1
    mi = mi + 1

  # ------------------------------------------------------------- people
  var fj = 0
  while fj < factionCount():
    let ai = findArch(p.archetypes[fj mod p.archetypes.len])
    var roles: seq[string] = @[]
    var traitPool: seq[string] = @[]
    var voicePool: seq[string] = @[]
    if ai >= 0:
      roles = archRoles(ai)
      traitPool = archTraits(ai)
      voicePool = archVoices(ai)
    if roles.len == 0: roles = @["grunt"]
    let home = factionHomeMap(fj)
    let homePlaces = placesOnMap(home)
    var k = 0
    while k < p.peoplePerFaction:
      var role = roles[nextInt(r, 0, roles.len - 1)]
      if k == 0: role = "leader"
      elif k == 1 and roles.len > 1: role = "lieutenant"
      let nm = pick(r, gFirst) & " \"" & pick(r, gCallsign) & "\" " &
               pick(r, gLast)
      let pid = factionId(fj) & "-p" & $(k + 1)
      var pl = ""
      var px = 0.0
      var py = 0.0
      var pz = 0.0
      if homePlaces.len > 0:
        let hp = homePlaces[nextInt(r, 0, homePlaces.len - 1)]
        pl = placeId(hp)
        placePos(hp, px, py, pz)
        px = px + float(nextInt(r, -12, 12))
        pz = pz + float(nextInt(r, -12, 12))
      var traits: seq[string] = @[]
      if traitPool.len > 0:
        var tp = traitPool
        shuffle(r, tp)
        var t = 0
        while t < tp.len and t < 2:
          traits.add tp[t]
          t = t + 1
      var voice = "default"
      if voicePool.len > 0: voice = voicePool[nextInt(r, 0, voicePool.len - 1)]
      let idx = addPerson(pid, nm, factionId(fj), role, voice, home, pl,
                          px, py, pz, traits)
      var act = "idle"
      if role == "leader": act = "guard"
      elif role == "trader": act = "trade"
      elif role == "scout": act = "patrol"
      elif role == "lieutenant": act = "patrol"
      setPersonActivity(idx, act)
      setPersonMood(idx, nextFloat(r) * 1.4 - 0.7)
      setPersonAttitude(idx, nextInt(r, -30, 20))
      var grp = factionId(fj) & "-band" & $(1 + (k mod 2))
      if role == "leader" or role == "lieutenant":
        grp = factionId(fj) & "-command"
      setPersonGroup(idx, grp)
      setPersonInventoryNote(idx, pick(r, @[
        "a worn AK and two magazines", "a shotgun, no spare shells",
        "medical supplies and nothing to fight with",
        "a scoped rifle kept very clean", "knives, rope, and a radio",
        "a pistol and a bag of tinned food"]))
      k = k + 1
    fj = fj + 1

  # ------------------------------------------------------------- rumours
  # 2-3 per faction, each a retrievable fact, each the seed of one quest.
  var fq = 0
  while fq < factionCount():
    let people = peopleOfFaction(fq)
    let n = 2 + nextInt(r, 0, 1)
    var k = 0
    while k < n:
      var subject = "the road"
      if placeCount() > 0: subject = placeName(nextInt(r, 0, placeCount() - 1))
      let verb = pick(r, @[
        "has been losing people to something nobody will name at",
        "is quietly moving fuel through",
        "wants the checkpoint at",
        "buried three of its own last week near",
        "pays hard currency for anything taken out of",
        "will not go within a kilometre of"])
      let text = factionName(fq) & " " & verb & " " & subject & "."
      let fid = factionId(fq) & "-rumour" & $(k + 1)
      addFact(fid, factionId(fq) & " rumour " & slug(subject), text)
      if people.len > 0:
        let giver = people[nextInt(r, 0, people.len - 1)]
        addPersonKnows(giver, fid)
        let qkind = pick(r, @["fetch", "kill", "escort", "deliver", "find",
                              "survive"])
        discard addQuest(fid & "-q", personId(giver),
                         titleCase(qkind) & " at " & subject,
                         text & " " & personName(giver) &
                         " will pay to have it settled.",
                         qkind, subject,
                         pick(r, @["ammunition", "a place to sleep",
                                   "safe passage", "roubles", "a weapon",
                                   "information"]),
                         @["reach " & subject,
                           "report back to " & personName(giver)])
      k = k + 1
    fq = fq + 1

  # ------------------------------------------------------------- contracts
  # One open bounty and one debt, both against the player, both `offered`.
  if personCount() > 0:
    let hunter = nextInt(r, 0, personCount() - 1)
    let mark = nextInt(r, 0, personCount() - 1)
    discard addContract("bounty-1", "bounty", personId(hunter), "player",
                        "bring in " & personName(mark) & ", alive if possible",
                        pick(r, @["a rifle", "a week of food",
                                  "passage off this map"]),
                        worldClockMs() + int64(nextInt(r, 2, 6)) * 86400000'i64)
    let lender = nextInt(r, 0, personCount() - 1)
    discard addContract("debt-1", "debt", personId(lender), "player",
                        "you already owe " & personName(lender) &
                        " for the last time",
                        pick(r, @["your weapon", "your freedom",
                                  "a favour, unspecified"]),
                        worldClockMs() + int64(nextInt(r, 5, 12)) * 86400000'i64)


  # ------------------------------------------------------------- caches
  # The thing people TALK about, made real at generation time: a cache per
  # faction (1-3), each with a story for why it exists, a guard group that is
  # made of real people, a rumour fact that carries its id, and a pickup
  # contract naming a bearer and a passphrase. Everything an NPC can say about
  # a cache is a row here; nothing about it is written in code.
  var fc = 0
  while fc < factionCount():
    let ai = findArch(p.archetypes[fc mod p.archetypes.len])
    var wants: seq[string] = @[]
    if ai >= 0: wants = archWants(ai)
    let home = factionHomeMap(fc)
    let homePlaces = placesOnMap(home)
    let n = 1 + nextInt(r, 0, 2)
    var k = 0
    while k < n:
      var wantText = ""
      if wants.len > 0: wantText = wants[nextInt(r, 0, wants.len - 1)]
      let kindWord = kindWordFor(wantText, r)
      var pl = ""
      var cx = 0.0
      var cy = 0.0
      var cz = 0.0
      if homePlaces.len > 0:
        let hp = homePlaces[nextInt(r, 0, homePlaces.len - 1)]
        pl = placeId(hp)
        placePos(hp, cx, cy, cz)
        cx = cx + float(nextInt(r, -25, 25))
        cz = cz + float(nextInt(r, -25, 25))
      let cid = factionId(fc) & "-cache" & $(k + 1)
      var placeWord = pl
      if pl.len > 0:
        let pidx = findPlace(pl)
        if pidx >= 0: placeWord = placeName(pidx)
      let nm = titleCase(pick(r, gFactionWord)) & " " & titleCase(kindWord)
      let why = pick(r, @[
        "It was buried the night the convoy broke up and nobody came back for it.",
        "It is the price of a truce that has not been spoken about since.",
        "A dead man put it there and told two people, and one of them talks.",
        "It was skimmed off a shipment nobody dares report missing.",
        "It is what is left of a camp that burned, dug up and moved once already."])
      let story = factionName(fc) & " keeps " & (if wantText.len > 0: wantText
                  else: kindWord) & " at " & (if placeWord.len > 0: placeWord
                  else: home) & ". " & why
      let ci = addCache(cid, nm, pl, home, factionId(fc), "", story, "",
                        cx, cy, cz)
      setCacheStatus(ci, "intact")
      var tpls: seq[string] = @[]
      var counts: seq[int] = @[]
      var inote = ""
      discard resolveItems(kindWord & " " & wantText, r, tpls, counts, inote)
      var t = 0
      while t < tpls.len:
        cacheAddItem(ci, tpls[t], (if t < counts.len: counts[t] else: 1))
        t = t + 1
      let grp = spawnGuardGroup(cid, factionId(fc), home, pl, cx, cy, cz,
                                2 + nextInt(r, 0, 2), r)
      setCacheGuardGroup(ci, grp)
      # who knows: the leader, every lieutenant, and one outsider -- that last
      # one is why a rumour can cross a faction line at all.
      for pj in peopleOfFaction(fc):
        let role = personRole(pj)
        if role == "leader" or role == "lieutenant":
          addPersonKnows(pj, cid)
          addCacheKnownBy(ci, personId(pj))
      if personCount() > 0:
        var tries = 0
        while tries < 8:
          let outsider = nextInt(r, 0, personCount() - 1)
          if personFaction(outsider) != factionId(fc):
            addPersonKnows(outsider, cid)
            addCacheKnownBy(ci, personId(outsider))
            tries = 8
          else:
            tries = tries + 1
      let rid = cid & "-rumour"
      addFactRef(rid, factionId(fc) & " cache rumour " & kindWord,
                 story, "cache", cid, "gen")
      for who in cacheKnownBy(ci):
        let wi = findPerson(who)
        if wi >= 0: addPersonKnows(wi, rid)
      k = k + 1
    # one pickup contract per faction: somebody is expected to come for one of
    # these, with a passphrase. This is what an impersonator has to beat.
    let mine = cachesOnMap(home)
    var chosen = -1
    for mi2 in mine:
      if cacheOwner(mi2) == factionId(fc) and chosen < 0: chosen = mi2
    let fpeople = peopleOfFaction(fc)
    if chosen >= 0 and fpeople.len > 0:
      let bearer = fpeople[nextInt(r, 0, fpeople.len - 1)]
      let token = pick(r, gCallsign) & " " & pick(r, gFactionWord)
      discard addPickupContract(cacheId(chosen) & "-pickup", cacheId(chosen),
                                personId(bearer), token,
                                worldClockMs() + int64(nextInt(r, 3, 9)) * 86400000'i64)
      addPersonKnows(bearer, cacheId(chosen))
      addCacheKnownBy(chosen, personId(bearer))
      for gi in peopleOfGroup(cacheGuardGroup(chosen)):
        remember(gi, "We are expecting " & personName(bearer) &
                 " for the cache. The word is \"" & token & "\".")
    fc = fc + 1

  note = $factionCount() & " factions, " & $personCount() & " people, " &
         $placeCount() & " places, " & $questCount() & " quests, " &
         $factCount() & " facts, " & $contractCount() & " contracts, " &
         $cacheCount() & " caches; world \"" &
         worldName() & "\""
  discard journal("world.generated", "", "", "{\"seed\":\"" & hex64(seed) &
                  "\",\"preset\":\"" & p.id & "\"}")
  result = true
