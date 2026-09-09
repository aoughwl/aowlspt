## RAYTRACED AUDIO ("soundfx") -- the flag, the path, the throttled verdict.
##
## The whole of the work is in `abi/aowlspt_audioray.h`: the FFI binding of
## Vercidium Audio v1.7.0 (`vaudionative.dll`), the bounded main-thread pump,
## the falsifiable smoke test and the occlusion export. This file is the same
## thin shape as `frametime.nim` -- read one flag, call one tick, print one
## line -- and for the same reason: everything that can fault belongs on the C
## side under exactly one `aowl_p_p_seh`, and everything that formats a sentence
## belongs here.
##
## WHAT IT HOOKS: one call, `arTick()`, riding the host's existing
## `TarkovApplication::Update` drain (`gDrainSlot`). NO new detour is installed,
## no IL2CPP name is resolved and no game pointer is dereferenced -- vaudio is
## an ordinary native DLL with KERNEL32-only imports, so this is a native->native
## call that never touches the token-gated `il2cpp_*` export surface at all.
##
## THE LICENCE DECIDES THE INSTALL SHAPE. The Vercidium Audio EULA clause 5.1(c)
## forbids making any binary of it "available as a standalone file or in any
## form outside an integrated, compiled Game or Application build". Shipping
## `vaudionative.dll` into `D:\Aowlspt\aowlspt\` beside the host is exactly a
## standalone file, so THE HOST DOES NOT SHIP IT. The user points
## `audioRayDllPath` at their own copy and the feature refuses, by name, when
## that path is absent or unloadable. This also sidesteps the consistency-check
## landmine (CLAUDE.md section 7) entirely: no new file is added to the install
## directory, so nothing can disagree with `D:\Aowlspt\ConsistencyInfo`.
##
## WHAT IS NOT DONE YET, said here rather than discovered live: the vaudio world
## contains only the smoke geometry. EFT's map colliders are not fed into it, so
## `aowl_audio_occlusion` refuses (returns -1.0) rather than answering 1.0 for
## every pair -- an unoccluded answer from an empty world is a confidently wrong
## number, which this project treats as worse than no answer.

proc cArInit(path: Il2CppPtr; occRays, occBounces, revRays, revBounces,
             maxPairs: int32): int32 {.importc: "aowl_ar_init", nodecl.}
proc cArTick() {.importc: "aowl_ar_tick", nodecl.}
proc cArRefusal(): int32 {.importc: "aowl_ar_refusal", nodecl.}
proc cArMissing(): cstring {.importc: "aowl_ar_missing", nodecl.}
proc cArDllPath(): cstring {.importc: "aowl_ar_dllpath", nodecl.}
proc cArVerMajor(): int32 {.importc: "aowl_ar_ver_major", nodecl.}
proc cArVerMinor(): int32 {.importc: "aowl_ar_ver_minor", nodecl.}
proc cArVerPatch(): int32 {.importc: "aowl_ar_ver_patch", nodecl.}
proc cArProduction(): int32 {.importc: "aowl_ar_production", nodecl.}
proc cArArmed(): int32 {.importc: "aowl_ar_armed", nodecl.}
proc cArFaults(): int32 {.importc: "aowl_ar_faults", nodecl.}
proc cArTicks(): int64 {.importc: "aowl_ar_ticks", nodecl.}
proc cArUpdates(): int64 {.importc: "aowl_ar_updates", nodecl.}
proc cArLastResult(): int32 {.importc: "aowl_ar_last_result", nodecl.}
proc cArLastCall(): cstring {.importc: "aowl_ar_last_call", nodecl.}
proc cArSmokeState(): int32 {.importc: "aowl_ar_smoke_state", nodecl.}
proc cArSmokeVerdict(): int32 {.importc: "aowl_ar_smoke_verdict", nodecl.}
proc cArBlockedLf(): int32 {.importc: "aowl_ar_smoke_blocked_lf", nodecl.}
proc cArBlockedHf(): int32 {.importc: "aowl_ar_smoke_blocked_hf", nodecl.}
proc cArClearLf(): int32 {.importc: "aowl_ar_smoke_clear_lf", nodecl.}
proc cArClearHf(): int32 {.importc: "aowl_ar_smoke_clear_hf", nodecl.}
proc cArPairsLive(): int32 {.importc: "aowl_ar_pairs_live", nodecl.}
proc cArOccQueries(): int64 {.importc: "aowl_ar_occ_queries", nodecl.}
proc cArOccHits(): int64 {.importc: "aowl_ar_occ_hits", nodecl.}
proc cArOccMisses(): int64 {.importc: "aowl_ar_occ_misses", nodecl.}

var gAryOn = false
var gAryReported = false
var gAryAt = 0'u64
## Module level, not a local: a pointer handed across FFI should not depend on
## a temporary's lifetime. `autoraid.nim` owns the `gAr` prefix, hence `gAry`.
var gAryPath = ""
const ArPeriodMs = 10000'u64

proc arGain(milli: int32): string =
  ## Gains cross the ABI as thousandths, because the C side has no formatter and
  ## a float through a variadic log call is the kind of thing that reads fine
  ## and prints garbage. One unit, spelled, always.
  $(milli div 1000) & "." & $((milli mod 1000) div 100) &
    $((milli mod 100) div 10) & $(milli mod 10)

proc arUnescapePath(s: string): string =
  ## `readStrKey` is a shallow reader and does NOT decode JSON escapes, so a
  ## Windows path written the only way JSON allows -- `"D:\\vaudio\\x.dll"` --
  ## arrives here with the backslashes still doubled and `LoadLibraryA` fails on
  ## it with a message that blames the file rather than the quoting. Collapse
  ## exactly that one escape and nothing else; a forward-slash path needs no
  ## treatment and is the better thing to write.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '\\':
      result.add('\\')
      i = i + 2
    else:
      result.add(s[i])
      i = i + 1

proc arClamp(v, lo, hi: int): int =
  if v < lo: lo elif v > hi: hi else: v

proc arRefusalText(): string =
  ## FOUR named refusals, never "it did not start". Which one it is decides what
  ## the user does next, so the line has to say.
  case cArRefusal()
  of 0: "armed"
  of 1: "audioRayDllPath is not set in aowlspt-host.json. The Vercidium Audio " &
        "EULA (clause 5.1(c)) forbids shipping vaudionative.dll as a standalone " &
        "file, so this host deliberately does NOT bundle it: point the key at " &
        "your own copy, e.g. \"audioRayDllPath\": " &
        "\"C:/vercidium_audio_v1.7.0/3d/native/production/windows/vaudionative.dll\""
  of 2: "LoadLibraryA failed for \"" & $cArDllPath() & "\" -- the path does not " &
        "exist, is not an x64 DLL, or a dependency is missing (this build of " &
        "vaudionative.dll imports KERNEL32 only, so a dependency failure here " &
        "means the wrong file)"
  of 3: "vaudionative.dll loaded but the export \"" & $cArMissing() & "\" did " &
        "not resolve -- this is not Vercidium Audio v1.7.0's native 3d build. " &
        "The bind is all-or-nothing on purpose: a partial bind would leave a " &
        "NULL to be called minutes later inside the guard"
  of 4: "SELF-DISABLED after " & $cArFaults() & " faults"
  else: "unknown"

proc arVerdictText(): string =
  ## Three outcomes, never two. INCONCLUSIVE is "I could not look", and it is
  ## printed with the last vaudio result code so the next step is a fact rather
  ## than a guess.
  let blocked = "blocked(LF=" & arGain(cArBlockedLf()) & " HF=" &
                arGain(cArBlockedHf()) & ")"
  let clear = "clear(LF=" & arGain(cArClearLf()) & " HF=" &
              arGain(cArClearHf()) & ")"
  case cArSmokeVerdict()
  of 1: "PASS -- the concrete slab measurably muffled the blocked source: " &
        clear & " vs " & blocked & ". A non-null filter alone would NOT have " &
        "been evidence: an empty world answers (1.000, 1.000) forever, which " &
        "is why the clear source is the control"
  of 2: "FAIL -- both filters read back but the wall made no difference: " &
        clear & " vs " & blocked & ". vaudio is running and answering; the " &
        "geometry is not reaching the raytracer"
  of 3: "INCONCLUSIVE -- at least one target filter was still NULL at the " &
        $cArTicks() & "-tick deadline (vaudio returns NULL for a pair it has " &
        "not raytraced yet), so nothing was measured. vaWorldUpdate returned " &
        "SUCCESS " & $cArUpdates() & " times; last non-success VAResult=" &
        $cArLastResult() & " from " & $cArLastCall() &
        ". This is NOT a pass and NOT a fail"
  else: "still running (" & $cArTicks() & " ticks, " & $cArUpdates() &
        " completed vaWorldUpdate passes)"

proc arLine(): string =
  "audioRay: vaudio " & $cArVerMajor() & "." & $cArVerMinor() & "." &
    $cArVerPatch() & (if cArProduction() != 0: " (production)" else: " (dev)") &
    " from " & $cArDllPath() & ". smoke: " & arVerdictText() &
    ". occlusion export: " & $cArOccQueries() & " queries / " & $cArOccHits() &
    " answered / " & $cArOccMisses() & " refused, " & $cArPairsLive() &
    " live pairs. faults=" & $cArFaults()

proc arTick() =
  ## Called once per Update drain. Cost when off: one boolean compare. Cost when
  ## on: one `vaWorldUpdate`, which returns immediately with VA_STILL_RUNNING
  ## while vaudio's own background threads work -- the raytracing does not
  ## happen on this thread. Nothing here allocates.
  if not gAryOn: return
  cArTick()
  let now = cNowMs()
  # Report on a period, and ALWAYS once the smoke test has settled, so a verdict
  # cannot be missed by a run that ended between two periods.
  if cArSmokeState() == 2 and not gAryReported:
    gAryReported = true
    okLog arLine()
    return
  if (now - gAryAt) > ArPeriodMs:
    gAryAt = now
    info arLine()

proc arConfigure() =
  ## Flag `audioRay`, default OFF. Read like every other flag; ANDed with
  ## nothing, because this feature depends on no other feature -- it does not
  ## need the raid-phase latch, a canvas, a camera or a world.
  gAryOn = readBoolKey("audioRay")
  if not gAryOn: return
  gAryPath = arUnescapePath(readStrKey("audioRayDllPath"))
  # Ranges from the reference C#/BepInEx port's own config, clamped here rather
  # than trusted: a ray count of zero would make `vaEmitterAddTarget` return
  # VA_FEATURE_DISABLED and the feature would then report "no filter yet"
  # forever, which is an INCONCLUSIVE that can never resolve.
  let occRays    = arClamp(readIntKey("audioRayOcclusionRays", 16), 4, 64)
  let revRays    = arClamp(readIntKey("audioRayReverbRays", 8), 0, 32)
  let maxSources = arClamp(readIntKey("audioRayMaxSources", 64), 8, 128)
  let armed = cArInit(cast[Il2CppPtr](toCString(gAryPath)), int32(occRays), 2'i32,
                      int32(revRays), 2'i32, int32(maxSources))
  if armed == 0:
    gAryOn = false
    warn "audioRay is set but did NOT arm: " & arRefusalText()
    return
  info "audioRay is set: Vercidium Audio " & $cArVerMajor() & "." &
       $cArVerMinor() & "." & $cArVerPatch() &
       (if cArProduction() != 0: " (production)" else: " (dev)") &
       " bound from " & $cArDllPath() & " by LoadLibraryA/GetProcAddress -- " &
       "native to native, so no il2cpp export and no token gate is involved. " &
       "It rides the existing TarkovApplication::Update drain, installs no " &
       "detour and dereferences no game pointer; one vaWorldUpdate per frame " &
       "(vaudio raytraces on its own threads). occlusionRays=" & $occRays &
       " reverbRays=" & $revRays & " maxSources=" & $maxSources &
       ". A falsifiable smoke test runs first: a concrete slab between one " &
       "source and the listener, a second source with nothing in the way, and " &
       "the verdict is the DIFFERENCE between the two gains -- so an empty " &
       "world reports FAIL rather than passing on a non-null pointer. " &
       "aowl_audio_occlusion is exported but refuses (-1.0) until EFT map " &
       "geometry is fed into the vaudio world, which is not built yet."
