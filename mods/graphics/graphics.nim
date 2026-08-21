## aowl.graphics — the control surface for the native full-frame post-process.
##
##     aowl build-mod mods/graphics
##     aowl run mods/graphics
##
## ---------------------------------------------------------------------------
## THE SPLIT
## ---------------------------------------------------------------------------
##
## The rendering does NOT run here. It runs client-side in the host, in
## `abi/aowlspt_graphics.h` (wrapped by `host/Aowlspt.Graphics/aowlgraphics.nim`),
## because that is where the GPU, the D3D11 device and the swap chain are — a
## mod DLL has none of them. This mod owns everything else: the config schema,
## the F12 settings surface, and turning a config edit into a grade the host
## renderer can apply. The one wire between the two halves is a single host
## call:
##
##     call("aowlspt.host::gfx_apply", <compact-params-json>)
##
## The host forwards that JSON, verbatim, to the native module, which copies it
## under a lock and uses it on the next Present. Nothing here touches Unity or
## IL2CPP, so this mod is a clean no-op on any host that does not carry the
## graphics module: the call simply returns an error and the game renders
## normally.
##
## ---------------------------------------------------------------------------
## WHAT THE STACK DOES  (see abi/aowlspt_graphics.h and shaders/Post.hlsl)
## ---------------------------------------------------------------------------
##
## A ReShade-style screen-space pass over the finished back buffer: CAS
## sharpening, linearize, exposure + highlight roll-off + shadow lift, white
## balance, an optional bloom composite, a tonemap LOOK (AgX — the ported
## original — or ACES, blended by strength), lift/gamma/gain, contrast around
## mid-grey, saturation, and a vignette. It is a *look* on top of BSG's shipped
## image, not a replacement of their HDR tonemapper — the honest limit of a
## screen-space pass. Depth effects (SSAO) wait for the in-engine bridge path.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings

const
  ModGuid = "aowl.graphics"
  ModName = "aowl.graphics"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

type
  Grade = object
    enabled: bool
    raidOnly: bool
    tonemapper: int
    tonemapStrength: float
    exposure: float
    contrast: float
    saturation: float
    temperature: float
    tint: float
    lift: float
    gamma: float
    gain: float
    shadows: float
    highlights: float
    sharpness: float
    bloom: bool
    bloomStrength: float
    vignette: float
    vignetteRadius: float
    diag: bool

proc defaultGrade(): Grade =
  Grade(enabled: true, raidOnly: true, tonemapper: 1, tonemapStrength: 0.85, exposure: 0.0,
        contrast: 1.05, saturation: 1.05, temperature: 0.0, tint: 0.0,
        lift: 0.0, gamma: 1.0, gain: 1.0, shadows: 0.0, highlights: 1.1,
        sharpness: 0.35, bloom: true, bloomStrength: 0.35, vignette: 0.18,
        vignetteRadius: 1.0, diag: false)

var gGrade = defaultGrade()

proc loadConfig() =
  gGrade = defaultGrade()
  gGrade.enabled        = setting("enabled").asBool(gGrade.enabled)
  gGrade.raidOnly       = setting("raidOnly").asBool(gGrade.raidOnly)
  gGrade.tonemapper     = setting("tonemapper").asInt(gGrade.tonemapper)
  gGrade.tonemapStrength = setting("tonemapStrength").asFloat(gGrade.tonemapStrength)
  gGrade.exposure       = setting("exposure").asFloat(gGrade.exposure)
  gGrade.contrast       = setting("contrast").asFloat(gGrade.contrast)
  gGrade.saturation     = setting("saturation").asFloat(gGrade.saturation)
  gGrade.temperature    = setting("temperature").asFloat(gGrade.temperature)
  gGrade.tint           = setting("tint").asFloat(gGrade.tint)
  gGrade.lift           = setting("lift").asFloat(gGrade.lift)
  gGrade.gamma          = setting("gamma").asFloat(gGrade.gamma)
  gGrade.gain           = setting("gain").asFloat(gGrade.gain)
  gGrade.shadows        = setting("shadows").asFloat(gGrade.shadows)
  gGrade.highlights     = setting("highlights").asFloat(gGrade.highlights)
  gGrade.sharpness      = setting("sharpness").asFloat(gGrade.sharpness)
  gGrade.bloom          = setting("bloom").asBool(gGrade.bloom)
  gGrade.bloomStrength  = setting("bloomStrength").asFloat(gGrade.bloomStrength)
  gGrade.vignette       = setting("vignette").asFloat(gGrade.vignette)
  gGrade.vignetteRadius = setting("vignetteRadius").asFloat(gGrade.vignetteRadius)
  gGrade.diag           = setting("diag").asBool(gGrade.diag)

# ---------------------------------------------------------------------------
# Pushing the grade to the host renderer
# ---------------------------------------------------------------------------

proc f(v: float): string =
  ## A plain decimal for the params JSON. `$` on a float is fine here — this
  ## runs on config change, not per frame.
  result = $v

proc paramsJson(g: Grade): string =
  ## The compact object the native module parses (flat keys, numbers/bools).
  ## Bools go out as 0/1 so the C reader's number path handles them uniformly.
  result = "{" &
    "\"enabled\":" & (if g.enabled: "1" else: "0") &
    ",\"raidOnly\":" & (if g.raidOnly: "1" else: "0") &
    ",\"tonemapper\":" & $g.tonemapper &
    ",\"tonemapStrength\":" & f(g.tonemapStrength) &
    ",\"exposure\":" & f(g.exposure) &
    ",\"contrast\":" & f(g.contrast) &
    ",\"saturation\":" & f(g.saturation) &
    ",\"temperature\":" & f(g.temperature) &
    ",\"tint\":" & f(g.tint) &
    ",\"lift\":" & f(g.lift) &
    ",\"gamma\":" & f(g.gamma) &
    ",\"gain\":" & f(g.gain) &
    ",\"shadows\":" & f(g.shadows) &
    ",\"highlights\":" & f(g.highlights) &
    ",\"sharpness\":" & f(g.sharpness) &
    ",\"bloom\":" & (if g.bloom: "1" else: "0") &
    ",\"bloomStrength\":" & f(g.bloomStrength) &
    ",\"vignette\":" & f(g.vignette) &
    ",\"vignetteRadius\":" & f(g.vignetteRadius) &
    ",\"diag\":" & (if g.diag: "1" else: "0") & "}"

proc pushGrade(): bool =
  ## Send the current grade to the native post-process. Returns whether the host
  ## carried the graphics module (i.e. the call was answered). A false here is
  ## the whole no-op story: on a host without the renderer the mod does nothing
  ## and says so once, rather than failing.
  var reply = ""
  let st = call("aowlspt.host::gfx_apply", paramsJson(gGrade), reply)
  result = st == Ok

# ---------------------------------------------------------------------------
# Settings schema (F12 / settingshub)
# ---------------------------------------------------------------------------

proc schema(): seq[Setting] =
  @[
    boolSetting("enabled", "Enable post-process", true,
                category = "Post-process",
                description = "Master switch. Off = the game renders untouched."),
    boolSetting("raidOnly", "Raid only (menu stays stock)", true,
                category = "Post-process",
                description = "Grade only in-raid; the menu and 2D UI stay " &
                    "stock. Off = grade everywhere (also needed if you run " &
                    "without the backend, which is what supplies the raid signal)."),
    enumSetting("tonemapper", "Tonemapper", "1", @["0", "1", "2"],
                category = "Tonemap",
                description = "0 none, 1 AgX (filmic, neutral highlights), 2 ACES."),
    floatSetting("tonemapStrength", "Tonemap strength", 0.85,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Tonemap",
                 description = "Blend of the tonemap look over the linear image."),
    floatSetting("exposure", "Exposure (EV)", 0.0,
                 lo = -3.0, hi = 3.0, step = 0.05, category = "Tonemap",
                 description = "EV bias applied before the tonemap."),
    floatSetting("contrast", "Contrast", 1.05,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Grade",
                 description = "Contrast around 18% mid-grey, in linear."),
    floatSetting("saturation", "Saturation", 1.05,
                 lo = 0.0, hi = 2.0, step = 0.01, category = "Grade",
                 description = "0 greyscale, 1 neutral, >1 vivid."),
    floatSetting("temperature", "Temperature", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "White balance",
                 description = "Cool (-) to warm (+)."),
    floatSetting("tint", "Tint", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "White balance",
                 description = "Green (-) to magenta (+)."),
    floatSetting("lift", "Lift (shadows)", 0.0,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Lift/Gamma/Gain"),
    floatSetting("gamma", "Gamma (midtones)", 1.0,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Lift/Gamma/Gain"),
    floatSetting("gain", "Gain (highlights)", 1.0,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Lift/Gamma/Gain"),
    floatSetting("shadows", "Shadow lift (additive)", 0.0,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Legacy (AgX)",
                 description = "Matches the original TarkovGraphics shadow knob."),
    floatSetting("highlights", "Highlight roll-off", 1.1,
                 lo = 0.5, hi = 2.0, step = 0.01, category = "Legacy (AgX)",
                 description = "Pre-tonemap highlight compression."),
    floatSetting("sharpness", "Sharpening (CAS)", 0.35,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Sharpen"),
    boolSetting("bloom", "Bloom", true, category = "Bloom"),
    floatSetting("bloomStrength", "Bloom strength", 0.35,
                 lo = 0.0, hi = 2.0, step = 0.01, category = "Bloom"),
    floatSetting("vignette", "Vignette", 0.18,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Vignette"),
    floatSetting("vignetteRadius", "Vignette radius", 1.0,
                 lo = 0.5, hi = 1.5, step = 0.01, category = "Vignette"),
    boolSetting("diag", "Red-tint diagnostic", false, category = "Debug",
                description = "Tints the frame red to confirm the blit lands.")]

proc onSettings(url, body, session: string): string =
  ## GET returns the schema with live values; POST applies one edit to
  ## config.json, re-reads, and re-pushes the grade so the change is visible at
  ## once.
  if body.len > 0 and applySettingFromBody(body) == Ok:
    loadConfig()
    discard pushGrade()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# Events — apply/reload without a settings round trip
# ---------------------------------------------------------------------------

proc onApplyEvent(payload: string): string =
  loadConfig()
  let ok = pushGrade()
  result = "{\"ok\":" & (if ok: "true" else: "false") & "}"

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  declareSettings(schema())
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard on("aowl.graphics.apply", onApplyEvent)
  if pushGrade():
    success "graphics  grade pushed to the host post-process (tonemapper=" &
            $gGrade.tonemapper & ", enabled=" & (if gGrade.enabled: "yes" else: "no") & ")"
  else:
    warn "graphics  this host has no post-process module, or it is not up yet; " &
         "the grade will be re-sent on the next config change. The game renders " &
         "normally in the meantime."
  Ok

proc onUpdate(elapsedMs: int64): Status = Ok

proc onUnload(): Status =
  ## Disable the effect on the way out so unloading the mod restores the stock
  ## look. We push an enabled=false grade rather than tearing the host module
  ## down (the host owns its lifetime).
  gGrade.enabled = false
  discard pushGrade()
  Ok

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
