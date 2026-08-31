# Spike 1 — can the host load + Instantiate the Manimal prefab WITHOUT the injected controller?

Companion to **`docs/PORT_manimal_ammo_loading_animations.md`** — that document's
STEP 3 lists this as *"[Blocker-defining] spike 1 … (INCONCLUSIVE today)"*. This
file answers only that one question. Nothing else in the plan is restated or
superseded; Findings A and B there still stand.

**Read-only research. The game was never run, nothing was deployed, `D:\Aowlspt`
was only read (`GameAssembly.dll`, 123,891,024 bytes).**

Instrument for every RVA below: `tools/il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll
.cache\global-metadata.dec.dat <verb>` (verbs `type` / `methods` / `shared` /
`bytes`) and `tools/fldoff.py … fields <Type>`. Date 2026-08-30, build
1.1.0.1.46777.

---

## VERDICT: **PASS**, conditional.

**Both crux capabilities exist in this build as non-generic, UNIQUE, real-bodied
methods callable at a static RVA. Neither needs managed type injection, neither
needs a generic instantiation, neither needs argument rewriting.**

The single most important piece of evidence:

> `EFT.ObjectsFactory::GameObject InstantiateWithoutPool(IEasyAssets easyAssets,
> ResourceKey resourceKey)` — **RVA `0x93AB40`, arity 2, sharedness=UNIQUE
> (owners=1), section `il2cpp`, real body** (`48 89 5C 24 08 57 48 83 EC 40 …`,
> not the `C2 00 00` universal stub).
>
> That is one static call that goes from *a bundle resource key* to *a live
> GameObject*, through the game's own EasyAssets pipeline. It is exactly the
> operation Finding B said we had no verified route for, and it is already
> compiled into the client as a plain non-generic method.

So spike 1 does **not** kill the port. The host-native approximation described in
the plan's *"only realistic port design"* is buildable in principle.

`inferred`, and it matters: PASS here is a **capability** verdict from offline
metadata. It is **not** a behavioural verdict. Nothing below has been executed,
no prologue has been verified against `abi/aowlspt_prologue.h`, and no bundle has
been loaded. Three outcomes, and this one is "the calls exist and are safe to
bind", not "it works".

---

## 1. Loading a NON-scene asset from a bundle — `measured`

`EFT.AssetsManager.AssetsManager` (type idx **16622**, `Assembly-CSharp.dll`)
carries a full non-scene asset API, not just `LoadScene`. Candidates, all
`sec=il2cpp` with ordinary prologues (no stub, no thunk shape):

| method | RVA | arity | shared? | prologue (16B) |
|---|---|---|---|---|
| `IOperation<object> LoadMainAssetAsync(string bundleName)` | `0x1911BD0` | 1 | **UNIQUE** | `48 89 5C 24 08 57 48 83 EC 30 80 3D DF D3 7A 05` |
| `IOperation<object> LoadAssetAsync(string bundleName, string assetName)` | `0x1911B20` | 2 | **UNIQUE** | `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 80` |
| `IOperation LoadAssetsAsync(string bundleName)` | `0x1911C50` | 1 | **UNIQUE** | `48 89 5C 24 08 57 48 83 EC 30 80 3D 60 D3 7A 05` |
| `IOperation LoadBundlesAsync(string[] bundleNames)` | `0x1911CD0` | 1 | **UNIQUE** | `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57` |
| `Object GetAsset(string assetName)` (sync) | `0x19117E0` | 1 | **UNIQUE** | `48 89 5C 24 20 56 48 83 EC 30 80 3D CD D7 7A 05` |
| `Object FindAsset(string assetName)` (sync) | `0x19114C0` | 1 | **UNIQUE** | `48 89 5C 24 10 57 48 83 EC 20 80 3D EB DA 7A 05` |
| `LoadSceneOperation LoadScene(string,string,LoadSceneMode,bool,Action<float>)` | `0x1911F60` | 5 | **SHARED (owners=2)** | — |

Two things to take from that table.

* **`LoadMainAssetAsync(bundleName)` is the intended entry for a bundle whose
  main asset is a prefab** — which is exactly the shape of
  `stanags_container.bundle` (SPT `UsePrefab.path` bundles carry one main
  prefab). One string argument, unique RVA. It is **async**: it returns
  `IOperation<object>`, so the host polls it from the `TarkovApplication::Update`
  bridge rather than blocking. `GetAsset`/`FindAsset` are the sync reads once the
  bundle is resident.
* **`LoadScene` @`0x1911F60` is SHARED by 2 owners** — noting it because the plan
  and fact #161 point at it. It is fine to *call*; it must **not** be detoured by
  name. We do not need it: our asset is a prefab, not a scene.

These are all **instance** methods (`RCX = the AssetsManager`). Getting that
instance is the open item — see §5.

## 2. Can `EasyBundle::_path` redirect introduce a NEW bundle key? — **NO** (`measured`)

Read of `mods/textures/redirect.nim`. The mechanism is a **prefix on
`Diz.Resources.EasyBundle::Load` @ `0x2772CC0`** which reads `<Key>` @`+0x30`,
looks it up in our table, and on a hit rewrites `_path` @`+0x20`.

That prefix only ever runs on an `EasyBundle` **the game already constructed**,
and the game constructs one per entry in BSG's own bundle manifest
(`AssetsManager.BundlesManifestContainer`, `LoadBundleManifestOperation`). **The
redirect is strictly key→path; it cannot add a key.** SPT's answer (a
`/singleplayer/bundles` manifest endpoint consumed by `spt-custom.dll`) is not
available to us: grep of `mods/tarkov/tarkov.nim` finds no bundles route, and we
have no client-side SPT DLL on an IL2CPP build.

**Workaround, and it is a good one:** we do not need a new key. Redirect an
**existing vanilla key we do not otherwise care about** — the natural choice is
the PortableRangeFinder's own prefab bundle, since the upstream mod already
clones that item — so that asking for that key yields *our* file. Every call in
§1 and §3 then works unchanged, and the loop closes with the mechanism we have
already shipped once. Cost: we lose the real asset behind that key while the
feature is on, so the flag must be default-OFF (rule 5) and the key choice must
be one nothing in a raid loads.

`inferred`: that the redirected bundle's own dependency list is taken from the
*manifest* entry (vanilla) rather than from our file is a real risk to the 9
dependency bundles. Unresolved; see §6.

## 3. `Object.Instantiate` and parenting — `measured`

The C# `Instantiate<T>` is generic, but IL2CPP compiled the **non-generic
`UnityEngine.Object` overloads with real RVAs** (the generic `mvar` forms have
`RVA=None` and are irrelevant). In `UnityEngine.CoreModule.dll`:

| method | RVA | shared? | prologue (16B) |
|---|---|---|---|
| `Object Instantiate(Object original, Transform parent, bool instantiateInWorldSpace)` | `0x52ADDA0` | **UNIQUE** | `48 89 5C 24 10 48 89 6C 24 18 57 48 83 EC 20 80` |
| `Object Instantiate(Object original)` | `0x52ADBE0` | **UNIQUE** | `48 89 5C 24 08 57 48 83 EC 20 80 3D 06 6B E2 01` |
| `Object Instantiate(Object, Vector3, Quaternion, Transform)` | `0x52AD8C0` | (unchecked) | — |
| `Object Internal_InstantiateSingleWithParent(Object, Transform, Vector3, Quaternion)` | `0x52AEAC0` | (unchecked) | — |

`0x52ADDA0` is the one to use: **static**, non-generic, prefab + parent +
world-space flag in a single call, so instantiate-and-parent is one RVA call, not
two. Convention: `RCX=original, RDX=parent, R8=bool`, then the trailing
`MethodInfo*` (NULL is acceptable — this is not a shared generic).

Two Assembly-CSharp conveniences also resolve, both **UNIQUE**, both real bodies:

* `GameObjectExtensions::GameObject InstantiatePrefab(Transform parent, GameObject prefab)` @ **`0x166F410`** (`48 89 5C 24 08 57 48 83 EC 20 80 3D BE EB A4 05`) — returns a concrete `GameObject`, saves a cast.
* `EFT.ObjectsFactory::GameObject InstantiateWithoutPool(IEasyAssets, ResourceKey, ResourceTypeInfo)` @ **`0x93A700`** (arity 3) alongside the arity-2 `0x93AB40` above.

## 4. Bundle / Unity-version compatibility — **UNKNOWN**

Not determinable without downloading the mod, which the brief forbids. The
client is Unity **2022.3.43f2**; the upstream bundle was authored for a *Mono*
EFT build on **SPT 4.0.0**, which tracks a nearby-but-not-identical Unity
version, and its `bundles.json` names 9 vanilla dependency bundles (shaders,
cubemaps, additional_hands, simple/spirit animations, weapon_root_anim_fix, a
medkit audio bundle) whose presence *in this build* is likewise unchecked.

Stating **UNKNOWN**, not a guess. A bundle built against a different Unity
serialization version fails to load outright, and shader/anim dependency drift
fails *visually* rather than loudly. This is the next-cheapest thing to settle
(read the bundle header's version string offline once a copy exists) and it can
still sink the feature after this PASS.

## 5. What is still open (none of it is a missing capability)

1. **Reaching the `IEasyAssets` / `AssetsManager` instance.** `measured`:
   `EFT.ObjectsFactory` (idx 7647) holds `EasyAssets : IEasyAssets` as a public
   INITONLY field at **`+0x20`** — a plain raw-offset read once we hold an
   `ObjectsFactory`. But `get_ObjectsFactory` returns **zero hits across all
   31,282 types**, and there is **no `EFT.PoolManager`** in this build. So the
   *holder* is unidentified offline. Per CLAUDE.md this is a **walk from a
   verified live object** problem for the live inspector (`roots` → a live
   `GameWorld`/`Player`, then `fields`), not a capability gap. It must be settled
   before any code is written, and an offset that can read null is not a path.
2. **Prologue byte-verify against `abi/aowlspt_prologue.h`**, not against live
   memory, for every RVA above.
3. **`ResourceKey` construction** for the `InstantiateWithoutPool` route.
   `AssetsManagerExtension::ReferenceToResourceKey(string)` @ `0x252DA90`
   (arity 1, sharedness unchecked) looks like the string→key bridge. If it is
   awkward, `LoadMainAssetAsync(string)` @ `0x1911BD0` + `Instantiate`
   @ `0x52ADDA0` avoids `ResourceKey` entirely.
4. **§4's bundle compatibility.**

## 6. Concrete call sequence a host implementation would use

Flag-gated default-OFF, one `aowl_p_p_seh` for the whole body, `VirtualQuery` on
every hop, capped polling, self-disable after N faults.

```
(setup, once)  EasyBundle::Load prefix @0x2772CC0  -- existing mechanism,
               map an EXISTING vanilla key -> our stanags_container.bundle path
(A) walk to ObjectsFactory from a live object   [OPEN, §5.1]
    read  EasyAssets  @ +0x20                   [field, measured]
    read  AssetsManager  (holder unidentified)  [OPEN]
(B) AssetsManager::LoadMainAssetAsync(bundleName)
        RVA 0x1911BD0  instance  arity 1  UNIQUE   -> IOperation<object>
        poll from the TarkovApplication::Update bridge @0x977B10, capped
(C) UnityEngine.Object::Instantiate(prefab, handsParent, false)
        RVA 0x52ADDA0  STATIC    arity 3  UNIQUE   -> Object (the GameObject)
    (alt) ObjectsFactory::InstantiateWithoutPool(easyAssets, resourceKey)
        RVA 0x93AB40   static    arity 2  UNIQUE   -> GameObject
    (alt) GameObjectExtensions::InstantiatePrefab(parent, prefab)
        RVA 0x166F410  static    arity 2  UNIQUE   -> GameObject
(D) get the Animator off the instance (the live inspector's `component` verb
    already does a working non-generic GetComponent -- reuse that path)
(E) drive it:  Animator::Play(string)                  0x524A680  (unchecked)
               Animator::SetBool(string,bool)          0x52495C0  (unchecked)
               Animator::GetCurrentAnimatorStateInfo   0x5249ED0  (sret)
               -- RVAs carried over from the plan doc, NOT re-checked here
(F) hide/restore the weapon renderer; null-guard
    ProceduralWeaponAnimation::ProcessEffectors 0xED10C0 and
    Player::VisualPass 0x6F8D60  (both from the plan doc, unique, unverified)
(G) teardown: destroy the instance, restore the renderer
```

Note (C) and (E)/(F) are **calls**, not detours — a call at a shared RVA is
fine, and none of these are shared anyway. The only *write* in the whole design
is the existing `_path` redirect, which we have shipped before.

---

## What this changes in the plan document

`docs/PORT_manimal_ammo_loading_animations.md` STEP 3 item 1 —
*"prove/disprove the loose-prefab path … If no, the whole thing is dead.
(INCONCLUSIVE today)"* — is now **PASS (capability)**. Its item 2 is **narrowed**:
we cannot add a bundle key, so it becomes "redirect an existing key", not "serve
a new one". Its Finding B stands untouched and is now **moot for the
approximation**: the injected `UsableItemController` subclass and the generic
controller-swap instantiation are simply not on this path.

The overall verdict of the plan — *not a faithful port; the approximation is a
multi-spike track* — is unchanged. This spike cleared the first spike, not the
track.
