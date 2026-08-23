## aowl.textures — high-res PBR texture replacement for post-1.0 Tarkov.
##
##     aowl build-mod mods/textures
##     aowl run mods/textures          # offline self-test (no game, no runtime)
##
## This is the aowlspt port and overhaul of the TarkovTextures project — a
## BepInEx/Harmony plugin that swapped stock EFT textures for higher-quality
## ambientcg PBR sets at runtime. Post-1.0 Tarkov is IL2CPP, so there is no
## BepInEx; this mod does the same job through the aowlspt host's native postfix
## detour (`hookReturn`), the exact primitive Harmony's postfix provided.
##
## ---------------------------------------------------------------------------
## THE SPLIT (read `README.md` for the full pipeline)
## ---------------------------------------------------------------------------
##
##  * **Offline pipeline** (`pipeline/build_pack.py`): reads the TarkovTextures
##    tree (extracted BSG textures + ambientcg PBR packs + the name-match table)
##    and emits `data/manifest.json` — a curated, VRAM-tiered `name→replacement`
##    map. This is real and has been run; `data/manifest.json` is its output.
##
##  * **Client runtime** (this mod): loads the manifest, declares its settings,
##    installs the two postfix swap hooks, and enforces a hard VRAM budget. The
##    name-match half runs live; the pixel-upload half waits on one named ABI
##    capability (`swap.nim` says which). Everything is guarded: no manifest, no
##    hook, or no capability all resolve to the same safe outcome — stock
##    textures, no crash.
##
## ---------------------------------------------------------------------------
## HAS IT RUN AGAINST BSG'S CLIENT? No.
## ---------------------------------------------------------------------------
##
## Not once. The upload path is implemented end to end (byte[] via
## il2cpp_array_new, decode via ImageConversion.LoadImage, in-place on the Unity
## thread), but two things only the live client can confirm: whether the two
## targets detour by name on the hardened 1.1.0.1.46777 build (see the bridge
## header on null `methodPointer`s — a static RVA is the fallback), and that the
## bound LoadImage is the byte[] overload. `aowl run mods/textures` proves the
## manifest, the lookup, the VRAM budget arithmetic and the safe-refusal path
## with no runtime in the process at all; `probeUpload` reports the rest at arm
## time in a raid.

import std/strutils
import aowlspt
import aowlspt/server     # `setting`, `serve`
import aowlspt/settings   # the F12 settings schema
import manifest
import swap
import loadprobe

const
  ModGuid = "aowl.textures"
  ModName = "aowl.textures"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

type
  Settings = object
    enabled: bool
    swapMode: string         ## "off" | "probe" | "match" | "full"
    hookAsync: bool          ## also hook get_asset (a thunk on this build)
    armDelayMs: int          ## how long after load before arming (past boot)
    quality: string          ## "off" | "2k" | "4k"
    vramBudgetMB: int
    minConfidence: float
    logMatches: bool
    catMetal: bool
    catWood: bool
    catConcrete: bool
    catBrick: bool
    catFabric: bool
    catGround: bool
    packRoot: string         ## where the replacement images live on disk
    probeTargets: string     ## multi-target counting probe; "" = OFF

proc defaultSettings(): Settings =
  Settings(enabled: true, swapMode: "off", hookAsync: false, armDelayMs: 15000,
           quality: "2k", vramBudgetMB: 1024,
           minConfidence: 0.5, logMatches: true,
           catMetal: true, catWood: true, catConcrete: true,
           catBrick: true, catFabric: true, catGround: false,
           packRoot: "", probeTargets: "")

var gCfg = defaultSettings()
var gTicks = 0
var gLastReadoutMs = 0'i64

proc sBool(key: string; d: bool): bool = setting(key).asBool(d)
proc sInt(key: string; d: int): int = setting(key).asInt(d)
proc sFloat(key: string; d: float): float = setting(key).asFloat(d)
proc sText(key: string; d: string): string = setting(key).asText(d)

proc loadConfig() =
  gCfg = defaultSettings()
  gCfg.enabled = sBool("enabled", gCfg.enabled)
  gCfg.swapMode = sText("swapMode", gCfg.swapMode)
  gCfg.hookAsync = sBool("hookAsync", gCfg.hookAsync)
  gCfg.armDelayMs = sInt("armDelayMs", gCfg.armDelayMs)
  gCfg.quality = sText("quality", gCfg.quality)
  gCfg.vramBudgetMB = sInt("vramBudgetMB", gCfg.vramBudgetMB)
  gCfg.minConfidence = sFloat("minConfidence", gCfg.minConfidence)
  gCfg.logMatches = sBool("logMatches", gCfg.logMatches)
  gCfg.catMetal = sBool("catMetal", gCfg.catMetal)
  gCfg.catWood = sBool("catWood", gCfg.catWood)
  gCfg.catConcrete = sBool("catConcrete", gCfg.catConcrete)
  gCfg.catBrick = sBool("catBrick", gCfg.catBrick)
  gCfg.catFabric = sBool("catFabric", gCfg.catFabric)
  gCfg.catGround = sBool("catGround", gCfg.catGround)
  gCfg.packRoot = sText("packRoot", gCfg.packRoot)
  gCfg.probeTargets = sText("probeTargets", gCfg.probeTargets)

proc tierName(): string =
  if gCfg.quality == "4k": "4K" else: "2K"

proc catAllowList(): string =
  ## The ",Cat,Cat," allow-list the swap handler matches against.
  var s = ","
  if gCfg.catMetal: s.add "Metal,"
  if gCfg.catWood: s.add "Wood,"
  if gCfg.catConcrete: s.add "Concrete,"
  if gCfg.catBrick: s.add "Brick,"
  if gCfg.catFabric: s.add "Fabric,"
  if gCfg.catGround: s.add "Ground,"
  result = s

# ---------------------------------------------------------------------------
# Settings schema (F12 panel)
# ---------------------------------------------------------------------------

proc texturesSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Enable texture replacement", true,
                category = "General",
                description = "Master switch. Off means stock textures, no hooks."),
    enumSetting("swapMode", "Swap mode", "off",
                @["off", "probe", "match", "full"], category = "General",
                description = "Escalation ladder. off: install nothing. probe: install the verified LoadAsset hook, count firings only (proves the hook is safe). match: also name-match against the manifest (no pixels). full: also upload the replacement texture. Escalate one rung at a time."),
    intSetting("armDelayMs", "Arm delay (ms)", 15000, lo = 0, hi = 120000,
               step = 1000, category = "General",
               description = "How long after load before hooks are installed. Deferred past the boot bundle-load storm, which is where the naive version crashed. The mod also waits for the Unity main-thread drain to be live."),
    boolSetting("hookAsync", "Hook async loads (get_asset)", false,
                category = "General", implemented = false,
                description = "Off: on build 1.1.0.1.46777 AssetBundleRequest::get_asset resolves to a tail-jump thunk, which is unsafe to postfix. Only enable once verified on your build."),
    enumSetting("quality", "Quality tier", "2k", @["off", "2k", "4k"],
                category = "General",
                description = "2K is shipped; 4K needs the 4K pack downloaded and degrades to 2K when absent."),
    intSetting("vramBudgetMB", "VRAM budget (MB)", 1024, lo = 128, hi = 8192,
               step = 128, category = "General",
               description = "Hard cap on replacement-texture VRAM. Textures are armed until this is spent."),
    floatSetting("minConfidence", "Minimum match confidence", 0.5,
                 lo = 0.0, hi = 1.0, step = 0.05, category = "General",
                 description = "Runtime floor on the name-match confidence, on top of the curated manifest."),
    boolSetting("logMatches", "Log matched textures", true, category = "General",
                description = "Log each texture the mod would swap. Useful before the upload path lands."),

    boolSetting("catMetal", "Metal surfaces", true, category = "Categories"),
    boolSetting("catWood", "Wood surfaces", true, category = "Categories"),
    boolSetting("catConcrete", "Concrete / plaster", true, category = "Categories"),
    boolSetting("catBrick", "Brick / stone / tile", true, category = "Categories"),
    boolSetting("catFabric", "Fabric / cloth", true, category = "Categories"),
    boolSetting("catGround", "Ground / terrain", false, category = "Categories",
                description = "Off by default: terrain covers huge screen area and is the heaviest on VRAM."),

    stringSetting("probeTargets", "Load-method counting probe", "",
                category = "Advanced",
                description = "DIAGNOSTIC, default OFF. Empty or 'off' installs nothing. Otherwise a comma list of GROUPS (ab eb ea am bm ex tc abx bsg all) or TAGS (ab6, eb42, am100582, tc56889, ...), installing a count-only typed PREFIX on each and logging one line every 10s: grep 'textures  loadprobe fires'. Start with 'bsg' -- BSG's own asset layer (Diz.Resources.EasyAssets/EasyBundle, EFT.AssetsManager, TextureCache) plus the ab6 control, which must read 0. A bare number still means an AssetBundle rid, and only that. Requires swapMode=off (both would detour ab6)."),

    boolSetting("packRootSet", "Custom pack root", false, category = "Advanced",
                implemented = false,
                description = "packRoot in config.json points at the replacement images; edited there, not here."),
  ]

proc onSettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    loadConfig()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc reportLoad() =
  let tier = tierName()
  let fit = residentTextureBudget(gCfg.vramBudgetMB, tier)
  info "textures  manifest: " & $entryCount() & " curated replacement(s), tier " &
       tier
  info "textures  VRAM budget " & $gCfg.vramBudgetMB & " MB fits ~" & $fit &
       " resident " & tier & " textures (RGBA32 + mips); the manifest is the " &
       "candidate set, the budget is the hard resident cap"
  info "textures  categories on: " & catAllowList().replace(",", " ")
  if entryCount() == 0:
    warn "textures  the manifest is empty or unreadable; the mod is a NO-OP " &
         "(stock textures). Run pipeline/build_pack.py to (re)generate " &
         "data/manifest.json."

# ---------------------------------------------------------------------------
# Offline self-test (aowl run mods/textures)
# ---------------------------------------------------------------------------

var gFailures = 0

proc check(what: string; ok1: bool; detail: string) =
  if ok1:
    success "selftest  " & what
  else:
    inc gFailures
    error "selftest  " & what & ": " & detail

proc simSelfTest(): Status =
  ## Proves the parts that need no runtime: the manifest parsed, the lookup is
  ## sound, the VRAM arithmetic is sane, and the swap path refuses cleanly when
  ## it cannot upload.
  check("the manifest parsed to at least one entry", entryCount() > 0,
        "the manifest at " & dataDir() & "/manifest.json did not parse; run " &
        "pipeline/build_pack.py")

  if entryCount() > 0:
    # Every entry must round-trip through lookup, and lookup must miss on junk.
    let firstName = entryName(0)
    check("a known name resolves", lookup(firstName) >= 0,
          "lookup(" & firstName & ") missed its own entry")
    check("an absent name misses",
          lookup("this-texture-does-not-exist-zzq") < 0,
          "a junk name resolved to an entry")

  let fit2k = residentTextureBudget(1024, "2K")
  let fit4k = residentTextureBudget(1024, "4K")
  check("a 1 GB budget fits some 2K textures and fewer 4K",
        fit2k > 0 and fit4k > 0 and fit4k < fit2k,
        "2K fit " & $fit2k & ", 4K fit " & $fit4k)

  check("the swap path is inert until armed on the client",
        not canUpload() and not swapArmed(),
        "the swap armed on the sim side, where there is no game to swap against")

  if gFailures == 0:
    success "selftest  all checks passed (" & $entryCount() & " replacements)"
    return Ok
  error "selftest  " & $gFailures & " check(s) failed"
  result = ErrGeneric

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  declareSettings(texturesSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  success ModName & " " & ModVersion & " loaded on " & hostName()

  # The manifest lives in the mod's own data dir; packRoot (where the images
  # are) defaults to the TarkovTextures tree the pipeline read from, overridable
  # in config.json for a deployed self-contained pack.
  let manifestPath = dataDir() & "/manifest.json"
  var root = gCfg.packRoot
  if root.len == 0:
    root = dataDir() & "/pack"     # a --copy pack, if one was assembled here
  discard loadManifest(manifestPath, root)
  reportLoad()

  if side() == sideSim:
    return simSelfTest()
  if side() != sideClient:
    info "textures is client-only; nothing to do on this side"
    return Ok

  # The counting probe is configured BEFORE the swapMode gate, deliberately:
  # it is a DIAGNOSTIC and its whole point is to run with swapMode=off, which
  # is the only configuration in which it is not fighting swap.nim for rid=6.
  configureLoadProbe(gCfg.probeTargets, gCfg.swapMode, gCfg.armDelayMs)
  if loadProbeEnabled():
    info "textures  loadprobe: probeTargets='" & gCfg.probeTargets &
         "' — will install count-only PREFIXes ~" &
         $(gCfg.armDelayMs div 1000) & "s after load and report every 10s " &
         "(grep: textures  loadprobe fires)"

  if not gCfg.enabled or gCfg.quality == "off" or gCfg.swapMode == "off":
    info "textures  swapMode=off (or disabled): no swap hooks will be " &
         "installed, the game uses stock textures. Escalate with swapMode " &
         "probe -> match -> full in config.json once boot is confirmed stable."
    return Ok
  if entryCount() == 0:
    return Ok   # already warned; stay a NO-OP

  # Nothing is armed here. Arming is deferred to onUpdate so no hook is
  # installed during the boot bundle-load storm — that is where the first live
  # test crashed. `configureSwap` only records the intent.
  setFilter(gCfg.minConfidence, catAllowList())
  configureSwap(gCfg.swapMode, gCfg.vramBudgetMB, tierName(),
                gCfg.hookAsync, gCfg.armDelayMs)
  info "textures  will arm in mode '" & gCfg.swapMode & "' ~" &
       $(gCfg.armDelayMs div 1000) & "s after load, once the game's assemblies " &
       "are up (drain-independent — the postfix runs on the Unity thread because " &
       "the game calls LoadAsset there)"
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if side() != sideClient:
    return Ok
  inc gTicks
  # The counting probe arms independently of the swap: it is meant to run with
  # swapMode=off, where `swapArmed()` is false forever and the swap's own
  # early-return below would otherwise never let a readout happen.
  discard maybeArmLoadProbe()

  let now = nowMs()
  let due = now - gLastReadoutMs >= 10000'i64
  if due:
    gLastReadoutMs = now
    # ONE line naming every candidate and its count, zeros included: "which
    # ones did NOT fire" is half the result of the probe raid.
    if loadProbeArmed():
      info loadProbeReport()

  # Deferred, verified arming of the swap: a no-op every tick until it is safe.
  if not swapArmed():
    discard maybeArm()
    return Ok
  if due and gCfg.logMatches:
    info "textures  " & swapStats()
  Ok

proc onUnload(): Status =
  if loadProbeArmed():
    info loadProbeReport()
  info ModName & " unloaded after " & $gTicks & " ticks; " & swapStats()
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = "savannt",
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
