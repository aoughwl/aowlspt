# Timeline: what the client does, in what order, and what that costs the server

[EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md) is the route-by-route question —
*is anything listening on this path*. This is the other question: **in what
order does the client call them, what does it actually send, and what does the
server have to remember between two calls that are minutes apart**. A server can
answer all 86 paths in the capture correctly one at a time and still be
unplayable, because `/client/match/local/end` posts its profile under
`results.profile` and the emulator looks for it under `profile`.

## Where the evidence comes from

`mods/tarkov/data/capture/raid1/manifest.json` — 220 HTTP records from a Fiddler
capture of a real client against BSG's live backend, in wire order.
`tools/metablob.py` broke the request obfuscation (a length-keyed byte shuffle
over `[int32 LE size][zlib(json)]`), so **147 of the 150 non-empty game request
bodies are now plain JSON**, one file per seq. Request headers for all 506
Fiddler sessions are available too.

What is **measured**: every request URL, method, header and **body**; the
response length after transport-gunzip; the session cookie; and four plaintext
response bodies (`/launcher/game/start`, `/client/metadata`,
`/client/libraries`, `/client/game/keepalive`).

What is still **not** measured: the content of the 207 encrypted responses.
Response bodies use the same wrapper but an AES-encrypted payload and nobody has
read one. So every claim about a *response* is an argument about a
compressed-and-encrypted length, quantised to 16 bytes and always at
`1 (mod 16)`. 81 bytes is the floor — `raid/configuration`, `match/local/end`,
`putMetrics`, `match/available`, `survey` and `nickname/reserved` all return it,
and they cannot all carry the same payload. So `game/profile/list` returning 81
at seq 083 means an **empty** list.

Requests are now ground truth. Where this document says what the client sends,
that is a quotation.

## What the capture actually contains — and the death

The session was described as ending in a death. That is right, but **not where
it looks**. The capture contains **two** raids:

| | raid 1 | raid 2 |
|---|---|---|
| entered by | `match/local/start` (seq 158) | `match/join` (seq 379) |
| `raid/configuration.raidMode` | `"Local"` (156) | `"Online"` (368, 373) |
| `match/local/start.mode` | `"TUTORIAL"` | — |
| `putMetrics.mode` | `"Training"` (209) | **`"Online"`** (399) |
| `putMetrics.sid` | `TUTORIAL_1891947_20_08_2026_01_20_33` | **`US-HOU01G013_6a8630f91174a60f6c207423_20.08.26_01-40-57`** |
| location | `Sandbox_start` | `Sandbox` |
| duration | `Metrics.TimeSpan` **948.26 s**; `results.playTime` 947 | `Metrics.TimeSpan` **84.03 s** |
| result posted | `results.result: "Survived"`, `exitName: "start_exit1"` | **nothing — no `match/local/end` at all** |

**Raid 1 is the tutorial and it was survived.** Seq 204 says so in as many
words: `serverId` begins `TUTORIAL_`, `results.result` is `"Survived"`,
`results.exitName` is `"start_exit1"`, and `Stats.Eft.SurvivorClass` is
`"Neutralizer"`. `Stats.Eft.Aggressor` records that a scav shot the player in
the right upper arm and `Stats.Eft.Victims` records the scavs the player killed,
but the player walked out. Anyone reading only seq 204 and expecting a death
will build the wrong thing.

**Raid 2 is the death.** The player joined a real BSG game server in Houston
(`US-HOU01G013`, session created 01:40:57 local = 22:40:57 UTC), spent 108.8 s
matching and 15.6 s loading (`putMetrics.ClientEvents`), played for **84
seconds**, and was back in the menu. Twelve seconds after the last keepalive the
client posted a `RestoreHealth` (seq 470) restoring **69.3 % of every single
body part** — Head 24.25/35, Chest 58.94/85, LeftArm 41.58/60 **with a
`Fracture`**, and so on, all seven parts at the same fraction — plus full Energy
and Hydration. At seq 204 the same profile was at full health on every part with
no effects. An 84-second raid and a uniform proportional health wipe is a death,
not an extract.

The word `"Killed"` appears nowhere in the capture, and that is the point:
**the death produced no HTTP request at all.** The server owned it. The client
learned about it by re-reading `game/profile/list` (seq 398) and then paying a
trader to patch it up. Any server that only implements `match/local/end` has no
mechanism for what actually killed this player.

## The clock

The keepalive bodies are plaintext, so they carry the only absolute timestamps:

| seq | utc_time | UTC | Δ |
|---|---|---|---|
| 168 | 1787178131.638247 | 22:22:11 | +0 s |
| 172 | 1787178271.580 | 22:24:31 | +139.9 s |
| 176 | 1787178411.632 | 22:26:51 | +280.0 s |
| 179 | 1787178551.630 | 22:29:11 | +420.0 s |
| 184 | 1787178691.656 | 22:31:31 | +560.0 s |
| 191 | 1787178831.651 | 22:33:51 | +700.0 s |
| 200 | 1787178971.925 | 22:36:11 | +840.3 s |
| 350 | 1787179158.509 | 22:39:18 | +1026.9 s |
| 386 | 1787179298.502 | 22:41:38 | +1166.9 s |
| 404 | 1787179446.324 | 22:44:06 | +1314.7 s |

**`/client/game/keepalive` fires every 140 seconds and it is a session
heartbeat, not an in-raid one.** Seqs 168–200 are in-raid, but 350 is
flea-market browsing and 404 is after `match/join`. It is simply the only
request a local raid makes, which is what makes that stretch *look*
raid-specific. The interval holds to within 30 ms over six consecutive gaps; the
two that do not (200→350 is 186.6 s, 386→404 is 147.8 s) both straddle a scene
load.

Cross-checks that all agree: `Info.RegistrationDate` = 1787178001 (22:20:01,
just after `profile/create` at seq 092); `Stats.Eft.LastSessionDate` = 1787178037
(22:20:37, raid 1 start) plus `playTime` 947 lands at 22:36:24, two seqs before
`match/local/end`; the RestoreHealth `timestamp` is 1787179458 (22:44:18). BSG
server-side ids are stamped in local time UTC+3.

## The seq gaps are not mysteries

`seq` is a Fiddler session number, so gaps are non-`/client` traffic. Reading
the header dump for all 506 sessions resolves them completely: they are
`CONNECT gw-pvp.escapefromtarkov.com:443` tunnels, BSG telemetry
(`POST /api/events/raw`), CDN quest icons, and Windows/Google background
chatter. **No game HTTP is missing.** The `GClient-RequestId` header is a
monotonic counter (seq 204 = 73, 379 = 157, 470 = 199) and it has no holes.

The long CONNECT runs are still useful as markers, because each sits exactly on
a scene transition: 049–067 (character select drawing), 161–167 (raid 1
loading), 210–223 (raid 1 → menu), 405–417 (raid 2 → menu). The server's slowest
answers — `items` 1,036,593 B, `dialogue` 2,573,985 B, `bot/generate` 23,697 B —
all land immediately before one.

## Session cookies

| | value | first seen |
|---|---|---|
| — | *(none)* | 014 `/launcher/game/start` |
| C1 | `PHPSESSID=sh8-03a803c183adb788815257c448f15de529` | 019 `/client/metadata` |
| C2 | `PHPSESSID=sh8-4af155b6ebb84cc65a00e8a24385dbc71c` | 028 `/client/game/version/validate` |

C1 is measured: the plaintext body of seq 014 is
`{"err":0,"errmsg":null,"data":{"session":"sh8-03a803c183adb788815257c448f15de529"}}`.
C2 appears on the first request after `/client/game/start` (026), so game/start
mints the play session — inferred from the cookie boundary, since 026's response
is encrypted.

The oddity: seq 402 `/client/libraries-extra` goes out on **C1**, mid raid-2
teardown, as `/client/libraries` (020) did at boot. The native early-bootstrap
layer keeps the launcher session and never switches.

## Phase table

| phase | seqs | what the client is doing |
|---|---|---|
| launcher / auth | 014 | `POST /launcher/game/start` (req 1,530 B), plaintext answer carrying the session id |
| native bootstrap | 019–020 | `/client/metadata` (414 B, plaintext, not JSON), `/client/libraries` (req 29,925 B, answer is the literal two bytes `{}`) |
| session handover | 024–028 | `game/mode` (`{"sessionMode":null}`) → `game/start` (empty body) → `game/version/validate` (`{"version":{"major":"1.1.0.1.46777","minor":"live","game":"live","backend":"6","taxonomy":"341"},"develop":true}`); cookie flips C1→C2 |
| pre-login static load | 030–048 | `menu/locale/en`, `languages`, `game/config`, `settings` (18,305 B), `putHWMetrics` (req 6,214 B → 86,116 B of JSON, `{Output,Errors}`), `locale/en` (706,897 B), `items` (1,036,593 B), `customization` (49,665 B), `/v2/client/game/profiles/` (465 B) |
| character-select data | 068–082 | first 304s (068, 069 — the client has an HTTP cache and honours it), `traderSettings`, `prestige/list`, main-quest lists, `variable/group`, `dialogue` (2,573,985 B), `tape/list`, `subtitle-track/list`, `season/active`, `battle-pass/active`, `handbook/templates` |
| **profile creation** | 083–098 | see below |
| menu entry #1 | 100–146 | `profile/status` → hideout set → **`game/token/issue`** (112, body `{}`, the only time in 220 requests) → `notifier/channel/create` → `builds/list`, `friends`, `achievement/*`, `quest/list` (58,465 B), `weather`, `ending/list`, `locations` (258,673 B), `mail/dialog/list`, `quest/chains` |
| **raid 1 — tutorial, local** | 148–209 | see below |
| menu reload | 224–263 | the static set again, mostly 304; `quest/list` is now 76,161 B where it was 58,465 B, for the identical request `{"completed":true}` |
| menu entry #2 | 266–299 | the canonical menu-entry sequence (below) |
| trading / flea / loadout | 301–365 | 8× `items/moving`, 6× `getTraderAssort`, 3× `items/prices`, 6× `ragfair/find`, 2× `insurance/items/list/cost`, `builds/weapon/save` (3,586 B of JSON), `builds/equipment/save` (10,275 B), one keepalive at 350 |
| **raid 2 — online, the death** | 368–404 | see below |
| final menu | 418–504 | third static reload, a `RestoreHealth` at 470, menu entry #3 (466–501), then `putLoadMetrics` and `match/group/invite/cancel-all` |
| logout | 506 | one `POST /client/game/logout`, empty body |

### The menu-entry sequence is a fixed shape

Seqs 266–299 and 466–501 are the same twelve calls in the same order:

```
game/profile/select  →  quest/chains  →  profile/status
  →  repeatalbeQuests/activityPeriods  →  game/profile/list
  →  game/profile/select  (again)      →  profile/status  (again)
  →  hideout/{settings,customization/offer/list,qte/list,areas,production/recipes}
  →  profile/status  (a third time)    →  notifier/channel/create
  →  server/list  →  match/group/current  →  survey  →  v2/shop/status
```

**`game/profile/select` is called twice per menu entry**, both times with the
identical body `{"uid":"6a862c118ad6a5aa18060240"}` (seqs 266/275, 466/474) — so
a server that treats select as a one-shot state transition sees it twice. And
**`profile/status` is polled three times** per menu entry (270, 277, 292;
468, 476, 491), all returning 193 B. It is a hot path.

The first menu entry (100–146) differs in one way: `game/token/issue` (112)
appears there and nowhere else. It is a create-once call.

## Profile creation, seqs 083–098

| seq | route | request body | resp |
|---|---|---|---|
| 083 | `game/profile/list` | *(empty)* | **81** (empty list) |
| 084 | `GET /client/globals` | — | 179,073 |
| 086 | `customization/storage` | *(empty)* | 833 |
| 088 | `game/profile/nickname/reserved` | *(empty)* | **81** |
| 090 | `game/profile/nickname/validate` | `{"nickname":"Savant_"}` | 97 |
| 092 | `game/profile/create` | `{"side":"Usec","nickname":"Savant_","headId":"5cde96047d6c8b20b577f016","voiceId":"5fc615110b735e7b024c76ea","seasonalPerkIds":null}` | 113 |
| 094 | `customization/storage` | *(empty)* | 833 |
| 096 | `game/profile/list` | *(empty)* | **8,577** |
| 098 | `game/profile/select` | `{"uid":"6a862c118ad6a5aa18060240"}` | 97 |

The 81 → 8,577 delta on `game/profile/list` across `profile/create` is the
clearest evidence in the capture: 81 is the floor, 8,577 is a compressed,
encrypted PMC-plus-scav pair. `create` answers 113 B, so it returns an id, not a
profile. `customization/storage` is asked twice with the same 833 B answer, and
the pre-create call cannot be profile-scoped because no profile exists yet.

### The emulator against this flow

The order and the shapes are right, with three concrete differences.

* `onProfileList` (`mods/tarkov/tarkov.nim:245`) builds from `allProfileIds()`,
  so it is genuinely empty before creation and emits PMC-then-scav after —
  matching both the 81 and the two-document reading of 8,577.
* `onNicknameValidate` (`tarkov.nim:415`) reads `nickname` — **matches** seq
  090 exactly.
* `onProfileSelect` (`tarkov.nim:353`) reads `uid` — **matches** seqs 098, 266,
  275, 466, 474 exactly.
* `onProfileCreate` (`tarkov.nim:389-390`) reads `nickname` and `side` — both
  present — but **ignores `headId` and `voiceId`**, which the client does send.
  The created character gets whatever head and voice `createProfile` defaults
  to, not the ones the player picked on the character screen. `seasonalPerkIds`
  is also unread; it is null here.
* `onProfileCreate` calls `bindSession` at `tarkov.nim:409`, binding the session
  itself. BSG's client does not rely on it — it calls `list` (096) then
  `select` (098) anyway — so the emulator is in the selected state one request
  earlier than BSG is.
* `onCustomizationStorage` (`tarkov.nim:1135`) always answers
  `{"_id": …, "suites": []}`, and at seq 086 there is no bound profile so `_id`
  is `""`. BSG answers 833 B, far above the floor, both times.

## Raid 1 — tutorial, local, seqs 148–209

```
148  tutor-game/check      {"skipTutorial":false}                        resp     97
150  tutor-game/profile    (empty)                                       resp  6,849
152  match/group/current   (empty)                                       resp     97
154  getMetricsConfig      (empty)                                       resp    225
156  raid/configuration    1,041 B JSON  location Sandbox_start          resp     81
158  match/local/start     {"serverId":null,"location":"Sandbox_start",
                            "timeVariant":"CURR","mode":"TUTORIAL",
                            "playerSide":"Pmc","transitionType":0,
                            "transition":null}                          resp 18,769
160  game/bot/generate     {"conditions":[5 x {Role,Limit,Difficulty}]}  resp 23,697
        ---- CONNECT tunnels only: the raid loads ----
168..200  game/keepalive x7                             22:22:11 .. 22:36:11
202  quest/complete        {"questId":"6895bbb0e7dac53c7c08797b"}        resp 18,161
204  match/local/end       76,839 B of JSON (see below)                  resp     81
208  game/profile/list     (empty)                                       resp 10,385
209  putMetrics            mode "Training", TimeSpan 948.26 s            resp     81
```

`raid/configuration` (seq 156) in full, less the 24-map dict:

```json
{"keyId":null,
 "onlinePveRaidStates":{ ...24 map names, all false... },
 "location":"Sandbox_start","transitionType":0,"timeVariant":"CURR",
 "metabolismDisabled":false,
 "timeAndWeatherSettings":{"isRandomTime":false,"isRandomWeather":false,
   "cloudinessType":"Clear","rainType":"NoRain","windType":"Light",
   "fogType":"NoFog","timeFlowType":"x0","hourOfDay":7},
 "botSettings":{"isScavWars":false,"botAmount":"AsOnline"},
 "wavesSettings":{"botAmount":"AsOnline","botDifficulty":"AsOnline",
   "isBosses":true,"isTaggedAndCursed":false},
 "timings":{},"side":"Pmc","raidMode":"Local",
 "playersSpawnPlace":"SamePlace","CanShowGroupPreview":true}
```

`game/bot/generate` (seq 160) asks for 51 bots in five buckets: assault ×10
hard, assault ×22 normal, marksman ×5 normal, marksman ×2 hard, and
`assaultTutorial` ×12 normal. It is the last request before the load gap, so
it is squarely on the loading-screen critical path.

The raid ran 948 seconds and the client made **no** HTTP request during it
except the heartbeat. Everything it needed came from the 18,769 B of
`match/local/start` and the 23,697 B of `bot/generate`.

### `/client/match/local/end` — the full contract

Seq 204 decodes to 76,839 bytes of JSON. The top level:

```
serverId          "TUTORIAL_1891947_20_08_2026_01_20_33"
results
  profile         the entire post-raid profile (see below)
  result          "Survived"
  killerId        "6a862c329eca0c1b7b0b1c0b"     <- set even on a survival
  killerAid       "0"
  exitName        "start_exit1"
  inSession       true
  favorite        false
  playTime        947
lostInsuredItems  []      <- the CLIENT tells the server what was lost
transferItems     {"656f0f98d80a697f855d34b1_transit":[{"_id":…,"_tpl":…}]}
locationTransit   null
```

`results.profile` carries 39 members: `_id`, `aid`, `savage`, `karmaValue`,
`Info`, `Customization`, `Encyclopedia`, `Health`, `Inventory` (93 items),
`InsuredItems`, `Skills`, `Notes`, `TaskConditionCounters`, `Quests` (22),
`Achievements`, `Prestige`, `Variables`, `SeasonalPerks`,
`SeasonalPerkEffectParameters`, `SeasonalRewards`, `moneyTransferLimitData`,
`battlePassDocumentLimitData`, `Bonuses`, `Hideout`, `RagfairInfo`,
`UnlockedInfo`, `WishList`, `Stats`, `CheckedMagazines`, `CheckedChambers`,
`TradersInfo`, `CompletableItems`, `QuestNotes`, `ReadQuestData`, `Ending`,
`UnlockedLocations`, `BattlePassUniversalDocumentBalance`, `BattlePassProgress`.

`Stats.Eft` has fifteen members: `SessionCounters`, `OverallCounters`,
`SessionExperienceMult`, `ExperienceBonusMult`, `GameEditionExperienceBonus`,
`TotalSessionExperience` (4420), `LastSessionDate`, `Aggressor`,
`DroppedItems`, `FoundInRaidItems`, `Victims`, `CarriedQuestItems`,
`DamageHistory`, `TotalInGameTime`, `SurvivorClass`. `SessionCounters.Items` is
the `{Key:[…],Value:n}` list form — `["AmmoUsed"]` 109, `["HitCount"]` 61,
`["CauseBodyDamage"]` 220933.

**One trap worth naming loudly.** `results.profile.Health.UpdateTime` is
**1787178003** — 22:20:03, thirty-four seconds *before* the raid started
(`LastSessionDate` 1787178037). Every body part reads `Current == Maximum`.
The `Health` block in this payload is the **pre-raid** snapshot, not the
post-raid one. A server that copies it verbatim heals the player for free after
every raid. That is exactly what `onMatchEnd` does (`tarkov.nim:1476`,
`Profile(id: p.id, text: raw(played))`).

## Raid 2 — online, the death, seqs 368–404

```
368  raid/configuration            1,035 B, location Sandbox, raidMode "Online"
369  match/group/invite/cancel-all (empty)
371  match/group/invite/cancel-all (empty)
373  raid/configuration            1,035 B, byte-identical to 368
376  match/group/exit_from_menu    (empty)
377  match/available               (empty)
379  match/join                    {"location":"Sandbox","savage":false,
                                    "dt":"CURR","servers":[191 x
                                    {"ping":-1,"ip":"…","port":"0"}],
                                    "keyId":""}                     resp 289
381  profile/status                (empty)                          resp 305   <- NOT 193
384  profile/status                (empty)                          resp 305
386  game/keepalive                                          22:41:38
388  profile/status                (empty)                          resp 305
390  getMetricsConfig              (empty)                          resp 225
394  putLoadMetrics                {"onlineAffiliation":1,"metricsType":1,
                                    "metricsValue":135,"locationName":"Sandbox",
                                    "isPMC":true}
398  game/profile/list             (empty)                          resp 14,241
399  putMetrics                    mode "Online", TimeSpan 84.03 s,
                                    sid US-HOU01G013_…_01-40-57
402  libraries-extra               7,980 B, on cookie C1            resp 96
404  game/keepalive                                          22:44:06
        ---- CONNECT tunnels only ----
418  ... the menu again; 470 RestoreHealth at 22:44:18
```

The online `raid/configuration` differs from the tutorial's in exactly four
fields: `keyId` `null`→`""`, `location` `Sandbox_start`→`Sandbox`,
`transitionType` `0`→`1`, `raidMode` `Local`→`Online`, and inside
`timeAndWeatherSettings`, `timeFlowType` `x0`→`x1` and `hourOfDay` `7`→**`-1`**.
Seqs 368 and 373 are byte-identical — the client posts the same configuration
twice, with two `cancel-all` calls between them.

`putMetrics.ClientEvents` at seq 399 breaks the 84-second raid down:
`MatchingCompletedReal` 115.36, `LocationLoadedReal` 22.21, `GameRunned` 123.37.
So ~115 s of matchmaking and loading — which is what `putLoadMetrics`
`metricsValue: 135` reports — then 84 s of play. `putLoadMetrics` fires three
times for this one raid, all with `locationName: "Sandbox"`: seq 394
(`metricsType: 1`, 135), seq 465 (`metricsType: 2`, 14), seq 502
(`metricsType: 3`, 10).

### `match/local/start` vs `match/join`, measured

| | `match/local/start` (158) | `match/join` (379) |
|---|---|---|
| request | 139 B of JSON, 7 fields | 8,569 B of JSON, 5 fields |
| what it names | one location, one `mode`, one side | a location, a savage flag, and **191 candidate game servers with the client's own ping to each** |
| response | 18,769 B | 289 B |
| `raid/configuration.raidMode` before it | `"Local"` | `"Online"` |
| preceded by | `raid/configuration` only | `cancel-all` ×2, `raid/configuration` ×2, `exit_from_menu`, `match/available` |
| followed by | `game/bot/generate`, 51 bots | nothing of the kind |
| `profile/status` after | not polled | polled 3× (381, 384, 388), 305 B each |
| how it ends | client POSTs `match/local/end`, 76,839 B of JSON | **nothing is posted** |
| `putMetrics.mode` | `"Training"` | `"Online"` |
| `putMetrics.sid` | `TUTORIAL_…` | `US-HOU01G013_…` |

`match/local/start` is the **client-hosted** path: the tiny request names a map
and a mode, the large response is everything the client needs to run the raid
itself, and the very next call asks the server to manufacture the bot roster —
something only a client-hosted raid needs. The result comes back the same way it
went out: the client posts its entire played profile and the server believes it.

`match/join` is the **server-hosted** path. The 8.5 KB request is a matchmaking
ticket, and the interesting half of it is `servers` — **the client posts back
the 191-entry server list it got from `/client/server/list` (seq 293), annotated
with its own ping measurements**, and BSG picks one. The 289-byte answer is a
ticket, not raid content. No bots are requested. And nothing is posted at the
end, because the client was never the authority on what happened — which is
precisely why an 84-second death leaves no trace in the HTTP.

### `profile/status`: 193 vs 305

| seq | resp | context |
|---|---|---|
| 100, 122 | 193 | menu entry #1 |
| 270, 277, 292 | 193 | menu entry #2 |
| **381, 384, 388** | **305** | after `match/join` |
| 468, 476, 491 | 193 | menu entry #3 |

The request body is empty every time, so the 112-byte difference is entirely the
server's doing. That is seven blocks of compressed growth on a 193-byte
baseline — too much for an enum word changing value, which compresses to
nothing. It is fields becoming non-empty. The emulator's own shape
(`tarkov.nim:1152-1181`) names the candidates: `status`, `sid`, `ip`, `port`,
`profileToken` — `"Free"`, `""`, `""`, `0`, `null` in the menu, and an address,
a port, a match id and a token when a raid is live. That mapping is inference;
the size change and its timing are not.

The behavioural fact is what matters: **the client polls `profile/status` three
times immediately after `match/join`, and the answer is a different size.** That
is the server handing over the address, and it is also the reconnect
mechanism — a client that restarts mid-raid asks this and is told the raid is
still there. By seq 468 it is 193 again, so the pending state is cleared before
the menu comes back.

## The server state machine

**[M]** measured, **[I]** inferred, **[K]** known from the emulator's own DTO
knowledge rather than from the capture.

```
                 launcher/game/start  [M: returns session id, plaintext]
                          |
                 game/start  [I: mints the play session; cookie flips here]
                          |
                   +------v------+
                   |  NO PROFILE |  profile/list -> 81 (empty)        [M]
                   +------+------+
                 profile/create {side,nickname,headId,voiceId}        [M]
                          |
                   +------v------+
                   |   CREATED   |  profile/list -> 8,577             [M]
                   +------+------+
                 profile/select {uid}                                 [M]
                          |
              +-----------v-----------+
              |  MENU (session bound) |  profile/status -> 193         [M]
              +---+---------------+---+
   raidMode Local |               | raidMode Online
  match/local/start               match/available -> match/join
        |                              |
  +-----v------+                +------v------+
  | LOCAL RAID |                | RAID PENDING|  profile/status -> 305 [M]
  | client owns|                | server owns |  polled 3x             [M]
  +-----v------+                +------v------+
   match/local/end                     |
   76,839 B of JSON  [M]               |  NOTHING is posted            [M]
        |                              |
        +--------------+---------------+
                       v
              MENU, profile/status -> 193                              [M]
              profile/list re-read                                     [M]
```

What the server must hold, and when it must change it:

1. **session → profile.** Set at `profile/select`, twice per menu entry [M], so
   the write must be idempotent.
2. **The raid's own settings, from `raid/configuration`, held until the raid
   ends** [M]. This is not optional bookkeeping: `match/local/end` carries **no
   `location` field at all**, so the only place the map name exists is the
   `raid/configuration` and `match/local/start` bodies sent 16 minutes earlier.
   Anything that needs to know where the raid happened — location-qualified
   quest conditions, insurance messages — must get it from there.
3. **A raid becomes pending at `match/join`** [M — seq 381 is the first 305 and
   the first `profile/status` after 379]. Whether `match/local/start` also flips
   it is unknown: no `profile/status` was issued between 158 and 204 [M, by
   absence]. A client-hosted raid needs no reconnect address, so probably not
   [I].
4. **`profile/status` answers two shapes** [M], and the pending one is cleared
   before the menu returns [M].
5. **At `match/local/end` the server takes `results.profile` and must not trust
   its `Health`** [M — `UpdateTime` predates the raid]. What else it must do
   is [K], not from the capture: apply inventory, settle `lostInsuredItems`
   (which the *client* supplies as a top-level list — the server is told, not
   asked), handle `transferItems` for anything carried into transit, fold
   `TaskConditionCounters` and `Stats.Eft.Victims` into quest progress, and
   record `playTime`, `exitName`, `result` and the `Stats.Eft` session counters.
6. **The write must land before the next request** [M]: the client re-reads
   `game/profile/list` at seq 208 and expects it to have changed (8,577 →
   10,385).
7. **`quest/complete` is its own route and it fires from inside the raid** [M,
   seq 202, body `{"questId":…}`], before `match/local/end`. Quest completion
   is therefore not only an item-event action, and it can land before the raid
   result is applied.
8. **The online path needs a server-side raid result with no client report**
   [M]. This is the one the capture proves exists and cannot show the content
   of.
9. **The heartbeat is 140 s and session-wide** [M].

Things that measurably change across a raid, and which the client therefore
re-reads expecting to see changed: `game/profile/list` (8,577 → 10,385),
`quest/list` (58,465 → 76,161 for the identical `{"completed":true}` request),
and `customization/storage` (833 → 1,073).

## Where the emulator differs — exact, with file:line

Route coverage belongs to [EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md). These
are the temporal and parser differences, and with the request bodies readable
the parser half is now exact rather than speculative.

### The one that stops everything

**1. `onMatchEnd` reads the wrong two fields, and they are the only two it
reads.**

`mods/tarkov/tarkov.nim:1378-1379`:

```nim
let outcome = parseResult(field(body, "exit").asText("Left"))
let played = field(body, "profile")
```

The real body has neither. The exit status is at **`results.result`** and the
profile is at **`results.profile`**. `field()` resolves dotted paths (it is used
that way at `emu/health.nim:169`), so these are looking for top-level members
that do not exist. Against BSG's actual 76,839-byte payload:

* `field(body, "profile")` is not found, so `tarkov.nim:1381-1384` takes the
  early return and logs *"match/end carried no profile; the raid changed
  nothing"*. **The raid changes nothing.** No inventory, no insurance, no quest
  progress, no stats, no achievements.
* `field(body, "exit")` defaults to `"Left"`, so even if the profile were found
  the outcome would always be "left early, keeps gear" — a death would never
  cost anything.

The correct values are already the right *vocabulary*: `parseResult`
(`emu/raid.nim:26-33`) maps `"Survived"`/`"Killed"`/`"Left"`/`"Runner"`/
`"MissingInAction"`, and `results.result` is `"Survived"` here. Only the path is
wrong. Note also that `exitName` (`"start_exit1"`) is a separate field from
`result` and neither substitutes for the other.

### The rest, in descending order of consequence

**2. `raidLocation` cannot find the location, and its fallback produces
garbage.**
`emu/quests.nim:503-522` tries `field(body, "location")` — absent from the real
payload — then falls back to splitting `serverId` on `'.'`. The real `serverId`
is `TUTORIAL_1891947_20_08_2026_01_20_33`, which contains no `'.'`, so the whole
string is returned as the map name. For an online raid it would be
`US-HOU01G013_6a8630f91174a60f6c207423_20`. Every `Location`-qualified quest
condition is then evaluated against a string that is not a map. The doc comment
at `emu/quests.nim:506-509` describes a `bigmap.1700000000` form that this
client does not use. The real location has to come from `raid/configuration` or
`match/local/start` and be remembered — see item 5.

**3. There is no pending-raid state.**
`onProfileStatus` (`tarkov.nim:1152`) hardcodes `"Free"` at `tarkov.nim:1164`
and `tarkov.nim:1174`, with `profileToken` null and `sid`/`ip`/`port` empty,
unconditionally. Nothing produces the 305-byte shape of seqs 381/384/388.
Reconnect is impossible: a client that restarts mid-raid is told it is Free.

**4. `/client/match/join` is not served.**
`tarkov.nim:1944-1950` registers `local/start`, `local/end`, `available`,
`group/current`, `group/status`, `group/exit_from_menu` and `exit` — not
`join`. That is the entire online entry path, and it is the path the player
actually died on. There is also no handler anywhere for a raid result that
arrives without a client POST (`onMatchEnd`, `tarkov.nim:1364`, is bound to
`/client/match/local/end` alone at `tarkov.nim:1945`), so insurance
(`tarkov.nim:1449`), quest advance (`tarkov.nim:1499`) and achievements
(`tarkov.nim:1506`) have no trigger on that path at all.

**5. `onMatchStart` records nothing, so nothing survives the raid.**
`tarkov.nim:1344-1362` resets the per-raid skill counter and returns a
`serverId`/`serverSettings`/`"busy"` object. It reads **none** of the seven
fields the client sends (`serverId`, `location`, `timeVariant`, `mode`,
`playerSide`, `transitionType`, `transition`) — so it never learns that this was
`mode: "TUTORIAL"` on `Sandbox_start`. Consequences: no location for item 2, no
pending state for item 3, no way to tell a genuine result from a replay, and the
pre-raid profile that `lostAfterRaid` needs is re-read from disk at end time
(`tarkov.nim:1369`) rather than snapshotted at start, so everything the player
did between start and end counts as "lost in the raid".

**6. `raid/configuration`'s echo names a field the client never sends.**
`emu/raid.nim:276` emits `profileId` from `field(body, "profileId")`. There is
no `profileId` in seqs 156, 368 or 373, so it is always `""`. The other four
echoed members — `location`, `timeVariant`, `raidMode`, `side`
(`emu/raid.nim:278-281`) — **all match** the real body exactly.

**7. `raidClock` accepts `timeFlowType: "x0"` and produces a zero-length raid.**
`emu/raid.nim:350-386` reads `timeAndWeatherSettings.isRandomTime`,
`.hourOfDay` and `.timeFlowType`, and **all three key names are exactly right** —
the concern in the comment about PascalCase spelling does not apply. It handles
`hourOfDay: -1` correctly (the online raid), rejecting it at
`emu/raid.nim:359-360`. But the tutorial sends `timeFlowType: "x0"`, and
`timeFlow` parses that as a known 0.0, which passes the `parsed < 0.0` guard at
`emu/raid.nim:367` and yields `spanHours = 0.0` — a raid collapsed to a single
instant, which is the exact failure the `MaxTimeFlow` comment at
`emu/raid.nim:311-321` warns about for a different reason. `x0` is a real,
observed value from a real client.

**8. `raid.nim`'s standing caveat is now answerable.**
`emu/raid.nim:325-338` says *"A raid has never been run against BSG's client, so
which of the three it actually posts is unknown."* It posts **all three**:
`timeVariant` (`"CURR"`), `IsNightRaid`'s neighbours in
`timeAndWeatherSettings`, and a real `hourOfDay` (`7` for the tutorial, `-1`
for the online raid). There is no `isNightRaid` member in either body. The
comment can be replaced with the quoted request above.

**9. `/client/quest/complete` is not served, and when it is, the key is
`questId`.**
Quest completion exists only as an item-event arm — `emu/quests.nim:51` maps
`"QuestComplete"` to `qaComplete`, handled at `emu/quests.nim:416` and
`emu/quests.nim:705`, reading the id from `body.field("qid")`
(`emu/quests.nim:365`, `emu/quests.nim:698`). The standalone route at seq 202
sends **`{"questId":"6895bbb0e7dac53c7c08797b"}`** — a different key. Against
this emulator the request 404s and the tutorial never closes.

**10. `tutor-game/check` and `tutor-game/profile` are not served.**
Seqs 148, 150, 257, 454. The body is `{"skipTutorial":false}` and it is sent on
**every** menu entry, not just the first. It is the gate in front of the tutorial
raid that a brand-new profile is pushed into.

**11. `/client/getMetricsConfig` is not served.**
Seqs 154 and 390, empty body both times — immediately before
`raid/configuration` on the local path and immediately after the
`profile/status` poll on the online path. Both times, directly on the raid-entry
sequence.

**12. `/client/putLoadMetrics` accepts the request but discards a real payload.**
`tarkov.nim:2000` routes it to `onNullData`. The body is
`{"onlineAffiliation","metricsType","metricsValue","locationName","isPMC"}` and
it fires three times per raid. Discarding is defensible; it is listed because
this is now known content rather than an unknown.

**13. `/client/libraries-extra` and `/client/match/group/invite/cancel-all` are
not served.**
`libraries-extra` at seq 402 posts 7,980 B on cookie C1 and gets 96 B back — not
the 81-byte floor, so it returns something. `onLibraries` (`tarkov.nim:995`) gets
the bare-`{}` treatment right for `/client/libraries` but has no counterpart
here. `cancel-all` appears at seqs 369, 371 and **504** — and 504 is the request
immediately before `game/logout`, so it is on the shutdown path too.

**14. `profile/create` drops the player's face and voice.**
`tarkov.nim:389-390` reads `nickname` and `side`; the client also sends
`headId: "5cde96047d6c8b20b577f016"` and
`voiceId: "5fc615110b735e7b024c76ea"` (seq 092), and neither is read anywhere.

**15. `customization/storage` never grows.**
`onCustomizationStorage` (`tarkov.nim:1135`) always answers empty `suites`.
BSG answers 833 B at seqs 086/094 and **1,073 B** at 260 and 457 — the tutorial
raid granted clothing and it stayed granted. Registered on two paths
(`tarkov.nim:1936`, `tarkov.nim:2009`); only `/client/customization/storage` is
used by this client.

**16. `version/validate` reads a string where the client sends an object.**
`tarkov.nim:174` does `field(body, "version").asText("")`, but seq 028 sends
`version` as an object of five members. It also reads `key`
(`tarkov.nim:175`); the real body's second member is `develop: true`. The
handler accepts everything regardless (`tarkov.nim:225-228` is explicit about
that), so nothing breaks — but neither read can ever succeed.

**17. Small parser mismatches that currently cost nothing.**
`onQuestList` (`tarkov.nim:943`) ignores the body's `{"completed":true}` and
returns everything. `onMailList` (`tarkov.nim:1699`) ignores
`{"limit":30,"offset":0}` and returns the whole dialog list. Both are fine at
this scale and both are wrong at a larger one.

**18. The keepalive body is the wrong type, and the envelope is a different
shape.**
Seq 168's plaintext body is:

```json
{"data":{"msg":"OK","utc_time":1787178131.638247},"err":null,"errmsg":null,
 "status":null,"errLog":{},"error":{"code":null,"message":null}}
```

`onKeepAlive` (`tarkov.nim:230-234`) writes `put(o, "utc_time", nowSeconds())` —
an **integer** where BSG sends a float with microsecond precision — inside
`envelope`, which is `{"err":0,"errmsg":null,"data":…}`
(`aowl/src/aowlspt/server.nim:654-656`). BSG's has `err: null` rather than `0`,
puts `data` first, and carries `status`, `errLog` and `error` besides. The client
accepts the emulator's shorter envelope, so this is a recorded difference, not a
defect — but it is the only envelope anyone has actually read.

### What the emulator gets exactly right

Worth stating, because it is most of the surface and it was checked field by
field against the real bodies:

* **Item events.** `emu/inventory.nim:185-212` (`Move`: `item`, `to.id`,
  `to.container`, `to.location.{x,y,r}`), `:235-256` (`Split`: `splitItem`,
  `newItem`, `container`, `count`), `:271-272` and `:407-409` (`Transfer`:
  `item`, `with`, `count`), `:371-397` (`Swap`: `item`, `to`, `item2`, `to2`),
  `:318` (`Examine`), and the envelope `{"data":[…],"tm":…,"reload":…}` at
  `tarkov.nim:726` — every one matches seqs 301, 303 and 318 exactly.
* **Trading.** `emu/trading.nim:343-373` (`buy_from_trader`: `tid`, `item_id`,
  `count`, `scheme_id`, `scheme_items`) and `:435-491` (`sell_to_trader`:
  `items[].{id,count}`, `tid`) match seqs 331 and 326.
* **Bots.** `emu/bots.nim:624-633` reads `conditions[].{Role,Limit,Difficulty}`
  — exactly seq 160, casing included, and the doc comment at
  `emu/bots.nim:622` already quotes the right shape.
* **Health.** `emu/health.nim:406-462` reads `trader`, `difference`,
  `difference.BodyParts.<part>.Health` and `.Effects` — matching seq 470.
  (The real `Effects` is a *list* `["Fracture"]` or `null` inside the request,
  while the profile stores a dict; whether `emu/health.nim:462` handles both was
  not checked.)
* **Insurance quote.** `tarkov.nim:1813-1814` reads `traders` and `items` —
  exactly seqs 355 and 365.
* **Build saves.** `emu/builds.nim:102-122` reads `Name`, `Id`, `Root`, `Items`
  with lowercase fallbacks — matching seqs 305 and 359, which use the
  capitalised spelling.
* **Profile select.** `tarkov.nim:353` reads `uid` — matching all five
  occurrences.

## What was not checked

* Nothing here was verified against a running server. The emulator claims are
  from reading source.
* No response body other than the four plaintext ones was read. Every claim
  about response *content* remains inference from length.
* Three request bodies did not decode and were not examined.
* The `Effects` list-versus-dict question in `emu/health.nim:462`.
* Whether `match/local/start` also flips `profile/status` to the 305-byte shape.
  The capture never asks between seqs 158 and 204.
* What BSG's server actually did with the online death — the result exists only
  in an encrypted `game/profile/list` response.
* The scav side is entirely absent. Both raids were PMC (`side: "Pmc"`,
  `savage: false`), so scav cooldown, karma and `savage/regenerate` have no
  observed timeline.
