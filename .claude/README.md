# `.claude/` — this project's workflow, encoded

Everything here exists so a fresh session (or a fresh subagent) does the right
thing without being briefed. Each rule below is here because breaking it cost
hours *and produced a misleading symptom*. Nothing is here because it seemed like
a good idea.

This is a plain local `.claude/` directory, not a packaged plugin. A
`.claude-plugin/plugin.json` is only needed to distribute via a marketplace;
skills, commands, agents and hooks all load from here as-is. If this ever needs
to be shared with another checkout, wrap it then.

## What is here

### Skills — `skills/<name>/SKILL.md`

Loaded automatically when the `description` matches what is being attempted, or
on request. They are the durable knowledge; the commands are thin drivers over
them.

| skill | load it before |
|---|---|
| `aowlspt-build` | compiling anything: the host, `tarkov.dll`, a mod, or `aowl.exe` itself |
| `aowlspt-deploy` | copying any artifact into `D:\Aowlspt` |
| `il2cpp-host` | writing or reviewing code that runs inside the live client |
| `empirical-debugging` | diagnosing anything about the running game |
| `token-discipline` | reading any log/capture/data blob, briefing a subagent, or writing a report |

The four rules they exist to stop us re-learning:

1. **PowerShell only, and name the build target.** gcc under Git Bash exits 1
   with no output; raw `nimony` exits 0 and writes nothing. `aowl build host` is
   **48s**, bare `aowl build` is **18m 25s** for ~25 programs. `aowl build` does
   **not** rebuild `aowl.exe` — `aowl bootstrap` does, and a fresh worktree has no
   `aowl.exe` at all. **Parallel builds in separate worktrees are measured safe**;
   only two builds in one checkout are a hazard.
2. **Never deploy without marker verification.** Rebuilds from a wrong base have
   silently dropped shipped features repeatedly.
3. **Empirical debugging, not source reasoning.** Six source-reasoning attempts
   at one bug failed; the first two empirical ones solved it in an hour.
4. **The false crash.** The game needs 60s+ to reach profile-select and then
   waits forever for a human. An idle game is indistinguishable from a hung one.

### The `tools/` CLIs the commands wrap

Python by design, so they change without a 30s rebuild. Commands wrap them rather
than duplicating logic, and each falls back with a note if the tool is absent from
the current branch.

| tool | does |
|---|---|
| `python tools/deploy.py check\|deploy\|rollback` | marker verification (data in `tools/deploy.json`), backup, rollback line |
| `python tools/harness.py run --until "<literal>"` | launch and capture with no human; distinguishes `IDLE` from `TIMEOUT` |
| `python tools/hostlog.py summary\|boot\|faults\|feature\|config\|tail` | reads the host log (always exactly one run); separates self-disabled features from warnings |
| `python tools/hostcfg.py show\|keys\|set` | flags, with key names checked against what the host actually reads |
| `python tools/wirelog.py summary\|routes\|route\|body\|errors\|grep\|nettrace` | the wire logs, route-census first, bodies truncated unless `--full N` |
| `python tools/bigjson.py size\|keys\|get\|find\|search` | the huge single-line JSON, by path -- never prints the file |
| `python tools/hooktest.py` | asserts what the context-bomb hook blocks and (more importantly) does not |

`DEVLOOP.md` in the repo root documents the fast path per task.

### Commands — `commands/*.md`

| command | does |
|---|---|
| `/build [target]` | driver check, then a **named-target** build in PowerShell |
| `/deploy [host\|tarkov\|all] [--check]` | wraps `tools/deploy.py` — markers, backup, rollback |
| `/launch [sentinel]` | wraps `tools/harness.py` — captures a run, `IDLE` ≠ `TIMEOUT` |
| `/lastrun [term]` | wraps `tools/hostlog.py`, plus the client's own log |
| `/hostflag [key] [value]` | wraps `tools/hostcfg.py` — key names checked |

Every command **wraps** its `tools/` CLI rather than reimplementing the logic, and
falls back with an explicit note if the tool is missing on the current branch. When
a tool's interface changes, only the invocation block in the command needs editing.

### Agents — `agents/*.md`

| agent | owns | pre-loaded with |
|---|---|---|
| `host-il2cpp` | `host/`, `abi/`, anything inside the live client | safety discipline, calling convention, reflection-is-dead, known RVAs |
| `server-backend` | `backend/`, `mods/`, the wire, the data blobs | wire format, port/db/selection facts, the data-file size table |

Both carry the context discipline and the required report shape. **Delegating to
one replaces pasting a 60-line briefing** — and pasting those facts into the
prompt as well pays for them twice, once in the agent's system prompt and once
in your own transcript. A recurring role with no agent definition should get
one rather than a third copy of the same briefing.

Invoke via the Agent tool with `subagent_type: host-il2cpp` / `server-backend`.

### Hooks — `settings.json` + `hooks/*.py`

Two hooks, on purpose. Both guard a failure that is **silent, narrow, and
checkable without judgement**; everything requiring judgement stayed a skill.

**`no-context-bombs.py`** (matcher `Bash|PowerShell|Read`) refuses reads that
would dump six figures of characters into context. `db.json` is 41,313,127 bytes
on **one line**; `045.json` is 18,297,513 on one line; `nettrace.log` is 3.1 MB.
A one-line file has no safe partial read -- `head -1`, `Read` with `limit: 1` and
any matching `grep` all return the whole file, and `cat db.json` alone is ~11.8M
tokens. Every block message names the accessor to run instead.

It deliberately does **not** block writing, copying, deleting or sizing those
files (`ls`/`stat`/`wc`/`Get-Item`), capped greps (`-o`, `-c`, `-l`,
`--max-columns`), bounded reads of the 14 KB `aowlspt-host.log`, or any command
that invokes one of the `tools/` accessors. `python tools/hooktest.py` asserts
all of that: **37 cases, 14 block / 23 allow**, and the allow half is the
important one.

**`no-compile-in-gitbash.py`** blocks compiler invocations issued through the
**Bash** tool, because that failure is silent in both directions (gcc: exit 1, no output;
nimony: exit 0, no artifact) and the condition is narrow enough to check exactly.
Reading, grepping and echoing those words are not blocked; the PowerShell tool is
untouched.

Everything else stayed a skill. A hook that fires wrongly is worse than no hook,
and the remaining rules are judgement calls that a regex cannot make.

`settings.json` also sets `BASH_MAX_OUTPUT_LENGTH=20000` (default 30,000) and
`MAX_MCP_OUTPUT_TOKENS=8000` (default 25,000) in its `env` block. Those are the
only ambient output caps Claude Code offers -- there is **no** setting that caps
the `Read` or `Grep` tools, which is precisely the gap the hook covers.

> **This whole directory only loads when Claude Code is started from inside
> `Projectsowlspt`.** Started from the parent `Projects\` (as one session was),
> the project root is the parent, `CLAUDE_PROJECT_DIR` is empty, and **none** of
> these hooks, skills, commands or agents are active -- verified live: `gcc
> --version` ran unblocked. Hook edits also need a session restart to take
> effect, since hook config is snapshotted at session start.

## Extending this

- **New durable knowledge** → a skill. Write the `description` as *when to load
  it*, since that is what the match is made against. Keep the body under ~500
  lines; put bulk in supporting files beside `SKILL.md`.
- **New operation** → a command in `commands/`, thin, delegating to a skill and
  wrapping a `tools/` CLI rather than embedding logic.
- **New hook** → only for a condition that is silent, narrow, and checkable
  without judgement. If you have to guess at intent, it belongs in a skill.
- Do not duplicate the offset tables here. `docs/SETTINGS.md` has the settings-path
  VAs, `docs/IL2CPP.md` the ABI, `docs/DEBUGGING.md` the failure tables. Copies rot.

## Not covered here, deliberately

- **No build hook that runs the build for you.** Which target to build is a
  judgement about what changed, and getting it wrong is the difference between
  48 seconds and 18 minutes. That is not a decision a hook can make.
- **No serialisation of parallel agents.** Measured: separate worktrees build
  concurrently and safely. Gating on `Get-Process` cost a whole session of
  needless serialisation and is deliberately not encoded anywhere here.
- **No deploy hook.** Deploying must remain a decision, and the verification it
  requires is exactly the sort of judgement a hook cannot make.
- **No SessionStart context injection.** The skills' descriptions already route
  the right knowledge to the right moment; loading all of it every session spends
  context on whichever three-quarters are irrelevant.
