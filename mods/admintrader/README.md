# Admin Trader — write your first aowlspt mod

This folder is a working mod *and* a tutorial. It adds a new trader who sells
everything for free and gives out one quest. It is about 380 lines, and roughly
300 of those are the JSON shapes the game client insists on; the mechanism
itself is three function calls.

Read `admintrader.nim` top to bottom. Then come back here.

---

## The whole idea, in one line

```nim
discard dbWrite("traders." & MyTraderId, myTraderJson)
```

`mods/tarkov` is the game server. It has no "trader" type and no "quest" type —
it reads `traders.<id>` and `templates.quests.<id>` out of the loaded database
and serves whatever it finds. So there is no trader API to learn. There is
`dbWrite`, and there are shapes.

Everything a mod does on the server side is one of four calls:

| you want to | you call |
|---|---|
| change game data | `dbWrite("some.dotted.path", json)` |
| read game data | `dbRead("some.dotted.path")` |
| answer a URL | `serve("/my/route", myHandler)` |
| read your own config | `setting("myKey").asBool(true)` |

## Make it yours in four steps

1. Copy this folder to `mods/yourtrader/` and rename `admintrader.nim`.
2. At the top of the file, change `ModGuid`, `ModName`, `TraderId` and
   `QuestId`. The two ids must be **24 hexadecimal characters** (`0`–`9`,
   `a`–`f`) and must not collide with an existing trader.
3. Add an entry to `registry/mods.json`. Its `id` must be **exactly** your
   `ModGuid` — the build fails if it is not, on purpose, because a guid
   mismatch silently puts a second dead row on the in-game mod panel.
4. `.\installer\build\aowl.exe build mods` (PowerShell — `gcc` fails silently
   under Git Bash).

To just rename *this* trader: edit `"nickname"` in `config.json`, or change it
on the in-game settings page, where it applies immediately.

## Getting it to actually load

Three things, all required. Missing any one of them looks exactly like a broken
mod, because nothing complains:

1. the built `.dll` in the install's `mods/<dir>/`,
2. an entry in `registry/mods.json` with a matching guid,
3. the mod enabled in the **manager-owned selection**,
   `mods/aowlspt-selection.json`.

Number 3 is the one that catches people. That file is written by `aowl.manager`
from `registry/mods.json`'s lists; **hand-editing it gets reverted**. Enable the
mod through the manager, or add it to a list in `registry/mods.json` that the
selection inherits.

## Settings

Every key you `declareSettings` must also exist in `config.json`. If it does
not, the control renders on the settings page, moves when you drag it, and
resolves to nothing. `declareSettings` backfills missing keys for you at load,
and `aowl build mods` fails you if a declared key has nowhere to land — but
ship them in `config.json` anyway, so a reader can see the defaults.

Two lines wire the whole settings surface up:

```nim
declareSettings(adminSchema())
discard serveSettingsRoutes()   # registers both HTTP routes
onSettingsApplied(onApply)      # what to do when a value changes
```

`onApply` must say what happened — `settingApplied(...)`,
`settingAppliesOnRestart(...)` or `settingIgnored(...)`. A setting that changes
and reports nothing is indistinguishable from a setting that does nothing.

## Check that it worked

```
curl -k https://127.0.0.1/admintrader/status
```

```json
{"ok":true,"mod":"aowl.admintrader","traderId":"ad0000000000000000000001",
 "questId":"ad0000000000000000000101","offers":4288,
 "nickname":"Admin Trader","traderInDatabase":true,"questInDatabase":true}
```

Note what that route reports: the state of the **database after the fact**, read
back — not "we called `dbWrite` and it returned Ok". A check that reads back
your own write cannot fail, and a check that cannot fail is the bug.

Every mod should have a status route like this one.

## Things worth knowing

* **A price is a barter requirement.** There is no price field. "Free" is a
  requirement for `count: 0` roubles.
* **An assort is three collections keyed to each other** — `items`,
  `barter_scheme`, `loyal_level_items`. An offer in one and not the others is
  an offer the client draws and cannot price. Build all three in the same loop.
* **Names are locale keys, not text.** A quest's `name` field holds the string
  `"<questId> name"`, and the actual sentence lives in `locales.global.en`.
  Skip that and the screen shows a raw 24-hex id.
* **The stock comes from `templates.handbook.Items`**, not `templates.items`.
  The handbook is the ~4,300 tradeable things and is small; `templates.items`
  is every raw template including hideout nodes, and is tens of megabytes.
* **Shape completeness beats field values.** A response the client cannot parse
  hangs it rather than erroring, so fill in the whole shape even where the
  numbers are zeros.

## What this mod does not do

* It does not touch any file on disk. `dbWrite` patches the database the server
  holds in memory, for the life of that process. Restart without the mod and
  the trader is gone.
* It has no client-side half. Everything here is `sideServer`.
* It writes the trader on every load, so loading it twice overwrites rather
  than duplicating — which is what you want here, and is not automatic; a mod
  that *adds* to something has to think about it.
