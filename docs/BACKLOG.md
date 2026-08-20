# Backlog: everything this repository says it has not done

This project has a habit: when something cannot be done, the code says so in
place, with the reason. Refusals are logged at run time in sentences. READMEs
carry gap tables. Docs mark shapes *(unverified)*. That discipline means the
backlog already existed — it was just spread across a hundred files, and nobody
had ever seen it in one place.

This is that list, collected. It is not a plan and it does not prioritise for
you. It is organised by **why** each item is not done, because that is the field
that makes a decision possible: everything blocked on one playtest is one
decision, everything blocked on a missing table is one importer change, and
everything blocked on the IL2CPP boundary is not a decision at all.

Sources: every `README.md` (root, `registry/`, `installer/`, `installer/payload/`,
`host/Aowlspt.Overlay/`, `reference/`, five mods), the other thirteen files in
`docs/`, and the
limitation vocabulary this project actually uses, grepped out of ~118,000 lines of
hand-written source — "refused", "not implemented", "unverified", "cannot",
"would need", "for now", "one day", "blocked on".

**Where a claim could not be verified from here, it is marked rather than
dropped.** Nothing below was confirmed by running the game, because nothing in
this repository ever has been.

**This list has been re-triaged against the tree, item by item.** Every entry is
now in exactly one of four states — *done*, *blocked on something specific and
named*, *blocked only on one playtest*, or *open work doable today* — and a
"done" is a file and a line rather than a recollection. Twenty-one items came
out as done and are at the end under
[Closed since this list was written](#closed-since-this-list-was-written); the
broken section went from nine items to three. The one number that did not move
is the important one: **fifteen items, and one session settles all fifteen.**

**Re-checked again on 2026-08-19, and this pass was about the *reasons* rather
than the items.** Every suite count in this document was re-derived by running
the binary; every "blocked on data" row in Group E was re-checked by grepping
`build/db/db.json`, and **eight of them were wrong** — the tables were already
there. Where a row has been re-checked it says so and when; where it has not,
it says that instead.

---

## Not undone, broken

Items that are **wrong**, not merely missing. Each carries its evidence. These
are separated out because they need dispatching rather than deciding.

**This section was nine items, then four, then three, then one, and is now
none.** `B11` was the last, and it was the only one that was a process rather
than a defect -- which is why it was closed by writing a program rather than by
correcting a sentence. B4's three README
paragraphs and B10's four documents are all corrected in place, and B2 closed
itself when the code moved rather than by anyone dispatching it. The originals
have been fixed in code since this was written; they are listed under
[Closed since this list was written](#closed-since-this-list-was-written) at the
end, with the file-and-line proof, rather than deleted — a backlog that quietly
loses its own history stops being checkable.

**B2 is closed and was closed by the code moving, not by anyone dispatching it.**
It said `aowl test`'s "patch fired" check was red because on msys2 ucrt64 gcc
15.2 the stand-in's `Tick` and `Hurt` compiled to prologues the detour engine
would not relocate. `docs/MODDING.md:1285-1294` now retracts that in place, and
a `hostharness` run against `tests/mockil2cpp/GameAssembly.dll` on 2026-08-19
answers **all 24 verdicts green**, including *"a compiled method was detoured
and the patch fired"* and *"patched EFT.Player::Tick (14 bytes) … the hook fired
on all 3 calls"*. If it goes red on another toolchain it is still a stand-in
artefact — but it is no longer the expected outcome.

### B4. Two mod READMEs describe gaps in `mods/tarkov` that are closed

Cross-mod gap claims age badly. **This was three and is now none** -- all three
are corrected in place, and the entries below record what they used to say
because a backlog that quietly loses its own history stops being checkable.

The lesson is the one G3 is about, and it is worth more than the two paragraphs:
**both claims were true when written**, and both survived months because their
subject could not see them. A gap in `mods/tarkov` recorded in
`mods/blackdivision/README.md` is a gap nobody maintaining `mods/tarkov` will
ever re-read. That is why `mods/tarkov` has a README of its own now (G3) rather
than the paragraphs merely having been fixed again.

What they said, and what is true:

| claim | where | what the code says now |
|---|---|---|
| "The emulator does not read loadouts. `mods/tarkov`'s bot generator reads exactly `firstName`, `health.BodyParts[0]` and `appearance.…[0]` … and nothing else — no `inventory`, no `chances`" | `mods/blackdivision/README.md:133-135` (**struck through in place 2026-08-19**) | `mods/tarkov/emu/bots.nim` rolls `inventory.equipment` per slot against `chances.equipment` and resolves `inventory.mods` breadth-first, and now also fills the rig, pockets and pack from `inventory.items` against the `generation.items` counts. `docs/EMULATOR-COVERAGE.md` records the change. |
| "`/client/game/bot/limit` cannot be changed. `mods/tarkov` answers it with the literal string `30` and it is not backed by any database path." | `mods/morebots/README.md:143-144` (**struck through in place 2026-08-19**) | `mods/tarkov/tarkov.nim` reads `locations.<loc>.base.BotMax` / `BotMaxPvE`, with `gDefaultBotLimit` a setting rather than a literal. |

Both corrected 2026-08-19. The loadout paragraph now records that the generator
builds from `inventory.equipment` (a weight map per slot, not a list) and the
three chance tables, and keeps the three details that were guessed wrong first:
the chance tables are three rather than one `chances.mods`; a mod slot name
appears in **either casing** in stock data, so an exact-key lookup silently
misses; and a weight of zero means never, so a pool summing to zero must produce
nothing rather than element zero. The bot-limit paragraph now records that
`onBotLimit` asks the map -- `BotMaxPvE` first, since this server is only ever
PvE -- and reads the map id from the query *and* the body, because the client
has spelled it both ways across builds and getting it wrong is a silent fall
back to the default.

### B10. One document still describes bugs that have been fixed

The code moved and the prose did not. This reads as current and is not, which is
worse than an absent note: it tells a reader to work around something that is no
longer there.

**This was four documents and is now none.** All four were corrected in place
and are listed below the line with what they say now.

`docs/PERF.md:292-297` was the last, and it said `writePtr` skips the write
barrier "because `il2cpp_gc_wbarrier_set_field` is not in the binding" and that
`bindField` refuses static fields. Both are done rather than merely unblocked:
`writePtr` routes reference stores through the barrier, `writePtrRaw` is the
opt-out and `barrierReady` says which you are getting; `bindStaticField` reads
static fields with readers that take **no object**, because a static and an
instance field share an offset space and only the type system can catch the
confusion. The page now says so, and says why the stand-in deliberately puts
`Player::SpawnCount` and `Player::Health` at the same offset 16.

The reason that row mattered more than its size: `tools/hostharness.nim`
asserts both against the stand-in *and against the stand-in's own counters* --
*"a reference field was stored through the collector's write barrier (2 call(s)
counted by the runtime)"*. One alone proves nothing, because a stand-in without
the export leaves the binding silently on a plain store.

Corrected since this row was written, and kept rather than deleted:

- `docs/INSTALL.md` — the "not-selected mod is still serving" paragraph is gone;
  the section now describes `probeGuid` and the four ways of not having a
  selection. The launch paragraph already described the poll rather than the
  1.2 s sleep.
- `registry/README.md` — the "no host answers the control probe" paragraph is
  gone. `host/common/modcontrol.nim:225` answers `probe` with
  `aowlspt.host.mods.capabilities`, and the guard that paragraph deferred on
  exists at `mods/manager/manager.nim:362`.

*Cost: one paragraph, in a file this document does not own.*

### ~~B11. `EMULATOR-COVERAGE.md` is rebuilt by hand~~ — closed 2026-08-19

`docs/ARCHITECTURE.md` says so in the "what is generated" list: the coverage
table is rebuilt by re-running the four shell commands its own "How it was
derived" section states, over `reference/` and `mods/tarkov`, and joining the two
halves by hand. Every headline in that document — the callbacks, the item-event
actions, the routes, the served/empty/absent split — is therefore only as current
as the last person who remembered.

**Re-derived 2026-08-19, and two of the four had drifted.** The four commands,
run verbatim:

| command | now | the document said |
|---|---:|---:|
| the `Callbacks` sweep over `reference/spt-4.1-surface.txt` | 226 | 226 |
| the `ItemEventActions` sweep over the same | 55 | 55 |
| `grep -oE 'serve(Prefix)?\("[^"]+"' mods/tarkov/tarkov.nim` | **95** | 94 |
| `grep -rn 'of "' mods/tarkov/emu/*.nim` | **145** | 134 |

The bucket split moved with them, from 122/25/64 to **127/24/60** — five
operations, all of them the hideout's wardrobe and the flea's renewal. Both the
counts and the split are corrected in place, but a document that needs this done
to it every few days is the argument for the generator, not against it.

It is in this section rather than in "just work" because the failure is silent:
the table does not become obviously wrong, it becomes quietly out of date while
still reading as measured. The four commands are already written down, which is
most of a generator.

**Done, and it cost an afternoon.** `tools/coverage.nim` (`aowl-coverage`)
computes all four sweeps in nimony by reading the files -- nothing shells out --
and derives the served / empty / absent split from `docs/coverage-rows.json`,
one row per callback method, joined against the routes `tarkov.nim` actually
registers. **The bucket is not stored**: it is worked out from which handler
each route is bound to, so rebinding one to `onEmptyObject` moves the headline
with nobody editing a number. Two marked regions of the document are rewritten
in place and the prose between them survives byte for byte; `--check` writes
nothing and fails, and `aowl test` runs it after `aowl-regcheck`.

Parsing the existing tables was tried first and **cannot** work, which is worth
more than the generator: the eleven per-operation tables carry **174**
operations against the reference's 211, and `GetRaidTime` appears in two of
them -- so the document's own sentence that every in-scope operation appears in
exactly one row was false. Keying rows to `Class.Method` instead makes the
input checkable in both directions: a method with no row and a row naming no
method are both errors, which a prose table can never be.

**The first run found eleven operations the hand join had wrong**, and the split
moved 127/24/60 to **125/25/61**. Three had no row at all (`Match.PutMetrics`,
`Match.EventDisconnect`, `Game.GetCurrentGroup`); eight were recorded as served
and shaped and are answered by a stock stub. Two moved the other way. None of
the eleven was a change to the emulator -- every one was the join being wrong.

Four of the eight are a behaviour claim rather than bookkeeping, and are their
own row below: `/client/mail/dialog/read`, `/pin`, `/unpin` and `/remove` are
all `onNullData`.

---

## The thing that dominates everything else

**Nothing in this repository has ever run against BSG's client. Not once.**

That sentence, in those words, appears at the top of `docs/ARCHITECTURE.md`,
`docs/INSTALL.md`, `docs/IL2CPP.md`, `docs/MODDING.md`, `docs/DEBUGGING.md`,
`docs/PERF.md`, `docs/MODMANAGER.md`, all ten mod READMEs, the overlay README,
and the module header of every client-side mod. It is the most repeated
sentence in the project.

It used to say *five* mod READMEs, because five was how many existed. All ten
`mods/*` have one as of 2026-08-19, and `mods/manager`'s was the last to be
given the sentence -- fittingly, since the half of that mod a player actually
touches is the half nothing drives.

`docs/INSTALL.md`, "What has actually been tested", puts it as a table, and the table is the honest summary
of the whole repository:

| | |
|---|---|
| the installer's refusal matrix | **126** automated checks (`installer\build\test-installer.exe`, re-run 2026-08-19: *"126 passed, 0 failed"*) |
| the filesystem layer | against a real temporary directory |
| build → payload → install → verify → launch | end to end, against a synthetic install |
| the whole first-run path | **64** checks (`installeruildirstrun.exe --scratch <dir>`, re-run 2026-08-19, 0 failed) — a synthetic vanilla client through install, a 39 MiB `importdb`, verify, the boot sequence against real data, live mod control, and a restart with the profile and the selection intact |
| the host inside a foreign process | injected, loaded its mods, reported the runtime absent |
| the backend and the emulator | answered the client's boot sequence over the wire |
| **the real client** | **never** |

The rest of the gate, re-derived by running each binary rather than by quoting
the last person who did:

| gate | checks | how |
|---|---:|---|
| `emutest`, against `tests/fixtures/emu-full.json` | **596** | `emutest.exe --root <stage> --backend … --port <n>` |
| `realtest`, against the 39.40 MiB imported database | **168**, 1 skipped | `realtest.exe --root <stage> --db build\db\db.json …` |
| `soak`, 24 closed play cycles | **915** | `soak.exe --root <stage> … --cycles 24` |
| `fuzzwire` | **152** | `fuzzwire.exe --root <stage> …` |
| `wstest`, the notifier websocket | **62** | `wstest.exe --root <stage> …` |
| `framelen`, hostile `Content-Length` framing | **102** | `framelen.exe --root <stage> …` |
| `livectl`, live mod control | **213** | `livectl.exe --root <stage> …` |
| `modreport`, the client host's ledger | **27** | `installer\build\modreport.exe` |
| `modclient`, the manager reading it | **90** | `installer\build\modclient.exe` |
| `detour_race`, a patch under live callers | **11** | `tests\detour_race.exe` |
| `dbrace`, concurrent readers and writers | **2** | `backend\bin\dbrace.exe` — one for torn reads and lost paths, one for stale key lists. The second was added with `dbKeys` on 2026-08-19 and is asked *in program order on the writer's own thread*, so it has no window to miss: 121,334 key lists, 0 stale |
| `hostharness` against the stand-in runtime | **28** verdicts | `hostharness.exe <stage> --runtime tests\mockil2cpp\GameAssembly.dll` — count the lines under `Result`, not `grep -c '^ok'`, which answers 31: three of those are the harness reporting its own staging before it has read a line of the host's log. It was 24 until 2026-08-19, when four verdicts about an instance method's unreportable fourth argument landed |
| `ws_stall`, a websocket peer that stops reading | **15** | `tests\ws_stall.exe --port <n>` — 14 and **2 failures** against the engine before the poller stopped waiting on a worker |
| `storeguard`, a reader holding a key across a commit | **9** | `installer\build\storeguard.exe --root <dir>` — 2 fail against the store as it was, because a handle that never sees a change is trivially never torn |
| `tickfault`, a mod whose `on_update` fails | **22** | `installer\build\tickfault.exe tests\tickfault` — three fixture mods; 9 fail with the honouring removed |
| `ovsync`, the client host's poll reaching the backend | **24** | `ovsync.exe --root <dir> --backend … --manager … --port <n>` — 18 fail against a dead port, with `silentPolls: 0` as the proof nothing arrived |
| `aowl-coverage --check`, the document against the code | **12** | `installer\build\coverage.exe --repo . --check` |
| `pttguard`, Path To Tarkov's graph against the real database | **62** | `installer\build\pttguard.exe` |
| `fakeregistry --check`, document + transport | **27**, 1 skipped | `python registry\fakeregistry.py --check --regcheck …` (44 with `--manager`, which needs a staged manager) |

**`tools/firstrun.nim` runs, and the row above is measured rather than
inherited.** This paragraph used to say it *could not* be re-run, and gave the
reason: `installer/payload/aowlspt/` held the host, the launcher and
`aowlspt-host.json` and **no `aowlspt-backend.exe`**, so `firstrun` installed a
target it could not start and failed at step 8 with *"could not spawn …
aowlspt-backend.exe"*.

That was true of the directory on disk and was never true of the payload step.
`aowl payload` stages all three binaries and **errors and returns 1** if any is
missing, so what had been observed was a directory assembled before the refusal
existed, left lying about. It has since been restaged: 32 files, host, backend,
launcher, registry and all ten mod libraries. Re-run 2026-08-19 the whole walk
completes — **64 checks, 0 failed**, nothing skipped.

Two numbers worth keeping out of it. **Cold boot on an empty store 1524 ms,
restart on a warm one 525 ms** — a delta of 999 ms, which is the store being
built rather than read. And the `aowlspt-verify` inside the walk reports **28**
checks; this document used to say "all thirty-one checks", which was not a
number anybody could reproduce and is retired rather than corrected.

The failure that hid all this is worth naming, because it is the same species as
the rest of this document and `firstrun` now refuses it: **the symptom appeared
three steps and two minutes after the cause.** A tree missing its backend was
diagnosed at step 8, when the spawn failed, rather than at step 5, when the
install produced it. The walk now halts as soon as the installed tree lacks
`aowlspt-backend.exe` or the host DLL, and says which and what to re-run.
Verified by taking the backend out of the payload deliberately: the walk stops
at **26 checks, exit 1**, with the diagnosis — so the 64 are checks that can
fail.

> The gap in the last row is the whole gap. Everything above it says the pipeline
> is sound; none of it says the game starts.

The useful distinction is not "tested / untested". It is **which items one real
session settles, and which it does not.** Those are two very different backlogs
that currently look the same.

### Settled in an afternoon by one real session

Every item here is an experiment, not a project. The code is written, the
refusal path is written, the log line that reports the answer is written. What is
missing is the answer. Run the game, read `aowlspt/aowlspt-host.log`, and these
resolve — most of them within the first minute of one raid.

| # | Item | Where | What one session tells you |
|---|---|---|---|
| S1 | **SWAY's spring integration law** | `mods/sway/model/spring.nim:33-60`, `model/tuning.nim:247-262` | The single boolean `springAccelPerFrame`: whether BSG's `Spring` does `velocity += acceleration` or `+= acceleration * dt`. **Worth a factor of sixty at 60 fps.** The failure is unmistakable rather than subtle: *"wrong one way the mod does nothing visible at all, wrong the other it pins the weapon against its acceleration clamp every frame."* One raid, one look at the weapon. |
| S2 | **SWAY's `masterIntensity` feel** | `mods/sway/model/limits.nim:30-37` | Stability is already characterised offline — `characterise.nim` sweeps every tunable to its divergence edge and the tightest margin is a factor of two. What is unknown is only *feel*: the model is stable to 20 and "produces an unusable weapon above about 3". One session picks the number. |
| S3 | **Which per-frame method the host detours for `invoke_main`** | `docs/IL2CPP.md:340-394` | The host tries a candidate table and warns if none binds. Whether a mod's `onMainThread` is really Unity's thread — which decides whether SAIN, perf and sway are legal at all — is one line in the boot log. *"Which candidate binds there, and whether it is really the player loop's thread, is exactly the sort of thing the stand-in cannot answer."* |
| S4 | **Whether the engine tolerates SAIN's five driving calls from the host's thread** | `mods/sain/README.md:403` | Named by SAIN as *"the one thing that needs the game to answer"*. `GoToPoint`, `Sprint`, `LookToPoint`, `Shoot` and the self-actions are written and will run. Whether they crash is a raid with bots in it. |
| S5 | **Every `EFT.` name in every client mod** | six mods' binding reports | Each mod prints its whole binding report a minute into a raid: `MISSING` per name, with a `why`. One session converts ~200 hypotheses into facts, and a wrong name is a refused binding rather than a wrong write — so the session is safe to run. This is the single highest-yield hour available. |
| S6 | **Whether `verifyHooks` targets actually fire** | `mods/fov`, `mods/classicmovement`, `mods/sain` | Each detours the methods it patched and counts them, logging the count after a minute. *"The thing I hooked is not the thing the game calls" is the failure mode that compiles clean and does nothing.* A count of zero names a stale target; a non-zero count confirms it live by observation. |
| S7 | **Whether the 23 perf knobs exist in the shipped build** | `mods/perf/README.md:401-405` | Managed-code stripping can remove a setter no game code calls. Each knob refuses cleanly and records what it asked for, so one run produces the whole answer at once: *"The first run against the real game is an experiment."* |
| S8 | **Whether the overlay draws, and whether it steals input** | `host/Aowlspt.Overlay/README.md:10-15, 128-131` | The one explicitly *(unverified)* marking in the overlay: a wndproc subclass cannot intercept `GetAsyncKeyState`, DirectInput or `GetRawInputBuffer`. If Tarkov polls that way, input reaches the game while the panel is open. Press Insert once. |
| S9 | **`mods/classicmovement`'s `IsAI` — property or field** | `mods/classicmovement.nim:142` | Looked for as both because *"which it is on a post-1.0 build cannot be confirmed from here and both are ordinary"*. The binding report says which. |
| S10 | **The box-header size convention** | `docs/IL2CPP.md:119-137` | The host calibrates it because the game and the stand-in can each self-consistently report a different thing. One run confirms the calibration picked right. |
| S11 | **Whether `perf`'s `onUnload` works at all** | `mods/perf/README.md:431-433` | *"`onUnload` itself has never been exercised against a runtime"* — `hostharness` stops the process rather than unloading. Disable the mod live once. |
| S12 | **Whether a detour comes back out on unload** | `docs/MODMANAGER.md`, "The honest limits" | Named as *"the failure mode this whole design is arranged around, and the one with the least evidence behind it"*: a detour that failed to come out is a game jumping into a freed DLL. Toggle one client mod off in a raid. |
| S13 | **The real boxed/bound call ratio** | `docs/PERF.md:290-319` | Every number in `PERF.md` is against the stand-in, whose `il2cpp_runtime_invoke` is cheaper than the real one — so *"the real boxed/bound ratio is larger than the table says, not smaller"*. One `perfbench` run in-process replaces the whole table. |
| S14 | **`mods/sain`'s two postfix hooks, which have never fired** | `mods/sain/README.md:241-245` | The stand-in has none of the six candidate method names, so both refuse and both cost lines read "nothing measured". Same position as `mods/classicmovement`'s `tiltCostNs`. |
| S15 | **Whether `perf`'s apply pass is thread-safe** | `mods/perf/README.md:406-409` | *"Thread safety is inferred, not tested."* Depends entirely on S3. |

**That is fifteen items, and one session settles all of them at once.** They are
listed separately because they are separately quotable, not because they are
separate work. The cost is: install, launch, play one raid, read one log.

Everything in `S1`–`S15` is currently costing this project the right to make a
claim. None of it is costing it a line of code.

### Not settled by a session

The rest of the backlog is real work or a real boundary. Grouped by reason below.

---

## Group A — Impossible post-1.0: the IL2CPP boundary

Roughly **24 items.** These are not backlog. They are the shape of the world
after Tarkov 1.0, and they should be read once and then stopped being counted as
debt. The project's own framing (`README.md:309`, `docs/IL2CPP.md`) is right:
pre-1.0 clients are Mono with an `Assembly-CSharp.dll` that Harmony can patch;
post-1.0 clients are IL2CPP with `GameAssembly.dll` and no managed assemblies at
all. Nothing built for one loads into the other, and the installer refuses to
downgrade across 1.0 with no `--force` that enables it.

**Nothing in this group is worth an hour of anyone's time except to stop
re-deriving it.**

- **Prepatching `EFT.WildSpawnType`** — `mods/morebots/README.md:37`,
  `mods/blackdivision/README.md:42`. No managed assembly to rewrite, the enum is
  native constants with its switch tables already emitted, and nothing is loaded
  so there is no pre-load window. **New `WildSpawnType` values cannot reach the
  client.** This blocks custom bot types in both mods permanently; both keep the
  mapping server-side and say so.
- **BigBrain layers and `HuntManager`** — `mods/sain/README.md:151`,
  `mods/morebots/README.md:39`, `mods/blackdivision/README.md:43`. BepInEx
  libraries and Unity `MonoBehaviour`s. None of the three exists.
- **SAIN's ~90 Harmony patches** — `mods/sain/README.md:152`. Four native detours
  are now running; *"four of ninety is still not a port of SAIN's patch set"*.
- **morebots' nine Harmony patches** — `mods/morebots/README.md:38`. All eight of
  the remaining ones need `this`.
- **`BDNvgPatch`** — `mods/blackdivision/README.md:44`. Impossible, *and already
  dead upstream*: `BotOwner_0` was removed in SPT 4.1.2.
- **SAIN's F6 GUI and Blazor preset editor, voice lines, per-limb aiming, door
  breaching** — `mods/sain/README.md:153-156`. C# UI, or main-thread engine work.
- **Postfix on a wide return or >4 register slots** — `docs/ABI.md:212-222`,
  `docs/IL2CPP.md:223-228`. A value type wider than a register comes back through
  a caller-allocated buffer whose layout the host cannot read. This is Win64, not
  a missing feature. (Stack arguments, `docs/IL2CPP.md:217-222`, are the softer
  half: *"They could be copied down; that is a second thing to get wrong on a path
  where being wrong is a corrupted argument rather than a crash."*)
- **Arguments past the fourth** — `docs/MODDING.md:314-318`. On an instance
  method `this` takes a register, so three declared arguments fit. Omitted rather
  than guessed at.
- **Exceptions and finalizers across the ABI** — `docs/ABI.md:236-239`. *"A
  finalizer's whole contract is about the exception in flight, and exceptions do
  not cross the C ABI in any form the other side could act on."*
- **A stale address cannot be refused** — `docs/ABI.md:349-355`. *"What no ABI can
  refuse is an address a mod wrote down and used next frame; by then it is a
  number."* `pinHandle` is the honest alternative and costs immovability.
- **`global-metadata.dat` is not read** — `docs/IL2CPP.md:54-60`. BSG ship it
  encrypted; going around that would be breaking a protection rather than using
  an interface. Consequence: the runtime cannot be started outside the game, so
  no offline type resolution and no `il2cppprobe --init`.
- **Bound calls are non-virtual by construction** — `docs/MODDING.md:574-579`. A
  binding by name against `EFT.Player` calls `EFT.Player`'s body even on an
  overriding subclass, *"silently, returning a plausible number"*. Mitigated by
  `bindOnObject`, not removed.
- **Generic instantiations have no name `findClass` accepts** — the reason SAIN
  cannot read bleeds and fractures, and the reason `List<IPlayer>` chains are out
  in blackdivision and morebots.
- **The backend cannot reflect or patch; the client host cannot serve routes or
  read the database** — `docs/ARCHITECTURE.md:121-152`. Explicitly *"Neither is a
  gap waiting to be filled."*
- **No static-file route in the ABI** — `mods/icebreaker/README.md:51`. Blocks
  banner images; degrades to a default.
- **Raycasts and NavMesh queries cost what they cost** — `docs/PERF.md:281`,
  `docs/IL2CPP.md:502-504`. Engine work; a native port does not make them cheaper.
- **WinHTTP's two-second floor against a dead port** —
  `host/Aowlspt.Overlay/README.md:350-358`, measured, *"and no knob reaches it"*.
- **A handler that never returns holds its session lock** —
  `docs/PERF-SERVER.md:890-894`, *"nothing can be done about that"*. What is
  bounded is the blast radius: ten seconds, then `503`.
- **Cross-1.0 downgrade and Mono/IL2CPP payload mismatch** —
  `docs/INSTALL.md`, "Refusals". The two refusals `--force` does not clear.
- **nimony language and toolchain boundaries** — the zeroed global in an
  `--app:lib` build (`docs/DEBUGGING.md:228-232`, *"has cost hours more than
  once"*), short-string inline storage killing pointers into strings
  (`:209-213`), `{.emit.}` scoped to its own module (`docs/PERF.md:134-142`), and
  PATH order giving gcc a `cc1` that *"dies with no diagnostic at all"*
  (`docs/DEBUGGING.md:20-24`).

---

## Group B — Needs a game name or offset nobody has dumped

Roughly **18 items, and eight of them are S5.** These are one step from Group A
and one step from done.
They are not blocked on capability — the ABI grew the capability, usually
recently, and the module comments record the moment it did. They are blocked on
*knowledge*: a member name, or a struct's field offsets, on a build nobody has
dumped.

**A session (S5) turns most of these into either "done" or "confirmed
impossible".** A metadata dump of a post-1.0 client closes the rest.

- **`ProceduralWeaponAnimation`'s camera-offset field names** — `mods/fov/fov.nim:138`.
  Upstream's `LerpCameraPatch`. Every capability blocker is gone: `this` is
  delivered, an address for it costs 8 ns, `bindRaw` handles the `Vector3`. What
  is left is *"that this port cannot confirm the names of the camera-offset
  fields against a running post-1.0 build, and writing a camera offset to a field
  guessed by name is the one kind of approximation the rest of this file
  refuses."*
- **The slider field on `GameSettingsTab`** — `mods/fov/fov.nim:193`. Blocks
  `minBaseFov`/`maxBaseFov`. *"The refusal is now about a name rather than a
  capability, which is a much shorter distance to travel."*
- **`EFTHardSettings.Instance.TRANSFORM_ROTATION_LERP_SPEED`** —
  `mods/classicmovement/classicmovement.nim:155-160`. The only item on that mod's
  list out for a reason about a *value*: *"this port could not verify upstream's
  constant against a running build, and inventing a number for a lerp speed is the
  kind of approximation the rest of this file refuses."*
- **`DamageInfo`'s field offsets** — `mods/sain/README.md:142`, `:536-542`. The
  damage hook knows the victim exactly and the aggressor is *inside* the value
  type, which the typed frame reports as `akBigValue` — an address of a copy whose
  layout the host cannot read. Blocks `firedAtUsThisTick` per enemy, and therefore
  enemy *ranking*. Explicitly: *"the damage hook does not unblock it — worth
  saying, because it looks as though it should."*
- **`EnemyStatus.EnemyLookAtMe`** — `mods/sain/README.md:141`. Gates
  `shallStandAndShoot` and feeds suppression. *"Cheap to add if the name proves
  right; deliberately not guessed at yet, because a wrong guess here silently
  makes bots stand in the open."*
- **`GameWorld.Grenades`, three candidate names** — `mods/sain/README.md:43`,
  `:396`. *"The only place in the mod where a decision depends on a guess it
  cannot work around."* `cdAvoidGrenade` never fires.
- **`BotOwner.BotsGroup`** — `mods/sain/README.md:397`. Wanted only as a *pointer*
  compared for equality, never dereferenced. Without it squads fall back to
  "same faction, within `squadCohesionRadius`", which the file explicitly does not
  pretend is the same thing.
- **`BotOwner.AimingData` and the three aim / three damage candidates** —
  `mods/sain/README.md:398-399`. The aim gate never engages.
- **The exfiltration controller** — `mods/sain/README.md:402`. `cdExtract` moves
  away from known threats instead of to an exit.
- **`KeyCode` ordinals** — `mods/fov/fov.nim:161-186`. The enum blocker expired —
  *"an enum is a number in both directions now"* — and what is left is turning a
  config string like `"KeypadMultiply"` into an ordinal, *"which means writing
  Unity's enumeration out by hand from memory. That is a guess about a value, not
  a missing capability."* Blocks `zoomToggleKey`, `holdToZoom` and three
  `*ToggleZoomMulti` settings.
- **All 23 Unity property names in `mods/perf`** — `mods/perf/perf.nim:10-14`.
  Stripping can remove a setter no game code calls; `masterTextureLimit` and
  `blendWeights` *"may have kept either name or neither"*.
- **Every `EFT.` name in the client half of `sain`, `blackdivision`, `morebots`,
  `fov`, `classicmovement`, `sway`, `icebreaker`** — each module header says the
  names are from the pre-1.0 C# surface plus the SPT 4.1.2 rename map, and that a
  wrong one produces a refused binding with a `why` line, never a wrong write.
- **Which per-frame method binds for `invoke_main`** — `docs/PERF.md:283-288`,
  and `UnityEngine.Time::get_deltaTime`'s compiled body *"may be shorter than the
  14 bytes a jump needs"* (`docs/IL2CPP.md:356`). See S3.
- **`SpawnPointParams` for icebreaker's map** — needs world coordinates that live
  in a scene bundle. Filed under Group D, where it is more honestly a data
  problem than a name problem.

---

## Group C — Needs a real playtest, and only a playtest

**Fifteen items, listed above as S1–S15.** Not repeated here.

The one worth restating because it is the sharpest: **SWAY's
`springAccelPerFrame`.** One boolean, a factor of sixty, a default argued
dimensionally rather than measured, and a failure mode that is visible in the
first ten seconds of a raid. `mods/sway/model/spring.nim` sets out the whole
argument for the default and then says *"That is an argument, not a measurement"*
— which is the most this project can honestly do from here, and exactly one
raid short of settling it.

Two more that are playtests of *balance* rather than of correctness, and so are
not settled by a single session:

- **morebots' `horde` preset** — `mods/morebots/README.md:78-81`. 2.5×/3×,
  *"past the point where any of it is balanced"*. Self-described.
- **icebreaker's wave tuning** — *"fewer bodies than Shoreline, more pressure than
  Factory"*, authored offline against a map that does not exist on this install.

---

## Group D — Needs data the importer does not bring

Roughly **12 items.** These are the cases where the code is correct and the
tables are absent. Two of them are permanent by design; the rest are one
importer change each.

**Read this group with the same suspicion Group E now carries.** Two of its rows
have already turned out not to be data problems at all — `RestoreHealth` below,
and `--loose all`, which was blamed on `jsondb` and is a route in `mods/tarkov`.
Every row here has been re-checked against `D:\SPT` and `build/db/db.json` on
2026-08-19 and says so.

**The permanent ones**, and they should stop being counted as debt:

- **The database is not distributable** — `docs/IMPORTDB.md:19-23`,
  `installer/payload/README.md:58-62`. It is BSG's data by way of SPT's. Not
  committed, not in a release, `build/db/` is gitignored. *"There is no `db.json`
  in a payload and there will not be one."*
- **No SPT install means no database, and no other way to get one** —
  `docs/INSTALL.md`, step 5. The server starts, `aowlspt-verify` passes, and the
  game has nothing in it. (`aowlspt-verify`'s check count moves with the mod
  set — 28 on the install `firstrun` built on 2026-08-19 — so no number is
  quoted here; the "thirty-one checks" this row used to carry was one.)

**The closeable ones:**

| Item | Where | What is missing | Cost |
|---|---|---|---|
| **icebreaker's `SpawnPointParams`** *(re-checked; unchanged — no scene bundle on this install)* | `mods/icebreaker/README.md:48`, `:140-146` | World coordinates from a scene bundle. **This is the one gap that stops a raid** — the map cannot be played at all. Nothing is invented in its place because *"an invented spawn point puts the player inside the hull or under the ice"*; `spawnPointsFile` in `config.json` lets an install that has the scene supply the array. | Not aowlspt's work — it is the map's assets, ~16 MB of authored content that is not code. |
| **icebreaker's authored loot** *(re-checked; unchanged)* | `:49` | 8 MB of extracted coordinates. Tables are written and *structurally valid* and empty. | Same. |
| **`staticAmmo` is imported and unread** | `docs/IMPORTDB.md:132-136` | Explicitly *named as not expressible*: the table imports fine, and nothing consumes it — `expandAmmoBox` picks from the box template's own filter instead. *"The data is imported so that the day someone wires it up, the table is already where they would look."* **Re-checked 2026-08-19: still true.** `staticAmmo` appears 13 times in `build/db/db.json` (one per map that has one) and `mods/tarkov` names it only in comments and in `raid.nim`'s check that it is *stripped* from `/client/locations`. | A day in `mods/tarkov/emu`. |
| **Seventeen file groups not imported** | `docs/IMPORTDB.md`, "The last row, itemised" | This row said *"nine tables … ~9 MB"* and **both halves were wrong.** The nine were real, and **eight more file groups nobody had listed** were in the etcetera at the end of it: `locations/*/statics.json`, `locations/*/allExtracts.json`, Ragman's `suits.json` / `bearsuits.json` / `usecsuits.json`, `templates/archivedQuests.json`, `templates/customAchievements.json`, `templates/customisationStorage.json`, `traders/*/services.json` and `server.json`. Measured on `D:\SPT` on 2026-08-19: **11,246,992 bytes (11.25 MB) across 71 files that nothing reads**, plus **50,423,639 bytes (50.42 MB) of other-language locales**, which are not a gap at all — they are one `--locales` flag away. Reason given for the rest is still *"the emulator has no route that reads them"*, which makes it a consequence of Group F rather than a cause. **Re-checked: still true**, and the importer now says so mechanically — `checkReadPaths` (`tools/importdb.nim:669`) walks the 29 paths `mods/tarkov` reads with a literal spelling and asserts each against the document it just wrote, instead of a sentence asserting it. | Follows the routes. |
| ~~**Trader healing (`RestoreHealth`)**~~ | `mods/tarkov/emu/health.nim` | **Done, and it was never blocked.** This row said *"needs the treatment price table"* and named an importer change. The table was in the database the whole time: `globals.config.Health.HealPrice` and `Effects.<name>.RemovePrice`, times the trader's `loyaltyLevels[n].heal_price_coef`. Nothing had to be imported. | Was: importer row. Actually: nobody had looked. |
| ~~**`--loose all` makes one response 560 MB**~~ **— fixed 2026-08-19** | `mods/tarkov/emu/raid.nim:40-110`, `:403-460`; was `docs/IMPORTDB.md`, *Why loose loot is opt-in* | **Done, in the place this row said it belonged.** `/client/locations` no longer splices the `locations` subtree in verbatim: `raid.nim` builds the map list from each map's `_Id` → `base` and nothing else — which is exactly what `LocationsGenerateAllResponse` asks for — with the key list cached after the first request, and `paths` carried through when the database has one. `base` still goes out byte for byte, so `morebots`' and `icebreaker`'s writes into `locations.<map>.base` still arrive. The absence is asserted rather than assumed: `raid.selfCheckRaid` runs the builder over a literal fixture that deliberately carries a map's `looseLoot` and a `staticAmmo` table and fails the load if either appears in the body, and it runs at load out of `emu/selfchecks.nim:133` — `emutest`'s own `/aowlspt/tarkov/selfcheck` check is green in the 541-check run above. **What this row used to say is kept:** the reason *it* gave was already a retirement of an earlier one — it said the problem was `jsondb`, *"it is held as one text document, indexed by byte offset, and `dbWrite` replaces the whole thing"*, and that had been fixed (a `db_patch` of an existing value went from **171 ms to 6.1 ms**); what actually made loose loot opt-in was this route. Measured 2026-08-19, before the fix: `aowl-importdb --from D:\SPT --loose all --no-check` produces **616,032,908 bytes (587.49 MiB)** in 13.1 s, and one `aowlprobe http://127.0.0.1:<port>/client/locations` against a backend on it returned a **560 MB body** (19.1 s wall including writing it out; `docs/IMPORTDB.md` measures 10.8 s server-side). Nothing failed then either — `realtest` passed all 134 checks against that database. **The 560 MB has not been re-measured against the new route**; what has been measured is that the loot is gone from the body. | Was: a route change in `mods/tarkov`. Done. |
| **31 templates render as their id** | `docs/IMPORTDB.md` | No `<id> Name` in the English locale. *"ugly and not broken"*. **Re-checked 2026-08-19** by re-running the import: *"templates with a localised name: 4642 of 4673"* — 4673 − 4642 = 31, still exactly 31. | Source data. |
| **Quest kill qualifiers** *(re-checked; unchanged)* | `docs/EMULATOR.md`, "What it is not" | `distance`, `weapon`, `daytime`, `equipment` inside a `Kills` condition. When present and non-empty **the kill is not credited at all**, because *"crediting a kill whose qualifier could not be checked hands out progress that was not earned"*. The raid report does not carry the qualifiers. | Blocks completion of qualified-kill quests. Needs either a richer raid report or a client-side sensor. |
| **Selling with no handbook price** *(re-checked; unchanged)* | `docs/EMULATOR.md`, "The request does not get to do the arithmetic" | *"refused, not paid at zero. The item is gone either way."* | Data. |
| **blackdivision's WTT dependencies** *(re-checked; unchanged — these are third-party content ids, not database rows, so no import can supply them)* | `mods/blackdivision/README.md:116-121` | Appearance ids and all eleven weapon ids belong to WTT-ContentBackport and WTT-Armory. Without them: bots with a customisation id that resolves to nothing, and unarmed bots. The self-test names them. | Third-party content. |
| **icebreaker scav raid timings** | `mods/icebreaker/README.md:44` | Cloned from `factory4_day` if the database has one. **Re-checked 2026-08-19, and the reason as written is now wrong in its detail:** the database *does* have a top-level `configs` object — the importer brings `configs.quest.repeatableQuests` — so "a stock database has no `configs` object" no longer holds. What is still absent is the subtree: `scavRaidTimeSettings` and `maxBotCap` are both **0 occurrences** in a 41 MB import, so the clone still never happens. Right conclusion, retired reason. | Importer row. |
| **`globalLootChanceModifier` multiplies an empty table** *(re-checked; unchanged — follows the loot above)* | `mods/icebreaker/README.md:152-154` | 0.27 is upstream's number, tuned against authored loot that is not here. A carried constant with no meaning on this install. | Follows the loot. |

---

## Group E — Just work

Roughly **30 items.** No boundary, no missing name, no session required. Someone
sits down and writes it. This is the only group where "how long" is a fair
question, and the answers below are the documents' own estimates where they gave
one.

**In `mods/tarkov` — the emulator's own surface**

`docs/EMULATOR-COVERAGE.md` is the authoritative list and should be read whole
rather than summarised. Its headline, against 211 client-facing operations:

| | operations | |
|---|---|---|
| served, and shaped against the reference DTO | 127 | the client's whole boot, raid, stash, trader, flea, hideout, quest, repair, daily-quest, gym and wardrobe path |
| served, deliberately empty or flattened | 24 | answers the right shape with nothing in it |
| **not served** | **60** | 404s, and the client retries or does without |

The 60 are not one job. They sort into three very different piles, and the
document's own framing is the right one — *"The distinction that decides priority
is not served/absent. It is whether a served route answers a shape the client can
read."*

- **Multiplayer, ~25 of the 60** — the 15 group and matchmaking calls, the 8
  friend-request operations, `SendMessage`/`CreateGroupMail` and friends,
  `ReportNickname`. On a single-player server these are arguably out of scope
  forever, and several are marked as such in place.
- **SPT's own plumbing, ~10** — `GetAllMiniProfiles` (the launcher's),
  `GetBotCap`/`GetBotBehaviours`/`GetRaidMenuSettings`/`RegisterPlayer`
  (SPT singleplayer routes), `ReceiveClientMods`, `RedeemProfileReward`. No
  counterpart here by construction.
- **Real content gaps, ~21** — down from ~26, and *this group's reasons were
  wrong eight times over.*

  **The standing instruction, and it is the whole lesson of this section:
  before scheduling anything here, grep `build/db/db.json` for the table the
  row claims to need.** A gap gets written down once, with a reason, and the
  reason is never re-checked against the data — so the sentence outlives the
  fact and a feature stays unbuilt for months behind it. The cost of being
  wrong in this direction is invisible, which is why it keeps happening.

  Eight rows were recorded as blocked on data the database already had. **All
  eight are served now, and not one needed anything imported:**

  | row | what it was filed as needing | what was actually there |
  |---|---|---|
  | `RestoreHealth` | "the treatment price table" | `globals.config.Health.HealPrice` and `Effects.<name>.RemovePrice`, times `loyaltyLevels[n].heal_price_coef` |
  | `ScavCaseProductionStart` | "its recipes are a different table" | `hideout.production.scavRecipes`, imported all along; the reward pool is a join on `_props.RarityPvE`, whose three values are the same three strings `endProducts` is keyed by |
  | `HandleQTEEvent` | a content gap | `hideout.qte`: one entry, area 23, fifteen `quickTimeEvents` with positions, speeds, success ranges and keys, and a `results` block |
  | `SetCustomisation` | a content gap | `templates.customization`, 728 entries, imported *and already served* (`tarkov.nim:551`); a profile carries `Customization` from creation |
  | `HideoutCustomizationApplyCommand` | a content gap | `hideout.customisation`: 38 globals (11 floors, 10 walls, 8 ceilings, 9 shooting-range targets) and 47 slots |
  | `SetMannequinPose` | a content gap | the `MannequinPose` nodes in the same `templates.customization` — ten of them |
  | `RecordShootingRangePoints` | a content gap | nothing was needed: the number is the client's and the only checkable facts (area 12 exists, the value is not negative) were already readable |
  | `ExtendOffer` | a content gap | nothing was needed; `maxRenewOfferTimeInHour` bounds it and the renewal is free because listing is free |

  `prestige` was also on this list and is served (`tarkov.nim:1346`).

  **Still genuinely blocked, each re-checked against `build/db/db.json` on
  2026-08-19 rather than carried forward:**

  | row | reason | re-checked? |
  |---|---|---|
  | `CicleOfCultistProductionStart` | `hideout.production.cultistRecipes` imports as literally `[{"_id":"66827062405f392b203a44cf"}]` | **yes** — grepped, one occurrence, that exact text |
  | `BuyCustomisation`, `GetTraderSuits` | need `traders/5ac3…e83c/{suits,bearsuits,usecsuits}.json`, 156,679 bytes the importer does not bring | **yes** — no `suits` key in the database; the one textual hit is prose inside a locale string |
  | `OpenRandomLootContainer` | needs `RandomLootContainers`, an SPT *config* that is in no database | **yes** — zero occurrences in `db.json` |
  | `GetTemplateCharacter` | `templates/character.json`, 14,013 bytes, unimported | **yes** — on the unread list, measured |
  | `GetDialogue` | `templates/dialogue.json`, 6,259,288 bytes, unimported. **Not** `traders/<id>/dialogue.json`, which is imported and *is* read now | **yes** |
  | `SellAllFromSavage` | **not a data reason at all.** Everything it would need is present — handbook prices, Fence's `PriceModifier` and loyalty levels, `emu/mail` paying roubles. What is missing is the items: `endScavRaid` has already moved them into the PMC stash before the client draws the screen the button is on, and the scav has no stash of its own by design (Group F). Refused by name in `emu/scav.refuseSellAll` | **yes — and the reason was rewritten** |

Beyond the 60:

- **Thirteen URLs marked *(url unverified)*** — the reference dump is metadata
  only and carries no route strings, so those paths are the well-known client ones
  *"rather than guessed silently"*.
- **Five *(unverified)* wire shapes in `mods/tarkov`** —
  `emu/inventory.nim:455`, `emu/repair.nim:351`, `emu/repeatable.nim:85`, `:467`,
  `:875`. Each is a member spelling or a rule the reference does not decide.
  `ApplyInventoryChanges` is served on a whitelist with *"the shape is
  *(unverified)*"*.
- **Quest time limits are not evaluated** — `docs/EMULATOR.md`, last paragraph.

**In `mods/sain` — sensors**

- **A real path distance** — `mods/sain/client/bridge.nim:482` still returns
  `pathDistance: -1.0` and every band comparison falls back to straight-line.
  This used to be described here as *"a one-line change at the sensor"* and
  `mods/sain/README.md:150` now explicitly retracts that: it needs a managed
  `NavMeshPath` constructed and its corner array read. Days, not a line.
- **Moving `bridge.apply` onto the main thread** — `:403`. *"work in this repo
  that has not been done"*, and it gates S4.

**In the host and the ABI**

- ~~**No gate for the client half of live mod control**~~ — **closed
  2026-08-19.** This row said the server half was proved every run by
  `tools/livectl.nim` (**213 checks**) and both ends of the *wire* by
  `modreport` (27) and `modclient` (90), but that nothing established *"that
  the query string reaches the backend: that is `aowl_ov_sync_start` and the
  overlay's worker thread, driven by hand only"*, and called itself **the gate
  that would settle S12 without a raid**.

  `tests/ovsync` is that gate: **24 checks**, in `aowl test`. Nothing in the
  loop is stood in for — a real backend on its own root and port, the real
  worker thread reached through `host/Aowlspt.Overlay/aowloverlay.nim` (the
  same two calls the IL2CPP host makes), and the real reader,
  `modcontrol.parseDesired`. The program's own socket drives the *manager* and
  never reads the feed. The assertion is the round trip in both directions: a
  mod is toggled through `/aowlspt/mods/disable/…`, a new body is waited for,
  and the check is on `DesiredMod.enabled` after parsing — then back the other
  way, `reportPath` building `?hs=…&sq=…&r=…`, carried up by the same worker
  and found again in the manager's ledger with this process's session,
  sequence and outcome letters.

  Its fixture is built so a feed accidentally wired to `/panel` **fails**: one
  of its three mods is client-only, so the client resolution and the panel's
  differ by construction. Red-cased both ways — a dead port fails 18 of 24 with
  `silentPolls: 0`, which is the proof nothing reached the backend at all, and
  a root staged without `manager.dll` fails 17 of 23 differently, on a live
  transport carrying a 404.

  **Three things it found that the documents had wrong**, all now corrected in
  place:

  1. `abi/aowlspt_overlay.h` said `Accept-Encoding: identity` *"is ignored by
     the backend as it stands today -- that is a change that has to be made
     there"*. It was made: `backend/aowlbackend.nim:515-520` honours it. That
     header is load-bearing rather than aspirational, and it is the only reason
     the feed works — the worker drops any body whose first byte is `0x78`. If
     that branch is ever narrowed the feed goes silent with no error anywhere,
     which is why the gate asserts the body came back uncompressed *by name*.
  2. **The feed publishes a 404 verbatim** and bumps its serial: it checks
     transport only, as documented. So the entire guard between a routing
     failure and a client host unloading every mod it has is `parseDesired`'s
     schema/`ok`/`count`/`complete` quartet — by design, and it holds, but the
     feed's safety is one function deep and in a different module from the
     fetch.
  3. The worker starts and even **draws** in a plain console process with no
     game: the throwaway D3D11 probe device succeeds. So the "a host that
     cannot draw still obeys the manager" path — the reason the worker was
     moved ahead of the swap-chain capture — is the branch this gate does *not*
     exercise on this machine, and seeing it needs a machine with no D3D11.
- ~~**The client host never reports its outcome back to the manager**~~ —
  **closed on both sides.** The host reports on the poll it already makes
  (`host/common/modcontrol.nim`, proved by `tests/modreport`, 27 checks) and the
  manager reads it (`mods/manager/mgr/clientreport.nim`, proved by
  `tests/modclient`, 90 checks); both are in `aowl test`. `live` on a
  client-side row is now a fact wherever there is a record.

  The rule that came out of it is worth keeping in view, because it is the one
  most likely to be broken by a later change: **there is deliberately no
  encoding for "no answer yet."** A row the rotation has not reached, a host
  that has not polled, and a process that has been replaced all arrive as
  *nothing*, and nothing may never be rendered as "off". Six of `modclient`'s
  checks fail the moment absence is read as a negative.
- ~~**A mod's DLL can be freed while a worker is inside its route handler**~~ —
  **closed in code, and the remaining work is that nothing in `aowl test` runs
  the proof.** This row said the module half was open and that "half of it
  landed alone is untestable dead code". Both halves landed. The trampoline
  half was already closed (retired, never freed, `tests/detour_race.c` in the
  gate); the module half is `host/common/modhost.nim` — `aowl_mod_inflight` /
  `aowl_mod_draining` in fixed C storage at `:210`, `modEnter` at `:273`,
  `drainMod` with a 5-second `DrainDeadlineMs`, and the calls around the
  dispatch in `backend/aowlbackend.nim:936` (routes) and `:1117` (the event
  fan-out). The ordering is exactly as this row prescribed: increment then
  test, set draining then read the count, neither in a `seq`.

  The `dbrace`-shaped reproducer this row asked for also exists —
  `backend/modrace.nim`, 712 lines with a vectored fault handler, a generation
  stamped into every reply so that a call landing in the *next* incarnation at
  the same base address is caught as a wrong answer rather than as a survival,
  and `--unguarded` to skip `modEnter`/`modLeave` and nothing else so the
  before-and-after is one binary. Built and run by hand on 2026-08-19:

  ```
  modrace.exe               43393 answers, 30822 clean refusals, 173210 empty
                            tables, no fault and no stale answer across 40
                            unloads under 8 threads
  modrace.exe --unguarded   8 of 8 workers faulted -- a call into a freed image
  ```

  **What is open is one line of `tools/aowl.nim`.** `grep -n modrace
  tools/aowl.nim` finds nothing, there is no `modrace.exe` in the gate's output,
  and it does not build with the flag set `dbrace` gets — it needs
  `-p:host\common` as well. A proof nobody runs is the same as no proof, and
  this is the second time that sentence has had to be written about this item.
- ~~**The 14-byte prologue write is not atomic**~~ — **closed 2026-08-19.**
  `aowl_hook_arm` and `aowl_hook_remove` suspend every other thread in the
  process across the write and retry until nobody's RIP is inside the bytes.
  The row's own two options were *"a 5-byte atomic patch through a near island
  … or thread suspension with RIP fix-up inside the engine"*; it is the second,
  and the prototype it was measured against had been sitting in
  `tests/detour_race.c` the whole time. Measured, six saturating workers:
  **517 prologue faults over 20000 install/remove cycles unparked, 0 over
  14080 parked**, with 77.4M of 79.6M calls in flight across a rewrite. Built
  against the engine as it was, the new `--engine-park` mode reports 368 and
  exits 1 — the gate fails against the old code, which is the only thing that
  makes it a gate.

  Two costs the row did not anticipate, both now in the header. **The freeze is
  not free**: the suspend/`GetThreadContext` sweep is inside it at ~11 us a
  thread, so a park on a 65-thread client is ~0.7 ms stopped and an
  arm-plus-disarm ~1.8 ms. A hitch, not a hang — but the header had claimed the
  window held only two `VirtualProtect`s and a byte write, and that was wrong.
  And **enumeration decided the evidence**: `CreateToolhelp32Snapshot` walks
  every thread on the machine, ~2 ms idle and nearer 15 ms under load, which
  held the gate to fifty cycles — and fifty rewrites proves very little about a
  race that is rare per rewrite. `ntdll!NtGetNextThread` took it to 14000, with
  Toolhelp kept as the fallback.

  What is *not* closed: a thread created after the enumeration is not parked,
  and the 64-retry give-up path has never executed, so its fallback to the
  unparked write is correct by inspection and not by test. Both are deliberate
  — re-enumerating with the process frozen is the deadlock, and proving a
  counter increments is not worth a synthetic thread that sits in a prologue
  forever.

  The history, kept:

  **The rate this row used to quote — "~1 in 140,000 calls" — is not
  reproducible and is withdrawn.** `detour_race` parks its workers across the
  byte write, which removes the prologue race and nothing else, and what leaks
  past the parking is far rarer than that: five runs on 2026-08-19 totalled
  about 574 million calls over roughly 97,000 install/remove cycles and
  produced **one** wrong answer, in one run, with `faults 0 (trampoline 0,
  prologue 0)` in all five. The gate is red on the run that sees it — 9 of 10
  — and green on the other four, which is worth knowing before reading a red
  `detour_race` as a regression. The *unparked* number is the one that matters
  for the real engine and it is much larger: `tests/detour_race.c` records that
  leaving the workers running accounts for "well over a thousand faults a run".

  Closing it was said to need either a 5-byte atomic patch through a near island
  — which would have moved `AOWL_JMP_SIZE`, the decoder's minimum, the `-9`
  "already ours" detection and every test with it — or thread suspension with
  RIP fix-up inside the engine. That framing was right, and the second option
  turned out to cost nothing structural at all.
- **Load order is not honoured on the client** — `docs/MODMANAGER.md`, "What came of it".
  *"It has not mattered because the client-side mods do not depend on one another;
  when it does, the fix is to sort by the order the backend already computes."*
- ~~**No `everyMain`**~~ — **closed.** `everyMain`/`stopMainRepeats` are in
  `aowl/src/aowlspt.nim`: a repeating callback on the drain's thread holding
  **one** slot rather than one per firing, with the stop deferred by one firing
  on purpose (yanking a slot from a callback already queued on another thread
  is the one way a stop could crash). The harness asserts it fires on the
  drain's thread, never more often than the runtime's frame count, and that the
  stop actually stops it.

  The reason this row gave was also **wrong**, and the wrong version is worth
  naming because it circulated: "`every` repeats on the host's thread;
  `onMainThread` reaches Unity's". On the IL2CPP host `hostSchedule` and
  `hostInvokeMain` share one queue and one thread, so `every(16, …)` already
  lands on the game's thread *there*. The real distinction is deadline versus
  drain — at 144 fps a 16 ms timer fires every third frame — plus the fact that
  **the ABI only ever promised the main thread for `invoke_main`**. A mod using
  `every` for frame work is building on one host's implementation detail.
- ~~**`bindField` refuses static fields**~~ — **closed** by `bindStaticField`.
  Its readers and writers take no object (`readInt(f)`, not `readInt(f, obj)`),
  which is the design rather than an inconvenience: the static and instance
  offset spaces overlap completely, so the stand-in now carries
  `Player::SpawnCount` (static Int32) and `Player::Health` (instance Single)
  **both at offset 16**, and the wrong binding answers `1091567616` with `ok`
  true. A `bool` flag would read identically whether it was right or wrong;
  only the compiler can catch this one. Staticness is asked of
  `il2cpp_field_get_flags` rather than inferred from the offset, and
  `il2cpp_runtime_class_init` runs before the block is read so that "zero"
  cannot mean "the static constructor has not run".
- ~~**`writePtr` skips IL2CPP's write barrier**~~ — **closed**, and it was the
  highest-value item in this group. `writePtr` routes reference stores through
  `il2cpp_gc_wbarrier_set_field`, resolved once at bind time; `writePtrRaw` is
  the deliberate opt-out and `barrierReady` reports which one you are getting.

  The part worth keeping: **the stand-in did not export the barrier**, so the
  binding would have fallen back to a plain store and any "the field was
  written" check would have passed without exercising it. The mock now exports
  it *and counts calls*, and the gate asserts both the mod's line and the
  runtime's counter — one alone proves nothing. `writePtrRaw` is also the only
  pointer store offered for statics, because the barrier wants the **owning
  object** and static storage is a GC root with no owner; handing it the block
  would be a wrong pointer given to the collector, not a conservative choice.
- **`bindMethod` refuses** doubles (`fast.nim:623-627`), five-or-more arguments
  (`MaxSlots* = 5`, including `this`) and arrays. It no longer refuses **enums**
  (`fast.nim:341-345`), and a **generic instantiation** is now reachable without
  a name — `bindOnObject`/`bindInClass` take the class off an instance
  (`fast.nim:644`). `bindRaw` covers the `Vector3` case; the rest stay boxed.
- **No `aowl build-tools`** — `docs/PERF.md:59-60`.
- **`?force=1` would be silently dropped** — `registry/README.md:614-617`. The
  router matches static routes by exact string. Worked around by path spelling; a
  query-string-aware router would remove the class.
- **No shutdown route and no console handler** — `docs/INSTALL.md`, step 7.
  *"'stop the server' and 'kill the server' are the same operation here."*
  `aowlspt-sim` has one (`SetConsoleCtrlHandler`, `aowlsim.nim:131`); the backend
  does not.
- **No automated store rollback** — `host/common/modstore.nim:86-88` keeps a
  three-generation `.hist` ring and there is no revert path in `host/common/`.
  To use one you stop the server and copy the file by hand.
- **B11 above** belongs here too, and is at the top of that section because it
  is a process that will keep producing wrong statements rather than a single
  wrong statement. B4 and B10 are closed.

---

## Group F — Deliberate: decided, not pending

Roughly **19 items,** and they are the reason this repository is worth reading.
They are listed so that nobody re-opens them by mistake, and **they should not be
counted in any backlog total.** A representative set:

- **Refuse, do not clamp** — `mods/perf/README.md:60-61`: *"A value outside the
  band is refused, not clamped. Clamping a typo into a plausible number hides the
  typo."* (`mods/sway/model/limits.nim` clamps *and says so by name*, which is the
  same principle reached by a different route, for a different reason: a JSON file
  constrains nothing and a diverging spring reaches the game as a NaN.)
- **`mods/perf` will not touch anything culling-shaped or `Physics`-shaped** —
  *"a mod that changes what a bullet hits is not a graphics setting however it is
  spelled"*. It will not call `GC.Collect` either: a forced collection is a
  stutter, which is the opposite of the job. All 23 knobs ship off.
- **`mods/icebreaker` invents nothing** — no spawn point, no loot coordinate. An
  invented spawn point puts the player inside the hull.
- **`mods/sain` will not guess `EnemyLookAtMe`, will not infer bleeding from
  falling health, and will not replace anything with its two postfix hooks** —
  *"The capability is there; the knowledge is not."*
- **No transactions in the emulator** — every path resolves the whole requirement
  to a list of (stack, amount) pairs, verifies every one, and only then removes
  anything.
- **The scav stash is spliced, not stored** — a shared stash implemented by
  copying is two writers with no lock.
- **Loopback only, everywhere, and no flag to change it.**
- **The store commits synchronously** — `docs/ARCHITECTURE.md:470-483`. There was
  a write-behind queue; it bought throughput and *"reopened exactly the hole this
  paragraph exists to close"*. Cost: ~1500 req/s down to ~800. (The *protocol* is
  still an open question — see G1.)
- **`WSAPoll` rather than IOCP** — an O(connections) scan against *"turning 'have
  I got a whole request yet' into a set of completions with a buffer lifetime
  attached to each — the bug class this file must not have"*.
- ~~**Sixteen detour thunk slots**~~ — **256 now**, and the old number was not a
  budget: it was how many `aowl_thunk_N` macros had been written out. One
  common thunk entered with a pointer to the hook's own record replaced them,
  after which a slot costs 25 bytes of tables and the 128-byte pool slot is
  allocated on demand. The refusal past capacity is kept deliberately, so a
  runaway install loop still gets "no free patch slots" rather than growing
  without bound. The client host still takes one for its own drain.

  **One hook per method** is the limit that actually bites, and it is
  unchanged: two mods wanting the same method is a refusal in whichever arms
  second. That is why `installer\build\hoststage` cannot be used for a second
  patching mod — `highlevel` is already on those methods — and it is documented
  in `docs/MODDING.md` and at the top of `examples/lesson`.
- **The overlay's JSON reader is not a JSON parser** and renders non-ASCII as
  `?`; when shapes do not fit, *the server flattens them* (`/panel`).
- **A dependency is never auto-enabled; a conflict excludes both mods** —
  *"Turning on a mod the user explicitly turned off, in order to satisfy something
  else, is the system deciding it knows better."*
- **Orphaned selections are reported, never repaired** — *"a list that quietly
  rewrote itself would be worse than one that says it is broken."*
- **`||` is not supported in version ranges** — reported as unparseable rather
  than parsed as something it does not mean.
- **`soak` refuses to run against a real database** — it is an invariant test over
  known data, and pointing it at real data is a category error.
- **`aowlspt-verify` does not check for `db.json`** — *"'It serves' and 'there is
  a game in it' are different claims and this tool only makes the first."*
  (Debatable, and the consequence is real: nothing between the installer and the
  menu screen tells you the game is empty.)
- **The uninstaller refuses without its manifest** — *"guessing at what to delete
  in a game directory is not a thing this program does."*
- **The installer will not downgrade across 1.0, and `--force` does not enable
  it** — *"it means the game you play is not the game you own."*
- **This client must never talk to the live service** — *"These tools will not
  stop you pointing the client somewhere else, and they will not help you
  either."*

---

## Group G — Owner's decisions, explicitly not made

Three, and all three are written down as questions rather than implemented,
which is the right call each time.

### G1. The store's commit protocol

`docs/PERF-SERVER.md:644-649`:

> None of that says the atomic write is wrong. It says the profile is written on
> every inventory drag, and a commit protocol priced for a save point is being
> paid thousands of times a raid. Somewhere between the two — committing on a
> schedule and at the points that matter, writing in place between them — is a
> design decision rather than an optimisation, which is why this section records
> the numbers and does not make it.

**Worth:** roughly 2x server throughput (~800 -> ~1500 req/s). **Risk:** it is
the exact hole the current design was built to close. Two prior attempts are
documented as reverted.

**Part of it was taken on 2026-08-19 without touching the decision.** The commit
was decomposed by syscall and the cost was not where the prose assumed -- not
the data (687/699/688 us at 3/16/84 KB), not the `.hist` ring (one snapshot per
key per five minutes, so a raid pays it once), but metadata. `MoveFileEx` with
`MOVEFILE_WRITE_THROUGH` was 415 us against 175 for a rename through the handle
that already wrote the file, and **the write-through flag had no defensible
reading where it sat**: with the data flush off, which is the default, it forced
the directory entry to the platter *ahead of the bytes it names*. Dropping it
strictly reduces that window. `store_set` went 718 -> 476 us, `items/moving`
1.17 -> 0.90 ms, throughput 840 -> 961 req/s on the gate configuration.

So the question this row asks is unchanged and is still the owner's: **the
profile is still committed on every inventory drag.** What has changed is that
the commit is 35% cheaper and that two bugs the atomic write brought with it are
gone -- a commit failed outright when the other host held the key open, and a
held reader handle never saw a commit at all, because the rename left it
following the unlinked file forever. `tests/storeperf/storeguard.nim` fails 2 of
9 against the code as it was, for exactly that.

### G2. Should the mod manager download binaries?

`registry/README.md:676-733`. The schema has `download` — url, `sha256`, `size`
— and nothing fetches it. All ten registry entries have `download: null`, which I
verified. The manager's refresh path refuses a fetched registry that carries one
outright.

> **This is the owner's call and it has not been made.** … It is arbitrary native
> code, from the network, loaded into a process that has been injected into a
> running game. Not sandboxed, not signed, not reviewed by anything but a hash
> that says "this is the file the registry named" — which is a statement about
> integrity, not about intent.

The document sets out both branches, including the honest form of "no": *delete
`download` at the next `aowlspt.registry/2`*. **The prerequisite this used to
carry is gone**: SHA-256 is implemented (`tools/release.nim:144`, and again in
`registry/validate.nim` and `mods/manager/mgr/registry.nim`). Nothing is left
here but the decision.

**Until this is decided, the registry is metadata only and no mod is
distributable through it.**

### ~~G3. Five mods have no README~~ — closed 2026-08-19

This said `classicmovement`, `fov`, `manager`, `sway` and `tarkov` — half the mod
set, including the two largest (`tarkov`, which it counted at 33 modules, and
`manager` at 8) — had no `README.md`, and that their module headers carried the
gap lists instead. **All ten directories under `mods/` now have a `README.md`**,
checked one at a time on 2026-08-19: `blackdivision`, `classicmovement`, `fov`,
`icebreaker`, `manager`, `morebots`, `perf`, `sain`, `sway`, `tarkov`. The three
that landed today are `tarkov`, `sway` and `manager`. The module count in the old
wording was also stale: `mods/tarkov` is **37 modules under `emu/` plus
`tarkov.nim`**, not 33.

The reason it mattered is kept, because it is what the READMEs are for and is
still the failure mode to watch: the concrete cost was visible in **B4**, where
gaps in `mods/tarkov` were recorded only in *other mods'* READMEs, and nobody
maintaining `mods/tarkov` was going to see them go stale. `mods/sway` had no gap
record outside its source at all — `springAccelPerFrame`, the highest-value
unknown in the project, lived in `model/spring.nim` and `model/tuning.nim` and
nowhere a reader would look first. Both now have a README that says so.

---

## Headline counts

Re-derived against the tree, item by item, rather than carried forward.

| reason | items | decidable as |
|---|---:|---|
| **Impossible post-1.0 (IL2CPP / Win64 / toolchain)** | ~24 | Nothing. Read once, stop counting. |
| **Blocked on something specific and named** | ~26 | A metadata dump, a scene bundle, a third-party mod, or a toolchain. |
| **Needs a real playtest — and nothing else** | **15** | **One session.** |
| **Needs data the importer does not bring** | 12 | 2 permanent, ~5 importer rows, 4 third-party content. |
| **Just work** | ~30 | Of which ~21 unserved emulator operations are the bulk. |
| **Deliberate, decided** | ~19 | Not backlog. Listed so nobody re-opens them. |
| **Owner's decisions, open** | 3 | Three conversations. |
| **Broken rather than undone** | **0** | Nothing left to dispatch. |
| **Closed since this list was written** | 21, plus the 2026-08-19 list below | Nothing. Kept for the record. |

Four things those numbers hide, and each matters more than the totals:

1. **Fifteen of them are one afternoon.** Group C is not fifteen tasks. It is one
   session, and it also collapses eight of the Group B name rows with it.
2. **The broken section went from nine to three and is now empty.** The last
   three closed on 2026-08-19: the two stale mod READMEs were corrected in
   place, and the hand-maintained table became `tools/coverage.nim`, which
   derives the served/empty/absent split from which handler each route is bound
   to and fails `aowl test` when the document on disk disagrees. It earned that
   the same day -- the four mail routes stopped being stubs one commit after
   the document was generated, and the split moved 125/25/61 to 129/21/61 with
   nobody editing a number.
3. **The two items this list called "one call site from closed" are done, and
   proved.** `bindStaticField` and `writePtr`'s write barrier are both in
   `fast.nim`, and `hostharness` asserts each of them against the stand-in
   *runtime's own counters* rather than against the mod's own report — because
   the stand-in did not export the barrier at all, so any "the field was
   written" check would have passed without exercising it. The same is true of
   the module refcount: `modEnter` landed, and `backend/modrace.nim` shows the
   before-and-after out of one binary. **The wiring this note used to call for
   is done**: `modrace` runs in `aowl test`, beside `tickrace`, `regrace`,
   `dbrace`, `detour_race` and, since 2026-08-19, `ws_stall`, `storeguard`,
   `tickfault` and `ovsync`.
4. **The decided pile is not backlog.** Roughly 19 of the ~115 items are Group F.
   The genuinely open list is around 75, and a quarter of that is the emulator's
   unserved surface, enumerated operation-by-operation in
   `docs/EMULATOR-COVERAGE.md` and not needing re-derivation.

**Nothing above was carried forward.** Every count in the four tables in this
document was re-derived on 2026-08-19 by running the binary or the grep that
produces it, and the commands are named beside the numbers.

---

## Top three, by what they unblock

Ranked by how much stops being unknown per unit of work — not by size. This was
nine entries, then seven, then four, and is now three. **None of the three is
work.** Two are a raid and one is a decision, and that is the honest state of
the top of this list rather than a flattering one: what remains at the top is
not blocked on anybody writing anything.

| # | Item | Reason | Unblocks | Cost |
|---|---|---|---|---|
| 1 | **Run the game once and read the log** | playtest | S1–S15 at once, eight Group-B name rows, and the right to make any claim at all about the client | one afternoon |
| 2 | **SWAY's `springAccelPerFrame`** | playtest | the entire calibration of the mod — a factor of sixty, and the difference between invisible and a catapult | ten seconds of a raid |
| 3 | **G2 — decide the download question** | owner | mod distribution, or the honest deletion of `download`. Either answer is progress; the open state is the only bad one. Its SHA-256 prerequisite no longer exists | one conversation |

Three notes on the ranking. **Item 1 is not first by a small margin.** It is the
only item on the list that changes what is *knowable* rather than what is done,
and it costs less than any of the others.

**Three rows left this table on 2026-08-19, and they are worth naming because
of what they had in common.** `modrace` was *"written, it builds, and
`grep -n modrace tools/aowl.nim` finds nothing"* — it is a gate phase now, with
`tickrace`, `regrace`, `dbrace` and `detour_race` beside it. `/client/locations`
no longer splices the loot: the list is built from `_Id` → `base` and
`selfCheckRaid` refuses the load if `looseLoot` or `spawnpoints` appear in the
body. B10's last document is corrected. All three were the same failure — work
that landed and was then not wired to anything that would notice it breaking —
and the two before them at 2 and 4, `writePtr`'s barrier and `bindField` on a
static field, were the same failure one step earlier.

**What that leaves is not a shorter list of the same kind of thing.** Of the
three rows above, two are a raid and one is a decision about what `download` is
for. The fourth, B11's generator, was written the same day this was and is
gone from the table for the usual reason. Plenty of work remains further down this document
— though the non-atomic 14-byte prologue write, which was the sharpest of it
when this was written, is closed as of the same day — but nothing left at the
top of the list is blocked on somebody reading more code.

---

## Closed since this list was written

Kept rather than deleted: a backlog that silently loses its own items cannot be
checked against what it used to claim. Each was verified against code, not
against a changelog.

### Closed on 2026-08-19

A long day, and the entries are grouped by what kind of thing they were rather
than by when they landed, because the kinds are the useful part.

**Defects nobody knew about, found by writing a check for something else:**

| what | how it presented |
|---|---|
| **One websocket client that stopped reading stopped the whole HTTP server** | every pong, close and refusal the poller sent took the registry lock with a *blocking* enter, and `AOWL_WS_SEND_MS` does not bound the holder -- its deadline is per stall and resets on every byte the peer accepts. A poller asleep on that lock is not in `WSAPoll`: no accepts, no reads, no deadlines. Measured against the old engine: one ordinary request in a two-second window, unanswered. `tests/ws_stall.c`, 14 checks and 2 failures against the pre-fix header |
| **`__declspec(thread)` is silently ignored by this gcc** | so the keep-alive fix committed the same morning was a process-global shared by sixteen workers. `__thread` now |
| **Three bot roles spawn with no rig and no backpack** | `mods/blackdivision`'s pools have nothing left that can roll against a stock database, and both its README and its source claimed the opposite. Found by building the `checkAgainstDatabase` its config had promised for months and never had |
| **A hook was told three of an instance method's four arguments** | omitted, not flagged, so index 3 read `""` and could not be told from an argument that was genuinely empty. The Win64 register rule is real; the silence was the defect. The slot is named `{"onStack":true,"type":"..."}` now, and the marker fails closed on a reader that has never heard of it |
| **The overlay legend was cut in half at the 480 floor** | 57 columns for a 106-character legend, silently truncated -- "loses the marker nobody knows yet", in the header's own words. `tests/overlayhost` decodes the back buffer into characters now, so the check is about pixels rather than intent |
| **A mod that failed every tick did so in silence** | `tickMods` discarded `on_update`'s status while `docs/DEBUGGING.md` had described a `Faulted` state for a long time. The state exists now: 120 consecutive failures, any success resets, routes and events untouched |

**Refusals that turned out to be nobody having looked:**

| what | what was actually there |
|---|---|
| **Quest kills refused on a `distance` qualifier** | `Victim.Distance` was in the report all along, and the check refused on the *presence* of the key: 191 of 283 kill conditions carry neutral values, and every one was refused |
| **`daytime` on quest kills** | `Victim.Time` was never the right input. The raid configuration the server already receives establishes the clock -- and the published acceleration is **0**, so it is refused and the enum ceiling assumed instead |
| **Fence karma from scav kills** | `standingForKill` is in the database for all 57 roles, and `emu/bots.nim` already read that exact path to hand it to the client |
| **`staticAmmo` imported and unread** | `docs/IMPORTDB.md` named a consumer that could never have used it: every ammo box has one cartridge in its filter. **Magazines** were the consumer, 3 to 51 each |
| **Four mail routes documented as "served"** | `onNullData`. Reading mail did not mark it read, pinning did not pin, removing did not remove |
| **`/client/game/profile/voice/change`** | answered `{"status":"ok"}` and wrote nothing, sitting directly under a route that really does write |

**Claims that were true when written:**

Four audits checked roughly 840 of them and found ~120 wrong -- the eleven mod
READMEs, five `docs/` files, four more `docs/` files, the twelve `abi/` headers
and the six examples. The two worth naming: **`examples/lesson` §9 taught that
when two mods hook one method "every handler runs and the first one that asks to
stop wins"**, which is exactly backwards -- the second to arm is refused, and
that is the file people copy from. And **"a hook is not told which instance it
fired on"** was asserted as a hard blocker in two mods, printed at runtime by
one of them, and was the stated reason for nine refusals; `hookArgs` carries
`this`, and the host reports the receiver's *concrete runtime class*.

**Wiring, which is where work goes to be forgotten:**

`modrace`, `tickfault`, `storeguard`, `ovsync`, `ws_stall`, `--engine-park` and
`aowl-coverage --check` are all in `aowl test` now. Several existed and ran
nowhere. `tools/firstrun.nim` runs again -- 64 checks -- and now halts at the
install that produced a broken tree rather than at the spawn three steps later.

**And the lesson that repeated all day**, in the corrections above and in four
briefs I wrote that were themselves wrong: *a document cannot see its own
subject.* `mods/fov` was cited to two READMEs as evidence that a hook is given
its instance; it never calls `thisPointer` and still printed the false claim.
The fix for that class is not more prose -- it is `tools/coverage.nim`,
`checkAgainstDatabase`, and a gate phase for everything else.

| was | now | proof |
|---|---|---|
| B1. `fuzzwire`/`livectl` run against a doubled root | fixed exactly as prescribed | `tools/fuzzwire.nim:533`, `tools/livectl.nim:746` — `gRoot = absolutePathOf(gRoot)` at parse time |
| B3. Two docs give incompatible emutest results | retracted in writing | `docs/IMPORTDB.md:234-238` withdraws the 94/227 and 77/235 numbers as taken during an unrelated red window |
| B4 (icebreaker row). "No weather or season table in the database" | corrected in place | `mods/icebreaker/README.md:120-125`; `mods/tarkov/emu/raid.nim:106` reads `dbRead("weather")` |
| B5. Disabled mods still load, write and answer | the host honours the selection | `host/common/modhost.nim:646-717` — an unselected mod is never opened |
| B6. Launcher starts the client ~50 s early | polls instead of sleeping | `tools/aowllaunch.nim:401-465`, `--backend-wait` 300 s default; the 54 s boot is also now 2.9 s |
| B7. `aowl payload` stages failed mods and exits 0 | exits 1 | `tools/aowl.nim:1592-1596` |
| B8. `payload.json`'s `kind` inference is wrong | `kind` is declared, inference is a documented fallback | `installer/src/aowlsptinstall/payload.nim:108-131`; the template ships `"kind": "full"` |
| B9. Do the hosts answer the control probe? | they do | `host/common/modcontrol.nim:225`. And the guard that deferred on it exists: `mods/manager/manager.nim:362`, `result = id == ModGuid` |
| The notifier is a poll, not a websocket | a real websocket, poll kept as fallback | `backend/websocket.nim:312` (handshake), `:277` (`wsPush`); gate `tools/wstest.nim` on port 6982 |
| No SHA-256 in the toolchain | implemented | `tools/release.nim:144`, and in `registry/validate.nim` and `mods/manager/mgr/registry.nim` |
| The registry repository does not exist | it does | `registry/mods.json`, `validate.nim`, `fakeregistry.py`, plus `tools/regcheck.nim` as a gate |
| SAIN: post a cover sample onto the main-thread queue | posted | `mods/sain/client/driver.nim:746`, probe at `client/coverprobe.nim:60` |
| `bindMethod` refuses enums | it does not | `aowl/src/aowlspt/fast.nim:341-345` |
| A generic instantiation has no name `findClass` accepts | reachable without a name | `fast.nim:644` `bindOnObject`, and `bindInClass` |
| `airdrop` loot table missing | served | `mods/tarkov/tarkov.nim:785`, route at `:1292` |
| `prestige` unserved | served | `mods/tarkov/tarkov.nim:1346` |
| B2. `aowl test`'s "patch fired" check is red | green, and the caveat retracted | `docs/MODDING.md:1285-1294`; `hostharness --runtime tests\mockil2cpp\GameAssembly.dll` re-run 2026-08-19 — 24 of 24 verdicts, *"a compiled method was detoured and the patch fired"* among them |
| No `everyMain` | `everyMain` / `stopMainRepeats` | `aowl/src/aowlspt.nim:474` and `:524`; the harness asserts *"everyMain fired 78 times on thread 24476, the game's own, and never more than once per frame (456 frames)"* and *"stopMainRepeats stopped a running everyMain chain"* |
| `bindField` refuses static fields | `bindStaticField`, with its own reader and writer types | `fast.nim:1213`; asserted three ways — the value agrees with the boxed path *and* the runtime counted the static-block lookups, an instance binding and a static binding each refuse the other's field, and a static write lands in the runtime's own block |
| `writePtr` skips IL2CPP's write barrier | it routes through `il2cpp_gc_wbarrier_set_field`; `writePtrRaw` is the opt-out and `barrierReady` says which you have | `fast.nim` (`writePtrRaw` at `:1142` and `:1356`, `barrierReady` at `:1153`); the stand-in now exports the barrier *and counts calls*, and the gate asserts both the mod's line and the runtime's counter — *"a reference field was stored through the collector's write barrier (2 call(s) counted by the runtime)"* |
| The client host never reports its outcome back to the manager | closed on both sides | `host/common/modcontrol.nim` (proved by `tests/modreport`, **27** checks) and `mods/manager/mgr/clientreport.nim` (proved by `tests/modclient`, **90** checks); both re-run 2026-08-19 |
| A mod's DLL can be freed while a worker is inside its route handler | a refcount around the dispatch, with a drain and a deadline | `host/common/modhost.nim:210` (the C storage), `:273` (`modEnter`), `backend/aowlbackend.nim:936` and `:1117`. Reproducer `backend/modrace.nim`: guarded, 43393 answers and no fault across 40 unloads under 8 threads; `--unguarded`, 8 of 8 workers fault. **The proof is not in `aowl test` — see the open row above.** |

One of these is *half*-closed and is still an open row above. The module
refcount is written, correct and demonstrated; what is missing is that nothing
runs the demonstration.

---

*Assembled from the project's own records and then re-checked against the code,
item by item. Where something could not be verified it is marked as unverified
rather than dropped; where a claim in one file contradicts another, both are
quoted rather than one being chosen; and where the code has since moved, the old
claim is struck with the file and line that moved it rather than deleted.*

---

## 2026-08-20: the capture changed what is knowable

Everything above was written while the real backend's traffic was unreadable.
It is readable now, in both directions, and that moves a number of items from
"blocked on a playtest" to "checked against what the backend actually did".

**What was solved.** Post-1.0 wraps every body -- request and response -- in a
length-keyed byte shuffle that carries no key, and encrypts responses only,
AES-192-CBC with an in-band IV under a key that is a plain 24-character ASCII
literal in the client. `docs/WIRE.md` is the description; `tools/bsgwire.py`
and `tools/bsgaes.py` are the implementation. All 171 encrypted bodies in
`mods/tarkov/data/capture/raid1` decrypt, and 149 request bodies decode.

**The bug it exposed, which was the important part.** The server never
unshuffled a request body. A shuffled body is not zlib-framed, so it fell
through `inflateBody`'s pass-through branch and reached handlers as noise --
with a 200, and nothing in the log. Every route that ignores its request body
kept working, which is most of the menu, so the client got all the way to
character selection against a server that had never read anything it was sent.
Fixed in `backend/wire.nim` and `aowlbackend.nim`; gated by
`tests/bsgwiretest.nim` against the real bodies.

That is worth stating as a lesson rather than an entry: **the failure had no
symptom at the layer it occurred at.** A gate that round-tripped our own
shuffle would have passed against the broken server, because the defect was in
*when* the server unwrapped, not in the arithmetic.

**Closed, with the evidence now in hand.**

| was | is |
|---|---|
| `onMatchEnd` read `exit` and `profile` | The client sends `results.result` and `results.profile` (seq 204). Three read sites corrected; every raid used to end by discarding a 76 KB profile and logging that the client had sent none. |
| `doSplit` read `item` | The client sends `splitItem` (seq 318). Every split failed. |
| `ReadEncyclopedia` shared the `Examine` branch | It sends `ids`, an array, and it can be empty (seq 341). Now its own branch. |
| `raidLocation` split `serverId` on `'.'` | Post-1.0 `serverId` is `TUTORIAL_1891947_20_08_2026_01_20_33` -- no map in it, no dot. The map is now remembered from `raid/configuration` / `match/local/start` and persisted per session (`emu/sessions.enterRaid`), because the raid result never names it. |
| `onMatchStart` read nothing and answered a pre-1.0 shape | It answers `{serverId, serverSettings, profile, locationLoot, transition, excludedBosses}` (seq 158). `locationLoot` is why post-1.0 never calls `getLocalloot`. |
| Seven menu routes 404ed | Served from `data/post1/`, BSG's own answers: main quests and their notes, variable groups, tapes, subtitle tracks, quest chains, metrics config. |
| `/client/quest/complete` was unserved | Served. Its key is `questId`, not the `qid` the item-event path uses (seq 202). |
| `locations.paths` was always `[]` | BSG's 18-edge transit graph, used when the database has none. `emu/raid.nim` says why. |
| *"`raidClock` has never been run against BSG's client, so which time field it posts is unknown"* | It posts `timeAndWeatherSettings.hourOfDay` -- exactly the camelCase names `emu/raid.nim` already looked for (seq 156). |

**Newly open, and named rather than left implied.**

- `/client/dialogue` is 13 MB of static post-1.0 dialogue trees and is not
  served. Too large to check in beside the other tables; it needs its own
  decision about where such data lives.
- `/client/match/join` -- the online raid path -- is still unserved. The capture
  shows a second raid entered this way, and `profile/status` answers 305 bytes
  with `status: "MatchWait"` and a `profileToken` while one is pending, against
  193 bytes and `"Free"` otherwise. The pending state is now specified and not
  implemented.
- ETags. 36 requests in the capture carry `If-None-Match` and all 36 were
  answered 304. Nothing in this repository emits an ETag, so a menu reload
  costs megabytes that cost the real backend nothing.
- `/client/tutor-game/profile` carries a profile and is not a static table;
  `tutor-game/check` answers `false` here because this server has no tutorial
  raid to run.
- The database delta is measured in `docs/POST1-DATA-DELTA.md`. The headline is
  reassuring -- the pre-1.0 import is additive-compatible, no property the
  emulator reads has been removed -- but 1,154 item templates and five maps
  exist post-1.0 that it does not know about.

### Response shapes: specified against the real backend, not yet applied

`docs/CAPTURE-RESPONSES.md` compares every route's answer against BSG's. Some
of what it found was applied the same night; the rest is below, with the reason
it was left. **Each of these is now a known-exact contract, not a guess** --
which is the only reason it is safe to leave them: the next session can apply
them without re-deriving anything.

Applied: `seasonal-perks` keys `commonPerks`/`personalPerks` -> `common`/
`personal` (four captures agree; the old names were derived from C# backing
fields, which is a reasonable guess and wrong); `profileChanges.improvements`
`{}` -> `[]`, which rides on every inventory action; `/client/friends` three
keys -> six; `/client/quest/list` object -> array, with `tools/realtest.nim`'s
reader migrated with it.

Left, and why:

- **`/client/customization/storage` sends an object where BSG sends an array**
  of `{id, source, type}`, 49 entries. Ranked second by the report and not
  applied: the emulator has no per-suite `type`, so the array would have to be
  synthesised, and an array of wrong elements is not better than an object of
  right ones. Needs the customization table read properly first.
- **`/client/items/prices/{id}`'s `currencyCourses` is keyed by currency name**
  (`usd`, `eur`) where BSG keys it by **template id** with exchange rates --
  `{"5449016a…":1, "569668774bdc2da2298b4568":138.55, …}`, roubles included at
  1. Every lookup misses on every trade screen. Small and mechanical; left only
  because it was found late.
- **`/client/battle-pass/active` answers `null`** where BSG always sends
  `{"battlePasses":[…]}`. `{"battlePasses":[]}` is very likely the right
  no-battle-pass answer and was not applied without a way to see the screen.
- **`/client/season/active` answers `{}`** where BSG sends `{"season":{…}}`.
  Same reasoning.
- **`/client/game/config` is missing `availableGameModes`**, `purchasedGames`,
  `sessionMode`, `ndaFree`, `isGameSynced`, `linkedPlatforms`, `backend.Lobby`
  and `backend.Static`, and sends an extra `ndid`.
- **Envelope B.** Five routes -- `/client/metadata`, `/client/game/start`,
  `/v2/client/game/profiles/`, `/client/game/keepalive`, `/v2/client/shop/status`
  -- answer with a *different* envelope: `{data, err:null, errmsg:null,
  status:null, errLog:{}, error:{code:null,message:null}}`, where `err` is
  **null** rather than the integer `0`. This server sends the ordinary envelope
  on all five. It is a strict subset so it probably deserialises, but "probably"
  is doing real work in that sentence.
- **`/v2/client/game/profiles/` sends one game-mode key where BSG sends three.**
  The real empty-account body is `{"pve":{"status":"locked"}, "pvp-season":{…,
  "status":"empty"}, "regular":{"SeasonalInfo":null,"status":"empty"}}`. Note
  what that proves and what it does not: it is the response *before* a profile
  exists (seq 048 precedes the profile creation at 092), so it says nothing
  about a populated slot -- which is exactly the thing two sessions have now
  failed to make render. What it does prove is that a slot can be as small as
  `{"status":"locked"}`, which makes "cut the slot object down and add fields
  back one at a time" a cheap experiment rather than a shot in the dark.
- **`bots.base` has 16 keys against BSG's 26** (seq 160), missing all ten
  post-1.0 additions, so every generated bot lacks them.

### The gate itself was wrong in two places, and had been for a while

Neither of these was found by reading the gate. They were found by a change that
made the gate run far enough to reach them.

**`fuzzwire` and `allmods` both looked for a log line the backend stopped
writing.** Both waited for `listening on 127.0.0.1:<port>`; the backend writes
`listening on <scheme>://127.0.0.1:<port>`, and has since it learned to serve
TLS. So `itIsListening` was permanently false, `waitUntilServing` always timed
out, and both gates reported *"the backend did not come up"* against a server
that was answering every request correctly -- which is exactly the failure mode
they exist to catch, aimed at themselves. Both now match on `://127.0.0.1:`,
which is what the two spellings have in common.

**`realtest` asserted the opposite of a deliberate fix.** It checked that
`/client/menu/locale/en` answers its strings *without* a `menu` wrapper. Post-1.0
requires the wrapper -- `data` deserialises into `EFT.BackendMenuLocale`, whose
only field is `menu` -- and `onMenuLocale` has wrapped it, with the reason in a
comment, since the menu-boot work. The check now asserts the wrapper is there
**and** that there are strings under it, because "there is a `menu` key" would
pass on a wrapper round nothing.

And one process note that cost an hour: **a test binary can be stale while the
mod is fresh.** `soak` and `fuzzwire` were rebuilt by the gate but run by hand
from `installer/build/` afterwards, and the hand runs were reproducing a bug
that had already been fixed -- the body in the log was the old shape because the
binary that sent it was the old binary. When a gate and a hand run disagree,
check the timestamps before believing either.

**Still true, and worth repeating because this section could be read as
"tested".** Nothing here was confirmed by running the game. It was confirmed
against a recording of the real backend, which is a different and weaker thing:
it proves what BSG answered on one day for one account, not that this server's
answers satisfy the client.
