# aowl.textures — bundle-file redirect

Replace EFT textures by making a vanilla bundle key resolve to **our** file on
disk. Exactly what SPT's `spt-custom.dll` does on 4.1.2.

```
aowl build-mod mods/textures     # compile the client mod (a .dll)
```

> **This README was rewritten on 2026-08-26 because the previous one described a
> mechanism that has been retired.** It documented a name-keyed `Texture2D`
> substitution (`swap.nim`) in detail, as though it were the live design. It is
> not — it is off, kept only so the measurements that killed it stay
> reproducible. Do not implement against the old text; it is in git history.

---

## 1. The reachability map — what this mechanism CAN and CANNOT touch

**This is the most important section in this file.** The mechanism has a hard
ceiling, and the failure mode at that ceiling is *silent*: you patch something,
every structural check passes, and the screen does not change.

All rows below were **measured on 2026-08-26** against the real install, not
recalled. The instrument is named per row.

| surface class | reachable? | where it actually lives | evidence |
|---|---|---|---|
| **Prefab / world-object textures** (props, rocks, containers, weapons, items) | **YES** | `StreamingAssets/Windows/assets/content/location_objects` — 276 bundle files, **1.2 GB** | `pipeline/reachability.py` §3 |
| **Terrain detail / grass** | **YES, partly** | grass *prefabs* are bundles; the grass *placement* is `StreamingAssets/Grass/*.pcl` (7 files, not textures) | directory listing |
| **Skybox / environment presets** | **YES** | `StreamingAssets/Windows/maps/*_preset.bundle` (19 files) | directory listing |
| **Terrain GROUND (what you walk on)** | **NO — HARD BLOCKER** | `sharedassetsNN.assets`, loaded engine-side. **Never passes through `EasyBundle`.** | see below |

### Why terrain ground is not reachable — confirmed, not assumed

I re-measured rather than trusting the recorded facts. A plaintext name scan of
the uncompressed `.assets` files (`scratchpad/namescan.py`, counts only):

```
sharedassets17.assets   128,926,224   MicroSplatConfig: 36   _Diffuse: 18   SplatAlpha: 6
sharedassets140.assets  164,844,272   SplatAlpha: 3
sharedassets161.assets  903,776,836   City_Asphalt_Trim_01: 2
sharedassets165.assets  256,440,004   SplatAlpha: 12   Grass_02_512: 14
```

That confirms **fact #84** (terrain textures are in `.assets`, not bundles) and
**fact #91** (the ground diffuse is a MicroSplat `Texture2DArray`, bound as
`_Diffuse`, in `sharedassets17`).

The structural half is what makes it a *hard* blocker, and it does not depend on
the scan at all: this mod's only lever is `EasyBundle._path`. `sharedassetsNN.assets`
is loaded by the **Unity engine's own scene loader**, which never constructs an
`EasyBundle`. Corroborating measurement: `assets/content/locations` is **6 KB**
(presets only) — the map scenes are genuinely not shipped as bundles, whereas
`sharedassets*` totals **23.1 GB** (1,225 files) against the bundle root's
**38.0 GB** (7,561 files).

Everything in this section is re-runnable: `python pipeline/reachability.py`.
Re-run it after any Tarkov update — the answer is build-specific, and a stale
answer fails silently.

So: *even a perfectly working redirect cannot reach the ground.* This is not a
bug to be fixed at this layer.

### What WOULD reach terrain ground, and what it costs

Patching `sharedassets17.assets` / `.resS` in place. That is blocked **twice
over**, both measured today:

1. **Hardlinks (fact #89).** `os.stat().st_nlink == 2` on `sharedassets17.assets`,
   its `.resS`, `sharedassets161.assets` — **and on the bundle files and
   `Windows.json` too**. An in-place write **corrupts the real Tarkov install at
   `D:\Games\Tarkov`**. You must back up, delete to break the link, write fresh,
   and re-check `st_nlink == 1`.
2. **The consistency manifest (CLAUDE.md §7).** `D:\Aowlspt\ConsistencyInfo` has
   **10,599 entries: 8,398 StreamingAssets bundles AND 1,286 sharedassets.** Both
   classes are covered. Each entry carries `Size` and `Checksum`, and I
   reproduced the checksum formula `sum(bytes) % 2**32` **byte-for-byte** on
   `maps/customs_preset.bundle`. A same-size replacement is not enough.

So the terrain route costs: break a hardlink safely, rewrite a 129 MB `.assets`
plus a 335 MB `.resS` with a correct Unity serialiser (no such tool is present —
`UnityPy` is **not installed** here), then re-sync two manifest fields. That is a
different project, and it puts the user's real game install at risk.

**The redirect, by contrast, writes no game file at all** — it points at a file
outside the manifest. That is why it is the only mechanism here that is safe by
construction, and it is the reason to keep the ceiling rather than break it.

---

## 2. The mechanism

A typed **PREFIX** on `Diz.Resources.EasyBundle::Load`, which rewrites `_path`
before anything reads it. Every number below was **re-verified on 2026-08-26**,
independently of the prior session:

- `Diz.Resources.EasyBundle::_path` @ **`0x20`**, type `string`
  — `python tools/fldoff.py fields Diz.Resources.EasyBundle`
- `void Load()` rid=42 @ **`0x2772cc0`**, arity 0, and **no `[SHARED]`
  annotation** — a genuinely unique RVA, so detouring it is safe
  — `python tools/il2cpp_resolve.py <gameasm> <metadec> type 30933 --shared`

The same query shows why this family is dangerous in general: `get_Assets`
@`0x6864D0` is **shared by 200 methods**, `get_LoadState` @`0x690d20` by 136.
`Load` is not one of them. **Re-run that check before retargeting anything here.**

Why `Load` and not `.ctor`: the ctor is arity 5, so a postfix is refused by the
host twice (stack args, and 7 register slots), and a prefix cannot help because
the frame ABI has no `aowl_frame_set_arg_*` and at prefix time `_path` is not yet
written. At `Load` entry `_path` is populated and still unread.

**The verbatim-name rule (fact #73):** the on-disk file must be named *exactly*
like the key. 214 of 292 in-scope keys have **no** `.bundle` extension; appending
one silently killed 214 of 278. This module never normalises, lowercases,
appends or strips. `path = bundleRoot & "/" & key`, and nothing else.

---

## 3. Verification — the part that must not lie

**The standing risk on this mod is a confident, verifiable, entirely wrong
success.** Fact #91 is the recorded precedent: patching the 12 named
`TerrainLayer` albedos *verified perfectly and changed nothing on screen*,
because the thing being rendered was a different object.

So the rule here: **a structural check is EVIDENCE, NOT PROOF.** "The file was
written", "the handle was rewritten", "the load succeeded", "the counter
incremented" — each is compatible with nothing changing on screen. None of them
is a pass.

### Bring-up procedure: make the wrong answer unmistakable

Do **not** bring this up with a subtle high-res retexture; a subtle change is
indistinguishable from no change. Use a **garish solid colour**.

1. Pick ONE key from `content/location_objects` that is visible immediately in a
   known spot. Build a patched bundle where the albedo is **solid magenta**.
2. Set `bundleRoot` to the pack dir; drop the file in named **verbatim**.
3. Ladder up one rung at a time: `redirectMode` `off` → `probe` (counts firings,
   writes nothing) → `match` (reads `<Key>`, counts hits, samples misses, still
   writes nothing) → `full` (rewrites `_path`).
4. **The `match` rung is the real instrument.** Its miss-sampler prints the keys
   the game *actually* asks for, rather than what an offline pipeline guessed.
   Get a hit here before ever going to `full`.
5. **Settle it on what renders.** Magenta on screen = PASS. Stock texture =
   FAIL. Could not get to the object / screen never loaded = **INCONCLUSIVE**,
   which is *not* a pass.

### The check that can actually fail — a negative control

A hit counter that only ever goes up cannot fail. Pair the bring-up with a
**mutation proof**: point the redirect at a **deliberately corrupt** file under
the same key.

- If the bundle now **fails to load**, the redirect provably reaches the real
  load path.
- If **nothing changes**, the redirect is *not* reaching it, and any "success"
  from the magenta run was something else.

This is the input that makes the check falsifiable, and it is the reason to
trust a subsequent green result. Run it once, at bring-up, per surface class.

---

## 4. What a mod author can and cannot ship

**CAN** ship a texture pack for: prefab and world-object textures, props, rocks,
containers, weapons, items, grass prefabs, skybox/environment presets. Layout:

```
<install>/mods/textures/
  textures.dll
  config.json          # bundleRoot -> the pack dir
  <pack>/<key>         # named VERBATIM, one file per bundle key
  <pack>/index.txt     # optional: one key per line, verbatim
```

`index.txt` is worth shipping — with it the whole table is read once at arm time
and the hook path does zero filesystem I/O; without it each distinct key costs a
cached `open()` probe.

**CANNOT** ship: a replacement for the terrain ground the player walks on. That
is the MicroSplat `Texture2DArray` in `sharedassets17`, and no bundle redirect
reaches it. Anyone promising "retextured ground" through this mechanism is
either wrong or is patching the user's real game install.

**Also cannot** (fact #79): reliably replace **non-albedo** maps. `ImageConversion.LoadImage`
has no colour-space argument, so normals, roughness, AO and splat masks would be
gamma-decoded as sRGB. `albedoOnly` therefore defaults **TRUE** — non-albedo
entries are matched, counted (`refusedNonAlbedo`) and deliberately **not**
swapped. This constraint applies to the retired upload path; the redirect
mechanism sidesteps it entirely, since the game's own pipeline does the decode
with the correct flags.

---

## 5. Status

- **Not registered in `registry/mods.json`, deliberately.** It was unregistered
  in `4ee8b48` as unfinished, and nothing here yet justifies putting it back in a
  shipped list. Re-register only after the §3 bring-up returns a real PASS.
- Ships with `redirectMode: "off"` and `bundleRoot: ""` — either alone makes the
  mod inert.
- `swap.nim` (name-keyed swap) is retired behind `legacyNameSwap: false`. It
  detours the **same RVA** as the redirect, so the two are mutually exclusive and
  the redirect wins. Do not enable both.
