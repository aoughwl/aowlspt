## aowldlss.nim -- the DLSS step of `aowlspt-launch`.
##
## Two calls, both into `tools/dlssapply.py`, both printed into the launcher's
## own output so the boot log carries the verdict:
##
##   `dlssPreLaunch(root)`  -- BEFORE `CreateProcess`. Makes the install match
##       the `aowl.dlss` mod config: swaps `nvngx_dlss.dll` (through
##       `tools/dlss.py install`, which re-syncs and re-injects the consistency
##       manifest) when the chosen version differs from what is on disk, and
##       writes the OptiScaler ini keys. Both are things that CANNOT be done
##       once the process exists -- the DLL is open in it and OptiScaler reads
##       its ini at attach -- which is the whole reason this lives here rather
##       than in the host or the mod.
##
##   `dlssVerdict(root, pid)` -- AFTER the client is resumed. Reads the module
##       list of the live process, takes the PE version off the
##       `nvngx_dlss.dll` it ACTUALLY LOADED (not off the file we hoped it
##       would load), re-reads the ini from disk, and prints PASS / FAIL /
##       INCONCLUSIVE per line plus one VERDICT line.
##
## WHY IT SHELLS OUT RATHER THAN PORTING THE LOGIC
## -----------------------------------------------
## The swap is not a file copy. It is a copy plus a `ConsistencyInfo` re-sync
## plus a re-injection of the AES manifest appended to `EscapeFromTarkov.exe`,
## with a backup, a rollback line and a read-back verification -- all of it in
## `tools/dlss.py`, all of it falsifier-tested by its own selftest. A second
## implementation of that here would be a second thing to keep correct, and
## the failure mode of getting it wrong is a client that refuses to boot.
##
## WHAT IT DOES WHEN PYTHON OR THE TOOLS ARE NOT THERE
## ---------------------------------------------------
## It SAYS SO and carries on with the launch. A shipped install has no
## `tools/` directory (measured: `D:\Aowlspt\aowlspt` holds no such folder), so
## the step is skipped on most machines -- and a skipped step that printed
## nothing would be indistinguishable from a step that ran and found nothing to
## do. The search order is `AOWLSPT_TOOLS`, then `<root>\aowlspt\tools`, then
## the repo checkout this exe was built from, and the line names which one was
## used or that none was.

import std/[strutils, osproc, envvars]
import aowlsptinstall/[winfs, log]

const DlssToolRel = "dlssapply.py"

proc quoted(s: string): string = "\"" & s & "\""

proc pythonExe(): string =
  ## `python` on PATH. Not resolved to an absolute path on purpose: the shell
  ## does that, and a hard-coded interpreter is the thing that rots first.
  result = getEnv("AOWLSPT_PYTHON", "python")

proc toolsDir*(root: string): string =
  ## Where `dlssapply.py` lives, or "" -- and the caller prints which.
  result = ""
  let fromEnv = getEnv("AOWLSPT_TOOLS", "")
  if fromEnv.len > 0 and exists(joinPath(fromEnv, DlssToolRel)):
    return fromEnv
  let inInstall = joinPath(joinPath(root, "aowlspt"), "tools")
  if exists(joinPath(inInstall, DlssToolRel)):
    return inInstall
  let fromRepo = getEnv("AOWLSPT_REPO", "")
  if fromRepo.len > 0 and exists(joinPath(joinPath(fromRepo, "tools"), DlssToolRel)):
    return joinPath(fromRepo, "tools")

proc runStep(root, verb, extra: string): int =
  ## One `dlssapply.py` invocation, echoed line by line. Exit code is returned
  ## rather than acted on: 0 PASS, 1 FAIL, 3 INCONCLUSIVE, and this file never
  ## aborts a launch over any of them -- a wrong upscaler is not worth refusing
  ## to start the game, and the line says what it is.
  result = -1
  let dir = toolsDir(root)
  if dir.len == 0:
    note "dlss: SKIPPED -- no dlssapply.py found (looked at $AOWLSPT_TOOLS, " &
         joinPath(joinPath(root, "aowlspt"), "tools") & " and $AOWLSPT_REPO\\tools). " &
         "The DLSS version and the OptiScaler keys are whatever they already " &
         "are on disk; nothing was changed and nothing was verified."
    return
  let cmd = quoted(pythonExe()) & " " & quoted(joinPath(dir, DlssToolRel)) &
            " --root " & quoted(root) & " " & verb & extra
  var outp = ""
  var code = -1
  try:
    let (o, c) = execCmdEx(cmd, workingDir = dir)
    outp = o
    code = c
  except:
    # A missing python is the common case on a player's machine, and it is a
    # SKIP with a reason -- never a failed launch and never a silent one.
    warn "dlss: could not run " & cmd & " -- is python on PATH? The launch " &
         "continues; nothing was applied or verified."
    return -1
  for ln in splitLines(outp):
    if ln.len > 0:
      line "  " & ln
  result = code

proc dlssPreLaunch*(root: string) =
  ## Called from `main` immediately before the client is started.
  heading "DLSS"
  let code = runStep(root, "apply", "")
  if code == 1:
    warn "dlss: the apply step reported FAIL (above). The game is still being " &
         "started -- with the DLSS DLL and the OptiScaler keys that are " &
         "actually on disk, which the verdict after boot will name."
  elif code == 3:
    note "dlss: INCONCLUSIVE (above). Nothing was applied."
  elif code == 0:
    ok "dlss: the install matches the aowl.dlss config"

proc dlssVerdict*(root: string; pid: int) =
  ## Called once the client has been resumed. Read-only.
  let code = runStep(root, "verify", " --pid " & $pid)
  if code == 0:
    ok "dlss: VERDICT PASS -- the loaded module and the OptiScaler keys match " &
       "the config"
  elif code == 1:
    warn "dlss: VERDICT FAIL -- see the lines above; each names the value it " &
         "read and the value the config asked for."
  elif code == 3:
    note "dlss: VERDICT INCONCLUSIVE -- something could not be read (most " &
         "often: NGX has not loaded nvngx_dlss.dll yet, which it only does " &
         "when DLSS actually initialises). Not a pass and not a failure."
