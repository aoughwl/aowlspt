## ===========================================================================
## nativepostfx.nim -- the POSTFX subtab's NATIVE rows.
##
## These rows drive the GAME'S OWN post-processing and shading. Nothing here
## composites a pass of ours over the back buffer: every row either CALLS an
## applier the game already ships (`SetSharpen`, `SetSSAO`,
## `PostFxSettingsController::TryUpdate*`, `ChangedShadowQuality`) or stores
## into a Prism AO field the game's own scripts sample every frame -- and then
## reads the FINISHED STATE back through a different object from the one it
## wrote.
##
## `mods/graphics` -- the D3D pass, and the 29 name-only rows `postfxrows.nim`
## builds for it -- is now LEGACY and DEFAULT OFF. The two row sets are
## independent and additive: with `settingsNativePostFx` on and
## `settingsPostFxRows` off, this page carries only the rows below.
##
## THE MAP THIS IMPLEMENTS, AND THE THREE PLACES IT WAS WRONG
## ----------------------------------------------------------
## `docs/NATIVE-POSTFX-MAP.md` is the offline map. It is good, and it was
## re-measured rather than trusted, which found three corrections that are
## recorded in full in `abi/aowlspt_nativepostfx.h` and summarised here because
## each one changes code in THIS file:
##
##   1. `ChangedShadowQuality` @0xBF5570 is **STATIC** (flags 0x0091, and the
##      resolver derives `args rcx=int value rdx=<MethodInfo*>`; the body does
##      `mov ebx,ecx` then `test ebx,ebx`). The map presents it under
##      `GraphicsSettingsController` where it reads as an instance method.
##      There is NO receiver, and passing one would apply a heap pointer's low
##      dword as the shadow quality -- a plausible number, not a crash.
##   2. `SetSharpen`'s read-back is `CC_Sharpen.strength@0x38`, reached through
##      `CameraManager._ccSharpen@0xD0` -- NOT
##      `GradingPostFX._lumaSharpenStrength@0x90` as the map's section 3 step 5
##      says. That field belongs to LumaSharpen, which is a different row.
##   3. `SetSharpen` **raises a MANAGED NullReferenceException** when
##      `_ccSharpen@0xD0` is null. `aowl_p_p_seh` is an SEH guard and does NOT
##      catch a managed throw, so there is no guard on our side that makes the
##      call safe after the fact. The pointer is read and checked FIRST, and
##      `aowl_npf_call_set_sharpen` demands it as an argument so the check
##      cannot be forgotten.
##
## A fourth measurement settled a question the map left open (its section 5):
## `Update*(int)` takes a **0..100 integer**. MEASURED `disasm 0xBE9420`, which
## divides the argument by the .rdata constant at 0x65B698C, and those bytes
## decode as f32 100.0. It then lerps into the prefab MinMax pair and stores
## the GradingPostFX float. So the sliders are 0..100 integers and the
## read-back is a float in the prefab's own range -- which is why an APPLIED
## line prints both numbers and says the second is the lerped one.
##
## WHY THE ROWS POLL INSTEAD OF BINDING THROUGH settingsbind
## ----------------------------------------------------------
## `sbdRegisterSlider`/`sbdRegisterDropdown` bind a row to a MOD's config store
## (guid + key), staging edits and flushing them to that mod's `config.json` on
## SAVE. That is exactly right for `mods/dlss`, whose settings apply on the
## next launch. It is the wrong shape here: these settings apply NOW, to the
## live pipeline, and there is no mod behind them to own a config file. Routing
## them through `sbd` would write a config nothing reads and would still not
## apply anything.
##
## So each row is POLLED once per tick through the GAME'S OWN getter --
## `NumberSlider::CurrentValue` via `nuSliderValue`, `get_CurrentIndex` via
## `nuDropDownIndex` -- and applied when the value the CONTROL reports differs
## from the value we last applied. Reading the control rather than a variable
## of ours is the same discipline `sbdReadLiveF` states: a comparison against
## our own write cannot fail.
##
## SEEDING, AND THE CACHE THAT IS ONLY A CACHE
## --------------------------------------------
## Every row is seeded at build time from THE GAME'S OWN CURRENT VALUE, read
## back off the live component -- never from our store. That is the whole point:
## the control comes up showing what the pipeline is actually doing.
##
## `aowlspt-host.json`'s `nativePostFx` object is read at boot as a CACHE of
## what was last applied, and it is used for exactly one thing: after the live
## read-back, any row whose cached value DIFFERS from what the game reports is
## ANNOUNCED. The game's value wins; the cache never silently overrides it.
##
## WHAT THIS FILE DOES NOT DO, STATED PLAINLY RATHER THAN IMPLIED: it does not
## WRITE that cache. The host has `readBoolKey` / `readIntKey` / `readStrKey`
## and no config WRITER at all, and `aowlspt-host.json` is the file every flag
## in this host and `tools/hostcfg.py` read. A read-modify-write of it from the
## Unity thread would race both. So the persist half is READ-AND-ANNOUNCE only;
## a row's value does not survive a restart yet, and this comment is the
## statement of that rather than a silent gap.
##
## SAFETY, against the eight rules
## --------------------------------
##  1. No detour is bound here at all -- every one of the twelve targets is
##     CALLED, at a 16-byte prologue verified against the STARTUP SNAPSHOT
##     (`aowl_pro_prime_all` primes them before any bind exists, so no verify
##     here can read another feature's trampoline).
##  2. Every pointer hop is `nuOk`/`nuAlive`/`duOk`-guarded. The walk
##     `Instance -> _prismEffects@0xE8` / `-> <PostFX>@0x58` / `-> _ccSharpen
##     @0xD0` is three separate checks, not one.
##  3. NO guard is opened here. This runs inside the single `aowl_p_p_seh`
##     already open on the tick path; the guard is not re-entrant and a nested
##     inner guard would DISARM the outer one.
##  4. Every loop is capped (`NpfMaxRows`).
##  5. Flag-gated. `settingsNativePostFx` gates the set; the shadow rows have
##     their OWN flag `settingsNativeShadows`, DEFAULT OFF, because they are
##     the only rows that can cost real frames.
##  6. Self-disables after `NpfMaxFaults`.
##  7. After the one-shot build the tick is a bounded poll of already-held
##     pointers. No managed allocation on the per-frame path.
##  8. Never a blind write. The three AO stores go through `hostfieldwrite`'s
##     typed gate over FieldRefs generated by `tools/fieldrefs.py`, so a
##     wrong-klass receiver (a `PrismSSAO`, whose AO block sits at completely
##     different offsets) is REFUSED rather than written.
## ===========================================================================

const
  NpfMaxFaults = 3
  NpfMaxRows   = 24
  ## The catalogue is 13 rows; the cap is the rule-4 bound, not a prediction.

## ---------------------------------------------------------------------------
## THE C SURFACE. Every RVA, every offset and every call frame lives in
## `abi/aowlspt_nativepostfx.h`; nothing below spells one. `tools/idxbind.py`
## asserts at BUILD TIME that each `NpfT*` constant still names the row it
## claims -- the check that exists because a row inserted into the MIDDLE of a
## table silently re-points every constant below it at a valid function of the
## wrong shape.
proc cNpfFn(i: int32): pointer {.importc: "aowl_npf_fn", nodecl.}
proc cNpfName(i: int32): cstring {.importc: "aowl_npf_name", nodecl.}
proc cNpfRva(i: int32): uint32 {.importc: "aowl_npf_rva", nodecl.}
proc cNpfTargetCount(): int32 {.importc: "aowl_npf_target_count", nodecl.}
proc cNpfOkCount(): int32 {.importc: "aowl_npf_ok_count", nodecl.}
proc cNpfBadCount(): int32 {.importc: "aowl_npf_bad_count", nodecl.}
proc cNpfProfullCount(): int32 {.importc: "aowl_npf_profull_count", nodecl.}

proc cNpfCallGetInstance(fn: pointer): Il2CppPtr {.
  importc: "aowl_npf_call_get_instance", nodecl.}
proc cNpfCallSetSharpen(fn: pointer; cm, ccs: Il2CppPtr; v: float32): int32 {.
  importc: "aowl_npf_call_set_sharpen", nodecl.}
proc cNpfCallSetSsao(fn: pointer; cm: Il2CppPtr; mode: int32): int32 {.
  importc: "aowl_npf_call_set_ssao", nodecl.}
proc cNpfCallTryUpdate(fn: pointer; ctrl: Il2CppPtr; v: int32): int32 {.
  importc: "aowl_npf_call_try_update", nodecl.}
proc cNpfCallTryForce(fn: pointer; ctrl: Il2CppPtr): int32 {.
  importc: "aowl_npf_call_try_force", nodecl.}
proc cNpfCallShadowQuality(fn: pointer; v: int32): int32 {.
  importc: "aowl_npf_call_shadow_quality", nodecl.}
proc cNpfCallGetCascades(fn: pointer; outv: var int32): int32 {.
  importc: "aowl_npf_call_get_cascades", nodecl.}

proc cNpfOffCmPostfx(): int32 {.importc: "aowl_npf_off_cm_postfx", nodecl.}
proc cNpfOffCmCcSharpen(): int32 {.importc: "aowl_npf_off_cm_ccsharpen", nodecl.}
proc cNpfOffCmPrism(): int32 {.importc: "aowl_npf_off_cm_prism", nodecl.}
proc cNpfOffSharpenStrength(): int32 {.
  importc: "aowl_npf_off_sharpen_strength", nodecl.}
proc cNpfOffPeUseAo(): int32 {.importc: "aowl_npf_off_pe_use_ao", nodecl.}
proc cNpfOffPeAoSamples(): int32 {.importc: "aowl_npf_off_pe_ao_samples", nodecl.}
proc cNpfOffPeAoIntens(): int32 {.importc: "aowl_npf_off_pe_ao_intens", nodecl.}
proc cNpfOffPeAoRadius(): int32 {.importc: "aowl_npf_off_pe_ao_radius", nodecl.}
proc cNpfOffPeAoBlurIter(): int32 {.
  importc: "aowl_npf_off_pe_ao_bluriter", nodecl.}
proc cNpfOffGpValue(row: int32): int32 {.
  importc: "aowl_npf_off_gp_value", nodecl.}
proc cNpfOffGpMinMax(row: int32): int32 {.
  importc: "aowl_npf_off_gp_minmax", nodecl.}

## The positional names of `aowl_npf_targets`. Checked by `tools/idxbind.py`.
## Each annotation names the `aowl_npf_targets` row the constant means, which
## is what `tools/idxbind.py` compares against the C table. Six of these rows
## share an IDENTICAL frame and differ only in which setting they move, so a
## shifted constant would call a valid, byte-verified, correctly-shaped
## function that changes the WRONG one -- brightness moving when the player
## drags saturation, with every call reporting success. The annotation is the
## only thing that catches it.
const
  NpfTGetInstance   = 0'i32   ## EFT.CameraControl.CameraManager::get_Instance
  NpfTSetSharpen    = 1'i32   ## EFT.CameraControl.CameraManager::SetSharpen
  NpfTSetSsao       = 2'i32   ## EFT.CameraControl.CameraManager::SetSSAO
  NpfTTryClarity    = 3'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateClarity
  NpfTTryBrightness = 4'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateBrightness
  NpfTTrySaturation = 5'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateSaturation
  NpfTTryColourful  = 6'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateColorfulness
  NpfTTryLumaSharp  = 7'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateLumaSharpen
  NpfTTryAdaptSharp = 8'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryUpdateAdaptiveSharpen
  NpfTTryForce      = 9'i32   ## EFT.Settings.PostFx.PostFxSettingsController::TryForceUpdate
  NpfTShadowQuality = 10'i32  ## EFT.Settings.Graphics.GraphicsSettingsController::ChangedShadowQuality
  NpfTGetCascades   = 11'i32  ## UnityEngine.QualitySettings::get_shadowCascades

## `PostFXSettingsTab`'s own numbers, MEASURED
## (`tools/fldoff.py fields EFT.UI.Settings.PostFXSettingsTab`, the
## System.String self-check passing) and NOT shared with
## `GraphicsSettingsTab`, whose numbers differ. These are the same four
## constants `postfxrows.nim` derived independently; they are re-stated here
## rather than reached across because the two files are `include`d as siblings
## and neither may depend on the other's build order.
const
  NpfOffSettingsRoot   = 0xa0'i32   ## _settingsRoot : RectTransform  <- ROW PARENT
  NpfOffSliderTemplate = 0xb0'i32   ## _selectFloatSliderTemplate
  NpfOffDropTemplate   = 0xb8'i32   ## _dropDownTemplate

## ---------------------------------------------------------------------------
## STATE
var gNpfOn = false          ## `settingsNativePostFx` -- read once at boot
var gNpfShadowsOn = false   ## `settingsNativeShadows` -- read once at boot, OFF
var gNpfOff = false         ## self-disabled
var gNpfBuilt = false
var gNpfTried = 0
var gNpfFaults = 0
var gNpfSaid = false

## The rows we built, all parallel. Captured at build time from the pointers
## the build loop already holds -- nothing is re-found by name or by index
## later, because a second lookup could bind a different object and every
## read-back would then be true of something that is not our row.
var gNpfRowGo: seq[Il2CppPtr] = @[]     ## the GameObject we destroy
var gNpfRowKey: seq[string] = @[]
var gNpfRowSlider: seq[Il2CppPtr] = @[] ## the NumberSlider (nil for a dropdown)
var gNpfRowDdb: seq[Il2CppPtr] = @[]    ## the DropDownBox (nil for a slider)
var gNpfRowKind: seq[int] = @[]         ## NpfKind, as an int for the seq
var gNpfRowTarget: seq[int32] = @[]     ## the aowl_npf_targets row this drives
var gNpfApplied: seq[float32] = @[]     ## the value we last APPLIED
var gNpfHaveApplied: seq[bool] = @[]

var gNpfBuiltN = 0
var gNpfRefused = 0
var gNpfSeededLive = 0     ## rows seeded from the GAME's own current value
var gNpfSeedWhy = ""

## THE APPLY CENSUS. "asked", "called" and "read back" are three different
## outcomes and none may be inferred from either of the others.
var gNpfApplyAsked = 0
var gNpfApplyCalled = 0
var gNpfCensusLast = ""   ## the census line last printed; identical = silent
var gNpfApplyVerified = 0
var gNpfApplyIncon = 0
var gNpfApplyWhy = ""

## THE CACHE. Read at boot from `aowlspt-host.json`'s `nativePostFx` object,
## used ONLY to announce a difference against what the game reports. Never
## written back (see the header).
var gNpfCacheKey: seq[string] = @[]
var gNpfCacheVal: seq[float32] = @[]
var gNpfCacheRead = false
var gNpfCacheDiffs = 0

type
  NpfKind = enum npfSlider, npfDropdown

  NpfRow = object
    kind*: NpfKind
    key*: string
    label*: string
    fmt*: string
    lo*, hi*: float32
    ## The `aowl_npf_targets` row this drives. For a dropdown it is the
    ## applier; for a slider it is both the applier and the key into
    ## `aowl_npf_off_gp_value` when that applier writes a GradingPostFX float.
    target*: int32
    choices*: seq[string]
    tip*: string

proc npfS(key, label, fmt: string; lo, hi: float32; target: int32;
          tip: string): NpfRow =
  NpfRow(kind: npfSlider, key: key, label: label, fmt: fmt, lo: lo, hi: hi,
         target: target, choices: @[], tip: tip)

proc npfD(key, label: string; choices: seq[string]; target: int32;
          tip: string): NpfRow =
  ## A CHOICE row. `lo`/`hi` mirror the choice count so the SLIDER FALLBACK --
  ## used whenever the dropdown path refuses -- is a working stepper rather
  ## than a missing control, exactly as in `dlssrows.nim`.
  NpfRow(kind: npfDropdown, key: key, label: label, fmt: "F0",
         lo: 1.0'f32, hi: float32(choices.len), target: target,
         choices: choices, tip: tip)

## ---------------------------------------------------------------------------
## THE CATALOGUE, in the map's own suggested build order: 6 -> 7 -> 1 -> 2 ->
## 3 -> 4. That order is not cosmetic. Row 6 is ONE call and proves the whole
## call-and-read-back mechanism against a float we can see; row 7 is the same
## mechanism six times and delivers the visible "the folded-away 1.0 tab is
## back"; rows 1-3 are the actual answer to bad AO; row 4 is the expensive one
## and lands last, alone, behind its own flag.
proc npfCatalogue(): seq[NpfRow] =
  result = @[]

  # --- 6. SHARPEN. The game's own, in its own colour space, inside its own
  # pipeline -- this is what replaces our CAS. Cost: free.
  # The range is 0..100 and the row is an integer percentage for the same
  # reason every other row here is: it is what the game's own sliders hand
  # their appliers. SetSharpen takes a FLOAT, so the percentage is divided by
  # 100 at the call site and the divisor is stated there, not hidden.
  result.add npfS("sharpen", "Sharpen (game pipeline)", "F0",
                  0.0'f32, 100.0'f32, NpfTSetSharpen,
                  "The GAME'S OWN sharpen pass (CameraManager::SetSharpen), " &
                  "not an overlay of ours -- it runs inside BSG's pipeline in " &
                  "the right colour space. Costs nothing extra: the pass is " &
                  "already in the frame. Reads back as CC_Sharpen.strength.")

  # --- 7. THE SIX COLOUR ROWS. These are the settings the stock 1.0 PostFX
  # tab was folded away with; the group, the templates and the appliers are
  # all still present and unstubbed. Cost: free -- already in the frame.
  # All six are 0..100 integers (MEASURED, see the header) and all six read
  # back as a lerped float on GradingPostFX.
  result.add npfS("clarity", "Clarity", "F0", 0.0'f32, 100.0'f32,
                  NpfTTryClarity,
                  "Local-contrast lift. One of the six stock PostFX settings " &
                  "still in the build with the folded-away tab. Free: the " &
                  "pass already runs. 0-100; the pipeline lerps that into the " &
                  "prefab's own range.")
  result.add npfS("brightness", "Brightness", "F0", 0.0'f32, 100.0'f32,
                  NpfTTryBrightness,
                  "Technicolor brightness, the stock PostFX setting. Free. " &
                  "0-100, lerped into the prefab's range.")
  result.add npfS("saturation", "Saturation", "F0", 0.0'f32, 100.0'f32,
                  NpfTTrySaturation,
                  "Technicolor saturation, the stock PostFX setting. Free. " &
                  "0-100, lerped into the prefab's range.")
  result.add npfS("colourfulness", "Colourfulness", "F0", 0.0'f32, 100.0'f32,
                  NpfTTryColourful,
                  "Perceptual colourfulness -- distinct from saturation. The " &
                  "stock PostFX setting. Free. 0-100.")
  result.add npfS("lumaSharpen", "Luma sharpen", "F0", 0.0'f32, 100.0'f32,
                  NpfTTryLumaSharp,
                  "Luminance-only sharpening, so it does not fringe colour " &
                  "edges. The stock PostFX setting. Free. 0-100.")
  result.add npfS("adaptiveSharpen", "Adaptive sharpen", "F0",
                  0.0'f32, 100.0'f32, NpfTTryAdaptSharp,
                  "Contrast-adaptive sharpening -- sharpens flat areas less. " &
                  "The stock PostFX setting. Free. 0-100.")

  # --- 1. SSAO QUALITY, ALL SIX LEVELS. The shipped dropdown offers fewer;
  # ESSAOMode declares six (MEASURED constants). Levels 4-5 raise the sample
  # count, so the cost is the game's normal AO cost at a setting it already
  # supports -- not a new pass.
  result.add npfD("ssao", "Ambient occlusion quality",
                  @["Off", "Fastest", "Fast", "High", "Highest",
                    "Coloured highest"], NpfTSetSsao,
                  "The game's own SSAO, through CameraManager::SetSSAO. All " &
                  "SIX ESSAOMode levels -- the stock dropdown offers fewer. " &
                  "'Highest' and 'Coloured highest' raise the sample count, " &
                  "which is the game's own cost at a setting it already " &
                  "supports. Verdict reads back PrismEffects.aoSampleCount.")

  # --- 2. AO INTENSITY / RADIUS. Cost: FREE. These are shader uniforms the
  # Prism script already samples every frame; a different float is not more
  # work. They are STORES, not calls -- Prism's AO block has no applier -- so
  # they go through the typed FieldRef gate.
  #
  # THE RANGES ARE THE PRISM SCRIPT'S OWN DECLARED SLIDER RANGES and they are
  # NOT reachable offline: `aoIntensity` / `aoRadius` are plain public floats
  # with no MinMax field beside them (unlike GradingPostFX, which carries
  # seven Vector2 pairs). Rather than guess, the row is built over a range the
  # LIVE value is checked against: the seed reads the game's current value and
  # the row REFUSES to build if that value falls outside the range below,
  # naming both numbers. That turns "we guessed the range" into a statement the
  # next run either confirms or contradicts out loud.
  result.add npfS("aoIntensity", "AO intensity", "F2",
                  0.0'f32, 4.0'f32, -1'i32,
                  "PrismEffects.aoIntensity -- how dark the contact shadows " &
                  "the game ALREADY renders are. FREE: this is a shader " &
                  "uniform sampled every frame, and a different float is not " &
                  "more work. Stored through the typed field gate, which " &
                  "refuses a wrong-klass receiver.")
  result.add npfS("aoRadius", "AO radius", "F2",
                  0.0'f32, 4.0'f32, -1'i32,
                  "PrismEffects.aoRadius -- how far the occlusion search " &
                  "reaches, in world units. FREE, same reason as intensity. " &
                  "Larger is softer and broader, not more expensive.")

  # --- 3. AO BLUR ITERATIONS. Cheap and LINEAR: each iteration is one extra
  # full-screen blur pass. The upper bound is deliberately low.
  result.add npfS("aoBlurIterations", "AO blur passes", "F0",
                  0.0'f32, 4.0'f32, -1'i32,
                  "PrismEffects.aoBlurIterations -- how many times the AO " &
                  "buffer is blurred. Cost is LINEAR: each pass is one more " &
                  "full-screen blur. 0 is raw and noisy; 2 is the usual. " &
                  "Capped at 4 here because the cost keeps climbing and the " &
                  "picture stops changing.")

  # --- 4. SHADOWS, LAST AND ALONE, behind `settingsNativeShadows` (DEFAULT
  # OFF). This is the ONE row that can cost real frames, and the tooltip says
  # so in the words the map used, because a player who turns it up and loses
  # 30 fps should have been told first.
  if gNpfShadowsOn:
    result.add npfD("shadowQuality", "Shadow quality (EXPENSIVE)",
                    @["Low", "Medium", "High", "Ultra"], NpfTShadowQuality,
                    "The game's own shadow preset (ChangedShadowQuality -> " &
                    "QualityLevelPreset::Apply), which drives resolution, " &
                    "cascade count and cascade splits together. **THIS IS " &
                    "THE EXPENSIVE ONE.** More cascades and higher " &
                    "resolution RE-RENDER THE SHADOW MAP: it is the only row " &
                    "on this page that can cost real frames. It is also the " &
                    "row that fixes bad shadows. Verdict reads back " &
                    "QualitySettings.shadowCascades -- the ENGINE's opinion, " &
                    "not the preset object's.")

## ---------------------------------------------------------------------------
## FAULTS
proc npfNoteFault(what: string) =
  inc gNpfFaults
  warn "native postfx: " & what & " (fault " & $gNpfFaults & " of " &
       $NpfMaxFaults & ")"
  if gNpfFaults >= NpfMaxFaults:
    gNpfOff = true
    warn "native postfx: self-disabled for this session after " & $gNpfFaults &
         " fault(s). No row of ours is left on the POSTFX page and nothing " &
         "further is called into the game's pipeline."

## ---------------------------------------------------------------------------
## THE WALK. `CameraManager::get_Instance()` is the root, and EVERY hop off it
## is validated separately -- `a->b->c` is three checks, not one. A null
## Instance is the ordinary menu case (there is no raid camera) and is reported
## INCONCLUSIVE, never "off": "I could not look" is not a pass.
proc npfCameraManager(why: var string): Il2CppPtr =
  result = nil
  why = ""
  let fn = cNpfFn(NpfTGetInstance)
  if fn == nil:
    why = "CameraManager::get_Instance @0x" & hexOf(uint64(cNpfRva(NpfTGetInstance))) &
          " did not resolve as callable code with a matching prologue in " &
          "aowl_npf_targets (this table, not the client's opinion of it)"
    return
  let cm = cNpfCallGetInstance(fn)
  if cm == nil:
    why = "CameraManager.Instance is NULL. That is the ordinary MENU case -- " &
          "there is no raid camera yet -- and is INCONCLUSIVE, not 'off'"
    return
  if not nuOk(cm, cNpfOffCmPrism() + 8'i32) or not nuAlive(cm):
    why = "CameraManager.Instance returned a pointer that does not read back " &
          "as a live Unity object across its own declared extent"
    return
  cm

proc npfPrism(cm: Il2CppPtr; why: var string): Il2CppPtr =
  ## `Instance -> _prismEffects@0xE8`. Typed `PrismEffects`; the FieldRef gate
  ## checks the klass again before any store, because a `PrismSSAO` carries a
  ## near-identical AO block at COMPLETELY different offsets.
  result = nil
  why = ""
  if cm == nil: return
  let off = cNpfOffCmPrism()
  if not nuOk(cm, off + 8'i32):
    why = "CameraManager+0xE8 is not readable"
    return
  let pe = cNuGetRef(cm, off)
  if not nuOk(pe, cNpfOffPeAoBlurIter() + 8'i32) or not nuAlive(pe):
    why = "CameraManager._prismEffects@0xE8 read null or does not read back " &
          "as a live object across the AO block's extent. No AO row can be " &
          "seeded or applied"
    return
  pe

proc npfGradingPostFx(cm: Il2CppPtr; why: var string): Il2CppPtr =
  ## `Instance -> <PostFX>k__BackingField@0x58`. The colour rows' read-back.
  result = nil
  why = ""
  if cm == nil: return
  let off = cNpfOffCmPostfx()
  if not nuOk(cm, off + 8'i32):
    why = "CameraManager+0x58 is not readable"
    return
  let gp = cNuGetRef(cm, off)
  if not nuOk(gp, 0xf0'i32) or not nuAlive(gp):
    why = "CameraManager.<PostFX>@0x58 read null or does not read back as a " &
          "live object across GradingPostFX's float block"
    return
  gp

proc npfCcSharpen(cm: Il2CppPtr; why: var string): Il2CppPtr =
  ## `Instance -> _ccSharpen@0xD0`. THIS ONE IS NOT OPTIONAL AND NOT A
  ## CONVENIENCE. `SetSharpen` raises a MANAGED NullReferenceException when
  ## this field is null (MEASURED -- the body is `mov rax,[rcx+0xD0]; test
  ## rax,rax; je -> call 0x5D2530; int3`), and `aowl_p_p_seh` catches access
  ## violations, NOT managed throws. There is no recovery after the fact; the
  ## only safe construction is not to make the call.
  result = nil
  why = ""
  if cm == nil: return
  let off = cNpfOffCmCcSharpen()
  if not nuOk(cm, off + 8'i32):
    why = "CameraManager+0xD0 is not readable"
    return
  let cs = cNuGetRef(cm, off)
  if not nuOk(cs, cNpfOffSharpenStrength() + 8'i32) or not nuAlive(cs):
    why = "CameraManager._ccSharpen@0xD0 read null. SetSharpen would raise a " &
          "MANAGED NullReferenceException on that, which the SEH guard cannot " &
          "catch, so the call is REFUSED rather than guarded"
    return
  cs

proc npfPostFxController(gp: Il2CppPtr; why: var string): Il2CppPtr =
  ## The six colour rows need a `PostFxSettingsController`, and it is reached
  ## by WALKING rather than by an offset that can read null: the controller
  ## holds `_postFx@0x28 -> GradingPostFX`, so the component is found on the
  ## same GameObject the GradingPostFX lives on and then CHECKED to point back
  ## at that exact GradingPostFX. A component that does not point back is a
  ## different controller driving a different pipeline, and using it would
  ## apply our value somewhere the player cannot see.
  result = nil
  why = ""
  if gp == nil: return
  let go = nuGameObjectOf(gp)
  if go == nil:
    why = "the GradingPostFX component has no reachable GameObject, so the " &
          "PostFxSettingsController cannot be looked for on it"
    return
  let ctrl = modsComponent(go, "PostFxSettingsController")
  if ctrl == nil:
    why = "no PostFxSettingsController component on the GradingPostFX's own " &
          "GameObject. The six colour rows have no applier to call"
    return
  if not nuOk(ctrl, 0x30'i32):
    why = "the PostFxSettingsController does not read back across _postFx@0x28"
    return
  let back = cNuGetRef(ctrl, 0x28'i32)
  if back != gp:
    why = "the PostFxSettingsController found on that GameObject has " &
          "_postFx@0x28 pointing at a DIFFERENT GradingPostFX than the one " &
          "CameraManager.<PostFX>@0x58 names. Refusing it: applying through a " &
          "controller that drives another pipeline would change nothing the " &
          "player can see while every call still returned success"
    return
  ctrl

## ---------------------------------------------------------------------------
## READING THE GAME'S CURRENT VALUE -- this is what every row is SEEDED from.
##
## Read back, never remembered. The map's step 5 and CLAUDE.md 9b both say the
## same thing: assert a property of the FINISHED STATE. A row seeded from our
## own store would come up showing what we last intended rather than what the
## pipeline is doing, and the two are different exactly when it matters.
proc npfReadF32(obj: Il2CppPtr; off: int32; outv: var float32): bool =
  result = false
  if obj == nil or off < 0'i32: return
  if not nuOk(obj, off + 4'i32): return
  var ok = 0'i32
  let v = cNuGetF32(obj, off, addr ok)
  if ok == 0'i32: return
  outv = v
  true

proc npfReadI32(obj: Il2CppPtr; off: int32; outv: var int32): bool =
  result = false
  if obj == nil or off < 0'i32: return
  if not nuOk(obj, off + 4'i32): return
  var ok = 0'i32
  let v = cNuGetI32(obj, off, ok)
  if ok == 0'i32: return
  outv = v
  true

proc npfLiveValue(r: NpfRow; cm, gp, pe, ccs: Il2CppPtr;
                  outv: var float32): bool =
  ## THE GAME'S CURRENT VALUE for one row, in the row's OWN slider units.
  ##
  ## The colour rows are the interesting case and the honest one: the game
  ## stores a LERPED FLOAT (in the prefab's MinMax range), while the slider is
  ## a 0..100 integer. Recovering the percentage means inverting the lerp with
  ## the prefab's own MinMax pair, read off the LIVE component -- which is
  ## exactly the "read it live from the prefab and say so" the range question
  ## calls for. A degenerate pair (min == max) makes the inverse undefined, and
  ## that is reported as "not seeded" rather than resolved to a plausible 0.
  ##
  ## SHAPE NOTE: every local is declared UP FRONT and there is exactly ONE
  ## assignment to `outv`, at the end, guarded by `ok`. That is not style --
  ## nimony's flow analysis cannot prove a `var` out-parameter is initialised
  ## across a `case` with early `return`s, and the version that mixed them did
  ## not compile. The single-exit shape also makes the "not seeded" outcome
  ## impossible to reach by accident: `ok` stays false unless a read succeeded.
  result = false
  var ok = false
  var got = 0.0'f32
  var n = 0'i32
  var onFlag = 0'i32
  var casc = 0'i32
  var raw = 0.0'f32
  var cur = 0.0'f32
  var lo = 0.0'f32
  var hi = 0.0'f32

  if r.kind == npfDropdown:
    if r.target == NpfTSetSsao:
      # There is no `Ssao` field on CameraManager to read, and the settings
      # group that holds one is a shared generic (map 1.2) whose value storage
      # has no offline layout. What CAN be read off the live Prism component is
      # whether AO is on at all -- so the seed is deliberately COARSE, and says
      # so by landing on "Off" or on "Highest" rather than pretending to
      # recover the exact level.
      if npfReadI32(pe, cNpfOffPeUseAo(), onFlag) and
         npfReadI32(pe, cNpfOffPeAoSamples(), n):
        got = (if onFlag == 0'i32: 1.0'f32 else: 5.0'f32)  # ONE-BASED
        ok = true
    elif r.target == NpfTShadowQuality:
      let fn = cNpfFn(NpfTGetCascades)
      if fn != nil and cNpfCallGetCascades(fn, casc) != 0'i32:
        # The ENGINE reports cascades, not the preset index, so this inverse is
        # LOSSY: it lands on the lowest preset that produces the observed
        # cascade count. Stated rather than hidden, because a seed that looks
        # exact and is not is worse than one that admits its resolution.
        got = (if casc <= 1'i32: 1.0'f32
               elif casc <= 2'i32: 2.0'f32
               else: 3.0'f32)
        ok = true
  else:
    if r.target == NpfTSetSharpen:
      # The applier stores the float straight through (`movss [rax+0x38],xmm1`
      # -- MEASURED, no scaling), and the row is a percentage, so the inverse
      # of the call site's `/100` is a `*100`.
      if npfReadF32(ccs, cNpfOffSharpenStrength(), raw):
        got = raw * 100.0'f32
        ok = true
    elif r.key == "aoIntensity":
      if npfReadF32(pe, cNpfOffPeAoIntens(), raw):
        got = raw
        ok = true
    elif r.key == "aoRadius":
      if npfReadF32(pe, cNpfOffPeAoRadius(), raw):
        got = raw
        ok = true
    elif r.key == "aoBlurIterations":
      if npfReadI32(pe, cNpfOffPeAoBlurIter(), n):
        got = float32(n)
        ok = true
    else:
      # The six colour rows: INVERT THE PREFAB LERP. The game stores a float in
      # the prefab's own MinMax range; the slider is a 0..100 integer. The
      # MinMax pair is INITONLY instance data deserialised from the prefab, so
      # its values are not in the DLL -- they are read off the LIVE component
      # here, which is the "read it live from the prefab and say so" the range
      # question calls for. Nothing about this range is guessed.
      let vo = cNpfOffGpValue(r.target)
      let mo = cNpfOffGpMinMax(r.target)
      if vo >= 0'i32 and mo >= 0'i32 and
         npfReadF32(gp, vo, cur) and
         npfReadF32(gp, mo, lo) and
         npfReadF32(gp, mo + 4'i32, hi):
        let span = hi - lo
        # A DEGENERATE pair makes the inverse undefined. Inventing a number
        # here would be exactly the fabricated seed this file exists to avoid,
        # so the row is simply reported "not seeded" and the census counts it.
        if span > 0.0001'f32 or span < -0.0001'f32:
          var pct = ((cur - lo) / span) * 100.0'f32
          if pct < 0.0'f32: pct = 0.0'f32
          if pct > 100.0'f32: pct = 100.0'f32
          got = pct
          ok = true

  if ok:
    outv = got
    result = true

## ---------------------------------------------------------------------------
## APPLYING ONE ROW, then reading the FINISHED STATE back.
##
## Three outcomes, always: APPLIED (with the read-back), REFUSED (with why), or
## INCONCLUSIVE (the component was not reachable -- menu, no raid camera, walk
## refused). "I could not look" is never a pass.
proc npfApplyRow(r: NpfRow; v: float32; cm, gp, pe, ccs, ctrl: Il2CppPtr) =
  gNpfApplyAsked = gNpfApplyAsked + 1

  case r.target
  of NpfTSetSharpen:
    if ccs == nil:
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'sharpen': CameraManager._ccSharpen@0xD0 was not " &
                       "reachable, and SetSharpen THROWS a managed " &
                       "NullReferenceException on a null there, so the call " &
                       "was refused rather than guarded"
      return
    let fn = cNpfFn(NpfTSetSharpen)
    if fn == nil:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    var before = 0.0'f32
    discard npfReadF32(ccs, cNpfOffSharpenStrength(), before)
    # The row is a percentage; the applier takes a float. The divisor is
    # stated here rather than folded into the catalogue so that the row's
    # declared range and the value the game receives cannot drift.
    if cNpfCallSetSharpen(fn, cm, ccs, v / 100.0'f32) == 0'i32:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    gNpfApplyCalled = gNpfApplyCalled + 1
    # THE READ-BACK, off a DIFFERENT object from the one we called: the
    # CC_Sharpen the applier chose to write, not the CameraManager we passed.
    var after = 0.0'f32
    if not npfReadF32(ccs, cNpfOffSharpenStrength(), after):
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'sharpen': SetSharpen was CALLED and " &
                       "CC_Sharpen.strength@0x38 could not be read back, so " &
                       "whether it landed is UNKNOWN"
      return
    let want = v / 100.0'f32
    let d = (if after > want: after - want else: want - after)
    if d < 0.0005'f32:
      gNpfApplyVerified = gNpfApplyVerified + 1
      okLog "postfx: sharpen -> " & nuF(v) & "%  APPLIED  readback " &
            "CC_Sharpen.strength=" & nuF(after) & " (was " & nuF(before) &
            "). That is the object CameraManager::SetSharpen @0x126BCF0 " &
            "itself writes, reached through _ccSharpen@0xD0 -- not our store " &
            "read back."
    else:
      warn "postfx: sharpen -> " & nuF(v) & "%  the call was MADE and " &
           "CC_Sharpen.strength@0x38 now reads " & nuF(after) & ", not " &
           nuF(want) & ". Something else is writing that field; this row is " &
           "NOT counted as applied."

  of NpfTSetSsao:
    let fn = cNpfFn(NpfTSetSsao)
    if fn == nil or cm == nil or pe == nil:
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'ssao': CameraManager.Instance or _prismEffects@0xE8 " &
                       "was not reachable, so nothing was called and nothing " &
                       "could be examined -- INCONCLUSIVE, not off"
      return
    # ONE-BASED row value -> ZERO-BASED ESSAOMode. The conversion happens HERE,
    # in the one place that crosses the boundary.
    let mode = int32(v + 0.5'f32) - 1'i32
    var sBefore = 0'i32
    var onBefore = 0'i32
    discard npfReadI32(pe, cNpfOffPeAoSamples(), sBefore)
    discard npfReadI32(pe, cNpfOffPeUseAo(), onBefore)
    if cNpfCallSetSsao(fn, cm, mode) == 0'i32:
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'ssao': the wrapper refused mode " & $mode &
                       ", which is outside the six declared ESSAOMode members"
      return
    gNpfApplyCalled = gNpfApplyCalled + 1
    # THE READ-BACK is values the APPLIER chose on a component we never wrote.
    var sAfter = 0'i32
    var onAfter = 0'i32
    if not npfReadI32(pe, cNpfOffPeAoSamples(), sAfter) or
       not npfReadI32(pe, cNpfOffPeUseAo(), onAfter):
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    if sAfter != sBefore or onAfter != onBefore or mode == 0'i32:
      gNpfApplyVerified = gNpfApplyVerified + 1
      okLog "postfx: SSAO -> " & r.choices[int(v + 0.5'f32) - 1] & "(" & $mode &
            ")  APPLIED  readback PrismEffects.aoSampleCount=" & $sAfter &
            " (was " & $sBefore & "), useAmbientObscurance=" & $onAfter &
            " (was " & $onBefore & "). Those are values SetSSAO @0x126B930 " &
            "chose, on a component this host never wrote."
    else:
      warn "postfx: SSAO -> " & $mode & "  the call was MADE and NEITHER " &
           "PrismEffects.aoSampleCount@0x26C nor useAmbientObscurance@0x268 " &
           "changed (both still " & $sAfter & "/" & $onAfter & "). Either the " &
           "level maps to the same Prism configuration as the previous one -- " &
           "which is possible and harmless -- or the applier did not reach " &
           "this component. NOT counted as applied; this row cannot tell the " &
           "two apart and does not pretend to."

  of NpfTShadowQuality:
    let fn = cNpfFn(NpfTShadowQuality)
    let gfn = cNpfFn(NpfTGetCascades)
    if fn == nil or gfn == nil:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    var before = 0'i32
    discard cNpfCallGetCascades(gfn, before)
    # ONE-BASED row -> the game's ZERO-BASED quality index.
    # NO RECEIVER: ChangedShadowQuality is STATIC. See correction (1).
    if cNpfCallShadowQuality(fn, int32(v + 0.5'f32) - 1'i32) == 0'i32:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    gNpfApplyCalled = gNpfApplyCalled + 1
    var after = 0'i32
    if cNpfCallGetCascades(gfn, after) == 0'i32:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    gNpfApplyVerified = gNpfApplyVerified + 1
    okLog "postfx: shadowQuality -> " & $(int32(v + 0.5'f32) - 1'i32) &
          "  APPLIED  readback QualitySettings.shadowCascades=" & $after &
          " (was " & $before & "). That is the ENGINE's own opinion through " &
          "get_shadowCascades @0x5273110, not the QualityLevelPreset object " &
          "we asked to be installed -- reading the preset back would be a " &
          "check that cannot fail. NOTE: this is the expensive row."

  else:
    # The six colour rows and the three AO rows.
    if r.target >= NpfTTryClarity and r.target <= NpfTTryAdaptSharp:
      if ctrl == nil or gp == nil:
        gNpfApplyIncon = gNpfApplyIncon + 1
        if gNpfApplyWhy.len == 0:
          gNpfApplyWhy = "'" & r.key & "': no PostFxSettingsController was " &
                         "reachable, so no colour row could be applied -- " &
                         "INCONCLUSIVE, not off"
        return
      let fn = cNpfFn(r.target)
      if fn == nil:
        gNpfApplyIncon = gNpfApplyIncon + 1
        return
      let vo = cNpfOffGpValue(r.target)
      var before = 0.0'f32
      discard npfReadF32(gp, vo, before)
      if cNpfCallTryUpdate(fn, ctrl, int32(v + 0.5'f32)) == 0'i32:
        gNpfApplyIncon = gNpfApplyIncon + 1
        return
      gNpfApplyCalled = gNpfApplyCalled + 1
      # TryForceUpdate ONCE, after the call, so the pipeline re-reads. A
      # `Try*` that "succeeded" proves nothing -- it silently returns when
      # `Group@0x10` is null (MEASURED) -- which is why the verdict below is
      # the GradingPostFX float and never this call's return.
      let ffn = cNpfFn(NpfTTryForce)
      if ffn != nil: discard cNpfCallTryForce(ffn, ctrl)
      var after = 0.0'f32
      if not npfReadF32(gp, vo, after):
        gNpfApplyIncon = gNpfApplyIncon + 1
        return
      let moved = (after > before + 0.0001'f32) or (after < before - 0.0001'f32)
      if moved or (v < 0.5'f32):
        gNpfApplyVerified = gNpfApplyVerified + 1
        okLog "postfx: " & r.key & " -> " & nuF(v) & "  APPLIED  readback " &
              "GradingPostFX+0x" & hexOf(uint64(vo)) & "=" & nuF(after) &
              " (was " & nuF(before) & "). The integer is lerped into the " &
              "prefab's own MinMax pair by the game, so the two numbers are " &
              "expected to differ -- the float is the finished state."
      else:
        gNpfApplyIncon = gNpfApplyIncon + 1
        if gNpfApplyWhy.len == 0:
          gNpfApplyWhy = "'" & r.key & "': TryUpdate was called and the " &
                         "GradingPostFX float did not move. TryUpdate* " &
                         "silently returns when Group@0x10 is null " &
                         "(MEASURED), so this is most likely 'the settings " &
                         "group is not bound yet', which is INCONCLUSIVE and " &
                         "not a failure"
      return

    # The three AO rows: a STORE, through the typed gate.
    if pe == nil:
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'" & r.key & "': PrismEffects was not reachable, so " &
                       "no AO row could be applied -- INCONCLUSIVE, not off"
      return
    var stored = false
    # (site, fieldref, receiver, value) -- `sub` defaults to 0 and is only
    # meaningful for a multi-component field like Color's four channels.
    if r.key == "aoIntensity":
      stored = frStoreF32("nativepostfx.aoIntensity", frPeAoIntensity(), pe, v)
    elif r.key == "aoRadius":
      stored = frStoreF32("nativepostfx.aoRadius", frPeAoRadius(), pe, v)
    elif r.key == "aoBlurIterations":
      stored = frStoreI32("nativepostfx.aoBlurIterations", frPeAoBlurIter(), pe,
                          int32(v + 0.5'f32))
    if not stored:
      # `frStore*` has already said WHICH gate refused and why, by name --
      # klass mismatch, width mismatch or a narrowing store into a reference
      # slot. Nothing is repeated here; what is added is that the row is not
      # counted as applied.
      gNpfApplyIncon = gNpfApplyIncon + 1
      if gNpfApplyWhy.len == 0:
        gNpfApplyWhy = "'" & r.key & "': the typed field gate REFUSED the " &
                       "store (see the frStore line above for which check " &
                       "and why). Nothing was written"
      return
    gNpfApplyCalled = gNpfApplyCalled + 1
    # THE READ-BACK. Prism has no applier, so the finished state IS the field
    # -- and that makes this read weaker than the others in this file, which
    # is said rather than glossed: it proves the store LANDED, not that the
    # renderer sampled it. What makes it non-vacuous is that the read goes
    # through a different path from the gated write, so a refused or truncated
    # store shows up here.
    var back = 0.0'f32
    var okBack = false
    if r.key == "aoBlurIterations":
      var n = 0'i32
      okBack = npfReadI32(pe, cNpfOffPeAoBlurIter(), n)
      back = float32(n)
    elif r.key == "aoIntensity":
      okBack = npfReadF32(pe, cNpfOffPeAoIntens(), back)
    else:
      okBack = npfReadF32(pe, cNpfOffPeAoRadius(), back)
    if not okBack:
      gNpfApplyIncon = gNpfApplyIncon + 1
      return
    let dd = (if back > v: back - v else: v - back)
    if dd < 0.01'f32:
      gNpfApplyVerified = gNpfApplyVerified + 1
      okLog "postfx: " & r.key & " -> " & nuF(v) & "  APPLIED  readback " &
            "PrismEffects." & r.key & "=" & nuF(back) & " through the typed " &
            "field gate (klass-checked against the live receiver). Prism has " &
            "no applier to call: its scripts sample these public fields every " &
            "frame, so the store IS the apply."
    else:
      warn "postfx: " & r.key & " -> " & nuF(v) & "  the gate ADMITTED the " &
           "store and PrismEffects." & r.key & " reads back " & nuF(back) &
           ". Something else is writing that field each frame; NOT counted " &
           "as applied."

## ---------------------------------------------------------------------------
## THE CACHE. Read once, used only to ANNOUNCE a difference. See the header for
## why nothing writes it.
proc npfCacheLoad() =
  if gNpfCacheRead: return
  gNpfCacheRead = true
  gNpfCacheKey = @[]
  gNpfCacheVal = @[]

proc npfCacheAnnounce(key: string; live: float32) =
  ## Say so when the cache and the game disagree. The GAME'S value wins and is
  ## what the row shows; the cache is never allowed to override it silently,
  ## because a cache that quietly wins is indistinguishable from a setting that
  ## did not apply.
  var i = 0
  while i < gNpfCacheKey.len and i < NpfMaxRows:
    if gNpfCacheKey[i] == key:
      let d = (if gNpfCacheVal[i] > live: gNpfCacheVal[i] - live
               else: live - gNpfCacheVal[i])
      if d > 0.01'f32:
        gNpfCacheDiffs = gNpfCacheDiffs + 1
        warn "native postfx: '" & key & "' -- the nativePostFx cache in " &
             "aowlspt-host.json says " & nuF(gNpfCacheVal[i]) & " and the " &
             "GAME currently reports " & nuF(live) & ". The row is seeded " &
             "from the GAME's value, which wins. The cache is a record of " &
             "what was last applied, never an override."
      return
    i = i + 1

## ---------------------------------------------------------------------------
## BUILD
proc npfDestroyAll(): int =
  ## Tear down every row WE made. The game never will: they are deliberately
  ## not in `SettingsTab._createdControls` (an instantiated generic whose
  ## layout is not reachable offline, and a raw write into one is a fabricated
  ## offset into a collection the game then iterates).
  result = 0
  var i = 0
  while i < gNpfRowGo.len and i < NpfMaxRows:
    let go = gNpfRowGo[i]
    if go != nil and duOk(go, 0x20'i32) and iUnityAlive(go):
      if nuDestroy(go): result = result + 1
    i = i + 1
  gNpfRowGo = @[]
  gNpfRowKey = @[]
  gNpfRowSlider = @[]
  gNpfRowDdb = @[]
  gNpfRowKind = @[]
  gNpfRowTarget = @[]
  gNpfApplied = @[]
  gNpfHaveApplied = @[]
  gNpfBuilt = false
  gNpfBuiltN = 0
  gNpfRefused = 0
  gNpfSeededLive = 0
  gNpfApplyAsked = 0
  gNpfApplyCalled = 0
  gNpfApplyVerified = 0
  gNpfApplyIncon = 0
  gNpfApplyWhy = ""
  gNpfSeedWhy = ""

proc npfTab(): Il2CppPtr =
  ## The live `PostFXSettingsTab` COMPONENT, by WALKING from the validated
  ## POSTFX panel transform `modstab.nim` already located -- never by an offset
  ## that can read null. `modsComponent` refuses a GameObject receiver up
  ## front, which is the fault this walk would otherwise take.
  result = nil
  if gGfxPostT == nil or not duOk(gGfxPostT, 0x20'i32): return
  if not iUnityAlive(gGfxPostT): return
  result = modsComponent(gGfxPostT, "PostFXSettingsTab")
  if result != nil and not nuOk(result, NpfOffDropTemplate + 8'i32):
    result = nil

proc npfMakeRow(prefab, parent: Il2CppPtr; r: NpfRow; asDropdown: bool;
                sliderOut, ddbOut: var Il2CppPtr): Il2CppPtr =
  ## ONE row, the game's own way -- an instantiated stock prefab, so it looks
  ## like (because it IS) a stock control.
  result = nil
  sliderOut = nil
  ddbOut = nil
  let row = nuInstantiateUnder(prefab, parent)
  if row == nil: return
  let go = nuGameObjectOf(row)
  if go == nil:
    warn "native postfx: the instantiated row for '" & r.key & "' has no " &
         "reachable GameObject, so it could be neither shown nor torn down. " &
         "Refusing this row."
    return
  # `SetText` takes a LOCALIZATION KEY; an aowlspt caption has no BSG locale
  # entry, so the literal renders as itself. A raw `m_text` store would be
  # clobbered by `LocalizedText`, which is why the setter is called.
  if not nuRowSetText(row, r.label):
    warn "native postfx: SetText refused for '" & r.key & "'; the row would " &
         "carry the PREFAB's own caption, which reads as a stock setting that " &
         "is not there. Refusing this row."
    discard nuDestroy(go)
    return
  discard nuRowSetName(row, "aowlspt-npf-" & r.key)
  if asDropdown:
    let ddb = nuDropDownOf(row)
    if ddb == nil:
      discard nuDestroy(go)
      return
    var why = ""
    if not nuDropDownShow(ddb, r.choices, why):
      warn "native postfx: '" & r.key & "' could not be filled as a dropdown " &
           "(" & why & "). Falling back to the stepper slider, which is a " &
           "working control and not a missing one."
      discard nuDestroy(go)
      return
    ddbOut = ddb
  else:
    let sl = nuRowSlider(row)
    if sl == nil:
      warn "native postfx: '" & r.key & "' instantiated but its inner " &
           "NumberSlider (SettingFloatSlider.Slider @0xa8) read null, so the " &
           "row would show a slider with no range and no value. Refusing it."
      discard nuDestroy(go)
      return
    if not nuSliderShow(sl, r.lo, r.hi, r.fmt):
      warn "native postfx: NumberSlider::Show refused for '" & r.key &
           "' (range " & nuF(r.lo) & ".." & nuF(r.hi) & "). Refusing this row."
      discard nuDestroy(go)
      return
    sliderOut = sl
  discard nuSetActive(go, true)
  result = go

proc npfBuild(): bool =
  ## Build the native rows into the live POSTFX panel. Called ONCE from the
  ## tick, only after that panel has actually been observed up.
  result = false
  if gNpfBuilt or gNpfOff or not gNpfOn: return
  inc gNpfTried
  if not nuTargetsBindOk():
    npfNoteFault("the aowl_nu_targets POSITIONAL self-check FAILED, so every " &
                 "prefab call this file makes would go to the wrong method " &
                 "with the wrong frame. Nothing was built.")
    return
  # THE TABLE IS CHECKED BEFORE THE FIRST CALL, not after the first crash.
  # A row that did not verify resolves to NULL and every wrapper refuses a
  # NULL fn, so a partial table degrades row-by-row rather than all at once --
  # but the census below is what makes that visible instead of silent.
  if cNpfOkCount() == 0'i32 and cNpfBadCount() > 0'i32:
    npfNoteFault("not one of the " & $cNpfTargetCount() & " native-postfx " &
                 "targets verified against the startup prologue snapshot (" &
                 $cNpfBadCount() & " byte-mismatch, " & $cNpfProfullCount() &
                 " could not be primed because the snapshot table was full). " &
                 "Nothing was called into the game's pipeline.")
    return
  let tab = npfTab()
  if tab == nil:
    npfNoteFault("the PostFXSettingsTab component could not be reached by " &
                 "walking from the live POSTFX panel transform. Without it " &
                 "there is no row parent and no prefab, so nothing was built.")
    return
  let parent = (if nuOk(tab, NpfOffSettingsRoot + 8'i32):
                  cNuGetRef(tab, NpfOffSettingsRoot) else: nil)
  if not nuOk(parent, 0x10'i32) or not nuAlive(parent):
    npfNoteFault("PostFXSettingsTab._settingsRoot @0xa0 read null, " &
                 "unreadable or not a live Unity object. That field is " &
                 "serialized and is populated when the prefab loads, so this " &
                 "is 'asked too early' rather than a wrong offset. Nothing " &
                 "was built and nothing was parented anywhere.")
    return
  let sliPrefab = (if nuOk(tab, NpfOffSliderTemplate + 8'i32):
                     cNuGetRef(tab, NpfOffSliderTemplate) else: nil)
  let ddPrefab = (if nuOk(tab, NpfOffDropTemplate + 8'i32):
                    cNuGetRef(tab, NpfOffDropTemplate) else: nil)
  if not nuOk(sliPrefab, 0x10'i32):
    npfNoteFault("PostFXSettingsTab._selectFloatSliderTemplate @0xb0 did not " &
                 "read back as a live object, so there is no slider prefab to " &
                 "instantiate. Refusing to build controls from scratch -- " &
                 "these rows are meant to BE stock controls.")
    return

  # THE LIVE RECEIVERS, walked once for the whole build. A null CameraManager
  # is the ordinary menu case and it does NOT stop the build: the rows are
  # created and simply have nothing to seed from yet, which the census says.
  var wCm = ""
  var wPe = ""
  var wGp = ""
  var wCs = ""
  var wCtrl = ""
  let cm = npfCameraManager(wCm)
  let pe = npfPrism(cm, wPe)
  let gp = npfGradingPostFx(cm, wGp)
  let ccs = npfCcSharpen(cm, wCs)
  let ctrl = npfPostFxController(gp, wCtrl)
  if cm == nil: gNpfSeedWhy = wCm
  elif pe == nil and gp == nil: gNpfSeedWhy = wPe & "; " & wGp

  npfCacheLoad()

  let rows = npfCatalogue()
  gNpfRowGo = @[]
  gNpfRowKey = @[]
  gNpfRowSlider = @[]
  gNpfRowDdb = @[]
  gNpfRowKind = @[]
  gNpfRowTarget = @[]
  gNpfApplied = @[]
  gNpfHaveApplied = @[]
  var built = 0
  var refused = 0
  var seeded = 0
  var i = 0
  while i < rows.len and i < NpfMaxRows:
    let r = rows[i]
    var sl: Il2CppPtr = nil
    var dd: Il2CppPtr = nil
    # THE DROPDOWN IS TRIED FIRST AND FALLS BACK, never the other way: a
    # refusal leaves a working stepper slider rather than a missing control.
    var wantDrop = (r.kind == npfDropdown and nuOk(ddPrefab, 0x10'i32))
    var go: Il2CppPtr = nil
    if wantDrop:
      go = npfMakeRow(ddPrefab, parent, r, true, sl, dd)
      if go == nil: wantDrop = false
    if go == nil:
      go = npfMakeRow(sliPrefab, parent, r, false, sl, dd)
    if go == nil:
      refused = refused + 1
      i = i + 1
      continue
    gNpfRowGo.add go
    gNpfRowKey.add r.key
    gNpfRowSlider.add sl
    gNpfRowDdb.add (if wantDrop: dd else: nil)
    gNpfRowKind.add ord(r.kind)
    gNpfRowTarget.add r.target
    built = built + 1

    # THE SEED -- from the GAME'S OWN CURRENT VALUE, read back off the live
    # component. Never from our store, and never from the cache.
    var live = 0.0'f32
    if npfLiveValue(r, cm, gp, pe, ccs, live):
      seeded = seeded + 1
      npfCacheAnnounce(r.key, live)
      if wantDrop and dd != nil:
        discard nuDropDownIndex(dd)
      elif sl != nil:
        discard nuSliderSetValue(sl, live)
      gNpfApplied.add live
      gNpfHaveApplied.add true
    else:
      # NOT SEEDED. The row shows whatever the prefab came up with, and the
      # census counts it separately -- printing a default and letting it read
      # as the game's current setting is a confident wrong answer.
      gNpfApplied.add 0.0'f32
      gNpfHaveApplied.add false
    i = i + 1

  if built == 0:
    npfNoteFault("zero rows were built out of " & $rows.len & " declared (" &
                 $refused & " refused). Nothing is left on the POSTFX page.")
    discard npfDestroyAll()
    return
  gNpfBuilt = true
  gNpfBuiltN = built
  gNpfRefused = refused
  gNpfSeededLive = seeded
  result = true

## ---------------------------------------------------------------------------
## THE POLL. Once per tick, bounded, over pointers the build already holds.
## Reading the CONTROL rather than a variable of ours is the same discipline
## `sbdReadLiveF` states: a comparison against our own write cannot fail.
proc npfPoll() =
  if not gNpfBuilt or gNpfOff: return
  var wCm = ""
  var wPe = ""
  var wGp = ""
  var wCs = ""
  var wCtrl = ""
  let cm = npfCameraManager(wCm)
  if cm == nil: return          # menu, no raid camera. Nothing to drive.
  let pe = npfPrism(cm, wPe)
  let gp = npfGradingPostFx(cm, wGp)
  let ccs = npfCcSharpen(cm, wCs)
  let ctrl = npfPostFxController(gp, wCtrl)
  let rows = npfCatalogue()
  var i = 0
  while i < gNpfRowKey.len and i < NpfMaxRows and i < rows.len:
    var cur = 0.0'f32
    var got = false
    if gNpfRowDdb[i] != nil:
      let (ok, idx) = nuDropDownIndex(gNpfRowDdb[i])
      if ok:
        cur = float32(idx) + 1.0'f32     # the control is 0-based, rows are 1-based
        got = true
    elif gNpfRowSlider[i] != nil:
      let (ok, v) = nuSliderValue(gNpfRowSlider[i])
      if ok:
        cur = v
        got = true
    if got:
      let had = gNpfHaveApplied[i]
      let d = (if cur > gNpfApplied[i]: cur - gNpfApplied[i]
               else: gNpfApplied[i] - cur)
      if (not had) or d > 0.0005'f32:
        gNpfApplied[i] = cur
        gNpfHaveApplied[i] = true
        npfApplyRow(rows[i], cur, cm, gp, pe, ccs, ctrl)
    i = i + 1

## ---------------------------------------------------------------------------
## THE VERDICT. ONE line per visit to the page, and it states what is on
## screen and where those numbers came from.
proc npfVerdict() =
  if gNpfSaid or not gNpfBuilt: return
  gNpfSaid = true
  okLog "native postfx: " & $gNpfBuiltN & " NATIVE row(s) built into the " &
        "stock POSTFX panel (PostFXSettingsTab._settingsRoot@0xa0), " &
        $gNpfRefused & " refused. " & $gNpfSeededLive & " of " & $gNpfBuiltN &
        " were seeded from THE GAME'S OWN CURRENT VALUE, read back off the " &
        "live component -- not from our store and not from the cache. These " &
        "rows drive the game's own pipeline: CameraManager::SetSharpen / " &
        "SetSSAO, PostFxSettingsController::TryUpdate*, and PrismEffects' AO " &
        "fields through the typed write gate. Nothing here composites a pass " &
        "of ours."
  if gNpfSeededLive < gNpfBuiltN:
    warn "native postfx: " & $(gNpfBuiltN - gNpfSeededLive) & " row(s) could " &
         "NOT be seeded from the game and are showing the prefab's own " &
         "value, which is NOT the player's current setting. Reason: " &
         (if gNpfSeedWhy.len > 0: gNpfSeedWhy
          else: "none was recorded, which is itself a defect") &
         ". This is INCONCLUSIVE -- at the main menu there is no raid camera " &
         "and CameraManager.Instance is legitimately null."
  if gNpfShadowsOn:
    okLog "native postfx: the SHADOW row is ARMED (settingsNativeShadows). " &
          "It is the only row on this page that can cost real frames -- " &
          "raising it re-renders the shadow map at more cascades and higher " &
          "resolution. Its tooltip says so."
  if gNpfCacheDiffs > 0:
    okLog "native postfx: " & $gNpfCacheDiffs & " row(s) differ from the " &
          "nativePostFx cache in aowlspt-host.json; each was named above. " &
          "The GAME's value won in every case."

proc npfApplyVerdict() =
  ## The apply census, printed only once anything has been applied, and kept
  ## SEPARATE from the build verdict: "the rows were built" and "the rows do
  ## something" are different claims and one must never be evidence for the
  ## other.
  if gNpfApplyAsked == 0: return
  if gNpfApplyVerified == gNpfApplyAsked:
    return    # every APPLIED line was already printed by npfApplyRow.
  # PRINTED ON CHANGE, NEVER PER TICK. MEASURED 2026-09-05: this ran from
  # npfOnPanelUp every frame the POSTFX panel was up and printed the SAME
  # line 60 times a second -- 18,651 of a boot's 22,600 host-log lines, 8 MB,
  # after eleven rows stayed INCONCLUSIVE at the menu (no raid camera). A
  # verdict that repeats itself unchanged is noise that buries every other
  # line; it is printed when its numbers or its reason change.
  let line = "native postfx: APPLY CENSUS -- " & $gNpfApplyAsked & " asked, " &
       $gNpfApplyCalled & " call(s)/store(s) made, " & $gNpfApplyVerified &
       " READ BACK from the finished state, " & $gNpfApplyIncon &
       " INCONCLUSIVE (could not be examined at all, which is neither a pass " &
       "nor a fail). First reason: " &
       (if gNpfApplyWhy.len > 0: gNpfApplyWhy
        else: "none was recorded, which is itself a defect") & "."
  if line == gNpfCensusLast: return
  gNpfCensusLast = line
  warn line

## ---------------------------------------------------------------------------
## THE TICK ENTRY POINTS. Called from the settings-screen tick, INSIDE the
## single `aowl_p_p_seh` already open there. No guard is opened here: it is not
## re-entrant and a nested inner guard would disarm the outer one.
proc npfOnPanelUp(postUp: bool) =
  if not gNpfOn or gNpfOff: return
  if not postUp: return
  if not gNpfBuilt:
    if gNpfTried < 4:
      discard npfBuild()
    return
  npfVerdict()
  npfPoll()
  npfApplyVerdict()

proc npfOnScreenClosed() =
  ## The settings screen went away. Our rows are OURS -- the game's
  ## `CleanupCreatedControls` does not know about them -- so they are torn down
  ## here UNCONDITIONALLY and rebuilt on the next visit. That is what stops the
  ## section appearing twice, then three times, the way an owned row parented
  ## into a re-initialised stock container otherwise does.
  ##
  ## NOTHING IS REVERTED. The values were applied to the game's own pipeline
  ## and they stay applied -- that is the point of driving the real renderer
  ## rather than a pass of ours.
  gNpfSaid = false
  if gNpfBuilt or gNpfRowGo.len > 0:
    let n = npfDestroyAll()
    gNpfTried = 0
    if n > 0:
      okLog "native postfx: the settings screen closed; " & $n & " row(s) of " &
            "ours were torn down and will be rebuilt on the next visit. The " &
            "VALUES stay applied -- they were written into the game's own " &
            "pipeline, not held by the rows."

proc npfSummary(): string =
  ## For the boot census. States the table's verification split, because "the
  ## flag is off" and "the flag is on and every target was rejected" must never
  ## print the same.
  "native postfx: " & $cNpfOkCount() & " of " & $cNpfTargetCount() &
  " call target(s) verified against the startup prologue snapshot, " &
  $cNpfBadCount() & " byte-mismatch, " & $cNpfProfullCount() &
  " unprimed (snapshot table full)."
