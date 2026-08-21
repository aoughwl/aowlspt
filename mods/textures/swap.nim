## swap.nim — the runtime texture swap, the IL2CPP port of TarkovTextures'
## Harmony postfix.
##
## The original was a BepInEx plugin with two Harmony postfixes:
##
##   [HarmonyPatch(typeof(AssetBundle), nameof(AssetBundle.LoadAsset), ...)]
##   [HarmonyPatch(typeof(AssetBundleRequest), "asset", MethodType.Getter)]
##
## each reading the returned `Texture2D`, matching by its `.name`, and swapping
## `__result` for a higher-res `Texture2D` built from a loose image on disk.
##
## Post-1.0 Tarkov is IL2CPP: no BepInEx, no Harmony. The host gives the exact
## primitive those patches needed — `hookReturn`, a **postfix** detour that is
## handed what the method returned and may replace it. So the two hooks below
## are the same two interceptions, one layer down.
##
## ---------------------------------------------------------------------------
## WHAT IS REAL AND WHAT WAITS ON A NAMED CAPABILITY
## ---------------------------------------------------------------------------
##
## The **name-match half is fully expressible today** and runs live: the postfix
## reads the returned texture object, calls `get_name` on it, lowercases, and
## looks the name up in the manifest. So the mod can prove — in a real raid —
## that it is intercepting the right texture loads and that its curated set
## matches them, logging every hit, before a single pixel is touched.
##
## The **swap half needs one capability the mod ABI does not yet expose**:
## building a `Texture2D` from image bytes means `il2cpp_array_new` (a managed
## `byte[]` to hand `UnityEngine.ImageConversion::LoadImage`) and a mod-side file
## read of the replacement image. Neither is bound on the mod side yet (see
## `aowl/src/aowlspt/il2cpp.nim` — no `arrayNew`, no `readFile`). Until it is,
## `gCanUpload` is false, `buildAndSwap` refuses cleanly, and the postfix returns
## `keepResult()` — the game keeps its stock texture. This is the same honest
## posture the `fov` and `perf` mods take toward capabilities they are waiting on.
##
## A second unknown is whether the two targets even **detour by name** on the
## hardened 1.1.0.1.46777 build: `abi/aowlspt_bridge.h` documents that
## `MethodInfo.methodPointer` is null for many methods on this build, so a
## by-name `patch` can fail to bind. If it does, `armSwap` records the refusal
## and the mod NO-OPs — a missed bind is never a crash. The durable fix, when it
## comes, is a static RVA for `UnityEngine.AssetBundle::LoadAsset` for this exact
## build, resolved the same way the bridge resolved `TarkovApplication::Update`.

import std/strutils
import aowlspt
import aowlspt/game
import manifest

const
  # The two interception points, matching the original plugin.
  TgtLoadAsset* = "UnityEngine.AssetBundle::LoadAsset"
  TgtReqAsset*  = "UnityEngine.AssetBundleRequest::get_asset"

# --------------------------------------------------------------------------
# VRAM budgeting
# --------------------------------------------------------------------------
#
# A 2K texture decoded to RGBA32 with a mip chain is ~22 MiB of VRAM. The
# curated manifest holds ~500 candidates; swapping all of them uncompressed
# would be ~11 GiB and would blow any GPU. So the mod is bounded by a hard VRAM
# budget: it arms textures until the projected budget is spent and then stops.
# The manifest is the soft bound (which textures may be swapped); this is the
# hard one (how many actually become resident).
#
# The real remedy for the per-texture cost is block compression (BC7/BC1) in the
# pipeline or on upload — noted in the README as the next pipeline step. Until
# then this budget keeps the resident set sane by count.

proc tierBytes(tier: string): int64 =
  ## Projected VRAM for one texture at a tier: RGBA32 + mip chain (~1.333x).
  if tier == "4K":
    return 4'i64 * 4096'i64 * 4096'i64 * 4'i64 div 3'i64
  # 2K default: 2048*2048*4 * 4/3
  result = 2048'i64 * 2048'i64 * 4'i64 * 4'i64 div 3'i64

var gArmed = false
var gCanUpload = false        ## flips true when the byte[]/LoadImage path lands
var gBudgetBytes: int64 = 0
var gResidentBytes: int64 = 0
var gTier = "2K"

# Live counters, readable through swapStats() and the settings/store surface.
var gMinConf = 0.0            ## runtime confidence floor on top of the manifest
var gCatFilter = ""          ## ",Metal,Wood," style allow-list; empty = all
var gFires: int64 = 0         ## postfix firings seen
var gTexReturns: int64 = 0    ## firings whose return was a texture we could name
var gMatches: int64 = 0       ## firings whose name is in the manifest
var gSwapped: int64 = 0       ## textures actually swapped (0 until gCanUpload)
var gWithinBudget: int64 = 0  ## matches that fit the VRAM budget
var gRefusedBudget: int64 = 0 ## matches dropped because the budget was spent
var gLastMatchName = ""

proc swapArmed*(): bool = gArmed
proc canUpload*(): bool = gCanUpload

proc setFilter*(minConf: float; enabledCats: string) =
  ## `enabledCats` is a comma-joined category list wrapped in commas, e.g.
  ## ",Metal,Wood,". Empty means every category the manifest carries.
  gMinConf = minConf
  gCatFilter = enabledCats

# --------------------------------------------------------------------------
# The postfix — one body, both targets
# --------------------------------------------------------------------------

proc onTextureReturn(target, args: string): HookResult =
  ## Runs after `LoadAsset` / `get_asset` returns, on the Unity thread (the game
  ## calls these there), which is exactly where a texture may legally be built
  ## and uploaded. Reads the returned object, matches by name, and — when the
  ## upload capability exists — swaps it.
  inc gFires
  let r = hookResult(args)
  if r.isNull:
    return keepResult()
  let obj = asObject(r)
  if not obj.ok:
    # Not a reference return we can inspect (or the host could not hand it over).
    return keepResult()
  # UnityEngine.Object::get_name — the same field the original matched on.
  let nmeR = obj.invoke("get_name")
  let name = nmeR.asText()
  if name.len == 0:
    return keepResult()
  inc gTexReturns
  let idx = lookup(name)
  if idx < 0:
    return keepResult()
  # Runtime filters on top of the pre-curated manifest: a confidence floor and a
  # per-category allow-list, both driven from config. A dropped match is not a
  # miss — it is a texture the player chose not to replace — so it is not counted
  # as a match.
  if entryConf(idx) < gMinConf:
    return keepResult()
  if gCatFilter.len > 0 and find(gCatFilter, "," & entryCat(idx) & ",") < 0:
    return keepResult()
  inc gMatches
  gLastMatchName = name
  let cost = tierBytes(entryTier(idx))
  if gResidentBytes + cost > gBudgetBytes:
    inc gRefusedBudget
    return keepResult()

  if not gCanUpload:
    # The name matched and it fits the budget — everything but the pixels. This
    # is the observable proof the wiring is correct ahead of the capability.
    inc gWithinBudget
    return keepResult()

  # --- the swap itself, once the capability lands -------------------------
  # var newHandle: Handle
  # if buildTextureFromFile(resolvedPath(idx), newHandle):
  #   gResidentBytes += cost
  #   inc gSwapped
  #   return replaceResult("{\"handle\":" & $uint64(newHandle) & "}")
  inc gWithinBudget
  result = keepResult()

# --------------------------------------------------------------------------
# Arming
# --------------------------------------------------------------------------

proc armSwap*(budgetMB: int; tier: string): bool =
  ## Registers the two postfix hooks. Returns true if at least one bound. A
  ## refusal on either is logged and tolerated — the mod runs with whichever
  ## interception points the build actually allows, or none.
  gArmed = false
  gTier = tier
  gBudgetBytes = int64(budgetMB) * 1024'i64 * 1024'i64
  gResidentBytes = 0
  var bound = 0

  let s1 = hookReturn(TgtLoadAsset, onTextureReturn, withArgs = false)
  if s1 == Ok:
    inc bound
    info "textures  hooked " & TgtLoadAsset & " (sync bundle load)"
  else:
    warn "textures  could not hook " & TgtLoadAsset & ": " & lastError() &
         " — sync bundle-load swaps are off (a by-name detour can fail on this " &
         "hardened build; a static RVA is the durable fix)"

  let s2 = hookReturn(TgtReqAsset, onTextureReturn, withArgs = false)
  if s2 == Ok:
    inc bound
    info "textures  hooked " & TgtReqAsset & " (async bundle load)"
  else:
    warn "textures  could not hook " & TgtReqAsset & ": " & lastError() &
         " — async bundle-load swaps are off"

  gArmed = bound > 0
  if gArmed and not gCanUpload:
    warn "textures  ARMED for matching only: the mod will report every texture " &
         "it would swap, but the byte[]/ImageConversion.LoadImage upload path " &
         "is not yet bound on the mod ABI, so stock pixels are kept. See swap.nim."
  result = gArmed

proc swapStats*(): string =
  result = "{\"armed\":" & (if gArmed: "true" else: "false") &
           ",\"canUpload\":" & (if gCanUpload: "true" else: "false") &
           ",\"tier\":\"" & gTier & "\"" &
           ",\"budgetBytes\":" & $gBudgetBytes &
           ",\"residentBytes\":" & $gResidentBytes &
           ",\"fires\":" & $gFires &
           ",\"textureReturns\":" & $gTexReturns &
           ",\"matches\":" & $gMatches &
           ",\"withinBudget\":" & $gWithinBudget &
           ",\"refusedBudget\":" & $gRefusedBudget &
           ",\"swapped\":" & $gSwapped &
           ",\"lastMatch\":\"" & gLastMatchName & "\"}"

proc residentTextureBudget*(budgetMB: int; tier: string): int =
  ## How many textures of `tier` fit in `budgetMB` — the count the mod can
  ## actually make resident, reported at load so the number is visible before a
  ## raid rather than discovered as a stutter inside one.
  let per = tierBytes(tier)
  if per <= 0:
    return 0
  result = int((int64(budgetMB) * 1024'i64 * 1024'i64) div per)
