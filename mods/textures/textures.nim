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
## Not once. The two target method names are Unity's own and stable, but whether
## they detour by name on the hardened 1.1.0.1.46777 build is unverified (see the
## bridge header on null `methodPointer`s), and the pixel-upload path is not yet
## expressible. `aowl run mods/textures` proves the manifest, the lookup, the
## VRAM budget arithmetic and the safe-refusal path with no runtime in the
## process at all.

import std/strutils
import aowlspt
import aowlspt/server     # `setting`, `serve`
import aowlspt/settings   # the F12 settings schema
import manifest
import swap

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

proc defaultSettings(): Settings =
  Settings(enabled: true, quality: "2k", vramBudgetMB: 1024,
           minConfidence: 0.5, logMatches: true,
           catMetal: true, catWood: true, catConcrete: true,
           catBrick: true, catFabric: true, catGround: false,
           packRoot: "")

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

  check("the swap path cannot upload yet and says so",
        not canUpload(),
        "canUpload() is true but the byte[]/LoadImage path is not bound")

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

  if not gCfg.enabled:
    info "textures  disabled in config; no hooks installed"
    return Ok
  if gCfg.quality == "off":
    info "textures  quality is off; no hooks installed"
    return Ok
  if entryCount() == 0:
    return Ok   # already warned; stay a NO-OP

  setFilter(gCfg.minConfidence, catAllowList())
  discard armSwap(gCfg.vramBudgetMB, tierName())
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if side() != sideClient:
    return Ok
  inc gTicks
  if not swapArmed():
    return Ok
  let now = nowMs()
  if now - gLastReadoutMs >= 10000'i64:
    gLastReadoutMs = now
    if gCfg.logMatches:
      info "textures  " & swapStats()
  Ok

proc onUnload(): Status =
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
