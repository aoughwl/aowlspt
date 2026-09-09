# Native menu-screen navigation (offline metadata study)

Build: GameAssembly.dll 1.1.0.1.46777, imagebase `0x180000000`.
All RVAs below produced by `tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll
.cache/global-metadata.dec.dat <verb>`; every one byte-verified with `bytes` and
classified with `shared`. `tools/fldoff.py` self-check
(`System.String._stringLength@0x10 / _firstChar@0x14`) **PASSED** before any offset
here was trusted. The game was never run.

Everything marked **measured** came out of those tools or out of capstone
disassembly of the bytes at the stated RVA. Everything else says **inferred**.

---

## 1. Headline verdict

**Screen-jumping is the WRONG lever. FAIL as a strategy; the working lever is the
matchmaker *operation*, not the screen.** (measured, see §5)

The matchmaker chain is **event-driven, not screen-driven**. Screens are views
constructed by `EFT.MatchmakerOperation`; the raid state is committed by
`MatchmakerOperation::Ready()`, which is reached from `OnReadyPressed()`. Calling a
`ShowScreen` with a later screen id would render a view whose backing controller was
never constructed and whose `RaidSettings` were never written — exactly the false
positive CLAUDE.md §9b warns about.

**PASS (metadata-level) for driving the flow by calling `MatchmakerOperation`
methods directly.** Unknowns and the experiments that settle them are in §7.

---

## 2. The screen-driving machinery

### `EFT.MainMenuShowOperation::ShowScreen(EMenuType screen, bool turnOn)`

| | |
|---|---|
| RVA | `0x9F8100` (VA `0x1809F8100`) |
| Derived signature | `void ShowScreen(EFT.UI.EMenuType screen, bool turnOn)` — arity 2, instance |
| Sharedness | **UNIQUE** (owners=1) |
| Section | `il2cpp` |
| First 16 bytes | `48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 4C` |
| Thunk shape | none matched — real body (not the `C2 00 00` universal stub) |

ABI: `RCX=this(MainMenuShowOperation)`, `EDX=EMenuType`, `R8B=turnOn`, `R9=MethodInfo*`
(NULL ok — not generic). (measured signature; ABI **inferred** from the standard rule)

This **is** the ShowScreen our host already postfixes. Body is a 23-entry jump table
on `EMenuType` at `0x9F8B00` (measured). Case `Play (0)` is literally:

```
009f8278 mov  rcx, [rdi + 0x118]        ; MainMenuShowOperation.<Matchmaker>k__BackingField
009f8288 xor  edx, edx                  ; MethodInfo* = NULL
009f828a call 0x180a2e100               ; MatchmakerOperation::ShowMatchmakerSideSelection
```

So `ShowScreen` is a *dispatcher into the operations*, not a screen stack.
`MainMenuShowOperation.<Matchmaker>k__BackingField @ 0x118` (measured, fldoff).

### `EFT.UI.EMenuType` (measured, `enum` verb)

`Play=0 Player=1 Trade=3 Chat=4 Handbook=5 Settings=6 Exit=7 Logout=8 HideScreen=9
EditBuild=10 Hideout=11 Reconnect=12 RagFair=13 GoInRaid=14 NewsHub=16
FinalStatistics=17 PlayerQuestsScreen=19 Expansions=20 Seasons=21 SwitchCharacter=22
MainMenu=100`

There is **no matchmaker-chain member** here: no side-select, no location, no accept.
`EMenuType` cannot express "go to the location screen". (measured)

### `EFT.UI.Screens.EEftScreenType` — the screen id, and why it is not a lever

The real screen identifier is `EEftScreenType`. Matchmaker-chain members (measured):

| value | name |
|---|---|
| 34 | `SelectRaidSide` |
| 35 | `SelectLocation` |
| 36 | `KeyAccess` |
| 37 | `MapPoints` |
| 38 | `MatchMakerAccept` |
| 39 | `Insurance` |
| 40 | `TimeHasCome` |
| 41 | `OfflineRaid` |
| 42 | `FinalCountdown` |

(Full enum has 58 members, `None=0` … `Seasons=57`.)

But `EEftScreenType` is only a **read-only property** on a controller
(`get_ScreenType`), and every `ShowScreen(EScreenState)` that consumes it lives on
`ScreenController\`2` / `IBaseScreenController\`1` — **generic definitions whose RVA is
`None`** (measured). There is no non-generic entry point that takes an
`EEftScreenType` and shows it. The only `EEftScreenType`-taking concrete method is:

* `EFT.UI.Screens.EftScreenManager::ReturnToSpecificScreen(EEftScreenType)` —
  RVA `0x172DFC0`, **UNIQUE**, bytes `48 89 5C 24 10 56 48 83 EC 20 80 3D BF 04 99 05`,
  real body. Name and semantics say it pops **back** to an already-created screen; it
  is **inferred** to be useless for advancing forward.

**Shared-generic hazard:** `ScreenController\`2::ShowScreen` is an uninstantiated
generic. Its per-instantiation code is not reachable offline, and a NULL `MethodInfo*`
is *not* acceptable for shared generics. Do not attempt to call it.

The actual show is done by **virtual dispatch**, measured inside
`<ShowMatchmakerSideSelectionInternal>d__34::MoveNext` @ `0xA345C0`:

```
00a3480e mov  r8, [rbx]            ; controller klass
00a34811 mov  rax, [r8 + 0x2f8]    ; vtable slot -> ShowScreen(EScreenState)
00a3481f mov  edx, 1               ; EScreenState = 1
00a34827 call rax
```

i.e. vtable slot `+0x2F8` on `RaidSideSelectionScreenController` (measured). Calling
that by hand requires a live controller instance — which only exists if the flow
built it. That is the whole point.

---

## 3. The real chain: `EFT.MatchmakerOperation` (type 8022)

All instance, **arity 0**, so the call is just `RCX=this, RDX=NULL MethodInfo*`.
All **UNIQUE**, all in `il2cpp`, none is the empty-body stub. (measured)

| method | RVA | first 16 bytes |
|---|---|---|
| `void ShowMatchmakerSideSelection()` | `0xA2E100` | `40 53 48 83 EC 70 80 3D 5E B1 68 06 00 48 8B D9` |
| `Task ShowMatchmakerSideSelectionInternal()` | `0xA2E340` | — |
| `Task ShowMatchmakerLocationSelection()` | `0xA31480` | `40 53 48 83 EC 70 80 3D F6 7D 68 06 00 48 8B D9` |
| `void ShowMatchmakerMapPointsScreen()` | `0xA30AA0` | `40 56 48 83 EC 40 80 3D D2 87 68 06 00 48 8B F1` |
| `void ShowMatchmakerInsuranceScreen()` | `0xA2EE60` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `void ShowMatchmakerAcceptScreen()` | `0xA2EFF0` | `40 56 48 83 EC 40 80 3D 77 A2 68 06 00 48 8B F1` |
| `void ShowMatchmakerOfflineRaidScreen()` | `0xA30F80` | `40 56 48 83 EC 20 80 3D F4 82 68 06 00 48 8B F1` |
| **`void OnReadyPressed()`** | `0xA312E0` | `40 53 48 83 EC 20 80 3D 95 7F 68 06 00 48 8B D9` |
| `Task Ready()` | `0xA2ECB0` | `40 53 48 83 EC 70 80 3D B5 A5 68 06 00 48 8B D9` |
| `void ResetReadyState()` | `0xA31630` | — |
| `bool CanShowInsuranceScreen()` | `0xA2EA60` | — |

Fields (measured, fldoff): `_raidSettings@0x40`, `_offlineRaidSettings@0x48`,
`_session@0x50`, `_readyPressed@0x60`, `OnReadyToStartMatching@0x38`.
NOTE: four inherited `Comfort.Common.AbstractOperation`/`Operation` fields have
**obfuscated names** (U+E000 private-use) — the "names are real" fact does not hold
for every inherited field.

### Getting `this`

* `EFT.TarkovApplication::get_MatchmakerOperation()` — RVA `0x977360`, **UNIQUE**,
  bytes `40 55 48 83 EC 40 80 3D 80 1B 74 06 00 48 8B E9`, real body. (measured)
* or `MainMenuShowOperation + 0x118`. (measured)
* `TarkovApplication::get_CurrentRaidSettings()` — RVA `0x691340` is
  **SHARED, owners=36** (`mov rax,[rcx+0xD8]; ret`). **Safe to CALL, NEVER detour.**
  Equivalently read `TarkovApplication + 0xD8`. (measured)

---

## 4. Side selection

### What the character slot's click actually calls

`EFT.UI.Matchmaker.MatchMakerSideSelectionScreen::SetSelectedSide(ESideType side)`
— RVA `0x1791FB0`, **UNIQUE**,
bytes `48 89 5C 24 18 57 48 83 EC 30 80 3D 4E C7 92 05 00 8B FA 48 8B D9 75 3A ...`,
real body. Reached by tail-jump from `<Awake>b__41_3` (`0x1792490`) and
`<Awake>b__41_4` (`0x1792530`), which are the toggle handlers. (measured)

**It is UI-only.** Disassembly shows it write `[this+0x160] = side` and then only call
`LocalizationManager`, `SetObjectVisibility`, `GUISounds::PlayUISound`, `Toggle::Set`,
`AnimatedToggle::TriggerAnimation`. **It does not touch `RaidSettings`.** (measured)

### What actually commits the side

`RaidSideSelectionScreenController::UpdateSideSelection(ESideType side)`
— RVA `0x17929D0`, **UNIQUE**,
bytes `48 83 EC 28 48 8B 41 70 48 85 C0 74 08 89 50 20`, real body. That is literally
`RaidSettings = [this+0x70]; if (RaidSettings) RaidSettings->[0x20] = side;` (measured)

Cross-checked with fldoff:
* `RaidSideSelectionScreenController.RaidSettings @ 0x70` (measured)
* `EFT.RaidSettings.<Side>k__BackingField @ 0x20`, type `ESideType` (measured)

So **`UpdateSideSelection` is a two-instruction field write.** There is no reason to
call it at all: write `RaidSettings + 0x20` directly (guarded read-validate-write).

### `EFT.ESideType` (measured, `enum` verb)

```
Pmc = 0        Savage = 1        Random = 2
```

"PMC" is `0`. There is **no `Pve` member** — the PVE/PMC split on that screen is not
`ESideType`; `RaidSettings.SelectedGameModes@0x10` (`Dictionary<string,bool>`) and
`_onlinePveRaidStates@0x28` / `IsPveOffline@0xa0` are the PVE carriers (measured
fields; their **semantics are inferred**).

`xref` scan of the whole `il2cpp` section for direct `E8/E9` calls to
`UpdateSideSelection` and to `ShowMatchmakerLocationSelection`: **0 callers each**
(measured) — both are invoked only through delegates/vtables, which is consistent with
calling them directly being harmless to other call sites.

---

## 5. Does a screen jump advance state? — the decisive evidence

`<Ready>d__40::MoveNext` @ `0xA32E30` (the body of `MatchmakerOperation::Ready`) calls,
in order (measured):

```
MatchmakerPlayersController::SetProcessingReadyButtonPress
MatchmakerOperation::LocationKeyCheck
MatchmakerOperation::ItemsRestrictionCheck
MatchmakerOperation::SelectedLocationGroupSizeCheck
ProfileInfo::GetLevel
LocationLevelVariants::ResolveByPlayerLevel
RaidSettings::set_SelectedLocation      (0x6D7FF0, UNIQUE)
RaidSettings::get_OnlinePveRaid
RaidSettings::set_SelectedLocation
RaidSettings::Apply                     (0x6D8E70, UNIQUE, bytes 48 89 5C 24 08 57 48 83 EC 20 48 8B FA 48 8B D9)
AFKMonitor::Stop
...then fires OnReadyToStartMatching
```

and `TarkovApplication::OnReadyToStartMatchingAsync()` — RVA `0x983830`, **UNIQUE**,
bytes `40 53 48 83 EC 70 80 3D 0A 57 73 06 00 48 8B D9` — is the sink. (measured)

**Conclusion (measured):** all raid state — resolved `Location`, `RaidSettings.Apply`,
the ready gate — is written by `Ready()`, not by any screen. A `ShowScreen`-style jump
to `MatchMakerAccept`/`OfflineRaid`/`FinalCountdown` would show a view over unwritten
state. **Do not do it.**

`OnReadyPressed()` @ `0xA312E0` = `SelectedLocationGroupSizeCheck` →
`ItemUiContext::CanShowUnloadItemsWindow` → `Ready()` (measured). It is the honest
single entry point that both validates and commits.

---

## 6. Recommended native path (replaces the UI clicking)

1. `TarkovApplication::get_MatchmakerOperation()` @ `0x977360` → `mmOp`.
2. `raidSettings = *(void**)(mmOp + 0x40)`; validate readable.
3. Write `*(int32*)(raidSettings + 0x20) = 0` (`ESideType.Pmc`) — read, validate, write.
4. Write `raidSettings + 0x30` (`LocationId`, `string`) with `il2cpp_string_new`, and
   `raidSettings + 0xa0` (`IsPveOffline`, bool) as wanted. **inferred** — see §7.
5. Call `MatchmakerOperation::OnReadyPressed()` @ `0xA312E0` (`RCX=mmOp, RDX=NULL`).

Every step: prologue byte-verify against the §2–§4 bytes, `aowl_is_readable` on each
hop, one outer `aowl_p_p_seh`, flag-gated default OFF, self-disable after N faults.
None of these methods is generic → NULL `MethodInfo*` is fine. None is SHARED → no
detour blast radius if we ever hook rather than call.

---

## 7. Unknowns, and the exact experiment for each

| # | Unknown | Status | Experiment |
|---|---|---|---|
| 1 | Does `OnReadyPressed` work when the location screen was never shown (i.e. is `LocationId` alone enough for `ResolveByPlayerLevel`)? | **INCONCLUSIVE** | Live inspector: `read $mmop+0x40 ptr`, then `read <rs>+0x30 str` after the flow reaches side-select. If `LocationId` is already non-null at side-select, step 4 is unnecessary; if null, write it and `call` `0xA312E0`, then read `<rs>+0xa8` (`_selectedLocation`) back — non-null = the state was really committed. |
| 2 | Is `mmOp` non-null at the moment we are on the side-select screen? | **INCONCLUSIVE** | `read $tarkovapp` → call `0x977360` via inspector `call`, or read `MainMenuShowOperation+0x118`. |
| 3 | Which field expresses "PVE zone" vs "PMC" on that screen (`SelectedGameModes` dict vs `IsPveOffline` vs `_onlinePveRaidStates`) | **INCONCLUSIVE** (fields measured, meaning inferred) | Read all three off `RaidSettings` once on the PVE slot and once on the PMC slot and diff. Negative assertion: after our write, `RaidSettings` must differ from the pre-write snapshot in exactly the field the human click changes. |
| 4 | Does `Ready()` need `MatchmakerPlayersController` to be initialised (it calls `SetProcessingReadyButtonPress` first)? | **INCONCLUSIVE** | Read `mmOp+0xa0` (`<MatchmakerPlayersController>k__BackingField`) before calling; refuse if null. |
| 5 | Is there a profile/session flag that skips side-select entirely? | **NOT SUPPORTED BY METADATA** — nothing found. `ApplyUnlockAllLocationsEditorDebug` exists but resolves to `0x628110`, the universal `C2 00 00` empty-body stub, so it does nothing. (measured) | none proposed |

**Verdict: INCONCLUSIVE→PASS-pending.** Native *screen jumping* is FAIL (§5). Native
*operation driving* is metadata-PASS and blocked only on unknowns 1–4, each of which is
one live-inspector read away and none of which needs a rebuild.

---

## Tool defect noticed (CLAUDE.md §10)

`tools/fldoff.py fields EFT.MatchmakerOperation` **crashes** with
`UnicodeEncodeError: 'charmap' codec can't encode character '\ue000'` — several
inherited `Comfort.Common.*` field names contain U+E000. It dies after printing the
header, so the failure looks like "type has no fields" if you are not watching stderr.
Workaround used here: `PYTHONIOENCODING=utf-8`. Suggested fix: force UTF-8 on stdout
in `fldoff.py`/`il2cpp_resolve.py` (`sys.stdout.reconfigure(encoding="utf-8",
errors="backslashreplace")`).
