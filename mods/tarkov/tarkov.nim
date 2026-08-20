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
import aowlspt/settings # the F12 settings schema this emulator declares
import aowlspt/json
import emu/ids
import emu/profile
import emu/sessions
import emu/templates
import emu/traders
import emu/inventory
import emu/raid
import emu/questcond
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
import emu/metadata
import emu/post1

const
  ModGuid = "aowl.tarkov"
  ModVersion = "0.1.0"
  ServerName = "aowlspt"
  # The url the client reaches this backend on -- what `backend.json`'s
  # `backendUrl` hands the client. Several responses (game/mode's `backendUrl`,
  # game/config's per-service urls) echo it back so the client knows which
  # server to build its next request against. An EMPTY value here is not
  # harmless: the client feeds it straight into `new Uri(...)` and post-1.0
  # throws `Invalid URI: The hostname could not be parsed`, which surfaces far
  # away as a null-ref in `InitPreloaderUI`. No trailing slash -- the client's
  # host regex wants a bare host. Kept in sync with `backend.json` by hand;
  # loopback is the only address this server ever answers on.
  BackendUrl = "https://127.0.0.1"

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
var gRaidClock = unknownClock()
  ## The in-game clock the last `/client/raid/configuration` established, kept
  ## for `emu/questcond`'s `daytime` windows. Kept rather than dropped: the
  ## parse already existed and everything but the raid id used to be thrown
  ## away at the end of `onRaidConfiguration`, which is why twelve `Kills`
  ## conditions across eight quests could never be credited from the victim
  ## list. One raid at a time, like `gRaidId` beside it -- this server plays
  ## one player.
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

proc onMetadata(url, body, session: string): string =
  ## `/client/metadata` -- the very first thing post-1.0 `GameAssembly.dll` asks
  ## for, from inside `il2cpp_init`, before any session exists. The client sends
  ## `{"version":"<ver>","key":"<decimal>"}`; the answer is that version's
  ## section layout, shuffled so the client's own deshuffle (keyed by the subKey
  ## its `key` encodes) reproduces the raw layout. See `emu/metadata`.
  ##
  ## This answer is NOT the standard `/client/*` envelope, and it must not be
  ## fabricated: a wrong layout does not fail here, it fails much later and much
  ## more confusingly when the client tries to decrypt its metadata with it. So
  ## a missing blob is logged, by version, and answered with an error envelope.
  ##
  ## The framing (zlib vs identity) is left to the backend, exactly as for every
  ## other route -- there is no encoding special-case here. The backend deflates
  ## by default and sends the body raw only when the request carried
  ## `Accept-Encoding: identity` (see `backend/aowlbackend.nim`). So a client
  ## that cannot inflate this early answer gets a raw one *iff* it asks with that
  ## header, which is the same contract every other route already relies on; this
  ## route adds no assumption of its own about how the il2cpp_init client frames.
  inc gRequests
  info("client/metadata HIT: body.len=" & $body.len & " session=" & session)
  let version = field(body, "version").asText("")
  let keyField = field(body, "key")
  let keyText = if keyField.isText: keyField.asText("") else: keyField.raw
  let requestKey = parseDecU32(keyText)

  let blob = loadBlob(version)
  if not blob.ok:
    error("client/metadata: no blob for version '" & version &
          "' -- install mods/tarkov/data/metadata/" & version &
          ".json with tools/metablob.py (nothing is fabricated here)")
    return metaError("no metadata blob for version " & version)

  var subKey = -1
  result = answerMetadata(blob, requestKey, subKey)
  if subKey < 0:
    error("client/metadata: could not recover a subKey for version '" &
          version & "' from key '" & keyText &
          "' (internalKey " & $blob.internalKey &
          ") -- the installed blob may be for a different build")

proc onGameConfig(url, body, session: string): string =
  ## What the client reads before anything else: who it is talking to, and the
  ## backend urls it should use for the rest of the session.
  let p = currentProfile(session)
  var backend = obj()
  put(backend, "Main", BackendUrl)
  put(backend, "Trading", BackendUrl)
  put(backend, "Messaging", BackendUrl)
  put(backend, "RagFair", BackendUrl)
  # `Lobby` and `Static` are read by the client too (matchmaking lobby and the
  # asset CDN). Point both at this backend so nothing reaches for the real
  # BSG hosts; the client never validates that they answer.
  put(backend, "Lobby", BackendUrl)
  put(backend, "Static", BackendUrl)
  var o = obj()
  put(o, "aid", if p.ok: p.field("aid").asInt(0) else: 0)
  put(o, "lang", "en")
  put(o, "languages", raw(languages()))
  put(o, "ndid", session)
  put(o, "ndaFree", false)
  put(o, "taxonomy", 341)
  put(o, "activeProfileId", p.id)
  put(o, "backend", backend)
  put(o, "useProtobuf", false)
  put(o, "utc_time", nowSeconds())
  put(o, "totalInGame", 0)
  put(o, "reportAvailable", false)
  put(o, "twitchEventMember", false)
  # Post-1.0 game-mode / ownership fields. The client's GameConfigResponse reads
  # each of these by name to decide which mode tiles are shown and whether the
  # account is fully synced. `purchasedGames`/`availableGameModes` are small
  # fixed dicts it indexes; a missing key here reads as "not owned" at best and
  # a null-deref at worst on the mode-select screen.
  put(o, "sessionMode", "regular")
  var purchased = obj()
  put(purchased, "eft", true)
  put(purchased, "arena", false)
  put(o, "purchasedGames", purchased)
  put(o, "isGameSynced", true)
  put(o, "linkedPlatforms", raw("[]"))
  var modes = obj()
  put(modes, "regular", true)
  put(modes, "pve", false)
  put(modes, "pvp-season", true)
  put(o, "availableGameModes", modes)
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
  # Deduplicate by id. `allProfileIds` reads the store directory, and anything
  # that parses to a profile there -- a stray backup a careless hand left beside
  # the real file, a half-written temp -- would otherwise be listed as a second
  # profile with the same `_id`. The client's own profile prep does a
  # `SingleOrDefault` over this list and throws "Sequence contains more than one
  # matching element" on the duplicate, which reads as a menu crash far from its
  # cause. One entry per id, whatever the store dir happens to hold.
  var seenIds: seq[string] = @[]
  for id in all:
    if id in seenIds:
      continue
    seenIds.add id
    let p = loadProfile(id)
    if p.ok:
      a.add raw(p.text)
      # The scav goes straight after its PMC. The client reads the pair in that
      # order and shows the second as the scav character.
      let sc = scavText(p, nowSeconds())
      if sc.len > 0:
        a.add raw(sc)
  result = envelope(a)

proc sideToInt(side: string): int =
  ## `EFT.EPlayerSide` on the wire is an int, not the profile's "Usec"/"Bear"
  ## string: Usec=1, Bear=2, Savage=4.
  case side
  of "Bear": 2
  of "Savage": 4
  else: 1

proc characterSlot(p: Profile): JsonObject =
  ## One `EFT.CharacterSelectionProfileData` value for the post-1.0
  ## character-select screen. The wire keys are NOT the C# field names -- they
  ## come from the client's `[JsonProperty]` attributes (decoded from the
  ## decrypted metadata): `uid` (the profile id, and the gate: `get_HasProfile`
  ## is `status==2 && uid != ""`), `status` (the `ECharacterSelectionProfileStatus`
  ## int, 2 = Available), `side` (`EPlayerSide` int), and camelCase for the rest.
  ## `PlayerVisualRepresentation` (PascalCase) is the model descriptor; it is
  ## null-guarded client-side, so a wrong Equipment costs the 3D doll, not the
  ## slot.
  var o = obj()
  put(o, "uid", p.id)
  # `status` is a STRING through EGameMode's sibling `EnumConverter`, NOT an int:
  # ECharacterSelectionProfileStatus maps Available->"available" (Locked->"locked",
  # Empty->"empty", InRaid->"in_raid"). An int `2` has no mapping, so it defaulted
  # to Locked(0) and the slot stayed un-clickable no matter the field casing.
  put(o, "status", "available")
  put(o, "side", sideToInt(p.side))
  put(o, "nickname", p.nickname)
  put(o, "lowerNickname", p.field("Info.LowerNickname").asText(toLowerAscii(p.nickname)))
  put(o, "nicknamePref", "")
  put(o, "level", p.level)
  put(o, "prestigeLevel", 0)
  put(o, "memberCategory", p.field("Info.MemberCategory").asInt(0))
  put(o, "accountType", p.field("Info.AccountType").asInt(0))
  put(o, "aid", p.field("aid").asInt(0))
  put(o, "gameVersion", p.field("Info.GameVersion").asText("live"))
  # PlayerVisualRepresentation is left null for now: a throw ANYWHERE in the
  # value (e.g. a FlatItem the Equipment deserialiser rejects) aborts the whole
  # dictionary deserialize and re-locks the slot. `get_HasProfile` only needs
  # `status==2` + non-empty `uid`, and `OnJsonDeserialize` builds the 3D model
  # only when the PVR is present (null-guarded), so a null PVR is a selectable
  # character without a doll -- exactly the safe first step. The model gets
  # wired back once the slot is confirmed binding.
  put(o, "PlayerVisualRepresentation", jnull())
  put(o, "SeasonalInfo", jnull())
  put(o, "unlockedProductionRecipe", raw("[]"))
  put(o, "unlockedRules", raw("[]"))
  put(o, "unlockedTraderDialogues", raw("[]"))
  put(o, "unlockedTraders", raw("[]"))
  result = o

proc onProfilesV2(url, body, session: string): string =
  ## `/v2/client/game/profiles/` -- the character-select bootstrap. Post-1.0
  ## deserialises `data` into `Dictionary<EGameMode, CharacterSelectionProfileData>`
  ## and drives `RunCharacterSelectionFlow` from it -- NOT the flat profile array
  ## `/client/game/profile/list` returns (a JSON array deserialises into an empty
  ## dictionary, which is the blank character screen). The key is the game-mode
  ## int: "0" = Regular (the `_pvpSlotView`), "1" = Pve, "2" = PvpSeason. This
  ## server has one regular profile, so it fills slot "0"; the other slots stay
  ## empty (a "create a character" prompt), which is correct.
  var modes = obj()
  let all = allProfileIds()
  for id in all:
    let p = loadProfile(id)
    if p.ok:
      # EGameMode's custom `EnumConverter` maps values to attribute wire strings
      # ("regular"/"pve"/"pvp-season"), NOT the enum name or number -- and a key
      # not in that map THROWS, aborting the whole dictionary and re-locking every
      # slot (which is why "0" and "Regular" both failed). "regular" = the PvP
      # slot; this server's one profile fills it.
      put(modes, "regular", characterSlot(p))
      break
  # Enveloped: a bare dictionary renders NOTHING (the client wraps this in
  # JsonResponse<T> and reads `.data`), while the envelope renders the Regular
  # slot. The dict key "regular" binds that slot to the mode; the value's own
  # field casing is what remains (see characterSlot).
  result = envelope(modes)

proc onShopStatus(url, body, session: string): string =
  ## `/v2/client/shop/status` -- the in-game-store account summary. The client
  ## reads `aid`, `labels` and `tarcoins` by name (capture seq 501); an empty
  ## object is a KeyNotFound on the store screen. There is no store here, so the
  ## wallet is empty and there are no labels, but the shape is the real one.
  let p = currentProfile(session)
  var o = obj()
  put(o, "aid", if p.ok: p.field("aid").asInt(0) else: 0)
  put(o, "labels", raw("[]"))
  put(o, "tarcoins", 0)
  result = envelope(o)

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

proc onVoiceChange(url, body, session: string): string =
  ## `ProfileChangeVoice`. Both spellings of the one property are read: the
  ## reference dump names it `Voice` and every other body this client sends
  ## arrives camel-cased.
  inc gRequests
  var voice = field(body, "voice").asText("")
  if voice.len == 0:
    voice = field(body, "Voice").asText("")
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  var problem = ""
  if not applyVoice(p, voice, problem):
    return failure(1, if problem.len > 0: problem
                      else: "that voice is already set")
  if not saveProfile(p):
    return failure(1, "could not save the profile")
  info p.nickname & " now speaks as " &
       p.field("Info.Voice").asText("")
  result = envelope(objOf("status", "ok"))

# ---------------------------------------------------------------------------
# The launcher's profile bootstrap
# ---------------------------------------------------------------------------
#
# Four routes that exist so a **profile can be chosen before the game starts**.
#
# The client is given its session on the command line -- `-token=<24 hex>` --
# and carries it as `Cookie: PHPSESSID=<token>` on every request after that.
# So something has to decide which profile is being played *before* a single
# `/client/` route is ever called, and nothing in the client's own protocol can
# do it: every one of those routes already needs the answer.
#
# **Why these are not `/launcher/*`.** SPT has a launcher API and this is not
# it. Its 4.1 shape is in `reference/spt-4.1-surface.txt` as
# `LauncherV2Callbacks` -- `Register`, `Login`, `Profiles`, `Profile`, `Remove`,
# `Wipe`, `Types`, `Mods`, `ModPages`, `Ping`, `CompatibleVersion` -- keyed on a
# **username** that has no counterpart here, and the dump carries no route urls
# at all, so the paths would be guesses. Wearing another server's url with a
# different body underneath is worse than an honest name: it invites a caller
# that speaks the real protocol and fails on the third field. Nothing in this
# tree speaks SPT's launcher API and SPT's own launcher needs a great deal more
# than profiles from a server before it will drive one, so compatibility here
# would be a claim rather than a feature. These sit beside
# `/aowlspt/tarkov/selfcheck` instead, in this server's own namespace, for the
# same reason that one does: it is not part of the client's protocol and must
# never be mistaken for it.
#
# **The token is the profile id.** Not a third identifier mapped to one -- the
# session is bound to itself here, `bindSession(id, id)`, so a launcher that
# holds a profile id holds everything it needs and there is no second thing to
# keep in step across a restart. `emu/sessions` persists the binding, which is
# what makes a profile created before the first launch still be the profile the
# client is playing after the server has been restarted under it.
#
# **No envelope.** These answer `{"ok":true,...}` or `{"ok":false,"error":...}`,
# not the client's `{err, errmsg, data}` -- see `onSelfCheck` for why a route
# outside `/client/` must not look like one inside it.

proc launcherReply(o: JsonObject): string = text(done(o))

proc launcherRefusal(message: string): string =
  ## A refusal the launcher can put in front of a person. `ok:false` rather
  ## than a 4xx: the backend's status codes belong to the pipeline, and a mod
  ## that could only refuse by returning a 200 with a bad body would be a mod
  ## whose failures read as successes.
  var o = obj()
  put(o, "ok", false)
  put(o, "error", message)
  result = launcherReply(o)

proc launcherProfile(id: string): JsonObject =
  ## One row of the launcher's profile list.
  ##
  ## `readable` is the field worth explaining: a profile whose document is on
  ## disk and cannot be parsed still has an id, and a list that silently omitted
  ## it would tell a player their character is gone. It is listed, marked, and
  ## left for them to choose against -- which is what SPT's own `MiniProfile`
  ## does with `InvalidOrUnloadableProfile`.
  let p = loadProfile(id)
  var o = obj()
  put(o, "id", id)
  put(o, "token", id)
  put(o, "readable", p.ok)
  put(o, "nickname", p.nickname)
  put(o, "side", p.side)
  put(o, "level", p.level)
  put(o, "experience", p.experience)
  put(o, "voice", p.field("Info.Voice").asText(""))
  put(o, "edition", p.field("Info.GameVersion").asText(""))
  put(o, "registered", p.field("Info.RegistrationDate").asInt(0))
  result = o

proc onLauncherPing(url, body, session: string): string =
  ## Is there a server here, and does it have anything to play?
  ##
  ## Separate from `/aowlspt/tarkov/selfcheck`, which answers whether this
  ## build's arithmetic held. A launcher wants a different question answered --
  ## "can I offer this person a profile" -- and the two have different answers
  ## on a server that loaded fine and has no profiles yet.
  inc gRequests
  var o = obj()
  put(o, "ok", true)
  put(o, "server", ServerName)
  put(o, "version", ModVersion)
  put(o, "edition", gEdition)
  put(o, "defaultSide", gDefaultSide)
  put(o, "profiles", allProfileIds().len)
  result = launcherReply(o)

proc onLauncherProfiles(url, body, session: string): string =
  ## Every profile, as much of each as a launcher can draw a row from. An empty
  ## list is the first-run answer and is not a failure: `ok` stays true.
  inc gRequests
  var a = arr()
  let all = allProfileIds()
  for id in all:
    a.add launcherProfile(id)
  var o = obj()
  put(o, "ok", true)
  put(o, "profiles", a)
  result = launcherReply(o)

proc onLauncherCreate(url, body, session: string): string =
  ## A new PMC, made before the game is running, and the token to launch it
  ## with.
  ##
  ## The same `createProfile` the client's own character screen goes through --
  ## deliberately, because two ways of building a profile is two profile shapes
  ## and only one of them gets fixed when the client changes.
  ##
  ## The nickname floor is three characters, matching
  ## `/client/game/profile/nickname/validate`: a launcher that let a two-letter
  ## name through would create a profile the client then refuses to rename.
  inc gRequests
  let nickname = field(body, "nickname").asText("")
  var sideName = field(body, "side").asText(gDefaultSide)
  let voice = field(body, "voice").asText("")
  var edition = field(body, "edition").asText(gEdition)
  if nickname.len < 3:
    return launcherRefusal("a profile needs a nickname of at least three " &
                           "characters")
  if nicknameTaken(nickname):
    return launcherRefusal("that nickname is taken")
  if sideName != "Bear" and sideName != "Usec":
    sideName = gDefaultSide
  if edition.len == 0:
    edition = gEdition
  var p = createProfile(nickname, sideName, edition, nowSeconds(),
                        gStartingRoubles)
  if not p.ok:
    return launcherRefusal("could not save the new profile: " & lastError())
  # The voice is optional and its failure is not. `applyVoice` checks the id
  # against the real customization table, which a server started without a
  # database does not have -- and refusing the whole profile because the voice
  # could not be looked up would make a launcher that offers voices unable to
  # create a profile at all. The character already has its side's default.
  if voice.len > 0:
    var problem = ""
    if applyVoice(p, voice, problem):
      if not saveProfile(p):
        return launcherRefusal("could not save the profile's voice")
    elif problem.len > 0:
      warn "the launcher asked for voice " & voice & ": " & problem
  # Bound to itself, which is what makes the returned token enough on its own.
  bindSession(p.id, p.id)
  success "the launcher created profile " & p.id & " (" & nickname & ", " &
          sideName & ")"
  discard broadcast("tarkov.profile.created", objOf("id", p.id))
  var o = obj()
  put(o, "ok", true)
  put(o, "token", p.id)
  put(o, "profile", launcherProfile(p.id))
  result = launcherReply(o)

proc onLauncherSelect(url, body, session: string): string =
  ## The token for a profile that already exists, and the binding that makes it
  ## work.
  ##
  ## A launcher could pass a profile id straight to `-token` without calling
  ## this, and for a profile this route or `onLauncherCreate` made it would
  ## work -- the binding is already there. It would *not* work for one the
  ## client's own character screen created, whose session is whatever id that
  ## run was launched with. So the launcher calls this and does not have to know
  ## which kind it is holding.
  inc gRequests
  var id = field(body, "id").asText("")
  if id.len == 0:
    id = field(body, "token").asText("")
  if id.len == 0:
    return launcherRefusal("that request named no profile")
  if not isMongoId(id):
    return launcherRefusal("that is not a profile id: " & id)
  let p = loadProfile(id)
  if not p.ok:
    return launcherRefusal("no such profile: " & id)
  bindSession(id, id)
  info "the launcher selected profile " & id & " (" & p.nickname & ")"
  var o = obj()
  put(o, "ok", true)
  put(o, "token", id)
  put(o, "profile", launcherProfile(id))
  result = launcherReply(o)

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
  # `[]`, not `{}`. BSG sends an array here, and this rides on the response to
  # every single inventory action, so the wrong container type is wrong
  # thousands of times a session rather than once.
  put(changes, "improvements", arr())
  put(changes, "skills", skills)
  put(changes, "health", raw(p.field("Health").raw()))
  # The real trader standings, so a quest reward that moved one is visible
  # without a reload.
  put(changes, "traderRelations", raw(p.field("TradersInfo").raw()))

  # The rest of what the real backend puts on *every* item-event response. They
  # were missing, and while a lenient deserialiser fills a missing array with an
  # empty one, `moneyTransferLimitData` is not an array: post-1.0's trade-confirm
  # handler reads it to redraw the money-transfer-limit gauge after a purchase,
  # and a null there is a NullReference inside the apply -- which surfaces as a
  # buy that spins forever, because the operation the button awaits never
  # completes. Sent with safe, faithful defaults (shapes taken from a real
  # captured buy) so the apply has everything it reaches for.
  put(changes, "changedHideoutStashes", arr())
  put(changes, "repeatableQuests", arr())
  put(changes, "recipeUnlocked", arr())
  put(changes, "completableItems", arr())
  put(changes, "readQuestData", arr())
  put(changes, "newQuestNotes", arr())
  put(changes, "variableValues", arr())
  put(changes, "seasonalRewards", arr())
  put(changes, "battlePassUniversalDocumentBalance", jnull())
  var moneyLimit = obj()
  put(moneyLimit, "nextResetTime", nowSeconds() + 86400)
  put(moneyLimit, "remainingLimit", 1000000)
  put(moneyLimit, "totalLimit", 1000000)
  put(moneyLimit, "resetInterval", 86400)
  put(changes, "moneyTransferLimitData", moneyLimit)

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
  ## An array, not the id-keyed object the database stores. See
  ## `emu/templates.questList`.
  envelope(raw(questList()))
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
  # Prefer the real post-1.0 locale (the decoded client capture, ~33k keys) when
  # it is deployed: SPT's pre-1.0 table is missing most post-1.0 UI strings, so
  # without it the client shows raw key paths -- map names as `Icebreaker`,
  # settings hovers as `Settings/Graphics/PostFxOff`, and so on. The SPT table
  # remains the fallback and the source for the mail this server composes.
  let post1Locale = post1Table("locale_" & (if lang.len > 0: lang else: "en"))
  if post1Locale.len > 0:
    return envelope(raw(post1Locale))
  result = envelope(raw(locale(if lang.len > 0: lang else: "en")))

proc onMenuLocale(url, body, session: string): string =
  ## Post-1.0 deserialises this `data` into `EFT.BackendMenuLocale`, whose sole
  ## field is `menu`; `ConvertToLocale` then reads `this.menu`. A flat map at
  ## `data` leaves `menu` null and the client null-refs in `ConvertToLocale`
  ## (surfacing far away as a preloader-UI crash), so the map is wrapped under
  ## `menu`. Pre-1.0 put the map straight on `data`; this is the post-1.0 shape.
  let lang = pathAfter(url, "/client/menu/locale/")
  let post1Menu = post1Table("menulocale_" & (if lang.len > 0: lang else: "en"))
  if post1Menu.len > 0:
    return envelope(objOf("menu", raw(post1Menu)))
  result = envelope(objOf("menu", raw(menuLocale(if lang.len > 0: lang else: "en"))))

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

proc onLibraries(url, body, session: string): string =
  ## `/client/libraries` -- a native early-bootstrap POST (its URL is in
  ## GameAssembly, not the managed metadata, like `/client/metadata`). The
  ## client uploads a ~30 KB manifest of its own libraries and BSG replies with
  ## a BARE `{}` -- not the `{err,data}` envelope. A wrapped answer leaves the
  ## client's native parser waiting and the main thread hangs at the loading
  ## screen. Verified against a real capture: body is exactly `{}`.
  inc gRequests
  result = "{}"

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
  # The real post-1.0 response is a bare `[]` (capture seq for
  # repeatalbeQuests/activityPeriods), and our SPT-shaped generated periods
  # (changeCost/changeStandingCost/freeChanges) do NOT deserialise on the
  # post-1.0 client -- it throws HTTPParsingResponseException, which cascades
  # into a NullReferenceException in MainMenuShowOperation and the menu
  # foreground never builds. Empty until the post-1.0 repeatable-quest shape is
  # rebuilt from the corpus (backlog).
  var p = currentProfile(session)
  discard p
  result = envelope("[]")

proc onEmptyArray(url, body, session: string): string =
  inc gRequests
  result = envelope(emptyArray())

proc onNullData(url, body, session: string): string =
  inc gRequests
  result = envelopeNull()

proc onOkStatus(url, body, session: string): string =
  inc gRequests
  result = envelope(objOf("status", "ok"))

proc onBattlePassActive(url, body, session: string): string =
  ## `/client/battle-pass/active` -- an OBJECT `{battlePasses:[...]}`, not null.
  ## No active battle pass -> empty list. Null data risks a deref on the client.
  inc gRequests
  result = envelope(objOf("battlePasses", arr()))

proc onEndingList(url, body, session: string): string =
  ## `/client/ending/list` -- an OBJECT `{elements:[...]}` of raid-ending
  ## descriptors, not a 404. Empty elements is a valid "no custom endings".
  inc gRequests
  result = envelope(objOf("elements", arr()))

proc onDialogue(url, body, session: string): string =
  ## `/client/dialogue` -- deserialised into `EFT.Dialogs.TraderDialogsDTO`, an
  ## OBJECT with an `elements` array (the trader dialog trees), NOT a bare array.
  ## The real answer is ~2.5 MB of every trader's dialog; an empty `elements` is
  ## a valid "no trader conversations yet", which is correct for a fresh profile
  ## and, crucially, deserialises without throwing (a bare array threw
  ## HTTPParsingResponseException and looped the whole post-select load).
  inc gRequests
  result = envelope(objOf("elements", arr()))

proc onSeasonalPerks(url, body, session: string): string =
  ## `/client/seasonal-perks/list` -- deserialised into
  ## `EFT.SeasonalPerks.SeasonalPerksData`, which is an OBJECT with two perk
  ## lists, not an array. Empty lists mean no seasonal modifiers, which is the
  ## correct answer outside a seasonal event.
  ##
  ## The keys are `common` and `personal`. They used to be `commonPerks` and
  ## `personalPerks`, derived from the C# backing-field names `_commonPerks` and
  ## `_personalPerks` -- a reasonable guess, and wrong. Four captures of this
  ## route agree on the short names (seq 044, 079, 236, 430), which is what a
  ## `[JsonProperty]` on the field does to a backing-field name.
  inc gRequests
  var o = obj()
  put(o, "common", arr())
  put(o, "personal", arr())
  result = envelope(o)

proc onSeasonActive(url, body, session: string): string =
  ## `/client/season/active` -- whether a seasonal event (Halloween, New Year)
  ## is running. None, so an empty object.
  inc gRequests
  result = envelope(emptyObject())

proc onTokenIssue(url, body, session: string): string =
  ## `/client/game/token/issue` -- issues a session token the client keeps for
  ## the rest of the session. There is no auth here (see `onProfileSelect`), so
  ## echoing the session id back as the token is enough for the client to hold.
  inc gRequests
  result = envelope(objOf("token", session))

proc onFriendList(url, body, session: string): string =
  ## `GetFriendListDataResponse` is an **object** of three lists, not a list.
  ## This answered `[]` for as long as it existed, which the client parses
  ## without complaint and then indexes `Friends` on.
  inc gRequests
  var o = obj()
  put(o, "Friends", arr())
  put(o, "Ignore", arr())
  put(o, "InIgnoreList", arr())
  # Six keys, not three. The other three are post-1.0 additions (seq 124, 249,
  # 442) and an absent one is a null the client indexes, which is the same
  # failure the first three were added to fix.
  put(o, "steamFriendList", arr())
  put(o, "incomingRequestList", arr())
  put(o, "sentRequestList", arr())
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
  ## What customisation the profile owns: heads, voices, gestures, poses,
  ## suites, dog tags and hideout decoration.
  ##
  ## An **array** of `{id, source, type}`, not an object with a `suites` list.
  ## The real backend answers 49 entries for a fresh account, every one of them
  ## `source: "default"` (capture seq 086 and 094), and later 62 once a
  ## preorder edition adds its own 13 with `source: "preorder"`. The object
  ## this used to send deserialises to nothing at all, so the character screen
  ## drew whatever it drew for an empty wardrobe.
  ##
  ## The 49 defaults are served from `data/post1/customizationstorage.json`
  ## because they are not derivable from the database this server has: SPT's
  ## `templates.customization` says what each id *is*, not which of them an
  ## account starts owning, and the split between the two is a property of the
  ## account rather than of the item.
  ##
  ## What this does **not** do is grow. Everything a player buys or unlocks
  ## should appear here and does not, because nothing tracks it yet -- so this
  ## is the starting wardrobe, permanently. That is a smaller lie than the
  ## previous one and it is still a lie; it is in the backlog rather than in a
  ## comment nobody reads.
  inc gRequests
  let owned = post1Table("customizationstorage")
  if owned.len == 0:
    return failure(1, "the post-1.0 table 'customizationstorage' is not " &
                      "installed, so this server cannot say what the profile " &
                      "is wearing")
  result = envelope(raw(owned))

proc onGameMode(url, body, session: string): string =
  ## `GameModeResponse`. Asked at boot, before the profile list, and this server
  ## has one mode.
  var o = obj()
  put(o, "gameMode", "regular")
  put(o, "backendUrl", BackendUrl)
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

# ---------------------------------------------------------------------------
# Post-1.0 static tables
# ---------------------------------------------------------------------------
#
# Seven routes the client asks for on every menu load that have no pre-1.0
# equivalent, so the SPT-derived database cannot answer them and they were not
# served at all. A 404 here is not harmless: the client retries and then sits
# on the loading screen. See `emu/post1` and `data/post1/README.md`.
#
# A missing table is a **refusal**, not an empty answer. An empty chapter list
# and an absent one look the same to the client, and only one of them is true;
# answering `[]` would turn a broken install into a game that quietly has no
# main quests.

proc post1Route(name, what: string): string =
  ## A post-1.0 list route backed by an optional installed table. When the table
  ## is absent the answer is an empty SUCCESS, not a failure: these routes
  ## (subtitle tracks, tapes, variable groups, main-quest lists, ...) are not
  ## essential to reach the menu, and the client RETRIES an `err:1` envelope
  ## forever -- which stalls the post-character-select load. An empty array is a
  ## valid "nothing here" for every one of them.
  let text = post1Table(name)
  if text.len == 0:
    return envelope(emptyArray())
  result = envelope(raw(text))

proc onMainQuestsList(url, body, session: string): string =
  inc gRequests
  result = post1Route("mainquests", "the main quest chapters")

proc onMainQuestNotesList(url, body, session: string): string =
  inc gRequests
  result = post1Route("mainquestnotes", "the main quest notes")

proc onVariableGroup(url, body, session: string): string =
  inc gRequests
  result = post1Route("variablegroups", "the variable groups")

proc onTapeList(url, body, session: string): string =
  inc gRequests
  result = post1Route("tapes", "the tape list")

proc onSubtitleTrackList(url, body, session: string): string =
  inc gRequests
  result = post1Route("subtitletracks", "the subtitle tracks")

proc onQuestChains(url, body, session: string): string =
  inc gRequests
  result = post1Route("questchains", "the quest chains")

proc onMetricsConfig(url, body, session: string): string =
  inc gRequests
  result = post1Route("metricsconfig", "the metrics configuration")

proc onTutorGameCheck(url, body, session: string): string =
  ## Whether to launch the tutorial. Answered `false`: this server has no
  ## tutorial raid to run, and the real backend's `true` sends the client into
  ## one -- `match/local/start` with `mode: "TUTORIAL"` -- which is a raid this
  ## emulator would have to be able to finish.
  inc gRequests
  result = envelope(objOf("launchTutorGame", raw("false")))

proc onCancelAllInvites(url, body, session: string): string =
  ## `/client/match/group/invite/cancel-all`. There are no groups here, so
  ## there is nothing to cancel and that is a success rather than a refusal --
  ## the client sends this on the way into a raid and a failure would read as
  ## a raid it could not enter. The wire answer is the literal `true`
  ## (capture seq 504), not null.
  inc gRequests
  result = envelope(raw("true"))

proc onQuestComplete(url, body, session: string): string =
  ## `POST /client/quest/complete` -- post-1.0's own hand-in route.
  ##
  ## Pre-1.0 completed a quest only through the item-event batch, as a
  ## `QuestComplete` action carrying `qid`. Post-1.0 also has this, a route of
  ## its own with a different spelling: the body is `{"questId": "..."}`
  ## (capture seq 202) and the answer is `{quests, questsStatus}` -- the quest
  ## list as it now stands, in the same element shape `/client/quest/list`
  ## uses, plus a status list. It fires during the raid-exit transition, so a
  ## 404 here loses a completion at the moment it is earned.
  ##
  ## The spelling is the whole trap. `applyQuestOnProfile` reads `qid`, so
  ## handing it this body unchanged names no quest and refuses, which is the
  ## same shape of bug as reading `exit` where the client sends
  ## `results.result`. It is renamed once, here, rather than teaching the quest
  ## code a second name for the same thing.
  inc gRequests
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")
  let questId = field(body, "questId").asText("")
  if questId.len == 0:
    return failure(1, "quest/complete named no quest")

  var gained = 0
  var problem = ""
  var note1 = ""
  # The profile-aware entry point, for the reason the item-event path uses it:
  # a version that only sees the quest array cannot check a level, a trader
  # standing or what was actually handed over, and a quest that pays out for
  # nothing is worse than one that will not complete.
  # Built and reparsed rather than string-spliced: `questId` comes off the
  # wire, and the builder is what knows how to escape it.
  let questBody = whole(done(objOf("qid", questId)).text)
  if applyQuestOnProfile(p, qaComplete, questBody,
                         nowSeconds(), gained, problem, note1):
    if gained > 0:
      addExperience(p, gained)
    if not saveProfile(p):
      return failure(1, "could not save the profile after completing " & questId)
    success "quest completed: " & questId
  if problem.len > 0:
    warn "quest/complete refused " & questId & ": " & problem
    return failure(1, problem)
  if note1.len > 0:
    warn "quest/complete: " & note1

  var o = obj()
  # The array form, like `/client/quest/list` -- the real backend's answer here
  # is a list of quest objects (13 of them at capture seq 202), the same element
  # shape that route uses. It sends the quests that are now relevant rather than
  # all of them; sending all of them is a superset and the client filters by
  # status, which is an approximation and is written down as one.
  put(o, "quests", raw(questList()))
  # Empty, and honestly so. `questsStatus` was empty in the capture too, and
  # this server has nothing to put in it that it has not already written into
  # the profile's own `Quests` array.
  put(o, "questsStatus", arr())
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
  # `currencyCourses` is keyed by the currency's own item TEMPLATE ID, not by a
  # name like "usd" (capture seq 317): the client looks the rate up by the tpl
  # of the currency an offer is priced in. Keying it "usd"/"eur" meant every
  # lookup missed and the flea comparison fell back to a rouble rate of 1. The
  # handbook is where the game keeps the rate; a currency it does not price is
  # left out rather than given an invented one. Roubles are the unit: 1.
  const RoublesTpl = "5449016a4bdc2d6f028b456f"
  put(courses, RoublesTpl, 1)
  let usd = handbookPrice(Dollars)
  if usd > 0: put(courses, Dollars, usd)
  let eur = handbookPrice(Euros)
  if eur > 0: put(courses, Euros, eur)
  # GP coin (the collector currency); included when the handbook prices it.
  const GpCoin = "5d235b4d86f7742e017bc88a"
  let gp = handbookPrice(GpCoin)
  if gp > 0: put(courses, GpCoin, gp)
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
  # From the request rather than from the echo: `raidConfiguration` answers
  # with the five members the client needs back and the clock is not among
  # them.
  gRaidClock = raidClock(body)
  # The map, remembered against the session. `raid/configuration` and
  # `match/local/start` are the only two places the client ever names it -- the
  # raid result does not -- so whichever of them arrives, the map is kept. See
  # `emu/sessions.enterRaid`.
  let configured = field(cfg, "location").asText("")
  if configured.len > 0:
    enterRaid(session, configured, field(body, "raidMode").asText(""))
  info "raid configured: " & field(cfg, "location").asText("?") & " as " &
       field(cfg, "side").asText("?")
  discard broadcast("tarkov.raid.configured", raw(cfg))
  result = envelopeNull()

proc onLocalLoot(url, body, session: string): string =
  inc gRequests
  let loc = field(body, "locationId").asText("factory4_day")
  result = envelope(raw(localLoot(loc, nowSeconds(), gRaidId)))

proc onMatchStart(url, body, session: string): string =
  ## Entering a raid. The response carries the **whole map**.
  ##
  ## This used to answer `{serverId, serverSettings, status, notifier}` with an
  ## `aiAmount`/`aiDifficulty` settings object, which is the pre-1.0 shape.
  ## What the post-1.0 backend really sends (capture seq 158, 18,769 bytes on
  ## the wire) is
  ##
  ##     {serverId, serverSettings, profile, locationLoot, transition,
  ##      excludedBosses}
  ##
  ## with `locationLoot` the complete location document -- spawn points, exits,
  ## waves, boss spawns, loot -- and `serverSettings` a pair of
  ## `TraderServerSettings` and `BTRServerSettings` that has nothing in common
  ## with the old one. `status` and `notifier` are not sent at all.
  ##
  ## That is the answer to a question this repository had open: post-1.0 never
  ## calls `/client/location/getLocalloot`, which is why that route is served
  ## and never exercised. The loot comes back here instead, once, and the
  ## client does not ask again.
  ##
  ## **Modelled on a tutorial raid**, because that is the only `match/local/
  ## start` in the capture. The two settings blocks are static game config and
  ## are very unlikely to differ per mode, but that is reasoning rather than
  ## evidence and it is written down here rather than assumed away.
  inc gRequests
  # The seven fields the client sends were read by nothing at all before, which
  # is how the map came to be unknown at the end of the raid. Real body:
  # `{serverId, location, timeVariant, mode, playerSide, transitionType,
  # transition}`.
  let startLocation = field(body, "location").asText("")
  let startMode = field(body, "mode").asText("")
  if startLocation.len > 0:
    enterRaid(session, startLocation, startMode)

  # The per-raid skill counter resets here rather than at the end: the raid the
  # player is entering is the one whose gains are capped.
  var starting = currentProfile(session)
  if starting.ok and startRaidSkills(starting):
    discard saveProfile(starting)

  # The id `raid/configuration` set, when there is one. Not a fresh id: it is
  # the seed `localLoot` lays the map out from, so minting a new one here would
  # give the raid a different map from the one the configuration screen just
  # described, and would do it only sometimes -- whenever the two happened to
  # be called in the other order.
  let raidId = if gRaidId.len > 0: gRaidId else: newId()
  var o = obj()
  put(o, "serverId", raidId)
  let settings = post1Table("serversettings")
  if settings.len > 0:
    put(o, "serverSettings", raw(settings))
  else:
    # Refused rather than faked. The BTR settings alone are fifteen tuned
    # numbers; an empty object here is a client that spawns a BTR with a move
    # speed of zero, which is a stranger bug than a missing raid.
    return failure(1, "the post-1.0 table 'serversettings' is not installed, " &
                      "so a raid cannot be started")
  # `null`, exactly as the real backend sends it. The client already has the
  # profile; this member is for a transit continuation, which this server does
  # not do.
  put(o, "profile", jnull())
  if startLocation.len > 0:
    put(o, "locationLoot",
        raw(localLoot(startLocation, nowSeconds(), raidId)))
  else:
    warn "match/local/start named no location, so the raid gets no map"
  var transition = obj()
  put(transition, "transitionType", field(body, "transitionType").asInt(0))
  put(transition, "transitionRaidId", raidId)
  put(transition, "transitionCount", 0)
  put(transition, "visitedLocations", arr())
  put(o, "transition", transition)
  put(o, "excludedBosses", arr())
  result = envelope(o)

proc raidMapFor(session, body: string): string =
  ## Which map the raid that is ending was on.
  ##
  ## The body first, when it names one, then the map the session recorded on
  ## the way in.
  ##
  ## That order is the opposite of what it looks like it should be, so it is
  ## worth saying why. A post-1.0 client does not put the map in the raid
  ## result at all -- `match/local/end` is `{serverId, results,
  ## lostInsuredItems, transferItems, locationTransit}` and `serverId` is a
  ## mode, an account and a timestamp -- so in production this reads the
  ## session every time and the first branch never fires. Where it does fire is
  ## a pre-1.0 client, which did carry `location`, and a caller that states the
  ## map explicitly. In both of those the body is the more specific statement
  ## about *this* raid, and preferring the remembered value would quietly
  ## override it with whatever map the session was last told about.
  ##
  ## Empty is a real answer and is left as one. A raid whose map is unknown
  ## must not be scored against a guess: `advanceQuestsAfterRaid` treats "" as
  ## "no location qualifier matched", which loses the map-specific progress of
  ## that one raid. Guessing loses it *and* credits the wrong map.
  result = raidLocation(body)
  if result.len == 0:
    result = raidLocationFor(session)
    if result.len == 0:
      warn "the raid that just ended has no map: the result body does not " &
           "carry one and the session did not record one, so map-qualified " &
           "quest progress from it is lost"

proc onMatchEnd(url, body, session: string): string =
  ## The client hands back the profile it played the raid with. Taking it is
  ## what makes a raid mean something -- health, what was picked up, what was
  ## lost -- and it is also the one place a mistake costs a player their stash,
  ## so the body is checked before it replaces anything.
  inc gRequests
  var p = currentProfile(session)
  if not p.ok:
    return failure(1, "no profile on this session")

  # `results.result` and `results.profile`, not `exit` and `profile`.
  #
  # This was wrong for as long as it existed and it could not have been caught
  # from the inside: `field` is a root-anchored dotted path rather than a
  # recursive search, so both lookups simply missed, the guard below fired, and
  # the server logged a tidy sentence saying the client had sent no profile. It
  # had sent 76 KB of one. Every raid ended with nothing carried home -- no
  # loot, no health, no quest progress, no stats -- and the log said the client
  # was at fault.
  #
  # The names are from a capture of the real backend: seq 204 of
  # `data/capture/raid1`, whose `results` object is
  # `{profile, result, killerId, killerAid, exitName, inSession, favorite,
  # playTime}`. `exitName` is the extract's name; `result` is the outcome word
  # `parseResult` already understood.
  let results = field(body, "results")
  let outcome = parseResult(results.field("result").asText("Left"))
  let played = results.field("profile")
  if not played.found or not isObject(played):
    # What it *did* carry, not just what it did not. A refusal that names only
    # the thing it wanted is how the previous version of this bug survived: the
    # server said the client had sent no profile, the client had sent 76 KB of
    # one, and the log gave nobody a reason to doubt the server.
    warn "match/end carried no results.profile; the raid changed nothing. " &
         "the body begins: " &
         (if body.len > 160: body.substr(0, 159) & "..." else: body)
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
    #
    # The played scav goes in whole rather than just its exit status: the
    # raid's `Stats.Eft.Victims` are on it, and those carry the game's own
    # `standingForKill` per role. `endScavRaid` above copies only items off
    # this document, so this is the one place the kills are still readable.
    var karmaProblems: seq[string] = @[]
    var karmaKills = 0
    if applyScavKarma(p, keepsGear(outcome), gFenceKarmaExtract,
                      gFenceKarmaDeath, raw(played), karmaProblems,
                      karmaKills):
      info "Fence standing is now " &
           $p.field("TradersInfo." & fenceId() & ".standing").asFloat(0.0) &
           " (" & $karmaKills & " kill(s) priced)"
    for problem in karmaProblems:
      warn "scav karma: " & problem
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
  # This post-1.0 client hands back only the *in-raid character* at raid end --
  # on a death especially, the body it POSTs has the equipment tree and nothing
  # else: no `stash`, no hideout, no mail. `updated` above is the whole profile
  # replaced by that body, so taking it whole would delete the player's entire
  # stash and every base equipment slot -- after which the menu cannot build the
  # character and hangs on the loading logo, and the stash is simply gone. When
  # the handed-back inventory carries no stash, keep the stored inventory whole;
  # the raid's XP, stats and quest progress below still apply from `played`.
  let raidCarriedFullInventory = played.field("Inventory.stash").asText("").len > 0
  if not raidCarriedFullInventory:
    setRaw(updated, "Inventory", p.field("Inventory").raw())
    warn "match/end: the raid body carried no stash, so the stored inventory " &
         "was kept intact rather than replaced (gear is not lost this raid)"
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
  # Only when the raid actually handed back a full inventory: if it did not, the
  # stored inventory was kept whole above and nothing was lost from the stash, so
  # every stash item would otherwise read as "lost" and be posted to insurance.
  if raidCarriedFullInventory and lost.len > 0:
    let due = nowSeconds() + gInsuranceHours * 3600
    let where = raidMapFor(session, body)
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
  discard advanceQuestsAfterRaid(updated, p.text, raidMapFor(session, body),
                                 results.field("result").asText("Left"),
                                 nowSeconds(), gRaidClock)

  # And whatever the raid just earned. After the quest pass rather than before
  # it: an achievement condition can name a quest status, and the status the
  # raid produced has only just been written.
  var earnedAchievements: seq[string] = @[]
  discard awardAchievements(updated, nowSeconds(), earnedAchievements)

  if not saveProfile(updated):
    return failure(1, "could not save the profile after the raid")
  # Only now. A raid whose result failed to save is still a raid in progress,
  # and dropping the map here would make the retry worse than the failure.
  leaveRaid(session)
  success "raid ended: " & results.field("result").asText("Left") & " for " &
          p.nickname
  discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
  result = envelopeNull()

proc onMatchAvailable(url, body, session: string): string =
  inc gRequests
  result = envelope(raw("true"))

proc onMatchJoin(url, body, session: string): string =
  ## `/client/match/join` -- the online-matchmaking join (capture seq 379). The
  ## answer is `{maxPveCountExceeded, profiles:[MatchProfile], estimate}`, and
  ## every field is one the client reads by name; a 404 here returns the raw
  ## `{"err":"no route"}` body, whose string `err` throws the typed
  ## `MatchGroupStatusResponse` deserialise (an HTTPParsingResponseException)
  ## rather than being handled as a server error. There is no matchmaking server
  ## behind this emulator, so the one profile it puts in `MatchWait` is the
  ## player's own; the offline raid the client actually plays goes through
  ## `/client/match/local/start`, which is unaffected.
  inc gRequests
  let p = currentProfile(session)
  let loc = field(body, "location").asText("")
  var prof = obj()
  put(prof, "profileid", if p.ok: p.id else: "")
  put(prof, "profileToken", session)
  put(prof, "status", "MatchWait")
  put(prof, "ip", "")
  put(prof, "port", 0)
  put(prof, "sid", "")
  put(prof, "version", if p.ok: p.field("Info.GameVersion").asText("live") else: "live")
  put(prof, "location", loc)
  put(prof, "raidMode", "Online")
  put(prof, "mode", "deathmatch")
  put(prof, "shortId", jnull())
  put(prof, "additional_info", jnull())
  var profiles = arr()
  profiles.add done(prof)
  var o = obj()
  put(o, "maxPveCountExceeded", false)
  put(o, "profiles", profiles)
  put(o, "estimate", 0)
  result = envelope(o)

proc onMatchGroup(url, body, session: string): string =
  ## `/client/match/group/current` -- `GroupMatchRaidSettings` on the wire is
  ## `{squad:[], raidSettings:null}`. The client reads `raidSettings` by name to
  ## restore a pending group raid; omitting the key is a KeyNotFound where it
  ## reads null, and EFT.RaidSettings is in the main-menu-show crash stack when
  ## it is absent. There is no group here, so both are empty.
  inc gRequests
  var o = obj()
  put(o, "squad", arr())
  put(o, "raidSettings", jnull())
  result = envelope(o)

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
  ##
  ## Prefer the full post-1.0 location list when the `locations` post-1.0 table
  ## is installed: it carries the 24 maps the real client expects, including the
  ## ones SPT's database has no `_Id` for at all -- Terminal (`Terminal_ui`
  ## 6925a2c38bdebd9e2302692e), the Sandbox variants, Icebreaker, Labyrinth,
  ## laboratory_dark, Lighthouse2. Without them the deploy screen lists nothing
  ## the client can select and a lookup of a post-1.0-only map id throws
  ## KeyNotFound. The SPT-db build (19 maps, and where mods write their per-map
  ## `base` fields) is the fallback when the table is absent.
  inc gRequests
  let post1Locations = post1Table("locations")
  if post1Locations.len > 0:
    return envelope(raw(post1Locations))
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

  # IL2CPP metadata bootstrap -- the earliest call of all, from inside
  # `il2cpp_init`, before there is a session. See `onMetadata`.
  discard serve("/client/metadata", onMetadata)

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
  # Post-1.0 loads the character-select profile list from a versioned path (with
  # a trailing slash) as well as the classic one. Same profile array; the client
  # was stuck on "loading profile data" because this 404'd. `servePrefix` covers
  # the trailing slash the client sends.
  discard servePrefix("/v2/client/game/profiles", onProfilesV2)
  discard servePrefix("/v2/client/shop/status", onShopStatus)
  discard serve("/client/game/profile/select", onProfileSelect)
  discard serve("/client/game/profile/create", onProfileCreate)
  discard serve("/client/game/profile/nickname/validate", onNicknameValidate)
  discard serve("/client/game/profile/nickname/reserved", onNicknameReserved)
  discard serve("/client/game/profile/nickname/change", onNicknameChange)
  discard serve("/client/game/profile/savage/regenerate", onSavageRegenerate)
  discard serve("/client/game/profile/voice/change", onVoiceChange)
  discard serve("/client/game/mode", onGameMode)
  # The launcher's own bootstrap, outside `/client/` -- see the note above
  # `onLauncherPing` for why these are not `/launcher/*`. Registered with the
  # rest rather than beside the self-check, because a server that refused to
  # serve the game must not offer to make a profile for it either.
  discard serve("/aowlspt/tarkov/launcher/ping", onLauncherPing)
  discard serve("/aowlspt/tarkov/launcher/profiles", onLauncherProfiles)
  discard serve("/aowlspt/tarkov/launcher/profile/create", onLauncherCreate)
  discard serve("/aowlspt/tarkov/launcher/profile/select", onLauncherSelect)

  discard serve("/client/profile/status", onProfileStatus)
  # `GetProfileSettings` answers a bare `true`; the client only checks that the
  # call succeeded.
  discard serve("/client/profile/settings", onTrue)
  discard serve("/client/game/profile/search", onEmptyArray)
  discard serve("/client/libraries", onLibraries)
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

  # Post-1.0 tables and stubs, none of which pre-1.0 had
  discard serve("/client/dialogue", onDialogue)
  discard serve("/client/quest/getMainQuestsList", onMainQuestsList)
  discard serve("/client/quest/getMainQuestNotesList", onMainQuestNotesList)
  discard serve("/client/variable/group", onVariableGroup)
  discard serve("/client/tape/list", onTapeList)
  discard serve("/client/subtitle-track/list", onSubtitleTrackList)
  discard serve("/client/quest/chains", onQuestChains)
  discard serve("/client/getMetricsConfig", onMetricsConfig)
  discard serve("/client/quest/complete", onQuestComplete)
  discard serve("/client/tutor-game/check", onTutorGameCheck)
  discard serve("/client/match/group/invite/cancel-all", onCancelAllInvites)

  # Raids
  discard serve("/client/raid/configuration", onRaidConfiguration)
  discard serve("/client/location/getLocalloot", onLocalLoot)
  discard serve("/client/location/getAirdropLoot", onAirdropLoot)
  discard serve("/client/locations", onLocations)
  discard serve("/client/match/local/start", onMatchStart)
  discard serve("/client/match/local/end", onMatchEnd)
  discard serve("/client/match/available", onMatchAvailable)
  discard serve("/client/match/join", onMatchJoin)
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
  # No active survey: the wire answer is `data:null` (capture seq 500), not an
  # empty object -- the client null-checks the survey before reading it.
  discard serve("/client/survey", onNullData)
  discard serve("/client/survey/view", onNullData)
  discard serve("/client/survey/opinion", onNullData)
  discard serve("/client/prestige/list", onPrestigeList)
  discard serve("/client/putMetrics", onNullData)
  discard serve("/client/putHWMetrics", onNullData)
  discard serve("/client/putLoadMetrics", onNullData)
  discard serve("/client/getMetrics", onEmptyObject)
  # Post-1.0 renamed a handful of routes and added a few. These are the ones a
  # real 1.1.0 client asks for on the way to the main menu that the pre-1.0
  # spellings above miss; each was a 404 the client retried and then stalled on.
  discard serve("/client/seasonal-perks/list", onSeasonalPerks)
  discard serve("/client/season/active", onSeasonActive)
  discard serve("/client/battle-pass/active", onBattlePassActive)
  discard serve("/client/ending/list", onEndingList)
  discard serve("/client/game/token/issue", onTokenIssue)
  discard serve("/client/customization/storage", onCustomizationStorage)
  discard serve("/client/friends", onFriendList)
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

# ---------------------------------------------------------------------------
# The F12 settings schema
# ---------------------------------------------------------------------------
#
# The emulator's own settings page. Every key here is read by the emulator at
# load (in `onLoad` below) or by an `emu/*` module through `setting()` -- the
# loot keys in `emu/loot`, the skill caps in `emu/skills`. All drive the
# emulator's behaviour, so all are declared implemented.

proc tarkovSchema(): seq[Setting] =
  result = @[
    enumSetting("edition", "Game edition", "standard",
                @["standard", "left-behind", "prepare-for-escape",
                  "edge-of-darkness", "unheard"], category = "Emulator",
                description = "Starting edition applied to a fresh profile"),
    enumSetting("defaultSide", "Default side", "Usec", @["Usec", "Bear"],
                category = "Emulator"),
    intSetting("startingRoubles", "Starting roubles", 500000,
               lo = 0, hi = 100000000, step = 1000, category = "Emulator"),
    intSetting("epochBase", "Epoch base (seconds)", 1700000000,
               category = "Emulator",
               description = "The Unix time the emulator's clock starts from"),

    intSetting("insurancePercent", "Insurance return chance (%)", 10,
               lo = 0, hi = 100, category = "Insurance"),
    intSetting("insuranceReturnHours", "Insurance return delay (hours)", 24,
               lo = 0, hi = 168, category = "Insurance"),

    intSetting("scavCooldownSeconds", "Scav cooldown (seconds)", 900,
               lo = 0, hi = 86400, step = 60, category = "Scav"),
    floatSetting("fenceKarmaOnScavExtract", "Fence karma on scav extract", 0.01,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "Scav"),
    floatSetting("fenceKarmaOnScavDeath", "Fence karma on scav death", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "Scav"),

    intSetting("defaultBotLimit", "Default bot limit", 30, lo = 0, hi = 200,
               category = "Bots",
               description = "Bot limit for a map the database says nothing about"),

    intSetting("mailKeepHours", "Mail keep (hours)", 72, lo = 0, hi = 8760,
               category = "Mail",
               description = "Inbox age bound; 0 or below keeps the whole history"),
    intSetting("mailKeepCollected", "Keep collected mail", 1, lo = 0, hi = 1,
               category = "Mail"),

    intSetting("fleaSpreadPercent", "Flea price spread (%)", 20, lo = 0, hi = 100,
               category = "Flea Market"),
    intSetting("fleaOfferHours", "Flea offer duration (hours)", 12,
               lo = 1, hi = 168, category = "Flea Market"),
    intSetting("fleaMaxOffers", "Flea max offers", 600, lo = 1, hi = 10000,
               category = "Flea Market"),
    intSetting("fleaSaleMinutes", "Flea sale time (minutes)", 30, lo = 0,
               hi = 1440, category = "Flea Market"),

    boolSetting("lootEnabled", "Loot enabled", true, category = "Loot"),
    floatSetting("staticLootMultiplier", "Static loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Loot"),
    floatSetting("looseLootMultiplier", "Loose loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Loot"),
    intSetting("maxLootItems", "Max loot items", 20000, lo = 0, hi = 200000,
               step = 1000, category = "Loot"),

    floatSetting("skillMaxPerRaid", "Skill max per raid", 100.0, lo = 0.0,
                 hi = 1000.0, step = 1.0, category = "Skills"),
    intSetting("masteringMaxPerRaid", "Mastering max per raid", 100, lo = 0,
               hi = 1000, category = "Skills")]

proc onTarkovSettings(url, body, session: string): string =
  ## GET serves the emulator's schema; a POST body persists one edit into
  ## config.json. The emulator reads these at load, so the write is saved and
  ## takes effect next start rather than live.
  if body.len > 0:
    discard applySettingFromBody(body)
  result = declaredSchemaJson().text

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

  # The emulator's own settings page, registered before the store gate below so
  # it answers even on a host where the emulator refuses to serve anything else.
  declareSettings(tarkovSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onTarkovSettings)

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
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
