# DEVLOOP

The fast path for each thing you do more than once a day. Everything below is
PowerShell from the repo root. `gcc` silently fails under Git Bash — build from
PowerShell or not at all.

---

## The measurements this document is built on

Taken 2026-08-22 on the i9-10850K (20 logical cores), in a fresh worktree,
timed with a stopwatch around the real command.

| what | command | time |
|---|---|---|
| **full build, cold worktree** | `aowl build` | **18 min 25 s** (1104.7 s, ≈25 compiles, strictly serial) |
| full build, warm, one file changed | `aowl build` | **4 min 27 s** (267.4 s) |
| **host DLL after a one-line edit** | `aowl build host` | **48 s** |
| host DLL, nothing changed | `aowl build host` | **0.39 s** |
| `aowl.exe` cold | `aowl bootstrap` | 30.2 s |
| `aowl.exe`, nothing changed | — | 0.27 s |
| CPU used by one build, of 20 cores | — | 30–40 % |

**The headline: 48 s instead of 18 min 25 s — 23× — for the single most
common change in this project.** That is what `aowl build host` buys, and the
only reason it was not available is that nobody had written the case label.

Even against a *warm* full build it is 5.6× (48 s vs 4 min 27 s), and that
warm figure is the honest everyday comparison: 4 of those 4½ minutes are
twenty-four other programs being checked and found already correct.

Three conclusions, and every tool here follows from one of them.

1. **nimony's incremental cache is excellent — 0.27 s for a no-op.** So the
   cost of a small change is *not* recompilation. The cost is that `aowl build`
   asks for twenty-five programs when you changed one. The fix is not a faster
   compiler; it is a way to name one target. That is `aowl build <target>`.

   One honest caveat on the 48 s: it is what a change to `aowlhost.nim` itself
   costs, and that file is the host's root module, so changing it invalidates
   everything downstream of it. A change to a *leaf* module the host imports is
   cheaper. There is no configuration that makes editing the root module cheap,
   and 48 s is close to the floor for a 1.5 MB native DLL.

2. **A build uses a third of the machine.** It is one nimony at a time, and
   nimony is largely single-threaded. Sixty percent of a 20-core box sits idle
   through an eighteen-minute build.

3. **Concurrent builds in separate worktrees are safe.** This was measured, not
   assumed: three agents' builds ran simultaneously through this work and all
   produced correct binaries (verified marker-by-marker with `deploy.py
   check`). Each worktree has its own `nimcache` beside every source directory,
   its own `installer/build`, and its own `.abistamp`. There is **no shared
   mutable build state** — `~/nimony` is read-only during a build, and the
   `nccompute`/`ncfib` directories in it are stale artifacts from June, not a
   live cache. **Stop serialising on one build slot; it costs hours and buys
   nothing.** The corruption folklore applies to two builds in the *same*
   checkout, which is a real hazard and a different one.

---

## I changed one host file

```powershell
.\installer\build\aowl.exe build host
```

Builds `host/Aowlspt.Host.Il2Cpp/bin/aowlspt-host-il2cpp.dll` and nothing else.
Other targets: `backend`, `sim`, `launch`, `installer`, `emutest`, `verify`,
`probe`, `mods`, `examples`, and `deploy` (the four artifacts a live install
takes, and only those).

Run the bare `aowl build` when — and only when — an `abi/*.h` header changed
(it drops every cache, which is correct and unavoidable: nimony does not track
a `#include` reached through `--passC:-I`), or before a release.

## I changed one mod

```powershell
.\installer\build\aowl.exe build-mod mods\tarkov
```

And for a mod you can iterate on without the game at all — which is most of
them — `aowl run mods\<name>` puts it in the simulator in about a second, and
`aowlspt-sim --watch` hot-swaps it on save. **Only `--watch` shadow-copies the
library.** Every other host maps it in place, so rebuilding over a running
backend or client fails with a sharing violation. Stop the host first.

## I changed `tools/aowl.nim`

```powershell
.\installer\build\aowl.exe bootstrap
```

**Read this even if you think you don't need to.** `aowl build` has never built
`aowl.exe`; no target anywhere does, and `installer/build/` is gitignored. So:

* a **fresh worktree has no `aowl.exe` at all** — the documented command simply
  does not exist there until you bootstrap;
* an `aowl.exe` copied in from another tree is from **another commit**.

Edit `tools/aowl.nim`, run `aowl build`, and all sixteen mods report `ok` while
your change to the driver did not run. The build succeeded. The edit did not
ship. Nothing said so.

`aowl bootstrap` compiles the driver, swaps it in by rename (so it works even
while it is running — the *next* invocation is the new one), and stamps a
content hash into `installer/build/.aowlstamp`. Every subsequent build compares
that hash and warns loudly when the driver is behind its source.

## Deploy and test

```powershell
python tools\deploy.py check          # verify markers, touch nothing
.\installer\build\aowl.exe build deploy
python tools\deploy.py deploy         # verify, back up, copy, print rollback
```

`deploy.py` refuses to copy anything if any required literal string is missing
from a built artifact. That is the point of it. The failure it prevents — a
rebuild from a wrong base silently dropping a feature, the binary shipping, the
game starting fine, and the feature simply being absent — has bitten this
project repeatedly and is invisible at every step except a human playing.

The marker list is data, in `tools/deploy.json`. **Add a marker the same day
you add a feature.** A good marker is a log-message literal: the compiler emits
it verbatim and it names the feature. Currently 19 for the host DLL.

One thing to expect: `check` run *while a build is in flight* will report the
target as "not built", because `buildIl2CppHost` deletes its output before
compiling (deliberately — a leftover output makes `placeLibrary` return early
and ship the stale binary). That is the tool being right, not a false alarm.

It verifies everything before it copies anything (a new host against an old
`tarkov.dll` is its own class of confusing bug), backs each live file up to
`<name>.bak-<stamp>`, and prints a rollback line. `python tools\deploy.py
rollback --only host` restores the newest backup.

## Launch and get the log, with no human

```powershell
python tools\harness.py run --until "host running"
python tools\harness.py run --until "settings pages:" --timeout 240
python tools\harness.py run --profile <id>          # skip the picker
```

Starts backend + client through the existing `aowlspt-launch.exe --no-logs`,
follows the host log as it is written, stops at the sentinel, copies both logs
into `build/runs/`, prints the summary and shuts down what it started.

**Readiness is never a timeout.** The game reaches profile-select in about a
minute and then waits forever for a person, and an idle game is
indistinguishable from a hung one from outside. So three things are tracked:
the sentinel literal; *progress*, where any new byte in the log resets a stall
clock (the host writes unbuffered, one open-write-close per line, so silence in
the log is real silence); and the stall clock itself, default 45 s, which
reports `IDLE` — a distinct outcome from `TIMEOUT`, because it is usually the
correct end state. Client death is detected directly rather than waited out.

Exit codes: `0` sentinel reached, `1` client died, `2` timed out, `3` idle.

## What happened last run

```powershell
python tools\hostlog.py summary       # boot checklist + everything that broke
python tools\hostlog.py faults
python tools\hostlog.py feature debugui
python tools\hostlog.py config        # what the host ACTUALLY read
python tools\hostlog.py tail
```

**The host truncates the log at every start**, so the file is always exactly
one run — "since the last launch" is the whole file, and no marker-seeking is
needed. `summary` prints the boot milestone checklist (eleven literals from
`aowlhost.nim`, ending at `host running`), then — separately — features that
*turned themselves off or never armed*, then warnings and errors, then faults
that were caught and survived. That first group is the one that matters: a
feature that spent its fault budget is not a warning, it means everything you
were about to test was not running.

`hostlog.py config` reads the host's own `<key> is set:` boot echo, which is
the only honest answer to "what config did this run use" — it is what the host
read, not what the JSON says.

## Flip a host flag

```powershell
python tools\hostcfg.py show          # every key, value, and unknown keys flagged
python tools\hostcfg.py set debugUi on botDiag off
python tools\hostcfg.py keys
```

The host does **not** parse `aowlspt-host.json` with a JSON parser. Each flag is
a raw `find(text, "\"" & key & "\"")` followed by "is the next non-`[ :\t]`
character `t` or a digit 1–9". Nothing enumerates the object, so **a typo'd key
is silently ignored** — `"debugUI"` with a capital I reads as absent, defaults
to off, and costs you a full launch cycle to discover. `"false"` in quotes is
false, `0` is false, `7` is true.

`hostcfg.py` refuses an unknown key and suggests the near-miss. The valid list
is not hardcoded: it is scraped out of the host sources at run time from the
`readBoolKey("...")` call sites, filtered to files that actually name
`aowlspt-host.json` (without that filter, `modcontrol.nim`'s unrelated JSON
readers offer `guid`/`path`/`lib` as host flags). So it cannot drift from what
the host really parses. 23 keys today. `show` also lists keys present in the
file that the host does not read — the typo detector working backwards.

Writes are a textual splice of one value, so `//`-prefixed doc keys, key order,
indentation and the BOM survive; the old file is kept as `.bak-<stamp>`.
Changes take effect at the next client start.

---

## What is still slow, and why

Honest list. These were looked at and not fixed.

**A cold full build is ~19 minutes and that is close to irreducible here.** It
is ~25 separate nimony invocations run in series. nimony is largely
single-threaded, so the only real win would be running the independent targets
in parallel inside `aowl build` — the targets genuinely are independent (each
writes its own `nimcache` beside its own source), so this is possible and worth
maybe 3–4× on a cold build. It is not done here because `aowl build`'s failure
accounting is a single global `failures` counter mutated from `run`, and making
that concurrent is a real change to a file several agents are editing. Named
targets remove the need in the common case; parallel `aowl build` is the
remaining win, and it is a contained one.

**The 60–90 s to reach the menu is the game, not us.** Nothing in this repo
touches it. `harness.py` removes the *human* from that wait, which is the part
that was actually expensive, but the wall-clock stays.

**A host change cannot be hot-reloaded.** The host DLL is injected into a
suspended process at start; there is no path to swapping it in a running
client, and `docs/DEBUGGING.md` is right that every non-`--watch` host maps its
libraries in place. So "change a host file, see the result" will always be
build → deploy → relaunch. The floor is now measured: `aowl build host` 48 s +
`deploy.py deploy` about a second + `harness.py run` ~90 s unattended. Call it
two and a half minutes, **none of it a person's attention**, against the ~10
minutes with a human inside it that this replaced. The remaining wall-clock is
one compile and one game start, and neither is ours to shorten.

**`aowl build` is still the right command after an ABI header change**, and it
will still be slow, because `dropStaleCaches` correctly throws every cache away.
That is not a bug to fix.

**Corrections to two things that were believed true.** `aowlspt-launch.exe` has
no `--no-reclaim` flag and no stale-backend reclaim feature — neither exists in
`tools/aowllaunch.nim`. And `tools/ailog.py` is not on this branch at all; it
lives only in other worktrees.
