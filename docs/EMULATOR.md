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
| **Traders** | settings, one trader or all of them, assorts, per-trader prices, flea price list |
| **Trading** | buy from a trader, sell back at the handbook price, and the loyalty level that turnover earns |
| **Flea market** | offers built off the handbook and the assorts, **sharing the cap between them**, search and filter that can reach a template the cap did not, the player's own offers — add, buy, remove, and **renew**, bounded by the database's own `maxRenewOfferTimeInHour` and free, because this market takes no listing fee either |
| **Quests** | accept, hand over, complete, fail — with the conditions actually evaluated, and reward experience |
| **Repeatable quests** | the dailies, the weekly and the scav's — generated out of the database's own skeletons and reward budget, derived per period rather than stored, with the reroll priced by the table |
| **Hideout** | area upgrade start and complete — against the stage's own requirements, the area's own gate and the last stage the table has — toggle, slots |
| **Hideout production** | recipes, starting a craft against its requirements — including the `Resource` it draws out of the area's own slots and the quest, loyalty and skill that unlock it — collecting it, continuous production |
| **The scav case** | `scavRecipes` started, paid for and rolled at the moment it starts: a count per rarity out of the recipe, and the templates out of `_props.RarityPvE` joined against the handbook |
| **Skills** | `Common` and weapon `Mastering`, taken from the raid as a delta and run through the game's own curve |
| **Raids** | configuration, weather, match start, **match end**, and generated loot: static containers, loose loot, ammo boxes and weapon presets expanded |
| **Bots** | generation by role and difficulty, dressed out of the database's own loadout, mod and ammo tables, with the per-slot chances honoured — and **carrying** what `inventory.items` and the `generation.items` counts put in their rig, pockets and pack |
| **Scavs** | a second character per profile — identity, appearance, cooldown, regenerate — sharing the PMC's stash rather than copying it, and moving Fence's standing at a configured rate |
| **The gym** | `hideout.qte`'s workout minigame — the entry's own requirements, energy and hydration spent per hit and per miss, and Strength paid out of the `results` block |
| **Customisation** | the wardrobe (`CustomizationSet`, validated against `templates.customization`) and the hideout's decorations — floors, walls, ceilings, shooting-range targets, mannequin poses and the shooting range's score, out of `hideout.customisation` |
| **Mail** | dialogs, messages, attachments, **and redeeming them** — and, since commit `2ea0559`, the inbox itself: **read, pin, unpin and remove** are real handlers rather than the `onEmptyObject` stubs they were, so marking a message read marks it read |
| **Insurance** | premiums off the handbook, buying the cover, and returns that survive a restart — with the covering letter **in the trader's own words**, resolved out of `traders.<id>.dialogue` through the locale the client last asked for |
| **Health** | healing and eating between raids, bounded by the damage and by what the item has left — and **treatment at a trader**, priced from `globals.config.Health`: hit points, energy, hydration and the effects a trader will remove, times that trader's `heal_price_coef` |
| **Repair** | durability on the item, restored at a trader for the template's price or with a kit for the kit's charge — and a permanent bite out of the maximum either way. A trader's `ExcludedIdList` and `ExcludedCategory` are both honoured, the second by a walk up the handbook tree |
| **Notes and markers** | the player's notes on the profile, and map markers on the paper map that carries them |
| **Achievements** | awarded, not merely listed — and only ones every condition of which was actually evaluated |
| **Builds** | weapon, equipment and magazine presets — saved, replaced, deleted, and kept beside the profile |
| **Personal** | the wishlist, favourites, pins and the hotkey bar |
| **Menu** | game mode, profile status, chat server, notifier channel, mail, friends, builds, flea market, insurance, hideout tables |

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

And a payout goes **into the stacks that are already there**, up to the
template's `StackMaxSize`, before it opens another one. A server that opens a
fresh stack per payout fills a stash with change: a soak of 200 play cycles
ended with 407 loose items in a stash that started with five, and average
request latency tracked the profile document from 797 µs to 105 ms. The
invariant `tools/soak.nim` holds it to is that the money is in the fewest
stacks it will go in — `ceil(total / StackMaxSize)`, exactly.

## The request does not get to do the arithmetic

Neither the price nor the count in a request is believed:

- **Selling** is priced by the handbook and counted against the item's own
  `StackObjectsCount`. One water bottle sold as five used to pay 75,000 for a
  15,000-rouble item, `err:0`, no warning. Selling part of a stack now leaves
  the rest of it rather than deleting the lot and paying for the part.
- **Buying from a trader** is priced by the offer's own `barter_scheme`,
  matched by template and multiplied by the count asked for, and the count is
  bounded by the assort's stock. `takePayment` alone cannot do this: it checks
  that the stacks named hold what the request claims, and has no idea what the
  thing being bought costs — so a body naming one rouble bought the rifle.
- **Buying on the flea** is priced by the offer, for the same reason.
- **A quest handover** credits the condition by what the profile holds, not by
  the count in the body. `count: 9999` on one item used to finish a "hand over
  five" condition and pay its reward.
- **A repair** is priced and sized by the item, not the request. A body asking
  to restore 9999 points of a 40-point hole pays for 40, and the price comes
  from the template's own `RepairCost` and the trader's loyalty coefficient. A
  kit repair is bounded twice over: by the damage, and by what the kit's
  remaining `Resource` can actually pay for.
- **A hideout upgrade** resolves the stage's `requirements` — the items, the
  area levels, the trader loyalty and the skill levels, plus the area's own
  `requirements` when `enableAreaRequirements` says they apply — verifies all of
  them and only then takes anything. It used to read none of them: the entire
  hideout was free, and instant, because the `completeTime` it wrote was never
  read back. **Every requirement in full, or the upgrade is refused naming what
  is missing** — the same rule a craft gets, out of the same resolver. It was
  briefly relaxed to a partial take, because against a real `hideout.areas`
  twenty-five of the twenty-eight areas ask for items at level 1 and a new
  profile has none of them, so refusing outright is a hideout a fresh profile
  cannot start. That is a fact about the **economy**, and the place it is
  answered is `tools/realtest.nim`, which now buys what a trader or the flea
  sells and brings the rest home from a raid. `emu/hideout.nim` argues it.
- **A repeatable quest's reroll** is priced by the skeleton's own `changeCost`,
  not by the request, which carries no price at all. The set's first
  `freeChanges` rerolls of a period cost nothing and the count of those used is
  the one thing about a daily this server stores; everything else about one is
  derived from the profile id and the clock. A quest that has already been
  accepted cannot be rerolled, because the player has progress on it.
- **`ApplyInventoryChanges`** is the client handing back whole item documents
  and saying "make it look like this", which is the one request that must not be
  believed as sent. Only the position and a handful of cosmetic `upd` members
  are taken; an entry naming a different template or a different stack size is
  refused outright.

The same rule — check everything, then take — is what starting a hideout craft
does with its inputs, and what the flea market does with a purchase. There is no
transaction to roll back anywhere in this server, so each of those places
resolves the whole requirement to a list of (stack, amount) pairs, verifies
every one, and only then removes anything. The flea does not get a second,
laxer copy of the rule; it calls `takePayment` in `emu/trading.nim`.

## A bounded list filled from one source is not a bound

The flea market is capped at 600 offers, which is a response size and a sensible
one. The trader assorts were poured into it first and the generated player
offers ran afterwards, against a list that was already full — so against a real
39 MiB database the flea was **600 rows of Prapor, Therapist and Skier stock and
not one generated offer**. No trader sells a bolt or a screw nut at any loyalty
level, in any currency, in any barter; neither, then, did the flea. Most hideout
stage materials could only be got by raiding for them. Nothing said so: every
request answered `err:0` with a full page of offers on it.

The cap is now shared — half to the traders, half to the handbook, either side
taking the slack the other cannot use — and the traders' half is filled a pass
at a time across all of them rather than in document order, which is the same
fault one level down: three traders filling the share and the other nine absent
from the flea entirely. The generated half is spread across the whole handbook
rather than taken off the front of it, which is the same fault a level below
*that*: the handbook is written in category order, so a prefix is a market made
entirely of ammunition.

And a cap applied before the filter is the same bug wearing a hat. A search
naming one template — `linkedSearchId`, or an item id in `handbookId`, which is
the client's "offers for this item" button — now materialises what the rebuild
did not reach: every currency-priced trader offer for it, plus one generated
offer if the handbook prices it. Otherwise the answer to "who is selling this?"
is decided by where the cap happened to fall. Those offers go into the same
cache the search reads, because the client's next request names the offer id it
was just shown.

The shape is not unique to the flea and the other two places it appears were
fixed with it. A raid's loot budget was handed whole to the static containers
and the loose loot ran on what was left, so a map whose crates could spend it
had no jackets and no floor spawns; it is halved the same way. A bot's mod
budget was spent in slot order, and the 14 slots are ordered with the armour and
the helmet ahead of every weapon — so plates and attachments could spend the
allowance before `FirstPrimaryWeapon` was reached, and the loop *stopped there*:
a bot with no gun, from data that says nothing of the sort. Weapons and worn
gear have separate budgets now, and the equipment item itself is never refused
for want of one. The same applies to what a bot carries: the rig, the pack and
the pockets each get an even share of the loot budget rather than the rig
getting all of it.

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
- The mailbox is **bounded**. An emptied message is kept — `rewardCollected`,
  no items — so the player keeps the record of where the reward came from, but
  only the most recent one per dialog, and only for `mailKeepHours`. Nothing
  removed one at all until it was measured: `mail.<id>` grew 267 bytes per
  withdrawn-and-collected flea offer, monotonically, for the life of the
  profile. A message still holding items is never dropped at any age or count:
  the mailbox is the only place those items exist.
- A redeemed mail attachment keeps its own `_id` when it crosses into the
  profile, so "is this already in the inventory?" is a complete answer to "has
  this already been redeemed?". And the mailbox is not edited during the move:
  the removals are staged and committed only once the profile that now holds
  the items has been saved. A crash in between leaves the reward sitting in the
  mailbox where the player can see it.
- **Nothing is created over a read that failed.** "There is no such key" and
  "the key is there and could not be read" used to be the same answer, and the
  recovery for the first — start from empty and write — destroys the second. A
  mailbox holding an unredeemed reward, a flea offer holding items that are out
  of the profile, the saved builds, the insurance queue and the scav record were
  all one transient read error away from being replaced with an empty one, with
  no error anywhere. `emu/store` makes the distinction; a read-only path still
  takes the empty answer and logs it, and a path about to write refuses.
- **An id issued after a restart can never be one an earlier run could have
  issued.** The run number is persisted and advanced before the first id is
  handed out, and a server that cannot establish it does not start. It used to
  be seeded from `nowMs`, which the ABI defines as milliseconds since *host*
  start — so two runs against one store issued the same ids and the second one
  gave a player's rifle the id of their own stash.
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

  One consequence of that is a **refusal, and it is a design refusal rather
  than a data one**: "sell all to Fence" on the scav's results screen
  (`SellAllFromSavage`) is answered by name and declined. Nothing about it is
  missing from the database — the handbook prices are loaded, Fence is in
  `traders` with his `PriceModifier` and his loyalty levels, and `emu/mail` can
  pay roubles. What is missing is *the items*: `endScavRaid` has already moved
  everything a surviving scav carried into the PMC stash, in real cells, at
  `/client/match/local/end`, which the client posts before it draws the screen
  the button is on. And because the scav has no stash of its own, selling
  "everything in the scav's inventory" against the document this server serves
  would sell the player's whole stash. The request's one member, `TotalValue`,
  is the client's arithmetic and is logged rather than paid.

## Nothing may contain itself

The inventory is a tree the client walks from the stash down, and three requests
could break the tree from one ordinary-looking body with `err:0` and no warning.

A `Move` naming the same item as its own destination wrote `parentId: X` onto X.
The same request naming the **stash** and something the stash holds made the
root its own descendant — and there is no way back from that, because the drag
that would fix it has to reach an item the client can no longer draw. So a move
now walks up from the destination and refuses if the item being moved is
anywhere on that path. `Swap` is two moves in one action and gets the same check
on both.

A second hole sat beside that one and the cycle check does not see it: **a
profile is built on five containers, and putting one of them inside another
closes no loop.** The stash inside the *equipment* root is not a cycle — the
walk up from the destination reaches the equipment root, finds no parent and
says the move is fine — and it is exactly the same damage, because the client
still draws the stash by walking down from a root that is now somebody's child.
The five are precisely the items with **no parent**, which is how `emu/market`
has always identified them, so the check falls out of that rather than out of a
list of ids: an item with no parent does not get one. `ApplyInventoryChanges`
had this closed; `Move` and `Swap` did not, and now do.

And `RagFairAddOffer` would list the stash itself. Listing takes the item and
everything under it out of the profile; everything under the stash is
everything. Only what is *in* the stash may be listed now, which is one walk up
`parentId` — and it falls out of that rule that the five containers a profile is
built on (they are exactly the items with no parent) and everything equipped
(it hangs off the equipment root, not the stash) are refused too, without the
market having to know any of their ids.

## One writer at a time, nearly

Every route here is read-modify-write over the whole profile document, and the
backend answers on a pool of threads. Six concurrent purchases on one profile
all answered `err:0`; three rifles arrived and three purchases were thrown away.
Nothing duplicated and no money went missing — each request's arithmetic was
self-consistent — and the client was still told three things happened that did
not.

Every save now stamps a per-profile counter, and a request checks the counter
has not moved since it read the document. Moved means this request has been
working from a document that no longer exists, and the client gets a failure it
can retry instead of a success it cannot.

A counter and not a re-read, which was the obvious first attempt: the store
replaces a file atomically, and opening it for reading immediately beforehand
made the replace fail with a sharing violation — every split and every purchase
refused. A fix for a silent discard cannot be a new way to lose the write.

**That narrows the window and does not close it**: two writers can still both
read the counter, both pass, and both write. Closing it means the host
serialising item-event handling per profile, which is a change in `backend/` — a
mod cannot do it, because there is no lock in the mod API and there should not
be one. A mod holding a lock across a request is a mod that can stop the
server.

## What comes out of the database, and what happens without one

Every static table is a `dbRead` with a fallback. A server started with a live
database dump serves the real items, traders and locales; a server started with
nothing serves valid empty tables — and the client still reaches its menu,
creates a profile, and enters a raid.

That is deliberate, and it is what makes the emulator testable at all. A server
that only works with a 40MB item table present cannot be started for the first
time, cannot be tested, and greets a new user with a wall of errors.

The other half of that is a habit rather than a mechanism: **a field name is
checked against a real database, not against the fixture.** A fixture is written
by whoever wrote the code that reads it, so it agrees with the code by
construction, and a name read wrong deserialises to a type default with nothing
logged. Three names in this pass would have been guessed wrong and were read off
a 41 MB dump from `aowl importdb` instead — the bot chance tables are
`weaponMods` and `equipmentMods` rather than one `mods`, a mod slot appears in
either casing in stock data, and an equipment slot holds a weight map rather
than a list.

Where the live dump comes from is [IMPORTDB.md](IMPORTDB.md):
`aowl importdb --from D:\SPT` converts an SPT installation into the database
this reads — 4,673 templates, 12 traders, 558 quests, 19 maps, 39.40 MiB
(41,313,127 bytes) — in **2.8 s** on the development machine, with a self-check
over the invariants above. Part of that self-check is `checkReadPaths`
(`tools/importdb.nim:679`), which walks the 29 database paths `mods/tarkov`
reads with a literal spelling and asserts each one is in the document it just
wrote, rather than asserting it in prose. It reads the
install and never writes to it, and what it produces is BSG's data by way of
SPT's: it is not committed here and not in a release.

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
Inventory · Nothing may contain itself · Trading · Trader loyalty
The flea market · Quests and the hideout · Production · Redeeming a reward
The floor of a raid · A raid · Skills · The scav · Bots · Mail and insurance
Buying insurance · Healing and eating · Healing at a trader
Repair and durability · Notes and map markers · The client's own batch
Achievements · Fence and scav karma · What a hideout upgrade costs
What a bot is wearing · The dailies · The sky · The menu's own state
The scav case · The gym · Customisation · The hideout's wardrobe
Across a restart · Kills credited from the raid's own victim list
The inbox: read, pinned and removed
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
ok    the craft survived the restart
ok    with its clock intact
ok    the redeemed reward is still in the stash
ok    and it is not back in the mailbox as well
ok    moving the stash into something the stash holds is refused
ok    and the stash still has no parent
ok    listing the stash itself on the flea is refused
ok    and costs exactly the premium that was quoted
ok    and the loyalty level it earns is derived from them
ok    an offer above the player's loyalty level is refused
ok    and the barter it would have cost is untouched
ok    and the part is full, not over-healed
ok    and the kit is down by exactly what it healed
ok    the insured kits came back once the cover matured
ok    and only once
ok    the rifle came home with the durability the raid left on it
ok    and the price was the item's arithmetic, not the request's count
ok    and the repair cost it a point of its maximum, permanently
ok    and the kit paid two units a point for class 4 armour
ok    and a kit spent to nothing is gone rather than left at zero
ok    a batch that would change a stack size is refused
ok    and the money is exactly what it was
ok    the achievement whose condition is met and checkable is awarded
ok    the one whose condition this server cannot evaluate is not awarded
ok    by exactly one extract's worth -- the death cost nothing
ok    and it took exactly the stage's materials
ok    and it cannot be completed before its construction time
ok    filled to exactly the magazine's capacity
ok    a bot is carrying what its loot table says
ok    and a container with no room for it gets none rather than an overlap
ok    moving the stash into another root container is refused
ok    a trader refuses a whole handbook category, not just a leaf
ok    and each asks for exactly the extracts the level band names
ok    and asking twice gives the same two quests, not two more
ok    and costs exactly the skeleton's own change cost, not the request's
```

The run prints its own total, and the total moves as endpoints are added, so it
is not quoted here — the number in a stale document is worse than no number.
What is worth quoting is that the count is the *whole* count: a check that could
not run is reported as skipped, not omitted.

Before any of that, the mod checks itself. `emu/selfchecks` runs the module
self-checks at **load**, and a failure returns `ErrUnsupported`, which means no
routes and no first answer. They used to be four exported procs nobody called —
the flea's filter, sort and category walk, the loot generator over its own
fixture, the quest condition evaluator over literals, and the skill curve —
which is worse than not having them: they read like coverage in a review and
were none. There are **thirteen** now: those four plus `health`, `production`'s
scav case, `gym`, `customise`, `decorate`, `dialogue`, `insurance`, `raid` and
`bots`. Each is over code with no database, no host and no profile in it, which
is exactly the code `emutest` cannot reach precisely — everything `emutest` sees
has been through a route, a JSON encoder and the wire. The gate is the server
not starting, which every test and every developer's own run already waits for.

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

## The gap list

[EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md) is the gap list: every operation the
reference dump knows the client can ask for, against every route this mod
registers, in three buckets — served and shaped against the reference's own
DTO, served deliberately empty, and not served at all. It says how it was
derived, so it can be rebuilt from `reference/` rather than trusted.

The short version of it: of 211 client-facing operations, **129** are served and
shaped, **21** answer the right shape with nothing in it, and **61** are not
served. Those three numbers are derived, not stored — `tools/coverage.nim` reads
the routes `mods/tarkov/tarkov.nim` registers and puts a row in the *empty*
bucket only when every route it names is bound to `onNullData`,
`onEmptyObject`, `onEmptyArray` or `onTrue`. They were 127/24/60 here and
125/25/61 in the generated document; both were stale in different directions,
and the four mail routes of commit `2ea0559` (`read`, `pin`, `unpin`, `remove`)
are the difference between the generated pair and the current one.
What is still missing is content and multiplayer — group matchmaking and
friends, the SPT launcher's own routes, trader clothing (`trader/<id>/
suits.json` is not imported), cultist recipes (`hideout.production.cultistRecipes`
imports as a single entry carrying nothing but an `_id`), and random loot
containers.

Read that gap list's reasons sceptically, and it says so itself: **seven of the
operations it once recorded as blocked on data were closed by reading
`build/db/db.json` rather than by importing anything** — `RestoreHealth`,
`ScavCaseProductionStart`, `HandleQTEEvent`, `SetCustomisation`,
`HideoutCustomizationApplyCommand`, `SetMannequinPose` and
`RecordShootingRangePoints`.

The one item on that list that was **not the mod's to fix** is closed. The
notifier used to be a poll because the backend's accept pool was fixed and a
held connection took one of its threads for the whole wait; the backend is a
poller with a pool of *request* workers now, so a held connection costs a socket
and its buffer. `/client/notifier/getwebsocket/<session>` is upgraded and held,
and the mod pushes with `notifyPush` — the revision-5 host call — from
`emu/notify.notifyOrQueue`, falling back to the same queue and the same poll for any
client that has not upgraded. `emu/mail.deliver` is where the notification is
raised, so a quest reward, an insurance return and a sold flea offer all
announce themselves when the message is written rather than on the next
minute's sweep.

**Repeatable quests used to be the one item on that list deliberately left
rather than half-built**, and the reason was the importer: a generator needs a
skeleton per quest type, a pool of targets and a reward budget, and neither
`templates.repeatableQuests` — the reference's `RepeatableQuestDatabase`, with
`Templates`, `Data`, `Rewards` and `Samples` — nor SPT's own
`configs/quest.json` was among the sections `aowl importdb` imported. Both are
now, `docs/IMPORTDB.md` says exactly what each half carries, and `emu/repeatable`
is built against them: the dailies, the weekly and the scav's, generated per
period out of the database's own reward budget rather than out of a number
chosen here. Where the two tables do not decide something — what an `items`
reward is worth, what `rewardSpread` is a fraction *of*, how a level band
interpolates — the module says so in a comment and the shape is marked
*(unverified)*, rather than a rule being invented and then read back as data.

## What it is not, in one paragraph

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
clearest case is quest conditions: `daytime`, `weaponCaliber`, the weapon-mod
lists and the two equipment lists inside a `Kills` condition. When one of those
restricts anything the kill is **not credited from the raid's victim list at
all**, because crediting a kill whose qualifier could not be checked hands out
progress that was not earned — though the refusal now **names the clause** it
could not check, so a player whose quest will not finish is told which one
stopped it. Time limits are not evaluated either.

`distance` used to be on that list and is not any more, as of commit `2ea0559`:
the reference dump's `Victim` carries a `Distance` per kill, so the qualifier
can be checked and the kill can be credited. It mattered more than one clause
should — 191 of the 283 `Kills` sub-conditions in a real database carry
`distance` and `daytime` keys with neutral values (`>= 0`, `0..0`) that restrict
nothing, and refusing those refused almost every kill in the game.
`emu/questcond.killCredit` carries the counts and the reasoning.

The distinction that matters: those are *content*, and they belong in mods —
including in this one. The pipeline underneath them is finished and tested.
