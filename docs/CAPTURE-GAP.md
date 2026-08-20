# Capture gap: what a real client asked BSG for, against what this server answers

`mods/tarkov/data/capture/raid1/` is a complete session against BSG's live
servers, taken with a real post-1.0 client (build 1.1.0.1.46777): launcher
start, a profile created from nothing, the menu, trading and the flea market,
a raid, the menu again, a second raid entry, and a logout. 220 requests.

[EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md) measures this server against a
*reference implementation* — SPT's callback surface, which is itself a
reconstruction. This measures it against **the client's own traffic**, which is
the only source in this repository that cannot be wrong about what the client
asks for. Where the two disagree, this one wins.

## First, a correction to how this capture has been described

It has been summarised as ending in a death. It does not. The decoded request at
seq 204 says:

```json
"serverId": "TUTORIAL_1891947_20_08_2026_01_20_33",
"results": { "result": "Survived", "exitName": "start_exit1", "playTime": 947 }
```

and seq 158 started it with `"location": "Sandbox_start", "mode": "TUTORIAL"`.
**The raid in this capture is the tutorial, on Ground Zero, survived after 947
seconds.** There is a `killerId` in the results, so the player was hit, but the
outcome field is `Survived`. Anything calibrated against "the player died here"
should be re-read — in particular, this capture contains **no** evidence about
what a normal PMC raid entry or a death looks like.

## What can and cannot be read from the capture

**Request bodies: readable.** The wire obfuscation was broken during this
session, and 147 of the 150 game request bodies are decoded to plain JSON in
`scratchpad/reqjson/<seq>.json`. 52 of those decode to non-empty documents; the
other 95 are the 18–27 byte bodies, which carry no fields (they decode to
nothing, consistent with `{}` plus the obfuscation wrapper). Full request
headers for all 506 captured sessions are in `scratchpad/reqs/reqs.json`.

**Response bodies: not readable.** `bodies/*.bin` are responses after
transport-gunzip. Four are plaintext — `/launcher/game/start` (seq 014),
`/client/metadata` (019), `/client/libraries` (020) and `/client/game/keepalive`
(168 and its nine repeats). Every other response carries `X-Encryption: aes` and
is ciphertext; the key is not known and nothing here pretends otherwise. So
every claim below about a *response* shape is derived from its length.

That length is nevertheless a real measurement. For an encrypted route
`resp_declen` is (compressed plaintext + encryption overhead), because BSG
compresses before encrypting — the evidence being `/client/locale/en` arriving
in 706,897 bytes, which no plausible locale table fits uncompressed. This server
also deflates every response on the wire. **So BSG's `resp_declen` and this
server's compressed wire length are comparable to within the ~17 bytes of header
and IV.** The calibration is visible in the table: `/client/settings` is 18,305
against 16,315, `/client/items` 1,036,593 against 1,275,375, `/client/locale/en`
706,897 against 772,466. Three independent routes landing within 25% is not a
coincidence, and it is why the outliers further down can be trusted.

**The manifest is close to complete, which matters for the "never called"
claims.** `reqs.json` records 231 requests to `*.escapefromtarkov.com`; the
manifest carries 220 of them. The eleven it omits are two `CONNECT` tunnels
(006, 013), `POST /launcher/analytics` (007), `GET
lobby.escapefromtarkov.com/router?vhost=pvp` (114), and seven CDN asset fetches
from `s3-prod` (141–144, 165, 166, 314). **Not one omitted request is a
`/client/*` route.** The 286 sequence numbers absent from the manifest are
`CONNECT` tunnels and third-party telemetry — Yandex Metrica, Microsoft, Google
Safe Browsing. So "this session never called X" is a strong claim here, not a
hedge.

## What every game request carries

Every one of the 217 requests with an `App-Version` header carries:

```
App-Version:         EFT Client 1.1.0.1.46777
X-Unity-Version:     2022.3.43f2
User-Agent:          UnityPlayer/2022.3.43f2 (UnityWebRequest/1.0, libcurl/8.5.0-DEV)
GClient-RequestId:   <integer, 1..217>
Accept-Encoding:     deflate, gzip
Content-Type:        application/json
Cookie:              PHPSESSID=sh8-...
```

`GClient-RequestId` is a per-session counter; it is not monotone in capture
order, because requests complete out of order. Nothing in
`backend/aowlbackend.nim` or `mods/tarkov/` reads either `App-Version` or
`GClient-RequestId`, and nothing yet appears to need to. They are recorded
because they are the two headers a version gate or a request-dedup would use,
and because a server that ignores both is indistinguishable from one that has
never heard of them.

## How the two route tables were derived

**The client's table** is the 220 records, with 24-hex-character path segments
folded to `{id}` and query strings dropped: 82 distinct (method, route) pairs.

**This server's table** was taken two ways and they agree. Statically:

```
grep -oE 'serve(Prefix)?\("[^"]+"' mods/tarkov/tarkov.nim | sort -u   # 111
```

`registerRoutes` in `mods/tarkov/tarkov.nim` is the only registration site —
`serve`/`servePrefix` appear nowhere else under `mods/tarkov/`,
`emu/sessions.nim` registers nothing, and no `emu/*.nim` file contains a
`"/client/` literal at all. Dynamically: the backend logs `ok route <url>` for
every successful registration, so the running server's own list is in
`aowlspt-backend.log`.

Of the 111, six are this project's own (`/aowlspt/tarkov/*`), leaving 105
client-facing routes.

## How the response sizes were measured

By running the server, not by reading it. `backend/bin/aowlspt-backend.exe` was
started against a scratch stage carrying `build/db/db.json` (the real imported
41 MB database, not a test fixture) and `installer/build/emustage`'s
`mods/tarkov/tarkov.dll`, on port 6981. A profile was created and selected, and
then every one of the 82 captured routes was called over HTTP with a zlib-framed
body, exactly as `backend/wire.nim` frames it. Both the deflated wire length and
the inflated JSON were recorded.

**The binary is older than the source, and this is load-bearing.** The staged
`tarkov.dll` was built at 15:49 on 2026-08-19; `tarkov.nim` has been edited since
(it changed twice while this document was being written, by another session).
The dll registers 100 routes, the current source registers 111, and the eleven
that exist only in source are exactly the post-1.0 menu-boot additions:

```
/client/battle-pass/active      /client/putHWMetrics
/client/customization/storage   /client/putLoadMetrics
/client/friends                 /client/season/active
/client/game/token/issue        /client/seasonal-perks/list
/client/libraries               /v2/client/game/profiles
                                /v2/client/shop/status
```

Those eleven answered 404 to the probe **because the binary predates them**, not
because the server does not serve them. They are marked *yes (src only)* in the
table and their size cells are `n/a`. Nothing was rebuilt to close this gap:
another session was editing the tree, and `docs/` already records what a
concurrent nimony build does to a shared `nimcache`. **So eleven routes have a
verified registration and an unverified response.**

## The route table

82 routes, in the order the client first called them. *Phase* is which part of
the session the first call falls in: `boot` (seq 014–048, launcher and il2cpp
bootstrap), `menu` (068–150, first menu load and profile creation), `raid-in`
(152–160), `in-raid` (168–200), `raid-out` (202–209), `menu-2` (224–299),
`trade` (301–365, inventory, traders and the flea), `raid-2` (368–404, the
second raid entry, which went through `match/join` rather than
`match/local/start`), `menu-3` (418–504), `logout` (506).

*BSG resp* is `resp_declen`. *Emu resp* is this server's deflated wire length,
measured as described above. **`n/a` means not measured, not zero.**

| # | Method | Route | Calls | First seq | Phase | Req bytes | BSG resp (declen) | Enc | 304 | Emulator | Emu resp (wire) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | POST | `/launcher/game/start` | 1 | 014 | boot | 1530 | 84 | plain |  | **no** | n/a |
| 2 | POST | `/client/metadata` | 1 | 019 | boot | 49 | 414 | plain |  | yes | 128 |
| 3 | POST | `/client/libraries` | 1 | 020 | boot | 29925 | 2 | plain |  | yes (src only) | n/a |
| 4 | POST | `/client/game/mode` | 1 | 024 | boot | 47 | 145 | aes |  | yes | 73 |
| 5 | POST | `/client/game/start` | 1 | 026 | boot | 22 | 145 | aes |  | yes | 59 |
| 6 | POST | `/client/game/version/validate` | 1 | 028 | boot | 117 | 81 | aes |  | yes | 52 |
| 7 | GET | `/client/menu/locale/en` | 1 | 030 | boot | 0 | 721 | aes |  | yes | 675 |
| 8 | GET | `/client/languages` | 1 | 033 | boot | 0 | 273 | aes |  | yes | 212 |
| 9 | POST | `/client/game/config` | 1 | 034 | boot | 23 | 625 | aes |  | yes | 379 |
| 10 | GET | `/client/settings` | 4 | 037 | boot | 0 | 18305 | aes |  | yes | 16,315 |
| 11 | POST | `/client/putHWMetrics` | 1 | 038 | boot | 6214 | 81 | aes |  | yes (src only) | n/a |
| 12 | GET | `/client/locale/en` | 1 | 043 | boot | 0 | 706897 | aes |  | yes | 772,466 |
| 13 | POST | `/client/seasonal-perks/list` | 4 | 044 | boot | 20-25 | 3985 | aes |  | yes (src only) | n/a |
| 14 | GET | `/client/items` | 4 | 045 | boot | 0 | 1036593 | aes | yes | yes | 1,275,375 |
| 15 | GET | `/client/customization` | 4 | 046 | boot | 0 | 49665 | aes | yes | yes | 39,049 |
| 16 | POST | `/v2/client/game/profiles/` | 1 | 048 | boot | 19 | 465 | aes |  | yes (src only) | n/a |
| 17 | GET | `/client/trading/api/traderSettings` | 3 | 071 | menu | 0 | 39681-39697 | aes |  | yes | 33,642 |
| 18 | GET | `/client/prestige/list` | 3 | 072 | menu | 0 | 9889 | aes | yes | yes | 7,030 |
| 19 | GET | `/client/quest/getMainQuestsList` | 3 | 073 | menu | 0 | 273 | aes | yes | **no** | n/a |
| 20 | GET | `/client/quest/getMainQuestNotesList` | 3 | 074 | menu | 0 | 18817 | aes | yes | **no** | n/a |
| 21 | GET | `/client/variable/group` | 3 | 075 | menu | 0 | 5601 | aes | yes | **no** | n/a |
| 22 | GET | `/client/dialogue` | 3 | 076 | menu | 0 | 2573985 | aes | yes | **no** | n/a |
| 23 | GET | `/client/tape/list` | 3 | 077 | menu | 0 | 2977 | aes | yes | **no** | n/a |
| 24 | GET | `/client/subtitle-track/list` | 3 | 078 | menu | 0 | 3905 | aes | yes | **no** | n/a |
| 25 | POST | `/client/season/active` | 3 | 080 | menu | 18-26 | 1825 | aes |  | yes (src only) | n/a |
| 26 | POST | `/client/battle-pass/active` | 3 | 081 | menu | 21-26 | 6673 | aes |  | yes (src only) | n/a |
| 27 | GET | `/client/handbook/templates` | 3 | 082 | menu | 0 | 88401 | aes | yes | yes | 74,604 |
| 28 | POST | `/client/game/profile/list` | 6 | 083 | menu | 18-25 | 81-14241 | aes |  | yes | 2,012 |
| 29 | GET | `/client/globals` | 3 | 084 | menu | 0 | 179073 | aes | yes | yes | 106,959 |
| 30 | POST | `/client/customization/storage` | 4 | 086 | menu | 18-27 | 833-1073 | aes |  | yes (src only) | n/a |
| 31 | POST | `/client/game/profile/nickname/reserved` | 1 | 088 | menu | 22 | 81 | aes |  | yes | 38 |
| 32 | POST | `/client/game/profile/nickname/validate` | 1 | 090 | menu | 50 | 97 | aes |  | yes | 66 |
| 33 | POST | `/client/game/profile/create` | 1 | 092 | menu | 135 | 113 | aes |  | yes | 64 |
| 34 | POST | `/client/game/profile/select` | 5 | 098 | menu | 52-61 | 97 | aes |  | yes | 105 |
| 35 | POST | `/client/profile/status` | 11 | 100 | menu | 21-27 | 193-305 | aes |  | yes | 139 |
| 36 | GET | `/client/hideout/settings` | 3 | 107 | menu | 0 | 193 | aes | yes | yes | 147 |
| 37 | GET | `/client/hideout/qte/list` | 3 | 108 | menu | 0 | 625 | aes | yes | yes | 574 |
| 38 | GET | `/client/hideout/customization/offer/list` | 3 | 109 | menu | 0 | 6689 | aes |  | yes | 4,558 |
| 39 | GET | `/client/hideout/areas` | 3 | 110 | menu | 0 | 7425 | aes |  | yes | 7,553 |
| 40 | GET | `/client/hideout/production/recipes` | 3 | 111 | menu | 0 | 18017 | aes | yes | yes | 16,032 |
| 41 | POST | `/client/game/token/issue` | 1 | 112 | menu | 22 | 257 | aes |  | yes (src only) | n/a |
| 42 | POST | `/client/notifier/channel/create` | 3 | 118 | menu | 19-26 | 225-241 | aes |  | yes | 95 |
| 43 | POST | `/client/builds/list` | 3 | 123 | menu | 19-27 | 6833-8737 | aes |  | yes | 136 |
| 44 | POST | `/client/friends` | 3 | 124 | menu | 22-25 | 145 | aes |  | yes (src only) | n/a |
| 45 | GET | `/client/achievement/statistic` | 3 | 126 | menu | 0 | 1841 | aes | yes | yes | 50 |
| 46 | POST | `/client/quest/list` | 3 | 130 | menu | 40-46 | 58465-76161 | aes |  | yes | 522,351 |
| 47 | POST | `/client/weather` | 3 | 131 | menu | 20-23 | 241 | aes |  | yes | 164 |
| 48 | POST | `/client/ending/list` | 3 | 132 | menu | 18-26 | 2625 | aes |  | **no** | n/a |
| 49 | GET | `/client/achievement/list` | 3 | 133 | menu | 0 | 17169 | aes | yes | yes | 10,637 |
| 50 | GET | `/client/locations` | 3 | 134 | menu | 0 | 258673 | aes | yes | yes | 206,436 |
| 51 | POST | `/client/mail/dialog/list` | 3 | 136 | menu | 45-49 | 81 | aes |  | yes | 38 |
| 52 | POST | `/client/quest/chains` | 3 | 146 | menu | 18-20 | 2817 | aes |  | **no** | n/a |
| 53 | POST | `/client/tutor-game/check` | 3 | 148 | menu | 43-47 | 97 | aes |  | **no** | n/a |
| 54 | POST | `/client/tutor-game/profile` | 1 | 150 | menu | 20 | 6849 | aes |  | **no** | n/a |
| 55 | POST | `/client/match/group/current` | 4 | 152 | raid-in | 21-28 | 97 | aes |  | yes | 48 |
| 56 | POST | `/client/getMetricsConfig` | 2 | 154 | raid-in | 21-28 | 225 | aes |  | **no** | n/a |
| 57 | POST | `/client/raid/configuration` | 3 | 156 | raid-in | 504-512 | 81 | aes |  | yes | 36 |
| 58 | POST | `/client/match/local/start` | 1 | 158 | raid-in | 134 | 18769 | aes |  | yes | 172 |
| 59 | POST | `/client/game/bot/generate` | 1 | 160 | raid-in | 137 | 23697 | aes |  | yes | 3,061 |
| 60 | POST | `/client/game/keepalive` | 10 | 168 | in-raid | 18-27 | 112-113 | plain |  | yes | 67 |
| 61 | POST | `/client/quest/complete` | 1 | 202 | raid-out | 59 | 18161 | aes |  | **no** | n/a |
| 62 | POST | `/client/match/local/end` | 1 | 204 | raid-out | 14800 | 81 | aes |  | yes | 36 |
| 63 | POST | `/client/putMetrics` | 2 | 209 | raid-out | 1423-1469 | 81 | aes |  | yes | 36 |
| 64 | POST | `/client/repeatalbeQuests/activityPeriods` | 2 | 271 | menu-2 | 19-26 | 81 | aes |  | yes | 1,075 |
| 65 | POST | `/client/server/list` | 2 | 293 | menu-2 | 20-22 | 1025 | aes |  | yes | 67 |
| 66 | POST | `/client/survey` | 2 | 298 | menu-2 | 23-27 | 81 | aes |  | yes | 38 |
| 67 | POST | `/v2/client/shop/status` | 2 | 299 | menu-2 | 18-22 | 161 | aes |  | yes (src only) | n/a |
| 68 | POST | `/client/game/profile/items/moving` | 9 | 301 | trade | 93-380 | 1009-1313 | aes |  | yes | 373 |
| 69 | POST | `/client/builds/weapon/save` | 1 | 305 | trade | 817 | 81 | aes |  | yes | 54 |
| 70 | POST | `/client/checkVersion` | 1 | 310 | trade | 20 | 129 | aes |  | yes | 69 |
| 71 | POST | `/client/ragfair/find` | 6 | 311 | trade | 262-287 | 177-50913 | aes |  | yes | 596 |
| 72 | POST | `/client/items/prices/{id}` | 3 | 317 | trade | 20-28 | 9985-65633 | aes |  | yes | 59,038 |
| 73 | POST | `/client/trading/api/getTraderAssort/{id}` | 7 | 320 | trade | 21-27 | 1553-13937 | aes |  | yes | 22,343 |
| 74 | POST | `/client/insurance/items/list/cost` | 2 | 355 | trade | 96-264 | 129-609 | aes |  | yes | 66 |
| 75 | POST | `/client/builds/equipment/save` | 1 | 359 | trade | 1766 | 81 | aes |  | yes | 54 |
| 76 | POST | `/client/match/group/invite/cancel-all` | 3 | 369 | raid-2 | 18-23 | 81 | aes |  | **no** | n/a |
| 77 | POST | `/client/match/group/exit_from_menu` | 1 | 376 | raid-2 | 19 | 81 | aes |  | yes | 36 |
| 78 | POST | `/client/match/available` | 1 | 377 | raid-2 | 25 | 81 | aes |  | yes | 40 |
| 79 | POST | `/client/match/join` | 1 | 379 | raid-2 | 1214 | 289 | aes |  | **no** | n/a |
| 80 | POST | `/client/putLoadMetrics` | 3 | 394 | raid-2 | 102-110 | 81 | aes |  | yes (src only) | n/a |
| 81 | POST | `/client/libraries-extra` | 1 | 402 | raid-2 | 7980 | 96 | aes |  | **no** | n/a |
| 82 | POST | `/client/game/logout` | 1 | 506 | logout | 18 | 97 | aes |  | yes | 51 |

Line numbers below are into the tree at `mods/tarkov/tarkov.nim` md5
`1e2e3465165eceec1beab562412d902e` (2026-08-19 21:56). The file is being edited
by another session; if a line has moved, the proc name is the durable half of
the citation.

---

## (a) Sixteen routes the client asked for and this server does not serve

Every one of these is a 404 today. They are ordered by where they first appear,
because ordering is what separates a hard stop from a shrug.

| Route | Calls | Seqs | Phase | BSG resp | Blocking? |
|---|---|---|---|---|---|
| `POST /launcher/game/start` | 1 | 014 | boot | 84 (plaintext) | no — see below |
| `GET /client/quest/getMainQuestsList` | 3 | 073, 233, 422 | menu | 273 | probably |
| `GET /client/quest/getMainQuestNotesList` | 3 | 074, 226, 425 | menu | 18,817 | probably |
| `GET /client/variable/group` | 3 | 075, 225, 420 | menu | 5,601 | probably |
| `GET /client/dialogue` | 3 | 076, 227, 429 | menu | **2,573,985** | probably |
| `GET /client/tape/list` | 3 | 077, 235, 428 | menu | 2,977 | probably |
| `GET /client/subtitle-track/list` | 3 | 078, 234, 427 | menu | 3,905 | probably |
| `POST /client/ending/list` | 3 | 132, 256, 451 | menu | 2,625 | unknown |
| `POST /client/quest/chains` | 3 | 146, 267, 460 | menu | 2,817 | unknown |
| `POST /client/tutor-game/check` | 3 | 148, 257, 454 | menu | 97 | unknown |
| `POST /client/tutor-game/profile` | 1 | 150 | menu | 6,849 | unknown |
| `POST /client/getMetricsConfig` | 2 | 154, 390 | raid-in | 225 | no |
| `POST /client/quest/complete` | 1 | 202 | raid-out | 18,161 | **yes** |
| `POST /client/match/group/invite/cancel-all` | 3 | 369, 371, 504 | raid-2 | 81 | no |
| `POST /client/match/join` | 1 | 379 | raid-2 | 289 | **yes, for the online path** |
| `POST /client/libraries-extra` | 1 | 402 | raid-2 | 96 | no |

What the ordering says:

**The six `menu` GETs at seq 073–078 are one block.** They are issued together,
between `traderSettings` (071) and `handbook/templates` (082), on all three menu
loads (073–078, 225–235, 420–429). Six consecutive routes that the client asks
for on every single menu entry are not fire-and-forget. This server has *none*
of them, and this is the largest single hole in the table. `/client/dialogue` at
2.5 MB compressed is the second-largest response BSG sent in the whole session —
larger than `/client/locations`, larger than `/client/globals`, second only to
`/client/items`. Whatever it is, it is not a stub. Its name and its neighbours
(`tape/list`, `subtitle-track/list`, both also new and also unserved) suggest the
voiced-dialogue tables, which would make all three post-1.0 additions for the
story content — but that is a guess from adjacency and size, and nothing in this
repository confirms it. All six are `GET` with an empty body, so none of them
needs a request to be understood before it can be answered.

**`/client/quest/complete` (202) is the only route in the list that sits inside a
state transition.** It fires between the last in-raid keepalive (200) and
`match/local/end` (204), and the decoded request is exactly one field:

```json
{"questId": "6895bbb0e7dac53c7c08797b"}
```

BSG answered with 18,161 bytes, which is a profile-changes document, not an
acknowledgement. A 404 there loses the quest completion. This server *has* quest
completion logic (`emu/quests.nim`, `emu/questcond.nim`) reachable through the
`QuestComplete` arm of the item-event endpoint; it is not reachable through this
URL, and the client evidently uses this URL as well.

**`/client/match/join` (379) is how the second raid was entered.** The first raid
went `raid/configuration` (156) → `match/local/start` (158) → `game/bot/generate`
(160). The second went `raid/configuration` (368, 373) →
`match/group/exit_from_menu` (376) → `match/available` (377) → `match/join` (379),
with no `match/local/start` and no `bot/generate` at all. The decoded body:

```json
{"location": "Sandbox", "savage": false, "dt": "CURR",
 "servers": [{"ping": -1, "ip": "148.72.169.76", "port": "0"}, …], "keyId": ""}
```

The client ping-tests a server list and posts the results. So the client has two
raid entry paths and this server implements one. Whether the offline path is
enough is a decision, not a finding — but the online path is live and reachable
from the menu, and it is what the client chose the second time.

**`/launcher/game/start` is not this server's job as written.** The capture's
copy is BSG's launcher authenticating and being handed a `PHPSESSID`; this
project's launcher uses `/aowlspt/tarkov/launcher/*` instead, and the reasoning
is in the comment above `onLauncherPing` (tarkov.nim:1899–1903). Listed for
completeness, not as a gap.

The remaining seven (`ending/list`, `quest/chains`, `tutor-game/check`,
`tutor-game/profile`, `getMetricsConfig`, `match/group/invite/cancel-all`,
`libraries-extra`) are each called on every menu load or every raid entry, so
each is a guaranteed 404 per session. Whether any of them stalls the client
cannot be determined from a capture of a *working* server: nothing here shows
what the client does when one fails. Three got 81-, 96- or 97-byte answers from
BSG, which is the size of an empty envelope, so an `onNullData` registration
would very likely satisfy them. `ending/list` (2,625), `quest/chains` (2,817),
`tutor-game/profile` (6,849) and `getMetricsConfig` (225) got real content and
would need real answers. `tutor-game/check`'s request is
`{"skipTutorial": false}`, which is the client asking whether to run the tutorial
— and this capture shows it then ran one.

## (b) Forty-five registered routes the capture never shows

This server's own six are excluded from the judgement — `/aowlspt/tarkov/launcher/ping`,
`/profiles`, `/profile/create`, `/profile/select`, and `/aowlspt/tarkov/selfcheck`
are deliberately outside the client's protocol.

**Superseded by a post-1.0 spelling that the capture *does* show.** These are
pre-1.0 leftovers, and the post-1.0 name is already registered alongside:

| Registered | Line | Post-1.0 name the client actually used |
|---|---|---|
| `/client/friend/list` | 1994 | `/client/friends` (seq 124, 249, 442) |
| `/client/friend/request/list/inbox` | 1995 | absent from capture |
| `/client/friend/request/list/outbox` | 1996 | absent from capture |
| `/client/trading/customization/storage` | 1940 | `/client/customization/storage` (086, 094, 260, 457) |
| `/client/getMetrics` | 2005 | `/client/getMetricsConfig` (154, 390) — and *that* one is unserved |

**Contradicted by how post-1.0 delivers the data.**
`/client/location/getLocalloot` (1945) and `/client/location/getAirdropLoot`
(1946) never appear. The client entered a raid twice and asked for loot neither
time. BSG's `match/local/start` answer was 18,769 bytes against this server's
172 — that is where the loot went. The same reading covers
`/client/game/bot/limit` and `/client/game/bot/difficulty` (1991, 1993): absent,
while `game/bot/generate` returned 23,697 bytes from a request that named the
limits and difficulties itself (see (d)). Post-1.0 appears to have folded
per-map limits into the generate call and the loot into the start call. **This
is inference from sizes and from the request side, not from a decrypted body.**

**Registered on the strength of a claim this capture does not support.**
`/client/log`, `/client/bsgLogging`, `/client/releaseNotes` (2019–2021) carry the
comment "each was a 404 the client retried and then stalled on". None of the
three appears in this capture, and — given that the manifest omits no `/client/*`
route at all — that absence is now meaningful. The claim may still be true of a
different code path (a crash, an update, a first run); it is not corroborated by
a complete normal session, and it should be re-checked before it is treated as
established.

**Not exercised because this session did not do the thing.** Twenty-five routes,
each with an ordinary explanation: the inbox was empty
(`/client/mail/dialog/view|info|read|pin|unpin|remove|getAllAttachments`), the
player never listed a flea offer (`/client/ragfair/offerfees`,
`/client/ragfair/itemMarketPrice`, `/client/reports/ragfair/send`), never deleted
a build or saved a magazine preset (`/client/builds/delete`,
`/client/builds/magazine/save`), never renamed, re-rolled the scav or changed
voice (`/client/game/profile/nickname/change`, `/savage/regenerate`,
`/voice/change`, `/search`, `/client/profile/view`, `/client/profile/settings`),
never answered a survey (`/client/survey/view`, `/client/survey/opinion`), and
never opened a chat (`/client/chatServer/list`). Also unexercised:
`/client/account/customization`, `/client/analytics/event-disabled`,
`/client/notifier/getwebsocket`, `/client/match/exit`,
`/client/match/group/status`, `/client/trading/api/getTrader/{id}`,
`/client/trading/api/getUserAssortPrice/{id}`.

The last two are worth a note: the client bought from and sold to three traders
(assorts fetched for `54cb5777…`, `5ac3b934…`, `579dc571…` at seqs 320–363) and
never once called `getTrader/{id}` or `getUserAssortPrice/{id}`. `traderSettings`
(39,681 bytes, three calls) evidently carries everything per-trader the menu
needs. Those two routes are not wrong to serve, but nothing in a normal session
reaches them.

## (c) Where the answer is the wrong size

Sixty-six routes are served by both. Eleven could not be measured (the stale
binary). Of the fifty-five measured, **forty-three are within 3× of BSG in both
directions** — which, for a from-scratch reimplementation against a different
database, is the most reassuring number in this document. Twelve are not.

### This server answers far less than BSG

| Ratio | Route | BSG | Here | Reading |
|---|---|---|---|---|
| 0.009 | `POST /client/match/local/start` | 18,769 | 172 | **The big one.** BSG returns ~18 KB from a 134-byte request. This server returns a serverId, five `serverSettings` booleans and a notifier stub (`onMatchStart`, tarkov.nim:1348–1367). Combined with `getLocalloot` never being called, the most likely reading is that the raid's loot and spawn data are in this response. Not confirmed — the body is encrypted. |
| 0.012 | `POST /client/ragfair/find` | 50,913 | 596 | **Void as a measurement:** the probe stage's `config.json` sets `fleaMaxOffers` to 2. BSG returned ~3.4 KB per offer for a `limit: 15` page. Re-measure with a realistic offer count before acting on it. |
| 0.016 | `POST /client/builds/list` | 8,737 | 136 | Real, and the sequence proves it: the profile was created at seq 092 and `builds/list` at 123 already returned 6,833 bytes. **BSG ships default presets with a brand-new profile.** This server returns what the player has saved, which for a new profile is nothing. |
| 0.027 | `GET /client/achievement/statistic` | 1,841 | 50 | Same shape, same evidence: seq 126, on a profile four seconds old, 1,841 bytes. This server answers `{"elements":{}}` (`onAchievementStatistic`, tarkov.nim:1113). BSG evidently returns the full roster with zeroed counters, not an empty map. |
| 0.065 | `POST /client/server/list` | 1,025 | 67 | BSG lists real regional servers; this one lists `127.0.0.1:6969` (`onServerList`, tarkov.nim:975). Correct for a local server. Recorded, not a defect — but see `/client/match/join`, whose request echoes a pinged server list back, so the two are related if the online path is ever implemented. |
| 0.108 | `POST /client/insurance/items/list/cost` | 609 | 66 | **Void as a measurement:** the probe sent an empty `items` array. The real request (seq 355) is `{"traders":["54cb5777…"],"items":["6a86309979a58e459510165d"]}`; the handler reads both fields correctly (see (d)), so the size gap is the probe's fault, not the server's. |
| 0.129 | `POST /client/game/bot/generate` | 23,697 | 3,061 | **Void as a measurement.** The decoded request at seq 160 asks for `Limit` 10 + 22 + 5 + 2 + … across several roles — dozens of bots. The probe asked for three. The two numbers are not comparable and no conclusion should be drawn from them. |
| 0.141 | `POST /client/game/profile/list` | 14,241 | 2,012 | BSG's profile document for a fresh character is 7× this server's. Worth pulling on: the decoded `match/local/end` body (seq 204) lists the client's own idea of a profile — 37 top-level members including `Prestige`, `Variables`, `SeasonalPerks`, `SeasonalPerkEffectParameters`, `SeasonalRewards`, `moneyTransferLimitData`, `battlePassDocumentLimitData`, `CompletableItems`, `QuestNotes`, `ReadQuestData`, `Ending`, `UnlockedLocations`, `BattlePassUniversalDocumentBalance`, `BattlePassProgress`. That is a checklist for `emu/profile.nim`, and it is ground truth rather than inference. |
| 0.284 | `POST /client/game/profile/items/moving` | 1,009–1,313 | 373 | The item-event response is the `profileChanges` document. 3–4× is not alarming for a different profile, but it is the endpoint where a missing sub-document is most likely to be a silent desync. |

`/client/metadata` also came out low (414 against 128), but that is an artifact:
the probe stage has no metadata blob for the version it sent, so the handler
answered its documented error envelope
(`aowlspt-backend.log`: *"no blob for version '' — install
mods/tarkov/data/metadata/.json"*). Not a gap.

### This server answers far more than BSG

| Ratio | Route | BSG | Here | Reading |
|---|---|---|---|---|
| 6.9× | `POST /client/quest/list` | 76,161 | 522,351 | **A real shape bug.** `onQuestList` (tarkov.nim:943) is two lines: `envelope(raw(quests()))`. It ignores the request body and returns the entire quest *template* table. The client sends `{"completed": true}` — it is asking a question this server never reads. BSG's answers varied 58,465–76,161 across the three menu loads, so its reply depends on the profile; this server's does not, and is ~7× larger on every menu entry. |
| 13.3× | `POST /client/repeatalbeQuests/activityPeriods` | 81 | 1,075 | BSG answered 81 bytes — an empty envelope — on both calls (seqs 271, 462). This server generates three activity periods (`onActivityPeriods`, tarkov.nim:1013). Answering *more* than the real server is not automatically wrong, but the client is being told about dailies BSG did not mention. |

`/client/trading/api/getTraderAssort/{id}` (13,937 against 22,343) and
`/client/items/prices/{id}` (65,633 against 59,038) both sit inside 2×, so the
assort and price tables are the right order of magnitude.

### One shape difference that is readable rather than inferred

`/client/game/keepalive` is one of the four plaintext routes, so both sides can
be compared byte for byte. BSG (seq 168, inflated):

```json
{"data":{"msg":"OK","utc_time":1787178131.638247},"err":null,"errmsg":null,
 "status":null,"errLog":{},"error":{"code":null,"message":null}}
```

This server (`onKeepAlive`, tarkov.nim:230–234): `{"err":0,"errmsg":null,
"data":{"msg":"OK","utc_time":1700172906}}`.

Two differences, both real:

1. **The envelope.** Post-1.0 BSG wraps in `{data,err,errmsg,status,errLog,error}`
   with `err: null`; this server uses the pre-1.0 `{err:0,errmsg,data}`. This
   server already knows the new envelope — `onMetadata` emits exactly it — but
   `envelope()` in `aowl/src/aowlspt/server.nim:653` produces the old one, so
   every other route uses the old one. **The client accepted it: it booted to
   the menu.** So this is a difference, not a defect, and it is recorded because
   the next unexplained parse failure is likely to be here.
2. **`utc_time` is fractional.** BSG sends `1787178131.638247`; this server sends
   an integer. `nowSeconds()` has no sub-second component to give.

`/client/libraries` is the one place a plaintext capture was already used
correctly: BSG's response is exactly `{}` (2 bytes), and `onLibraries`
(tarkov.nim:999–1006) returns exactly `{}` with a comment citing the capture.

## (d) The request side, field by field

This section used to be guesswork. It is not any more: 52 request bodies decoded
to non-empty JSON, so for every one of them the client's actual field names can
be put next to what the handler reads.

**How `field` works, because two of the findings below turn on it.**
`field(body, path)` in `aowl/src/aowlspt/json.nim:464–485` is a *dotted path from
the document root*. It does not search recursively. A handler asking for
`"profile"` will not find `results.profile`.

### The mismatches

| # | Route / action | Client sends | Handler reads | Consequence |
|---|---|---|---|---|
| 1 | `POST /client/match/local/end` (seq 204) | `results.profile`, `results.result` | `field(body, "profile")`, `field(body, "exit")` — `onMatchEnd`, tarkov.nim:1378–1379 | **Every raid changes nothing.** Neither field is found, so the handler takes its own `warn "match/end carried no profile; the raid changed nothing"` branch and returns `envelopeNull()`. The 14,800-byte profile the client just handed back is discarded. This is the single most consequential finding in this document. |
| 2 | item event `Split` (seq 318, 2×) | `splitItem`, `newItem`, `container`, `count` | `action.field("item")` for the source — `doSplit`, `emu/inventory.nim:235` | **Every split fails.** `item` is absent, so `indexOf` gets `""`, no item matches, and the action records `split: no such item `. `newItem` and `container` on the next lines are read correctly, which is what makes this look right at a glance. |
| 3 | item event `ReadEncyclopedia` (seq 341) | `ids` (an array) | `action.field("item")` — `emu/inventory.nim:632–634` | The encyclopedia entry is not marked read. Cosmetic, but exact. |
| 4 | `POST /client/raid/configuration` (156, 368, 373) | no `profileId` member at all | `field(body, "profileId")` — `raidConfiguration`, `emu/raid.nim:276` | The echoed `profileId` is always `""`. The client did not miss it, so this is dead weight rather than a fault — but the field is not in the request and the code believes it is. |
| 5 | `POST /client/game/profile/create` (092) | `side`, `nickname`, `headId`, `voiceId`, `seasonalPerkIds` | `nickname` and `side` only — `onProfileCreate`, tarkov.nim:389–390, then `createProfile(nickname, sideName, …)` | The character's chosen head (`5cde96047d6c8b20b577f016`) and voice (`5fc615110b735e7b024c76ea`) are dropped. Every profile gets whatever `emu/profile.nim` defaults to. |

### Read, and read correctly

Verified field-for-field against the decoded bodies:

| Route / action | Client sends | Handler |
|---|---|---|
| `items/moving` `Move` (seqs 301, 303, 318; 16×) | `item`, `to.id`, `to.container`, `to.location` | `doMove`, `emu/inventory.nim:198–212` |
| `items/moving` `Transfer` (seq 318, 2×) | `item`, `with`, `count` | `doTransfer`, `emu/inventory.nim:407–409` |
| `items/moving` `Swap` (seq 301) | `item`, `to`, `item2`, `to2` | `doSwap`, `emu/inventory.nim:371–397` |
| `items/moving` `Examine` (seq 318) | `item` | `emu/inventory.nim:632–634` |
| `items/moving` `TradingConfirm` sell (326) | `type: "sell_to_trader"`, `tid`, `items[].id`, `items[].count`, `price` | `applyTrading` → `sellToTrader`, `emu/trading.nim:495, 435–450` |
| `items/moving` `TradingConfirm` buy (331) | `type: "buy_from_trader"`, `tid`, `item_id`, `count`, `scheme_id`, `scheme_items[].id/.count` | `buyFromTrader`, `emu/trading.nim:343–392` — **every field matches, including `scheme_items`** |
| `items/moving` `RagFairBuyOffer` (seq 353) | `offers[].id`, `offers[].count`, `offers[].items` | `buyOffer`, `emu/market.nim:1164–1170` |
| `items/moving` `Insure` (seq 357) | `tid`, `items[]` | `doInsure`, `emu/personal.nim:90, 106` |
| `items/moving` `RestoreHealth` (seq 470) | `trader`, `items`, `difference.BodyParts` | `doTreatment`, `emu/health.nim:405–417` — accepts `tid`/`trader`/`Trader` and `difference`/`Difference` |
| `builds/weapon/save` (305), `builds/equipment/save` (359) | `Id`, `Name`, `Root`, `Items` (capitalised) | `saveBuild`, `emu/builds.nim:102–120` — reads both capitalisations |
| `game/bot/generate` (160) | `conditions[].Role/.Limit/.Difficulty` | `emu/bots.nim:624–633` |
| `game/profile/select` (098) | `uid` | `onProfileSelect`, tarkov.nim:353 |
| `game/profile/nickname/validate` (090) | `nickname` | `onNicknameValidate`, tarkov.nim:420 |
| `insurance/items/list/cost` (355) | `traders[]`, `items[]` | `onInsuranceCost`, tarkov.nim:1798 |
| `ragfair/find` (311) | 23 members, `page`/`limit`/`sortType`/… | `searchResult`, `emu/market.nim` |

**All ten item-event actions the client used are handled**: `Move`, `Split`,
`Transfer`, `Swap`, `Examine`, `ReadEncyclopedia`, `TradingConfirm`,
`RagFairBuyOffer`, `Insure`, `RestoreHealth`. `TradingConfirm` and
`ReadEncyclopedia` are dispatched by `elif kind == …` (tarkov.nim:848,
`emu/inventory.nim:632`) rather than a `case` arm, so a grep for `of "…"` misses
them; they are there.

### One documented unknown, now answered

`raidClock` in `emu/raid.nim:323–345` refuses to establish a raid's in-game hour
and says why, ending with:

> *(A raid has never been run against BSG's client, so which of the three it
> actually posts is unknown. If it turns out to post `timeVariant` alone, this
> closes nothing and the refusal is the honest answer.)*

It is now known. Seq 156:

```json
"timeAndWeatherSettings": {"isRandomTime": false, "isRandomWeather": false,
  "cloudinessType": "Clear", "rainType": "NoRain", "windType": "Light",
  "fogType": "NoFog", "timeFlowType": "x0", "hourOfDay": 7}
```

The client posts `hourOfDay`, `isRandomTime` and `timeFlowType`, in exactly the
camelCase spellings `raidClock` reads, nested exactly where it looks. **The
refusal can be lifted.** Note `timeFlowType: "x0"` — a frozen clock — which
`timeFlow` parses to 0.0, so the span collapses and the raid is a single hour.
That is the tutorial's doing; a normal raid would post a real flow rate.

### Bodies that are ignored, and whether that is right

| Route | reqlen | Handler | Ignored? | Right? |
|---|---|---|---|---|
| `/client/libraries` | 29,925 | `onLibraries` :999 | yes | **Yes** — BSG replies `{}`; the manifest is write-only. |
| `/client/putHWMetrics` | 6,214 | `onNullData` :1031 | yes | Yes — `{Output, Errors}`, a hardware survey. BSG answered 81 bytes. |
| `/client/putMetrics` | 1,423–1,469 | `onNullData` :1031 | yes | Yes — `{sid, Settings, SharedSettings, HardwareDescription, Location, Metrics, ClientEvents, SpikeSamples, mode}`. Telemetry. BSG answered 81 bytes. |
| `/client/putLoadMetrics` | 102–110 | `onNullData` :1031 | yes | Yes — `{onlineAffiliation, metricsType, metricsValue, locationName, isPMC}`. |
| `/client/game/version/validate` | 117 | `onGameVersion` :224 | yes | Yes, deliberately, with the reasoning in the doc comment. The body is `{"version":{"major":"1.1.0.1.46777","minor":"live","game":"live","backend":"6","taxonomy":"341"},"develop":true}` — nested, so a future check must read `version.major`. |
| `/client/game/mode` | 47 | `onGameMode` :1148 | yes | Probably — the body is `{"sessionMode": null}` and this server has one mode. |
| `/client/quest/list` | 40–46 | `onQuestList` :943 | yes | **No** — `{"completed": true}` is a filter, and see (c). |
| `/client/mail/dialog/list` | 45–49 | `onMailList` :1636 | yes | **No** — `{"limit": 30, "offset": 0}` is paging. Harmless while the inbox is small; wrong once it is not. |
| `/client/match/local/start` | 134 | `onMatchStart` :1348 | yes | **No** — the client says `{"serverId":null,"location":"Sandbox_start","timeVariant":"CURR","mode":"TUTORIAL","playerSide":"Pmc","transitionType":0,"transition":null}`, and not one `field(body, …)` appears in the proc. Which map, which side and whether this is the tutorial are all discarded. |
| `/client/raid/configuration` | 504–512 | `onRaidConfiguration` :1330 | partly | The 14-member body is read for six values; `onlinePveRaidStates` (24 maps), `botSettings`, `wavesSettings`, `timings`, `playersSpawnPlace`, `metabolismDisabled`, `transitionType` and `CanShowGroupPreview` are dropped. `botSettings.botAmount` and `wavesSettings.botDifficulty` are exactly what `onMatchStart` hardcodes as `"AsOnline"` two hundred lines later. |

## (e) The 304s: this server has no conditional-GET support at all

`If-None-Match` appears on 36 requests in `reqs.json`, and **all 36 were answered
304** — a perfect correlation, so these are real conditional GETs and not
opportunistic headers. They cover 17 routes, every large static `GET`:

`/client/items` (3), `/client/customization` (3), `/client/globals`,
`/client/locations`, `/client/handbook/templates`, `/client/prestige/list`,
`/client/dialogue`, `/client/variable/group`, `/client/tape/list`,
`/client/subtitle-track/list`, `/client/quest/getMainQuestsList`,
`/client/quest/getMainQuestNotesList`, `/client/achievement/list`,
`/client/achievement/statistic`, `/client/hideout/settings`,
`/client/hideout/qte/list`, `/client/hideout/production/recipes` (2 each).

The tags are **weak and numeric**: `W/"1986898181"`, `W/"3520757149"`,
`W/"3864865206"`, `W/"1993727101"`. Every one observed is a decimal unsigned
32-bit integer, which is the shape a CRC32 of the response body takes. That is a
guess about how BSG computes them and it does not matter: the server chooses its
own tags, and any stable function of the body will do.

The pattern is unmistakable in the sequence: seq 045 fetched `/client/items` in
full (1,036,593 bytes) with no `If-None-Match`; seqs 069, 224 and 426 sent
`If-None-Match: W/"1986898181"` and got 304 with a zero-length body.

**Nothing in this repository does anything with them.** `grep -rni
'etag|if-none-match|304'` over `backend/`, `aowl/` and `mods/tarkov/` returns
nothing outside generated `nimcache` C. The response builder at
`backend/aowlbackend.nim:582–588` emits exactly four headers — `Content-Type`,
`Content-Length`, `Connection` and nothing else. There is no ETag to send and no
`If-None-Match` to read.

The consequence is measurable rather than theoretical. In this session the client
re-entered the menu twice. Against BSG that cost three 304s for `/client/items`.
Against this server it would cost **three further 1.27 MB transfers**, and the
same again for `/client/customization` (39 KB), `/client/globals` (107 KB),
`/client/locations` (206 KB) and `/client/handbook/templates` (75 KB). Summing
the seventeen routes over their non-first calls, the capture shows BSG shipping
~0 bytes where this server would ship roughly **4.4 MB per extra menu load**.

This is a latency and bandwidth issue, not a correctness one — the client handles
a 200 with a full body fine, because that is what it gets today. It is recorded
because `docs/PERF-SERVER.md` measures how fast the tables are *built*, and this
is the first evidence that the client would rather they were not sent at all.
It is also cheap: the routes are all static per database, so one CRC32 computed
when a table is first built covers every call.

## What was not checked

- **No response body was decrypted.** Every shape claim about an
  `X-Encryption: aes` route is derived from its length.
- **Eleven routes were not measured** because the staged binary predates them;
  their registration is verified from source and from nothing else.
- **The client was not run against this server for this document.** The 404s in
  (a) are 404s by construction — the route is not registered — but what the
  client *does* with each one is unknown. "Blocking?" in that table is a
  judgement from position in the sequence, not an observation.
- **Four size comparisons are void** and are labelled as such in (c):
  `ragfair/find`, `insurance/items/list/cost`, `game/bot/generate` and
  `metadata`. They are left in rather than deleted so nobody measures them again
  and thinks they have found something.
- **The raid was the tutorial.** Everything this capture shows about raid entry,
  bot generation, raid results and quest completion is the tutorial's version of
  it. A normal PMC raid may differ, and this capture cannot say how.
- **The three findings in (d) that are bugs were not fixed.** This task was
  analysis only. `match/local/end` reading `profile` instead of `results.profile`
  is the one to fix first; it is a one-line change and it is currently throwing
  away every raid.
