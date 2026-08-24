---
name: aowlsptcode:inspect
description: Use the aowlinspect MCP tools (inspect_state, inspect_roots, inspect_find, inspect_findtext, inspect_children, inspect_tree, inspect_parent, inspect_read, inspect_component, inspect_label, inspect_call, inspect_press) instead of hand-driving the live inspector's file channel. Load before writing to aowlspt-inspect.txt by hand, before polling aowlspt-inspect-out.txt, or before parsing inspector prose output yourself.
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
