# SAIN driver â€” the RVA table, and the one live measurement that gates it

This is the byte-verified static-RVA table that replaces SAIN's per-tick by-name
binding (`ensure`/`resolveOn`/`findOn` â†’ the token-gated `il2cpp_class_*` exports,
fact #224). Every RVA here was resolved offline with
`tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat`
and the resolver reproduces two known-good ground-truth RVAs byte-exact in the
same run (`EFT.BotOwner::UpdateManual`â†’`0x81B7C0`,
`BotMover::SetTargetMoveSpeed`â†’`0x1A2B4D0`). Build 1.1.0.1.46777.

Prologue bytes below are the expected 16-byte signature to bake into the mod and
feed to `aowl_pro_verify(rva, sig, 16)` at bind â€” the host compares them against
the **startup snapshot** (`abi/aowlspt_prologue.h`), never live memory.

## Drive path â€” the observable behaviour (all UNIQUE, real bodies)

Reach a bot's components from its `EFT.Player`, then call the setter. Instance
convention `RCX=this`, args `RDX/R8/R9`/XMM, hidden trailing `MethodInfo*`=NULL
(none of these is a shared generic, so NULL is legal).

| member | type::method (sig) | RVA | shared | prologue (16B) |
|---|---|---|---|---|
| getter | `EFT.BotOwner::get_Mover() -> BotMover` | `0x80F920` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_Steering() -> BotSteering` | `0x80D8E0` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_WeaponManager() -> BotWeaponManager` | `0x80F040` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_AIData() -> IAIData` | `0x810360` | UNIQUE | (getter) |
| getter | `AIData::get_BotOwner() -> BotOwner` | `0x692A50` | **SHAREDÃ—338** trivial `[rcx+0x28]` | call-safe; = field @0x28 |
| move | `BotMover::GoToPoint(Vector3,bool,float,bool,bool,bool,bool) -> NavMeshPathStatus` | `0x1A2EE00` | UNIQUE | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 70 48` |
| sprint | `BotMover::Sprint(bool,bool)` | `0x1A2D700` | UNIQUE | `48 89 5C 24 08 57 48 83 EC 30 0F B6 FA 48 8B D9` |
| sprint(alt) | `BotMover::set_Sprinting(bool)` | `0x1A2B040` | SHAREDÃ—2 trivial `mov [rcx+0x130],dl` | call-safe |
| stop | `BotMover::Stop()` | `0x1A2D600` | UNIQUE | â€” |
| look | `BotSteering::LookToPoint(Vector3)` | `0x1A3B690` | UNIQUE | `48 83 EC 28 48 8B 41 10 48 85 C0 74 3C 48 8B 40` |
| reload | `BotReload::TryReload() -> bool` | `0xBB44A0` | UNIQUE | `40 53 48 83 EC 30 33 C0 48 8B D9 48 89 44 24 40` |
| speed(server) | `BotMover::SetTargetMoveSpeed(float)` | `0x1A2B4D0` | UNIQUE | already used by server/drive.nim |

Note the by-name trap this table removes: `Sprint` also resolves on
`BotMoverBTR` to `0x628110` â€” the 6,438-owner **empty stub** (`ret 0`). A by-name
walk that met a BTR mover would bind the stub and silently drive nothing. The RVA
table pins `BotMover::Sprint@0x1A2D700`, a real body.

## Sensor getters â€” resolvable, but each needs its DECLARING TYPE pinned

Every name below resolves, but several are ambiguous by declaring type and the
old `LazyCall` picked whichever class the live object happened to be. The RVA
table MUST pin one. Measured ambiguities:

| name | correct owner for the census | RVA | other owners seen |
|---|---|---|---|
| `get_IsAI` | `EFT.Player` | `0x726890` | `EFT.PlayerBridge` `0x2510790` |
| `get_ProfileId` | `EFT.Player` | `0x71F9E0` | `EFT.BotOwner` `0x6F15C0` |
| `get_MovementContext` | `EFT.Player` | `0x690D20` | `PlayerBridge::get_MovementContextAdapter` `0x6898E0` |
| `get_HealthController` | `EFT.Player` | `0x727E40` | `EFT.BotOwner` `0x810150` |
| `get_BotsGroup` | `EFT.Player` | `0x734BD0` | `EFT.BotOwner` `0x80FCD0` |
| `get_ShootData` | `EFT.BotOwner` | `0x80E8D0` | â€” |
| `get_Medecine` | `EFT.BotOwner` | `0x80ECC0` | â€” |

The remaining ~50 members of `bindAll` (memory/enemy/weapon/medicine sub-getters
and the vector readers) are the same shape: resolvable offline once the owner is
pinned. That work is mechanical but real â€” it is not a wiring afternoon.

## ENUMERATION - SOLVED (was the first blocker; the live measurement was taken)

**Superseded 2026-08-30.** The earlier text here said `listLen` returned 0
unconditionally and needed a live `List<Player>` measurement a subagent could not
take. That measurement has since been taken (fact #226, "40 live: 39 bots + the
local player", every hop confirmed readable in a real raid), and the code walks it:

- `mods/sain/client/live.nim:2029-2085` -- `listLen`/`listAt`/`arrayOf`/`listBound`
  read the fixed il2cpp `List<T>`-of-reference layout (`_items` object[] @0x10,
  `_size` int @0x18, array data @+0x20, `Array.max_length` @0x18) as a **guarded,
  self-validating** read: every hop VirtualQueried, `_size` clamped to the backing
  array's `max_length` and to a 512 hard cap, an unreadable list/array/element
  returns 0 without a dereference. No by-name, no shared-generic `MethodInfo*`.
- `client/bridge.nim` probe step 7 already reports the live count off this path.

So the alive-players list is both reached (`AllAlivePlayersList`, non-generic
field @0x1c8 off a host-validated world) **and** counted/indexed. Enumeration is
no longer the blocker.

## THE REMAINING BLOCKER - the ~56 by-name sensor/drive call sites (a large, live-gated effort)

With enumeration solved, `capFull` is STILL deliberately withheld
(`client/bridge.nim` probe step 7 forces `capReadOnly`), and `onUpdate`
(`sain.nim` ~1950) gates `scan`/`tick` on `capFull`, so **the client decision
loop never ticks in a raid and no bot is driven from the client half.** The sole
reason is the binding mechanism, not enumeration:

- Every per-bot sensor read (`get_IsAI`, `get_MovementContext`, `get_Position`,
  the memory/enemy/weapon/medicine sub-getters, ~50 in all) and every drive
  setter (`GoToPoint`, `Sprint`, `LookToPoint`, `TryReload`, `Stop`, ~6) is a
  `LazyCall`. `LazyCall`/`ensure`/`resolveOn`/`findOn` -> `il2cpp.findMethod`,
  which calls `il2cpp_class_get_method_from_name` **directly** on the runtime
  entry table -- a TOKEN-GATED export that returns a plausible random non-zero
  handle instead of failing, so the nil check passes and the first dereference
  kills the client (fact #35/#224). `ensure` therefore refuses the entire table
  behind `reflectionRefused()` (config `allowIl2cppReflection`, default false),
  which is why enabling the mod is SAFE but drives nothing from the client.
- The fix is to replace those ~56 call sites with the byte-verified static-RVA
  table above, each with its declaring type PINNED (the getters section lists the
  measured ambiguities), calling by RVA with a NULL `MethodInfo*` (none is a
  shared generic). That bypasses the export ABI entirely -- the same route
  `server/drive.nim`'s botnav already uses.

Why this is NOT a subagent job and NOT a wiring afternoon:

1. It is ~56 call sites plus the two refused discovery detours
   (`AddActivePLayer@0x254ce30`, `OnDead@0x732c30`, both needing TYPED RVA
   handlers and the measured identity walk `Player.Profile@0x9c0` ->
   `Profile.Id@0x10` -> `System.String`), not the "28 settings" the feature was
   scoped as three times.
2. Each converted bind INSTALLS a live read/call into game code. A wrong
   declaring-type pin binds a base body or, worse, the 6,438-owner empty stub at
   `0x628110` (the `Sprint`-on-`BotMoverBTR` trap noted above) and drives nothing
   silently -- a "check that cannot fail". Distinguishing a correct bind from that
   requires the live diag `K > 0` plus a per-setting read-back, which only the
   coordinating session can observe. A subagent shipping this rests on unverified
   binds -- exactly what CLAUDE.md 9b forbids.

Do it incrementally, in the coordinating session, one component at a time, each
verified live against `K>0` and a value read-back before the next is added.

## fact-#24 disposal â€” NOT in this path (cleared)

`grep -rE "ToESain|CreateClasses|SainEnumMirror|ESainWildSpawn" mods/sain/**/*.nim`
returns nothing. The Nim reimplementation never calls
`SainEnumMirrorExtensions.ToESain()` or `BotComponent.CreateClasses()`; that
disposal lives in the real managed SAIN.dll, which is not loaded (no BepInEx).
The driver is **not** downstream of the fact-#24 disposal. No prerequisite bug
there.

## The 28+ settings â€” honest wired/removed split

The registered settings (`mods/sain/sain.nim`, 41 rows) are almost all
**decision-core thresholds** (`engageDistance`, `timeBeforeSearch`,
`holdGroundBaseTime`, health thresholds, `coverMinEnemyDistance`, â€¦). They are
consumed by the Nim decision core (`core/decide.nim`), not by a game method â€” so
each reaches a bot ONLY when the client decisionâ†’drive loop actually runs on that
bot.

- **Reach a bot TODAY (server/drive.nim botnav path, independent of this driver):**
  `difficulty`, `roles.{pmc,scav,boss,zombie}.difficulty` â†’ per-role move speed
  via `SetTargetMoveSpeed@0x1A2B4D0`. ~5 settings, already observable
  (fact #158, move speed 0.49).
- **Blocked at enumeration (need the client loop, which is dead at `listLen=0`):**
  every `engageDistance`, `timeBeforeSearch`, `runAwayHealthThreshold`,
  `willSearchForEnemy`, `canShiftCoverPosition`, `holdGroundBaseTime`,
  `fightBackHealthThreshold`, cover distances, `decisionHz`, `maxBotsPerTick`,
  `farFromPlayerDistance`. These are correctly *computed* per bot by the decision
  core; they simply never execute because no bot is enumerated.
- **Not behavioural (infra/flags):** `enabled`, `server.patchBrains`,
  `server.neutraliseLocationModifiers`, `logDecisions`, `driveFromHostThread`,
  `allowIl2cppReflection`.

No setting was removed as unexposed by SAIN 4.5.0; the correct verb is **blocked**,
on one measurement, not **removed**.

## Acceptance â€” the exact host-log line to watch (INCONCLUSIVE from a subagent)

The driver is revived only when the existing diag
`sain: N bots, M decisions, K game calls` reads **K > 0**, and a per-setting line
`sain: applied <key>=<v>, bot read back <v>` shows a live bot value that CHANGES
with the setting. Both are INCONCLUSIVE here: they require the live enumeration
fix (List<Player> layout measurement) that only the coordinating session can take.
