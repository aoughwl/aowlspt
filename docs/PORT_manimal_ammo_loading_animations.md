# Port plan — Manimal Ammo Loading Animations → aowlspt (post-1.0 IL2CPP)

Source: https://github.com/danauraborealis/ManimalAmmoLoadingAnimations (v1.6.0, MIT).
Analysed 2026-08-30. **Read-only research — nothing deployed or launched.**

---

## Verdict up front

**BLOCKED as a faithful port. Feasible only as a from-scratch host-native
re-implementation, which is a multi-spike research track, not a "tonight" task —
and even that gives an approximation, not the original.**

The single pivotal fact decides it: **this mod SHIPS its own animation assets.**
It is not re-timing or re-triggering an existing game animation — **vanilla EFT
has no first-person magazine-loading animation at all.** The entire visible
behaviour is a custom `AssetBundle` (`stanags_container.bundle`) containing a
hand-authored Animator graph (draw/put-away clips) plus new magazine meshes,
dispatched through a **runtime-injected managed subclass of
`Player.UsableItemController`**. Both of those are precisely the two things our
host cannot do today.

---

## STEP 1 — What the source mod is and does

### Player-visible behaviour
While you load rounds into a magazine (SPT's out-of-raid/in-raid mag loading,
optionally driven by the *ContinuousLoadAmmo* mod), the mod plays a **first-person
animation of hands holding that specific magazine and thumbing rounds in**, at a
speed tied to your Mag Drills skill. It draws the mag on the first bullet, loops
while loading, swaps the visible mesh if you chain into a different mag, and plays
a put-away clip when done. It syncs to other players under **Fika** (co-op).

### Shape / target
- **Two client DLLs (BepInEx plugins, Harmony patches), one SPT server mod (C#),
  and a data/asset payload.** `netstandard2.1`, references
  `EscapeFromTarkov_Data/Managed/Assembly-CSharp.dll` — i.e. a **Mono** EFT build.
- Server metadata: `SptVersion = ~4.0.0`, `IsBundleMod = true`. Uses
  `WTTServerCommonLib` / `WTTClientCommonLib` to register a custom item + parent.
- Ships assets: **`ServerModFiles/bundles/manimal/stanags_container.bundle`** and
  `bundles.json` (declares 9 vanilla dependency bundles: shaders, cubemaps,
  additional_hands, simple/spirit animations, weapon_root_anim_fix, a medkit audio
  bundle). Plus `db/CustomItems/hidden_anim_STANAGS.jsonc` (a virtual item cloned
  from **PortableRangeFinder**, `UsePrefab.path = manimal/stanags_container.bundle`)
  and `db/CustomParents/loadammo_bundle_parent.jsonc`.

### The trick (how it works)
It creates a throwaway **virtual "usable item"** whose `UsePrefab` is the custom
bundle, then hijacks the game's usable-item controller machinery to spawn that
bundle's prefab in first person and play its Animator. Concretely:

1. **Detect** the vanilla load flow: Harmony-hooks the obfuscated inner class
   `Player.PlayerInventoryController.Class1204` — `.Start` (grab mag template id +
   per-round speed) and `.method_5` (the per-bullet wait; stretched on bullet 1 to
   fit the draw clip). Also `GameWorld.OnGameStarted` to warm the bundle.
2. **Inject a managed subclass** `LoadAmmoBundleController : Player.UsableItemController`
   whose `vmethod_0` binds the bundle's `Animator` and plays `OUT TO USE S` /
   `USE TO OUT S` states on layer 1.
3. **Inject a marker item class** `LoadAmmoBundleItem : PortableRangeFinderItemClass`
   (via `WTTClientCommonLib [CustomParent]`) so patches can do `item is
   LoadAmmoBundleItem`.
4. **Route** the item through that controller with four dispatch prefixes:
   - `Player.SetInHandsUsableItem` → `Proceed<LoadAmmoBundleController>` and skip.
   - `ClientUsableItemController.smethod_11` → `smethod_7<...>` for our item.
   - `HandsControllerClass.method_49` → force `EWeaponAnimationType.Pistol`.
   - `GClass2970.smethod_0` → return a stub `GInterface323`.
5. **Drive** it: create item via `ItemFactoryClass.CreateItem`, `DropCurrentController`
   → `smethod_1<LoadAmmoBundleController>` → `smethod_8<...>` → `SpawnController`,
   enable the mesh matching the mag template id (`MagAnimLookup`), run a coroutine
   that watches mag count and plays put-away/chained-swap/teardown.
6. **Guard PWA**: null-guard prefixes on
   `ProceduralWeaponAnimation.ProcessEffectors` and `Player.VisualPass` to survive
   the controller-swap window where `WeaponRootAnim` is briefly null.
7. **Fika**: a separate DLL sideloaded by reflection converts local session
   start/stop/mesh-swap events into network packets.

### Concrete patch-target list (source, Mono names)
| target | kind | what it does |
|---|---|---|
| `PlayerInventoryController.Class1204.Start` | prefix+postfix | capture mag tpl id + speed; count sessions |
| `PlayerInventoryController.Class1204.method_5` | prefix (skip) | stretch first-bullet delay by draw-clip len |
| `GameWorld.OnGameStarted` | postfix | warm the bundle |
| `Player.SetInHandsUsableItem` | prefix (skip) | route our item to our controller |
| `ClientUsableItemController.smethod_11` | prefix (skip) | build controller for our item id |
| `HandsControllerClass.method_49` | prefix (skip) | force Pistol anim type |
| `GClass2970.smethod_0` | prefix (skip) | return stub GInterface323 |
| `ProceduralWeaponAnimation.ProcessEffectors` | prefix (skip) | null-guard during swap |
| `Player.VisualPass` | prefix (skip) | null-guard during swap |
| `Player.SetEmptyHands` / `TrySetLastEquippedWeapon` / CLA internals | prefix | ContinuousLoadAmmo compat |

**Answer to the pivotal question:** it **ships its own assets** (a bundle with new
Animator clips + meshes). It does **not** re-time existing game animation.

---

## STEP 2 — Portability to our architecture

Post-1.0 EFT is **IL2CPP**: no BepInEx, no Harmony, no Mono patching. Our mods work
via the host DLL: byte-verified static-RVA detours/calls, flag-gated, guarded
(CLAUDE.md §5). Two structural findings dominate.

### Finding A — the mod's target names DO NOT EXIST in our build
Measured with `tools/il2cpp_resolve.py` against the live `GameAssembly.dll` +
`.cache/global-metadata.dec.dat` (self-check `_stringLength@0x10`/`_firstChar@0x14`
passed). This IL2CPP build uses **real deobfuscated names**; every obfuscated
identifier the mod patches returns **zero hits across all 31,282 types**:
`smethod_*`, `method_49`, `Class1204`, `GClass2970`, `HandsControllerClass`.

So there is **no 1:1 target map**. Some real equivalents exist and resolve
cleanly (RVAs are PE-base offsets; the DLL is ASLR-relocated at runtime — add the
**live** base, not `0x180000000`; **prologues NOT yet byte-verified**):

| real method (this build) | RVA | shared? | note |
|---|---|---|---|
| `EFT.Player::SetInHandsUsableItem(Item, Callback<IUsableItemController>)` | `0x740DD0` | unique | dispatch entry |
| `EFT.Player::DropCurrentController(Action, bool, Item)` | `0x740540` | unique | |
| `EFT.Player::DestroyController()` | `0x740270` | unique | |
| `EFT.Player::SpawnController(AbstractHandsController, Action)→Task` | `0x73FC40` | unique | |
| `EFT.Player::TrySetLastEquippedWeapon(bool, Callback)` | `0x740FB0` | unique | |
| `EFT.Player::SetEmptyHands(Callback<IEmptyHandsController>)` | `0x740620` | unique | |
| `EFT.Player::StopBlindFire()` | `0x6F38A0` | unique | |
| `EFT.Player::RemoveLeftHandItem(float)` | `0x73B990` | unique | |
| `EFT.Player::VisualPass()` | `0x6F8D60` | unique | null-guard candidate |
| `EFT.Animations.ProceduralWeaponAnimation::ProcessEffectors(float,int,Vector3,Vector3,bool)` | `0xED10C0` | unique | arity-5; 5 same-named strategy variants exist too |
| `UsableItemController` (idx 6914) `::Spawn(float,Action)` | `0x7DD250` | (unchecked) | real names, **no** `smethod_1/7/8` |
| `UnityEngine.Animator::Play(string)` | `0x524A680` | (unchecked) | in `UnityEngine.AnimationModule` |
| `UnityEngine.Animator::SetBool(string,bool)` | `0x52495C0` | (unchecked) | |
| `UnityEngine.Animator::Update(float)` | `0x524B000` | (unchecked) | |
| `UnityEngine.Animator::GetCurrentAnimatorStateInfo(int)` | `0x5249ED0` | (unchecked) | returns struct by value (sret) |

**No** `Class1204` under `PlayerInventoryController` (idx 6734), **no**
`HandsControllerClass.method_49` (base is `AbstractHandsController` idx 6903;
enum `EWeaponAnimationType` idx 7302 exists), **no** `smethod_11` on
`ClientUsableItemController` (idx 8577). The load-ammo flow and the controller-swap
statics must be **re-identified by signature** — the equivalents almost certainly
exist under real names, but that is unbudgeted reverse-engineering work, and
several are **async `Task`-returning state machines** (much harder to detour
cleanly than a plain method).

> Per fact #39: several `ProceduralWeaponAnimation` property names are mis-assigned
> in SPT's deobfuscation. The two PWA null-guards touch exactly this class, so any
> port must byte-verify `HandsContainer`/`WeaponRootAnim` offsets **live**, never
> trust the SPT name.

### Finding B — the two hard blockers our host cannot do today

1. **Runtime-injected managed subclass of `Player.UsableItemController` with a
   vtable override (`vmethod_0`).** CLAUDE.md §5 rates managed type injection
   "plausible, not blocked" for *constructing an object* (object_new etc. are
   ungated), and fact #203 shows building a native Unity object at runtime is
   viable — **but** "constructing a valid `Il2CppClass`" is explicitly *not
   verified*, and #203 flags that **managed callbacks are inconclusive.** A
   `UsableItemController` subclass whose overridden virtual the engine calls is
   exactly an unverified managed callback. **This is the crux blocker.**

2. **Generic controller-swap methods instantiated with the injected type** —
   `Proceed<LoadAmmoBundleController>`, `smethod_1<...>`, `smethod_8<...>`. A
   generic instantiation needs a real `Il2CppClass` for the type argument and a
   valid `MethodInfo*` (shared generics require a non-NULL one). With the type
   argument being a type that doesn't exist in metadata, this is not reachable by
   an RVA call.

Everything else is more tractable:
- **The AssetBundle itself is loadable.** `mods/textures/redirect.nim` already
  does the SPT `spt-custom.dll` trick — rewrite `Diz.Resources.EasyBundle::_path`
  (prefix on `Load` @ RVA in that module) so a bundle key resolves to our file,
  and the game loads it through its own unmodified pipeline. Fact #161 shows the
  client has a first-class `AssetsManager::LoadScene(bundleName,…)`; fact #64/#73
  document the EasyBundle/EasyAssets chain. Serving a **new** bundle key means our
  emulated backend adds the custom item to `db.json`/`itemsadd` (clone of
  PortableRangeFinder, `UsePrefab.path` set) and serves/redirects the bundle file.
  Plausible, but **unproven end-to-end for a non-scene prefab bundle** we then
  `Instantiate`.
- **The dispatch prefixes that merely set `__result` and skip** (force enum type,
  return a stub interface) map onto our host's prefix + set-return capability.
- **But** `mods/textures/redirect.nim` also records a hard host limitation: the
  frame ABI exposes `aowl_frame_set_ret_*` and **no `aowl_frame_set_arg_*`** — a
  host detour **cannot rewrite a call's arguments.** Any source prefix that works
  by mutating an argument (or by calling `Proceed<T>` in place of the original)
  has no direct host equivalent.

### The only realistic port design (host-native, not a 1:1 port)
Skip the injected controller entirely. Instead:
1. Backend registers the custom item + ships/redirects the bundle so the game can
   load `stanags_container.bundle` through EasyAssets.
2. Host detects the load-ammo flow (re-identified real method for the old
   `Class1204.Start`) and reads the mag template id + speed.
3. Host loads the bundle prefab and **`Object.Instantiate`s it as a plain
   GameObject** parented to the camera/hands rig (fact #203-style native object
   construction), enables the right mesh, and drives its `Animator` directly by
   RVA (`Play`/`SetBool`/`Update` above) — **no `UsableItemController` subclass.**
4. Host hides the real weapon renderer during the load and restores it after.
5. Guard PWA/VisualPass as the original does, byte-verified live.

This is an **approximation**: no Fika sync, no ContinuousLoadAmmo compat, and
positioning/parenting the loose prefab to look right in first person (the original
gets this for free from the controller system) is real, fiddly, unproven work.

### Where it would live
A new client-side mod under `mods/` (Nim, e.g. `mods/loadammoanim/`) for the host
RVA detours + Animator driving, plus backend/`db.json` work for the custom item
and bundle serving. It is **new host RVA work**, not a config change.

---

## STEP 3 — Feasibility verdict & next steps

**Verdict: BLOCKED as a faithful port; a stripped host-native approximation is a
larger track (multiple research spikes), not a tonight job.** It fundamentally
needs asset injection *and* managed dispatch we cannot currently do. State plainly
to the user: the mod's whole point is **shipping new animations**, and our host
has no verified way to inject a managed `UsableItemController` subclass.

If we still want to pursue the approximation, the honest ordering of unknowns
(each is a spike that can fail and must announce it):

1. **[Blocker-defining] Prove/disprove the loose-prefab path** — can the host load
   `stanags_container.bundle`'s prefab through EasyAssets and `Object.Instantiate`
   it as a first-person GameObject with a live Animator, without the controller
   system? If no, the whole thing is dead. (INCONCLUSIVE today.)
2. **Serve the custom item + bundle** from the backend (clone PortableRangeFinder,
   `UsePrefab.path`; redirect the new bundle key like `mods/textures`). Verify the
   client actually requests and loads it (EasyBundle `match` rung).
3. **Re-identify the load-ammo flow** — find the real IL2CPP method(s) that were
   `Class1204.Start`/`method_5` on Mono, by signature; byte-verify prologues.
4. **Hide/restore the weapon renderer + parent the prefab** to look right in first
   person; guard PWA/VisualPass (`0xED10C0` / `0x6F8D60`), byte-verified live.
5. Only then consider Fika/CLA parity (co-op is its own separate track).

Assets that would still have to be authored/obtained: the mod's MIT licence lets
us reuse `stanags_container.bundle` directly, so we would **not** need to author
new clips — but we must confirm the shipped bundle's Unity/shader versions load in
this client build, and that its 9 dependency bundles exist here.

**Bottom line for tonight:** not portable as-is; the faithful path needs managed
type injection we have not verified, and the approximation path starts with an
unproven asset-instantiation spike. Recommend not starting a build until spike (1)
returns a real answer.
