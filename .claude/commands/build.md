---
description: Build aowlspt the correct way (PowerShell, named target, driver-stamp aware)
argument-hint: [target: host|backend|sim|launch|mods|deploy|... or a mod path]
---

Build this repo. Follow the `aowlspt-build` skill — load it now if it is not
already loaded, and obey it over any habit of your own.

Arguments given: `$ARGUMENTS` (may be empty).

Procedure:

1. **Ensure a driver exists and is current.** `installer/build/` is gitignored,
   so a fresh worktree has **no `aowl.exe` at all**. If it is missing, produce
   the first one with the raw nimony invocation in the `aowlspt-build` skill.
   If it exists but `tools/aowl.nim` has changed, or a build warns that the
   driver is behind its source:

   ```powershell
   & .\installer\build\aowl.exe bootstrap
   ```

   Do **not** poll `Get-Process nimony,aowl,gcc` to wait for other agents.
   Parallel builds in **separate worktrees are measured safe**; only two builds
   in this same checkout are a hazard.

2. **Name the target.** Bare `aowl build` compiles ~25 programs and takes
   **18m 25s**; `aowl build host` after a one-line edit takes **48s**. Pick the
   target that covers what changed — `host`, `backend`, `sim`, `launch`,
   `installer`, `emutest`, `verify`, `probe`, `mods`, `examples`, `deploy`.
   Only do a bare full build if I asked for one or an ABI header changed.

3. **Build**, in PowerShell only — never the Bash tool, gcc silently fails there:

   ```powershell
   & .\installer\build\aowl.exe build $ARGUMENTS
   ```

   If `$ARGUMENTS` names a single mod directory rather than a target, use
   `build-mod` with that path.

4. **Read the result honestly.** If the failure names an identifier in a file
   unrelated to the change, rebuild before believing it. `ld.lld: undefined
   symbol: strlit_*` means one nimcache holds two compilations of a module —
   delete that cache entry. If the failure is exit 1 with no output, run
   `& .\installer\build\aowl.exe doctor` and check PATH order.

5. Report: which target was built, how long it took, where the artifacts landed,
   and whether the driver was bootstrapped. Do **not** deploy — that is `/deploy`.
