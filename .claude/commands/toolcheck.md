---
description: Replay recorded inspector cases against the live client to catch the tool lying
argument-hint: [run|record|list|show|preflight] [--at menu|raid]
---

Run the inspector regression harness: `python tools/toolcheck.py $ARGUMENTS`.

**Run this after every host build.** The inspector has repeatedly produced
*confidently wrong answers* — a stale `$comp` printing a fictional field map,
`click` invoking on a GameObject, `label` reporting `text = ""`, `open` rejecting
a correct target, `state` claiming not-in-raid while a human was in one. Every
one was found by accident. This finds them on purpose.

Typical use:

```
python tools/toolcheck.py preflight        # sends NOTHING to the client
python tools/harness.py run --until "host running" --keep
python tools/toolcheck.py record --at menu # first time only, on a run you vouch for
python tools/toolcheck.py run --at menu    # after every host build
```

Exit codes: `0` pass, `1` regression, `2` no answer / inspector dead, `3` scope
changed (verdicts withheld), `4` nothing ran.

How to read it honestly:

- **DRIFT is not a failure.** An answer may legitimately have changed. Promoting
  drift to a verdict would manufacture the exact wrongness this tool opposes.
- **Exit 3 means the game changed**, not that the tool regressed — the scope key
  (image key + file hash of `GameAssembly.dll`, plus `db.json`) differs. Blaming
  the tool for a Tarkov update is also a wrong answer.
- **A skip is not a pass**, and the harness says so. If no baseline exists it
  prints that drift was **not checked for any case** — do not read that as green.
- **A `refuse` case asserts a REFUSAL.** Half the historical bugs were the tool
  *answering* where it should have declined; `GetComponent returned NULL — this
  is an ANSWER, not a crash` and `searched EXHAUSTIVELY` vs `STOPPED EARLY` are
  correct behaviours worth locking in.

Preflight reads the inspector's fault budget and **refuses at 8 of 8**, because
past that the inspector is off and every case would "pass" by matching silence.

**Note:** as of writing, no case has ever run and there is no baseline. Expect the
first `run --at menu` to need regex tuning — it will fail loudly rather than pass
vacuously, which is the intended first use.
