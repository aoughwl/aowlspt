## aowl.dlss -- the CONTROL SURFACE for DLSS / OptiScaler on this install.
##
##     aowl build-mod mods/dlss
##
## ---------------------------------------------------------------------------
## THE SPLIT, AND WHY NOTHING HERE APPLIES ANYTHING
## ---------------------------------------------------------------------------
##
## Every knob this mod declares is applied by a **launcher-side step**, before
## `EscapeFromTarkov.exe` starts:
##
##   * `nvngx_dlss.dll` is a file the running client holds OPEN, and it is
##     listed in the consistency manifest (`IsCritical:true`) -- swapping it
##     needs the process stopped and the manifest re-synced and re-injected
##     into the exe. `tools/dlss.py install` is the only path that does all
##     three with a read-back verification; this mod does not reimplement it.
##   * `OptiScaler.ini` is read by the proxy DLL at process attach. A write
##     after that point changes a file and nothing else.
##
## So the mod owns the SCHEMA and the persisted VALUES, and
## `tools/dlssapply.py` -- called by `aowlspt-launch` (tools/aowldlss.nim)
## before the client starts -- reads this mod's `config.json` and makes the
## install match it. The same tool, re-run against the live process id after
## the client is up, prints the boot verdict: the version of the
## `nvngx_dlss.dll` the process actually LOADED, the OptiScaler keys actually
## on disk, and PASS or FAIL against these values.
##
## That is why every caption says "applies on restart" and why the hot-apply
## hook below never claims a change took effect. A setting that says it
## applied and did not is the defect this repository produces most often.
##
## ---------------------------------------------------------------------------
## WHY NUMBERS RATHER THAN NAMES FOR `version` AND `upscaler`
## ---------------------------------------------------------------------------
##
## The native settings rows for these live in the game's own Graphics page
## (`host/Aowlspt.Host.Il2Cpp/dlssrows.nim`). A native CHOICE row is a
## `SettingDropDown` or a `SettingSelectSlider`, and every bind either of those
## has (`BindTo`, `BindToEnum`, all three `BindIndexTo` overloads) is a GENERIC
## method with no offline code entry -- the same reason `postfxrows.nim`
## declines `preset` and `tonemapper`. The bindable native controls on this
## build are exactly two: a toggle and a float slider.
##
## A step-valued float slider IS therefore the honest stepper, and it is
## mutually exclusive by construction, which a set of independent toggles is
## not. The number is the source of truth in both surfaces -- this schema, the
## F12 overlay and the native row all show the same 1/2/3 -- so the two cannot
## drift, and the meaning of each step is in the caption and in the
## description.
##
## ---------------------------------------------------------------------------
## PROVENANCE
## ---------------------------------------------------------------------------
## `docs/DLSS.md` (which SR versions exist, their hashes, the manifest
## landmine, what was measured on this GPU) and `docs/DLSSNR.md` (what "DLSS 5"
## actually is: an unsigned third-party rebuild of a leaked NVIDIA binary, a
## stated 616.56 driver minimum, a D3D11 game that has to be bridged onto D3D12
## -- which REPLACES DLSS with FSR or XeSS while the pass is on). The
## descriptions below carry the short form of both; neither doc is summarised
## optimistically.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings

const
  ModGuid = "aowl.dlss"
  ModName = "DLSS"
  ModAuthor = "aowlspt"
  ModVersion = "0.1.0"

# ---------------------------------------------------------------------------
# The catalogue mirrors, kept as ONE table each so a caption, a description and
# the launcher's mapping cannot disagree. `tools/dlssapply.py` carries the same
# two tables and its self-test asserts they match this file's text.
# ---------------------------------------------------------------------------

const
  VersionNames = ["310.5.3 (shipped)", "310.7.0", "310.7.129"]
  UpscalerNames = ["DLSS", "FSR 3.1", "XeSS"]

var
  cfgVersion = 2
  cfgUpscaler = 1
  cfgNrEnabled = false
  cfgNrWorkingScale = 0.25
  cfgNrIntensity = 1.0

proc clampI(v, lo, hi: int): int =
  if v < lo: lo elif v > hi: hi else: v

proc versionName(i: int): string =
  VersionNames[clampI(i, 1, 3) - 1]

proc upscalerName(i: int): string =
  UpscalerNames[clampI(i, 1, 3) - 1]

proc loadConfig() =
  cfgVersion = clampI(setting("version").asInt(cfgVersion), 1, 3)
  cfgUpscaler = clampI(setting("upscaler").asInt(cfgUpscaler), 1, 3)
  cfgNrEnabled = setting("nrEnabled").asBool(cfgNrEnabled)
  cfgNrWorkingScale = setting("nrWorkingScale").asFloat(cfgNrWorkingScale)
  cfgNrIntensity = setting("nrIntensity").asFloat(cfgNrIntensity)

# ---------------------------------------------------------------------------
# Settings schema (F12 / settingshub, and the native Graphics page)
# ---------------------------------------------------------------------------

proc schema(): seq[Setting] =
  @[
    floatSetting("version", "DLSS version (1 shipped 310.5.3 / 2 310.7.0 / 3 310.7.129)",
                 2.0, lo = 1.0, hi = 3.0, step = 1.0,
                 category = "Super Resolution",
                 description = "APPLIES ON RESTART. Which nvngx_dlss.dll the launcher installs before the game starts. 1 = 310.5.3, the DLL the game shipped with (the rollback target); 2 = 310.7.0, proven loaded on this machine 2026-09-03; 3 = 310.7.129, pinned and hash-verified but never booted here. The swap re-syncs and re-injects the consistency manifest -- the client refuses to boot if that file changes size without it (docs/DLSS.md). The DLL is locked while the client runs, so this can only ever take effect on the next launch."),
    floatSetting("upscaler", "Upscaler (1 DLSS / 2 FSR 3.1 / 3 XeSS)",
                 1.0, lo = 1.0, hi = 3.0, step = 1.0,
                 category = "Super Resolution",
                 description = "APPLIES ON RESTART. OptiScaler's Dx11Upscaler key: 1 = dlss (the game's own DLSS, native DX11), 2 = ffx_12 (FSR 3.1 through OptiScaler's DX11-on-DX12 bridge), 3 = xess_12 (XeSS, same bridge). Only does anything when OptiScaler is installed beside the executable; when it is not, the launcher's verdict says so rather than pretending the value was applied. OptiScaler reads its ini at process attach, so a change mid-session cannot be picked up."),
    boolSetting("nrEnabled", "DLSS 5 re-lighting", false,
                category = "Neural rendering (DLSS 5)",
                description = "APPLIES ON RESTART. OptiScaler [DlssNr] Enabled -- the leaked 'DLSS 5' neural re-lighting pass. Read docs/DLSSNR.md before turning this on: the model is an unsigned third-party rebuild of a leaked NVIDIA binary, its author states a 616.56 driver minimum, and because this game talks D3D11 to NGX the pass only runs with the frame bridged onto D3D12 -- which REPLACES DLSS with FSR or XeSS as the upscaler for as long as it is on. No published performance number exists for a Turing card."),
    floatSetting("nrWorkingScale", "DLSS 5 working scale", 0.25,
                 lo = 0.25, hi = 1.0, step = 0.05,
                 category = "Neural rendering (DLSS 5)",
                 description = "APPLIES ON RESTART. OptiScaler [DlssNr] WorkingScale. The fraction of the frame the model works on; its cost falls with the SQUARE of this (OptiScaler's own ini comment). 0.25 is what tools/dlssnr.py installs on this GPU."),
    floatSetting("nrIntensity", "DLSS 5 intensity", 1.0,
                 lo = 0.0, hi = 2.0, step = 0.05,
                 category = "Neural rendering (DLSS 5)",
                 description = "APPLIES ON RESTART. OptiScaler [DlssNr] Intensity -- how hard the model's re-lighting reads. 1.0 is OptiScaler's own default.")]

proc summary(): string =
  "version=" & versionName(cfgVersion) & " upscaler=" & upscalerName(cfgUpscaler) &
  " dlss5=" & (if cfgNrEnabled: "on" else: "off") &
  " workingScale=" & $cfgNrWorkingScale & " intensity=" & $cfgNrIntensity

proc onSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok:
      loadConfig()
  result = declaredSchemaReply(st).text

proc onSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok:
    loadConfig()
  result = declaredSchemaReply(st).text

proc onSettingsHotApply(key: string) =
  ## THE HONEST HOOK. There is no hot-apply for any of these and there cannot
  ## be one: the DLL is open in this very process and OptiScaler read its ini
  ## before this mod existed. The value is stored; the launcher applies it and
  ## prints the verdict on the next boot. Saying so is the whole job of this
  ## proc -- a setting that silently waits for a restart reads as broken.
  loadConfig()
  settingIgnored("stored, and it takes effect on the NEXT LAUNCH. " &
                 "aowlspt-launch runs tools/dlssapply.py before the game " &
                 "starts and prints a PASS/FAIL verdict in the boot log. " &
                 "Nothing can apply it now: nvngx_dlss.dll is open in this " &
                 "process and OptiScaler read its ini at attach. Current " &
                 "stored state: " & summary())

proc onLoad(): Status =
  loadConfig()
  declareSettings(schema())
  onSettingsApplied(onSettingsHotApply)
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onSettingsReset)
  success "dlss  control surface only -- the launcher applies these before " &
          "the game starts. Stored: " & summary()
  Ok

proc onUpdate(elapsedMs: int64): Status = Ok

proc onUnload(): Status = Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
