# Starting an offline raid natively (no menu UI)

Offline, static analysis only. The game was not run and nothing was deployed.

**Instruments.** `tools/il2cpp_resolve.py` (verbs `find` / `type` / `bytes` /
`shared`), `tools/fldoff.py` (`fields`, String self-check PASSED:
`_stringLength@0x10`, `_firstChar@0x14`), and a scratch capstone disassembler
over `Resolver.code_bytes` with an RVA→method-name map built from every image's
`methodPointers`. Inputs: `D:/Games/Tarkov/GameAssembly.dll`,
`.cache/global-metadata.dec.dat`. All addresses are **RVAs** (imagebase
`0x180000000`); runtime = `GameAssemblyBase + RVA`.

Everything labelled *measured* was read out of the binary/metadata in this pass.
Everything else is labelled *inferred*.

---

## 1. The call chain (measured)

```
[UI]  MatchmakerOperation::ShowMatchmakerSideSelection      0xA2E100  unique
        -> ShowMatchmakerLocationSelection                  0xA31480  unique
        -> ShowMatchmakerOfflineRaidScreen                  0xA30F80  unique
        -> ShowMatchmakerAcceptScreen / InsuranceScreen
        -> MatchmakerOperation::OnReadyPressed              0xA312E0  unique
             fires event MatchmakerOperation.OnReadyToStartMatching (@+0x38)
[APP] TarkovApplication::<MainMenu>g__OnReadyToStartMatching|191_1  0x988A10 unique
        -> TarkovApplication::OnReadyToStartMatchingAsync   0x983830  unique
             (state machine <OnReadyToStartMatchingAsync>d__195::MoveNext 0x9CC7B0)
             *** THE BRANCH ***
        -> TarkovApplication::LocalGameMatching             0x984170  unique
             (state machine <LocalGameMatching>d__199::MoveNext 0x9C3810)
             -> ShowTimeHasComeScreen 0x982C50
             -> LoadMapAndData        0x984620
             -> ObjectsFactory::LoadBundlesAndCreatePools
             -> GamePrepare           0x9848B0
             -> LocalGameCreate       0x986330   <- LocalGame instance is built here
```

`TarkovApplication::InternalStartGame(string gameMap, bool isLocalGame, bool
isBotEnabled)` @ `0x978150` (unique) exists and is tempting, but **it is not on
this path** — nothing in the matchmaker chain calls it (measured: it does not
appear in the MoveNext disassembly of either state machine). It is the
dev/command-line entry. Not recommended without a separate study.

### The offline switch, measured byte-for-byte

In `<OnReadyToStartMatchingAsync>d__195::MoveNext`:

```
009ccb81  inc   dword ptr [rbx + 0x1e4]      ; TarkovApplication.CurrentTotalRaidNum++
009ccb87  mov   rax, qword ptr [rbx + 0xd8]  ; this->_raidSettings
009ccb97  cmp   dword ptr [rax + 0x44], 1    ; RaidSettings.RaidMode == ERaidMode.Local
009ccb9b  je    0x9cccc0                     ; -> LOCAL branch
...       (fallthrough)                      ; -> NetworkGameMatching 0x984360
009cccc9  movups xmm0, [rax + 0x50]          ; copy RaidSettings.TimeAndWeatherSettings
009cccf0  lea   rdx, [rsp + 0x70]            ; arg1 = &TimeAndWeatherSettings (28-byte struct, byref)
009cccf5  mov   rcx, rbx                     ; this
009cccea  xor   r9d, r9d                     ; MethodInfo* = NULL
009ccced  xor   r8d, r8d                     ; inTransition = false
009cccf8  call  0x984170                     ; LocalGameMatching
```

**`RaidSettings.RaidMode == ERaidMode.Local (1)` is the whole offline gate**, not
`IsPveOffline`. This matches the reported symptom (fact #263/#246): with RaidMode
left at `Online (0)` the client runs `NetworkGameMatching` and the load is
cancelled.

Also measured here: the game itself passes **`MethodInfo* = NULL`** to
`LocalGameMatching`, so a NULL trailing arg is correct — no shared generic
involved.

---

## 2. The target method

**Call `EFT.TarkovApplication::OnReadyToStartMatchingAsync()`.**

| | |
|---|---|
| RVA | `0x983830` |
| VA | `0x180983830` |
| Section | `il2cpp` (generated code) |
| Sharedness | **UNIQUE**, owners = 1 (`il2cpp_resolve.py shared 0x983830`) |
| Signature (derived from metadata, rid 50674) | `System.Threading.Tasks.Task OnReadyToStartMatchingAsync()` — **instance, zero declared parameters** |
| Native frame | `RCX = TarkovApplication*`, `RDX = const MethodInfo*` (may be NULL) |
| Prologue (16 bytes) | `40 53 48 83 EC 70 80 3D 0A 57 73 06 00 48 8B D9` |
| Thunk shape | real body (`push rbx; sub rsp,0x70; cmp cctor-flag; mov rbx,rcx`) — **not** the `C2 00 00` universal empty stub |

It is `async`, so it returns a `Task` immediately and the work continues over
subsequent frames. Call it **from the Unity main thread** (the
`TarkovApplication::Update` bridge @ `0x977B10`) — it touches UI and the job
scheduler.

Smaller alternative if you want to skip the branch entirely:
`LocalGameMatching` @ `0x984170` (unique, prologue
`48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 55`), frame
`RCX=this, RDX=&TimeAndWeatherSettings(28 bytes), R8=inTransition(bool),
R9=MethodInfo*(NULL)`. Not preferred: it skips the `JobScheduler::SetForceMode`
and raid-counter setup that `OnReadyToStartMatchingAsync` does first.

---

## 3. Argument construction plan

`OnReadyToStartMatchingAsync` takes no arguments. Everything comes out of state
we must set first. All offsets below are **measured** via `fldoff.py`, and the
three marked ✓ are independently confirmed by the compiled accessor bytes.

### 3.1 `TarkovApplication` (type 7933)

| Field | Offset | Note |
|---|---|---|
| `_raidSettings` | `0xD8` ✓ | `get_CurrentRaidSettings@0x691340` is literally `48 8B 81 D8 00 00 00 C3` |
| `_localMatchmakerOperation` | `0x100` | |
| `_menuOperation` | `0x128` | only the ONLINE branch reads it |
| `<CurrentTotalRaidNum>` | `0x1E4` | incremented by the method itself |

The instance is a `MonoBehaviourSingleton`; the host already reaches it (the
`Update` bridge at `0x977B10` is `TarkovApplication::Update`, so `RCX` there is
the instance). *Walk from that, do not re-derive a singleton pointer.*

### 3.2 `EFT.RaidSettings` (type 6557) — what we must write

| Field | Offset | Value for "offline Woods, PMC" |
|---|---|---|
| `<Side>k__BackingField` | `0x20` ✓ (`set_Side@0x6D7FE0` = `89 51 20 C3`) | `ESideType.Pmc = 0` |
| `LocationId` (string) | `0x30` | `"Woods"` via `il2cpp_string_new` |
| `<RaidMode>k__BackingField` | `0x44` ✓ (`set_RaidMode@0x6D8720` = `89 51 44 C3`) | `ERaidMode.Local = 1` |
| `SelectedDateTime` | `0x40` | enum `EDateTime` (type not resolvable by that name; enumerate before writing) |
| `TimeAndWeatherSettings` | `0x50`, 28 bytes inline | already valid from the ctor; leave alone |
| `BotSettings` | `0x70` | set by `.ctor()`; leave alone |
| `WavesSettings` | `0x88` | set by `.ctor()`; leave alone |
| `IsPveOffline` | `0xA0` | **not** the offline gate; do not rely on it |
| `_selectedLocation` | `0xA8` | **the hard one — see below** |
| `_locationSettings` | `0xB0` | `JsonType.LocationSettings`, INITONLY, source of Locations |

Enums (measured, `fldoff.py enum`): `ERaidMode {Online=0, Local=1, Coop=2,
Narrate=3}`; `ESideType {Pmc=0, Savage=1, Random=2}`;
`EPlayersSpawnPlace {SamePlace=0, DifferentPlaces=1, AtTheEndsOfTheMap=2}`.

The two enum writes are plain 4-byte stores (the setters prove it) — no call
needed, but read-validate-then-write.

### 3.3 `_selectedLocation` MUST already be a real `Location` — measured

`<LocalGameMatching>d__199::MoveNext`:

```
009c3e8a  mov rdi, [r14 + 0xd8]           ; _raidSettings
009c3eaf  cmp qword ptr [rdi + 0xa8], 0   ; _selectedLocation
009c3eb7  je  0x9c3eed                    ; skip refinement if null
009c3ed3  mov rcx, [rdi + 0xa8]
009c3eda  call JsonType.LocationLevelVariants::ResolveByPlayerLevel
009c3ee8  call EFT.RaidSettings::set_SelectedLocation   ; 0x6D7FF0
```

`LocalGameMatching` only *refines* an already-chosen `Location`; it never
resolves `LocationId` → `Location`. If `_selectedLocation` is null the map load
later has nothing to load. So we must supply it.

Source: `RaidSettings._locationSettings@0xB0` →
`JsonType.LocationSettings.locations@0x10`, a
`Dictionary<string, JsonType.Location>` (measured).

Two ways to get `locations["Woods"]`:

* **Preferred — walk the Dictionary's `entries` array by raw offsets** and
  compare the key string in place. Avoids calling `Dictionary<K,V>::TryGetValue`,
  which IS a shared generic and therefore needs a real `MethodInfo*` we cannot
  fabricate. Cost: the `Dictionary<string,Location>` instantiated layout is
  **not reachable offline** (all `Il2CppGenericClass.cached_class` are null in
  the file), so the entries-array offset has to be borrowed from a live object
  or a verified header.
* Assign with **`RaidSettings::set_SelectedLocation` @ `0x6D7FF0`** (unique;
  prologue `8B 05 4A E5 9D 06 4C 8D 15 23 11 A0 06 48 89 91`). Frame:
  `RCX=raidSettings, RDX=Location*, R8=MethodInfo*(NULL)`. **Do not raw-write
  this field** — the compiled setter contains a GC write barrier; a bare pointer
  store can be collected out from under the raid.

### 3.4 `MatchmakerOperation.MatchmakerPlayersController` must be non-null — measured

```
009c3ff6  call TarkovApplication::get_MatchmakerOperation  ; 0x977360
009c3ffb  test rax, rax / je -> NRE throw
009c4004  mov  rcx, [rax + 0xa0]     ; <MatchmakerPlayersController>k__BackingField
009c400b  test rcx, rcx / je -> NRE throw
009c4022  call MatchmakerPlayersController::SetMatchingAbortAvailability
```

Both are hard null checks that jump to the NRE throw helper. If
`MatchmakerOperation@+0xA0` is null, `LocalGameMatching` throws inside the async
state machine and the raid silently never starts.

Good news, also measured: `get_MatchmakerOperation@0x977360` (unique) is
**self-healing** — if `_menuOperation@0x128` is null (or its `+0x118` is), it
constructs an `OfflineInventoryController` + `MatchmakerOperation` from the
backend session and stores it at `+0x100`. What it does **not** do is populate
`+0xA0`; that is set by `set_MatchmakerPlayersController@0x691060` from the
matchmaker screens.

So the sequence must be either (a) let the UI get as far as side-select once
(which is exactly where our automation already reaches), or (b) call
`MatchmakerOperation::ShowMatchmakerSideSelection()` @ `0xA2E100` (unique,
prologue `40 53 48 83 EC 70 80 3D 5E B1 68 06 00 48 8B D9`; frame
`RCX=matchmakerOperation, RDX=MethodInfo*`) and wait frames for its async body
before firing `OnReadyToStartMatchingAsync`.

Confirmed on the same path: `MatchmakerOperation._raidSettings@0x40` is the same
object the ready check reads (`OnReadyPressed` @`0xA312E0` does
`mov rax,[rbx+0x40]; cmp dword [rax+0x44],2` — RaidMode again, and
`cmp dword [rax+0x20],0` — Side). Set the fields on whichever of
`TarkovApplication._raidSettings` / `MatchmakerOperation._raidSettings` you
verify are the same pointer; they should be, but check.

---

## 4. Sharedness verdicts (all from `il2cpp_resolve.py ... shared`)

| Method | RVA | Verdict |
|---|---|---|
| `TarkovApplication::OnReadyToStartMatchingAsync` | `0x983830` | UNIQUE (1) |
| `TarkovApplication::LocalGameMatching` | `0x984170` | UNIQUE (1) |
| `TarkovApplication::NetworkGameMatching` | `0x984360` | UNIQUE (1) |
| `TarkovApplication::LocalGameCreate` | `0x986330` | UNIQUE (1) |
| `TarkovApplication::InternalStartGame` | `0x978150` | UNIQUE (1) |
| `TarkovApplication::get_MatchmakerOperation` | `0x977360` | UNIQUE (1) |
| `TarkovApplication::<MainMenu>g__OnReadyToStartMatching\|191_1` | `0x988A10` | UNIQUE (1) |
| `MatchmakerOperation::ShowMatchmakerSideSelection` | `0xA2E100` | UNIQUE (1) |
| `MatchmakerOperation::ShowMatchmakerOfflineRaidScreen` | `0xA30F80` | UNIQUE (1) |
| `MatchmakerOperation::OnReadyPressed` | `0xA312E0` | UNIQUE (1) |
| `RaidSettings::set_SelectedLocation` | `0x6D7FF0` | UNIQUE (1) |
| `<OnReadyToStartMatchingAsync>d__195::MoveNext` | `0x9CC7B0` | UNIQUE (1) |
| `<LocalGameMatching>d__199::MoveNext` | `0x9C3810` | UNIQUE (1) |
| `TarkovApplication::get_CurrentRaidSettings` | `0x691340` | **SHARED (36)** — safe to *call*, never detour |
| `RaidSettings::set_RaidMode` | `0x6D8720` | **SHARED (12)** — trivial `mov [rcx+0x44],edx` |
| `RaidSettings::set_Side` | `0x6D7FE0` | **SHARED (67)** — trivial `mov [rcx+0x20],edx` |

None of the unique targets matched the universal empty-body stub (`C2 00 00`).

---

## 5. Feasibility verdict

**INCONCLUSIVE, leaning PASS.**

What is settled offline (measured):

* the exact method to call, its RVA, that it is unique, that it has a real body,
  its 16 prologue bytes, and that it takes no arguments;
* that the offline/online decision is one comparison, `RaidSettings@+0x44 == 1`;
* that the game itself passes a NULL `MethodInfo*` into the local branch, so no
  shared-generic problem applies to the call we want to make;
* that `_selectedLocation@+0xA8` and `MatchmakerOperation@+0xA0` are hard
  prerequisites, with the exact instructions that prove it.

What is **not** settled offline, and the experiment that settles each:

1. **Is `TarkovApplication._raidSettings@0xD8` non-null at the main menu, and is
   `_locationSettings@0xB0` populated there?**
   Experiment: live inspector, read `$app @0xd8` then `@0xb0` as `ptr` at the
   main menu, before pressing anything. Read-only, one batch.
2. **The `Dictionary<string, Location>` instantiated layout.** Not reachable
   offline (every `cached_class` in the file is null). Experiment: on the live
   dictionary at `_locationSettings+0x10`, dump 0x40 bytes and identify the
   `entries`/`count` pair against a known key.
3. **Is `MatchmakerOperation@+0xA0` already non-null at the point our automation
   currently stalls (the SELECT YOUR CHARACTER / PVE ZONE screen)?** If yes, the
   whole side-select screen can be skipped by just writing RaidSettings and
   calling `0x983830`. Experiment: at that stalled screen, read
   `$app @0x100 @0xa0` (and `$app @0x128`) as `ptr`. This is the single highest-
   value measurement in this document — it decides whether we need step (b) of
   §3.4 at all.
4. **Whether the profile/side selection the stuck screen performs writes
   anything else** (e.g. which profile `GetProfileForLocalGame@0x986130` returns).
   Not analysed. Experiment: read `_raidSettings` field-by-field on a session
   that reached the raid through the UI, and diff against a session that did not.

I would not ship a call to `0x983830` before measurement 1 and 3. Everything
else can be built behind a default-OFF flag in the meantime.

---

## 6. Calling notes

* **Hidden trailing `const MethodInfo*` applies to every call here.**
  `OnReadyToStartMatchingAsync`: `RCX=this`, `RDX=MethodInfo*`.
  `set_SelectedLocation`: `RCX=this`, `RDX=Location*`, `R8=MethodInfo*`.
  `LocalGameMatching`: `RCX=this`, `RDX=&TimeAndWeather`, `R8=inTransition`,
  `R9=MethodInfo*`.
* **NULL `MethodInfo*` is correct here** — measured directly from the game's own
  call site (`xor r9d,r9d` before `call 0x984170`). No shared generic is on this
  path. The one place a shared generic *would* bite is
  `Dictionary<string,Location>::TryGetValue`; §3.3 avoids it by walking.
* **Byte-verify all 16 prologue bytes against the startup snapshot** before any
  call, per the standing rule. The prologue tables above are from
  `GameAssembly.dll` on disk, so they are the pre-patch truth.
* Run on the Unity main thread via the `Update` bridge; one `aowl_p_p_seh`
  around the whole body; flag-gated default OFF; self-disable after N faults.
