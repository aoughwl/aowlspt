# aowl.ammoloading — "Ammo Loading"

Everything about putting rounds into a magazine and taking them out again.
**Two features**, and one of them deliberately lives somewhere else.

## Feature 1 — the loading ANIMATION

Status, plainly: **ARMED but NEVER FIRED.** The hooks install and byte-verify,
and the mod has never been observed to fire on a real magazine load while
armed. Do not read anything below as "this works"; read it as "this is what is
installed and waiting". The ladder is `off -> probe -> read -> spawn ->
animate` and **only `animate` is visible**.

### The dependency nobody expects: `spawn` and `animate` need aowl.textures

The `spawn` and `animate` rungs cannot work until a bundle is riding an
existing vanilla bundle key. This build **cannot add** a bundle key -- the game
builds one `EasyBundle` per entry in BSG's own manifest -- so
`stanags_container.bundle` must **replace** an existing key, and that redirect
is performed by **`mods/textures`** with `redirectMode=full` plus a
`bundleRoot` containing a file named exactly like the key you put in
`hijackKey`. This mod never detours `EasyBundle::Load` itself, because a second
detour on that function would overwrite `mods/textures`' trampoline and
silently kill the first.

**That redirect is NOT set up as shipped.** `hijackKey` is empty by default and
`spawn` refuses loudly when it is. So on a stock install the highest rung that
can do anything at all is `read`. Setting up the textures redirect is a
prerequisite, not a detail.

## Feature 2 — the load/unload SPEED (not implemented here, on purpose)

How long loading and unloading a magazine takes **is a server database value**,
not client code, and it is already exposed:

| what | database path | shipped value | tuning row |
|---|---|---:|---|
| load time | `globals.config.BaseLoadTime` | 0.85 | `g_BaseLoadTime` |
| unload time | `globals.config.BaseUnloadTime` | 0.3 | `g_BaseUnloadTime` |
| skill scaling | `globals.config.LoadTimeSpeedProgress` | 1 | `g_LoadTimeSpeedProgress` |

All three are already among the 770 `globals.config` rows that
`mods/tarkov/emu/globaltunedata.nim` serves, under category **Globals**
("Base Load Time", "Base Unload Time", "Load Time Speed Progress"). Change them
there.

This mod does **not** declare its own control for them. Two settings writing
one value is exactly the shape that produces "I changed it and nothing
happened".

(Mag Drills also scales load speed at runtime via
`globals.config.SkillsSettings.MagDrills.*`, which is likewise already exposed
under **Skills**.)

---

## Upstream and what this port loses

A port of [ManimalAmmoLoadingAnimations](https://github.com/danauraborealis/ManimalAmmoLoadingAnimations)
(v1.6.0, MIT) to the post-1.0 IL2CPP client. Upstream's animation bundle is
reused verbatim under its MIT licence (`LICENSE.upstream.txt`).

Vanilla EFT has **no** first-person magazine-loading animation. Everything
visible here comes out of upstream's hand-authored bundle.

## This is an approximation, and here is exactly what is lost

Upstream injects a managed subclass of `Player.UsableItemController` whose
`vmethod_0` the engine calls, and routes it through **generic** controller-swap
methods instantiated with that injected type. Neither is reachable on IL2CPP:
constructing a valid `Il2CppClass` is unverified on this build, and a generic
instantiation needs a real class for the type argument plus a non-NULL
`MethodInfo*`.

So this skips the controller system entirely — it detects the load, instantiates
upstream's prefab through the game's own EasyAssets pipeline, enables the mesh
for the magazine being loaded, and drives that prefab's Animator by verified
static RVA.

**Lost relative to upstream:**

* **Fika co-op sync.** Upstream ships a second DLL that turns session
  start/stop/mesh-swap into network packets. Not carried.
* **ContinuousLoadAmmo compatibility.** Upstream has a dedicated patch set for
  it. Not carried.
* **Free first-person placement.** Upstream's prefab is positioned by the
  controller system; ours is parented by us. This is the one part that needs
  live iteration rather than offline proof.

**Gained, by accident and worth stating:** upstream needs null-guard prefixes on
`ProceduralWeaponAnimation::ProcessEffectors` and `Player::VisualPass` purely
because the controller swap leaves `WeaponRootAnim` briefly null. We never swap
controllers, so that window does not exist and those guards are not installed —
which also keeps us clear of the measured landmine that several
`ProceduralWeaponAnimation` property names are **mis-assigned** in SPT's
deobfuscation. This mod reads no PWA property at all.

## The asset, and where it goes

`data/stanags_container.bundle` (19,422,029 bytes) ships with this mod. It is
upstream's file, unmodified.

* Bundle header reports Unity **2022.3.43f1**; this client is **2022.3.43f2** —
  same patch, differing only in the hotfix digit, so the serialization version
  matches. That it *loads* is still a behavioural claim, not proven here.
* Upstream's `bundles.json` names **9 vanilla dependency bundles** (shaders,
  cubemaps, physics materials, muzzleflash, additional_hands, simple/spirit
  animations, weapon_root_anim_fix, a medkit audio bundle). Whether all nine
  exist under those keys in this build is **unverified**.

### The bundle-key problem — read before enabling

**We cannot add a bundle key.** The game builds one `EasyBundle` per entry in
BSG's own manifest, and `mods/textures/redirect.nim` can only rewrite an
existing key's `_path`. So our bundle must **ride an existing vanilla key**, and
that key's real asset is unavailable while this feature is on. Pick a key
nothing in a raid loads.

**The redirect is done by `mods/textures`, not by this mod.** That mod already
owns a prefix on `Diz.Resources.EasyBundle::Load` @0x2772CC0, and **two detours
on one function overwrite each other's trampoline and silently kill the first**.
So:

1. Set `mods/textures` `redirectMode` to `full` and point its `bundleRoot` at a
   directory.
2. Copy `data/stanags_container.bundle` into that directory, named **exactly**
   like the vanilla key you are hijacking (no extension is appended or stripped).
3. Set this mod's `hijackKey` to that same key.

If `hijackKey` is empty the spawn rung **refuses loudly** and vanilla behaviour
is untouched. It never silently no-ops.

## Turning it on

Default **OFF** — this detours the live magazine-loading flow during gameplay.
Vanilla loading is never suppressed on any rung; the animation is added
alongside it.

Escalate **one rung at a time** (`mode` in `config.json`):

| rung | what it does |
|---|---|
| `off` | installs nothing |
| `probe` | counts detections only, zero dereferences |
| `read` | also resolves which magazine is loading; nothing called or written |
| `spawn` | also instantiates the prefab and enables the matching mesh |
| `animate` | also plays it — **only this rung is visible** |

## Acceptance

`GET /aowlspt/ammoloading/stats`.

The falsifiable negative is **behavioural**: a magazine load must take
measurable time and pass through intermediate states. An instant transfer with
`animate` on must read **FAIL**, not PASS.

Three outcomes, never two:

* **INCONCLUSIVE** — `sessions == 0`. No magazine was loaded during the run.
  That is "I could not look", not "it worked".
* **FAIL** — `tplRefused > 0` (the template-id offset inference is wrong),
  `spawnRefused > 0`, `timedOut > 0` (the terminal signal is not arriving),
  `retired == true`, or `meshFallback` high with `meshHits == 0` (every magazine
  animating as a stanag).
* **PASS** — `sessions > 0`, `tplRead == sessions`, `spawned > 0`,
  `animDriven > 0`, `teardowns == sessions`, `faults == 0`, `timedOut == 0`.

`meshHits` and `meshFallback` are kept apart deliberately: a single `spawned`
counter would hide "every magazine animated as a stanag", which is a bug that
looks exactly like success.

## Every address, with provenance

Resolved offline with `tools/il2cpp_resolve.py` and `tools/fldoff.py` against
build 1.1.0.1.46777. Every one was byte-checked to be something other than
`C2 00 00`, this build's universal empty-body stub shared by 6,438 methods.

| RVA | method | owners | use | name trusted? |
|---|---|---|---|---|
| `0x768F50` | `LoadMagazineProcess::Start` | UNIQUE | **detour** | no — re-identified by signature |
| `0x769260` | `LoadMagazineProcess::RaiseLoadEventArgs` | UNIQUE | **detour** | no — signature |
| `0x938430` | `EFT.ObjectsFactory::.ctor` | UNIQUE | **detour** (latch) | signature (3 args, one `IEasyAssets`) |
| `0x93AB40` | `ObjectsFactory::InstantiateWithoutPool` | UNIQUE | call | signature |
| `0x524A680` | `Animator::Play(string)` | UNIQUE | call | name |
| `0x52495C0` | `Animator::SetBool(string,bool)` | **SHARED (2)** | call only | name |
| `0x524B000` | `Animator::Update(float)` | UNIQUE | call | name |

Only UNIQUE RVAs are detoured. `SetBool` is shared and is **called, never
detoured** — calling a shared RVA is correct code for the receiver passed;
detouring one has unbounded blast radius.

**The trigger was re-identified, not looked up.** Upstream patches
`Player.PlayerInventoryController.Class1204`, an obfuscated Mono name with
**zero hits** across all 31,282 types here. `LoadMagazineProcess` (type 6713)
matches it on shape: `Task<IResult> Start()`, `float _loadOneAmmoSpeed`,
`Magazine _magazine`, and `<LoadProcess>g__CoolDown|18_0()` for the per-bullet
wait — exactly upstream's `Start`, `Float_0`, `MagazineItemClass`, `method_5`.

### Field offsets

| offset | field |
|---|---|
| `+0x18` | `LoadMagazineProcess._magazine` |
| `+0x30` | `LoadMagazineProcess._loadOneAmmoSpeed` |
| `+0x60` | `Item.<Template>k__BackingField` |
| `+0xE0` | `ItemTemplate.<_id>k__BackingField` (inline `MongoID`) |
| `+0xF0` | the template-id string (`MongoID._stringID`, struct-relative `+0x10`) |

The last one is the **only inferred** step: IL2CPP reports value-type field
offsets including the 0x10 object header, so an inline struct's field sits at
`structBase + (reported - 0x10)`. That inference is not trusted, it is
**checked** — a magazine template id is always 24 hexadecimal characters, so
`read` mode requires exactly that and refuses otherwise. A wrong offset produces
a refusal naming itself (`tplRefused`), not a plausible wrong id.

### The EasyAssets holder

`ObjectsFactory.EasyAssets` is a public INITONLY field at `+0x20`, but the
*holder* of an `ObjectsFactory` is not identifiable offline: `get_ObjectsFactory`
returns zero hits across all 31,282 types, and this build has **no
`PoolManager`** at all — so upstream's `Singleton<PoolManagerClass>.Instance
.EasyAssets` has no equivalent to resolve.

Rather than guess an offset that could read null, the pointer is taken from a
place it is known live: **the constructor's own arguments**. `ObjectsFactory::
.ctor(IEasyAssets, …)` is detoured and both `this` and arg 0 are latched. That
is "walk from a verified live object" applied literally — the object is verified
because the engine is in the act of constructing it.

## What has not been established

* **Nothing here has been run.** Every claim above is from offline metadata,
  prologue bytes and upstream source. No rung has been exercised in the client.
* Whether the bundle **loads** in this build (§ Unity version above is a
  compatibility argument, not a load).
* Whether all 9 dependency bundles resolve.
* **First-person placement.** The prefab is instantiated but its parenting and
  local transform relative to the hands rig are not solved; upstream got this
  free from the controller system. Expect the `animate` rung to need live
  iteration here.
