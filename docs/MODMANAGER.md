# Changing the mod set while the server and the game are running

The question this document answers: **can a mod be enabled or disabled without
restarting anything?**

Short answer, as of this writing:

| | can a mod be turned off and on live? | proven by |
|---|---|---|
| `aowlspt-backend` (server) | **yes**, fully | `aowl test` → "Live mod control", `tools/livectl.nim` |
| `aowlspt-host-il2cpp` (client) | **the mechanism is wired end to end, and it reports back**, but has never been run against BSG's client | the mock runtime under `tests/mockil2cpp`; the wire itself by `tests/modreport` (the host half) and `tests/modclient` (the manager half) |
| `aowlspt-sim` | **yes** — it loads one mod, and `modcontrol` is wired the same way it is on the backend | `aowl run <mod>`, and `--emit aowlspt.host.mods.list` |

Nothing here needs a mod rebuild, an ABI revision, or a change to
`aowlspt_abi.h`. The whole facility is built on the event channel every host
already has.

## What happens when you flip the switch

The manager (`mods/manager`, guid `aowl.manager`) is an ordinary backend mod. It
reads `registry/mods.json`, resolves it against your selection, and serves the
result:

```
GET  /aowlspt/mods                 what this is, and whether control is live
GET  /aowlspt/mods/panel           the same, flattened for the in-game overlay
GET  /aowlspt/mods/disable/<id>    override it off
GET  /aowlspt/mods/enable/<id>     override it on
POST /aowlspt/mods/toggle/<id>     {"enabled":true} — set it and apply it
GET  /aowlspt/mods/apply           push the current selection at the host
GET  /aowlspt/mods/client/<ver>    the desired set, resolved for the client side
GET  /aowlspt/mods/clientreport    what the client host said came of it
```

Your choice is written to the manager's own store, never into the registry, so a
`git pull` in a registry checkout can never conflict with what you switched off
last night.

`/aowlspt/mods/apply` states **the whole desired set**, not a diff. The manager
cannot know what the host has without asking, and a diff computed from a stale
picture is how you end up with two copies of a mod loaded.

Read `"control"` out of `/aowlspt/mods` to find out what will actually happen:

* `present` — the host answered and can load and unload. Changes take effect
  now.
* `absent` — a host answered but cannot unload. Changes are saved and take
  effect on the next start.
* `unknown` — nothing has answered the probe yet.

`"liveChanges":true` is the same claim in one field. A manager that reported
"disabled" for a mod that is still serving would be worse than one with no live
control at all: the first is a missing feature, the second is a lie you act on.

## The protocol

`host/common/modcontrol.nim` is the host half, and it is shared by both hosts —
the wire is the same on either side and two implementations of it would drift.
`mods/manager/mgr/control.nim` is the mod half. The *loader* underneath both is
shared now too: `host/common/modhost.nim` owns discovery, the version probe,
`describe`/`init`/`on_load`, the mod table and `unloadOne` on both sides. The
client host used to carry its own copy of all of it.

```
aowlspt.host.mods.probe    {"from":"<guid>"}
  -> aowlspt.host.mods.capabilities
     {"host":"...","version":"...","control":true,"load":true,
      "unload":true,"reloadNeedsRestart":false}

aowlspt.host.mods.load     {"guid":"...","path":"<absolute .dll>"}
aowlspt.host.mods.unload   {"guid":"..."}
  -> aowlspt.host.mods.result
     {"guid":"...","action":"load"|"unload","ok":...,"deferred":...,
      "error":"..."}

aowlspt.host.mods.list     {}
  -> aowlspt.host.mods.listed
     {"mods":[{"guid","name","version","path","live","hotReloadable"}]}
```

Events rather than new ABI functions, deliberately: the channel already exists
on every host, so this needed no header change, no revision bump and no rebuild
of any mod that does not care. The host becomes a subscriber to a reserved
`aowlspt.host.*` namespace and answers by emitting.

Two rules the host must keep, and both are things a manager cannot work around:

* **Every request produces exactly one `result`, failures included.** Silence
  is indistinguishable from a host that never implemented any of this, and the
  manager would sit in `unknown` forever.
* **`load` is idempotent.** A guid that is already live answers `ok:true` and
  does nothing, because `/apply` restates the whole set on every call.

The reply to a control request is `requested`, not `applied`: the host has taken
the request, and the outcome arrives in the next `result`. That is a consequence
of the next section.

## Queue, then drain

Nothing is loaded or unloaded inside the emit. `submit` records the request and
returns; `drain` performs it, from the host's own loop.

The reason is specific and fatal. `broadcast` is delivered **synchronously**. At
the moment a control request arrives, the stack runs through the manager's route
handler — and, for an unload, quite possibly through the mod being unloaded.
Calling `FreeLibrary` there means returning into unmapped memory.

So there is exactly one place in each host where a mod is loaded or unloaded
while it is running:

* `backend/aowlbackend.nim` — `modcontrol.drain()` in the serve loop, once a
  tick.
* `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` — `modcontrol.drain()` in the tick
  loop, immediately after `takeModSet()`.

`drain` takes the queue wholesale before it runs anything, because performing a
request can emit, which can queue another request, and appending to a sequence
being walked by index is how a request runs twice or never.

The teardown is the other half of the danger. `unloadOne` calls the mod's
`on_unload`, then a teardown the *host* supplies which drops every route, event
subscription, timer and detour the mod registered, and only then frees the
library. Anything the teardown misses is a call through a function pointer into
memory that has been unmapped: a route still served, an event still delivered, a
detour the game still jumps to. See "Unloading" in [ABI.md](ABI.md).

**And the teardown cannot drop a pointer a thread is already carrying.** The
backend's `matchRoute` copies a route out under the registration lock and
`runRoute` calls it with no lock held — deliberately, because a handler may
register a route and a walk holding the lock across the call would wait on
itself. So a worker can be between the copy and the call, or inside the call, at
the moment the control thread reaches `FreeLibrary`. That is closed by a
reference held across the dispatch: `modhost.modEnter` before the call and
`modLeave` after it (`host/common/modhost.nim:273`, taken at
`backend/aowlbackend.nim:941` for routes and `:1148` for the event fan-out —
re-derived 2026-08-19; those two were `:936` and `:1117`, which by then landed
in the comment above the call and in another proc's doc comment. `modhost:273`
is still exactly `proc modEnter*`. Note that `backend/aowlbackend.nim` is under
active edit, so these two will move again), and
`unloadOne` sets a draining flag, waits up to `DrainDeadlineMs` (5 s) for the
count to reach zero, and gives up and leaves the mod loaded rather than freeing
it out from under somebody. The ordering is the whole of it — `modEnter`
increments *then* tests the flag, `drainMod` sets the flag *then* reads the
count — and the flag and counter live in fixed C storage indexed by the mod's
slot rather than in `gMods`, which grows from the control thread while workers
read it.

A worker turned away by the drain is **answered**, not dropped: it gets a
refusal, which in the server is a 503. The cost of the pair is 7.3 ns against a
route handler's ~423 µs, two thousandths of one percent — which is why a
refcount is right here and wrong on a detour firing, where the call itself is
2.9 ns and trampolines are retired instead.

**7.3 ns is the source's figure and it is for the bare interlocked pair**
(`host/common/modhost.nim:164`, `backend/aowlbackend.nim:949`), not for
`modEnter`/`modLeave` with their bounds check and their second load.
[ARCHITECTURE.md](ARCHITECTURE.md) quotes 11.2 ns for the shipped bodies and
33 ns under sixteen threads. Neither figure was re-derived on 2026-08-19,
because nothing in this tree measures either: `modrace` counts answers and has
no timing mode. Both are plausible and only one of them can be describing the
same thing; treat them as unverified rather than as two documents agreeing.

`backend/modrace.nim` is the reproducer, and **`aowl test` runs it.** This
paragraph used to say it was "the one gate here that `aowl test` does not run:
nothing in `tools/aowl.nim` mentions it and no `modrace.exe` is built by the
gate". That stopped being true: `tools/aowl.nim:1297-1314` compiles
`backend/racemod.c`, builds `modrace.exe` and runs it as
`--cycles 24 --workers 16` under the check "a mod unloaded under live callers
never answers from a freed library". Re-derived 2026-08-19.

It is also a clean before-and-after out of one binary — `--unguarded` skips
`modEnter`/`modLeave` and nothing else. Run by hand at its defaults, 8 workers
and 40 cycles, on 2026-08-19:

```
backend\bin\modrace.exe               45527 answers, 29552 clean refusals,
                                      220674 empty tables, no fault and no
                                      stale answer across 40 unloads under
                                      8 threads
backend\bin\modrace.exe --unguarded   8 of 8 workers faulted -- a call into a
                                      freed image, and 4 answers came from
                                      another incarnation of the mod
```

The three counts are throughput and move run to run; the counts that matter are
the two zeros. At the gate's own size the unguarded run faults **16 of 16**,
which is the number [ARCHITECTURE.md](ARCHITECTURE.md) quotes.

## The client half, as the source has it

Read `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` if this section and the code ever
disagree; the code is the document of record.

`hostMain` installs this host's teardown — `modhost.setModTeardown(
dropModRegistrations)` — before it loads a single mod, then calls
`startModControl()` once the mods are up and the overlay has started, which
hands `modcontrol` this host's `HostOps`. The unload wrapper goes through
`modhost.unloadByGuid`, which runs the mod's `on_unload`, then
`dropModRegistrations` (event subscriptions, pending main-thread callbacks under
the drain's lock, and **detours**, each one removed through `cHookRemove`), and
only then `FreeLibrary`. `opsCanUnload` asks `modhost.hasTeardown()`, which is
true in every run that reached `hostMain`: the loader is what refuses an unload
without a teardown, and a capabilities reply that disagreed with it would offer
a switch that always answers "deferred".

The other seam this host uses is `modhost.setHostBlockArm`, which is how
`aowl_hostapi_arm_live` still runs per mod: the revision-3 live-object entries
mean nothing without a managed heap, so the shared builder leaves them null and
this host fills them in before `aowlspt_init` sees the block.

That wires it into the *event* protocol. On the server that is the whole story,
because the manager and the host share a process and therefore an event channel.
On the client they do not — nothing in the game process ever emits
`aowlspt.host.mods.unload`. So the client **asks** instead:

* `aowlspt-host.json` beside the host DLL carries `backendPort` and
  `modSyncMs` (3000 by default; `0` switches the whole thing off, and a missing
  `backendPort` does too, with a line in the log saying so).
* `overlaySyncStart("/aowlspt/mods/client/" & HostVersion, modSyncMs)` puts the
  poll on the overlay's worker thread — the one HTTP client already in the
  process. The host's own version goes in the path so the manager checks each
  mod's `pipeline` range against the *client* host, not against the backend.
* `takeModSet()` runs on the tick, reads the newest whole answer, and hands it
  to `applyDesired`, which appends to the same queue the manager's own requests
  land in. `drain` performs it on the game thread.

The direction is the safety argument: the backend is **asked**, never listened
to. `parseDesired` refuses a body that fails any of four checks — `schema`
(`aowlspt.clientset/1`), the manager's own `ok`, a trailing `complete` key the
manager writes last, and a `count` that must equal the rows actually read. The
last two exist because the reader is fed by a fixed buffer inside the game
process, and a body cut in half by that buffer parses perfectly and says the
mods that did not fit should be unloaded. Every failure of the far end — down,
starting, restarting, serving a 404, serving too much — converges on "leave the
mods alone", because the only thing that can move a mod is a complete document
that says so.

Two more rules on this side:

* **A mod the backend does not mention is left exactly as it is**, and named
  once in the log. A DLL dropped into `mods/` by hand is somebody's deliberate
  act and the registry has no opinion on it.
* **One attempt per change, not one per poll.** A load the host refuses is not
  retried until the backend's answer for that mod changes.

## What came of it: the client host's report

The poll above is a question. It now carries an answer to the *previous* one,
on its own query string:

```
GET /aowlspt/mods/client/<hostver>?hs=<sid>&sq=<n>&r=<records>[&more=1]
```

| | |
|---|---|
| `hs` | the host **process**, 1..16 of `[0-9a-f]`, constant for one run of the game |
| `sq` | decimal from 0, `+1` on every real change to any row |
| `r` | records joined by `!`, each `<guid>~<want><outcome>[~<code>]` |
| `more=1` | the rows did not all fit in the path; the rest come on later polls |

`<want>` is `+` for "should be loaded" and `-` for "should be unloaded".
`<outcome>` is one letter from a closed set:

| | |
|---|---|
| `n` | nothing to do — it was already in that state |
| `k` | attempted, and it worked |
| `s` | **not attempted**; `code` says why |
| `r` | attempted and refused, live — and a restart will not change that |
| `d` | attempted and refused *live*; the change holds on restart |

`<code>` appears only on `s`, `r` and `d`, and is one of `noartifact`,
`nofile`, `nopath`, `missing`, `wrongguid`, `loadfailed`, `noteardown`,
`unloadfailed` — a slug, never a sentence. The sentence is in the host's log,
where it can be as long as it needs to be.

It rides the poll rather than a channel of its own because a second channel
needs an HTTP client, a socket and a thread inside a DLL injected into a running
game, and all three of those exist exactly once over there — in the overlay, for
the panel. Riding the poll costs a longer path on a request that was being made
anyway. The path is capped at 191 characters by `aowl_ov_sync_start`, which is
what pays for one letter per outcome and a rotation instead of a full dump.

Three rules, and the first is the one everything else is arranged around.

**There is deliberately no encoding for "no answer yet".** A guid with no record
is a guid this host has not answered about. `more=1`, an old host, a host that
has not polled yet and a record thrown away for being malformed all converge on
*absence*, and absence means unknown — never "no", never "off", never "not
running". The manager may only narrow a mod's state on a record it actually
received. `mods/manager/mgr/clientreport.nim` is shaped around making that hard
to get wrong: `clientRunning` is documented as meaningless unless `clientKnows`
is true first, and the arbitration everything actually calls, `liveVerdict`,
cannot be asked the question without also being told what is known.

**The query is a report, not a filter.** The body served is byte-for-byte the
body the bare route serves. A manager that answered a filtered set to a
reporting host would have the report change the thing it reports on — and the
host would then act on the filtered answer and unload what it had just told the
truth about.

**`k` is transient.** One poll after a load or an unload succeeds the mod is
simply in the state it was asked for, and the next report says `n`. Both mean
"this mod is where you wanted it"; `k` only adds "and this host is the one that
just moved it". A manager that read `k` as a state and `n` as a lesser one would
have every successful change appear to regress a second later.

### What the manager does with it

* **`live` on the panel is no longer the server's alone.** It is
  `clientreport.liveVerdict`: *running* when either host says so, *not running*
  when every host that could be running it has said so, and **null** otherwise.
  Which hosts could be running it is the registry's `sides`, so a client-only
  mod is not answered for by the server's inventory however complete that
  inventory is — before this, such a row read `live:false`, which was the
  server truthfully answering a question about the wrong process.
* **The `*` (restart) marker on a client row is a fact where there is one.** A
  `d` from the game raises it; so does an `s` or an `r`, because what is running
  is not what you asked for. Where the client host has said nothing the marker
  falls back to what it always was — this selection against the one the manager
  started with.
* **The row carries the client's own words.** `clientLive`, `clientWant`,
  `clientOutcome` and `clientCode` on `/panel` and `/list`, plus the sentence
  appended to `reason`. They are **absent from the row entirely** when there is
  no record: absence is how this protocol says "no answer yet", and a `false`
  there is exactly the collapse the wire refuses to encode.
* **A different `hs` drops everything.** The outcomes are scoped to one run of
  one game; holding "refused" from the session before last and drawing it
  against the client running now is a fact about a process that no longer
  exists.
* **A complete report is the whole ledger.** Rows a report *without* `more=1`
  does not mention are rows the host has dropped, and they go back to unknown.
  A report *with* `more=1` leaves everything it did not mention exactly as it
  was — the rotation is not an erasure.

```
GET /aowlspt/mods/clientreport
```

is the ledger as the manager holds it, and answers the two questions a panel row
cannot: which guids there is an answer for at all, and whether a row reads
unknown because the rotation has not reached it (`more`), because no host has
ever polled (`reporting:false`), or because the record was refused.

What the client half does *not* do: honour load order *while running*. The
manager resolves an order and `applyDesired` applies a set. It has not mattered
because the client-side mods do not depend on one another; when it does, the fix
is to sort by the order the backend already computes.

## The selection at startup

The manager writes what it resolved to `aowlspt-selection.json` — the schema,
the side it is for, and `load`, which is every mod id in the order they should
come up. `modhost.loadAll` reads it, on both hosts — but only one document is
ever written, and it is stamped with the side of the manager that wrote it, so
in practice **it is the server's startup that this governs**. See "Which host
this actually governs" below before relying on it for the client.

What it governs:

* **Which mods load.** A mod that is installed and not in `load` is not
  started at all — no `on_load`, no database writes, no routes. Before this it
  was loaded like everything else and only taken out later, if
  `/aowlspt/mods/apply` was called; on a host with no live control, never. So a
  panel row reading `not-selected` was a mod that was still serving.
* **In what order.** `loadAfter` in the registry is the manager's to resolve
  and this is where the answer is used. Before, the order was whatever
  `collectEntries` returned — a directory walk — and SAIN could come up before
  MoreBots against the registry's own instruction.

Mods are matched to the file by **guid**, not by filename: each candidate
library is opened, asked what it calls itself through `describe`, and put back
down without being initialised. Nothing that is not selected ever runs a line of
its own code.

**Four ways of not having a selection, and all four load everything**, which is
what a fresh install needs and is exactly what this did before:

| the file | what happens |
| --- | --- |
| absent | the directory walk, silently — nobody has chosen yet |
| present, unreadable or truncated | the directory walk, with a `warn` naming the file |
| present, written for another side | the directory walk, with a note; a client host does not act on the server's document |
| present, `"load": []` | the directory walk, with a `warn` |

The last one is the interesting refusal. A working manager always names at least
itself — its row is protected so that a selection cannot switch off the thing
that would switch it back on — so an empty list is never "the player chose
nothing". It is what the manager writes when it could not resolve anything at
all, which is what happens when its own stored selection is damaged. Honouring
it would take the manager out at the next start along with every route that
could put it back. `livectl` produces exactly that document on purpose.

A selection that names mods and matches none of them installed is refused the
same way and for the same reason: a stale file, or a copy from another install,
must not be able to leave a host running nothing.

**A fifth case, which the manager refuses rather than the host.** A `load` that
names ten mods and not the manager is an install with the same "no way in" as an
empty one: the host honours it, the manager does not come up, and every
`/aowlspt/mods/*` route goes with it. The host cannot see it — it has no idea
which of ten ids is the manager — so `selectionDocument` puts `aowl.manager` in
the array whatever the resolution said, at the front, and the panel says out
loud that the selection and the process disagree. Reachable without any route
having allowed it: a local list that does not inherit `aowl.list.core`, a
refreshed registry whose lists stop naming the manager, or a hand-edited store.

### Which host this actually governs

The manager declares `sides: ["server","sim"]`, so on a real install it runs in
the backend and the document it writes says `"side":"server"`. `readSelection`
checks the side and refuses a document written for another one — for a good
reason, since a client host acting on the server's list would unload every
client mod it has, none of which is named there.

So **the client host's startup is a directory walk, always**: every installed
client mod runs its `on_load`, installs its detours and starts ticking, and the
manager's decisions only reach it seconds later, when the first
`/aowlspt/mods/client/<ver>` poll lands and `applyDesired` unloads what should
not have been there. That is a set, not an order, and it is after the fact.

Nothing today writes a client-side selection document. Closing it means either a
second file the client host reads (`side: "client"`, resolved by the same
manager through the same `resolve` call the client route already makes) or the
client host learning to read the server's document and act only on the rows for
mods that declare its side. The first is the honest one — the resolution for the
client is a different resolution, not a filtered view of the server's — and it
needs a change in `host/common/modhost.nim` as well as in the manager, which is
why it is written down here rather than done.

The order therefore takes effect **at the next start** — which is what the panel
has always said about a change on a host with no live control. A brand-new
install has no selection file until the manager has run once.

## What is refused, and why refusing is the feature

**No teardown registered → deferred to restart.** A mod is taken out only when
the host can prove it left nothing behind. Without `setModTeardown`, `unloadOne`
refuses, and `modcontrol` reports that as `ok:false, deferred:true` — "on
restart" — rather than unloading anyway. "Takes effect when you restart" is a
fine answer; a half-unloaded mod is not. (The backend installs its teardown
before it loads any mod, and the IL2CPP host owns its own, so neither of them
is in this state today. The refusal is what keeps a *third* host honest.)

**A mod that is not loaded → already in the requested state.** `unload` of a
guid the host does not have answers `ok:true` and does nothing; `load` of a guid
that is already live answers `ok:true` and does nothing. Both are ordinary cases
rather than errors, because `/apply` restates the whole set every time.

**A library that exports the wrong guid → refused.** A load request naming one
guid whose library announces another is a mistake the manager has to see, so the
guid is read back off what actually loaded rather than echoed from the request.

**A mod that is `wrong-side` is never unloaded.** The host skips a mod that does
not declare its side before it ever calls `on_load`, so asking for it back would
be a request that can only ever answer "there was nothing there".

**A verb from a newer manager than the host → refused, out loud.** The
manager's contract is one reply per request, and a name nobody answers is
indistinguishable from a host with no control at all.

## Off and on again is a *fresh* instance

`AOWLSPT_MOD_HOT_RELOADABLE` is reported in `listed` but is **not** required for
an unload, and that is a deliberate reading of the ABI. The flag says the mod
implements `state_save`/`state_load` and can be taken out and put back
mid-session *without losing what it was doing*. Taking a mod out and leaving it
out needs less than that: it needs `on_unload` to run and the host to drop the
registrations, both of which the host guarantees.

So a mod that is disabled and then enabled again comes up in its initial state —
its `on_load` runs again and its globals start over. That is exactly what
"disable it, then enable it" means to the person clicking the switch. It is also
what `aowlspt-sim --watch` does on a rebuild: nothing carries state across, and
a mod with state worth keeping keeps it in the store.

## The test

`tools/livectl.nim`, run by `aowl test` under the heading **Live mod control**.
It stages a root with the manager, the Tarkov emulator and
`examples/gameserver`, writes a three-mod registry of its own, starts the
backend on port 6979, and drives the routes the way the panel does. **213
checks** — 211 when this paragraph last named a number and forty when it was
first written, and the growth is
mostly the selection document, the registry refresh and the client-report
ledger arriving under the same tool. The ones worth knowing about:

* control is `present` — the exact word, because `absent` and `unknown` both
  answer `ok` to every apply and change nothing.
* a disabled mod's routes are **gone from the router**: the response is the
  backend's `{"err":"no route"}`, not a failure and not a stale body. Both an
  exact route and a prefix route are checked, because they are matched by
  different code.
* the emulator beside it never stops answering. Getting the teardown's filter
  backwards takes out every mod *except* the one being unloaded, and a test with
  one mod in it cannot see the difference.
* a reloaded mod is a fresh instance: `examples/gameserver` counts the requests
  it has served, and the first request after the reload must answer 1. A host
  that kept the library mapped answers 4.
* the idempotent cases — apply twice, enable what is enabled, disable what is
  not loaded — are checked by **counting host log lines**, because all three
  answer `ok` whether or not anything happened underneath.

213 is the tool's own last line — "live mod control answered all 213 checks" —
re-derived 2026-08-19 against a scratch root staged the way `aowl test` stages
it. Worth one warning if you do the same: stage it with the *current* builds of
`manager.dll`, `tarkov.dll` and `gameserver.dll`. A stage carrying yesterday's
manager fails 27 of the 213 on the selection-persistence group, which reads as a
regression and is a stale DLL.

Run it by hand against a stage of your own:

```
installer\build\livectl.exe --root <stage> --backend backend\bin\aowlspt-backend.exe --port 6979
```

The stage needs `mods/manager/manager.dll`, `mods/tarkov/tarkov.dll` and
`mods/gameserver/gameserver.dll`; the registry and the manager's config are
written by the tool. It refuses a root that already carries a saved selection,
because a leftover selection is a different test.

The client half has two gates, and between them they cover the wire rather than
the game. `tests/modreport` drives `modcontrol`'s ledger directly — no host, no
runtime, no server — and asserts what the client host *says*: 27 checks, and the
outcomes a staged run cannot produce on demand are the point of it (a mod with
no teardown, an unload that failed, a library announcing the wrong guid, a row
the backend has stopped naming). `tests/modclient` drives the other end,
`mods/manager/mgr/clientreport.nim`, exactly **90** checks (both counts re-run
2026-08-19: `modreport.exe` prints 27 `ok` lines and `modclient.exe` 90, all
passing; "over 90" was one too generous): every letter, every code,
a report cut off mid-rotation, a host that comes back under a new process id,
and the group headed "absence is not off", which fails the moment a guid with no
record is allowed to mean "not running".

What neither of them establishes is that the query string reaches the backend.
That is `aowl_ov_sync_start` and the overlay's worker thread, and it has been
driven by hand — the host against a stand-in server that serves the
`aowlspt.clientset/1` body and records the query strings it is handed, and the
manager against polls issued by hand with the report on them. `tools/hostharness.nim`
runs the IL2CPP host against `tests/mockil2cpp`, which is what exercises resolve,
call and patch — but nothing yet drives a real manager against a real client host
in one run.

## Where the registry comes from, and refreshing it

Everything above decides what runs from a `mods.json`. That file ships with the
install, and it can also be **refreshed from a URL** — which is what makes "a
single repository of all the mods, with lists you can pick from" a thing that
can be updated rather than a thing frozen at build time.

Two switches, not one, and both off by default: `registryUrl` says where, and
`registryFetchEnabled` says whether the manager may go there at all. A URL
written down to try later must not start reaching the network the moment the
file is saved. `registryPath` pinned to a local checkout beats both — if you
have said which file to use, nothing is going to replace it behind you.

```
GET /aowlspt/mods/registry           what is loaded, and where it came from
GET /aowlspt/mods/registry/fetch     fetch now; returns immediately
GET /aowlspt/mods/registry/fetch/force   adopt even if the revision is not newer
GET /aowlspt/mods/registry/revert    go back to the one that shipped
```

The fetch runs on a worker thread and the route answers straight away — 43 ms
while a deliberately slow server was still dribbling out a body. Nothing about
a request or a frame waits for the network.

**A refresh can only ever leave you where you were or better.** The fetched
document is validated by `registry/validate.nim` — *the same code* a publisher
runs as `aowl-regcheck --file mods.json`, so a file that passes CI is one the
manager accepts by construction rather than by discipline — then written,
read back, re-validated, and rolled back if the readback differs. It is refused,
with a reason, for: the feature being off, no URL, a pinned `registryPath`, a
refused connection, a non-200, a total-fetch deadline (per-operation timeouts do
not bound a server that dribbles), a body over `registryFetchMaxBytes` (refused,
never truncated — a registry cut short still parses, it just has fewer mods in
it than the publisher wrote), unparseable content, an unknown schema, any
validation failure, an empty registry, a **lower** revision than the one loaded,
and any entry carrying a `download` block.

Every one of those refusals is now asserted rather than reasoned about.
`registry/fakeregistry.py --check` generates each wrong document, puts the ones
that are refused for their *content* through `aowl-regcheck --file` (the same
validator the manager runs), asserts the transport modes over a real socket
against the shipped `registryFetchMaxBytes` and `registryFetchTimeoutMs`, and
with `--manager <url>` drives all thirteen modes against a running manager and
asserts the outcome and the reason: 44 checks. It found that the `huge` mode had
quietly stopped being larger than the ceiling and was being *adopted*.

Both numbers re-derived 2026-08-19. *Thirteen* is `MANAGER_CASES` in
`registry/fakeregistry.py`, which has thirteen entries. *44* is only **partly**
re-run: `fakeregistry.py --check --regcheck installer\build\aowl-regcheck.exe`
without `--manager` answers "27 passed, 0 failed, 1 skipped" — the document and
transport layers — and skips the manager layer, which needs a manager running on
a URL. That layer is one check per mode plus one per stated reason fragment,
which is 13 + 4 = 17, and 27 + 17 = 44. The arithmetic closes; the seventeen
themselves were not driven this pass.

That last one is the deliberate line. `download` is *specified* — `{url,
sha256, size}`, all three or none — and nothing reads it. Fetching metadata is
updating a document; fetching binaries is unsandboxed native code from the
network into a process injected into a running game, and it also needs a
SHA-256 the toolchain does not have (nimony ships md5 and sha1, neither fit to
gate execution on). `registry/README.md` states the shape it would take if that
answer ever changes, and says it is a governance decision rather than a coding
one.

**Your own lists survive a refresh.** Local lists live in the selection store,
not in the registry, and are merged in at read time so the resolver cannot tell
them apart from a published one. A refresh reports what moved — `+ [added]
- [removed] ~ [name 0.1.0 -> 9.9.9]` — and names any of your selections that now
point at a mod the new registry does not have. It does not repair them for you:
a list that quietly rewrote itself would be worse than one that says it is
broken.

## The honest limits

* **Nothing here has ever run against BSG's client.** The IL2CPP host has been
  run against a stand-in runtime that exports the same C API and against a live
  process with no runtime in it at all. `tests/mockil2cpp` sets out what that
  does and does not establish.
* **Unloading a client mod that has patched game code relies on the detour
  coming out.** `dropModRegistrations` removes each of the mod's hooks before
  the library is freed, and that path is exercised against the mock only. A
  detour that failed to come out is a game jumping into a freed DLL — the
  failure mode this whole design is arranged around, and the one with the least
  evidence behind it.
* **The server half is what has been driven for real**, by `livectl` in the
  gate and by hand against a staged install.
* **Toggling a mod used to cost 32 MB.** Every nimony binary statically links
  its own mimalloc, which commits a 32 MiB arena the first time that binary
  allocates; a mod DLL is a nimony binary, and `FreeLibrary` unmaps the image
  without releasing the arena, because the arena is process memory the image no
  longer has any code to give back. Two hundred load/unload cycles committed
  6.4 GB. `modhost` now calls the mod's own exported `mi_process_done` in the
  one place it is safe to — after `on_unload`, after the host's teardown, after
  the three host-owned structures are freed, and immediately before
  `FreeLibrary` — with `MIMALLOC_DESTROY_ON_EXIT` set so that it releases the
  arena rather than only collecting the heap. The same two hundred cycles now
  commit 400 KB. It depends on the ABI's "borrowed in, owned out" rule holding:
  nothing the host still holds may have come out of the mod's allocator.
  `hostharness --churn` is what measures it.
* **`listed` reports one row per guid, not one per slot.** The loader keeps dead
  rows — a context pointer is an index — so a mod toggled fifty times owns fifty
  rows with the same guid, and reporting all of them grew the reply without
  bound. `listedRowFor` picks the live row, or the most recent dead one.
* **Load order is honoured at startup and not while running.** `loadAll` reads
  `aowlspt-selection.json` on both sides — but only the server's manager writes
  one, and it is stamped `"side":"server"`, which the client host correctly
  refuses to act on. So the client starts by loading everything and the live
  sync then applies a *set* rather than an order (see "Which host this actually
  governs"). The manager will not touch a mod its
  registry does not list — on either side.
