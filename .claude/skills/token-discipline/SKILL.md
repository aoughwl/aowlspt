---
name: token-discipline
description: Load before reading any log, wire capture, database or data blob in this repo; before grepping anything under mods/tarkov/data or D:\Aowlspt; before briefing a subagent; and before writing a subagent report. Names the measured-huge files, the safe accessor for each, and the required report shape. Load it when a read is about to be large, when context is filling, or when delegating.
---

# Token discipline

Context is the scarce resource on this project, and it is not spent evenly. It
is spent in five places, all measured. Each has one correct move.

## 1. The measured-huge files — never read raw

| file | bytes | lines | longest line |
|---|---:|---:|---:|
| `D:\Aowlspt\aowlspt\db.json` | 41,313,127 | **1** | 41,234,032 |
| `mods/tarkov/data/capture/raid1/responses/large/045.json` | 18,297,513 | **1** | 18,297,513 |
| `mods/tarkov/data/capture/raid1/responses/large/076.json` | 13,252,394 | **1** | 13,252,394 |
| `D:\Aowlspt\aowlspt\nettrace.log` | 3,101,235 | 42,107 | 270 |
| `mods/tarkov/data/post1/locale_en.json` | 2,766,414 | **1** | 2,766,414 |
| `mods/tarkov/data/post1/locations.json` | 1,907,774 | **1** | 1,907,774 |
| `mods/tarkov/data/capture/` (whole tree) | 50,969,045 | 705 files | — |
| `D:\Aowlspt\aowlspt\aowlspt-backend.log` | 26,086 | 264 | **6,082** |
| `D:\Aowlspt\aowlspt\aowlspt-host.log` | 14,085 | 91 | 779 |

**A one-line file has no safe partial read.** `head -1`, `Get-Content -TotalCount 1`,
`Read` with `limit: 1`, and any matching `grep` all return the entire file. At
~3.5 chars/token, `cat db.json` is ~11.8M tokens — larger than the whole context
window. This is not a style preference; it is the difference between a session
that works and one that dies.

The `no-context-bombs` PreToolUse hook blocks these. The hook is the floor, not
the ceiling — it cannot know that a 200 KB read was also pointless.

## 2. Use the accessor, not the file

```
python tools/hostlog.py summary|boot|faults|feature <n>|config|grep <re>|tail
python tools/wirelog.py summary|routes|route <r>|body <r> --path a.b|errors|grep <re>|nettrace
python tools/bigjson.py size|keys|get --path a.b.c|find --key K|search --value V  <file>
python tools/bsgwire.py  scan|decode|extract        # capture bodies
python tools/hostcfg.py  show|keys|set              # host flags
python tools/harness.py  run --until "<literal>"    # a run, IDLE != TIMEOUT
```

Every one of these truncates by default and says how much it withheld.
`wirelog.py routes` answers "what did the client ask for and how big was it" in
~10 lines where the raw log is 26 KB. `bigjson.py keys` gives the shape of a
41 MB document in 20 lines.

**`--full N` and `--max-lines N` exist and are legitimate** — but raising a cap
is a deliberate act taken *after* the summary told you which one thing you need,
never as the first move. Ask for the narrowest thing that answers the question:
`bigjson.py get --path` beats `keys` beats `get` on the parent.

## 3. Do not re-read

Files you have already read this session are still in context. Re-reading them
pays twice for the same tokens. If you only need to confirm an edit landed:
`Edit`/`Write` error out when they fail, so a successful call *is* the
confirmation. Prefer `git diff --stat` over re-reading changed files.

Read large source files with `offset`/`limit` around the symbol you found with
`Grep`, not from line 1.

## 4. Do not paste briefings an agent definition already carries

`.claude/agents/host-il2cpp.md` already contains the IL2CPP standing facts, the
calling convention, the reflection-is-dead list, the known RVAs, the eight
live-path rules and the build/deploy/debug rules. Delegating with
`subagent_type: host-il2cpp` loads all of it. **Pasting those facts into the
prompt as well pays for them twice** — once in the agent's system prompt and
once in your own transcript.

A good delegation prompt is the *task and its acceptance test*, and nothing that
is already in the agent definition or a skill:

> Add a settings page for the sway mod. Verify the marker survives deploy.
> Report per the required shape.

If a recurring role has no agent definition yet, write one rather than pasting
the same briefing a third time.

## 5. The required subagent report shape

Reports get relayed, so a long report is paid for twice. Answer in **under 200
words**, in this order, omitting any line that has no content:

```
DID:        what changed, one line per file (path only, no code)
ARTIFACT:   built/deployed path + size, or "none"
VERIFY:     the exact command or click that demonstrates it
UNVERIFIED: what you did NOT test, and why
BLOCKED:    what stopped you, if anything
```

Rules: **never restate the brief.** Never paste code you wrote — the caller can
read the file. Never paste tool output; give the one number or line that carries
the conclusion, and name the instrument that produced it. Separate observations
from conclusions. If you must include a log excerpt, one line.

## 6. Never read a subagent transcript

The `.output` files under the tasks directory are the agent's full JSONL tool
traffic — tens of thousands of tokens whose conclusion you already receive in
the completion notification. The hook blocks these. Wait for the notification.

## 7. Ambient caps

`.claude/settings.json` sets `BASH_MAX_OUTPUT_LENGTH=20000` (down from the
30,000 default) and `MAX_MCP_OUTPUT_TOKENS=8000` (down from 25,000). These are
backstops against a surprise, not a budget to spend; a command whose output is
being truncated at 20,000 characters was the wrong command.

There is no setting that caps the `Read` tool or `Grep` output. That gap is
exactly what the hook and the accessors cover.

## When you are about to do a big read anyway

Say so, and say why, in one line: what question it answers and what cheaper
thing you already tried. If you cannot name the question, do not do the read.
