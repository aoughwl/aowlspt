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

## Kernel census, measured 2026-09-04

Read-only, from the bytes of the two cached DLLs, with
`python tools/dlssnr_census.py .cache/dlssnr/nvngx_dlssnr_sf2.dll --compare .cache/dlssnr/nvngx_dlssnr_orig.dll --kernel cc_split_swin_16h_qkv_512_chained`
(pure Python: `struct`, stdlib `compression.zstd` on 3.14, an inlined LZ4
decoder that was never needed). Nothing was run on the GPU. This section
supersedes the "`sm_NNN` strings: none visible" row of section 2 -- that row
was true of the *strings* and wrong about the *contents*, because every cubin
in `sf2` is zstd-compressed and a string scan cannot see inside one.

**The plain answer.** The installed SF build carries, for Turing, the SAME
231 kernels the leaked Blackwell build carries -- 111 named `*_fp8` and 120
not -- cross-compiled to `sm_75` from NVIDIA's own PTX. The `_fp8` kernels
on `sm_75` are **not** an FP16 rewrite: they are the FP8 kernels with the
FP8 tensor path emulated (4.5x the instructions of their non-fp8 twins, 2.3x
the tensor-op count, plus ~9,000 integer/bit-shuffle instructions per
kernel). Their non-fp8 twins are ordinary FP16 tensor kernels of normal
size and exist on every arch. **Which of the two the host launches is
decided by host code that SF did NOT change** (the host `.text` differs from
NVIDIA's in exactly 29 bytes, both patches decoded below; the weights
resource is byte-identical), so the choice on a 2060 SUPER is whatever the
stock code chooses -- and the stock code's selection basis could not be
read from the bytes (no arch compare feeds it; the `_fp8` suffix is matched
at 25 code sites against names, not against the GPU). **From the bytes
alone it is undeterminable which variant runs; the only evidence that the
`_fp8` variants are the ones launched is the r/nvidia live kernel trace on
an RTX 2070, whose per-kernel numbers match this file exactly (below), and
nothing in SF's changes could redirect that choice.** So: FP8-expanded on
Turing per the one live trace; FP16-native-only is ruled out as a
description of what SF built; "runs FP16 Turing kernels" is true only of
the 120 non-fp8 twins IF the stock selector picks them, which nobody has
shown.

### 1. Containers

15 CUDA fatbins (magic `0xBA55ED50`, version 1, 16-byte header) at
**identical file offsets** in both files (`0xdf0e0`, `0x4a2220`, `0x6fe100`,
`0x94cb60`, `0xbd0990`, `0xdd4bc0`, `0x10e2a40`, `0x1121b90`, `0x1123af0`,
`0x1126590`, `0x11293b0`, `0x112bd00`, `0x112e3f0`, `0x112fd90`, `0x113d3c0`,
all in `.data`). SF repacked each one **in place**: every `sf2` payload is
smaller than the original's and the slack up to the old end is zero-filled
(verified for all 15). No bare cubins outside a fatbin (the ELF-magic scan
finds exactly the 15 raw `sm_120` ELFs in `orig` and **zero** in `sf2`, which
is why the earlier string scan saw nothing). No TensorRT: `nvinfer` 0,
`TensorRT` 0; the 4 `TRT` hits are `WStrToUTF8Str`.

Compression is **zstd** (payload magic `28 B5 2F FD`), decoded with the
stdlib. Not zlib, not LZ4. The fatbin entry flag on compressed entries is
`0x8041` (uncompressed `sm_120` ELF in `orig`: `0x1000041`; recompressed in
`sf2`: `0x1008041`) -- the documented LZ4 bit `0x2000` is NOT set, so the
tool decides by payload magic, never by flag. Every decoded size equals the
entry header's `decompressed_size` field (68/68). Entry header size is 120
bytes on NVIDIA's entries (object name kept), 64 on SF's added ELFs, 80 on
SF's re-inserted PTX.

| | `orig` 310.8.0.0 | `sf2` 310.8.SF |
|---|---|---|
| fatbin entries | 30 (15 PTX + 15 ELF) | **68** (8 PTX + 60 ELF) |
| ELF `sm_120` | 15, raw, 12,014,440 B, 231 kernels | 15, zstd 2,256,440 -> 12,014,440 B, 231 kernels, **byte-identical to `orig` (15/15 SHA-256)** |
| ELF `sm_89` | -- | 15, zstd 1,832,808 -> 8,160,912 B, 231 kernels |
| ELF `sm_86` | -- | 15, zstd 4,686,912 -> 21,823,504 B, 231 kernels |
| ELF `sm_75` | -- | 15, zstd 5,928,936 -> 27,749,136 B, 231 kernels |
| PTX (`.target sm_120`, `.version 9.4`) | 15, zstd 5,148,632 -> 37,129,930 B, 231 `.entry` | **8** (fatbins 5, 7-12, 14 -- the 62-kernel one and the seven single-kernel ones; DROPPED from the 7 largest: 0-4, 6, 13), 728,480 -> 5,864,711 B, 69 `.entry` |

The retained PTX is NVIDIA's text with LF turned into **CRLF** (fatbin 5:
5,555,470 -> 5,840,669 B, +285,199 = its line count; line-for-line diff
empty; `e4m3` 7,488 / `cvt.rn.satfinite` 2,496 / `mma.sync` 5,856 in both).
So the stored PTX still says `.target sm_120` and still contains the e4m3
conversions; it is NOT what ptxas was fed for `sm_75` (PTX ISA refuses
`e4m3` below `sm_89` -- inferred from the ISA rule, not measured), so SF
compiled from a rewritten PTX that is not in the file. Consequence of the
drop: on any GPU without an exact ELF (`sm_80` A100, `sm_90` Hopper,
`sm_100`) 7 of 15 modules have nothing to JIT.

### 2. What the cubins say about themselves

`e_machine` is `0xBE` on all 60 + 15. The sm is **bits 8..15 of `e_flags`,
not the low byte** (the question's premise): `sm_75` = `0x06004B04`, `sm_86`
= `0x06005604`, `sm_89` = `0x06005904`, `sm_120` = `0x06007802`; the low byte
is `0x04` on SF's cubins and `0x02` on NVIDIA's (a toolchain/ABI marker, not
an arch). The fatbin header's `arch` field agrees with the ELF in all 60
cases. Kernel names come from the `.text.<name>` sections and were
cross-checked against `STT_FUNC` symbols: identical sets everywhere except
that SF's `sm_75/86/89` cubins of fatbins 4 and 5 additionally export 4 / 12
ptxas-generated `$__internal_N_$__cuda_sm70_shflsync_{bfly,idx_p}` helpers
(shuffle thunks; NVIDIA's `sm_120` build inlined them).

### 3. Kernel census

| arch | cubins | kernels | `*_fp8` | non-fp8 | distinct names | `.text` of the 111 fp8 kernels | `.text` of the 120 non-fp8 |
|---|---|---|---|---|---|---|---|
| `orig` `sm_120` | 15 | 231 | 111 | 120 | 231 | 3,786,880 B = 236,680 instr (mean 2,132) | 4,011,904 B = 250,744 (mean 2,089) |
| `sf2` `sm_120` | 15 | 231 | 111 | 120 | 231 | identical | identical |
| `sf2` `sm_89` | 15 | 231 | 111 | 120 | 231 | 3,723,392 B = 232,712 (mean 2,096) | 3,920,768 B = 245,048 (mean 2,042) |
| `sf2` `sm_86` | 15 | 231 | 111 | 120 | 231 | 16,747,392 B = 1,046,712 (mean 9,429) | 4,506,880 B = 281,680 (mean 2,347) |
| `sf2` `sm_75` | 15 | 231 | 111 | 120 | 231 | **21,123,712 B = 1,320,232 (mean 11,893)** | 6,054,016 B = 378,376 (mean 3,153) |

(instruction count = `.text` bytes / 16; Volta+ SASS is fixed 128-bit.)

The 231-name set is the same on every arch and the same as `orig`. **Every
one of the 111 `_fp8` kernels has a non-fp8 twin present (111/111)**; 9 of
the 120 non-fp8 kernels have no fp8 twin (`cc_cb_clear`, the four
`cuda_capture_*`, and similar utility kernels). 227 of the 231 names also
occur as C strings in the host's `.rdata` (`0xaefa8`..`0xbcdb0`, next to the
layer classes that use them); the 4 without are the `cuda_capture_*` debug
kernels.

Per-kernel, `sm_75 / sm_89` `.text` ratio over the 231 kernels: min 0.67,
median 1.87, max 7.72 -- the non-fp8 kernels grow a little, the fp8
kernels grow 4-8x. The kernel the Reddit post
singled out, on the four arches (`--kernel cc_split_swin_16h_qkv_512_chained`):

| arch | non-fp8: bytes / instr / opc `0x23c` | `_fp8`: bytes / instr / opc `0x23c` / opc `0x27a` |
|---|---|---|
| `sm_75` | 41,984 / **2,624** / 448 | 191,232 / **11,952** / **1,024** / 0 |
| `sm_86` | 29,056 / 1,816 / 224 | 142,592 / 8,912 / 512 / 0 |
| `sm_89` | 26,496 / 1,656 / 224 | 35,456 / 2,216 / 0 / **256** |
| `sm_120` | 27,136 / 1,696 / 224 | 35,584 / 2,224 / 0 / 256 |

The r/nvidia analysis ("DLSS 5 Neural Rendering running on an RTX 2070")
reported 11,952 instructions / 368 B stack for the fp8 QKV-512 kernel and
2,624 / 8 B for the non-fp8 one, and "~1040 HMMA.1688.F16" per tile. The
instruction counts match this file **exactly**, so that post was measuring
this SF build (or the same repack). Opcode `0x23c` (the low 12 bits of the
first qword of each instruction) occurs 1,024 times in the `sm_75` fp8
kernel vs 448 in its twin and vanishes on `sm_89+`, where `0x27a` appears
(256, only ever in `_fp8` kernels, never on `sm_75/86`). The identification
`0x23c` = HMMA and `0x27a` = QMMA is **inferred** from public SASS opcode
tables and consistent with the post; the counts are measured. The rest of
the `sm_75` fp8 kernel's excess is integer/bit work (`0x812` x2,075, `0x816`
x1,458, `0x807` x1,078, `0x824` x992, `0x819` x805 -- raw opcodes, not named
here). The stack numbers were not reproduced: the `.nv.info` attributes
`0x23/0x25` are not present in these cubins' global section, and the
per-kernel `.nv.info.<k>` sections were not decoded.

### 4. What SF changed in the host (everything else is NVIDIA's bytes)

`sf2` is 165,830,144 B, `orig` 165,840,496: the difference is exactly the
10,352-byte Authenticode blob that `orig` carries at its end and `sf2`'s
security directory still points at (now past EOF). PE checksum field
unchanged (`0x9e2fe9d`), `TimeDateStamp` unchanged (`0x6a7b862b`). Outside
the fatbins the two files differ in:

* the PE header: `SizeOfImage` (`0x9d930` -> `0x9d7ac`), `.rsrc` VirtualSize
  (`0x8cdac98` -> `0x8cdacb0`) -- 3 bytes;
* **`.text`, 29 bytes in two places, decoded by hand:**
  1. **RVA `0x17ecc`-`0x17ee7`, the GPU architecture gate.** The function
     at `0x17e20` (it logs `DLSSNR: Created feature %u (... preset=%d ->
     %s)`) reads the NvAPI architecture id, does `lea ecx,[eax-0x140]; cmp
     ecx,0x70; ja default; jmp [table+rcx]`. In NVIDIA's build the cases
     `0x140`, `0x160` (Turing), `0x170` (Ampere), `0x180`, `0x190` (Ada) and
     `0x1A0` each do `mov esi,<id>; jmp 0x17efc`, and `0x17efc` is `mov
     [rsp+0x28],0x1B0; mov [rsp+0x20],esi; lea r9/r8/rcx,<strings>` = the
     `DLSSNR: Unsupported GPU architecture 0x%x, minimum required 0x%x`
     path with minimum **`0x1B0`** (the Blackwell id; the version resource
     says `NGXGpuArchitecture = NVSDK_NGX_GPU_Arch_Blackwell2`). SF rewrote
     the `0x160`, `0x170`, `0x180`, `0x190` cases to `xor esi,esi; nop;nop;
     nop; jmp 0x17f31` -- the success path. `esi` is consumed only by that
     error message (searched the rest of the function for `esi` uses: none),
     so zeroing it is cosmetic. `0x140` and `0x1A0` still refuse.
  2. **RVA `0x15cc4`: one immediate, `0x1B0` -> `0x160`**, in `mov dword
     [rsp+0x3c],imm32` right after `mov dword [rsp+0x38],0x12`, building a
     two-dword local passed to a call (the function also references
     `ngx_templates.h`). A `{0x12, minimum-arch}` pair next to the string
     `GetFeatureRequirements error: NvAPI_GPU_GetArchInfo failed` reads as
     the NGX feature-requirement `MinHWArchitecture` being lowered to Turing
     (**inferred**: the consumer was not decoded).
  Nothing else in `.text` differs. In particular none of the 25 code sites
  that compare a 4-byte name tail against `"_fp8"` (`81 3B 5F 66 70 38` =
  `cmp dword [rbx],"_fp8"` x18, `[rax]` x3, `[rdi]` x3, one other) changed.
* `.rsrc`: the version resource (`16/1/1033`, 1,184 -> 1,220 B; `FileVersion`
  `310,8,0,0` -> `310.8.SF.0`, `ProductVersion` likewise; every other field
  including `NGXGpuArchitecture=NVSDK_NGX_GPU_Arch_Blackwell2`,
  `NGXMinimumDriverVersion=615.00`, `NGXApiVersion=0x0000013` unchanged) was
  moved from the head of the section to its tail, which shifts the weights
  resource **`10/WEIGHTS_HT/1033`** from file `0x114a160` to `0x1149cb8`
  (-1,192 B). **The weights blob, 147,695,410 bytes, is byte-identical** in
  the two files (one `==` over the whole span). That is what a naive
  outside-the-fatbins diff reports as "142,148,736 bytes differ": a move,
  not a change -- `dlssnr_census.py` now says so instead of printing the
  number. The blob contains no kernel names, no `fp8`, no `arch`, no
  `variant` string; only the 158 `blockN.layerM.layer*` tensor labels.

### 5. How the runtime picks a variant, as far as the bytes say

* **Which cubin:** the host loads each fatbin whole -- `Enabling CuModule
  kernel path (load fatbin once, resolve entry points)`, `cuModuleLoadData`,
  `cuModuleGetFunction`, `NvAPI_D3D12_CreateCuModule`/`CreateCuFunction`,
  `vkCreateCuModuleNVX` are all present as strings -- and the driver picks
  the ELF matching the device (standard fatbin dispatch). On a 2060 SUPER
  that is the `sm_75` ELF, the only candidate. There is no host-side
  `sm_NN` string or arch table of its own (`sm_` 0 hits in host strings;
  the 15 `-arch sm_120 -m 64 -split-compile 0` strings in `orig` are
  ptxas command lines inside the dropped PTX).
* **`_fp8` or not:** kernel names are C strings in `.rdata`, both variants
  side by side per layer class, and 25 code sites test whether a name ends
  in `_fp8`. No string `fp16`, `e4m3` (outside the resource-format enum
  names `NGXCubinFormat_sE4M3`, `NGXCubinFormat_sE4M3_HWC32`,
  `NGXCubinFormat_R16F_HWC16`), `precision`, `emulat`, `Turing`, `Ampere`,
  `Blackwell` exists in the host. The one selector-shaped string is
  `DLSSNR: weight '%s' (arch_variant '%s') not claimed by any network
  factory -- check the tag against the dispatch table in cc_network.cpp`,
  i.e. the network factory dispatches on a tag carried by the weight
  descriptor -- and the descriptor (host `.rdata`/`.data`) and weights are
  unchanged. A scan of `.text` for `cmp` against any arch id `0x140`-`0x1D0`
  finds only the gate's `cmp eax,0x140`; a `cmp eax,0x160` at `0x509c1` is a
  Vulkan result check. An arch-driven fp8 switch through a register-loaded
  constant cannot be excluded by this scan, but nothing SF touched feeds
  one. **Verdict on the selector: the host makes the same fp8/non-fp8
  decision it makes on Blackwell; what that decision is was not decoded.**

### 6. Not verified

Which variant actually launches on this machine (a live kernel trace, e.g.
Nsight or a `cuLaunchKernel` hook, would settle it in one raid); the
`0x27a`/`0x23c` mnemonics; the meaning of the `{0x12, 0x1B0}` pair; the
per-kernel stack sizes. The doc's section 2 row for `sm_NNN` strings stands
as a record of what a string scan sees and is superseded by this section.
