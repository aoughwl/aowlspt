# Distribution — the final build customers receive

Design pass only. Nothing here is implemented yet except this document. Every
claim about the CURRENT system below is measured against this repo at
`feat-distribution` (branched from `feat-settings-native`); every claim about
the FUTURE system is a proposal.

## 1. What ships TODAY, measured

`installer/README.md` and `installer/payload/README.md` are the source of
truth; this is a summary of what running the pipeline actually produces.

- `aowl payload` assembles `installer/payload/aowlspt/` from what has already
  been built: `aowlspt-host-il2cpp.dll`, `aowlspt-launch.exe`,
  `aowlspt-host.json`, `aowlspt-backend.exe`, and `mods/<name>/` (each mod's
  `.dll` plus its `data/` and `config.json`). `examples/` is deliberately
  excluded. A mod whose library failed to build but whose `data/`/`config.json`
  still exist is refused in three places (`aowl payload`, `aowl release`,
  `aowlspt-verify`) rather than shipped silent and inert — this is the pattern
  worth copying for the mod-API split below.
- `aowlspt-install.exe` (built from `installer/src/`, pure Win32 Nimony, no
  .NET/PowerShell runtime dependency) is the actual installer binary. It reads
  a `payload/payload.json` declaring `targetTarkovVersion`, `targetBackend`
  (`mono`/`il2cpp`), and `kind` (`full`/`overlay`), and refuses two things
  outright with no override: rolling a post-1.0 client backwards across 1.0,
  and a scripting-backend mismatch (Mono plugin on an IL2CPP client). This
  repo only ever produces `il2cpp`/`full` payloads.
- The install is laid down as: mirror the vanilla client (hard-linking ~77 GB
  of asset bundles, copying only the "hot" list that a mod loader could
  plausibly rewrite — `EscapeFromTarkov.exe`, `UnityPlayer.dll`,
  `GameAssembly.dll`, `Managed/`, etc.), then copy `payload/aowlspt` over it,
  then write `mods/manager/config.json`'s default list and `backend.json`.
  `BattlEye` and `ConsistencyInfo` are deliberately not carried across.
- **`db.json` is never shipped.** It's produced locally via
  `aowl importdb --from <SPT install> --out <target>\aowlspt`, and a release
  archive ships `aowl-importdb.exe` as a standalone tool for exactly this,
  since there's no `aowl.exe` outside a dev checkout.
- `tools/deploy.json` verifies **7 artifacts** at deploy time by content
  marker, not just file existence — `host` (44 markers, by far the most
  scrutinised), `nameidx`/`nameidxshared` (the by-name RVA index, magic-byte
  + version-word gated), `tarkov` (6), `backend` (2), `launch` (3), `textures`
  (7). This is the pattern §6.f reuses for release packaging: a rebuild from a
  wrong base must refuse to ship, the same way it refuses to deploy.
- **The live inspector is not a separate artifact today.** Its code
  (`host/Aowlspt.Host.Il2Cpp/inspect.nim`, `debugui.nim`, `invoke.nim`,
  `modetext.nim`, `modstab.nim`) is compiled directly into
  `aowlspt-host-il2cpp.dll` and gated at runtime by two flags in
  `aowlspt-host.json`: `liveInspector` (read-only) and `liveInspectorWrite`
  (arms writes/calls). There is no build target, payload entry, or deploy.json
  artifact that produces an inspector-only binary. Splitting it into its own
  product (§4) is new work, not a repackaging of something that already
  exists standalone.
- The mod API surface (`aowl/src/aowlspt/`) is **11 modules**:
  `abi.nim botnav.nim fast.nim fixture.nim game.nim il2cpp.nim json.nim
  menutext.nim server.nim settings.nim sync.nim`, plus the root
  `aowlspt.nim`. All ship today as Nimony **source**, imported directly by
  every mod (`import aowlspt`, `import aowlspt/settings`, ...) — there is no
  compiled/source split at all yet; a mod author who has this repo checked out
  already gets the full source. Measured: **12 mods** import
  `aowlspt/settings` today (`admin blackdivision classicmovement fov graphics
  morebots resourcepacks sain settingshub tarkov textures`, plus one `.md`
  false-positive-filtered), not the 9 the brief cites — worth flagging back,
  not silently correcting.
- Building a mod requires `nimony.exe` at `%USERPROFILE%\nimony\bin\` (or a
  path passed positionally to `aowl`) — **not vendored, not built by this
  repo, and not part of any artifact `aowl payload` produces.** This is the
  single biggest gap between "ship the API as source" and "a customer can
  actually compile a mod" — see §3.

## 2. Proposed package layout

Two products, matching the owner's two requirements. Both are payload
directories in the existing `installer/payload/` shape — no new installer
mechanism, because `aowlspt-install.exe` already generalises over what a
payload carries.

```
aowlspt-release-<version>/
  INSTALL.md                          copy of docs/INSTALL.md
  aowlspt-install.exe                 the installer (unchanged)
  aowl-importdb.exe                   the db.json importer (unchanged)
  payload/
    payload.json                      targetTarkovVersion, targetBackend, kind=full
    aowlspt/
      aowlspt-host-il2cpp.dll         inspector code EXCLUDED (see §4)
      aowlspt-launch.exe
      aowlspt-host.json               liveInspector: false by default
      aowlspt-backend.exe
      registry/mods.json
      mods/<name>/
        <name>.dll                    COMPILED
        config.json
        data/...
      api/                            NEW: the public Nimony source, read-only
        aowlspt.nim
        aowlspt/
          abi.nim  server.nim  settings.nim  json.nim  sync.nim
          game.nim  menutext.nim  il2cpp.nim  fast.nim  fixture.nim  botnav.nim
        README.md                     "how to build a mod against this", §3
        toolchain/                    pinned nimony, see §3
```

```
aowlspt-inspector-<version>/            SEPARATE product, sold/gated separately
  INSTALL.md
  payload/
    payload.json                      kind=overlay — adds to an existing aowlspt install
    aowlspt/
      aowlspt-inspect-il2cpp.dll       NEW build target, see §4
      aowlspt-host.json.patch          or a documented manual JSON edit enabling it
```

The `api/` directory in the release payload is new; everything else already
exists as a concept in `aowl payload`/`aowlspt-install`.

## 3. The compiled/source split — and the honest difficulty

**Ships as source** (the public API surface a mod author writes against):
all 11 modules under `aowl/src/aowlspt/` plus the root `aowlspt.nim`. This
is not a curated subset — it already IS the whole API; there is no internal
implementation hiding behind it to keep compiled, because these modules
mostly wrap `.h` ABI headers and IL2CPP calling convention, which is exactly
the kind of code a mod author needs to be able to read to trust it (per
CLAUDE.md §5, offsets and frame shapes must be derived, never guessed — the
same rule applies to a mod author debugging their own mod).

**Ships compiled**: every mod under `mods/*` that this repo produces itself
(`tarkov`, `textures`, `admin`, etc.) — as `.dll` only, same as today. Their
`.nim` source stays in the git repo, not the release archive; a paying
customer is not automatically a contributor.

**The crux, stated honestly**: shipping the API as readable source solves
"can a mod author read what they're calling." It does **not** solve "can a
mod author compile a mod," because:

1. **Nimony is not vendored anywhere in this repo or its build output.**
   `tools/aowl.nim` expects it at `%USERPROFILE%\nimony\bin\nimony.exe` and
   never builds it. It is itself a compiler under active development
   (per `.claude` skill `aowlcode:nim-vs-nimony`, feature set differs from
   Nim 2 — no closures, no regex, restricted stdlib). A customer needs a
   working Nimony toolchain before `aowlspt/settings.nim` is even readable to
   the compiler, and there is currently no packaged, versioned Nimony
   distributable this project controls or has verified against.
2. `aowl build-mod PATH` is a thin wrapper around
   `nimony c --app:lib -p:<path-to-api-source>`. That invocation itself is
   easy to document and reproduce standalone (see `api/README.md` above) —
   the wrapper is not the hard part.
3. There's also a Windows toolchain dependency for the C backend
   (`gcc`/`lld`, referenced via `e.ucrt64` in `tools/aowl.nim`, defaulting to
   `C:\msys64\ucrt64\bin`) that a customer's machine needs regardless of
   Nimony.

**Proposed answer, to put to the owner as a question rather than build
silently**: either (a) this project takes on packaging and versioning a
Nimony release as part of `api/toolchain/` — real ongoing maintenance burden,
since Nimony moves — or (b) mod authoring is documented as "requires you to
have Nimony built from its own repo," which is honest but raises the bar for
a modding community significantly above "download an SDK." There is no
existing mechanism in this repo for (a); building one is out of scope for
this pass and is flagged as an open question in §5.

## 4. The inspector as a separate product

Currently the inspector is compile-time part of the host DLL, gated only at
runtime by JSON flags. Splitting it cleanly needs:

- A **build-time** split, not just a runtime flag: a release-tier host build
  should not even contain `inspect.nim`/`debugui.nim`/`invoke.nim`'s code, so
  a customer who didn't buy the inspector product can't flip a JSON flag and
  get it anyway. This likely means a new `aowl build host-inspect` (or a
  `-d:aowlInspector` define) target producing a second DLL,
  `aowlspt-inspect-il2cpp.dll`, alongside the existing `aowlspt-host-il2cpp.dll`
  — genuinely new work, not present in `tools/aowl.nim` today.
- **Packaging**: a separate payload (`kind: overlay`) that installs over an
  existing `aowlspt` install and swaps the host DLL, or ships as a drop-in
  replacement the customer installs manually. It must not silently coexist
  with two detours on the same function (per CLAUDE.md §5's double-detour
  trap) — one host DLL loaded at a time, enforced by the installer refusing
  to lay down both.
- **Safety/support story**: `liveInspectorWrite` calls into live game code —
  CLAUDE.md is explicit that a wrong `click`/`invoke` has already escaped its
  own guard once. A customer-facing inspector needs: default OFF for write
  mode even when the product is installed, a visible in-product warning
  before the first write-mode command, and a documented "if this breaks your
  save/game state, here's what changed" disclosure — none of which exists
  today because the inspector has only ever been a dev tool run by the people
  building this repo.
- **Gating**: whatever entitlement mechanism ships (§5) needs to cover this
  product independently of the base game, since it's plausible to sell one
  without the other.

## 5. Licensing / entitlement — open question, no DRM invented

**There is no existing entitlement mechanism in this repo.** Nothing in
`installer/`, `tools/aowl.nim`, or `tools/deploy.py` checks a license key, a
signature, or an online activation. Per the task constraints, I have not
invented one.

Questions to put to the owner rather than answer unilaterally:
- Is a "free" build simply an older/smaller payload (e.g., fewer mods,
  no inspector), or does everything gate behind a single purchase?
- Any activation should be **offline-verifiable** given this project's
  general offline-first design (`il2cpp_resolve.py`, no telemetry mentioned
  anywhere) — is that a hard requirement, or is a lightweight online check
  (e.g., backend phones home once) acceptable?
- Piracy tolerance: given the audience is EFT mod users, is the goal "raise
  the bar slightly" or "hard-gate"? These have very different implementations
  and the wrong one is wasted engineering either way.

## 6. Build reproducibility

Reuse the `tools/deploy.json` marker pattern exactly, extended to release
packaging rather than only live deploys:

- A new marker list, e.g. `tools/release.json`, of the same shape as
  `deploy.json`'s `artifacts` array, covering the release-specific outputs:
  the `api/` source tree (checksum/file-count check that it matches
  `aowl/src/aowlspt/` at the tag being released — catches an API module added
  to the repo but forgotten in packaging, the same class of bug the mod
  `data/`-without-`.dll` refusal in `aowl payload` already catches), and the
  inspector DLL's own markers if §4 is built.
- `aowl release` (name TBD, doesn't exist yet) should call the same
  `deploy.py`-style check-before-write logic, refusing to produce a release
  archive with a missing marker, not just refusing to deploy one.
- **Never weaken `tools/deploy.json` to make a release check pass** — this
  applies equally to any new `release.json`; a marker existing to catch a real
  past failure (the scav-spawn fix, the exit patch dropped silently) is not
  something a packaging deadline gets to override.

## 7. What was NOT implemented this pass

Per the task's STEP 3 constraint ("implement only what is clearly safe and
additive... do not restructure the existing installer"), no code changes were
made — no new `aowl` target, no `api/` staging, no `release.json`. The
compiled/source split, the inspector build-time separation, and the
entitlement mechanism all involve decisions (see §3, §4, §5) that should be
confirmed before scaffolding is built on top of them.
