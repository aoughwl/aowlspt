# 1.0 release readiness — audit, not a build pass

Measured against `feat-10-release` (worktree branched from `feat-settings-native`
at `cedf87a`). No live install was touched, per constraint. `aowl payload` /
`aowl build` were NOT run in this pass (read-only audit); statements about what
those commands do are from reading `tools/aowl.nim` directly, not from executing
it — flagged below as "not run."

## Profile creation — the headline question

**Works, and is reachable without a repo checkout.** `aowlspt-launch.exe` (a
shipped payload artifact) takes `--new NAME [--side Usec|Bear]` and `--pick`,
both plain CLI flags on the installed binary — no source checkout needed.
`tools/aowlsession.nim` documents `POST /aowlspt/tarkov/launcher/profile/create`,
which is what `--new` calls. Verified in `tools/aowllaunch.nim`: when a fresh
install has **zero** profiles, the auto-select path does not error — it warns
"nothing to select" and starts the client with no token, falling back to the
**game's own in-client character-creation flow** (`tools/aowllaunch.nim` ~1888).
So a tester who just double-clicks the launcher with no flags still reaches
character creation; `--new`/`--pick` are conveniences, not the only path.
**Not run live** — this is read from the launcher's own control flow and log
strings, not observed against a real empty `db.json`.

## STATUS AFTER THE AUDIT — what has since been fixed

The audit below is preserved as written. These items are now closed:

* **#1, #2, #3 — FIXED in `958e7a2`.** All five unregistered mods
  (`uihub`, `settingshub`, `admin`, `graphics`, `resourcepacks`) are in
  `registry/mods.json`. `settingshub` and `uihub` went into
  **`aowl.list.core`**, which every list inherits — so `vanillaplus` gets the
  settings surface without needing its own entry, closing #3 as well.
  `admin`, `graphics` and `resourcepacks` are registered but in no list on
  purpose, and their descriptions say so. `aowl.icebreaker` was dropped (1.0
  ships the map) along with the two stale `loadAfter` references to it.
  **Verified**: `installeruildowl-regcheck.exe --repo <repo>` — 200
  checks, 0 failures, exit 0. It was 1 failure and 7 warnings before, and that
  one pre-existing failure (`textures` exported its guid as its display name)
  is fixed too.
  *The check that would have caught this already existed* — `aowl-regcheck`
  tests the registry in both directions — but it only runs inside
  `aowl verify`, which had not been run. The binary is prebuilt and instant;
  run it directly.
* **#7 — FIXED.** `aowl payload` now **fails** on a missing `payload.json`
  instead of warning. The file is gitignored, so it exists only on the machine
  this was developed on; a release cut from a fresh clone got "ok, N files
  staged", exit 0, and an installer that could not run. Requires
  `aowl bootstrap` to take effect, since `aowl build` does not rebuild
  `aowl.exe`.

* **Profile creation — VERIFIED LIVE, no longer read-only.** The audit could
  only read the launcher's control flow. The route `--new` actually calls was
  driven directly against a standalone backend:
  `POST /aowlspt/tarkov/launcher/profile/create {"nickname":"ReleaseTest1","side":"Bear"}`
  → `{"ok":true,"token":"0000000000fc...","profile":{...,"side":"Bear","voice":"Bear_1","level":1}}`;
  re-listing `/aowlspt/tarkov/launcher/profiles` showed it persisted alongside
  the existing profile; and creating the same nickname again was refused with
  the server's own `{"ok":false,"error":"that nickname is taken"}`. The test
  profile was then deleted (`store/aowl.tarkov/profile.<id>` plus its `.hist`
  entry) and the list re-read to confirm only the real profile remained.
* **The settings surface — VERIFIED LIVE.** After deploying the staged payload
  mods to `D:\Aowlsptowlspt`, `/aowlspt/ui/page/settings` answers 200
  `text/html` (8801 bytes) and `/aowlspt/settings/index` answers 200 JSON.
  `/aowlspt/mods` reports `"mods":16` (was 11), `"problems":[]`.
* **The payload guard — VERIFIED.** With `payload.json` temporarily renamed
  away, `aowl payload` now exits 1 with the explanatory message instead of
  exit 0. (`aowl bootstrap` was run, so the rebuilt `aowl.exe` carries it.)

**The cheap rung nobody was using:** the backend runs STANDALONE on plain
HTTP with no game client, no TLS and no certificate --
`aowlspt-backend.exe --root D:\Aowlsptowlspt --port 6969` -- and answers
every route. Send `Accept-Encoding: identity` or it deflates (fact #123).
Every verification in this section took seconds; none needed a client launch.

Still open from the audit: **#4** (`deploy.json` covers 2 of 7 mod artifacts —
dev-install path only, does not block the payload), **#5** (rebuilding a mod
needs the private Nimony toolchain), **#6** (`db.json` must be imported
post-install), and everything under "What could NOT be verified without a live
install".

## BLOCKER

| # | Finding | Evidence |
|---|---|---|
| 1 | **The shipping settings UI (`mods/uihub`) and 4 other real mods — `admin`, `graphics`, `resourcepacks`, `settingshub` — are entirely absent from `registry/mods.json`.** `aowl payload` stages their `.dll`/`data`/`config.json` fine (it walks `mods/*` blindly), but the mod manager only knows what's in the registry, and hand-editing `aowlspt-selection.json` is reverted by design. A fresh install therefore has these 5 mods **on disk but permanently unmanageable** — gate 2 of the documented 3-gate load path fails, with no UI path to fix it. | `python -c "..."` diff of `registry/mods.json` mod ids vs `mods/*` dirs: registry has `blackdivision classicmovement fov manager morebots pathtotarkov perf sain sway tarkov textures icebreaker` (12); `mods/` has 16 dirs including `admin graphics resourcepacks settingshub uihub`. Confirmed by `grep -c` for each name in `registry/mods.json`: `settingshub`=0, `uihub`=0, `admin`=0, `resourcepacks`=0, `graphics`=0 (its one hit is a tag string, not a mod id). |
| 2 | **`docs/SHELVED-NATIVE-SETTINGS.md` says the shipping settings surface for 1.0 IS `mods/uihub`'s browser page** (`/aowlspt/ui/page/settings`), because the native in-game settings work is deliberately off. Combined with #1, **1.0 as packaged today ships no reachable settings UI at all** — the native path is off by design, and the browser fallback can't be enabled through the manager. | `docs/SHELVED-NATIVE-SETTINGS.md` lines 1-9; registry gap above. |
| 3 | **The default selection list, `aowl.list.vanillaplus`** (installer default per `installer/src/aowlsptinstall.nim:43`), **doesn't include `settingshub`/`uihub` even if they were registered** — it only has `fov`, `sway`, `classicmovement`, `perf`, `textures` on top of core. So even fixing #1 needs a list edit, not just a registry entry, for the settings page to be on by default. | `registry/mods.json` `aowl.list.vanillaplus` entries; `installer/src/aowlsptinstall.nim:43`. |
| 4 | **`tools/deploy.json` (used for the LIVE dev install, not the release payload) covers only 2 of the mod artifacts** (`tarkov`, `textures`) among 7 total. This is a known, accepted gap for the dev deploy path (facts #112/#115/#121) — it is NOT what `aowl payload` uses, so it does not block the release payload, but a `deploy.py deploy` against `D:\Aowlspt` will keep silently skipping marker-verification on every other mod, including the newly-blocking ones above. Do not treat `deploy.py check` passing as evidence any mod besides tarkov/textures is intact. | `python -c "json.load(deploy.json)"` artifact list: `host, nameidx, nameidxshared, tarkov, backend, launch, textures`. |

## SHOULD-FIX

| # | Finding | Evidence |
|---|---|---|
| 5 | **Building any mod requires a private Nimony toolchain** (`%USERPROFILE%\nimony\bin\nimony.exe`, not vendored, not built by this repo) plus MSYS2 `ucrt64` gcc/lld. This only matters if a tester is expected to rebuild anything; the payload ships pre-built `.dll`s so a pure install-and-play tester doesn't hit it. Testers who want to tweak a mod will. | `docs/DISTRIBUTION.md` §3 (design doc, cross-checked: `tools/aowl.nim` really does reference `e.ucrt64` defaulting to `C:\msys64\ucrt64\bin` and expects nimony at that fixed path — confirmed by grep, not by running a build). |
| 6 | **`db.json` is never shipped** and must be produced post-install via a separate `aowl-importdb.exe` against a real SPT/Tarkov install path the tester must already have. This is correct/intentional per `docs/DISTRIBUTION.md`, but it is a REQUIRED step with an external dependency (an existing Tarkov install) that the runbook below must state explicitly — it is not obvious from just running the installer. | `tools/aowl.nim` `importdb` command (~line 2636); `docs/DISTRIBUTION.md` §1. |
| 7 | **Confirmed: `installer/payload/payload.json` does not exist** (only `payload.json.template` does). `aowl payload` warns rather than fails when it's missing, but `aowlspt-install.exe` requires it (`targetTarkovVersion`, `targetBackend`, `kind`) to run at all. Must be created from the template before packaging a release, or `aowl payload` will report success while the installer still can't run. | `Test-Path`/`ls` on `installer/payload/`: `payload.json` MISSING, `payload.json.template` present. `tools/aowl.nim` `cmdPayload` ~line 2599. |

## NICE-TO-HAVE

| # | Finding |
|---|---|
| 8 | `docs/DISTRIBUTION.md` itself proposes (not yet built) a compiled/source mod-API split, a separate inspector product, and an entitlement mechanism — all explicitly out of scope per the doc's own §7 and per this task's "do not restructure the installer" constraint. Nothing here blocks a tester build. |

## Runbook — download to raid, as packaged today

1. Run `aowlspt-install.exe` from the release payload. Installs by hard-linking
   the vanilla client's ~77GB, then lays `payload/aowlspt` over it. **Needs**:
   an existing vanilla Tarkov 1.0 IL2CPP install to link against, and enough
   free disk for whatever isn't hard-linkable.
2. Run `aowl-importdb.exe --from <SPT install> --out <target>\aowlspt` to
   produce `db.json`. **Needs**: a source SPT install with data to import; not
   part of the base game install. If this step is skipped, `db.json` is
   absent and the emulator has nothing to serve — NOT verified what
   `aowlspt-backend.exe` does in that case (would need a live run).
3. Run `aowlspt-launch.exe` (no flags). With no profiles, the client reaches
   the game's own character-creation screen; a new profile is created there,
   or via `--new NAME --side Usec|Bear` beforehand.
4. **Settings**: per BLOCKER #1/#2, there is currently no reachable settings
   surface in a stock 1.0 package — the browser page (`uihub`) can't be
   enabled through the manager, and the native in-game settings are
   deliberately off (`docs/SHELVED-NATIVE-SETTINGS.md`). A tester who wants
   `/aowlspt/ui/page/settings` today needs registry/selection hand-edited
   from a source checkout, which contradicts "no repo checkout needed."
5. Raid: not driven in this pass (would require touching a live install,
   explicitly disallowed for a subagent).

## What could NOT be verified without a live install

- Whether `aowlspt-backend.exe` degrades gracefully or hard-fails with no
  `db.json` present.
- Whether the installer's default `mods/manager/config.json` seed actually
  matches `aowl.list.vanillaplus` as claimed, or drifts.
- End-to-end raid entry, deploy marker behavior against a real `D:\Aowlspt`,
  and whether `aowl payload`/`aowl build` actually run clean on this branch —
  none were executed in this audit pass.

No code was changed. This is audit-only per task instructions; the registry
gap (BLOCKER #1) is a one-line-per-mod JSON fix but is a real content/product
decision (does 1.0 want admin/graphics/resourcepacks enabled by default?) and
was left for the owner rather than silently added.
