---
name: aowlsptcode:inspect
description: Use the aowlinspect MCP tools (inspect_state, inspect_roots, inspect_find, inspect_findtext, inspect_children, inspect_tree, inspect_parent, inspect_read, inspect_component, inspect_label, inspect_call, inspect_press, inspect_screenshot, inspect_path, inspect_open_settings, inspect_batch, inspect_assert) instead of hand-driving the live inspector's file channel. Load before writing to aowlspt-inspect.txt by hand, before polling aowlspt-inspect-out.txt, before parsing inspector prose output yourself, or before taking a screenshot.
---

# Prefer the typed tools over the raw file channel

The live inspector (CLAUDE.md section 2) is a file-based command channel:
write to `aowlspt-inspect.txt`, poll `aowlspt-inspect-out.txt` for a matching
sentinel, then parse prose text. That is a 3-step, race-prone, hand-scraped
workflow. The `aowlinspect` MCP server (this plugin) collapses it to one typed
call per verb.

**Prefer `mcp__aowlsptcode_aowlinspect__inspect_*` tools over hand-writing to
the file channel or shelling out to `tools/inspector.py` directly**, unless a
verb genuinely has no typed tool yet (this plugin covers the common subset —
`state`, `roots`, `find`, `findtext`, `children`, `tree`, `parent`, `read`,
`component`, `label`, `call`, `press` — not the full ~30-verb surface in
`docs/INSPECTOR-PRODUCT.md`; fall back to `tools/inspector.py` for anything
else, e.g. `scan`, `dump`, `open`, `tab`).

## Why this matters (the property, not just convenience)

Every call gets its own unique sentinel, and the result is only accepted if
the out-file body contains THAT sentinel — a stale previous answer, a
partial write, or another batch's response is never returned as if it were
this call's answer. A timed-out call comes back as a typed `{"error":
{"kind":"timeout", ...}}`, not a plausible-looking empty result.

## What "structured" means here

- `inspect_find` / `inspect_findtext` return `hits` as objects
  (`ptr`/`name`/`parent`/`var`), plus an explicit `completeness` field
  (`EXHAUSTIVE` / `STOPPED_EARLY` / `HIT_CAP` / `NOTHING_EXAMINED`) and a
  `can_trust_absence` boolean. **An empty `hits` list is NOT evidence a name
  is absent unless `can_trust_absence` is true.** This mirrors CLAUDE.md's
  EXHAUSTIVE-vs-STOPPED-EARLY warning, but as a field you can branch on
  instead of a sentence you have to remember to reread.
- `inspect_findtext` additionally reports `scope` (`ACTIVE_ONLY` /
  `ALL_ACTIVE_AND_INACTIVE`) and `inactive_skipped` — the actual scope used,
  echoed back, not just the flag you passed in.
- Every result includes `parse_ok`: false means the parser could not
  confidently extract structured fields from this particular prose (some
  verbs' exact wording were not independently re-verified against a live
  client for this plugin — see the plugin's own report). When `parse_ok` is
  false, the raw text is still available under `raw` — use it, but do not
  trust invented structure around it.
- Write-gated verbs (`inspect_call`, `inspect_press`) always send `allow
  write` for you and still require `liveInspectorWrite` on the host; a
  refusal comes back as `ok:false`, not a silent no-op.

## Do not

- Do not hand-parse `aowlspt-inspect-out.txt` when a typed tool covers the
  verb you need — that reintroduces the exact staleness risk this plugin
  exists to remove.
- Do not call `inspect_call` / `inspect_press` against a live client someone
  else may be using — same rule as the raw channel, unchanged by having a
  typed wrapper.

## Compound tools — a whole verification in one round trip

Each of these replaces a hand-chained sequence of 4-8 raw-verb calls that a
prior session was doing by hand:

- **`inspect_path(path)`** — resolve a slash path (`"Preloader UI/BottomPanel/
  .../SettingsButton"`) from the scene roots to a pointer chain in one call.
  Segments are auto-quoted before being sent (`find` tokenizes on
  whitespace, so an unquoted multi-word segment like `Preloader UI` fails
  live with `! not an address: UI` — measured). Fails fast at the first
  missing segment and reports whether that miss is `EXHAUSTIVE` (trustworthy
  "not there") or `STOPPED_EARLY`/`HIT_CAP` (inconclusive).
- **`inspect_open_settings()`** — the whole fact #109 recipe (walk to the
  Settings tab's last child, `component ... AnimatedToggle`,
  `call rva:0x55ba430 v_pb $comp 1`, confirm via `state`) in one call.
  Returns PASS/FAIL/INCONCLUSIVE with the evidence at whichever step it
  stopped. Verified live end-to-end in this task.
- **`inspect_batch(commands)`** — send several raw verbs in ONE channel
  round trip. The channel already supported multi-line batches; only the
  per-tool handlers never used it. Read the `note` field in the result: the
  combined raw text has no delimiter between commands, so per-command
  parsing is unreliable when the batch mixes two calls to the SAME verb.
  Prefer this for independent single-purpose verbs.
- **`inspect_assert(name)`** — run ONE named assertion from
  `tools/acceptance.py` (`tab_count`, `no_donor_caption`,
  `no_placeholder_text`, `spawner_one_active_toggle`, `postfx_group`,
  `one_panel_active_per_group`, `no_faults`, `settings_json`) against an
  ALREADY-RUNNING client with Settings ALREADY OPEN. It does **not** launch
  the client or drive the mode selector — per CLAUDE.md, a subagent must
  never start/stop the game, and this MCP server may run inside one. Call
  `inspect_open_settings` first.

## `inspect_screenshot` — the expensive one

Captures the EscapeFromTarkov window BY HWND via `PrintWindow(...,
PW_RENDERFULLCONTENT)`, which works even when the window is not focused or
foreground; a plain `BitBlt` reliably comes back black for this kind of
DX/Unity swapchain, so that path is only a fallback, and the result says
which path (`method`) actually produced the image. If BOTH paths produce a
near-uniform (near-black) image, the tool returns `ok:false` — it never
hands back a black PNG as if it were a real capture.

**This is the most expensive action in the toolbox.** CLAUDE.md section 2 is
explicit: a screenshot is for genuinely VISUAL questions only — layout,
overlap, "does this look right", "where is this control on screen". Every
other question (does a control exist, what does it say, what state is it
in) goes through `inspect_find` / `inspect_findtext` / `inspect_label` /
`inspect_state` instead. It returns a PNG **path** plus width/height/
mean_luminance, never inline image bytes — read the file only if you
actually need to look at it.
