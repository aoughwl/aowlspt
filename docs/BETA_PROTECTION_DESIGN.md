# aowlspt — 7-Day Beta Expiry & IP Protection (DESIGN, not yet implemented)

Status: **PLAN ONLY.** Nothing here is built. This is a survey of what exists plus a
layered design for the user to approve or change. No code has been written, no build
made, no artifact deployed.

Provenance is marked throughout:

- **[VERIFIED-HERE]** — measured on this Windows/MINGW64 box during this survey.
- **[RELAYED]** — reported by the aoughwl-side (WSL) Claude via the coordinator; **not**
  verified on this machine. Treat as a lead, not a fact.
- **[INFERRED]** — reasoning/design judgement, not a measurement.

---

## 0. The one-paragraph honest summary

A purely client-side expiry check is **not unbreakable and cannot be made so** — the code
that decides expired-vs-live runs on the attacker's machine, so a determined cracker with
Ghidra/IDA removes it in days-to-weeks regardless of how it is written. The realistic and
worthwhile goal is to **raise the cost from minutes to days**: defeat casual clock-rollback,
casual "delete the check" repackaging, and most resellers. The genuine moat is **not the
expiry check at all** — it is that aowlspt's crown-jewel logic (the server emulator) runs in
a **separate backend process that need never ship in full to beta users**. Design accordingly:
spend obfuscation budget on the client host DLL because it must ship, and keep the valuable
logic server-side. Anything sold to the user as "unbreakable" is dishonest and will burn them.

---

## PART 1 — SURVEY: what already exists

### 1.1 Obfuscation library

- **[VERIFIED-HERE]** No obfuscation library or pass exists **in this repo or on this Windows
  box.** A recursive case-insensitive grep for `obfusc|mangle|flatten|strenc|junkcode|opaque`
  across `C:\Users\savant\Projects\aowlspt\`, all `aowlspt-*` sibling worktrees, and the
  `C:\Users\savant\` Nimony toolchain dirs (`aowlc`, `aowli`, `aowlkit`, `aowlrt`, `aowlabi`,
  `aowlsem`, `aowlhexer`, …) returned nothing. `C:\Users\savant\obfuscate` and
  `~/obfuscate` do **not** exist here.
- **[VERIFIED-HERE]** The org's obfuscator is **`obfnif`** (repo `aoughwl/obfuscate`) — a **real,
  fully-specified, IR-level NIF/AIF obfuscator for Nimony.** Its **implementation `.nim` is NOT
  cloned to this machine** (separate GitHub repo `aoughwl/obfuscate`); what is on disk is its
  complete authoritative documentation. So the library exists and is usable, but must be cloned
  before a build here can invoke it.
  - Authoritative doc: **`C:\Users\savant\Projects\aoughwl-aoughwl.github.io\docs\obfuscate.md`**
    (front-matter `repo: aoughwl/obfuscate`). Entry: `obfnif --all keep.txt mod.p.nif`.
  - **What it does:** operates entirely on the compiler's balanced NIF/AIF IR token tree (never
    source text), on both the parsed `.p.nif` layer (rename by spelling) and the typed
    `.s.nif/.s.aif` layer (symbol-precise rename). Techniques: **name-mangling**
    (`--name-style:opaque|confuse`), **control-flow** (`--wrap-opaque`, `--dead-else`, `--nest`),
    **opaque predicates** (`--opaque-pred`, computed TRUE/FALSE), **dead-code injection**
    (`--dead-guard`, `--junk-discard`), **provenance destruction** (`--strip-info` zeroes all
    line-info). Behaviour-preservation is verified against `aowli-interp` (byte-identical output;
    `--all` grows typed IR ~1.5×). The old source-text mangler `obfuscate.nim` was removed and
    subsumed by this IR pass.
  - **String encryption is DELIBERATELY NOT a feature** — by design it rides the token tree and
    never rewrites `Str`/`Char` tokens, so **string literals are left untouched.** This is the
    key gap for our purposes (section 2.6): the "expired"/date markers would ship in plaintext
    unless we add a separate string-encryption step or emit no plaintext markers.
  - Planned use (docs): `obfnif --opaque-pred --dead-guard --strip-info` over the licence
    crypto/activation modules, **release-only, as the last step**; the docs themselves frame it
    as a **"buys time, not security"** layer.
    (`aowl-store\docs\LICENSING.md:92`, `aowl-store\docs\AOWLSPT-INTEGRATION.md:128-141`.)
  - Ruled out as false positives: `nimony\src\lengc\mangler.nim` and `treemangler.nim` are
    ordinary C-emit name-mangling; `*.dce.nif` are compiler dead-code-*elimination* artifacts.
- **[RELAYED]** On the WSL box, `~/obfuscate/obfuscate` is a **NIF ident-rename** pass, but it is
  **RETIRED and always skipped** (a yellow "obfuscate repo in flux" warning is expected).
  **Do not design around reviving it.** A separate **NIF control-flow obfuscation** stage is
  still applied at release (Layer C, +1.5% runtime) — but see the caveat: none of this is on
  this box, and the only *named, documented* obfuscator here (`obfnif`) is unimplemented.

Net: there is **no working name-mangling/string-encryption/CFG obfuscation library in this repo
or on this Windows box today.** `obfnif` is a spec; Layer C is [RELAYED] and WSL-only.

### 1.2 Timestamp-gating / build-expiry

- **[VERIFIED-HERE]** No build-expiry or timestamp-gate exists in this repo. `tools/betacheck.py`
  matched an `expire`-family grep but is a **red herring**: it is a QA acceptance harness for
  "the four ship-blocking beta *defects*" checked over the wire (profile/trader correctness),
  **not** a time gate. `find … -iname gate.nim` returned nothing; `~/aowl-release` does not
  exist here.
- **[VERIFIED-HERE]** `docs/DISTRIBUTION.md:194` in this very repo states it plainly:
  *"There is no existing entitlement mechanism in this repo. Nothing in `installer/`,
  `tools/aowl.nim`, or `tools/deploy.py` checks a license key, a signature, or an online
  activation."* The build-time stamps that DO exist are **content-identity staleness
  detectors, not clocks**: the `aowlspt-names.idx` build-stamp (keyed on `GameAssembly.dll`'s
  PE header, `tools/doctor.py:325`) and the `.abi`/`.aowl` **djb2 content hashes**
  (`tools/aowl.nim:1168-1312`, comment: *"Contents rather than times"*). No date threshold
  anywhere in aowlspt source.
- **[VERIFIED-HERE] There IS a real licence system — server-side, in the separate `aowl-store`
  product** (Cloudflare Worker + D1), NOT in aowlspt itself:
  - `aowl-store\worker\src\index.ts:159` — `if (lic.expires_at && lic.expires_at < now()) return 'expired'`
  - `:635` — signed-token lifetime cap (`MAX_TOKEN_LIFE`); `:414-416` — download-claim link expiry (410 `claim_expired`)
  - `aowl-store\migrations\0001_init.sql:126-129` — `expires_at INTEGER`, subscription-driven
  - `aowl-store\docs\LICENSING.md:105` — token expires at end of paid period or 30 days
  - Reference time = **the server's wall clock vs a per-licence `expires_at` in D1.**
    Offline token-expiry enforcement is noted as **not yet built**
    (`aowl-store\docs\AOWLSPT-INTEGRATION.md:24` — "add Ed25519" if enforced offline later).
  - `aowlup\src\aowlup.nim:638` carries a UI hint — *"hardened builds expire; re-install to
    refresh the licence gate"* — describing licence-gated release backends fetched from a
    private repo; the "hardened build" expiry it alludes to lives in **that private binary**,
    not in any source tree on this machine.
- **[RELAYED]** Additionally, `~/aowl-release/gate.nim` on the WSL box is a
  **version-validity check, fail-CLOSED**, that refuses to run once expired — effectively the
  7-day-expiry mechanism, built for Linux/ELF. Details in Part 2.4.

**Reconciliation:** the org already has TWO distinct answers to "stop working after N days" —
a **server-side subscription gate** (`aowl-store`, verified here, best for the *paid* product)
and a **client-side build gate** (`gate.nim`, relayed, best for a *free offline beta*). The
free 7-day beta wants the client-side gate (no accounts, no keys); the paid product should lean
on the already-built server-side licence.

### 1.3 The three-layer release pipeline `[RELAYED]`

Reported to exist on WSL, invoked via something like `aowl release`
(**[VERIFIED-HERE]** the `aowl` driver *does* expose a `release` subcommand —
`tools/aowl.nim:49  release  a versioned, verifiable artifact`):

| Layer | What | State |
|---|---|---|
| **A** — source obfuscation | `~/obfuscate/obfuscate`, NIF ident rename | **RETIRED / always skipped** |
| **B** — the gate | `~/aowl-release/gate.nim`, fail-closed version validity | **active; the expiry mechanism** |
| **C** — control-flow obf + strip | NIF CFG obfuscation + `strip --strip-all` | **always applied; +1.5% runtime** |

**[RELAYED] — two structural problems with reusing it as-is:**

1. **WSL-only and unpushable.** `~/aowl-release` is **not a git repo**; its fixes live only on
   that one WSL box. This aowlspt checkout is Windows/MINGW64 and does not have any of it.
2. **Linux-shaped.** The gate uses `/proc/self/exe`, ELF `strip`, and targets **5 ELF nimony
   binaries**. aowlspt ships a **Windows host DLL + backend `.exe` + launcher `.exe`** — a
   different shape entirely (**[VERIFIED-HERE]** the live install runs `aowlspt-launch.exe` and
   `aowlspt-backend.exe`, plus the host DLL `aowlspt-host-il2cpp.dll`).

### 1.4 Existing surfaces on this box worth reusing `[VERIFIED-HERE]`

- **`VERSION`** (repo root) is the single source of truth for the bundle version; `aowl release`
  stamps it into `payload/payload.json` (`"version"`) and into `aowlspt-install.txt` at install
  time. A build **already carries a version string and a build date in its archive name**
  (`aowlspt-<v>-<date>.zip`) — a natural, already-present place to derive a reference time from.
- **`host/Aowlspt.Host.Il2Cpp/betanotice.nim`** — a main-menu-only overlay that already draws
  host-owned text, rides the existing `EFT.UI.PreloaderUI::Update` chain inside one
  `aowl_p_p_seh` guard, reads flag `uxBetaOverlay` from `aowlspt-host.json`, and forwards raid
  state so it is menu-only. This is an **ideal existing host-side surface** for an "expired"
  banner and for a delayed-degradation hook (it already runs every frame on the menu, guarded).
- **Host config** is JSON flags in `aowlspt-host.json` read at boot (`uxBetaOverlay`, etc.).
- **Three separable artifacts already exist**, so defense-in-depth across processes is natural,
  not new plumbing.

---

## PART 2 — DESIGN: the layered 7-day expiry

### 2.0 Hard truths (state these to any stakeholder; do not paper over them)

1. **No purely client-side check is unpatchable.** The decision runs on the attacker's CPU.
   Goal = raise cost minutes→days, defeat casual repackaging and resale. Not impossible. Say so.
2. **`if expired: exit()` is the weakest possible form** — one branch, one patch, one obvious
   crash site. We do the opposite: many independent checks, scattered across DLL + backend +
   launcher, reading time from several sources, degrading in **delayed, varied, confusing** ways.
3. **Time source is the crux** (section 2.2). A local clock is trivially rolled back.
4. **Must not brick a paying customer or a machine.** "Dead" = refuses to run, never damages the
   game install or OS. Beta and paid builds must diverge cleanly (section 2.5).
5. **The expiry checks are exactly the code that most needs obfuscating** (section 2.6).

### 2.1 Reuse the gate's DESIGN, ported to Windows `[RELAYED design → INFERRED port]`

The gate already solved nimony gotchas; **reuse them, do not rediscover** (all **[RELAYED]**):

- No `{.intdefine/strdefine.}` in nimony — the pipeline rewrites a plain
  `const GateValidUntil* = N'i64` at release time. Port: same, patch the const during
  `aowl release` from `VERSION`'s build date + 7 days.
- FFI bare `nil` fails → `cast[pointer](addr tv)`. Uninitialised array fails →
  `default(array[4096, char])`.
- **CRITICAL ORDERING FIX (the single most important detail):** a wrapper that does
  `import gate; gateCheck(); import real` **FAILS** — nimony hoists imported-module init, so
  `real` runs **before** the check. The working shape is: **run the check at the gate module's
  own MODULE-INIT** (top-level `gateCheck()` call), and inject `import gate` as the **entry
  file's first import** so the gate inits before anything else. This is what makes expiry
  **not bypassable by import reordering.** Preserve this exactly when porting.

### 2.2 Time source — enumerate honestly, pick a blend

| Source | Offline? | Rollback resistance | Notes |
|---|---|---|---|
| **Embedded build timestamp** (from `VERSION`/release date, baked into `GateValidUntil`) | Yes | Low — set system clock back | Baseline. Already have the build date. |
| **System clock `now()`** compared to the const | Yes | Low | Trivially rolled back; never the *only* source. |
| **Signed timestamp fetched once** (HTTPS, on first run) | **No — needs network** | High | Requires a phone-home. **OPEN QUESTION for the user — section 4.** No key system, but is a silent one-time timestamp fetch acceptable? |
| **NTFS/file-creation timestamps** of install dir / a dropped marker file | Yes | Medium — resists naive clock rollback if you take **max(seen timestamps)** | Attacker can touch files, but must find them. |
| **Persisted monotonic high-water mark** (store `max(now ever seen)` across runs in an obscure per-user location; if `now < stored`, treat as tampered) | Yes | **Medium-high vs rollback specifically** | Cheap, offline, and directly defeats "set the clock back." Best offline anti-rollback primitive. |
| **`ConsistencyInfo` / install timestamps this project already touches** | Yes | Medium | Reuses existing project surface; obscure location helps. |

**[INFERRED] Recommended blend (offline-first, no network required):**
`GateValidUntil` const (build date + 7 days) **AND** a **persisted monotonic high-water mark**
so rolling the clock back below the last-seen time is itself treated as expiry. Optionally add
the one-time signed network timestamp **only if** the user approves a silent phone-home
(section 4). Keep the reference time in **several obscure places**, never one obvious const the
cracker greps for.

### 2.3 Defense-in-depth: many checks, delayed & varied failure `[INFERRED]`

The distance between "the check" and "the visible failure" is what costs a cracker time. So:

- **Scatter N independent checks** across all three artifacts (host DLL, backend `.exe`,
  launcher `.exe`). Each reads the reference time from a *different* subset of sources.
- **Do not fail at the check site.** On "expired", a check **sets a poison flag / corrupts a
  value used much later**, e.g.:
  - launcher: still launches, but the backend it spawns has been handed a subtly wrong
    parameter so the *emulator* misbehaves minutes into a session;
  - backend: serves subtly-wrong emulator output (a trader assort that is empty, a profile
    field off) rather than refusing at boot — looks like a bug, not a check;
  - host DLL: the `betanotice` overlay flips to an "expired" banner, and a *separate, delayed*
    check introduces a slow drift or disables a feature after a randomised delay.
- **Vary the failure mode** between builds and between checks: immediate refusal in one place,
  slow drift in another, corrupt-a-structure in a third. A cracker who neutralises one visible
  symptom must still find the others.
- **Fail-CLOSED** overall (gate refuses if it cannot determine validity), but see 2.5 on not
  bricking legit users.
- **[INFERRED / rule from repo §9b]** Every check must be falsifiable — assert a property of
  the *finished* state, three outcomes PASS/FAIL/INCONCLUSIVE, never a self-comparison. An
  "INCONCLUSIVE" (can't read the clock, no network) must **not** silently count as "valid."

### 2.4 The gate itself, Windows shape `[RELAYED base → INFERRED port]`

- Replace `/proc/self/exe` with the Win32 equivalent (`GetModuleFileNameW`) for any
  self-referential logic.
- Replace ELF `strip` with the Windows toolchain's strip / no-debug-info release build (the
  MINGW64 `strip` on the produced PE, or link without a `.pdb`).
- Embed the gate in **three** artifacts, each with the **module-init + first-import** ordering
  fix, not one ELF.
- `-d:gateSelfRemove` (delete own binary) exists **[RELAYED]** but is **counseled against as
  default**: a kill-switch that deletes files punishes legit users hit by clock skew or offline
  runs and is a support/liability disaster. See 2.5.

### 2.5 "Completely dead" without bricking anyone — reconcile with the user's wording

The user wants "after 7 days it no longer works and is completely dead." **[INFERRED]
Recommended interpretation:** *dead* = **the software refuses to run and stays refusing**
(a clear "this beta has expired" message, then it will not start), **not** self-deletion and
**not** touching the game install. Rationale:

- A beta expiry that self-deletes or corrupts files is a liability and a reputation risk when
  it misfires (offline user, DST/clock skew, timezone). Graceful-refuse-and-stay-dead achieves
  "completely dead" from the user's point of view with far less blast radius.
- **Beta vs paid must diverge cleanly:** the gate const and the whole gate module are
  compiled **only into beta builds** (`aowl release --beta` sets a distinct build define /
  selects the entry file that imports `gate` first). The **paid build never imports the gate**,
  so there is zero risk of a paid customer being bricked by a stray const — the check literally
  is not in their binary. Keep two release recipes, not one binary with a flag the paid path
  could inherit.
- "Dead" must never mean a damaged Tarkov/SPT install or a modified OS. The host DLL simply
  stops installing its detours and shows the expired banner; the backend refuses to serve;
  the launcher refuses to spawn. Nothing left behind that a normal uninstall would not remove.

**This is the user's call** — self-delete is available if they insist, but the recommendation
is graceful, reversible-by-reinstall "dead."

### 2.6 Tie in obfuscation `[RELAYED capability → INFERRED application]`

- **Reality check first:** the only *named* obfuscator (`obfnif`) is **design-doc-only,
  unimplemented [VERIFIED-HERE]**, and Layer C is **[RELAYED]/WSL-only**. So today there is
  **nothing on this box to point the beta build at.** Either bring Layer C over from WSL, or
  implement the `obfnif` spec, before a public beta can be meaningfully hardened.
- When available, apply **NIF control-flow obfuscation + strip** to the beta artifacts (Layer C,
  +1.5% runtime [RELAYED]). The expiry checks are **exactly** the code that most needs it:
  obscure the const, the comparisons, and the poison-flag propagation.
- **[RELAYED] Strings are copied VERBATIM today — the single biggest leak.** String encryption
  is the #1 next obfuscation step and would directly protect any human-readable marker the gate
  or the "expired" message would otherwise expose. Recommend building/adopting a
  string-encryption pass **before** shipping a public beta, or at minimum ensuring the gate
  emits **no plaintext** "expired"/"valid until"/date strings a cracker can grep and pivot on.
- Do **not** rely on Layer A (retired ident-rename); do not plan around reviving it.

---

## PART 3 — DISTRIBUTION OF THE FREE BETA (secondary)

Constraints **[VERIFIED-HERE from CLAUDE.md]**: the repo is **PRIVATE and must stay so** until
the personal-address leak is fully settled; a `#nightly-beta-builds` Discord webhook exists and
is a **credential — never commit it, not even here**; the docs site is `aoughwl.github.io`.

- **Host the binary, not the source.** Ship only the built, stripped, obfuscated **beta bundle**
  (`aowlspt-<v>-<date>.zip`) — launcher + backend + host DLL + payload — from a public release
  channel (GitHub Releases on a *separate public distribution repo*, or the docs-site download
  page). The **source repo and the paid build stay private.** Never expose the paid artifacts.
- **How the 7-day clock starts — two models, different UX:**
  - **Global build date** (clock = build date + 7 days, same for everyone): simplest, fully
    offline, no per-download infrastructure. Downside: someone grabbing the zip on day 6 gets 1
    day. Good for time-boxed public test windows ("this beta build is good through DATE").
  - **Per-download stamp** (clock starts at first run / download): friendlier UX (everyone gets a
    full 7 days) but needs either the persisted-first-run marker (offline, resettable by a clean
    reinstall) or a per-download signed token (network, closer to a key system the user rejected).
  - **[INFERRED] Recommend global build-date windows for the beta** (matches "no key system",
    fully offline) and cadence the releases so a fresh build lands regularly — the recurring
    build date *is* the renewing clock.
- **Updates reach users** via the existing nightly channel: announce each new dated beta build
  in `#nightly-beta-builds` (webhook stays server-side in the release tooling, never in the
  repo) and/or a downloads page on `aoughwl.github.io`. A new build = a new 7-day window.
- **Publish without exposing source or the paid build:** release only stripped/obfuscated
  binaries; keep `aowl release --beta` as a distinct recipe from the paid recipe; never push the
  private source repo public until the address-leak item is settled (CLAUDE.md §0).
- **[VERIFIED-HERE, security rules]** Release identity is `savannt` / `savant.eclipse@gmail.com`.
  Never run any command that prints a git remote URL (`git remote get-url` etc.) — a GitHub token
  leaked once that way (the URL embedded a token before the `@github` host). Never write the
  user's personal email address anywhere (see CLAUDE.md §0); use the release identity above.

---

## PART 4 — OPEN QUESTIONS THE USER MUST DECIDE

1. **Network or fully offline?** *(the crux)* Is a **one-time, silent HTTPS fetch of a signed
   timestamp on first run** acceptable? It is the only way to make clock-rollback genuinely hard.
   The user said "no key system" — a bare timestamp fetch is not a key system, but it **is** a
   phone-home. **If NO → we ship the offline blend (build-date const + persisted monotonic
   high-water mark), which resists casual rollback but not a determined one.** If YES → we add the
   signed-timestamp source on top. *Default assumption until told otherwise: fully offline.*
2. **What does "completely dead" mean — graceful refuse (recommended) or self-delete?** We
   recommend graceful-refuse-and-stay-dead (no file damage). Confirm, or explicitly opt into
   `-d:gateSelfRemove`.
3. **Clock start: global build-date window (recommended, offline, no key) or per-download
   stamp (fuller 7 days per user, needs a marker or token)?**
4. **Port `gate.nim` into this repo, or build the aowlspt beta ON the WSL box against the
   Windows artifacts?** (a) Port = self-contained, Windows-native, but re-solves the Linux→Windows
   gap and duplicates gate logic. (b) Build-on-WSL = reuses the working gate, but couples releases
   to that one un-pushable box and the Linux/ELF assumptions still need Windows equivalents for the
   PE artifacts. **[INFERRED] Recommend (a) port** a minimal Windows gate module into this repo
   (version-controlled, testable here) that reuses the gate's *design* — module-init check,
   first-import ordering, fail-closed — rather than depending on an un-pushable box.
5. **Invest in a string-encryption pass before the public beta?** Strings ship verbatim today
   (biggest leak); the expiry markers would be plaintext without it. Recommend yes, or at least a
   no-plaintext-markers constraint on the gate.
6. **How many scattered checks, and where?** Needs a concrete map (which check in launcher vs
   backend vs DLL, which time sources each reads, which degradation each triggers) before
   implementation — deliberately left for the approval step.

---

## What this protection CAN and CANNOT stop (honest assessment)

**Can:** defeat clock-rollback by casual users (with the monotonic high-water mark); defeat
"just delete the one check" repackaging (many scattered, delayed, varied checks); make the
reference time non-obvious (several obscure sources, obfuscated const); keep the crown-jewel
emulator logic **off the beta user's disk entirely** (server-side backend). Raise a reseller's
effort from minutes to days.

**Cannot:** stop a skilled reverse engineer with Ghidra/IDA and days-to-weeks — source is not
recoverable but algorithms are, and every client-side check is ultimately patchable. Cannot be
made "unbreakable." Cannot substitute for the real moat, which is **not shipping the valuable
logic**. Obfuscation raises cost; it never reaches infinity.

**Verified vs unverified, explicitly:**
- **[VERIFIED-HERE]** aowlspt has **no** build-expiry and **no** entitlement mechanism (its own
  `docs/DISTRIBUTION.md:194` says so); `obfnif` is **spec-only, unimplemented**; the only working
  date-based refusal in the org is the **server-side** `aowl-store` subscription gate.
- **[RELAYED, NOT reproduced here]** everything about the WSL pipeline and `gate.nim` — the box
  does **not** have `~/aowl-release`, `~/obfuscate`, any `gate.nim`, or Layer C
  (**[VERIFIED-HERE]** those paths are absent).

Before implementation, the gate's actual source and the release recipe must be obtained from the
WSL box and verified, or reimplemented from scratch here against this repo's Windows artifacts.
