## The Tarkov emulator, as an aowlspt mod.
##
##     aowl build-mod mods/tarkov
##
## This is the game server: profiles, the static tables, traders, the flea
## market, quests, the hideout, raids. It is a **mod**, not part of the backend,
## and it reaches the backend only through `aowlspt` and `aowlspt/server` — the
## same two imports any other mod has. Nothing here is privileged.
##
## That constraint is the point of the file. If the emulator needed a private
## door into the host, the plugin API would not be enough to write a game server
## with, and everyone else's mods would hit the same wall one endpoint later.
## Every gap found while writing this was closed in the API rather than worked
## around here: persistence (`save`/`load`/`savedKeys`), reading a request body
## (`aowlspt/json`), building arrays and envelopes, events, timers.
##
## Layout:
##
##     emu/ids.nim        MongoIds
##     emu/profile.nim    the profile document, and its persistence
##     emu/sessions.nim   session id -> profile
##     emu/templates.nim  the static tables, out of the database
##     emu/traders.nim    trader settings and assorts
##     emu/inventory.nim  the item-moving endpoint
##     emu/raid.nim       raid setup and teardown
##
## Every route answers in the client's envelope — `{"err":0,"errmsg":null,
## "data":...}` — via `envelope`. A route that returns bare data gets a client
## that reads a good response as a failure, silently, and that is an evening to
## find once.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import emu/ids
import emu/profile
import emu/sessions
import emu/templates
import emu/traders
import emu/inventory
import emu/raid
import emu/quests
import emu/hideout
import emu/trading
import emu/bots
import emu/mail
import emu/insurance
import emu/market
import emu/production
import emu/skills
import emu/scav
import emu/redeem
import emu/notify

const
  ModGuid = "aowl.tarkov"
  ServerName = "aowlspt"

var gRequests = 0
var gEdition = "standard"
var gDefaultSide = "Usec"
var gNowSeconds = 0
var gStartingRoubles = 500000
var gInsurancePercent = 10
var gInsuranceHours = 24
var gScavCooldownSeconds = 900
var gRaidId = ""

proc nowSeconds(): int =
  ## Wall-clock seconds. The host gives monotonic milliseconds since it started,
  ## which is the right clock for timing and the wrong one for a registration
  ## date, so a base is taken from config once and added to.
  result = gNowSeconds + int(nowMs() div 1000'i64)

# ---------------------------------------------------------------------------
# Resolving the caller
# ---------------------------------------------------------------------------

proc currentProfile(session: string): Profile =
  ## The profile this request belongs to.
  ##
  ## Falls back to the only profile in the store when the session is unknown and
  ## there is exactly one. That covers the case the client puts a server in
  ## after a restart -- it keeps its old session id and never re-selects -- and
  ## it deliberately does not guess when two profiles exist.
  var id = profileFor(session)
  if id.len == 0:
    let all = allProfileIds()
    if all.len == 1:
      id = all[0]
      if session.len > 0:
        bindSession(session, id)
        info "rebound session " & session & " to the only profile " & id
  if id.len == 0:
    return Profile(id: "", text: "", ok: false)
  result = loadProfile(id)
  # Continuous production and area bonuses catch up here rather than on a timer.
  # A server that was switched off for a day must not lose that day's water, and
  # must not invent a day of fuel it never burned -- `tickHideout` works both out
  # from what is actually in the generator.
  if tickHideout(result, nowSeconds()):
    discard saveProfile(result)

# ---------------------------------------------------------------------------
# Launcher and login
# ---------------------------------------------------------------------------

proc onGameConfig(url, body, session: string): string =
  ## What the client reads before anything else: who it is talking to, and the
  ## backend urls it should use for the rest of the session.
  let p = currentProfile(session)
  var backend = obj()
  put(backend, "Main", "")
  put(backend, "Trading", "")
  put(backend, "Messaging", "")
  put(backend, "RagFair", "")
  var o = obj()
  put(o, "aid", if p.ok: p.field("aid").asInt(0) else: 0)
  put(o, "lang", "en")
  put(o, "languages", raw(languages()))
  put(o, "ndid", session)
  put(o, "taxonomy", 341)
  put(o, "activeProfileId", p.id)
  put(o, "backend", backend)
  put(o, "useProtobuf", false)
  put(o, "utc_time", nowSeconds())
  put(o, "totalInGame", 0)
  put(o, "reportAvailable", false)
  put(o, "twitchEventMember", false)
  result = envelope(o)

proc onGameStart(url, body, session: string): string =
  ## The client is ready to play. `utc_time` is what it sets its clock from.
  var o = obj()
  put(o, "utc_time", nowSeconds())
  result = envelope(o)

proc onGameVersion(url, body, session: string): string =
  ## Version validation. Accepting whatever the client reports, on purpose: this
  ## server is not the place to enforce a client build, and refusing here gives
  ## a player an error with nothing they can do about it.
  result = envelope(objOf("isvalid", true))

proc onKeepAlive(url, body, session: string): string =
  var o = obj()
  put(o, "msg", "OK")
  put(o, "utc_time", nowSeconds())
  result = envelope(o)

proc onLogout(url, body, session: string): string =
  ## The session binding survives a logout. The client reconnects with the same
  ## id, and dropping the binding here would put it back at "no profile".
  result = envelope(objOf("status", "ok"))

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

proc onProfileList(url, body, session: string): string =
  ## Every profile, PMC and scav side by side. An empty list is what puts the
  ## client on its "create a character" screen, which is the correct first-run
  ## behaviour rather than something to avoid.
  var a = arr()
  let all = allProfileIds()
  for id in all:
    let p = loadProfile(id)
    if p.ok:
      a.add raw(p.text)
      # The scav goes straight after its PMC. The client reads the pair in that
      # order and shows the second as the scav character.
      let sc = scavText(p, nowSeconds())
      if sc.len > 0:
        a.add raw(sc)
  result = envelope(a)

proc onProfileSelect(url, body, session: string): string =
  ## Binds this session to a profile. The id comes out of the request body, and
  ## a body naming a profile that does not exist is refused rather than bound --
  ## binding it would produce "no profile" on every request after this one, far
  ## from the cause.
  let wanted = field(body, "uid").asText("")
  var id = wanted
  if id.len == 0:
    let all = allProfileIds()
    if all.len >= 1:
      id = all[0]
  if id.len == 0:
    return failure(1, "there are no profiles to select")
  let p = loadProfile(id)
  if not p.ok:
    return failure(1, "no such profile: " & id)
  bindSession(session, id)
  success "session " & session & " -> profile " & id & " (" & p.nickname & ")"

  # Insurance returns are checked at login as well as on a timer. A server that
  # was switched off when a return came due must still deliver it, and a timer
  # alone never does.
  let posted = deliverDue(id, nowSeconds())
  if posted > 0:
    info "delivered " & $posted & " insurance return(s)"
  let settled = settleOffers(id, nowSeconds())
  if settled > 0:
    info "settled " & $settled & " flea offer(s)"

  var notifier = obj()
  put(notifier, "server", ServerName)
  put(notifier, "channel_id", session)
  put(notifier, "url", "")
  var o = obj()
  put(o, "status", "ok")
  put(o, "notifier", notifier)
  put(o, "notifierServer", "")
  result = envelope(o)

proc onProfileCreate(url, body, session: string): string =
  ## Creates a PMC from the character screen's choices.
  let nickname = field(body, "nickname").asText("")
  var sideName = field(body, "side").asText(gDefaultSide)
  if nickname.len == 0:
    return failure(1, "a profile needs a nickname")
  if nicknameTaken(nickname):
    # 255 is the client's own "nickname is taken" code, and using it makes the
    # client show its own message rather than a generic failure.
    return failure(255, "that nickname is taken")
  if sideName != "Bear" and sideName != "Usec":
    sideName = gDefaultSide
  let p = createProfile(nickname, sideName, gEdition, nowSeconds(),
                        gStartingRoubles)
  if not p.ok:
    return failure(1, "could not save the new profile: " & lastError())
  bindSession(session, p.id)
  success "created profile " & p.id & " (" & nickname & ", " & sideName & ")"
  discard broadcast("tarkov.profile.created", objOf("id", p.id))
  result = envelope(objOf("uid", p.id))

proc onSavageRegenerate(url, body, session: string): string =
  ## A new scav character. The `savage` id is kept -- the client caches it from
  ## the profile list and from the raid it just played -- and only the character
  ## behind it is replaced.
  let p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  if not regenerateScav(p, nowSeconds()):
    return failure(1, "could not regenerate the scav")
  result = envelope(objOf("status", "ok"))

proc onNicknameValidate(url, body, session: string): string =
  let nickname = field(body, "nickname").asText("")
  if nickname.len < 3:
    return failure(256, "that nickname is too short")
  if nicknameTaken(nickname):
    return failure(255, "that nickname is taken")
  result = envelope(objOf("status", "ok"))

proc onNicknameReserved(url, body, session: string): string =
  result = envelope(raw("\"\""))

proc onNicknameChange(url, body, session: string): string =
  let nickname = field(body, "nickname").asText("")
  if nickname.len < 3:
    return failure(256, "that nickname is too short")
  if nicknameTaken(nickname):
    return failure(255, "that nickname is taken")
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  setText(p, "Info.Nickname", nickname)
  setText(p, "Info.LowerNickname", toLowerAscii(nickname))
  if not saveProfile(p):
    return failure(1, "could not save the profile")
  result = envelope(objOf("status", 0))

# ---------------------------------------------------------------------------
# The item event: everything the player does by dragging something
# ---------------------------------------------------------------------------

proc deletedList(ids: seq[string]): JsonArray =
  ## The client wants deletions as objects, not bare ids. A list of strings here
  ## is a body it parses without complaint and then ignores, so the items stay
  ## on screen until the next restart.
  result = arr()
  for id in ids:
    result.add objOf("_id", id)

proc itemEventResponse(p: Profile; ch: Change): string =
  ## The diff the client applies to its own copy of the inventory.
  var items = obj()
  put(items, "new", raw(text(ch.created)))
  put(items, "change", raw(text(ch.changed)))
  put(items, "del", deletedList(ch.deleted))

  var skills = obj()
  put(skills, "Common", arr())
  put(skills, "Mastering", arr())
  put(skills, "Points", 0)

  var changes = obj()
  put(changes, "_id", p.id)
  put(changes, "experience", p.experience)
  put(changes, "quests", arr())
  put(changes, "questsStatus", arr())
  put(changes, "ragFairOffers", arr())
  put(changes, "builds", arr())
  put(changes, "items", items)
  put(changes, "production", jnull())
  put(changes, "improvements", obj())
  put(changes, "skills", skills)
  put(changes, "health", raw(p.field("Health").raw()))
  # The real trader standings, so a quest reward that moved one is visible
  # without a reload.
  put(changes, "traderRelations", raw(p.field("TradersInfo").raw()))

  var byProfile = obj()
  put(byProfile, p.id, changes)

  var warnings = arr()
  for problem in ch.problems:
    # Reported rather than swallowed. A warning the client shows is how a player
    # finds out an action did not take, instead of watching an item slide back.
    var w = obj()
    put(w, "index", 0)
    put(w, "errmsg", problem)
    put(w, "code", "0")
    put(w, "data", obj())
    warnings.add w

  var data = obj()
  put(data, "warnings", warnings)
  put(data, "profileChanges", byProfile)
  result = envelope(data)

proc onItemsMoving(url, body, session: string): string =
  ## One endpoint, a list of actions, applied in order. In order matters: a
  ## split followed by a move of the new item only works if the split has
  ## already happened.
  inc gRequests
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")

  let actions = field(body, "data")
  var inv = openInventory(p.field("Inventory.items").raw())
  if not inv.items.ok:
    return failure(1, "this profile has no item list")

  var ch = newChange()
  var examined: seq[string] = @[]
  var earned = 0
  var touchedProfile = false
  let list = each(actions)
  for a in list:
    # Quests and the hideout are edits to the *profile*, not to the item list,
    # and they arrive down the same endpoint as the drags. Dispatched here
    # rather than inside the inventory because the inventory has no business
    # knowing what a profile is -- and because the same batch routinely carries
    # both: handing in a quest item is a removal and a quest update together.
    let kind = a.field("Action").asText("")
    let qa = questAction(kind)
    let ha = hideoutAction(kind)
    let pa = productionAction(kind)
    if qa != qaNone:
      # The profile-aware entry point rather than the array-only one. Every
      # condition worth evaluating -- level, trader standing, what has actually
      # been handed over -- is about the profile, so a version that only sees
      # the quest array cannot refuse anything and a quest that pays out for
      # nothing is worse than one that will not complete.
      var gained = 0
      var problem = ""
      if applyQuestOnProfile(p, qa, a, nowSeconds(), gained, problem):
        earned = earned + gained
        touchedProfile = true
      if problem.len > 0:
        ch.problems.add problem
    elif ha != haNone:
      var problem = ""
      let updated = applyHideout(p.field("Hideout.Areas").raw(), ha, a,
                                 nowSeconds(), problem)
      if problem.len > 0:
        ch.problems.add problem
      else:
        setRaw(p, "Hideout.Areas", updated)
        touchedProfile = true
    elif pa != paNone:
      if applyProduction(p, inv, pa, a, nowSeconds(), ch):
        touchedProfile = true
    elif isRagfairAction(kind):
      discard applyRagfair(inv, a, p.stashId, p.id, p.nickname, ch,
                           nowSeconds())
    elif mailSource(a).len > 0:
      # A reward dragged out of a message is an ordinary `Move` carrying
      # `fromOwner: {type:"Mail"}`. Tested before the generic move, because the
      # item it names is not in the inventory yet.
      discard redeem(inv, p.id, p.stashId, a, ch)
    elif kind == "TradingConfirm":
      discard applyTrading(inv, a, p.stashId, ch)
    else:
      discard applyAction(inv, a, ch, examined)

  if earned > 0:
    addExperience(p, earned)

  if inv.dirty:
    setRaw(p, "Inventory.items", text(inv.items))
  if examined.len > 0:
    # The encyclopedia is a flat map of template id -> true. Merged into what
    # is already there rather than rebuilt, so examining one item does not
    # un-examine the rest.
    var enc = parseObject(p.field("Encyclopedia").raw())
    if not enc.ok:
      enc = newDoc()
    for tpl in examined:
      setBool(enc, tpl, true)
    setRaw(p, "Encyclopedia", text(enc))
  if inv.dirty or examined.len > 0 or touchedProfile:
    if not saveProfile(p):
      # A redemption that took an item out of the mailbox and then failed to
      # save the profile would lose it. The mailbox edits are staged until the
      # profile is on disk, and dropped if it is not.
      discardRedemptions()
      return failure(1, "could not save the profile: " & lastError())
  commitRedemptions()

  for problem in ch.problems:
    warn "items/moving: " & problem
  result = itemEventResponse(p, ch)

# ---------------------------------------------------------------------------
# Traders
# ---------------------------------------------------------------------------

proc onTraderSettings(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(traderSettings()))

proc onTraderAssort(url, body, session: string): string =
  ## `/client/trading/api/getTraderAssort/<id>`.
  inc gRequests
  let id = pathAfter(url, "/client/trading/api/getTraderAssort/")
  if id.len == 0:
    return failure(1, "no trader in " & url)
  result = envelope(raw(traderAssort(id, nowSeconds() + 3600)))

proc onTraderUserAssort(url, body, session: string): string =
  inc gRequests
  result = envelope(emptyObject())

# ---------------------------------------------------------------------------
# Static tables
# ---------------------------------------------------------------------------
#
# The largest bodies the server sends, and the ones that must not be rebuilt per
# request: each is spliced in as the text the database already holds.

proc onItems(url, body, session: string): string = envelope(raw(items()))
proc onGlobals(url, body, session: string): string = envelope(raw(globals()))
proc onHandbook(url, body, session: string): string = envelope(raw(handbook()))
proc onCustomization(url, body, session: string): string =
  envelope(raw(customization()))
proc onLanguages(url, body, session: string): string =
  envelope(raw(languages()))
proc onQuestList(url, body, session: string): string =
  envelope(raw(quests()))
proc onAchievementList(url, body, session: string): string =
  envelope(objOf("elements", raw(achievements())))

proc onLocale(url, body, session: string): string =
  ## `/client/locale/en` -- the language is the last path segment.
  let lang = pathAfter(url, "/client/locale/")
  result = envelope(raw(locale(if lang.len > 0: lang else: "en")))

proc onMenuLocale(url, body, session: string): string =
  let lang = pathAfter(url, "/client/menu/locale/")
  result = envelope(raw(menuLocale(if lang.len > 0: lang else: "en")))

proc onSettings(url, body, session: string): string =
  let v = dbRead("settings")
  if v.ok:
    return envelope(raw(v.raw))
  result = envelope(emptyObject())

proc onServerList(url, body, session: string): string =
  ## One server: this one. The client shows a ping and picks it.
  var s = obj()
  put(s, "ip", "127.0.0.1")
  put(s, "port", 6969)
  var a = arr()
  a.add s
  result = envelope(a)

proc onCheckVersion(url, body, session: string): string =
  var o = obj()
  put(o, "isvalid", true)
  put(o, "latestVersion", "")
  result = envelope(o)

# ---------------------------------------------------------------------------
# The endpoints that exist so the menu works
# ---------------------------------------------------------------------------
#
# A pile of small routes, each of which the client calls on the way to the main
# menu and each of which stops the menu when it 404s. They are grouped here
# rather than scattered because that is what they have in common: the answer is
# "nothing, successfully".

proc onEmptyObject(url, body, session: string): string =
  inc gRequests
  result = envelope(emptyObject())

proc onEmptyArray(url, body, session: string): string =
  inc gRequests
  result = envelope(emptyArray())

proc onNullData(url, body, session: string): string =
  inc gRequests
  result = envelopeNull()

proc onOkStatus(url, body, session: string): string =
  inc gRequests
  result = envelope(objOf("status", "ok"))

proc onNotifierChannel(url, body, session: string): string =
  ## The client opens a notification channel and polls it. Answering with a
  ## channel it can poll -- rather than a 404 -- is what keeps it from retrying
  ## in a loop for the whole session.
  var notifier = obj()
  put(notifier, "server", ServerName)
  put(notifier, "channel_id", session)
  put(notifier, "url", "")
  put(notifier, "notifierServer", "")
  put(notifier, "ws", "")
  result = envelope(notifier)

proc onNotifierPoll(url, body, session: string): string =
  ## Long-polled by the client. Answering immediately -- with news if there is
  ## any, and a ping if there is not -- rather than holding the connection: a
  ## held connection occupies one of a fixed number of accept workers, and four
  ## players idling in the menu would take the whole pool.
  let queued = take(session)
  if queued.len > 0:
    return envelope(raw(queued))
  result = envelope(raw(ping()))

# ---------------------------------------------------------------------------
# Raids
# ---------------------------------------------------------------------------

proc onRaidConfiguration(url, body, session: string): string =
  inc gRequests
  let cfg = raidConfiguration(body)
  gRaidId = field(cfg, "raidId").asText("")
  info "raid configured: " & field(cfg, "location").asText("?") & " as " &
       field(cfg, "side").asText("?")
  discard broadcast("tarkov.raid.configured", raw(cfg))
  result = envelopeNull()

proc onLocalLoot(url, body, session: string): string =
  inc gRequests
  let loc = field(body, "locationId").asText("factory4_day")
  result = envelope(raw(localLoot(loc, nowSeconds(), gRaidId)))

proc onMatchStart(url, body, session: string): string =
  inc gRequests
  # The per-raid skill counter resets here rather than at the end: the raid the
  # player is entering is the one whose gains are capped.
  var starting = currentProfile(session)
  if starting.ok and startRaidSkills(starting):
    discard saveProfile(starting)
  var settings = obj()
  put(settings, "aiAmount", "AsOnline")
  put(settings, "aiDifficulty", "AsOnline")
  put(settings, "bossEnabled", true)
  put(settings, "scavWars", false)
  put(settings, "taggedAndCursed", false)
  var o = obj()
  put(o, "serverId", newId())
  put(o, "serverSettings", settings)
  put(o, "status", "busy")
  put(o, "notifier", objOf("server", ServerName))
  result = envelope(o)

proc onMatchEnd(url, body, session: string): string =
  ## The client hands back the profile it played the raid with. Taking it is
  ## what makes a raid mean something -- health, what was picked up, what was
  ## lost -- and it is also the one place a mistake costs a player their stash,
  ## so the body is checked before it replaces anything.
  inc gRequests
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")

  let outcome = parseResult(field(body, "exit").asText("Left"))
  let played = field(body, "profile")
  if not played.found or not isObject(played):
    warn "match/end carried no profile; the raid changed nothing"
    return envelopeNull()

  let playedId = played.field("_id").asText("")
  # A scav raid hands back the scav, not the PMC. Recognised by the id rather
  # than by a flag in the body, because the id is the one thing that cannot be
  # wrong about which character was played.
  if playedId.len > 0 and playedId == p.scavId:
    var brought = 0
    var scavProblems: seq[string] = @[]
    if not endScavRaid(p, raw(played), keepsGear(outcome), nowSeconds(),
                       gScavCooldownSeconds, brought, scavProblems):
      return failure(1, "could not finish the scav raid")
    for problem in scavProblems:
      warn "scav raid: " & problem
    if not saveProfile(p):
      return failure(1, "could not save the profile after the scav raid")
    success "scav raid ended: " & $brought & " item(s) brought home"
    discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
    return envelopeNull()

  if playedId != p.id:
    # A body naming a different profile is refused rather than applied. Applying
    # it would overwrite one player's character with another's.
    error "match/end named profile " & playedId & " on a session bound to " & p.id
    return failure(1, "that raid result is for a different profile")

  var updated = Profile(id: p.id, text: raw(played), ok: true)
  # Skills are applied as a delta against the pre-raid profile and run through
  # the game's curve, rather than believed as sent. The client's numbers are the
  # client's.
  var levelUps: seq[string] = @[]
  discard applyRaidProgress(updated, p.text, nowSeconds(), levelUps)
  for s in levelUps:
    info p.nickname & " levelled " & s
  if not keepsGear(outcome):
    # Death takes the gear but not the stash: the client has already removed
    # what was lost from the profile it is handing back, so this is a log line
    # rather than an edit. Doing it again here would take it twice.
    info "profile " & p.id & " died in the raid"
  # What was insured and did not come home goes into the post. Worked out from
  # the *pre-raid* profile, because the post-raid one no longer has the items --
  # which is exactly what makes them eligible.
  let lost = lostAfterRaid(p.text, raw(played))
  if lost.len > 0:
    let goods = itemsById(p.text, lost)
    let due = nowSeconds() + gInsuranceHours * 3600
    if queueReturn(p.id, "54cb50c76803fa8b248b4571", goods, due):
      info $lost.len & " insured item(s) will be returned in " &
           $gInsuranceHours & "h"

  # Quest progress out of the raid: the counters the client accumulated, the
  # kills it did not count, and every quest that is now ready to hand in.
  # Rewards are *not* paid here -- the `QuestComplete` the player sends pays
  # them, and paying here as well would pay them twice.
  discard advanceQuestsAfterRaid(updated, p.text, raidLocation(body),
                                 field(body, "exit").asText("Left"),
                                 nowSeconds())

  if not saveProfile(updated):
    return failure(1, "could not save the profile after the raid")
  success "raid ended: " & field(body, "exit").asText("Left") & " for " &
          p.nickname
  discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
  result = envelopeNull()

proc onMatchAvailable(url, body, session: string): string =
  inc gRequests
  result = envelope(raw("true"))

proc onMatchGroup(url, body, session: string): string =
  inc gRequests
  result = envelope(objOf("squad", arr()))

proc onWeather(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(weather(nowSeconds())))

proc onLocations(url, body, session: string): string =
  inc gRequests
  let v = dbRead("locations")
  var o = obj()
  put(o, "locations", if v.ok: raw(v.raw) else: emptyObject())
  put(o, "paths", arr())
  result = envelope(o)

# ---------------------------------------------------------------------------
# Bots
# ---------------------------------------------------------------------------

proc onBotGenerate(url, body, session: string): string =
  ## The largest body the server builds, at the worst moment: the player is on a
  ## loading screen waiting for it. The cost work is in `emu/bots` -- tables
  ## read once per batch rather than once per bot -- and what is left here is
  ## the reporting, so a slow batch is visible in the log rather than guessed at.
  inc gRequests
  let started = nowMs()
  var generated = 0
  let batch = generate(body, generated)
  let took = nowMs() - started
  info "generated " & $generated & " bot(s) in " & $int(took) & "ms"
  result = envelope(raw(batch))

proc onBotLimit(url, body, session: string): string =
  inc gRequests
  result = envelope(raw("30"))

proc onBotDifficulty(url, body, session: string): string =
  inc gRequests
  let v = dbRead("bots.core")
  if v.ok:
    return envelope(raw(v.raw))
  result = envelope(emptyObject())

# ---------------------------------------------------------------------------
# Mail
# ---------------------------------------------------------------------------

proc onMailList(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyArray())
  result = envelope(raw(dialogList(p.id)))

proc onMailView(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyObject())
  let dialogId = field(body, "dialogId").asText("")
  result = envelope(raw(dialogView(p.id, dialogId)))

proc onMailAttachments(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyObject())
  result = envelope(raw(allAttachments(p.id)))

# ---------------------------------------------------------------------------
# Hideout, the flea market, insurance
# ---------------------------------------------------------------------------
#
# Each of these is a table the client reads at the menu and a screen it opens
# from it. They answer out of the database when it has them and with a valid
# empty table when it does not -- the screen opens and shows nothing, rather
# than the menu refusing to load.

proc onHideoutAreas(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(table("hideout.areas", "[]")))

proc onHideoutRecipes(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(table("hideout.production", "[]")))

proc onHideoutSettings(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(table("hideout.settings", "{}")))

proc onRagfairFind(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  result = envelope(raw(searchResult(body, p.id, p.nickname, nowSeconds())))

proc onRagfairPrice(url, body, session: string): string =
  inc gRequests
  result = envelope(raw(marketPrice(body, nowSeconds())))

proc onInsuranceCost(url, body, session: string): string =
  ## What each trader would charge to insure each item in the request. Priced
  ## off the handbook, so a server with no handbook quotes nothing rather than
  ## quoting zero -- a free premium makes insuring strictly better than not,
  ## which is a decision the player should be making.
  inc gRequests
  let traders = each(field(body, "traders"))
  let itemIds = each(field(body, "items"))
  var out1 = obj()
  for t in traders:
    let tid = t.asText("")
    if tid.len == 0:
      continue
    var perItem = obj()
    for it in itemIds:
      let tpl = it.asText("")
      let price = handbookPrice(tpl)
      let premium = premiumFor(price, gInsurancePercent)
      if premium > 0:
        put(perItem, tpl, premium)
    put(out1, tid, perItem)
  result = envelope(out1)

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc sweep(payload: string): string =
  ## The periodic pass: insurance that has come due, flea offers that have sold
  ## or expired, and a notification to whoever is playing so they find out now
  ## rather than the next time a screen happens to reload.
  ##
  ## On a timer *and* at login, which is not redundancy. A server that was
  ## switched off when a return came due must still deliver it, and a timer
  ## alone never does; a login alone never tells a player who is already sitting
  ## in the menu.
  var sessions: seq[string] = @[]
  var profiles: seq[string] = @[]
  boundSessions(sessions, profiles)
  for i in 0 ..< sessions.len:
    let posted = deliverDue(profiles[i], nowSeconds())
    let settled = settleOffers(profiles[i], nowSeconds())
    if posted + settled > 0:
      info "sweep: " & $posted & " insurance, " & $settled & " offer(s) for " &
           profiles[i]
      # One note, not one per item: the client opens the inbox from it, and the
      # inbox is where the detail already is.
      push(sessions[i], newMessageNote("", "", 5, nowSeconds()))
  result = ""

proc registerRoutes() =
  ## Every route, in one place, in the order the client calls them. Reading this
  ## list top to bottom is reading the client's boot sequence.

  # Login and session
  discard serve("/client/game/config", onGameConfig)
  discard serve("/client/game/start", onGameStart)
  discard serve("/client/game/version/validate", onGameVersion)
  discard serve("/client/game/keepalive", onKeepAlive)
  discard serve("/client/game/logout", onLogout)
  discard serve("/client/checkVersion", onCheckVersion)
  discard serve("/client/server/list", onServerList)

  # Profiles
  discard serve("/client/game/profile/list", onProfileList)
  discard serve("/client/game/profile/select", onProfileSelect)
  discard serve("/client/game/profile/create", onProfileCreate)
  discard serve("/client/game/profile/nickname/validate", onNicknameValidate)
  discard serve("/client/game/profile/nickname/reserved", onNicknameReserved)
  discard serve("/client/game/profile/nickname/change", onNicknameChange)
  discard serve("/client/game/profile/savage/regenerate", onSavageRegenerate)
  discard serve("/client/game/profile/voice/change", onOkStatus)

  # Static tables
  discard serve("/client/items", onItems)
  discard serve("/client/globals", onGlobals)
  discard serve("/client/handbook/templates", onHandbook)
  discard serve("/client/customization", onCustomization)
  discard serve("/client/account/customization", onEmptyArray)
  discard serve("/client/languages", onLanguages)
  discard servePrefix("/client/locale/", onLocale)
  discard servePrefix("/client/menu/locale/", onMenuLocale)
  discard serve("/client/settings", onSettings)
  discard serve("/client/quest/list", onQuestList)
  discard serve("/client/achievement/list", onAchievementList)
  discard serve("/client/achievement/statistic", onEmptyObject)

  # The inventory, and the traders
  discard serve("/client/game/profile/items/moving", onItemsMoving)
  discard serve("/client/trading/api/traderSettings", onTraderSettings)
  discard servePrefix("/client/trading/api/getTraderAssort/", onTraderAssort)
  discard servePrefix("/client/trading/api/getUserAssortPrice/",
                      onTraderUserAssort)
  discard serve("/client/trading/customization/storage", onEmptyArray)

  # Raids
  discard serve("/client/raid/configuration", onRaidConfiguration)
  discard serve("/client/location/getLocalloot", onLocalLoot)
  discard serve("/client/locations", onLocations)
  discard serve("/client/match/local/start", onMatchStart)
  discard serve("/client/match/local/end", onMatchEnd)
  discard serve("/client/match/available", onMatchAvailable)
  discard serve("/client/match/group/current", onMatchGroup)
  discard serve("/client/weather", onWeather)

  # Hideout, flea market, insurance
  discard serve("/client/hideout/areas", onHideoutAreas)
  discard serve("/client/hideout/production/recipes", onHideoutRecipes)
  discard serve("/client/hideout/settings", onHideoutSettings)
  discard serve("/client/hideout/qte/list", onEmptyArray)
  discard serve("/client/ragfair/find", onRagfairFind)
  discard serve("/client/ragfair/itemMarketPrice", onRagfairPrice)
  discard serve("/client/insurance/items/list/cost", onInsuranceCost)

  # The menu's supporting cast
  discard serve("/client/notifier/channel/create", onNotifierChannel)
  discard servePrefix("/client/notifier/getwebsocket", onNotifierPoll)
  discard serve("/client/mail/dialog/list", onMailList)
  discard serve("/client/mail/dialog/info", onEmptyObject)
  discard serve("/client/mail/dialog/view", onMailView)
  discard serve("/client/mail/dialog/getAllAttachments", onMailAttachments)
  discard serve("/client/mail/dialog/read", onNullData)
  discard serve("/client/mail/dialog/pin", onNullData)
  discard serve("/client/mail/dialog/unpin", onNullData)
  discard serve("/client/mail/dialog/remove", onNullData)

  # Bots
  discard serve("/client/game/bot/generate", onBotGenerate)
  discard serve("/client/game/bot/limit", onBotLimit)
  discard serve("/client/game/bot/difficulty", onBotDifficulty)
  discard serve("/client/friend/list", onEmptyArray)
  discard serve("/client/friend/request/list/inbox", onEmptyArray)
  discard serve("/client/friend/request/list/outbox", onEmptyArray)
  discard serve("/client/builds/list", onEmptyObject)
  discard serve("/client/survey", onEmptyObject)
  discard serve("/client/prestige/list", onEmptyArray)
  discard serve("/client/putMetrics", onNullData)
  discard serve("/client/analytics/event-disabled", onNullData)
  discard serve("/client/repeatalbeQuests/activityPeriods", onEmptyArray)

proc onLoad(): Status =
  if side() != sideServer:
    info "the emulator is a server mod; nothing to do on this side"
    return Ok

  seedIds(nowMs())
  gEdition = setting("edition").asText("standard")
  gDefaultSide = setting("defaultSide").asText("Usec")
  gNowSeconds = setting("epochBase").asInt(1700000000)
  gStartingRoubles = setting("startingRoubles").asInt(500000)
  gInsurancePercent = setting("insurancePercent").asInt(10)
  gInsuranceHours = setting("insuranceReturnHours").asInt(24)
  gScavCooldownSeconds = setting("scavCooldownSeconds").asInt(900)
  configureMarket(setting("fleaSpreadPercent").asInt(20),
                  setting("fleaOfferHours").asInt(12),
                  setting("fleaMaxOffers").asInt(600),
                  setting("fleaSaleMinutes").asInt(30))

  if not storeReady():
    error "this host has no persistent store; profiles cannot be kept " &
          "(host api " & $hostApiSize() & " bytes, this mod expects " &
          $expectedApiSize() & ")"
    return ErrUnsupported

  registerRoutes()

  # A minute is the right period for this: it is not a game loop, and every
  # thing it does is something the player would otherwise wait for a screen
  # reload to see.
  if everyMs(60000, sweep) != Ok:
    warn "no periodic sweep on this host: " & lastError()

  let all = allProfileIds()
  success "Tarkov emulator loaded, " & $all.len & " profile(s)"
  for id in all:
    let p = loadProfile(id)
    if p.ok:
      info "  " & id & "  " & p.nickname & " (" & p.side & ", level " &
           $p.level & ")"
  Ok

proc onUnload(): Status =
  info "the emulator handled " & $gRequests & " request(s)"
  Ok

exportMod(
  guid = ModGuid,
  name = "Tarkov Emulator",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
