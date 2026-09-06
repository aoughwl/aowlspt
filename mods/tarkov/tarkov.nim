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
import aowlspt/menutext # the main menu's bottom-right corner label
import aowlspt/capability # the cross-mod call surface; this mod PROVIDES aowl.items
import emu/ids
import emu/profile
import emu/starterkit
import emu/sessions
import emu/templates
import emu/traders
import emu/inventory
import emu/raid
import emu/maplock
import emu/questcond
import emu/quests
import emu/hideout
import emu/trading
import emu/bots
import emu/modrarity
import emu/orbit
import emu/mail
import emu/mailcheck
import emu/insurance
import emu/dialogue
import emu/market
import emu/production
import emu/skills
import emu/progression
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
import emu/planting
import emu/metadata
import emu/post1
import emu/globalsgaps # the config members REAL BSG sends and db.json lacks
import emu/afk # the AFK kick, disabled in the served /client/settings
import emu/itemsgaps # the `_props` members REAL BSG sends and db.json lacks
import emu/itemsadd  # the WHOLE item templates BSG serves and db.json lacks
import emu/tuning   # the globals overrides -- the settings that reach the CLIENT
import emu/svm      # the SVM rows that are NOT globals.config, + the read ledger
import emu/spawn    # spawning items into a stash from the settings page
import emu/loadout  # the automation library's declarative gear minter
import emu/raidloadout # AutoRaid's EPHEMERAL loadout: minted, then stripped

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
  # The url the client fetches *assets* from -- `backend.Static`, the asset CDN
  # base that every `/files/...` request is resolved against. Plain HTTP, and on
  # purpose.
  #
  # `/client/*` goes over the managed HTTP stack, which post-1.0 configures to
  # accept any certificate, so HTTPS with a self-signed cert is fine there.
  # Assets do not: they are fetched with `UnityWebRequest`, through Unity's own
  # transport, and the client's call sites never assign a `certificateHandler`
  # (proven in `EFT.<DownloadTexture2D>d__218::MoveNext`, RVA 0xA7FF70 -- the
  # request is built at +0xA8018F with none). Unity therefore validates our
  # certificate, rejects it, and never sends the request; the error branch
  # returns null *without logging*, so a trader avatar that fails this way is an
  # infinite spinner and a silent client log. The only trace is a `handshake
  # FATAL` line on the server side.
  #
  # There is nothing a server can do to make that client accept its certificate.
  # So the asset base offers no certificate at all: the backend opens a second,
  # plain-HTTP listener (`--asset-port`, default 80) serving the same `/files/`
  # and `/regular/files/` routes, and this url names it. No TLS handshake
  # happens, so no TLS validation can fail, and *every* `UnityWebRequest` asset
  # fetch works -- including bundles and anything a mod adds later, not just the
  # icons `tools/imagecache.py` pre-seeds into Unity's own cache.
  #
  # Portless, which means port 80 -- keep it in step with the backend's
  # `--asset-port` default. If that port has to move (IIS, the Hyper-V port
  # reservation), both this and the backend flag move together; the client is
  # given whatever this says.
  AssetUrl = "http://127.0.0.1"

var gRequests = 0
var gDeployNoted = false
  ## One `/client/globals` readback per process; see `onGlobals`.

# Is a raid being played right now?
#
# Set at `/client/match/local/start` and cleared at `/client/match/local/end`.
# It exists for ONE consumer: the item spawner, which must refuse while a raid
# is running.
#
# WHY. The client plays the raid on its own machine holding its own copy of the
# profile, and `onMatchEnd` REPLACES the stored profile with the one the client
# posts back (see the header of `emu/raid.nim`, which says so in as many
# words). A spawn during a raid therefore writes into a profile document that
# is about to be overwritten by a client that never saw it: the item appears in
# no stash, in no raid, and the wire carries a 200 the whole way. That is the
# silent-success failure this project keeps paying for, so the spawner declines
# by name instead -- see `raidSpawnRefusal`.
var gRaidActive = false

proc raidSpawnRefusal(): string =
  ## The single sentence every spawn surface uses to decline mid-raid, so the
  ## F6 overlay and the settings page cannot drift into explaining it
  ## differently -- or, worse, into one of them not explaining it at all.
  result = "a raid is in progress. Items cannot be spawned now: the client " &
           "is holding its own copy of your profile and posts it back when " &
           "the raid ends, which would overwrite anything spawned in the " &
           "meantime. Extract or die first, then spawn into the stash."

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

# ---------------------------------------------------------------------------
# The menu corner label (see `menuCornerLabel` in `tarkovSchema` and
# `applyMenuCornerLabel` below).
# ---------------------------------------------------------------------------
var gMenuNickname = ""
  ## The last profile nickname seen at profile-select, held here so a setting
  ## change (which arrives with no session/profile context of its own) can
  ## re-apply "Profile Name" without re-deriving it.
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

var gFilesPng = ""
  ## The bytes served for every `/files/*` (and CDN-prefixed `/regular/files/*`)
  ## request -- a tiny valid PNG.
  ##
  ## Post-1.0 fetches its trader avatars, handbook/quest icons and document
  ## pictures from `/files/<kind>/<id>.png|jpg`. Those images are not in this
  ## emulator's data set, so a real one cannot be served. A `/files/*` 404 makes
  ## the client retry on a timer and sit on a spinner; a valid placeholder
  ## answered immediately ends that. Built once at load from `PlaceholderPngHex`;
  ## read-only on the worker threads after that.

const PlaceholderPngHex =
  "89504e470d0a1a0a0000000d4948445200000010000000100802000000909168" &
  "36000000144944415478da63702011308c6a18d5307c350000144ac00104416c" &
  "550000000049454e44ae426082"
  ## A 16x16 opaque dark-grey PNG, 77 bytes. Hand-decoded rather than embedded as
  ## raw bytes so the source stays plain ASCII and no editor or line-ending
  ## normalisation can corrupt a binary blob in the middle of a `.nim` file.

proc hexNibble(c: char): int =
  if c >= '0' and c <= '9': ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
  else: -1

proc decodeHex(s: string): string =
  ## Even-length hex to bytes. A stray non-hex character ends the decode rather
  ## than guessing -- the input here is a compile-time constant.
  result = ""
  var i = 0
  while i + 1 < s.len:
    let hi = hexNibble(s[i])
    let lo = hexNibble(s[i + 1])
    if hi < 0 or lo < 0: break
    result.add char(hi * 16 + lo)
    i = i + 2

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
  # `Static` alone is http, and it is the only one that may be: it is the base
  # every asset fetch is resolved against, and those go through Unity's
  # transport, which validates our self-signed certificate and drops the
  # request in silence. See `AssetUrl`. The five above stay on HTTPS -- they are
  # `/client/*` traffic on the managed stack, which does accept it, and moving
  # them would be a change to the one thing that already works.
  put(backend, "Static", AssetUrl)
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
  ##
  ## THE ONE WINDOW A LOADOUT CAN LAND IN. MEASURED
  ## (`data/capture/raid1/manifest.json`, its own seq): the client fetches
  ## `profile/list` at 096, selects at 098, configures the raid at 156 and
  ## starts the match at 158 -- and never fetches `profile/list` again in
  ## between. `onMatchStart` sends `profile: null`. So the inventory the
  ## character spawns with is the one built HERE, and this is the last moment
  ## anything can change it for the raid that follows.
  ##
  ## `tarkov.profile.listing` is emitted before a single profile is loaded, so a
  ## subscriber may mint into the store during it -- `mods/autoraid`'s server
  ## half does exactly that, via `autoraid.loadout.apply` -> `emu/raidloadout` --
  ## and the loop below then reads the profiles FRESH and serves the updated
  ## text. Emitted even when no profile is bound to the session: an unbound
  ## session is the first-run case, and a subscriber that wants to know about
  ## it should hear about it rather than be told nothing happened.
  ##
  ## `arListingBegin`/`arListingEnd` bracket it so an apply can report whether
  ## it landed inside the window. An apply outside it is honoured and does NOT
  ## reach the coming raid, and it says so.
  var a = arr()
  let all = allProfileIds()
  arListingBegin()
  var listing = obj()
  put(listing, "session", session)
  put(listing, "profileId", currentProfile(session).id)
  put(listing, "cycle", arListingCycle())
  discard broadcast("tarkov.profile.listing", listing)
  arListingEnd()
  # Deduplicate on the PARSED `_id`, which is what the client keys on -- NOT on
  # the id `allProfileIds` derives from the store FILENAME.
  #
  # This used to dedup on the filename key, and its own comment warned about "a
  # stray backup a careless hand left beside the real file" while being unable to
  # catch one: on 2026-08-31 a backup written as
  # `profile.<id>.bak-availableAfter-<ts>` produced a DIFFERENT filename key and
  # the SAME `_id` inside, so it sailed through the check and both were served.
  # The client's profile prep does a `SingleOrDefault` over this list and threw
  # `InvalidOperationException: Sequence contains more than one matching element`
  # (EFT.TarkovApplication.IsLeaving / ProfileDataLoader.Apply), which reads as a
  # menu crash a long way from its cause.
  #
  # Keying on the value the client itself keys on is the whole point: no stray
  # file in the store dir can reproduce it, whatever it is named. A profile whose
  # `_id` will not parse is NOT silently dropped -- it falls back to the filename
  # key, because dropping a real profile is worse than serving an odd one.
  #
  # The migration's own backups use a `profilebak.` prefix and are not picked up
  # by `allProfileIds` at all (measured: 3 `profile.*` files -> 3 PMC entries);
  # this change is downstream of that and does not affect it.
  var seenIds: seq[string] = @[]
  var seenScavIds: seq[string] = @[]
  for id in all:
    var p = loadProfile(id)
    if p.ok:
      var key = p.docId
      if key.len == 0:
        key = id
      if key in seenIds:
        # Named, at warn level, because a silently deduped duplicate is how this
        # bug stayed invisible: the client crashed and the server looked healthy.
        warn "profile list: DROPPED a duplicate of _id " & key &
             " served from store key " & profileKey(id) &
             " -- a stray file beside the real profile. The client does " &
             "SingleOrDefault over this list and throws on a duplicate; " &
             "move or delete that file."
        continue
      seenIds.add key
      # The progression floors, applied to the STORED profile before it is
      # served. Here rather than at creation because the settings are editable
      # after a character exists, and a floor that only ran once would be a row
      # that silently does nothing for everyone who already has a profile.
      # `applyProgression` returns false once the floor is met, so the steady
      # state is a plain read with no write.
      var notes: seq[string] = @[]
      if applyProgression(p, notes):
        if not saveProfile(p):
          warn "progression: the profile was raised but could NOT be stored, " &
               "so it will be raised again on the next fetch"
        for n in notes:
          info n
      a.add raw(p.text)
      # The scav goes straight after its PMC. The client reads the pair in that
      # order and shows the second as the scav character.
      let sc = scavText(p, nowSeconds())
      if sc.len > 0:
        # Same rule for the scav, and it is NOT redundant: the scav's `_id` comes
        # from the PMC's `savage` field, so two PMCs with distinct `_id`s can
        # still name the same scav and put the same id in the list twice. Keyed
        # on the scav document's own `_id`, falling back to the PMC's `savage`.
        var sk = field(sc, "_id").asText("")
        if sk.len == 0:
          sk = p.scavId
        if sk.len > 0 and sk in seenScavIds:
          warn "profile list: DROPPED a duplicate SCAV of _id " & sk &
               " (PMC " & key & ", store key " & profileKey(id) & ")"
        else:
          if sk.len > 0:
            seenScavIds.add sk
          a.add raw(sc)
  result = envelope(a)

proc sideToInt(side: string): int =
  ## `EFT.EPlayerSide` on the wire is an int, not the profile's "Usec"/"Bear"
  ## string: Usec=1, Bear=2, Savage=4.
  case side
  of "Bear": 2
  of "Savage": 4
  else: 1

proc buildPvr(p: Profile; pvr: var JsonObject): bool =
  ## Assemble a MINIMAL but VALID `EFT.PlayerVisualRepresentation` for the
  ## character-select slot: enough for the screen to show the nickname and render
  ## a 3D character (in default clothes), no more. Returns `false` when the
  ## profile is missing any piece the doll needs, so `characterSlot` can fall back
  ## to a null PVR (a selectable-but-nameless slot) rather than emit a value that
  ## might abort the dictionary deserialize and RE-LOCK the slot.
  ##
  ## Wire shape (from the decrypted 1.1.0.1.46777 global-metadata; the client's
  ## `[JsonProperty]` names, NOT the C# field names):
  ##   EFT.PlayerVisualRepresentationDescriptor carries
  ##     [JsonProperty("Info")]          -> JsonType.PlayerInfo
  ##     [JsonProperty("Customization")] -> the body/face descriptor
  ##     [JsonProperty("Equipment")]     -> { Id, Items }
  ##   JsonType.PlayerInfo has NO field-level JsonProperty overrides -> every key
  ##   is the PascalCase field name (Nickname/Side/Level/MemberCategory/
  ##   GameVersion/...). We send only the five the visual needs; missing fields
  ##   default, which does not throw.
  ##
  ## `Side` goes out as the profile's STRING form ("Usec"/"Bear"/"Savage"): the
  ## profile wire proves the client's `EPlayerSide` converter reads that string
  ## (SPT's mirror models `VisualInfo.Side` as `String` too). This is the one
  ## slot field that is an int -- there the field takes an int converter; here in
  ## PlayerInfo it is the string form.
  let nick = p.nickname
  let head  = p.field("Customization.Head").asText("")
  let body  = p.field("Customization.Body").asText("")
  let feet  = p.field("Customization.Feet").asText("")
  let hands = p.field("Customization.Hands").asText("")
  let equip = p.field("Inventory.equipment").asText("")
  # Fail-safe gate: refuse (-> null PVR) unless every visual piece is present.
  # This guards against a half-populated profile; it CANNOT guard against a wrong
  # wire-type guess, which is why the shapes above are taken from ground truth.
  if nick.len == 0 or head.len == 0 or body.len == 0 or feet.len == 0 or
     hands.len == 0 or equip.len == 0:
    return false

  var info = obj()
  put(info, "Nickname", nick)
  put(info, "Side", p.side)
  put(info, "Level", p.level)
  put(info, "MemberCategory", p.field("Info.MemberCategory").asInt(0))
  put(info, "GameVersion", p.field("Info.GameVersion").asText("standard"))

  # Customization descriptor: the four body/face slots the doll is built from
  # (Head/Body/Feet/Hands). Voice/DogTag are gameplay, not visual, and the match
  # customization descriptor omits them.
  var cust = obj()
  put(cust, "Head", head)
  put(cust, "Body", body)
  put(cust, "Feet", feet)
  put(cust, "Hands", hands)

  # MINIMAL Equipment: the inventory equipment ROOT item only, no worn gear. `Id`
  # resolves to a real item inside `Items`, so the model builder finds the root
  # and renders a default-clothed body; a full-gear doll is the follow-up once
  # this is proven. The RISK the task flags lives here -- an item the deserialiser
  # rejects aborts the slot -- so we send nothing but the well-known default-
  # inventory root tpl (55d7217a...), the same tpl the profile generator uses for
  # this exact item, as a bare {_id,_tpl} FlatItem.
  var rootItem = obj()
  put(rootItem, "_id", equip)
  put(rootItem, "_tpl", "55d7217a4bdc2d86028b456d")
  var equipObj = obj()
  put(equipObj, "Id", equip)
  put(equipObj, "Items", raw("[" & done(rootItem).text & "]"))

  pvr = obj()
  put(pvr, "Info", info)
  put(pvr, "Customization", cust)
  put(pvr, "Equipment", equipObj)
  result = true

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
  # PlayerVisualRepresentation drives the nickname + 3D doll on the slot. A throw
  # ANYWHERE in this value (e.g. a FlatItem the Equipment deserialiser rejects)
  # aborts the whole dictionary deserialize and re-locks the slot -- so `buildPvr`
  # is fail-safe: it emits a PVR only when it can build a clean, minimal one from
  # the profile, else returns false and we send the null it sent before (a
  # selectable-but-nameless slot). `get_HasProfile` only needs `status==2` +
  # non-empty `uid`, and the model builder is null-guarded on the PVR, so the
  # null fallback can never itself lock the slot.
  var pvr = obj()
  if buildPvr(p, pvr):
    put(o, "PlayerVisualRepresentation", pvr)
  else:
    put(o, "PlayerVisualRepresentation", jnull())
  put(o, "SeasonalInfo", jnull())
  put(o, "unlockedProductionRecipe", raw("[]"))
  put(o, "unlockedRules", raw("[]"))
  put(o, "unlockedTraderDialogues", raw("[]"))
  put(o, "unlockedTraders", raw("[]"))
  result = o

proc emptyCharacterSlot(): JsonObject =
  ## One `EFT.CharacterSelectionProfileData` for a mode with NO character yet.
  ##
  ## This exists because OMITTING a mode key is NOT the same as sending an empty
  ## slot, which is what the old comment in `onProfilesV2` assumed. A key the
  ## dictionary never receives is a slot the client was never told about, so it
  ## draws nothing -- no character, and no "create a character" prompt either.
  ## The slot prefab really does carry the affordance (`View/Empty` with its own
  ## Idle/Hover, measured live in the tree), but it only renders for a slot whose
  ## status is `empty`.
  ##
  ## `status` goes over the wire as a STRING through EGameMode's sibling
  ## `EnumConverter`: Available->"available", Locked->"locked", Empty->"empty",
  ## InRaid->"in_raid". `get_HasProfile` is `status==2 && uid != ""`, so an empty
  ## slot is the exact inverse: status "empty" and a blank uid.
  ##
  ## Every field the populated slot sends is sent here too, at its zero value. A
  ## throw ANYWHERE in one value aborts the WHOLE dictionary deserialize and
  ## re-locks every slot -- including the one that does have a character -- so a
  ## missing field here would cost us the working slot, not just this one.
  var o = obj()
  put(o, "uid", "")
  put(o, "status", "empty")
  put(o, "side", 0)
  put(o, "nickname", "")
  put(o, "lowerNickname", "")
  put(o, "nicknamePref", "")
  put(o, "level", 0)
  put(o, "prestigeLevel", 0)
  put(o, "memberCategory", 0)
  put(o, "accountType", 0)
  put(o, "aid", 0)
  put(o, "gameVersion", "standard")
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
  # The two modes this server has no character for are sent EXPLICITLY as empty
  # slots, not omitted. Omitting them was the old behaviour and its comment
  # claimed it produced "a create a character prompt"; it does not -- measured on
  # the live client, the response carried only the "regular" key and the player
  # saw no empty slot and no + button anywhere on the screen. Only these two keys
  # are legal besides "regular"; anything outside the EnumConverter map THROWS and
  # re-locks every slot, so this list is closed on purpose.
  put(modes, "pve", emptyCharacterSlot())
  # "pvp-season" is deliberately NOT sent. Sending it populates the SEASONAL slot
  # view, whose RefreshModeSpecificState calls CharacterSelectionSeasonPanel.ShowPerks
  # with the SeasonalPerksData the client fetched from /client/seasonal-perks/list.
  # That value arrives null here, ShowPerks throws NullReferenceException inside the
  # client's own RunInitialLobbyFlow, and the task that activates MenuScreen never
  # completes -- the player is left staring at an empty background. Measured from the
  # client's own output_000.log stack, not inferred. Restore this key only once the
  # seasonal-perks payload is known to deserialize into a non-null SeasonalPerksData.
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

proc applyMapLockSettings*() =
  ## Read the three map-lock keys and write `Locked` into every map's base.
  ##
  ## ONE apply path, called from both the load-time config read and the
  ## settings POST -- not two copies of the same three `setting()` calls. The
  ## fov mod learned this the expensive way: an edit that persisted to
  ## config.json while the live value kept what it was loaded with is a slider
  ## that moves and changes nothing.
  ##
  ## And it MUST be hot: measured with tools/realtest.nim before this proc
  ## existed, turning `mapsUnlockedByDefault` off persisted correctly and left
  ## all 24 maps still served unlocked, because the apply only ran at load.
  ## The check that caught it is "with the default OFF, NO map is served
  ## unlocked", asked of the served payload over every map.
  let rep = applyMapLocks(LockConfig(
    unlockedByDefault: setting("mapsUnlockedByDefault").asBool(true),
    lockList: setting("mapsLocked").asText(""),
    unlockList: setting("mapsUnlocked").asText("")))
  let msg = lockSummary(rep)
  # An unresolved map name is a WARN, not an info: the setting saved cleanly
  # and locked nothing, which reads as success everywhere else.
  if rep.unresolved.len > 0 or rep.failed > 0:
    warn "map locks: " & msg
  else:
    info "map locks: " & msg
  discard applySetting("mapsLockResult", quoted(msg))

proc applyMenuCornerLabel() =
  ## Drives the main menu's bottom-right corner label from the
  ## `menuCornerLabel` setting, using whatever nickname was last seen at
  ## profile-select (`gMenuNickname`). Safe to call with no profile selected
  ## yet -- "Profile Name" then logs and falls back to leaving the stock label
  ## alone, rather than sending an empty override that would look identical to
  ## every other "nothing to say" case.
  ##
  ## The three options are represented on the wire (see `aowlspt/menutext`)
  ## as:
  ##   * "PVE ZONE"     -> the literal string "PVE ZONE", sent as an
  ##     override. Simpler and unambiguous versus clearing the override and
  ##     trusting the stock default to still read "PVE ZONE" -- this way the
  ##     option means what it says regardless of what the host's stock text
  ##     happens to be.
  ##   * "Profile Name" -> `clearMenuModeText()`. The tarkov mod already
  ##     broadcasts the nickname on `aowlspt.menu.nickname` as the manager's
  ##     DEFAULT (see `onProfileSelect` below), so clearing any override here
  ##     lets that default show through -- no need to re-send the nickname as
  ##     an override too.
  ##   * "No text"      -> a single space (`" "`), sent as an override. An
  ##     empty string is already spoken-for: `setMenuModeText("")` means
  ##     "clear my override" all the way down this chain (menutext.nim,
  ##     mgr/control.nim's `onMenuModeText`, the host's `modeTextSetWanted`),
  ##     so it cannot ALSO mean "blank the label" -- that would be one value
  ##     doing two jobs. A single space is a distinct, non-empty, printable-
  ##     ASCII string that survives every `menuTextSane`/`menuTextAcceptable`
  ##     check unchanged and renders as visually blank on screen.
  let choice = setting("menuCornerLabel").asText("Profile Name")
  case choice
  of "PVE ZONE":
    discard setMenuModeText("PVE ZONE")
  of "No text":
    discard setMenuModeText(" ")
  else: # "Profile Name", and any unrecognised value defaults here too
    if gMenuNickname.len == 0:
      info "menu corner label: setting is 'Profile Name' but no profile " &
           "has been selected yet -- leaving the stock label alone"
    discard clearMenuModeText()

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

  # Name the character for the main menu's bottom-right corner label. The mod
  # manager holds this and relays it to the client host on the mod-sync poll the
  # host already makes (see mgr/control.nim), which then calls the game's own
  # PreloaderUI.SetGameModeText. This is only the DEFAULT -- any mod's
  # `setMenuModeText` override wins -- and the whole path is off unless the
  # player set `uxMenuModeText` in aowlspt-host.json. A broadcast nobody is
  # subscribed to is a no-op, so this costs nothing when the feature is off.
  if p.nickname.len > 0:
    discard broadcast("aowlspt.menu.nickname", objOf("nickname", p.nickname))
    gMenuNickname = p.nickname
  else:
    info "menu corner label: profile " & id & " has no nickname to show"
  applyMenuCornerLabel()

  # A useful signal, and TOO LATE to change this raid. MEASURED (capture raid1,
  # manifest seq 096 then 098): this fires immediately AFTER the client's last
  # `/client/game/profile/list`, so a loadout applied here reaches the client at
  # the NEXT list, not the raid that is about to start. The window that DOES
  # reach it is `tarkov.profile.listing`, emitted from `onProfileList` above.
  # Kept, because knowing which profile a session bound to is worth knowing.
  var selected = obj()
  put(selected, "session", session)
  put(selected, "profileId", id)
  discard broadcast("tarkov.profile.selected", selected)

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
  let canonEdition = normalEdition(edition)
  if canonEdition.len == 0:
    return launcherRefusal("this server does not have a starting profile for " &
                           "edition '" & edition & "'")
  edition = canonEdition
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

proc onItems(url, body, session: string): string =
  ## The item-template document, with the `_props` members REAL BSG sends
  ## and this pre-1.0 database lacks spliced in. `applyItemsGaps` caches
  ## against its input text, so the 12.7 MB reparse happens once. `applyItemsAdd`
  ## then splices in the WHOLE templates BSG serves that db.json lacks entirely,
  ## so a payload that references one (a battle-pass reward, a season item, a
  ## quest note) resolves instead of throwing "Cannot find template ... for item".
  envelope(raw(applyItemsAdd(applyItemsGaps(items()))))
proc onGlobals(url, body, session: string): string =
  ## The globals document, with every singleplayer override applied.
  ##
  ## This is where a settings row stops being a number in a file and becomes a
  ## number the CLIENT reads: `globals.config` is what the client's own
  ## ballistics, stamina, malfunction, skill and flea-market code parses at
  ## session start. `applyGlobalTunes` returns its argument unchanged, without
  ## reparsing it, when nothing is overridden -- see `emu/tuning`.
  let served = applyGlobalTunes(applyGlobalsGaps(globals()))
  # The readback, once per process, and it reads the BYTES that are about to go
  # out rather than the config key that was supposed to change them.
  #
  # `TimeBeforeDeployLocal` is the raid deploy countdown, and MEASURED by the
  # client-log agent it is a FIXED 10 s inside the 21.7 s GamePooled ->
  # GameRunned tail in all three sessions. It is already an exposed server
  # value modifier -- `g_TimeBeforeDeployLocal` in `emu/globaltunedata`,
  # 0..100, unset = whatever db.json holds -- so there is nothing new to add
  # and nothing to default ON. What was missing is the half that can fail:
  # a line saying what the client was actually handed. If this prints 10 while
  # config.json says 3, the override did not reach the wire.
  if not gDeployNoted:
    gDeployNoted = true
    let cfg = field(served, "config.TimeBeforeDeployLocal")
    if cfg.found:
      info "globals: TimeBeforeDeployLocal served as " & $cfg.asInt(-1) &
           " s (set g_TimeBeforeDeployLocal in mods/tarkov/config.json to " &
           "change it; unset is vanilla)"
    else:
      warn "globals: the served document has no config.TimeBeforeDeployLocal " &
           "-- the deploy countdown cannot be read back from it"
  result = envelope(raw(served))
proc onHandbook(url, body, session: string): string = envelope(raw(handbook()))
proc onCustomization(url, body, session: string): string =
  envelope(raw(customization()))
proc onLanguages(url, body, session: string): string =
  envelope(raw(languages()))
proc onQuestList(url, body, session: string): string =
  ## An array, not the id-keyed object the database stores. See
  ## `emu/templates.questList`.
  ##
  ## The availability pass runs HERE, not only at profile creation: a profile
  ## made before this existed, or made against a database that has since
  ## changed, would otherwise keep an empty entry set forever. It is idempotent
  ## and only ever moves a quest out of absent/`Locked`, so running it on every
  ## menu load cannot undo progress.
  var p = currentProfile(session)
  if not p.ok:
    # No profile to speak for. The raw template array is still a valid answer
    # and is what shipped before; it is NOT presented as a per-profile one.
    return envelope(raw(questList()))
  let opened = refreshAvailability(p, nowSeconds())
  if opened > 0:
    if not saveProfile(p):
      warn "quest/list: could not save the profile after opening " &
        $opened & " quest(s)"
    else:
      info "quest/list: " & $opened & " quest(s) now AvailableForStart"
  result = envelope(raw(questListFor(p)))
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
  # `safeLanguage`, not the raw URL segment: `lang` is whatever the client put
  # after `/client/locale/`, and it is spliced into BOTH a dotted database path
  # and a FILE path. A segment carrying a dot or a slash reads a different
  # subtree, or a different file, than the one asked for -- and both callees
  # fall back to English, so the wrong answer would have looked like a working
  # one. `emu/dialogue.localeText` already sanitised for exactly this reason;
  # these two routes, the ones the client actually calls, did not.
  let lang1 = safeLanguage(lang)
  let post1Locale = post1Table("locale_" & lang1)
  if post1Locale.len > 0:
    return envelope(raw(post1Locale))
  result = envelope(raw(locale(lang1)))

proc onMenuLocale(url, body, session: string): string =
  ## Post-1.0 deserialises this `data` into `EFT.BackendMenuLocale`, whose sole
  ## field is `menu`; `ConvertToLocale` then reads `this.menu`. A flat map at
  ## `data` leaves `menu` null and the client null-refs in `ConvertToLocale`
  ## (surfacing far away as a preloader-UI crash), so the map is wrapped under
  ## `menu`. Pre-1.0 put the map straight on `data`; this is the post-1.0 shape.
  let lang = pathAfter(url, "/client/menu/locale/")
  let lang1 = safeLanguage(lang)
  let post1Menu = post1Table("menulocale_" & lang1)
  if post1Menu.len > 0:
    return envelope(objOf("menu", raw(post1Menu)))
  result = envelope(objOf("menu", raw(menuLocale(lang1))))

proc onSettings(url, body, session: string): string =
  ## The AFK kick is disabled HERE, at the data source. `config.AFKTimeoutSeconds`
  ## is the value `EFT.AFKMonitor::Start`@0x9e8450 loads into `_afkTimeout`, and a
  ## value <= 0 takes the client's own `Debug.LogError` branch, never arming the
  ## monitor -- see `emu/afk.nim` for the disassembly and for the timing
  ## measurement that ties the served number to the observed dialog.
  let v = dbRead("settings")
  if v.ok:
    return envelope(raw(disableAfkKick(v.raw)))
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

proc onFiles(url, body, session: string): string =
  ## Every `/files/*` (and CDN-prefixed `/regular/files/*`) binary asset --
  ## trader avatars, handbook/quest icons, document images. This emulator has no
  ## image set, so one placeholder answers all of them; the point is that the
  ## answer is immediate and valid so the client stops retrying and the screen
  ## settles. The backend recognises the path and sends these bytes raw and
  ## un-deflated with an `image/png` Content-Type; the handler just hands over
  ## the bytes.
  inc gRequests
  result = gFilesPng

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
  ## BSG ships one active battle pass (44 KB, capture seq 081) to every account;
  ## `battlePasses:[]` is an install-constant HOLE, not a fresh-profile empty.
  ## The real catalogue is `data/post1/battlepassactive.json`; absent it, the
  ## empty list is the non-throwing fallback.
  inc gRequests
  result = post1Object("battlepassactive", objOf("battlePasses", arr()))

proc onEndingList(url, body, session: string): string =
  ## `/client/ending/list` -- an OBJECT `{elements:[...]}` of raid-ending
  ## descriptors. BSG ships four prestige-ending elements (capture seq 132) the
  ## same for every account; `elements:[]` is an install-constant HOLE. Real
  ## data in `data/post1/endinglist.json`, empty list as the fallback.
  inc gRequests
  result = post1Object("endinglist", objOf("elements", arr()))

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
  result = post1Object("seasonalperks", o)

proc onSeasonActive(url, body, session: string): string =
  ## `/client/season/active` -- the active seasonal event. BSG sends
  ## `{"season":{...}}` (capture seq 080); we sent `{}`, so `data.season` read
  ## back null and any consumer that derefs it throws -- the same null-perks
  ## shape that keeps the pvp-season slot disabled (see onCharacterList). The
  ## captured season is real BSG content in `data/post1/seasonactive.json`.
  ##
  ## Unlike the other three this route is TIME-scoped: the season carries
  ## start/end timestamps, so the captured event is a real-shape season that is
  ## not necessarily current. It is still strictly better than `{}` -- a
  ## non-null `season` object rather than a null the client indexes -- and the
  ## fallback stays `{}` if the file is absent.
  inc gRequests
  result = post1Object("seasonactive", obj())

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

proc onAutoscriptLoadout(url, body, session: string): string =
  ## `/aowlspt/tarkov/autoscript/loadout` -- mint a declared loadout, then read
  ## the profile back and say what really arrived.
  ##
  ## Not in the client's envelope. Nothing in the client asks for this: the
  ## caller is `tools/autoscript.nim`, running as a separate process on behalf of
  ## a test script, and an envelope would invite something to treat it as a game
  ## route (the reason `/aowlspt/tarkov/selfcheck` is bare too).
  ##
  ## It is a route rather than an in-game mod hook because a CLIENT-side mod
  ## cannot serve HTTP -- `serve()` inside the game process registers into
  ## nothing. The backend is the only place a script can be answered from.
  inc gRequests
  let rep = applyLoadout(body)
  info "autoscript loadout: " & rep.verdict & " -- " & rep.reason
  result = reportJson(rep)

proc onAutoRaidLoadoutStatus(url, body, session: string): string =
  ## `/aowlspt/autoraid/loadout/status` -- what AutoRaid's ephemeral loadout has
  ## done, and the measured wire order that decides WHEN it can be seen.
  ##
  ## Bare JSON built by the builders, never a hand-rolled string: the whole
  ## reason `errJson`/`obj()` exist is that a status route which answers
  ## something that is not JSON is indistinguishable from a working one until
  ## something parses it.
  ##
  ## Served under BOTH namespaces on purpose. Measured (see the ORBIT comment in
  ## `onLoad`): a route at `/aowlspt/orbit/plan` 404s on a running backend while
  ## `/aowlspt/tarkov/...` beside it answers, so the contract's
  ## `/aowlspt/autoraid/...` path may not reach a mod on this host at all. Both
  ## are registered and both answer the same document; the `/aowlspt/tarkov/`
  ## one is the one known to work.
  inc gRequests
  result = arStatusJson()

proc onAutoscriptVerify(url, body, session: string): string =
  ## `/aowlspt/tarkov/autoscript/verify` -- the read-back half alone. Mints
  ## nothing and saves nothing; the same `countPlaced` decides. A script uses it
  ## to assert a loadout survived a raid, or to check the ground truth before
  ## minting on top of it.
  inc gRequests
  let rep = verifyLoadout(body)
  result = reportJson(rep)

proc onAutoscriptCaps(url, body, session: string): string =
  ## `/aowlspt/tarkov/autoscript/capabilities` -- THE VERSION HANDSHAKE.
  ##
  ## Answers what THIS DEPLOYED BUILD of tarkov.dll can be asked for, so a
  ## script can refuse loudly against a stale install instead of minting the
  ## wrong thing quietly. The whole reason it exists is that a 404 is the only
  ## staleness `applyGear` could previously detect, and a stale-but-present
  ## route does not 404: it answers 200 having ignored the field the script
  ## cared about.
  ##
  ## Deliberately GET-shaped and side-effect free -- it must be answerable by an
  ## install too old to do anything else the script wants, which is the one case
  ## it is for.
  inc gRequests
  var caps = arr()
  for c in split(LoadoutCaps, ','):
    if c.len > 0: caps.add jstr(c)
  var o = obj()
  put(o, "api", LoadoutApi)
  put(o, "caps", caps)
  put(o, "mod", "aowl.tarkov")
  result = text(done(o))

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

proc onBotDigest(url, body, session: string): string =
  ## `/aowlspt/tarkov/botdigest/<role>/<seed>/<n>` -- N loadouts for one role at
  ## one stated seed, hashed.
  ##
  ## THE INSTRUMENT for "defaults reproduce current behaviour exactly". No
  ## `aowl` verb generated bots at a seed and printed a hash, so that claim was
  ## previously true by construction, which is an argument and not a
  ## measurement. This makes it a number two builds can be compared on, and --
  ## the half that matters -- a number that MOVES when one attachment knob is
  ## moved. If it did not move, the check could not fail.
  ##
  ## Not in the client's envelope: nothing in the client asks for this. Same
  ## reasoning as `/aowlspt/tarkov/selfcheck`.
  ##
  ## `items` is the INCONCLUSIVE detector. A digest over zero items is a stable
  ## hash of the empty string and would agree with itself across any change; a
  ## caller must refuse to read a verdict out of a zero.
  inc gRequests
  let rest = pathAfter(url, "/aowlspt/tarkov/botdigest/")
  var parts: seq[string] = @[]
  var cur = ""
  for ch in rest:
    if ch == '/':
      parts.add cur
      cur = ""
    else:
      cur = cur & ch
  parts.add cur
  let role = if parts.len > 0: parts[0] else: ""
  let seed = if parts.len > 1: parts[1] else: "seed"
  # Parsed here rather than with `digitsToInt`, which is declared further down
  # the file and is not in scope yet. Total and non-raising: one non-digit byte
  # falls back to 8 rather than to a partial number.
  var n = 8
  if parts.len > 2 and parts[2].len > 0:
    var acc = 0
    var good = true
    for ch in parts[2]:
      if ch < '0' or ch > '9':
        good = false
      else:
        acc = acc * 10 + (ord(ch) - ord('0'))
    if good and acc > 0 and acc <= 64:
      n = acc
  var o = obj()
  put(o, "role", role)
  put(o, "seed", seed)
  put(o, "count", n)
  if role.len == 0 or n <= 0:
    put(o, "ok", false)
    put(o, "reason", "usage: /aowlspt/tarkov/botdigest/<role>/<seed>/<n>")
    return text(done(o))
  let t = loadTables(role)
  if not t.ok:
    put(o, "ok", false)
    put(o, "reason", "no bots.types entry for role " & role)
    return text(done(o))
  var items = 0
  let d = loadoutDigest(t, seed, n, items)
  put(o, "ok", items > 0)
  put(o, "items", items)
  put(o, "digest", d)
  put(o, "priceIndex", priceIndexSize())
  if items == 0:
    put(o, "reason", "INCONCLUSIVE: generated 0 items; the digest is the " &
                     "hash of the empty string and cannot distinguish builds")
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

proc post1Object(name: string; fallback: JsonObject): string =
  ## An install-constant OBJECT route backed by an installed table -- the object
  ## counterpart of `post1Route`, which serves arrays. These routes
  ## (battle-pass/active, seasonal-perks/list, ending/list, season/active) send
  ## the SAME content to every account regardless of profile: a battle-pass
  ## catalogue, the seasonal perk definitions, the prestige-ending descriptors,
  ## the active seasonal event. Empty is always wrong for them -- a hole
  ## `emptygap.py` ranks -- yet type/shape audits pass an empty one, because the
  ## SHAPE is right and only the CONTENT is missing.
  ##
  ## When the table is absent the answer is the caller's `fallback` (the empty-
  ## but-correctly-shaped object each route already served), NOT the raw table:
  ## the fallback is a valid, non-throwing "nothing here", and losing the data
  ## file must degrade to that rather than to a 404 that stalls the menu.
  let text = post1Table(name)
  if text.len == 0:
    return envelope(fallback)
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
  put(o, "quests", raw(questListFor(p)))
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
    # The stock loadouts still, for the same reason the profile path serves
    # them: an empty `equipmentBuilds` makes `EquipmentBuildsScreen.Show`
    # throw out of `Enumerable.First`.
    put(o, "equipmentBuilds", raw(text(defaultEquipmentBuilds())))
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
  # `{"err":0,"data":null,"errmsg":null}` -- measured, capture seq 305
  # (`/client/builds/weapon/save`) and 359 (`.../equipment/save`), both
  # `resp_declen: 81`. We used to answer `{"id": ...}`; the client does not
  # read it back, it re-reads `/client/builds/list`, which is seq 441.
  result = envelopeNull()

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
# ORBIT
# ---------------------------------------------------------------------------

proc onOrbitPlan(url, body, session: string): string =
  ## The plan for the raid that is running, and the verdict on it.
  ##
  ## Served rather than only broadcast so the check can be read with curl
  ## instead of by grepping a log, and so that a `mods/sain` that never got the
  ## broadcast can be told apart from a plan that was never built -- two
  ## failures with identical symptoms on the client side.
  inc gRequests
  var o = obj()
  put(o, "plan", Json(text: lastPlanJson()))
  put(o, "check", orbitCheck())
  put(o, "state", orbitState())
  result = done(o).text

proc onObjectiveCatalog(url, body, session: string): string =
  ## The objective catalog as it went on `tarkov.objectives.catalog`.
  ##
  ## Served for the same reason the plan is: "the catalog was never built" and
  ## "the catalog was built and `mods/sain` never received it" are the same
  ## symptom on the client, and only a route can tell them apart. The client's
  ## own verdict on what it RECEIVED is at `/aowlspt/sain/status`, and the two
  ## being different documents is the point.
  inc gRequests
  result = lastCatalogJson()


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
  # A SUPERSET of what this used to send. It sent `raw(cfg)` -- the five members
  # the client gets echoed back -- which carries neither the session nor the
  # profile, so a subscriber could not tell WHOSE raid it was. Every member of
  # `cfg` is still there; `session`, `profileId` and `raidMode` are added.
  #
  # Later still: this is seq 156 against the last `profile/list` at 096, so gear
  # applied from here spawns with the NEXT raid, not this one. It is kept
  # because the MAP is known here and nowhere earlier, which is the thing this
  # event is actually for. `tarkov.profile.listing` is the window that reaches
  # the coming raid, and `emu/raidloadout`'s status route says which of the two
  # the last apply used.
  var cfgDoc = parseObject(cfg)
  setText(cfgDoc, "session", session)
  setText(cfgDoc, "profileId", currentProfile(session).id)
  setText(cfgDoc, "raidMode", field(body, "raidMode").asText(""))
  discard broadcast("tarkov.raid.configured", text(cfgDoc))
  # The ORBIT plan for this map, built here because this is the FIRST moment
  # the map is known and it is known before any bot exists. `emitPlan` is a
  # no-op when the map has not changed, so the second caller below costs
  # nothing on the common path. See `emu/orbit.nim` for what a plan is and,
  # more importantly, for the three things it deliberately does not contain.
  emitPlan(field(cfg, "location").asText(""))
  # What `bot/generate` cannot name: it carries neither the map nor the raid.
  setRaidContext(configured, gRaidId)
  result = envelopeNull()

proc onLocalLoot(url, body, session: string): string =
  inc gRequests
  let loc = field(body, "locationId").asText("factory4_day")
  # The fallback namer. A client that reaches `getLocalloot` without having
  # sent `raid/configuration` -- the scav path does exactly this -- would
  # otherwise enter a raid with no plan and the dispatcher would sit
  # INCONCLUSIVE for the whole raid with no way to tell that apart from a
  # broken bus.
  emitPlan(loc)
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
  # The raid has begun; the spawner declines until it ends. Set here rather
  # than inferred from anything else, because this route is the client saying
  # so.
  gRaidActive = true
  # The seven fields the client sends were read by nothing at all before, which
  # is how the map came to be unknown at the end of the raid. Real body:
  # `{serverId, location, timeVariant, mode, playerSide, transitionType,
  # transition}`.
  let startLocation = field(body, "location").asText("")
  let startMode = field(body, "mode").asText("")
  if startLocation.len > 0:
    enterRaid(session, startLocation, startMode)
  # The definitive raid-entry signal: the 3D world is loading now. The manager
  # relays this to the client host so the graphics post-process grades the raid
  # world and leaves the menu stock. Paired with `tarkov.raid.ended` below.
  discard broadcast("tarkov.raid.started", objOf("location", startLocation))

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
  # CANONICALISED before it leaves here. Quest `Location` conditions carry
  # database keys as their target (`bigmap`, `interchange`); the session
  # remembered what the CLIENT said (`Woods`, `Interchange`), and `listHas`
  # is an exact string compare, so on 13 of 19 maps every map-qualified
  # counter compared two spellings of the same map and refused. Same defect
  # as the empty-loot one, in a place whose only symptom is quest progress
  # that does not arrive.
  result = canonicalLocation(raidLocation(body))
  if result.len == 0:
    result = canonicalLocation(raidLocationFor(session))
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
  # The raid is over, so the spawner is usable again. Cleared FIRST, before any
  # early return below: every exit from this handler means the client is no
  # longer holding the profile, including the ones that reject the body. A
  # clear placed at the bottom would leave the spawner refusing forever after
  # one malformed raid result.
  gRaidActive = false
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
    # AutoRaid's ephemeral gear, on the SCAV path too.
    #
    # The minted set is keyed by the PMC's profile id and a scav never has one
    # of its own, so this looks like it could be skipped -- and skipping it is
    # exactly the bug. `p` here IS the PMC profile (the scav's loot has just
    # been merged into it) and a minted PMC kit is sitting in that inventory. A
    # scav raid run between arming a spawned loadout and taking it into a PMC
    # raid would otherwise save minted gear into the stash permanently.
    #
    # The consequence is stated rather than hidden: a scav raid CONSUMES the
    # armed PMC loadout. That is the honest behaviour for gear that only exists
    # for one raid, and the alternative -- leaving it -- is the duplication this
    # module exists to prevent.
    # The id is bound to a local FIRST. `arStripBeforeSave(p, p.id, ...)` reads
    # a field of the very object it takes as `var`, which nimony refuses as
    # "mutable argument aliases with immutable parameter" -- correctly, since
    # the callee could rewrite the text the id was read out of.
    var arScavMinted: seq[string] = @[]
    let arScavId = p.id
    let arScavActed = arStripBeforeSave(p, arScavId, arScavMinted)
    if not arScavActed:
      info "autoraid loadout: no minted set for " & arScavId &
           " at the end of a scav raid; nothing to strip"
    if not saveProfile(p):
      return failure(1, "could not save the profile after the scav raid")
    if arScavActed:
      arEndVerdict(arScavId, arScavMinted)
    success "scav raid ended: " & $brought & " item(s) brought home"
    discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
    # Only the ids this server PLANTED, and only those found in the saved
    # profile -- never the inventory. Nothing is emitted when none came home.
    emitTaken(p.text)
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
  # Both spellings of the map go in: `raidMapFor` is CANONICAL (a database
  # key, which is what everything that reads `locations` needs) while a
  # quest's `Location` target is usually the client's `base.Id`. Passing only
  # one of the two is what refused map-qualified progress -- first on the
  # thirteen maps whose key differs from the id, then, after canonicalising,
  # on the seven whose target is an id. See `emu/raid.locationAliases`.
  let questMap = raidMapFor(session, body)
  discard advanceQuestsAfterRaid(updated, p.text, questMap,
                                 results.field("result").asText("Left"),
                                 nowSeconds(), gRaidClock,
                                 locationAliases(questMap))

  # And whatever the raid just earned. After the quest pass rather than before
  # it: an achievement condition can name a quest status, and the status the
  # raid produced has only just been written.
  var earnedAchievements: seq[string] = @[]
  discard awardAchievements(updated, nowSeconds(), earnedAchievements)

  # AUTORAID'S EPHEMERAL GEAR, out before the save.
  #
  # Placed here, after `raidCarriedFullInventory` has decided which inventory is
  # being written, and that ordering is the whole of it: on a DEATH the client
  # posts no stash, the guard above puts the STORED inventory back into
  # `updated`, and the minted items are in that stored inventory -- so stripping
  # before the guard would strip a copy that is then thrown away and the gear
  # would come home anyway. On an EXTRACT the posted inventory is kept and the
  # minted items are in that one. Both cases are handled by stripping whatever
  # `updated.Inventory.items` holds at this point, which is the array that is
  # about to be saved.
  #
  # `minted` is kept across the save so the verdict below can be a NEGATIVE over
  # the profile as it was actually written, rather than over the object this
  # handler is holding.
  var arMinted: seq[string] = @[]
  let arActed = arStripBeforeSave(updated, p.id, arMinted)
  if not arActed:
    info "autoraid loadout: no minted set for " & p.id &
         " at the end of this raid; nothing to strip"

  if not saveProfile(updated):
    return failure(1, "could not save the profile after the raid")

  if arActed:
    arEndVerdict(p.id, arMinted)

  # `transferItems`: everything the player handed to the BTR container or
  # carried into a transit. It is in the request body and it is **not** in the
  # profile the client posts back -- handing an item over is exactly how it
  # leaves the character -- so the profile replacement above destroyed all of
  # it. Pay the BTR, load the container, extract, and the kit was neither in
  # the stash nor in the mail. Silent, permanent, and answered with a 200.
  #
  # Posted rather than spliced into the stash, for three reasons. A stash can
  # be full, and the only honest thing a splice can do when it is full is drop
  # items -- which is the bug being fixed, wearing a different hat. The
  # mailbox has no capacity to run out of, so the full-stash case stops being
  # a case at all: the items wait in the inbox until there is room. And the
  # client already has `EFT.UI.DragAndDrop.MailTransferItemsGridItemView` -- a
  # mailbox view built for transferred items -- which is the best evidence
  # available that post is what the real backend does with them.
  #
  # After the save on purpose: a raid whose result was thrown away must not
  # leave items in a mailbox for it.
  var xferProblems: seq[string] = @[]
  let carried = transferredItems(body, xferProblems)
  for problem in xferProblems:
    # `error`, not `warn`. Every line here means items this server could see
    # and could not place, which is the loudest thing that happens in this
    # handler.
    error "match/end transferItems: " & problem
  let carriedList = parseArray(carried)
  if carriedList.ok and carriedList.len > 0:
    # Which of them are already somewhere the player can reach. Both places are
    # checked, because this is what makes a retried `match/local/end`
    # idempotent: without it a client that re-posts the same body -- and it
    # does, after a failed save -- gets a second copy of every transferred
    # item.
    var home: seq[string] = @[]
    let stashItems = each(updated.field("Inventory.items"))
    for it in stashItems:
      home.add it.field("_id").asText("")
    let inbox = loadMail(p.id)
    for i in 0 ..< inbox.len:
      let attached = each(whole(inbox.items[i]).field("items.data"))
      for a in attached:
        home.add a.field("_id").asText("")
    var owed = newList()
    for i in 0 ..< carriedList.len:
      let id = field(carriedList.items[i], "_id").asText("")
      var have = false
      for h in home:
        if h.len > 0 and h == id:
          have = true
      if not have:
        owed.add carriedList.items[i]
    if owed.len == 0:
      info $carriedList.len & " transferred item(s) are already in the stash " &
           "or the mailbox; nothing was posted"
    elif deliver(p.id, "", "The items you handed over in the raid have been " &
                 "delivered.", mkSystem, nowSeconds(), text(owed)):
      # Plain words rather than a trader's. This is a system message, which the
      # client renders without a sender, so there is no voice being put in
      # anybody's mouth -- unlike the insurance returns, which refuse to send
      # anything the database has no wording for.
      success $owed.len & " item(s) handed over in the raid were posted to " &
              "the mailbox"
    else:
      # The mailbox could not be written and the profile already has been, so
      # the items exist nowhere. Nothing here can put them back -- the profile
      # the client played with no longer contains them -- so the only useful
      # act is to name every one of them in the log, loudly enough that a
      # human can put them back by hand.
      var names = ""
      for i in 0 ..< owed.len:
        if names.len > 0: names.add ", "
        names.add field(owed.items[i], "_tpl").asText("?") & " (" &
                  field(owed.items[i], "_id").asText("?") & ")"
      error "could not post " & $owed.len & " transferred item(s) to " &
            p.nickname & "'s mailbox, and the profile has already been " &
            "saved without them, so they are LOST: " & names

  if outcome == rrTransit:
    # KNOWN LIMITATION, stated rather than hidden. `locationTransit` names a
    # destination map (MEASURED: `EFT.LocationTransit` is `{hash, playersCount,
    # ip, location, profiles, transitionRaidId, raidMode, side, dayTime}` --
    # no items), and this server does not continue a raid onto it: it ends the
    # raid here, exactly as it does for `Left`. Gear is kept and the transit
    # hold has just been posted above, so nothing is lost by it; what is
    # missing is the seamless second raid.
    let dest = transitDestination(body)
    warn "this raid ended in a transit to " &
         (if dest.len > 0: dest else: "an unnamed location") &
         ", and this server does not continue a raid across one: it has been " &
         "ended here instead. Nothing was lost -- the gear is kept and the " &
         "transit hold has been posted to the mailbox."

  # Only now. A raid whose result failed to save is still a raid in progress,
  # and dropping the map here would make the retry worse than the failure.
  leaveRaid(session)
  success "raid ended: " & results.field("result").asText("Left") & " for " &
          p.nickname
  discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
  emitTaken(p.text)
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
  ## The table goes out through `post1LocationsTuned`, not verbatim. This is the
  ## payload the client builds its scav wave scenario from -- proven live: a
  ## Factory raid logged exactly one `toSpawn:2`, which is the span of
  ## `factory4_day`'s single negative-time base wave (`slots 2/4`), while
  ## `match/local/start` was serving four waves of span 4 that the client never
  ## looked at. Serving this route verbatim was therefore serving BSG's
  ## online-tuned waves regardless of anything `localLoot` did. The tuning is
  ## computed once and cached, so this route stays the cheap one it was made
  ## into.
  let post1Locations = post1LocationsTuned()
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

proc digitsToInt(s: string; default: int): int =
  ## A decimal query parameter, or the default. Non-raising and total: one
  ## non-digit byte returns the default rather than a partial number, because
  ## `?limit=50x` meaning 50 is a guess about what somebody meant.
  if s.len == 0:
    return default
  var acc = 0
  for i in 0 ..< s.len:
    let c = s[i]
    if c < '0' or c > '9':
      return default
    acc = acc * 10 + (int(c) - int('0'))
    if acc > 1000000:
      return default
  result = acc

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

proc onOrbitContainers(url, body, session: string): string =
  ## The loot-table census for ONE map, named in the query (`?map=Woods`) or
  ## in the body, with no raid running.
  ##
  ## It exists so the falsifiable assertion can be a NEGATIVE over EVERY map
  ## -- "no map's loot tables fail to parse" -- rather than an observation
  ## about whichever map a raid happened to load. `/orbit/plan` cannot answer
  ## that: it reports the last plan built, and there is at most one.
  ##
  ## Takes the id the CLIENT uses ("Woods"); `lootCensusFor` resolves it
  ## through `canonicalLocation` and reports BOTH spellings, so an unresolved
  ## id and an empty map are distinguishable in the answer.
  inc gRequests
  var map = queryValue(url, "map")
  if map.len == 0:
    map = field(body, "map").asText("")
  result = lootCensusFor(map)

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
    # Through the ONE resolver: the client sends `base.Id` ("Interchange")
    # and the table is keyed by the database key ("interchange"), so a raw
    # read missed on 13 of 19 maps and silently returned the DEFAULT bot cap
    # instead of the map's own -- a wrong number, not an error.
    let key = canonicalLocation(loc)
    let pve = dbRead("locations." & key & ".base.BotMaxPvE")
    if pve.ok and pve.asInt(0) > 0:
      return envelope(raw($pve.asInt(0)))
    let cap = dbRead("locations." & key & ".base.BotMax")
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

proc mailServed(route, payload: string): string =
  ## The last thing that happens to a mail body before it goes on the wire.
  ##
  ## Announces, and does not alter. `emu/mailcheck.mailPayloadProblems` asserts
  ## a property of these FINISHED BYTES -- no attachment is a stash/container
  ## root, every sender id is one the client can name -- rather than of
  ## anything this server just wrote. Silently repairing here would hide the
  ## writer's bug, which is the whole reason the last one lived long enough to
  ## reach a player's inbox: every step of it succeeded.
  let problems = mailPayloadProblems(payload)
  for pr in problems:
    error route & ": " & pr
  result = payload

proc onMailList(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyArray())
  result = envelope(raw(mailServed("mail/dialog/list", dialogList(p.id))))

proc onMailView(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyObject())
  let dialogId = field(body, "dialogId").asText("")
  result = envelope(raw(mailServed("mail/dialog/view",
                                   dialogView(p.id, dialogId))))

proc onMailDialogInfo(url, body, session: string): string =
  ## `/client/mail/dialog/info` -- the header of ONE dialog: the sender, its
  ## newest message, its unread count and its parcel badge.
  ##
  ## This was served by `onEmptyObject`. `{}` is a correct answer for a dialog
  ## that does not exist and a wrong one for a dialog that does, and the two
  ## are indistinguishable to the client: it takes the empty header, draws a
  ## row with no preview and no badge, and the player's insurance return has
  ## no visible unread mark. Same shape of defect as the hard-coded `new: 0`
  ## that `dialogList` used to carry.
  ##
  ## Built by selecting out of `dialogList` rather than by assembling a header
  ## here, so the row this route draws and the row the inbox draws cannot
  ## disagree -- a second place deciding what a dialog header looks like is
  ## how the two drift apart.
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyObject())
  # Not gated on a non-empty id. A system message is delivered with an empty
  # sender -- `mkSystem` renders without one, which is what an achievement, an
  # insurance return and the BTR hand-over all want -- so `""` is a real dialog
  # in this mailbox and refusing to look it up would be the same wrong answer
  # in a smaller place.
  let dialogId = field(body, "dialogId").asText("")
  let rows = each(whole(dialogList(p.id)))
  for row in rows:
    if row.field("_id").asText("") == dialogId:
      let header = raw(row)
      return envelope(raw(header))
  # No such dialog. `{}` is the honest answer *here* -- and it is now only ever
  # sent when the dialog genuinely is not in the mailbox.
  warn "mail/dialog/info asked for dialog '" & dialogId &
       "', which is not in this profile's mailbox; an empty header was sent"
  result = envelope(emptyObject())

proc onMailAttachments(url, body, session: string): string =
  inc gRequests
  let p = currentProfile(session)
  if not p.ok:
    return envelope(emptyObject())
  result = envelope(raw(mailServed("mail/dialog/getAllAttachments",
                                   allAttachments(p.id))))

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

  # The ORBIT plan and its verdict. Under `/aowlspt/tarkov/` rather than
  # `/aowlspt/orbit/`, measured: a route registered at `/aowlspt/orbit/plan`
  # 404s on a running backend while `/aowlspt/tarkov/launcher/ping` beside it
  # answers, so that namespace does not reach a mod on this host.
  discard serve("/aowlspt/tarkov/orbit/plan", onOrbitPlan)
  discard serve("/aowlspt/tarkov/orbit/containers", onOrbitContainers)
  discard serve("/aowlspt/tarkov/objectives/catalog", onObjectiveCatalog)

  # The automation library's gear side. Same namespace as the launcher routes,
  # measured to be the one that reaches a mod on this host.
  discard serve("/aowlspt/tarkov/autoscript/loadout", onAutoscriptLoadout)
  discard serve("/aowlspt/tarkov/autoscript/verify", onAutoscriptVerify)
  discard serve("/aowlspt/tarkov/autoscript/capabilities", onAutoscriptCaps)

  # AutoRaid's ephemeral loadout status. Both namespaces; see the handler.
  discard serve("/aowlspt/autoraid/loadout/status", onAutoRaidLoadoutStatus)
  discard serve("/aowlspt/tarkov/autoraid/loadout/status",
                onAutoRaidLoadoutStatus)

  discard serve("/client/profile/status", onProfileStatus)
  # `GetProfileSettings` answers a bare `true`; the client only checks that the
  # call succeeded.
  discard serve("/client/profile/settings", onTrue)
  discard serve("/client/game/profile/search", onEmptyArray)
  discard serve("/client/libraries", onLibraries)
  discard serve("/client/profile/view", onEmptyObject)

  # Binary assets. The client fetches trader avatars, handbook icons and quest
  # images from `/files/*` and, when they 404, retries on a timer and stalls the
  # screen. One prefix route answers every one of them with a placeholder PNG.
  # Post-1.0 resolves these against its asset-CDN base, whose url carries a
  # `/regular` path prefix, so once the host redirects that CDN host here the
  # requests arrive as `/regular/files/...` -- registered alongside the bare
  # `/files/` spelling so both resolve. See `onFiles`.
  discard servePrefix("/files/", onFiles)
  discard servePrefix("/regular/files/", onFiles)

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
  # And without the trailing slash. `servePrefix` requires one, so the bare
  # `/client/items/prices` -- which is a literal in the client's own string
  # table -- matched nothing and 404'd. The handler never reads the URL, so
  # both spellings are the same answer.
  discard serve("/client/items/prices", onItemPrices)

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
  # Both spellings. MEASURED against the client's own string table (the
  # decrypted `global-metadata`): `/client/airdrop/loot` occurs ONCE and
  # `/client/location/getAirdropLoot` occurs ZERO times -- i.e. the route this
  # server has always served is one this client never calls, and the one it
  # does call 404'd. The old name is kept because a pre-1.0 client does use it
  # and removing it would trade one silent gap for another.
  discard serve("/client/airdrop/loot", onAirdropLoot)
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
  discard serve("/client/mail/dialog/info", onMailDialogInfo)
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
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Starting edition applied to a fresh profile"),
    enumSetting("defaultSide", "Default side", "Usec", @["Usec", "Bear"],
                category = "Emulator",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("startingRoubles", "Starting roubles", 500000,
               lo = 0, hi = 100000000, step = 1000, category = "Emulator",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("epochBase", "Epoch base (seconds)", 1700000000,
               category = "Emulator",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. The Unix time the emulator's clock starts from"),

    # The label used to read "Insurance return chance (%)", which is not what
    # this number is: `emu/insurance.premiumFor` multiplies the item's handbook
    # price by it to work out what the TRADER CHARGES. Nothing anywhere reads
    # it as a chance. The row is renamed rather than left flattering, because a
    # row that names the wrong mechanic is worse than no row.
    #
    # 0 is "insurance costs nothing" -- the free case, wired at that one site
    # rather than as a second boolean, since a multiplier that can reach zero
    # already expresses it and two controls for one number disagree eventually.
    intSetting("insurancePercent", "Insurance premium (% of item value)", 10,
               lo = 0, hi = 100, category = "Traders/Insurance",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. What the trader charges to insure an item, as a percentage of its handbook price (emu/insurance.premiumFor). 0 makes insurance free"),
    # 0 is "instant": `queueReturn` records `dueAt = now`, and the next pass of
    # `deliverDue` posts the items back through the trader's own mail. The
    # return is a real mechanic here -- premium taken, items held in the store,
    # message delivered -- so the instant case is the timer set to zero and not
    # a separate switch.
    intSetting("insuranceReturnHours", "Insurance return delay (hours)", 24,
               lo = 0, hi = 168, category = "Traders/Insurance",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. How long a trader holds insured gear before mailing it back (emu/insurance.queueReturn / deliverDue). 0 returns it on the next delivery pass"),

    intSetting("scavCooldownSeconds", "Scav cooldown (seconds)", 900,
               lo = 0, hi = 86400, step = 60, category = "Scav",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    floatSetting("fenceKarmaOnScavExtract", "Fence karma on scav extract", 0.01,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "Scav",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    floatSetting("fenceKarmaOnScavDeath", "Fence karma on scav death", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "Scav",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),

    intSetting("defaultBotLimit", "Default bot limit", 30, lo = 0, hi = 200,
               category = "Bots",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Bot limit for a map the database says nothing about"),

    intSetting("mailKeepHours", "Mail keep (hours)", 72, lo = 0, hi = 8760,
               category = "Mail",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Inbox age bound; 0 or below keeps the whole history"),
    intSetting("mailKeepCollected", "Keep collected mail", 1, lo = 0, hi = 1,
               category = "Mail",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),

    # ---- the flea market ------------------------------------------------
    #
    # Two things this page deliberately does NOT duplicate. "Is the flea open
    # at all" and "from what level" are `RagFair Enabled` and `RagFair Min
    # User Level` under `Flea Market > RagFair` -- generated rows that write
    # `globals.config.RagFair.enabled` / `.minUserLevel` in the document the
    # client fetches, which is where the client reads both. A second control
    # for either would be a row that fights the one that actually works.
    intSetting("fleaSpreadPercent", "Flea price spread (%)", 20, lo = 0, hi = 100,
               category = "Flea Market/Offers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("fleaOfferHours", "Flea offer duration (hours)", 12,
               lo = 1, hi = 168, category = "Flea Market/Offers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("fleaMaxOffers", "Flea max offers", 600, lo = 1, hi = 10000,
               category = "Flea Market/Offers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("fleaSaleMinutes", "Flea sale time (minutes)", 30, lo = 0,
               hi = 1440, category = "Flea Market/Offers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    floatSetting("fleaPriceMultiplier", "Flea price multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.05,
                 category = "Flea Market/Offers",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales every asking price on the flea, at BOTH places an offer is born (emu/market.scaleFleaPrice). `buyOffer` charges the offer's own price, so the label and the bill cannot disagree. 0 is free"),
    intSetting("fleaSellFeePercent", "Flea listing fee (%)", 0, lo = 0, hi = 100,
               category = "Flea Market/Selling",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. A percentage of the asking price, taken out of the stash when you LIST something (emu/market.addOffer). 0, the default, is what this server did before: listing is free"),
    # Declared and NOT wired, with the reason on the row.
    #
    # The client-side flag exists (`RagFair Is Only Found In Raid Allowed`
    # under `Flea Market > RagFair`) and is served, but the SERVER cannot
    # enforce it: nothing in this emulator ever stamps `upd.SpawnedInSession`
    # on anything a raid produced -- `emu/repeatable` says so in as many words
    # about the same field. A server-side found-in-raid check would therefore
    # not be a restriction, it would refuse every listing, always. That is a
    # missing mechanic upstream of this row, so the row says so instead of
    # pretending.
    boolSetting("fleaSellRequiresFoundInRaid",
                "Flea selling requires found in raid", false,
                category = "Flea Market/Selling", implemented = false,
                description = "aowlspt original (server emulator); acts on the SPT-derived database. NOT WIRED: this server never stamps upd.SpawnedInSession on raid loot, so a found-in-raid check could only ever refuse every listing rather than restrict any. The client-side flag is separately available as Flea Market > RagFair > Is Only Found In Raid Allowed"),

    # ---- THE LOOT PAGE -------------------------------------------------
    #
    # Six `category` values, not one, because a category is the ONE structural
    # device this settings system has: `modSetGroupByCategory` in the host
    # renderer buckets rows by `category` and draws a header row ahead of each
    # bucket. There is no sub-page, no tab and no two-column layout in
    # `settingspages.nim` -- a page IS a flat `seq[SwRow]` -- so grouped
    # sections in a fixed order is the richest screen this build can express,
    # and these six are it. `subcategory` is NOT read by the renderer (it
    # parses `category` only), so it is not used to carry structure here.
    #
    # `lootPreset` and `lootSummary` are the two rows that make the page
    # legible without the documentation: a one-click preset that writes the
    # knobs below it, and a sentence the SERVER writes describing what the
    # current combination will actually do. Both follow the pattern
    # `spawnNow`/`spawnResult` already established -- see `onTarkovSettings`.
    enumSetting("lootPreset", "Loot preset", "custom",
                @["custom", "vanilla", "scarce", "richer", "goblin"],
                category = "Loot/Presets",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Picking anything other than `custom` WRITES the knobs in the sections below and then the page shows what it wrote, so a preset is a starting point you can then fine-tune rather than a mode that locks the sliders. `vanilla` restores every loot knob to its shipped default. `scarce` halves both passes and biases toward cheap items; `richer` is 1.5x with fuller containers; `goblin` is 3x with the container cap raised and a bias toward valuables. Changing any individual knob afterwards does NOT reset this row -- it is a button, not a mode."),
    stringSetting("lootSummary", "What this configuration does", "",
                  category = "Loot/Presets",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. WRITTEN BY THE SERVER, not by you: one sentence describing what the current loot configuration will actually do, recomputed from emu/loot.lootConfig() -- the same object the generator reads -- every time any loot row is saved. If this line disagrees with what you set, the generator agrees with THIS line."),

    floatSetting("bossSpawnChanceMultiplier", "Boss spawn chance multiplier",
                 1.0, lo = 0.0, hi = 5.0, step = 0.1,
                 category = "Bots/Bosses",
      description = "aowlspt original (server emulator); acts on the post-1.0 location table. Scales every boss's own BossChance before the server rolls it, once per raid, seeded from the raid id (emu/raid.rollBossSpawnList). 1.0 is BSG's own numbers -- Woods is Shturman 45%, the Goons 15%, Partisan 10%, Cultists 10%. 0 means no bosses at all. Anything at or above 2.0 makes most bosses certain, which is what the server used to do by accident."),
    boolSetting("cultistsEnabled", "Cultists may spawn", true,
                category = "Bots/Bosses",
      description = "aowlspt original (server emulator); acts on the post-1.0 location table. The sectantPriest/sectantWarrior entries. They are the most expensive AI in the game and they roll independently of the map boss, so turning them off is the cheapest single thing you can do for raid framerate. On means they still only spawn at their data chance (10% on Woods), not every raid."),
    boolSetting("bossSlotExclusive", "One map boss per raid", true,
                category = "Bots/Bosses",
      description = "aowlspt original (server emulator); acts on the post-1.0 location table. Bosses that compete for a map's boss slot -- Shturman OR the Goons on Woods, Reshala OR Wedge on Customs -- are rolled in the table's order and the first winner takes the slot. Off lets every one of them roll independently, which is the pre-fix behaviour and can put four boss groups in one raid. Partisan and the Cultists are not part of the slot and always roll on their own."),

    boolSetting("stagedStart", "Staged raid start (defer extra waves)", false,
                category = "Bots/Spawns", appliesOn = "next raid",
      description = "aowlspt original (server emulator); acts on the post-1.0 location table. OFF serves the pre-existing table: 12 waves at Time:-1 (40 bots) plus every rolled boss, all placed synchronously while the raid loads -- measured at 41.9-49.5 s from PlayerSpawnEvent to GameRunned on Woods (docs/MOD-PERF.md). ON keeps the SAME waves and the SAME bots per raid but leaves at most 'Staged start: bots at start' on the synchronous arm and moves the rest to the timer arm from 'Staged start: first delay' onward, gives every immediate boss 'Staged start: boss delay', and restores the map's own BotStart (the non-wave spawner the client refuses at 0). The served table is logged per map as 'staged-start readback'."),
    intSetting("stagedStartInitialBots", "Staged start: bots at start", 0,
               lo = 0, hi = 60, step = 2, category = "Bots/Spawns",
               appliesOn = "next raid",
      description = "aowlspt original (server emulator). How many bots stay on the synchronous Time:-1 arm when staged start is ON. 0 means the map's own vanilla at-start total (Woods: 8), never below 4 (one wave)."),
    intSetting("stagedStartFirstDelaySec", "Staged start: first delay (s)", 20,
               lo = 5, hi = 300, step = 5, category = "Bots/Spawns",
               appliesOn = "next raid",
      description = "aowlspt original (server emulator). time_min of the first deferred wave; each further deferred wave lands 10 s later. 20 s puts the first one right after the 10 s deploy countdown."),
    intSetting("stagedStartBossDelaySec", "Staged start: boss delay (s)", 45,
               lo = 0, hi = 600, step = 5, category = "Bots/Spawns",
               appliesOn = "next raid",
      description = "aowlspt original (server emulator). The Time written on every rolled boss that the table ships at Time:-1 (Shturman, the Goons, the Cultists); a boss already on its own clock (Partisan at 900) or on a trigger is left alone. INFERRED from Partisan's own Time being honoured; the boss-roll log names the Time each kept boss was served with."),

    boolSetting("lootEnabled", "Loot enabled", true, category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The master switch. Off means every map serves an empty floor, and the server says so in its log rather than serving a silent []."),
    floatSetting("lootGlobalMultiplier", "Global loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies BOTH the container pass and the loose pass, on top of their own multipliers (emu/loot.generateLoot). 1.0 is the shipped behaviour; 0 empties the map."),
    floatSetting("staticLootMultiplier", "Container loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales both how OFTEN a container spawns and how FULL it is. Split the two with the Containers section below."),
    floatSetting("looseLootMultiplier", "Loose loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales the probability of every loose spawn point on the map (emu/loot.looseLoot)."),
    intSetting("maxLootItems", "Max loot items", 20000, lo = 0, hi = 200000,
               step = 1000, category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. A hard ceiling on the items in one raid's Loot array. Three real maps produce 1,826 items between them against this default, so it binds only a pathological table or a very large multiplier."),
    floatSetting("lootStaticBudgetShare", "Container share of the item budget",
                 0.5, lo = 0.0, hi = 1.0, step = 0.05,
                 category = "Loot/Global",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. How much of Max loot items the container pass may spend before the loose pass runs; whatever it does not spend is handed on. 0.5 is the half-and-half split the generator used to hardcode. Raise it only if containers are being cut off."),

    boolSetting("staticLootEnabled", "Containers spawn loot", true,
                category = "Loot/Containers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Off skips the static-container pass entirely: no crates, safes, jackets or weapon boxes anywhere on the map."),
    floatSetting("containerSpawnChanceMultiplier",
                 "Container spawn chance multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1,
                 category = "Loot/Containers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales each container's own `probability` -- HOW MANY crates exist this raid, without changing how full they are. Containers marked IsAlwaysSpawn ignore this, as they do every other chance."),
    floatSetting("containerFillMultiplier", "Container fill density", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1,
                 category = "Loot/Containers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales the item COUNT drawn from a container's own itemcountDistribution -- how full each crate is, without changing how many crates there are. An item that does not fit the grid is still dropped rather than stacked on one that did."),
    intSetting("containerMaxItems", "Container item cap", 64, lo = 1, hi = 512,
               step = 1, category = "Loot/Containers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The most items one container may be asked to hold, after the fill multiplier. 64 is the number the generator used to hardcode. Raise it if a high fill density is being clipped; the container's own grid is still the real limit."),
    stringSetting("containerTypeChances", "Per-container-type chances", "",
                  category = "Loot/Containers",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. `templateId=multiplier` pairs, comma separated, applied to that container TEMPLATE's spawn chance only -- e.g. `578f87b7245977356274f2cd=2` doubles the ground caches. The id is the container item's own template (`Items[0]._tpl` of the spawn point). A malformed pair is dropped and the count that survived is reported in the summary line; it is never read as zero."),

    boolSetting("looseLootEnabled", "Loose loot spawns", true,
                category = "Loot/Loose",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Off skips the loose pass entirely: nothing on the floor, in jackets' place, or on shelves. Loose-loot spawn points are SERVER-side data (they are not recoverable from the client's scene files), so this switch is the only thing that controls them."),
    boolSetting("lootForcedSpawns", "Forced quest/key spawns", true,
                category = "Loot/Loose",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. `spawnpointsForced` -- the quest items and keys that ignore probability entirely. Leave this ON unless you know a quest you are running does not need its item; turning it off can make a quest uncompletable."),
    intSetting("looseLootPointLimit", "Loose spawn point limit", 0, lo = 0,
               hi = 100000, step = 50, category = "Loot/Loose",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. At most this many non-forced loose points may spawn on one map. 0, the default, is no limit. Use it to thin a map without changing WHICH points can spawn -- the multiplier changes the odds, this changes the ceiling."),

    floatSetting("lootValueBias", "Bias toward valuables", 0.0, lo = -2.0,
                 hi = 2.0, step = 0.1, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Reweights every loot pool by the item's HANDBOOK price. Above 0 favours expensive items, below 0 favours cheap ones, 0 is off and the shaping code is not run at all. An item the handbook does not list is left unweighted rather than treated as worthless. The effect is bounded at 20x the pivot so one absurd price cannot swallow a pool."),
    floatSetting("lootValuePivot", "Value bias pivot (roubles)", 20000.0,
                 lo = 1.0, hi = 1000000.0, step = 1000.0,
                 category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The handbook price at which Bias toward valuables has no effect. Items above it are favoured by a positive bias, items below it by a negative one."),
    intSetting("lootMinHandbookPrice", "Minimum item value (roubles)", 0,
               lo = 0, hi = 1000000, step = 500, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Items cheaper than this are removed from every loot pool before anything is drawn. 0 is off. An item the handbook does not list is NOT removed."),
    intSetting("lootMaxHandbookPrice", "Maximum item value (roubles)", 0,
               lo = 0, hi = 10000000, step = 5000, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Items dearer than this are removed from every loot pool. 0 is off."),
    floatSetting("lootRarityCommon", "Common item weight", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose template declares `_props.RarityPvE` (or `_props.Rarity`) = Common. If NO item in a pool declares a rarity, the server says so in its log rather than letting the slider read as broken."),
    floatSetting("lootRarityRare", "Rare item weight", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As above, for Rare."),
    floatSetting("lootRaritySuperrare", "Superrare item weight", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Item mix",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As above, for Superrare. 0 removes superrare items from every pool."),
    # ---- Loot > Item mix > Category weights ---------------------------
    #
    # This subsection is the answer to "a 28-row flat list". The five families
    # people actually reweight are named sliders now; the free-text row below
    # them stays for everything else and is applied ON TOP, so the advanced
    # escape hatch is not removed and the two cannot disagree without a stated
    # winner (emu/loot.categoryWeightsFromSettings).
    #
    # A slider at 1.0 emits NO entry at all, which is what keeps the shaping
    # pass skipped entirely at defaults rather than run with neutral numbers.
    floatSetting("lootWeightMoney", "Money", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches the money base class 543be5dd4bdc2deb348b4569. 1.0 emits no entry at all; 0 removes money from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, the id does not match this database and the slider is doing nothing."),
    floatSetting("lootWeightAmmo", "Ammunition", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As Money, for base class 5485a8684bdc2da71d8b4567."),
    floatSetting("lootWeightMeds", "Medical", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As Money, for base class 543be5664bdc2dd4348b4569."),
    floatSetting("lootWeightKeys", "Keys", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As Money, for base class 543be5e94bdc2df1348b4568."),
    floatSetting("lootWeightBarter", "Barter items", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As Money, for base class 5448eb774bdc2d0a728b4567."),
    stringSetting("lootCategoryWeights", "Advanced: extra id=multiplier pairs", "",
                  category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. APPLIED ON TOP OF THE FIVE SLIDERS ABOVE, and it wins where they overlap. `id=multiplier` pairs, comma separated, where `id` is any item template id OR any BASE CLASS id on its `_parent` chain -- so one entry covers a whole family. The chain is walked up to 12 hops and refuses to revisit a template. The community's usual base classes: money 543be5dd4bdc2deb348b4569, ammo 5485a8684bdc2da71d8b4567, meds 543be5664bdc2dd4348b4569, keys 543be5e94bdc2df1348b4568, barter 5448eb774bdc2d0a728b4567. Those five ids are SPT-community-known and were NOT verified against this install's database by the change that added this row -- check the log line the server prints, which reports how many pool entries the weights actually touched."),
    # ---- Loot > Item mix > Category weights, the other seventeen ------
    #
    # Five families were named sliders; the other seventeen were reachable only
    # by pasting a 24-character base-class id into the free-text row, which is
    # not a control surface, it is a documentation lookup. Each id below was
    # READ OUT OF THIS INSTALL'S OWN db.json on 2026-08-31 -- `bigjson.py get
    # --path templates.items.<id>._name` returned the name in the description
    # -- so none of them is community lore. One candidate that did NOT resolve
    # against this database was dropped rather than shipped as a slider that
    # reweights nothing.
    #
    # Every one is 1.0 by default and a slider at 1.0 emits NO pool entry, so
    # the shaping pass is still skipped entirely and the RNG stream is
    # unchanged for anyone who never opens the page.
    floatSetting("lootWeightAmmoBoxes", "Ammo boxes", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 543be5cb4bdc2deb348b4568, which this install's db.json names `AmmoBox` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightFood", "Food and drink", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 543be6674bdc2df1348b4569, which this install's db.json names `FoodDrink` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightElectronics", "Electronics", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 57864a66245977548f04a81f, which this install's db.json names `Electronics` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightValuables", "Valuables (jewellery)", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 57864a3d24597754843f8721, which this install's db.json names `Jewelry` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightWeapons", "Weapons", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5422acb9af1c889c16000029, which this install's db.json names `Weapon` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightKnives", "Knives", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5447e1d04bdc2dff2f8b4567, which this install's db.json names `Knife` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightMods", "Weapon attachments", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448fe124bdc2da5018b4567, which this install's db.json names `Mod` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightMagazines", "Magazines", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448bc234bdc2d3c308b4569, which this install's db.json names `Magazine` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightArmor", "Body armour", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448e54d4bdc2dcc718b4568, which this install's db.json names `Armor` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightHelmets", "Helmets", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5a341c4086f77401f2541505, which this install's db.json names `Headwear` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightRigs", "Chest rigs", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448e5284bdc2dcb718b4567, which this install's db.json names `Vest` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightBackpacks", "Backpacks", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448e53e4bdc2d60728b4567, which this install's db.json names `Backpack` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightGrenades", "Grenades", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 543be6564bdc2df4348b4568, which this install's db.json names `ThrowWeap` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightContainers", "Cases and containers", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5795f317245977243854e041, which this install's db.json names `SimpleContainer` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightStims", "Stimulants", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5448f3a64bdc2d60728b456a, which this install's db.json names `Stimulator` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightTools", "Tools", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 57864bb7245977548b3b66c2, which this install's db.json names `Tool` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),
    floatSetting("lootWeightSpecial", "Special items", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Loot/Item mix/Category weights",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of every item whose `_parent` chain reaches base class 5447e0e74bdc2d3c308b4567, which this install's db.json names `SpecItem` (measured 2026-08-31). 1.0 emits no entry at all; 0 removes the family from every pool. The summary line reports how many pool entries the weights actually touched -- if it says none, no item in the pool descends from this class."),

    # ---- Loot > Money ---------------------------------------------------
    #
    # The section the single-dollar drop earned. `emu/bots.randomStackCount`
    # fixed the *absence* of a stack count; nothing made the resulting number
    # visible or adjustable, so "why is this scav carrying one dollar" was
    # still a question nobody could answer from the screen.
    #
    # The three currency template ids and their declared spawn ranges were read
    # out of this install's db.json on 2026-08-31 and are quoted on each row, so
    # the page states what the untouched game does before anyone moves a slider.
    # All three descend from the Money base class, so the Money family weight
    # above AND the currency row here both apply and both multiply; the
    # currency row is the more specific of the two and is applied last.
    floatSetting("lootCurrencyRoubles", "Roubles in loot pools", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of template 5449016a4bdc2d6f028b456f -- this database spawns it in stacks of 5500..13500 with a hard cap of 1,000,000. It is a weight on HOW OFTEN this currency is drawn, not on how much of it: the stack size is the three rows below. 0 removes this currency from every pool and leaves the other two."),
    floatSetting("lootCurrencyDollars", "Dollars in loot pools", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of template 5696686a4bdc2da3298b456a -- this database spawns it in stacks of 45..100 with a hard cap of 50,000. It is a weight on HOW OFTEN this currency is drawn, not on how much of it: the stack size is the three rows below. 0 removes this currency from every pool and leaves the other two."),
    floatSetting("lootCurrencyEuros", "Euros in loot pools", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the pool weight of template 569668774bdc2da2298b4568 -- this database spawns it in stacks of 35..90 with a hard cap of 50,000. It is a weight on HOW OFTEN this currency is drawn, not on how much of it: the stack size is the three rows below. 0 removes this currency from every pool and leaves the other two."),
    floatSetting("moneyStackMultiplier", "Money stack multiplier", 1.0,
                 lo = 0.0, hi = 50.0, step = 0.1, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales every CURRENCY stack, in world loot AND in a bot's pockets -- both generators read this one key through emu/knobs.moneyStackConfig, so the floor and the corpse cannot disagree. Applied after the roll and after the generic stack cap, then bounded by the item's own StackMaxSize, which is the client's limit and not ours to exceed. Loose ammunition declares the same kind of spawn range and is deliberately NOT touched by this row."),
    intSetting("moneyStackMin", "Minimum money stack", 0, lo = 0,
               hi = 1000000, step = 100, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The smallest currency stack that may spawn, after the multiplier. 0, the default, is no floor -- the item's own declared range decides. Set it to 1000 and no rouble pile below a thousand exists; note the same number is applied to dollars and euros, whose whole declared range is 45..100, so a floor set for roubles will flatten the other two."),
    intSetting("moneyStackMax", "Maximum money stack", 0, lo = 0,
               hi = 1000000, step = 100, category = "Loot/Money",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The largest currency stack that may spawn, after the multiplier. 0, the default, is no ceiling. This is the row for the complaint that world money piles are absurd: this database lets a rouble stack reach 1,000,000, while the game's own declared spawn range is 5500..13500."),

    # ---- Bots > Gear ----------------------------------------------------
    #
    # The other half of "what people spawn with", and the half that had no
    # control surface at all: before this, one number -- the Bot AI mod's
    # `configs.botLoot.richnessMultiplier` -- governed every bot in the game,
    # and nothing at all governed what they WORE.
    #
    # Every row below is a MULTIPLIER ON THE DATABASE'S OWN NUMBER
    # (`bots.types.<role>.chances`), never a replacement for it. None of them
    # can put an item in a slot the role's pool does not name, and at exactly
    # 1.0 `emu/botgear.scalePercent` returns its input with no arithmetic at
    # all -- so an untouched page draws the same bot, roll for roll. That is
    # what makes this a control surface rather than a second generator
    # competing with the first.
    #
    # Composability is the answer to "a 200-row list": the number that reaches
    # a slot is global x family x slot, all three defaulting to 1.0, so a
    # player who only wants everyone better equipped moves ONE row.
    boolSetting("botGearEnabled", "Bot gear tuning enabled", true,
                category = "Bots/Gear",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The master switch for every row in Bots > Gear and Bots > Loot. OFF makes all of them return 1.0 without acting on their values -- the database own chances, untouched -- so it is the one-click way back from any experiment without setting thirty rows to 1.0 by hand. It does NOT disable bot gear; a bot still wears what its table says."),
    floatSetting("botGearMultiplier", "Global gear multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Bots/Gear",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies EVERY equipment slot chance, for every bot family, on top of the per-family and per-slot rows below. 2.0 roughly doubles how often an optional slot is filled -- a chance is still capped at certain, never more -- and 0 strips every optional slot, leaving bots in whatever their table marks required. Pockets are exempt: a bot without them does not spawn (emu/bots.addLoadout)."),
    floatSetting("botWeaponModChance", "Weapon attachment chance", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Bots/Gear",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies `chances.weaponMods` -- how often an OPTIONAL attachment (a scope, a grip, a suppressor) is fitted. Slots the weapon marks `_required` are untouched, because a rifle missing a required part is a gun with a hole in it rather than a plainer gun. 0 gives every bot an iron-sighted stock weapon."),
    floatSetting("botEquipmentModChance", "Gear attachment chance", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Bots/Gear",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. As above, for `chances.equipmentMods` -- helmet armour plates, visors, headset attachments and armour inserts. Lowering it is the cheapest way to make helmeted bots less bullet-proof without removing the helmet."),

    # ---- Bots > Gear > Per bot type -------------------------------------
    #
    # Nine families, covering all 57 role keys read out of this install's
    # `bots.types` on 2026-08-31. Classified by prefix, because that is how the
    # database itself groups them; the ninth, `Other`, is the honest catch-all
    # rather than a silent gap.
    floatSetting("botGearScav", "scav gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for scav bots, on top of the global row and under the per-slot rows. Database roles in this family: assault, cursedassault, crazyassaultevent, marksman, arenafighterevent, peacemaker and gifter."),
    floatSetting("botGearUsec", "PMC USEC gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for PMC USEC bots, on top of the global row and under the per-slot rows. Database roles in this family: pmcusec and usec."),
    floatSetting("botGearBear", "PMC BEAR gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for PMC BEAR bots, on top of the global row and under the per-slot rows. Database roles in this family: pmcbear and bear."),
    floatSetting("botGearRaider", "raider gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for raider bots, on top of the global row and under the per-slot rows. Database roles in this family: pmcbot."),
    floatSetting("botGearRogue", "rogue gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for rogue bots, on top of the global row and under the per-slot rows. Database roles in this family: exusec."),
    floatSetting("botGearBoss", "boss gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for boss bots, on top of the global row and under the per-slot rows. Database roles in this family: every role whose key starts `boss` -- 14 of them in this database."),
    floatSetting("botGearFollower", "boss follower gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for boss follower bots, on top of the global row and under the per-slot rows. Database roles in this family: every role whose key starts `follower`, plus tagillahelperagro and shooterbtr."),
    floatSetting("botGearCultist", "cultist gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for cultist bots, on top of the global row and under the per-slot rows. Database roles in this family: every role whose key starts `sectant`."),
    floatSetting("botGearOther", "unclassified gear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies every equipment slot chance for unclassified bots, on top of the global row and under the per-slot rows. Database roles in this family: every role none of the eight rules above matches -- in this database that is the infected* and spirit* roles. It exists so that no role is silently ungoverned."),

    # ---- Bots > Gear > Per slot -----------------------------------------
    #
    # The twelve slots that are actually ROLLED. `Pockets` and
    # `SecuredContainer` are absent on purpose and the reason is measured, not
    # stylistic: the client dereferences `Equipment.Slots[8]` (Pockets)
    # unconditionally in `EFT.Player::HasMarkOfUnknown`, and `BotsGroup..ctor`
    # runs that over every player in the raid while a bot activates -- so a bot
    # whose pockets roll failed does not spawn without pockets, it does not
    # spawn at all and takes the activation with it. A slider that can set that
    # chance to zero is a slider that crashes raids, so it is not offered.
    floatSetting("botSlotHeadwear", "Helmets and hats", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Headwear` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotEarpiece", "Headsets", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Earpiece` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotFaceCover", "Face covers", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.FaceCover` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotArmorVest", "Body armour", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.ArmorVest` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotEyewear", "Eyewear", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Eyewear` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotArmBand", "Armbands", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.ArmBand` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotTacticalVest", "Chest rigs", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.TacticalVest` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotBackpack", "Backpacks", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Backpack` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotPrimaryWeapon", "Primary weapon", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.FirstPrimaryWeapon` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotSecondaryWeapon", "Second primary weapon", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.SecondPrimaryWeapon` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotHolster", "Sidearm", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Holster` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),
    floatSetting("botSlotScabbard", "Melee weapon", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Gear/Per slot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `chances.equipment.Scabbard` percentage the role own table declares. 0 means no bot ever spawns with this slot filled; above 1 makes it commoner up to certain, never more. A role whose table does not mention the slot is treated as 100 per cent before this multiplier, which is what the generator already did."),

    # ---- Bots > Loot ----------------------------------------------------
    #
    # What a bot CARRIES, as opposed to wears -- and therefore what the player
    # gets off the corpse. `emu/bots.addContainerLoot` fills each carried
    # container from that role's own pool and count table; these scale the
    # count, never the pool, so a role that carries nothing still carries
    # nothing (a multiplier on a roll of zero is zero, and that is the honest
    # reading of a table that said nothing).
    floatSetting("botLootMultiplier", "Global bot loot multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.1, category = "Bots/Loot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales how much loose loot every bot carries. It is applied ON TOP OF the Bot AI mod published `configs.botLoot.richnessMultiplier` rather than replacing it -- two owners, one number, and the order is stated so neither control silently wins. Above 1.0 it also raises the per-bot item bound, or the extra items would have nowhere in the budget to go."),
    intSetting("botLootMaxItems", "Loose items per bot (cap)", 24,
               lo = 0, hi = 200, step = 1, category = "Bots/Loot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The most loose items one bot may carry across its rig, backpack and pockets together. 24 is the number `emu/bots` used to hardcode as MaxLootPerBot. The multipliers scale this cap when they are above 1.0, so raising it by hand is only needed if you want a fuller bot at a multiplier of 1.0."),
    intSetting("botSpareMagazines", "Spare magazines per bot", 4,
               lo = 0, hi = 16, step = 1, category = "Bots/Loot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. How many loaded spare magazines go into a bot rig, at most, across all its weapons. 4 is the number `emu/bots` used to hardcode as MaxSpareMags. 0 is a real answer -- a bot with one magazine and no reload -- and it is the single largest thing you can change about how long a firefight lasts. Each spare is the model the weapon actually took and is filled with the correct calibre, so a spare that finds no room in any grid is dropped rather than written to a cell that overlaps something."),

    # ---- Bots > Loot > Per bot type -------------------------------------
    #
    # The same nine families as the gear section, so "raiders carry more, scavs
    # carry less" is two rows and not a table of template ids.
    floatSetting("botLootScav", "scav loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot scav bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootUsec", "PMC USEC loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot PMC USEC bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootBear", "PMC BEAR loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot PMC BEAR bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootRaider", "raider loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot raider bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootRogue", "rogue loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot rogue bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootBoss", "boss loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot boss bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootFollower", "boss follower loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot boss follower bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootCultist", "cultist loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot cultist bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),
    floatSetting("botLootOther", "unclassified loot", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies how much loose loot unclassified bots carry, on top of the global row and the Bot AI mod published richness. 0 empties their pockets; the equipment they WEAR is the gear section and is unaffected."),

    floatSetting("botLootVest", "Rig contents", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per container",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `generation.items.vestLoot` count -- how many loose items go in the chest rig specifically -- under the global and per-family rows. The pool is untouched: this changes how much, never what."),
    floatSetting("botLootPockets", "Pocket contents", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per container",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `generation.items.pocketLoot` count. Pockets themselves are never removed whatever this says -- the client dereferences Equipment.Slots[8] unconditionally and a bot without them does not spawn -- so 0 empties them rather than deleting them."),
    floatSetting("botLootBackpack", "Backpack contents", 1.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Bots/Loot/Per container",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Multiplies the `generation.items.backpackLoot` count. A plain scav's backpack pool has 1,851 entries in it, so this is the row with the most headroom. Nine other `generation.items` kinds (healing, grenades, stims, food, currency and the rest) have NO row and the reason is measured: they name a category no table resolves to templates, the generator does not produce them at all, and a slider wired to nothing is worse than an absent one."),

    intSetting("botSparesPerWeapon", "Spare magazines per weapon", 2,
               lo = 0, hi = 8, step = 1, category = "Bots/Loot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. How many spares of ITS OWN magazine each armed weapon contributes, before the per-bot cap above applies. 2 is the number emu/bots used to hardcode -- and 2 is exactly how many circular magazines the player counted beside a single-fed shotgun, which is what identified this path as the cause of that bug."),
    boolSetting("botSpareInternalMagazines",
                "Carry spares of fixed tube/cylinder magazines", false,
                category = "Bots/Loot",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. OFF (the default, and the fix) means a magazine the template marks `ReloadMagType: InternalMagazine` -- a pump shotgun's tube, a revolver's cylinder, a Mosin's box -- is never duplicated into a rig, as a spare or as loose loot. Those cannot be swapped in and hold no extra rounds; two of them beside a single-fed shotgun is the bug that was reported live. MEASURED on this install's database: 32 of the 502 (weapon, magazine) pairs the bot tables name are internal, and 12 of the 15 shotguns take one. Detachable magazines are entirely unaffected. ON restores the previous behaviour, bug included."),

    # ---- Bots > Quality -------------------------------------------------
    #
    # Every row above scales how OFTEN a slot is filled. These scale WHAT goes
    # in it, and they do it the one way that cannot invent an item: they
    # re-weight the role's own pool by a number the template itself declares.
    # A bot can never receive something its table does not already list.
    #
    # All three default to the no-op value, and the no-op is exact rather than
    # arithmetic: at 0.0 the biased picker returns `pickTemplate(pool, r)`
    # itself, one draw from the same vector, so the RNG stream and every bot in
    # the raid are identical to a build without the feature.
    floatSetting("botAmmoQuality", "Ammunition quality", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05, category = "Bots/Quality",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Leans every bot's ammunition toward the harder- or softer-hitting rounds THAT ROLE ALREADY LISTS, by `_props.PenetrationPower`. +1 is as armour-piercing as its own table allows, -1 as soft, 0 is the table's own weighting untouched. It is applied after the magazine's accepted-cartridge filter, so it can never load a round the magazine refuses; a calibre whose pool is all one penetration value is unaffected, which is the honest answer for a pool the property cannot rank."),
    floatSetting("botArmorTier", "Armour tier", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Leans every equipment pick toward heavier or lighter protection by `_props.armorClass`. +1 gives bots the best armour their own pool contains, -1 the worst, 0 the pool's own weighting. Only helmets, rigs and body armour declare an armour class, so a weapon or armband pool normalises to a constant and is untouched -- one row covers every slot without a table saying which slots are armour."),
    floatSetting("botMagazineFill", "Magazine fill", 1.0, lo = 0.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. The fraction of its own declared capacity each magazine is loaded to, so the same number means the same thing on a 6-round shotgun tube and a 60-round drum. 1.0, the default, is full, which is what the generator always did. It is floored at ONE round rather than zero: a magazine served empty is a bot that never fires."),

    # ---- Bots > Quality > Per bot type ----------------------------------
    #
    # The same nine families as the gear and loot sections. These ADD to the
    # global rows above rather than multiplying them -- a bias is a direction on
    # a scale that already has a zero, and multiplying would make "global 0,
    # scavs +1" come out at 0, the opposite of what the two rows say. The sum is
    # clamped to -1..1, so a family row can cancel the global one and neither
    # can run off the end.
    floatSetting("botAmmoScav", "scav ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for scav bots (assault, cursedassault, crazyassaultevent, marksman, arenafighterevent, peacemaker, gifter). 0 leaves the global row alone."),
    floatSetting("botAmmoUsec", "PMC USEC ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for PMC USEC bots (pmcusec, usec). 0 leaves the global row alone."),
    floatSetting("botAmmoBear", "PMC BEAR ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for PMC BEAR bots (pmcbear, bear). 0 leaves the global row alone."),
    floatSetting("botAmmoRaider", "raider ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for raider bots (pmcbot). 0 leaves the global row alone."),
    floatSetting("botAmmoRogue", "rogue ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for rogue bots (exusec). 0 leaves the global row alone."),
    floatSetting("botAmmoBoss", "boss ammunition", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for boss bots (every role whose key starts `boss` -- 14 of them in this database). 0 leaves the global row alone."),
    floatSetting("botAmmoFollower", "boss follower ammunition", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05,
                 category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for boss follower bots (every `follower*` role, plus tagillahelperagro and shooterbtr). 0 leaves the global row alone."),
    floatSetting("botAmmoCultist", "cultist ammunition", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05,
                 category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for cultist bots (every `sectant*` role). 0 leaves the global row alone."),
    floatSetting("botAmmoOther", "unclassified ammunition", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05,
                 category = "Bots/Quality/Ammunition per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global ammunition-quality row for every role none of the eight rules above matches -- in this database the infected* and spirit* roles. It exists so no role is silently ungoverned."),

    floatSetting("botArmorScav", "scav armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for scav bots. 0 leaves the global row alone; the pool is never widened, so a scav cannot receive armour its own table does not list."),
    floatSetting("botArmorUsec", "PMC USEC armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for PMC USEC bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorBear", "PMC BEAR armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for PMC BEAR bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorRaider", "raider armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for raider bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorRogue", "rogue armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for rogue bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorBoss", "boss armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for boss bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorFollower", "boss follower armour", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05,
                 category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for boss follower bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorCultist", "cultist armour", 0.0, lo = -1.0, hi = 1.0,
                 step = 0.05, category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for cultist bots. 0 leaves the global row alone; the pool is never widened."),
    floatSetting("botArmorOther", "unclassified armour", 0.0, lo = -1.0,
                 hi = 1.0, step = 0.05,
                 category = "Bots/Quality/Armour per bot type",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Added to the global armour-tier row for every role none of the eight rules above matches. It exists so no role is silently ungoverned."),

    boolSetting("lootStackRandomRange", "Use the item's own stack range", false,
                category = "Loot/Money & stacks",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. OFF (the shipped behaviour) rolls a stack uniformly over 1..StackMaxSize, which for currency is a far larger number than the game itself ever spawns. ON uses the template's declared `_props.StackMinRandom`..`StackMaxRandom` where it has one -- the SAME discriminator emu/bots.randomStackCount already uses for scav money, read here rather than duplicated. On stock data that is currency and loose ammunition and nothing else; everything else is unaffected either way. Turn this on if world money stacks look absurd."),
    floatSetting("lootStackMultiplier", "Stack size multiplier", 1.0, lo = 0.0,
                 hi = 10.0, step = 0.1, category = "Loot/Money & stacks",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales the rolled stack count for anything stackable, after the roll and before the cap. Never produces a stack below 1 or above the item's own StackMaxSize."),
    floatSetting("lootStackMaxFraction", "Stack size cap (fraction)", 1.0,
                 lo = 0.0, hi = 1.0, step = 0.05,
                 category = "Loot/Money & stacks",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. Caps every spawned stack at this fraction of the item's own StackMaxSize. 1.0, the default, is no cap. 0.05 on a 500,000-limit rouble stack caps it at 25,000."),

    stringSetting("lootPerMapMultipliers", "Per-map multipliers", "",
                  category = "Loot/Per-map",
      description = "aowlspt original (server emulator); acts on the SPT-derived database. `map=multiplier` pairs, comma separated, applied to BOTH passes on that map only -- e.g. `factory4_day=2, lighthouse=0.5`. The name must be the DATABASE location key (bigmap, woods, factory4_day, rezervbase), not the client-side Id, because the generator is handed the resolved key. A map set to 0 serves an empty floor and the server names this setting in its log when it does."),

    floatSetting("skillMaxPerRaid", "Skill max per raid", 100.0, lo = 0.0,
                 hi = 1000.0, step = 1.0, category = "Skills",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("masteringMaxPerRaid", "Mastering max per raid", 100, lo = 0,
               hi = 1000, category = "Skills",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),

    # ---- server-side economy and time modifiers ------------------------
    #
    # These five cannot ride the globals table: none of them is a value the
    # database keeps in `globals.config`. Each names the one function it
    # reaches, and each of those functions is the ONLY place its number is
    # produced, which is what keeps the row from becoming decorative.
    # OFF by default since the beta. It shipped `true`, which meant every
    # trader's whole stock was buyable at level 1 -- Prapor's 422
    # `loyal_level_items` entries were rewritten to 1 on the way out -- so the
    # honest answer to "are items gated by loyalty and quests" was "no". The
    # sandbox behaviour is still one switch away; it is just no longer the
    # thing a stranger gets without asking.
    # ---- progression ----------------------------------------------------
    #
    # Every row here is a FLOOR applied to the stored profile on each fetch,
    # never a ceiling and never a reset: a value already above the setting is
    # left alone, so leaving one of these on does not undo play, and turning one
    # back to 0 takes nothing away. Zero is off, throughout.
    #
    # Two of the three write a field the setting is NOT named after, because
    # that is the field the client reads. See the header of `emu/progression`.
    intSetting("progressionPlayerLevel", "Player level", 0, lo = 0, hi = 79,
               category = "Progression/Player",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Raise the character to at least this level. The client derives the level it draws from Info.Experience against globals.config.exp.level.exp_table and does not trust Info.Level, so this writes the matching EXPERIENCE (emu/progression.xpForLevel) and sets Info.Level alongside it. 0 is off; 79 is the length of the exp table on this database"),

    # The exact-XP row the old profile managers had. Not a duplicate of the row
    # above: the level row snaps to an exp-table boundary, this one sets a
    # number in between, and Info.Level is re-DERIVED from it rather than typed.
    intSetting("progressionExperience", "Experience (exact)", 0,
               lo = 0, hi = 100000000, step = 10000,
               category = "Progression/Player",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Raise Info.Experience to at least this number, and re-derive Info.Level from it against globals.config.exp.level.exp_table (emu/progression.levelForXp). A floor, like every row on this page: a profile already above it is untouched, and setting it back to 0 takes nothing away. 0 is off"),

    intSetting("progressionSkillLevel", "Skill level", 0, lo = 0, hi = 51,
               category = "Progression/Skills",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Raise every skill the profile already carries to at least this level, by writing Skills.Common[].Progress = level x 100. 51 is elite. Only ids ALREADY on the profile are touched, so this cannot reintroduce one of the 17 pre-1.0 ids the client answers \\\"Can't find skill to upgrade\\\" for. 0 is off"),
    stringSetting("progressionSkillIds", "Only these skills", "",
                  category = "Progression/Skills",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Comma-separated skill ids (Endurance, Strength, Perception ...) to restrict the row above to. Matched on the WHOLE id, case-insensitively -- a substring match would make one entry select several. Empty means every skill on the profile"),

    intSetting("progressionMasteryLevel", "Weapon mastery level", 0,
               lo = 0, hi = 3, category = "Progression/Mastery",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Raise every weapon family to at least this mastery level (1, 2 or 3) by writing Skills.Mastering[].Progress up to that family's own Level2/Level3 threshold out of globals.config.Mastering -- the thresholds differ per family (M4 is 1600/2000, SKS 200/300), so they are read, not assumed. 0 is off"),
    stringSetting("progressionMasteryFamilies", "Only these weapon families", "",
                  category = "Progression/Mastery",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Comma-separated family names (M4, AKM, AKSU, SKS ...) to restrict the row above to. Mastery is per weapon FAMILY, not per weapon: the 79 families on this database cover several templates each, which is why this is a filter and not 79 rows. Empty means every family"),

    boolSetting("traderUnlockAllOffers", "Unlock every trader offer", false,
                category = "Traders/Offers",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Sell every trader's whole stock from loyalty level 1, ignoring loyalty and quest gating (emu/traders.traderAssort). Off by default."),
    # A DIFFERENT axis from the row above, and the one that answers the error
    # a player actually sees. `traderUnlockAllOffers` moves every OFFER down to
    # loyalty 1; this moves the PLAYER up to the top level each trader defines.
    # Both are needed to describe "unlock the traders", and neither implies the
    # other -- loyalty level also sets the healing and repair price coefficients
    # (emu/health, emu/repair) and gates hideout recipes (emu/production), none
    # of which the assort rewrite touches.
    boolSetting("traderMaxLoyalty", "Max trader loyalty level", false,
                category = "Traders/Offers",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Put every trader at the highest loyalty level their own loyaltyLevels array defines, ignoring player level, sales sum and standing (emu/traders.loyaltyLevelFor). Applied in the derivation rather than written to the profile, because refreshLoyalty re-derives the stored number after every trade. Off by default"),
    floatSetting("traderPriceMultiplier", "Trader price multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.05, category = "Traders/Offers",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales every barter-scheme count, in BOTH the assort the client is shown and the cost the server charges -- scaling only one is a shop that shows one price and takes another"),
    # The per-item purchase limit, and only that. Loyalty and quest gating is
    # the row above; the price is the row above that. One switch per mechanic,
    # because a single "remove restrictions" toggle cannot be turned half on.
    boolSetting("traderIgnoreStockLimits", "Ignore trader stock limits", false,
                category = "Traders/Offers",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Removes the per-item purchase limit -- the assort's upd.StackObjectsCount check in emu/trading.buyFromTrader that answers \\\"that trader has only N of those\\\". Off by default"),
    floatSetting("repairPriceMultiplier", "Repair price multiplier", 1.0,
                 lo = 0.0, hi = 10.0, step = 0.05, category = "Traders/Repair",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales what a TRADER charges to repair (emu/repair.doTraderRepair). 0 makes trader repairs free. A kit repair is paid for in the kit's own Resource, not in roubles, so this does not touch it"),
    floatSetting("hideoutConstructionMultiplier",
                 "Hideout construction time multiplier", 1.0,
                 lo = 0.0, hi = 5.0, step = 0.05, category = "Hideout",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales every area upgrade duration (emu/hideout.upgradeSeconds). 0 makes upgrades instant"),
    floatSetting("hideoutProductionMultiplier",
                 "Hideout craft time multiplier", 1.0,
                 lo = 0.0, hi = 5.0, step = 0.05, category = "Hideout",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales a craft's duration when it STARTS; a craft already running keeps the terms it started on"),
    floatSetting("questXpMultiplier", "Quest experience multiplier", 1.0,
                 lo = 0.0, hi = 100.0, step = 0.1, category = "Quests",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales the experience a quest pays out (emu/quests.rewardExperience)"),

    # What the main menu's bottom-right corner reads. Three options, wired
    # through aowlspt/menutext (the literal key "menuCornerLabel" is also the
    # deploy marker for this feature -- see tools/deploy.json). See
    # `applyMenuCornerLabel` below for how each is represented on the wire.
    enumSetting("menuCornerLabel", "Menu corner label", "Profile Name",
                @["Profile Name", "PVE ZONE", "No text"], category = "Menu",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. What the main menu's bottom-right corner shows: the logged-in character's name, the stock \\\"PVE ZONE\\\", or nothing"),

    # ---- which maps the player may load into ---------------------------
    #
    # The three rows behind `emu/maplock`. `Locked` only, never `Enabled`:
    # BSG's own /client/locations reply for this build carries Enabled=false
    # on 9 of its 24 maps as its own "not in the game right now" axis, and
    # overwriting that would remove maps from the selection screen for a
    # reason the player did not ask for. See emu/maplock.nim for the measured
    # wire shape (both fields are plain JSON bools) and for why this is here
    # rather than in the phantom `mods/icebreaker` three files still cite.
    boolSetting("mapsUnlockedByDefault", "All maps unlocked by default", true,
                category = "Maps",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Writes locations.<map>.base.Locked on every map in the table, which /client/locations sends to the client verbatim. ON is the stock behaviour -- the database ships Locked=false on all 19 maps. Turn it OFF to lock every map except the ones named in \\\"Maps to leave unlocked\\\" below. Every map is rewritten on every apply, so this is reversible; locking only the locked ones would strand a map locked forever"),
    stringSetting("mapsLocked", "Maps to lock", "",
                  category = "Maps",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Comma-separated maps to lock even when the switch above is ON. Any spelling works -- the database key (bigmap), the client's own Id (Woods, Interchange, RezervBase) or the _Id GUID -- because each name is resolved through emu/raid.canonicalLocation. Only 4 of 19 maps spell the key and the Id alike, so a name that resolves to no map is REPORTED in the row below rather than silently ignored"),
    stringSetting("mapsUnlocked", "Maps to leave unlocked", "",
                  category = "Maps",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Comma-separated maps to keep unlocked when \\\"All maps unlocked by default\\\" is OFF -- the per-map half of the lock. Same name resolution as the row above. Empty with the switch off locks everything"),
    stringSetting("mapsLockResult", "Last lock result", "",
                  category = "Maps",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. What the last apply did: how many maps were locked and unlocked, how many database writes succeeded, and any map name in the two lists above that resolved to NO map -- which is the case where the setting saves cleanly and locks nothing"),

    # ---- raid timing and extracts (emu/svm -> emu/raid) ------------------
    #
    # These edit the LOCATION document, and are applied where that document is
    # BUILT rather than written into the database, for the reason emu/maplock's
    # header records in full: /client/locations is answered out of the post-1.0
    # table, so 19 successful database writes were served to nobody.
    floatSetting("raidTimeMultiplier", "Raid time multiplier", 1.0,
                 lo = 0.1, hi = 10.0, step = 0.1, category = "Raid/Timing",
                 description = "aowlspt original (server emulator); acts on the SPT-derived database. Scales every map's own EscapeTimeLimit (and EscapeTimeLimitCoop / EscapeTimeLimitPVE where the map has them) in the document /client/locations serves. Per map, not a flat number: Factory's 20 minutes and Streets' 50 stay in proportion. 1.0 is stock and costs nothing -- no location document is touched at all"),
    intSetting("raidTimeMinutes", "Raid time (fixed minutes)", 0,
               lo = 0, hi = 600, step = 5, category = "Raid/Timing",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. An ABSOLUTE raid length for every map, in minutes, overriding the multiplier above. 0 is off, which is what leaves the multiplier in charge"),

    boolSetting("extractsAlwaysAvailable", "All extracts always available",
                false, category = "Raid/Extracts",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Sets every exit's Chance and ChancePVE to 100 in the served location document, so no extract is rolled away for the raid. Does NOT remove an extract's requirement -- that is the next row, and they are different fields"),
    boolSetting("extractsNoRequirements", "Remove extract requirements", false,
                category = "Raid/Extracts",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Sets every exit's PassageRequirement to \\\"None\\\" and clears its RequirementTip, so a co-op / train / item-gated exfil opens without the condition. Measured shapes from data/post1/locations.json: PassageRequirement is a string (\\\"Train\\\", \\\"TransferItem\\\"), RequirementTip a string"),
    boolSetting("extractsNoTimeWindow", "Extracts open for the whole raid",
                false, category = "Raid/Extracts",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Sets every exit's MinTime/MinTimePVE to 0 and MaxTime/MaxTimePVE wide open, so an exfil that only exists in the last ten minutes exists from the start. Seconds, per the served document"),
    stringSetting("raidTuneResult", "Last raid tune result", "",
                  category = "Raid/Extracts",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Written BY the server: what the raid rows are set to, and how many map bases and exits have actually been rewritten while building a served location document. Zero maps tuned with the rows switched on means no client has fetched /client/locations since the apply -- not that the rows did nothing"),

    # ---- stash size (emu/svm) -------------------------------------------
    intSetting("stashRows", "Stash rows", 0, lo = 0, hi = 500, step = 5,
               category = "Profile/Stash",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Sets cellsV on the first grid of all five edition stash templates (Standard 30, Left Behind 40, Prepare to Escape 50, Edge of Darkness 68, Unheard 72), which /client/items serves and which the server's own item placement reads back through emu/grid.stashGrid. Each id is checked against the stash _parent before it is written. 0 leaves every stash exactly as the database has it"),
    intSetting("stashCols", "Stash columns", 0, lo = 0, hi = 50, step = 1,
               category = "Profile/Stash",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Sets cellsH the same way. NARROWING a stash that already holds items leaves items outside the grid, which the client draws where it cannot be picked up -- widening is safe, narrowing is not. 0 leaves it alone (every stash is 10 wide)"),
    stringSetting("stashResult", "Last stash result", "",
                  category = "Profile/Stash",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Written BY the server, and READ BACK from the database rather than reported from the write: how many of the five stash templates now report the requested size, naming any that does not, any id that is not a stash on this database, and any with no usable Grids"),

    # ---- item spawning -------------------------------------------------
    #
    # Four ordinary rows rather than a control type the settings UI does not
    # have yet. `spawnNow` is momentary: `onTarkovSettings` intercepts the POST
    # that sets it, runs the spawn, and writes the key back to false, so the
    # page never renders a checkbox stuck on and the row is armed again.
    # A remote select, not a text box. The value stored is still a plain
    # string -- the template id -- so nothing about persistence changes; what
    # changes is that the UI does typeahead against `/items` below instead of
    # the player typing an id from memory, and that free text the search does
    # not match is REFUSED rather than persisted and then refused at spawn time.
    # 4,673 item templates is far too many to inline in the schema, which is
    # what `optionsUrl` exists for.
    selectSetting("spawnQuery", "Item to spawn", "", @[],
                  optionsUrl = "/aowlspt/settings/" & ModGuid & "/items",
                  category = "Spawn Items",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. Search the item table by name or paste a 24-hex template id"),
    intSetting("spawnCount", "How many", 1, lo = 1, hi = 5000,
               category = "Spawn Items",
      description = "aowlspt original (server emulator); acts on the SPT-derived database."),
    intSetting("spawnCondition", "Condition (%)", 100, lo = 1, hi = 100,
               category = "Spawn Items",
               description = "aowlspt original (server emulator); acts on the SPT-derived database. Durability, resource or medkit charge as a percentage of the template's own maximum; only the properties the template declares are written"),
    boolSetting("spawnNow", "Spawn now", false, category = "Spawn Items",
                description = "aowlspt original (server emulator); acts on the SPT-derived database. Turn on to spawn. It turns itself back off, and the outcome appears in the row below"),
    stringSetting("spawnResult", "Last spawn result", "",
                  category = "Spawn Items",
                  description = "aowlspt original (server emulator); acts on the SPT-derived database. What the last spawn did, or exactly why it did nothing")]

  # Several hundred server value modifiers, generated from the database and
  # applied to the globals document the client fetches. `emu/tuning` builds
  # this list and the patcher from the SAME table, which is what stops a row
  # existing here without being wired to anything (CLAUDE.md 9b).
  let tuneRows = tuneSchema()
  for st in tuneRows:
    result.add st

proc onSpawnItemOptions(url, body, session: string): string =
  ## The `optionsUrl` behind the "Item to spawn" row:
  ## `GET .../items?q=<term>&limit=<n>` -> `{"options":[{value,label}], "matched":N}`.
  ##
  ## `matched` is the number of items the term REALLY matches, which can be
  ## larger than the number returned. Reporting it separately is what lets the
  ## page say "showing the first 50 of 214" instead of implying the list is
  ## complete -- a truncated list presented as a whole one is how somebody
  ## concludes an item does not exist.
  let want = queryValue(url, "q")
  var limit = 50
  let lim = queryValue(url, "limit")
  if lim.len > 0:
    let n = digitsToInt(lim, 50)
    if n > 0 and n <= 200:
      limit = n
  var a = arr()
  var matched = 0
  let hits = searchItemsCounted(want, limit, matched)
  for h in hits:
    var o = obj()
    o.put("value", h.tpl)
    o.put("label", (if h.name.len > 0: h.name else: h.tpl))
    a.add o
  var root = obj()
  root.put("options", a)
  root.put("matched", matched)
  result = done(root).text

proc spawnProfileId(session: string): string =
  ## Which stash a spawn goes into.
  ##
  ## The settings page is reached from a browser, not from the game client, so
  ## the session is usually empty and `profileFor` answers nothing. Falling back
  ## to the only profile when there is exactly one -- and REFUSING, by name,
  ## when there are several, because picking one of two stashes arbitrarily is
  ## how a spawn lands somewhere nobody is looking.
  result = profileFor(session)
  if result.len > 0:
    return
  let all = allProfileIds()
  if all.len == 1:
    result = all[0]

proc runSpawn(session: string): string =
  ## Perform the spawn the four `spawn*` rows describe and return the outcome.
  if gRaidActive:
    warn "spawn refused: " & raidSpawnRefusal()
    return raidSpawnRefusal()
  let pid = spawnProfileId(session)
  if pid.len == 0:
    let all = allProfileIds()
    if all.len == 0:
      return "there is no profile to spawn into yet"
    return "there are " & $all.len & " profiles and this page is not bound " &
           "to one; log in to the character you want first"
  let outcome = spawnInto(pid, setting("spawnQuery").asText(""),
                          setting("spawnCount").asInt(1),
                          setting("spawnCondition").asInt(100))
  result = outcome.message
  if outcome.ok:
    info "spawn: " & outcome.message
  else:
    warn "spawn refused: " & outcome.message

proc isLootKey(key: string): bool =
  ## Every key on the Loot page. Written as a prefix test plus the four rows
  ## whose names predate the page, rather than as a list -- a `const seq` is not
  ## constant-foldable here, and a list would be a second place to remember to
  ## add a row to. `lootSummary` is deliberately EXCLUDED: it is written by the
  ## server, and treating the server's own write as an edit would recompute the
  ## summary from the summary.
  if key == "lootSummary":
    return false
  if key.startsWith("loot") or key.startsWith("container"):
    return true
  # The three money-stack rows are read by BOTH generators through
  # `emu/knobs.moneyStackConfig`, so they are a loot key for the purposes of
  # recomputing the summary even though they do not spell `loot`. Missing this
  # would have left the page describing the previous money configuration --
  # the exact stale-summary failure `onTarkovApply` documents.
  if key.startsWith("moneyStack"):
    return true
  result = key == "staticLootMultiplier" or key == "looseLootMultiplier" or
           key == "maxLootItems" or key == "staticLootEnabled" or
           key == "looseLootEnabled"

proc applyLootPreset(name: string) =
  ## A preset WRITES the knobs and then gets out of the way -- it is a button,
  ## not a mode. Every preset sets every knob it cares about explicitly, so
  ## picking one twice with edits in between lands in the same place both times;
  ## a preset that only set the knobs that differ from the last one would make
  ## the result depend on history.
  ##
  ## `vanilla` is the important one: it is the exact set of defaults
  ## `emu/loot.defaultLootConfig` returns, so it is also the way back from any
  ## experiment.
  if name == "custom" or name.len == 0:
    return
  # Everything starts from vanilla; the named preset then overrides.
  discard applySetting("lootEnabled", "true")
  discard applySetting("lootGlobalMultiplier", "1.0")
  discard applySetting("staticLootMultiplier", "1.0")
  discard applySetting("looseLootMultiplier", "1.0")
  discard applySetting("maxLootItems", "20000")
  discard applySetting("lootStaticBudgetShare", "0.5")
  discard applySetting("staticLootEnabled", "true")
  discard applySetting("containerSpawnChanceMultiplier", "1.0")
  discard applySetting("containerFillMultiplier", "1.0")
  discard applySetting("containerMaxItems", "64")
  discard applySetting("looseLootEnabled", "true")
  discard applySetting("lootForcedSpawns", "true")
  discard applySetting("looseLootPointLimit", "0")
  discard applySetting("lootValueBias", "0.0")
  discard applySetting("lootValuePivot", "20000.0")
  discard applySetting("lootMinHandbookPrice", "0")
  discard applySetting("lootMaxHandbookPrice", "0")
  discard applySetting("lootRarityCommon", "1.0")
  discard applySetting("lootRarityRare", "1.0")
  discard applySetting("lootRaritySuperrare", "1.0")
  # The five category-weight sliders. A preset that skipped them would leave a
  # Money=0 from an earlier experiment in force under a "vanilla" label, which
  # is the history-dependence the docstring above says a preset must not have.
  discard applySetting("lootWeightMoney", "1.0")
  discard applySetting("lootWeightAmmo", "1.0")
  discard applySetting("lootWeightMeds", "1.0")
  discard applySetting("lootWeightKeys", "1.0")
  discard applySetting("lootWeightBarter", "1.0")
  # The other seventeen family weights and the three currency weights, for the
  # same reason the five above are here: a preset that skipped them would leave
  # a `Valuables = 0` from an earlier experiment in force under a "vanilla"
  # label, which is exactly the history-dependence this proc's docstring says a
  # preset must not have. Written out rather than looped, because the loop
  # would have to import the emu module's key array into the settings
  # declaration and the two are deliberately separate lists -- the disagreement
  # between them is what `emu/knobs`' ledger is for.
  discard applySetting("lootWeightAmmoBoxes", "1.0")
  discard applySetting("lootWeightFood", "1.0")
  discard applySetting("lootWeightElectronics", "1.0")
  discard applySetting("lootWeightValuables", "1.0")
  discard applySetting("lootWeightWeapons", "1.0")
  discard applySetting("lootWeightKnives", "1.0")
  discard applySetting("lootWeightMods", "1.0")
  discard applySetting("lootWeightMagazines", "1.0")
  discard applySetting("lootWeightArmor", "1.0")
  discard applySetting("lootWeightHelmets", "1.0")
  discard applySetting("lootWeightRigs", "1.0")
  discard applySetting("lootWeightBackpacks", "1.0")
  discard applySetting("lootWeightGrenades", "1.0")
  discard applySetting("lootWeightContainers", "1.0")
  discard applySetting("lootWeightStims", "1.0")
  discard applySetting("lootWeightTools", "1.0")
  discard applySetting("lootWeightSpecial", "1.0")
  discard applySetting("lootCurrencyRoubles", "1.0")
  discard applySetting("lootCurrencyDollars", "1.0")
  discard applySetting("lootCurrencyEuros", "1.0")
  discard applySetting("moneyStackMultiplier", "1.0")
  discard applySetting("moneyStackMin", "0")
  discard applySetting("moneyStackMax", "0")
  discard applySetting("lootStackRandomRange", "false")
  discard applySetting("lootStackMultiplier", "1.0")
  discard applySetting("lootStackMaxFraction", "1.0")
  case name
  of "scarce":
    discard applySetting("lootGlobalMultiplier", "0.5")
    discard applySetting("containerFillMultiplier", "0.7")
    discard applySetting("lootValueBias", "-0.5")
    discard applySetting("lootStackMaxFraction", "0.5")
    discard applySetting("moneyStackMultiplier", "0.5")
  of "richer":
    discard applySetting("lootGlobalMultiplier", "1.5")
    discard applySetting("containerFillMultiplier", "1.3")
    discard applySetting("lootStackRandomRange", "true")
  of "goblin":
    discard applySetting("lootGlobalMultiplier", "3.0")
    discard applySetting("containerFillMultiplier", "2.0")
    discard applySetting("containerMaxItems", "128")
    discard applySetting("lootValueBias", "0.8")
    discard applySetting("lootStackRandomRange", "true")
    discard applySetting("moneyStackMultiplier", "3.0")
  else:
    discard  # "vanilla": the block above IS vanilla

proc onTarkovApply(key: string) =
  ## THE HOT-APPLY HOOK, and the reason it exists.
  ##
  ## There are TWO transports into this mod's settings and they were not
  ## symmetric -- the identical shape `mods/maps` was bitten by:
  ##
  ##   * the event bus -- `SettingsApplyQuery` -> the SDK's `onApplyQuery` ->
  ##     `applySettingFromBody` AND THEN `gApplyHook(key)`. This mod registered
  ##     no hook, so the bus path persisted the edit and stopped there.
  ##   * the ROUTE below, which did all the hot-apply work inline.
  ##
  ## So an edit that arrived over the bus reached config.json and nothing else:
  ## picking a loot PRESET wrote no knobs, and `lootSummary` was never
  ## recomputed, so the page went on describing the previous configuration. A
  ## sentence that says what the loot will do, computed from a stale read, is
  ## worse than no sentence.
  ##
  ## Both transports now converge here. It is idempotent -- every branch re-reads
  ## config.json rather than trusting the value that was posted -- and it reports
  ## a verdict on every path, so the host log distinguishes "in force now" from
  ## "stored, next start" instead of printing one "applied" for both.
  ##
  ## `spawnNow`/`spawnQuery` are deliberately NOT here: they need the `session`
  ## the route is handed and the hook is not, so they stay in the route. That is
  ## a KNOWN, STATED hole in the bus path, not an oversight.
  applyMenuCornerLabel()
  if key.len > 1 and key[0] == 'g' and key[1] == '_':
    loadGlobalTunes()
  if key == "mapsUnlockedByDefault" or key == "mapsLocked" or
     key == "mapsUnlocked":
    applyMapLockSettings()
  # The four SVM rows that are not globals.config. One call reads ALL of them
  # -- the stash pair, the exact-XP row and the five raid rows -- because
  # `emu/svm`'s read ledger is what proves each key is consulted, and a
  # per-key branch here would be a second place for a key to go missing from.
  # Cheap: every row is off by default and `applyStashSize`/`setRaidTunePolicy`
  # return without touching a document when nothing is configured.
  if key.startsWith("stash") or key.startsWith("raid") or
     key.startsWith("extracts") or key == "progressionExperience":
    applySvmSettings()
  # The staged-start rows: one call reads all four and drops the tuned-
  # locations cache only if something changed (emu/raid.applyStagedStartSettings).
  if key.startsWith("stagedStart"):
    applyStagedStartSettings()
  if key.startsWith("progression"):
    configureProgression(setting("progressionPlayerLevel").asInt(0),
                         setting("progressionSkillLevel").asInt(0),
                         setting("progressionSkillIds").asText(""),
                         setting("progressionMasteryLevel").asInt(0),
                         setting("progressionMasteryFamilies").asText(""))
  elif key == "traderMaxLoyalty" or key == "traderUnlockAllOffers" or
       key == "traderIgnoreStockLimits" or key == "traderPriceMultiplier":
    configureTraders(setting("traderUnlockAllOffers").asBool(false),
                     setting("traderPriceMultiplier").asFloat(1.0),
                     setting("traderIgnoreStockLimits").asBool(false),
                     setting("traderMaxLoyalty").asBool(false))
  # Bots > Gear and Bots > Loot. These are HOT: `refreshBotGear` re-reads the
  # whole page off config.json -- not off the value that was just posted -- and
  # the next `bot/generate` batch is built with it. That is the difference
  # between this and the "stored, next start" answer at the bottom of this
  # proc, and it is why the verdict says so explicitly rather than printing one
  # "applied" for both cases.
  if key.startsWith("botGear") or key.startsWith("botLoot") or
     key.startsWith("botSlot") or key == "botSpareMagazines" or
     key.startsWith("botAmmo") or key.startsWith("botArmor") or
     key.startsWith("botSpare") or key == "botMagazineFill" or
     key == "botWeaponModChance" or key == "botEquipmentModChance":
    refreshBotGear()
    settingApplied("re-read from config.json; the next bot batch is generated " &
                   "with it, with no restart")
    return
  if isLootKey(key):
    if key == "lootPreset":
      applyLootPreset(setting("lootPreset").asText("custom"))
    # The money rows are shared with the bot generator, so the bot side has to
    # be re-read too or a money edit would reach the floor and not the corpse.
    if key.startsWith("moneyStack"):
      refreshBotGear()
    # Taken LAST and read out of `lootConfig()` -- the same object the generator
    # reads -- not out of the value that was just posted. A summary derived from
    # the incoming edit would be a check that cannot fail.
    let summary = lootConfigSummary()
    discard applySetting("lootSummary", jstr(summary).text)
    settingApplied("the loot generator now reads: " & summary)
    return
  if key.startsWith("progression") or key.startsWith("trader") or
     key.startsWith("maps") or key == "menuCornerLabel" or
     (key.len > 1 and key[0] == 'g' and key[1] == '_'):
    settingApplied("re-read from config.json and pushed into the live emulator")
    return
  # Everything else on this page is read once, when the emulator loads. Saying
  # so is the honest answer; saying "applied" would be the lie this mechanism
  # exists to stop.
  settingAppliesOnRestart("stored in config.json; the emulator reads this key " &
                          "at load, so it takes effect on the next start")

proc onTarkovSettings(url, body, session: string): string =
  ## GET serves the emulator's schema; a POST body persists one edit into
  ## config.json. The emulator reads these at load, so the write is saved and
  ## takes effect next start rather than live -- except for the keys
  ## `onTarkovApply` handles, which would be useless if they did not act
  ## immediately.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    let key = field(body, "key").asText("")
    # The SAME hook the event bus runs. Converging the two transports here is
    # what stops one of them quietly doing less than the other.
    onTarkovApply(key)
    # `spawnNow` is a button, not a value. Run it, record what happened, and
    # put the key back to false so the control is armed again -- a checkbox
    # that stays on after its action is one nobody can press twice. It stays
    # HERE and not in the hook because it needs `session`.
    if key == "spawnNow" and setting("spawnNow").asBool(false):
      let outcome = runSpawn(session)
      discard applySetting("spawnResult", jstr(outcome).text)
      discard applySetting("spawnNow", "false")
    elif key == "spawnQuery":
      # Typing in the search box previews what it would match, so an ambiguous
      # query is visible BEFORE the spawn refuses it.
      let q = setting("spawnQuery").asText("")
      if q.len > 0:
        discard applySetting("spawnResult",
                             jstr("matches: " & searchSummary(q, 8)).text)
  result = declaredSchemaReply(st).text

# ---------------------------------------------------------------------------
# THE `aowl.items` PROVIDER
# ---------------------------------------------------------------------------
#
# The same `spawnInto` the "Spawn Items" settings rows drive, published as a
# capability so a surface that is NOT the settings page -- the admin mod's F6
# overlay -- can spawn without reaching into this mod's routes or its config.
#
# THE ONE RULE THIS HANDLER EXISTS TO OBEY: every path that did not put items
# in a stash returns `capFail` with the reason. `spawnInto` already declines in
# five distinguishable ways and populates `message` on every one of them, so
# there is nothing here to invent -- the failure mode this guards against is
# the opposite one, a `capOk` carrying `"spawned": 0`, which reads to a caller
# as success and is the single worst outcome this project produces.
#
# Request : {"query": str, "count": int?, "condition": int?, "profileId": str?,
#            "session": str?}
# Reply   : {"spawned": int, "query": str, "message": str}

proc onItemsCapability(request: string): CapReply =
  if not strictObject(request):
    return capFail("the aowl.items request is not a JSON object")

  # `op: "inventory"` and `op: "count"` are answered BEFORE the query check,
  # because neither takes a query. Putting them below it would make "show me my
  # stash" fail with "aowl.items needs a query", which is a refusal that
  # describes the wrong thing.
  let op0 = field(request, "op").asText("")

  if op0 == "inventory" or op0 == "count":
    var pid0 = field(request, "profileId").asText("")
    if pid0.len == 0:
      pid0 = spawnProfileId(field(request, "session").asText(""))
    if pid0.len == 0:
      let all = allProfileIds()
      if all.len == 0:
        return capFail("there is no profile yet; log in first")
      return capFail("there are " & $all.len & " profiles and the request " &
                     "named none; pass \"profileId\", or log in")

    if op0 == "count":
      # THE MINT READBACK, exposed. It reports READABILITY separately from the
      # number and this handler keeps them separate: a profile that could not
      # be opened must not come back as "you have 0", which a caller comparing
      # a before and an after would read as a failed spawn rather than as a
      # check that could not run.
      let tplWanted = field(request, "tpl").asText("")
      if tplWanted.len == 0:
        return capFail("aowl.items op=count needs a \"tpl\"")
      let cr = templateCount(pid0, tplWanted)
      var oc = obj()
      put(oc, "spawned", 0)
      put(oc, "tpl", tplWanted)
      put(oc, "readable", cr.readable)
      put(oc, "count", cr.count)
      put(oc, "message", (if cr.readable:
                            "the profile holds " & $cr.count & " x " & tplWanted
                          else:
                            "COULD NOT LOOK: " & cr.why))
      return capOk(done(oc).text)

    var limI = field(request, "limit").asInt(32)
    if limI < 1: limI = 1
    if limI > 64: limI = 64
    var distinct0 = 0
    let rowsInv = stashRows(pid0, limI, distinct0)
    var rawRows = "["
    for i in 0 ..< rowsInv.len:
      if i > 0: rawRows.add ","
      var r = obj()
      put(r, "tpl", rowsInv[i].tpl)
      put(r, "name", rowsInv[i].name)
      put(r, "count", rowsInv[i].count)
      rawRows.add done(r).text
    rawRows.add "]"
    var oi = obj()
    put(oi, "spawned", 0)
    put(oi, "profileId", pid0)
    put(oi, "total", distinct0)         # distinct templates in the stash
    put(oi, "returned", rowsInv.len)
    put(oi, "rows", raw(rawRows))
    # `total == 0` is an ANSWER (an empty stash) and is reported as one. It is
    # NOT distinguishable here from a profile whose item list would not parse,
    # which `stashRows` returns empty for -- so the message says "reads as",
    # not "is". The `count` op above is the one that separates those.
    put(oi, "message", $rowsInv.len & " of " & $distinct0 &
                       " distinct template(s) read back from the stash of " &
                       pid0)
    return capOk(done(oi).text)

  let query = field(request, "query").asText("")
  if query.len == 0:
    return capFail("aowl.items needs a \"query\": part of an item name, or a " &
                   "24-hex template id")
  # `op: "search"` -- LOOK, do not spawn.
  #
  # This is what makes the F6 spawner usable rather than a guessing game. The
  # overlay has one line to show the player, so what comes back is a rendered
  # sentence, not a list to format twice: `searchSummary` already composes it
  # for the settings page, and having a second formatter would be a second
  # thing to keep true.
  #
  # It is also the honest answer to "I typed and nothing showed up": before
  # this, the only way to learn whether a query matched anything was to spawn
  # it, and a query that matched nothing looked exactly like a query that had
  # not been typed at all.
  #
  # A search does NOT touch the profile, so it is deliberately allowed during a
  # raid -- the raid guard above returns before this only because spawning is
  # what the raid invalidates. Reading is safe; being able to look up an item's
  # id mid-raid and spawn it on extract is useful.
  if field(request, "op").asText("") == "search":
    var matched = 0
    let hits = searchItemsCounted(query, 10, matched)
    var o = obj()
    put(o, "spawned", 0)
    put(o, "query", query)
    put(o, "matched", matched)
    # `matched == 0` is an ANSWER, not a failure: the query is well-formed and
    # the database genuinely has no such item. Saying so plainly is the whole
    # point, so it is `capOk` with a message, not `capFail`.
    put(o, "message", searchSummary(query, 10))
    return capOk(done(o).text)

  # `op: "list"` -- the same search, as ROWS instead of a sentence.
  #
  # WHY BOTH EXIST. `op:"search"` renders one line because the F6 overlay has
  # one line to show. The native inventory screen has a COLUMN, and formatting a
  # sentence only to split it apart again would make the row boundaries depend
  # on the separator characters inside an item name -- "5.45x39mm BS gs" has a
  # semicolon nowhere but nothing stops the locale from carrying one. So the
  # rows cross the wire as rows. `searchSummary` is untouched and still the only
  # renderer of the one-line form; this is not a second formatter of the same
  # thing, it is the unformatted thing.
  #
  # `limit` is the caller's page size, clamped: the shared region that carries
  # these has a fixed 64-row table and asking for more than fits would produce a
  # silent truncation on the far side instead of an honest `matched` count here.
  if field(request, "op").asText("") == "list":
    var lim = field(request, "limit").asInt(32)
    if lim < 1: lim = 1
    if lim > 64: lim = 64
    var matched = 0
    let hits = searchItemsCounted(query, lim, matched)
    var rows = "["
    for i in 0 ..< hits.len:
      if i > 0: rows.add ","
      var r = obj()
      put(r, "tpl", hits[i].tpl)
      put(r, "name", (if hits[i].name.len > 0: hits[i].name else: hits[i].tpl))
      rows.add done(r).text
    rows.add "]"
    var o = obj()
    put(o, "spawned", 0)
    put(o, "query", query)
    put(o, "matched", matched)          # how many REALLY matched
    put(o, "returned", hits.len)        # how many are in `rows`
    put(o, "rows", raw(rows))
    put(o, "message", (if matched == 0:
                         "no item matches \"" & query & "\""
                       else:
                         $hits.len & " of " & $matched & " match \"" &
                         query & "\""))
    return capOk(done(o).text)

  # Mid-raid, refuse before doing any work -- but only a SPAWN, which is why
  # this sits below the search above rather than at the top of the handler.
  # The F6 overlay is reachable IN a raid, that being most of the point of it,
  # so this is the surface most likely to hit this path and the one where a
  # silent no-op would be least visible: the player is looking at the game,
  # not at a stash.
  if gRaidActive:
    warn "aowl.items refused: " & raidSpawnRefusal()
    return capFail(raidSpawnRefusal())

  var count = field(request, "count").asInt(1)
  if count < 1: count = 1
  var condition = field(request, "condition").asInt(100)
  if condition < 1: condition = 1
  if condition > 100: condition = 100

  # Which stash. An explicit profileId wins; otherwise the session, otherwise
  # `spawnProfileId`'s single-profile fallback. Ambiguity is REFUSED by name
  # rather than resolved arbitrarily -- see `spawnProfileId`.
  var pid = field(request, "profileId").asText("")
  if pid.len == 0:
    pid = spawnProfileId(field(request, "session").asText(""))
  if pid.len == 0:
    let all = allProfileIds()
    if all.len == 0:
      return capFail("there is no profile to spawn into yet; log in first")
    return capFail("there are " & $all.len & " profiles and the request named " &
                   "none; pass \"profileId\", or log in to the character you want")

  let outcome = spawnInto(pid, query, count, condition)
  if not outcome.ok:
    warn "aowl.items refused: " & outcome.message
    return capFail(outcome.message)
  # Belt and braces: `spawnInto` clamps `count` to at least 1 before placing,
  # so `ok` cannot mean zero items -- but a future change to that clamp must
  # not turn into a silent success here.
  if count < 1:
    return capFail("the spawn reported success but placed no items; refusing " &
                   "to report that as a success")
  info "aowl.items: " & outcome.message
  var o = obj()
  put(o, "spawned", count)
  put(o, "query", query)
  put(o, "message", outcome.message)
  result = capOk(done(o).text)

proc onTarkovSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  applyMenuCornerLabel()
  result = declaredSchemaReply(st).text

proc onLoad(): Status =
  if side() != sideServer:
    info "the emulator is a server mod; nothing to do on this side"
    return Ok

  # Decode the placeholder image once, before any route can be asked for it.
  gFilesPng = decodeHex(PlaceholderPngHex)

  # The edition is normalised here and NOWHERE else. The settings page spells
  # it with hyphens, the launcher and `Info.GameVersion` with underscores; an
  # edition this server cannot build a starting kit for is refused at create
  # rather than quietly downgraded to standard.
  let wantEdition = setting("edition").asText("standard")
  gEdition = normalEdition(wantEdition)
  if gEdition.len == 0:
    warn "edition '" & wantEdition & "' is not one this server knows; new " &
         "profiles will be standard"
    gEdition = "standard"
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
  # The five server-side modifiers above, each handed to the module that owns
  # the number. Read here, at load, like every other key on this page.
  configureTraders(setting("traderUnlockAllOffers").asBool(false),
                   setting("traderPriceMultiplier").asFloat(1.0),
                   setting("traderIgnoreStockLimits").asBool(false),
                   setting("traderMaxLoyalty").asBool(false))
  # The progression floors. Read at load like every other key on this page; the
  # profile itself is only rewritten when a fetch finds it below the floor.
  configureProgression(setting("progressionPlayerLevel").asInt(0),
                       setting("progressionSkillLevel").asInt(0),
                       setting("progressionSkillIds").asText(""),
                       setting("progressionMasteryLevel").asInt(0),
                       setting("progressionMasteryFamilies").asText(""))
  configureRepairPrices(setting("repairPriceMultiplier").asFloat(1.0))
  configureHideoutTimes(
    setting("hideoutConstructionMultiplier").asFloat(1.0))
  configureCraftTimes(setting("hideoutProductionMultiplier").asFloat(1.0))
  configureQuestXp(setting("questXpMultiplier").asFloat(1.0))
  # Seed the Loot page's summary line at boot, so it is right the first time the
  # page is opened rather than only after something on it has been edited.
  discard applySetting("lootSummary", jstr(lootConfigSummary()).text)

  applyMapLockSettings()
  # The non-globals SVM rows: stash size, exact XP, raid time, extracts. One
  # call, which is also the ledger's first run -- see `emu/svm`.
  applySvmSettings()
  applyStagedStartSettings()
  configureMarket(setting("fleaSpreadPercent").asInt(20),
                  setting("fleaOfferHours").asInt(12),
                  setting("fleaMaxOffers").asInt(600),
                  setting("fleaSaleMinutes").asInt(30),
                  setting("fleaPriceMultiplier").asFloat(1.0),
                  setting("fleaSellFeePercent").asInt(0))

  # Read the server value modifiers out of config.json BEFORE the schema is
  # declared, so the page and `/client/globals` agree from the first request.
  #
  # A key absent from config.json is not an override -- the settings UI writes a
  # key only when somebody edits it -- so an untouched install resolves zero of
  # these and `applyGlobalTunes` never even parses the globals document.
  loadGlobalTunes()
  let tunes = globalTuneReport()
  if tunes.len > 0:
    info "singleplayer: " & $tunes.len & " of " & $globalTuneTotal() &
         " server value modifiers are overridden and will be served in " &
         "/client/globals"
    for line in tunes:
      info "  " & line
  else:
    info "singleplayer: " & $globalTuneTotal() &
         " server value modifiers available, none overridden"
  # A value that is not a JSON literal is refused rather than spliced into the
  # globals document, and it is said out loud -- an override that silently did
  # not apply is the failure this whole surface is built to avoid.
  let rejected = globalTuneRejected()
  for bad in rejected:
    warn "singleplayer: refusing a modifier whose value is not a JSON " &
         "literal: " & bad

  # The non-globals SVM rows say what they did, for the same reason the globals
  # ones do: a modifier that applied silently is indistinguishable from one that
  # did not apply. The ledger line is the falsifiable half -- it names any key
  # the schema declares and the server never read.
  info "singleplayer: " & svmLedgerLine()
  let svmNever = svmLedgerNeverRead()
  if svmNever.len > 0:
    for k in svmNever:
      warn "singleplayer: SVM key declared and NEVER READ: " & k
  if stashReport().len > 0:
    info "singleplayer: " & stashReport()
  info "singleplayer: " & raidTuneReport()

  # The emulator's own settings page, registered before the store gate below so
  # it answers even on a host where the emulator refuses to serve anything else.
  declareSettings(tarkovSchema())
  # THE HOOK. Without this line every edit that arrives over the EVENT BUS (the
  # in-game settings surface, as opposed to the F12 route below) is persisted to
  # config.json and acted on by nothing: no loot preset written, no summary
  # recomputed, no trader/progression/map-lock reconfigure, and the host log
  # says "NO EFFECT ... this mod registered no onSettingsApplied hook". It is
  # registered BEFORE the routes for the same reason mods/debug does.
  onSettingsApplied(onTarkovApply)
  discard serve("/aowlspt/settings/" & ModGuid, onTarkovSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onTarkovSettingsReset)
  # The typeahead source for the item-spawn row. Registered beside the schema
  # route and before the store gate, so the search box works on a host where
  # the emulator refuses to serve anything else -- a select whose options route
  # 404s renders as an empty list, which reads as "there are no items".
  discard serve("/aowlspt/settings/" & ModGuid & "/items", onSpawnItemOptions)

  # Publish the spawner as `aowl.items/1`. The registry entry for this mod
  # lists the name too; that is what lets a consumer distinguish "not
  # installed" from "installed but not in the selection", and it is NOT what
  # makes the call work -- this line is.
  let capSt = provide("aowl.items", 1, onItemsCapability)
  if capSt == Ok:
    info "singleplayer: providing aowl.items/1 -- the item spawner is now " &
         "callable by any loaded mod (the admin mod's F6 overlay uses it)"
  else:
    warn "singleplayer: provide(aowl.items/1) was REFUSED, so the F6 overlay " &
         "spawner will report the capability as unavailable. The " &
         "settings-page spawner is unaffected."

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
  # The planting bus, installed BEFORE the self-checks: `emu/plantcheck` runs
  # a real round-trip through it and would otherwise be checking nothing.
  # A refusal here is fatal in the honest sense -- every later plant would be
  # dropped in silence -- so it is a warning naming the cause, not a nil.
  if not installPlanting():
    warn "planting: could not subscribe to " & EvLootPlant & "/" & EvBotsPlant &
         " (" & lastError() & "); no mod will be able to plant loot or bots " &
         "into a raid on this host"

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
  # The bot-loadout digest instrument. A prefix route because the role, the seed
  # and the count are in the path; see `onBotDigest`.
  if servePrefix("/aowlspt/tarkov/botdigest/", onBotDigest) != Ok:
    warn "no bot digest route on this host: " & lastError()
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

  # AutoRaid's ephemeral loadout, subscribed AFTER the self-check gate so a
  # build that fails its own arithmetic never mints anything.
  if on(ARApplyEvent, arApply) != Ok:
    warn "no " & ARApplyEvent & " subscription on this host: " & lastError() &
         " -- AutoRaid's spawned loadout will do nothing, and it will do it " &
         "silently unless this line is read"
  # A process that has just started cannot have a raid in progress, so any
  # minted set still on disk belongs to a raid that never ended -- a crash, a
  # killed client, a backend restarted mid-raid. Stripped now and announced,
  # because minted gear that is never stripped is indistinguishable from gear
  # the player owns one menu load later.
  let swept = arSweepStale()
  if swept > 0:
    warn "autoraid loadout: " & $swept &
         " profile(s) carried a stale minted set from a raid that never ended"

  # A minute is the right period for this: it is not a game loop, and every
  # thing it does is something the player would otherwise wait for a screen
  # reload to see.
  if everyMs(60000, sweep) != Ok:
    warn "no periodic sweep on this host: " & lastError()

  let all = allProfileIds()
  success "Tarkov emulator loaded, " & $all.len & " profile(s)"
  for id in all:
    var p = loadProfile(id)
    if p.ok:
      info "  " & id & "  " & p.nickname & " (" & p.side & ", level " &
           $p.level & ")"
      # The quest availability pass, paid HERE instead of on the player's
      # login.
      #
      # `/client/quest/list` calls `refreshAvailability` on every menu load and
      # the pass is a full condition evaluation over ~558 templates. MEASURED
      # with `tools/loadpathbench.py`: the route cost 871 ms on its first
      # request and 38 ms on its second, so the pass is essentially the whole
      # of the first one -- and the first one is the one the client waits for
      # while the menu is blank. Nothing about it needs a request: it depends
      # on the profile and the database, both of which exist now.
      #
      # It is NOT removed from the route. This is a warm-up, not a
      # replacement: a profile the client creates later, or one that changes,
      # still gets the pass where it always got it, and `refreshAvailability`
      # memoises on the profile text so the request-time call is then a
      # comparison instead of a scan.
      let opened = refreshAvailability(p, nowSeconds())
      # And the SERVED array, for the same reason and with a separate
      # measurement: `emu/templates.questList` builds a 3.4 MB array out of the
      # id-keyed table on its first call, and `questListFor` then parses it and
      # 558 objects. MEASURED: with this line absent, the first
      # `/client/quest/list` cost 862 ms even with the availability pass
      # already done at load. The result is thrown away -- what is kept is the
      # `questList()` memo it builds on the way.
      discard questListFor(p)
      if opened > 0:
        if saveProfile(p):
          info "  " & id & "  " & $opened & " quest(s) opened at load"
        else:
          warn "could not save " & id & " after opening " & $opened &
               " quest(s) at load"
  Ok

proc onUnload(): Status =
  info "the emulator handled " & $gRequests & " request(s)"
  Ok

exportMod(
  guid = ModGuid,
  name = "Singleplayer",
  author = "aowlspt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
