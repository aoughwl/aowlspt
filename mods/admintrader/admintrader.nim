## Admin Trader — the "copy this one" example mod.
##
##     aowl build-mod mods/admintrader
##
## It adds a brand new trader to the game, gives him every item in the handbook
## for free, and hands him one quest to give out.
##
## ## The one idea
##
## `mods/tarkov` IS the game server. It has no trader type and no quest type —
## it reads `traders.<id>` and `templates.quests.<id>` straight out of the
## loaded database and serves whatever is there. So a mod does not need a
## trader API, it needs `dbWrite` and the right shape.
##
## `aowlspt/trader` is that shape. It does not hide the write: `install(t)`
## does `dbWrite("traders." & id, …)` and says so, and you can read it.
##
## ## Want to make your OWN trader?
##
## 1. Copy this folder to `mods/yourtrader/` and rename the `.nim`.
## 2. Change `ModGuid`, `ModName` and the two ids below. `traderId` refuses
##    anything that is not 24 hex characters, loudly, before anything is
##    written — so a typo is a log line, not a trader nobody can reach.
## 3. Add an entry to `registry/mods.json` whose `id` is EXACTLY your
##    `ModGuid`, and whose `sides` and `author` match this source VERBATIM —
##    `aowl selfcheck` compares them character by character.
## 4. `aowl build mods`.
##
## ## Getting it to actually load (this trips everyone up)
##
## Three things, all required, and missing any one looks identical to a broken
## mod because nothing complains: the built `.dll` in the install, an entry in
## `registry/mods.json` with a matching guid, and the mod enabled in the
## manager-owned selection (`mods/aowlspt-selection.json`). That last one is
## written by `aowl.manager` and hand-editing it gets reverted — enable through
## `GET /aowlspt/mods/enable/<guid>`. See `docs/MOD-ENABLE-PATH.md`.

import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/trader

const
  ModGuid = "aowl.admintrader"
  ModName = "Admin Trader"
  ModAuthor = "aowlspt"
  ModVersion = "1.0.0"

  TraderHex = "ad0000000000000000000001"
    ## 24 hex characters, like every id the client handles. Ours starts `ad`
    ## so it is obvious in a log which ids this mod invented.
  QuestHex = "ad0000000000000000000101"
  Painkillers = "544fb37f4bdc2dee738b4567"
    ## The quest asks for one, and the Admin Trader sells it for nothing, so
    ## the whole loop is completable from a fresh profile.

  StatusRoute = "/admintrader/status"

# ---------------------------------------------------------------------------
# Settings — three knobs, and every one of them is in config.json
# ---------------------------------------------------------------------------
#
# The rule the build enforces: a key you DECLARE here must also exist in
# `config.json`, or the control renders, moves, and resolves to nothing.

proc adminSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Add the Admin Trader", true,
                category = "Admin Trader",
                appliesOn = "restart",
                description = "Off removes nothing already written; it stops " &
                              "the trader being written at the next start."),
    stringSetting("nickname", "Trader name", "Admin Trader",
                  category = "Admin Trader",
                  description = "What the trader is called on the trading " &
                                "screen. Changing it here rewrites him live."),
    intSetting("maxOffers", "How many items he stocks", 4500,
               lo = 1, hi = 100000,
               category = "Admin Trader",
               appliesOn = "restart",
               description = "Everything in the handbook, capped. The " &
                             "handbook holds about 4,300 items, so the " &
                             "default is 'all of them'.")]

# ---------------------------------------------------------------------------
# The trader, his stock, and his quest
# ---------------------------------------------------------------------------

var gTrader: Trader
var gQuest: Quest
var gInstalled = false
var gWhyNot = ""

proc identify() =
  ## Give both globals their ids and text. Called FIRST in `onLoad`, before the
  ## `enabled` check, so that even the disabled path reports the real ids
  ## rather than empty strings — an empty id pasted into a db path reads back
  ## the whole table with every field blank, which looks like a trader that
  ## exists and has no name.
  gTrader = newTrader(traderId(TraderHex),
                      setting("nickname").asText("Admin Trader"))
  gTrader.description = "A test trader added by the Admin Trader example " &
                        "mod. Everything he has is free, and he has everything."
  gQuest = newQuest(questId(QuestHex), gTrader, "Admin Induction")
  gQuest.description = "Bring me one pack of painkillers. I sell them for " &
                       "nothing, so this should not take long."
  gQuest.note = "Hand over 1 x Painkillers."
  gQuest.startedText = "Take your time. Or do not."
  gQuest.successText = "Good. You now know how a quest works."
  gQuest.failText = "That should not have been possible."

proc build(): bool =
  ## Everything this mod is, in one proc. Three sections, and each one only
  ## says what makes THIS trader different from a default one.
  gInstalled = false
  gWhyNot = ""

  # The handbook is the ~4,300 TRADEABLE things. `price = 0` is the default,
  # and free is not a special case here: a price IS a barter requirement, and
  # this asks for zero roubles.
  discard gTrader.stockWholeHandbook(setting("maxOffers").asInt(4500))
  if install(gTrader) != Ok:
    gWhyNot = whyNot(gTrader)
    return false

  gQuest.requireLevel(1)                    # startable from a fresh profile
  gQuest.requireHandover(Painkillers, 1)
  gQuest.rewardExperience(500)
  gQuest.rewardStanding(0.1)
  if install(gQuest) != Ok:
    gWhyNot = whyNot(gQuest)
    return false

  gInstalled = true
  result = true

# ---------------------------------------------------------------------------
# The status route — every mod should have one
# ---------------------------------------------------------------------------

proc onStatus(url, body, session: string): string =
  ## `GET /admintrader/status` — what actually happened, in numbers you can
  ## assert on. `auditTrader`/`auditQuest` read every field back out of the
  ## database; none of it reports what this mod *did*.
  var o = obj()
  put(o, "ok", gInstalled)
  put(o, "mod", ModGuid)
  auditTrader(gTrader, o)
  auditQuest(gQuest, o)
  put(o, "offers", gTrader.offers.len)   # what we tried; the audit says what IS
  if gWhyNot.len > 0:
    put(o, "problem", gWhyNot)
  result = done(o).text

proc onApply(key: string) =
  ## Hot-apply. Only `nickname` can change without a restart — the stock and
  ## the enable flag are declared `appliesOn = "restart"` and say so on the
  ## page, which is honest rather than a control that silently does nothing.
  if key == "nickname":
    gTrader.nickname = setting("nickname").asText("Admin Trader")
    if install(gTrader) == Ok:
      settingApplied("the trader is now called \"" & gTrader.nickname & "\"")
    else:
      settingIgnored("could not rewrite the trader: " & whyNot(gTrader))
  else:
    settingAppliesOnRestart("takes effect when the backend restarts")

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server mod; nothing to do on this side"
    return Ok

  declareSettings(adminSchema())     # backfills any key missing from config.json
  identify()                         # …so read the nickname after it
  discard serveSettingsRoutes()      # the two settings routes, in one line
  onSettingsApplied(onApply)

  if serve(StatusRoute, onStatus) != Ok:
    warn "could not register " & StatusRoute

  if not setting("enabled").asBool(true):
    info ModName & " is disabled in config.json; no trader was added"
    return Ok

  if build():
    success ModName & ": trader " & TraderHex & " and quest " & QuestHex &
            " added"
  else:
    warn ModName & " did not install: " & gWhyNot
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad)
