# aowl.graphics — post-process graphics overhaul

A togglable full-frame post-processing stack for post-1.0 Escape From Tarkov
(IL2CPP, build 1.1.0.1.46777). Ported and heavily expanded from the BepInEx
`TarkovGraphics` mod (AgX tonemapper), rebuilt for the native aowlspt host where
there is no BepInEx and managed C# does not run.

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

## The stack (pipeline order)

`CAS sharpen → linearize → exposure + highlight roll-off + shadow lift → white
balance → bloom composite → tonemap look (AgX / ACES / none) → lift-gamma-gain →
contrast → saturation → vignette → back to sRGB`

- **AgX** — the ported Sobotka matrices + polynomial sigmoid (same as
  `Shaders/AgXTonemap.shader`), applied as a blendable look.
- **ACES** — Narkowicz fit, selectable alternate.
- **Color grade** — exposure, contrast, saturation, temperature/tint white
  balance, lift/gamma/gain, plus the original `shadows`/`highlights` knobs.
- **CAS** — AMD-style contrast-adaptive sharpening.
- **Bloom** — bright-pass + separable Gaussian at half resolution (optional).
- **Vignette** — smooth, radius-controlled.
- **SSAO** — *not implemented*: it needs the depth buffer, which the engine binds
  separately from the back buffer. Parked for the in-engine bridge path.

## Defaults (sane, subtle)

AgX at 0.85 strength, exposure 0, contrast 1.05, saturation 1.05, CAS 0.35,
bloom 0.35, vignette 0.18. Neutral-plus: cleaner highlights and a touch of
contrast/sharpness over stock, nothing garish. Everything is in `config.json`
and editable live from the F12 settings panel.

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

## Status

- **Working / compiles clean:** the mod, the host module, the whole D3D11
  pipeline (vtable capture, Present/ResizeBuffers detours, runtime HLSL compile,
  bright-pass bloom, main grade, state save/restore), the config → `gfx_apply`
  wire, the settings schema. Safe-by-default: any failure latches `broken` and
  Present becomes a pass-through.
- **Pending live validation:** confirming the hook lands on the game's real swap
  chain (use `diag`), tuning defaults against real raids, and Present-hook
  ordering vs. the overlay (graphics is started after the overlay so it grades
  first and the UI draws on top — verify in-game).
- **Pending the bridge:** the in-engine HDR path and depth-based SSAO.
