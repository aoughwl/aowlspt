---
description: Deploy built artifacts to D:\Aowlspt with mandatory marker verification and timestamped backup
argument-hint: [host|tarkov|all] [--check]
---

Deploy to the live install. Follow the `aowlspt-deploy` skill — load it now.

Target: `$ARGUMENTS` (default `all`). `--check` means verify only, write nothing.

**The rule: no deploy without marker verification.** Rebuilds from a wrong base
have silently dropped shipped features many times. A green build is not evidence.

Procedure:

1. **Use `tools/deploy.py`.** It is the tool for this job — do not reimplement
   its verification logic. It checks the required literal markers in the **built**
   file (19 for the host DLL, 30 across all artifacts), refuses on any miss, takes
   a timestamped backup and prints the rollback line.

   ```powershell
   python tools\deploy.py check                    # verify only, write nothing
   python tools\deploy.py deploy                   # verify, back up, copy
   python tools\deploy.py deploy --only host       # one artifact
   python tools\deploy.py rollback                 # undo the last deploy
   ```

   Artifact names: `host`, `tarkov`, `backend`, `launch`. Map `$ARGUMENTS` onto
   `--only` (or the positional target); `--check` means run the `check` verb.
   `--dry-run` is available. The marker list is data in `tools/deploy.json` — if a
   new feature needs a marker, add it there, not to this command.

   Report what the tool printed, verbatim where it matters.

2. **If `tools/deploy.py` is not on this branch**, fall back to the manual
   procedure in the `aowlspt-deploy` skill, and say clearly in your report that
   you used the fallback and why.

3. Either way, these must all be true before anything is overwritten — `deploy.py`
   enforces them, so on the fallback path you enforce them by hand:

   - the game is **not running** (`Get-Process EscapeFromTarkov -ErrorAction SilentlyContinue`)
   - every required marker is present **in the built artifact**, not the live one
   - a timestamped backup of each live file exists
   - the rollback command has been **printed to me first**

4. If any marker is missing: **stop, do not deploy, do not "fix it after".**
   Report which markers are missing and which commit last contained them. A
   missing marker means the build came from the wrong base. Do not edit
   `tools/deploy.json` to make a failing check pass.

5. Report: tool or fallback, markers checked and result, backup paths, rollback
   command, final file timestamps.
