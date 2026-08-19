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
## Layout — the spine of it. There are **37** modules under `emu/` and
## `README.md` beside this file lists all of them, along with every refusal this
## server makes and what each one costs the player. This list is the seven a
## reader needs to follow a request through, not the whole set:
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
import emu/dialogue
import emu/market
import emu/production
import emu/skills
import emu/scav
import emu/redeem
import emu/notify
import emu/personal
import emu/builds
import emu/loot
import emu/health
import emu/repair
import emu/notes
import emu/achievements
import emu/repeatable
import emu/gym
import emu/customise
import emu/decorate
import emu/selfchecks

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
var gDefaultBotLimit = 30
var gFenceKarmaExtract = 0.01
var gFenceKarmaDeath = 0.0
var gRaidId = ""
var gSelfCheckFailures: seq[string] = @[]
  ## Every load-time check that did not hold, for `/aowlspt/tarkov/selfcheck`.
  ## Empty is the ordinary state and is also an answer: it is the difference
  ## between "this mod loaded" and "nothing is listening".

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
  ##
  ## **Any session may select any profile, on purpose.** There is no credential
  ## in this protocol to check one against: the client authenticates at the
  ## launcher and the game then talks to a backend it reaches over loopback,
  ## with a session id it chose itself. A server that refused would be refusing
  ## the only caller there is. If this ever listens on anything but loopback,
  ## that is where the check belongs -- at the socket, in `backend/`, not here,
  ## because an ownership test built out of the session id is a test the caller
  ## supplies both sides of.
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

  # Where this profile's write counter stood when this request read it, checked
  # again at the moment of the write -- see `saveIfUnchanged` and the limitation
  # named there.
  #
  # Taken *after* `currentProfile`, because that catches the hideout up and may
  # save the profile itself; taking it before would have every request that
  # burned a minute of fuel refuse its own write.
  let asRead = profileVersion(p.id)

  let actions = field(body, "data")
  var inv = openInventory(p.field("Inventory.items").raw())
  if not inv.items.ok:
    return failure(1, "this profile has no item list")

  var ch = newChange()
  var examined: seq[string] = @[]
  var earned = 0
  var touchedProfile = false
  var questTouched = false
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
    let pe = personalAction(kind)
    let hx = healthAction(kind)
    let rp = repairAction(kind)
    let nt = noteAction(kind)
    if nt != naNone:
      if applyNotes(p, inv, nt, a, nowSeconds(), ch):
        touchedProfile = true
    elif rp != reNone:
      # Repair before everything else, because `Repair` names its item in
      # `target` rather than in `item` and the generic dispatch would take it
      # for an unknown action and drop it silently.
      if applyRepair(p, inv, rp, a, ch):
        touchedProfile = true
    elif hx != hxNone:
      if applyHealth(p, inv, hx, a, ch):
        touchedProfile = true
    elif pe != peNone:
      # Insurance, the wishlist, favourites, pins and hotkeys. Tested first
      # because two of them -- `PinLock` and `Bind` -- name an item the generic
      # inventory dispatch would otherwise happily handle as an unknown action.
      if applyPersonal(p, inv, pe, a, gInsurancePercent, ch):
        touchedProfile = true
    elif qa != qaNone:
      # The profile-aware entry point rather than the array-only one. Every
      # condition worth evaluating -- level, trader standing, what has actually
      # been handed over -- is about the profile, so a version that only sees
      # the quest array cannot refuse anything and a quest that pays out for
      # nothing is worse than one that will not complete.
      var gained = 0
      var problem = ""
      var note1 = ""
      if applyQuestOnProfile(p, qa, a, nowSeconds(), gained, problem, note1):
        earned = earned + gained
        touchedProfile = true
        questTouched = true
      if problem.len > 0:
        ch.problems.add problem
      if note1.len > 0:
        # Applied, and worth telling the player about anyway -- a quest the
        # database has no template for is one whose conditions were not checked
        # and whose rewards do not exist. That used to be an `err:0` with
        # nothing in it and a line in a log nobody reads.
        ch.problems.add note1
    elif ha != haNone:
      # The profile-aware entry point, not the array-only one: an upgrade needs
      # items out of the stash, a level in another area and a loyalty level with
      # a trader, and none of those is in `Hideout.Areas`.
      if applyHideoutOnProfile(p, inv, ha, a, nowSeconds(), ch):
        touchedProfile = true
    elif pa != paNone:
      if applyProduction(p, inv, pa, a, nowSeconds(), ch):
        touchedProfile = true
    elif kind == "RepeatableQuestChange":
      # A reroll. Before the generic dispatch because it names its quest in
      # `qid` rather than in `item`, and it edits both the profile (the
      # standing it costs) and the item list (the money it costs).
      if changeQuest(p, inv, a, nowSeconds(), ch):
        touchedProfile = true
    elif isRagfairAction(kind):
      discard applyRagfair(inv, a, p.stashId, p.id, p.nickname, ch,
                           nowSeconds())
    elif mailSource(a).len > 0:
      # A reward dragged out of a message is an ordinary `Move` carrying
      # `fromOwner: {type:"Mail"}`. Tested before the generic move, because the
      # item it names is not in the inventory yet.
      discard redeem(inv, p.id, p.stashId, a, ch)
    elif gymAction(kind):
      # The gym's workout. Before the generic dispatch because it names no item
      # at all -- `results` and an event id -- and the inventory would take it
      # for an unknown action and drop it in silence, which is a player working
      # out for nothing.
      if applyGym(p, a, nowSeconds(), ch):
        touchedProfile = true
    elif customiseAction(kind):
      # Setting a head, a suite, a dog tag or a voice. Also nameless as far as
      # the item list is concerned, and also a write the client asks for by id,
      # which is why `emu/customise` checks every one of them against the table
      # rather than copying it into the profile.
      if applyCustomisation(p, a, ch):
        touchedProfile = true
    elif decorateAction(kind) != daNone:
      # The hideout's own wardrobe: a floor, a wall, a ceiling, a target, a
      # mannequin's pose, or the shooting range's score. Nameless as far as the
      # item list is concerned -- an offer id, a map of poses, or a bare number
      # -- so the generic dispatch would take each of them for an unknown action
      # and drop it in silence, which is a player redecorating and watching
      # nothing change.
      let da = decorateAction(kind)
      var changed = false
      if da == daApply:
        changed = applyDecoration(p, a, ch)
      elif da == daPose:
        changed = applyMannequinPose(p, a, ch)
      else:
        changed = recordShootingRange(p, a, ch)
      if changed:
        touchedProfile = true
    elif sellAllAction(kind):
      # Refused by name. There is nothing left in the scav to sell by the time
      # this can arrive -- see `emu/scav`'s `refuseSellAll` for the whole of it.
      refuseSellAll(a, ch)
    elif kind == "TradingConfirm":
      if applyTrading(p, inv, a, ch):
        # A trade moves `TradersInfo.<id>.salesSum` and re-derives the loyalty
        # level from it, so the profile has changed even when the item list is
        # all the client asked about.
        touchedProfile = true
    else:
      discard applyAction(inv, a, ch, examined)

  if earned > 0:
    addExperience(p, earned)

  if questTouched:
    # Handing a quest in moves the level, the trader standing and the quest
    # status an achievement condition reads, so this is the second moment an
    # achievement can become true. Not run on every item event: the table is a
    # few hundred entries and a stash is dragged in thousands of times a
    # session.
    var earnedAchievements: seq[string] = @[]
    if awardAchievements(p, nowSeconds(), earnedAchievements) > 0:
      touchedProfile = true

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
    if profileVersion(p.id) != asRead:
      # Somebody else wrote this profile while this request was working from
      # it. Two distinct answers rather than one, because "the disk refused"
      # and "you were overtaken" are different problems and a single message
      # for both sends whoever reads the log looking in the wrong place.
      discardRedemptions()
      return failure(1, "another request changed this profile while this one " &
                        "was being handled; nothing was applied")
    if not saveProfile(p):
      # A redemption that took an item out of the mailbox and then failed to
      # save the profile would lose it. The mailbox edits are staged until the
      # profile is on disk, and dropped if it is not.
      #
      # Two reasons to be here and one answer. Either the write failed, or the
      # profile changed underneath this request while it was working -- and in
      # both cases the client has to be told the action did not happen, because
      # the alternative is telling it the action happened and throwing the
      # result away.
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
  # This is the only place the client says what language it is playing in, and
  # the trader mail this server composes has to be written in it -- an
  # insurance return is stored as text, so resolving it into English once is
  # English forever. Remembered against the profile rather than the session
  # because the sweep that posts a matured return runs with nobody logged in.
  # A failed write costs English mail, not a locale, so it is discarded.
  discard rememberLanguage(profileFor(session), lang)
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

proc onActivityPeriods(url, body, session: string): string =
  ## The dailies, the weekly and the scav's, generated rather than stored --
  ## `emu/repeatable` says how, and why there is nothing to store.
  ##
  ## The route's own spelling is the client's, typo included: it asks for
  ## `/client/repeatalbeQuests/activityPeriods` and a server that serves the
  ## correctly-spelled path serves nothing at all.
  var p = currentProfile(session)
  if not p.ok:
    # A session with no profile is the launcher poking the server before anyone
    # has selected a character. An empty list is what it expects.
    return envelope("[]")
  result = envelope(activityPeriods(p, nowSeconds()))

proc onEmptyArray(url, body, session: string): string =
  inc gRequests
  result = envelope(emptyArray())

proc onNullData(url, body, session: string): string =
  inc gRequests
  result = envelopeNull()

proc onOkStatus(url, body, session: string): string =
  inc gRequests
  result = envelope(objOf("status", "ok"))

proc onFriendList(url, body, session: string): string =
  ## `GetFriendListDataResponse` is an **object** of three lists, not a list.
  ## This answered `[]` for as long as it existed, which the client parses
  ## without complaint and then indexes `Friends` on.
  inc gRequests
  var o = obj()
  put(o, "Friends", arr())
  put(o, "Ignore", arr())
  put(o, "InIgnoreList", arr())
  result = envelope(o)

proc onChatServerList(url, body, session: string): string =
  ## One chat server: this one. `ChatServer` in the reference -- the client
  ## reads `Regions` and `Chats` off whichever entry it picks, so both have to
  ## be present and empty rather than absent.
  var srv = obj()
  put(srv, "_id", "aowlspt00000000000000000")
  put(srv, "RegistrationId", 20)
  put(srv, "DateTime", nowSeconds())
  put(srv, "IsDeveloper", true)
  put(srv, "Regions", arr())
  put(srv, "VersionId", "bgkidft87ddd")
  put(srv, "Ip", "127.0.0.1")
  put(srv, "Port", 6969)
  put(srv, "Chats", arr())
  var a = arr()
  a.add srv
  result = envelope(a)

proc onSelfCheck(url, body, session: string): string =
  ## `/aowlspt/tarkov/selfcheck` -- did this build's own arithmetic hold?
  ##
  ## The one route that answers whether the *rest* of them exist. Not in the
  ## client's namespace and never sent to the client: it is here so that a tool,
  ## a gate or a person can tell "this mod refused to load, and here is which
  ## check failed" apart from "nothing is listening", which are the same 404
  ## otherwise.
  ##
  ## Deliberately not wrapped in the client's `{err, errmsg, data}` envelope --
  ## nothing in the client asks for this, and an envelope would invite something
  ## to treat it as a game route.
  inc gRequests
  var fails = arr()
  for f in gSelfCheckFailures:
    fails.add jstr(f)
  var o = obj()
  put(o, "ok", gSelfCheckFailures.len == 0)
  put(o, "failures", fails)
  result = text(done(o))

proc onAchievementStatistic(url, body, session: string): string =
  ## `CompletedAchievementsResponse` is `{elements: {id: count}}`. `{}` gave the
  ## achievements screen a null to enumerate, and an empty map gave it a screen
  ## where nothing had ever been obtained -- which was true until achievements
  ## were awarded and is not any more.
  ##
  ## Counted over every profile the store holds, because that is the population
  ## this server has. See `completedStatistics` for why that is the honest
  ## reading of a number the reference names and does not define.
  inc gRequests
  var ids: seq[string] = @[]
  let all = allProfileIds()
  for id in all:
    let p = loadProfile(id)
    if not p.ok:
      continue
    let names = keys(p.field("Achievements"))
    for n in names:
      ids.add n
  result = envelope(objOf("elements", raw(completedStatistics(ids))))

proc onPrestigeList(url, body, session: string): string =
  ## `GetPrestigeResponse` is `{elements: [...]}`, not a bare array.
  inc gRequests
  result = envelope(objOf("elements", raw(table("templates.prestige", "[]"))))

proc onCustomizationStorage(url, body, session: string): string =
  ## What clothing the profile owns. An object with a `suites` list -- an empty
  ## array here is a null `suites` in the character screen.
  let p = currentProfile(session)
  var o = obj()
  put(o, "_id", p.id)
  put(o, "suites", arr())
  result = envelope(o)

proc onGameMode(url, body, session: string): string =
  ## `GameModeResponse`. Asked at boot, before the profile list, and this server
  ## has one mode.
  var o = obj()
  put(o, "gameMode", "regular")
  put(o, "backendUrl", "")
  result = envelope(o)

proc onProfileStatus(url, body, session: string): string =
  ## `GetProfileStatusResponseData`: one entry per character the account can
  ## play, PMC and scav, each saying it is not currently in a raid.
  ##
  ## `Free` is the status the client reads as "you may enter a raid". A missing
  ## entry for the scav is a scav button that does nothing.
  let p = currentProfile(session)
  var list = arr()
  if p.ok:
    var pmc = obj()
    put(pmc, "profileid", p.id)
    put(pmc, "profileToken", jnull())
    put(pmc, "status", "Free")
    put(pmc, "sid", "")
    put(pmc, "ip", "")
    put(pmc, "port", 0)
    list.add pmc
    let scav = p.scavId
    if scav.len > 0:
      var sc = obj()
      put(sc, "profileid", scav)
      put(sc, "profileToken", jnull())
      put(sc, "status", "Free")
      put(sc, "sid", "")
      put(sc, "ip", "")
      put(sc, "port", 0)
      list.add sc
  var o = obj()
  put(o, "maxPveCountExceeded", false)
  put(o, "profiles", list)
  result = envelope(o)

proc onTrue(url, body, session: string): string =
  inc gRequests
  result = envelope(raw("true"))

proc onTrader(url, body, session: string): string =
  ## `/client/trading/api/getTrader/<id>` -- one trader's base, where
  ## `traderSettings` is all of them. A trader the database does not have is a
  ## refusal rather than an empty object: an empty object is a trader with no
  ## currency and no loyalty levels, which the screen draws as a broken one.
  inc gRequests
  let id = pathAfter(url, "/client/trading/api/getTrader/")
  let base = traderBase(id)
  if base.len == 0:
    return failure(1, "no such trader: " & id)
  result = envelope(raw(base))

proc onItemPrices(url, body, session: string): string =
  ## `GetItemPricesResponse`: `{supplyNextTime, prices, currencyCourses}`.
  ##
  ## `prices` is what the trader screen divides by to show a flea comparison, so
  ## a missing key is a division on a null. The prices are the handbook's, which
  ## is the same table the flea builds its own offers off -- one source, so the
  ## comparison the screen draws agrees with the offers behind it.
  inc gRequests
  var prices = obj()
  let hb = dbRead("templates.handbook.Items")
  if hb.ok:
    for entry in each(whole(hb.raw)):
      let tpl = entry.field("Id").asText("")
      if tpl.len > 0:
        put(prices, tpl, entry.field("Price").asInt(0))
  var courses = obj()
  # The handbook is where the game keeps the exchange rate; a currency it does
  # not price is left out rather than given an invented one.
  let usd = handbookPrice(Dollars)
  if usd > 0: put(courses, "usd", usd)
  let eur = handbookPrice(Euros)
  if eur > 0: put(courses, "eur", eur)
  var o = obj()
  put(o, "supplyNextTime", nowSeconds() + 3600)
  put(o, "prices", prices)
  put(o, "currencyCourses", courses)
  result = envelope(o)

proc onAirdropLoot(url, body, session: string): string =
  ## What is in a crate. Generated by the same loot generator the floor of a
  ## raid uses, seeded from the container id the client names, so two clients
  ## opening the same crate see the same contents and a bug report can be
  ## replayed from the id in it.
  inc gRequests
  let container = field(body, "containerId").asText("")
  var o = obj()
  put(o, "icon", "Common")
  put(o, "container", raw(lootFor("airdrop", if container.len > 0: container
                                             else: gRaidId)))
  result = envelope(o)

proc onBuildsList(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    # Still all three lists. A client without a profile selected asks for this
    # too, and the shape it gets must not depend on that.
    var o = obj()
    put(o, "equipmentBuilds", arr())
    put(o, "weaponBuilds", arr())
    put(o, "magazineBuilds", arr())
    return envelope(o)
  result = envelope(raw(buildsJson(p.id)))

proc saveOneBuild(session, kind, body: string): string =
  let p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  var problem = ""
  let id = saveBuild(p.id, kind, body, problem)
  if id.len == 0:
    return failure(1, problem)
  result = envelope(objOf("id", id))

proc onBuildWeapon(url, body, session: string): string =
  inc gRequests
  result = saveOneBuild(session, "weaponBuilds", body)

proc onBuildEquipment(url, body, session: string): string =
  inc gRequests
  result = saveOneBuild(session, "equipmentBuilds", body)

proc onBuildMagazine(url, body, session: string): string =
  inc gRequests
  result = saveOneBuild(session, "magazineBuilds", body)

proc onBuildDelete(url, body, session: string): string =
  ## A delete of a build that is not there is refused rather than answered
  ## "done": it means the client's list and the server's disagree, and a
  ## cheerful answer leaves them disagreeing.
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  let id = field(body, "id").asText(field(body, "Id").asText(""))
  if not removeBuild(p.id, id):
    return failure(1, "no such build: " & id)
  result = envelopeNull()

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
  ## The same URL the client upgrades to a websocket, answered as a poll for
  ## every client that does not.
  ##
  ## A request carrying `Upgrade: websocket` never reaches this handler at all
  ## -- the backend answers `101` and holds the connection, and `deliver`
  ## pushes down it. What arrives here is a client that asked for the channel
  ## as an ordinary request, and it gets what it always got: news if there is
  ## any, a ping if there is not, immediately rather than held.
  ##
  ## Both paths stay, and this one is not a legacy. A client mid-login, one
  ## whose socket has just dropped, and every tool that drives this server over
  ## `wire.nim` are all in exactly this state, and a notification that had
  ## nowhere to go while a socket was reconnecting would be a notification
  ## lost. `deliver` queues whatever it could not push, so the next poll
  ## carries it.
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
    # Scav karma. Applied after the gear has been brought home and before the
    # single save, so a raid that failed to save does not leave the standing
    # moved for a raid whose loot was thrown away.
    if applyScavKarma(p, keepsGear(outcome), gFenceKarmaExtract,
                      gFenceKarmaDeath):
      info "Fence standing is now " &
           $p.field("TradersInfo." & FenceId & ".standing").asFloat(0.0)
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
    let due = nowSeconds() + gInsuranceHours * 3600
    let where = raidLocation(body)
    # One queue entry per **insuring trader**, not one for everybody. The
    # profile records who covered each item and this used to ignore it and post
    # the lot from Prapor; now that the message is the trader's own words, a
    # Therapist-insured rig arriving with Prapor's "my dogs found it" is a
    # visible lie rather than an invisible detail.
    #
    # Every id that is settled one way or the other comes out of the profile's
    # `InsuredItems` below. Nothing used to, and the cost of that was a raid
    # paying out gear that the raid before it had already paid out: the item is
    # not in the profile the client hands back -- it is in the post, or still
    # queued -- so the next raid's `lostAfterRaid` finds it "lost" all over
    # again. See `emu/insurance.withoutInsured` for why queueing, and not
    # delivery or collection, is the moment that owns the removal.
    var settled: seq[string] = @[]
    for trader in insuringTraders(p.text, lost):
      let mine = idsForTrader(p.text, lost, trader)
      let goods = itemsById(p.text, mine)
      if goods.len == 0 or goods == "[]":
        # Covered ids with no item behind them in the pre-raid profile: sold,
        # eaten, or otherwise gone from the stash between raids, which nothing
        # in this server takes out of `InsuredItems`. There is nothing to post
        # and nobody to post it, so the cover is discharged quietly -- left in
        # place it would ask the same unanswerable question at the end of every
        # raid the player ever plays, and send a "my guys are on it" message
        # each time.
        info $mine.len & " insured item(s) covered by " & trader &
             " are not in the profile at all; nothing to return"
        for id in mine:
          settled.add id
        continue
      if queueReturn(p.id, trader, goods, due, where, nowSeconds()):
        for id in mine:
          settled.add id
        info $mine.len & " insured item(s) will be returned by " & trader &
             " in " & $gInsuranceHours & "h"
        # And the trader says so now, if the database gives them the words for
        # it. Nothing is sent when it does not: there is no wording of this
        # server's own to fall back to and inventing one is not on the table.
        discard announceStart(p.id, trader, where, nowSeconds())
      else:
        # The queue could not be written. The cover stays on those ids on
        # purpose: nothing is owed to the player yet, so the loss must remain
        # claimable rather than being quietly cancelled by a failed write.
        warn "could not queue " & $mine.len & " insured item(s) for return " &
             "by " & trader & "; the cover on them stands"
    if settled.len > 0:
      # Written to the profile that is about to be saved -- the one the client
      # played the raid with -- because that is the profile the *next* raid
      # will be compared against.
      updated.setTopLevel("InsuredItems",
                          withoutInsured(updated.field("InsuredItems").raw(),
                                         settled))

  # Quest progress out of the raid: the counters the client accumulated, the
  # kills it did not count, and every quest that is now ready to hand in.
  # Rewards are *not* paid here -- the `QuestComplete` the player sends pays
  # them, and paying here as well would pay them twice.
  discard advanceQuestsAfterRaid(updated, p.text, raidLocation(body),
                                 field(body, "exit").asText("Left"),
                                 nowSeconds())

  # And whatever the raid just earned. After the quest pass rather than before
  # it: an achievement condition can name a quest status, and the status the
  # raid produced has only just been written.
  var earnedAchievements: seq[string] = @[]
  discard awardAchievements(updated, nowSeconds(), earnedAchievements)

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
  ## The sky. A constant -- temperature 18, season 1 -- until now, and that was
  ## fine as a default and wrong as the only answer: a weather mod had nothing
  ## to write into, and could not register a route of its own either, because
  ## the backend refuses a second registration of the same path. So the constant
  ## moved behind a database path and stayed the fallback.
  inc gRequests
  result = envelope(raw(weather(nowSeconds())))

proc onLocations(url, body, session: string): string =
  ## The map list. Descriptions only -- see `emu/raid` for what the client
  ## reads from this and what it was being sent instead.
  ##
  ## This was `dbRead("locations")` spliced in whole, which is every map's
  ## `base` *and* every map's loot: 12.5 MB and 247 ms on a default import,
  ## 560 MiB and 10.8 s on one with loose loot, for a screen listing nineteen
  ## maps. `looseLoot` now belongs to `/client/location/getLocalloot`, which
  ## already asks one map at a time.
  inc gRequests
  result = envelope(raw(liveLocationsBody()))

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

proc queryValue(url, name: string): string =
  ## One `?name=value` out of a url. Written here rather than in `aowlspt/json`
  ## because it is two routes worth of need and no route on this server takes a
  ## query it cannot also take in its body.
  var at = find(url, "?" & name & "=")
  if at < 0:
    at = find(url, "&" & name & "=")
  if at < 0:
    return ""
  var i = at + name.len + 2
  result = ""
  while i < url.len and url[i] != '&':
    result.add url[i]
    inc i

proc onBotLimit(url, body, session: string): string =
  ## How many bots the client may have alive on this map at once.
  ##
  ## This was the literal `30`, for every map, with no database path behind it
  ## at all -- so a mod shipping real population data (19 maps, 154 waves, a
  ## summed cap of 341) had all of it land in the database and none of it reach
  ## the client. The map is now asked, and the constant is what answers when the
  ## database has nothing to say about it.
  ##
  ## `BotMax` is the field the location base carries; `BotMaxPvE` is the PvE
  ## variant, and this server is only ever PvE, so it wins where both are
  ## present. The map comes from the query (`?location=factory4_day`) or from
  ## the body, because the client has spelled it both ways across builds and
  ## reading it wrong is a silent fall back to the default.
  inc gRequests
  var loc = queryValue(url, "location")
  if loc.len == 0:
    loc = field(body, "location").asText("")
  if loc.len == 0:
    loc = field(body, "locationId").asText("")
  if loc.len > 0:
    let pve = dbRead("locations." & loc & ".base.BotMaxPvE")
    if pve.ok and pve.asInt(0) > 0:
      return envelope(raw($pve.asInt(0)))
    let cap = dbRead("locations." & loc & ".base.BotMax")
    if cap.ok and cap.asInt(0) > 0:
      return envelope(raw($cap.asInt(0)))
  result = envelope(raw($gDefaultBotLimit))

proc onBotDifficulty(url, body, session: string): string =
  ## The brain settings for one role at one difficulty.
  ##
  ## The client asks `?type=assault&difficulty=normal`; this answered
  ## `bots.core` regardless, which is one set of settings for every bot in the
  ## game. `difficultyOf` reads the role's own block and falls back to
  ## `bots.core`, so a database with no per-role settings behaves exactly as it
  ## did.
  inc gRequests
  var role = queryValue(url, "type")
  if role.len == 0:
    role = field(body, "type").asText("")
  var level = queryValue(url, "difficulty")
  if level.len == 0:
    level = field(body, "difficulty").asText("normal")
  if role.len == 0:
    let v = dbRead("bots.core")
    if v.ok:
      return envelope(raw(v.raw))
    return envelope(emptyObject())
  result = envelope(raw(difficultyOf(role, level)))

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

# The four that used to be `onNullData`. Each answers `null` like the stub did
# -- that part was right, the reference has no response DTO for any of them --
# and each now changes the state the *next* `/client/mail/dialog/list` is built
# from, which is the part that was missing. See `emu/mail`, "What the player
# does to a dialog", for where `pinned` and `removed` live and why `remove`
# keeps a message that still holds items.
#
# Both spellings of every member are read. The reference names them `Dialogs`
# and `DialogId`; the client sends the camel-cased wire form, which is what
# `/client/mail/dialog/view` already reads as `dialogId`. Accepting both costs
# one line and is the difference between a working route and a route that
# silently does nothing on a build that spells it the other way -- which is
# exactly the failure these four are being fixed out of.

proc dialogIdOf(body: string): string =
  let a = field(body, "dialogId")
  if a.found:
    return a.asText("")
  result = field(body, "DialogId").asText("")

proc onMailRead(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelopeNull()
  var wanted: seq[string] = @[]
  var list = field(body, "dialogs")
  if not list.found:
    list = field(body, "Dialogs")
  if list.found and isArray(list):
    for e in each(list):
      let id = e.asText("")
      if id.len > 0:
        wanted.add id
  # A single-id spelling is accepted as well: the route is used from the
  # dialog screen as well as from the inbox, and a request naming one dialog
  # must not be read as naming none.
  let single = dialogIdOf(body)
  if single.len > 0:
    wanted.add single
  let changed = markDialogsRead(p.id, wanted)
  if changed > 0:
    info "marked " & $changed & " message(s) read for " & p.id
  result = envelopeNull()

proc onMailPin(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelopeNull()
  let id = dialogIdOf(body)
  if id.len == 0:
    warn "mail: a pin request named no dialog; nothing was pinned"
  elif not setDialogPinned(p.id, id, true):
    warn "mail: could not pin " & id & "; the dialog state was not written"
  result = envelopeNull()

proc onMailUnpin(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelopeNull()
  let id = dialogIdOf(body)
  if id.len == 0:
    warn "mail: an unpin request named no dialog; nothing was unpinned"
  elif not setDialogPinned(p.id, id, false):
    warn "mail: could not unpin " & id & "; the dialog state was not written"
  result = envelopeNull()

proc onMailRemove(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelopeNull()
  let id = dialogIdOf(body)
  if id.len == 0:
    warn "mail: a remove request named no dialog; nothing was removed"
    return envelopeNull()
  var kept = 0
  if not removeDialog(p.id, id, kept):
    warn "mail: could not remove " & id & "; the mailbox was left as it was"
  elif kept > 0:
    # Said out loud, because it is the one thing about this operation that is
    # not what the player asked for.
    warn "mail: removed the dialog with " & id & ", but kept " & $kept &
         " message(s) that still hold uncollected items -- they are off the " &
         "inbox and still on the collect-all screen"
  result = envelopeNull()

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

proc onHideoutCustomisation(url, body, session: string): string =
  ## `GetHideoutCustomisation`. The offers the hideout screen draws: 38 globals
  ## -- 11 floors, 10 walls, 8 ceilings, 9 shooting-range targets -- and 47
  ## poster and statuette slots, straight out of `hideout.customisation`.
  ##
  ## This answered `[]` until the table was read. That was wrong twice over: the
  ## reference's `HideoutCustomisation` is an **object** of `Globals` and
  ## `Slots` rather than an array, and the table has been imported and populated
  ## all along. *(The URL is the one already in use here; the shape is the
  ## reference DTO's.)*
  inc gRequests
  result = envelope(raw(hideoutCustomisationTable()))

proc onQteList(url, body, session: string): string =
  ## `GetQteList`. The gym's minigame, out of `hideout.qte` -- one entry in this
  ## database, and it answered the empty array until the workout was served.
  ## Empty when the database has none, which is a hideout with no bench rather
  ## than a menu that will not open.
  inc gRequests
  result = envelope(raw(qteTable()))

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
  ##
  ## `items` is a list of the player's **item ids**, not template ids -- the
  ## client is naming the things in its stash. Priced by looking each one up in
  ## the profile and taking its `_tpl`; a string that is not in the profile is
  ## used as a template id directly, which is what a caller with a template in
  ## hand means and costs nothing to allow. Reading the id as a template was a
  ## quote of nothing for every real request, which reads as "insurance is
  ## free" on the screen that offers it.
  inc gRequests
  let p = currentProfile(session)
  let traders = each(field(body, "traders"))
  let itemIds = each(field(body, "items"))
  var out1 = obj()
  for t in traders:
    let tid = t.asText("")
    if tid.len == 0:
      continue
    var perItem = obj()
    for it in itemIds:
      let named = it.asText("")
      if named.len == 0:
        continue
      var tpl = named
      if p.ok:
        let owned = each(p.field("Inventory.items"))
        for o in owned:
          if o.field("_id").asText("") == named:
            tpl = o.field("_tpl").asText(named)
      let price = handbookPrice(tpl)
      let premium = premiumFor(price, gInsurancePercent)
      if premium > 0:
        # Keyed by what the client asked about, so it can match the answer back
        # to the row it drew.
        put(perItem, named, premium)
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
      # No note from here any more. Each of those insurance returns and settled
      # offers arrives as a message through `emu/mail.deliver`, which notifies
      # at the point the message is written -- so a summary note here would be
      # a second badge for mail the player has already been told about, and one
      # that names no dialog to open.
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
  discard serve("/client/game/mode", onGameMode)
  discard serve("/client/profile/status", onProfileStatus)
  # `GetProfileSettings` answers a bare `true`; the client only checks that the
  # call succeeded.
  discard serve("/client/profile/settings", onTrue)
  discard serve("/client/game/profile/search", onEmptyArray)
  discard serve("/client/profile/view", onEmptyObject)

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
  discard serve("/client/achievement/statistic", onAchievementStatistic)

  # The inventory, and the traders
  discard serve("/client/game/profile/items/moving", onItemsMoving)
  discard serve("/client/trading/api/traderSettings", onTraderSettings)
  discard servePrefix("/client/trading/api/getTraderAssort/", onTraderAssort)
  discard servePrefix("/client/trading/api/getUserAssortPrice/",
                      onTraderUserAssort)
  discard servePrefix("/client/trading/api/getTrader/", onTrader)
  discard serve("/client/trading/customization/storage", onCustomizationStorage)
  discard servePrefix("/client/items/prices/", onItemPrices)

  # Raids
  discard serve("/client/raid/configuration", onRaidConfiguration)
  discard serve("/client/location/getLocalloot", onLocalLoot)
  discard serve("/client/location/getAirdropLoot", onAirdropLoot)
  discard serve("/client/locations", onLocations)
  discard serve("/client/match/local/start", onMatchStart)
  discard serve("/client/match/local/end", onMatchEnd)
  discard serve("/client/match/available", onMatchAvailable)
  discard serve("/client/match/group/current", onMatchGroup)
  discard serve("/client/match/group/status", onMatchGroup)
  discard serve("/client/match/group/exit_from_menu", onNullData)
  discard serve("/client/match/exit", onNullData)
  discard serve("/client/weather", onWeather)

  # Hideout, flea market, insurance
  discard serve("/client/hideout/areas", onHideoutAreas)
  discard serve("/client/hideout/production/recipes", onHideoutRecipes)
  discard serve("/client/hideout/settings", onHideoutSettings)
  discard serve("/client/hideout/qte/list", onQteList)
  discard serve("/client/ragfair/find", onRagfairFind)
  discard serve("/client/ragfair/itemMarketPrice", onRagfairPrice)
  discard serve("/client/insurance/items/list/cost", onInsuranceCost)
  discard serve("/client/hideout/customization/offer/list",
                onHideoutCustomisation)
  # `StorePlayerOfferTaxAmount` -- the client asks the server to remember the
  # tax it just quoted, then lists the offer. This server prices a listing from
  # the offer itself, so there is nothing to remember and the answer is the one
  # the client checks for.
  discard serve("/client/ragfair/offerfees", onTrue)
  discard serve("/client/reports/ragfair/send", onNullData)

  # The menu's supporting cast
  discard serve("/client/notifier/channel/create", onNotifierChannel)
  discard servePrefix("/client/notifier/getwebsocket", onNotifierPoll)
  discard serve("/client/mail/dialog/list", onMailList)
  discard serve("/client/mail/dialog/info", onEmptyObject)
  discard serve("/client/mail/dialog/view", onMailView)
  discard serve("/client/mail/dialog/getAllAttachments", onMailAttachments)
  discard serve("/client/mail/dialog/read", onMailRead)
  discard serve("/client/mail/dialog/pin", onMailPin)
  discard serve("/client/mail/dialog/unpin", onMailUnpin)
  discard serve("/client/mail/dialog/remove", onMailRemove)

  # Bots
  discard serve("/client/game/bot/generate", onBotGenerate)
  # Prefix, not exact: both of these carry a query string
  # (`?location=`, `?type=&difficulty=`) and an exact route does
  # not match a url with one on the end.
  discard servePrefix("/client/game/bot/limit", onBotLimit)
  discard servePrefix("/client/game/bot/difficulty",
                      onBotDifficulty)
  discard serve("/client/friend/list", onFriendList)
  discard serve("/client/friend/request/list/inbox", onEmptyArray)
  discard serve("/client/friend/request/list/outbox", onEmptyArray)
  discard serve("/client/chatServer/list", onChatServerList)
  discard serve("/client/survey", onEmptyObject)
  discard serve("/client/survey/view", onNullData)
  discard serve("/client/survey/opinion", onNullData)
  discard serve("/client/prestige/list", onPrestigeList)
  discard serve("/client/putMetrics", onNullData)
  discard serve("/client/getMetrics", onEmptyObject)
  discard serve("/client/analytics/event-disabled", onNullData)
  discard serve("/client/repeatalbeQuests/activityPeriods", onActivityPeriods)
  # The client talks to the server about itself: crash notes, release notes and
  # its own log stream. Each is fire-and-forget and each retries when it 404s.
  discard serve("/client/log", onNullData)
  discard serve("/client/bsgLogging", onNullData)
  discard serve("/client/releaseNotes", onNullData)

  # Saved builds -- weapon presets, equipment loadouts, magazine templates.
  discard serve("/client/builds/list", onBuildsList)
  discard serve("/client/builds/weapon/save", onBuildWeapon)
  discard serve("/client/builds/equipment/save", onBuildEquipment)
  discard serve("/client/builds/magazine/save", onBuildMagazine)
  discard serve("/client/builds/delete", onBuildDelete)

proc onLoad(): Status =
  if side() != sideServer:
    info "the emulator is a server mod; nothing to do on this side"
    return Ok

  gEdition = setting("edition").asText("standard")
  gDefaultSide = setting("defaultSide").asText("Usec")
  gNowSeconds = setting("epochBase").asInt(1700000000)
  gStartingRoubles = setting("startingRoubles").asInt(500000)
  gInsurancePercent = setting("insurancePercent").asInt(10)
  gInsuranceHours = setting("insuranceReturnHours").asInt(24)
  gScavCooldownSeconds = setting("scavCooldownSeconds").asInt(900)
  # What `/client/game/bot/limit` answers for a map the database says nothing
  # about. It was a literal in the route; it is a default here, which is the
  # difference between a value somebody can change and one they cannot.
  gDefaultBotLimit = setting("defaultBotLimit").asInt(30)
  # Fence's standing per scav raid. The reference gives the requirement and not
  # the rate -- see the note at the foot of `emu/traders` for where the default
  # comes from and why it is a setting rather than a constant.
  gFenceKarmaExtract = setting("fenceKarmaOnScavExtract").asFloat(0.01)
  gFenceKarmaDeath = setting("fenceKarmaOnScavDeath").asFloat(0.0)
  # The inbox is bounded. Both are "off" at zero or below, for anyone who wants
  # the whole history -- see the header of `emu/mail`.
  configureMail(setting("mailKeepHours").asInt(72),
                setting("mailKeepCollected").asInt(1))
  configureMarket(setting("fleaSpreadPercent").asInt(20),
                  setting("fleaOfferHours").asInt(12),
                  setting("fleaMaxOffers").asInt(600),
                  setting("fleaSaleMinutes").asInt(30))

  if not storeReady():
    error "this host has no persistent store; profiles cannot be kept " &
          "(host api " & $hostApiSize() & " bytes, this mod expects " &
          $expectedApiSize() & ")"
    return ErrUnsupported

  # After the store check and before any route can hand out an id. A server that
  # cannot establish a fresh run number does not start: see `emu/ids` for the
  # profile corruption that came of guessing one from the clock.
  if not initIds():
    error "this server cannot issue unique item ids; refusing to start"
    return ErrUnsupported

  # The modules that can prove themselves without a database, a host or a
  # profile do it now, and this server does not start if one of them cannot.
  # See `emu/selfchecks` for what runs and why a failure is fatal rather than a
  # log line -- four of these checks existed and nothing called any of them,
  # which is how a check comes to be counted as coverage without being any.
  let selfFails = selfCheckFailures()

  # One route either way, and it is registered *before* the gate below decides
  # whether there will be any others.
  #
  # A mod that refuses to serve and a mod that is serving fine look identical
  # from outside -- every route 404s in the first case, and a caller cannot tell
  # that from a backend that has not finished starting, a mod that was never
  # selected, or a wrong port. The log says which, and nothing in a test reads
  # the log. So this answers on both paths: `{ok: true, failures: []}` when the
  # arithmetic held, and `{ok: false, failures: [...]}` naming every check that
  # did not when it refused. It is deliberately outside `/client/`, because it
  # is not part of the client's protocol and must never be mistaken for it.
  gSelfCheckFailures = selfFails
  if serve("/aowlspt/tarkov/selfcheck", onSelfCheck) != Ok:
    warn "no self-check route on this host: " & lastError()

  if selfFails.len > 0:
    for f in selfFails:
      error "self-check: " & f
    error "this build fails its own arithmetic; refusing to serve"
    error "the reason is readable at /aowlspt/tarkov/selfcheck, which is the " &
          "only route this mod registered"
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
