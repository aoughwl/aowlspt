# The emulator

`mods/tarkov` is a Tarkov server — profiles, the static tables, traders and
trading, the inventory, quests, the hideout and its production queue, raids and
their loot, bots, scavs, skills, the flea market, mail and insurance — and it is
**a mod**. It imports `aowlspt`, `aowlspt/server` and `aowlspt/json`, and
nothing else. There is no private door into the host.

That constraint is the reason it exists in this repo. A plugin API is only as
good as the largest thing anyone has written with it, and the largest thing
worth writing here is the game server itself. Every gap found while writing it
was closed in the API rather than worked around in the mod:

| Found writing | Closed by |
|---|---|
| profiles must survive a restart | `save` / `load` / `savedKeys`, on ABI revision 2 |
| every route reads a request body | `aowlspt/json` — `field`, `each`, `count` |
| every route writes one back | `arr`, `objOf`, `envelope`, `failure` |
| a profile must keep fields the mod does not model | `Doc` / `List` member-wise editing |
| one mod tells another a raid ended | `broadcast` / `onEvent`, now delivered |
| a sweep must run whether or not a request arrives | `everyMs`, off the request threads |
| a config value read one way on one host and another on another | `ConfigValue.asText`, unquoting on every host |
| a mod that adds a table the database has never held | `dbWrite` creating a path instead of refusing |

```
aowl build-mod mods/tarkov
```

## Writing an endpoint

```nim
proc onKeepAlive(url, body, session: string): string =
  var o = obj()
  put(o, "msg", "OK")
  put(o, "utc_time", nowSeconds())
  result = envelope(o)

discard serve("/client/game/keepalive", onKeepAlive)
```

`envelope` is not optional. Every `/client/*` endpoint answers
`{"err":0,"errmsg":null,"data":...}`, and the client reads `err` before it looks
at anything else — a route returning bare data gets a client that treats a
perfectly good response as a failure, with a 200 on both sides and nothing in
either log.

## What is implemented

| | |
|---|---|
| **Login** | config, start, version validate, keepalive, logout, server list |
| **Profiles** | list, create, select, nickname validate/change, voice, persistence |
| **Static tables** | items, globals, handbook, customization, locales, languages, settings, quests, achievements, prestige |
| **Inventory** | move, split, merge, transfer, remove, fold, toggle, tag, swap, examine |
| **Traders** | settings, assorts, per-trader prices |
| **Trading** | buy from a trader, sell back at the handbook price |
| **Flea market** | offers built off the handbook and the assorts, search and filter, the player's own offers — add, buy, remove |
| **Quests** | accept, hand over, complete, fail — with the conditions actually evaluated, and reward experience |
| **Hideout** | area upgrade start and complete, toggle, slots |
| **Hideout production** | recipes, starting a craft against its requirements, collecting it, continuous production |
| **Skills** | `Common` and weapon `Mastering`, taken from the raid as a delta and run through the game's own curve |
| **Raids** | configuration, weather, match start, **match end**, and generated loot: static containers, loose loot, ammo boxes and weapon presets expanded |
| **Bots** | generation by role and difficulty, out of the database's bot tables |
| **Scavs** | a second character per profile — identity, appearance, cooldown, regenerate — sharing the PMC's stash rather than copying it |
| **Mail** | dialogs, messages, attachments, **and redeeming them** |
| **Insurance** | premiums off the handbook, and returns that survive a restart |
| **Menu** | notifier channel, mail, friends, builds, flea market, insurance, hideout tables |

The profile is held **as JSON text** and edited member-wise. A typed model would
have to name several hundred fields to avoid dropping any — and the day the
client adds one, a typed model silently deletes it from every profile it saves.
Text plus a merge keeps what it does not know about.

## Money is stacks, not a balance

Paying 25,000 roubles from a stack of 500,000 edits that stack; paying from
three stacks of 10,000 consumes two and edits the third. A server that treats
currency as a number and rewrites one stack loses the rest of the player's
money, silently, because the client believes whatever the diff says.

So `takePayment` verifies every stack in the request before it takes anything.
There is no transaction to roll back, which means the transaction has to be
"check it all, then act".

The same rule — check everything, then take — is what starting a hideout craft
does with its inputs, and what the flea market does with a purchase. There is no
transaction to roll back anywhere in this server, so each of those places
resolves the whole requirement to a list of (stack, amount) pairs, verifies
every one, and only then removes anything. The flea does not get a second,
laxer copy of the rule; it calls `takePayment` in `emu/trading.nim`.

The same reasoning runs through the rest of it:

- An item the server gives you gets a **real cell** in the stash, found by a
  first-fit scan of an occupancy map built from what is already there. An item
  with no position, or one overlapping another, is drawn on top of it and cannot
  be picked up — which looks exactly like never having been given it. If the
  stash is full the purchase is refused.
- Selling something the handbook has no price for is **refused**, not paid at
  zero. The item is gone either way.
- A hideout upgrade that was never started cannot be completed. A repeated
  `HideoutUpgradeComplete` is either a replayed request or a client out of step,
  and granting it is a free level.
- Collecting a craft **removes the record in the same step that puts the output
  in the stash, and only if the output actually landed** — a full stash refuses
  the collection rather than eating the craft. A craft that can be collected
  twice is free items.
- A craft's progress is *derived* — `now - StartTimestamp`, clamped to the
  duration — rather than counted. A server switched off for a week comes back
  with the craft finished exactly once, and agrees with a server that was
  running the whole time.
- A redeemed mail attachment keeps its own `_id` when it crosses into the
  profile, so "is this already in the inventory?" is a complete answer to "has
  this already been redeemed?". And the mailbox is not edited during the move:
  the removals are staged and committed only once the profile that now holds
  the items has been saved. A crash in between leaves the reward sitting in the
  mailbox where the player can see it.
- Skills taken from a raid are the **delta** the client reports, not the numbers
  it reports. Taking the numbers means skills are whatever anyone who edits
  their client says they are; ignoring them means skills never move. The delta
  is the raid's claim about how much work was done — which is fair, the server
  was not there — and the curve and the cap that turn it into progress are the
  server's, so a client claiming a thousand points of Endurance gets the same
  answer as one claiming a hundred.
- The scav's stash is **not stored**. "Shared stash" implemented by copying the
  PMC's stash into the scav document and back is two writers with no lock, and
  its failure mode is a stash that quietly diverges. What is stored under
  `scav.<pmc id>` is only what is the scav's; the PMC's stash is spliced in at
  read time. There is one copy, so there is nothing to diverge from.

## What comes out of the database, and what happens without one

Every static table is a `dbRead` with a fallback. A server started with a live
database dump serves the real items, traders and locales; a server started with
nothing serves valid empty tables — and the client still reaches its menu,
creates a profile, and enters a raid.

That is deliberate, and it is what makes the emulator testable at all. A server
that only works with a 40MB item table present cannot be started for the first
time, cannot be tested, and greets a new user with a wall of errors.

One consequence is worth naming: `itemStackLimit` returns **zero for "unknown"**,
not one. Treating an unknown template as a stack limit of one makes every merge
fail on a server with no item table — which was a real bug, caught by the test
below, and fixed by making "I don't know" a different answer from "one".

## Testing

```
aowl test
```

runs `emutest`, which drives the client's boot sequence over the wire — zlib
framing included — in the order the client uses it, section by section:

```
Boot · Creating a profile · Selecting and starting · Static tables · Traders
Inventory · Trading · The flea market · Quests and the hideout · Production
Redeeming a reward · The floor of a raid · A raid · Skills · The scav · Bots
Mail and insurance · Across a restart
```

```
ok    no profiles on a fresh install
ok    create returns a profile id
ok    the duplicate nickname is refused
ok    the starting roubles are in the stash
ok    split reports the new stack
ok    merge deletes the source
ok    and the encyclopedia remembers it
ok    a move of an item that is not there is a warning, not a 500
ok    buying takes the money and gives the item
ok    and the payment came out of the right stack
ok    and the new item was given a position in the stash
ok    a payment larger than the stack is refused
ok    the map hands over its loot
ok    the raid result is accepted
ok    and the raid experience stuck
ok    a raid result for another profile is refused
ok    the craft survived the restart, with its clock intact
ok    the redeemed reward is still in the stash
ok    and it is not back in the mailbox as well
```

The run prints its own total, and the total moves as endpoints are added, so it
is not quoted here — the number in a stale document is worse than no number.
What is worth quoting is that the count is the *whole* count: a check that could
not run is reported as skipped, not omitted.

The database is `tests/fixtures/emu-full.json` — a trader with an assort, a
handbook price, a stash grid, plus what the flea, the hideout, the loot tables
and the quests need, in one document, because the checks for those cross into
each other. The narrower fixtures beside it (`emu-db`, `emu-market`,
`emu-hideout`, `emu-loot`, `emu-quests`) exist for driving one area by hand.
Without a fixture those checks are *skipped* rather than failed: answering out
of the fallbacks is a supported way to run, and it is the way a first-time user
runs.

Two of those checks carry more weight than the rest.

**Order.** These endpoints depend on each other. Tested individually they would
pass against a server that cannot actually get a player into the menu.

**The restart.** Halfway through, `emutest` kills the backend and starts it
again against the same root. Everything after that point runs against a server
that has forgotten everything except what it wrote to disk — which is the only
way to tell a working profile store from a working in-memory cache.

## What it is not

It does not have the game's content. Traders sell what the database gives them,
maps have the loot the database has, quests are the quests in the database, bots
wear what the bot tables dress them in. A server with no database serves valid
empty tables and the client still reaches its menu.

Two earlier refusals in this file are no longer true and are recorded here
because a removed limitation is worse than a missing one — somebody designs
around it:

- **Redeeming a mail attachment used to be refused.** It is implemented, in
  `emu/redeem.nim`. The half that was missing was never the container; it was
  the ordinary inventory move working across the mailbox boundary, and that is
  what was built. The identity and ordering guarantees are above.
- **Reading a hook's arguments used to be refused** on the client side. It is
  implemented too — `hookArgs`, with suppression — and the remaining limits
  (four arguments, a replacement that must match the declared return type) are
  in [MODDING.md](MODDING.md) and [IL2CPP.md](IL2CPP.md).

What is genuinely not evaluated is named in the source rather than faked. The
clearest case is quest conditions: `distance`, `weapon`, `daytime`, `equipment`
and the other qualifiers inside a `Kills` condition. When one is present and
non-empty the kill is **not credited from the raid's victim list at all**,
because crediting a kill whose qualifier could not be checked hands out progress
that was not earned. Time limits are not evaluated either.

The distinction that matters: those are *content*, and they belong in mods —
including in this one. The pipeline underneath them is finished and tested.
