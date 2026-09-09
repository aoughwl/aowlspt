## The bot type registry: what a custom bot *is*, and where it lands.
##
## Registering a bot type is two separate things, and conflating them is what
## made the original hard to use:
##
##  1. **The template** — a `bots.types.<name>` document: appearance, health,
##     difficulty, inventory. This is data, and it goes into the shared database
##     with `dbWrite`, which merges. Two mods that add sibling fields to the
##     same bot do not clobber each other.
##  2. **The identity** — the name, the integer role id, whether it is a boss,
##     which brain it borrows, which difficulties it allows. This is the part
##     the client would need, and the part that cannot be delivered post-1.0
##     (see the module comment in ../morebots.nim). It is kept anyway, and
##     served over `/morebotsapi/bottypes`, because the faction graph needs the
##     name -> id mapping and because a value that is written down can be
##     checked.
##
## The bot *config* — preset batch, durability, item spawn limits, equipment
## filters, currency stacks — is a third thing, and it goes under `bots.config`
## rather than into the type, because that is where a generator looks for it.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import spawntypes
import dbpath

type
  BotTypeInfo* = object
    name*: string        ## as the modder wrote it: "blackDivAssault"
    key*: string         ## the database key: "blackdivassault"
    id*: int             ## the WildSpawnType value
    scavRole*: string    ## end-of-raid label; locale key is "ScavRole/<this>"
    baseBrain*: int      ## the vanilla role whose brain it borrows
    isBoss*: bool
    isFollower*: bool
    hostileToAll*: bool
    countAsBoss*: bool
    presetBatch*: int
    excluded*: string    ## raw JSON array of difficulty indices

var gTypes: seq[BotTypeInfo] = @[]

proc typeCount*(): int = gTypes.len

proc indexOfName*(name: string): int =
  ## By key, so "BossWedge" and "bosswedge" are the same registration. The
  ## original matched case-sensitively in one place and case-insensitively in
  ## another, which is a bug that only shows up on the one mod that capitalises
  ## differently.
  let want = lower(name)
  result = -1
  for i in 0 ..< gTypes.len:
    if gTypes[i].key == want:
      return i

proc roleId*(name: string): int =
  ## Name -> role integer, custom types first and vanilla behind them. -1 for a
  ## name nobody has registered, which callers report rather than paper over.
  let i = indexOfName(name)
  if i >= 0:
    return gTypes[i].id
  result = vanillaId(name)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

var gExistKeys: seq[string] = @[]
var gExistAnswers: seq[bool] = @[]

proc botTypeExists*(key: string): bool =
  ## Does the database (or this mod's buffer) hold `bots.types.<key>`?
  ##
  ## Memoised, and the memo is worth more than it looks. `relateOne` asks this
  ## once per target bot type per relation, and a default install applies twelve
  ## relations over roughly fifty types — three hundred and thirty questions
  ## about fifty distinct keys. Each unmemoised answer copies a whole bot type
  ## document (a few hundred kilobytes) out of the database to look at its
  ## length. The memo turns that into fifty copies.
  ##
  ## Safe to memoise because the answer only ever goes from false to true, and
  ## it is this mod that makes it do so — `writeTemplate` sets the entry.
  for i in 0 ..< gExistKeys.len:
    if gExistKeys[i] == key:
      return gExistAnswers[i]
  let v = dbView("bots.types." & key)
  let answer = v.ok and v.raw.len > 1
  gExistKeys.add key
  gExistAnswers.add answer
  result = answer

proc noteBotType(key: string) =
  ## This mod has just written `bots.types.<key>`, so it exists from now on.
  for i in 0 ..< gExistKeys.len:
    if gExistKeys[i] == key:
      gExistAnswers[i] = true
      return
  gExistKeys.add key
  gExistAnswers.add true

proc writeTemplate*(key, templateJson: string): bool =
  ## The type document into `bots.types.<key>`. A merge, so a second mod adding
  ## a loadout overlay later does not have to restate the whole bot.
  if templateJson.len == 0:
    return false
  result = dbPut("bots.types." & key, templateJson)
  if result:
    noteBotType(key)

proc writeConfig*(key, configJson: string): int =
  ## `BotTypeConfig`, spread across `bots.config`. Returns how many sections it
  ## wrote, so a config that turned out to be empty is visible in the log rather
  ## than silently doing nothing.
  ##
  ## Upstream keyed `presetBatch` and `bosses` by the *original* casing and
  ## everything else by the lower-cased name. That is reproduced nowhere: every
  ## key here is the lower-case one, because a generator that looks a bot up by
  ## one spelling and finds its durability under another is the bug that
  ## produces bots with default gear and no error.
  result = 0
  if configJson.len == 0:
    return
  let doc = whole(configJson)

  let batch = child(doc, "presetBatch")
  if batch.found:
    discard dbPut("bots.config.presetBatch", done(objOf(key, batch.asInt(1))).text)
    inc result

  let dur = child(doc, "durability")
  if dur.found:
    discard dbPut("bots.config.durability." & key, dur.raw())
    inc result

  let limits = child(doc, "itemSpawnLimits")
  if limits.found:
    discard dbPut("bots.config.itemSpawnLimits." & key, limits.raw())
    inc result

  let equip = child(doc, "equipment")
  if equip.found:
    discard dbPut("bots.config.equipment." & key, equip.raw())
    inc result

  let currency = child(doc, "currencyStackSize")
  if currency.found:
    discard dbPut("bots.config.currencyStackSize." & key, currency.raw())
    inc result

proc appendToConfigList*(path, value: string) =
  ## `bots.config.bosses` and `bots.config.botRolesThatMustHaveUniqueName` are
  ## arrays, and `dbWrite` replaces an array outright — so the only safe way to
  ## add to one is to read it, check, and write the whole thing back.
  let cur = dbView(path)
  var out1 = arr()
  if cur.ok and cur.raw.len > 0:
    let items = each(whole(cur.raw))
    for it in items:
      if it.asText("") == value:
        return
      out1.add raw(it.raw())
  out1.add value
  discard dbPut(path, done(out1).text)

proc registerType*(payload: string): bool =
  ## One `morebots.type.register` event. Idempotent by name: `morebots.ready` is
  ## announced twice on purpose (see ../morebots.nim), so a well-behaved
  ## dependent will register twice and must not end up with two of everything.
  let doc = whole(payload)
  let name = field(doc, "name").asText("")
  if name.len == 0:
    error "morebots: a type registration arrived without a name; ignoring it"
    return false
  let key = lower(name)
  let id = field(doc, "id").asInt(-1)
  if id < 0:
    error "morebots: bot type '" & name & "' has no role id; ignoring it"
    return false

  let existing = indexOfName(name)
  var info1 = BotTypeInfo(
    name: name, key: key, id: id,
    scavRole: field(doc, "scavRole").asText("Scav"),
    baseBrain: field(doc, "baseBrain").asInt(1),
    isBoss: field(doc, "isBoss").asBool(false),
    isFollower: field(doc, "isFollower").asBool(false),
    hostileToAll: field(doc, "hostileToAll").asBool(false),
    countAsBoss: field(doc, "countAsBoss").asBool(false),
    presetBatch: field(doc, "presetBatch").asInt(1),
    excluded: "")

  let ex = field(doc, "excludedDifficulties")
  if ex.found:
    info1.excluded = ex.raw()
  else:
    # No answer means "normal only", which is what the original defaulted to
    # and what almost every custom bot actually wants: the vanilla difficulty
    # curve is tuned for vanilla loadouts.
    info1.excluded = "[0,2,3]"

  # Another registration for a name already known replaces the entry rather
  # than adding a second: the last word wins, and there is exactly one row per
  # bot for anything that iterates the registry.
  if existing >= 0:
    gTypes[existing] = info1
  else:
    gTypes.add info1

  let tmpl = field(doc, "template")
  if tmpl.found and tmpl.raw().len > 2:
    if not writeTemplate(key, tmpl.raw()):
      warn "morebots: could not write the template for " & name

  let cfg = field(doc, "config")
  if cfg.found:
    let sections = writeConfig(key, cfg.raw())
    if sections == 0:
      warn "morebots: the config for " & name & " set nothing"
    if field(cfg, "isBoss").asBool(false):
      appendToConfigList("bots.config.bosses", key)
    if field(cfg, "mustHaveUniqueName").asBool(false):
      appendToConfigList("bots.config.botRolesThatMustHaveUniqueName", key)

  result = true

proc overlayType*(payload: string): int =
  ## `morebots.type.overlay` — a partial document merged onto one or more
  ## existing types. This is the whole of upstream's `BotTypeReplace` and of the
  ## WTT loadout service, and it is one `dbWrite` per target, because a merging
  ## database is exactly the shape both of those hand-rolled.
  ##
  ## Returns how many types it touched.
  result = 0
  let doc = whole(payload)
  let patch = child(doc, "patch")
  if not patch.found:
    warn "morebots: an overlay arrived with no 'patch'; ignoring it"
    return
  let names = each(child(doc, "names"))
  for n in names:
    let key = lower(n.asText(""))
    if key.len == 0:
      continue
    if not botTypeExists(key):
      warn "morebots: overlay skipped, no bot type '" & key & "' in the database"
      continue
    if dbPut("bots.types." & key, patch.raw()):
      inc result

# ---------------------------------------------------------------------------
# What the client would have been told
# ---------------------------------------------------------------------------

proc bottypesJson*(): string =
  ## The registry as `{"848421": "blackDivAssault", ...}` plus the flags.
  ##
  ## Upstream never needed this: the prepatcher wrote the names into the client
  ## assembly's enum, so the client already knew them. Post-1.0 it cannot, so
  ## the mapping is at least *available* over HTTP rather than nowhere. Nothing
  ## in the shipped client reads it — see the note in ../morebots.nim.
  var o = obj()
  for i in 0 ..< gTypes.len:
    let t = gTypes[i]
    var e = obj()
    put(e, "name", t.name)
    put(e, "key", t.key)
    put(e, "id", t.id)
    put(e, "scavRole", t.scavRole)
    put(e, "baseBrain", t.baseBrain)
    put(e, "isBoss", t.isBoss)
    put(e, "isFollower", t.isFollower)
    put(e, "hostileToAll", t.hostileToAll)
    put(e, "countAsBoss", t.countAsBoss)
    put(e, "excludedDifficulties", raw(t.excluded))
    put(o, t.name, e)
  result = done(o).text

proc difficultiesJson*(): string =
  ## `/singleplayer/settings/bot/difficulties`: every registered type's four
  ## difficulty blocks, read back out of the database.
  ##
  ## Read back rather than cached, and that is the point — the faction relations
  ## edit `Mind` *after* the type is registered, so a cached copy would serve
  ## bots that are hostile to nobody.
  var o = obj()
  for i in 0 ..< gTypes.len:
    let key = gTypes[i].key
    let v = dbView("bots.types." & key & ".difficulty")
    if v.ok and v.raw.len > 2:
      put(o, key, raw(v.raw))
  result = done(o).text
