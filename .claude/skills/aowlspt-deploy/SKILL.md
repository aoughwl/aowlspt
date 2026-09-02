---
name: aowlspt-deploy
description: How to deploy aowlspt artifacts to the live install at D:\Aowlspt without silently dropping features. Load before copying any built DLL into the live install, before launching the game to test a change, or when a feature that used to work has vanished. Covers mandatory marker verification, timestamped backups, rollback, and the consistency-check landmine.
---

# Deploying to the live install

Live install: `D:\Aowlspt` (game) / `D:\Aowlspt\aowlspt` (our files).

## The rule

**Never deploy without marker verification.**

Rebuilds from a wrong base have silently dropped shipped features many times —
the scav-spawn fix, the exit-button patch, the version brand, image serving. Each
time the build was green, the copy succeeded, and the feature was simply gone.
The only thing that catches it is checking that the feature's marker string is
present in the artifact you are about to ship.

## Use the CLI tool

`python tools/deploy.py` does this job. **Wrap it; do not reimplement it.** It
verifies the required literal markers in the **built** file (19 for the host DLL,
30 across all artifacts), refuses on any miss, takes a timestamped backup and
prints the rollback line.

```powershell
python tools\deploy.py check                 # verify only, write nothing
python tools\deploy.py deploy                # verify, back up, copy
python tools\deploy.py deploy --only host    # one artifact
python tools\deploy.py rollback              # undo the last deploy
```

Artifacts: `host`, `tarkov`, `backend`, `launch`. `--dry-run` and `--install` are
available.

The marker list is **data**, in `tools/deploy.json`. Add a marker the same day you
add a feature — that is the whole point. Markers must be literals the compiler
cannot fold away; log-message text is ideal, because it is emitted verbatim and
names the feature. **Never edit `deploy.json` to make a failing check pass.**

If the tool is not on your branch, use the manual procedure below and say in your
report that you used the fallback.

## Manual procedure (fallback)

Only for when `tools/deploy.py` is unavailable. The marker lists below are the
ones that were verified by hand; `tools/deploy.json` is the current authority
and carries more (19 for the host DLL, 30 in total).

### 1. Verify markers in the BUILT artifact

Every marker must be present as a literal string in the file you are about to
copy. Check the build output, not the live file.

**`aowlspt-host-il2cpp.dll`** — `host\Aowlspt.Host.Il2Cpp\bin\`:

```
debugui  debugEsp  settingsUiProbe  settingsRelabelProbe  settingsBindProbe
settingsPages  uxMenuModeText  imageCdnRedirect  osCloseFix  uxVersionBrand
unlimitedBots  botDiag  Exit button
```

**`tarkov.dll`** — `mods\tarkov\bin\`:

```
ensurePockets  post1LocationsTuned  tuneOfflineSpawns  onFiles  creation-session
```

Check them:

```powershell
$dll = 'host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll'
$bytes = [IO.File]::ReadAllBytes($dll)
$text  = [Text.Encoding]::ASCII.GetString($bytes)
$markers = 'debugui','debugEsp','settingsUiProbe','settingsRelabelProbe',
           'settingsBindProbe','settingsPages','uxMenuModeText','imageCdnRedirect',
           'osCloseFix','uxVersionBrand','unlimitedBots','botDiag','Exit button'
$missing = $markers | Where-Object { -not $text.Contains($_) }
if ($missing) { Write-Output "MISSING: $($missing -join ', ')" } else { Write-Output 'all markers present' }
```

**If anything is missing, STOP.** Do not deploy and then investigate. A missing
marker means you built from the wrong base — find the commit that has the
feature and rebuild. Deploying first destroys the evidence and the working install.

### 2. Back up the live file with a timestamp

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$live  = 'D:\Aowlspt\aowlspt\aowlspt-host-il2cpp.dll'
Copy-Item $live "$live.bak-$stamp"
Write-Output "ROLLBACK: Copy-Item '$live.bak-$stamp' '$live' -Force"
```

Print the rollback command **before** you overwrite anything, so it is in the
transcript whether or not the deploy goes well.

### 3. Copy, then confirm

```powershell
Copy-Item 'host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll' $live -Force
(Get-Item $live).LastWriteTime
```

The game must not be running — the DLL is loaded into `EscapeFromTarkov.exe` and
the copy will fail with a sharing violation if it is.

## The consistency-check landmine

The client **refuses to boot** if a file listed in `D:\Aowlspt\ConsistencyInfo`
changes **size**. Content may change freely; size may not, unless you also fix
the manifest.

`D:\Aowlspt\Logging.config` is **hardlinked** to `D:\Games\Tarkov\Logging.config`.
Editing one edits both.

When changing log levels, keep the level name the same length:
`Trace`, `Debug`, `Error` are 5 characters; `Information` is 11. Swapping
`Debug` for `Trace` is free. Swapping `Debug` for `Information` breaks the boot.

If a size change is unavoidable, re-sync the `ConsistencyInfo` entry: update its
**Size** and its **Checksum**, where the checksum is the byte-sum of the file
modulo 2^32.

## Never

- Never modify the live install as a way of testing a source change. Build, verify,
  back up, deploy.
- Never delete the `.bak-*` files without being asked. They are the only history
  the live install has.
- Never deploy while the game is running.
