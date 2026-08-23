# aowlspt — how to work in this repo

## 0. NEVER expose the personal address. Non-negotiable.

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

**This rule is for the COORDINATING session, not for subagents.** A subagent must never
deploy to `D:\Aowlspt\aowlspt` and never start or stop the game: a human may be playing,
several agents build concurrently, and every deploy must be serialised through one place
that verifies markers first. Subagents build, verify, and report an artifact path.

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

Write the command file **without a BOM**. PowerShell 5.1's `Set-Content -Encoding
utf8` emits one; it is stripped now, but `printf` from Bash is the safe habit.

Flags in `aowlspt-host.json`: `liveInspector` (read-only), `liveInspectorWrite` **plus**
an `allow write` line in the batch for anything that writes or calls into game code.

**NEVER take a screenshot to find something out.** It is the most token-expensive action
available and the inspector exists precisely to replace it. Reserve screen capture for
questions that are genuinely visual and that no field read can answer — and say why.

Anchors rebind per batch: `$preloader $verlabel $modetext $tab1 $settings $gameworld
$you $_`. `state` explains WHY an anchor is null (e.g. the host learns the SettingsScreen
pointer only once that screen has been opened).

---

## 3. Build rules

- **PowerShell only.** `gcc` silently fails in Git Bash (exit 1, no output).
- Hand-invoking `nimony` outside `aowl` silently exits 0 producing **nothing**.
- **Name the target**: `aowl build host` ≈ 2m vs `aowl build` ≈ 4m27s warm / 18m cold.
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

## 4. NEVER deploy without verifying markers in the BUILT artifact

Rebuilds from a wrong base have silently dropped features many times (the scav-spawn fix,
the exit patch, the version brand, image serving). Use `python tools/deploy.py check|deploy|rollback`
— it refuses on any missing marker, backs up with a timestamp, and prints the rollback
line. Marker list is data in `tools/deploy.json`; **never edit it to make a check pass.**

## 5. IL2CPP facts

Reflection is **dead** (`il2cpp_object_get_class`, `il2cpp_class_get_name`,
`il2cpp_value_box`, field iteration all fault). Only raw static-offset field read/write,
direct calls at static RVA, and `il2cpp_string_new` work. Convention: instance
`RCX=this, RDX/R8/R9=args`, then a **hidden trailing `const MethodInfo*`**; NULL is fine
except for shared generics. Imagebase `0x180000000`; generated code lives in the
**`il2cpp` PE section, not `.text`**. Offsets come from `Il2CppMetadataRegistration.fieldOffsets`
via `tools/il2cpp_resolve.py` (`find` / `type` / `bytes <RVA>`; there is **no**
`fields` verb) — **never guess**. Full signatures are reachable offline
(`returnType@8`, `parameterStart@16`, `parameterCount@34`), so a patch frame shape
should be **derived, never inferred from a method name**. Metadata strings are
encrypted (`tools/metablob.py`; decrypted cache at `.cache/global-metadata.dec.dat`).

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
  fires for every method that shares it. Check sharedness before patching by name.
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
