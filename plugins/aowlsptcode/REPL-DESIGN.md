# REPL improvement for the live inspector -- design (and what shipped)

## Decision: host-side interactive terminal, NOT the in-game console overlay

`docs/INSPECTOR-PRODUCT.md` (section 4) recommends an in-game console overlay
as the eventual shipped interface, staged behind a structured-output mode and
a socket shim. That overlay touches game-thread code (rendering the overlay,
reading input inside the Unity main thread loop) and is explicitly the
riskiest, highest-effort step in that doc's own staged plan (step 5 of 6,
deliberately last). This task's constraint is stricter than that doc's
staging: **no network I/O or blocking reads on the Unity main thread**, which
rules out the overlay outright for this pass regardless of effort budget.

The cheaper, safe alternative -- a host-MACHINE terminal REPL that still talks
through the existing file channel -- delivers most of the same ergonomic win
(no more four-manual-steps-per-question) with zero new game-thread code and
zero new risk to the live client. This is what deliverable (b) already
provides at the protocol level (one MCP call per verb, sentinel-guarded); an
`aowl inspect` interactive shell would be a thin readline/completion front
end over the SAME `channel.py` used by the MCP server -- not a second
implementation of the transport.

## Why not built this pass

Deliverable (b) took the full time budget: the typed MCP server, its parsers,
15 passing unit tests (synthetic fixtures, no live client), the recipe_run
integration verified read-only against the real `facts.db`, and the skill
doc. The task said implement (a) only after (b) is fully done and only if
safe -- (b) is done, but there was no time left to build and test a second
deliverable (the readline shell) to the same bar (tab completion over the
verb list, persistent `$r`/`$f`/`$comp` anchors across commands entered
interactively, etc.) without shortchanging it.

## What the host-side REPL should be, concretely (for the next pass)

- `aowl inspect` (a new `aowl` driver subcommand, or a standalone
  `tools/inspect_repl.py`) built on `plugins/aowlsptcode/mcp/channel.py`'s
  `run_batch`/parsers directly -- no MCP indirection needed for a terminal
  tool talking to itself.
- `readline`/`prompt_toolkit` history + tab-completion of the ~30 verb names
  from `docs/INSPECTOR-PRODUCT.md` section 1.
- Anchors ($r_, $f_, $comp, $_) persist across lines the user types
  interactively, matching the file channel's per-batch semantics: each
  Enter-press is one batch sent through the same sentinel-guarded
  `run_batch`, so staleness protection is inherited for free rather than
  reimplemented.
- Pretty-print using the SAME `parse_*` functions this plugin already ships,
  so a human at the terminal and an agent through MCP see structurally
  identical data, not two independently-parsed views of the same prose that
  can drift apart.
