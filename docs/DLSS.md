# DLSS on this install -- what works, what does not, and the evidence

Measured 2026-09-02 on the machine that runs `D:\Aowlspt`. Everything below
that says *measured* was read off this machine or off the named URL on that
date; everything that says *stated by* is somebody else's claim, reproduced
with its source. The tool is `tools/dlss.py`; its self-test is registered in
`tools/selftests.py`.

## TL;DR

* **This GPU is an RTX 2060 SUPER (Turing), driver 581.42.** Not a 2080 -- same
  generation, same feature set, less throughput.
* **The game ships DLSS Super Resolution 310.5.3.0** (`nvngx_dlss.dll`,
  54,779,504 bytes, sha256 `8707e53b…`), byte-identical to the DLL in NVIDIA's
  public SDK repository at tag `v310.5.3`. That is already a DLSS 4.5-era
  library: presets J/K (DLSS 4 transformer) and L/M (DLSS 4.5 second-gen
  transformer) exist in it, and the game's own Graphics settings expose a
  **DLSS Preset** dropdown (`EDLSSPreset`: Default/F/J/K/L/M).
* **What `tools/dlss.py install` does:** swaps in a newer SR DLL from a
  hash-verified official/TechPowerUp source (310.7.0 or 310.7.129), re-syncs
  the `ConsistencyInfo` manifest entry (the file is listed there with
  `IsCritical:true`; a size change without a re-sync stops the client from
  booting), and optionally writes the machine-wide driver preset override.
  Backup + rollback + read-back verification, all falsifier-tested.
* **"DLSS 5" is not a Super Resolution upgrade and is not installable here.**
  It is `nvngx_dlssnr.dll` 310.8.0.0, a leaked, unreleased *neural rendering*
  (re-lighting) model. There is no official source for it, NVIDIA's own launch
  (2026-09-03, NBA 2K27) is RTX 50-only, the community fork that wires it into
  arbitrary games states a 616.56 driver minimum (this machine: 581.42), and
  this game drives NGX through the **D3D11** API. `dlss.py` refuses it and says
  why. Details and sources in section 5. **2026-09-03: the user asked for it
  anyway, knowingly** -- that is `tools/dlssnr.py` and `docs/DLSSNR.md`, a
  separate tool with its own catalog, gates and falsifiers.

## 1. This machine and this install (measured)

| Item | Value | How |
|---|---|---|
| GPU | NVIDIA GeForce RTX 2060 SUPER, 8 GiB | `nvidia-smi` |
| Driver | 581.42 (WMI `32.0.15.8142`, 2025-09-21) | `nvidia-smi`, `Win32_VideoController` |
| Game DLL | `D:\Aowlspt\EscapeFromTarkov_Data\Plugins\x86_64\nvngx_dlss.dll` | search of `D:\Games\Tarkov` + `D:\Aowlspt` |
| Version | FileVersion **310.5.3.0** | PE version resource |
| Size / sha256 | 54,779,504 / `8707e53b26c68c606b98bf31c223485ff30d310a261b1a36d48b2eaabc1507ec` | `sha256sum` |
| Same file in `D:\Games\Tarkov` | identical hash; **not** hardlinked (`fsutil hardlink list` = 1 name each) | measured |
| Manifest | `ConsistencyInfo` entry `{"Path":"EscapeFromTarkov_Data\\Plugins\\x86_64\\nvngx_dlss.dll","Size":54779504,"Checksum":-785527982,"IsCritical":true}` (10,599 entries, 34 critical) | `grep` |
| Checksum formula | signed-int32(byte-sum mod 2^32) recomputed from the DLL = **-785527982 == manifest** | `dlss.py selftest` first check |
| Files checker | `files-checker_000.log`: "Consistency ensurance is launched … succeed. ElapsedMilliseconds:691" on every boot | client log |
| NGX bridge | `DLSSImporter.dll` (66,896 B) imports `NVSDK_NGX_D3D11_*` only, built from `NGX/core/rel_310_5` | `strings` |
| Driver-side NGX | `nvngx.dll` 488,800 B, `_nvngx.dll`, `nvngx_dlssg.dll` in the driver store (`nv_dispi.inf_amd64_901d8cfde13e2b8b`, 2025-09-23); no `nvngx_dlssnr.dll` | `ls` |
| NVIDIA App | present (`%LOCALAPPDATA%\NVIDIA Corporation\NVIDIA app`, `NvBackend`) | `ls` |
| DRS preset override | `0x10E41DF3` on the base profile: **unset** (`NvAPI_DRS_GetSetting` -> -160, which the driver itself names `NVAPI_SETTING_NOT_FOUND`; the base profile enumerates 0 customised settings) | `dlss.py preset get` |
| Game-side state | last client log: `"DLSSMode": "Off"`, `"DLSSPreset": "Default"`, `"DLSSEnabled": false` | `application_000.log` |

What the game exposes (offline metadata, `il2cpp_resolve.py … find/fields/type`, searched EXHAUSTIVELY):

* `EFT.Settings.Graphics.EDLSSMode` = Off 0, Quality 2, Balanced 3, Performance 4, UltraPerformance 5
* `EDLSSPreset` (Unity.Postprocessing.Runtime) = Default 0, F 6, J 10, K 11, L 12, M 13 -- these are the NGX
  `NVSDK_NGX_DLSS_Hint_Render_Preset_*` numbers, so the dropdown IS a per-app preset hint
* `DLSSWrapper::SetCurrentNvGfxPresetExt(uint)` @0x5005220, `GetCurrentNvGfxPresetExt()` @0x50051b0,
  `IsDLSSSupported()` @0x5005660, `InitializeDLSS()` @0x5005830, field `_currentNvGfxPreset@0xe8`
* `EFT.CameraControl.CameraManager::SetDLSSPreset(EDLSSPreset)` @0x126caa0,
  `EFT.UI.Settings.GraphicsSettingsTab::ShowDlssPreset()` @0x17107f0 with a `DLSSPresetValidator`
* `EFT.Console.Commands.DLSSCommands` exists (console commands; not enumerated)
* Settings screen: `_dlssNotAvailableBlockController` @0x138 (docs/SETTINGS-UI-MAP.md)
* No type name contains `nvngx`, `Upscal`, or `DlssImporter`; no DLSS Frame Generation or Ray
  Reconstruction wrapper exists in the game (`nvngx_dlssg`/`nvngx_dlssd` are not shipped by it)

## 2. What works on an RTX 2060 SUPER (Turing)

| Feature | Turing | Evidence |
|---|---|---|
| DLSS Super Resolution, CNN presets (A-F) | yes | shipped 310.5.3 already runs it |
| DLSS 4 transformer SR (preset J, K) | yes, at a higher cost than on Ada/Blackwell | NVIDIA: "RTX 2060 through RTX 2080 Ti … Super Resolution, DLAA, Ray Reconstruction support group" ([VideoCardz summary of NVIDIA's guidance](https://videocardz.com/newz/nvidia-wants-gamers-to-pick-the-right-dlss-4-5-model-preset-for-their-rtx-gpu)) |
| DLSS 4.5 second-gen transformer SR (preset L, M) | runs, **slower**: no FP8 on Turing | NVIDIA, [DLSS 4.5 SR announcement](https://www.nvidia.com/en-us/geforce/news/dlss-4-5-super-resolution-available-now/): "GeForce RTX 20 and 30 Series GPUs lack native FP8 support, so Models M and L carry a heavier performance impact … may therefore prefer to remain on Model K" |
| DLAA | yes (a DLSS SR mode) | same |
| DLSS Frame Generation / Multi-Frame Generation | **no** -- RTX 40 for FG, RTX 50 for MFG; and the game has no `nvngx_dlssg` wrapper anyway | NVIDIA guidance above; metadata |
| DLSS Ray Reconstruction | hardware-capable, but the game has no `nvngx_dlssd` integration | metadata |
| "DLSS 5" neural rendering (`nvngx_dlssnr`) | **not through this tool** -- see section 5 | |

**Recommended preset on this GPU: K** (NVIDIA's own words above). L/M are selectable
in the game's dropdown and will run; expect a measurable frame-time hit versus K.
The game's dropdown is the right place to choose: it is per-app and needs no
driver write. The machine-wide DRS override exists for one case only -- forcing a
preset the game's dropdown cannot name.

## 3. The artifacts (URLs, sizes, SHA256) -- all fetched and verified 2026-09-02

`python tools/dlss.py fetch --all` puts these in `.cache/dlss/` (gitignored; NVIDIA
binaries are never committed).

| Key | What | Source | Size | SHA256 |
|---|---|---|---|---|
| `310.7.0` (**default**) | `nvngx_dlss.dll` FileVersion 310.7.0.0, DLSS SDK 310.7.0 (2026-06-23: "Improved tracking of resources … Bug Fixes & Stability") | [github.com/NVIDIA/DLSS @ v310.7.0, lib/Windows_x86_64/rel](https://raw.githubusercontent.com/NVIDIA/DLSS/v310.7.0/lib/Windows_x86_64/rel/nvngx_dlss.dll) | 58,977,904 | `be6e434a94ca32499515eb62ca0e6c274526055d568d0426e4c652dcdfb6ee6e` -- and the recomputed git blob id `dc5f2058fe755d10765514b7a4a33b45e0702992` equals what GitHub's contents API reports for that path at that tag |
| `310.7.129` | `nvngx_dlss.dll` FileVersion 310.7.129.0, newest SR DLL in TechPowerUp's archive (2026-08-26) | [techpowerup.com/download/nvidia-dlss-dll/](https://www.techpowerup.com/download/nvidia-dlss-dll/), form id 3229 -> `us1-dl.techpowerup.com/files/…/nvngx_dlss_310.7.129.zip` | zip 45,049,603; DLL 74,208,880 | zip `0de171b0f522f87bee3dccb98b26976723eb16758366cf04402a83eebaca2ce8` (TPU's published value, matched); DLL `d202b024cf5a809d4f6cb57b698ca61cdf7e7f664915a3794942042066d7cf72` (measured from that zip) |
| `310.5.3` | the shipped version, re-fetchable for rollback | [github.com/NVIDIA/DLSS @ v310.5.3](https://raw.githubusercontent.com/NVIDIA/DLSS/v310.5.3/lib/Windows_x86_64/rel/nvngx_dlss.dll) | 54,779,504 | `8707e53b26c68c606b98bf31c223485ff30d310a261b1a36d48b2eaabc1507ec` == the live file; blob `6004172e07e13663e8be56b44ec51a47ee77450c` matches GitHub |
| `npi` | nvidiaProfileInspector v3.0.2.1 (2026-07-05), GUI to inspect the DRS override | [GitHub release asset](https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip) | 433,354 | `88dcf3514111e8de630688467c03c36d8c2a8ad9ebc8073f27c069f82b75bb40` (GitHub's asset digest, matched) |

TechPowerUp's page also lists (published SHA256 of the zips, not fetched):
310.7.128 (2026-08-24) `cde8e573ed3a832bc4e123195fe8d3f009156736ed97e93e7a7f9352a4c2263a`,
310.6.0 (2026-03-31) `10b7efaa64393bedac6d42f2b7bdf65ce1d92ce0c84d7d5d35762703a2eb9581`,
310.5.3 (2026-01-30) `3399dbb5b091a9d764d04de388eeff619bf26db1af9b65e54193c2993c513ae0`.

Why 310.7.0 is the default and not 310.7.129: 310.7.0 is NVIDIA's own release
with an independent second hash (the git blob id) and release notes; 310.7.129
is a game-extracted drop TechPowerUp hosts, 15 MB larger, whose changes NVIDIA
has not documented anywhere I could find. Both are pinned; pick with
`--version 310.7.129`.

Not fetched, by decision:

* **DLSSTweaks** -- its GitHub release carries only a pointer file; the DLL is on Nexus
  behind a login, so there is nothing to pin. Its documentation was still the source
  for the DRS setting ids ([emoose/DLSSTweaks#139](https://github.com/emoose/DLSSTweaks/issues/139)).
* **OptiScaler 0.9.4** (`Optiscaler_0.9.4-final.20260718._MM.7z`, 55,016,448 B, GitHub digest
  `575cb4df866116093df75af607e37fd70e10f5163e0f23fd5c804142e80ef0ad`,
  [release](https://github.com/optiscaler/OptiScaler/releases/tag/v0.9.4)) -- a DXGI-proxy
  upscaler shim. Verifiable, but it would sit in the same process as the aowlspt host,
  and nothing it offers (preset override, alternate DLL path) is needed: the game has
  the dropdown and the tool swaps the DLL directly.

## 4. Using the tool

```
python tools/dlss.py status                       # DLL, hash, version, manifest, GPU, driver, DRS override, cache
python tools/dlss.py fetch [--version V | --all]  # verify-or-download into .cache/dlss/, always + NPI
python tools/dlss.py install [--version V] [--preset K] [--dry-run]
python tools/dlss.py rollback [--backup TS]
python tools/dlss.py preset get | set K | clear
python tools/dlss.py selftest                     # exit 0/1; registered in tools/selftests.py
```

`install` refuses while `EscapeFromTarkov.exe` runs (the DLL is locked and a human may be
playing), refuses a source whose hash is not the pin, refuses a hardlinked target, and refuses
a manifest that does not hold exactly one entry for the DLL. It then: backs up DLL + manifest
to `.cache/dlss/backup/<ts>/`; copies the new DLL beside the old one and `os.replace`s it
(a directory-entry swap, never a write-through); rewrites the single manifest entry in the
file's own compact JSON; and verifies the **finished state**: sha256 of the live DLL ==
pin, PE version == source, manifest Size/Checksum == values recomputed from the file now on
disk, every other entry unchanged, `IsCritical` preserved. It prints the rollback line.

`--preset K` additionally writes DRS setting `0x10E41DF3`
(`NGX_DLSS_OVERRIDE_RENDER_PRESET_SELECTION`, honoured by DLSS >= 3.1.11 on the driver's
*base* profile) through NVAPI (`nvapi64.dll`, `NVDRS_SETTING` V1 = 12,320 bytes), reads
it back, and records the prior value so `rollback` restores it exactly (deleting the
setting if it was absent). This is machine-wide: every DLSS game sees it. It is not done
by default. nvidiaProfileInspector is fetched only to *look* -- its `.nip` import path
calls `ResetProfile` on the target profile before applying (`DrsImportService.cs:213`
at v3.0.2.1), which would wipe whatever else the base profile holds.

The dry run against the live install, 2026-09-02:

```
  live   : D:\Aowlspt\...\nvngx_dlss.dll  v310.5.3.0  sha 8707e53b26c68c60
  source : .cache/dlss/nvngx_dlss_310.7.0.dll  v310.7.0.0  sha be6e434a94ca3249
  manifest entry : {... "Size": 54779504, "Checksum": -785527982, "IsCritical": true}
               -> {... "Size": 58977904, "Checksum": -282693640, "IsCritical": true}
```
(310.7.129 would become `"Size": 74208880, "Checksum": 1628777542`.)

### The coordinator's procedure (between deploys, game stopped)

1. `python tools/dlss.py install` (add `--version 310.7.129` or `--preset K` as decided).
2. Start the client. Read `D:\Aowlspt\Logs\<ts>\*files-checker_000.log`: it must say
   `Consistency ensurance is succeed`. If it says otherwise, `python tools/dlss.py rollback`.
3. Enable DLSS in Graphics settings (mode Quality/Balanced/…, preset K), or drive it with
   the inspector. The client log's `"DLSSMode"`, `"DLSSPreset"`, `"DLSSEnabled"` lines are
   the read-back; `DLSSWrapper._currentNvGfxPreset@0xe8` is the live one.
4. Optional: `ShowDlssIndicator` (DWORD, `HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore`,
   value 1024) draws NVIDIA's on-screen DLSS version/preset overlay -- the only rendering-side
   proof that the new DLL and preset are the ones in use. NVIDIA ships the `.reg` in
   [NVIDIA/DLSS/utils](https://github.com/NVIDIA/DLSS/tree/main/utils).

## 5. "DLSS 5" -- what it actually is, and why it is refused here

Sources: [TechPowerUp, 2026-08-30](https://www.techpowerup.com/352181/leaked-dlss-5-is-being-tested-on-rtx-20-series-turing-gpus-now-runs-on-emulators-and-old-directx-titles),
[Wccftech](https://wccftech.com/dlss-5-now-works-on-rtx-20-30-gpus-older-graphics-apis-and-even-pcsx2/),
[Held Games explainer](https://heldgames.com/guides/dlss-5-mod-explained),
[Nexus "Applying RR and DLSS 5 RenoDX for the games" (site mod 2224)](https://www.nexusmods.com/site/mods/2224),
[Dagherbou/OptiScaler_DLSSNR releases](https://github.com/Dagherbou/OptiScaler_DLSSNR/releases),
[Kizzuwatnaa/DLSS5-Autopilot README](https://github.com/Kizzuwatnaa/DLSS5-Autopilot),
[RankFTW/RHI releases](https://github.com/RankFTW/RHI/releases).

* **The file** is `nvngx_dlssnr.dll` version 310.8.0.0, ~158 MB, "148 million FP8 parameters".
  It leaked from an early-access build of NBA 2K27 around 2026-08-26. NVIDIA's launch is
  2026-09-03, NBA 2K27, RTX 50 only (Autopilot README; TechPowerUp).
* **What it does**: it is not upscaling. It runs over a finished frame with colour + motion
  vectors and re-lights/re-textures it (skin, fabric, shadow fall-off). It is a *third* NGX
  feature beside SR (`nvngx_dlss`) and RR (`nvngx_dlssd`), and no game or engine has an
  integration for it -- every "DLSS 5 in game X" is an injector: Krish's `renodx-dlss5`
  ReShade add-on (D3D12), ShortFuse's `renodx-dlss` add-on ("reported not working in many
  games"), NIGos' `dlss5-bridge`, jlrouzies-fr's `DLSS5-Feeder`, or Dagherbou's OptiScaler
  fork (D3D12; D3D11 "with FSR underneath"; Vulkan in v0.1.2).
* **Nexus mod 2224** (the page the user gave; WebFetch 403s, curl'd 2026-09-02) is a
  guide + repack of exactly that: OptiScaler-DLSSNR files, `nvngx.dll_dlssnr.dll`, a
  `setup_windows.bat` choosing a proxy (`1 = DXGI`, `5 = D3D12 if you use ReShade`),
  separate "Rtx 20-30" / "Rtx 40-50" file sets, and the RenoDX add-ons. Its own
  requirements text: "RTX 50-series hardware and a sufficiently recent NVIDIA driver may be
  required for certain neural features."
* **Turing**: ShortFuse rebuilt the model with "a nearly full FP16 pipeline for RTX 20/30" and
  a "speed boost" build for RTX 20; results are "a mixed bag … some games run, others crash
  or fail to initialize" (TechPowerUp). The OptiScaler fork author: "An RTX 50 series card.
  The model does not run on anything older. I am aware of DLLs compiled for older GPUs but I
  have not tested them personally. A driver new enough to ship nvngx_dlssnr.dll. Minimum of
  616.56."
* **Why the tool refuses it, in order of weight:**
  1. There is no official or first-party source. Every copy is a rehost of a leaked NVIDIA
     binary, and the Turing builds are third-party re-compilations of it. Nothing to pin
     against, and the brief forbids recommending a random rehost.
  2. Driver: the only stated minimum is 616.56; this machine runs 581.42.
  3. API: `DLSSImporter.dll` talks `NVSDK_NGX_D3D11_*`. Every proven DLSS-NR route is D3D12;
     the D3D11 path replaces the game's DLSS with FSR and runs the model on top -- that is
     no longer "DLSS" and it puts a DXGI proxy in the same process as the aowlspt host.
  4. Cost: it is a full-frame 148M-parameter model on top of the existing frame; on a 2060
     SUPER without FP8 the FP16 fallback has "a hard cap on the DLSS 5 performance"
     (TechPowerUp comments) -- not a setting anyone would leave on in a shooter.

If NVIDIA ships DLSS-NR officially with Turing support and a D3D11 path, the catalog in
`tools/dlss.py` is where a pinned `nvngx_dlssnr.dll` goes; the manifest/backup/verify
machinery is feature-agnostic.

**Superseded 2026-09-03 by an explicit user decision**: the leaked route IS installed
here, eyes open, through `tools/dlssnr.py` -- see `docs/DLSSNR.md` for the measured state
of the fork, the Turing rebuild, the hashes, and what remains unproven. The four reasons
above are still true; they are now printed as gates and caveats, not a refusal.

## 6. Override mechanisms, for the record

| Mechanism | What it is | Used here? |
|---|---|---|
| Game's Graphics > DLSS Preset dropdown | per-app NGX hint via `SetCurrentNvGfxPresetExt` | **yes, preferred** |
| DRS `0x10E41DF3` on the base profile | driver-side forced preset, read by DLSS >= 3.1.11 (per-game profiles: 3.6+ but buggy -- emoose/DLSSTweaks#129/#139) | `--preset` / `preset set`, via NVAPI with read-back |
| NVIDIA App "DLSS Override -- Model Preset / Super Resolution" | writes the same family of DRS keys (plus newer SR-DLL-override ids this tool does not know) and swaps the DLL from the driver's store; "Recommended" = M for Performance, L for Ultra Performance, K otherwise | not automated; it is installed, a human can use it |
| `C:\ProgramData\NVIDIA\NGX\models\nvngx_config.txt` | driver-side OTA path that can point `nvngx.dll` at another `nvngx_dlssX.dll` | no -- a DLL swap plus manifest re-sync is simpler and verifiable |
| `HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore` `ShowDlssIndicator`=1024 | on-screen overlay naming DLL version + preset | recommended for verification |
| DLSSTweaks (`dlsstweaks.ini`) / OptiScaler (`OptiScaler.ini` `RenderPresetOverride`) | in-process shims | no (see section 3) |

Other known DRS ids (emoose): `0x10E41DF4` FORCE_DLAA, `0x10E41DF5` scaling ratio (float
0.333-1.0), `0x10E41DF7` RR preset, `0x10AFB76C` OVERRIDE_PERF_TO_9X.

## 7. What was NOT verified

* **That the game boots and renders with 310.7.0 / 310.7.129 in place.** `install` was
  run only as `--dry-run` and against the self-test's synthetic tree; the game was running
  with a human at it. The coordinator runs the real install between deploys and reads
  `files-checker_000.log`.
* **That the client's files checker verifies only Size** (CLAUDE.md 7 says size). The tool
  re-syncs Size *and* Checksum, so it does not depend on which.
* **What changed in 310.7.128/129.** TechPowerUp's "What's New" text was not in the page
  as served; NVIDIA has no notes for those builds.
* **The DRS write path** (`DRS_SetSetting` + `SaveSettings`). Only the read path ran (result:
  unset). Writing may need an elevated process; if it fails, the tool prints the driver's
  own status name and writes nothing else.
* **The newer NVIDIA App override ids** for forcing the SR DLL itself. Not researched
  beyond the preset id; not needed, since the DLL is swapped on disk.
* **Whether `DLSSCommands` console commands can flip the preset at runtime.** Not enumerated.
* The two WebFetch-refused pages (NVIDIA custhelp 5620, VideoCardz) were read only through
  search-engine summaries; NVIDIA's own DLSS 4.5 news page was read in full.

## 8. MEASURED 2026-09-03: where the game's DLSS setting lives, and the whole install proven

* The client's REAL consistency manifest is an AES blob appended to `EscapeFromTarkov.exe`
  (see `tools/consistency.py`); the plain `ConsistencyInfo` is the launcher's copy. `dlss.py
  install` now re-injects it; `files-checker_000.log` read `Consistency ensurance is succeed`
  on the patched exe (09:19:47).
* The game persists its graphics settings to
  `%APPDATA%\Battlestate Games\Escape from Tarkov\Settings\Graphics.ini` (JSON despite the
  name) on SAVE. After selecting Quality through the game's own dropdown
  (`BaseDropDownBox` item Button click via the inspector) and preset K, and pressing SAVE:
  `"DLSSMode": "Quality"`, `"DLSSPreset": "K"`, `"DLSSEnabled": true` (11:48:06).
* No route is hit on the backend for this save, and no NGX line appears in `Player.log`
  either way; the rendering-side proof is the NVIDIA on-screen indicator
  (`ShowDlssIndicator`), which only a human can read.

* **PROVEN 2026-09-03 ~12:30.** `Get-Process EscapeFromTarkov` lists module `nvngx_dlss.dll`
  FileVersion 310,7,0,0 loaded from `D:\Aowlspt\EscapeFromTarkov_Data\Plugins\x86_64\`
  while the client sits at the menu (NGX only loads it when DLSS initialises);
  `HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore\ShowDlssIndicator` = 1024; the user
  reports the NVIDIA DLSS badge on screen in raid. DLSS 310.7.0 / preset K is live.
