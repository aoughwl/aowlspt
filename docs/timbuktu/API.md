# Escape from Timbuktu: the API pillar

Four other documents in this directory design systems. This one designs the
thing those systems are *shipped as*, because the owner asked for that
specifically:

> "and remember, we also want to collapse a lot of this logic into our nimony
> API, we want to ship an amazing API that users can use to make mods, we want
> to replace base systems with our better system and offer that replacement as
> an API you can use or something"

So the deliverable of Timbuktu is not a mod. It is a set of `aowlspt/*` modules
that a stranger can `import`, plus a small number of runtime protocols that let
one mod hand a base system to another without either of them knowing the other
exists. Timbuktu is then the first customer of its own API — the same relation
`mods/tarkov` already has to the current one, which its registry entry states
outright: *"Written entirely on the public mod API, which is the only honest
test that the API is enough to build a game server with."*

**Nothing in this repository has ever run against BSG's client.** That sentence
governs section 5 and section 7 and is not repeated in every paragraph that
depends on it.

---

## 1. The API as it stands today

### 1.1 The shape

Nine files, and it is worth having the sizes in mind because they say where the
weight is:

| module | lines | what it is |
|---|---:|---|
| `aowl/src/aowlspt.nim` | 1493 | the surface: lifecycle, registration, capability tests, `exportMod` |
| `aowl/src/aowlspt/abi.nim` | 294 | a transliteration of `abi/aowlspt_abi.h`, deliberately mechanical |
| `aowl/src/aowlspt/fast.nim` | 1370 | bound calls and bound field access, no host on the path |
| `aowl/src/aowlspt/game.nim` | 913 | the comfortable client surface over `resolve`/`call`/`patch` |
| `aowl/src/aowlspt/il2cpp.nim` | 754 | the runtime's own C exports, by name |
| `aowl/src/aowlspt/server.nim` | 778 | routes, database, config, store, events, JSON building |
| `aowl/src/aowlspt/json.nim` | 690 | a scanning reader and a member-wise editor |
| `aowl/src/aowlspt/sync.nim` | 93 | one `CRITICAL_SECTION`, per mod, per library |
| `aowl/src/aowlspt/fixture.nim` | 123 | where an offline self-test may load a runtime from |

The brief for this document listed the eight files under `aowl/src/aowlspt/`
and put them at "about 5000 lines" — they are 4915 — and omitted
`aowl/src/aowlspt.nim`, which is the file every mod actually imports. Worth
correcting because the omission is structural: the eight are modules, and the
ninth is *the API*.

A mod is one library exporting three symbols — `aowlspt_abi_version`,
`aowlspt_describe`, `aowlspt_init` — all three written by the `exportMod`
template at `aowl/src/aowlspt.nim:1458`. Everything else is optional.

### 1.2 What is genuinely good, and should be copied rather than replaced

**a. Refusals are sentences, and they are made at registration.** `installPatch`
in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` refuses a postfix on a wide-value
return and on a method with stack arguments *before* installing, with a
`gLastError` that names which of the two it was. `aowl_hook_error_text` in
`abi/aowlspt_detour.h` turns nine distinct install failures into nine distinct
sentences. `bindMethod` in `fast.nim` answers `ok = false` and a `why` naming
the argument it could not classify. Any new module has to hold this line: an
approximation on this stack is a plausible number handed to the game.

**b. The three-answer status.** `configGet` distinguishes `Ok` /
`ErrNotFound` / `ErrConfigParse`, and `aowl/src/aowlspt/abi.nim` carries the
whole story of why — a BOM'd `config.json` made the mod manager read
`activeLists` as empty and write a selection naming only itself. The same
distinction appears in `Stored.missing` ("there is no such key" versus "there is
one and it could not be read"). Every persistent system Timbuktu adds owes the
same distinction; see D9 for the fact that three mods have each rebuilt it.

**c. The size watermark.** `storeReady()`, `livePointersReady()`,
`typedPatchesReady()`, `notifyReady()` each test against the boundary its
capability appeared at — `HostApiSizeRev2`..`Rev5`, written as literals in
`abi.nim` precisely so they do not move when the struct does. The rule that
falls out is stated in `docs/MODDING.md`: *a size test means "there is a
function here that will answer", not "this works."* Both real hosts fill
entries they cannot honour with the refusal they already owe.

**d. The sigil precedent.** `dbKeys` (`aowl/src/aowlspt/server.nim:337`) added a
whole new database operation with **zero ABI surface**: a path beginning
`"?keys "` answers key enumeration, a host that does not implement it looks for
a root member by that literal name and answers `ErrNotFound`, and the mod falls
back to the read it was already doing. `dbKeysReady()` probes with the sigil and
no path and looks for `ErrBadArg`. This is the cheapest extension mechanism in
the tree and section 4 leans on it.

**e. `mergeInto` semantics.** `dbPatch` merges recursively rather than
replacing (`backend/jsondb.nim:1220`), *"which is what makes two mods editing
different fields of the same item safe."* Whatever `place` does to
`locations.<map>` has to keep that property.

### 1.3 The defects

Named individually because each one costs Timbuktu something specific.

**D1. There is no extension point in the one route that matters.**
`onItemsMoving` at `mods/tarkov/tarkov.nim:395-566` is a hand-written
`if`/`elif` chain over `questAction(kind)`, `hideoutAction(kind)`,
`productionAction(kind)`, `personalAction(kind)`, `healthAction(kind)`,
`repairAction(kind)`, `noteAction(kind)`, `gymAction(kind)`,
`customiseAction(kind)`, `decorateAction(kind)`, `isRagfairAction(kind)`,
`mailSource(a)`, `sellAllAction(kind)` — and the *order* is load-bearing,
documented case by case (repair first because it names its item in `target`;
mail-redeem before the generic move because the item is not in the inventory
yet). Every verb the client can perform on a profile arrives down this one
endpoint. A third-party mod cannot add a verb, cannot replace a verb, and
cannot observe one. **This single defect is why Timbuktu cannot replace the
hideout with the API as it stands.** It is not a missing feature in
`mods/tarkov`; it is a missing shape in `aowlspt`.

**D2. First-claimant-wins is the rule everywhere, and it is written down
nowhere as a rule.** The backend refuses a second registration of the same
url+kind (`backend/aowlbackend.nim:1159-1181`, *"the route " & u & " is already
registered"*). The detour engine refuses a second hook on a method
(`abi/aowlspt_detour.h`, rc `-9`, *"that method is already patched -- something
else detoured it first"*). The registry resolver refuses two mods that
`provides` the same capability (`mods/manager/mgr/resolve.nim:178`, *"both
provide "*). Three implementations of one policy, in three layers, discovered
separately by whoever hits them. `docs/MODDING.md` mentions the middle one only
as an obstacle in an example's comment.

**D3. `sptRange` is declared, transported, and never checked.** It is in
`abi/aowlspt_abi.h:616`, in `ModInfo`, in `registerMod`, in `fillModInfo`, in
the `exportMod` signature, and in all eight examples. `host/common/modhost.nim`
reads `sides` (line 846) and the ABI version (line 819) and never reads the
range. Grep the tree: nothing does. The examples are already inconsistent about
it — `~4.1.0` in `hello` and `backend`, `*` in the other six — which is what a
field with no consequence looks like from the outside.

**D4. `mfThreadSafe` is declared and never read.** `abi/aowlspt_abi.h:626`,
`abi.nim:120`, `modhost.nim:1153` as a constant, `tests/abi_layout.nim` as a bit
value. No host branches on it.

**D5. `stateSave`/`stateLoad` are documented as working and are called by no
host.** `docs/MODDING.md`, "Surviving a rebuild", says *"`stateSave` runs just
before the library is freed and `stateLoad` on the next incarnation, so
rebuilding a mod mid-session does not visibly reset it"*, and tells you to try
it with `aowlspt-sim --watch`. `host/Aowlspt.Sim/aowlsim.nim:1420-1444` says the
opposite in the same tree, and warns at run time when a mod declares
`mfHotReloadable`: *"They will not be called here -- no host implements them
yet."* `docs/ARCHITECTURE.md:120` agrees with the simulator. `examples/lesson`
§7 teaches the feature. No mod in `mods/` implements the pair. Timbuktu is the
first project here whose in-memory state would be expensive to rebuild, so this
stops being a documentation bug and becomes a design input.

**D6. `side()` is the only side vocabulary, and five of eight examples got the
guard wrong.** `side()` returns `sideServer` / `sideClient` / `sideSim` and
nothing else. What a mod actually wants to ask is "can I serve a route here",
"is there a database here", "is there a runtime here" — and the answers are not
the three enum values, because `sideSim` serves routes and reads a database and
has no runtime. Writing `if side() == sideServer` instead of
`if side() != sideClient` silently registers nothing under `aowl run`;
`examples/envelope` says *"Two files in this directory had that bug"*, and
`aowlspt-sim` carries a bespoke error message whose only job is to explain the
confusion. The host knows the answer. The mod should not be encoding the rule
five times.

**D7. Cross-mod protocol is a naming convention and nothing else.** `emit`/`on`
carry a string name and a JSON payload, delivered synchronously in subscription
order to everyone but the emitter. There is no discovery, no version, no schema,
no reply routing, and `emit` returns a `Status` rather than a delivery count. So
every mod that needs a protocol invents the same handshake: `mods/icebreaker`
publishes `aowlspt.locations.changed` and answers `aowlspt.locations.hello`;
`mods/morebots` broadcasts `morebots.ready` and answers `morebots.hello` and
documents the two-way handshake as *"which does not depend on load order at
all"*; `host/common/modcontrol.nim` reserves `aowlspt.host.mods.*` and answers
`...capabilities` with a JSON object. Three good designs of the same thing, none
of them reusable. **The one piece of machinery this needs already works and is
unnamed:** both hosts copy the subscriber list out from under the registration
lock and release it before calling anything (`backend/aowlbackend.nim:1196`
onward; `aowlhost.nim:1395` onward), which is what makes a handler that emits
from inside an emit safe — so *synchronous request/reply over the event bus is
already sound on both sides*, and `modcontrol.emitReply` is the host quietly
using it.

**D8. `notifyPush` is addressable only by the mod that owns login.** It takes a
session id (`aowl/src/aowlspt.nim:1346`); every event a mod can observe names a
profile id; the mapping is `mods/tarkov`'s private store key `"sessions"`
(`emu/sessions.nim`). `docs/API-GAPS.md` gap 3 works this through and concludes
correctly that the host must not hold the mapping. Timbuktu will want to tell a
player that something happened in the world while they were in a raid, so it
inherits the gap.

**D9. "Absent" versus "unreadable" has been rebuilt three times, in two mods.**
`mods/tarkov/emu/store.nim` (`readKey`), `mods/tarkov/emu/profile.nim`
(`ProfileRead` = `prLoaded|prMissing|prUnreadable`),
`mods/manager/mgr/selection.nim` (`SelectionState` =
`ssFresh|ssLoaded|ssUnreadable|ssCorrupt`). All three exist because
`Stored.missing` is one boolean and the third state — *readable, and not what
this mod wrote* — has no representation at all. The manager's version refuses to
persist over an unreadable document, which is the behaviour all three want.

**D10. Six other things every mod rewrites.**

| rewritten | copies | where |
|---|---:|---|
| unquoting a config string (`ConfigValue.asText` returns the quotes) | 4 | `manager.nim:330`, `mgr/refresh.nim:165`, `fov/fov.nim:312`, `icebreaker.nim:233` |
| reading a text file with a BOM strip and a `try/except` | 4 | `mgr/registry.nim:198`, `bd/data.nim:81`, `ice/tables.nim:100`, `bots/spawnscale.nim:101` |
| parsing a number (`parseInt` is `.raises`, and nimony has no exceptions) | 3+ | `hello.nim:88`, `backend.nim:41`, `highlevel.nim:282` |
| a JSON array of strings | 3 | `mgr/registry.nim:103`, `icebreaker.nim:246`, `pathtotarkov.nim:124` |
| fixed-point float→text, because `$` writes `0.020000000000000004` into a profile | 2 | `tarkov/emu/numbers.nim`, `sway/model/fmt.nim` |
| deriving the mods root from `modDir()` by string surgery | 2 in one mod | `manager.nim:317`, `mgr/control.nim` |

There is **no file API at all** in `aowlspt`, and no HTTP: `mgr/httpfetch.nim`
is ~400 lines including a `{.emit.}` block that `LoadLibraryA`s `winhttp.dll`
and runs a worker thread, *"purely because `aowl build-mod` passes no
`--passL`"*.

**D11. The mod manager reaches into host source to do its job.**
`mods/manager/mgr/cfgscan.nim:47` imports `../../../host/common/jsonpath`, and
`mgr/refresh.nim:85` imports `../../../registry/validate`. `cfgscan` argues the
point well — *"A second opinion about a config file is not a safety net. It is
the bug"* — which is exactly the argument for those validators being public API
rather than a relative path out of the mods tree.

**D12. Version-range matching exists and is private to one mod.**
`mods/manager/mgr/semver.nim` implements `*`, `=`, `>=`, `>`, `<=`, `<`, `~`,
`^` (with the 0.x caret rule), ANDed terms, and refuses `||` and two-component
versions rather than approximating them. It is a mod's private module. Any
module that wants to state a compatibility range has to write a second one.

**D13. `dbPatch` merges objects and replaces arrays.** `mergeInto`
(`backend/jsondb.nim:1220`) recurses into objects and, for anything else,
*"anything else in the patch replaces"*. Two mods appending to
`locations.<map>.exits` clobber each other, silently, last writer wins. Every
system Timbuktu adds that decorates a shared list inherits this.

**D14. The mod-side registration tables and the host's do not agree about
capacity.** `RouteCapacity`, `EventCapacity`, `PatchCapacity` and
`TypedPatchCapacity` are each 1024 in `aowl/src/aowlspt.nim:193-201`. The detour
engine holds **256** slots for the whole process, shared across every mod, one
of which the client host spends on its own per-frame drain
(`docs/ABI.md`, "Patching"). A mod that plans against the number it can see
plans against the wrong number.

**D15. There is no `aowl new`.** `tools/aowl.nim` has `build`, `build-mod`,
`build-hosts`, `build-installer`, `test`, `doctor`, `run`, `payload`, `release`,
`importdb`, `clean`. Shipping "an amazing API that users can use" starts with a
command that writes a working mod directory, and there isn't one.

---

## 2. The proposed layering

### 2.0 Arguing with the brief's four

The brief proposes `world`, `npc`, `story`, `place`. Three objections and two
additions.

**Objection 1 — the four cannot be written first.** Every one of them wants to
replace or extend something `mods/tarkov` owns, and D1 says there is nowhere to
plug in. `place` wants the item-event verbs. `story` wants the quest tables and
the quest verbs. `npc` wants dialogue routes. `world` wants profile state. Each
of those is behind either a route that is already claimed or an `if`/`elif`
chain in one mod's private source. **A module that lets a system be claimed,
handed over, and extended has to exist before any of the four, or the four are
just Timbuktu's internal source files with `aowlspt/` in their path.** That
module is `aowlspt/claim`, below.

**Objection 2 — `npc` and `story` are one substrate seen twice.** "What this
NPC knows" and "what this quest requires" are both: a fact, with a subject, a
predicate, a value, a provenance, and a time. `mods/tarkov/emu/questcond.nim`
already evaluates conditions over a profile; NPC knowledge is the same
evaluation over a different subject. Two mod-author-facing modules is right —
the vocabulary an NPC author wants is not the vocabulary a quest author wants —
but they should sit on one store and one query, or Timbuktu ships two fact
engines that disagree about time.

**Objection 3 — `world` should not own persistence.** Persistence is another
pillar's document and the store already exists, atomic, with history, at
`host/common/modstore.nim`. `world` should own **identity** — the thing that has
no answer today at all (see 2.3) — and take a journal as a parameter.

**Addition 1 — `aowlspt/claim`**: capability declaration, negotiation, and
synchronous request/reply over the existing event bus.

**Addition 2 — `aowlspt/verb`**: the extension point for the item-event
endpoint, which is where a base system is actually replaced.

The names are placeholders that match the repo's one-short-word convention
(`abi`, `fast`, `game`, `json`, `server`, `sync`). Naming is the owner's; see
section 9.

### 2.1 `aowlspt/claim` — who owns what, and how to ask

**The surface.**

```
claim(system: string; version: int): Status      # I own this base system
owner(system: string; into: var Owner): Status   # who owns it, and at what version
ask(system, verb, payload: string; into: var string): Status   # synchronous
answer(system, verb: string; handler: AskHandler): Status      # the other end
announce(system: string; payload: Json)          # "I changed something"
```

**What it hides.** That all of it is `emit`/`on` with a reserved name prefix and
a JSON envelope carrying `{"v":n,"from":guid,"to":system,...}`; that `ask` works
because both hosts copy the subscriber list out and release the registration
lock before calling a handler, so a handler may emit and be heard before the
outer `emit` returns; that a missing owner is `ErrNotFound` and not a hang. It
hides the three handshakes in D7 by being the fourth one, written once.

**How it replaces rather than fights.** It does not replace anything. It is the
mechanism by which everything else is replaceable, and it is additive to every
existing mod: a mod that never calls `claim` is unaffected, and a mod that asks
for an unclaimed system gets `ErrNotFound` on the first call rather than a
timeout.

**Why it is not an ABI entry.** Because it does not need to be. `emit`/`on` are
revision 1 and every host implements them; the whole of `modcontrol`'s control
protocol is built on the same two calls. Spending an ABI revision on this would
buy nothing and would make it unavailable on the very hosts a mod most wants to
be portable across.

### 2.2 `aowlspt/verb` — adding and replacing an item-event action

**The surface, server side only.**

```
type VerbResult = object   # handled / declined / refused-with-a-sentence
onVerb(action: string; handler: VerbHandler): Status
onAnyVerb(handler: VerbHandler): Status          # last resort, for a logger
declineVerb() / handledVerb(ch: Change) / refuseVerb(code: int; why: string)
```

**What it hides.** That the item-event endpoint is one route owned by whichever
mod registered it first; that the batch is a JSON array and each element carries
an `Action`; that ordering inside the batch is load-bearing; that the answer has
to be an `itemEventResponse`-shaped envelope, not a bare object.

**How a mod replaces a base system with it.** The owner of the endpoint —
`mods/tarkov` today — consults registered verb handlers *before* its own
`if`/`elif` chain, and a handler that returns `handled` short-circuits it. That
is one edit in one mod, plus the module. Then Timbuktu writes:

```
discard claim("aowl.system.hideout", 1)
discard onVerb("HideoutUpgrade", refusePolitely)
discard onVerb("HideoutUpgradeComplete", refusePolitely)
discard onVerb("TimbuktuBuild", build)
```

and the hideout is gone, replaced, and *said out loud* rather than 404'd.

**The honest limit.** A verb the client never sends cannot be added by this or
by anything else. `TimbuktuBuild` above is a verb the real client will never
emit; the only verbs Timbuktu can *receive* are ones BSG's client already
sends. What this buys is the ability to give an existing verb new meaning, and
to refuse one truthfully. See section 7.

### 2.3 `aowlspt/world` — identity

**The problem it solves, precisely.** There is no stable identifier for anything
in this stack. A `GameObj` is a GC handle good for a session. A hook's `this` is
good for the length of the handler and is refused with `ErrDisposed` afterwards.
A raw pointer is good until the collector moves. A `session` is an opaque string
that no example ever uses for anything but echoing it back. The only durable
identifier anybody has built is `mods/tarkov/emu/ids.nim` — 24 hex characters,
a persisted run number in store key `"ids.run"`, advanced and written back
*before a single id is issued*, and a mod that cannot establish it **refuses to
start**. That module was written after a real corruption: two servers against
one store issued the same three ids, the stash root became a rifle, and the
client could no longer draw the inventory tree.

**The surface.**

```
type Eid = distinct string          # a MongoId, because the client parses one
newEid(): Eid                       # never collides across restarts
type Entity = object                # kind, eid, place, facts
spawn(kind: string; into: var Entity): Status
find(e: Eid; into: var Entity): Status
place(e: Eid; where: Place): Status
forget(e: Eid): Status
```

**What it hides.** The run-number protocol and its refusal-to-start rule; the
fact that an id must be 24 hex characters or the client rejects it; the store
key layout; the "absent versus unreadable versus not-mine" triple from D9,
which it answers as a single `EntityRead` enum rather than a boolean.

**What it must not hide.** That an `Eid` is not a handle: it names a row, not a
live object, and there is no `world` call that hands back a pointer.

**Relation to the persistence pillar.** `world` writes through a `Journal`
interface it does not implement. `docs/timbuktu/PERSISTENCE.md` owns what a
journal is. If that document lands with a different shape, `world` changes its
parameter type and nothing else.

### 2.4 `aowlspt/place` — containers, grids, placement

**This is the module with the least design risk and the most immediate value,
and it exists already, trapped inside one mod.** `mods/tarkov/emu/grid.nim` is
an occupancy map and a first-fit scan, both orientations tried, falling back to
a 10×68 standard stash when the database has no template. Its header states the
rule that makes it necessary: *"There is no 'just put it in the container': the
client draws the stash from the positions the server sent, and an item with no
location, or one overlapping another item, is drawn on top of what is already
there and cannot be picked up."* `emu/loot.nim` is the same problem again for
static containers, plus the two shapes that cannot be spawned bare — an ammo box
without its cartridge stacks, and a weapon without its preset expanded, *"a
floating receiver with no magazine, no handguard and no sights"*.

**The surface.**

```
type Grid, Placement                # lifted verbatim from emu/grid.nim
gridFor(tplId: string): Grid
fit(g: var Grid; w, h: int; into: var Placement): bool
type Container                      # a grid set plus an owner Eid
put(c: var Container; item: ItemSpec; into: var Placement): Status
expand(tplId: string; into: var List): Status    # a weapon or ammo box, whole
```

**What it hides.** That the grid dimensions come out of the item template and
that a missing template is a fallback rather than a failure; that a weapon is a
tree; that two items in one container must not overlap.

**How it replaces a base system.** It does not, on its own — it is the substrate
Timbuktu's physical containers stand on. The replacement is
`claim("aowl.system.hideout")` plus `place` doing the work the hideout's slots
used to.

**Extraction cost.** `emu/grid.nim` imports `aowlspt`, `aowlspt/server`,
`aowlspt/json` and `templates`. Only the last is emulator-private, and only for
reading the stash template. That is one parameter, not a rewrite.

### 2.5 `aowlspt/npc` — knowledge, dialogue, tools

**The surface.**

```
type Actor                          # an Eid with a knowledge view
knows(a: Actor; subject: Eid; pred: string; into: var Fact): bool
learn(a: Actor; f: Fact): Status    # with provenance and a timestamp
forgetOlder(a: Actor; ms: int64): int
type Tool = proc (a: Actor; args: string; into: var string): Status
tool(name: string; t: Tool): Status
say(a: Actor; to: Eid; line: string): Status
```

**What it hides.** The fact store and its indexes; that provenance is what makes
"this NPC saw it" different from "this NPC was told"; that a timestamp needs a
wall clock the ABI does not offer (`nowMs()` is *monotonic milliseconds since
host start* — `mods/tarkov` derives seconds by holding `gNowSeconds + nowMs()
div 1000`, which is a second thing every mod would otherwise rebuild).

**How it extends rather than fights.** SPT dialogue is already a server concern
and `mods/tarkov/emu/dialogue.nim` and `emu/mail.nim` serve it. An NPC that
speaks through the existing mail and dialogue routes is an NPC the real client
can already hear. An NPC that speaks through anything else is section 7.

**The `tool` surface is where a mod author cannot be trusted.** See section 6.

### 2.6 `aowlspt/story` — seeded generation, quest graphs

**The surface.**

```
type Seed = distinct uint64
seedOf(parts: varargs[string]): Seed   # deterministic, order-dependent, stated
type Rng                               # from a Seed; no global state
type Quest, Step, Cond
graph(into: var Quest): Status
publish(q: Quest): Status              # into templates.quests, additively
progress(who: Eid; q: Quest; into: var Progress): Status
```

**What it hides.** That `templates.quests` is a database table and that
publishing into it is a `dbPatch`; that quest conditions have a shape the client
validates; that a generated quest must be *stable* across restarts, which is why
the seed is derived from stated parts rather than from a clock. `mods/tarkov`
already learned the clock lesson the hard way in `emu/ids.nim` and again in
`emu/rand.nim`.

**Where it collides with D13.** Publishing a quest is appending to a list.
`dbPatch` replaces lists. Either `story` reads-modifies-writes the whole table
under a claim (correct, expensive, and racy against another mod doing the same),
or the database grows a list-append operation. The sigil precedent (`?keys`)
says a `"?append "` path form is available for the price of one edit in
`backend/jsondb.nim` and no ABI revision. That is my recommendation, and it is
also a decision I do not get to make alone; see section 9.

### 2.7 What deliberately does not get a module

* **Persistence.** Another pillar. `world` takes a journal.
* **A file API and an HTTP client.** Both are real gaps (D10), both are wanted,
  and both belong to a general-API cleanup rather than to Timbuktu. Naming them
  here so the cleanup can cite a customer.
* **A UI.** Section 7.

---

## 3. Versioning and stability

### 3.1 The thing that makes this different from the C ABI

The C ABI is a boundary between two separately compiled binaries, which is why
it has `size` watermarks and appended-never-inserted fields. **`aowlspt/*` is
not that boundary.** These modules are nimony source, compiled into each mod's
own DLL. A mod carries its copy of `world` inside its own library, and nothing
at run time can disagree with it.

So the compatibility question splits in two, and conflating them is the mistake
to avoid:

| | breaks how | promise |
|---|---|---|
| **the procs** — `spawn`, `fit`, `knows` | at compile time, when the author rebuilds | source semver, deprecate-then-remove |
| **the wire** — event names, payload shapes, store key layouts, claimed system names | at run time, between two mods built at different times | protocol version, negotiated, refused on mismatch |

A mod written against `world` v1 keeps running unchanged when v2 ships, because
it was never linked against v2. It fails to *compile* against v2 if v2 broke
source. And it fails to *talk to* a v2 mod if the protocol version changed and
nobody negotiated.

### 3.2 The promise on the procs

* **Additive within a minor.** New procs, new fields at the end of an object,
  new enum members at the end. Never a changed signature, never a changed
  meaning of an existing status.
* **A removed proc is first a deprecated wrapper for one minor**, whose body
  calls the replacement and whose docstring names it. nimony has no
  `{.deprecated.}` that will warn usefully here, so the docstring and the
  changelog are the mechanism, which is weak and should be said so.
* **The gate is `pipeline`**, the existing field in `registry/mods.json`, a
  semver range matched against `hostVersion()` and implemented by
  `mods/manager/mgr/semver.nim`. A mod that needs `world` v2 declares
  `"pipeline": ">=0.2.0"`. This is imperfect and the imperfection should be
  written down: `pipeline` gates *loading* on the host's version, which is a
  runtime gate on what is really a compile-time fact. It is right often enough —
  a mod built in this tree is built against this tree's `aowlspt` — and it is
  wrong for a mod someone built elsewhere and shipped as a binary. **A mod's
  built-against pipeline version belongs in `ModInfo`**, where `sptRange` and
  `abiRevision` already are, and where D3 says nobody is reading anyway.

### 3.3 The promise on the wire

Every protocol carries an integer version in its envelope and negotiates it once:

```
claim("aowl.system.hideout", 2)     # I speak version 2
owner("aowl.system.hideout", o)     # o.version is what the owner speaks
```

Rules, all three taken from behaviour that already exists in this tree:

1. **A mismatch is a refusal with a sentence, never a silent downgrade.** The
   registry resolver's rule: *"A failure is reported, never repaired… A mod list
   that silently becomes a different mod list is worse than one that refuses."*
2. **An owner may answer an older version** if it chooses to, and says so in the
   negotiation. It may not answer a newer one.
3. **A field added to a payload is additive and a subscriber ignores it**, which
   is exactly what `docs/API-GAPS.md` gap 1 argues for `tarkov.raid.ended`: *"an
   empty string means 'the client did not tell us', never 'not applicable'"*, and
   a subscriber that treats a missing key and an empty value alike is the bug the
   convention prevents.

### 3.4 Store layout is a wire too

`store/<guid>/<key>` is per-mod and private, so a key layout change inside
Timbuktu breaks only Timbuktu. But `world` will want entities readable by more
than one mod, and the moment a second mod reads them the layout is a protocol.
Two options and I prefer the first:

* **Nobody reads another mod's store.** Cross-mod reads go through `ask`, which
  is versioned. Costs a round trip; buys the ability to change the layout.
* A shared store namespace with a schema version in every document. Costs a
  migration story nobody has written.

---

## 4. The replacement mechanism

### 4.1 Three layers, and each already exists

**Layer 1 — declared, before anything loads.** `registry/mods.json` already
carries `requires`, `conflicts`, `provides`, `loadAfter`, and
`mods/manager/mgr/resolve.nim:166` already turns *two mods providing the same
capability* into a conflict without either having heard of the other:

```nim
  for p in a.provides:
    for q in b.provides:
      if p == q:
        return "both provide " & p
```

Both are excluded, both get a `vConflict` verdict and a sentence, and nothing is
repaired. **This is the answer to "two mods both claiming to own the same base
system", and it needs no code — only a vocabulary.** Reserve `aowl.system.*`
for base-system replacements: `aowl.system.hideout`, `aowl.system.quests`,
`aowl.system.traders`, `aowl.system.raid`. Timbuktu declares
`provides: ["aowl.system.hideout"]` and the resolver does the rest.

**Layer 2 — runtime, first claimant wins.** Routes and detours already work this
way (D2). `claim()` should use the same rule and say so: the second `claim` of a
system answers `ErrGeneric` with `lastError()` naming the guid that got there
first. **Do not chain.** The argument against chaining a detour applies verbatim
to chaining a system claim: chaining means an ordering that nobody declared, and
the host would have to invent one. Order is `loadAfter`'s job, it is declared, it
is resolved deterministically, and the resolver already refuses cycles.

**Layer 3 — the shim, and it is the replacer's obligation.** A mod that still
expects the hideout, running beside Timbuktu, must not get silence. Concretely:

* **Not a refusal to load.** The manager refuses *providers*, not *consumers*. A
  mod that merely reads `hideout.areas` is not a conflict and must not be
  excluded.
* **Not a 404.** The client draws the hideout screen out of its own bundles and
  will open it whatever the server says. An unanswered `/client/hideout/*` is a
  hang, and a hang is worse than an empty hideout.
* **A truthful refusal.** Timbuktu, having claimed the system, answers those
  routes and those verbs with `failure(code, "the hideout is not used on this
  install; areas are built in the world")`. `mods/tarkov` already has the
  vocabulary for this: `docs/EMULATOR-REFUSALS.md` is a document of exactly such
  answers.
* **A capability answer for mods that ask.** A mod that calls
  `owner("aowl.system.hideout", o)` and gets a guid that is not `aowl.tarkov`
  can decide for itself. That is what `claim` is for, and it is the only path by
  which a well-written third-party mod degrades gracefully instead of guessing.

### 4.2 The one edit that unlocks all of it

`mods/tarkov`, at the top of `onItemsMoving` and at the top of each `/client/*`
handler for a claimed system, consults the claim table before its own dispatch.
Roughly thirty lines plus the `aowlspt/verb` module. Everything else in this
document is downstream of that edit, which is why it is first in section 8.

---

## 5. Server versus client

The vocabulary is `Side` — `sideServer`, `sideClient`, `sideSim` — declared in
`aowl/src/aowlspt/abi.nim:104` and reported by `side()`. A mod declares which it
supports in `exportMod(sides = {...})` and `host/common/modhost.nim:846` skips a
mod that does not claim the running side before `on_load` runs. The capability
matrix is `docs/ARCHITECTURE.md`, "The three hosts", and the two facts that
matter here are: the backend cannot reflect or patch, and the client host cannot
serve routes or read the database. *"Neither is a gap waiting to be filled."*

| module | server | client | sim | why |
|---|:---:|:---:|:---:|---|
| `aowlspt/claim` | yes | yes | yes | `emit`/`on` are revision 1 and universal. A claim made on one side is invisible on the other — the two hosts are different processes with different event buses — and that must be stated, not discovered. |
| `aowlspt/verb` | yes | — | yes | It is the item-event endpoint, which is HTTP. `ErrUnsupported` on the client. |
| `aowlspt/world` | yes | read-only | yes | The authority is the server: it has the store and the database. The client half is a *view* — "which entity is this pointer" — and is entirely speculative; see section 7. |
| `aowlspt/place` | yes | — | yes | Grids and templates are database and profile work. |
| `aowlspt/npc` | yes | partial | yes | Knowledge, dialogue and tools are server. Anything that makes an NPC *move* is client, is `mods/sain`'s territory, and is unproven. |
| `aowlspt/story` | yes | — | yes | Quest tables and progress are server. |

Two side notes that follow from D6 and belong in whichever module lands first:

* Ship `servesRoutes()`, `hasDatabase()`, `hasRuntime()` as the questions a mod
  actually asks, alongside `side()`. `sideSim` answers yes, yes, no — which is
  the shape five examples got wrong by writing the enum comparison directly.
* `sideSim` is not a lesser server. `aowlspt-sim` implements the store out of
  the same `host/common/modstore.nim` the backend does, which is why
  `mods/tarkov` can be driven with no server and no game. Every module here must
  run offline in the simulator, and a self-test that reports which of its
  bindings resolved is the established pattern (`aowl/src/aowlspt/fixture.nim`
  exists to make that safe).

---

## 6. What a mod author cannot be trusted with

Not a slight — a list of places where a plausible-looking mistake is
indistinguishable from correct behaviour until it is very expensive.

**1. Raw addresses across a frame.** Already true and already handled:
`pointerOf` documents that *"the collector moves objects between frames, and a
saved address then names whatever moved into that space -- which reads as a
plausible object rather than as a crash"*, and `docs/BACKLOG.md` lists "a stale
address cannot be refused" under the permanent boundaries. **`world` must never
hand back a pointer or a raw `Handle`.** An `Eid` names a row.

**2. Issuing an id.** `mods/tarkov/emu/ids.nim` is the whole argument. The API
must expose `newEid()` and must not expose the seed, the counter, or a way to
supply an id from outside. A mod that supplies its own id is a mod that collides
with a restart.

**3. Writing directly into another system's store keys or database paths.**
`dbPatch` merges and therefore looks safe; D13 says arrays do not merge. A mod
appending to `locations.<map>.exits` will believe it worked. `place` and `story`
must own their tables and expose an append that is actually an append.

**4. Deciding that "unreadable" means "absent".** Three mods rebuilt this
distinction (D9) and every one of them wrote a comment about the character that
got overwritten. `world.find` must answer a three-state enum, and there must be
no boolean overload of it, because the boolean overload is the bug.

**5. Holding a lock across a call that can block.** `aowlspt/sync` says it and
`mods/manager` had to invent a whole `…Locked` worker/wrapper split ten times
over to obey it. `claim`'s `ask` is a synchronous call into another mod's
handler — **`ask` must refuse, loudly, if called with the mod lock held**, or it
is a deadlock generator wearing a friendly name. That refusal needs a mechanism
`sync.nim` does not have today (the lock is opaque and not reentrancy-aware); it
is cheap to add a depth counter beside it.

**6. An NPC tool that writes.** `npc`'s `tool` surface is the point where a
model's output becomes a mutation. The tool interface must be **declare what you
want, do not do it**: a tool returns a proposed change, `npc` validates it
against the actor's knowledge and the world's rules, and the write happens in
one place that can refuse. `mods/tarkov`'s rule, stated in `emu/hideout.nim` and
enforced everywhere, is the model: *"resolve the whole requirement, verify every
part of it, and only then take anything… There is no transaction to roll back."*

**7. Suppressing a hook without asking for arguments.** Already refused by the
host, and worth naming because the reasoning generalises: *"a mod that believes
it is suppressing when it is not would be debugging the game instead of its own
registration."* Any `verb` handler that returns `handled` without having read
the batch element should be refused the same way.

**8. Trusting a payload from another mod.** `ask` crosses a trust boundary that
looks like a function call. Payloads are data. `claim` should hand a `JsonRef`,
never a parsed record the receiver did not check.

---

## 7. Open questions

Marked as questions because the answer needs either a real client, a decision,
or both.

**Q1. Can anything Timbuktu builds be *seen*?** The building pillar wants
physical structures. `docs/BACKLOG.md` Group A is unambiguous that there is no
managed type definition, no `MonoBehaviour`, no BepInEx, no prefab loading, and
that new `WildSpawnType` values cannot reach the client. What exists is: static
containers and loose loot points already declared in `locations.<map>`, which
the client instantiates from its own bundles. **The working hypothesis for
`place` is therefore "reuse a container the map already has", and whether a
server can add a static container at a position the level does not contain one
has never been tested.** If it cannot, physical building is confined to existing
container positions, and that changes the building pillar rather than this one.

**Q2. Does a server-side hideout refusal leave a broken screen?** The client
draws the hideout from bundles. A truthful `failure(...)` on
`HideoutUpgrade` is the right server answer; whether the client shows an error,
shows nothing, or hangs is unknown and is one session's observation.

**Q3. Is there any client-side reach for an entity view?** `mods/sway`
demonstrates real reach: `openIl2Cpp()`, `bindStaticField`, and a six-load walk
from `EFT.GameWorld` to the weapon's hands rotation, re-done every frame *"which
is what makes the raw pointers safe"*. So walking live objects works, against a
stand-in runtime. Every `EFT.` name in that walk is still a hypothesis
(`docs/BACKLOG.md` S5). `world`'s client half depends entirely on this and
should be designed as refusable.

**Q4. Can a mod be told which player a client-side fact belongs to?**
`notifyPush` needs a session; sessions live in one mod's store (D8). Until
`tarkov.session.bound` exists as an event — `docs/API-GAPS.md` gap 3, twenty
lines, no ABI change — Timbuktu cannot address a player from anywhere but the
route that player called.

**Q5. Does `emit` re-entrancy hold under a mod's own lock?** The host side is
sound: both hosts copy subscribers and release the registration lock before
calling. What is unverified is a mod calling `ask` from inside its own
`withModLock`, which is item 5 of section 6 and is a mod-side rule rather than a
host property. A test in the simulator settles it.

**Q6. Should `stateSave`/`stateLoad` be implemented, or removed?** D5 says they
are documented, taught, flagged, and dead. Timbuktu is the first thing here with
expensive in-memory state. Implementing them is a change in
`host/common/modhost.nim` plus two shim accessors; removing them means editing
`docs/MODDING.md`, `examples/lesson` and the `ModFlags` enum. Doing neither is
the current state and is the worst of the three.

**Q7. Does the client cache quest tables?** `story` generates quests at run
time. If the client reads `templates.quests` once at login, a quest generated
mid-session is invisible until relog. `mods/tarkov/emu/raid.nim` already hit the
equivalent for locations — *"a map added after the first `/client/locations` is
invisible until restart"* — and that is a server-side cache, not a client one.
Unknown for quests.

**Q8. What does a wall clock come from?** `nowMs()` is monotonic since host
start, by contract. `mods/tarkov` holds `gNowSeconds` and adds `nowMs() div
1000`. NPC memory decay and story pacing both want real time. Either the ABI
grows one (revision 6, a watermark cost) or `world` inherits `tarkov`'s trick
and its caveats. This is a decision, not a discovery.

---

## 8. The order things would have to be built

Each step is independently useful and each one is testable in `aowlspt-sim`
without a game.

**1. `aowlspt/claim`.** Capability declaration, `owner`, `ask`/`answer`,
`announce`. ~250 lines plus a chapter in `docs/MODDING.md`. Nothing else in this
document is reachable without it, and it closes D7 for every existing mod — the
three hand-rolled handshakes in `icebreaker`, `morebots` and `modcontrol` become
one. Ship it with the `aowl.system.*` vocabulary added to `registry/README.md`,
which closes the "two mods own the hideout" question at zero code cost.

**2. The `mods/tarkov` consultation edit, plus `aowlspt/verb`.** The thirty
lines at the top of `onItemsMoving` and the module that makes them addressable.
Until this lands, nothing can replace a base system. Gate it behind a self-test:
a fixture mod that claims a verb, and an `emutest` case that proves the base
chain still runs when nobody claims it.

**3. Two closures of existing gaps, because everything downstream wants them.**
`docs/API-GAPS.md` gap 1 (`tarkov.raid.ended` says what happened) and gap 3's
options 1 and 2 (`session` on the events that already fly, plus
`tarkov.session.bound`/`unbound`). Both are payload edits in one mod, no ABI
change, and both are already argued and costed by that document.

**4. `aowlspt/place`.** Extract `emu/grid.nim` and the container half of
`emu/loot.nim`, parameterise the template read, keep the emulator working on the
extracted module rather than on a copy. The first real proof that "collapse the
logic into the API" produces something a second mod can use.

**5. `aowlspt/world`.** Identity first — `Eid`, `newEid`, the three-state read —
against whatever `PERSISTENCE.md` settles on for a journal. The client-side view
is deferred behind Q3.

**6. The shared fact substrate, then `aowlspt/npc` and `aowlspt/story` over
it.** In that order, and with the substrate not exported: two vocabularies, one
store, one clock.

**7. The general-API cleanup that all of the above will have made obvious.**
`servesRoutes()`/`hasDatabase()`/`hasRuntime()` (D6); `ConfigValue.asText`
unquoting (D10, four copies); a text-file read (D10, four copies); `textList`
(D10, three copies); a fixed-point number formatter (D10, two copies); `semver`
promoted out of `mods/manager/mgr/` (D12); `jsonpath`'s validator made public so
`mgr/cfgscan.nim` stops importing across the tree (D11); a `Journal`-shaped
answer to "absent versus unreadable versus not mine" (D9); and `aowl new` (D15).
None of it is Timbuktu's, all of it is the "amazing API" the owner asked for,
and by this point each item has a customer that can be named.

**Not on this list, deliberately:** any new ABI revision. Everything above is
`emit`, `on`, `serve`, `dbGet`, `dbPatch`, `save`, `load` — revision 1 and 2 —
plus one optional `"?append "` path sigil that costs a backend edit and no
watermark. Revision 6 should be spent on a wall clock (Q8) or on per-caller
request serialisation (the thing `mods/tarkov`'s `gProfileVersion[64]` array is
a workaround for), and on nothing in this document.

---

## 9. Decisions that are the owner's, not this document's

1. **The module names.** `claim`, `verb`, `world`, `place`, `npc`, `story`. They
   match the repo's one-short-word convention; `claim` and `verb` are the two I
   invented and the two most likely to be wrong.
2. **Whether `mods/tarkov` accepts the consultation edit at all.** Step 2 makes
   the emulator serve a mechanism it does not use. That is the right trade and it
   is not mine to impose on the mod that is currently the whole game server.
3. **`"?append "` versus read-modify-write for list mutation** (§2.6, D13). The
   sigil is cheap and is a second reserved string in a namespace that has one.
4. **Q6 — implement `stateSave`/`stateLoad`, or delete them.**
5. **Q8 — spend an ABI revision on a wall clock, or inherit the emulator's
   trick.**
6. **Whether `npc` tools may write at all**, or whether every mutation goes
   through a verb the player performed. The conservative answer costs
   expressiveness; the permissive one puts a model's output on the write path.
