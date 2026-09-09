# The mod manager

`aowl.manager` 1.0.0 — the registry, your lists, and what is actually running.

A backend mod on the same public API as any other: `aowlspt`, `aowlspt/server`,
`aowlspt/json`, `aowlspt/sync` and nothing else. It has no private door into the host, which is
the same constraint the emulator is written under and for the same reason — a
manager that needed privileged access would prove the plugin API is not enough
to manage plugins with.

It reads `registry/mods.json`, resolves it against your own selection (active
lists plus per-mod overrides), persists that selection with `save`/`load`,
serves the whole thing under `/aowlspt/mods/…`, and `broadcast`s when it
changes.

**The one thing this mod must never do is remove its own way back.** Switching
the manager off is honoured all the way down: it drops itself, a host with live
control unloads it, and every `/aowlspt/mods/*` route goes with it — so nothing
running can undo it, and the selection on disk then says it is off, so a restart
does not help either. The only recovery is hand-editing a file. That happened
for real: a test host pressed the toggle on row zero and the install had to be
re-staged. Most of the design below is a consequence of that, and of one other
incident described in §2.

Proved by, all re-run 2026-08-19:

| tool | checks | invocation |
|---|---|---|
| `mgrguard` | **56** | `installer\build\mgrguard.exe` |
| `modresolve` | **164** | `installer\build\modresolve.exe` |
| `modclient` | **90** | `installer\build\modclient.exe` |
| `livectl` | **213** | `installer\build\livectl.exe --root <scratch> --backend backend\bin\aowlspt-backend.exe --port <n>` |

`livectl` needs `mods/{manager,tarkov,gameserver}/<name>.dll` staged under its
`--root`; point it at a scratch directory of your own, not at a shared build
tree.

And the sentence that stands over everything in this repository, which applies
to this mod more sharply than to most: **nothing here has ever run against
BSG's client. Not once.** The four tools above prove the server half -- the
resolution, the document, the wire, live enable and disable under load. The
client half is wired end to end and both ends of the *wire* are gated
(`modreport`, `modclient`), but the panel a player would actually press is
driven by hand only: nothing establishes that a toggle in the overlay reaches
`aowl_ov_sync_start`, reaches the backend, and comes back. Every sentence below
about what *the player* sees is therefore an argument from the code, not an
observation.

---

## 1. The selection document

`aowlspt-selection.json`, written **beside the mods**, decides what the *next*
start loads. `host/common/modhost.nim` honours it to the letter when it names at
least one mod. Its shape:

```json
{ "schema": "aowlspt.selection/1",
  "writtenBy": "aowl.manager",
  "side": "server",
  "registry": "<path to mods.json>",
  "load": ["aowl.manager", "..."] }
```

Three rules govern it, and each exists because its absence cost an install.

**`aowl.manager` is always in it, whatever the resolution said.** A resolution
can leave the manager out without any route having allowed it — select a local
list that does not inherit `aowl.list.core`, or adopt a registry whose lists
stop naming it. The mod keeps running and keeps serving, and `managerContradiction`
says so on the panel; but the document decides the *next* start, and the mod it
left out owns every route that could put it back. It goes at the front: it has
no `loadAfter`, nothing requires it, so no edge in the registry can be broken by
placing it there.

**The file is inert until a host reads it.** `/aowlspt/mods` reports
`selectionFile`, `selectionFileWritten` and `selectionFileRefused` — where the
document is, whether this run wrote it, and why not. It used to say a
`startupHonoured` field said whether a host had ever read it; there is no such
field, here or anywhere, and whether a host reads it is a fact about the host.

**What was already there is inspected before it is overwritten**
(`inspectSelectionFile`, once, at load), because three states have the same
symptom — "my selection is being ignored" — with the reason in a host log
nobody is reading:

* a copy in the **install root**, which `modhost.readSelection` looks at *first*
  and which this mod does not write. A stale one there wins over every document
  this manager produces, for ever, silently.
* a document written for **another side**. A host refuses it, correctly, and
  loads everything instead.
* a document whose `writtenBy` is not this manager — somebody's hand-edited
  recovery file, about to disappear.

---

## 2. When the document is deliberately **not** written

### What went wrong

A UTF-8 byte-order mark on this mod's `config.json`. The host's per-key lookup
could not find `activeLists` in a document that did not parse and answered "no
such key"; `readConfig` read that as the empty string, which is *also* what
`"activeLists": []` reads as; nothing was seeded; nothing resolved; and the
manager wrote down that the correct thing to load was **itself**. The next boot
loaded one mod out of ten and said nothing, because every layer involved was
doing exactly what it was told.

The BOM is stripped now. **That is not the fix.** The fix is that the manager
can no longer act on the difference between "you selected nothing" and "I could
not read what you selected" — because it can now tell them apart, and refuses
when it cannot.

The host cannot make this refusal itself. `modhost` refuses an *empty* `load`
array, at length and for the same argument — but the document that bricks an
install is not the empty one. It is the one naming **this manager and nothing
else**, which has the same shape as a legitimate ten-mod document, and the host
has no way to know which id in a `load` array is the manager. That id is known
here, so the refusal lives here: `mgr/writeguard.nim`.

### The rule

* A document naming **anything other than the manager** is always written.
  Whatever else is wrong, the player still has mods and still has a manager to
  change them with.
* A document naming **only the manager** is written **only when every input
  that could have produced it was intact**: the config parsed, the store was
  readable, the registry loaded and describes mods, every active list exists,
  the resolution had no problems in it, and the host reported a version the
  `pipeline` ranges could actually be checked against. Then it is an answer to a
  question somebody asked — a player who switched everything off is entitled to
  exactly that file — and it is written.
* Otherwise **the previous file is left exactly as it is**, and the refusal is
  logged with its reason. That is a state a person can still boot out of: the
  old order, or no file at all and a host that walks the directory and loads
  everything.

`selectionWriteFault` takes every fact it decides on as an argument
(`WriteFacts`) and reads no global, no file and no clock. The version that read
globals could not be tested, and **an untestable refusal is a refusal nobody
knows fires** — this project's recurring bug is a check that passes because the
thing it checks never happened. `mgrguard`'s 56 checks drive it directly.

---

## 3. There is no encoding for "no answer yet"

The client host lives in `EscapeFromTarkov.exe`. No event this mod broadcasts
will ever reach it, so it polls instead, and reports back on the query string of
that same poll:

    GET /aowlspt/mods/client/<hostver>?hs=<sid>&sq=<n>&r=<records>[&more=1]

| field | meaning |
|---|---|
| `hs` | the host **process**, 1..16 hex. Constant for one run of the game. A different `hs` means everything held here is about a process that no longer exists, and all of it drops back to unknown. |
| `sq` | decimal from 0, +1 on every real change. The same `sq` twice is a re-send, not new intent. |
| `r` | records joined by `!`, each `<guid>~<want><outcome>[~<code>]` |
| `more` | `1` when the rows did not all fit in the path. The rest arrive on later polls; the host rotates, so nothing is starved and no acknowledgement is needed. |

### The outcome letters

| letter | meaning | is it running? | is it settled? |
|---|---|---|---|
| `n` | nothing to do; it was already in that state | as wanted | yes |
| `k` | attempted, and it worked | as wanted | yes |
| `s` | **not attempted**; the code says why | the opposite of wanted | no |
| `r` | attempted, refused, and refused after a restart too | the opposite of wanted | no |
| `d` | attempted, refused **live**; the change holds on restart | the opposite of wanted | no — this is the only letter that means "restart and it will be so" |

`n` and `k` are the same answer deliberately: `k` is transient — the tick after a
load succeeds the mod is simply in the state it was asked for, and the next poll
reports `n`. A manager that read `k` as a state and `n` as a lesser one would
have every successful change appear to regress one poll later.

`s`, `r` and `d` all mean the mod is **not** where it was asked to be. The host
only records them for a mod whose live state differs from the wanted one, so the
running state is the opposite of what was wanted — a fact rather than an
inference; the host looked before it said so.

### The codes, and the sentence each becomes

| code | what the player is told |
|---|---|
| `noartifact` | the registry gives it no artifact to load |
| `nofile` | it is not installed on the client side |
| `nopath` | the client host was given no path to load it from |
| `missing` | the client loader reported success and left no live mod behind |
| `wrongguid` | that library announces a different guid |
| `loadfailed` | the client loader refused it; the host log has the reason |
| `noteardown` | that host cannot take any mod out while it runs |
| `unloadfailed` | the unload itself failed; the host log has the reason |

A slug outside this closed set is kept and rendered verbatim but is never given
a sentence: a manager that invented an explanation for a code it does not know
would be putting a future host's words in its own mouth.

### The rule itself

**A guid with no record is a guid this host has not answered about.** `more=1`, a
host that has not polled, a host too old to report at all, a record dropped for
being malformed, a row refused for the table's 256-row cap — all of them
converge on *absence*, and absence is **unknown**. Never "no", never "off",
never "not running".

That is enforced structurally, not by convention. Every accessor that can narrow
a mod's state comes in two parts: `clientKnows(guid)` says whether there is a
record, and `clientRunning(guid)` reads it — and `clientRunning` is documented as
**meaningless** unless the first is true. Callers do not use them directly; they
use `liveVerdict`, which cannot be asked the question without also being told
what is known. **This project has shipped the collapse of those two twice.** The
shape of `mgr/clientreport.nim` is what stops a third time, and 6 of
`modclient`'s 90 checks are about nothing else.

`liveVerdict` arbitrates both hosts at once — "a fact beats a silence, and two
silences are a silence":

1. either host says it is running → **running**;
2. every host that *could* be running it has said it is not → **stopped**;
3. anything else → **unknown**, rendered as JSON `null`, which the overlay reads
   as "leave this row alone".

Which hosts could be running it is the registry's `sides`. A mod that runs on
both, listed as absent by the server and unmentioned by the client, is unknown —
the client is where it would be running, and nobody asked it.

Reports are **merged, never used to rebuild the table**: a poll carrying three
rows out of nine said nothing about the other six, and clearing them would turn
the host's rotation into six mods flickering to unknown and back for ever. The
one exception is a report *without* `more=1` — that is the host's whole ledger,
so rows it does not mention are rows it has dropped, and those go back to
unknown, which is what they are.

On the panel, `clientLive` / `clientOutcome` / `clientCode` are **absent from
the row entirely** when nothing is known, rather than false. The overlay's JSON
reader is about 130 lines of C — it was 60 before it became a structural walker
— and leaves a field it cannot find alone.

---

## 4. The failure table

What each damaged input looks like, what the player sees, and how they get back.

| what is wrong | what the manager does | what the player sees | the way back |
|---|---|---|---|
| **`config.json` absent** | `cfgAbsent`. Nothing is seeded. If the resolution is then degenerate, the document is refused. | The previous `aowlspt-selection.json` stands; the status route names the fault. | Nothing is lost — lists and overrides are in the mod's own store. Restore the config or delete the selection file to go back to loading everything installed. |
| **`config.json` empty or unparseable** (BOM, truncation, trailing comma, UTF-16) | `cfgUnreadable`, from the host's own `ConfigValue.faulted` — **not** from a second parser in this mod. The degenerate document is refused with the sentence *"a config that cannot be read produces the same empty answer as a config that selects nothing, and only one of those is something you asked for."* | An `error` line naming the file, and the old selection untouched. | Fix the file and restart. |
| **`activeLists` present but not an array** | `cfgListsBad`; treated as naming no lists, and the guard's belt-and-braces check fires if nothing was ever stored. | Same refusal, different sentence. | Fix the file. |
| **registry absent or unreadable** | `registryOk` false. Refusal: *"there is no registry to resolve against: …"* | The status route carries `registry.error`. | Point `registryPath` at a checkout, or reinstall the registry. |
| **`mods.json` truncated** | `wholeJsonObject` refuses it **whole**. A scanner does not fail on a truncated document — it parses as whatever survived, and a half-read manifest is a mod list nobody chose. | *"…is not one complete JSON object — truncated, or not a registry at all."* | Re-fetch or `git checkout` the file. |
| **`mods.json` from another schema** | Refused whole. A half-understood registry loads five of your seven mods and says everything is fine. | *"declares schema "X"; this reader knows …"* | Update the manager, or revert the registry. |
| **`mods.json` parses but has no mods** | Warned, and the degenerate document refused: *"a registry with nothing in it selects nothing, which is not the same as you selecting nothing."* | Panel shows zero rows and the warning. | Restore the manifest. |
| **one bad entry in `mods.json`** | Reported and skipped at **entry granularity** — one mod with a broken `requires` block must not take the other seven down. | A warning naming the entry; the rest resolve. | Fix that entry. |
| **selection store truncated** | `ssCorrupt`. `selectionUsable()` is false, so **nothing writes** — `setLists`, `setOverride`, `putLocalList` and `deleteLocalList` all return false and change nothing in memory either. | *"the stored selection is not usable: … It is left on disk as it is."* | Fix it or delete it and restart. Deleting seeds the config's defaults. |
| **selection store from another schema** | Same refusal. `aowlspt/json` scans, so such a document does not fail to read — it reads as whatever fields happen to still be spelled the same, and saving that reading back destroys the half it could not understand, with no copy. | Same sentence, naming both schemas. | Delete it (losing the setup) or downgrade/upgrade the manager to match. |
| **selection store unreadable** (store error) | `ssUnreadable`. No selection is in effect and nothing is written. Seeding the defaults here is what "the manager silently forgot my setup" looks like from the inside. | *"the stored selection could not be read (…). … the file itself is untouched."* | Fix the store; the file is intact. |
| **no store at all** (host older than ABI revision 2) | `storeWorks()` false. The selection is in effect for this run only. | *"it is in effect for this run only"* on every change. | Update the host. |
| **a selection written for another side** | Detected at load and reported; the host refuses such a document and loads **everything** instead. | *"…was written for the client side and this manager is the server one."* | Delete it; this manager rewrites it. |
| **a selection in the install root** | Detected. That copy is read *first* by the host and this mod never writes there. | *"Until it is deleted, nothing you change here decides what loads at the next start."* | Delete the one above `mods/`. |
| **an active list the registry does not have** | Resolution reports it; if the result is degenerate, the write is refused naming the list. | *"the active list X is not in <path>, so nothing could have been selected by it"* | Re-add the list, or select another. |
| **the host's version is unreadable** | `pipelineChecked` false — every `pipeline` range was skipped, so **no mod was ever really considered**. Degenerate result refused. | The refusal quotes the version string the host reported. | A host that reports its version. |
| **another mod's `config.json` is broken** | `mgr/cfgscan.nim` scans the resolved order **once**, at load. | The panel says which mods are running on defaults. | Fix and restart — a config repaired mid-session has not been re-read by the mod it belongs to either, which is why re-scanning would lie. |

Two things are true of every row: **your lists and overrides live in this mod's
own store and are never touched by any of these failures**, and a refusal is
always louder than the thing it refuses. The store is written whole, every time,
through the store's own durable commit, so a kill mid-write leaves the previous
selection rather than half of this one.

---

## 5. Where your choices live, and why not in the registry

Three pieces, in the mod's store, never in `mods.json`:

* **`lists`** — an ordered set of list ids. Shared documents; changing one is
  changing *which* curated set you are playing.
* **`overrides`** — your own per-mod enable/disable, applied after every list.
  An override is remembered even when the mod it names is in no active list, so
  switching lists and back does not lose the fact that you turned one thing off.
* **`local`** — lists *you* wrote, stored here **in full** rather than by id.

The registry is somebody else's git repository. Writing your choices back into
it would make every `git pull` a merge conflict and make "share my list" mean
"share my machine's state". And the registry can be *replaced* — `mgr/refresh.nim`
can adopt a fetched `mods.json`, and `aowlspt-install` overwrites the installed
copy every time it runs — so a list that lived in that file is a list either of
those could silently delete. "My raid night setup vanished after an update" is
the failure this split exists to prevent.

`withLocalLists` merges your lists in *after* the registry is read, so
resolution cannot tell yours from a published one. An id collision **wins for
you, and is said out loud**: the other way round, a refresh could silently take
over the meaning of a list you wrote. A local list may `inherits` a registry
list, which is the intended shape — you keep pointing at somebody else's curated
set and your own document is three lines of difference on top. The cost is that
a local list can go stale by naming a mod the new registry lacks; that is
**reported, never repaired**, because deleting an entry out of somebody's list to
make it resolve is exactly the silent edit this is arranged against.

---

## 6. The routes

    GET  /aowlspt/mods                what this is, and a one-line summary
    GET  /aowlspt/mods/status         the same route under a second name
    GET  /aowlspt/mods/list           every mod, its verdict and the reason
    GET  /aowlspt/mods/panel          the same, flattened for the in-game overlay
    GET  /aowlspt/mods/client         the desired set, resolved for the client side
    GET  /aowlspt/mods/client/<ver>   the same, against that client host's version
    GET  /aowlspt/mods/clientreport   what the client host said came of it
    GET  /aowlspt/mods/lists          the lists in the registry
    GET  /aowlspt/mods/conflicts      only the problems
    GET  /aowlspt/mods/describe/<id>  one mod, in full
    GET  /aowlspt/mods/enable|disable|clear/<id>
    GET  /aowlspt/mods/select/<id>    make one list the active list
    POST /aowlspt/mods/select         {"lists":["a","b"]}
    POST /aowlspt/mods/toggle/<id>    {"enabled":true} -- set it and apply it
    GET  /aowlspt/mods/reload         re-read the registry from disk
    GET  /aowlspt/mods/apply          push the current selection at the host
    GET  /aowlspt/mods/registry[/fetch|/fetch/force|/revert]
    POST /aowlspt/mods/lists/local    create or replace one of *your* lists

Every route also accepts `{"id":"…"}` in the body, because a browser can reach a
path and a script would rather send a document. Every route reports the truth,
per change, in `outcome`: nothing here claims to have enabled a mod that is not
running. `/panel` and `/toggle/<id>` are the two the in-game overlay speaks, and
`/panel` is flat because the overlay's reader is a hand-written structural JSON
reader in C that builds no tree and allocates nothing — the rule is
that if the shapes do not fit, the *server* flattens them.

A client-only mod reads as `wrong-side` on `/list` and `/panel`, correctly:
that is the **server's** resolution and it is not loading there. What the game
was told is on `/client`; what the game did is on `/clientreport`.

---

## 7. What a raid — or a real install — would be the first to disprove

1. **That the refusal in §2 fires when it should.** It is proved by `mgrguard`
   against synthetic `WriteFacts`, which is exactly the point of taking them as
   an argument. It has never been proved by a real BOM on a real config on a
   real install since the fix.
2. **That the shipped `writeSelectionFile: true` is safe.** The guard covers the
   degenerate document. It does not cover a resolution that is *wrong* while
   naming ten mods — a bad registry that resolves confidently is written down
   without complaint, by design, because "wrong" is not a thing this mod can see.
3. **That the document is ever honoured at startup.** It is documented as inert
   until a host reads it, and nothing on `/aowlspt/mods` can say whether one
   has — this item used to name a `startupHonoured` field that does not exist. Whether the client host in a shipped install actually
   reads it is a fact about that host.
4. **That the client's `hs`/`sq` scoping survives a real game restart.** A new
   process id drops the whole table to unknown; that path is exercised by
   `modclient` with synthetic polls, not by a game that actually crashed and
   came back.
5. **That absence never renders as "off" anywhere downstream.** It is enforced
   at the accessor here. The overlay merges these rows with rows the client host
   pushes in directly, by guid, and that merge is on the other side of a process
   boundary from every check listed above.
6. **That `aowl.manager` cannot be switched off.** `isProtected` covers the
   toggle route, `applySelection` and the selection document. It does not cover
   somebody hand-editing `aowlspt-selection.json` — which is, deliberately, also
   the only way back in.
