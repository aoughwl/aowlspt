# Admin Trader — write your first aowlspt mod

This folder is a working mod *and* a tutorial. It adds a new trader who sells
everything in the game for free, and gives out one quest.

It is **199 lines**, and about 40 of those are the settings page. Read
`admintrader.nim` top to bottom — it should take a couple of minutes — then
come back here.

---

## The whole idea, in one line

```nim
discard dbWrite("traders." & myTraderId, myTraderJson)
```

`mods/tarkov` is the game server. It has no "trader" type and no "quest" type —
it reads `traders.<id>` and `templates.quests.<id>` out of the loaded database
and serves whatever it finds. So there is no trader API to learn. There is
`dbWrite`, and there are *shapes*.

The shapes are the hard part: a trader's `base` has 33 fields, a quest template
has 30, and a missing one hangs the client rather than erroring. So they live in
`aowlspt/trader`, with a working default for every field.

```nim
import aowlspt/trader

var t = newTrader(traderId("ad0000000000000000000001"), "Admin Trader")
t.description = "Everything, free."
discard t.stockWholeHandbook()          # ~4,300 items, price 0
discard install(t)                      # dbWrite("traders.<id>", …)
```

That is a complete, working, browsable trader. `install` is not a framework —
it does exactly two `dbWrite`s and reads them back, and it names both in its doc
comment.

## A quest is the same move

```nim
var q = newQuest(questId("ad0000000000000000000101"), t, "Admin Induction")
q.description = "Bring me one pack of painkillers."
q.requireLevel(1)                                  # startable immediately
q.requireHandover("544fb37f4bdc2dee738b4567", 1)   # painkillers
q.rewardExperience(500)
q.rewardStanding(0.1)
discard install(q)
```

A quest with no start condition or no finish condition can never be taken or
handed in, so `install` refuses to write one and says why.

## Everything a server mod does

| you want to | you call |
|---|---|
| change game data | `dbWrite("some.dotted.path", json)` |
| read game data | `dbRead("some.dotted.path")` |
| answer a URL | `serve("/my/route", myHandler)` |
| read your own config | `setting("myKey").asBool(true)` |
| add a trader / quest | `aowlspt/trader` — the shapes above |

## Make it yours in four steps

1. Copy this folder to `mods/yourtrader/` and rename `admintrader.nim`.
2. At the top of the file, change `ModGuid`, `ModName`, `TraderHex` and
   `QuestHex`. The two ids must be **24 hexadecimal characters** (`0`–`9`,
   `a`–`f`) and must not collide with an existing trader. A typo is safe:
   `traderId` refuses it in the log and nothing is written.
3. Add an entry to `registry/mods.json`. Its `id` must be **exactly** your
   `ModGuid`, and its `sides` and `author` must match your source **verbatim** —
   `aowl selfcheck` compares them character by character.
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

Number 3 is the one that catches people. That file is written by `aowl.manager`;
**hand-editing it gets reverted.** The supported route is
`GET /aowlspt/mods/enable/<guid>`. See `docs/MOD-ENABLE-PATH.md`.

## Settings

Every key you `declareSettings` must also exist in `config.json`. If it does
not, the control renders on the settings page, moves when you drag it, and
resolves to nothing. `declareSettings` backfills missing keys at load and
`aowl build mods` fails you if a declared key has nowhere to land — but ship
them in `config.json` anyway, so a reader can see the defaults.

Three lines wire the whole settings surface up:

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
python tools\acceptance_admintrader.py       # the same thing, asserted
```

The route's body comes from `auditTrader` and `auditQuest`, and every number in
it is read back out of the **database**, not out of this mod:

```
listedInTradersTable=yes  tradersInTable=13  offersStored=4288
offersNotFree=0  offersUnpriced=0  questStart=1  questFinish=1  questRewards=2
```

Note that the two offer counters are **negative** — `offersNotFree`,
`offersUnpriced`. "We wrote 4,288 free offers" is a claim about our own write
and cannot fail. "No offer in the database costs anything" can. A check that
cannot fail is the bug.

The suite also compares our stored `base` against the 12 **stock** traders'
field by field, and fails if any field matches none of them. That check exists
because the ten content checks above all passed while the client was rejecting
our trader outright: `json.loads` accepted the 102,095-byte document, and the
client's *typed* deserializer did not. **"It is valid JSON" is not a check** —
it is the §9b trap, a test that cannot fail. Compare against data you did not
write.

Note also that `listedInTradersTable` can read `"unknown: …"`. Enumerating the
traders table needs a host that can list keys; `aowlspt-backend` can and
`aowlspt-sim` cannot. Three outcomes, never two — "I could not look" is not a
pass.

## Things worth knowing

These were all real ways to write a trader that looks fine and is silently
broken. `aowlspt/trader` now makes most of them impossible rather than merely
documented — but knowing *why* is what lets you debug the next one.

* **A price is a barter requirement.** There is no price field. "Free" is a
  requirement for `count: 0` roubles — which is what `freeOffer` writes.
* **An assort is three collections keyed to each other** — `items`,
  `barter_scheme`, `loyal_level_items`. An offer in one and not the others is
  an offer the client draws and cannot price. `traderAssort` emits all three
  from one list of `Offer`s in one loop, so they cannot disagree.
* **Names are locale keys, not text.** A quest's `name` field holds the string
  `"<questId> name"`, and the sentence lives in `locales.global.en` under a key
  containing a **space** — so a dotted `dbWrite` path writes a key nobody reads.
  `localeText` takes a key and a value, never a path.
* **The stock comes from `templates.handbook.Items`**, not `templates.items`.
  The handbook is the ~4,300 tradeable things and is ~400 KB;
  `templates.items` is 4,673 raw templates including hideout nodes and stashes,
  tens of megabytes, with the wrong contents for a shop. `stockWholeHandbook`
  takes no table argument.
* **`insurance_price_coef` is a string** in the real data (`"0"`, not `0`) for
  5 of the 12 stock traders, and a number for the other 7. `traderBase`
  matches the data rather than correcting it.
* **`items_sell` is NOT `{category, id_list}`.** That is the *buy* side's
  shape. Measured across the 12 stock traders, `items_sell` is either a dict
  keyed by loyalty level (`"1".."4"`, 8 traders) or a bare `[]` (4 traders).
  Writing the buy shape there produced
  `JSON parsing error in response to traderSettings at line 1 position 101170`
  in the live client — from a document that was **perfectly valid JSON**. This
  is why `traderBase` owns `items_sell` and no caller can supply one.
* **Shape completeness beats field values.** A response the client cannot parse
  hangs it rather than erroring, so fill in the whole shape even where the
  numbers are zeros. That is why `traderBase` writes all 33 fields whether you
  set them or not.

## What this mod does not do

* It does not touch any file on disk. `dbWrite` patches the database the server
  holds in memory, for the life of that process. Restart without the mod and
  the trader is gone.
* It has no client-side half. Everything here is `sideServer`.
* It writes the trader on every load, so loading it twice overwrites rather
  than duplicating — which is what you want here, and is not automatic; a mod
  that *adds* to something has to think about it.
