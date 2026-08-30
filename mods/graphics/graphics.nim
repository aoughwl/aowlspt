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
  ModName = "Graphics"
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
    clarity: float
    vibrance: float
    shadowDetail: float
    grain: float
    grainSize: float
    dither: float
    chroma: float
    bloomThreshold: float
    diag: bool

proc defaultGrade(): Grade =
  ## The "filmic" preset, spelled out. Anything not overridden below inherits it.
  Grade(enabled: true, raidOnly: true, tonemapper: 1, tonemapStrength: 0.90, exposure: 0.0,
        contrast: 1.10, saturation: 1.02, temperature: 0.04, tint: 0.0,
        lift: 0.0, gamma: 1.0, gain: 1.0, shadows: 0.0, highlights: 1.1,
        sharpness: 0.35, bloom: true, bloomStrength: 0.30, vignette: 0.20,
        vignetteRadius: 1.0,
        clarity: 0.30, vibrance: 0.35, shadowDetail: 0.35,
        grain: 0.18, grainSize: 1.5, dither: 1.0, chroma: 0.0,
        bloomThreshold: 0.70,
        diag: false)

# ---------------------------------------------------------------------------
# PRESETS - the point of the mod
#
# Twenty sliders is a toolkit, not a product. A preset is one word a player
# types (or picks in the settings panel) that produces a finished look, and one
# line they can paste into Discord for someone else to reproduce it exactly.
#
# Semantics, deliberately unambiguous: while `preset` is anything other than
# "custom", the preset OWNS every look key and the individual sliders are
# ignored. Pick "custom" to drive the sliders yourself. The alternative --
# letting sliders partially override a preset -- means switching preset does
# not visibly change anything once you have touched one slider, which is the
# single most common way a preset system feels broken.
# ---------------------------------------------------------------------------

proc presetNames(): seq[string] =
  @["custom", "neutral", "filmic", "cold-clinical", "warm-cinematic", "night-owl"]

proc applyPreset(g: var Grade, name: string) =
  ## Overwrite the look keys from a named preset. `enabled`, `raidOnly` and
  ## `diag` are NOT touched: they are policy, not a look, and a preset that
  ## silently re-enables the effect or re-arms the red-tint diagnostic would be
  ## a nasty surprise.
  if name == "neutral":
    # Cleanup only. What BSG shipped, minus the banding and the mush. The
    # honest baseline: if you cannot tell this apart from vanilla in a
    # screenshot, it is doing its job.
    g.tonemapper = 1;  g.tonemapStrength = 0.60
    g.exposure = 0.0;  g.contrast = 1.02;  g.saturation = 1.0
    g.temperature = 0.0; g.tint = 0.0
    g.lift = 0.0; g.gamma = 1.0; g.gain = 1.0
    g.shadows = 0.0; g.highlights = 1.05
    g.sharpness = 0.30; g.clarity = 0.15; g.vibrance = 0.15
    g.shadowDetail = 0.20
    g.bloom = false; g.bloomStrength = 0.0; g.bloomThreshold = 0.70
    g.vignette = 0.08; g.vignetteRadius = 1.0
    g.grain = 0.0; g.grainSize = 1.5; g.dither = 1.0; g.chroma = 0.0
  elif name == "cold-clinical":
    # The competitive look: see people. Cool and slightly bright, shadows
    # pulled open hard, bloom OFF (bloom is glare, glare is a player you did
    # not see), no vignette (a vignette darkens exactly the screen edge where
    # peripheral movement lives), no grain.
    g.tonemapper = 1;  g.tonemapStrength = 0.70
    g.exposure = 0.15; g.contrast = 1.06;  g.saturation = 0.95
    g.temperature = -0.18; g.tint = -0.03
    g.lift = 0.0; g.gamma = 1.04; g.gain = 1.0
    g.shadows = 0.0; g.highlights = 1.20
    g.sharpness = 0.50; g.clarity = 0.40; g.vibrance = 0.20
    g.shadowDetail = 0.55
    g.bloom = false; g.bloomStrength = 0.0; g.bloomThreshold = 0.80
    g.vignette = 0.0; g.vignetteRadius = 1.0
    g.grain = 0.0; g.grainSize = 1.5; g.dither = 1.0; g.chroma = 0.0
  elif name == "warm-cinematic":
    # The screenshot look. Warm, contrasty, bloomy, grainy, a touch of lens.
    # Costs you a little visibility and buys you a frame worth posting.
    g.tonemapper = 1;  g.tonemapStrength = 1.0
    g.exposure = 0.0;  g.contrast = 1.12;  g.saturation = 1.05
    g.temperature = 0.22; g.tint = 0.04
    g.lift = 0.012; g.gamma = 1.0; g.gain = 1.02
    g.shadows = 0.0; g.highlights = 1.10
    g.sharpness = 0.30; g.clarity = 0.28; g.vibrance = 0.35
    g.shadowDetail = 0.30
    g.bloom = true; g.bloomStrength = 0.55; g.bloomThreshold = 0.62
    g.vignette = 0.30; g.vignetteRadius = 1.05
    g.grain = 0.28; g.grainSize = 1.8; g.dither = 1.0; g.chroma = 0.25
  elif name == "night-owl":
    # Dark interiors: Factory basements, Labs, Reserve bunkers, night raids.
    # Exposure and gamma up, toe re-lifted hard, highlight roll-off raised so a
    # flashlight does not blow out the wall in front of you, dither raised
    # because a lifted near-black gradient is where 8-bit banding is worst.
    g.tonemapper = 1;  g.tonemapStrength = 0.75
    g.exposure = 0.55; g.contrast = 0.98;  g.saturation = 0.95
    g.temperature = -0.05; g.tint = 0.0
    g.lift = 0.0; g.gamma = 1.12; g.gain = 1.0
    g.shadows = 0.02; g.highlights = 1.30
    g.sharpness = 0.40; g.clarity = 0.35; g.vibrance = 0.25
    g.shadowDetail = 0.70
    g.bloom = true; g.bloomStrength = 0.15; g.bloomThreshold = 0.85
    g.vignette = 0.05; g.vignetteRadius = 1.0
    g.grain = 0.10; g.grainSize = 1.5; g.dither = 1.5; g.chroma = 0.0
  else:
    discard   # "filmic" is defaultGrade(); "custom" reads the sliders

var gGrade = defaultGrade()
var gPreset = "filmic"

proc loadConfig() =
  gGrade = defaultGrade()
  gGrade.enabled        = setting("enabled").asBool(gGrade.enabled)
  gGrade.raidOnly       = setting("raidOnly").asBool(gGrade.raidOnly)
  gGrade.diag           = setting("diag").asBool(gGrade.diag)

  gPreset = setting("preset").asText(gPreset)
  if gPreset != "custom":
    applyPreset(gGrade, gPreset)
    return
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
  gGrade.clarity        = setting("clarity").asFloat(gGrade.clarity)
  gGrade.vibrance       = setting("vibrance").asFloat(gGrade.vibrance)
  gGrade.shadowDetail   = setting("shadowDetail").asFloat(gGrade.shadowDetail)
  gGrade.grain          = setting("grain").asFloat(gGrade.grain)
  gGrade.grainSize      = setting("grainSize").asFloat(gGrade.grainSize)
  gGrade.dither         = setting("dither").asFloat(gGrade.dither)
  gGrade.chroma         = setting("chroma").asFloat(gGrade.chroma)
  gGrade.bloomThreshold = setting("bloomThreshold").asFloat(gGrade.bloomThreshold)

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
    ",\"clarity\":" & f(g.clarity) &
    ",\"vibrance\":" & f(g.vibrance) &
    ",\"shadowDetail\":" & f(g.shadowDetail) &
    ",\"grain\":" & f(g.grain) &
    ",\"grainSize\":" & f(g.grainSize) &
    ",\"dither\":" & f(g.dither) &
    ",\"chroma\":" & f(g.chroma) &
    ",\"bloomThreshold\":" & f(g.bloomThreshold) &
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
    enumSetting("preset", "Preset", "filmic", presetNames(),
                category = "Preset",
                description = "aowlspt original (native D3D11 post-process). A finished look in one word. While this is anything but `custom` it OWNS every look slider below and they are ignored -- pick `custom` to drive them yourself. neutral = cleanup only; filmic = the default look; cold-clinical = visibility first (no bloom, no vignette, shadows pulled open); warm-cinematic = the screenshot look; night-owl = dark interiors and night raids."),
    boolSetting("enabled", "Enable post-process", true,
                category = "Post-process",
                description = "aowlspt original (native D3D11 post-process). Master switch. Off = the game renders untouched."),
    boolSetting("raidOnly", "Raid only (menu stays stock)", true,
                category = "Post-process",
                description = "aowlspt original (native D3D11 post-process). Grade only in-raid; the menu and 2D UI stay stock. Off = grade everywhere (also needed if you run without the backend, which is what supplies the raid signal)."),
    enumSetting("tonemapper", "Tonemapper", "1", @["0", "1", "2"],
                category = "Tonemap",
                description = "aowlspt original (native D3D11 post-process). 0 none, 1 AgX (filmic, neutral highlights), 2 ACES."),
    floatSetting("tonemapStrength", "Tonemap strength", 0.85,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Tonemap",
                 description = "aowlspt original (native D3D11 post-process). Blend of the tonemap look over the linear image."),
    floatSetting("exposure", "Exposure (EV)", 0.0,
                 lo = -3.0, hi = 3.0, step = 0.05, category = "Tonemap",
                 description = "aowlspt original (native D3D11 post-process). EV bias applied before the tonemap."),
    floatSetting("contrast", "Contrast", 1.05,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Grade",
                 description = "aowlspt original (native D3D11 post-process). Contrast around 18% mid-grey, in linear."),
    floatSetting("saturation", "Saturation", 1.05,
                 lo = 0.0, hi = 2.0, step = 0.01, category = "Grade",
                 description = "aowlspt original (native D3D11 post-process). 0 greyscale, 1 neutral, >1 vivid."),
    floatSetting("temperature", "Temperature", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "White balance",
                 description = "aowlspt original (native D3D11 post-process). Cool (-) to warm (+)."),
    floatSetting("tint", "Tint", 0.0,
                 lo = -1.0, hi = 1.0, step = 0.01, category = "White balance",
                 description = "aowlspt original (native D3D11 post-process). Green (-) to magenta (+)."),
    floatSetting("lift", "Lift (shadows)", 0.0,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Lift, Gamma, Gain",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("gamma", "Gamma (midtones)", 1.0,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Lift, Gamma, Gain",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("gain", "Gain (highlights)", 1.0,
                 lo = 0.5, hi = 1.8, step = 0.01, category = "Lift, Gamma, Gain",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("shadows", "Shadow lift (additive)", 0.0,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Legacy (AgX)",
                 description = "From TarkovGraphics (the original's grade knob), reimplemented in aowlspt's native post-process. Matches the original TarkovGraphics shadow knob."),
    floatSetting("highlights", "Highlight roll-off", 1.1,
                 lo = 0.5, hi = 2.0, step = 0.01, category = "Legacy (AgX)",
                 description = "From TarkovGraphics (the original's grade knob), reimplemented in aowlspt's native post-process. Pre-tonemap highlight compression."),
    floatSetting("sharpness", "Sharpening (CAS)", 0.35,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Sharpen",
      description = "aowlspt original (native D3D11 post-process)."),
    boolSetting("bloom", "Bloom", true, category = "Bloom",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("bloomStrength", "Bloom strength", 0.35,
                 lo = 0.0, hi = 2.0, step = 0.01, category = "Bloom",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("vignette", "Vignette", 0.18,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Vignette",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("vignetteRadius", "Vignette radius", 1.0,
                 lo = 0.5, hi = 1.5, step = 0.01, category = "Vignette",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("clarity", "Clarity (local contrast)", 0.30,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Detail",
                 description = "aowlspt original (native D3D11 post-process). Wide-radius local contrast. This is what makes a flat, hazy frame read as three-dimensional. Costs 4 texture taps; masked to mid-tones so it cannot crush blacks or blow highlights."),
    floatSetting("vibrance", "Vibrance", 0.35,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Grade",
                 description = "aowlspt original (native D3D11 post-process). Saturation weighted by how unsaturated a pixel already is. Gains colour separation without turning foliage neon, which a flat saturation multiplier does. Free (no extra taps)."),
    floatSetting("shadowDetail", "Shadow detail (toe lift)", 0.35,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Grade",
                 description = "aowlspt original (native D3D11 post-process). Re-lifts ONLY the toe after contrast, so raising contrast does not cost you the ability to see a player standing in a doorway. Free."),
    floatSetting("grain", "Film grain", 0.18,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Film",
                 description = "aowlspt original (native D3D11 post-process). Animated, weighted toward the shadows -- where real grain lives and where banding lives. Free."),
    floatSetting("grainSize", "Grain size (px)", 1.5,
                 lo = 1.0, hi = 4.0, step = 0.1, category = "Film",
      description = "aowlspt original (native D3D11 post-process)."),
    floatSetting("dither", "Output dither (LSB)", 1.0,
                 lo = 0.0, hi = 2.0, step = 0.1, category = "Film",
                 description = "aowlspt original (native D3D11 post-process). Triangular-PDF noise at ~1 least-significant bit before the 8-bit write. The cheapest real win here: it is the only thing that kills banding in dark interiors. Leave it on."),
    floatSetting("chroma", "Chromatic aberration", 0.0,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Lens",
                 description = "aowlspt original (native D3D11 post-process). Radial, red/blue only, exactly zero at the screen centre so it never smears what you are aiming at. Off by default. Costs 2 texture taps."),
    floatSetting("bloomThreshold", "Bloom threshold", 0.70,
                 lo = 0.0, hi = 1.0, step = 0.01, category = "Bloom",
                 description = "aowlspt original (native D3D11 post-process). Luma knee for the bright pass. Raise it so only real light sources bloom."),
    boolSetting("diag", "Red-tint diagnostic", false, category = "Debug",
                description = "aowlspt original (native D3D11 post-process). Tints the frame red to confirm the blit lands.")]

proc onSettings(url, body, session: string): string =
  ## GET returns the schema with live values; POST applies one edit to
  ## config.json, re-reads, and re-pushes the grade so the change is visible at
  ## once.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok:
      loadConfig()
      discard pushGrade()
  result = declaredSchemaReply(st).text

proc onSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok:
    loadConfig()
    discard pushGrade()
  result = declaredSchemaReply(st).text

# ---------------------------------------------------------------------------
# Events — apply/reload without a settings round trip
# ---------------------------------------------------------------------------

proc onApplyEvent(payload: string): string =
  loadConfig()
  let ok = pushGrade()
  result = "{\"ok\":" & (if ok: "true" else: "false") & "}"

proc presetOwns(key: string): bool =
  ## Is `key` a look slider that the ACTIVE preset overwrites?
  ##
  ## Derived from `loadConfig`, not guessed: that proc reads `enabled`,
  ## `raidOnly`, `diag` and `preset`, and then -- if the preset is anything but
  ## `custom` -- calls `applyPreset` and RETURNS. Every other key is therefore
  ## read only in the `custom` branch, so storing one while a preset is active
  ## is a write that can never be observed. If a key is ever moved above that
  ## early return in `loadConfig`, add it to this list in the same edit.
  if gPreset == "custom":
    return false
  case key
  of "enabled", "raidOnly", "diag", "preset": result = false
  else: result = true

proc onSettingsHotApply(key: string) =
  ## The hot-apply half of the in-process settings bus (`aowlspt/settings`).
  ## graphics is `sides = {sideClient}`, so its `/aowlspt/settings/<guid>`
  ## route is registered into nothing -- the client host refuses
  ## `route_register`. Without this hook an edit made in F12 would persist to
  ## config.json and not reach the live grade until the next load, which is a
  ## slider that moves and changes nothing. Same two calls the route handler
  ## makes, deliberately: one apply path, not two.
  ##
  ## It must also SAY what it did. Three things here can silently swallow an
  ## edit, and all three used to look identical in the log:
  ##
  ##   1. `enabled` is false -- the whole post-process is off, so a look slider
  ##      changes nothing visible. (The boot line in the session that prompted
  ##      this read `enabled=no`.)
  ##   2. `preset` is anything but `custom` -- `loadConfig` calls `applyPreset`
  ##      and RETURNS, so every look slider below is overwritten by the preset
  ##      and the value just stored is ignored. This is the "I changed
  ##      saturation and nothing happened" report, exactly.
  ##   3. `pushGrade` returned false -- this host carries no post-process
  ##      module, so there is nothing to re-grade.
  loadConfig()
  let pushed = pushGrade()
  if not pushed:
    settingIgnored("this host carries no post-process module, so there is " &
                   "nothing to re-grade; the game renders untouched")
    return
  if presetOwns(key):
    settingIgnored("preset=\"" & gPreset & "\" OWNS this slider -- the value " &
                   "is stored but the preset overwrites it every load. Set " &
                   "Preset to \"custom\" to drive it yourself.")
    return
  if not gGrade.enabled:
    settingIgnored("the post-process master switch (\"enabled\") is off, so " &
                   "the grade is not drawn; the value is stored and takes " &
                   "effect as soon as you enable it")
    return
  settingApplied("grade re-pushed: preset=" & gPreset & " tonemapper=" &
                 $gGrade.tonemapper & " saturation=" & $gGrade.saturation &
                 " contrast=" & $gGrade.contrast & " exposure=" &
                 $gGrade.exposure & " raidOnly=" &
                 (if gGrade.raidOnly: "yes" else: "no"))

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  declareSettings(schema())
  onSettingsApplied(onSettingsHotApply)
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onSettingsReset)
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
