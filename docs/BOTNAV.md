# Bot navigation / AI control — IL2CPP recon

Everything below was resolved **offline** from `D:\Games\Tarkov\GameAssembly.dll` +
the decrypted `global-metadata.dat`, using `tools/il2cpp_resolve.py` (type/field/RVA)
and capstone for the disassembly. Imagebase `0x180000000`. All generated code lives
in the **`il2cpp` PE section**, not `.text`.

## Toolchain validation

Before trusting a single number below, the resolver was checked against five
independently-known ground truths on this build:

| Claim (known good, from other features) | Resolver output | Match |
|---|---|---|
| `System.String._stringLength` @0x10, `_firstChar` @0x14 | 0x10 / 0x14 | yes |
| `BotOwner::PreActivate` @0x813F60 | 0x813f60 | yes |
| `BotOwner.WeaponManager` @+0x308 | 0x308 (`BotWeaponManager`) | yes |
| `GameWorld::RegisterPlayer` @0x25038C0 (botDiag detour) | 0x25038c0 | yes |
| `BotSpawner::AddPlayer` @0x2563AE0, `MaxBots` @+0xC0 (botcap) | 0x2563ae0 / 0xc0 | yes |

`Player` offsets already proven live also reproduce exactly: `Profile`+0x9C0,
`AIData`+0xA00, `IsYourPlayer`+0xB89, `MovementContext`+0x60,
`MovementContext.PreviousPosition`+0x370.

---

## 1. `EFT.BotOwner` layout (the fields that matter)

Type 7088, `Assembly-CSharp.dll`.

| Offset | Field | Type | Why we care |
|---|---|---|---|
| 0x30 | `_botState` | `EBotState` | activation state |
| 0x40 | `_activateTime` | float | 0 until activated |
| 0x68 | `Settings` | `BotSettings` | -> `_difficulty`@0x10, `_role`@0x14 (`WildSpawnType`, int32) |
| 0x148 | `Steering` | `BotSteering` | look/aim steering |
| 0x308 | `WeaponManager` | `BotWeaponManager` | (already known) |
| 0x390 | `BotsController` | `BotsController` | |
| **0x3D0** | **`Mover`** | **`BotMover`** | **the movement object** |
| 0x3F0 | `BotsGroup` | `BotsGroup` | grouping |
| 0x3F8 | `PatrollingData` | `PatrollingData` | patrol layer |
| 0x400 | `ProfileId` | `string` | stable id |
| 0x408 | `Id` | int32 | per-raid bot id |
| 0x410 | `SpawnBotZone` | `BotZone` | zone it spawned in |
| **0x418** | **`GetPlayer`** | **`Player`** | back-reference — used as the round-trip check |
| 0x431 | `IsDead` | bool | |

### Getting from a `Player` to its `BotOwner` — safely, without reflection

`Player.AIData` @+0xA00 is typed `IAIData` and has **two** concrete implementations
with *different* layouts:

* `AIData` (type 1510): `_botOwner` @ **+0x28**
* `StubAIData` (type 1524): `<BotOwner>k__BackingField` @ **+0x30**

Reflection is dead, so we cannot ask which one it is. The resolution is
**self-validating**: read the candidate at +0x28; accept it only if
`[cand + 0x418] == player`. If not, try +0x30 with the same test. If neither
round-trips, give up on that player. No blind write, no guessed offset.

## 2. `BotMover` (type 1312) — the movement object

Fields that matter:

| Offset | Field |
|---|---|
| 0x30 | `_player` |
| **0x80** | **`_moverStateMachine`** (`BotMoverStateMachine`) |
| 0x130 | `<Sprinting>` bool |
| 0x138 | `<IsMoving>` bool |
| 0x148 | `<SDistDestination>` float |
| 0x158 | `<Pause>` bool |
| 0x15C | `<MoveSpeed>` float |
| 0xD8 | `_pathFinder` (`BotPathFinderCorePoints`) |

`BotMoverStateMachine`: `_owner`@0x10, `<CurrentMoverState>`@0x18,
`_states` (`Dictionary<EBotMoverState,BotMoverState>`) @ **0x20**.

## 3. THE MOVEMENT ENTRY POINT — directly callable

```
EFT.BotOwner::GoToPoint(Vector3 position, bool slowAtTheEnd, float reachDist,
                        bool getUpWithCheck, bool mustHaveWay, bool mustGetUp,
                        bool onlyShortTrie, bool force) -> NavMeshPathStatus
RVA 0x81CB40   section: il2cpp
prologue (16): 48 83 EC 68 0F 57 C0 0F 2F C3 76 20 48 8B 41 68
```

Full disassembly — the entire function:

```
18081CB40  sub  rsp, 0x68
18081CB44  xorps xmm0, xmm0
18081CB47  comiss xmm0, xmm3          ; 0 vs reachDist
18081CB4A  jbe  18081CB6C             ; reachDist >= 0  -> skip the Settings deref
18081CB4C  mov  rax, [rcx + 0x68]     ; this->Settings          (only if reachDist < 0)
18081CB50  test rax, rax / je throw
18081CB55  mov  rax, [rax + 0x68]     ;   .Current
18081CB5E  mov  rax, [rax + 0x30]
18081CB67  movss xmm3, [rax + 0x14]   ;   default reach dist
18081CB6C  mov  rcx, [rcx + 0x3d0]    ; this->Mover
18081CB73  test rcx, rcx / je throw
18081CB78  mov  eax, [rdx + 8]        ; <- pos.z   : Vector3 arrives BY POINTER in RDX
18081CB7B  movsd xmm0, [rdx]          ; <- pos.x/y
18081CB7F  lea  rdx, [rsp + 0x50]     ; copy on our stack
18081CB84  mov  [rsp+0x58], eax
18081CB88  movzx eax, byte [rsp+0xb0] ; force
18081CB90  mov  qword [rsp+0x40], 0   ; <=== MethodInfo* = NULL  (the game itself)
18081CB99  mov  byte [rsp+0x38], al   ; force
18081CB9D  movzx eax, byte [rsp+0xa8] ; onlyShortTrie
18081CBA5  mov  byte [rsp+0x30], al
18081CBA9  movzx eax, byte [rsp+0x98] ; mustHaveWay
18081CBB1  mov  byte [rsp+0x28], al
18081CBB5  mov  byte [rsp+0x20], 1    ; getUpWithCheck := true (hardcoded)
18081CBBA  movsd [rsp+0x50], xmm0
18081CBC0  call 181A2EE00             ; BotMover::GoToPoint
18081CBC5  add  rsp, 0x68
18081CBC9  ret
18081CBCA  call 1805D2530 / int3      ; managed NullReference throw helper
```

### What this proves

1. **`Vector3` (12 bytes) is passed BY POINTER**, not in XMM — it is not a
   1/2/4/8-byte aggregate, so Win64 passes a pointer to a caller-owned copy.
   `RDX` is `Vector3*`. Confirmed by `movsd xmm0,[rdx]` + `mov eax,[rdx+8]`.
2. **`float` args go in the XMM register of their positional slot.** `reachDist`
   is arg index 3 and arrives in `XMM3`. Independently confirmed by
   `BotOwner::SetTargetMoveSpeed` (`movss [rax+0x15C], xmm1` — arg index 1 -> XMM1)
   and `BotMover::SetTargetMoveSpeed` (`movss [rcx+0x15C], xmm1; ret`, a two-
   instruction function that is pure ABI ground truth).
3. **`MethodInfo* = NULL` is correct here** — the game passes a literal 0 for the
   trailing `MethodInfo*` on its own call to `BotMover::GoToPoint`.
4. **Passing `reachDist >= 0` skips the `Settings` pointer chain entirely.** With
   `reachDist = 1.0f` the *only* game pointer the function dereferences before the
   forwarding call is `[this + 0x3D0]` (Mover). That is a one-hop attack surface.

### Native call signature to use

```c
typedef int32_t (*BotOwner_GoToPoint_t)(
    void*  botOwner,       // RCX
    Vector3* position,     // RDX  (pointer to a 12-byte struct we own)
    uint8_t slowAtTheEnd,  // R8b
    float   reachDist,     // XMM3   -- MUST be >= 0 to skip the Settings chain
    uint8_t getUpWithCheck,// [rsp+0x20]
    uint8_t mustHaveWay,   // [rsp+0x28]
    uint8_t mustGetUp,     // [rsp+0x30]
    uint8_t onlyShortTrie, // [rsp+0x38]
    uint8_t force,         // [rsp+0x40]
    void*   methodInfo);   // [rsp+0x48]  -- NULL is proven safe
```

Return is `NavMeshPathStatus`: `0 = Complete`, `1 = Partial`, `2 = Invalid`.
**This means path validation is free** — we do not need `NavMesh.CalculatePath` or
`NavMesh.SamplePosition` interop at all. Issue the command, read the status, and
report back whether the point was reachable.

### The bail path is a managed throw — so pre-flight the whole chain

`BotMover::GoToPoint` @0x1A2EE00 dereferences, in order:

```
[mover + 0x80]  _moverStateMachine        -> null: throw
[msm   + 0x20]  _states (Dictionary)      -> null: throw
Dictionary::get_Item(_states, EBotMoverState 1)  -> null result: throw
[state + 0x20]                            -> null: throw
```

Every bail goes to `call 0x1805D2530; int3` — the managed NullReference throw
helper. An IL2CPP managed throw unwinding out through our native frame is exactly
what we must not provoke, so **every one of those hops is checked with
`aowl_is_readable` before the call is made**, and the call itself sits inside the
outer `aowl_p_p_seh`. The dictionary lookup result cannot be statically proven, so
we additionally require the bot to have been observed *already moving* at least
once (its `PreviousPosition` has changed between samples), which empirically proves
the mover state machine is populated. Doctrine: make the client tell you.

### Other directly-callable commands (all verified)

| RVA | Signature | Prologue (16) | Notes |
|---|---|---|---|
| 0x81CB40 | `BotOwner::GoToPoint(Vector3*, bool, float, bool×5)` | `48 83 EC 68 0F 57 C0 0F 2F C3 76 20 48 8B 41 68` | the primary |
| 0x81C970 | `BotOwner::StopMove()` | `48 83 EC 28 48 8B 81 D0 03 00 00 48 85 C0 74 30` | derefs Mover, sets `IsMoving=0` |
| 0x81C9C0 | `BotOwner::SetTargetMoveSpeed(float)` | `48 83 EC 28 48 8B 81 D0 03 00 00 48 85 C0 74 0D` | RCX=this, XMM1=speed; Mover only |
| 0x814D10 | `BotOwner::Sprint(bool, bool)` | `48 89 5C 24 10 48 89 6C 24 18 56 48 83 EC 20 80` | RCX,DL,R8b; has an il2cpp class-init guard |
| 0x81CAE0 | `BotOwner::GoToByWay(Vector3[] way, float reachDist)` | — | needs a **managed** `Vector3[]`; see caveat below |
| 0x1A2D600 | `BotMover::Stop()` | `48 83 EC 28 48 8B 81 80 00 00 00 C6 81 38 01 00` | mover-level |
| 0x1A2DFD0 | `BotMover::GoToPoint(CustomNavigationPoint, bool, bool)` | — | needs a managed nav-point object |

**ABI trap worth recording:** `BotOwner::get_Position()` @0x80FEE0 returns a
`Vector3` **by hidden pointer** — `RCX` is the return buffer and `RDX` is `this`
(`mov rax,[rdx+0x418]`). Any 12-byte-returning method is shaped this way. We avoid
it entirely and read position from `Player.MovementContext(+0x60).PreviousPosition(+0x370)`,
which needs no call at all.

## 4. Waypoints in the map data we serve — a NEGATIVE result

`LocationBase` as we serve it (see `mods/tarkov/emu/raid.nim`,
`tuneOfflineSpawns` / `post1LocationsTuned`) contains **no patrol graph**. Checked
every key of `locations.bigmap.base` (100 keys): the only nav-adjacent members are
`SpawnPointParams`, `OpenZones`, `MaxBotPerZone`, `MinDistToFreePoint`,
`MaxDistToFreePoint`, `MinDistToExitPoint`. There is no `PatrolWay`, no
`PatrolPoint`, no path list.

That is expected: `PatrolWay` / `PatrolPoint` are **Unity scene components baked
into the map bundle**, discovered client-side by `BotSpawner._zonesPatrols`
(`Dictionary<PatrolPoint,BotZone>` @ +0x30). They are never server data, so there
is no cheap server-side patrol source to lift.

**But `SpawnPointParams` is a perfectly good server-side waypoint source**, and it
is the cheap option the task was looking for. Each entry is a real, navmesh-valid
world position with a zone name:

```json
{"BotZoneName": "ZoneFactorySide", "Categories": ["Player","Bot"],
 "CorePointId": 2, "Id": "01a445b0-...", "Sides": ["Savage"],
 "Position": {"x": 569.0529, "y": 1.46199012, "z": -54.5297432}, ...}
```

Counts: Customs 318, Factory 160, Ground Zero 57. Filtering to
`Categories contains "Bot"` gives a named waypoint set per map, for free, from data
we already serve — no client-side path synthesis required.

## 5. Spawn-side lever (already in use by `botcap`)

`EFT.BotSpawner` (type 6539): `_bots`(`BotsList`)@0x18, `_allBotZones`@0x20,
`_zonesPatrols`@0x30, `_allPlayers`(`List<Player>`)@0x48, `_allBotsCount`@0x70,
`OnBotCreated`(`Action<BotOwner>`)@0xA8, `OnBotRemoved`@0xB0, `MaxBots`@0xC0,
`Groups`@0xC8. `AddPlayer(Player)` @0x2563AE0 is the existing detour point;
`MaxBots`@0xC0 reproduces exactly.

---

# What was built on top of this

Flag: **`botNav`** in `aowlspt-host.json`, **default `false`**, with a `"//botNav"`
doc key (written by `tools/aowl.nim`'s config stager) and a row on the in-game
settings page. Unlike `botDiag` this feature CALLS INTO and WRITES TO live game
objects, which is why it is opt-in and why it switches itself off after eight
trapped faults.

## The one hook: kind 15 on `EFT.BotOwner::UpdateManual` @0x81B7C0

```
prologue (16): 40 53 48 81 EC A0 00 00 00 80 3D 08 CF 89 06 00
  40 53                push rbx
  48 81 EC A0 00 00 00 sub  rsp, 0xA0
  80 3D 08 CF 89 06 00 cmp  byte [rip+0x689CF08], 0    ; disp32 pins the build
  48 8B D9             mov  rbx, rcx                   ; RCX = the BotOwner
```

`BotsList::UpdateByUnity` (0x1BD6510) is its only caller, so this runs once per
LIVE bot per FRAME, on the Unity main thread, only in a raid, with the BotOwner
in RCX. One hook is therefore both halves of the feature:

* **the census** — every bot announces itself every frame, so nothing walks
  `GameWorld.RegisteredPlayers` and nothing has to resolve a `Player` back to its
  `BotOwner` (genuinely ambiguous — see the `IAIData` note above);
* **the service tick** — a bot's pending command is issued while that bot's own
  Update runs, so no pointer is ever held across frames.

**The prologue snapshot — ADOPTED.** `aowl_botnav_verify` compares against
`aowl_pro_verify` (`abi/aowlspt_prologue.h`), i.e. against the ORIGINAL bytes
snapshotted before any feature bound, not against live memory. The VirtualQuery
gate still runs first and the 16-byte compare is still exact; it simply cannot
self-reject because some other feature detoured the target first. All four RVAs
(`UpdateManual`, `GoToPoint`, `StopMove`, `SetTargetMoveSpeed`) are also primed
eagerly by `aowl_pro_prime_all` at host startup.

Nothing here is currently exposed to that trap — `UpdateManual` is detoured by
nothing else, and `GoToPoint` / `StopMove` / `SetTargetMoveSpeed` are call
targets that are never detoured at all — but that is a property of today's
feature set, not a guarantee, and it is exactly the sort of thing that stops
being true quietly.

**Hook contention: none.** Nothing else in this host detours `UpdateManual`
(kinds 0-14 are all elsewhere; the closest neighbour is `botai`, kind 12, on
`PreActivate`). Anything that later wants `UpdateManual` must register as a RIDER
on kind 15 — the `debugui`/`modetext` slot-aliasing pattern — never re-detour it,
because a second detour overwrites the first's trampoline.

## Files

| File | What |
|---|---|
| `abi/aowlspt_botnav.h` | offsets, the verified target table, guarded readers, and the three direct-call thunks |
| `host/Aowlspt.Host.Il2Cpp/botnav.nim` | registry, command grammar, service tick (`include`d into `aowlhost.nim`) |
| `host/common/modcontrol.nim` | `parseBotNav` (intake gate), `reportBotNav` + census on `reportPath` |
| `mods/manager/mgr/control.nim` | `aowlspt.bot.nav` intake, `aowlspt.bot.census` emit |
| `mods/manager/mgr/clientreport.nim` | census ingest off the poll's query string |
| `aowl/src/aowlspt/botnav.nim` | the mod-facing API |

## Wire

Commands out and the registry back both ride the **existing** `modSyncMs` poll
against `backendPort`. No new endpoint, no new socket, no new thread.

```
mod --sendBotTo--> aowlspt.bot.nav --> manager
  manager --> GET /aowlspt/mods/client/<hostver>  {"botNav":"7|213.500|1.400|-58.200|2.000|1|30000"}
    host (Unity thread) --> EFT.BotOwner::GoToPoint(&Vector3, ...)

host --> GET /aowlspt/mods/client/<hostver>?bn=<census>  --> manager
  manager --broadcast--> aowlspt.bot.census --> mod's onBotCensus
```

The command set is a flat scalar, not a JSON array, deliberately: it rides
`pathGet` verbatim like `menuModeText`, and its length and charset are gated in
exactly one place (`parseBotNav`) before the grammar ever sees it, which is then
gated again per field before anything reaches a game pointer.

Census record, `!`-separated: `id,role,difficulty,alive,x,y,z,lastNavStatus`,
coordinates in whole metres.

**The census is partial and rotates**, and this is a real constraint rather than
a shortcut. `ReportMaxPath` is **191 characters for the whole path** — the
overlay's sync worker copies it into a 192-byte field and truncates silently past
that — which cannot hold a full registry. Each census therefore carries the bots
that fit (about five), starting where the last one stopped, and cycles through
the rest on later polls. Rotation rather than priority, exactly as the mod-outcome
rows do it, so no bot is starved and nothing has to be acknowledged: each record
is a state and repeating it is free. Consumers must accumulate across censuses
keyed on `id` — a bot absent from one payload has not left the raid. If the mod
rows have already eaten the budget the census is dropped whole for that poll
rather than truncated.

## Safety, concretely

* **One** `aowl_p_p_seh` for the whole per-bot tick. No inner guard anywhere —
  that guard is not re-entrant and a nested one would disarm the outer on return.
* Every pointer `BotMover::GoToPoint` would dereference before its first possible
  bail is VirtualQuery-walked first (`aowl_botnav_can_command`), so the managed
  NullReference throw helper at 0x1805D2530 is unreachable.
* The one hop that cannot be proven statically — the `Dictionary` lookup for
  `EBotMoverState 1` — is covered empirically: a bot is only commandable once it
  has been **observed moving**, which is proof its mover state machine is live.
* `reachDist` is forced `>= 0.25`, so the `Settings` pointer chain is never
  walked and `[this+0x3D0]` is the only game deref on the call path.
* Commands re-issue on a **500 ms** throttle, never per frame: `GoToPoint` runs
  `CalcPath` and allocates a managed path.
* A `NavMeshPathStatus` of `2` (Invalid) drops the command instead of spinning.
* Fixed-size registry (48 bots), so the per-frame path allocates nothing.
* Self-disables after 8 trapped faults, and says so in the log.
* Never suppresses the original `UpdateManual` — that is the bot's entire brain.

## How to see a bot move under our command

1. Set `"botNav": true` in `aowlspt-host.json` (and `"botAiActivate": true`, so
   the bots actually activate).
2. Start an offline raid with bots and let them walk around for a few seconds —
   a bot is not commandable until it has been seen moving.
3. Read `aowlspt-host.log` for `botnav (bot navigation API) armed on
   EFT.BotOwner::UpdateManual` and for the byte-verify line naming all three call
   targets.
4. `GET /aowlspt/mods/clientreport` and read `botNav` for the live census; pick
   a bot's `id` and a destination (a `SpawnPointParams.Position` from the map is
   a known-navmesh-valid choice).
5. Issue the command from a mod (`sendBotTo(id, x, y, z, reach = 2.0,
   holdMs = 30000)`), or by publishing `botNav` on the client-set body.
6. The log prints `botnav: bot id=N GoToPoint(x, y, z) -> Complete` and the
   bot's `x/y/z` in successive censuses move toward the point.

**Unverified.** None of the above has been run against the live game — the recon
is static (offline binary + metadata) and the build is compile-verified only.
What is proven is the disassembly, the ABI, the offsets, the byte-verified
prologues, and that the whole tree builds. What is **not** proven is any
end-to-end behaviour: whether `UpdateManual` fires as expected under our detour,
whether the pre-flight admits real bots, and above all whether a re-issued
command holds a bot against its own brain for useful stretches or merely nudges
it. Treat the first live test as an experiment, not a confirmation.

## A note on finding build errors in this host

`aowl.exe build` buffers its **entire** output until it exits — through
PowerShell redirection, `Out-File`, `Tee-Object` and a bash pipe alike. The host
is the second of six stages, so a compile error there stays invisible for the
half hour the remaining stages take, and killing the build loses the buffer
rather than flushing it.

The fast path is to invoke nimony directly with the exact flags
`buildIl2CppHost` uses, from PowerShell, in the host directory:

```powershell
$R="<worktree>"; $N="$env:USERPROFILE\nimony"
cd "$R\host\Aowlspt.Host.Il2Cpp"
& "$N\bin\nimony.exe" c --app:lib "--passC:-I$R\abi" `
  "-p:$R\aowl\src" "-p:$R\installer\src" "-p:$R\host\common" `
  "-p:$R\host\Aowlspt.Overlay" "-p:$R\host\Aowlspt.Graphics" `
  "-o:$R\host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll" `
  "$R\host\Aowlspt.Host.Il2Cpp\aowlhost.nim"
```

It prints errors immediately. The standing warning that hand-invoking nimony
"silently exits 0 producing NOTHING" is about it not *placing* the DLL (that is
`placeLibrary`'s job — the artifact is left in `nimcache/<hash>/aowlhost.dll`),
not about diagnostics. Use it to find the error, then run the real
`aowl.exe build` to produce the shipped binary.

Two things this build tripped over that are worth knowing before writing more
host code:

* **nimony requires definite initialisation.** `var v: array[3, float64]` whose
  address is handed to a C function that fills it is an error — "the callee
  writes it" is not a proof nimony accepts. Initialise explicitly.
* **`$` does not apply to floats here.** Use `formatFloat(v, ffDecimal, 2)`,
  which is what `botdiag.nim` already does for a Vector3.
* A new `abi/*.h` needs its own `{.emit: """#include "..." """.}` in
  `aowlhost.nim`'s header block, or every `importc ... nodecl` from it fails at
  C codegen as an implicit declaration.

## 6. What is NOT reachable (honest limits)

* **Behaviour tuning (SAIN-style) is not reachable this way.** The decision layer
  is `BotOwner.Brain` (`StandartBotBrain` @+0x80), `DecisionProxy` @+0x48 and
  `DecisionQueue` @+0x3A0 — a layered node graph. Directing it needs either
  replacing brain layers (managed subclassing, impossible without reflection) or
  detouring the per-decision dispatch. Neither is in scope here.
* **A nav command is advisory, not authoritative.** The brain re-evaluates its goal
  every tick and will re-target the mover. A single `GoToPoint` call is typically
  overridden within a frame or two. Holding a bot on our destination therefore
  requires *re-issuing* the command on a cadence. It must **not** be re-issued per
  frame — `GoToPoint` runs `CalcPath` and allocates a managed path, and per-frame
  managed allocation has already crashed us once. Re-issue on a throttle and stop
  when `BotMover.SDistDestination` (+0x148) is small.
* **`GoToByWay`** would give true multi-waypoint routes, but its first argument is
  a **managed `Vector3[]`**. Building one needs `il2cpp_array_new` with a resolved
  `Il2CppClass*` for `Vector3[]`, which the reflection ban makes awkward. Multi-hop
  routes are therefore better done as a host-side sequence of single `GoToPoint`
  calls, advancing when `SDistDestination` drops below the reach distance.
