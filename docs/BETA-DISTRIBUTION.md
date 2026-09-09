# Beta distribution & IP protection — the free public beta

Design pass, with one implemented, tested core (`tools/betagate.nim`). Every
claim about the CURRENT repo is measured against `feat-beta-distribution`
(branched from `feat-settings-native`); everything else is a proposal to
confirm before host wiring is built on top of it.

This document is the beta-specific companion to `docs/DISTRIBUTION.md` (the
packaging design) and to `aoughwl/aowl-store`'s `docs/LICENSING.md` (the paid
product's licence system). **Read those two first** — this design deliberately
reuses their machinery rather than inventing a parallel one.

---

## 0. The requirement, restated precisely

The owner's words: *"no key system for the free beta, but after 7 days it no
longer works and is completely dead ... the logic for how that works [must] be
very hard so nobody can easily patch the timestamp ... we dont want anyone to
take this product and resell it as their own."*

So the beta must satisfy four things at once:

1. **No key, no activation, no server round-trip.** A download runs on first
   launch with zero setup. This rules out the paid product's activation flow
   (`LICENSING.md` §"the enforcement is decryption") *as the primary gate* — the
   content key there comes from the server, and the beta has no server call.
2. **Hard 7-day expiry from the build timestamp.** Not from first-run; from when
   *we* built it. Every copy of one beta archive dies on the same wall-clock
   instant, no matter when it was downloaded.
3. **Tamper-resistant.** Rolling the system clock back, patching the compare,
   or editing the embedded timestamp must all fail — or at least cost far more
   than the beta is worth to a would-be reseller.
4. **Resale-resistant.** A reseller who reposts the archive ships something that
   is already dead or dies within the week, and that cannot be trivially
   re-armed.

## 1. The honest threat model — say what is and is not achievable

This is the single most important section, because the whole scheme is worthless
if it is designed against the wrong adversary.

**The beta runs entirely on hardware the attacker controls, with no server.**
That is a hard constraint with a hard consequence, stated plainly in
`LICENSING.md` and true here too:

> A signature check is an `if`. Every `if` on a machine the attacker owns is one
> patched byte away from `true`.

For the *paid* product `LICENSING.md` escapes this by making enforcement
**decryption, not a check**: the content key lives on the server and is wrapped
to the buyer's machine, so there is no `if` to patch — skipping the decryption
skips the payload. **The free beta cannot use that escape as its root of trust**,
because "no server call" means any key needed to decrypt must ship *inside the
archive*, and a key in the archive can be extracted. A purely offline, keyless
build is therefore **not cryptographically un-runnable after day 7** — that is a
mathematical fact, not a limitation of effort.

What *is* achievable, and what this design targets:

- **Casual bypass does nothing.** Editing a JSON date, `LoadLibrary` on a lone
  DLL, or setting the clock back to last week all fail closed.
- **A determined cracker must redo real work,** distributed across three
  binaries and hidden by `obfnif`, and must re-do it **for every weekly beta
  drop** because each drop re-seals under a fresh key and re-stamps.
- **The valuable asset is sealed, not just gated.** The emulator is worth what
  its *data* is worth (`mods/tarkov/data`, the imported item DB, capture-derived
  tables). Those blobs ship **encrypted** and are only decrypted through the
  gated path, so a naive clock-patch that skips the gate boots into a server
  that has no data — reproducing `LICENSING.md`'s "a copied install has a server
  that boots into nothing", offline.
- **A reseller cannot re-arm it** without rebuilding from source they do not
  have, or cracking the seal every week.

The design does **not** claim "uncrackable". Per `docs/CLAUDE.md` §9b — *a
verification that cannot fail is the bug* — a scheme that claimed to hard-stop a
determined offline attacker would be exactly that lie. The realistic and
sufficient goal for a *free* beta is: it dies on schedule for every normal user,
casual sharing is inert, and reselling is more work than it is worth.

## 2. Root of trust: a signed build stamp (asymmetric, not symmetric)

The build timestamp is the thing everything keys off, so it must be
**unforgeable by whoever holds the archive**. That forces **asymmetric**
signing:

- At release, `aowl release` (see §5) writes a **beta stamp** and signs it with
  an **Ed25519 private key held only offline in aoughwl** — the same trust root
  as the paid product's release signing (`LICENSING.md` §"sealing at release").
- Only the **public key** is compiled — as a constant — into the host DLL, the
  backend, and the launcher. A public key cannot mint a new stamp.

A symmetric MAC (HMAC/SHA-256, which `tools/release.nim` already has) is
**rejected on purpose**: the verify key would equal the sign key, it would ship
in the client, and the attacker could re-stamp any expiry they like. This is the
one place hand-rolled crypto is banned — `LICENSING.md` is explicit: *"If token
expiry is later enforced offline, add Ed25519 then, and vendor a reviewed
implementation rather than typing one out."* **This beta is that case.** Vendor a
reviewed Ed25519 verify (e.g. the reference `ref10`/`donna` in C behind
`abi/aowlspt_shim.h`, called the same way the TLS shim in `abi/aowlspt_tls.h`
already reaches BCrypt); do not type one out. BCrypt itself gained Ed25519 only
recently and unevenly across Windows builds, so a vendored constant-time C impl
is the portable choice.

### The stamp

```
beta stamp (signed blob, ships as payload/beta.stamp):
  magic          "AOWLBETA1"
  buildEpoch     int64   seconds UTC when this archive was cut
  expiryEpoch    int64   buildEpoch + 7*86400   (explicit, not recomputed client-side)
  version        string  from VERSION
  archiveId      16 bytes random, unique per drop  (names the leak; rotates the seal)
  sig            64 bytes Ed25519 over all the above
```

`expiryEpoch` is stored explicitly and signed, not recomputed as
`buildEpoch + 7d` on the client, so the 7-day constant is not a client-side
literal an attacker edits to `700`. Changing 7 days to 3 for a shorter drop is
then a release-time decision, not a client patch surface.

## 3. Enforcement: reconcile many clocks, ratchet forward, fail closed

There is no single trustworthy clock offline, so the gate never trusts one. It
gathers every time source it can, takes a **conservative maximum**, compares to
the signed `expiryEpoch`, and **fails closed** on any doubt. This logic — the
genuinely tricky part — is implemented and unit-tested in `tools/betagate.nim`
(§6); the crypto and the OS source-reads are the host port around it.

### Time sources (each an upper bound on "now")

| source | why it helps | how it is defeated alone |
|---|---|---|
| system wall clock | the normal case | set it back |
| **anti-rollback ratchet** | highest time ever seen, persisted in several places (see below) | delete *all* copies |
| newest mtime across install files & the beta's own logs | writing files advances real time; can't go backward without effort | touch every file back |
| newest timestamp in the client's own `Logs\` and our host log | same, and these grow every run | edit logs |
| opportunistic online time (NTP, or `Date:` from an HTTPS HEAD to a pinned host) **only if a network exists** | authoritative when present | be offline (then the others carry it) |

The decision is `effectiveNow = max(all available sources, ratchet)`. Because
each source is an *upper* bound and we take the max, **a source can only ever
move `effectiveNow` later** — i.e. toward expiry. Rolling one back is defeated by
any other that wasn't. To pass expiry undetected the attacker must roll back
*every* source *and* every ratchet copy at once.

### The anti-rollback ratchet

On every run the gate records `effectiveNow` if it exceeds the stored value, in
several independent locations, all keyed by `archiveId` so a fresh drop starts
clean:

- a value under `HKCU\Software\Aowlspt\b\<archiveId>` (name obfuscated),
- an NTFS **alternate data stream** on an innocuous install file (invisible to
  a casual copy, survives normal file ops),
- a hidden file in `%LOCALAPPDATA%` and one beside the install.

The gate reads *all*, takes the **max**, and if any is missing or lower it
rewrites it forward. Setting the clock back now reads as "we have already seen a
later time than you claim it is" → expired. Deleting all of them only resets to
the *real* clock, which is already past expiry for an old archive.

### Distributed, redundant, fail-closed

The same gate runs independently in **three** binaries — launcher, host DLL, and
backend — because one patched `if` should not open the product:

- The **launcher** refuses to start the game past expiry (visible, friendly
  message pointing at the store).
- The **host DLL** checks at init *and* re-checks on a low-frequency timer, and
  on expiry **stops decrypting** the sealed data (§4) rather than merely
  returning `false` from a check — enforcement is unsealing, not a boolean.
- The **backend** refuses to answer game routes past expiry, so even a patched
  host talks to a dead server.

Every check is **fail-closed**: a missing stamp, a bad signature, an unreadable
source, an exception — all read as expired, never as "allow". Three outcomes,
never two (`docs/CLAUDE.md` §9b): VALID / EXPIRED / **and any INCONCLUSIVE maps
to EXPIRED**, because "I could not check" must not run the beta.

## 4. Seal the data, so expiry is decryption where it can be

Pure checks are patchable; decryption is not (once you skip it you have no
data). We cannot make the *whole* beta un-runnable offline (§1), but we can make
the **valuable data** only reachable through the gated path, exactly as
`AOWLSPT-INTEGRATION.md` §3 recommends ("seal the data, not just the code"):

- At release, seal `mods/tarkov/data`, the imported item DB, and capture-derived
  tables with **AES-256-GCM** under a random per-drop content key
  (`archiveId`-scoped), decrypted through the existing `aowlspt/json` reader.
- For the beta the content key is **derived from material in the signed stamp**
  (e.g. `HKDF(archiveId, info="aowl-beta-seal")`), so it ships *implicitly*, not
  as a plaintext key file — extractable by a determined cracker, but not by a
  clock-patcher, and only after defeating `obfnif` on the derivation path.
- The unseal is **behind the time gate**: the KEK derivation runs only if the
  gate says VALID, so patching the clock does not get you decrypted data — it
  gets you a server booting into nothing.

This is the honest middle ground for a keyless offline build: the seal is not
un-crackable, but it converts "patch one byte" into "extract the key, defeat the
obfuscation, and redo it every weekly drop". Combined with §2–§3 it is what
makes clock-patching *and* re-hosting both unprofitable.

## 5. Release-time: `aowl release --beta`

Extend the existing, reproducible `tools/release.nim` (do not fork it):

1. Read `VERSION`; compute `buildEpoch = now`, `expiryEpoch = buildEpoch + 7d`;
   generate a random 16-byte `archiveId` and a random 32-byte content key.
2. Seal the §4 artifacts into the payload (IV derived per path — `iv =
   HKDF(contentKey, info=relPath)` — so two builds of one tree stay
   byte-identical, which the existing `--check-only` reproducibility gate
   already gouards).
3. Write and **Ed25519-sign** `payload/beta.stamp` (§2). The private key is read
   from an env var / offline file, **never** the repo.
4. **Refuse to release** (reuse the `deploy.json` marker discipline —
   `docs/DISTRIBUTION.md` §6) if: a sealed artifact appears in the archive in
   plaintext, the stamp is missing/unsigned, the public key baked into the built
   host/backend/launcher does not match the signing key, or `expiryEpoch <=
   buildEpoch`. A verification that cannot fail is the bug; each of these catches
   a real way to ship a decorative gate.
5. **`obfnif` hardening pass, last** (`aoughwl/obfuscate`): run over the gate and
   unseal modules in host/backend/launcher — `--opaque-pred --dead-guard
   --strip-info`, rename. Release build only; per `AOWLSPT-INTEGRATION.md` §5
   this buys time, not security, and is deliberately the outermost layer.

Because the stamp and seal rotate per drop, each weekly beta invalidates any
crack of the previous one.

## 6. What is implemented in this pass: `tools/betagate.nim`

The reconciliation-and-ratchet **decision core** — the part most likely to be
gotten subtly wrong, and the part `docs/CLAUDE.md` §9b warns is where
"can't-fail" bugs hide — is implemented as pure logic with no crypto and no OS
calls, and unit-tested (`tests/test_betagate.nim`, run with the standard `nim`
compiler). It exposes:

```nim
type TimeSource = object
  present: bool        # false = could not read this source
  epoch:   int64
type Verdict = enum vExpired, vValid            # note: NO third "allow on doubt"

proc reconcile(sources: openArray[TimeSource]; ratchet: int64): int64
  ## effectiveNow = max(ratchet, every present source). Absent sources ignored.

proc decide(effectiveNow, expiryEpoch: int64; stampOk: bool): Verdict
  ## fail-closed: stamp bad -> vExpired; effectiveNow >= expiry -> vExpired.
```

The tests assert the properties that must hold, stated as negatives so they can
actually fail (a can't-fail check is the bug):

- a rolled-back single source never lowers the verdict (ratchet dominates),
- a bad/absent stamp is always `vExpired` regardless of time,
- exactly at `expiryEpoch` it is `vExpired` (dead *on* day 7, not after),
- all-sources-absent falls back to the ratchet alone and never to "valid",
- no input combination yields "valid" once `effectiveNow >= expiry`.

The host/backend/launcher port wraps this core with: Ed25519 verify of the
stamp (vendored, §2), the OS reads for each source, and the ratchet
read/write in the several locations (§3). Those are integration work that needs
the Nimony build and are **not** implemented here, on purpose — they are listed
as the ordered next steps below.

## 7. Order of work (put §2/§4 key-management choices to the owner first)

1. **Confirm the trust root**: reuse the paid product's Ed25519 release-signing
   key for the beta stamp, or a separate beta-only key? (Recommend separate, so
   a beta-key compromise cannot forge a paid release.)
2. Vendor the reviewed Ed25519 verify behind `abi/aowlspt_shim.h`; bake the
   public key into host + backend + launcher as a constant.
3. Port `tools/betagate.nim` into a shared host/backend module; add the OS
   source reads and the ratchet locations (§3).
4. Wire the three enforcement points (§3) — launcher refuse, host stop-unseal,
   backend refuse — each fail-closed, each with a `find`/log line that announces
   *why* it declined (`docs/CLAUDE.md` §6: every failure path announces itself).
5. Extend `tools/release.nim` with `--beta` (§5) and its refuse-to-ship gates.
6. Seal the §4 data blobs through the `aowlspt/json` reader.
7. `obfnif` pass over the gate + unseal modules, release build only.

## 8. What was NOT done, and why

No host, backend, launcher, or `release.nim` code was changed this pass: every
one of those needs the Nimony build to verify and involves the key-management
decision in §7.1 that should be confirmed first. Only the pure decision core and
its tests were added, because they are toolchain-independent, unit-testable
today, and are the piece whose correctness the rest depends on. This mirrors
`docs/DISTRIBUTION.md`'s own STEP-3 discipline: design the mechanism, implement
only the clearly-correct, additive, verifiable part, and flag the decisions.
