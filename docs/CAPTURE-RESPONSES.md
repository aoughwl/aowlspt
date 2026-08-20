# Capture responses: what BSG's server actually answered, against what this one does

`mods/tarkov/data/capture/raid1/` is one complete session against BSG's live
post-1.0 servers (client build 1.1.0.1.46777): launcher, a profile created from
nothing, the menu, trading and the flea, a tutorial raid, a second raid entry,
and a logout.

[CAPTURE-GAP.md](CAPTURE-GAP.md) measured that capture when the response bodies
were still ciphertext, so every claim in it about a *response* was derived from
its length. **The bodies are now decrypted.** 170 of them are in
`mods/tarkov/data/capture/raid1/responses/<seq>.json` and 15 more — the bulk
tables, up to 18 MB — in `responses/large/<seq>.json`, kept out of git for size.
This document is the shape-level comparison that could not be written before:
for every route in the capture, what BSG's `data` contained and what
`mods/tarkov/tarkov.nim` emits instead.

Where this document and CAPTURE-GAP.md disagree about a response, this one
wins; where they disagree about a *route table*, CAPTURE-GAP.md is simply older
(`tarkov.nim` registers 120 routes now against the 111 it counted).

## What was verified and what was not

**Verified:** every BSG shape below was read out of the decoded JSON at the
seq cited. Every emulator shape was read out of the source at the `file:line`
cited.

**Not verified:** nothing was run and nothing was rebuilt. `mods/tarkov/tarkov.nim`
was last edited at 22:47; the newest built `mods/tarkov/bin/tarkov.dll` is 22:19
and `installer/build/emustage`'s is 15:49, so **no binary in the tree contains
the source this document describes**, and another session owns the build lane
(a concurrent nimony build corrupts the shared `nimcache` — see
[DEBUGGING.md](DEBUGGING.md)). Every emulator claim here is therefore *what the
source says it will emit*, not a measured response.

**Partly verified:** the routes whose handler is a raw pass-through of a
database table — `/client/items`, `/client/globals`, `/client/locale/en`,
`/client/customization`, `/client/settings`, `/client/handbook/templates`,
`/client/locations`, `/client/quest/list`. Their shape is whatever
`build/db/db.json` holds, and that file is present (41 MB, 2026-08-19 00:47), so
the ones that mattered were opened and checked against the capture — see §7.
The *content* of the multi-megabyte tables was not diffed and belongs to
[IMPORTDB.md](IMPORTDB.md).

**Not in the capture at all:** a non-tutorial PMC raid, a death, a scav run,
a group, a flea listing being *posted*, insurance actually paying out, and any
`/v2/client/game/profiles/` call made by an account that already has a
character. Everything said about those states below is marked as inferred.

## 1. The envelope

There are **three** envelopes in the capture, not one, and which one a route
uses is a property of the route.

### Envelope A — 167 of 185 responses

```json
{"err":0,"errmsg":null,"data":<payload>}
```

`err` is the integer `0`. `errmsg` is `null`. Key **order varies**: 78 responses
serialise `err, errmsg, data` and 90 serialise `err, data, errmsg` — for example
seq 028 `/client/game/version/validate` is the first order and seq 024
`/client/game/mode` is the second. Both come back from the same session
minutes apart, so order carries no meaning and nothing should be built on it.

The one non-zero `err` in the whole session is seq 402
`/client/libraries-extra`, which BSG itself refused:

```json
{"err":201,"errmsg":"201 - Client not authorized","data":null}
```

`aowl/src/aowlspt/server.nim:653` emits exactly Envelope A, in the
`err, errmsg, data` order, and `failure` at `server.nim:669` emits the same
shape with a non-zero `err` and a string `errmsg`. **Envelope A is correct and
needs no change.**

### Envelope B — 15 responses, five routes

```json
{"data":<payload>,"err":null,"errmsg":null,"status":null,
 "errLog":{},"error":{"code":null,"message":null}}
```

Note `err` is **`null`**, not `0`, and there are three keys Envelope A does not
have. The five routes are exactly:

| Route | seq |
|---|---|
| `/client/metadata` | 019 |
| `/client/game/start` | 026 |
| `/v2/client/game/profiles/` | 048 |
| `/client/game/keepalive` | 168, 172, 176, 179, 184, 191, 200, 350, 386, 404 |
| `/v2/client/shop/status` | 299, 501 |

That is not a random set. `/client/metadata` and `/client/game/keepalive` are
the two routes `tools/bsgwire.py` already documents as skipping the wire
envelope, and `/v2/...` is a version prefix. **These five are served by a
different backend service from the other 77**, and Envelope B is that service's
`JsonResponse<T>`.

`mods/tarkov/tarkov.nim` sends Envelope A on all five: `onGameStart`
(tarkov.nim:222), `onKeepAlive` (tarkov.nim:234), `onProfilesV2`
(tarkov.nim:338), and `onEmptyObject` for `/v2/client/shop/status`
(tarkov.nim:1011, registered tarkov.nim:2117). `onMetadata` (tarkov.nim:187)
sends neither — it answers the shuffled blob raw, which the route's own comment
at tarkov.nim:160 says is deliberate.

**How much this matters is the one thing here that is inferred rather than
measured.** Envelope A is a strict subset of Envelope B by key, and a
Newtonsoft-style deserialiser leaves absent fields at their defaults, so the
likeliest outcome is that Envelope A deserialises into Envelope B's type
without complaint. Two things could make it not so, and neither can be settled
from the capture:

1. `err` is `null` in every Envelope B response and `0` in every Envelope A
   one. If the B type declares `err` as anything but a nullable int — a string,
   an object, an `Error` — then `0` is a hard deserialisation failure on
   `/client/game/keepalive`, i.e. on every keepalive for the whole session.
2. If any client code reads `response.error.code` to decide success, an absent
   `error` object is a null-ref at the read, not a tolerated default.

Both are cheap to eliminate: emit Envelope B on those five routes and the
question stops existing. That is recommendation 1 below.

### Envelope C — one response

`/client/libraries` (seq 020) is the literal two-byte body `{}`. No envelope at
all. `onLibraries` (tarkov.nim:1007) already returns `"{}"`, and the comment
above it says it was checked against this capture. Correct.

### What `data` is, when it is not an object

129 of the payloads are objects, but the rest are not, and several handlers
guess wrong about which. From the capture:

| `data` | seqs |
|---|---|
| `null` | 028, 038, 156, 204, 209, 298, 305, 359, 368, 373, 376, 394, 399, 402, 465, 500, 502 |
| `[]` | 083, 136, 263, 271, 458 |
| `true` (bare bool) | 369, 371, 377, 504 |
| bare string | 088 (`"Savant_"`) |
| array of objects | 26 responses, incl. 071 `traderSettings`, 293 `server/list` |

## 2. `/v2/client/game/profiles/` — the character-selection response

This route has cost two sessions. Here is the whole of what BSG answered, seq
048, verbatim:

```json
{
 "data": {
  "pve": {
   "status": "locked"
  },
  "pvp-season": {
   "SeasonalInfo": {
    "achievements": { "completedAchievementIds": [] },
    "battlePassRewards": [
     { "battlePassId": "6a27da69f3610ccfe5e71ab5", "completed": 0, "total": 53 }
    ],
    "kdPmc": 0,
    "raidsSurvivedPmc": 0,
    "seasonEndAt": "2026-12-07T09:00:39+00:00",
    "seasonNameLocalizationKey": "69e232a764dfe95549003f0f",
    "selectedSeasonalPerkIds": [
     "69c41a19cd28c936320a7523", "69c41a86383fc5c9ad03f3d5",
     "69c41adf883efd5e3b09ccae", "69ce5d9296f3b267fa08f137",
     "69ce5e104e0a1c7ca20781c9", "69ce5eb3e4b79de94a0d78c8"
    ],
    "storyChapters": { "completed": 0, "total": 10 }
   },
   "status": "empty"
  },
  "regular": {
   "SeasonalInfo": null,
   "status": "empty"
  }
 },
 "err": null,
 "errmsg": null,
 "status": null,
 "errLog": {},
 "error": { "code": null, "message": null }
}
```

**Read the state this was captured in before reading anything else into it.**
Seq 048 is the boot call, and it precedes profile creation (seq 092) — seq 083
`/client/game/profile/list` returns `[]` at that point. So this is the
**account-with-no-character** response, and it is the only
`/v2/client/game/profiles/` call in the session. The capture therefore proves
what an *empty* slot looks like and proves nothing at all about a populated
one.

### What it establishes, as fact

1. **All three game-mode keys are always present.** `pve`, `pvp-season`,
   `regular` — the literal `EnumConverter` wire strings, lowercase, with a
   hyphen in `pvp-season`. Not ints, not `"Regular"`.
2. **A slot value can be as small as one key.** `pve` is `{"status":"locked"}`
   and nothing else. So the client tolerates a slot object with no `uid`, no
   `side`, no `nickname` — every other field is optional.
3. **`status` is a wire string.** Observed values: `"locked"` (mode not owned)
   and `"empty"` (mode owned, no character yet).
4. **`SeasonalInfo` is PascalCase while `status` is lowercase**, in the same
   object. The casing is per-field and is not negotiable.
5. **`SeasonalInfo` may be `null`** (`regular`) or a populated object
   (`pvp-season`), and it is *absent entirely* from `pve`. All three are
   accepted by the client in the same response.
6. **This route uses Envelope B**, `err: null` and the three extra keys.

### What the emulator sends

`onProfilesV2` at tarkov.nim:313–338 builds `var modes = obj()`, walks
`allProfileIds()`, and on the first profile that loads does
`put(modes, "regular", characterSlot(p))` and `break` (tarkov.nim:332–333),
then `envelope(modes)` at tarkov.nim:338.

`characterSlot` at tarkov.nim:271–311 emits sixteen keys: `uid`, `status`
(`"available"`, tarkov.nim:287), `side` (an **int**, via `sideToInt` at
tarkov.nim:263/288), `nickname`, `lowerNickname`, `nicknamePref`, `level`,
`prestigeLevel`, `memberCategory`, `accountType`, `aid`, `gameVersion`,
`PlayerVisualRepresentation` (null), `SeasonalInfo` (null),
`unlockedProductionRecipe`, `unlockedRules`, `unlockedTraderDialogues`,
`unlockedTraders`.

### The differences

| | BSG (048) | emulator | |
|---|---|---|---|
| `pve` key | present, `{"status":"locked"}` | **absent** | missing |
| `pvp-season` key | present | **absent** | missing |
| `regular` key | present, always | present **only if a profile loads** | conditional |
| `data` with no profile | the three-key object above | `{}` (loop never runs, tarkov.nim:323–333) | missing |
| `status` | `"locked"` / `"empty"` | `"available"` | unverifiable — no populated slot in capture |
| `side` | absent | int (tarkov.nim:287) | extra, unverified |
| the other 14 keys | absent | present | extra, unverified |
| envelope | B | A (tarkov.nim:338) | wrong envelope |

### Exactly what to change

1. **Always emit all three keys.** Build `modes` with `pve`, `pvp-season` and
   `regular` unconditionally, before the profile loop. This is the change with
   evidence behind it: BSG never omits a mode, and a missing key in a
   `Dictionary<EGameMode, …>` is a slot the character screen has no entry for.
2. **When there is no profile, the value is `{"status":"empty"}`, not an
   omitted key and not `{}` at the top level.** The empty-account response is
   in the capture; match it. For a mode this server does not offer, use
   `{"status":"locked"}` as `pve` does at seq 048 — `pve` and `pvp-season`
   should both be `locked` here, since this server has neither.
3. **Send Envelope B** (see §1).
4. **Leave `status: "available"` as it is, and treat every other key in
   `characterSlot` as unverified.** The capture contains no populated slot, so
   `"available"`, the int `side`, and the fourteen extra fields are all still
   guesses from the decompiled metadata — the same guesses that produced two
   failed sessions. They are *plausible*: the shape of `pve` proves the client
   accepts a slot object with almost nothing in it, which means the extra keys
   are unlikely to be *required*; but a key whose type the deserialiser rejects
   still aborts the whole dictionary, and `side` as an int is the field most
   likely to be that key, since every other side-valued field in the capture is
   a string (`"Usec"`, `"Savage"` — see §4). **If the slot still fails to bind
   after fixes 1–3, drop `characterSlot` to `{"uid": …, "status": "available"}`
   and add fields back one at a time.** That minimal object is the one the
   capture supports.

## 3. `/client/profile/status` — the pending-raid contract

Eleven calls, two distinct bodies. The 193-byte one (seq 100, 122, 270, 277,
292, 468, 476, 491) and the 305-byte one (seq 381, 384, 388). The difference
between them *is* the contract, and it is entirely inside the per-profile
object.

### The idle body (seq 100, and identical at 122/270/277/292/468/476/491)

```json
{"maxPveCountExceeded": false,
 "profiles": [
  {"profileid":"6a862c118ad6a5aa18060240","profileToken":null,"status":"Free",
   "sid":"","ip":"","port":0},
  {"profileid":"6a862c118ad6a5aa18060241","profileToken":null,"status":"Free",
   "sid":"","ip":"","port":0}]}
```

Two entries — the PMC (`…240`) and the scav (`…241`) — six keys each, in the
order `profileid, profileToken, status, sid, ip, port`.

### The pending body (seq 381, and identical at 384/388)

The scav entry is **byte-for-byte the idle entry**. Only the PMC entry changes,
and it grows from six keys to eleven:

```json
{"profileid":"6a862c118ad6a5aa18060240",
 "profileToken":"72f15b4c872c64710e9d7af58d1b1f3e",
 "status":"MatchWait",
 "ip":"","port":0,"sid":"",
 "version":"live",
 "location":"Sandbox",
 "raidMode":"Online",
 "mode":"deathmatch",
 "shortId":null,
 "additional_info":null}
```

Field by field, idle → pending:

| key | idle | pending | note |
|---|---|---|---|
| `profileid` | id | id | unchanged |
| `profileToken` | `null` | 32-hex string | **appears** — this is the raid token |
| `status` | `"Free"` | `"MatchWait"` | wire string, not an int |
| `sid` | `""` | `""` | unchanged, but moves after `port` |
| `ip` | `""` | `""` | unchanged; still empty even with a raid pending |
| `port` | `0` | `0` | unchanged; still zero even with a raid pending |
| `version` | absent | `"live"` | **added** |
| `location` | absent | `"Sandbox"` | **added** — the map id |
| `raidMode` | absent | `"Online"` | **added** — wire string |
| `mode` | absent | `"deathmatch"` | **added** — wire string |
| `shortId` | absent | `null` | **added, null** |
| `additional_info` | absent | `null` | **added, null**; snake_case, alone among these |

Key order also changes (`status, sid, ip, port` idle vs `status, ip, port, sid`
pending), which by §1 is not meaningful.

Two things worth naming because they are counter-intuitive:

- **`ip` stays `""` and `port` stays `0` even while a raid is pending.** The
  client does not learn its game server from this route. Anything that assumed
  a pending status implies an address is wrong.
- **The pending state was reached through `/client/match/join` (seq 379), not
  `/client/match/local/start`.** Seq 379 answers with the *same* profile
  object — the eleven-key pending PMC entry — plus one extra top-level key,
  `"estimate": 210`, and **with only the PMC in the array**, no scav entry. So
  `match/join` both sets the state and returns it; `profile/status` afterwards
  simply reports what `match/join` decided.
- The token `72f15b4c872c64710e9d7af58d1b1f3e` in seq 381 is the same string
  seq 379 returned. **The server mints it at `match/join` and echoes it until
  the raid ends.**

### What the emulator sends

`onProfileStatus` at tarkov.nim:1157–1187. It builds a fixed six-key object per
profile with `status: "Free"` hardcoded (tarkov.nim:1168 and tarkov.nim:1178),
wraps it as `{"maxPveCountExceeded": false, "profiles": [...]}` (tarkov.nim:1184–1186),
and envelopes it at tarkov.nim:1187.

**The idle body is exactly right** — same six keys, same types, same
`maxPveCountExceeded: false`, PMC then scav. Nothing to change there.

**There is no pending state at all.** The emulator has no way to report
`MatchWait`, and `/client/match/join` is not registered (§5), so the pending
half of the contract does not exist. What it must report:

- **Idle:** what it already sends. `status: "Free"`, six keys, both profiles.
- **Pending, PMC entry only:** `status: "MatchWait"`, `profileToken` set to the
  same string `/client/match/join` returned, plus `version: "live"`,
  `location` = the requested map id, `raidMode: "Online"`, `mode` = the match
  mode, `shortId: null`, `additional_info: null`. `ip: ""`, `port: 0`, `sid: ""`
  stay as they are.
- **Pending, scav entry:** unchanged from idle. Do not touch it.
- **`/client/match/join` itself** returns `{"maxPveCountExceeded": false,
  "profiles": [<the one pending PMC entry>], "estimate": <int seconds>}`.

**Inferred, not verified:** what `status` becomes once the raid actually
starts. `MatchWait` is the last thing seq 388 reports, and by the time
`profile/status` is called again at seq 468 the client is back in the menu and
the answer is the plain six-key `Free` entry again. **Nothing in the capture
sits between those two**, so there is no evidence for an `"InRaid"` value, nor
for what clears the state — no `match/local/end` follows the seq 379 join.
`Free` on the next `profile/status` after a raid ends is the only part of the
return path the capture shows.

## 4. Enum-as-string: every enum-valued field in the capture

Post-1.0 puts a custom `EnumConverter` on a lot of enums, so a field a pre-1.0
emulator sends as an int comes back from BSG as a wire string. This is the
whole list, swept out of the decoded responses (the sweep excluded
`/client/items`, `/client/dialogue` and `/client/locale/en`, whose template
noise drowns everything else; item template enums are covered by
[IMPORTDB.md](IMPORTDB.md)).

**Strings on the wire.** Values are the literal bytes BSG sent, and the seq
column is where to look.

| Field | Wire values seen | Seq |
|---|---|---|
| *(the three `/v2/.../profiles` keys)* | `pve` `pvp-season` `regular` | 048 |
| `status` (character slot) | `locked` `empty` | 048 |
| `status` (profile/status) | `Free` `MatchWait` | 100, 381 |
| `status` (nickname/validate, profile/select, logout) | `ok` | 090, 098, 506 |
| `raidMode` | `Online` | 379, 381, 384, 388 |
| `mode` (match) | `deathmatch` | 379, 381 |
| `mode` (seasonal perk) | `not_require` | 044, 079, 236, 430 |
| `version` (profile/status) | `live` | 379, 381 |
| `gameMode` | `regular` `pve` | 024, 081, 252, 446 |
| `sessionMode` | `regular` | 034 |
| `Info.Side` | `Usec` `Savage` | 096, 150, 208, 273 |
| `side` (quest / achievement) | `Pmc` `Savage` `All` | 130, 133, 202, 262, 444 |
| `BotSide` | `Savage` `Usec` | 134, 158 |
| `WildSpawnType` | `assault` `marksman` | 134, 158 |
| `BotDifficulty`, `Difficulty`, `BotPreset` | `easy` `normal` `hard` `impossible` | 084, 134, 158, 160 |
| `BossDifficult`, `BossEscortDifficult` | `easy` `normal` `hard` `impossible` | 134, 158 |
| `BearPlayerBehaviour`, `UsecPlayerBehaviour` | `ChancedEnemies` | 134, 158 |
| `SavagePlayerBehaviour` | `Neutral` `Warn` `AlwaysEnemies` | 134, 158 |
| `Rules` | `Normal` `AvoidOwnPmc` `AvoidAllPmc` | 134, 158 |
| `ExfiltrationType` | `Individual` `Manual` `SharedTimer` | 134, 158 |
| `PassageRequirement` | `None` `Empty` `Timer` `Reference` `Train` `TransferItem` `WorldEvent` `ScavCooperation` | 134, 158 |
| `Requirement` | `Empty` `HasItem` | 084 |
| `RequiredSlot` | `ArmorVest` `Backpack` `FirstPrimaryWeapon` | 084, 134, 158 |
| `TraderServiceType` | `BtrBotCover` `BtrItemsDelivery` `CultistsAid` `ExUsecLoyalty` `PlayerTaxi` `StoryCardBarter` `TransitItemsDelivery` `ZryachiyAid` | 158 |
| `currency` (trader) | `RUB` `USD` | 071, 231, 421 |
| `GameVersion` / `GameEdition` | `standard` `left_behind` `prepare_for_escape` `edge_of_darkness` `unheard_edition` `eod_tue_edition` | 084, 096, 398 |
| `SurvivorClass` | `Unknown` | 096, 150, 160, 208 |
| `LethalDamagePart`, `BodyPart` | `Head` `Body` `Hands` `Feet` | 046, 084, 096 |
| `BodyPartColliderType` | `Eyes` `HeadCommon` `Pelvis` `RibcageUp` `LeftCalf` `LeftThigh` … | 084 |
| `bodyPart` (hideout QTE) | `LeftArm` `RightArm` | 108 |
| `rarity` (achievement) | `Common` `Rare` `Legendary` `Seasonal` | 133 |
| `BuildType` | `Standard` `Custom` | 123, 253, 441 |
| `source` (customization storage) | `default` `preorder` | 086, 094, 260, 457 |
| `tradeAction` | `buy` | 044, 079, 236, 430 |
| `FireMode` | `single` `fullauto` | 084, 123, 130, 150 |
| `skillType` | `Physical` `Practical` `Combat` | 110, 285, 485 |
| `_type` (template node) | `Node` `Item` `Preset` | 046, 084 |
| `audioQuality` | `Low` `Medium` `High` | 037, 070, 230, 434 |
| `RainIntensity` | `None` `Low` `Med` `High` | 037, 070, 230, 434 |
| `WindSpeed` | `Light` `Moderate` `Strong` `VeryStrong` `Hurricane` | 037, 070, 230, 434 |
| `MovementState` | `None` `Run` `Sprint` `Duck` `Prone` `Jump` `Land` `Turn` `Stop` `Gear` `Drop` `Search` `VaultGeneric` `VaultLand` | 037, 070, 230, 434 |
| `ExposedParameter` | `MasterVolume` `MusicVolume` `ChatVolume` `HideoutVolume` `RoomToneVolume` `UIVolume` `WorldVolume` | 037, 070, 230, 434 |
| `TriggerName` | `botEvent` `interactObject` | 134 |
| `result` (hideout QTE) | `Exit` `None` | 108 |
| `acceptanceAndFinishingSource`, `progressSource` | `eft` | 130, 202 |

**Enum-valued fields that are still ints.** Not everything moved, and guessing
either way costs a session:

| Field | Wire type | Seq |
|---|---|---|
| `status` (quest, in `/client/quest/list`) | int `0` | 130 |
| `Info.AccountType` | int `0` | 096 |
| `Info.MemberCategory`, `Info.SelectedMemberCategory` | int `0` | 096 |
| `Info.PrestigeLevel` | int `0` | 096 |
| `season` (weather) | int | 131 |
| `PauseReasons`, `Keys` (metrics config) | int arrays | 154 |

So `status` is a string on `/client/profile/status` and
`/v2/client/game/profiles/` and an **int** on `/client/quest/list`, in the same
session. The name is not the guide; the route is.

### Where the emulator sends an int against this

The only enum-as-int in emulator source that the capture contradicts is
`sideToInt` (tarkov.nim:262), used at tarkov.nim:287 for
`characterSlot.side`. Every side-valued field in the capture is a string —
`Info.Side` is `"Usec"` at seq 096, quest `side` is `"Pmc"` at seq 130,
`BotSide` is `"Savage"` at seq 134 — and the request the client *sends* to
create a profile is `{"side":"Usec", …}` (request seq 092). The capture has no
populated character slot, so this is not proof; it is the strongest available
circumstantial case that `side` should be `"Usec"` there too, and §2 says what
to do about it.

Everywhere else the emulator already emits strings: `mods/tarkov/emu/bots.nim:884`
and `:1046` set `Info.Side` to `"Savage"`, `:1060` sets
`SurvivorClass: "Unknown"`, and `emu/customise.nim` uses `"_type":"Node"` /
`"Item"` and `"Side":["Usec"]`. Those match seq 096/046/084.

## 5. Boot and session routes

Format throughout §5–§7: BSG's `data` shape at the seq cited, then what the
handler at the `tarkov.nim` line cited emits, then the delta.

### Exact matches — nothing to do

These eight answer the same key set with the same types as BSG:

| Route | BSG `data` | Emulator | seq / line |
|---|---|---|---|
| `/client/game/mode` | `{gameMode:str, backendUrl:str}` | same | 024 / tarkov.nim:1154 |
| `/client/game/start` | `{utc_time:float}` | same | 026 / tarkov.nim:222 |
| `/client/game/keepalive` | `{msg:"OK", utc_time:float}` | same | 168 / tarkov.nim:234 |
| `/client/game/logout` | `{status:"ok"}` | same | 506 / tarkov.nim:239 |
| `/client/game/token/issue` | `{token:str}` | same (session id as the token) | 112 / tarkov.nim:1061 |
| `/client/notifier/channel/create` | `{server, channel_id, url, notifierServer, ws}` | same five | 118 / tarkov.nim:1303 |
| `/client/checkVersion` | `{isvalid:bool, latestVersion:str}` | same | 310 / tarkov.nim:988 |
| `/client/server/list` | array of `{ip:str, port:int}` | same element shape, one entry | 293 / tarkov.nim:982 |
| `/client/libraries` | bare `{}` | bare `{}` | 020 / tarkov.nim:1007 |
| `putMetrics` / `putHWMetrics` / `putLoadMetrics` | `null` | `envelopeNull()` | 038, 209, 394 / tarkov.nim:1033 |

### Byte-exact replays

Seven routes are now answered from tables extracted straight out of this
capture. `post1Route` (tarkov.nim:1203) reads
`mods/tarkov/data/post1/<name>.json` and envelopes it raw, and each of those
files is **byte-identical to the capture's `data`** (checked by loading both and
comparing the parsed documents):

| Route | table | seq |
|---|---|---|
| `/client/quest/getMainQuestsList` | `mainquests.json` | 073 |
| `/client/quest/getMainQuestNotesList` | `mainquestnotes.json` | 074 |
| `/client/variable/group` | `variablegroups.json` | 075 |
| `/client/tape/list` | `tapes.json` | 077 |
| `/client/subtitle-track/list` | `subtitletracks.json` | 078 |
| `/client/quest/chains` | `questchains.json` | 146 |
| `/client/getMetricsConfig` | `metricsconfig.json` | 154 |

These are correct by construction and are the model the rest of §6 should
follow where a table is static.

### `/client/game/config` (seq 034) — six missing keys, boot-critical

BSG:

```json
{"aid":1891947, "lang":"en", "languages":{…20…}, "ndaFree":false,
 "taxonomy":6, "activeProfileId":"5bedb4245e9d88212f667821",
 "backend":{"Lobby":…, "Trading":…, "Messaging":…, "Main":…, "Static":…, "RagFair":…},
 "useProtobuf":false, "utc_time":1787177957.856316, "totalInGame":25222,
 "reportAvailable":true, "twitchEventMember":false,
 "sessionMode":"regular",
 "purchasedGames":{"eft":true,"arena":false},
 "isGameSynced":true,
 "linkedPlatforms":[],
 "availableGameModes":{"regular":true,"pve":false,"pvp-season":true}}
```

`onGameConfig` at tarkov.nim:195–217 emits `aid, lang, languages, ndid,
taxonomy, activeProfileId, backend, useProtobuf, utc_time, totalInGame,
reportAvailable, twitchEventMember`, with `backend` (tarkov.nim:197–202)
carrying only `Main, Trading, Messaging, RagFair`.

- **MISSING:** `ndaFree`, `sessionMode`, `purchasedGames`, `isGameSynced`,
  `linkedPlatforms`, `availableGameModes`; and `backend.Lobby`,
  `backend.Static`.
- **EXTRA:** `ndid` (tarkov.nim:208) — not in BSG's answer at all.
- **TYPE:** none among the shared keys. (`taxonomy` is `341` here against BSG's
  `6`; that is a value, not a type.)

`availableGameModes` is the one that matters: it is the same three
`EnumConverter` keys as §2 and it is what tells the client which mode buttons
exist. `purchasedGames` and `sessionMode` are the same class. Adding all six is
cheap and every value is in seq 034.

### `/v2/client/shop/status` (seq 299, 501) — all three keys missing

BSG: `{"aid":1891947, "labels":[], "tarcoins":0}`, in Envelope B.
Emulator: registered to `onEmptyObject` (tarkov.nim:2117 → tarkov.nim:1011),
which sends `{}` in Envelope A. Every field is absent. Send
`{"aid": <profile aid>, "labels": [], "tarcoins": 0}`.

### `/client/weather` (seq 131, 251, 445) — right keys, unusable values

Key sets match at both levels (`emu/raid.nim:442–460` against seq 131). Three
value problems:

- `date` and `time` are `""` at `emu/raid.nim:453–458` and again at `:457–458`
  for the outer object. BSG sends `"2026-08-20"` / `"15:21:10"` on the outer
  object and `"2026-08-20"` / `"2026-08-20 01:15:04"` — a **full datetime** —
  on the inner one. The two `time` fields are not the same format. An empty
  string into a `DateTime.Parse` is a throw, not a default.
- `acceleration` is `0` at `emu/raid.nim:456`; BSG sends `7` at seq 131, 251
  and 445. That is the in-raid clock speed, so `0` is a stopped clock.
- `rain_intensity` is the float `0.0` at `emu/raid.nim:449`; BSG sends the int
  `0`. Also `season` is `1` at `emu/raid.nim:459` against BSG's `0`.

### `/client/survey` (seq 298, 500)

BSG `data` is `null`. Registered to `onEmptyObject` (tarkov.nim:2234 →
tarkov.nim:1011), which sends `{}`. Use `onNullData` (tarkov.nim:1033).

### `/client/game/version/validate` (seq 028)

BSG `data` is `null`. `onGameVersion` (tarkov.nim:230) sends
`{"isvalid":true}`. Extra key, but the route's own comment says accepting
anything is deliberate and a truthy `data` reads the same as a null one here.
Cosmetic; `envelopeNull()` would be the literal match.

### `/client/libraries-extra` (seq 402) — not registered, and BSG refused it too

The emulator does not serve this route. Note what BSG did with it: `{"err":201,
"errmsg":"201 - Client not authorized","data":null}`. So the real backend
returns an **error** here, and the client carried on into the raid regardless.
Registering it is optional; if it is registered, `failure(201, "201 - Client
not authorized")` is the answer with evidence behind it, and `envelopeNull()`
is the safe alternative.

### Database pass-throughs — checked at the wrapper only

`/client/settings` (037), `/client/locale/en` (043), `/client/items` (045),
`/client/customization` (046), `/client/handbook/templates` (082),
`/client/globals` (084), `/client/locations` (134), `/client/languages` (033),
`/client/menu/locale/en` (030). The handlers (tarkov.nim:936–967) hand a
database table straight to `envelope`, so their correctness is the database's.
Two wrappers were checked and both are right:

- `/client/menu/locale/en` — BSG's `data` is `{"menu": {…24 strings…}}`, and
  tarkov.nim:967 wraps under `menu`. Correct (this was a known pre-1.0/post-1.0
  difference and it is already fixed).
- `/client/locale/en` — BSG's `data` is a **flat** map whose keys are
  `"<templateId> Name"`, `"<templateId> ShortName"`, `"<templateId> Description"`.
  tarkov.nim:958 passes the table through flat. Correct.

`/client/settings` (seq 037) is worth one specific note: BSG's `data` is
`{"config": {…}}`, wrapped. tarkov.nim:972 passes the `settings` table through
with **no wrapper of its own**, so the table itself must already contain the
`config` key. Checked: `build/db/db.json`'s `settings` table *is* `{"config":
{…}}`, so the wrapper is right. Its `config` has 30 keys against BSG's 34 —
missing `CollectLoadTimeMetrics`, `KeepAliveStaticInterval`,
`LobbyConnectionPercentage` and `SteamSyncCooldownSeconds`, all four of them
timing or telemetry constants the client can default.


## 6. Trading, the flea, inventory and raid

### `/client/game/profile/items/moving` (seq 301, 303, 318, 326, 331, 341, 353, 357, 470)

Nine calls. Every one answers `{"warnings": [], "profileChanges": {<profile id>: {…}}}`,
and the inner object has **exactly twenty-one keys** in every one of them:

```
_id  experience  quests  questsStatus  ragFairOffers  items  production
improvements  skills  health  traderRelations  changedHideoutStashes
repeatableQuests  recipeUnlocked  moneyTransferLimitData  completableItems
readQuestData  newQuestNotes  variableValues  seasonalRewards
battlePassUniversalDocumentBalance
```

`itemEventResponse` (tarkov.nim:662–707, `changes` built at :674–688) emits eleven.

- **MISSING (10):** `changedHideoutStashes` `[]`, `repeatableQuests` `[]`,
  `recipeUnlocked` `[]`, `moneyTransferLimitData`
  `{nextResetTime, remainingLimit, totalLimit, resetInterval}` (seq 301 carries
  the values), `completableItems` `[]`, `readQuestData` `[]`, `newQuestNotes`
  `[]`, `variableValues` `[]`, `seasonalRewards` `[]`,
  `battlePassUniversalDocumentBalance` `null`. Nine of the ten are constants.
- **EXTRA:** `builds` (tarkov.nim:680). BSG sends no `builds` key in any of the nine.
- **TYPE, and this is the important one:** `improvements` is an **array** `[]`
  in all nine BSG responses; tarkov.nim:683 emits `obj()`, an **object**. A C#
  field typed as a list receiving `{}` is a deserialisation failure, and this
  response is on the path of every inventory action there is.
- **TYPE:** `traderRelations` is **polymorphic** — `[]` (array) when no trader
  changed (seq 301, 303, 318, 341, 470), and an object holding **only the
  changed fields of the changed trader** when one did (seq 326:
  `{"5ac3b934156ae10c4430e83c":{"salesSum":13131,"standing":0.0}}` — two fields,
  not that trader's whole `TraderInfo`). tarkov.nim:688 always sends the entire
  `TradersInfo` table as an object. Probably harmless, since it overwrites with
  the same values, but it is not what the server does.
- **`items` is a sparse diff.** BSG omits `new`/`change`/`del` when they would
  be empty: `{}` at seq 301, `{"new":[…]}` at 318, `{"change":[…],"del":[…]}`
  at 326, `{"new":[…],"change":[…]}` at 331. The emulator always sends all
  three. Over-inclusion, not a type error.

### `/client/items/prices/{id}` (seq 317, 322, 335) — `currencyCourses` is keyed wrong

BSG, seq 317:

```json
{"supplyNextTime": 1787181960,
 "prices": { "…681 entries, tpl → int…" },
 "currencyCourses": {
   "5449016a4bdc2d6f028b456f": 1,
   "569668774bdc2da2298b4568": 138.55,
   "5696686a4bdc2da3298b456a": 125.13,
   "5d235b4d86f7742e017bc88a": 7500.0 }}
```

`currencyCourses` is keyed by **currency item template id**, and the values are
**exchange rates**: roubles `1`, dollars `138.55`, euros `125.13`, the GP coin
`7500.0`.

`onItemPrices` (tarkov.nim:1340–1351) builds
`{"usd": handbookPrice(Dollars), "eur": handbookPrice(Euros)}` — lowercase
currency names for keys, handbook prices for values, no rouble entry and no GP
coin. Every lookup by tpl id misses. The proc's own comment at tarkov.nim:1330
("a missing key is a division on a null") describes exactly what this does to
the trader screen's price comparison. `prices` and `supplyNextTime` are right.

### `/client/match/join` (seq 379) — not registered

BSG: `{"maxPveCountExceeded": false, "profiles": [<one eleven-key pending PMC
entry>], "estimate": 210}`. The entry is in §3.

Not in `registerRoutes`; grep for `match/join` in `tarkov.nim` finds nothing.
This is the online raid-entry call. The raid in this capture went in through
`match/local/start` instead, which is why the emulator has got this far without
it.

### `/client/match/group/invite/cancel-all` (seq 369, 371, 504)

BSG `data` is the bare bool `true` in all three. `onCancelAllInvites`
(tarkov.nim:1246–1252) sends `envelopeNull()`. Use `envelope(raw("true"))`,
which is what `onMatchAvailable` already does correctly for seq 377.

### `/client/match/group/current` (seq 152, 297, 494, 499)

BSG: `{"squad": [], "raidSettings": null}`, identical in all four.
`onMatchGroup` (tarkov.nim:1748–1750) sends `{"squad": []}` only. Add
`raidSettings: null`. Low risk, free to fix.

### `/client/match/local/start` (seq 158)

BSG: `{serverId, serverSettings, profile:null, locationLoot, transition,
excludedBosses:[]}`. `serverSettings` is
`{TraderServerSettings:{TraderServices:{8 entries}}, BTRServerSettings:{15 keys}}`;
`transition` is `{transitionType:int, transitionRaidId:str, transitionCount:int,
visitedLocations:[]}`; `locationLoot` is the full 107-key map base document.

`onMatchStart` (tarkov.nim:1421–1467) builds exactly that key set — it was
rewritten from the pre-1.0 `{serverId, serverSettings, status, notifier}` shape
and the proc's own comment records it. Two conditional failure modes remain:

- `serverSettings` comes from `post1Table("serversettings")`, and a missing
  table turns the whole route into `failure(1, …)`, i.e. a raid that cannot
  start. **All of it is in seq 158 and can be extracted the same way the seven
  tables in §5 were.** Until it is, this route is one missing file away from
  blocking.
- `locationLoot` is omitted entirely (with a `warn`) when the request names no
  location. BSG always sends it.

### `/client/raid/configuration` (156, 368, 373), `/client/match/group/exit_from_menu` (376), `/client/match/available` (377)

BSG: `null`, `null`, `true`. Emulator: `envelopeNull()`, `envelopeNull()`,
`envelope(raw("true"))`. All three match.

### `/client/insurance/items/list/cost` (seq 355, 365)

BSG: `{traderId: {itemId: premium}}`, nested objects with int premiums.
`onInsuranceCost` (tarkov.nim:1967–1998) builds exactly that. Match.

### `/client/trading/api/traderSettings` (071, 231, 421) and `getTraderAssort/{id}` (320 and six more)

Both are raw database pass-throughs (`emu/traders.nim:35–43` and `:56–71`), so
their shape is the import's. Two facts from the capture that the importer
should know:

- `traderSettings` is an array of 18 traders, 33 keys each, and inside
  `loyaltyLevels[i]` **`insurance_price_coef` is a string** while every sibling
  `*_coef` is an int (seq 071). That is BSG's own inconsistency; an importer
  that normalises it to an int introduces a mismatch.
- `getTraderAssort` is `{nextResupply:int, items:[], barter_scheme:{},
  loyal_level_items:{}}`, and **the item element shape varies by trader**.
  Prapor's items carry `location:null` and an `upd` with `UnlimitedCount`,
  `BuyRestrictionMax` and `BuyRestrictionCurrent`; Fence's (seq 337) carry none
  of those and only `upd.StackObjectsCount`.

### `/client/game/bot/generate` (seq 160)

BSG returns 31 bot profiles with **26 keys** each, and not one of them is
`Notes`, `Quests`, `RagfairInfo`, `TradersInfo` or `UnlockedInfo`.
`generateProfile` (`emu/bots.nim`, around :899–967) sets all five
unconditionally. Extra keys, very likely tolerated, but provably not what the
server sends.

The other direction is worse and is now measured rather than guessed.
`build/db/db.json`'s `bots.base` has **16** keys against BSG's 26, and
everything it lacks is a post-1.0 addition:

```
BattlePassProgress   BattlePassUniversalDocumentBalance   CompletableItems
Ending               QuestNotes                           ReadQuestData
SeasonalPerkEffectParameters   SeasonalPerks   SeasonalRewards
UnlockedLocations
```

Since `generateProfile` starts from `bots.base` and only fills keys it knows
about, **every bot this server generates is missing those ten**. Seq 160 has
all of them, 31 times over, so the fixture can be rebuilt from the capture.

### `/client/locations` (seq 134)

BSG: `{locations: {mapId → base}, paths: [18 entries]}`. `locationsBody`
(`emu/raid.nim:159–190`) builds the same two keys, so the shape matches.
`paths` is very likely `[]` because the importer does not read
`database/locations/base.json`'s `paths` — the code's own comment says so. A
missing transit graph, not a shape bug.

### `/client/ragfair/find` (311, 343, 345, 347, 351, 361) — NOT CHECKED

BSG's `data` is `{offers:[], offersCount:int, selectedCategory:str,
categories:{catId → int}}`, and **`categories` is present at seq 343 and 361
and absent at 345, 347 and 351** — it tracks a flag in the request. Offer
elements carry 16 to 18 keys depending on whether the offer has buy
restrictions.

`onRagfairFind` (tarkov.nim:1958–1961) delegates to `searchResult` in
`emu/market.nim`, **which was not read**. This is the one route in the capture
this document does not compare, and it needs its own pass.

## 7. Profile, progression, hideout and menu content

### Exact matches, confirmed against `build/db/db.json`

These were checked key-set against the capture and the shipped database and are
right: `/client/game/profile/create` (092, `{uid}`),
`/client/game/profile/nickname/validate` (090, `{status:"ok"}`),
`/client/achievement/list` (133, `{elements:[15-key elements]}` — the db's
`templates.achievements[0]` has the same 15 keys),
`/client/prestige/list` (072, `{elements:[6-key elements]}`),
`/client/hideout/settings` (107, the same 5 float keys, byte-for-byte),
`/client/hideout/qte/list` (108), `/client/hideout/customization/offer/list`
(109, `{globals, slots}` with 7- and 8-key elements),
`/client/hideout/areas` (110, 11-key elements),
`/client/hideout/production/recipes` (111 — BSG's `data` is the object
`{recipes, scavRecipes, cultistRecipes}`, and the db's `hideout.production`
table is already that object, so the raw pass-through is correct),
`/client/builds/list` (123, `{equipmentBuilds, weaponBuilds, magazineBuilds}`),
`/client/game/profile/list` in its empty state (083, `[]`).

### `/client/customization/storage` (seq 086, 094, 260, 457) — wrong container type

BSG's `data` is a **bare array** of ownership records, 49 entries at seq 086 and
62 at seq 260:

```json
[{"id":"674731c8bafff850080488bb","source":"default","type":"dogTag"}, …]
```

`type` runs `dogTag`, `environment`, `gesture` and more; `source` is `default`
or `preorder`.

`onCustomizationStorage` (tarkov.nim:1140–1147) sends the **object**
`{"_id": <profile id>, "suites": []}`. Wrong container, wrong keys, no content.
Four independent captures agree. This is the clothing/customisation inventory,
and a list deserialiser handed an object does not degrade — it fails.

### `/client/quest/list` (seq 130, 262, 444) — wrong container type

BSG's `data` is a **bare array** of quest objects (9 at seq 130, 22 at 262 and
444), 39 keys each. `onQuestList` (tarkov.nim:944–946) is
`envelope(raw(quests()))` where `quests()` is `table("templates.quests", "{}")`,
and **`build/db/db.json`'s `templates.quests` is a dict of 558 quests keyed by
id**, not an array. So this route hands the client a JSON object where it wants
a list. Same failure mode as the one above, on the quest journal.

Note also that quest `status` is the **int** `0` here (§4) — this is the route
where `status` is *not* a wire string.

### `/client/seasonal-perks/list` (seq 044, 079, 236, 430) — wrong key names

BSG, four for four:

```json
{"common":  [ …6 perks… ],
 "personal":[ …33 perks… ]}
```

with each perk `{id, type, imageUrl, effects, points, mutuallyExclusiveSeasonalPerkIds}`
— e.g. `{"id":"69c41a19cd28c936320a7523","type":"common",
"imageUrl":"/files/seasonal-perks/6a60d391ad4b72034b029c61.png",
"effects":[{"effectId":"insurance_disabled"}],"points":null,
"mutuallyExclusiveSeasonalPerkIds":[]}`.

`onSeasonalPerks` (tarkov.nim:1040–1050) sends `{"commonPerks": [],
"personalPerks": []}`. The comment at tarkov.nim:1044 says the wire keys come
from the C# backing fields `_commonPerks` / `_personalPerks`. **Four live
captures say the wire keys are `common` and `personal`.** The `[JsonProperty]`
attribute wins over the field name, exactly as it does for `characterSlot` in
§2. Rename the keys and, ideally, fill them — the perk ids in seq 048's
`selectedSeasonalPerkIds` are the same ids seq 044 defines, so the two routes
have to agree.

### `/client/season/active` (seq 080, 237, 438) — the whole payload is missing

BSG: `{"season": {"id":"69e232a764dfe95549003f0f", "startTs":1776431739,
"endTs":1796634039, "seasonalRewards":[…]}}`, identical in all three.
`onSeasonActive` (tarkov.nim:1051–1055) sends `{}`. `build/db/db.json` has no
`season` table at all, so this is unimplemented rather than misplumbed. Note
that `season.id` is the same string as `seasonNameLocalizationKey` in seq 048 —
these routes are meant to agree.

### `/client/battle-pass/active` (seq 081, 252, 446) — `null` against a real payload

BSG: `{"battlePasses":[{id, exchangeRate, itemExchangeSettings, pages,
documents, documentLimits}]}`, a substantial object, in all three. The route is
registered to `onNullData` (tarkov.nim:2247), which answers `data: null`. Of the
"wired to nothing" routes this is the clearest: BSG always answers structured,
non-empty content here. `id` is the same `battlePassId` seq 048 reports progress
against.

### `/client/friends` (seq 124, 249, 442) — three of six keys

BSG: `{"Friends":[], "Ignore":[], "InIgnoreList":[], "steamFriendList":[],
"incomingRequestList":[], "sentRequestList":[]}` — six keys, all empty arrays.
`onFriendList` (tarkov.nim:1064–1073) sends the first three. Add the other
three as empty arrays; they are free.

### Routes the capture uses that are not registered

| Route | seq | BSG `data` |
|---|---|---|
| `/client/quest/complete` | 202 | `{quests:[13 objects], questsStatus:[]}` |
| `/client/ending/list` | 132, 256, 451 | `{elements:[{id, systemName, conditions, rewards, consequences}] × 4}` |
| `/client/tutor-game/profile` | 150 | `{profile: {…a whole profile…}}` |
| `/client/dialogue` | 076 | 2.5 MB table |
| `/client/match/join` | 379 | see §3 |
| `/client/libraries-extra` | 402 | BSG itself answered `err:201` |

`/client/ending/list` is a static four-element table and is the cheapest of
these to fix — extract it from seq 132 into `mods/tarkov/data/post1/` and wire
it through `post1Route` like the seven in §5. `/client/tutor-game/profile` is
already named in the backlog by a comment at `emu/post1.nim:19`, which says
correctly that it carries a profile and is therefore not a static table.

### Cosmetic differences worth recording but not worth prioritising

| Route | seq | BSG | Emulator | Where |
|---|---|---|---|---|
| `/client/game/profile/select` | 098 | `{status:"ok"}` | `{status, notifier, notifierServer}` | tarkov.nim:386 |
| `/client/game/profile/nickname/reserved` | 088 | bare string `"Savant_"` | bare string `""` | tarkov.nim:428 |
| `/client/builds/weapon/save`, `/client/builds/equipment/save` | 305, 359 | `null` | `{id:<string>}` | tarkov.nim:1384 |
| `/client/achievement/statistic` | 126 | id → **float** (`2.15`, a percentage) | id → **int** (a count) | `emu/achievements.nim:132` |
| `/client/tutor-game/check` | 148 `true`, 257/454 `false` | bool | always `false` | tarkov.nim:1244 |
| `/client/settings` | 037 | `config` with 34 keys | db has 30 — missing `CollectLoadTimeMetrics`, `KeepAliveStaticInterval`, `LobbyConnectionPercentage`, `SteamSyncCooldownSeconds` | `build/db/db.json` |

### Checked only in the state the capture exercises

`/client/mail/dialog/list` (136, 263, 458) is `[]` in all three — an empty
inbox, which the emulator matches. `/client/repeatalbeQuests/activityPeriods`
(271, 462) is `[]` in both. `/client/game/profile/list` populated (096 and four
more) is a straight dump of the persisted profile, so its correctness belongs to
profile creation, not to this handler. **None of the three has a populated
shape in this capture, so none of them is verified beyond empty.**

One thing the populated profile does establish: a real post-1.0 profile carries
35 top-level keys including `CompletableItems`, `UnlockedLocations`, `Ending`,
`QuestNotes`, `ReadQuestData`, `SeasonalPerks`, `SeasonalPerkEffectParameters`,
`SeasonalRewards`, `BattlePassProgress`,
`BattlePassUniversalDocumentBalance`, `Prestige`, `UnlockedInfo`,
`moneyTransferLimitData` and `battlePassDocumentLimitData` (seq 096). Whether
this server's created profiles carry them was not checked.

Also worth noting because it will otherwise look like a bug: **BSG itself flips
container type on empty collections.** `CompletableItems` is `[]` at seq 096 and
`{}` at seq 208; `Achievements` is `[]` at 096 and `{}` at 398. That is
serialiser noise on an empty collection, not a contract.

## 8. The ten that matter, ranked

Ranked by *how visibly the client breaks*, not by how much work the fix is.
Anything that fails a deserialiser outranks anything that leaves a screen
empty, and anything that leaves a screen empty outranks a wrong number.

**1. `/client/quest/list` hands the client an object where it wants an array.**
seq 130/262/444 · `onQuestList`, tarkov.nim:944–946.
`quests()` serves `templates.quests`, which is a **dict of 558 quests keyed by
id** in `build/db/db.json`; BSG sends a bare array. Fix: emit
`[ …values of templates.quests… ]`, not the map. This is the quest journal and
every quest-gated screen behind it.

**2. `/client/customization/storage` hands the client an object where it wants
an array.** seq 086/094/260/457 · `onCustomizationStorage`, tarkov.nim:1140–1147.
BSG sends `[{"id":…,"source":"default","type":"dogTag"}, …]`, 49 to 62 entries.
The emulator sends `{"_id":…,"suites":[]}`. Fix: emit an array of
`{id, source, type}` — one entry per owned customisation item, `source`
`"default"` or `"preorder"`.

**3. `profileChanges.improvements` is an object where BSG sends an array.**
seq 301 and eight more · tarkov.nim:683.
`put(changes, "improvements", obj())` → change to `arr()`. One character of
intent, and it sits on the response to *every* inventory action.

**4. `/v2/client/game/profiles/` omits two of the three game modes.**
seq 048 · `onProfilesV2`, tarkov.nim:313–338.
BSG always sends `pve`, `pvp-season` and `regular`. Build all three
unconditionally; give the modes this server does not offer
`{"status":"locked"}` and an empty `regular` `{"status":"empty"}`. §2 has the
whole body and the rest of the change. This is the character-selection screen
and it has already cost two sessions.

**5. `/client/seasonal-perks/list` uses the wrong key names.**
seq 044/079/236/430 · `onSeasonalPerks`, tarkov.nim:1040–1050.
`commonPerks`/`personalPerks` → `common`/`personal`. Four live captures agree
and the comment at tarkov.nim:1044 is wrong. The perk ids seq 048 selects are
defined here, so §2 and this route have to agree or the character screen has
dangling references.

**6. `/client/battle-pass/active` answers `null` against a real payload.**
seq 081/252/446 · registered to `onNullData` at tarkov.nim:2247.
BSG always sends `{"battlePasses":[{id, exchangeRate, itemExchangeSettings,
pages, documents, documentLimits}]}`. Extract seq 081 into
`mods/tarkov/data/post1/battlepass.json` and serve it through `post1Route` —
the same mechanism that already makes seven routes byte-exact (§5).

**7. `/client/match/join` is not registered.**
seq 379.
Online raid entry gets a 404. Answer
`{"maxPveCountExceeded": false, "profiles": [<pending PMC entry>],
"estimate": <int>}` and set the profile's pending state so the
`/client/profile/status` calls that follow report `MatchWait` (§3).

**8. `/client/game/config` is missing `availableGameModes` and five siblings.**
seq 034 · `onGameConfig`, tarkov.nim:195–217.
Add `availableGameModes` `{"regular":true,"pve":false,"pvp-season":true}`,
`purchasedGames` `{"eft":true,"arena":false}`, `sessionMode` `"regular"`,
`ndaFree` `false`, `isGameSynced` `true`, `linkedPlatforms` `[]`, and
`backend.Lobby` / `backend.Static`. Drop `ndid`. `availableGameModes` is what
tells the client which mode buttons exist, and it is the same three
`EnumConverter` keys as item 4.

**9. The five Envelope B routes get Envelope A.**
seq 019/026/048/168/299 · `server.nim:653`.
`{"data":…,"err":null,"errmsg":null,"status":null,"errLog":{},"error":{"code":null,"message":null}}`
on `/client/metadata`, `/client/game/start`, `/v2/client/game/profiles/`,
`/client/game/keepalive` and `/v2/client/shop/status`. **This is the one item
on the list whose severity is inferred rather than measured** (§1) — it may
well be tolerated. It is here because it is cheap, because it covers keepalive
(which runs forever), and because leaving it unknown means every failure on
those five routes has two candidate causes instead of one.

**10. `/client/items/prices/{id}` keys `currencyCourses` by name instead of
template id.** seq 317/322/335 · `onItemPrices`, tarkov.nim:1340–1351.
BSG: `{"5449016a4bdc2d6f028b456f":1, "569668774bdc2da2298b4568":138.55,
"5696686a4bdc2da3298b456a":125.13, "5d235b4d86f7742e017bc88a":7500.0}` —
tpl ids, exchange rates. The emulator: `{"usd":…, "eur":…}` — names, handbook
prices, no rouble. Every lookup misses, on every trade screen.

Just below the line, and cheap: `/client/season/active` sending `{}` instead of
`{"season":{…}}` (seq 080, tarkov.nim:1051–1055); `/client/friends` sending
three of six keys (seq 124, tarkov.nim:1064–1073);
`/client/match/group/invite/cancel-all` sending `null` instead of `true`
(seq 369, tarkov.nim:1246–1252); `/client/ending/list` not registered
(seq 132 — a static four-element table, extractable today);
`post1Table("serversettings")` not being installed, which turns
`/client/match/local/start` into a hard failure (seq 158 has the whole table).

## 9. What this document did not check

- **Nothing was run.** No response here was measured off the wire; every
  emulator claim is read from source. The tree's newest `tarkov.dll` (22:19)
  predates the source this describes (22:47) and the build lane belongs to
  another session.
- **`/client/ragfair/find`** — `emu/market.nim:searchResult` was not read. The
  BSG side is described in §6; the emulator side is not.
- **Database content** for `/client/items`, `/client/globals`,
  `/client/locale/en`, `/client/customization`, `/client/handbook/templates`,
  `/client/locations` and `/client/dialogue`. Only the wrapper the handler puts
  around the table was checked. `/client/settings` was checked one level deeper
  and is 30 of BSG's 34 `config` keys.
- **Populated states** for `/client/mail/dialog/list`,
  `/client/repeatalbeQuests/activityPeriods` and `warnings` on
  `/client/game/profile/items/moving` — all three are empty in every capture,
  so their non-empty shape is unknown.
- **Anything about a populated character slot.** Seq 048 is the only
  `/v2/client/game/profiles/` call and the account had no character. Everything
  `characterSlot` emits beyond `status` is still a guess from decompiled
  metadata.
- **A PMC raid, a death, a scav run, a group, posting a flea offer, and an
  insurance payout.** None of them happen in this capture.
- **Whether the client actually rejects any of the mismatches above.** This
  document says what differs and reasons about which differences a deserialiser
  cannot survive. It does not contain a single observation of the client
  reacting to one.

Line numbers are against `mods/tarkov/tarkov.nim` at 2368 lines, 2026-08-19
22:47. **Another session was editing that file while this was being written** —
it grew by 220 lines in the course of it — so a cited line may have moved. Every
citation also names its proc; trust the name over the number.
