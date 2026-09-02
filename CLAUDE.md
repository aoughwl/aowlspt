# aowlspt — how to work in this repo

## 0. NEVER expose the personal address. Non-negotiable.

There is a personal address (domain deliberately withheld) address on this machine — it is the
one Claude Code reports as the user's email, and it is NOT spelled out here on
purpose, because this file is tracked and this repo is public. Writing it down
to warn about it is itself the leak.

That address must **never** reach anything public — no git commit author or
committer, no README, no release note, no Discord post, no issue, no pushed file.
It leaked once, into two public repos, and had to be scrubbed with a history
rewrite and a force push.

The identity to use, everywhere, is the one WSL already has:

```
git config --global user.name  savannt
git config --global user.email savant.eclipse@gmail.com
```

`savant.eclipse@gmail.com` is the only verified email on the GitHub account, so
it is also the only one that links a commit to the profile — a commit authored
with any other address shows a generic avatar and no attribution.

Before the FIRST commit in any repo, check `git config user.email`. A per-repo
`user.email` silently overrides the global one, which is exactly how this
happened. `savannt@users.noreply.github.com` is also fine.

If it leaks again: rewrite the author AND committer fields (`git filter-branch
--env-filter`, or `--amend` for a single commit), delete `refs/original/*`,
expire the reflog, then force-push every branch and tag. Verify against the
GitHub API, not the local clone.

### It happened again, in THIS repo — measured 2026-08-24

Do not assume the earlier scrub covered this repo. An audit on 2026-08-24 found:

* **274 commits** across ~90 local branches authored AND committed by the
  address, and **50 of the 51 commits on `origin/main`** — i.e. it was pushed.
* Cause: the **global** config held it until **2026-08-23 ~12:16**, when it was
  switched. No per-repo, per-worktree or env override was ever involved — the
  earlier note blaming a per-repo override is not what happened here. Last bad
  commit 2026-08-23 18:12; nothing since.
* It also sat in `CLAUDE.md` content on 4 branches, and **on disk plus in the
  index of 4 of the 66 worktrees** — `git gc` could not prune the blob until
  those worktrees were reset. A scrub that only walks refs will miss this.

All of it was rewritten and force-pushed; a fresh clone of `origin` now reports
zero occurrences, and `main`'s tree hash is byte-identical to before
(`30ddabee…`), so only metadata changed.

**Two things that are still true and matter:**

1. **GitHub keeps force-pushed commits reachable by direct SHA** until its own
   GC runs. `git fetch origin <old-sha>` still returned a commit bearing the
   address after the push. The repo is private, so this needs repo access AND
   the SHA — but "I force-pushed" is NOT "it is gone". The only complete fixes
   are GitHub Support running `gc`, or deleting and recreating the repo.
2. **The repo is PRIVATE** (`api.github.com/repos/savannt/aowlspt` 404s
   unauthenticated while `git ls-remote` succeeds). That is what kept this from
   being a public leak. Do not make it public until item 1 is settled.

### The guard

`tools/githooks/pre-commit`, wired up with
`git config --local core.hooksPath tools/githooks` (which every worktree
inherits, since worktrees share local config — and worktrees are where the 274
came from). It refuses a commit whose author identity, committer identity, or
staged content carries the address. Tested against all three cases.

The hook never writes the address literally; it reassembles the pattern at
runtime. **Do the same in anything you write.** A guard, a test fixture or a
warning that spells the string out is itself the leak — that is exactly how
this file came to contain it in the first place.


Post-1.0 Escape From Tarkov is **IL2CPP**. There is no BepInEx and no Mono patching.
aowlspt is a host DLL running on the Unity main thread plus a nimony backend that
emulates the game server.

---

## 1. ALWAYS drive the game yourself. Never ask the user to.

Start it, stop it, restart it after every deploy — unprompted. The user's attention is
the scarcest resource in this project; do not spend it on process management.

```powershell
# stop (the host DLL is LOCKED while the game runs, so a deploy needs this first)
Get-Process -Name EscapeFromTarkov,aowlspt-backend,aowlspt-launch -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 4
# start
Start-Process -FilePath "D:\Aowlspt\aowlspt\aowlspt-launch.exe" -WorkingDirectory "D:\Aowlspt\aowlspt"
```

Only ask the user for what genuinely requires human eyes or a human decision.

**Three rules measured 2026-09-02, each of which cost an hour when unknown:**

- `run.py` without `--keep` FORCE-STOPS the client when its verdict lands, and
  stopping the Bash task that launched it kills the game too. Both read as a
  clean crash afterwards. Boot with `--keep`; never TaskStop a boot.
- Every native death leaves a Unity crash report in
  `%LOCALAPPDATA%\Temp\Battlestate Games\EscapeFromTarkov\Crashes\Crash_<UTC>`.
  `run.py` prints it on DIED and `python tools/crashwatch.py last` symbolises
  it (`il2cpp_resolve.py symbolize`). Read it BEFORE theorising: four "clean"
  deaths were a SAIN use-after-free and a mode-skip Submit race, both named
  in the report the whole time. And read the DUMP too: `python tools/dmpread.py
  <Crash_*>/crash.dmp` prints the faulting instruction's registers -- on 2026-09-02
  four flag bisects (one sample each) chased noise for an hour while the dump
  said `Rax=1 Rcx=1 Rdx=0`: a Profile argument that was the integer 1. One
  bisect sample is not a conclusion; a register is.
- **A fail-fast death writes NO Crash_* folder.** `abort()` / `__fastfail`
  (0xc0000409) bypasses Unity's handler entirely; the only records are the
  Windows Application Error event, `%LOCALAPPDATA%\CrashDumps\EscapeFromTarkov.exe.<pid>.dmp`
  and cdb (`python tools/crashwatch.py wer`). MEASURED 2026-09-02 13:18: mimalloc's
  thread-ownership assertion in a mod ticked on a different thread than it was
  initialised on -- run.py had called it a clean teardown. `run.py` now prints
  all three sources on every DIED; "no crash report" is never "no crash".
- `--until-phase MENU` now needs a MenuScreen::Show proof line; natesp's
  `raid phase = MENU` only means "no GameWorld" and is true on the character
  screen too (`PARKED-BEFORE-MENU`, exit 10, is that case).


**This rule is for the COORDINATING session, not for subagents.** A subagent must never
deploy to `D:\Aowlspt\aowlspt` and never start or stop the game: a human may be playing,
several agents build concurrently, and every deploy must be serialised through one place
that verifies markers first. Subagents build, verify, and report an artifact path.

**Entering and leaving a raid, PROVEN 2026-09-02 (use this, never tree-walking
automation):** boot with `python tools/run.py --keep --until-phase MENU ...`, then
write `allow write` + `raid Woods` to `aowlspt-inspect.txt` and
`python tools/run.py --attach --until-phase DEPLOYED`. The host drives menu ->
side -> map -> offline screen -> insurance -> accept -> READY on uihooks
show-events (~10s), then the game loads; DEPLOYED latches on the true deploy
signal. `raidexit` is the exit half (in progress). Every step logs `autoRaid:`
with a readback and a census on refusal; read those, not the screen.

Do not sleep for a fixed duration and hope. Drive off `state` / `until` — ask the client
where it is instead of guessing at timings.

**The false crash:** the client takes >60s to reach profile-select and then waits
indefinitely for a human. A process check at 20s reads "gone" because it has not spawned
yet, and an idle game is indistinguishable from a hung one. Before declaring a crash:
wait 90s+, confirm the host log actually STOPPED progressing, and read the client's own
logs under `D:\Aowlspt\Logs\<ts>\`.

---

## 2. ALWAYS debug with the LIVE INSPECTOR. Not screenshots, not guesswork.

The inspector queries the running client in **seconds**, with no rebuild and no restart.
Before it existed, every question cost a build → deploy → launch → human-looks-at-screen
cycle (~10 minutes for ONE bit of information, and only if the needed log line had been
predicted in advance).

Write commands to `D:\Aowlspt\aowlspt\aowlspt-inspect.txt`; answers land in
`aowlspt-inspect-out.txt` and the host log. The trigger is a **content change**, so bump
a serial line (`#12`) to re-run the same batch.

```
read/write EXPR TYPE     i8..i64 u8..u64 f32 f64 ptr bool str klass
parent EXPR [N]          children EXPR      tree EXPR [DEPTH]
roots                    every scene root -> $r0..$rN (transforms; GOs are $rgoN)
find NAME [ROOT] [BUDGET]      NO ROOT = ALL scenes    find NAME in ROOTNAME
find more [BUDGET]       dump EXPR [N]      fields EXPR [N]
findtext SUBSTR [ROOT] [BUDGET] [all]  search by the TEXT A CONTROL DISPLAYS
                          (TMP_Text only), not GameObject name; ACTIVE nodes
                          only by default, `all` includes inactive (unpressable)
                          hits    findtext more [BUDGET]
component EXPR TypeName  -> $comp           rect EXPR       label EXPR
scan EXPR N TYPE VALUE   canvas EXPR        call TARGET SIG [ARGS]   image
click EXPR / invoke EXPR         open [GROUP] / tab EXPR [0|1]
state / where / anchors / targets / help / echo TEXT
let NAME EXPR            wait N / until EXPR [FRAMES]        allow write
EXPR = $anchor | 0xhex ( +0xNN | @0xNN )*      '+' moves, '@' DEREFERENCES
```

**`roots` is how you reach anything.** The live UI is NOT in any scene
`SceneManager` lists — on this build it lives in **`DontDestroyOnLoad`**, which
`sceneCount`/`GetSceneAt` exclude by design, so all three listed scenes report
`rootCount=0` **truthfully**. `roots` asks `GameObject::get_scene_Injected` which
scene `$preloader` really belongs to, and enumerates that: `Login UI` (the mode
selector + character slots), `Preloader UI`, `Environment UI`, `Canvas`, and 7
more. Before `roots` existed, `find` searched only `$preloader`'s subtree and
would report a name **"NOT PRESENT"** when it was merely unreachable.

`$rN` binds a **Transform** (same kind of handle as `$c0`/`$f1`, so it goes
straight into `children`/`tree`/`find`); `$rgoN` is the GameObject, which is what
`component` wants. Feeding a GameObject to a Transform walker is now REFUSED:
it used to fault, and worse, could read a plausible `childCount` and invent a
hierarchy of wrong children without faulting at all.

`find` auto-resumes across frames (12ms slice per frame, node budget bounds the
whole search) and says which happened: `searched EXHAUSTIVELY` vs `STOPPED EARLY`
— and STOPPED EARLY is **not** proof a name is absent.

**`rect EXPR` prints real numbers**: `anchoredPosition`, `sizeDelta`, `anchorMin`, `anchorMax`, `pivot` and `rect (x,y,w,h)`. Do NOT reach for `fields` instead -- `UnityEngine.RectTransform` declares exactly ONE il2cpp field (`reapplyDrivenProperties`, static); the rest are native-side. MEASURED Win64 ABI on this build: a Vector2 (8 bytes) comes back packed in RAX; a Rect (16 bytes) comes back via hidden-buffer sret `(retbuf in RCX, this in RDX, MethodInfo* in R8)`. Every getter is byte-verified and checked NOT `[shared]`; a failed verify or a NaN/absurd struct prints a refusal, never a plausible number.

`find NAME X` with exactly ONE trailing token is genuinely ambiguous against the
`[ROOT] [BUDGET]` grammar — `X` disambiguates by **readability**: if it reads
back as a live Transform/GameObject it is treated as ROOT, otherwise as BUDGET
(and `find` says which it picked, and why). This replaced a bug where a plain
integer like `find SettingsScreen 200000` was always read as ROOT — `200000`
decimal IS `0x30d40`, a bogus pointer — searched that one bogus node, and
reported the name **"genuinely NOT PRESENT"**. An explicit ROOT is *also* now
refused up front, exactly like `tree` already refuses, if it does not read back
as a valid Transform — `find` never again reports a "genuinely NOT PRESENT" or
"searched EXHAUSTIVELY" verdict when zero valid nodes were actually visited; it
says plainly that nothing was examined.

**`findtext` shares `find`'s root/budget parser and reporter**, so the two cannot drift apart; only the per-node predicate differs. Every hit is checked against `GameObject::get_activeInHierarchy` and tagged, because a hit on an INACTIVE node is **not pressable** -- pressing one returns success and does nothing (fact #72). `findtext` therefore searches ACTIVE nodes only by default; pass a trailing `all` to include inactive hits, and the summary always states which scope was searched. `find` has the identical blind spot and was deliberately LEFT UNCHANGED -- flip its default only as a considered decision, not silently.

Write the command file **without a BOM**. PowerShell 5.1's `Set-Content -Encoding
utf8` emits one; it is stripped now, but `printf` from Bash is the safe habit.

Flags in `aowlspt-host.json`: `liveInspector` (read-only), `liveInspectorWrite` **plus**
an `allow write` line in the batch for anything that writes or calls into game code.

**NEVER take a screenshot to find something out.** It is the most token-expensive action
available and the inspector exists precisely to replace it. Reserve screen capture for
questions that are genuinely visual and that no field read can answer — and say why.

Anchors rebind per batch: `$preloader $verlabel $modetext $tab1 $settings $gameworld
$you $_`. `state` explains WHY an anchor is null (e.g. the host learns the SettingsScreen
pointer only once that screen has been opened) — but check that explanation against the
host log before trusting it; `$settings` is populated by whichever of two independent
hooks fires first (the `ShowScreen` postfix that drives Phase 1/2/3, or the separate
invoke2 ladder proof on `EnsureTabInitialized`), and a null anchor while the host log
shows "settings probe: ShowScreen (postfix) first fired" means a flag gating one of
those hooks is off, not that Settings was never opened.

---

## 3. Build rules

- **MSYS `sed -i` rewrites CRLF files as LF** (the repo has `* -text`), which
  turns a one-line edit into a whole-file diff and a phantom conflict. Edit with
  the Edit tool or a Python script that preserves newlines; check `git diff
  --stat` before committing.
- **PowerShell only.** `gcc` silently fails in Git Bash (exit 1, no output).
- Hand-invoking `nimony` outside `aowl` silently exits 0 producing **nothing**.
- **Name the target**: `aowl build host` ≈ 2m on a quiet machine, but MEASURED 740-840s
  (12-14 min) on 2026-09-02 with several agents and builds contending for the CPU; `aowl build` ≈ 4m27s warm / 18m cold.
  Targets: host backend sim launch installer emutest verify probe mods examples deploy.
- `aowl build` does **not** rebuild `aowl.exe` itself → use `aowl bootstrap`.
  `installer/build/` is gitignored, so a fresh worktree has **no** `aowl.exe` at all.
- **`bootstrap` and named targets exist only on `feat-dev-tooling` and its
  descendants** — measured: `grep -c bootstrap tools/aowl.nim` is 0 on `main`, and
  `tools/aowl.nim` at `04f0311` does not even compile. `integ-tooling` is the
  consolidated branch where they work; start there. If you copy `aowl.exe` from
  another checkout for speed, it runs **that checkout's** `aowl.nim`, so a build
  step defined on your branch goes **silently unexercised** — this has bitten
  three agents. Say so if you do it.
- **Concurrent builds in separate git worktrees are SAFE** (measured). Do NOT serialise
  agents. The corruption hazard is two builds in the **same checkout**.
- **So route every build through `python tools/buildlock.py build <target>`** —
  same arguments as `aowl`, one extra word, and it makes the hazard impossible
  instead of merely forbidden. Separate worktrees still build in parallel at
  full speed; only same-checkout builds contend.

  This rule was written into this file and broken **one hour later** by the same
  session, with the seductive reasoning *"I am only building a DIFFERENT
  target"*. That is exactly the case it is about: the hazard is the shared
  intermediate directory, not the final artifact. Two `aowl` and two `nimony`
  processes ran at once, **neither** left an artifact, `deploy.py check`
  reported the host DLL simply "not built", and ~20 minutes of subagent work had
  to be redone. A rule in a document cannot fail closed; a lock can. It refuses
  with exit 4 and builds nothing rather than colliding, breaks genuinely stale
  locks itself, and `--status` says who holds it.

## 4. NEVER deploy without verifying markers in the BUILT artifact

Rebuilds from a wrong base have silently dropped features many times (the scav-spawn fix,
the exit patch, the version brand, image serving). Use `python tools/deploy.py check|deploy|rollback`
— it refuses on any missing marker, backs up with a timestamp, and prints the rollback
line. Marker list is data in `tools/deploy.json`; **never edit it to make a check pass.**

When agents are building, deploy through `python tools/deploylock.py deploy <artifacts>`:
it holds the same build lock while it copies, because `aowl` removes its output
before writing it and a deploy issued in the second between two queued builds
reads an absent DLL (measured twice, 2026-09-01).

`deploy.py` covers only the **host** DLL. For a **mod** DLL use `tools/markers.py <dll>
<marker>...`, which shares `tools/litscan.py` with it and reports three outcomes
(PRESENT / MISSING / **INCONCLUSIVE**, exits 0 / 1 / 3).

**"Is this exact string in this DLL?" — DO THIS:**

```powershell
python tools\markers.py --string "settingsColorWidget" <path-to-any-binary>
```

Repeatable (`--string A --string B`), takes an arbitrary PATH (a build in a worktree —
nothing needs to be a declared artifact, and it never deploys), prints the byte offset and
WHICH encoding matched, and exits 0 PRESENT / 1 MISSING / 3 INCONCLUSIVE. It is also the
right way to assert a marker you **just added** landed in the build — do **not** add it to
`tools/deploy.json` for that, and never relax an entry there to make a check pass. MEASURED: under **Git Bash** a `--string` that begins with `/` is rewritten by MSYS path conversion before python ever sees it (`/aowlspt/keybinds` arrives as `C:/Program Files/Git/aowlspt/keybinds`, and was reported a confident MISSING); markers.py now REFUSES that shape as INCONCLUSIVE — re-run with `MSYS_NO_PATHCONV=1` or from PowerShell (a leading `//` is **not** a fix, it leaves the extra slash in the literal).

**NEVER marker-check a binary with PowerShell** —
`[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($p)).Contains($s)`.
`ASCII.GetString` maps every byte >= 0x80 to `?`, so any marker containing a non-ASCII
character reads as ABSENT — a confidently wrong answer. **FIVE separate agents** have hit
this: one lost ten minutes to 14 false MISSINGs (including a literal that predated its own
change), one nearly concluded its build had not picked up its own edits, one reported six
literals absent that `markers.py` finds immediately. `[Text.Encoding]::Latin1` is **`$null`**
on PS 5.1, and PowerShell returns `$null` for a missing static property instead of throwing
— so a `try/catch` probe reports "Latin1 exists", wrongly. And `ReadAllBytes` has returned a
**truncated** buffer on a freshly-built DLL (2,399,232 of 2,454,016 bytes), making every
marker past the cut read MISSING; `markers.py` checks the PE section table for exactly that
and answers INCONCLUSIVE. `grep -a` is acceptable; the one-liner is not.

And remember Nimony stores each `&`-concatenated fragment as a **separate rodata entry**,
so a long literal legitimately may not appear contiguously: that is INCONCLUSIVE, not
MISSING. `markers.py` measures fragment coverage and says which it is; a naive byte
search cannot tell them apart, and `--absent` needs a positive control or it can pass
vacuously.

## 5. IL2CPP facts

Reflection is **NOT dead** -- it is **TOKEN-GATED**. This is stock IL2CPP with a gated export ABI (`docs/IL2CPP_EXPORTS.md` -- NOTE: that file currently lives ONLY on the
unmerged branch `feat-il2cpp-export-map`, not here; measured 2026-08-26). **40** of the 241 `il2cpp_*` exports (22 static + 18 nonce; an earlier count of 38 was wrong) take an **extra trailing argument we never pass** -- a pointer to 32 bytes -- and `memcmp` it first. On mismatch they do NOT return NULL: they return a **uniform random non-zero uint64** from a per-thread MT19937-64. THAT is why a nil check passes and the first dereference kills the client. 20 gates are STATIC (expected bytes extracted from `.rdata`); 18 are NONCE-derived via the exported `il2cpp_nonce(apiId)`.

Two corrections, because both were once stated here as fact and are FALSE: `il2cpp_object_get_class` does **not** fault -- it is `mov rax,[rcx]; ret`, so a bad pointer yields a *plausible number* silently, which is worse; and `il2cpp_value_box` is intact and ungated. **Nothing a mod needs is stubbed** (386 exports, none at the universal stub; the 9 `ret0` ones are ordinary release no-ops).

**What to DO today:** raw static-offset field read/write, direct calls at byte-verified static RVA, and `il2cpp_string_new` -- a direct RVA call bypasses the export ABI entirely and no gate affects it. Never write "reflection is dead" into a comment, a doc or a refusal message again; say the export is token-gated and its failure mode is a plausible random value. Runtime managed **type injection is PLAUSIBLE, not blocked** -- every injector-relevant export (`object_new`, `gc_alloc_fixed`, `gchandle_*`, `runtime_class_init`, `runtime_invoke`, `add_internal_call`, `type_get_object`) is ungated -- but constructing a valid `Il2CppClass` has NOT been checked, so "plausible" means the export surface does not block it, not that it works. Convention: instance `RCX=this, RDX/R8/R9=args`, then a **hidden trailing `const MethodInfo*`**; NULL is fine except for shared generics. Imagebase `0x180000000`; generated code lives in the **`il2cpp` PE section, not `.text`**. Offsets come from `Il2CppMetadataRegistration.fieldOffsets` via `tools/il2cpp_resolve.py` -- **every verb takes the two paths FIRST**: `il2cpp_resolve.py GAMEASM METADEC <verb> ...`, verbs `find` / `methods` / `type [--shared]` / `bytes <RVA>` / `shared <RVA-or-VA>` / `fields <Type>` (writing `il2cpp_resolve.py bytes <RVA>` without the paths used to traceback out of `Resolver`; it now refuses with the full command line) -- or `tools/fldoff.py` (`fields <Type>` / `field <Type> <fieldName>`), each with a mandatory self-check (`System.String._stringLength@0x10`, `_firstChar@0x14`) that must pass before any offset is trusted -- **never guess**. Field offsets are **three-state**, never two: a real offset, `--` for a const (no storage), or **`GENERIC` / `GENERIC-NO-LAYOUT`** for an UNINSTANTIATED generic definition (``List`1``). IL2CPP writes an **all-zero** fieldOffsets array for those 1,569 types because the layout depends on the type arguments and is built at runtime; the tools used to print `0x0` for every field of ``List`1``, which is a fabricated offset that reads the object header. **Instantiated generic layouts (`List<int>`) are NOT reachable offline** -- the 33,464 `Il2CppGenericClass` entries are all present but every `cached_class` in the file is null; take that layout from a live object or from a verified header, and say it is borrowed. Full signatures are reachable offline (`returnType@8`, `parameterStart@16`, `parameterCount@34`), so a patch frame shape should be **derived, never inferred from a method name**. And the VALUES you pass must be the ones the game itself would
pass: read them off the live receiver the game handed you (MEASURED 2026-09-02: the
character-select Submit frame was correct for two weeks while the host computed its own
gameMode/profileData; the game's flow then met `EGameMode.Pve==1` where a Profile
belongs, crashing 1 boot in 3 -- reading `_gameMode@0x160`/`_profileData@0x178` off the
slot view fixed it in one call). Use `il2cpp_resolve.py callers` and `methods` to find
the real click path before pressing anything. Metadata strings are encrypted (`tools/metablob.py`; cache at `.cache/global-metadata.dec.dat`).

- **Walk from a verified live object; never trust an offset that can read null.**
  (`SettingsTab._rectTransform`@0x78 reads null; the row container was only ever reached
  by walking up from a live control.)
- **Writing UI text requires CALLING real setters** — `LocalizedText::SetLabelText`
  @0x140FE70, `TMP_Text::set_text` @0x51BC1E0 — **and re-applying**, because
  `LocalizedText` clobbers raw `m_text` stores. Resolving `ForceMeshUpdate` lands on
  `0x628110`, which is `C2 00 00` (`ret 0`) — and is **not that method's own code**:
  it is this build's universal empty-body stub, shared by **6,438** methods. A stub
  that passes a signature check is the worst case.
- **28.3% of by-name lookups land on a SHARED RVA** (6,261 RVAs have more than one
  owner). *Calling* a shared address is fine — it is correct code for the receiver
  you pass. **Detouring one is a write with unbounded blast radius**, because it
  fires for every method that shares it. Check sharedness before patching by name
  with `il2cpp_resolve.py ... shared <RVA-or-VA>`, or `Resolver.sharedness(addr)`
  in Python — **one function, three outcomes**: `shared` / `unique` / `unknown`.
  `unknown` (the address is not in the methodPointers histogram at all — a live
  ASLR address, a typo, a non-code RVA) is **not** "unsafe to assume unshared";
  it is a refusal. Never re-derive this from `shared_rva_counts()` with a
  `.get(rva, 1)` default: that default made every unknown address read back as
  "1 owner, safe to detour".
- **Two detours on one function**: the second overwrites the first's trampoline. Ride an
  existing detour as a drain. Verify prologues against the **startup snapshot**
  (`abi/aowlspt_prologue.h`), never against live memory — verifying after another feature
  patched the function reads the trampoline and self-rejects.
- Host safety, non-negotiable: prologue byte-verify, `VirtualQuery` on **every** hop,
  ONE `aowl_p_p_seh` per body (**not re-entrant — never nest**), capped iteration,
  flag-gated default-OFF, self-disable after N faults, no per-frame managed allocation.

## 6. Debug empirically. Make the client tell you.

Six source-reasoning attempts at one bug all failed; the first two empirical ones solved
it in an hour. In order of cost: the inspector → the client's own logs (`tools/ailog.py`,
`D:\Aowlspt\Logs\`) → the served payload on the wire → a read-only guarded host detour.

**Every failure path must announce itself.** A feature that declines silently is the
worst outcome we produce, and a confidently wrong diagnostic is worse than none — several
cycles have been lost to messages that asserted a cause with no evidence. State a measured
fact or say you do not know.

## 7. Consistency-check landmine

The client refuses to boot if a file listed in `D:\Aowlspt\ConsistencyInfo` changes SIZE.
`Logging.config` is HARDLINKED to `D:\Games\Tarkov\Logging.config`. Keep level names the
same length (`Trace`/`Debug`/`Error` are 5 chars; `Information` is 11) and re-sync the
manifest entry (Size + Checksum = byte-sum mod 2^32).

## 8. Token discipline

`db.json` is **41 MB on ONE line**; `locale_en.json` 2.7 MB on one line; `nettrace.log`
3.1 MB. A single unwindowed read destroys the session. Use `tools/bigjson.py`,
`tools/wirelog.py`, `tools/hostlog.py` — never `cat`/`Read` those files. Never read agent
transcript files. Do not paste long briefings into subagents: use `.claude/agents/*`.

## 9. The fact store: RECALL BEFORE YOU RE-DERIVE

This repo has a fact store (the `aowlfacts` MCP server in the `aowlcode` plugin,
SQLite at `%USERPROFILE%\.aowl\facts.db`). It holds two things: **facts** —
measured assertions with provenance — and **recipes**, replayable procedures
known to work.

**Before deriving anything about the live client, call `fact_recall`.** Before
navigating the UI, call `recipe_list` / `recipe_get`. This is not optional
politeness; it is the cheapest call in the session and the alternative has a
measured cost. In the session this rule comes from, the whole `open-settings`
procedure was re-derived by hand — through three wrong turns — while a recipe
holding the exact same five steps sat in the store, unread.

**Record what you measure, as you measure it**, with `fact_record`: a field
offset, an RVA, what a name really points at, and above all a FALSE POSITIVE —
a thing that looks like it worked and did not. `ButtonFeedback::OnPointerClick`
plays the click sound and presses nothing; that fact is worth more than most
working code.

Nothing forces either call. A hook can inject context and can deny a tool, but
**no hook can make a model call a tool** — so recall is a discipline, not a
mechanism, and it is on you.

What goes where:

* **the store** — high-cardinality measurements that expire when the game build
  changes (offsets, RVAs, klass identities, which node holds a label), plus
  procedures. Every fact carries a scope key hashed from `GameAssembly.dll` and
  `db.json`, so a Tarkov update marks them `[STALE: scope changed]` rather than
  letting them quietly lie.
* **this file** — prose rules, workflow, and the lessons above. Do not migrate
  them into the store; they are read once and cost nothing more.

A fact recorded as `measured` that was not measured poisons the store, and a
poisoned store is worse than an empty one. Say `inferred` when you inferred it.

## 9b. A VERIFICATION THAT CANNOT FAIL IS THE BUG

Every single defect in the settings screen -- twenty-plus hours of them -- was
the same shape. Not a hard bug: a check that could only ever say yes.

* the row relabel sized its write by counting the TMPs the **donor** had text
  on, then re-read only what it had just written. It reported "0 did not take"
  for 16 rows that were all visibly wrong on screen.
* a settle-loop counted any tick with `reaped == 0` as STABLE -- indistinguish-
  able from "the thing has not spawned yet" -- so it hit its threshold and
  disabled itself permanently before the late spawn.
* an offline disassembly proof established, correctly, which field
  `SetGameModeText` writes. It could not establish that the field reaches the
  screen. It did not. The label the player sees was a different object in a
  different scene root.
* the backend selftest asserted with substring `contains`, so a payload that
  was not valid JSON at all passed for months.

So: **assert a property of the FINISHED STATE, never of your own write.**
Prefer the negative -- "no TMP under this panel still reads the donor's
caption", "exactly one stock panel is active", "the served payload parses
strictly" -- because a negative can be falsified and a self-comparison cannot.
If you cannot describe the input that would make your check fail, you have not
written a check.

Three outcomes, never two: PASS / FAIL / **INCONCLUSIVE**. "I could not look"
is not a pass. `find`/`findtext` reporting STOPPED EARLY, an unreadable
pointer, a screen that never opened -- all inconclusive. The inspector already
models this correctly; code that consumes it must not flatten it.

And structural is not behavioural. A sibling index, an `activeSelf`, a log line
saying "ok" are evidence, not proof. The only thing that settles a UI question
is reading back what the live tree renders. `tools/acceptance.py` exists so that
costs one command instead of fifteen minutes -- run it before saying "fixed".

---

## 10. THE TOOLS ARE HALF-BUILT. SAY SO THE MOMENT YOU NOTICE

The live inspector, the fact store, `harness.py`, `entergame.py`, `deploy.py` —
all of it is under active construction and none of it is finished. **The instant
you hit a rough edge, a wrong answer, a missing verb or a thing you wished
existed, RAISE IT IMMEDIATELY, in the same message.** Do not file it away, do
not "work around it and mention it later", and above all do not silently route
around it. Working around a broken tool and saying nothing is the single most
expensive thing you can do here, because the workaround costs you ten minutes
and costs the next session the same ten minutes forever.

This is not a suggestion box. It is the main feedback loop of the project, and
it has already paid for itself many times over. In one session the inspector
produced: a failed `component` lookup leaving `$comp` holding the PREVIOUS
batch's pointer, so `click` pressed the wrong object twice and printed a
complete, entirely fictional field map of a Button that does not exist;
`click`/`invoke` imposing `UnityEngine.UI.Button`'s layout on any pointer, which
called `UnityEvent::Invoke` on a GameObject and escaped the guard; `label` on a
Transform reporting `text = ""`, which reads as "the label is empty" and is not
an answer; and `open` rejecting a correct target because the prologue snapshot
had recorded our own trampoline. Every one of those was found by USING the tool
and saying so, and every one is now fixed. None would have been found by
reading the code.

So, concretely:

* **A tool that gives a confidently wrong answer is a P0.** Report it before
  continuing with whatever you were doing. A wrong answer delivered plausibly is
  worse than a crash.
* **A missing verb is a feature request.** Say what you wanted and what you had
  to do instead. "I could not search by the text a control DISPLAYS, only by
  object name, so I hunted through the tree by hand" is exactly the report that
  is wanted.
* **Include the evidence** — the batch you ran and what came back. A one-line
  gripe with no repro is not actionable.
* **Propose the fix if it is obvious**, but do not go implement it mid-task
  without saying so first; the human decides what gets built next.

---

## 11. WORK AUTONOMOUSLY. DO NOT ASK WHICH THING TO DO NEXT.

Standing instruction from the user, given 2026-09-01 and not to be re-litigated:

> "idk do whatevers best, dont ever ask me again- be time efficient and token
> efficient- get the most done, always, but always be smart- waste time building
> great tooling and systems"

So: **do not end a turn with a question about priority.** "Should I do A or B?"
is the single most expensive sentence available here, because it costs a
round trip and buys nothing the repo cannot answer. Pick the one that unblocks
more work, do it, and say what you picked. Ask only when proceeding under any
assumption would be unsafe or would destroy work -- that is a different thing
from not knowing which task is more valuable.

The three efficiencies, in priority order when they conflict:

1. **Be smart.** A wrong answer delivered fast is the most expensive outcome in
   this project. Section 9b outranks everything below.
2. **Be time efficient.** Parallelise. Dispatch independent work to subagents in
   ONE message so they run concurrently, and keep working while they run. The
   coordinating session drives the game and serialises deploys; subagents build
   and report artifacts (section 1). Never serialise two things that do not
   depend on each other.
3. **Be token efficient.** The logs here are measured token bombs (section 8).
   Never read a whole log, a whole transcript, or `db.json`. Prefer a tool that
   answers a question over a dump you then read.

**"Waste time building great tooling and systems" is an explicit licence, and
it is the highest-leverage instruction in this file.** A fix applies once; a
tool applies every session afterwards. When you hit a rough edge, the right
response is usually to build the thing that makes the whole class of problem
visible, not to work around this instance. Measured examples from the session
this rule came from:

* the supervisor could not detect a stall by construction, because the host's
  5-second heartbeat refreshed the progress clock. The fix was 20 lines; the
  VALUE was `tools/test_supervise.py`, which drives the real supervisor against
  synthetic logs and proves each verdict CAN fire -- including the negative
  controls.
* 14 worktrees had been gutted by Windows temp cleanup, leaving checkouts where
  `git commit -a` would commit the deletion of the whole tree. Removing them
  took a minute. `tools/wtcheck.py` means it can never silently return.
* `Resolver.parent_type` had been answering "no base class" for 13,088 of
  29,835 types. The fix was small; the value was the `verify-parents`
  self-check that now gates map generation and that FAILED before the fix.

The build slot is the one genuinely serial resource: **concurrent `aowl build
host` in the SAME checkout corrupts** (separate worktrees are safe, but see
section 0 and `wtcheck.py` before creating one). When several agents need to
build, the coordinator hands out the slot; an agent that is ready to build says
so and waits rather than building speculatively.

Report what you did and what you did NOT verify. Finishing with "here is what
is still unproven" is complete work; finishing with a question about what to do
next is not.
