# MOD-PERF — what a mod may do on the load path, and the number that proves each rule

Measured 2026-09-01 on build 1.1.0.1.46777, Woods, three offline raids:
`D:\Aowlspt\Logs\log_2026.09.01_12-10-54`, `13-52-07`, `13-56-55` (client
`output_000.log`, `spawn-system_000.log`), plus the host log of a later run on
the same build (`D:\Aowlspt\aowlspt\aowlspt-host.log`, 1469 s, relative
timestamps — the 13:56 session's host log had been overwritten by then; see
"Rough edges"). Every number below was counted with `grep -c` over a
timestamp window or with `tools/bigjson.py` / a `json.load` of `db.json`,
never read by eye. Where a claim is inferred rather than measured it says so.

No rule without its number. If you add a rule, add the measurement.

---

## 0. The shape of a raid load (t0 = launch, session 13-56-55)

| milestone            | wall clock   | from t0 | delta   | what it is |
|----------------------|--------------|---------|---------|------------|
| process start        | 13:56:55.9   | 0       |         | first client log line |
| first backend request| 13:57:07.4   | 11.5 s  | 11.5 s  | `/client/game/mode` — the client's own boot, no mod is consulted before it |
| LocationLoaded       | 13:58:42.3   | 106 s   |         | map assets in |
| GameCreated          | 13:58:44.1   | 108 s   | 1.4 s   | our `/client/locations` + `match/local/start` tables are parsed here (`SpawnWave Time:` dump at 13:58:44.096) |
| PlayerSpawnEvent     | 13:58:54.7   | 119 s   | 10.5 s  | |
| GamePooled           | 13:59:14.9   | 139 s   | 20.2 s  | object pool; the bot burst runs concurrently (see 1) |
| countdown screen     | 13:59:26.0   | 150 s   | 11.1 s  | `EFT.<ShowCountdown>` first log at 13:59:26.041 |
| GameTimer.Start      | 13:59:36.3   | 160 s   | 10.3 s  | `globals.config.TimeBeforeDeployLocal` = **10** in `db.json` |
| GameRunned           | 13:59:36.6   | 161 s   | 0.3 s   | logged in the **same millisecond** as `GameSpawned:92.53(31.25)` — GameRunned IS the end of the spawn phase |

The three sessions agree to the second: GamePooled→GameRunned is 21.7 / 21.5 /
22.85 s, PlayerSpawnEvent→GameRunned is 41.9 / 47.2 / 49.5 s.

---

## 1. Spawn tables: what OUR configuration costs at raid start

### 1.1 What we served vs what vanilla ships (Woods)

| | vanilla `db.json` `locations.woods.base` | served by `mods/tarkov` (flag OFF) |
|---|---|---|
| waves at `Time:-1` | 16 waves, `slots_max` sum **8** (min 6); 9 of the 16 have `slots_max` 0 | **12** waves, span sum **40** (8 × 4 assault + 2 pmcUSEC + 2 pmcBEAR × 2) |
| waves on the timer arm | 0 | 11 (6-10 trickle at 20+30i s, plus one at 360 s) |
| `BotStart` / `BotStop` / `BotMax` | 10 / 1900 / 30 | **0** / 86400 / 30 |
| `BossLocationSpawn` chances | every entry `BossChance: 0` (the capture is BSG's PvE reply; the real roll is server side) | Kojaniy 45, Knight 15, Partisan 10, Priest 10 from `data/post1/locations.json`; the winners are served at **100** (`emu/raid.rollBossSpawnList`) |

Source: `mods/tarkov/emu/raid.nim` `offlineScavWavesWith` (waves),
`tuneOfflineSpawns` (`BotStart 0`, budgets), `applyBossPolicy` (the roll).
`/client/locations` and `match/local/start` both go through `tuneOfflineSpawns`
— the client builds its wave scenario from the former (proof in the
`tuneOfflineSpawns` doc comment).

### 1.2 What the client did with it

Between `GameCreated` and `GameRunned` (line window in `output_000.log`):

| session  | `AIDATA create` | of which AI (minus the player) | `ActivateBotCallback` (start+after pairs) | last activation → GameRunned |
|----------|----|----|----|----|
| 13-56-55 | 45 | 44 | 88 | 13:59:20.8 → 13:59:36.6 = **15.8 s** |
| 13-52-07 | 43 | 42 | 84 | 13:54:42.1 → 13:54:52.5 = **10.4 s** |
| 12-10-54 | 44 | 43 | 86 | 12:13:25.8 → 12:13:42.6 = **16.8 s** |

Per-group census before GameRunned (`TryToSpawnInZone ... Type:`, session
13-56-55): 8 × assault, 2 × pmcUSEC, 2 × pmcBEAR, followerKojaniy,
followerBirdEye, followerBigPipe — i.e. **every one of our 12 immediate waves
was placed**, PMC waves included, plus Shturman and the Goons with escorts.
The first bot activates 7.5 s after PlayerSpawnEvent (13:59:02.2) and the
burst runs 18.7 s; 40 of the 44 activations land before GamePooled.

**Does GameRunned wait on the initial spawn?** Not directly: the last
`ActivateBotCallback` is 10-17 s before GameRunned in all three sessions, and
what fills that tail is `GC::Collect` (1.2 s), a silent 10 s stretch, the
countdown screen and the fixed 10 s `TimeBeforeDeployLocal`. But the burst IS
on the load path: `GameSpawned` reports the spawn phase as **31.25 s**
(PlayerSpawnEvent 61.28 → 92.53 game seconds), `LocalBotsSpawnInitialization`
awaits the `Task.WhenAll` of the `Time < 0` waves before `Run(2)` (disassembly
in the `offlineScavWaves` doc comment), and the two pre-GameRunned
`/client/game/bot/generate` calls cost 0.95 s + 1.2 s of server time at
13:58:45-48. Reducing the burst can shorten PlayerSpawnEvent→GamePooled; it
cannot touch the 10 s countdown (that is `globals.config.TimeBeforeDeployLocal`,
exposed as `g_TimeBeforeDeployLocal` in `emu/globaltunedata.nim`).

### 1.3 The three client complaints, and whose they are

* `Wrong wave WildSpawnType pmcUSEC at wave SpawnPoints: ZoneBigRocks  if u use
  DEBUG file it can is ok` × 4 at 13:58:44.095 — **ours by design**, and
  cosmetic: the client validates the wave's `WildSpawnType` against its
  offline whitelist, logs Error, and places the wave anyway (2 + 2 PMC groups
  spawned, above). A PMC that the client will actually request has to come
  from a `pmcUSEC`/`pmcBEAR` wave (fact #259/#265, `raid.nim` "The PMCs"
  comment); there is no server-side spelling that avoids the message without
  losing the PMCs. Not changed.
* `BotStart для неволнового спавна <= 0` ("BotStart for non-wave spawn <= 0")
  with `NonWavesSpawnScenario ... BotStart:0 BotStop:86400 BotMax:30` — **our
  bug**: `tuneOfflineSpawns` wrote `BotStart 0` (vanilla Woods ships 10), and
  the client disables its own replenishing spawner when it is ≤ 0. Fixed
  under the `stagedStart` flag (the base's own value, 10 when the base ships
  0). Off the flag the old value is still written, on purpose.
* `spawn process error _inSpawnProcess:N. > _maxBots:0` on every spawn — the
  host's `unlimitedBots` detour pokes `BotSpawner.MaxBots = 0` (host log
  0:00:00.000 line), and the client's check reads 0 as "over the cap" but
  proceeds. Host feature, not a mod; report only.
* `Delays in progress: id:Delay params. Count:2 Zone:ZoneBigRocks ...
  RemoveReason:noData` every ~3 s — a wave whose `bot/generate` data has not
  arrived. In 13-52-07 and 12-10-54 it was the 4-bot assault wave and cleared
  after 25 lines (~75 s); in 13-56-55 it was the 2-bot PMC wave and was still
  logging at 14:02 (69 lines). It does not gate GameRunned; it is a retry
  loop the client runs on its own. Staging moves the PMC waves off the burst,
  which is the case that stuck.

### 1.4 The fix: `stagedStart` (default OFF) in `mods/tarkov`

Settings (F12 → Bots/Spawns; `mods/tarkov/config.json`):

| key | default | meaning |
|-----|---------|---------|
| `stagedStart` | `false` | OFF = the table above, byte for byte. ON = same waves, same bots per raid, different clocks |
| `stagedStartInitialBots` | `0` | bots kept at `Time:-1`; 0 = the map's own vanilla at-start `slots_max` sum (Woods 8), floor 4 |
| `stagedStartFirstDelaySec` | `20` | `time_min` of the first deferred wave; each next one +10 s |
| `stagedStartBossDelaySec` | `45` | `Time` written on every rolled boss the table ships at -1; Partisan (`Time:900`) and triggered bosses untouched |

What ON serves for Woods (from the pure generator, `selfCheckRaid` asserts it):
**2 waves / 8 bots at `Time:-1`** (was 12 / 40), 10 waves / 32 bots deferred to
20..110 s, the 11 trickle waves unchanged, bosses at `Time:45`, `BotStart 10`.
Total bots per raid identical (asserted, with a negative control: the check
refuses to pass if the unstaged table already fits the cap).

Readback, so the client log can be held against it: every map's served table
logs one line `staged-start readback <Id>: ON|OFF -- N wave(s) at Time:-1 (B
bots), M deferred to A..B s (C bots), K trickle wave(s) ...; BotStart x -> y;
bosses moved to Time T: n`, and the boss roll line now names the clock:
`boss roll: seed=... kept=bossKojaniy@Time:45,...`. The client-side witness is
its own `SpawnWave Time:` dump at GameCreated — count the `Time:-1` lines.

INFERRED, not yet measured: that a `boss*` entry with `Time >= 0` is delayed
the way Partisan's `Time:900` is (`partisan by time` in the client log). The
readback names the served `Time`; the client's `BOSS_WAVE info ... Time:` line
will confirm or refute it on the first staged raid.

---

## 2. The host thread: per-frame work outside a raid

Each mod's `onUpdate(elapsedMs)` is called from the host's own thread loop
(`aowlhost.nim:9557 cSleep(16)`, `9746 modhost.tickMods(elapsed)`); `everyMain` riders
(`onFovTick`, `onMainTick`) run once per Unity frame on the main thread. The
`debug` profiler table (host log 0:00:12.750, printed once) measured every
mod's loader-tick cost at **0.012-0.392 ms total over 25-120 ticks** — the
per-tick cost of the mods is not where load time goes. The log volume is:

| emitter (host log, 1469 s run) | lines | pattern | verdict |
|---|---|---|---|
| `inspect\|` | 6284 | inspector batches (a human/agent asking) | on demand, fine |
| `singleplayer rebrand` | 5091 | `not resolved -- BUDGET, not absence: the scan for node "MainCaption"` **4681×**, `CACHED ... yielded no targets` 470× — 3-5 lines/s for the whole run | **host feature (modstab), report only**: a bounded scan that never latches "absent" and re-runs every tick with formatted text |
| `natesp` | 582 | `VERDICT INCONCLUSIVE -- canvas REFUSED -- no live GameWorld` + `raid phase = MENU` — 4 lines / 10 s, 199 pairs, for **0 contacts** | host feature; the gate is correct (it refuses) but it formats and logs the refusal every 2.5 s |
| `overlay` / `live inspector` | 291 / 408 | `IDLE and HEALTHY` 2 lines / 10 s | heartbeat |
| boot bursts | 367 (0-10 s), 319 (20-30 s), 307 (40-50 s) | sain RVA table 111 lines at load, inspector 219, settings page build 183 | one-shot |

Mod tick handlers, audited (file:line, what runs when NOT in a raid):

| mod | handler | gate before any allocation? | out-of-raid work |
|---|---|---|---|
| sain | `sain.nim:2037 onUpdate`, `client/driver.nim:1333 tick` | yes: `sain.nim:2096 if capability() != capFull:` returns before `scan`/`tick` | none O(bots) |
| morebots | `morebots.nim:1694 onUpdate` → `1755 if ws != GwLive:` returns before `censusTick` (771) | yes | none |
| fov | `fov.nim:4980 onUpdate`; `fov.nim:3817 onFovTick` (every frame) | **onFovTick has no raid gate**: `applyFov()` is called on every tick (`fov.nim:3839`), in the menu too; `applyFov` returns at its own first guard | a per-frame call that returns at a guard |
| maps | `maps.nim:1440 onMainTick` → `1444 if not gEnabled: return ""` | yes | **`maps.nim:2442 onDiagTick` builds `mapsDiagText()` (`2448`, a multi-branch string) every call regardless of raid; `3020 onReconcileTick` runs `mirrorDrift()` (`3029`) every call** |
| admin | `admin.nim:1071 onUpdate` | no raid gate at the call site | `adm/data.nim:579 gStatus = "no GameWorld: " & gwStateText()` **every tick**; `admin.nim:1133 setStatus(dataStatus() & "  " & godStatus())` every tick |
| ammoloading | `ammoloading.nim:1282 onUpdate` → `report()` | `gEnabled` (default false) checked first | when enabled: `reportText()` (dozens of `&`) built **every tick**, the 30 s throttle is on the write, not the build (`1184` before `1186`) |
| debug | `debug.nim:677 onUpdate` | none | `burn(gSpinMs)` (0 by default); `reconcileTick` (421) re-reads the whole config (`440 setting("").raw`) every `cReconcilePeriodMs = 1000` |
| textures | `textures.nim:427 onUpdate` | no raid gate | a 10 s readout (`441`, `info loadProbeReport()` at 447/461) formats regardless of raid |
| graphics | `graphics.nim:467` | — | `= Ok`, nothing |
| manager | `mgr/refresh.nim:900 refreshTick` | `926 if gEnabled and gUrl.len > 0 and not gPinnedPath:` | one comparison when idle |
| waypoints | none | — | server-side routes only |

---

## 3. Host boot: the "3.8 s of mod loading"

Host log: `il2cpp bound` 0.985 s, `backend polling ... every 3000ms` 1.203 s,
`the backend wants aowl.<mod> loaded; queueing` **4.766 s** ×6, every mod's
"loaded" line by **4.797 s**. The load itself is ~30 ms; the 3.8 s is one
3-second poll period plus the backend's mod-build answer. The deferred
release (`releasing deferred mods now -- MODS READY`) is at **18.188 s** and
re-runs every mod's init (`morebots: off`, `ammoloading will arm in 12000ms`
appear twice, at 4.77 s and 18.20 s — the second pass is
`modload.nim:902 modLoadReleaseMods` ("releasing deferred mods now", line
914); the first pass is the backend-poll answer at 4.766 s. Why a deferred
release re-runs an already-run init was NOT traced — host code is out of
scope here; it is reported, not explained). **Neither is on the client's critical
path**: the client's first request is at 11.5 s and its first raid-relevant
one (`/client/locations`) is minutes later; the mods are idle until the
GameWorld exists. It is, however, a double init: a mod that arms a detour in
`onLoad` should expect to be loaded twice per process. sain's "25 REFUSED
rows" at 4.766 s are its RVA-table verdicts (22 members refused), printed as
111 lines — informational, ~0 ms.

---

## 4. The rules, each with its number

1. **Serve at raid start only what the client needs to open the raid.** Our
   12 immediate waves = 40 bots + bosses → 42-44 AI created before
   GameRunned, a 31.25 s spawn phase, two 1 s `bot/generate` calls, and one
   PMC wave stuck in `noData` retries for 3.5 min. Vanilla Woods opens with 8.
   Pattern: put the vanilla count on the `Time < 0` arm and the rest on the
   timer arm (`stagedStart`); keep the total per raid identical and log the
   table you served.
2. **Never write a value the client rejects and then keep going.**
   `BotStart 0` → `BotStart для неволнового спавна <= 0` and the vanilla
   spawner silently off, for every raid since the line was written. Pattern:
   read the base's own value, write only what you mean, and grep the client
   log for the field name after the first raid.
3. **A gate must sit before the allocation, not before the log.**
   `ammoloading.nim:1184` builds `reportText()` every call and throttles only
   the write (`1186`); `maps.nim:2442 onDiagTick` formats on every call;
   `admin adm/data.nim:579` concatenates a status string every tick with no
   GameWorld. sain (`capFull` before `scan`) and morebots (`GwLive` before
   `censusTick`) are the pattern to copy: one cheap bool, then return.
4. **Do not O(bots)/O(nodes) outside a raid — and do not re-scan what you
   already know is absent.** `singleplayer rebrand` scanned for `MainCaption`
   4681 times in one run, each time reporting "BUDGET, not absence", 3-5
   lines/s for 24 minutes; `natesp` printed 199 identical INCONCLUSIVE
   refusals for 0 contacts. Pattern: arm on the GameWorld-live edge, cache the
   census, log a verdict once per edge, budget the scan per frame and stop
   when the budget says so.
5. **Nothing a mod does at boot is on the client's load path — until it is.**
   Host boot to "mods loaded" 4.8 s, deferred release 18.2 s; the client's
   first request 11.5 s, `GameCreated` 108 s. Boot cost is hidden today;
   `onLoad` runs twice per process, so make it idempotent and never block in
   it.
6. **The 10 s you cannot remove from a mod is `TimeBeforeDeployLocal`.** It
   is a `globals.config` number (10) served by the SPT layer
   (`g_TimeBeforeDeployLocal`), not a spawn cost; changing it is a design
   decision, not an optimisation.
7. **Pair every served table with a readback and a self-check that can
   fail.** `staged-start readback` per map, `boss roll ... kept=name@Time:N`,
   and `selfCheckRaid` pins the OFF table to 12 waves / 40 bots at -1 and
   refuses to pass when the unstaged table already fits the cap (the vacuous
   case). The client's own `SpawnWave Time:` dump is the witness.

---

## 5. Rough edges hit while measuring (CLAUDE.md §10)

* **The host log is one file per install, overwritten per run.** The 13:56
  session's host log was gone by the time this was written; the host-side
  numbers above are from a later run of the same build. `tools/hostlog.py`
  has no `--session`. A per-run copy under `D:\Aowlspt\Logs\<ts>\` next to
  the client's own logs would make the two logs line up.
* **`bigjson.py find` requires `--key`**, and its usage line shows it only
  after a failed call; `find db.json TimeBeforeDeployLocal` errors. Minor.
* **`hostlog.py` timestamps are relative** (`[0:00:04.781]`) while the client
  logs are wall clock; there is no way to align a host event to a client
  milestone without the launch instant. A wall-clock stamp on the host log's
  first line would fix it.
* **No offline runner for a mod's self-check.** `selfCheckRaid` runs only
  inside a backend that has loaded `tarkov.dll` (`/aowlspt/tarkov/selfcheck`,
  `tools/emutest.nim`), so a subagent that may not deploy cannot prove its own
  self-check passes; it can only build and hand the DLL over.
* **`wirelog.py` reads the current `aowlspt-backend.log`**, which, like the
  host log, is the latest run: the `bot/generate` exchanges of the 13:56
  session were not recoverable, so which wave got `noData` is inferred from
  the client's `Count:`/`Zone:`, not read from the wire.
