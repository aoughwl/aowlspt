# The mod registry

One file, `mods.json`, in one git repository: every mod that exists, and every
**list** that names a set of them. A list is a document, so "my raid night
setup" is a thing you commit, diff and send someone rather than a screenshot of
a folder.

`mods/manager` reads this file, resolves it against your own selection, and
serves the result under `/aowlspt/mods/...` while the game is running. It can
also **fetch a newer copy** from a URL — off by default, metadata only, and
refusing anything it cannot fully check; see "Refreshing from a URL" and "The
registry as its own repository" below.

```
registry/mods.json      the manifest: mods and lists
registry/README.md      this — the schema, and the resolution rules
registry/validate.nim   is a mods.json a mods.json? one implementation, two callers
registry/fakeregistry.py a registry server that is wrong on purpose, for testing
```

`validate.nim` is the load-bearing one. `aowl-regcheck --file` runs it for a
publisher and `mods/manager/mgr/refresh.nim` runs it on a fetched document
before it will adopt one — the *same code*, so a file that passes the
publisher's gate is a file the manager accepts, and a disagreement between the
two is impossible rather than unlikely.

Two properties everything below is arranged around:

- **Resolution is a function.** The same registry plus the same selection gives
  the same set of mods in the same order, on every machine, every run. Nothing
  depends on directory order, file timestamps or which mod happened to load
  first.
- **A failure is reported, never repaired.** A missing dependency does not
  silently enable something you turned off; a conflict does not get broken by a
  coin flip. The resolver excludes and says why, because a mod list that quietly
  becomes a different mod list is worse than one that refuses.

## The file

```json
{
  "schema": "aowlspt.registry/1",
  "registry": {
    "id": "aowl.registry.official",
    "name": "...",
    "description": "...",
    "revision": 2,
    "updated": "2026-08-18"
  },
  "mods":  [ ... ],
  "lists": [ ... ]
}
```

`schema` is checked. A reader that does not know the schema string refuses the
file rather than guessing at fields it has never seen — a half-understood
registry is how you get a list that loads five of your seven mods and tells you
everything is fine.

`registry.id` names the registry. It is what a log line and a refresh answer
use to tell two of them apart, so it is required.

`registry.revision` is a whole number that **goes up**, and it is the only
thing that orders two copies of the same registry. It is optional, and a file
without one is usable — but a reader then cannot tell a newer copy from an
older one, and the manager's refresh degrades to "take it or leave it": it can
never refuse a rollback, because it cannot see that one is happening. Bump it in
the same commit that changes anything else. `updated` is a date for people and
is not read by anything.

Everything a reader here has ever added is optional in exactly this way: an
older build ignores `revision` and works, and a newer one uses it. That is the
only kind of change `aowlspt.registry/1` can take without becoming
`aowlspt.registry/2`.

`mods` and `lists` are **arrays, not objects**. Order is meaningful for lists
(see below), and an array is what produces a readable diff when someone adds an
entry in the middle.

### A mod

```json
{
  "id": "aowl.blackdivision",
  "name": "Black Division",
  "author": "TacticalToaster (ported to aowlspt)",
  "version": "1.2.3",
  "description": "A hostile PMC faction of six roles ...",
  "pipeline": ">=0.1.0",
  "sides": ["server", "client", "sim"],
  "source":   { "kind": "intree", "path": "mods/blackdivision", "url": null },
  "artifact": { "dir": "blackdivision", "library": "blackdivision.dll" },
  "upstream": { "name": "WTT Black Division", "author": "...", "url": "https://..." },
  "license": "MIT",
  "download": null,
  "requires":  [ { "id": "aowl.morebots", "version": ">=1.0.0" } ],
  "conflicts": [ { "id": "some.other.mod", "reason": "both own bot brains" } ],
  "provides":  [ "aowl.capability.bottypes" ],
  "loadAfter": [ "aowl.morebots" ],
  "tags": ["bots", "content"]
}
```

| field | rule |
|---|---|
| `id` | reverse-DNS, and **it must equal the `guid` in the mod's own `exportMod`**. The registry does not get its own naming scheme: the id here and the guid the host loads are the same string, so a list entry and a log line can be matched by eye. |
| `name`, `author`, `version` | as the mod declares them. `version` is `MAJOR.MINOR.PATCH`. |
| `description` | one or two sentences: what it is, not how to install it. |
| `pipeline` | a semver **range** the mod needs from aowlspt itself, matched against `hostVersion()`. |
| `sides` | any of `server`, `client`, `sim`. Mirrors the mod's `sides = {...}`. |
| `source` | where the code is. `kind` is `intree` (this repository, `path` set, `url` null) or `git` (`url` set). |
| `artifact` | where the built library lands relative to the mods root: `<dir>/<library>`. This is the only field that lets the manager ask the host to load or unload a specific mod, so it is required. |
| `upstream` | the work this is a port of, when it is one. Credit, not machinery. |
| `license` | SPDX id where there is one; `null` when the upstream states none. `null` means *unknown*, not *unlicensed*. |
| `download` | `null`, or `{ "url", "sha256", "size" }` — all three, or none. `sha256` must be 64 hex characters and `size` the byte count. **Nothing in this repository fetches it**; see "The open question" below. |
| `requires` | hard dependencies: `{ "id", "version" }` where `version` is a range. |
| `conflicts` | `{ "id", "reason" }`. The reason is not decoration — it is what the manager prints when it refuses to load both. |
| `provides` | capability ids. Two enabled mods that provide the same id conflict, even though neither has heard of the other. That is how "two AI overhauls" is detected without every AI mod listing every other one. |
| `loadAfter` | soft ordering. Unlike `requires`, the named mod does not have to be present. |
| `tags` | free-form, for a UI to group by. Not used in resolution. |
| `internal` | optional, default `false`. **Presentation only.** Infrastructure a player has no business seeing: the settings index, the fallback browser page, an ABI experiment. The manager's player-facing panel omits the row; every diagnostic route still carries it, and resolution, load order and selection are untouched -- an internal mod is still resolved, still loaded, still required by whatever requires it. |
| `shipped` | optional, default `true`. **Distribution only.** Whether the built artifact can ever reach an install (`aowl payload` stages `mods/*`, so anything under `examples/` cannot). It is NOT a visibility flag: `aowl.textures` is `shipped: false` and is an ordinary player mod that simply has no artifact yet, while `aowl.settingshub` ships in every install and must never appear in the list. The two questions are independent; set both when both apply. |

#### Why `download` is null for everything here

Every mod in this registry is built from this repository by
`aowl build-mod mods/<name>`, and there is no published artifact to point at
yet. The alternative was to write a plausible-looking URL and a made-up
`sha256`, which would be a hash that verifies nothing and a link that 404s —
strictly worse than the empty field, because it would *look* checked.

The shape is in the schema anyway, and deliberately: a field cannot be added to
a format after something depends on the format not having it. What is **not**
here is anything that acts on it. `aowl-regcheck` checks that a `download`
block is well formed and then names every entry that has one; the manager's
refresh path refuses a fetched registry that carries one outright. See "The open
question" at the end of this file.

#### Why `aowl.perf` is in the registry and in no list

`mods/perf` has a directory under `mods/`, so it has an entry — a registry that
skipped it would not be a registry of every mod that exists, and `regcheck`
fails the build over exactly that. It is in no `lists` entry, which means every
selection this file can produce gives it `not-selected`.

That is the honest default for what it is. It changes shadow distance, LOD bias
and texture mip limits — things a person notices and then blames on whatever
they installed most recently — and its own `config.json` ships with all
twenty-three knobs off. A performance mod that arrives switched on and quietly
makes the game look different is the shape of complaint nobody can debug,
because the thing that changed is not the thing they turned on. It is one
`/aowlspt/mods/enable/aowl.perf` away for anyone who wants it, and the mod then
still applies nothing until its own config says to.

#### Why the mod manager is a mod in here, and what stops it being switched off

`mods/manager` is `aowl.manager` in the `mods` array, like everything else, and
it is the first entry of `aowl.list.core` — which every other list in this file
inherits. There is no `alwaysOn` field, and that was the choice, not an
oversight.

The manager had to go in for two reasons that are both about not lying. It is a
directory under `mods/`, so a registry that omitted it would be a registry that
does not, in fact, list every mod that exists — and `aowlspt-verify` says so out
loud, as *"installed mod(s) are not named in the registry; the manager cannot
enable or disable those"*. And a mod absent from the manifest has no row on the
panel, so the one component you would most want to see the version of is the one
component the panel cannot show.

The alternative on the table was a new schema concept — `"alwaysOn": true`, or a
`core` section outside `mods`. It was rejected because **nothing would honour
it**. The resolution rules above are implemented in `mods/manager/mgr/resolve.nim`
and the nine verdicts `verdictName` can return are exhaustive; a flag this file
declares and the resolver
has never heard of is decoration, and decoration in a manifest is worse than an
empty field, because it reads as a guarantee. The same argument that keeps
`download` null keeps this field out: a check that verifies nothing is worse than
no check.

So the guarantee is made out of the parts that already exist and are already
implemented. `aowl.list.core` is inherited by `vanillaplus`, which is inherited
by `raidnight`, which is inherited by `headless`; flattening (step 1) pulls the
parent's entries in ahead of the child's, so `aowl.manager` is present and
enabled in every selection this file can produce. Nothing needs a special case
to arrive at that, which is the point — it is the ordinary rules producing the
result, so it stays true when the rules are exercised rather than only when
somebody remembers the exception.

What that does **not** cover, and is worth writing down rather than discovering:
a user's own per-mod override (step 3) beats every list, so `aowl.manager` can be
explicitly disabled — and so can a *local* list that does not inherit
`aowl.list.core`, or a refreshed registry whose lists stop naming it. Resolution
then gives it `disabled` or `not-selected`, honestly, because the resolver has
no special cases and should not grow any.

The rule therefore lives where it can be carried out, in three places, and all
three are in `mods/manager` rather than in this file:

1. `routeDisable` refuses to set the override at all, and says why.
2. `applySelection` will not put its own guid in the unload list — the door the
   routes do not cover, reachable from a hand-edited store or a list that simply
   stops naming it.
3. `selectionDocument` always names it in `aowlspt-selection.json`, whatever the
   resolution said. **This was missing**, and it was the one that mattered most:
   the first two protect the *running* process, and the file protects the next
   start. A resolution without the manager in it wrote a `load` array without
   the manager in it; `modhost` honours the file to the letter, so the manager
   did not come up, and with it went every route that could have put it back.
   The host cannot refuse that document — it refuses an *empty* `load` for
   exactly this argument, but it has no way to know which of ten ids is the
   manager. The manager does, so it writes it.

`provides: ["aowl.capability.modmanager"]` is here for the ordinary reason — a
second mod claiming to manage the mod list conflicts with this one under step 8,
and is reported rather than silently layered on top.

#### Version ranges

Small on purpose, because every operator here has to be implemented exactly.

```
*                 anything
1.2.3             exactly 1.2.3
=1.2.3            exactly 1.2.3
>=1.2.3  >1.2.3   
<=1.2.3  <1.2.3
~1.2.3            >=1.2.3 and <1.3.0   (patch-level drift)
^1.2.3            >=1.2.3 and <2.0.0
^0.2.3            >=0.2.3 and <0.3.0   (at 0.x the minor is the breaking one)
>=1.2.3 <2.0.0    space-separated terms are ANDed
```

`||` is **not** supported. A range containing it is reported as unparseable and
the mod is excluded — as against being parsed as something it does not mean.
A version that is not `MAJOR.MINOR.PATCH` is also reported rather than coerced;
a missing component would otherwise silently read as zero and make `1.2` match
`~1.2.0` when nobody said so.

### A list

```json
{
  "id": "aowl.list.raidnight",
  "name": "Raid Night",
  "author": "savannt",
  "version": "1.0.0",
  "description": "...",
  "inherits": ["aowl.list.vanillaplus"],
  "entries": [
    { "id": "aowl.morebots",  "enabled": true },
    { "id": "aowl.icebreaker", "enabled": false, "note": "not tonight" }
  ]
}
```

`inherits` is what makes "pick certain mods out of a list" expressible. You take
someone else's list, add your own entries, and flip individual ones off — and
what you share is *your* list, still a few lines, still pointing at theirs, so
their next update reaches you.

`aowl.list.headless` in this file is exactly that: it inherits Raid Night whole
and switches off the three client-only mods, which is a document that says
"considered and declined" where an edited copy would only say "absent".

`note` is free text and carries no meaning to the resolver. It is there because
the interesting half of a mod list is why a thing is off.

### Lists you write, which are not in this file

The lists above are *published* — they are in somebody's git repository, and a
refresh replaces them wholesale. Your own lists are not, and must not be:

```
POST /aowlspt/mods/lists/local
{ "id": "my.raidnight", "name": "My raid night",
  "inherits": ["aowl.list.raidnight"],
  "entries": [ { "id": "aowl.sain", "enabled": false, "note": "not tonight" } ] }
```

The same document shape, minus `author` and `version`, which are the fields that
only mean something once a list has left your machine. It is stored in the mod
manager's own store beside your selection (`mgr/selection.nim`) and merged into
the registry at read time by `withLocalLists`, so resolution cannot tell it from
a published one — that is the point; a local list with its own rules would be a
list with its own bugs.

Three consequences worth stating plainly:

- **A registry refresh cannot touch it.** Neither can `aowlspt-install`, which
  overwrites the installed `mods.json` every time it runs. That is the whole
  reason it lives where it lives.
- **It can go stale.** A refresh can remove a mod your list names. Resolution
  reports that entry as `unknown` and the refresh answer names it out loud; the
  entry is not deleted for you. Editing somebody's list to make it resolve is
  the silent edit this file's rules are arranged against.
- **A local id that collides with a published one wins**, and says so in
  `problems`. The other way round, publishing an id would let somebody quietly
  take over the meaning of a list you wrote.

`GET /aowlspt/mods/lists` marks each list `"local": true|false`, which is the
difference between a list a refresh can replace and one it cannot.

## Resolution

The inputs are: the registry, a **selection** (an ordered set of active list ids
plus the user's own per-mod overrides), the current `side()`, and
`hostVersion()`. The output is an ordered list of mod ids to load, plus a
decision with a reason for *every* mod in the registry — including the ones that
were never in the running, because "why is this not loaded" is the question
people actually ask.

**1. Flatten each active list.** Depth-first over `inherits`, in declared
order; a parent's entries come before the child's own. A list appearing twice in
one flattening contributes once, at its first position. A cycle in `inherits`
is a hard error: the list is rejected entire and named, and resolution continues
with the rest.

**2. Merge, in order.** Active lists are processed in the order the selection
gives them, entries within a list in file order. The **first** appearance of a
mod id fixes its position; a later appearance updates its `enabled` flag but
does **not** move it. That is what makes an inherited override behave the way
you would draw it: the child list flips a switch on the parent's entry rather
than moving the mod to the end.

**3. Apply overrides.** The user's own enable/disable decisions are applied
last and beat every list. An override naming a mod that no active list mentions
*adds* it, at the end — enabling a mod outside your lists is a normal thing to
do and should not require editing a list to do it.

**4. Drop unknown ids.** An entry naming a mod that is not in the registry is a
`unknown` decision and is dropped. It does not stop anything else.

**5. Side.** A mod that does not declare the current side gets `wrong-side` and
is not loaded here. This is *information, not a fault*: one binary ships to both
sides, and a client mod in a server list is normal.

**6. Pipeline range.** `pipeline` is matched against `hostVersion()`. A
mismatch is `pipeline` and the mod is excluded. If `hostVersion()` is not a
parseable semver, range checking is skipped for every mod and that is stated
once — refusing to load anything because the *host* misreported its version
would be punishing the wrong party.

**7. Dependencies.** Every `requires` entry must name a mod that is in the
registry, enabled after step 3, surviving steps 5 and 6, and satisfying the
range. Otherwise the dependent is excluded with `missing-dependency`, naming
which requirement failed and why. Exclusion **cascades** — anything that
required the excluded mod is excluded too — and is iterated to a fixed point.

A dependency is never auto-enabled. Turning on a mod the user explicitly turned
off, in order to satisfy something else, is the system deciding it knows better;
it says what is missing and lets them decide.

**8. Conflicts.** Two enabled mods conflict if either names the other in
`conflicts`, or if they `provide` an id in common. A conflict is not
auto-resolved: **both** are excluded and reported, with the reason text from the
registry. The single exception is an explicit user override — if exactly one of
the two was turned on by the user's own override rather than by a list, that one
wins and only the other is excluded. That is the one case where somebody has
actually stated a preference.

**9. Order.** A stable topological sort of what survives: repeatedly take the
earliest mod in merged order whose `requires` and `loadAfter` (restricted to
mods that are actually loading) have all been emitted. A cycle among `requires`
excludes every mod in the cycle with `cycle` and names them — a cycle is a
registry bug, and loading it in an arbitrary order would hide it.

`loadAfter` names that are absent or not loading are ignored, which is what
makes it soft.

**10. The result** is the ordered id list plus one decision per mod:

| verdict | meaning |
|---|---|
| `loaded` | it will load, at position *n* |
| `disabled` | switched off by a list or by you |
| `not-selected` | no active list mentions it |
| `wrong-side` | it does not run on this side |
| `pipeline` | its `pipeline` range excludes this host |
| `missing-dependency` | a `requires` entry is absent, disabled or the wrong version |
| `conflict` | it conflicts with another enabled mod |
| `cycle` | it is part of a `requires` cycle |
| `unknown` | a list named it and the registry does not have it |

Nothing else can happen. If a mod is not in exactly one of those states, the
resolver is wrong.

## What the in-game panel needs from an entry

The overlay draws one row per registry mod, from
`GET /aowlspt/mods/panel` — see `host/Aowlspt.Overlay/README.md` for the shape.
Three fields stop being cosmetic once a row is a button.

- **`id` really must equal the mod's `guid`.** The panel is keyed by guid, and
  it merges two sources on that key: the manager's rows, from the registry, and
  the rows the client host pushes in for what is loaded in *its* process. An
  entry whose `id` disagrees with the mod's `exportMod` guid does not correct
  itself — it shows up as two rows for one mod, one of which cannot be toggled.
- **`artifact` really is required.** It is the only thing that lets the manager
  say *which file* to load, so a mod without one answers `refused` on every
  enable, with that sentence, rather than being quietly skipped.
- **`version` has to fit in 24 bytes and `id` in 80.** Those are the panel's
  fixed row fields — a pointer into a string a worker thread might be
  reallocating is a use-after-free at 60 Hz, so the rows are fixed-size. A
  longer value truncates rather than crashing, but it truncates *on screen*.
  `tests/overlayhost/realbackend.py` checks every entry against both limits.

`sides` matters too, and in a way that is easy to misread: the manager runs on
the **server** side, so its rows describe the backend's view. A client-only mod
is not on the panel because the manager knows nothing about it — the client host
puts it there itself, and the manager's "not running" is never allowed to grey
such a row out.

## What checks this file

`tools/regcheck.nim`, in two modes, and the split matters because a standalone
registry repository has no `mods/` tree to check anything against.

```
aowl-regcheck                      the repository: the file and the mods
aowl-regcheck --file mods.json     the file alone
```

**`--file`** runs `registry/validate.nim` and nothing else: schema, required
fields, versions and ranges that parse, ids that are unique and inside the
panel's byte limits, `requires` / list `entries` / `inherits` that resolve, and
inheritance that terminates. It needs no repository, finds none, and is the mode
a registry repository runs in CI. **It is the same code the mod manager runs on
a fetched registry before it will adopt one**, so what passes here is what the
manager accepts.

Findings come in three severities, and the difference is whether acting on the
file anyway is defensible:

| | meaning |
|---|---|
| **fail** | the file is not usable. A duplicate id, a list entry naming a mod that is not there, an inheritance cycle. The manager refuses the whole document. |
| **warn** | usable, and probably wrong. A `loadAfter` naming a mod nobody defines is *defined* to be ignored, so it cannot be a failure — and is almost always a typo. |
| **note** | legal, and worth saying. A `conflicts` entry may name somebody else's mod. An entry with a `download` block is named here too, because nothing acts on one. |

Three of those rules are not about one entry but about what the *resolver* will
do with the file, and they were added because a file can satisfy every rule
above and still resolve to fewer mods than it reads as — the exact failure this
whole gate exists to prevent, arriving through the one door it did not watch:

| | severity | what it catches |
|---|---|---|
| **the load-order graph terminates** | fail | Two mods each naming the other in `loadAfter`, or one naming itself. Resolution step 9 excludes *every* survivor of a cycle with `cycle`, so this is not a wrong order — it is those mods not loading, and nothing else would have said so. The same emit loop runs in `validate.nim`, over the same two edge kinds, and names the survivors. |
| **a list carries its own dependencies** | warn | A list that enables a mod whose `requires` it does not enable. Resolution step 7 excludes that mod with `missing-dependency` every run. A warning and not a failure because several lists can be active at once and an override can supply the gap — but a list you hand somebody is a list that has to stand alone. |
| **a list enables no two mods that conflict** | warn | Declared `conflicts`, or two mods providing the same capability. Step 8 excludes **both**, so such a list resolves to two fewer mods than it reads as. |

There is a fourth, on `requires` itself: **a dependency has to declare every
side its dependent does**. Sides are decided (step 5) before dependencies (step
7), so a client-and-server mod requiring a server-only one is excluded on the
client with `missing-dependency` — an entry that is correct in every field and
cannot load on the side it was written for. A warning, because the entry is
still right on the sides the two share.

**The default mode** runs all of that first and then the half that needs the
source tree: it reads each mod's guid, name, author, version and sides out of
its own `exportMod(...)` call in `mods/<dir>/<dir>.nim` and compares them to the
entry here, treating the source as the truth and this file as the copy.

It exists because every way of getting this file wrong is silent from inside the
system. The manager reports honestly on what the registry told it; being told
something false is not a state it can detect. So `regcheck` fails the build on:

- a directory under `mods/` with no entry — the mod loads, and nothing can list,
  enable or disable it;
- an `intree` entry naming a directory that is not there — an entry describing a
  mod that cannot be built;
- `id` ≠ the exported guid — the failure the panel section below describes, where
  one mod becomes two rows and one of them cannot be toggled;
- `name`, `author`, `version` or `sides` disagreeing with `exportMod`;
- an `artifact` that is not the file `aowl build-mod` produces;
- a duplicate `id`, a `requires` or list `entries` id that is not in `mods`, or an
  `inherits` naming a list that is not in `lists`.

`loadAfter` and `conflicts` naming something absent are *not* failures: both are
defined to tolerate it (soft ordering; a conflict may name somebody else's mod),
so they are reported and passed.

`aowl test` runs the repository mode as **The mod registry against the mods**,
and the build fails when they disagree.

A value the scanner cannot resolve — a guid computed rather than declared — is
reported as unread and that field is skipped, rather than compared against the
empty string and quietly passing.

## What the resolver does not do

- It does not download anything, and it does not reach the network at all.
  Fetching a *registry* is `mgr/refresh.nim`'s, is off by default, and is
  metadata only; `download` is still metadata for a fetcher that does not
  exist — it is parsed and reported, never requested.
- It does not verify that the built library exists. That is the host's answer to
  give, and the manager asks it rather than guessing from the filesystem.
- It does not write to the registry. Your selection lives in the manager's own
  store (`save`/`load`); the registry is somebody's git repository and the
  manager only ever reads it.

## The registry as its own repository

Everything above describes a file. This section describes the *repository* it is
meant to live in, because "one git that contains a json of all the mods" is only
true once that git is a thing somebody can clone, validate and publish without
having a checkout of aowlspt beside it.

### Layout

```
mods.json          the manifest. This is the whole product.
README.md          what this registry is, who runs it, what gets in
CONTRIBUTING.md    the entry template and the submission rules
.github/workflows/validate.yml   runs the gate on every push and every PR
```

One file at the root, named `mods.json`, and no directory structure at all. Not
`mods/<id>.json` merged at publish time, which was the alternative and is worse
for the thing a registry is for: a merged file is one nobody reviews, and the
review *is* the gate. A pull request against one file shows exactly what changes
— an entry added, a version bumped, a list edited — and `git log -p mods.json`
is the history of the mod ecosystem in a form a person can read.

The cost is merge conflicts when two entries land at once. That is a real cost
and it is the right one to pay: two people adding entries to the same array is a
conflict a human resolves in ten seconds, and two people adding files that get
concatenated is a conflict nobody sees.

### How it is validated before it is published

```
aowl-regcheck --file mods.json
```

Exit code 0 or 1, findings on stdout. The binary is the one this repository
builds into `installer/build/aowl-regcheck.exe`; a registry repository takes it
from an aowlspt release rather than building it, which is what keeps the
registry repository free of any build tooling of its own.

```yaml
# .github/workflows/validate.yml
name: validate
on: [push, pull_request]
jobs:
  validate:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: get the validator
        run: |
          curl -L -o tools.zip <the aowlspt release asset>
          tar -xf tools.zip
      - name: validate
        run: .\aowl-regcheck.exe --file mods.json
```

The gate has to run in the registry repository and not only in aowlspt, and the
reason is the direction the file travels. Once a manager can fetch this file,
the first thing that reads a broken entry is somebody's game, not somebody's
build. A validator that only runs where the file is *consumed* is a validator
that finds the problem after it has shipped.

### How a mod author submits an entry

1. Fork, add one object to `mods`, open a pull request. Nothing else in the file
   changes in that PR — a version bump and a new mod are two reviews.
2. `id` **must equal the guid the mod's `exportMod` declares.** This is the one
   rule the whole schema is arranged around: the panel is keyed by guid and
   merges the registry's rows with what the host reports is loaded, so an entry
   whose id disagrees becomes two rows for one mod, one of which cannot be
   toggled. It does not correct itself, and nothing downstream can detect it.
3. `artifact` must name the file the build produces (`<dir>/<dir>.dll`). It is
   the only thing that lets a manager say *which file* to load, so an entry
   without one answers `refused` on every enable.
4. `download` stays `null`. See the open question below.
5. Bump `registry.revision`. One number, one commit, always up.
6. CI runs `aowl-regcheck --file mods.json`. A red run is not a formality: every
   failure it reports is a state the manager refuses the whole file for.

What review is *for*, given that the gate already ran: whether the description
says what the mod is rather than how to install it, whether `conflicts` reasons
are sentences a person can act on, whether `provides` uses a capability id that
already exists rather than inventing a synonym, and whether the upstream credit
is right. None of that is machine-checkable and all of it is what makes the file
worth reading.

### Lists in a public registry

A list in this file is a *published* list — a document with an author, a version
and a name, that other people inherit from. That is a different thing from
"somebody's personal setup", which belongs in the manager's store and never
comes near this repository (see "Lists you write" above). The test for whether a
list belongs here is whether anyone else would `inherits` it.

## Refreshing from a URL

`mods/manager/mgr/refresh.nim`. **Off by default, metadata only**, and arranged
so that every way it can fail leaves the registry you are running exactly where
it was.

```json
"registryUrl": "https://.../mods.json",
"registryFetchEnabled": false,
"registryFetchOnStart": false,
"registryFetchTimeoutMs": 8000,
"registryFetchMaxBytes": 4000000
```

Two switches rather than one, because "I wrote down a URL to try later" and
"fetch from it" are different intentions, and a URL that starts reaching the
network the moment it is saved is a surprise.

```
GET /aowlspt/mods/registry              is it on, and what happened last
GET /aowlspt/mods/registry/fetch        fetch now; returns at once
GET /aowlspt/mods/registry/fetch/force  ... and accept an older revision
GET /aowlspt/mods/registry/revert       drop the fetched copy
POST /aowlspt/mods/lists/local          create or replace one of your own lists
GET  /aowlspt/mods/lists/local/delete/<id>
```

The fetch runs on a worker thread — `mgr/httpfetch.nim`, WinHTTP loaded by name
so nothing has to be added to the shared mod link line — and no route ever waits
for it. `/fetch` answers `fetching` and the result arrives on a later call or on
the manager's own half-second tick. Measured against a loopback server handing
over one byte at a time: the fetch route returned in 43ms and
`/aowlspt/mods/status` answered in 29ms while that fetch was still out.

A registry that validates is written to `<manager data>/mods.json`, which is the
first place the manager already looks, so a refresh survives a restart and
`revert` is a file deletion — an undo a person can also perform with a file
manager, rather than a second piece of state that can disagree with the first.
The file is read back and re-validated after the write, and put back the way it
was if the readback is not what was written: a document that passed every check
in memory and reached the disk half-written would otherwise be the file the
*next* start reads.

One precedence consequence worth knowing before it surprises somebody: the
adopted copy sits ahead of the installed one in the manager's search order, so
after `aowlspt-install` ships a newer `mods.json` the *adopted* file still wins.
That is the right default — an install must not silently undo a refresh you
asked for — but it means "I installed a new build and the registry did not
change" has an answer, and the answer is `/aowlspt/mods/registry/revert`. An
explicit `registryPath` beats both, which is why the fetch refuses to run at all
when one is set.

The path spelling of `force` is not a style choice. The backend matches a static
route by exact string, so `?force=1` matches no route at all and the handler is
never called — a flag the router silently drops reads as "forced" and behaves as
"not forced", which for a rollback is the wrong way round.

### Every way it refuses

| what happened | what it does |
|---|---|
| the fetch is off, or no `registryUrl` | nothing, and names which switch |
| `registryPath` points at a checkout you keep | refuses: an adopted copy would be written where nothing reads it. `git pull` and `/aowlspt/mods/reload` is the honest answer |
| connection refused, DNS failure, TLS failure | keeps the current registry, names the Windows error |
| the whole fetch exceeded `registryFetchTimeoutMs` | keeps it. The deadline bounds the *whole* fetch, not each call — a server handing over one byte at a time trips no per-operation timeout |
| any status but 200 | keeps it, names the status |
| the body reached `registryFetchMaxBytes` | keeps it. Refused, never truncated: a registry cut short parses fine and has fewer mods in it than the publisher wrote |
| not JSON, or not an object | keeps it |
| a `schema` this build does not implement | keeps it, and names both strings |
| any `fail` from `registry/validate.nim` | keeps it, and lists them |
| no mods at all | keeps it — an empty registry is a URL pointing somewhere unexpected far more often than it is somebody's intent |
| **any entry carries a `download` block** | keeps it. See below |
| a `revision` lower than the one in effect | keeps it. A rollback is a real thing to want, so `/fetch/force` does it — but not by accident |

"Newer" is not "better", and the revision check is the only part of that a
machine can decide. The rest is the table above: a registry is adopted because
it survived every check, not because it arrived.

### What a refresh tells you

`added`, `removed` and `versionChanged` — by id, diffed against the file that
was in effect — and `orphaned`: everything *you* have said that the new registry
cannot honour. Active lists it does not define, overrides naming mods it does
not have, and entries inside your own lists that now point at nothing. Reported,
never repaired.

An actual run, adopting a registry that dropped `aowl.icebreaker`:

```
diff: + ['aowl.brandnew'] - ['aowl.icebreaker'] ~ ['aowl.tarkov 0.1.0 -> 9.9.9']
orphaned:
  - your override on aowl.icebreaker names a mod the new registry does not have
  - your list my.raidnight names aowl.icebreaker, which the new registry does not have
```

`my.raidnight` was still there afterwards, still active, still saying what it
said. That is the property the whole split exists for.

### Testing it

`registry/fakeregistry.py` is a registry server that is wrong on purpose:

```
python registry/fakeregistry.py --port 7391 --serve registry/mods.json
curl http://127.0.0.1:7391/mode/truncate     # and garbage, schema, invalid,
                                             # download, empty, notfound, error,
                                             # slow, huge, bump, older
```

Point a staged manager's `registryUrl` at it and walk the table above. Every row
of that table was produced by this server against a real backend rather than
reasoned about — a refusal nobody has watched fire is a refusal nobody knows is
wired up.

**And `--check` is the half that asserts it.** Serving a wrong document proves
nothing on its own: what has to be checked is that the wrongness still provokes
the refusal, and that the refusal still happens.

```
python registry/fakeregistry.py --check --regcheck installer\build\aowl-regcheck.exe
python registry/fakeregistry.py --check --regcheck installer\build\aowl-regcheck.exe ^
       --port 7391 --manager http://127.0.0.1:6981
```

Three layers, and the file's own docstring sets out which is which: every body
that is refused for what it *says* goes through `aowl-regcheck --file` — the
same `validate.nim` the manager runs before it will adopt anything — and the
expected verdict is asserted; the transport modes are asserted over a real
socket against the shipped `registryFetchMaxBytes` and
`registryFetchTimeoutMs`; and with `--manager` pointed at a staged manager
whose `registryUrl` is this server, all thirteen modes are driven end to end
and the outcome (`refused`, with the reason named, or `adopted`) is asserted.
44 checks, and the run that introduced them found two things by failing:

* **`huge` had stopped being huge.** It grew the document until it held 4000
  mod entries, which was over the ceiling when it was written and is 3.0 MB
  against a 4.0 MB ceiling now — so the mode that exists to provoke the size
  refusal was being adopted instead, and had been for as long as the ceiling
  had been where it is. It now grows until the *bytes* pass the ceiling.
* **`truncate` is not refused for being unparseable.** `aowlspt/json` scans, so
  half a registry still reads as an object with a schema and a revision on it;
  it is refused because `mods` is no longer an array. That is precisely why a
  short body may never be adopted "as far as it got", and why the fetch refuses
  on `truncated` before the validator ever sees it.

Nothing else in the repository drives these: `tools/livectl.nim` exercises the
fetch path's success and its revert, and stops there.

## The open question: mod binaries

**This is the owner's call and it has not been made.** It is written down here
rather than implemented, because implementing it is a decision about what this
project is.

The schema has `download`: a URL, a `sha256` and a `size`. **Nothing fetches
it.** It is parsed (`mgr/registry.nim`), validated (`registry/validate.nim`) and
served back out of `/aowlspt/mods/describe/<id>` as `downloadUrl` and
`downloadHash`, so a person can see what a publisher declared; no code in this
repository turns any of that into a request.
`aowl-regcheck` checks that it is well formed and names every entry that has
one. The manager's refresh path refuses a fetched registry that carries one
outright, with the reason in the answer.

The reason for the asymmetry — the shape exists, the behaviour does not — is
that a field cannot be added to a format after something depends on it not being
there, whereas a fetcher can be added at any time. So the cheap half is done and
the expensive half is a question:

**Should a mod manager download and load a mod binary from a URL?**

What is on the other side of that yes:

- It is arbitrary native code, from the network, loaded into a process that has
  been injected into a running game. Not sandboxed, not signed, not reviewed by
  anything but a hash that says "this is the file the registry named" — which is
  a statement about integrity, not about intent. A compromised registry
  repository, or one whose maintainer has a bad afternoon, reaches every
  installation that has this switched on.
- `sha256` is the whole of the verification story, and there is **no SHA-256 in
  the toolchain today**. nimony's standard library ships `md5` and `sha1`;
  neither is a hash to gate code execution on. Implementing SHA-256 is a day's
  work and is the *smallest* part of this.
- It changes what the registry repository is. Today it is a document, and a
  wrong entry produces a wrong row on a panel. With this, it is a distribution
  channel, and a wrong entry produces code running on somebody's machine. The
  review standard, the maintainer set and the trust model all have to change to
  match, and that is a governance problem rather than a coding one.

If the answer is yes, the shape it should take:

1. SHA-256 in `aowl/src`, tested against known vectors, before anything else.
2. Download to a staging path, hash it, check the size against `download.size`,
   and only then move it into `mods/` — never write into the live mods tree and
   verify afterwards.
3. A third switch, separate from `registryFetchEnabled`, defaulted off, named
   for what it does rather than for what it enables.
4. A per-registry allowlist of download hosts, so "the registry was taken over"
   and "the binaries were taken over" are two compromises rather than one.
5. Nothing loaded in the same session it was downloaded in. A binary that
   appears and is loaded in one gesture leaves no moment in which a person could
   have looked at it.

If the answer is no, the honest form of that is to delete `download` at the next
`aowlspt.registry/2` and say in this file that mods are distributed the way they
are today. A field nothing will ever read is decoration in a manifest, and
decoration in a manifest reads as a guarantee.
