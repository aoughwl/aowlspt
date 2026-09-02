---
name: aowl-inspector
description: How to ask the running Tarkov client a question through the live inspector, and how to avoid the answers it gives that are confidently wrong. Load before driving the game UI, before pressing any control, before enumerating components, or when an inspector answer looks surprising. Covers the session fault budget, COMPLETE-vs-TRUNCATED, the active-check before pressing, expression syntax, and the verbs that replaced guessing.
---

# The live inspector

The inspector queries the running client in **seconds**, with no rebuild and no
restart. Before it existed, one bit of information cost a build → deploy →
launch → human-looks-at-screen cycle of roughly ten minutes.

Write commands to `D:\Aowlspt\aowlspt\aowlspt-inspect.txt`; answers land in
`aowlspt-inspect-out.txt` and in the host log. The trigger is a **content
change**, so bump a serial line (`#12`) to re-run an identical batch. Write it
**without a BOM** — PowerShell 5.1's `Set-Content -Encoding utf8` emits one;
`printf` from Bash is the safe habit. Easier still: use `tools/inspector.py`,
which handles the serial, the retries and the sentinel for you, and exposes
`run_batch` as a library function.

## The four things that will cost you the most

### 1. The fault budget is 8, for the whole session

```
!! FAULTED (caught; the game survived). LAST HOP: Component::GetComponent(String)
!! fault 5 of 8 before the inspector switches itself off for this session
```

At 8 the inspector **disables itself until the client restarts**. The budget is
shared with every other guarded operation and with every other agent driving the
same client.

So **never probe by trial.** Discovering a component type by trying candidates
one after another is bounded at 8 mistakes, and it has ended a session's UI work.
Use `components` (below).

### 2. A caught fault unwinds the ENTIRE guarded body

Statements after the faulting call never run, **silently**. A batch that faults
early therefore returns a **truncated** result that reads exactly like a clean
negative — "this screen has no such control" when the truth is "the walk stopped".
This is the most expensive failure shape in this project.

Set status *before* each read, never after. Never put "did it work" bookkeeping
after a call that can fault.

### 3. COMPLETE vs TRUNCATED — absence proves nothing from a partial walk

`find` says `searched EXHAUSTIVELY` vs `STOPPED EARLY on the NODE BUDGET`, and
**STOPPED EARLY is not proof a name is absent.** In a raid there are ~177 scene
roots and the default budget will not cover them; narrow the root or raise the
budget. `tools/ui.py` carries the same flag through as
`TRUNCATED (absence proves nothing)`. Propagate it — never report absence from an
incomplete walk.

### 4. Check `activeInHierarchy` BEFORE pressing

An inactive control accepts the call, does not fault, and the game ignores it —
so it **reports success and does nothing**. Measured: the main menu's
`DisconnectButton` persists into a raid while inactive; pressing it "succeeded"
twice with the client still in the raid; the same button with the ESC menu open
worked. Finding a correctly-named, correctly-typed control is **not** evidence it
is the one on screen.

`tools/ui.py`'s `actuate()` now refuses an inactive target by name. Keep it that
way.

## Reaching things

`roots` is how you reach anything. The live UI is **not** in any scene
`SceneManager` lists — it lives in `DontDestroyOnLoad`, which `sceneCount`
excludes by design, so those scenes truthfully report `rootCount=0`. `roots`
enumerates the scene `$preloader` really belongs to.

`$rN` binds a **Transform**; `$rgoN` is the GameObject, which is what `component`
wants. Feeding a GameObject to a Transform walker is refused — it used to invent
a plausible hierarchy of wrong children without faulting.

Where things actually live, measured:

| what | where |
|---|---|
| main menu screen | `Common UI` → `MenuScreen` (**not** Menu UI) |
| matchmaker screens | `Menu UI` → `UI` → ~28 screens |
| settings taskbar buttons | `Preloader UI` |
| `SettingsScreen` | `Common UI` |
| post-raid results | `Session End UI` — a root that exists **only** after leaving a raid |

`Menu UI` **does not exist during a raid**. Its absence is the most reliable
in-raid signal — better than the inspector's own in-raid anchor, which reads
`-1` mid-raid, and better than the `RegisterPlayer` count, which fires when the
**server** starts, well before the player is in.

## Identity: names lie, so ask what it displays

`find NAME` searches **object names only**, and object names lie:
`CharacterSlotView_pvp` displays **"PvE"**. Use `find` for structure. For
identity use `tools/ui.py find_text`, which searches the text a control
**displays**.

`components EXPR [BaseType]` enumerates every component with its resolved type
name and binds `$k0..$kN`:

```
components 0x...aefe0
  6 component(s)
    [3] EFT.UI.UiElementBlocker    ($k3)
    [4] EFT.UI.UpdatableToggle     ($k4)
```

That call replaced an unbounded guessing game. Names are **fully qualified** —
it resolves through the offline index, not Unity's short-name match. A name it
cannot verify prints `UNVERIFIED` rather than a plausible guess.

`component EXPR Type` (singular) still exists and still costs faults on some
objects. Prefer `components`.

## Pressing things

- `EFT.UI.DefaultUIButton` is **not** a `UnityEngine.UI.Button`. The inspector's
  `click` imposes Button layout on whatever it is handed. Press a
  `DefaultUIButton` as itself.
- `ButtonFeedback::OnPointerClick` plays the click sound and **presses nothing**.
- Taskbar entries are `AnimatedToggle`; `press` / `DefaultUIButton.OnClick` does
  nothing on them. Drive toggles with `Toggle::set_isOn` @ `0x55ba430`, which
  **fires listeners**. `SetIsOnWithoutNotify` @ `0x55ba440` does not, and would
  change the control without telling the game.
- Writes and calls need the `liveInspectorWrite` flag **and** an `allow write`
  line in the batch, which arms for that batch only.

Proving an effect: `press` returning ok means only *the handler did not fault*.
Look for the target's GameObject pointer changing, a screen change, or a field
read. Otherwise say **UNVERIFIED**.

## Expression syntax

`EXPR = $anchor | 0xhex ( +0xNN | @0xNN )*` — `+` moves, `@` **dereferences**.

The offset form takes **no space**: `read $k4+0x120 bool`. Writing
`read $k4 +0x120 bool` parses `+0x120` as the *type* and errors; `$k4@0x120`
dereferences and reads somewhere else entirely.

## Channel hygiene

The channel **drops batches** — `tools/inspector.py` retries and says so. It is
**single-writer**: if a human or another agent is driving the same client, your
batch can interleave. If an answer does not match what you sent, suspect that
first and report it rather than blaming the client.

## The tool has lied before — say so when it does

Every one of these was found by *using* it and reporting: a failed `component`
leaving `$comp` holding the previous batch's pointer, so `click` pressed the
wrong object and printed a complete, entirely fictional field map; `click`
calling `UnityEvent::Invoke` on a GameObject and escaping the guard; `label` on a
Transform reporting `text = ""`, which reads as "empty" and is not an answer;
`open` rejecting a correct target because the prologue snapshot had recorded our
own trampoline; `state` reporting `in-raid anchor slot=-1` while a human was in a
raid.

**A tool that gives a confidently wrong answer is a P0.** Report it in the same
message, with the batch you ran and what came back. `tools/toolcheck.py` exists to
catch these deliberately — run it after a host build.

## Never take a screenshot to find something out

It is the most token-expensive action available and the inspector exists to
replace it. Reserve capture for questions that are genuinely visual and that no
field read can answer — and say why.
