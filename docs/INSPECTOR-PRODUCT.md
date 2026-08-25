# The live inspector as a first-class product

Source of record: `host/Aowlspt.Host.Il2Cpp/inspect.nim` (~4,200 lines), read in
bounded windows for this pass. CLAUDE.md section 2 documents the verb surface
from the outside; this doc checks it against the actual code.

## 1. What it is today

Verb dispatch lives at `inspect.nim:3389-3548`. Grouped by capability:

**Memory / typed access**
- `read EXPR TYPE`, `write EXPR TYPE VALUE` — i8..i64, u8..u64, f32, f64, ptr,
  bool, str, klass. `write` is gated (see Safety below).
- `dump EXPR [N]` / `fields EXPR [N]` — raw bytes, capped at `InspMaxDumpBytes`
  = 512 per call, a deliberate blast-radius cap.
- `scan EXPR N TYPE VALUE` — byte-range search for a value.
- `let NAME EXPR` — bind an expression result to a session variable.

**Tree navigation**
- `roots` — every scene root, including `DontDestroyOnLoad`, which
  `SceneManager` enumeration silently excludes. This is the fix for the
  original "NOT PRESENT" false negative described in CLAUDE.md — confirmed
  present and is the officially documented way to reach anything.
- `parent EXPR [N]`, `children EXPR`, `tree EXPR [DEPTH]`.
- `find NAME [ROOT] [BUDGET]` / `find more [BUDGET]` — name-substring search,
  resumable across frames (12ms slice/frame), reports `EXHAUSTIVE` vs
  `STOPPED EARLY` explicitly (`inspect.nim:1690,1702`). **Confirmed: matches
  only the GameObject's own name** (`nm` at line 1662) — there is no way to
  search by displayed text.

**Components / UI reads**
- `component EXPR TypeName` → binds `$comp`.
- `components EXPR` — enumerate a GameObject's components.
- `rect EXPR` — RectTransform geometry.
- `label EXPR` — TMP_Text content, read as a field (`m_text` @ +0xE0).
- `canvas EXPR` — resolve a Graphic's owning Canvas.

**Writes / calls (gated)**
- `settext EXPR TEXT...` — writes through real setters
  (`LocalizedText::SetLabelText`, `TMP_Text::set_text`), never a raw
  `m_text` poke, and reads back before/after to catch a silent revert.
- `press EXPR [OFFSET]` — EFT's own `DefaultUIButton.OnClick` path.
- `click EXPR` / `invoke EXPR` — `Button::Press` (checks interactable) vs
  raw `UnityEvent::Invoke`.
- `open [GROUP]` / `tab EXPR [0|1]` — screen/tab navigation helpers.
- `call TARGET SIG [ARGS]` — direct IL2CPP call by RVA, several signature
  shapes (`p`, `pp`, `pi`, `pl`, `pf`, `pff`, `i`, `b`, ...).

**Session / meta**
- `state` / `where`, `anchors`, `targets`, `echo`, `help`, `wait`/`until`,
  `allow write`, `image`.

### The three CLAUDE.md-cited failures — verified against inspect.nim, not assumed

1. **Stale `$comp` after a failed lookup.** Fixed. `iCmdComponent` clears
   `$comp` *before* attempting the lookup (`inspect.nim:2187-2202`, comment
   explicitly narrates the old bug: "click $comp -> pressed the PREVIOUS
   batch's component"). `click`/`invoke` on a null `$comp` now name the
   specific cause ("A `component` lookup that fails now leaves $comp unbound
   rather than stale", `inspect.nim:2791`).

2. **`click`/`invoke` imposing `UnityEngine.UI.Button`'s field layout on any
   pointer.** Fixed, and fixed twice over. `iCmdClick` (`inspect.nim:2764+`)
   has two live type-confusion guards: a GAMEOBJECT-in-the-OnClick-slot check
   (the one that actually caused the escape — EFT's `DefaultUIButton` is not
   a `UnityEngine.UI.Button` at all, confirmed by measured
   `GetComponent("Button")` returning NULL) and a KNOWN-KLASS-pointer check.
   `press` is a second, EFT-native verb built specifically because Button's
   layout doesn't apply to any real EFT control.

3. **`label` on a Transform reporting `text = ""`.** Fixed. `iCmdLabel`
   explicitly refuses a Transform by klass identity before reading +0xE0
   (`inspect.nim:2540-2549`), with the exact false-negative story from
   CLAUDE.md preserved in the source comment as the reason for the guard.

All three are real, checked-in guards, not just documentation. That is a
meaningfully stronger claim than "the doc says it's fixed" — worth surfacing
to the owner, since the CLAUDE.md write-up reads as a live warning and the
code has since closed all three.

### Half-built / still worth flagging
- `find` is name-only (see Gaps).
- `find` results are frame-sliced and resumable, which is correct for safety
  but means a caller must know to check EXHAUSTIVE/STOPPED EARLY — an easy
  thing for a new user to skip and silently misread as "not present."
- `scan`/`dump`/`fields` cap at 512 bytes per call with no documented way to
  page through a larger struct other than repeated calls at increasing
  offsets — usable, but manual.
- `call`'s signature shapes (`p`,`pp`,`pi`,`pl`,`pf`,`pff`,...) are a fixed
  enum of argument shapes; a call needing a shape not in that list has no
  fallback verb.

## 2. Gaps — what a user would reach for and not find

1. **Cannot search by displayed text, only by object name.** Confirmed at
   `inspect.nim:1662` — `find` compares against the GameObject name (`nm`),
   never against a resolved TMP_Text/label string. A user hunting "the button
   that says PLAY" must walk the tree by hand and `label` every candidate.
   This is the one CLAUDE.md already names; it is real.
2. **No search by component type.** `find` matches names; there is no
   `find type:DefaultUIButton` or `findcomp TypeName [ROOT]` to answer "every
   button in this subtree," which is a hugely common question once you're
   past exploring one specific control.
3. **No structured/JSON output.** Every verb answers in narrated prose text
   designed for a human reading the file. A future tool built on top of the
   inspector (a UI overlay, automated test assertions, an LLM driving it) has
   to re-parse that prose. There is no `--json` or machine-readable mode.
4. **No batch composition beyond sequential lines.** No conditionals, no
   loops ("for each child, do X"), no way to express "click every button
   matching NAME" without hand-writing N lines. `wait`/`until` gives one
   primitive condition-wait; nothing composes.
5. **No history / replay of a session** beyond the raw `aowlspt-inspect-out.txt`
   log — no named session, no "show me the last 5 batches," no diffing two
   states of the same object across time.
6. **No breakpoint/detour-on-call verb.** Everything is poll-based (`wait`,
   `until`, repeated `read`). There's no "stop when this method is entered"
   even though the host already does detours elsewhere in the codebase for
   other features — the inspector doesn't expose that capability to a user.
7. **Bytes-in/bytes-out is per-call capped (512B) with no streaming/paging
   verb** for a structure larger than that cap — workable but tedious for a
   power user staring at a big buffer.

## 3. Product shape — shipping as a standalone debugger mod

**What it is, framed for a buyer:** a live memory/UI debugger for the
aowlspt-hosted Tarkov client — read/write typed memory, walk the live scene
graph, find and press real UI controls, call managed methods by RVA, all
without a rebuild or restart. The pitch line CLAUDE.md itself makes ("~10
minutes for one bit of information" without it) is the value proposition.

**Packaging.** It already lives inside the host DLL
(`host/Aowlspt.Host.Il2Cpp/inspect.nim`) gated by two independent flags in
`aowlspt-host.json` (`liveInspector` for reads, `liveInspectorWrite` for
writes/calls — confirmed at `inspect.nim:218-235,1366-1373`). As a shippable
product it should be pulled into its own optional module/DLL that the base
distribution loads only if present, so the free tier of aowlspt never carries
inspector code at all, and it becomes an add-on purchase rather than a
flag flip on code everyone already has. This also shrinks the attack surface
for the base product — a debugger with write access to a live game process
is not something every user should be one config edit away from enabling.

**Enable/disable.** Keep the two-flag split (read vs write) — it is already
correct product design: a support/QA tier gets read-only inspection, a dev
tier gets writes. Add a license-gated third state so the write flag itself
requires the module to be present and licensed, not just a JSON boolean a
curious user could flip themselves.

**Safety story — this is the hard part of the pitch.** The inspector can
write live process memory and invoke arbitrary managed methods by RVA. The
existing safety net is substantial and should be foregrounded, not hidden:
per-call byte caps (512B), a per-batch fault budget that self-disables after
`InspMaxFaults`=8 faults, one SEH guard per command (never nested, so one bad
line cannot corrupt the batch or crash the host), `VirtualQuery` validation
before every memory hop, and multiple measured type-confusion guards (see
section 1) that refuse rather than silently misreport. This is a real,
non-trivial engineering story — "the debugger that refuses instead of
guessing" is a legitimate marketing claim, not spin, because the code backs
it (the STOPPED EARLY / EXHAUSTIVE distinction, the GameObject-vs-Transform
refusals, the stale-pointer fix). The gap: none of this is enforced against
*multiplayer* or *anti-cheat* exposure — this is explicitly a single-player
offline tool (SPT-shaped, per repo convention) and the doc/marketing must say
so loudly, since "writes live game memory" reads very differently to a buyer
who might try it against a live online session.

**What a paying user gets, concretely:** the debugger module, a documented
verb reference (this doc's section 1 is close to a first draft), the
find-by-name / find-by-component gap closed (see Gaps #1-2, worth shipping
before v1 rather than after), and ideally the structured-output mode (Gap #3)
so the product is scriptable, not just REPL-typeable.

## 4. Interface

Today: a file-based channel — write to `aowlspt-inspect.txt`, poll
`aowlspt-inspect-out.txt` and the host log, bump a serial comment line to
force a re-run. This is genuinely developer-grade: no discoverability, no
syntax help while typing, no way to tell "is my batch still running" without
re-reading a text file, and it depends on an external editor/tool loop
(exactly the loop this doc's own CLAUDE.md context praises the inspector for
*replacing* at the game-interaction layer — it would be strange to ship the
same UX at the tool's own interaction layer).

**Recommendation: an in-game console (a REPL rendered as an overlay in the
client itself), backed by the same command dispatcher, with the file channel
kept alive underneath as the scriptable/automatable backend.**

Why this over the alternatives:
- **HTTP/socket endpoint** — best for scripting and remote/automated use
  (CI-style toolcheck, agent-driven testing), but it is not what a paying
  end-user opens to debug their own game live. It's the right *addition*,
  not the right primary interface, and it's nearly free to add since the
  dispatcher already consumes a line of text and returns lines of text —
  wrapping it in a local TCP/named-pipe listener is a thin shim over the
  same `iCmdX` functions, no rewrite.
- **Standalone TUI (separate process)** — solves discoverability and
  responsiveness but still requires alt-tabbing out of the game, which is
  exactly the friction the file channel already has today (edit a file in
  another window, alt-tab back). Doesn't clear the bar of "meaningfully
  better," just "somewhat better."
- **In-game console (recommended)** — a buyer explicitly wants to see the
  game state while querying it: `find` a button, watch it highlight,
  `press` it, watch the screen react, all without leaving the game window.
  This is also the natural place to put live overlays (`rect` outlines drawn
  directly over the control, autocomplete over recently-seen `$rN`/`$comp`
  anchors, command history) that the file channel structurally cannot offer.
  It is more implementation work than the other two, but it is the one that
  actually earns "shipped as its own debugger-like mod" rather than "the
  same file-watch loop with a license key."

Staged: file channel stays as the automation/scripting surface for internal
tooling and toolcheck regardless of what ships to users — do not remove it.

## 5. Naming

Working recommendation from the brief is **Scry**. Candidates evaluated:

| Name | One-line read |
|---|---|
| **Scry** | Verb-first ("scrying" = seeing at a distance), reads naturally as a CLI verb (`scry find PostFX`), short, and distinct from generic debugger names on a marketplace listing. |
| Owlscope | On-theme and self-explanatory ("a scope for the owl project") but reads as a viewer/telescope, undersells the write/call capability that's actually the differentiator. |
| Talon | Strong owl-adjacent word (a raptor's grip), suggests "reach in and grab/hold" which fits the write/press verbs well, but has heavy prior use as a name (talon.dev, browser extensions) — collision risk on a store listing. |
| Perch | Cute thematically (owl's vantage point) but reads passive — a perch is where you sit and watch, not where you reach in and act. Undersells writes. |
| Nocturne | Evocative and on-theme (owls are nocturnal) but is a music term first in most people's ears; doesn't parse as a tool name without context. |
| Lumen | Off-theme (light, not owl), generic — already heavily used across dev tooling and SaaS products. Drop. |
| Roost | On-theme but same passivity problem as Perch — a roost is where the owl rests, not where it hunts. |
| Pellet | Owl-specific (what owls regurgitate — the undigested, revealing bits) — has a nice "here's the raw truth" resonance for a debugger, but the association is unavoidably a bit gross for a product name. |
| Mews | The historical term for a hawk/owl enclosure — obscure enough that almost no buyer will get the reference unprompted. Drop for discoverability. |

**Final recommendation: Scry.** It's the only candidate that is simultaneously
(a) on-theme without being literally "owl-something" — avoids brand
collision with `aowlspt` itself while still fitting the flock of names
around it, (b) a strong, natural verb, which matters because every single
command in this tool IS a verb (`find`, `click`, `read`, `press`) and the
product name should read the same way in a command, and (c) short enough
that `scry <verb>` doesn't feel like typing overhead in a REPL used
constantly. Talon is the strongest runner-up on theme-fit but loses on name
collision risk; Owlscope is the safest but undersells the write capability
that's the actual product differentiator. Do not rename anything in code for
this pass — this is a recommendation for the next naming decision, not an
instruction to execute it.

## 6. Staged plan — smallest valuable step first

1. **Close Gap #1 (find-by-displayed-text) and Gap #2 (find-by-component-type).**
   Smallest, highest-leverage change: both reuse the existing tree-walk in
   `iCmdFind`, just widen the match predicate. No new packaging, no interface
   work, ships value to today's internal users immediately.
2. **Add a structured-output mode** (Gap #3) behind a flag on the existing
   file-channel dispatcher — same commands, JSON-shaped answers. This is the
   enabling step for both the socket interface and any UI overlay later; do
   it before building either.
3. **Split the inspector into its own optional module** (Section 3 packaging)
   so the base aowlspt distribution stops carrying inspector code by default.
   Pure refactor, no new user-facing capability, but it's the prerequisite
   for selling it as a separate add-on and for tightening the base product's
   safety surface.
4. **Add the socket/HTTP shim** over the existing dispatcher — cheap, given
   step 2, and immediately useful for `toolcheck` and any future automated
   regression suite, independent of whether the in-game console ships yet.
5. **Build the in-game console** (Section 4 recommendation) as the shipped
   user-facing interface — the largest single piece of new work, deliberately
   last so it lands on top of an already-hardened, already-scriptable
   dispatcher rather than being built and hardened in parallel with it.
6. **Rename, license-gate, and package for sale** — after the product
   actually does what section 3's "what a paying user gets" promises, not
   before. Renaming first would mean shipping "Scry" as a worse tool than
   today's inspector under a nicer name.
