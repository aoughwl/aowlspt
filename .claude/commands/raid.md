---
description: Drive the client from the main menu into an offline raid, fully automated
argument-hint: [map, default factory]
---

Get the client into an offline raid. Map: `$ARGUMENTS` (default `factory`).

**Recall first — do not re-derive this.** `recipe_get("enter-offline-raid")` holds
the exact sequence, and it is fully automated including the practice-mode
checkbox. Re-deriving it by hand-walking the UI tree has cost multiple sessions
and, once, five of the eight session faults.

Load `.claude/skills/aowl-inspector/SKILL.md` before touching the UI.

The shape of it:

1. `python tools/entergame.py` — past the PvE Zone / PvE / PvP Season selector.
   It selects by **displayed title**, never object name, because the names lie.
2. Click through by displayed text via `tools/ui.py`'s `click_text(TEXT, root=…)`.
   **Pass `root=` explicitly** — the CLI hardcodes `Common UI` and the matchmaker
   screens live under `Menu UI`.
3. The practice-mode checkbox is `EFT.UI.UpdatableToggle`, driven by
   `Toggle::set_isOn` @ `0x55ba430`. Find it with `components`, never by guessing
   types.

**Verify arrival properly.** The `Menu UI` scene root **disappearing** is the
signal. Do **not** use the `RegisterPlayer` count — it fires when the *server*
starts, well before the player is in (measured: 5 events at server start, 22 once
actually in). Do not use the inspector's in-raid anchor either; it reads `-1`
mid-raid.

Loading is slow. Drive off observed state, never a fixed sleep.

If a step fails, report **what was searched and whether the walk was COMPLETE** —
0 hits on a complete walk under the wrong root means wrong tree, not missing
control.
