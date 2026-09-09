# The post-1.0 Tarkov client boot flow — complete offline map

Build: `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes, 2026-08-12),
decrypted metadata `.cache/global-metadata.dec.dat` (27,776,072 bytes) — the
same pair `docs/SETTINGS-UI-MAP.md` was measured against.
Imagebase `0x180000000`; every address is an **RVA** unless written `VA`.
Runtime address = `GameAssemblyBase + RVA`.

**Instrument for every MEASURED line, unless stated otherwise:**

```
python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat <verb> ...
```

abbreviated below as `R <verb>`. Verbs used: `find`, `fields`, `member`,
`typemethods`, `genericmethods`, `disasm`, `callers`, `shared`, `symbolize`,
`bytes`. Two facts came from a one-off python scan of the PE (a rip-relative
`lea` / 8-byte-VA search over the `il2cpp` and `.text` sections); those are
tagged **MEASURED (PE scan)** and the scan is described inline.

Every statement is tagged **MEASURED**, **MEASURED-BY-USE** (read off the
disassembly of a body rather than off a table), **INFERRED**, or
**UNKNOWN — needs a live read**. §8 lists the open questions and names the exact
pointer or verb each one needs.

This map exists so that two features can be implemented in ONE attempt:

* **F1** — run the aowlspt mod load as a native step *of the game's own loading
  flow*, synchronous with the game, using the game's own loading screen and
  caption.
* **F2** — skip the character/mode selection screen with **no frame of UI**.

The headline result is in §6: **F1 and F2 are the same hook.** The game already
contains a no-UI character-selection bypass,
`TarkovApplication::TryCreateInRaidCharacterSelection`, and the point at which
that bypass is consulted is also the only point in the boot where the flow parks
indefinitely while still rendering. That is the one place a native step can be
*synchronous with the game* without freezing the Unity main thread.

---

## 1. The boot state machine

### 1.1 The class chain

MEASURED `R typemethods` on each:

```
EFT.AbstractApplication
  |- EFT.ClientApplication`1        (generic; bodies via `R genericmethods`)
       |- EFT.CommonClientApplication`1
            |- EFT.TarkovApplication   type 7933, Assembly-CSharp.dll, 174 declared methods
```

MEASURED: every method on `ClientApplication`1` and `CommonClientApplication`1`
reports `RVA=- sharedness=NO-CODE` from `typemethods` — they are uninstantiated
generic definitions. Their real bodies are one instantiation each, reachable
with `R genericmethods` (self-check block passes: `genericMethodPointers
count=206077`, `0 of 206826` rows out of range, negative control
`System.String::get_Length` yields `0` rows).

| Method | body RVA | note |
|---|---|---|
| `ClientApplication`1::Awake()` | `0x3cab720` | generic body, 1 instantiation |
| `ClientApplication`1::Start()` | `0x3cab770` | generic body |
| `ClientApplication`1::StartTask()` | `0x3cab830` | generic body |
| `ClientApplication`1::Init(IAssetsManager, InputTree)` | `0x3cabad0` | generic body |
| `CommonClientApplication`1::Awake()` | `0x3cbdc20` | generic body |
| `CommonClientApplication`1::StartTask()` | `0x3cbe420` | generic body |
| `CommonClientApplication`1::RunFilesChecking(...)` | `0x3cbebc0` | generic body |
| `TarkovApplication::StartTask()` | `0x977880` | UNIQUE, `FAMILY|VIRTUAL` |
| `TarkovApplication::Update()` | `0x977B10` | UNIQUE — the host's bridge |
| `TarkovApplication::Init(IAssetsManager, InputTree)` | `0x978540` | UNIQUE |

**A generic body is NOT in the per-image `methodPointers` histogram**, so
`R shared <that RVA>` answers `unknown`. That is a refusal, not "unshared".
Do not detour a generic body on the strength of an `unknown` verdict.

### 1.2 `Start()` is a two-line kickoff

MEASURED `R disasm 0x3cab770`:

```
mov rax,[rdx+0x1e8] ; mov rdx,[rdx+0x1f0] ; call rax      <- virtual StartTask()
...
jmp System.Threading.Tasks.Task::ContinueWith(...)  @0x46142a0
```

Unity's `Start` calls the virtual `StartTask()` through the `Il2CppClass` vtable
(slot pair `{methodPtr@+0x1e8, MethodInfo*@+0x1f0}`) and attaches a
continuation. **Everything after this point is an async state machine.**

### 1.3 The async chain, outermost first

Each `Task`-returning method compiles to a *kickoff* at the RVA `typemethods`
reports; the body lives in a nested `<Name>d__NN::MoveNext`. MEASURED — the
`d__NN` types are separate metadata types (`R find <Name>` finds them):

| Method | kickoff RVA | state machine | `MoveNext` RVA |
|---|---|---|---|
| `TarkovApplication::StartTask` | `0x977880` | `<StartTask>d__85` (7926) | `0x9def00` |
| `CommonClientApplication`1::StartTask` | `0x3cbe420` | `<StartTask>d__17` (7744) | `0x2fe7d90` (generic body) |
| `ClientApplication`1::StartTask` | `0x3cab830` | `<StartTask>d__14` (7727) | `0x2fe72d0` (generic body) |
| `TarkovApplication::RunInitialLobbyFlow` | `0x97b550` | `<RunInitialLobbyFlow>d__121` (7914) | `0x9d7fb0` |
| `TarkovApplication::RunCharacterSelectionFlow` | `0x97c350` | `<RunCharacterSelectionFlow>d__130` (7912) | `0x9d6bd0` |
| `TarkovApplication::ShowCharacterSelectionScreen` | `0x97c0e0` | `<ShowCharacterSelectionScreen>d__129` (7919) | `0x9daa00` |
| `TarkovApplication::ExecuteCharacterSelection` | `0x97c5e0` | `<ExecuteCharacterSelection>d__131` (7874) | `0x9b6e60` |
| `TarkovApplication::ShowProfileLoadingScreen` | `0x979a10` | `<ShowProfileLoadingScreen>d__108` (7924) | `0x9dd570` |
| `TarkovApplication::MainMenuLoad` | `0x97a380` | `<MainMenuLoad>d__113` (7893) | `0x9c7ac0` |
| `TarkovApplication::InitPreloaderUI` | `0x97a530` | `<InitPreloaderUI>d__114` (7879) | `0x9ba3e0` |
| `TarkovApplication::MainMenu` | `0x983130` | `<MainMenu>d__191` (7892) | `0x9c5c00` |
| `TarkovApplication::LoadCharacterSelectionBootstrap` | `0x97b8d0` | — | — |
| `TarkovApplication::LoadCharacterSelectionData` | `0x97ba70` | — | — |
| `CharacterSelectionScreenController::SubmitAsync` | `0x13f0cc0` | `<SubmitAsync>d__43` (14117) | `0x13f1500` |

**A state machine's field offsets are printed WITH the 0x10 object header, but
the machines are `System.ValueType` and the compiled body addresses them
UNBOXED.** MEASURED-BY-USE: `R fields <SubmitAsync>d__43` reports
`profileData@0x30 / <>4__this@0x38 / gameMode@0x40`, while `R disasm 0x13f1500`
reads `[rdi+0x20]`, `[rdi+0x28]`, `[rdi+0x30]` for exactly those three, and the
kickoff at `0x13f0cc0` writes `[rsp+0x60]`/`[rsp+0x70]` for a machine based at
`rsp+0x40`. **Subtract 0x10 from every `R fields` offset on a `d__NN` type.**
A host that used the table value directly would read the field one slot along —
a plausible number, never a fault.

### 1.4 Stage 1 — `CommonClientApplication`1::StartTask` (`<StartTask>d__17`)

MEASURED `R disasm 0x2fe7d90 --to 0x2fe9ee0`, named callees in body order:

```
RunFilesChecking(ordinaryMode, criticalMode, token)     @0x3cbebc0   <- ConsistencyInfo
DG.Tweening.Core.TweenManager::SetCapacities(...)       @0x27bea40
ClientApplication`1::StartTask()                        @0x3cab830   <- stage 0
ClientApplicationInitOperation::Execute(resetSettings…) @0x9ea410
JsonExtensions::ToPrettyJson / ToJson                   (settings dump)
MonoBehaviourSingleton`1::get_Instance()                @0x33e1a40
PreloaderUI::ShowErrorScreen(header,message,accept)     @0x156b930   <- failure path
UnityEngine.GameObject::AddComponent<T>()               @0x2a9ae90
EFT.UI.UiPools::Init()                                  @0x13a5290
Diz.DependencyManager.DependencyGraph`1::Retain(keys, progress) @0x3e47b40
EFT.EasyAssetsExtensions::WaitForAllBundles(bundles, onFinished, …) @0x253f520
Task::ContinueWith(...)                                 @0x46142a0
```

MEASURED `R disasm 0x2fe72d0 --to 0x2fe7d30` — stage 0 (`ClientApplication`1`)
is settings/cursor/logger only: `UICanvasScalerController::Start` `@0x16bd6c0`,
`InitializeAudioListenerManager` `@0x3cac1d0`, `CursorSwitcher::SetCursor`
`@0x1448a20`, `AbstractLogger::.ctor`, `PrefsUtils::RegisterKeyToReset`.

### 1.5 Stage 2 — `TarkovApplication::StartTask` (`<StartTask>d__85`)

MEASURED `R disasm 0x9def00 --to 0x9df470`:

```
await this.<>n__0()                        @0x987c70   <- base.StartTask (stage 1)
EftScreenManager::get_Instance()           @0x172dc10
ReadyToDepartureEventHandler::.ctor(...)   @0x66ad40
HWEcho::GetMetrics() -> ValueTuple<string,string> @0x1e04200
<interface dispatch, interface slot index 0x47>   (the metrics upload)
Task::ContinueWith(<StartTask>b__85_0)     @0x46142a0
AsyncTaskMethodBuilder::SetResult()        @0x44363e0
```

**CORRECTION TO A TEMPTING MISREADING.** `<StartTask>b__85_0` `@0x987c40` is
*not* a boot-ordering step. MEASURED `R disasm 0x987c40 --to 0x987c70`: it is
five instructions — `rcx = this._menuOperation@0x128`, then
`jmp MainMenuShowOperation::ShowScreen(EMenuType screen=4, bool turnOn=1)` `@0x9f8100`.
MEASURED `R fields EFT.UI.EMenuType`: `4 == Chat` (`MainMenu == 100`,
`Play == 0`). It is the *open-chat* action, adjacent in the body to
`EftScreenManager::InitChatScreen(Action openChatAction)`. Reading `edx=4` as a
boot stage would be a confidently wrong answer.

### 1.6 Stage 3 — the lobby flow: `RunInitialLobbyFlow` (`d__121`)

`R fields <RunInitialLobbyFlow>d__121` (subtract 0x10 for the unboxed body):

| table | unboxed | field |
|---|---|---|
| `0x10` | `0x00` | `<>1__state` int |
| `0x18` | `0x08` | `<>t__builder` |
| `0x30` | `0x20` | `<>4__this` TarkovApplication |
| `0x38` | `0x28` | `<bootstrap>5__2` CharacterSelectionBootstrapResult |
| `0x48` | `0x38` | `<overriddenGameMode>5__3` Nullable\<EGameMode\> |
| `0x50` | `0x40` | `<inRaidResult>5__4` **CharacterSelectionResult** (24 bytes) |
| `0x68` | `0x58` | `<>u__1` TaskAwaiter |
| `0x70` | `0x60` | `<>u__2` TaskAwaiter\<CharacterSelectionBootstrapResult\> |
| `0x78` | `0x68` | `<>u__3` TaskAwaiter\<bool\> |

MEASURED `R fields CharacterSelectionBootstrapResult`:
`<Profiles>k__BackingField@0x10 (CharacterSelectionDataResponse)`,
`<SeasonalPerks>k__BackingField@0x18`.

MEASURED `R disasm 0x9d7fb0 --to 0x9d8940`. In body order (`rsi` = the unboxed
machine, `r12` = `<>4__this`):

```
1  await this.LoadCharacterSelectionBootstrap()                     @0x97b8d0
2  data = bootstrap.Profiles                          (machine field, read as [rsi+0x28])
3  r14b = (data == null) ? false : data.HasOnlyEmptyProfileSlots()  @0xb87f50
4  if (<bool at machine+0x30>) goto the alternate branch @0x9d8a5a
5  if (TryCreateInRaidCharacterSelection(data, out result@machine+0x40))  @0x97bbf0
        -> BYPASS: goto 6b
     else
        await RunCharacterSelectionFlow(
                 rcx = this, rdx = data,
                 r8b = startupFlow: 1,
                 r9  = seasonalPerks,
                 [rsp+0x20] = returnGameMode: Nullable<EGameMode> with no value,
                 [rsp+0x28] = canGoBackToLanguage: r14b,
                 [rsp+0x30] = MethodInfo*: 0)                       @0x97c350
6b await ShowLanguageSelectionIfNeeded(this, data, r8 = 0)          @0x97bd20
7b await ExecuteCharacterSelection(result, startupFlow)             @0x97c5e0
   (a second ExecuteCharacterSelection site at 0x9d8bfc serves the
    Dictionary`2::TryGetValue branch at 0x9d8b2b -> 0x3f86cd0)
```

**Line 5 is the whole of F2.** The game already ships the "select a character
without ever showing the screen" path; the only reason it does not fire on a
normal boot is that no profile is `InRaid`.

`RunInitialLobbyFlow` has **0 direct callers** (MEASURED `R callers 0x97b550`)
and **0 rip-relative `lea` references** (MEASURED (PE scan): a scan of the
`il2cpp` and `.text` sections for `48 8D /r disp32` and `4C 8D /r disp32` whose
computed target equals the RVA found none; the only 8-byte-VA occurrence of
`0x18097b550` in the whole file is its own `methodPointers` slot at file offset
`0x6c52540`). The same is true of `ShowMenuScreen` `@0x978a00`,
`InitPreloaderUI` `@0x97a530`, `LoadLoginScenes` `@0x977f50` and `LoadMainMenu`
`@0x9792f0`. So they are reached through a vtable slot or through a delegate
built from a `MethodInfo*`, and **who calls `RunInitialLobbyFlow`, and when, is
not derivable offline** — see §8 Q1.

### 1.7 Character selection — the object model

`EFT.CharacterSelectionDataResponse` (type 8774) **is a
`Dictionary<EGameMode, CharacterSelectionProfileData>`** — MEASURED
`R typemethods` prints `base class: System.Collections.Generic.Dictionary`2`,
and `R fields` returns the `Dictionary`2` GENERIC-NO-LAYOUT block. Its own
methods:

| Member | RVA | sharedness |
|---|---|---|
| `.ctor()` | `0xb87ed0` | UNIQUE |
| `bool HasOnlyEmptyProfileSlots()` | `0xb87f50` | UNIQUE |
| `bool TryGetInRaidProfile(out EGameMode, out CharacterSelectionProfileData)` | `0xb881a0` | UNIQUE |
| `CharacterSelectionDataResponse BuildCharacterSelectionMockData()` | `0xb883d0` | UNIQUE |
| `PlayerVisualRepresentation LoadPlayerVisualRepresentation(string)` | `0xb88980` | UNIQUE |

`TryGetInRaidProfile`'s declared signature is
`(EGameMode, CharacterSelectionProfileData)`; MEASURED-BY-USE both are **out**
parameters — the only caller (`0x97bc19`) passes `rdx = lea [rsp+0x50]` (an int
slot) and `r8 = lea [rsp+0x68]` (a pointer slot), `r9 = 0`.

`EFT.CharacterSelectionProfileData` (type 8775), MEASURED `R fields`:

| Offset | Field | Type |
|---|---|---|
| `0x10` | `_playerVisualRepresentation` | PlayerVisualRepresentationDescriptor |
| `0x18` | `PlayerVisualRepresentation` | PlayerVisualRepresentation |
| `0x20` | `Status` | ECharacterSelectionProfileStatus |
| `0x28` | `SeasonalInfo` | CharacterSelectionSeasonInfo |
| `0x30` | `AccountType` | int |
| `0x38` | `AccountId` | long |
| `0x40` | `GameVersion` | string |
| `0x48` | `Level` | int |
| `0x50` | `LowerNickname` | string |
| `0x58` | `MemberCategory` | EMemberCategory |
| `0x60` | `Nickname` | string |
| `0x70` | `PrestigeLevel` | int |
| `0x74` | `Side` | EPlayerSide |
| `0x78` | `ProfileId` | string |

**`ECharacterSelectionProfileStatus` IS knowable offline, contrary to
`abi/aowlspt_modeskip.h`.** MEASURED `R fields EFT.ECharacterSelectionProfileStatus`
prints the `HASDEFAULT` constants: **`Locked = 0`, `Empty = 1`, `Available = 2`,
`InRaid = 3`.** The header's refusal to gate on `Status` was written when the
resolver did not surface `fieldDefaultValues`; it now does, and that refusal
should be retired rather than copied forward.

MEASURED `R fields EGameMode`: `Regular = 0`, `Pve = 1`, `PvpSeason = 2`.
MEASURED `R fields EScreenState`: `Temporary = 0`, `Queued = 1`, `Root = 2`.

`CharacterSelectionResult` (type 14115) is a **24-byte value type**. MEASURED
`R fields` gives `GameMode@0x10 (EGameMode, INITONLY)`, `ProfileData@0x18`,
`Cancelled@0x20`; MEASURED-BY-USE the unboxed layout the compiled code uses is
`GameMode@0x0 (dword)`, `ProfileData@0x8 (qword)`, `Cancelled@0x10 (byte)` —
see `R disasm 0x97bbf0` writing `movups [rbx], xmm0` + `movsd [rbx+0x10], xmm1`,
and `R fields <ExecuteCharacterSelection>d__131`, where `result` occupies
`0x30..0x48` = exactly 0x18 bytes.

`CharacterSelectionScreenController` (type 14118), MEASURED `R typemethods`:

| Member | RVA | sharedness |
|---|---|---|
| `.ctor(data, startupFlow, profileId, Nullable<EGameMode>, seasonalPerks, canGoBack)` | `0x13f0530` | UNIQUE |
| `Task<CharacterSelectionResult> get_CompletionTask()` | `0x13f04e0` | UNIQUE |
| `void Back()` | `0x13f0800` | UNIQUE |
| `Task BackAsync()` | `0x13f0a40` | UNIQUE |
| `void Submit(EGameMode, CharacterSelectionProfileData)` | `0x13f0bf0` | UNIQUE |
| `Task SubmitAsync(EGameMode, CharacterSelectionProfileData)` | `0x13f0cc0` | UNIQUE |
| `void OpenSeasonIntro()` | `0x13f0ee0` | UNIQUE |
| `bool get_StartupFlow()` | `0xb65c80` | **SHARED x41** |
| `string get_ProfileId()` | `0x690c40` | **SHARED x185** |
| `Nullable<EGameMode> get_CurrentGameMode()` | `0x690cb0` | **SHARED x147** |
| `CharacterSelectionDataResponse get_Data()` | `0x690d90` | **SHARED x137** |
| `SeasonalPerksData get_SeasonalPerks()` | `0x65ed10` | **SHARED x107** |

Fields, MEASURED `R fields` (the `ScreenController`2` half is `GENERIC` — those
offsets do not exist anywhere in this file):

| Offset | Field |
|---|---|
| `0x48` | `<StartupFlow>k__BackingField` bool |
| `0x49` | `<CanGoBack>k__BackingField` bool |
| `0x50` | `<ProfileId>k__BackingField` string |
| `0x58` | `<CurrentGameMode>k__BackingField` Nullable\<EGameMode\> |
| `0x60` | **`_completion` TaskCompletionSource\<CharacterSelectionResult\>** |
| `0x68` | `<Data>k__BackingField` CharacterSelectionDataResponse |
| `0x70` | `<SeasonalPerks>k__BackingField` SeasonalPerksData |

### 1.8 `Submit` — disassembled in full

MEASURED `R disasm 0x13f0bf0 --to 0x13f0cc0`. `Submit(EGameMode gameMode,
CharacterSelectionProfileData profileData)` is a **fire-and-forget wrapper and
nothing else**:

```
call SubmitAsync(rcx=this, edx=gameMode, r8=profileData, r9=MethodInfo*=0)  @0x13f0cc0
if (returnedTask != null)
    jmp Task::ContinueWith(task, <static delegate>, r8=0)                   @0x46142a0
else
    <null-ref throw helper @0x5d2530>
```

`Submit` **writes no field of its own and starts no task of its own.**
Everything happens in `SubmitAsync`.

MEASURED `R disasm 0x13f1500 --to 0x13f1830` — `<SubmitAsync>d__43::MoveNext`,
in source order (unboxed: `state@0x0`, `builder@0x8`, `profileData@0x20`,
`<>4__this@0x28`, `gameMode@0x30`, `<>u__1@0x38`):

```
if (profileData == null)              -> fall through to SetResult, do NOTHING
if (profileData.Status@0x20 == 0)     -> fall through to SetResult, do NOTHING
      (`cmp dword [profileData+0x20], 0 ; jbe end` — Status must not be Locked)
awaiter = this.TryCloseScreen(forced: 0, order: 0)     <- shared-generic call:
      rcx = controller, edx = 0, r8d = 0,
      r9  = MethodInfo* loaded from [[klass+0x20]+0xc0]+0x60   (NOT null)
if (!await awaiter)                   -> SetResult, do NOTHING
tcs    = controller._completion@0x60
task   = tcs.m_task@0x10
struct result = { GameMode = gameMode, ProfileData = profileData, Cancelled = 0 }
if (!Task<T>.TrySetResult(task, &result))   <slow path @0x259a20>
SetResult()
```

`TryCloseScreen(bool forced, EScreenOrder order) -> Task<bool>` is declared on
`ScreenController`2` (MEASURED `R typemethods ScreenController`2` — every member
is `NO-CODE`, the base is generic).

**The complete set of state changes `Submit` performs is: one
`TaskCompletionSource<CharacterSelectionResult>.TrySetResult`, preceded by a
screen close.** Nothing on `TarkovApplication`, nothing on the screen. Everything
the rest of the boot reads comes out of that 24-byte struct and out of the live
`CharacterSelectionProfileData` inside it.

**The `MethodInfo*` for `TryCloseScreen` is loaded from the class, not zeroed.**
It is a shared generic and NULL would be wrong there. That is the one call in
this whole map where the "NULL MethodInfo is fine" rule does not hold.

### 1.9 What the screen would have done — `ShowCharacterSelectionScreen`

MEASURED `R disasm 0x9daa00 --to 0x9db490`:

```
MonoBehaviourSingleton`1::get_Instance()                 @0x33e1a40
controller = new CharacterSelectionScreenController(
                 data, startupFlow, profileId,
                 currentGameMode, seasonalPerks, canGoBack)   @0x13f0530
machine[+0x50] = controller
edx = (machine[+0x28] == r14b) ? 1 : 2                   <- EScreenState (Queued/Root)
task = controller.<vtable {ptr@klass+0x308, MethodInfo*@klass+0x310}>(edx, forced:0)
       == ScreenController`2::ShowScreenAsync(EScreenState, bool) -> Task<bool>
await task
if (machine[+0x28] && machine[+0x40] != 0
    && !PrefsUtils.GetBool(<key>, false))                @0x964360
        new SeasonsIntroScreenController()               @0x1593a40
        … PrefsUtils.SetBool(<key>, true)                @0x964800
await controller.CompletionTask                          <- the indefinite park
```

**The screen's `Show` sets nothing the later flow reads.** The only thing that
crosses the boundary is the `CharacterSelectionResult` resolved into
`_completion` — the same 24 bytes `TryCreateInRaidCharacterSelection` builds
directly. That is the structural reason the in-raid bypass is safe and the
reason F2 is possible at all.

**The 1-in-3 crash this replaces.** The current `modeskip.nim` calls
`Submit(gameMode, profileData)` with values read off the live slot view
(`_gameMode@0x160`, `_profileData@0x178`), after waiting for wall-clock quiet on
`ShowSlot`. That is correct *as far as the values go* — but it still requires
the screen to exist, to have been shown, and to be closable, and
`TarkovApplication` re-shows the screen ~372 ms later from its own lobby flow
(recorded in `abi/aowlspt_modeskip.h`). Every one of those preconditions
disappears if the bypass fires before the screen is ever constructed.

### 1.10 `ExecuteCharacterSelection` — the post-Submit continuation

MEASURED `R fields <ExecuteCharacterSelection>d__131` (subtract 0x10 unboxed):
`result@0x30 (24 bytes)`, `startupFlow@0x48`, `<>4__this@0x50`.

MEASURED `R disasm 0x9b6e60 --to 0x9b7600`, in order:

```
fast path: if (result.ProfileData.ProfileId equals the current session profile id
                    via System.SpanHelpers::SequenceEqual        @0x457ffc0
              && result.ProfileData.Status@0x20 == 2 /* Available */
              && that ProfileId's length > 0)
              -> return true immediately; NOTHING below runs
this._pendingCharacterSelection@0x1c0 = null                     (seen at 0x9b70d8)
EnvironmentUI::SetGameModeVisual(EGameMode, bool forced)         @0x14644f0
await this.ShowProfileLoadingScreen()                            @0x979a10
await this.RecreateCurrentBackendWithResult()                    @0x978f80
   or  this.RecreateBackendWithResult(gameMode, force, showLoadingScreen) @0x978c10
await this.PrepareGame()                                         @0x97cc70
```

MEASURED `R fields PendingCharacterSelection`: one field, `ProfileId@0x10`.

### 1.11 The loading screen and its caption

Two different things are called "the loading screen"; do not conflate them.

**`EFT.UI.PreloaderUI` (type 14830, a `MonoBehaviourSingleton`)** is the
always-on overlay: black-screen fader, error screens, FPS counter, RTT/loss
labels, corner watermark, menu task bar. MEASURED `R fields`:
`_loader GameObject@0x80`, `WetLog TMP_Text@0xb8`, `MenuTaskBar@0xe8`,
`_alphaVersionText@0x110`, `_sessionIdText@0x118`, `_sessionModeText@0x128`.
It has **no** progress caption. `SetLoaderStatus(bool)` `@0x156acf0` is
`SHARED x2`.

**`EFT.UI.ProfileLoadingScreen` (type 14859) is the screen with the caption.**
MEASURED `R fields`:

| Offset | Field | Type |
|---|---|---|
| `0xa0` | `_loadingPanel` | RectTransform |
| `0xa8` | `_errorPanel` | RectTransform |
| **`0xb0`** | **`_statusField`** | **CustomTextMeshProUGUI** |
| `--` | `PROFILE_LOADING_TEXT` | string const (localization key; metadata value encrypted) |
| `--` | `PROFILE_LEAVING_TEXT` | string const (same) |

MEASURED `R typemethods EFT.UI.ProfileLoadingScreen`:

| Member | RVA | sharedness |
|---|---|---|
| `Show(ProfileLoadingScreenController controller)` | `0x157a8c0` | UNIQUE |
| `Show(bool loading)` | `0x157aa40` | UNIQUE |
| `SetLivingStatus(bool isLiving)` | `0x157abe0` | UNIQUE |
| `AutoHide(Action)` | `0x157ace0` | UNIQUE |
| `TranslateCommand(ECommand)` | `0x157ad80` | UNIQUE |

MEASURED `R disasm 0x157aa40` — `Show(bool loading)` is:

```
SetLivingStatus(false)                                  @0x157abe0
<virtual {klass+0x298, klass+0x2a0}>(this, true)        <- UIScreen show/animate
_loadingPanel@0xa0 .gameObject.SetActive(loading)
_errorPanel@0xa8  .gameObject.SetActive(!loading)
```

MEASURED `R disasm 0x157abe0` — **this is the exact way the game writes its own
loading caption**:

```
id  = isLiving ? PROFILE_LEAVING_TEXT : PROFILE_LOADING_TEXT
s   = LocalizationManager::get_Instance()@0xaf4f70 .LocalizedValue(id) @0xaf7ae0
tmp = this._statusField@0xb0
tmp.<virtual {klass+0x558, klass+0x560}>(s)             <- TMP_Text::set_text
```

`TMPro.TMP_Text::set_text(string)` `@0x51BC1E0` is MEASURED **UNIQUE**
(`R shared 0x51BC1E0` → `owners=1`; `R symbolize 0x51BC1E0` names it exactly).
`EFT.LocalizationManager::LocalizedValue(string id)` `@0xaf7ae0` is UNIQUE,
`ASSEM|HIDEBYSIG`; there is a 2-arg overload at `0xaf7ca0`.

So a host that wants to drive the game's own caption calls
`TMP_Text::set_text(_statusField, il2cpp_string_new(text))` and **re-applies**
(CLAUDE.md §5: `LocalizedText` clobbers raw stores, and the game itself
re-writes this field whenever `Show`/`SetLivingStatus` runs). Whether a
`LocalizedText` component is attached to `_statusField`'s GameObject on this
build is **UNKNOWN — needs a live read** (§8 Q4).

### 1.12 "Loading is done", as the game itself defines it

MEASURED `R disasm 0x9839e0` —
`TarkovApplication::OnApplicationLoaded(bool interactiveMainMenuForColdBoot)`
`@0x9839e0`, UNIQUE:

```
ClientLoadTimeMetrics::OnMainMenuShown(interactiveMainMenuForColdBoot)  @0x9687a0
MenuLoadProfiler::RequestReport(<milestone name>)                      @0x9e37b0
invoke this.AfterApplicationLoaded@0x218   (Action)
this._isFirstTimeApplicationLoad@0x140 = 0
```

MEASURED `R callers 0x9839e0`: exactly two sites,
`<MainMenu>d__191::MoveNext +0x724` and `<Run>d__184::MoveNext +0x1e7d`.

**`TarkovApplication.AfterApplicationLoaded` (Action, `@0x218`), with
`add_AfterApplicationLoaded` `@0x977110` (UNIQUE), is the game's own
"the client has finished loading" event.** That is the correct finished-state
signal for any boot verdict, and it is strictly later than `MenuScreen::Show`.

### 1.13 The main menu

MEASURED `R typemethods EFT.UI.MenuScreen` (type 14732):

| Member | RVA | sharedness |
|---|---|---|
| `Awake()` | `0x1538360` | UNIQUE |
| `Show(MainMenuBaseScreenController controller)` | `0x1538760` | UNIQUE |
| `Show(matchmaker, expansionsInfo, modeDescriptor, profile, seasonalRewardController)` | `0x15387A0` | UNIQUE |
| `ShowInRaid()` | `0x1539650` | UNIQUE |
| `Click(EMenuType)` | `0x1539770` | UNIQUE |

MEASURED `R callers 0x15387a0`: **exactly one** direct caller —
`MenuScreen::Show(MainMenuBaseScreenController)` `@0x1538760 +0x30`. The 1-arg
`Show` is itself reached only through the screen-controller vtable (no static
edge), so the 5-arg `Show` the host already gates on is the right receiver.

MEASURED `R callers 0x97a380` — `MainMenuLoad` has three direct callers:
`LoadMainMenu @0x9792f0 +0x2` (a **tail `jmp`**; `R typemethods` flags
`LoadMainMenu` as `TAILJUMP: jmp rel32 at +2 — a postfix detour here has no
return site`), `<InitPreloaderUI>b__114_2 @0x988070 +0x2f`, and
`<ShowLegacyLoginScreen>d__112::MoveNext @0x9dcff0 +0x335`.

MEASURED `R callers 0x979a10` — `ShowProfileLoadingScreen` has two:
`<CreateBackend>d__102::MoveNext +0x90f` and
`<ExecuteCharacterSelection>d__131::MoveNext +0x3a1`.

---

## 2. Threads

**MEASURED:** nothing in this map proves a thread. What is measured is that
every method above is either a `MonoBehaviour` member (`Awake`, `Start`,
`Update`) or is reached synchronously from one, and that the awaits are wrapped
in `System.Threading.Tasks.TaskAwaiters::ForceAsync` `@0x270e430`, which forces
each continuation to be *posted* rather than run inline.

**INFERRED:** the continuations are posted to Unity's `SynchronizationContext`
and therefore resume on the Unity main thread, because each of them immediately
touches `MonoBehaviour`/`GameObject` state — `ExecuteCharacterSelection` calls
`EnvironmentUI::SetGameModeVisual`, `ShowCharacterSelectionScreen` constructs a
screen controller and shows it. Unity's API would throw off-thread.

**MEASURED, from the host's own record**
(`host/Aowlspt.Host.Il2Cpp/modload.nim`, 2026-09-02): aowlspt mods are
**initialised on the host ops thread and must be ticked on the same thread** —
mimalloc heap ownership. The host already logs both thread ids and warns if they
are the same.

**Consequence for F1, and it is the whole design constraint:** a native step
that runs *inside* the flow runs on the Unity main thread. It must therefore
**wait on the ops thread's work** — publish a request, poll a flag — and must
never perform the mod load itself, and never block. Blocking the Unity main
thread for a multi-minute mod build freezes rendering, stops the loading
animation, and makes Windows mark the window Not Responding: indistinguishable
from a hang, which is the failure mode the whole modload screen exists to
prevent.

§8 Q2 names the one-line live probe that turns the INFERRED above into a
MEASURED.

---

## 3. Feature F1 — a synchronous native mod-load step

### 3.1 The constraint that eliminates most candidates

We cannot inject managed code. Therefore we cannot hand the game a `Task` that
completes when we say so, and we cannot make any `await` in §1 wait for us.
Two mechanisms remain:

* **(a) delay the trigger** — do not let the flow advance past a point it is
  already willing to sit at, and advance it ourselves when ready;
* **(b) spin on the Unity main thread inside a detour** — rejected in §2.

So the only question is: *where does the boot already park indefinitely while
still pumping frames?*

### 3.2 The answer: the character-selection park

MEASURED (§1.9): `ShowCharacterSelectionScreen` ends in
`await controller.CompletionTask`, and `CompletionTask` is resolved only by
`SubmitAsync` or `BackAsync`. On a stock client that await lasts until a human
clicks. The game renders, `TarkovApplication::Update` `@0x977B10` ticks every
frame (so the host drain runs), and nothing times out.

MEASURED (§1.6): the flow consults
`TryCreateInRaidCharacterSelection(data, out result)` `@0x97bbf0` **before** it
constructs the controller. That gives two usable hold points, differing in what
is on screen while holding:

| Hold point | Screen while holding | Cost |
|---|---|---|
| **H1** — decline the bypass, let the screen show, resolve the completion when ready | the character-selection screen, visible | one frame (in fact many) of the screen — exactly what F2 exists to avoid |
| **H2** — take the bypass, but return `true` only once the mods are ready | **UNKNOWN — needs a live read (§8 Q3)** | `abi/aowlspt_modeskip.h` records "a blank background with no menu" for a *different* deferral mistake, so this must be checked, not assumed |

**H2 is the recommendation**, because it is the only one that also satisfies F2,
and because what is on screen can be *made* right: the host can raise the game's
own profile-loading screen itself.

### 3.3 Raising the game's own loading screen

`TarkovApplication::ShowProfileLoadingScreen()` `@0x979a10` is UNIQUE, arity 0,
instance, `PRIVATE|HIDEBYSIG`, and is an async kickoff — MEASURED
`R disasm 0x979a10` is a builder `Start` and nothing else, and MEASURED
`R disasm 0x9dd570` (`<ShowProfileLoadingScreen>d__108::MoveNext`) reaches
`EftScreenManager::get_Instance()` `@0x172dc10`. Calling it from the drain with
`rcx = <the live TarkovApplication>`, `rdx = MethodInfo* = 0` returns a `Task`
we discard and puts `ProfileLoadingScreen` up.

**Prologue trap.** MEASURED `R bytes 0x979a10` =
`48 83 EC 68 80 3D E5 F4 73 06 00 75 29 48 8D 0D`. Byte 4 begins a
**rip-relative `cmp byte ptr [rip+d], 0`** (the IL2CPP class-init guard). That
does **not** stop a *direct call* — only a detour that must relocate the
prologue. See §5 T3.

Then, each poll, write the caption:

```
tmp = <the live ProfileLoadingScreen>._statusField@0xb0
TMP_Text::set_text(tmp, il2cpp_string_new(line))     @0x51BC1E0   UNIQUE
```

and **re-apply**, because `SetLivingStatus` `@0x157abe0` writes the same field
from the game's side whenever `Show` runs.

Reaching the `ProfileLoadingScreen` instance must be done by **walking from a
verified live object** (CLAUDE.md §5): the controller is a `ScreenController`2`
whose `Screen` field is `GENERIC` and therefore has **no offset in this build's
metadata at all** (MEASURED — `R fields CharacterSelectionScreenController` and
`R fields EFT.UI.ProfileLoadingScreen` both end in the `GENERIC — NO LAYOUT`
refusal). §8 Q4.

### 3.4 What "loading is done" looks like to the game

Two signals, both MEASURED, and they mean different things:

* `EFT.UI.MenuScreen::Show(5-arg)` `@0x15387A0` — the menu is being shown. This
  is what `modload.nim` gates the deferred release on today.
* `TarkovApplication::OnApplicationLoaded(bool)` `@0x9839e0` → invokes
  `AfterApplicationLoaded@0x218` — the client itself declaring the load complete.
  Strictly later.

For a *verdict*, `AfterApplicationLoaded` is the right one. For the *release
gate* the existing `MenuScreen::Show` is fine and already proven live.

### 3.5 The instrument that makes the whole flow observable

**`EFT.MenuLoadProfiler` (type 7942) is the game's own boot-stage log**, and
draining it read-only is the cheapest way to learn the real ordering and the
real threads:

| Member | RVA | sharedness | first 16 bytes |
|---|---|---|---|
| `void StartFlow(string startMarkName)` | `0x9e2e80` | UNIQUE | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 40 48` — clean |
| `IDisposable Begin(string name)` | `0x9e3310` | UNIQUE | `48 89 5C 24 08 48 89 74 24 10 57 48 81 EC 90 00` — clean |
| `void Mark(string name)` | `0x9e3640` | UNIQUE | `40 53 48 83 EC 40 48 8B D9 80 3D 9F 5A 6D 06 00` — **rip-rel at byte 9** |
| `void RequestReport(string milestoneName)` | `0x9e37b0` | UNIQUE | — |
| `void MarkNextFrame(string name)` | `0x9e39c0` | UNIQUE | — |
| `void MarkEndOfFrame(string name)` | `0x9e3ab0` | UNIQUE | — |
| `void PrintReport()` | `0x628110` | **SHARED x9614 — the universal empty stub** | never touch |

All are static (`Sync`, `_sw`, `_entries`, `_reportRequested`, `_reportPrinted`
are static fields; `MIN_REPORTED_INTERVAL_MS = 100.0`). `Begin` and `StartFlow`
have clean 15-byte windows and take the stage name in `RCX`; `Mark` does not,
and a detour engine that cannot fix up `80 3D <rel32>` must refuse it rather
than patch it.

---

## 4. Feature F2 — skipping the screen with no frame of UI

### 4.1 The hook

**`EFT.TarkovApplication::TryCreateInRaidCharacterSelection(
CharacterSelectionDataResponse data, out CharacterSelectionResult result)`
@ `0x97bbf0`.**

MEASURED `R member TryCreateInRaidCharacterSelection`:
`attrs=0x0091 PRIVATE|STATIC|HIDEBYSIG`, `arity=2`, `section=il2cpp`,
`sharedness=UNIQUE owners=1`.

**It is STATIC.** ABI: `RCX = data`, `RDX = &result` (a 24-byte out buffer the
caller supplies — `lea rdx,[rsi+0x40]`, a field of its own state machine),
`R8 = MethodInfo*` (the caller passes `xor r8d,r8d`, i.e. NULL).

MEASURED `R bytes 0x97bbf0`:
`48 89 5C 24 10 | 57 | 48 83 EC 40 | 33 FF | 48 8B DA | 89 …`
— five complete instructions covering bytes 0..14, **no rip-relative operand**,
so a 14-byte absolute-jump detour has a clean relocation window. Compare
`ShowProfileLoadingScreen`, `PrepareGame`, `MainMenuLoad`, `OnApplicationLoaded`
and `MenuLoadProfiler::Mark`, all of which carry `80 3D <rel32>` inside the
first 16 bytes (§5 T3).

MEASURED `R callers 0x97bbf0` — **two** call sites:

```
0x9d8735  in <RunInitialLobbyFlow>d__121::MoveNext        +0x785   <- the boot
0x9cd95f  in <OpenCharacterSelectionFromMenu>d__118::MoveNext +0x8ef  <- in-menu switch
```

A detour fires for **both**. The in-menu "switch character" path must be left
alone, so the detour has to be a **one-shot armed only for the first call after
boot**. `TarkovApplication` carries two fields that plausibly discriminate:
`_pendingCharacterSelection@0x1c0` and `_characterSelectionFromMenuBusy@0x1c8`
(MEASURED `R fields EFT.TarkovApplication`). §8 Q5.

### 4.2 Its body, in full

MEASURED `R disasm 0x97bbf0 --to 0x97bd20`:

```
if (data == null) goto fail
if (!data.TryGetInRaidProfile(out gameMode@rsp+0x50,
                              out profile@rsp+0x68))     @0xb881a0   goto fail
result->GameMode    = gameMode      (dword at +0x00)
result->ProfileData = profile       (qword at +0x08)
result->Cancelled   = 0             (byte  at +0x10)
<GC write barriers for the two managed slots>
return true

fail:
result->{0, 0, 0}   (xorps xmm0 ; movups [rbx],xmm0 ; mov [rbx+0x10],0)
return false
```

There is no other side effect. It touches no `TarkovApplication` field, starts
no task, and shows nothing.

### 4.3 Why the values must be the game's own, not computed

The crash recorded on 2026-09-02 — `Rax=1 Rcx=1 Rdx=0`, "a Profile argument that
was the integer 1" — came from the host *computing* `gameMode` and
`profileData`. This hook removes that class of error by construction:

* `data` arrives in `RCX` from the game's own `<bootstrap>5__2.Profiles`.
* `data` **is a `Dictionary<EGameMode, CharacterSelectionProfileData>`** (§1.7),
  so the correct way to obtain a `(gameMode, profileData)` pair is to ask that
  dictionary — the key you look up *is* an `EGameMode`, and the value it hands
  back *is* the game's own `CharacterSelectionProfileData` object.
* Never construct a `CharacterSelectionProfileData`. Never write an `EGameMode`
  that is not a key of that dictionary.

The instantiated `Dictionary<EGameMode,CharacterSelectionProfileData>` layout is
**not reachable offline** — `R fields EFT.CharacterSelectionDataResponse` ends in
the `GENERIC — NO LAYOUT` refusal, and every `Il2CppGenericClass.cached_class` in
this file is null. Either call the instantiated `Dictionary`2::TryGetValue` body
the boot itself calls (`0x3f86cd0`, reached at
`<RunInitialLobbyFlow>d__121 +0x9d8b2b`; it is a **generic body**, so `R shared`
says `unknown` and it needs a real `MethodInfo*`), or read the layout off a live
object and say it is borrowed. §8 Q6.

### 4.4 Trap: `Status`

MEASURED (§1.8): `SubmitAsync` refuses outright when `profileData.Status == 0`
(`Locked`). MEASURED (§1.10): `ExecuteCharacterSelection`'s fast path requires
`Status == 2` (`Available`). The bypass path checks `Status` nowhere —
`TryGetInRaidProfile` is what enforces `InRaid`, and we are replacing it.
**A host that substitutes its own pair must therefore check `Status` itself:**
accept `2 == Available`; refuse `0 == Locked` and `1 == Empty`; `3 == InRaid`
is the reconnect case and belongs to the original. This retires the
"we cannot know the enum values" refusal in `abi/aowlspt_modeskip.h`.

### 4.5 What the screen's `Show` would have set that the flow later reads

MEASURED, from §1.9: **nothing.** The controller's show path sets
`SeasonsIntroScreenController` state and a `PrefsUtils` bool (`GetBool`
`@0x964360` / `SetBool` `@0x964800`) that gate the seasons intro, and it writes
`machine[+0x50] = controller` inside its own state machine. Nothing outside that
machine reads either. `EnvironmentUI::SetGameModeVisual` `@0x14644f0` — the one
visual side effect that *does* matter — is performed by
`ExecuteCharacterSelection`, on both branches.

**The one thing the bypass branch still runs, and that must not be skipped**, is
`ShowLanguageSelectionIfNeeded(data)` `@0x97bd20` at `0x9d8847`. It sits on the
bypass side of the branch, so taking the bypass does not skip it — but a host
that instead short-circuited *further down* (e.g. by calling
`ExecuteCharacterSelection` directly from the drain) **would** skip it. Do not.

---

## 5. Traps

**T1 — state-machine field offsets are printed boxed and used unboxed.**
Subtract `0x10`; §1.3 has the proof. Using the table value reads the neighbouring
field and never faults.

**T2 — `0x628110` is this build's universal empty body, shared by 9,614
methods.** In this map it appears as
`TarkovApplication::ApplyUnlockAllLocationsEditorDebug` and
`MenuLoadProfiler::PrintReport`. A signature check passes on it. Never bind it,
and never read "the method exists" from it.

**T3 — rip-relative bytes inside the relocation window.** MEASURED `R bytes`:

| RVA | method | first 16 bytes | window |
|---|---|---|---|
| `0x97bbf0` | `TryCreateInRaidCharacterSelection` | `48 89 5C 24 10 57 48 83 EC 40 33 FF 48 8B DA 89` | **clean** |
| `0x13f0bf0` | `Submit` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 80` | clean through byte 14 |
| `0x13f0530` | controller `.ctor` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` | clean |
| `0x13efae0` | `CharacterSelectionScreen::ShowSlot` | `44 89 44 24 18 48 89 4C 24 08 53 55 57 41 55 48` | clean |
| `0x157aa40` | `ProfileLoadingScreen::Show(bool)` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 0F` | clean |
| `0x157abe0` | `ProfileLoadingScreen::SetLivingStatus` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 80` | clean through byte 14 |
| `0x9e2e80` | `MenuLoadProfiler::StartFlow` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 40 48` | clean |
| `0x9e3310` | `MenuLoadProfiler::Begin` | `48 89 5C 24 08 48 89 74 24 10 57 48 81 EC 90 00` | clean |
| `0x979a10` | `ShowProfileLoadingScreen` | `48 83 EC 68 80 3D …` | **rip-rel at byte 4** |
| `0x97cc70` | `PrepareGame` | `40 53 48 83 EC 70 80 3D …` | **rip-rel at byte 6** |
| `0x97a380` | `MainMenuLoad` | `40 53 48 83 EC 70 80 3D …` | **rip-rel at byte 6** |
| `0x97ba70` | `LoadCharacterSelectionData` | `40 53 48 83 EC 70 80 3D …` | **rip-rel at byte 6** |
| `0x9e3640` | `MenuLoadProfiler::Mark` | `40 53 48 83 EC 40 48 8B D9 80 3D …` | **rip-rel at byte 9** |
| `0x97b8d0` | `LoadCharacterSelectionBootstrap` | `40 53 48 81 EC 90 00 00 00 80 3D …` | **rip-rel at byte 9** |
| `0x9839e0` | `OnApplicationLoaded` | `48 89 5C 24 08 57 48 83 EC 20 80 3D …` | **rip-rel at byte 10** |

Calling any of these directly is unaffected. *Detouring* one requires a
relocator that fixes up `80 3D <rel32>`; if the engine cannot, it must refuse and
say so, exactly as `CharacterSelectionScreen::Show @0x13ef4d0` was refused
(`abi/aowlspt_modeskip.h`).

**T4 — `LoadMainMenu @0x9792f0` is a TAILJUMP.** `R typemethods` annotates it:
`jmp rel32 at +2 — tail-call thunk; a postfix detour here has no return site`.
Its whole body is `jmp MainMenuLoad @0x97a380`.

**T5 — shared getters everywhere on the controller.** `get_ProfileId` is
`SHARED x185`, `get_Data` `x137`, `get_CurrentGameMode` `x147`,
`get_SeasonalPerks` `x107`, `get_StartupFlow` `x41`. *Calling* them is correct;
*detouring* one fires for every folded owner. Read the fields instead
(`0x50`, `0x68`, `0x58`, `0x70`, `0x48`).

**T6 — the one call in this map that needs a real `MethodInfo*`.**
`SubmitAsync`'s `TryCloseScreen` is a shared generic and the compiled body loads
`r9` from `[[klass+0x20]+0xc0]+0x60` rather than zeroing it (§1.8). The
instantiated `Dictionary`2::TryGetValue` at `0x3f86cd0` is the same shape.
NULL is fine everywhere else measured here.

**T7 — `TryCreateInRaidCharacterSelection` has two callers** (§4.1). A detour
that is not one-shot will also hijack the in-menu character switch.

**T8 — the async chain throws, and a throw aborts the whole flow silently.**
Every `MoveNext` in §1.3 ends in `AsyncTaskMethodBuilder::SetException`
`@0x4436490`. `abi/aowlspt_modeskip.h` records the measured consequence: a
`NullReferenceException` inside `CharacterSelectionSeasonPanel::ShowPerks`
aborted the lobby-flow task and `MenuScreen` was **never** activated — the game
did not crash and logged nothing obvious. An aborted lobby task and a slow one
look identical from outside.

**T9 — the false crash.** The client takes >60 s to reach the character screen
and then waits for a human forever. That is exactly the state F1's hold point
deliberately creates. Any verdict must distinguish `IDLE` (alive, holding) from
`TIMEOUT`; `python tools/harness.py run --until "<literal>"` does.

**T10 — every `TarkovApplication` field in this map is a pointer that can read
null early in boot** — `_menuOperation@0x128`, `_settingsScreenResolver@0x130`,
`_pendingCharacterSelection@0x1c0`, `AfterApplicationLoaded@0x218`.
`VirtualQuery`/`aowl_is_readable` on every hop; `a->b->c` is three checks.

---

## 6. What a correct implementation must do

### 6.1 F1 + F2 as one hook (the recommendation)

Flag-gated, default OFF; one `aowl_p_p_seh` around the whole body (never
nested); capped iteration; self-disable after N faults; no per-frame managed
allocation; never blind-write.

**At startup (no game state touched):**

1. `aowl_pro_verify` the 16-byte prologue of `0x97bbf0` against the **startup
   snapshot** (`abi/aowlspt_prologue.h`), never against live memory. On mismatch:
   refuse, log, feature inert. Do the same for every RVA you will *call*:
   `0x51BC1E0` (`set_text`), `0xaf7ae0` (`LocalizedValue`), `0x979a10`
   (`ShowProfileLoadingScreen`).
2. Bind **one** drain on `TryCreateInRaidCharacterSelection` `@0x97bbf0`. If
   another feature already hooks it, ride that drain — never a second detour.

**Inside the detour (Unity main thread, first call only):**

3. `VirtualQuery` `RCX` (`data`) and `RDX` (`&result`). If either fails, chain to
   the original unchanged and count a fault.
4. If this is not the first call since boot (§8 Q5), chain to the original.
5. Ask the ops thread whether the mods are ready. **Do not build, do not tick,
   do not wait, do not sleep.** If not ready, publish "hold" state and take the
   hold path (5a).

   5a. There is no way to make this *call* block. So the hold must be placed one
   step earlier, on whatever invokes `RunInitialLobbyFlow`. **That caller is not
   identified offline (§8 Q1) and it is the single blocking unknown for F1.** If
   Q1's live read shows the flow is entered from a delegate we can gate, the hold
   goes there. If it shows the mods poll is already faster than the boot, F1
   collapses into "return `true` when ready, chain to the original otherwise" —
   which is F2 alone, and is still correct.
6. When ready, and the wanted profile is a key of `data`:
   * `gameMode` = the `EGameMode` key you looked up in `data`;
   * `profileData` = the value `data` handed back;
   * refuse unless `profileData != NULL` and `profileData.Status@0x20 == 2`;
   * write `result->GameMode = gameMode` (dword `+0x00`),
     `result->ProfileData = profileData` (qword `+0x08`),
     `result->Cancelled = 0` (byte `+0x10`);
   * return `true` **without** calling the original.
7. Never write a `CharacterSelectionProfileData` you constructed. Never write an
   `EGameMode` that was not a key of `data`.

**Caption, from the drain (`TarkovApplication::Update` `@0x977B10`):**

8. Once `ProfileLoadingScreen` is up — either because the game raised it inside
   `ExecuteCharacterSelection`, or because the host called
   `ShowProfileLoadingScreen` `@0x979a10` with `rcx = the live
   TarkovApplication, rdx = 0` — write
   `TMP_Text::set_text(screen._statusField@0xb0, il2cpp_string_new(line))`
   `@0x51BC1E0` on each poll, and **re-apply**.
9. Reach `_statusField` **by walking from a verified live object**, validating
   each hop. Never by an offset off a pointer that can read null.

### 6.2 Finished-state predicates a verdict reads back

Three outcomes, never two. Assert the finished state; prefer negatives.

| # | Predicate | PASS | FAIL | INCONCLUSIVE |
|---|---|---|---|---|
| P1 | **No `CharacterSelectionScreenController` was ever constructed.** A read-only counting drain on `.ctor` `@0x13f0530` (UNIQUE, clean prologue) reports 0. | count == 0 | count >= 1 | drain never bound / prologue verify refused |
| P2 | **No `CharacterSelectionScreen::ShowSlot` fired.** Same shape on `@0x13efae0` (UNIQUE, clean prologue). | count == 0 | count >= 1 | drain never bound |
| P3 | **The main menu was reached.** `MenuScreen::Show(5-arg)` `@0x15387A0` fired at least once with a live receiver, then `AfterApplicationLoaded@0x218` was invoked (observe via `OnApplicationLoaded` `@0x9839e0` — but see T3: it may not be relocatable; if not, gate on `MenuScreen::Show` alone and *say so*). | both seen | menu never shown | held >90 s but the host log is still progressing → `IDLE`, not `TIMEOUT` (T9) |
| P4 | **The selected profile is the one asked for.** Read `ProfileId` off the live session after the menu appears and compare with `launchProfileId`. A property of the finished state, not of our own write. | equal | different | session pointer unreadable |
| P5 | **The mods were released before the menu appeared.** `python tools/hostlog.py summary` shows the release line strictly earlier than the `MenuScreen::Show` line. | earlier | later, or absent | no release line at all |
| P6 | **The caption on screen is ours.** No TMP under the loading panel still renders the localized `PROFILE_LOADING_TEXT` value while our line is supposed to be up (`findtext`, active nodes). | none does | one does | screen never opened, or `findtext` reports STOPPED EARLY |

P1 and P2 are the ones that matter, and they are **negatives** — they can be
falsified. "Submit returned success" cannot be, and is exactly the shape of check
CLAUDE.md §9b is about.

### 6.3 What a wrong implementation looks like in the log

* `prologue did not verify against the startup snapshot` on `0x97bbf0` — either
  the wrong build, or another feature patched it first and the verify is reading
  a trampoline (a hook-order problem, not a bad RVA).
* The detour fires **twice**, and the second time the player is thrown out of the
  menu into character selection → T7: the one-shot arming is missing and the
  in-menu switch at `<OpenCharacterSelectionFromMenu>d__118 +0x8ef` was hijacked.
* `MenuScreen::Show` never fires, the host log stops progressing, and there is no
  crash report → T8: the lobby-flow task threw and was swallowed by
  `AsyncTaskMethodBuilder::SetException`. Read the client's own log under
  `D:\Aowlspt\Logs\<ts>\` and look for `CharacterSelectionSeasonPanel`.
* The game reaches the menu with the **wrong profile**, and
  `python tools/dmpread.py <Crash_*>/crash.dmp` shows a small integer where a
  pointer belongs (`Rcx=1`, `Rdx=0`) → a computed `profileData` (§4.3).
* Everything looks right but P1 counts 1 → the bypass returned `true` too late,
  after `ShowCharacterSelectionScreen` had already constructed the controller.
  The boot succeeded and **F2 failed**: that is a frame of UI.
* The window goes Not Responding during the mod build → the wait was performed on
  the Unity main thread (§2).

---

## 7. Where existing records disagree with this map

1. **`abi/aowlspt_modeskip.h`:** "`ECharacterSelectionProfileStatus`'s constant
   values live in metadata `fieldDefaultValues`, which neither resolver verb
   exposes". **Superseded.** `R fields EFT.ECharacterSelectionProfileStatus`
   prints them — `Locked=0, Empty=1, Available=2, InRaid=3` (§1.7). The refusal
   to gate on `Status` should be replaced by an explicit `Status == 2` check
   (§4.4).
2. **`abi/aowlspt_modeskip.h`:** treats `Submit @0x13f0bf0` as the thing to call.
   Still valid as a last resort, but §1.8 shows `Submit` is a two-line wrapper
   whose entire effect is one `TrySetResult`, and §4 shows the game has its own
   no-UI path that runs strictly earlier. The 1-frame flash is not a timing
   problem to be tuned; it is a consequence of hooking too late.
3. **`host/Aowlspt.Host.Il2Cpp/modload.nim`** header: "This is NOT injected into
   the client's own step list — doing that means detouring whatever drives those
   captions, and that method is not identified on this build." **Superseded in
   part.** The method that drives the profile-loading caption *is* identified:
   `ProfileLoadingScreen::SetLivingStatus @0x157abe0` writes `_statusField@0xb0`
   through `TMP_Text::set_text @0x51BC1E0` (§1.11). What remains unidentified is
   only whether a `LocalizedText` also owns that TMP (§8 Q4).
4. **CLAUDE.md §5** records `ForceMeshUpdate @0x628110` as "a stripped stub".
   Consistent with this map, but state it accurately: `0x628110` is the build's
   **universal** empty body, shared by 9,614 methods, and it turns up twice in
   this map (T2).

---

## 8. Open questions this map does NOT answer — each with the exact live read

**Q1 (blocking for F1). Who invokes `RunInitialLobbyFlow` `@0x97b550`, and when
relative to `MainMenuLoad` `@0x97a380`?** MEASURED: 0 direct callers, 0
rip-relative references (§1.6). *Live read:* bind read-only counting drains on
`0x97b550` and `0x97a380` and log `GetCurrentThreadId()` plus a monotonic
timestamp for each; the order of the two lines answers it. Better: drain
`MenuLoadProfiler::Begin @0x9e3310` (clean prologue) and log its `RDX` string —
that names every stage the game itself declares and answers Q1 and Q2 at once.

**Q2. Which thread do the `MoveNext` continuations resume on?** INFERRED main
thread (§2). *Live read:* the same drain, logging `GetCurrentThreadId()`,
compared with the id the host already records for the Unity drain in
`aowlspt-host.log`.

**Q3 (blocking for F1's screen). What is on screen at the moment
`TryCreateInRaidCharacterSelection` is called?** *Live read:* from the drain,
`roots` then `findtext` for any active caption; or read
`EftScreenManager::get_Instance() @0x172dc10` and its
`CurrentBaseScreenController` (setter at `0x172dd40`). Do this **before** writing
any hold logic — "a blank background with no menu" is on record for a nearby
mistake.

**Q4. Does `ProfileLoadingScreen._statusField@0xb0` carry a `LocalizedText`
component, and what is the live pointer to the screen itself?** *Live read:*
`component <statusField> EFT.UI.LocalizedText`, and `label` on the same node to
see what it renders. If a `LocalizedText` is present, the caption must be driven
through `LocalizedText::SetLabelText @0x140FE70` and re-applied, not through
`set_text` alone. The screen pointer must come from a walk, because
`ScreenController`2::Screen` is `GENERIC` with no offset in this build.

**Q5. How does the detour tell the boot call from the in-menu switch?**
Candidates from the field table: `_pendingCharacterSelection@0x1c0` (null on the
boot path — MEASURED, `ExecuteCharacterSelection` clears it at `0x9b70d8`) and
`_characterSelectionFromMenuBusy@0x1c8`. *Live read:* from inside a read-only
drain at both call sites, read both off the live `TarkovApplication` and record
which one differs. A frame counter is not an answer; a field is.

**Q6. The instantiated layout of
`Dictionary<EGameMode, CharacterSelectionProfileData>`.** Not reachable offline
(§4.3). *Live read:* take `_buckets`/`_entries`/`_count` off a live
`CharacterSelectionDataResponse` captured in the drain via `RCX`, and say the
layout is **borrowed** — or avoid the layout entirely by calling the instantiated
`Dictionary`2::TryGetValue` body at `0x3f86cd0` with the correct `MethodInfo*`.

**Q7. What are `PROFILE_LOADING_TEXT` / `PROFILE_LEAVING_TEXT`?** Their metadata
default values are encrypted — `R fields` prints `'<undecoded:0xe>'`. *Live
read:* read the string the game itself writes, i.e. `label` on `_statusField`
after `SetLivingStatus` has run. String-searching the metadata blob proves
nothing.

**Q8. Which `EGameMode` should a startup selection use?** MEASURED: it must be a
key of the live `data` dictionary. Whether the launcher's `launchProfileId` maps
to `Regular(0)` or `Pve(1)` on this install is a property of the served profile
list, not of the binary. *Live read:* enumerate `data`'s keys inside the drain
and log them before choosing.
