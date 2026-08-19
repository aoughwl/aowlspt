# Three gaps in the mod API, and what closing them would cost

These are not a wish list. Each one is a wall a mod hit: `mods/pathtotarkov`
was written against the public API — `dbRead`, `dbPatch`, `onEvent`,
`broadcast`, `store`, `notifyPush` — and three features it was supposed to have
were cut because the API cannot express them. The mod shipped with the holes
documented rather than worked around (`mods/pathtotarkov/README.md`, "What the
API could not express"), and this file is the follow-up: what a fix looks like,
what it costs, and what could go wrong.

**Nothing in this repository has ever run against BSG's client.** That sentence
governs two of the three proposals below and is repeated where it bears on one,
because the difference between "the server has this fact" and "this fact is
true of a real raid" is exactly what these gaps are about.

Read in a hurry: **do gap 1 first**, it is a payload change with no ABI
consequences; **most of gap 3 is free** and rides along with gap 1's edit;
**gap 2 is the only one that is real work**, and its tidiest form has a cost in
the ABI watermark that is worth avoiding.

| | gap | cost | value | rank |
|---|---|---|---|---|
| 1 | `tarkov.raid.ended` carries only the profile | one broadcast payload in `mods/tarkov`; **no ABI change** | two mod features that are impossible today | **first** |
| 3 | `notifyPush` is unaddressable by a third-party mod | the same edit, plus ~20 lines of relay; **no ABI change** | makes a revision-5 facility reachable — on a delivery path nothing has ever confirmed | second |
| 2 | no `dbKeys(path)` | index change in `backend/jsondb.nim` + a host entry or a path form; possibly ABI revision 6 | every mod that iterates a table stops shipping a hard-coded key list | third |

---

## Gap 1 — `tarkov.raid.ended` says who, and nothing else

### What a mod hits, and where

Two lines broadcast it, and they are identical:

* `mods/tarkov/tarkov.nim:1020` — the scav path out of `onMatchEnd`
* `mods/tarkov/tarkov.nim:1120` — the PMC path

```nim
discard broadcast("tarkov.raid.ended", objOf("profile", p.id))
```

That is the whole event. A subscriber learns that *somebody's* raid ended and
must reconstruct everything else. `mods/pathtotarkov` reconstructs the location
by holding the last `tarkov.raid.configured` and matching it on the profile id
— `mods/pathtotarkov/ptt/state.nim:101`, `raidEndMoves`, whose docstring says
so — and `mods/icebreaker` does the same thing at `icebreaker.nim:617`.

Pairing recovers the location. It cannot recover **which exfil was taken** or
**whether the player survived**, and those are precisely the two rules
`mods/pathtotarkov` had to refuse: exfil-decides-destination and
die-and-go-home (`mods/pathtotarkov/README.md`, rows 3 and 5 of the "What
survived" table).

Pairing also has a defect nobody has hit yet because nobody has run two
profiles: the pending raid is a **single slot** (`pendingProfile`,
`pendingLocation`, `pendingSide` in `ptt/state.nim:88`). Two profiles in flight
and the second configuration overwrites the first, after which one of the two
raid-end events resolves to the wrong map or to nothing. A self-describing
`raid.ended` removes the pairing, and with it that whole class of bug, from
every mod that currently does it.

### What the server already knows at the moment it broadcasts

`onMatchEnd` at `mods/tarkov/tarkov.nim:981` computes all of this before it
reaches either broadcast:

| field | where it already is | free? |
|---|---|---|
| `profile` | `p.id` | already sent |
| `session` | the handler's own `session` parameter | **free** — and it is gap 3's whole fix |
| `location` | `raidLocation(body)`, already called at `tarkov.nim:1107` (`emu/quests.nim:503`, which tries `location` then the `serverId` prefix) | **free** |
| `exitStatus` | `outcome`, computed at `tarkov.nim:991` via `parseResult` (`emu/raid.nim:25`) | **free** |
| `survived` | `keepsGear(outcome)` (`emu/raid.nim:34`) — or, more honestly, `outcome == rrSurvived` | **free** |
| `side` | which of the two branches is broadcasting: `"Savage"` at line 1020, `"Pmc"` at line 1120 | **free** |
| `raidId` | `gRaidId`, set in `onRaidConfiguration` at `tarkov.nim:951` | **free** |
| `exitName` | **not read by anything today.** See below | not free |

So the claim in the mod's README — "about one line" — is **true for the
location and the outcome and false for the exit**. The location and the
survival flag are values already sitting in locals two lines above the
broadcast. The exit name is a field this emulator has never parsed.

### The exit, honestly

`reference/spt-4.1-surface.txt:9766` gives the 4.x request body:

```
EndLocalRaidRequestData
    prop String ServerId
    prop EndRaidResult Results
    prop LocationTransit LocationTransit
    prop IEnumerable<Item> LostInsuredItems
    prop Dictionary<String, IEnumerable<Item>> TransferItems
```

and `EndRaidResult` (line 9793) carries `Result` (the `ExitStatus` enum, line
12150: `KILLED`, `LEFT`, `MISSINGINACTION`, `RUNNER`, `SURVIVED`, **`TRANSIT`**)
and `ExitName`. `LocationTransit` (line 9889) carries `Location`,
`SptExitName`, `SptLastVisitedLocation` and `TransitionRaidId`.

Two things follow, and the second is the useful one:

1. **This emulator is reading a body shape it invented.** It reads
   `field(body, "exit")` and `field(body, "profile")` at the top level
   (`tarkov.nim:991`, `:992`), where the reference says `results.result` and
   `results.profile`, nested. `tools/emutest.nim:2016` posts
   `{"exit":"Survived","profile":{...}}`, so the tests confirm the emulator
   against the emulator's own guess. Nothing here has ever run against BSG's
   client, and this is one of the places that would show. Any patch that adds
   `exitName` should read defensively — `results.exitName`, then `exitName` —
   and the same defensiveness belongs on `exit` itself, which is a separate
   fix this document is not proposing.
2. **For a transit, the destination is in the body already.** If the client
   fills `LocationTransit.Location`, a mod does not need an exfil→destination
   table for the transit case at all; it needs one only for an ordinary
   extract, which is exactly the table upstream Path To Tarkov hand-wrote. The
   `TRANSIT` member of `ExitStatus` is the flag that says which case it is.

I did not verify that an exfil's `Name` in `base.exits[]` and a transit's
`name` share a namespace. They do not look like they do: exits on a stock
database are named `"Crossroads"`, `"UN Roadblock"`; transits are named
`"CUS_TRANSIT_9"`, and the second string only occurs elsewhere in the locale
table as a description key. **Unverified**, and a mod that maps exit names to
destinations must ship its own table until a raid says otherwise.

### The fix

Replace both broadcasts with one builder, next to the two handlers:

```nim
proc raidEndedEvent(p: Profile; session, location, exitName: string;
                    outcome: RaidResult; side: string): JsonObject =
  ## Everything the server knows at the moment a raid ends, said once, so that
  ## a subscriber does not have to reconstruct it from an earlier event.
  result = obj()
  put(result, "profile", p.id)
  put(result, "session", session)
  put(result, "location", location)      # may be "" -- see raidLocation
  put(result, "exitStatus", $outcome)    # Survived/Killed/Left/Runner/MissingInAction
  put(result, "survived", outcome == rrSurvived)
  put(result, "keptGear", keepsGear(outcome))
  put(result, "exitName", exitName)      # "" when the client did not send one
  put(result, "side", side)              # "Pmc" or "Savage"
  put(result, "raidId", gRaidId)
```

with `exitName` read as `field(body, "results.exitName")` falling back to
`field(body, "exitName")` and then `field(body, "locationTransit.sptExitName")`
— `field` is a dotted path (`aowl/src/aowlspt/json.nim:464`), so each of those
is one expression.

The same treatment belongs on `tarkov.raid.configured` at `tarkov.nim:954`,
which already broadcasts the whole configuration object and needs only
`session` added, so that a subscriber can address the player it is about to
hear about.

**Contract to write down alongside it, because subscribers will depend on it:**
every field is always present; `location` and `exitName` may be empty strings;
an empty string means "the client did not tell us", never "not applicable". A
mod that treats a missing key and an empty value the same way is the bug this
convention exists to prevent, and `mods/pathtotarkov`'s baseline story
(README, "The record that makes uninstalling safe") is what that class of
mistake costs when it lands in persisted state.

### Cost

**No ABI change.** `broadcast` already carries an arbitrary JSON object
(`aowl/src/aowlspt/server.nim:487`), delivered synchronously to every
subscriber but the emitter (`backend/aowlbackend.nim:1196`). This is a payload
edit in one mod: the builder above, two call sites, and the two lines that read
`exitName` out of the body. Call it thirty lines with the comment it deserves.

**Compatibility:** additive. Every existing subscriber reads `profile` and
ignores the rest; `mods/blackdivision/blackdivision.nim:573` and
`mods/icebreaker/icebreaker.nim:1317` keep working unchanged.

### What it would let a mod do

* **Exfil decides destination.** The rule Path To Tarkov is famous for. With
  `exitStatus == "Transit"` plus `locationTransit.location`, the destination
  comes from the client rather than from a table.
* **Dying sends you home.** One `survived` flag closes a whole row of that
  mod's gap table.
* **Delete the pairing.** `ptt/state.nim`'s pending-raid slot and
  `icebreaker`'s equivalent both stop being needed, and the two-profile defect
  above goes with them.
* Anything scoring a raid: a mod that pays out on survival, or penalises a
  run-through, currently cannot tell one from the other.

### What could go wrong

* **The field names are the emulator's, not BSG's.** `exitName` will be `""`
  on every raid if the real client nests it somewhere this patch does not look.
  That fails safe — a mod sees "the client did not tell us" and falls back to
  the location, which is what it does today — but it will look like the feature
  works until somebody plays a raid.
* **`location` is already fallible.** `raidLocation` (`emu/quests.nim:503`)
  tries two spellings and returns `""` for a third. Putting it on the event
  does not make it more reliable; it makes it *visibly* unreliable to more
  mods, which is an improvement, but a subscriber that assumes a non-empty
  location will now break in a new place.
* **Subscribers acting on `survived` change player-visible behaviour.** A mod
  that moves a player home on death is a mod that moves them wrongly if the
  outcome is misread. `parseResult` maps an unknown string to `rrLeft`
  (`emu/raid.nim:32`), i.e. "survived enough to keep gear", so an unrecognised
  exit status will read as a live player. That default is right for the
  emulator's own use and is a trap for this one; the event should carry the raw
  string too, so a mod can tell "Left" from "we did not recognise this".

---

## Gap 3 — `notifyPush` cannot be addressed by anyone but the game server

### What a mod hits, and where

`notifyPush(session, payload)` (`aowl/src/aowlspt.nim:1346`) takes a **session
id**. Every event a mod can observe names a **profile id** — `raid.configured`
carries `profileId` (`emu/raid.nim:270`), `raid.ended` carries `p.id`. The host
API has no profile→session call and no session enumeration
(`abi/aowlspt_abi.h`, the full entry list ends at `notify_push` on line 561).
The mapping exists, but it is `mods/tarkov`'s private store:
`emu/sessions.nim:53` (`profileFor`) and `:86` (`boundSessions`) — a module in
one mod, persisted under that mod's store key `"sessions"`, not API.

So the revision-5 notifier is reachable only by the mod that owns the request
layer, which is one mod. `mods/pathtotarkov` says the consequence out loud at
`pathtotarkov.nim:435-446`: the only session ids it can ever hold are the ones
that arrive on its own routes, which the game client never calls, so
`notifyOnMove` ships off and its self-test reports *"a push was refused as
unsupported: this host has no notifier"*.

### The fix, and it is not an ABI entry

**Who owns the mapping decides this.** `mods/tarkov` binds sessions because it
serves the login route; the backend knows only which *sockets* are open
(`backend/websocket.nim:218`, `wsRegister(session, ticket)`) and has no idea
which profile is behind one. Putting profile→session in the host would mean the
host learning a game concept from a mod that is free to redefine it — and the
first mod that replaces the login route would silently desynchronise it.
**The host should not hold this.** That rules out `notifyProfile` as a host
entry, and it rules out `sessionsFor(profileId)` as one.

What is left is a convention between mods, over the event bus that already
exists, and it is small:

1. **Sessions on the events that already fly.** `session` added to
   `tarkov.raid.configured` and `tarkov.raid.ended` — the same edit as gap 1.
   That alone makes a push addressable for the single most common case: "the
   player whose raid just ended". `mods/pathtotarkov` needs nothing else.
2. **A bind event.** `mods/tarkov` broadcasts `tarkov.session.bound`
   `{"session": s, "profile": p}` from `bindSession` (`emu/sessions.nim:61`)
   and `tarkov.session.unbound` `{"session": s}` from `unbind` (`:73`), plus
   one `tarkov.session.bound` per existing binding at load, after
   `ensureLoaded`. A mod that wants the mapping keeps its own copy, which is
   twenty lines and no new API surface. This is the same shape as the
   `aowlspt.locations.hello` / `aowlspt.locations.changed` protocol
   `mods/icebreaker` already publishes and `mods/pathtotarkov` already consumes.
3. **A relay, for mods that would rather not keep a copy.** `mods/tarkov`
   subscribes to `aowlspt.notify.profile` `{"profile": id, "payload": {...}}`,
   resolves it against its own bindings, and calls `notifyPush`. Delivery
   status comes back as `aowlspt.notify.result`
   `{"profile": id, "status": n}` — the reply-by-event pattern
   `host/common/modcontrol.nim:253` already uses. Events are delivered
   synchronously in subscription order (`backend/aowlbackend.nim:1196`), so a
   mod that wants the answer inline can subscribe before it emits.

Options 1 and 2 are worth doing. Option 3 is worth writing down and probably
not worth building until a second mod asks for it: a relay whose only caller is
a mod that could have kept twelve bindings in a `seq` is indirection for its own
sake.

### Cost

**No ABI change, no revision, no watermark question.** Everything above is
`broadcast` and `onEvent`, both revision 1. The work is inside `mods/tarkov`
and is additive: a mod that never subscribes never notices.

### What it would let a mod do

Push a notification to the player it just did something to — which is what
`notify_push` was added for, and which today only `mods/tarkov` can do. Concretely:
`mods/pathtotarkov` could turn `notifyOnMove` on and tell the player where they
now are, instead of broadcasting to other mods and hoping.

### What could go wrong, and why this ranks second rather than first

**The delivery this unblocks has never been observed to work.** `notifyPush`
reaches `wsPush` (`backend/aowlbackend.nim:740`), which needs a websocket the
game client opened; there is no such socket in the simulator
(`host/Aowlspt.Sim/aowlsim.nim:49`) and none inside the game process
(`docs/IL2CPP.md:100`). Nothing here has ever run against BSG's client, so the
*shape* of a payload the client would dispatch on is a guess — the mod's own
README says its payload "is this port's guess that no client has ever
acknowledged". Closing this gap makes the call **addressable**. It does not
make it **useful**, and nobody should implement it believing otherwise.

Second failure mode: a stale copy. A mod that caches `tarkov.session.bound` and
misses an `unbound` pushes to a session that has been rebound to a different
profile — which is a notification delivered to the wrong player. The relay in
option 3 does not have that problem, because it resolves at push time against
the one authoritative store; that is the argument for building it if the
convention gets more than one consumer.

---

## Gap 2 — there is no `dbKeys(path)`

### What a mod hits, and where

`db_get` takes a dotted path and returns that subtree's text
(`abi/aowlspt_abi.h:333`). There is no sibling that lists an object's members.
So "which maps does this database have" costs the whole `locations` table.
`mods/tarkov` measured what that is: **12.5 MB and 247 ms on a default import,
560 MiB and 10.8 seconds with loose loot** (`mods/tarkov/emu/raid.nim:52-56`,
citing `docs/IMPORTDB.md`) — and that measurement is why `/client/locations`
was rewritten.

The comment that survives that rewrite is the clearest statement of this gap in
the tree, at `mods/tarkov/emu/raid.nim:93-110`:

> Building the list needs the map *names*, and the plugin ABI has `db_get` for
> a dotted path and no sibling that lists an object's members … If the ABI ever
> grows a key enumeration, this cache stops being necessary and should go.

The consequence for third-party mods is uniform: **every mod that iterates a
table ships a hard-coded key list.** `mods/pathtotarkov` ships nineteen map
keys at `pathtotarkov.nim:91-99`, with a comment admitting a hard-coded list is
wrong the first time a map mod adds one; its honest alternative,
`discoverMaps: "scan"` (`pathtotarkov.nim:265-280`), does the full read and
prints what it cost. `mods/tarkov` pays the read exactly once and caches
(`emu/raid.nim:121`, `buildLocationIndex`), accepting that a map added after
the first `/client/locations` is invisible until restart.

### What it would actually cost in `backend/jsondb.nim`

The index is a good place for this and does not quite hand it to you.

`indexObject` (`backend/jsondb.nim:600`) already **is** a key enumeration: it
walks an object's immediate members, reads each name with `skipString`, skips
each value with `skipValue`, and records the byte range. Its own docstring says
it is "`findKeyIn`'s loop with the early return taken out". The names are read
and then thrown away — only `memberKey(objA, name)` survives, into a flat
`gMembers` table keyed by `objStart` + US + name (`jsondb.nim:591`). There is
no per-object member list, so answering "the keys of this object" from the
index as it stands means scanning every entry of `gMembers` for a matching
prefix, which is O(every indexed member in the document). That is the wrong
shape.

The change that makes it right is small: have `indexObject` also append each
name to `gNames: Table[int, seq[string]]`, keyed by the same anchor offset it
already uses for `gIndexed`, and drop that entry wherever `gIndexed`/`gDirty`
entries are dropped (`indexClear` at `:213`, `rebaseLocked` at `:366`, the
`IndexCeiling` path in `indexedFind` at `:690`). Then:

* **An object that has already been indexed answers from a table lookup.** Free.
  On a running server this is the common case: any mod that has read
  `locations.bigmap.base` has already indexed `locations`.
* **An object that has not** costs exactly one `indexObject` — which is the
  scan the *next* read into that object was going to pay anyway. So the first
  `dbKeys("locations")` costs a walk over the `locations` subtree's bytes and
  the reads after it get faster, not slower.

That walk is not free — `skipValue` steps over the bytes it skips, so it is
O(subtree size) even though it parses nothing. What it is *not* is the
13.5 MB `substr`, the copy across the ABI boundary into a mod's buffer, and the
mod-side parse that `dbRead("locations")` costs today. The answer for
`locations` is nineteen short strings; the answer for a table of *n* children is
about `sum(len(name)) + 3n` bytes.

Memory: the names are the only new allocation, and they are already in the
document. For a 100k-child table of 24-character Mongo ids that is ~2.7 MB held
in the index and ~2.7 MB returned — 200× smaller than the subtree, and still
not nothing. Two mitigations, in order of preference: (a) only cache `gNames`
for objects that were asked, rather than for every object the walk indexes;
(b) let `IndexCeiling` evict it, which it already does for `gMembers`.

### Two ways to expose it, and one of them is much cheaper

#### Option A — a path form, no ABI change at all

`db_get` takes a string. A path that begins with a reserved sigil answers keys
instead of a value:

```
dbRead("?keys locations")   -> {"ok": true, "raw": "[\"bigmap\",\"develop\",...]"}
```

**Cost: zero ABI surface.** No new entry, no revision, no watermark, and — the
part that matters — **it degrades correctly on an old host without a capability
test**: a backend that does not implement it walks the path, fails to find a
root member literally named `?keys locations`, and answers `ErrNotFound`, at
which point the mod falls back to the full read or its config list. A mod
cannot ask "does this host have it" and does not need to: it asks, and a
`NotFound` is the answer.

Against it: it is a side channel in a string, and the ambiguity is real —
nothing stops a JSON key containing anything, as `memberKey`'s own comment
notes (`jsondb.nim:591`: locale keys contain spaces, and "nothing stops a name
containing a dot"). A root member named `?keys locations` would be shadowed.
The root of an SPT database has a handful of members with names like
`templates`, `locations`, `globals`, `traders`; the collision is not credible,
but it is a collision and the doc comment must say so.

#### Option B — a host entry, ABI revision 6

```c
/* The immediate member names of the object at `path`, as a JSON array of
 * strings. Server side only. */
AowlStatus (AOWLSPT_CALL *db_keys)(void* ctx, AowlSlice path, AowlBuffer* out);
```

appended **after** `notify_push`, with `AOWLSPT_HOSTAPI_SIZE_REV6
((int32_t)sizeof(AowlHostApi))` and `REV5` re-pinned to
`offsetof(AowlHostApi, db_keys)` — the existing macros are written exactly that
way (`abi/aowlspt_abi.h:576-580`) and `tests/abi_layout.c` pins them to the
real offsets.

**This is where the proposal has to be checked rather than assumed, because
the watermark rule makes it expensive.** `size` is a watermark, not a version:
it says "there is a real function at every offset below this", it is raised
last, and it is never raised past a null entry (`abi/aowlspt_abi.h:582-604`,
`abi/aowlspt_live.h:112-137`). The hosts arm disjoint halves — the IL2CPP host
arms revisions 3 and 4 and stops at 216 because it has no notifier socket
(`aowlspt_live.h:116-123`); the backend arms 3, 4 and 5 by installing refusing
stubs for the live entries and only then raising `size`
(`abi/aowlspt_notify.h:92`); the simulator arms 3 and 4 with refusals and
deliberately stops below 5 (`host/Aowlspt.Sim/aowlsim.nim:47-51`).

The hosts that want `db_keys` are the backend and the simulator. The backend
reaches revision 6 for free — it is already at 5. **The simulator cannot reach
revision 6 without first claiming revision 5**, which means installing a
refusing `notify_push` it does not have. That is a legal move under the rule as
written (a capability a host lacks returns `AOWLSPT_ERR_UNSUPPORTED` rather
than misbehaving, and `size` still means "there is a function here that will
answer"), and it is exactly what `aowlspt_notify.h` does for the live entries.
But it has an observable consequence: `notifyReady()` is a size test against
the revision-5 boundary (`aowl/src/aowlspt.nim:1336`), so **`notifyReady()`
would start answering `true` in the simulator**, and `mods/pathtotarkov`'s
self-test line *"a push was refused as unsupported: this host has no notifier"*
would change to a push that returns `ErrUnsupported` from the host rather than
from the guard. Any mod that reads `notifyReady()` as "a push will be delivered"
— which the docstring warns against and which is nonetheless the natural
reading — changes behaviour under the simulator.

The client host is unaffected: it has no database (`db_get` and `db_patch` are
refused under `--side client`, `aowlsim.nim:51-56`) and would stay at 216.

So option B is **compatible** — it can be made without breaking a shipped mod —
but it spends the one thing the watermark design was protecting, which is the
simulator's ability to say an honest "no" to the notifier by size. If it is
taken, `aowlsim.nim`'s arming block gets a refusing `notify_push` and a comment
explaining that the sim now claims 5 in order to claim 6, and `docs/ABI.md`,
`docs/ARCHITECTURE.md:86` and `docs/MODDING.md:148` all need the row.

**Recommendation: take option A.** If a general key-enumeration entry is wanted
later it can be added as revision 6 with the path form kept as its
implementation, and by then there will be evidence about how often mods call it.
A gap closed without touching the ABI is worth more than the tidier design.

### The three answers a caller needs

Whichever form, the contract is the same and must be written down before the
first mod depends on guessing it:

| the path is | answer |
|---|---|
| an **object** | `AOWLSPT_OK`, a JSON array of the immediate member names, in document order, duplicates included if the document has them (a mod that dedupes should say so; the database has been wrong before) |
| an **array** | `AOWLSPT_ERR_BAD_ARG`, and `last_error` says "`x.y` is an array, not an object". Not an array of indices: `["0","1",...]` for 100k elements is a 700 KB answer to a question whose real form is "how long is it", and a caller that wanted indices already has the length from `db_get` |
| a **scalar** (string, number, bool, null) | `AOWLSPT_ERR_BAD_ARG`, same wording |
| **absent** | `AOWLSPT_ERR_NOT_FOUND`. Distinct from an empty object, which answers `OK` with `[]`. A wrapper that folds them together is the bug this distinction exists to prevent |
| an object with **100k children** | `AOWLSPT_OK` and a large answer: `sum(len(name)) + 3n` bytes, ~2.7 MB for 100k Mongo ids. One walk, no value copied, no subtree parsed. That is 200× cheaper than the read it replaces and it is still large enough that the doc comment must give the formula rather than call it cheap |

Mod-side wrapper, in `aowl/src/aowlspt/server.nim` next to `dbRead` (`:133`):

```nim
proc dbKeys*(path: string; into: var seq[string]): Status
  ## The immediate member names of the object at `path`.
  ##
  ## `ErrNotFound` means there is no such path -- which is not the same as an
  ## object with no members, and a caller that treats them alike will create
  ## something over the top of a table it failed to read.
  ## `ErrUnsupported`/`ErrNotFound` from a host that does not implement it:
  ## fall back to reading the subtree, and say what it cost.
```

`keys(whole(text))` already exists mod-side (`aowl/src/aowlspt/json.nim:362`) and is
what `pathtotarkov.nim:277` calls after the expensive read; the wrapper should
produce the same `seq[string]` so a mod can swap one for the other.

### What it would let a mod do

* Stop shipping key lists. `pathtotarkov.nim:91-99` deletes; `discoverMaps`
  stops being a setting with a cost attached and becomes the default.
* `mods/tarkov` deletes its `LocationIndex` cache and the restart-to-see-a-new-map
  caveat with it (`emu/raid.nim:104-110`, which asks for exactly this).
* Anything that wants to iterate `templates.items`, `traders`, `locales` — none
  of which is enumerable today at any price a mod is willing to pay.

### What could go wrong

* **Document order is not stable across a patch.** `dbPatch` merges and
  `mergeInto` (`jsondb.nim:963`) can move a member. A mod that relies on the
  order of the answer is relying on something nobody promised; the contract
  should say "document order, which may change when anything patches that
  object".
* **The names are a snapshot.** Between `dbKeys` and the `dbRead` of a child,
  another mod may patch. That is true of every read here and is not new, but a
  key list *looks* like an index and invites being cached; the doc comment
  should say it is not one.
* **`gNames` is a second thing to invalidate.** Everything that drops a
  `gIndexed` entry must drop the matching `gNames` entry, and a miss there is
  the exact failure mode the anchor-coordinate design exists to refuse — stale
  names against a re-anchored document. The three sites are `indexClear`
  (`:213`), `rebaseLocked` (`:366`) and the `IndexCeiling` branch in
  `indexedFind` (`:686`). Fail closed: on any doubt, re-index.
* **Option A's sigil could collide** with a real root member, as above.
* **Option B costs the simulator's honest `notifyReady()`**, as above.

---

## Ranking, by value per unit of work

1. **Gap 1 — the raid-end payload.** Highest value, lowest cost, no ABI. Two
   mod features that are impossible today become possible; a whole pairing
   mechanism and its two-profile defect disappear from two mods; the change is
   additive and cannot break a subscriber. The only caveat is that its most
   valuable field, `exitName`, is read from a body shape no raid has ever
   confirmed — which is a reason to write it defensively, not a reason to wait.
2. **Gap 3 — sessions on events.** Nearly free, and its cheap half is
   *literally the same edit* as gap 1: put `session` on the two raid
   broadcasts. The bind/unbind events are twenty more lines in `mods/tarkov`.
   It ranks below gap 1 only because what it unblocks — a push down a websocket
   nothing here has ever seen a client open — is unproven end to end.
3. **Gap 2 — `dbKeys`.** The most work and the only one that touches the
   backend's index. Its value is real and permanent — it is the difference
   between mods that describe the database and mods that hard-code it — but it
   is one afternoon in `jsondb.nim` plus a contract, not a line.

**Do gap 1 first**, because it is the only one of the three that converts
directly into player-visible behaviour, it costs a payload, and gap 3's useful
half falls out of the same edit.

## What is not worth doing

**`notifyProfile` and `sessionsFor` as host entries.** Both were the obvious
shape of the gap-3 fix and both are wrong: the profile→session mapping belongs
to whichever mod serves the login route, the host has no way to learn it that
does not involve believing a mod, and the backend's own registry is keyed by
session and knows nothing about profiles (`backend/websocket.nim:218`). Spending
an ABI revision on this would put a game concept in the host and would still be
wrong the first time a mod replaces the login route. The convention costs
nothing and cannot desynchronise, because there is only ever one store.

**And the standing caveat, which applies hardest here:** nothing in this
repository has ever run against BSG's client. Gap 3 makes a notifier
addressable without establishing that anything is listening, and gap 1's exit
field is read from a request shape taken from a surface dump rather than from a
raid. Both are worth doing because they cost almost nothing and because a mod
author currently cannot even *attempt* the feature. Neither should be described
as working until a raid says so.
