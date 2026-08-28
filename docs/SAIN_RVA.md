# SAIN driver — the RVA table, and the one live measurement that gates it

This is the byte-verified static-RVA table that replaces SAIN's per-tick by-name
binding (`ensure`/`resolveOn`/`findOn` → the token-gated `il2cpp_class_*` exports,
fact #224). Every RVA here was resolved offline with
`tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat`
and the resolver reproduces two known-good ground-truth RVAs byte-exact in the
same run (`EFT.BotOwner::UpdateManual`→`0x81B7C0`,
`BotMover::SetTargetMoveSpeed`→`0x1A2B4D0`). Build 1.1.0.1.46777.

Prologue bytes below are the expected 16-byte signature to bake into the mod and
feed to `aowl_pro_verify(rva, sig, 16)` at bind — the host compares them against
the **startup snapshot** (`abi/aowlspt_prologue.h`), never live memory.

## Drive path — the observable behaviour (all UNIQUE, real bodies)

Reach a bot's components from its `EFT.Player`, then call the setter. Instance
convention `RCX=this`, args `RDX/R8/R9`/XMM, hidden trailing `MethodInfo*`=NULL
(none of these is a shared generic, so NULL is legal).

| member | type::method (sig) | RVA | shared | prologue (16B) |
|---|---|---|---|---|
| getter | `EFT.BotOwner::get_Mover() -> BotMover` | `0x80F920` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_Steering() -> BotSteering` | `0x80D8E0` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_WeaponManager() -> BotWeaponManager` | `0x80F040` | UNIQUE | (getter) |
| getter | `EFT.BotOwner::get_AIData() -> IAIData` | `0x810360` | UNIQUE | (getter) |
| getter | `AIData::get_BotOwner() -> BotOwner` | `0x692A50` | **SHARED×338** trivial `[rcx+0x28]` | call-safe; = field @0x28 |
| move | `BotMover::GoToPoint(Vector3,bool,float,bool,bool,bool,bool) -> NavMeshPathStatus` | `0x1A2EE00` | UNIQUE | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 70 48` |
| sprint | `BotMover::Sprint(bool,bool)` | `0x1A2D700` | UNIQUE | `48 89 5C 24 08 57 48 83 EC 30 0F B6 FA 48 8B D9` |
| sprint(alt) | `BotMover::set_Sprinting(bool)` | `0x1A2B040` | SHARED×2 trivial `mov [rcx+0x130],dl` | call-safe |
| stop | `BotMover::Stop()` | `0x1A2D600` | UNIQUE | — |
| look | `BotSteering::LookToPoint(Vector3)` | `0x1A3B690` | UNIQUE | `48 83 EC 28 48 8B 41 10 48 85 C0 74 3C 48 8B 40` |
| reload | `BotReload::TryReload() -> bool` | `0xBB44A0` | UNIQUE | `40 53 48 83 EC 30 33 C0 48 8B D9 48 89 44 24 40` |
| speed(server) | `BotMover::SetTargetMoveSpeed(float)` | `0x1A2B4D0` | UNIQUE | already used by server/drive.nim |

Note the by-name trap this table removes: `Sprint` also resolves on
`BotMoverBTR` to `0x628110` — the 6,438-owner **empty stub** (`ret 0`). A by-name
walk that met a BTR mover would bind the stub and silently drive nothing. The RVA
table pins `BotMover::Sprint@0x1A2D700`, a real body.

## Sensor getters — resolvable, but each needs its DECLARING TYPE pinned

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
| `get_ShootData` | `EFT.BotOwner` | `0x80E8D0` | — |
| `get_Medecine` | `EFT.BotOwner` | `0x80ECC0` | — |

The remaining ~50 members of `bindAll` (memory/enemy/weapon/medicine sub-getters
and the vector readers) are the same shape: resolvable offline once the owner is
pinned. That work is mechanical but real — it is not a wiring afternoon.

## BLOCKER — the client driver enumerates ZERO bots, and lifting it is a LIVE measurement

`mods/sain/client/live.nim:2034` — `listLen` returns **0 unconditionally**, so
`scanForBots` (driver.nim:618) sees `n=0`, the while loop never runs, no bot is
attached, `tickBot` never fires, and every drive call count is 0. That is why the
diag reads `K=0`. **The RVA setters above are correct and useless until this is
lifted**, because there is no bot to call them on.

The list itself IS reached (`AllAlivePlayersList` is a non-generic field @0x1c8,
read off a host-validated world). The break is counting/iterating it:

- `List<Player>::get_Count` / `get_Item` are **shared generics** → need a real
  `MethodInfo*`; NULL is illegal for a shared generic and the only offline route
  to one is by-name, which is the fatal gated path. **The RVA-call route is
  genuinely blocked here.**
- The field route (`_size`/`_items`) is blocked *offline*: IL2CPP writes an
  all-zero fieldOffsets array for the uninstantiated `List`1` definition
  (`GENERIC-NO-LAYOUT`, CLAUDE.md §5), so the tools cannot confirm `_size@0x18`/
  `_items@0x10` offline and the mod's own comment (`listLenWhy`) refuses to guess.

The standard il2cpp `List<T>`-of-reference layout is fixed
(`_items` object[] @0x10, `_size` int @0x18, array data @+0x20), and a guarded,
**self-validating** read is legitimate (VirtualQuery `_items`; `_size <=
array.length`; each element a readable `Player` whose `get_ProfileId` reads back)
— that is a falsifiable check, not a guess, and it is the correct fix. But
**confirming it needs a live `dump`/`scan` on a real `List<Player>` pointer inside
a raid via the inspector**, which a subagent must not do (no game start; inspector
MCP unreachable from a subagent). This is a one-command measurement for the
coordinating session; until it is taken, reviving the client driver from a
subagent would rest on an unverified offset — exactly the "check that cannot fail"
CLAUDE.md §9b forbids.

## fact-#24 disposal — NOT in this path (cleared)

`grep -rE "ToESain|CreateClasses|SainEnumMirror|ESainWildSpawn" mods/sain/**/*.nim`
returns nothing. The Nim reimplementation never calls
`SainEnumMirrorExtensions.ToESain()` or `BotComponent.CreateClasses()`; that
disposal lives in the real managed SAIN.dll, which is not loaded (no BepInEx).
The driver is **not** downstream of the fact-#24 disposal. No prerequisite bug
there.

## The 28+ settings — honest wired/removed split

The registered settings (`mods/sain/sain.nim`, 41 rows) are almost all
**decision-core thresholds** (`engageDistance`, `timeBeforeSearch`,
`holdGroundBaseTime`, health thresholds, `coverMinEnemyDistance`, …). They are
consumed by the Nim decision core (`core/decide.nim`), not by a game method — so
each reaches a bot ONLY when the client decision→drive loop actually runs on that
bot.

- **Reach a bot TODAY (server/drive.nim botnav path, independent of this driver):**
  `difficulty`, `roles.{pmc,scav,boss,zombie}.difficulty` → per-role move speed
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

## Acceptance — the exact host-log line to watch (INCONCLUSIVE from a subagent)

The driver is revived only when the existing diag
`sain: N bots, M decisions, K game calls` reads **K > 0**, and a per-setting line
`sain: applied <key>=<v>, bot read back <v>` shows a live bot value that CHANGES
with the setting. Both are INCONCLUSIVE here: they require the live enumeration
fix (List<Player> layout measurement) that only the coordinating session can take.
