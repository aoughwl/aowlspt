# aowl.graphics — post-process graphics overhaul

A togglable full-frame post-processing stack for post-1.0 Escape From Tarkov
(IL2CPP, build 1.1.0.1.46777). Ported and heavily expanded from the BepInEx
`TarkovGraphics` mod (AgX tonemapper), rebuilt for the native aowlspt host where
there is no BepInEx and managed C# does not run.

## STATUS: LEGACY — kept as a backup, not developed further (2026-09-04)

This D3D11 back-buffer pass is **no longer the direction**. It stays in the tree,
buildable and unchanged, default OFF, as a fallback; it will not get new
features. Work on making the game look better moves to driving the game's *own*
renderer — see **`docs/NATIVE-POSTFX-MAP.md`**, which maps the stock PostFX
settings BSG folded away in 1.0, the shadow/AO/quality appliers, and the field
offsets and RVAs to reach them.

**Why the shipped default looked grey, plainly:** this pass runs on the **back
buffer**, which BSG has *already* tonemapped and encoded to LDR sRGB. Every
preset here then applied a **second** tonemapper (AgX at `tonemapStrength`
0.85-1.0). A tonemapper's job is to compress highlights into range; run one on an
image whose highlights are already at 1.0 and it has nothing left to recover and
everything to flatten — the toe crushes the blacks, the shoulder pulls the whites
down, and saturation follows luma down with them. That is the grey. It was a
double tonemap, not a taste disagreement, and the fix was never to re-season it.
Anyone reviving this pass should start from `tonemapStrength 0`, `tonemapper 0`,
bloom off, and keep only what BSG's frame does not already do (local contrast,
edge-adaptive sharpening, vibrance, dither).

The other structural limit, unchanged: the pass sees the shipped LDR image, not
the linear HDR scene, and has no scene depth — so SSAO, contact shadows and fog
were never reachable from here at all. The native route in the map above has all
three, because the game already renders them.

## The split (why this mod is only half the story)

The **rendering runs in the host, not in this mod.** A mod DLL has no GPU, no
D3D11 device and no swap chain, so it cannot draw. The pixels are pushed by a
native host module:

| Piece | Where | Does |
|---|---|---|
| Render passes | `abi/aowlspt_graphics.h` + `host/Aowlspt.Graphics/aowlgraphics.nim` | Hooks DXGI `Present`, runs the HLSL over the back buffer |
| Shader source | `mods/graphics/shaders/Post.hlsl` | AgX/ACES + grade + CAS + bloom + vignette (also embedded in the header) |
| Control surface | `mods/graphics/` (this mod) | Config, F12 settings schema, turns a config edit into a grade |

The one wire between them is a single host call:

```
call("aowlspt.host::gfx_apply", <compact-params-json>)
```

The host forwards that JSON verbatim to the native module, which copies it under
a lock and applies it on the next frame. On any host that does not carry the
graphics module the call just returns an error and this mod is an inert no-op —
the game renders normally.

## Which path: native D3D11, not in-engine

The original attached a `MonoBehaviour` to the FPS Camera and did the AgX blit in
`OnRenderImage`, in linear HDR. That cannot be ported literally here:

- IL2CPP with managed-code stripping **cannot define a new managed type**, so
  there is no `TonemapBehaviour` to attach.
- Loading a `Shader`/`Material` needs an AssetBundle plus a chain of boxed
  `il2cpp_runtime_invoke` calls; the Unity-thread bridge
  (`feat-il2cpp-bridge`, `abi/aowlspt_bridge.h`) provides "run a closure on the
  main thread", **not** a render helper.

So the effect runs as a **native D3D11 pass over the back buffer** (ReShade
style), compiled at runtime with `D3DCompile` against the game's own device.
This is screen-space only: it grades BSG's **finished LDR sRGB frame**, so AgX
here is a filmic *look*, not a literal replacement of their HDR tonemapper. That
is the honest limit of the screen-space path and it still gets most of the win.

## Presets — the point of the mod

Twenty sliders is a toolkit, not a product. A preset is one word that produces a
finished look, and one line you can paste into Discord for someone else to
reproduce it exactly:

```json
"preset": "cold-clinical"
```

| Preset | What it is for |
|---|---|
| `neutral` | Cleanup only — vanilla minus the banding and the mush. If you cannot tell it from stock in a screenshot, it is doing its job. |
| `filmic` *(default)* | AgX look, real contrast with the shadow toe bought back, a little grain. |
| `cold-clinical` | **Visibility first.** Cool, slightly bright, shadows pulled open hard. Bloom **off** — bloom is glare, and glare is a player you did not see. Vignette **off** — it darkens exactly the screen edge where peripheral movement lives. |
| `warm-cinematic` | The screenshot look. Warm, contrasty, bloomy, grainy, a touch of lens. Costs a little visibility. |
| `night-owl` | Dark interiors and night raids — Factory basements, Labs, Reserve bunkers. Exposure and gamma up, toe lifted hard, highlight roll-off raised so a flashlight does not blow out the wall in front of you. |
| `custom` | The sliders drive. |

**Semantics, deliberately unambiguous:** while `preset` is anything other than
`custom`, the preset **owns every look key** and the individual sliders are
ignored. Pick `custom` to drive them yourself. The alternative — letting a
slider partially override a preset — means that once you have touched one
slider, switching preset appears to do nothing, which is the single most common
way a preset system feels broken. `enabled`, `raidOnly` and `diag` are never
touched by a preset: they are policy, not a look.

## The stack (pipeline order)

`CAS sharpen → clarity → chromatic aberration → linearize → exposure +
highlight roll-off + shadow lift → white balance → bloom composite → tonemap
look (AgX / ACES / none) → lift-gamma-gain → contrast + shadow-toe re-lift →
saturation → vibrance → vignette → back to sRGB → film grain → output dither`

- **AgX** — the ported Sobotka matrices + polynomial sigmoid (same as
  `Shaders/AgXTonemap.shader`), applied as a blendable look.
- **ACES** — Narkowicz fit, selectable alternate.
- **Color grade** — exposure, contrast, saturation, temperature/tint white
  balance, lift/gamma/gain, plus the original `shadows`/`highlights` knobs.
- **CAS** — AMD-style contrast-adaptive sharpening.
- **Bloom** — bright-pass + separable Gaussian at half resolution (optional).
- **Vignette** — smooth, radius-controlled.
- **Clarity** — wide-radius local contrast (unsharp against a 4-tap low pass),
  masked to the mid-tones so it cannot crush blacks or blow highlights. This is
  the knob that makes a flat, hazy frame read as three-dimensional. It is a
  *different frequency band* from CAS on purpose; stacking two sharpeners on the
  same band is what produces ringing.
- **Vibrance** — saturation weighted by `1 - existing saturation`. Grey, washed
  out things gain; already-saturated things (foliage, flares, a hit marker) do
  not. That is the difference between colour separation and neon foliage.
- **Shadow detail** — re-lifts *only* the toe after contrast, so raising
  contrast does not cost you the ability to see a player standing in a doorway.
  A global `lift` cannot do this: it lifts the whole image into milk.
- **Film grain** — animated, weighted toward the shadows, which is both where
  real grain lives and where 8-bit banding lives.
- **Output dither** — triangular-PDF noise at ~1 LSB before the 8-bit write.
  The cheapest real win in the whole stack: every gradient built in linear above
  gets quantised on the way out, and dark Tarkov interiors are almost entirely
  gradient. On by default.
- **Chromatic aberration** — radial, red/blue only, exactly zero at the screen
  centre so it never smears what you are aiming at. Off by default.
- **SSAO / fog / DoF** — see the depth section below. Still not implemented, but
  the reason is now a measurement instead of an assumption.

## The depth buffer: a probe, not a claim

The old wording here was *"SSAO needs the depth buffer, which the engine binds
separately from the back buffer"*. That is an assumption, and it was never
measured. What is now true:

* **API-level, this is not blocked.** ReShade gets scene depth out of D3D11
  games routinely. Two routes exist: (a) whatever depth-stencil view is still
  bound when `Present` is called, if its texture carries
  `D3D11_BIND_SHADER_RESOURCE`; or (b) the ReShade route — intercept
  `ID3D11Device::CreateTexture2D` to add `BIND_SHADER_RESOURCE` and promote the
  format to typeless, then track clears per draw call. Route (b) is a much
  larger, per-draw write into the game's renderer and is not something to
  attempt on a hunch.
* **So route (a) is now probed, for free.** `aowl_gfx_save` already asks
  `OMGetRenderTargets` for the bound DSV every frame. `aowl_gfx_probe_depth`
  reads that view's texture descriptor **once**, and puts the verdict in the
  host status line. It binds nothing, reads no depth, and modifies nothing — it
  reports a descriptor.
* **Three outcomes, never two.** `depth: NO DSV bound at Present`,
  `depth: DSV WxH fmt=N bind=0xNN srv=no`, or `... srv=YES fullres=yes`. Only
  the last one means depth effects are reachable from this hook. `depth: not
  probed yet` is a fourth, honest state: no frame has been graded.

**Verdict today: INCONCLUSIVE.** The probe is built and marker-verified in the
DLL; it has never run, because running it requires the live client. Read
`aowl_gfx_status` in the host log after one raid frame and the answer is
there — no rebuild, no guessing.

## Performance

The whole stack is **one** fullscreen pass over the back buffer, plus one
`CopyResource` of the back buffer, plus **three more half-resolution passes if
and only if `bloom` is on**. Everything added in this revision (clarity,
vibrance, shadow detail, grain, dither, chromatic aberration) lives inside the
existing main pass:

| Effect | Extra texture taps | Extra passes |
|---|---|---|
| clarity | 4 | 0 |
| chromatic aberration | 2 | 0 |
| vibrance, shadow detail, grain, dither | 0 | 0 |
| **bloom** | 0 in the main pass | **3 half-res passes** |

So **`bloom` is the only expensive switch** — turn it off first if you are
chasing frames. `cold-clinical` already has it off.

The cost is **measured, not estimated**: the module issues a D3D11
timestamp-disjoint pair around the whole chain, collects it non-blocking on a
later frame (issuing timestamps *every* frame is itself a cost, so this samples
rather than instruments), exponentially averages it, and prints it in the status
line as `post N.NNN ms GPU (measured, K samples)`. If no sample has landed it
says `post GPU cost NOT MEASURED` — which is **not** the same as "free", and it
will never print a number it did not measure.

**The number itself is INCONCLUSIVE in this revision**: it can only be produced
by the running client. See the live test below.

## Defaults

`preset: "filmic"` — AgX at 0.90, contrast 1.10 with the shadow toe re-lifted
0.35, vibrance 0.35, clarity 0.30, CAS 0.35, bloom 0.30, vignette 0.20, grain
0.18, dither on. Everything is in `config.json` and editable live from the
settings panel.

## Raid-state gate (menu stays stock)

By default (`raidOnly: true`) the grade runs **only in a raid**; the main menu
and 2D UI screens render stock. The post-process is at Present level and has no
game-state knowledge, so the signal comes from the backend, which knows raid
state definitively:

```
tarkov mod                         manager mod                 client host                graphics module
POST /client/match/local/start  →  onRaidStarted (cache)   →   /aowlspt/mods/client   →   aowl_gfx_set_in_raid(1)
  broadcast tarkov.raid.started     put "inRaid":true            poll (~3s) parseInRaid     gate ramps 0→1 (fade in)
POST /client/match/local/end    →  onRaidEnded (cache)     →   same poll               →   aowl_gfx_set_in_raid(0)
  broadcast tarkov.raid.ended       put "inRaid":false                                       gate ramps 1→0 (fade out)
```

- The `inRaid` flag rides the mod-set poll the host **already** makes — no new
  endpoint, no new thread.
- The transition is a per-frame ramp of a `_GateAmount` blend (0 = untouched
  frame, 1 = full grade), so it fades over ~12 frames instead of popping — and
  it lands during the raid's black loading screen anyway.
- Safe-by-default: the gate defaults to closed (menu stock). If the backend/
  manager is absent the signal never arrives and the effect stays off — set
  `raidOnly: false` to grade everywhere (also the no-backend escape hatch).
- `diag: true` forces the grade on regardless of raid state, so the red-tint
  blit test works in the menu too.

## Config / controls

Flat keys in `config.json`; the F12 settings UI (settingshub) reads the schema
this mod declares and writes edits back through `/aowlspt/settings/aowl.graphics`.
`diag: true` red-tints the frame to confirm the blit lands on the right buffer.

## Build

```
$env:PATH="C:\msys64\ucrt64\bin;$env:PATH"
.\installer\build\aowl.exe build-mod mods/graphics   # this mod
.\installer\build\aowl.exe build-hosts               # the host DLL with the renderer
```

(Build from PowerShell — gcc fails silently in Git Bash.)

## The live test (nothing below has been observed, only built)

I cannot launch the client, so **every claim about how this LOOKS is
INCONCLUSIVE by construction.** What has actually been verified offline:

| Check | Result |
|---|---|
| All four HLSL entry points compile (`fxc /T ps_5_0`, `vs_5_0`) | **PASS** |
| `fxc` cbuffer reflection offsets match the C `f[]` writes byte for byte (`_Res` at offset 120 = `f[30]`, 128 bytes into a 144-byte buffer) | **PASS** |
| Header compiles standalone (`gcc -c`, no errors) | **PASS** |
| `mods/graphics` and the host DLL build | **PASS** |
| `tools/deploy.py check --only host --only graphics` with 5 new graphics markers and 4 new host markers | **PASS** (63 / 13 markers) |
| `config.json` parses strictly | **PASS** |
| How any of it looks in a raid | **INCONCLUSIVE — never run** |

The exact live test, in order:

1. `"diag": true, "raidOnly": false` → the menu goes red. This proves the blit
   still lands on the right back buffer after the shader rewrite. If it does
   not, nothing below matters.
2. `"diag": false`, enter a raid, and read the host status line. It now carries
   both new measurements in one string:
   `... | post N.NNN ms GPU (measured, K samples) | depth: ...`
   That single line settles the performance number **and** the depth verdict.
3. Cycle `preset` through `neutral` → `cold-clinical` → `warm-cinematic` →
   `night-owl` from the settings panel. **The falsifiable check is a negative:**
   `cold-clinical` must have no bloom and no vignette, and `warm-cinematic` must
   have both — if switching preset changes nothing, the preset path is dead and
   the sliders are still driving.
4. Stand in a dark interior (Factory basement, Labs) with `dither: 0` and then
   `dither: 1`. Banding in the wall gradient must visibly go away. This is the
   one effect whose presence or absence is unambiguous on a still frame.

## Status

- **Working / compiles clean:** the mod, the host module, the whole D3D11
  pipeline (vtable capture, Present/ResizeBuffers detours, runtime HLSL compile,
  bright-pass bloom, main grade, state save/restore), the config → `gfx_apply`
  wire, the settings schema. Safe-by-default: any failure latches `broken` and
  Present becomes a pass-through.
- **Pending live validation:** everything visual, plus the GPU cost number and
  the depth verdict — both of which the module now measures and prints itself,
  so validating them costs one raid and one log read rather than a guess.
- **Pending the bridge:** the in-engine HDR path. Depth-based SSAO is no longer
  blocked on the bridge in principle — it is blocked on the probe result.
- **Not implemented, deliberately:** `.cube` LUT loading. It needs file I/O, a
  3D texture and a new SRV slot, and the preset system already delivers the
  thing LUTs are wanted for (one line you can share). Half-shipping it would be
  worse than not shipping it.

## Present-hook coexistence (why it now works)

The detour engine refuses a **second** hook on the same DXGI `Present` function
(`aowlspt_detour.h` returns error -9 when it sees our own jump stub already
there). The overlay boots first and takes that hook, so graphics' own
`aowl_hook_install` was failing with "could not hook Present". Fixed by not
hooking twice:

- **Overlay present:** graphics runs in *driven mode* — no hook of its own. The
  overlay calls a registered pre-present callback (`aowl_gfx_grade`) at the top
  of its Present hook, once per frame, before drawing its UI. Grade first, UI on
  top. A matching pre-resize callback drops graphics' back-buffer refs before a
  resize (same DXGI_ERROR_INVALID_CALL hazard the overlay already guards).
- **Overlay absent** (it is being retired for native settings): graphics owns
  its own Present hook via `aowl_gfx_start`.

The host picks the path at boot with `overlayRunning()`. Both are safe-by-default
— any failure latches `broken` and the frame passes through untouched.
