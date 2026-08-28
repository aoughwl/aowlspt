---
description: Launch the client and capture its log without a human, via tools/harness.py
argument-hint: [literal to wait for, e.g. "host running"]
---

Launch the live client and capture what it does. Follow the `empirical-debugging`
skill — especially the false-crash section.

**Use `python tools/harness.py`.** It launches, waits, captures and shuts down
with no human in the loop, and — the important part — it **distinguishes `IDLE`
from `TIMEOUT`**. It tracks the sentinel, log progress and a stall clock rather
than a bare timer, which is exactly the false-crash problem: the game needs 60s+
to reach profile-select and then waits forever for a person, so a bare timeout
reports a crash that never happened.

```powershell
python tools\harness.py run --until "$ARGUMENTS"
python tools\harness.py run --until "host running" --timeout 300 --stall 45
python tools\harness.py run --profile <name>     # play a profile, don't stop at the picker
python tools\harness.py run --keep               # leave client and backend up
python tools\harness.py watch                    # watch an already-running client
```

Also: `--root` (default `D:\Aowlspt`), `--args` for extra client arguments,
`--out` for where logs are copied, `-q` to not echo while waiting.

If `$ARGUMENTS` is empty, pick a sentinel that actually answers the question
being asked — the host log line the feature under test emits — rather than a
generic one.

**Read the outcome literally:**

- `IDLE` — the client is alive and waiting for a human. That is not a failure.
  Say so and ask me to drive it, or re-run with `--profile`.
- `TIMEOUT` — the log genuinely stopped progressing. Now investigate.
- Sentinel reached — report the line and the surrounding context.

Never report "it crashed" from a process check. Report what you observed: how
long since the last host-log line, and what that line said.

Then summarise with `/lastrun`, or directly:

```powershell
python tools\hostlog.py summary
```

If `tools/harness.py` is not on this branch, fall back to
`& .\installer\build\aowlspt-launch.exe --root D:\Aowlspt`, then wait **at least
90 seconds**, compare the tail of `D:\Aowlspt\aowlspt\aowlspt-host.log` twice a
good interval apart, and only call it a crash once it has genuinely stopped
progressing. Say you used the fallback.

Note: the launcher's stale-backend reclaim and `--no-reclaim` flag live on branch
`fix-launcher-stale-backend` (which is what is currently deployed). Do not assume
they exist on whatever branch you are on.
