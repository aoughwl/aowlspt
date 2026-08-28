---
description: Show or safely change a host feature flag via tools/hostcfg.py (key names checked)
argument-hint: [key] [on|off|value]   (no args = show all)
---

Read or set a host flag. Arguments: `$ARGUMENTS` — `$1` is the key, `$2` the value.
With no arguments, just show the current config.

**Use `python tools/hostcfg.py`.** Do not hand-edit the JSON. The tool refuses
unknown keys and suggests near-misses (`debugUI` → `debugUi`), and its 23 valid
keys are scraped from the live `readBoolKey` call sites so they cannot drift out
of date. A key the host does not read is silently ignored and looks exactly like
a broken feature — that is the failure this prevents.

```powershell
python tools\hostcfg.py show                       # every known key, value, source
python tools\hostcfg.py keys                       # what the host can actually read
python tools\hostcfg.py get debugUi
python tools\hostcfg.py set debugUi on
python tools\hostcfg.py set debugUi off botDiag on # several at once
python tools\hostcfg.py set waitForRuntimeMs 240000
python tools\hostcfg.py diff                       # non-default values only
```

`--dry-run` is available. The target is the live `aowlspt-host.json`; `--root`
overrides the install.

Procedure:

1. **Show first, always** — `python tools\hostcfg.py show`.
2. If no key was given, stop here and report the current values.
3. If a key was given, `set` it. If the tool rejects the key, do **not** work
   around it — report its suggestion and ask me.
4. Re-read with `diff` and show what changed.

If `tools/hostcfg.py` is not on this branch, fall back to reading the config JSON
in the install directly, verify the key already exists before writing, back it up
with a timestamp, and say you used the fallback.

**Do not** change flags as a way of "trying things" during a debugging session
without saying so — a flag left on is indistinguishable from a code change later.
New features are flag-gated and default OFF by project rule (`il2cpp-host` skill);
turning one on for a test means turning it back off afterwards.

The host config is not in `ConsistencyInfo`, so its size may change freely. Files
that *are* listed there must not change size — see the `aowlspt-deploy` skill.
