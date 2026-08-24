# Where the post-1.0 settings screen keeps its created controls

**Status: SOLVED offline.** Disassembly + metadata only; the game was never run
for this note. Every address is an RVA in `GameAssembly.dll`
(imagebase `0x180000000`, so VA = RVA + `0x180000000`).

Three live deploy-and-click cycles were spent disproving three guesses. The
reason none of them found the controls is now a two-line fact rather than a
suspicion:

> `SettingsScreen::ShowScreen` calls `EnsureTabInitialized` and **then**, three
> instructions later, tail-jumps into `SettingsTab::set_IsSelected(true)` — and
> it is *that* call, not `EnsureTabInitialized`, that builds the controls. The
> Phase-1.5 postfix hook was firing roughly 20 instructions too early, on the
> wrong object.
>
> And only the **selected** tab is ever built. Four of the five
> `_createdControls` lists are legitimately null at any moment.

---

## 1. Who populates `_createdControls`, and when

### 1a. The write itself — `SettingsTab::CreateControl<T>` @ `0x2B86E20`

`CreateControl<T>` has no per-definition RVA (metadata says `None`) because it is
generic. Every `T` here is a reference type (`SettingToggle`,
`SettingFloatSlider`, `SettingSelectSlider`, `SettingDropDown`, …), so IL2CPP
emits **one** shared body, which is reached by direct `call` from the concrete
`Show*` helpers. Located by following a caller rather than by walking
`Il2CppGenericMethodTable`:

`GameSettingsTab::ShowHeadBobbing` (`0x1706430`):

```
+0x1706543: mov  r9,  qword ptr [rip + 0x565bfbe]   ; MethodInfo* for the instantiation
+0x170654a: mov  rcx, rdi                            ; this  = the tab
+0x170654d: mov  r8,  qword ptr [rdi + 0x98]         ; parent transform
+0x1706554: mov  rdx, qword ptr [rdi + 0xa8]         ; prefab
+0x170655b: call 0x182b86e20                         ; SettingsTab::CreateControl<T> (gshared)
```

And inside that shared body, the lazy list creation and the store — `rsi` is
`this`, i.e. the tab, moved from `rcx` at `+0x2b86e40`:

```
+0x2b86e40: mov  rsi, rcx                            ; rsi = this (SettingsTab)
...
+0x2b86fc9: cmp  qword ptr [rsi + 0x88], 0           ; _createdControls == null?
+0x2b86fd1: jne  0x182b870bb                         ;   no -> straight to Add
+0x2b86fd7: mov  rcx, qword ptr [rip + 0x41c8df2]    ; List<SettingControl> klass
+0x2b86fde: call 0x1805d9e20                         ; il2cpp object_new
+0x2b8700d: mov  edx, 8
+0x2b87015: call 0x1805d9300                         ; array_new(SettingControl[8])
+0x2b8701a: mov  qword ptr [rdi + 0x10], rax         ; list._items
+0x2b8706f: mov  qword ptr [rsi + 0x88], rdi         ; *** this._createdControls = list ***
```

This is the only writer. It runs **once per control**, synchronously, inside the
tab's `CreateControls`.

### 1b. Metadata confirmation of the offset

`fieldOffsets` was located in `Il2CppMetadataRegistration` by its
`(NTYPES, ptr, NTYPES, ptr)` signature — `fieldOffsets = 0x186B61E70`,
`NTYPES = 31282`. Dumper self-checks against `System.String _stringLength=0x10 /
_firstChar=0x14` before printing anything (`tools/fldoff.py`).

```
EFT.UI.Settings.SettingsTab (type 15717)
    OnLoadingInProgress                 0x80
    _createdControls                    0x88     <-- confirmed
    <IsInitialized>k__BackingField      0x90     <-- the "first-select latch"
```

So `+0x90` is not an ad-hoc latch: it is the `IsInitialized` auto-property
backing field, which `SettingsTab::Close` (`0x171BDF0`) and
`SettingsTab::ResetInitialization` (`0x14F3560`) clear.

### 1c. The caller chain, end to end

```
SettingsScreen::ShowScreen            0x1720DE0   (rcx = screen, edx = ESettingsGroup)
  +0x1720EE0  call 0x171BCA0          SettingsTab::set_IsSelected(oldTab, false)
  +0x1720F00  call 0x171FF10          SettingsScreen::EnsureTabInitialized(this, group)
                                        -> direct-calls each tab's Show(); builds NO controls
  +0x1720F4E  mov [rbx+0x118], rcx    _currentTab = the newly chosen tab
  +0x1720FC1  jmp 0x171BCA0           *** tail-jump: set_IsSelected(newTab, true) ***

SettingsTab::set_IsSelected            0x171BCA0   (rcx = tab, dl = value)
  +0x171BD1C  cmp byte [rbx+0x90], 0   IsInitialized?
  +0x171BD2B  mov byte [rbx+0x90], 1
  +0x171BD32  mov rax, [rdx+0x2C8]     *** vtable slot -> OnFirstSelect ***
  +0x171BD39  mov rdx, [rdx+0x2D0]     (its MethodInfo*)
  +0x171BD40  call rax
  +0x171BD48  mov rax, [rdx+0x2D8]     *** vtable slot -> OnSelect ***  (every select)
  +0x171BD56  call rax

GameSettingsTab::OnFirstSelect         0x1703CB0
  ... builds the BlockController ...
  +0x1703E25  jmp 0x1703FB0            GameSettingsTab::CreateControls  (tail jump)

GameSettingsTab::CreateControls        0x1703FB0
  -> Show*() helpers -> CreateControl<T> @0x2B86E20 -> writes [tab+0x88]
```

All five tabs build synchronously from `OnFirstSelect`; verified individually:

| tab | `OnFirstSelect` | how it builds |
|---|---|---|
| Game | `0x1703CB0` | tail-`jmp` → `CreateControls` `0x1703FB0` |
| Graphics | `0x170A8B0` | inlines `CreateControls`: `call CreateBlockers 0x170AA50`, then `ShowResolution`, `ShowAspectRatio`, … |
| PostFX | `0x1719490` | `call CreateBlockers 0x1719540`, `ShowEnablePostFx`, `ShowBrightness`, … |
| Sound | `0x171C400` | 4× `call ShowSettingSelectSlider 0x171D0F0` |
| Controls | `0x16FFF80` | `call CreateControls 0x16FD990`, then `jmp rax` (the `OnSelect` slot) |

### 1d. The vtable slot, and why nothing "xrefs" it

`OnFirstSelect` is invoked through **klass vtable slot at byte offset `0x2C8`**
(its `MethodInfo*` at `0x2D0`); `OnSelect` is the next slot, `0x2D8` / `0x2E0`.
IL2CPP `VirtualInvokeData` is 16 bytes `{methodPtr, method}` and the vtable
begins at `Il2CppClass + 0x138` (corroborated by the `test byte [rax+0x135], 1`
class-initialised check the generated code emits everywhere, e.g.
`+0x2b86ec1`). So:

* `OnFirstSelect` = vtable index **25** (`0x138 + 25*16 = 0x2C8`) ✔
* `OnSelect`      = vtable index **26** (`0x138 + 26*16 = 0x2D8`) ✔

A pattern scan of the whole `.text` + `il2cpp` segments for
`mov r64,[reg+0x2C8]` immediately followed by a `+0x2D0` load finds exactly two
sites inside the settings UI:

```
0x171BD32  EFT.UI.Settings.SettingsTab::set_IsSelected
0x171BDBC  EFT.UI.Settings.SettingsTab::OnTabSelected      <-- the dead one
```

(All other hits are unrelated classes whose slot `0x2C8` means something else.)

`OnTabSelected` (`0x171BDA0`) is byte-for-byte the same logic as the tail of
`set_IsSelected` and has zero callers — confirming the earlier finding that it is
dead code in this build. **Therefore `set_IsSelected` is the only live invoker of
`OnFirstSelect`, and `ShowScreen` is its only caller** (a single-caller xref over
the `il2cpp` segment: `0x1720EE0 -> 0x171BCA0`). Since the settings screen
demonstrably *does* show controls in game, `ShowScreen` demonstrably runs.

A raw data scan for the qword `0x181720DE0` / `0x18171BCA0` / `0x181703CB0`
finds exactly one hit each, and each sits inside the contiguous
`Il2CppCodeGenModule.methodPointers` run — i.e. these methods have **no** static
vtable/ldftn reference anywhere, because IL2CPP builds vtables at runtime from
metadata. "No xrefs" here means "dispatched", not "dead"; `OnTabSelected` is dead
for the separate reason that no slot-`0x2C8` invoker other than `set_IsSelected`
exists.

---

## 2. Why `EnsureTabInitialized` pre-warms all five yet the list is still null

Nothing is deferred. There is no coroutine, no async continuation, no
`Update`-frame delay, and no toggle callback. Two plain facts explain it:

1. **Ordering.** `EnsureTabInitialized` is called at `+0x1720F00`; the call that
   creates controls is the tail-jump at `+0x1720FC1`, ~50 bytes later in the same
   function. A postfix on `EnsureTabInitialized` returns to `+0x1720F05` — before
   `_currentTab` has even been assigned.

2. **Scope.** `EnsureTabInitialized` is a 5-way switch that only calls the tab's
   **`Show(...)`** (direct `call`s, visible in the disassembly:
   `0x171FFF9 -> PostFXSettingsTab::Show`, `0x17200D3 -> SoundSettingsTab::Show`,
   `0x1720141 -> GameSettingsTab::Show`, plus two vtable-dispatched arms for
   graphics/controls). `GameSettingsTab::Show` (`0x17037A0`) was read end to end:
   it stores the session/profile/customization args, wires the nickname field,
   calls `SetLocalProfile`, `RefreshNickname`, `ValidateCurrentInput`,
   `RefreshNicknameCooldownMessage` — and **never** touches `OnFirstSelect`,
   `CreateControls`, or `[this+0x88]`.

   The `+0x138` HashSet (`_initializedTabs`, metadata-confirmed) only stops
   `Show` being re-run; it has nothing to do with control creation.

Consequence worth stating plainly: **at most one tab has a non-null
`_createdControls` at any time — the one currently selected.** A census that
expects all five to fill will always report four nulls, forever. The
`_createdControls` of a previously-visited tab does survive (it is only cleared
by `CleanupCreatedControls` from `Close`), so after visiting several tabs several
lists are populated; but on first open exactly one is.

---

## 3. The single best hook

### Recommended: `EFT.UI.Settings.SettingsScreen::ShowScreen` @ RVA `0x1720DE0`, POSTFIX

* **(a) Does it definitely run?** Yes. It is the sole caller of
  `SettingsTab::set_IsSelected`, which is the sole live invoker of the
  `OnFirstSelect` vtable slot, which is the only path to `CreateControls`. Since
  the screen visibly builds controls, this method runs — on every tab click and
  on the initial open.
* **(b) Does it run after the controls exist?** At postfix, yes. The final
  `jmp 0x18171BCA0` is a tail-jump, so `set_IsSelected`'s `ret` returns to
  `ShowScreen`'s caller, i.e. through the detour's return trampoline. By the time
  the postfix runs, `OnFirstSelect` → `CreateControls` → `CreateControl<T>` have
  all completed.
* **(c) Is a tab object in a register?** `RCX` = the `SettingsScreen`, `EDX` =
  the `ESettingsGroup` index. The tab itself is at `[RCX+0x118]` (`_currentTab`),
  which `ShowScreen` writes at `+0x1720F4E`, i.e. *before* the tail-jump — so it
  already names the tab whose controls were just built. `EDX` independently maps
  to the same tab through the group→field table already in
  `abi/aowlspt_settingsui.h`, giving a free cross-check.

**Prologue (byte-verified against `D:\Games\Tarkov\GameAssembly.dll`):**

```
0x1720DE0:  48 89 5C 24 08        mov  qword ptr [rsp+0x08], rbx      (5)
            48 89 74 24 10        mov  qword ptr [rsp+0x10], rsi      (5)  -> 10
            57                    push rdi                            (1)  -> 11
            48 83 EC 30           sub  rsp, 0x30                      (4)  -> 15
            80 3D 2B D6 99 05 00  cmp  byte ptr [rip+0x0599D62B], 0   (7)  -> 22
```

First 16 bytes for the `AowlBridgeTarget.sig` memcmp:

```
48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 80
```

**Steal quality: the cleanest of any settings target so far.** `AOWL_JMP_SIZE`
is 14, and the first instruction boundary at or past 14 is **15** — so the
detour steals 15 bytes consisting of four instructions, **none of which has a
RIP-relative operand**. No displacement fixup is needed at all (unlike `Show`
and `EnsureTabInitialized`, whose steals both cut through a
`cmp byte [rip+…], 0`). All four are in the decoder's core tables
(`89 /r` with `disp8`, `push r64`, `83 /5 ib` with REX.W).

### Backup: `EFT.UI.Settings.SettingsTab::set_IsSelected` @ RVA `0x171BCA0`, POSTFIX

Innermost guaranteed frame; `RCX` is the tab **directly** (no `_currentTab`
hop), `DL` is the value (walk only when `dl != 0`). Fires twice per tab switch
(deselect old, select new).

```
0x171BCA0:  48 89 5C 24 10        mov  qword ptr [rsp+0x10], rbx      (5)
            56                    push rsi                            (1)  -> 6
            48 83 EC 20           sub  rsp, 0x20                      (4)  -> 10
            48 8B 05 37 88 9B 05  mov  rax, qword ptr [rip+0x059B8837](7)  -> 17
```

sig16: `48 89 5C 24 10 56 48 83 EC 20 48 8B 05 37 88 9B`.
Steal = **17** bytes, and the last instruction **is RIP-relative** — the copier
must fix its displacement, exactly as it already does for the `cmp byte [rip]`
in the two existing settings targets. Slightly more machinery than `ShowScreen`
for no extra information, hence second choice.

### Explicitly not recommended

* `SettingsScreen::Show` (`0x171FA00`) — Phase 1's target; runs before any tab
  is selected. Proven wrong live and now proven wrong statically.
* `SettingsScreen::EnsureTabInitialized` (`0x171FF10`) — Phase 1.5's target;
  wrong by ~50 bytes of the *same* function, and only ever calls `Show`.
* `SettingsTab::OnTabSelected` (`0x171BDA0`) — dead code, zero live invokers of
  its slot pattern.
* `SettingsScreen::OpenGroup` (`0x1720C80`) — plausible-looking, but it is a
  separate method with no callers found and it is *not* on the path
  `ShowScreen` takes; do not use it.

---

## 4. Per-control field layout, confirmed from metadata (not from a live run)

All of the following come from `fieldOffsets` + the metadata field table, with
the `System.String` self-check passing on every invocation:

```
EFT.UI.Settings.SettingControl (type 15652)
    Text                       0x80    (LocalizedText)      <-- confirmed
    _blocker                   0x88
    NotifyUserChanged          0x90
    _tooltipSettingsHover      0x98
    _elementBlocker            0xA0

EFT.UI.LocalizedText (type 14184)
    localizationKey            0x70
    _labels                    0x78    (List<TextMeshProUGUI>)  <-- confirmed
    _stringCase                0x80
    _formatTemplate            0x88
    _formatValues              0x90
    _localeUnsubscriber        0x98
    <FormattedText>k__Backing  0xA0

TMPro.TMP_Text (type 25471)
    m_text                     0xE0    (System.String)      <-- confirmed

EFT.UI.Settings.SettingsScreen (type 15735)
    _gameSettingsScreen        0xF0    _graphicsSettingsScreen  0xF8
    _postFXSettingsScreen     0x100    _soundSettingsScreen    0x108
    _controlsSettingsTabScreen 0x110   _currentTab             0x118
    _session                  0x120    _profileInfo            0x128
    _customization            0x130    _initializedTabs        0x138
    _tabs                       0x0    (static)
```

Every offset already hard-coded in `abi/aowlspt_settingsui.h` reproduces exactly.
The chain `SettingControl.Text(+0x80) -> LocalizedText._labels(+0x78) ->
List._items(+0x10) -> array elems(+0x20) -> TMP_Text.m_text(+0xE0) ->
String._stringLength(+0x10)/_firstChar(+0x14)` is **fully confirmed offline**.

### Telling widget kinds apart

The four concrete subclasses each keep their widget at `+0xA8`, confirmed:

| type index | class | field at `+0xA8` | widget type |
|---|---|---|---|
| 15659 | `EFT.UI.Settings.SettingDropDown` | `DropDown` | dropdown |
| 15662 | `EFT.UI.Settings.SettingFloatSlider` | `Slider` | continuous slider |
| 15668 | `EFT.UI.Settings.SettingSelectSlider` | `Slider` | discrete/stepped slider |
| 15677 | `EFT.UI.Settings.SettingToggle` | `Toggle` | toggle |
| 15652 | `EFT.UI.Settings.SettingControl` | *(base — no `+0xA8`)* | — |

**Caveat, stated honestly:** the *type indices* above are metadata truth, but
`Il2CppClass*` pointers are allocated at runtime and therefore cannot be given
offline — there is no static klass array in the PE (the single data reference to
each of these methods is its `methodPointers` slot, nothing else). The
reflection-free runtime discriminator is `klass->name`, a `const char*` at
**`Il2CppClass + 0x10`** in this version's layout. That offset is inferred from
the layout the generated code already corroborates (`initialized_and_no_error`
byte at `+0x135`, vtable base at `+0x138` — both proven above by the `0x2C8` /
`0x2D8` slot arithmetic), not measured directly. **This is the one item in this
document that still wants a single live confirmation**, and it is free: the
probe already logs each control's klass pointer, so one run prints the five
distinct klass values and a `+0x10` C-string read next to them settles it.

---

## 5. Verdict on the Phase-1.7 poll (`5b055d4`, branch `feat-settings-phase1`)

**It would have worked, and it was targeting the right object and the right
offset.** Polling `_createdControls` (`+0x88`) on every registered tab from a
`GameSettingsTab::Update` prefix is sound: creation is synchronous, so a poll
that runs on any later frame sees the finished list, and `+0x88` is the correct
field on the correct base class.

Two reasons it is still worth replacing rather than shipping:

1. Its census would have reported "4 of 5 tabs null" and looked like a partial
   failure, when that is in fact the correct steady state (§2).
2. It only ticks while `GameSettingsTab::Update` runs, i.e. while the Game tab's
   MonoBehaviour is enabled — it can miss, or lag, a tab whose controls are built
   while a different tab drives the frame.

So the poll is not *wrong*; the `ShowScreen` postfix is simply exact. This branch
retargets to `ShowScreen` and keeps every guard, cap and VEH wrapper the
Phase-1.5 code already had. The `feat-settings-phase1` poll remains a valid
fallback if the postfix somehow does not fire.

---

## What remains unproven without a live run

Being explicit, because three cycles were burned on things that looked proven:

1. **That the detour's postfix survives a tail-jump exit.** The mechanism
   (return-address capture at entry) says yes, and `set_IsSelected` returns
   normally, but no settings target has previously been hooked on a
   tail-jumping function. If the postfix does not fire, switch to the backup
   (`set_IsSelected`, `0x171BCA0`), whose exit is an ordinary `ret`.
2. **`Il2CppClass->name` at `+0x10`** (§4 caveat).
3. **That `ShowScreen` is on the *initial-open* path** as well as the tab-click
   path. It must be, because the first tab shown has controls and only
   `set_IsSelected` can create them — but the *identity of ShowScreen's own
   caller* is genuinely unknowable offline (it is dispatched, with no static
   reference), so this is inference, not observation.

Everything else in this document is byte-level or metadata fact.

## Tooling used

* `tools/il2cpp_resolve.py` — type/method RVAs (BE self-check passes).
* `tools/fldoff.py` — field-name → offset via
  `Il2CppMetadataRegistration.fieldOffsets` (`0x186B61E70`), self-checked
  against `System.String`. (This was cited as `scratchpad/fldoff.py (new)`,
  which was never committed and does not exist; the path above is the real,
  committed tool.)
* `scratchpad/disa2.py` — annotated capstone disassembly with RVA→name.
* `scratchpad/xref2.py` — direct-`E8` xrefs over `.text` **and** `il2cpp`.
* Ad-hoc scans: `mov r64,[reg+0x2C8]`+`0x2D0` pattern (vtable-slot invokers) and
  absolute-qword data references (delegate/ldftn references).
