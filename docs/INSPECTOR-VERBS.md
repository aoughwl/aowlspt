# The aowlspt live inspector — verb reference

The inspector asks the **running** client a question and answers in seconds, with
no rebuild and no restart. This file is the complete verb reference.

It is written for two audiences at once: a modder who wants to know what a
control is, and an automated batch that wants a machine-readable verdict.

---

## The contract this instrument keeps

**Every answer distinguishes "I looked and it is not there" from "I could not
look."** That is not a nicety, it is the whole design:

- `find` reports `searched EXHAUSTIVELY` versus `STOPPED EARLY`, and
  `STOPPED EARLY` is never phrased as absence.
- A failed `component` lookup leaves `$comp` **unbound**, so a later `click
  $comp` refuses instead of pressing whatever the previous batch left there.
  (It once pressed the wrong object twice and printed a complete, entirely
  fictional field map of a Button that did not exist.)
- `rect` refuses rather than printing a plausible-but-wrong struct.
- Feeding a **GameObject** to a Transform walker is refused: it used to read a
  plausible `childCount` and invent a hierarchy of wrong children *without
  faulting*.
- Assertions report **PASS / FAIL / INCONCLUSIVE**, never two outcomes.

If you add a verb, it must keep this property. A verb that cannot report "I
could not look" is a bug, not a feature.

---

## Using it

Write commands to `D:\Aowlspt\aowlspt\aowlspt-inspect.txt`. Answers land in
`aowlspt-inspect-out.txt` and in the host log.

The trigger is a **content change**, so to re-run an identical batch, bump a
serial line:

```
#12
roots
```

Write the file **without a BOM**. PowerShell 5.1's `Set-Content -Encoding utf8`
emits one; it is stripped now, but `printf` from Bash is the safe habit.

Flags in `aowlspt-host.json`:

| flag | what it enables |
|---|---|
| `liveInspector` | the whole channel, read-only |
| `liveInspectorWrite` | permits `allow write`; without it, writes and calls refuse |

Anything that **writes** or **calls into game code** additionally needs an
`allow write` line in the batch itself. That permission lasts for that batch
only.

### Expressions

```
EXPR = ATOM ( +0xNN | @0xNN )*
```

`ATOM` is `0x<hex>`, a decimal, or `$name`. `+` **moves** the address; `@`
moves and then **DEREFERENCES**.

```
$preloader@0x20        the version label
$verlabel+0xe0         where TMP.m_text lives
```

Anchors rebind per batch: `$preloader $verlabel $modetext $tab1 $settings
$gameworld $you $_`. `state` explains **why** an anchor is null.

### Types

`i8 u8 i16 u16 i32 u32 i64 u64 f32 f64 ptr bool str klass`

`klass` reads the `Il2CppClass*` every live IL2CPP object carries at offset 0 —
the one piece of type information that is reachable without reflection, and
enough to answer "are these two objects the same type".

---

## Assertions — making a batch a TEST

This is the newest and most important group. Without it, a batch is a
transcript that a human has to read; with it, a batch has a verdict a harness
can grep.

Every assertion has exactly three outcomes:

| prefix | meaning |
|---|---|
| `PASS:` | the finished state was read, and it is what was claimed |
| `FAIL:` | the finished state was read, and it is **not** what was claimed |
| `INCONCLUSIVE:` | the state could **not** be read; nothing was established |

`INCONCLUSIVE` is never folded into either of the others. Concretely you get it
when the expression does not evaluate, when the memory is not readable, when
the object is Unity-fake-null, or when a helper function did not byte-verify on
this build.

### `assert EXPR TYPE OP VALUE`

`OP` is `==` `!=` `<` `<=` `>` `>=`. For `TYPE str` it is `==` `!=` or
`contains`, compared against the rest of the line.

```
assert $verlabel+0xe0 str contains 1.0
assert $settings+0x118 ptr != 0
assert $f1+0x38 f32 > 0.5
```

Notes that matter:

- Comparison is on the **raw value**, not on rendered text, so formatting can
  never change a result.
- `f32`/`f64` equality uses a **relative tolerance** (~1e-6). Exact `==` on a
  value that came out of a matrix multiply is a check that can only ever fail —
  the mirror image of one that can only ever pass.
- Signed types are sign-extended by declared width, so `assert p i32 == -1`
  means what it says.
- A **null `String*`** is a real, readable answer: `assert ... str != foo`
  passes, `== foo` fails. It is not inconclusive.
- An unknown TYPE or an unknown OP is a **refusal** ("nothing was asserted"),
  not a failure — it does not count toward the verdict at all.

### `assert-active EXPR` / `assert-inactive EXPR`

Uses `GameObject::get_activeInHierarchy`, **not** `activeSelf`. A node that is
itself active but sits under an inactive ancestor is still unpressable — a
press on it reports success and does nothing — so `activeSelf` would be a check
that passes for an unpressable node.

`INCONCLUSIVE` when the node is unreadable, when it is fake-null, or when the
helper functions did not verify on this build.

### `assert-null EXPR` / `assert-nonnull EXPR` / `assert-readable EXPR`

Three separate claims on purpose:

- `assert-readable` is a claim about **memory** — is this address committed.
- `assert-null` / `assert-nonnull` are claims about the **pointer stored at**
  that address.

`assert-nonnull` additionally **FAILS** on Unity fake-null: a non-zero,
readable pointer whose native half at `+0x10` is gone still compares `== null`
in C#, and a fake-null object is not a live one. It also fails on a non-zero
value that is not readable memory at all — a non-zero value is not an object.
On success it binds `$_`.

### `assert-name EXPR SUBSTR`

The node's GameObject name **contains** `SUBSTR`, case-insensitive — exactly
`find`'s own predicate, so the two cannot disagree about what "this node is
called X" means.

An **empty** name is `INCONCLUSIVE`, not a mismatch: `Object::get_name`
returning `""` is indistinguishable from the call not having produced anything.
(This is the same trap as `label` reporting `text = ""`, which reads as "the
label is empty" and is not an answer.)

### `verdict`, and the automatic batch verdict

Any batch that ran at least one assertion ends with two grep-able lines:

```
  ASSERTIONS: 3 pass, 1 fail, 0 inconclusive
  BATCH VERDICT: FAIL
```

Precedence is **FAIL > INCONCLUSIVE > PASS**. `INCONCLUSIVE` outranks `PASS`
deliberately: a batch where two checks passed and one could not look has not
demonstrated the property it was written to demonstrate.

A batch that ran **no** assertions prints **no verdict line**. "No checks ran"
and "every check passed" must never print the same thing.

Counters are per batch and a **resumed** batch keeps them — a batch that parked
on `until` is one test, not two. `verdict` prints the running tally mid-batch.

---

## Lifecycle and diagnosis

### `watch EXPR TYPE [FRAMES]`

Samples a value **once per frame** (default 60 frames, cap 240) and reports
every change.

```
watch $you+0x1c8 f32 120
```

This exists because a value that is wrong one frame in thirty is invisible to
`read`, and `read` run twice is indistinguishable from a value that never
moved.

The **whole expression is re-evaluated every frame**, not just the final read: a
pointer chain whose middle hop is republished is exactly the lifecycle bug this
verb is for, and caching the final address would hide it.

The summary separates three genuinely different results:

- **0 readable samples** → `NOTHING WAS SAMPLED … INCONCLUSIVE`. This says
  nothing about stability; it says the instrument could not look.
- **some unreadable frames** → reported as its own lifecycle finding: something
  in the chain was being destroyed and recreated.
- **read every frame, never changed** → a real negative, explicitly scoped to
  the window: "a flicker rarer than N frames would not have been seen."
- **changed N times** → not stable.

Changes are printed up to 16 and counted beyond that.

### `whyread EXPR` (alias `explain`)

Explains *why* an expression is or is not usable, in up to six numbered steps:

1. the expression did not parse/evaluate (and the syntax rule)
2. it is NULL, or it is not committed memory — and whether it lands inside the
   `il2cpp` **code** section, which means it is a function address, not an
   object
3. the `Il2CppClass*` at `+0x00`: unreadable, not a class at all, or a type
   name **checked against this build's metadata** and printed as `UNVERIFIED`
   if no such type exists
4. whether the klass is a Transform or a GameObject that this session learned
   from a by-contract source — and, for a GameObject, why Transform walkers
   refuse it
5. **Unity fake null**: readable, and dead
6. `activeInHierarchy`, or an explicit "could not be determined" — which is
   inconclusive, not "active"

> `why` is **still** the alias for `whydidntitdraw`. It was deliberately not
> rebound: quietly repointing a verb that existing scripts use, at a different
> question, is the exact class of silent change this instrument is supposed to
> be incapable of.

---

## Navigation

### `roots`

Every scene root → `$r0..$rN` (Transforms; the GameObjects are `$rgo0..`).

This is how you reach anything. The live UI is **not** in any scene
`SceneManager` lists — on this build it is in `DontDestroyOnLoad`, which
`sceneCount`/`GetSceneAt` exclude by design. `roots` asks which scene
`$preloader` really belongs to and enumerates that.

### `children EXPR [N]` · `tree EXPR [DEPTH]` · `parent EXPR [DEPTH]`

`children` binds `$c0..$cN`. Walking **up** from an object you have already
verified is the most reliable navigation on this build.

### `path EXPR`

The full hierarchy path as one line, `/A/B/C`. Three outcomes:

- **COMPLETE** — the walk reached a null parent, so the path is absolute within
  its scene root.
- **INCOMPLETE** — the chain stopped at an unreadable or fake-null ancestor.
  The leading `...` is not decoration; the part above it is unknown.
- **TRUNCATED** — the 24-level depth cap. The part above was never walked.

If `Transform::get_parent` does not byte-verify on this build, `path` refuses
outright rather than printing an empty path.

### `siblings EXPR` (alias `sibs`)

The node's parent's children, each with its `activeInHierarchy` state, bound to
`$s0..$sN`, with **this** node marked `<<< THIS` and its sibling index stated.
Sibling index is how nearly every row, tab and list control in this UI is
actually identified.

- A **null parent** is an answer, not a failure: "it is a hierarchy root, so it
  has no siblings."
- If the node is **not among its own parent's children**, that is reported as a
  contradiction and the whole listing is declared INCONCLUSIVE — usually it
  means you passed a component where a Transform was compared.

### `find NAME [ROOT] [BUDGET]` · `find NAME in ROOTNAME` · `find more [BUDGET]`

Name search. **No root searches every scene.** Auto-resumes across frames
(12ms per frame slice; the node budget bounds the whole search) and always says
which happened: `searched EXHAUSTIVELY` or `STOPPED EARLY`.

`find NAME X` with exactly one trailing token is genuinely ambiguous. It
disambiguates by **readability** — if `X` reads back as a live Transform it is a
ROOT, otherwise a BUDGET — and says which it picked and why. An explicit ROOT
that does not read back as a valid Transform is refused **up front**.

### `findtext SUBSTR [ROOT] [BUDGET] [all]` · `findtext more [BUDGET]`

Search by the **text a control displays** (TMP_Text only), not by object name.
Shares `find`'s root/budget parser and reporter, so the two cannot drift apart.

Every hit is checked against `activeInHierarchy` and tagged, because a hit on an
inactive node is **not pressable**. Active nodes only by default; `all`
includes inactive hits, and the summary always states which scope was searched.

> **Known blind spot:** menu button captions live in EFT
> `DefaultUIButton._text @+0xB8`, which is **not** a TMP_Text node, so
> `findtext` finds **zero** for them. Drive those by object NAME plus a visible
> filter plus a component press (`pressname`).

### `findcomp TypeName [ROOT] [BUDGET]`

Find every node that **has a component** of a given type.

```
findcomp PostProcessLayer
findcomp Button $r3 1200
```

"Find the object with a PostProcessLayer" is a question `find` (name) and
`findtext` (displayed text) both structurally cannot answer.

Route: one `il2cpp_string_new` for the type name, reused for every node, then
the **Component** overload of `GetComponent` on each Transform. Transforms come
out of the child walk *by contract*, so the GameObject/Component overload
confusion — which faults inside Unity's C++ — cannot arise here.

Binds `$k1..` (the component) and `$kn1..` (the node), and tags each hit
active / INACTIVE / UNKNOWN.

Cost and honesty:

- Each node costs a **managed call**, not a field read — roughly two orders of
  magnitude more expensive per node than `find`. Default budget is therefore
  **600** nodes, ceiling 4000, and there is deliberately **no `more`**.
- It is **atomic**: one frame slice, no cross-frame resume.
- A partial answer says `STOPPED EARLY` on the budget or on the frame slice,
  and is never described as exhaustive. `0 valid nodes visited` says
  `NOTHING WAS EXAMINED … the search never looked`.
- If the `GetComponent(System.String)` icall is not registered in this runtime,
  it refuses before touching anything and calls that INCONCLUSIVE — because
  every node would otherwise take the wrapper's failure branch and raise.

---

## Reading memory

| verb | what it does |
|---|---|
| `read EXPR TYPE` | one typed read; a `ptr` read also binds `$_` |
| `write EXPR TYPE VALUE` | needs `allow write` |
| `dump EXPR [N]` | hex dump |
| `fields EXPR [N]` | per-8-byte-slot guess table |
| `scan EXPR N TYPE VALUE` | find the offset of a known value |

---

## Components, geometry, text

| verb | notes |
|---|---|
| `component EXPR TypeName` | → `$comp`. A failed lookup leaves `$comp` **unbound**. Picks the GameObject vs Component overload from the klass. |
| `components EXPR [BaseType]` | lists every component, named and validated against this build's metadata |
| `rect EXPR` | `anchoredPosition`, `sizeDelta`, `anchorMin/Max`, `pivot`, `rect`. Refuses on a failed prologue verify or an absurd struct rather than printing a number. Do **not** use `fields` instead: `RectTransform` declares exactly one il2cpp field; the rest are native-side. |
| `canvas EXPR` | the Graphic's cached Canvas and its render mode |
| `label EXPR` | `TMP_Text.m_text` as a field read |
| `settext EXPR TEXT...` | writes via the **real setters** and re-applies |

`ForceMeshUpdate` resolves to `0x628110`, which is `C2 00 00` (`ret 0`) — this
build's **universal empty-body stub, shared by 6,438 methods**. It is not that
method's code. Writing raw `m_text` does not stick either; `LocalizedText`
clobbers it.

---

## Visibility

| verb | notes |
|---|---|
| `visible EXPR` | composite verdict: active, graphic enabled, colour alpha, CanvasGroup chain, Canvas enabled/order/mode, lossyScale, pixel rect → `NOT VISIBLE` + CAUSE, `VISIBLE`, or `INCONCLUSIVE`. Never two. |
| `screenrect EXPR` | the rect in real back-buffer pixels, origin bottom-left. Says UNKNOWN, not "off screen", when the back-buffer size has not been published. |
| `canvasorder [EXPR]` | live Canvases and their sortingOrder. Without EXPR it is a SCOPE, not a census. |
| `whydidntitdraw EXPR` (alias `why`) | runs all three and names the first failing condition |

---

## Acting on the UI (all need `allow write`)

| verb | notes |
|---|---|
| `click EXPR` | `Button::Press`, checks `interactable` |
| `invoke EXPR` | fires `m_OnClick` directly, no checks |
| `press EXPR [OFF]` | EFT `DefaultUIButton.OnClick` at `+0x120` |
| `pressname NAME [ROOT]` | find → keep the ONE VISIBLE → press it. **Refuses on 0 or more than 1 visible.** |
| `open [GROUP]` | `SettingsScreen::ShowScreen` — asynchronous |
| `tab EXPR [0\|1]` | `SettingsTab::set_IsSelected` |
| `record on\|off` | log every UI click as `clickrec:` (read-only) |

`ButtonFeedback::OnPointerClick` plays the click sound and presses **nothing**.
Pressing an **inactive** node returns success and does nothing.

---

## Batch control

| verb | notes |
|---|---|
| `# anything` | comment; a `#12` serial line is how you re-run an identical batch |
| `let NAME EXPR` | bind `$NAME` for the rest of the batch |
| `wait N` | park N frames |
| `until EXPR [FRAMES]` | park until the pointer at EXPR reads non-zero |
| `watch EXPR TYPE [N]` | see above |
| `allow write` | arm writes and calls, **this batch only** |
| `echo TEXT` | put a marker in the output |
| `state` / `where` | what screen/tab is up right now |
| `anchors` / `targets [SUBSTR]` / `image` / `help` | inventory |

`until` exists because navigation is asynchronous: `ShowScreen` returns long
before the screen it asked for exists. A timeout is **reported and the batch
continues**, because the commands after a failed wait are usually the ones that
explain why it failed. Frame cap 300 (~5s) for `wait`/`until`, 240 for `watch`.

---

## Operating traps (measured)

- Running inspector reads immediately after a raid-entry marker **stalls the
  still-loading client** and can produce a stuck load: the entry marker fires
  during scene LOAD, not at deploy. The raid-phase latch is the only
  trustworthy deployed signal.
- The inspector self-disables after a fault budget is spent. Faults are caught
  and named (`LAST HOP: …`), but they are finite per session; a restart re-arms
  it.
- Long searches park and resume rather than stalling the frame. If a batch
  seems to hang, it is more often parked on an `until` than crashed.

---

## The REPL, and mod control (`python tools\irepl.py`)

Interactive shell over the same file channel, with history and tab completion.
`.help` lists the meta commands. **One line = one batch**, matching the file
channel's real anchor semantics — `$f1`/`$comp`/`$r0` do *not* survive to the
next line, and the shell does not pretend otherwise; `.batch` … `.end` composes
several lines into ONE batch when anchors must carry.

It is not a new transport. It imports `tools/ichannel.py`, which is now a
re-export of `plugins/aowlsptcode/mcp/channel.py` — the sentinel-guarded
transport and prose parsers the `aowlinspect` MCP server already uses.
`tools/inspector.py` (under `ui.py` / `enterraid.py`) delegates to the same
module now, so the python side is **one** implementation where it was three.
The Nim side (`tools/aowlui.nim`'s `Ui`) was already shared by `aowl ui`,
`aowl raid`, `aowllayout` and `autoscript`, and is untouched.

The verdict model survives interactively: the host's own `BATCH VERDICT` line
is adopted, `find`/`findtext` STOPPED-EARLY-with-no-hits is recorded as
INCONCLUSIVE (absence is not proven), `.verdict` rolls the session up with
FAIL > INCONCLUSIVE > PASS, and a session in which nothing asserted anything
prints **no verdict at all** rather than PASS.

Readiness: a batch that gets no answer flips the shell to NOT READY and every
later line refuses by name (`CLIENT_NOT_READY`) until `.ready` gets an answer.
This is the raid-load trap above — a REPL invites rapid-fire reads, and rapid-
fire reads into a loading client is what produces the stuck load screen.

### Mod control

These are **HTTP against the backend**, not inspector batch commands, because
that is where mod state lives (`docs/MOD-ENABLE-PATH.md`, `mods/manager`).
Nothing here touches the Unity main thread. Implementation: `tools/modctl.py`.

| verb | what it does |
|---|---|
| `mods [FILTER]` | every mod, with **which of the four gates is blocking it** |
| `modinfo <id>` | one mod in full, with the manager's own reason |
| `modenable <id>` | persistent user override ON — needs `.write on` |
| `moddisable <id>` | persistent user override OFF — needs `.write on` |
| `modreload <id>` | live restart — **refuses by name** (see below) |

`mods` never answers "off". It names the gate, because "off" is what made
`aowl.ammoloading` look broken for a day when the platform had simply never
selected it. Per-row outcomes and their named refusals:

| outcome | refusal | meaning |
|---|---|---|
| FAIL | `DLL_MISSING` | gate 1 — no `mods\<dir>\<lib>` in the install |
| FAIL | `NOT_SELECTED` | gate 3 — no list and no override mentions it |
| FAIL | `BLOCKED` | gate 4 — wrong-side / pipeline / dep / conflict / cycle |
| FAIL | `SELECTED_BUT_NOT_LIVE` | selected, and the client host says it is not running |
| INCONCLUSIVE | `NO_CLIENT_ANSWER` | `clientLive` is **absent** from the row. `manager.nim` is explicit that absence means *no answer yet*; rendering it as "not loaded" is the bug the field exists to prevent |
| INCONCLUSIVE | `UNKNOWN_VERDICT` | a verdict this tool has no wording for, printed verbatim rather than guessed at |
| INCONCLUSIVE | `BACKEND_UNREACHABLE` | we could not look. Names every URL tried and why each failed |
| INCONCLUSIVE | `NOT_IN_REGISTRY` | gate 2 — not a mod the manager knows |
| PASS | — | selected, and the client host reports it LIVE |

**`modreload` refuses.** There *is* a `GET /aowlspt/mods/reload` route and it is
not this: it re-reads `registry/mods.json` from disk. It does not quiesce the
mod, detach its detours, `FreeLibrary` it or re-arm it — and a `FreeLibrary`
landing during scene teardown with detours still armed is a live crash. So the
verb refuses, with **two distinct named causes**, because they have different
fixes:

- `RELOAD_NOT_DECLARED` — the mod has not set `AOWLSPT_MOD_HOT_RELOADABLE`, so
  since `ba46898` the client host refuses to unload it live and it stays loaded.
  That gate exists because two undeclared mod DLLs were `FreeLibrary`'d during
  scene teardown and took the client down inside a second. No mod in the repo
  declares it today. The fix is in the mod, not here.
- `RELOAD_UNSUPPORTED` — the mod *is* reloadable but no driver exists. The verb
  looks up `tools/modreload.py:reload_mod` and starts working the day that
  lands. It will not substitute `GET /aowlspt/mods/reload`, which is a registry
  re-read, and reporting success for an operation that never ran is the whole
  thing we are avoiding.

### Self-test

    python tools\irepl.py --selftest      20 cases, offline, no client, no backend
    python tools\irepl_mutation.py        proves the self-test can FAIL

The self-test covers PASS, FAIL and INCONCLUSIVE for the mod verbs, including
"not selected" and "cannot be reloaded" as **distinct named refusals**. The
mutation run collapses the three-state `clientLive` into two and asserts the
self-test goes red — a check whose failing input you cannot name is not a check.
