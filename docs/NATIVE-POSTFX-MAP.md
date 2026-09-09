# NATIVE POSTFX MAP — driving the game's OWN rendering from a POSTFX subtab

Status: **map only.** No host or mod code implements any of this yet. Every
address, offset and enum value below is MEASURED offline from the shipped
`GameAssembly.dll` + decrypted metadata; anything I did not measure is labelled
`inferred` and says what would settle it.

Standing instrument for the whole document (run from the repo root, PowerShell):

```
$g="D:\Games\Tarkov\GameAssembly.dll"; $m=".cache\global-metadata.dec.dat"
python tools\il2cpp_resolve.py $g $m typemethods <Type>
python tools\fldoff.py         $g $m fields <Type>
python tools\il2cpp_resolve.py $g $m disasm <RVA> --len N
python tools\il2cpp_resolve.py $g $m callers <RVA>
python tools\il2cpp_resolve.py $g $m bytes <RVA>
```

Mandatory self-check, run before any offset here was trusted, and it passed:

```
python tools\fldoff.py $g $m field System.String _stringLength   ->  0x10
```

Build 1.1.0.1.46777. Imagebase `0x180000000`; every RVA below is in the
`il2cpp` section (checked with `bytes`), so runtime address =
`GameAssemblyBase + RVA`.

**One tool defect found while writing this, reported per CLAUDE.md 10:**
`il2cpp_resolve.py disasm` **silently ignores an unrecognised flag**. I passed
`--count 200` (wrong name for `--len`) three times and got the default 16-line
window back each time with no complaint — which reads as "this function is only
16 instructions long", a confidently wrong answer of exactly the shape section
10 is about. It should refuse an unknown `--x` argument rather than fall back to
a default.

---

## 0. The one-paragraph conclusion

Everything the pre-1.0 PostFX tab drove is **still in this build, still wired,
and still applied by non-generic, UNIQUE-RVA methods that take one scalar
argument**. The shading/quality half is the same. So the route is not a shader
of ours over the back buffer; it is: *walk to the live component → direct call
at a byte-verified RVA with the value the game itself would pass → read the
finished state back*. No detour, no injection, no managed allocation, no
reflection.

---

## 1. The stock PostFX settings BSG folded away

### 1.1 They are all still declared

`fields EFT.Settings.PostFx.PostFxSettingsGroup` (MEASURED). Each row is a
`GameSetting<T>` reference held by the group:

| off | field | T |
|---|---|---|
| 0x18 | EnablePostFx | bool |
| 0x20 | Brightness | int |
| 0x28 | Saturation | int |
| 0x30 | Clarity | int |
| 0x38 | Colorfulness | int |
| 0x40 | LumaSharpen | int |
| 0x48 | AdaptiveSharpen | int |
| 0x50 | ColorFilterType | Filter |
| 0x58 | Intensity | int |
| 0x60 | ColorBlindnessType | ColorBlindMode |
| 0x68 | ColorBlindnessIntensity | int |

`EFT.UI.Settings.PostFXSettingsTab` also still exists as a real `SettingsTab`
with `_settingsRoot@0xA0`, `_selectFloatSliderTemplate@0xB0`,
`_dropDownTemplate@0xB8`, `_toggleLeftTemplate@0xC0`,
`_postFXSettingsGroup@0xD8`, `_visualizeButton@0xC8` (MEASURED). **So "BSG
deleted the PostFX tab" is false as a statement about the code**: types, group,
templates and appliers are all present and unstubbed. Whether the tab is
*reachable* in the shipped 1.0 UI is a live question — `inferred` until someone
opens Settings and runs `findtext` for one of its captions.

### 1.2 Do NOT go through `GameSetting<T>` — it is a shared generic

`typemethods Bsg.GameSettings.GameSetting'1` (MEASURED): `get_Value`,
`set_Value`, `SetValue`, `ForceApply` all report `RVA=- sharedness=NO-CODE`,
because they are uninstantiated generic definitions with 11 instantiated bodies
each. A shared-generic body is precisely the case where a NULL `MethodInfo*` is
*not* fine (CLAUDE.md 5). The value's storage has no offline offset either:
`fields Bsg.GameSettings.GameSetting'1` returns `GENERIC — NO LAYOUT`.

**Consequence:** the settings-object route costs a live class walk plus a
correct `MethodInfo*` for one instantiation. The applier route below costs
neither.

### 1.3 The appliers — non-generic, UNIQUE, one scalar argument

`typemethods EFT.Settings.PostFx.PostFxSettingsController` (MEASURED). Instance
methods; ABI `RCX=controller, EDX=value, R8=NULL MethodInfo*`.

| method | RVA | sharedness |
|---|---|---|
| TryForceUpdate() | 0xBE8880 | UNIQUE |
| UpdateEnablePostFX(bool) | 0xBE92B0 | UNIQUE |
| TryUpdateBrightness(int) / UpdateBrightness(int) | 0xBE9350 / 0xBE9420 | UNIQUE |
| TryUpdateSaturation(int) / UpdateSaturation() | 0xBE9560 / 0xBE9620 | UNIQUE |
| TryUpdateClarity(int) / UpdateClarity(int) | 0xBE9730 / 0xBE9800 | UNIQUE |
| TryUpdateColorfulness(int) / UpdateColorfulness() | 0xBE9930 / 0xBE99F0 | UNIQUE |
| TryUpdateLumaSharpen(int) / UpdateLumaSharpen(int) | 0xBE9B00 / 0xBE9BD0 | UNIQUE |
| TryUpdateAdaptiveSharpen(int) / UpdateAdaptiveSharpen(int) | 0xBE9D00 / 0xBE9DD0 | UNIQUE |
| TryUpdateColorFilterType(Filter) / Update…(Filter) | 0xBEA1C0 / 0xBEA290 | UNIQUE |
| TryUpdateIntensity(int) / UpdateIntensity(int) | 0xBEA2B0 / 0xBEA380 | UNIQUE |
| TryUpdateColorBlindnessType / Update… | 0xBE9F00 / 0xBE9FD0 | UNIQUE |
| TryUpdateColorblindnessIntensity / Update… | 0xBE9FF0 / 0xBEA0C0 | UNIQUE |

`_postFx@0x28` on the controller is the `GradingPostFX` it drives (MEASURED).
`UpdateBrightness` prologue MEASURED `48 89 5C 24 10 57 48 83 EC 30 48 8B 59 28
0F 29` — a real body, **not** this build's universal empty stub at `0x628110`.

`Try*` vs bare: `inferred` from the naming plus `UpdateBrightness` reading
`[rcx+0x28]` in its first instructions — the `Try*` form presumably null-checks
`_postFx` first. **Prefer `Try*`**: a null-check the game wrote beats one we add.

### 1.4 The pipeline component: `GradingPostFX`

`fields` + `typemethods GradingPostFX` (MEASURED). It has a real
`OnRenderImage(RenderTexture,RenderTexture)` @`0x1F04BB0`, so it is live code on
the camera, not dead weight.

Float state, directly readable for the read-back proof:

| off | field | off | field |
|---|---|---|---|
| 0x80 | _clarityStrength | 0x94 | _adaptiveSharpenStrength |
| 0x84 | _brightness | 0x98 | _colorBlindMode (enum) |
| 0x88 | _saturation | 0x9C | _colorBlindAmount |
| 0x8C | _colourfulness | 0xA0 | _currentFilter (enum) |
| 0x90 | _lumaSharpenStrength | 0xA4 | _currentFilterAmount |

Setters, all UNIQUE, instance, one float (`RCX=this, XMM1=coef, RDX=NULL
MethodInfo*` — the float takes the XMM register matching its integer slot, so
slot 1 = XMM1):

`UpdateClarityStrength` 0x1F05280 · `UpdateTechnicolorBrightness` 0x1F053A0 ·
`UpdateTechnicolorSaturation` 0x1F054C0 · `UpdateColourfullness` 0x1F055C0 ·
`UpdateLumaSharpenStrength` 0x1F056C0 · `UpdateAdaptiveSharpenStrength`
0x1F057E0 · `SetColorBlindMode` 0x1F05900 · `UpdateColorBlindAmount` 0x1F05C00 ·
`SetFilter` 0x1F05CE0 · `UpdateFilterAmount` 0x1F05F00 · `UpdateDynamicValues`
0x1F05FE0.

`UpdateClarityStrength` prologue MEASURED
`48 89 5C 24 10 57 48 83 EC 30 80 3D 19 BE 1B 05`.

### 1.5 The ranges — and the clamp the UI imposes that the field does not

`GradingPostFX` carries its own `Vector2` min/max pairs (MEASURED):

| off | field |
|---|---|
| 0xB8 | _clarityStrengthMinMax |
| 0xC0 | _technicolorBrightnessMinMax |
| 0xC8 | _technicolorSaturationMinMax |
| 0xD0 | _desaturateMultiplyMinMax |
| 0xD8 | _colourfulnessMinMax |
| 0xE0 | _lumaSharpenStrengthMinMax |
| 0xE8 | _adaptiveSharpenStrengthMinMax |

These are `INITONLY` **instance** fields deserialised from the prefab, so their
*values* are not in the DLL — read them off the live component. This is exactly
the clamp the brief asks about, and there are **two clamps stacked**:
`PostFxSettingsController.Update*(int)` applies the UI's 0..100 integer range on
top, then `GradingPostFX.Update*(float coef)` lerps a coefficient into the
prefab MinMax pair (`inferred` from the `coef` parameter name plus the paired
MinMax fields; settle with `disasm 0x1F05280 --len 0x120` before shipping a
slider). Calling `GradingPostFX` directly skips the integer clamp but still
lands inside the prefab range; storing `_clarityStrength@0x80` raw skips both —
the one action here that can produce a value the game itself would never
produce, and therefore the one I would not do first.

---

## 2. The shading / quality knobs

### 2.1 The settings that exist

`fields EFT.Settings.Graphics.GraphicsSettingsGroup` (MEASURED), the rows that
change how the world is lit:

| off | setting | T |
|---|---|---|
| 0x30 | GraphicsQuality | Nullable&lt;int&gt; |
| 0x38 | ShadowsQuality | int |
| 0x40 | TextureQuality | int |
| 0x80 | AnisotropicFiltering | AnisotropicFiltering |
| 0x88 | OverallVisibility | float |
| 0x90 | LodBias | float |
| 0xA8 | Ssao | ESSAOMode |
| 0xB0 | Sharpen | float |
| 0xB8 | SSR | ESSRMode |
| 0xD0 | HighQualityFog | bool |
| 0xD8 | GrassShadow | bool |
| 0xE0 | ChromaticAberrations | bool |
| 0xE8 | Noise | bool |
| 0xF0 | ZBlur | bool |
| 0x100 | HighQualityColor | bool |
| 0x110 | VolumetricLight | ESSRMode |
| 0x138 | _controller | GraphicsSettingsController |

`ESSAOMode` (MEASURED constants): `Off=0 FastestPerformance=1
FastPerformance=2 HighQuality=3 HighestQuality=4 ColoredHighestQuality=5`.
Six levels — **more than the shipped dropdown offers**. That is the second
"the UI clamps below what the field accepts" case in this document, and the
cheapest visible win on the whole list.

### 2.2 The appliers — `EFT.CameraControl.CameraManager`, all UNIQUE

`typemethods EFT.CameraControl.CameraManager` (MEASURED):

| method | RVA |
|---|---|
| get_Instance() **static** | 0x1263BD0 |
| SetSSAO(ESSAOMode) | 0x126B930 |
| SetSSR(ESSRMode) | 0x126BD10 |
| SetSharpen(float) | 0x126BCF0 |
| SetOverallVisibility(float) | 0x126B630 |
| SetChromaticAberration(bool) | 0x126B560 |
| SetNoise(bool) | 0x126B5D0 |
| SetZBlur(bool) | 0x126C920 |
| EnableAutoExposure(bool) | 0x126B600 |
| SetSuperSampling(float) | 0x126B4F0 |
| SetPrismPreset(Camera, PrismPreset) | 0x12656E0 |
| GetSSREnabled() | 0x126C080 |

Fields for the walk (MEASURED): `instance` (static), `<PostFX>k__BackingField
@0x58` → GradingPostFX, `<Camera>k__BackingField@0x70`, `_prismEffects@0xE8` →
PrismEffects, `_ssaa@0x110`.

Prologues MEASURED — `SetSSAO` `48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 55`;
`SetSharpen` `48 83 EC 28 48 8B 81 D0 00 00 00 48 85 C0 74 0A`;
`get_Instance` `48 83 EC 28 80 3D E6 8B E5 05 00 75 18 48 8D 0D`.

### 2.3 Shadows

`GraphicsSettingsController::ChangedShadowQuality(int)` @`0xBF5570`, UNIQUE.
MEASURED `disasm 0xBF5570 --len 0x1F0`: its only IL2CPP-owned call is
`EFT.Settings.Graphics.QualityLevelPreset::Apply()` @`0xC03890` — everything
else is `il2cpp_codegen` runtime helpers in `.text`.

`fields EFT.Settings.Graphics.QualityLevelPreset` (MEASURED) — the shadow
control surface, all plain scalars:

| off | field | off | field |
|---|---|---|---|
| 0x10 | _pixelLightCount | 0x30 | _shadowNearPlaneOffset |
| 0x14 | _antiAliasing | 0x34 | _shadowCascades |
| 0x18 | _softParticles | 0x38 | _shadowCascade2Split |
| 0x19 | _realtimeReflectionProbes | 0x3C | _shadowCascade4Split (Vector3) |
| 0x20 | _shadowMaskMode | 0x48 | _skinWeights |
| 0x24 | _shadows (ShadowQuality) | 0x4C | _maximumLodLevel |
| 0x28 | _shadowResolution (ShadowResolution) | 0x50 | _particleRaycastBudget |
| 0x2C | _shadowProjection | static | _singleShadowCascades |

Static instances `_low`/`_medium`/`_high`/`_ultra` (MEASURED, in the statics
block), plus `GetPreset(int)` @`0xC03E10` and `ApplyShadowShaderKeywords()`
@`0xC03FF0`. `Apply()` prologue MEASURED
`48 89 5C 24 08 57 48 83 EC 40 80 3D FC 64 4B 06`.

**There is no shadow-DISTANCE field here.** MEASURED `callers 0x5273200` on
`UnityEngine.QualitySettings::set_shadowDistance`: **0 direct callers**, and the
tool states that also means nothing inlined the body away. So on this build BSG
never sets shadow distance from managed code; it comes from the Unity quality
asset. That makes `set_shadowDistance` @`0x5273200` (**static**, `XMM0=value`,
`RDX=NULL MethodInfo*`) a knob we would be the only writer of — which is both
the appeal and the risk: nothing will fight us for it, and nothing will restore
it either.

### 2.4 Ambient occlusion — BSG uses **Prism**, not Unity PPv2

MEASURED `find SSAO` / `find AmbientOcclusion`: `PrismSSAO` and `PrismEffects`
live in `Assembly-CSharp.dll` and are BSG's;
`UnityEngine.Rendering.PostProcessing.*` and two `UnityStandardAssets` AO
scripts also exist in the build but are `inferred` unused — no evidence either
way was collected, so do not call them dead.

`fields PrismEffects` (MEASURED). These are **public** fields, so a write is a
plain field store with no property call:

| off | field | off | field |
|---|---|---|---|
| 0x268 | useAmbientObscurance (bool) | 0x284 | aoRadius |
| 0x26C | aoSampleCount (SampleCount) | 0x288 | aoDownsample (bool) |
| 0x270 | useAODistanceCutoff (bool) | 0x28C | aoBlurType |
| 0x274 | aoDistanceCutoffLength | 0x290 | aoBlurIterations |
| 0x278 | aoDistanceCutoffStart | 0x294 | aoBias |
| 0x27C | aoIntensity | 0x234 | useFog (bool) |
| 0x280 | aoMinIntensity | 0x238…0x264 | fogIntensity / fogStartPoint / fogDistance / fogColor / fogEndColor / fogHeight |
| 0xE8 | useVignette | 0xEC…0xF8 | vignetteStart / End / Strength / Color |

`PrismSSAO` is the same shape with its AO block at `0x91…0xCA`
(`useAmbientObscurance@0x91`, `aoSampleCount@0x94`, `aoIntensity@0xA4`,
`aoRadius@0xAC`, `aoBlurIterations@0xB8`, `aoBias@0xBC`) — MEASURED. Which of
the two is on the raid camera is `inferred`: `CameraManager._prismEffects@0xE8`
types as `PrismEffects`, so **PrismEffects is the one to walk to**. Settle it
live with `component <camera> PrismEffects`.

This is the real answer to "bad shadows/AO": **the AO the game already renders
has an intensity, a radius, a sample count and a blur-iteration count sitting in
public float fields, and its quality enum has two levels above what the dropdown
offers.** That is a far better lever than any screen-space fake of ours.

---

## 3. How a write takes effect, and the read-back that proves it

1. **Root.** `CameraManager::get_Instance()` @`0x1263BD0`, prologue-verified
   against the startup snapshot (`abi/aowlspt_prologue.h`), called inside the
   single `aowl_p_p_seh`. Null → refuse and say so.
2. **Walk, validating every hop** (`aowl_is_readable` per dereference):
   `instance → _prismEffects@0xE8` for AO/fog, or
   `instance → <PostFX>k__BackingField@0x58` for the colour block. Never an
   offset that can read null without a check — that is how `_rectTransform@0x78`
   burned a day.
3. **Write** through `hostfieldwrite` / `abi/aowlspt_fieldrefs.h`: one
   `AowlFieldRef` row per field, declaring type name, offset, width and
   ref-ness, so the existing admission gate (`aowl_fr_admit`, `aowl_fr_recvok`,
   `tools/fieldrefs.py`) refuses a wrong-klass receiver, a narrowing store or a
   width mismatch **before** the store. The counters
   `refused_narrow_ref` / `refused_width` / `refused_klass` / `admitted` already
   exist and belong in the verdict line.
4. **Apply.** A raw store on a Prism script takes effect on the next
   `OnRenderImage` with no apply call (`inferred` — the Prism scripts read their
   public fields each frame; falsifiable by writing `aoIntensity` and watching
   the frame). For settings-owned knobs, call the game's own applier instead:
   `SetSSAO` / `SetSharpen` / `SetSSR` / `SetOverallVisibility` on CameraManager;
   `ChangedShadowQuality` (→ `QualityLevelPreset::Apply`) for shadows;
   `PostFxSettingsController.TryUpdate*` then `TryForceUpdate` for colour.
5. **Proof — a property of the FINISHED STATE, never of our own write**
   (CLAUDE.md 9b). Do not re-read the field we just stored; read downstream:
   * AO: `SetSSAO(HighestQuality)`, then read `PrismEffects.aoSampleCount@0x26C`
     and `useAmbientObscurance@0x268` — values the *applier* chose.
   * Sharpen: `SetSharpen(x)`, then read
     `GradingPostFX._lumaSharpenStrength@0x90`; and the negative — no other
     `Update*` float on that component moved.
   * Shadows: `ChangedShadowQuality(n)`, then
     `UnityEngine.QualitySettings::get_shadowResolution` / `get_shadowCascades`
     — the engine's opinion, not the preset object's.
   * Three outcomes always: PASS / FAIL / **INCONCLUSIVE** when the component
     was not reachable (menu, no raid camera, walk refused). "I could not look"
     is not a pass.

Steps 1-2 and the read-back are all available **today in the live inspector**
(`component` / `read` / `call`) at zero build cost. Do that before writing a
line of host code.

---

## 4. Ranked proposal for the POSTFX subtab

`settingsbind.nim` supports `sbdToggle`, `sbdSlider`, `sbdDropdown`, `sbdEnable`
(MEASURED: `grep -n kind host/Aowlspt.Host.Il2Cpp/settingsbind.nim`).
`dlssrows.nim` is the working precedent for native rows on a graphics tab.

| # | row | kind | drives | cost | why |
|---|---|---|---|---|---|
| 1 | SSAO quality, all 6 levels (unclamped) | dropdown | SetSSAO 0x126B930 | cheap → expensive at the top | one enum store plus the game's own re-config; levels 4-5 raise sample count, so the cost is the game's normal AO cost at a setting it already supports |
| 2 | AO intensity / radius | slider ×2 | PrismEffects.aoIntensity@0x27C, aoRadius@0x284 | **free** | shader uniforms already sampled every frame; a different float is not more work |
| 3 | AO blur iterations | slider | aoBlurIterations@0x290 | cheap, linear | each iteration is one extra full-screen blur pass |
| 4 | Shadow quality / resolution / cascades | dropdown ×3 | ChangedShadowQuality 0xBF5570 → QualityLevelPreset::Apply 0xC03890 | **expensive** | more cascades and higher resolution re-render the shadow map; the one row that can cost real frames, and the one that fixes "bad shadows" |
| 5 | Shadow distance | slider | QualitySettings::set_shadowDistance 0x5273200 | expensive | more geometry in the shadow pass; and see §2.3 — we would be its only writer |
| 6 | Sharpen (the game's own) | slider | SetSharpen 0x126BCF0 | **free** | replaces our CAS with BSG's, in the right colour space, inside their pipeline |
| 7 | Clarity / Brightness / Saturation / Colourfulness / LumaSharpen / AdaptiveSharpen | slider ×6 | PostFxSettingsController.TryUpdate* | **free** | already in the frame's cost; these are the folded-away 1.0 rows, restored |
| 8 | Chromatic aberration / Noise / ZBlur off | toggle ×3 | SetChromaticAberration / SetNoise / SetZBlur | free (negative) | turning them off *saves* time |
| 9 | High-quality fog / grass shadow / LOD bias / anisotropic | toggle + slider | group + controller | cheap | ordinary quality knobs |
| 10 | Overall visibility | slider | SetOverallVisibility 0x126B630 | expensive | draw distance: more geometry, and it is competitively sensitive |

Verdict lines each row should print, SAIN-style — one per row per apply, with
the value read back from the finished state and never from our own store:

```
postfx: SSAO -> HighestQuality(4)  APPLIED  readback PrismEffects.aoSampleCount=<n> (was <m>)
postfx: SSAO  REFUSED  CameraManager.Instance null (no raid camera) -- INCONCLUSIVE, not off
postfx: shadowQuality -> 3  APPLIED  QualitySettings.shadowCascades=4 shadowResolution=3
postfx: sharpen -> 0.60  APPLIED  GradingPostFX._lumaSharpenStrength=0.42 (coef lerped into prefab MinMax)
postfx: aoIntensity  BLIND-WRITE REFUSED  fieldref klass mismatch (receiver is not PrismEffects)
```

Suggested build order: **6 → 7 → 1 → 2 → 3 → 4.** Row 6 is one call and proves
the whole call-and-read-back mechanism against a float we can see; row 7 is the
same mechanism six times and delivers the visible "the folded-away tab is back";
rows 1-3 are the actual answer to bad AO; row 4 is the expensive one and should
land last, alone, with a frame-time measurement beside it.

---

## 5. What is NOT established

* Whether the PostFX tab is reachable in the shipped 1.0 UI (§1.1).
* Whether `PrismEffects` or `PrismSSAO` is the script on the raid camera (§2.4).
* The numeric MinMax ranges — prefab data, not DLL data (§1.5).
* Whether `Update*(float coef)` takes a normalised 0..1 or a raw value
  (`disasm 0x1F05280 --len 0x120` settles it).
* Whether the `Try*` prefix means a null-check (§1.3).
* Every cost class in §4 is an estimate from what the pass does, **not** a
  measurement. Nothing in this document has been timed on this machine.
