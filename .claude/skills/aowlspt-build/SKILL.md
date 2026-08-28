---
name: aowlspt-build
description: How to build aowlspt correctly on Windows. Load before compiling anything in this repo — the host DLL, tarkov.dll, any mod, the aowl driver itself — before parallelising build work across agents, or when a build fails in a way that does not match the code you changed. Covers the PowerShell-only rule, naming a build target (18m vs 48s), bootstrapping the driver, when parallel builds are safe, and how to read a build failure honestly.
---

# Building aowlspt

The build is a nimony toolchain driven by one program, `installer\build\aowl.exe`.
Every rule below exists because breaking it cost hours and produced a *misleading*
symptom, not an obvious one.

## Always name the target

**This is the single biggest time win available.** Measured:

| what | command | time |
|---|---|---|
| full build | `aowl build` | **18m 25s** (~25 programs, strictly serial) |
| host DLL after a one-line edit | `aowl build host` | **48s** |
| host DLL, nothing changed | `aowl build host` | **0.39s** |

The cost was never compile speed — nimony's incremental cache no-ops in 0.27s.
It is that bare `aowl build` compiles **twenty-five programs when you changed
one**. Name the target:

```powershell
& .\installer\build\aowl.exe build host
```

Targets: `host`, `backend`, `sim`, `launch`, `installer`, `emutest`, `verify`,
`probe`, `mods`, `examples`, and `deploy` (the four artifacts a live install
takes). Bare `aowl build` is for a release or a from-scratch checkout, not for
an edit loop.

One case stays legitimately slow: **changing an ABI header** correctly drops all
caches and forces a full rebuild. That is right, not a bug.

Other subcommands: `bootstrap`, `build-mod PATH`, `build-hosts`,
`build-installer`, `test`, `doctor`, `run PATH`, `payload`, `release`,
`importdb`, `clean`. Flags: `--debug`, `--nimony PATH`, `--ucrt64 PATH`,
`-v/--verbose`. Run everything from the repo root, in **PowerShell**.

`DEVLOOP.md` in the repo root documents the fast path per task.

## Hard rules

### 1. PowerShell only. Never Git Bash.

`gcc` invoked from Git Bash **silently fails**: exit 1, no output, no diagnostic.
The build then reports a failure that has nothing to do with your change. The
Bash tool in this session is Git Bash. Use the PowerShell tool for anything that
compiles. Bash is fine for reading files and grepping.

Related: `C:\msys64\ucrt64\bin` must come **before** Git-for-Windows'
`/mingw64/bin` on PATH, or gcc loads the wrong `cc1` and dies with no diagnostic.
`aowl doctor` checks exactly this — run it first when the *build* is behaving
strangely rather than the code.

### 2. Never hand-invoke nimony to "just build one thing".

Invoking `nimony.exe` directly outside the paths `aowl` sets up **exits 0 and
produces nothing**. A green exit code is not evidence a file was written. If you
think you need a raw nimony call, use `aowl build-mod PATH` instead.

### 3. `aowl build` does NOT rebuild `aowl.exe`. Use `aowl bootstrap`.

`installer/build/` is gitignored, so **a fresh worktree has no `aowl.exe` at
all** — the build command documented above does not exist there until you
bootstrap. An existing checkout may have a stale one. Either way a change to
`tools/aowl.nim` **silently does not ship**, while all 16 mods still print `ok`
and the build looks perfect.

```powershell
& .\installer\build\aowl.exe bootstrap
```

`bootstrap` rebuilds the driver from `tools/aowl.nim`, swaps it in **by rename**
(so it works while the current driver is running) and stamps a content hash.
Every later build then **warns loudly** when the driver is behind its source —
so the trap is now self-announcing rather than silent. Heed that warning.

In a worktree with no `aowl.exe` yet, produce the first one directly — this is
the one case where rule 2 is suspended, because there is no other way to get a
driver:

```powershell
& "$env:USERPROFILE\nimony\bin\nimony.exe" c `
  --passC:-I<repo>\abi -p:<repo>\installer\src -p:<repo>\aowl\src `
  -o:<repo>\installer\build\aowl.exe <repo>\tools\aowl.nim
```

Then use `aowl bootstrap` from then on. Verify the timestamp actually moved.

### 4. Parallel builds: separate worktrees are SAFE. Same checkout is not.

**Measured, not assumed:** three agents built simultaneously in three separate
git worktrees and every binary verified 30/30 markers. Each worktree has its own
`nimcache` (nimony writes it relative to the **working directory**), its own
`installer/build`, its own `.abistamp`. There is no shared mutable build state;
`~/nimony`'s `nccompute`/`ncfib` are stale artifacts, not a live cache.

**So: give each parallel agent its own worktree, then let them all build at
once.** Do **not** poll `Get-Process nimony,aowl,gcc` and wait for other agents.
That was enforced for a whole session and serialised four agents for nothing,
while each individual build used only 30–40% of a 20-core machine.

The real hazard is **two builds in the SAME checkout / same working directory**,
which share one nimcache. That produces either:

- a **silently corrupt binary** — same size, links, runs, then exits −1 with no
  diagnostic; or
- `ld.lld: undefined symbol: strlit_*`, meaning the cache holds objects from two
  different compilations of one module. Fix: delete that one cache entry.

So don't start a second build in a checkout that is already building. And keep
the honest-failure rule: **if a build fails on an identifier from a file you
never touched, rebuild before believing it.** Do not "fix" a phantom error — you
will be editing correct code.

## Reading a failure honestly

| symptom | most likely cause |
|---|---|
| exit 1, no output at all | gcc under Git Bash, or wrong PATH order — run `aowl doctor` |
| error names a file you never touched | rebuild before believing it; if two builds shared this checkout, that is the cause |
| `ld.lld: undefined symbol: strlit_*` | one nimcache holds two compilations of a module — delete that cache entry |
| binary links and runs, then exits −1 with no diagnostic | corrupt object from two builds in the same checkout — rebuild |
| build is green but behaviour did not change | stale `aowl.exe` (bootstrap warns), or you rebuilt but never deployed |
| build took 18 minutes | you did not name a target — `aowl build host` is 48s |
| exit 0 and no artifact | raw nimony invocation — use `aowl build-mod` |
| mod fails to load, error 126 | a *dependency* DLL is missing, not the mod — `objdump -p mod.dll \| grep 'DLL Name'` |

Artifacts land at:

- host — `host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll`
- emulator/backend mod — `mods\tarkov\bin\tarkov.dll`
- tools and driver — `installer\build\`

Building is not shipping. See the `aowlspt-deploy` skill before touching the live
install at `D:\Aowlspt\aowlspt`.
