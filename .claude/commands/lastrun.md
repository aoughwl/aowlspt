---
description: What happened in the last run — via tools/hostlog.py, plus the client's own log
argument-hint: [feature or grep term, e.g. settingsBindProbe or bot]
---

Summarise the most recent run. Filter term: `$ARGUMENTS` (optional).

**Use `python tools/hostlog.py`.** The host **truncates its log at every start**,
so `aowlspt-host.log` is always exactly one run — no date filtering needed, and
no risk of reading yesterday's run as today's. The tool encodes the four
questions we always ask instead of ad-hoc greps guessed in advance:

```powershell
python tools\hostlog.py summary            # did it boot? what broke?
python tools\hostlog.py boot               # the load sequence
python tools\hostlog.py faults             # everything that went wrong
python tools\hostlog.py feature $ARGUMENTS # one subsystem, whole run
python tools\hostlog.py config             # what config the host actually read
python tools\hostlog.py grep <pattern>
python tools\hostlog.py tail
python tools\hostlog.py summary --backend  # the backend log instead
```

Procedure:

1. `summary` first. It **separates features that turned THEMSELVES off** (a
   self-disable after N faults — a real failure) **from mere warnings**. Report
   that distinction; do not flatten it.
2. `faults` if summary shows anything wrong.
3. If `$ARGUMENTS` names a feature, `feature $ARGUMENTS` for its whole run;
   otherwise `grep` for it.
4. Also read the **client's own log** — the newest directory under
   `D:\Aowlspt\Logs\`. This is the client telling you what it did and it usually
   knows more than we do. Search it for exceptions and for the filter term.

Report **observations, then conclusion**, kept separate — "host log says X"
before "therefore Y". Quote refusal messages rather than paraphrasing; they are
worded specifically. If nothing in the logs supports a conclusion, say the logs
do not show it rather than inferring from source. That is the project rule
(`empirical-debugging` skill).

If `tools/hostlog.py` is not on this branch, fall back to reading
`D:\Aowlspt\aowlspt\aowlspt-host.log` and `aowlspt-backend.log` with
`Get-Content -Tail 200`, and say you used the fallback.
