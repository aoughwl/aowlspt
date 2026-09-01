# Overnight-readiness audit — can Claude run unattended for hours?

Audited 2026-09-01 on `integ-beta9`. Read-only: nothing was launched, deployed
or stopped. Every claim below is cited to a file:line or the command that
produced it. PASS / GAP / UNKNOWN — "I could not look" is UNKNOWN, never PASS.

**Short answer: not yet, but it is much closer than the last time it burned an
evening. Three specific holes account for nearly all the wasted time, and all
three are small.** They are, in order: (1) nothing watches the raid once you are
in it, (2) the supervisor is blind to the backend watchdog that already exists,
(3) a mod that fails its self-check is not connected to the client death it
causes.

---

## A. Error-detection completeness

`tools/run.py` is the supervisor. Its `Supervisor` watches exactly three
sources (`tools/run.py:110-118`): the **host log**, the **client's own logs**
via `crashwatch`, and the **process table** — plus a native-popup scan on a 5s
cadence (`tools/run.py:379-396`). One verdict, distinct exit codes
(`tools/run.py:97-107`).

| failure mode | detected? | how fast | evidence |
|---|---|---|---|
| Native Win32 popup (BattlEye, "Unable to check the client version") | **PASS** | <=5s | `popups.py` EnumWindows + `WM_GETTEXT` on children, called at `run.py:386`. `WM_GETTEXT` not `GetWindowTextW` — the latter returns empty cross-process (`popups.py:44-49`). |
| In-game modal error dialog | **PASS** | next poll | host `errdlg` writes one `ERRORDIALOG kind=...` line; `run.py:236` returns on it, and suppression notices are excluded so they are not reported as dialogs. Default **ON**: `aowlhost.nim:8078` `gErrDlg = readBoolKeyDef("catchErrorDialogs", true)`. |
| ...and if it did NOT arm | **PASS** | end of run | `run.py:436-441` downgrades IDLE to INCONCLUSIVE when `errdlg_armed is not True`. This is the single best piece of design in the harness — it is a check that *can* fail. |
| Client process death | **PASS** | <=5s | `run.py:404-410`, distinguishes "was up and is gone" from "never started" (`:412-421`, `BOOT_GRACE_S = 95` per CLAUDE.md section 1). |
| Client never started | **PASS** | 95s | same. Reported as its own cause, not as a crash. |
| Host fatal (`il2cpp_init returned 0`) | **PASS** | immediate | `FATAL_HOST_LINES` (`run.py:88-95`); host emits it at `aowlhost.nim:7194`. Returns at once instead of burning the 95s grace. |
| Client-log exceptions | **PASS** | <=poll | `crashwatch` measured signatures, tailers built from end-of-file (`run.py:117`). |
| **BACKEND death / hang** | **GAP — but not the gap you expected** | never | see below |
| **Raid-load stall / matchmaking hang** | **GAP** | never | see section B |
| **Mod on_load failure -> client death** | **GAP** | never linked | see below |
| Inspector channel contention | **PARTIAL** | — | see section D |

### The backend: the watchdog exists, the supervisor cannot see it

You suspected nothing supervises the backend. That is **wrong in the launcher
and right in the supervisor**, and the distinction matters.

`tools/aowllaunch.nim` has a real watchdog — `# The backend watchdog` at
`aowllaunch.nim:1488`, restart bookkeeping at `:1534`, restart at `:1587-1590`,
and a give-up at `:1572` and `:2841`:

    err "BACKEND DOWN -- aowlspt-backend died " & $gWd.fails & " times in " & ...
    err "BACKEND DOWN -- auto-restart gave up; the game has no server " & ...

It is on `main` and on `integ-beta9` (`git merge-base --is-ancestor
feat-backend-watchdog integ-beta9` -> yes).

**But `grep -rn "BACKEND DOWN" tools/ plugins/` returns nothing.** `run.py`'s
`Supervisor` never opens the backend log and never reads the launcher's output
— the only `backend` mentions in `run.py` are the two `Stop-Process` lines
(`:350`, `:465`). `harness.py:119` knows the path; `triage.py:214` reads it
**after** the run, at rank 5. So: the backend can die permanently, the launcher
will announce it in plain English, and the supervisor will report `IDLE` or
`TIMEOUT`. **This is the cheapest fix in this document: add `"BACKEND DOWN"` to
`FATAL_HOST_LINES` and tail the backend log in `Supervisor`.**

### The mod-selfcheck chain (today's multi-hour loss)

`modload.nim` does surface a failed mod: a FAILED row keeps the in-game panel up
and refuses to auto-dismiss (`modload.nim:41`, `:462-473`). But that is a *human
visual* signal on a screen nobody is watching at 3am. Nothing:

* writes a machine-readable "mod X registered only N of M routes" line the
  supervisor matches;
* connects "tarkov.dll failed its selfcheck" to the *consequence* ("Unable to
  check the client version" popup — which `popups.py` **does** now catch in
  <=5s, so the symptom is detected today and the cause is still not named).

**GAP: cause-to-symptom linkage.** `triage.py` ranks findings but has no rule
joining a mod-load failure to a subsequent popup or death.

Note: `host/Aowlspt.Host.Il2Cpp/modload.nim` is **uncommitted** in the main
checkout (`git status --porcelain -uno` -> ` M`, 80 insertions). The brief said
everything was committed; it is not.

---

## B. Auto-raid — bounded on the way in, completely unbounded once inside

Four implementations, all tracked:

| impl | last commit | role |
|---|---|---|
| `host/.../natraid.nim` (1501 L) | 2026-08-31 17:41 | native raid start, `uxNativeRaid` / `uxNativeRaidDrive` |
| `host/.../autoraid.nim` (667 L) | 2026-08-30 15:44 | UI-press menu->raid machine, `uxAutoRaid` |
| `host/.../raidphase.nim` (541 L) | 2026-08-31 12:46 | read-only "am I deployed" signal |
| `tools/enterraid.py` (386 L) | 2026-08-31 20:22 | out-of-process driver, what `/raid` uses |

Deployed flags in `D:\Aowlspt\aowlspt\aowlspt-host.json`: `uxAutoRaid:false`,
`uxNativeRaid:false`, `uxNativeRaidDrive:true`. Since `aowlhost.nim:8361`
computes `gNrDrive = gNrOn and readBoolKey("uxNativeRaidDrive")`, **no in-host
auto-raid is armed live** — `uxNativeRaidDrive:true` is inert. The working path
is `tools/enterraid.py`.

**Entry is properly bounded — PASS.** Every phase has a deadline:

* `natraid.nim:243-297` — `NrProbeWindowMs = 300000`, `NrMaxDriveAttempts = 5`,
  `NrMaxDefers = 40`, `NrMaxLocTries = 12`; enforced `:1400`, `:1440`, `:1248`,
  `:535`. It even verifies the *finished state*, re-reading
  `MatchmakerOperation._readyPressed@0x60` and treating 0 as "the press did not
  take" (`:1305`), unreadable as INCONCLUSIVE (`:1298`). Textbook section 9b.
* `autoraid.nim:67-104` — `ArMenuWaitMs = 180000`, `ArStepTimeoutMs = 45000`,
  `ArMaxPlayExtends = 6`, `ArMaxFaults = 3`; enforced `:554-557`.
* `enterraid.py` — menu poll 180s (`:266`), per-press 4-20s, final
  `deadline = time.time() + 300.0` (`:318`) with a definite FAIL (`:329`).

Nothing spins forever on entry.

**Once in the raid, nothing bounds anything — GAP, and this is failure mode #1
from the brief.** All three go hands-off at READY and never look again:

* `autoraid.nim:636` — *"READY pressed ... Going hands-off; this feature will not
  touch the UI again this session."*
* `enterraid.py:321-327` — on the host-log raid marker it does a blind
  `time.sleep(60.0)` and returns 0. **That is a check that cannot fail
  (CLAUDE.md 9b): it asserts a duration, not a state.** A raid that errors
  mid-load still exits 0.
* `natraid.nim` reaches `NrDone` and stops observing.

No extract timeout. No in-raid global deadline. No stall detector.
`harness.py`'s 45s `--stall` clock is log-level, not raid-semantic. This is
exactly "sit in the raid for 25 minutes tailing logs".

**Raid exit IS detectable — the signal exists, the consumer does not.**
`raidphase.nim` detects both edges read-only: deploy via
`GameWorld.AfterGameStarted` subscribers (`:66-77`), end via `RpPhaseResults = 4`
(`:124`) driven by `SessionEndUIScene` in `SceneManager` (`:128`, `:239`,
`:262`), GameWorld gone, or `Camera.main` gone. **Nothing consumes
`RpPhaseResults`.** So the autonomous raid loop in MEMORY.md is one wire away,
not a rebuild.

---

## C. Headless — server-side yes, client-side no, and it is honest about it

* `tools/headless.py` (350 L) is **not a stub** and **does not mean "no
  graphics"** — it means "no `EscapeFromTarkov.exe`" (`headless.py:10-29`).
  Three suites (`:130-186`): `backend-selftest`, `admintrader`, `betacheck`.
  Verdict is the child's **exit code**, not a stdout substring (`:224-229`);
  exits 0 PASS / 1 FAIL / 2 INCONCLUSIVE; `--mutate` inverts it as a falsifier.
  **PASS.**
* Real headless client: `tools/aowllaunch.nim:428-437` builds
  `-batchmode -nographics` behind `--nographics-anyway`, fatal without
  `--low-render` (`:425`), and warns at launch that it "has never been observed
  to boot this client" (`:2463-2466`).
* `docs/HEADLESS.md:26-31` — **measured**: `UnityPlayer.dll` contains
  `batchmode`, `nographics`, `PlayerInitEngineNoGraphics`. `:33-46` —
  **"Nothing here has ever booted this client with these switches."** `:147-156`
  self-corrects that `-monitor` *is* present, and adds *"the string is there is
  the measurement and it works is not."*
* What is actually used unattended: `harness.py:240-241` passes `--low-render`,
  and `--offscreen` (`:231-239`) parks the window off every monitor, verifying
  the finished window state (`:263-289`). **The GPU still renders.**

**Verdict: server E2E headless PASS; client E2E headless GAP (never booted);
client E2E unattended-but-rendering PASS.** Zero mentions of headless in
`CLAUDE.md` or any skill — it is not wired into any workflow.

---

## D. End-to-end test API — 3.5 of 5 steps

Three layers, none complete:

* **assertions (in-client)** — `inspect.nim:5420-5620`: `assert EXPR TYPE OP
  VALUE`, `assert-active` / `-null` / `-readable` / `-name`, `verdict`,
  `wait N`, `until EXPR [FRAMES]`. Genuine three-outcome: PASS/FAIL/INCONCLUSIVE
  never folded, precedence FAIL > INCONCLUSIVE > PASS, and a batch with **no**
  assertions prints no verdict (`:5771-5776`). **PASS.**
* **navigation (Nim)** — `aowl ui <roots|screens|findtext|click|inraid|
  wait-screen|...>` (`aowluicmd.nim:11-70`); `clickText(): ClickResult`
  (`aowlui.nim:968`), `waitUntil(): bool` (`:953`), `inRaid(): Tri` (`:1095`).
* **composition (Python)** — `acceptance.py:404-450` is the only thing that
  chains launch -> navigate -> assert, and it is **one hardcoded settings
  scenario**, not a runner. No scenario file format; `inspect_assert` exposes 8
  hardcoded names (`server.py:427-439`).

Timeouts return **distinguishable verdicts, never hangs**: `until` prints
`TIMED OUT -- ... never read non-zero within the frame cap. The batch continues`
(`inspect.nim:6844-6851`); the shell side waits on a per-batch sentinel and
raises `TimeoutErr` with a diagnosis, exit 2 (`inspector.py:11-23`), and a stale
out-file is **refused** rather than parsed.

| step | writable today? |
|---|---|
| launch | YES (`acceptance.py:107`) |
| menu | YES (`acceptance.py:126` -> `entergame.py`) |
| raid | YES, but **two disagreeing implementations**: `aowl raid` clicks by displayed text (`aowluicmd.nim:52-70`) while `enterraid.py` navigates by GameObject *name* because `findtext` finds zero menu buttons (captions live at `_text+0xB8`, `enterraid.py:5-11`). One of them is wrong on this build. |
| **extract** | **NO. Zero code.** No `exitraid` tool, no `exfil` / `ExfiltrationPoint` reference in `tools/` or the MCP plugin. The advertised `/exitraid` slash command **has no skill file on disk.** |
| assert | PARTIAL — strong primitives, no post-raid vocabulary (survived, loot delta, XP, exit name). |

### Channel contention — guarded on one side only

`plugins/aowlsptcode/mcp/channel.py:61-124` implements `_Lock`, a cross-process
advisory lock (`O_CREAT|O_EXCL`, key = sha1 of the live dir's abspath, in the
system temp dir — deliberately not in the live install). It spans the whole
write-then-poll window (`:219-224`), self-heals after `LOCK_STALE_S = 180`, and
raises a **distinct** `ChannelBusy` (`:110-116`) so a collision never reads as a
host fault. `tools/ichannel.py` re-exports it; `inspector.py:200-215` delegates.
Proven by `inspector.py --selftest` case 3.

**GAP: `tools/aowlui.nim`'s `Ui` writes the command file directly
(`aowlui.nim:234`, `runBatchOnce:259`) with no lock**, and `tools/inspect.ps1`
is a fourth unlocked writer. `channel.py:52` documents the lock as advisory —
"a cooperating writer that does not use channel.py is unaffected". **The Nim
side is exactly that non-cooperating writer, and it is the side
`aowlspt-launch.exe` uses in-process.** Confirmed as suspected.

---

## E. Worktrees — the loss risk is real but it is not what it looks like

Measured: **102 worktrees** (`git worktree list | wc -l`), **108 branches**
(`git branch | wc -l`).

Worktrees with modified/staged **tracked** files (`git status --porcelain
--untracked-files=no`, run per worktree):

* **14 worktrees under `C:\Users\savant\AppData\Local\Temp\` report ~1,000-1,145
  tracked-dirty files each — and they are all ` D ` (deleted).** Sample:
  `wt-integ` on `integ-tooling` shows `934 files changed, 174658 deletions(-)`.
  **Windows cleaned `%TEMP%`; the working trees are gone but git still registers
  them.** The commits are safe. The hazard is different and worse: **an agent
  told to "continue on `integ-tooling`" and handed that registration lands in an
  empty tree and can commit a mass deletion.** Branches affected:
  `feat-aowlui`, `feat-resolver-harden`, `probe-multitarget`, `probe-easyassets`,
  `feat-patch-by-rva`, `fix-nameidx-stamp`, `feat-name-index`,
  `feat-codegen-resolve`, `feat-components`, `integ-host-final`, `feat-debug-ui`,
  `integ-host-all`, `integ-host-diag`, `integ-tooling`.
* Genuinely dirty with small real edits (**this is where work can be lost**):
  `admin-f6-spawn` (6), `agent-a8a1db920bfd9d86d` (6),
  `fix-overlay-flicker-and-mask` (4), `feat-uihub-ux` (3), `feat-dtogap-ours`
  (3), `agent-aa5113ed7e08ec038` (2), `agent-deploy-target` (2), plus 5 with one
  file each — and **the main checkout itself** (`modload.nim`, uncommitted).

### Proposed rule

1. **`git worktree prune` now**, then delete the 14 `%TEMP%` registrations
   explicitly (`git worktree remove --force`). Never create a worktree under
   `%TEMP%` again — put them under `.claude/worktrees/` only.
2. **One agent owns one branch, and the branch name is in the task brief.** No
   two concurrent agents may touch the same file; if the plan needs that, they
   are one agent.
3. **Every subagent commits before it reports.** A report that says "done" with
   an uncommitted tree is not done. Concurrent builds in *separate* worktrees
   are measured safe (CLAUDE.md section 3) — the risk is entirely uncommitted
   state.
4. **Before handing a branch to an agent, verify the worktree exists and is
   clean** (`git -C <wt> status --porcelain -uno`). Empty output or no directory
   means recreate it, do not reuse.
5. Add `.claude/worktrees` and `build` to a repo ripgrep ignore — a repo-wide
   `Grep` **timed out at 20s** for one of my subagents today and returns
   instantly when scoped. That tax is paid by every agent, every session.

---

## F. Overnight-readiness verdict — what to build, in order

Ordered by hours saved per hour spent.

1. **Bound the raid.** A global in-raid deadline plus a stall detector. Wire
   `raidphase.nim`'s `RpPhaseResults` (already published, `:124`) into
   `enterraid.py`, and delete the `time.sleep(60.0)` at `enterraid.py:321` — it
   is a check that cannot fail. Verdicts: `IN-RAID` / `EXTRACTED` /
   `RAID-STALLED` / `INCONCLUSIVE`. *Directly kills failure mode #1.* Small: the
   signal already exists.
2. **Teach the supervisor about the backend.** Add `"BACKEND DOWN"` to
   `run.py:88` `FATAL_HOST_LINES` and tail `aowlspt-backend.log` in
   `Supervisor`. The launcher already prints the verdict (`aowllaunch.nim:1572`,
   `:2841`); nothing reads it. **~20 lines.**
3. **A single `raidloop` driver with one terminal verdict**, wrapping
   run.py + enterraid + the exit signal, so an overnight run has exactly one
   process to kill and one exit code to read. Today the pieces exist and the
   composition does not.
4. **An extract primitive**, and a real `/exitraid` skill file (the slash
   command is advertised with nothing behind it). Without it no loop can close,
   and step 4 of 5 of any e2e test is unwritable.
5. **Lock the Nim channel.** Port `channel.py`'s `_Lock` (temp dir, sha1 of live
   path, 180s stale break) into `aowlui.nim` — the file format is trivially
   interoperable. Otherwise `aowlspt-launch.exe` silently clobbers batches, and
   a clobbered batch looks like a wrong answer, not an error.
6. **Resolve the two raid-entry implementations.** `aowl raid` (by displayed
   text) and `enterraid.py` (by GameObject name) cannot both be right on this
   build. Measure, keep one, delete the other.
7. **Link mod-load failure to its consequence** in `triage.py`: a FAILED mod row
   followed by a popup or death should rank 1 and name the mod. Today the
   symptom is caught in <=5s and the cause is never stated.
8. **Worktree hygiene** (section E) — prune, then the one-agent-one-branch rule
   and commit-before-report.
9. **Make `run.py --json` the required end of every unattended step**, so a
   verdict survives an external `TerminateProcess`. The sparse `mark()` trail
   (`run.py:190-200`) already does this correctly; it just is not mandated.

**Not blockers:** headless client (section C — never booted, and `--offscreen`
is sufficient); a scenario-file test runner (nice, not on the critical path).

### Honest bottom line

If items 1 and 2 land, an unattended run can no longer sit for 25 minutes on a
dead client or a dead backend — the two things that actually burned the
evenings. Everything the harness needs to *see* a failure is already built and
measured; what is missing is a **deadline on the one phase that has none** and a
**wire from a watchdog that already speaks, to a supervisor that is not
listening.** Both are hours, not days.
