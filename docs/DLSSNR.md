# DLSS-NR ("DLSS 5", `nvngx_dlssnr.dll`) on this install -- the Turing / D3D11 route

Researched and measured 2026-09-03 for the machine that runs `D:\Aowlspt`
(RTX 2060 SUPER, Turing). The user asked for the leaked model knowingly, on a
GPU it was not built for, in a game that talks D3D11 to NGX. This document
records what is **measured** (read off this machine or off the named URL on
that date, with the command), what is **stated by** somebody else (with the
source), and what is **inferred**. The tool is `tools/dlssnr.py`; its self-test
is registered in `tools/selftests.py`. `docs/DLSS.md` section 5 is the earlier
refusal and is still correct about the facts; this supersedes its decision.

## TL;DR

* **What runs**: Dagherbou's OptiScaler_DLSSNR fork (`v0.1.2`, 2026-09-02)
  installed as `dxgi.dll` beside `EscapeFromTarkov.exe`, its forwarder
  `nvngx.dll_dlssnr.dll`, its runtime folder `OptiScaler\`, and the model
  `nvngx_dlssnr.dll` -- **ShortFuse's `310.8.SF-v2` rebuild** from
  RankFTW/rhi-repo, the file RHI and DLSS5oneclick install on RTX 20/30.
* **On D3D11 the model refuses to run** (`FeatureNotSupported`, fork author).
  The fork lifts the frame onto D3D12 through a *bridged* upscaler, so the
  in-game upscaler becomes **FSR 2.2 w/Dx12**, not DLSS: "you cannot use DLSS
  as your upscaler in these games ... You are trading DLSS for FSR or XeSS to
  get the pass" (fork v0.1.2 notes). The DLSS 310.7.0 / preset K proven in
  `docs/DLSS.md` is therefore **bypassed** while this is on.
* **Driver**: the fork states a 616.56 minimum. The machine was on 581.42 when
  this research started and **reads 616.56 now** (`nvidia-smi`, 12:46 local;
  new driver-store folder `nv_dispi.inf_amd64_a3944b54ff18b284`). That driver
  store does **not** ship `nvngx_dlssnr.dll` (only `nvngx.dll`, `_nvngx.dll`,
  `nvngx_dlssg.dll`, `nvngx_update.exe`), so the model must come from the
  download regardless; whether 616.56 is needed to *run* it is not measured.
* **Performance expectation on a 2060 SUPER: bad.** Nobody has published a
  number for Turing. The closest measurements are Ampere on the *unmodified*
  FP8 model (RTX 3080: 138 -> 4 FPS; RTX 3070 laptop: 29 ms -> 3,300 ms) and
  the claim that the FP16 rebuild gives "respectable performance in many
  titles" on RTX 30. The tool defaults `WorkingScale=0.5` (the model works on
  a quarter of the pixels) and turns on the FPS overlay so the verdict is a
  number, not an impression.
* `python tools/dlssnr.py status | fetch | install --dry-run` were run for
  real (outputs in section 6). **`install` was NOT run**; the game was running
  the whole time.

## 1. Sources, in order of weight

| # | Source | What it is | Read how |
|---|---|---|---|
| S1 | [Dagherbou/OptiScaler_DLSSNR releases](https://github.com/Dagherbou/OptiScaler_DLSSNR/releases) | the fork; release notes v0.1.0 (08-30), v0.1.1 (09-01), v0.1.1.5 (09-01), v0.1.2 (09-02) | GitHub releases API, curl |
| S2 | [RankFTW/rhi-repo releases](https://github.com/RankFTW/rhi-repo/releases) | binary drops RHI installs from: `dlssnr-310.8.0`, `dlssnr-310.8.0-RTX40`, `dlssnr-310.8.SF`, `dlssnr-310.8.SF-v2`, plus `renodx-dlss5-*`, `dlss-*`, `streamline-*` | GitHub releases API (asset `digest` = sha256) |
| S3 | [faisalkindi/DLSS5oneclick](https://github.com/faisalkindi/DLSS5oneclick) README + `src/installer.rs`, `src/ngx.rs` | names S2 as its source for `nvngx_dlssnr.dll`, picks the newest `dlssnr-*.SF*` tag; enforces driver >= 616.56 "the minimum OptiScaler's fork documents" | raw.githubusercontent |
| S4 | [RankFTW/RHI releases](https://github.com/RankFTW/RHI/releases) 2.5.1-2.5.5 | "DLSS5 Tool + DX11 Bridge", "DLSS Tool (ShortFuse)" methods; the `310.8.SF` DLL "extending Neural Rendering support across the RTX 20, 30, 40, and 50 Series" (Wccftech quoting RHI 2.4.9) | GitHub releases API |
| S5 | [Nexus site mod 2224](https://www.nexusmods.com/site/mods/2224) (the page the user gave) | a guide + repack: file 9321 "OptiScaler DLSSNR-dlss5" 330.2 MB (09-01, "Frame Gen support for RTX 20 through 40", "Rtx 20-30" / "Rtx 40-50" file sets), file 9219 "Dlss5" 136.5 MB ("the official DLSS 5"), `Renodx Dlss5 for 30-40-50` 219 KB, `Streamline` 143.2 MB | curl with a browser UA (WebFetch 403s); downloads need a login, **no hashes obtainable** |
| S6 | [OptiScaler wiki: Escape from Tarkov (SPT)](https://github.com/optiscaler/OptiScaler/wiki/Escape-from-Tarkov-(SPT)) | last tested 0.7.7-pre13, filename `dxgi.dll` **or `winmm.dll`** ("some reported winmm.dll instead had to be used to boot"), GPU 9070XT, inputs DLSS, "Only works for the Singleplayer Tarkov mod (SPT)!" | curl |
| S7 | [OptiScaler wiki: Manual Installation](https://github.com/optiscaler/OptiScaler/wiki/Manual-Installation), [Compatibility with other mods](https://github.com/optiscaler/OptiScaler/wiki/Compatibility-with-other-mods-(Reshade,-SpecialK)) | supported proxy names `dxgi.dll winmm.dll d3d12.dll dbghelp.dll version.dll wininet.dll winhttp.dll OptiScaler.asi`; Insert = overlay, Page Up = FPS overlay, End = FG toggle; `plugins\` folder for a colliding `dxgi.dll` | curl (raw wiki) |
| S8 | [TechPowerUp 352033](https://www.techpowerup.com/352033/) (analysis of the leak), [352086](https://www.techpowerup.com/352086/) (Ada), [352147](https://www.techpowerup.com/352147/) (Ampere), [352181](https://www.techpowerup.com/352181/) (Turing) | 158 MB, 148M FP8 parameters, 15 cubins all `sm_120`; "30% performance hit on rtx 4070ti" (comment); RTX 3080 138 -> 4 FPS; ShortFuse "speed boost" build for RTX 20, "mixed bag ... some games run, others crash or fail to initialize"; @DystopianSuns: FP16 implementation on RTX 20/30 | curl with UA |
| S9 | [Wccftech](https://wccftech.com/dlss-5-now-works-on-rtx-20-30-gpus-older-graphics-apis-and-even-pcsx2/) | "RHI 2.4.9 now ships with ShortFuse's modified 'nvngx_dlssnr.dll 310.8.SF'"; "respectable performance in many titles ... using RTX 30-series cards" (RenoDX Discord, unquantified) | curl |
| S10 | [NIGos/dlss5-bridge](https://github.com/NIGos/dlss5-bridge) | the ReShade-side D3D11 -> private-D3D12 mirror (the *other* D3D11 route; not used here) -- confirms the model needs D3D12 and that Unity D3D11 games have been bridged (7 Days to Die, Tainted Grail) | GitHub API + README |
| S11 | NVIDIA driver service (`gfwsl.geforce.com ... DriverManualLookup psid=127 pfid=934 osID=57`) | newest driver offered for **RTX 2060 SUPER, Win10/11 x64 DCH**: **616.56, 2026-08-26**, `https://us.download.nvidia.com/Windows/616.56/616.56-desktop-win10-win11-64bit-international-dch-whql.exe` (984.3 MB); before it 610.88 (07-28), 610.74 (07-07) | curl |
| S12 | two YouTube uploads 2026-08-30: "SPT Escape from Tarkov DLSS 5 Neural Rendering Interchange map" (`6MLoj9nLW4c`), "NVIDIA DLSS 5 on Escape from Tarkov" (VeryBadSCAV, `P7ALK3Rqh6Y`) | proof somebody ran it in SPT Tarkov; **neither description names the GPU, the route or the driver** | page metadata |

Nothing Tarkov-specific beyond S6 and S12 was found: no issue on the fork
mentions Tarkov, Turing, a 2060/2070/2080 or DX11 (GitHub issue search, 0
hits), and the fork's README is a 404 (everything lives in release notes).

## 2. The artifacts -- measured 2026-09-03, all in `.cache/dlssnr/` (gitignored, never committed)

| Key | File | Source | Size | SHA256 |
|---|---|---|---|---|
| `optiscaler` | `OptiScaler-DLSSNR-v0.1.2.zip` | S1 tag `v0.1.2-dIssnr` (sic -- capital I in the tag; the asset name is normal) | 130,438,762 | `4ecf3c3d4a1c23637144855fc327f4b33079370219188ca0e198c7cb6ed58f36` == GitHub's asset digest |
| `sf2` (**default**) | `nvngx_dlssnr_310.8.SF-v2.zip` -> `nvngx_dlssnr.dll` | S2 tag `dlssnr-310.8.SF-v2` (2026-08-30 21:18Z) | zip 116,693,212; DLL 165,830,144 | zip `1da35941894994eb087e017577829e492454e9bae3a6a9397027069ceb74955c` == digest; DLL `6eb209e764f39872625debd6abaf45e2bb6322f6f270f781f70c059ae30b3927` |
| `orig` | `nvngx_dlssnr_310.8.0.zip` -> `nvngx_dlssnr.dll` | S2 tag `dlssnr-310.8.0` (2026-08-27) | zip 109,425,288; DLL 165,840,496 | zip `388c0a7912e15ec911b9c9e11a692142b11fe387ddf2b637d8c358138fffb3ac` == digest; DLL `e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e` |

Recorded but not fetched (no Turing claim, or superseded):
`dlssnr-310.8.SF` zip `4de991bf3a1cf5ba95c6621c2a5203299e823ea11bf1702513281b85aa4dc449` (114,611,736);
`dlssnr-310.8.0-RTX40` zip `46124cfaef532ad5f6da07494772ea8c1b3e719f934e254385697f38d1289e3f` (110,604,522);
fork v0.1.1.5 `735b10b4…`, v0.1.1 `4dbed94f…`, v0.1.0 `21e73d05…`; `renodx-dlss5_4.70.zip`
`d6e356d01b429af6288f488a4926c44f1d779a7d4586ee8c79d04d3a09a536e6` (the ReShade-route add-on);
`dlss5-bridge.addon64` 1.4.7 `f0828689adab004c23e433bf4c6cf5f890641136582abb2856de8d83443ea9e5`.
The Nexus repack's own hashes are **unobtainable** without a login (S5); the guide
names the same fork and the same "Rtx 20-30" DLL, so the GitHub sources above are
what it repacks, inferred from the file list it prints, not proven byte-for-byte.

What the two model DLLs are, measured from the bytes (`python` over the zip members):

| | `orig` 310.8.0.0 | `sf2` "310.8.SF" |
|---|---|---|
| PE FileVersion / ProductVersion | `310.8.0.0` / `310,8,0,0` | **`310.8.2.0`** / **`310.8.SF.0`** |
| FileDescription / OriginalFilename | `NVIDIA DLSSNR - DVS PRODUCTION` / `CL 38718415` | same (the resource was left alone) |
| `sm_NNN` cubin arch strings | **`sm_120` x 15**, nothing else | **none visible** -- the cubins were repacked; the "FP16" claim cannot be checked from strings (`_fp8` substrings 1,818 -> 137, `_fp16` 0 in both) |
| Authenticode | intact (directory at 165,830,144, 10,352 B) | **stripped**: the same directory now points exactly at EOF -- the signature was cut off, the code was changed, nothing NVIDIA-signed remains |
| DLL names visible in the file | `dxgi.dll`, itself | same -- CUDA/NGX are reached at runtime, not by import name |

So `sf2` is: the leaked NVIDIA binary, patched by a third party, unsigned, with
its stated Turing support resting on RHI's and DLSS5oneclick's word plus one
tweet. That is the honest provenance and it is why `fetch` pins both the zip and
the inner DLL and prints the signature state every time.

What the fork zip holds (17 members copied, 4 skipped): `OptiScaler.dll`
(25,782,784; version resource `OriginalFilename=OptiScaler.dll`, `ProductName=OptiScaler`,
`CompanyName=nitec`, FileVersion 10.0.0.1), `nvngx.dll_dlssnr.dll` (110,080; exports
`NVSDK_NGX_D3D12_{Init_Ext,CreateFeature,EvaluateFeature,ReleaseFeature}` and the
`VULKAN` four -- "the model refuses calls from any module whose path does not contain
nvngx.dll, so the forwarder is named to satisfy that check"), `OptiScaler.ini` (55,614;
sections listed in section 4), `OptiScaler\` (FSR 2/3 + FG DX12/VK, XeSS + `libxess_dx11.dll`,
`D3D12_OptiScaler\D3D12Core.dll`), `Licenses\`. Skipped: `setup_windows.bat`,
`setup_linux.sh`, the empty `!! EXTRACT ALL FILES TO GAME FOLDER !!`, the READ ME.

## 3. Why these choices

* **Proxy name `dxgi.dll`.** The fork's own installer default ("most compatible"), the
  OptiScaler wiki's Tarkov-SPT page's first reported name (S6), and what DLSS5oneclick
  writes for the opti engine. `D:\Aowlspt` holds **none** of the seven proxy names today
  (measured: `ls`), the aowlspt host is `LoadLibrary`'d by `aowlspt-launch.exe` into the
  suspended process (docs/ARCHITECTURE.md), not proxy-loaded, so nothing collides. If the
  game does not boot with `dxgi.dll`, S6 says `winmm.dll` -- `install --proxy winmm`.
* **`Dx11Upscaler=fsr22_12`.** The model answers `FeatureNotSupported` on D3D11 (S1, all
  four releases). The fork's fix is its Dx11-on-Dx12 bridge, and it only runs under an
  upscaler marked "w/Dx12" in the overlay -- ini values `fsr22_12`, `fsr21_12`, `xess_12`,
  `ffx_12` (measured from `[Upscalers]`). The ini default `auto` is **`fsr22`, native
  DX11**, under which the pass never runs and nothing says so; the tool refuses a native
  value outright. `ffx_12` (FSR 3.1) is selectable with `--upscaler`.
* **`[DlssNr] Enabled=true`.** Off by default in the fork. **`WorkingScale=0.5`**: "cost
  falls with the square of this" (ini comment); a Turing card with no FP8 starts at a
  quarter of the cost, the overlay slider goes up from there. **`AutoCapture=false`**:
  the fork otherwise writes eight before/after frames to `dlssnr-capture\` beside the
  exe each session.
* **`[Log] LogToFile=true, LogLevel=2`.** "The log states why the pass did not start"
  (S1). A feature that declines silently is the worst outcome we produce.
* **`[Menu] ShowFps=true`.** The frame-time verdict without a screenshot.
* **Hotkeys (fork/OptiScaler defaults, unchanged):** `Insert` overlay, `Page Up` FPS
  overlay, `Page Down` cycle its mode, `End` frame-gen toggle; the **Neural Rendering
  toggle is unbound** ("under Keybinds, 'Neural Rendering'. It is unbound by default").
  None of these is a default Tarkov bind as far as the settings map shows, which is
  inferred, not measured.
* **The driver gate is `616.56`, overridable.** Stated by the fork author in every
  release ("A driver new enough to ship nvngx_dlssnr.dll. Minimum of 616.56"), copied
  by DLSS5oneclick (`ngx.rs`: "the minimum OptiScaler's fork documents for DLSS-NR").
  Nobody documents a machine running the model on an older driver, and nobody documents
  one failing for that reason either. Two measured facts bound it: the 616.56 driver
  store on this machine ships **no** `nvngx_dlssnr.dll`, so the phrase is not literally
  about sourcing the file; and the model DLL names no driver DLL in its import table.
  Treated as real until this machine measures otherwise; `--force-driver` exists for
  that measurement.
* **The model gate**: `orig` is refused on anything but Blackwell because the file
  itself says `sm_120` only (measured). `sf2` is allowed on Turing because RHI/DLSS5oneclick
  say so (stated). `--force-model` overrides.
* **The manifest negative.** Files *added* beside the exe are not in
  `ConsistencyInfo` (only listed files are checked, CLAUDE.md 7). The tool does not
  assume that: it reads both the plain manifest (10,599 entries) and the embedded one
  in the patched exe (**10,601** -- two more than the launcher's copy; not investigated)
  and refuses if any planned path is listed. The self-test plants `dxgi.dll` in a fake
  manifest and proves the refusal fires, then removes it and proves PASS returns.

## 4. What is NOT proven (read before pressing anything)

1. **That it runs at all on this GPU.** No Turing measurement exists anywhere I could
   cite; TechPowerUp's Turing article is "some games run, others crash or fail to
   initialize". The fork author has "not tested [older-GPU DLLs] personally".
2. **That the game boots with `dxgi.dll` beside it** on *this* build with the aowlspt host
   injected. S6's report is for OptiScaler 0.7.7-pre13 on an AMD card in stock SPT.
   Two DXGI-hooking modules in one process (OptiScaler + anything the host hooks) is
   unmeasured.
3. **The Dx11-on-Dx12 bridge on Unity 2022's D3D11 path with the game's own
   `DLSSImporter.dll`** (which calls `NVSDK_NGX_D3D11_*`). OptiScaler hooks those exports;
   whether the game's DLSS dropdown must be ON for the hook to see a feature (it must be,
   inferred from "A game that already uses DLSS") means the in-game setting stays
   Quality/K while the actual upscaler becomes FSR 2.2 -- the settings UI will lie.
4. **Performance.** Unquantified for Turing everywhere. Expect the FPS overlay to be
   the first real number.
5. **The 616.56 minimum**, as above.
6. **The 10,601 vs 10,599 manifest entry count.**
7. **Interaction with the NVIDIA DLSS indicator** (`ShowDlssIndicator=1024`, docs/DLSS.md
   8): with FSR delivering the frame, the badge should disappear -- that would be the
   cheapest proof the bridge is active. Inferred.

## 5. Exact user steps

1. **Driver first** (done as of 12:46 local: `nvidia-smi` reads 616.56). If it ever reads
   below that again: S11's URL, Custom install keeping every component -- DLSS5oneclick
   found NGX Core missing on NVCleanstall-style minimal installs.
2. Stop the game (the coordinator does this; `install` refuses while
   `EscapeFromTarkov.exe` has a pid).
3. `python tools/dlssnr.py install` -- prints the plan, the backup path and the rollback
   line; verifies the finished tree; exits non-zero on any mismatch.
4. Start the game, go to Graphics, leave DLSS at Quality / K (the hook needs a DLSS feature
   to intercept), enter a raid.
5. `Insert` -> OptiScaler overlay. Top-left dropdown must read an upscaler with **w/Dx12**
   (the ini pre-selects FSR 2.2 w/Dx12); the **DLSS Neural Rendering** panel must show
   "Enable Neural Rendering" ticked with no red text under it. If there is text, it is
   the answer -- read it, then `D:\Aowlspt\OptiScaler.log`.
6. `Page Up` for the FPS overlay. Compare with the pass off (untick, or bind a key under
   Keybinds -> Neural Rendering). Raise `WorkingScale` only if the number allows it.
7. `python tools/dlssnr.py rollback` puts the tree back byte-for-byte (measured by the
   self-test: a pre-existing `dxgi.dll` is restored identical, every added file is gone,
   the exe and the manifest were never touched).

## 6. The runs (2026-09-03, real, game running the whole time)

`python tools/dlssnr.py status` (12:49 local):

```
== GPU ==
  gpu       : NVIDIA GeForce RTX 2060 SUPER (Turing (RTX 20))
  driver    : 616.56  [nvidia-smi]
  driver 616.56 vs stated minimum 616.56 -> OK
  model sf2  : 310.8.2.0 -> listed for this GPU  [stated by RHI 2.4.9 notes / DLSS5oneclick README; RTX 20 measured by nobody I can cite]
  model orig : 310.8.0.0 -> NOT listed for Turing (RTX 20)  [MEASURED: only sm_120 cubins in the file]
== live root (D:\Aowlspt) ==
  proxy DLLs: none of dxgi.dll, winmm.dll, version.dll, dbghelp.dll, d3d12.dll, wininet.dll, winhttp.dll present
  nvngx_dlssnr.dll ABSENT / nvngx.dll_dlssnr.dll ABSENT / OptiScaler\ ABSENT / OptiScaler.ini ABSENT
  manifest  : plain ConsistencyInfo: 10599 entries; embedded manifest: 10601 entries
  manifest lists any file this tool would add: NONE (added files are unchecked by the client)
== cache == optiscaler PASS / sf2 PASS / orig PASS
  game running: True
```

(An earlier `status` in the same session, before the driver update landed, read
`driver 581.42 -> TOO OLD`; the gate fired as designed.)

`python tools/dlssnr.py fetch --all`: all three zips verified against their pins and
GitHub's digests; `sf2` extracted with `PE FileVersion 310.8.2.0 ProductVersion
'310.8.SF.0'; cubin arch strings NONE VISIBLE; Authenticode STRIPPED (directory
165830144,10352 past EOF)`; `orig` with `{'sm_120': 15}; Authenticode intact`.

`python tools/dlssnr.py install --dry-run` (12:51):

```
install: driver 616.56 vs stated minimum 616.56 -> OK
== plan ==
  proxy     : dxgi.dll  (OptiScaler.dll from OptiScaler-DLSSNR-v0.1.2.zip)
  model     : sf2 -> nvngx_dlssnr.dll  (ShortFuse's 'nvngx_dlssnr.dll 310.8.SF' v2 ..., v310.8.2.0)
  ini       : [DlssNr] Enabled=true; WorkingScale=0.5; AutoCapture=false; [Upscalers] Dx11Upscaler=fsr22_12;
              [Log] LogToFile=true; LogLevel=2; [Menu] ShowFps=true
  adds      : 17 files (OptiScaler.ini, dxgi.dll, nvngx.dll_dlssnr.dll, nvngx_dlssnr.dll + OptiScaler\ + Licenses\)
  overwrites: none
  manifest  : plain ConsistencyInfo: 10599 entries; embedded manifest: 10601 entries; hits among planned files: NONE
  backup    : C:/Users/savant/Projects/aowlspt/.cache/dlssnr/backup/20260903-125142
DRY RUN: nothing written. Rollback line would be: python tools/dlssnr.py rollback --backup 20260903-125142
```

`python tools/dlssnr.py selftest`: `SELFTEST PASS` -- 45 checks; the falsifiers that must
refuse or FAIL: a model whose sha256 != pin, a native-DX11 upscaler, a zip whose
`OptiScaler.dll` is another DLL, a same-size tamper of the installed model, the ini
edited back to `auto`, a manifest that lists a planned file (re-armed and shown to PASS
again afterwards), a fake running pid (tree proven unchanged after the refusal), an
UNKNOWN running state, driver 581.42 without `--force-driver`, a Blackwell-only model on
Turing without `--force-model`, and a backup without its manifest. Two of these checks
failed on the first run (CRLF lost by a text-mode read; `os.walk` pruning only leaf
directories) -- both were defects in the test fixture and the rollback pruner, fixed
before the PASS above.


## Turning the model OFF while leaving the install in place (measured 2026-09-03)

In `D:\Aowlspt\OptiScaler.ini`: `[Upscalers] Dx11Upscaler=dlss` (OptiScaler passes the game's DLSS request through to the real nvngx_dlss.dll -- `dlss` is a documented value for Dx11 games) and `[DlssNr] Enabled=false`. Turning it back on: `Dx11Upscaler=ffx_12` (FSR 3.1 bridged; FSR 2.2 smears wind-moving foliage) and `Enabled=true`; the user's preferred look was `WorkingScale=0.25`, `Intensity=2.0` (a stylised post-process; ~10 fps at 4K on the RTX 2060 SUPER at 0.5 scale).
