# The mod registry

One file, `mods.json`, in one git repository: every mod that exists, and every
**list** that names a set of them. A list is a document, so "my raid night
setup" is a thing you commit, diff and send someone rather than a screenshot of
a folder.

`mods/manager` reads this file, resolves it against your own selection, and
serves the result under `/aowlspt/mods/...` while the game is running.

```
registry/mods.json      the manifest: mods and lists
registry/README.md      this — the schema, and the resolution rules
```

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
  "registry": { "id": "...", "name": "...", "description": "..." },
  "mods":  [ ... ],
  "lists": [ ... ]
}
```

`schema` is checked. A reader that does not know the schema string refuses the
file rather than guessing at fields it has never seen — a half-understood
registry is how you get a list that loads five of your seven mods and tells you
everything is fine.

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
| `download` | `null`, or `{ "url": ..., "sha256": ..., "size": ... }`. |
| `requires` | hard dependencies: `{ "id", "version" }` where `version` is a range. |
| `conflicts` | `{ "id", "reason" }`. The reason is not decoration — it is what the manager prints when it refuses to load both. |
| `provides` | capability ids. Two enabled mods that provide the same id conflict, even though neither has heard of the other. That is how "two AI overhauls" is detected without every AI mod listing every other one. |
| `loadAfter` | soft ordering. Unlike `requires`, the named mod does not have to be present. |
| `tags` | free-form, for a UI to group by. Not used in resolution. |

#### Why `download` is null for everything here

Every mod in this registry is built from this repository by
`aowl build-mod mods/<name>`, and there is no published artifact to point at
yet. The alternative was to write a plausible-looking URL and a made-up
`sha256`, which would be a hash that verifies nothing and a link that 404s —
strictly worse than the empty field, because it would *look* checked.

The rule the manager applies: a mod whose `source.kind` is `intree` may have a
null `download` and is expected to be present already. A mod from anywhere else
**must** carry `download.url` and `download.sha256`, and a fetcher that cannot
verify the hash must refuse the file rather than install it.

#### Version ranges

Small on purpose, because every operator here has to be implemented exactly.

```
*                 anything
1.2.3             exactly 1.2.3
=1.2.3            exactly 1.2.3
>=1.2.3  >1.2.3   
<=1.2.3  <1.2.3
~1.2.3            >=1.2.3 and <1.3.0   (patch-level drift)
^1.2.3            >=1.2.3 and <2.0.0   (and, for 0.x, <0.3.0 — 0.x minors break)
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

## What the resolver does not do

- It does not download anything. `download` is metadata for a fetcher that does
  not exist yet; the manager reports what a mod needs and never reaches the
  network.
- It does not verify that the built library exists. That is the host's answer to
  give, and the manager asks it rather than guessing from the filesystem.
- It does not write to the registry. Your selection lives in the manager's own
  store (`save`/`load`); the registry is somebody's git repository and the
  manager only ever reads it.
