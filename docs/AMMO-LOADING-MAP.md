# The in-raid reload / magazine-load path — complete offline map

Build: `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes, 2026-08-12),
decrypted metadata `.cache/global-metadata.dec.dat` (27,776,072 bytes).
Imagebase `0x180000000`; every address below is an **RVA** unless written `VA`.
Runtime address = `GameAssemblyBase + RVA`.

**Instrument for every MEASURED line:**

```
python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat <verb> ...
```

abbreviated below as `R <verb>`. Verbs used: `find`, `typemethods`, `methods`,
`callers`, `shared`, plus `Resolver.code_bytes` / `section_of_rva` /
`sharedness` in-process for the prologue table in §6.

Every statement is tagged **MEASURED**, **INFERRED** or **UNVERIFIED**.
Nothing here has been observed live yet — §7 is the live experiment this map
exists to make possible, and until it runs, every "this is the path the player
takes" claim in §2–§4 is **offline structure, not observed behaviour**.

---

## 0. Why this document exists — the wrong answer it replaces

The `ammoloading` mod bound its probe to `LoadMagazineProcess::Start`
@`0x768F50` and a broad probe to `LoadMagazineProcess::.ctor` @`0x768D40`.
Across a full raid in which the player loaded and unloaded magazines, the
host log printed, every 30 s (instrument: `aowlspt-host.log`, the mod's own
`reportText`):

> `ammoloading  ARMED but NEVER FIRED. mode=probe … LoadMagazineProcess::Start
> @0x768F50 has been entered ZERO times and the broad probe
> LoadMagazineProcess::.ctor @0x768D40 is installed, never fired`

Both hooks were prologue-verified and installed. So this is *installed and
never entered*, and the type identification was wrong.

**MEASURED, and it explains the zero exactly.** `R callers 0x768d40` returns
**one** caller site:

```
0x76f587  call in <LoadMagazine>d__51::MoveNext @0x76f070 +0x517 [unique]
```

and the declaring-type walk (`Il2CppTypeDefinition.declaringTypeIndex@12` →
`typedef_of_type_va`) puts all three of them inside one enclosing type:

| type idx | nested name (MEASURED) |
|---|---|
| 6713 | `EFT.Player/PlayerInventoryController/LoadMagazineProcess` |
| 6708 | `EFT.Player/PlayerInventoryController/CheckMagazineProcess` |
| 6719 | `EFT.Player/PlayerInventoryController/UnloadMagazineProcess` |
| 6729 | `EFT.Player/PlayerInventoryController/<LoadMagazine>d__51` |

So `LoadMagazineProcess` is **the round-by-round INVENTORY magazine-filling
process** — the async state machine behind
`PlayerInventoryController::LoadMagazine(Ammo, Magazine, int, bool)`
@`0x766930`. It is reachable **only** from that one async body.

It is **not on the weapon-reload path at all.** A weapon reload never
constructs it: a reload runs `Player.FirearmController`'s reload operations
(§2, §3), which either swap the whole magazine (external mag — no per-round
ammo transfer exists) or commit an ammo delta directly (internal mag).

That is the whole defect. The old probe was a correct probe of a **different
feature**.

**Second, independent reason the old zero was guaranteed** (MEASURED, `R
typemethods 6734`): `PlayerInventoryController::LoadMagazine` is an **override**
of `EFT.InventoryLogic.ItemController::LoadMagazine(Ammo, Magazine, int, bool)`
@`0x10e5180`. Out of raid the receiving controller is not a
`PlayerInventoryController`, so the stash "load magazine" action does not run
the overriding body either. Both halves of the user's report — in-raid reload
and inventory mag filling — could miss `0x768F50`, for two different reasons.

---

## 1. Object model — who is on the path

MEASURED `R find FirearmController` / `R find InventoryController` /
`R find FirearmsAnimator`, plus the declaring-type walk above.

| type idx | full name | role |
|---|---|---|
| 6835 | `EFT.Player/FirearmController` | the local player's hands controller for a firearm. Declares every `Reload*` entry point. |
| 8726 | `EFT.ClientFirearmController` | derives from 6835. **MEASURED: it does NOT declare `ReloadMag`, `QuickReloadMag`, `ReloadWithAmmo`, `ReloadCylinderMagazine` or `ReloadBarrels`** (`R typemethods 8726`, 54 declared methods, none of those names). Those bodies are therefore the base's, one body for every local player. |
| 6734 | `EFT.Player/PlayerInventoryController` | in-raid inventory controller. Owns the `*MagazineProcess` family. |
| 12334 | `EFT.InventoryLogic.InventoryController` | out-of-raid base, derived from `ItemController`. |
| 2226 | `FirearmsAnimator` | the Animator wrapper that carries the `Reload` params. |
| 10797 | `EFT.Animations.ProceduralWeaponAnimation` | procedural weapon sway/aim. MEASURED `R typemethods 10797`: its only reload-related members are `set_TacticalReload(bool)` `0xebbb70`, `get_TacticalReload` `0xebbb80`, `UpdateTacticalReload` `0xec5ac0`, `ApplyTacticalReloadTransformations` `0xec99b0` (all UNIQUE). These are a **pose flag**, driven from `BaseReloadOperation::TacticalReload` `0x793640`, not a reload-start signal — the setter fires for `true` *and* `false`. Deliberately NOT bound; recorded so the next reader does not have to re-check. |
| 12143 | `EFT.InventoryLogic.Magazine` | the magazine item. |
| 11730 | `EFT.InventoryLogic.AmmoPack` | the source-ammo bundle passed to internal-mag reloads. |
| 14701 | `EFT.UI.ItemUiContext` | the out-of-raid inventory context menu backend. |

**MEASURED — the observed-player branch is a different tree.** All the
`EFT.NextObservedPlayer.Operations.Reload*HandsOperation` types (11237, 11239,
11241, 11244, 11247, 11264) are what runs for *other* players. They share no
RVA with the local operations, but they DO call the same
`FirearmsAnimator::Reload(bool)` body — see §4, which is why that site alone
is not a "the player reloaded" signal.

---

## 2. The reload entry points — `Player.FirearmController`

MEASURED `R typemethods 6835`.

| RVA | signature | slots (this+args) | sharedness |
|---|---|---|---|
| `0x7843e0` | `void ReloadMag(Magazine, ItemAddress, Callback)` | 4 | **UNIQUE** |
| `0x784570` | `void QuickReloadMag(Magazine, Callback)` | 3 | **UNIQUE** |
| `0x7848f0` | `void ReloadWithAmmo(AmmoPack, Callback)` | 3 | **UNIQUE** |
| `0x7847a0` | `void ReloadCylinderMagazine(AmmoPack, Callback, bool quickReload)` | 4 | **UNIQUE** |
| `0x784ad0` | `void ReloadBarrels(AmmoPack, ItemAddress, Callback)` | 4 | **UNIQUE** |
| `0x784690` | `void ReloadGrenadeLauncher(AmmoPack, Callback)` | 3 | UNIQUE |
| `0x7840c0` | `bool CheckAmmo()` | 1 | **UNIQUE** |
| `0x784bd0` | `bool CanStartReload(bool)` | 2 | UNIQUE (overridden at `0xb72ea0`) |
| `0x78b0d0` | `bool IsInReloadOperation()` | 1 | UNIQUE |
| `0x7784f0` | `float GetWeaponReloadAnimationSpeed()` | 1 | UNIQUE |
| `0x77b420` | `void ReloadMagNotFound()` | 1 | UNIQUE |

MEASURED `R callers 0x7843e0` and `R callers 0x784570`: **0 direct callers** —
"reached only through a vtable/delegate/event", which the tool states is a real
answer and also proves nothing inlined the body away. So the body exists and is
entered by dispatch; a prefix at the RVA is the only way to see it.

MEASURED `R callers 0x7840c0`: exactly one edge,
`EFT.ClientFirearmController::CheckAmmo @0xb70eb0 +0xb` — i.e. the client
override tail-calls the base. Probing `0x7840c0` therefore sees the local
client's ammo checks.

**The `IEventsConsumer*` ammo callbacks on 6835 are a trap.** MEASURED: the
following are all **SHARED x2** — the interface implementation and the plain
method fold to one body:

```
0x77fa80  IEventsConsumerOnAddAmmoInMag  == AddAmmoToMag
0x77fac0  IEventsConsumerOnDelAmmoFromMag == DelAmmoFromMag
0x77f9c0  IEventsConsumerOnAddAmmoInChamber == OnAddAmmoInChamber
0x77fb60  IEventsConsumerOnDelAmmoChamber == RemoveAmmoFromChamber
```

`SHARED` is `SHARED`. They are **not** eligible for a detour under the
UNIQUE-only rule, however benign the two owners look. Use the per-operation
bodies in §3 instead, which are UNIQUE.

---

## 3. The reload operations — where the ammo actually changes

MEASURED `R typemethods` on 6759 / 6801 / 6799 / 6803 / 6805 / 6798 / 6806 /
6809. All nested under `EFT.Player/FirearmController`.

### 3.1 The class tree (MEASURED, `base class:` line of `typemethods`)

```
FirearmOperation
 └─ BaseReloadOperation                       (6759)
     ├─ ReloadExternalMagOperation            (6799)   magazine SWAP
     ├─ ReloadMultiBarrelOperation            (6806)
     ├─ ReloadSingleBarrelOperation           (6809)
     └─ ReloadInternalMagBase                 (6801)
         ├─ ReloadInternalMagOperation        (6803)   round-by-round
         ├─ ReloadInternalMagWithOpenBoltOperation (6805)
         └─ ReloadCylinderMagOperation        (6798)
```

`EFT.ClientFirearmController` declares its own
`ClientPlayerReloadCylinderMagOperation` (8718),
`ClientPlayerReloadInternalMagOperation` (8719) and
`ClientPlayerReloadInternalMagWithOpenBoltOperation` (8720) and overrides
`GetOperationFactoryDelegates` @`0xb73010`. **MEASURED: there is no
`ClientPlayerReloadExternalMagOperation`** — the external-mag reload, which is
the common case, uses the base `ReloadExternalMagOperation` body directly.

### 3.2 Operation start (the animation begins here)

| RVA | method | slots | sharedness |
|---|---|---|---|
| `0x7b08f0` | `ReloadExternalMagOperation::Start(ReloadExternalMagResult, Callback)` | 3 | **UNIQUE** |
| `0x7b3580` | `ReloadInternalMagBase::Start(AmmoPack, Callback)` | 3 | **UNIQUE** — covers internal-mag, open-bolt and cylinder |
| `0x7b5ea0` | `ReloadMultiBarrelOperation::Start(...)` | 3 | UNIQUE |
| `0x7b7eb0` | `ReloadSingleBarrelOperation::Start(...)` | 3 | UNIQUE |
| `0x7937b0` | `BaseReloadOperation::Start(Callback)` | 2 | UNIQUE |
| `0x7b39d0` | `ReloadInternalMagOperation::Start(AmmoPack, Callback)` | 3 | UNIQUE (thin; the base at `0x7b3580` is the real body) |

MEASURED `R callers` on `0x7b08f0`, `0x7b3580`, `0x7b39d0`: **0 direct
callers** each — factory-delegate dispatch, nothing inlined.

### 3.3 The ammo-change sites

This is the half the feature's verdict turns on, and the two magazine kinds
are **structurally different**:

* **External magazine** — there is *no per-round ammo transfer*. The loaded
  magazine is physically swapped into the weapon. The ammo-change moment is
  `ReloadExternalMagOperation::OnMagInsertedToWeapon` @`0x7b1c70` (**UNIQUE**,
  1 slot), with `OnMagPulledOutFromWeapon` @`0x7b10d0` and `OnMagPuttedToRig`
  @`0x7b1130` either side of it. Probing an `AddAmmo`-shaped method for an
  external mag reload and reporting zero would be a check that cannot pass.
* **Internal magazine / cylinder / open bolt** — rounds move one at a time.

| RVA | method | slots | sharedness |
|---|---|---|---|
| `0x7b1c70` | `ReloadExternalMagOperation::OnMagInsertedToWeapon()` | 1 | **UNIQUE** |
| `0x7b40f0` | `ReloadInternalMagOperation::AddAmmoToMag()` | 1 | **UNIQUE** |
| `0x7b45c0` | `ReloadInternalMagOperation::CommitReloadWithAmmo(int, AmmoPack, Player, Magazine, Weapon)` | **6** | **UNIQUE** |
| `0x7af550` | `ReloadCylinderMagOperation::AddAmmoToMag()` | 1 | **UNIQUE** |
| `0x7b4fd0` | `ReloadInternalMagWithOpenBoltOperation::AddAmmoToMag()` | 1 | UNIQUE |
| `0x7b6840` | `ReloadMultiBarrelOperation::AddAmmoToMag()` | 1 | UNIQUE |
| `0x7af600` | `ReloadCylinderMagOperation::CommitReloadWithAmmo(int, AmmoPack, Player, CylinderMagazine, Weapon, List<int>)` | 7 | UNIQUE |

**`CommitReloadWithAmmo` @`0x7b45c0` has 6 slots — PREFIX ONLY.** Arguments 5
and 6 live on the *caller's* stack at `[entry_rsp+0x28+8*(n-4)]`; a POSTFIX
thunk opens its own frame and the original then reads them out of ours. That is
the crash-by-construction shape named in `CLAUDE.md` §5. MEASURED `R callers
0x7b45c0`: two edges, `SwitchToIdle @0x7b4220 +0x105` and `Commit @0x7b44a0
+0x5f` — so it is the commit point of a completed internal-mag reload, entered
from ordinary code, not from a delegate.

**SHARED sites in this family that must NOT be detoured** (MEASURED):
`BaseReloadOperation::.ctor` `0x791100` **SHARED x29`,
`ReloadCylinderMagOperation::SendReloadCommand` `0x628110` **SHARED x9614** —
that is this build's universal empty-body stub (`C2 00 00`), shared by 6,438+
methods; a signature check passes on it and it does nothing.
`ReloadInternalMagOperation::OnOnOffBoltCatchEvent` `0x7a41f0` SHARED x10.

---

## 4. The animator

MEASURED `R typemethods 2226` (`FirearmsAnimator`, 99 declared methods).

| RVA | method | slots | sharedness |
|---|---|---|---|
| `0x1c82e80` | `void Reload(bool b)` | 2 | **UNIQUE** |
| `0x1c7e7c0` | `void Reload(int currentMagType, int nextMagType, bool isFast)` | 4 | **UNIQUE** |
| `0x1c82f70` | `void ResetReload()` | 1 | UNIQUE |
| `0x1c827a0` | `void ReloadFast(bool)` | 2 | UNIQUE |
| `0x1c82a90` | `void LoadOneTrigger(bool loadOne)` | 2 | **UNIQUE** — the per-round animation trigger |
| `0x1c809d0` | `void SetAmmoOnMag(int count)` | 2 | UNIQUE |
| `0x1c812c0` | `void SetAmmoInChamber(float count)` | 2 | UNIQUE |
| `0x1c80bc0` | `void SetAmmoCountForRemove(int count)` | 2 | UNIQUE |
| `0x1c80fc0` | `void SetCamoraIndexForLoadAmmo(int)` | 2 | UNIQUE |
| `0x1c83770` | `void CheckAmmo()` | 1 | UNIQUE |
| `0x1c7f750` | `void SetBoltActionReload(bool)` | 2 | UNIQUE |

**`FirearmsAnimator::Reload(bool)` @`0x1c82e80` is the convergence point of
every reload start in the build.** MEASURED `R callers 0x1c82e80` — 13 sites,
12 `call` + 1 tail `jmp`:

```
LauncherReload::Start                                     @0x7a9050 +0x116
ReloadExternalMagOperation::Start                         @0x7b08f0 +0x280
ReloadInternalMagBase::Start                              @0x7b3580 +0xce
ReloadMultiBarrelOperation::Start                         @0x7b5ea0 +0xf6
ReloadSingleBarrelOperation::Start                        @0x7b7eb0 +0x164
FirearmsAnimator::Reload(int,int,bool)                    @0x1c7e7c0 +0x4a  (tail jmp)
+ 7 EFT.NextObservedPlayer.* HandsOperation::Start bodies
```

**Consequence, and it is the reason this site is classified `pkAnim` and not
`pkInput`:** those seven observed-player call sites mean `Reload(bool)` also
fires for **other players' reloads**. In an offline raid with bots, a non-zero
count here does **not** by itself prove the local player reloaded. The
`FirearmController::*` sites in §2 do — observed players use
`ObservedPlayerHandsController`, not `FirearmController`.

MEASURED `R callers 0x1c7e7c0`: 0 direct callers (delegate/vtable only).

---

## 5. The out-of-raid path — the stash "load magazine" action

MEASURED `R methods LoadMagazine`, `R typemethods EFT.UI.ItemUiContext`,
`R typemethods EFT.UI.BaseInventoryItemContextInteractions`.

| RVA | method | slots | sharedness | which world |
|---|---|---|---|---|
| `0x151db70` | `EFT.UI.ItemUiContext::LoadAmmoByType(Magazine, string ammoTemplateId, Action)` | 4 | **UNIQUE** | the context-menu action itself |
| `0x1522090` | `EFT.UI.ItemUiContext::ReloadWeapon(Weapon, IEnumerable<CompoundItem>)` | 3 | UNIQUE | context-menu "reload weapon" |
| `0x1522e30` | `EFT.UI.ItemUiContext::UnloadAmmo(ItemContext)` | 2 | UNIQUE | |
| `0x151de50` | `EFT.UI.ItemUiContext::CheckMagazine(Magazine)` | 2 | UNIQUE | |
| `0x14a3210` | `EFT.UI.BaseInventoryItemContextInteractions::ReloadWeapon()` | 1 | UNIQUE | the menu entry |
| `0x10e5180` | `EFT.InventoryLogic.ItemController::LoadMagazine(Ammo, Magazine, int, bool)` | 5 | **UNIQUE** | **base body — OUT of raid** |
| `0x10e5150` | `EFT.InventoryLogic.ItemController::LoadMagazine(Ammo, Magazine, int)` | 4 | UNIQUE | 3-arg overload |
| `0x766930` | `PlayerInventoryController::LoadMagazine(Ammo, Magazine, int, bool)` | 5 | **UNIQUE** | **override — IN raid** |
| `0x766bc0` | `PlayerInventoryController::UnloadMagazine(Magazine, bool)` | 3 | **UNIQUE** | in raid |
| `0x10c31b0` | `EFT.InventoryLogic.InventoryController::UnloadMagazine(Magazine, bool)` | 3 | UNIQUE | out of raid |
| `0x768d40` | `…/LoadMagazineProcess::.ctor(InventoryController, Magazine, Ammo, int, bool, float)` | 7 | UNIQUE | constructed **only** from `<LoadMagazine>d__51::MoveNext` |
| `0x768f50` | `…/LoadMagazineProcess::Start()` | 1 | UNIQUE | the old, wrong probe |

**INFERRED (not measured):** because `0x766930` is the override and `0x10e5180`
the base, a firing at `0x766930` means *in-raid* inventory loading and a firing
at `0x10e5180` with `0x766930` silent means *out-of-raid* stash loading. That
inference is exactly what the live probe in §7 tests; the two are bound
separately so the log can name which one it saw instead of asserting it.

---

## 6. Prologue table — what a bind must byte-verify

MEASURED in-process: `Resolver.code_bytes(rva, 16)`,
`Resolver.section_of_rva(rva)`, `Resolver.sharedness(rva)`. **Every row is in
the `il2cpp` PE section, every row is UNIQUE (owners = 1), and no row is the
`C2 00 00` universal stub.**

| RVA | method | first 16 bytes |
|---|---|---|
| `0x7843e0` | `FirearmController::ReloadMag` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `0x784570` | `FirearmController::QuickReloadMag` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 80` |
| `0x7848f0` | `FirearmController::ReloadWithAmmo` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 80` |
| `0x7847a0` | `FirearmController::ReloadCylinderMagazine` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `0x784ad0` | `FirearmController::ReloadBarrels` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `0x7840c0` | `FirearmController::CheckAmmo` | `40 53 48 83 EC 20 80 3D 57 42 93 06 00 48 8B D9` |
| `0x1c82e80` | `FirearmsAnimator::Reload(bool)` | `40 53 48 83 EC 20 80 3D 07 D5 43 05 00 48 8B D9` |
| `0x1c7e7c0` | `FirearmsAnimator::Reload(int,int,bool)` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 41` |
| `0x7b08f0` | `ReloadExternalMagOperation::Start` | `40 53 41 57 48 83 EC 58 8B 05 42 5C 90 06 4C 8D` |
| `0x7b3580` | `ReloadInternalMagBase::Start` | `48 89 5C 24 10 48 89 6C 24 18 57 48 83 EC 30 49` |
| `0x7b1c70` | `ReloadExternalMagOperation::OnMagInsertedToWeapon` | `40 53 48 83 EC 20 80 79 7C 00 48 8B D9 0F 85 A1` |
| `0x7b45c0` | `ReloadInternalMagOperation::CommitReloadWithAmmo` | `40 53 57 41 54 41 55 41 57 48 83 EC 40 80 3D 5C` |
| `0x7b40f0` | `ReloadInternalMagOperation::AddAmmoToMag` | `48 89 5C 24 10 57 48 83 EC 20 80 3D 2D 43 90 06` |
| `0x7af550` | `ReloadCylinderMagOperation::AddAmmoToMag` | `48 89 5C 24 08 57 48 83 EC 20 33 D2 48 8B D9 E8` |
| `0x766930` | `PlayerInventoryController::LoadMagazine` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `0x766bc0` | `PlayerInventoryController::UnloadMagazine` | `48 89 5C 24 08 57 48 81 EC 80 00 00 00 80 3D BA` |
| `0x10e5180` | `ItemController::LoadMagazine` | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 50 80` |
| `0x151db70` | `ItemUiContext::LoadAmmoByType` | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `0x768f50` | `LoadMagazineProcess::Start` (old) | `40 53 48 83 EC 70 80 3D 3F F3 94 06 00 48 8B D9` |
| `0x768d40` | `LoadMagazineProcess::.ctor` (old) | `48 89 5C 24 08 57 48 83 EC 20 8B 05 F0 D7 94 06` |

Note the identical 16 bytes on several rows. Sixteen bytes of a standard
register-save prologue are **not** an identity check; they are a "has anyone
already patched this" check. Identification is by RVA from the per-image
`methodPointers`, which is §1–§5's job.

---

## 7. The live experiment — what the rebound probe tests

Bound by `mods/ammoloading/ammoloading.nim` as read-only PREFIX drains, all
UNIQUE, one census line per *kind* per run. Kinds:

| kind | sites | what a non-zero count proves |
|---|---|---|
| `input` | `ReloadMag`, `QuickReloadMag`, `ReloadWithAmmo`, `ReloadCylinderMagazine`, `ReloadBarrels`, `CheckAmmo` | the **local player's** reload input reached the firearm controller |
| `opstart` | `ReloadExternalMagOperation::Start`, `ReloadInternalMagBase::Start` | a reload operation began; the reload animation is running |
| `anim` | `FirearmsAnimator::Reload(bool)`, `Reload(int,int,bool)`, `LoadOneTrigger` | the animator was told to reload — **includes other players** (§4) |
| `ammo` | `OnMagInsertedToWeapon`, `CommitReloadWithAmmo`, both `AddAmmoToMag` | the magazine's ammo actually changed |
| `inv` | `PlayerInventoryController::LoadMagazine`/`UnloadMagazine` (in raid), `ItemController::LoadMagazine` (out of raid), `ItemUiContext::LoadAmmoByType` | an inventory magazine fill/empty, and **which of the two worlds** |

**The verdict, and it is a negative so it can fail:**

* `input > 0` **and** `ammo == 0` → **FAIL**. The player reloaded and no
  ammo-change site was entered: this map's §3.3 is wrong.
* `input == 0` and `anim == 0` and `inv == 0` → **INCONCLUSIVE**, never PASS.
  Nobody reloaded during the run; "I could not look" is not a pass.
* `input > 0` and `ammo > 0` → **PASS** for the mapping, and the census names
  the receiver klass at each site so the animation feature can be built on the
  one that carries the magazine.

A count alone is not enough to know *which* object was in `RCX`, so each site
also prints, once, the receiver's `klass->name`. That read uses
`Il2CppClass.name` @`0x10`, which is **INFERRED** (`abi/aowlspt_components.h`
§ "the one inference"; `il2cpp_class_get_name` is a TLS thread-attach wrapper,
not an accessor). It is fenced the same way: the bytes are accepted only if
they are 1–63 printable ASCII characters, and anything else prints
`klass?=UNREADABLE` rather than a plausible wrong type name.

---

## 8. What this map does NOT establish

* **Nothing here has been observed live.** Every claim is offline metadata and
  static disassembly. The `callers` verb sees `E8`/`E9` rel32 edges only, so
  "0 direct callers" means *dispatch*, not *dead*.
* **Which operation a given weapon uses** is decided at runtime by
  `GetOperationFactoryDelegates` (`0xb73010` for the client override) against
  the weapon's `EReloadMode`. Offline we know the set, not the choice.
* **Instantiated generic layouts are not reachable offline** — no field offset
  in this document comes from a generic instance.
* **The `inv` in-raid/out-of-raid split in §5 is INFERRED** from the
  override/base relationship. §7 is the experiment that settles it.
* **`ProceduralWeaponAnimation` was checked and excluded**, not omitted — see
  §1. An earlier draft of this document asserted it had *no* reload members at
  all; that was written before `R typemethods 10797` was actually run, and it
  was wrong. It has four, and they are still the wrong signal, for a stated
  reason.
