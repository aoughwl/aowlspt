## Debug -- the F3 overlay's configuration surface, and the per-mod profiler.
##
## ---------------------------------------------------------------------------
## WHAT THIS MOD IS, AND THE ONE THING IT IS NOT
## ---------------------------------------------------------------------------
##
## Two features, both opt-in, both default OFF:
##
##   **A. The F3 overlay's settings.** The Minecraft-style info panel already
##   exists and is drawn Unity-natively by the host
##   (`host/Aowlspt.Host.Il2Cpp/debugui.nim`), toggled by a configurable virtual
##   key that ships as 114 = VK_F3. What it did NOT have was a way to change
##   which lines it shows, in what order, and where, other than hand-editing
##   `aowlspt-debugui.json` next to the host DLL. This mod declares that file as
##   a settings schema, so every one of those choices is a control in whatever
##   settings UI is installed, and writing one rewrites the file. **No rebuild,
##   and no restart**: the host re-reads that file on every toggle-on, so the
##   round trip is "change a setting, press F3 off, press F3 on".
##
##   **B. The profiler** -- the aowlspt-shaped answer to ModProfiler. Which mod
##   is costing frame time, in absolute milliseconds and as a share of the
##   frame, over a rolling window. See `abi/aowlspt_profile.h` for the design
##   and, more importantly, for the error bars.
##
## **What it is NOT: a second overlay.** The temptation was to draw a profiler
## HUD of its own in the Present hook, the way `mods/admin` draws the F6 menu.
## That would have meant a second thing bound to F3 and two panels fighting over
## one key. Instead the profiler publishes into a shared page and the EXISTING
## panel grew new field names for it (`prof`, `prof1`..`prof8`, `frametime`),
## which is a strictly additive change to one `case` statement. Put `prof1` in
## `overlayFields` and the costliest mod is a line on the F3 panel.
##
## ---------------------------------------------------------------------------
## WHY THIS CANNOT KILL THE CLIENT
## ---------------------------------------------------------------------------
##
## Fact #145: on this build EVERY by-NAME IL2CPP route -- call, bind or host
## patch -- is fatal the moment it is USED, not when it is resolved. Calling
## `get_Instance`, binding `Physics::Raycast` and patching a method by name each
## killed the client instantly and silently.
##
## This mod has no such route to be fatal. It resolves no IL2CPP name, calls no
## game method, binds no detour, reads no game memory and patches no byte. Its
## entire native surface is `abi/aowlspt_profile.h`: a page this process created,
## a `QueryPerformanceCounter` pair, and integer arithmetic. There is nothing
## here for a wrong RVA to be wrong about, and nothing to byte-verify, because
## nothing is called at an RVA.
##
## The instrumentation itself lives in code we own the source of and rides
## dispatch points that already exist -- `tickMods` in the shared loader, and
## the shared `EFT.UI.PreloaderUI::Update` rider chain in the client host. **No
## new detour is installed anywhere**, which is the two-detours-one-trampoline
## rule respected rather than tested.
##
## ---------------------------------------------------------------------------
## HOW TO FALSIFY THE PROFILER, WHICH IS THE ONLY REASON TO BELIEVE IT
## ---------------------------------------------------------------------------
##
## A timing number this mod produced and then read back proves nothing. So this
## mod ships the input that makes its own claim fail if the claim is wrong:
##
##   set `selfTestSpinMs` to 5, with `profiler` on.
##
## `onUpdate` then busy-spins for 5 ms of wall time per tick, IN THIS MOD. If
## the attribution works, `aowl.debug` moves to the top of the profile with
## ~5 ms per tick and every other mod is unchanged. If the profiler were
## measuring something else -- the tick loop, the frame, itself -- the cost
## would land somewhere else or be smeared across every mod, and that is
## visible in one look at `/aowlspt/debug/profile`.
##
## The spin defaults to 0 and is described in the schema as a self-test, because
## a setting that makes the game slower is not a feature.

import std/[strutils, syncio]
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json

import "dbg" / prof

const
  ModGuid = "aowl.debug"
  ModName = "Debug"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

  OverlayFile = "aowlspt-debugui.json"
  ## The host's own config, which must sit beside the host DLL for the host to
  ## find it. Named here once so the refusal message can quote it.

  HostMarkerFile = "aowlspt-host.json"
  ## What proves a directory IS the host's directory. See `overlayPath`.

# ---------------------------------------------------------------------------
# Where the host's overlay config lives, and the refusal that keeps this honest
# ---------------------------------------------------------------------------

proc parentOf(path: string): string =
  var cut = -1
  for i in 0 ..< path.len:
    if path[i] == '/' or path[i] == '\\': cut = i
  if cut <= 0: return ""
  result = path.substr(0, cut - 1)

var gOverlayPathFault = ""

proc overlayPath(): string =
  ## `<install>/aowlspt/aowlspt-debugui.json`, derived from this mod's own
  ## directory: `<install>/aowlspt/mods/debug` -> up two.
  ##
  ## Derived and then CHECKED, not assumed. The check is a negative and can
  ## therefore fail: the directory two levels up must already contain the
  ## host's own `aowlspt-host.json`. If it does not, this is not the host's
  ## directory -- a different install layout, a mod staged somewhere else, a
  ## test harness -- and this mod writes NOTHING and says where it looked.
  ##
  ## Blind-writing a JSON file into a guessed directory is exactly the "never
  ## blind-write" rule, and the failure mode without this check is silent: the
  ## settings appear to apply, the file lands somewhere nothing reads, and the
  ## panel never changes.
  gOverlayPathFault = ""
  let mine = modDir()
  if mine.len == 0:
    gOverlayPathFault = "the host did not tell this mod its own directory"
    return ""
  let dir = parentOf(parentOf(mine))
  if dir.len == 0:
    gOverlayPathFault = "could not walk up two levels from " & mine
    return ""
  var probe = ""
  try:
    probe = readFile(dir & "/" & HostMarkerFile)
  except:
    probe = ""
  if probe.len == 0:
    gOverlayPathFault = dir & " does not contain " & HostMarkerFile &
                        ", so it is not the host's directory and " &
                        OverlayFile & " was NOT written there"
    return ""
  result = dir & "/" & OverlayFile

# ---------------------------------------------------------------------------
# The settings schema
# ---------------------------------------------------------------------------
#
# Two categories, because they are two features with two different blast radii:
# "Overlay" only ever rewrites a config file the host reads, and "Profiler"
# only ever writes integers into a page this process created.

const
  DefaultFields = "fps,frametime,build,map,raid,bots,pos,rot"
  ## What the panel shows out of the box. `frametime` is in the default because
  ## it is the one line that is useful before you know what you are looking for
  ## -- and it prints an explicit "profiler OFF" when the profiler is off,
  ## rather than a zero.

  KnownFields =
    "fps, frame, frametime, build, map, raid, bots, pos, rot, botlist, " &
    "prof, prof1..prof8, note1, note2, note3"

proc debugSchema(): seq[Setting] =
  result = @[
    # ---- the F3 overlay -------------------------------------------------
    boolSetting("overlayEnabled", "F3 overlay", true, category = "Overlay",
                description = "aowlspt original (F3 debug overlay). Draw the debug panel at all. The host also has its own debugUi flag; both must be on."),
    stringSetting("overlayFields", "Lines, in order", DefaultFields,
                  category = "Overlay",
                  description = "aowlspt original (F3 debug overlay). Comma-separated, one panel line each, TOP TO BOTTOM in this order. Known names: " & KnownFields & ". An unknown name prints " &
                                "itself with a '?' rather than vanishing, so " &
                                "a typo is visible on screen."),
    enumSetting("overlayAnchor", "Corner", "topleft",
                @["topleft", "topright", "bottomleft", "bottomright",
                  "top", "bottom", "center"], category = "Overlay",
      description = "aowlspt original (F3 debug overlay)."),
    floatSetting("overlayX", "X offset", 16.0, lo = -4000.0, hi = 4000.0,
                 step = 1.0, category = "Overlay",
      description = "aowlspt original (F3 debug overlay)."),
    floatSetting("overlayY", "Y offset", -16.0, lo = -4000.0, hi = 4000.0,
                 step = 1.0, category = "Overlay",
                 description = "aowlspt original (F3 debug overlay). Unity's Y grows UPWARD, so a top anchor wants a NEGATIVE Y to move down."),
    floatSetting("overlayFontSize", "Font size", 18.0, lo = 6.0, hi = 72.0,
                 step = 1.0, category = "Overlay",
      description = "aowlspt original (F3 debug overlay)."),
    floatSetting("overlayLineHeight", "Line spacing", 22.0, lo = 6.0, hi = 96.0,
                 step = 1.0, category = "Overlay",
      description = "aowlspt original (F3 debug overlay)."),
    intSetting("overlayThrottle", "Refresh every N frames", 10,
               lo = 1, hi = 600, category = "Overlay",
               description = "aowlspt original (F3 debug overlay). The panel rebuilds its text every Nth frame. 1 is smoothest and costs the most; 10 is the shipped default and is imperceptible."),
    colorSetting("overlayColor", "Text colour", "1,1,0.62",
                 category = "Overlay",
      description = "aowlspt original (F3 debug overlay). Applies as you drag: " &
                    "the host re-reads aowlspt-debugui.json while the panel is " &
                    "on screen, so no F3 off/on cycle is needed."),
    intSetting("overlayToggleKey", "Toggle key (virtual-key code)", 114,
               lo = 0, hi = 255, category = "Overlay",
               description = "aowlspt original (F3 debug overlay). 114 is VK_F3, which is the Minecraft key and the shipped default. 0 disables the toggle."),

    # ---- the profiler ---------------------------------------------------
    boolSetting("profiler", "Per-mod profiler", false, category = "Profiler",
                description = "aowlspt original (per-mod profiler; aowlspt's answer to ModProfiler). Time every mod's per-frame work and every host rider on the shared Update hook. OFF costs one load and a predicted branch per mod per tick. Add 'prof1'..'prof8' to the overlay lines to see the result in game."),
    intSetting("profilerWindowFrames", "Rolling window (frames)", 120,
               lo = 10, hi = 512, category = "Profiler",
               description = "aowlspt original (per-mod profiler; aowlspt's answer to ModProfiler). How many frames each reported window covers. 120 is about two seconds at 60 fps."),
    floatSetting("selfTestSpinMs", "Self-test: burn N ms per tick, in THIS mod",
                 0.0, lo = 0.0, hi = 50.0, step = 0.5, category = "Profiler",
                 description = "aowlspt original (per-mod profiler; aowlspt's answer to ModProfiler). THE FALSIFIER, not a feature. Set it to 5 and this mod should jump to the top of the profile at ~5 ms per tick with every other mod unchanged. If the cost lands anywhere else, the attribution is wrong and the profile should not be believed. Leave at 0.")]

# ---------------------------------------------------------------------------
# Applying the settings
# ---------------------------------------------------------------------------

var gSpinMs = 0.0
var gOverlayWriteState = "not attempted"
var gOverlayWrites = 0

proc jstr(v: string): string =
  ## Minimal JSON string escaping. The values here are colours, key names and a
  ## comma list, but a settings UI can put anything in a string field and a
  ## config file that does not parse would silently revert the whole panel to
  ## built-in defaults -- which looks exactly like "the setting did not apply".
  result = "\""
  for i in 0 ..< v.len:
    let c = v[i]
    if c == '"' or c == '\\': result.add '\\'; result.add c
    elif c == '\n' or c == '\r' or c == '\t': result.add ' '
    elif int(c) < 32: discard
    else: result.add c
  result.add "\""

proc fnum(v: float): string =
  ## A float with one decimal place, without depending on a formatting library.
  let scaled = int(v * 10.0 + (if v < 0.0: -0.5 else: 0.5))
  result = (if scaled < 0 and scaled > -10: "-" else: "") &
           $(scaled div 10) & "." & $(if scaled < 0: -(scaled mod 10)
                                      else: scaled mod 10)

proc writeOverlayConfig() =
  ## Rewrite `aowlspt-debugui.json` from the current settings.
  ##
  ## The ESP half of that file is NOT written here. `debugEsp` draws markers
  ## over live bots and is the host's to own; rewriting the file would drop
  ## every esp* key back to the host's defaults, which is a silent change to a
  ## feature this mod does not administer. So the ESP keys are read back off
  ## disk and passed through verbatim -- and when the file does not exist yet,
  ## they are simply absent and the host uses its own defaults, which is the
  ## same outcome.
  let path = overlayPath()
  if path.len == 0:
    gOverlayWriteState = "REFUSED: " & gOverlayPathFault
    return

  var existing = ""
  try: existing = readFile(path)
  except: existing = ""

  var esp = ""
  for line in existing.split('\n'):
    let t = line.strip()
    if t.startsWith("\"esp"):
      esp.add "  " & (if t.endsWith(","): t else: t & ",") & "\n"

  var doc = "{\n"
  doc.add "  \"_written_by\": \"" & ModGuid & " " & ModVersion &
          " -- edit it here or in the Debug mod's settings; the settings win " &
          "on the next apply\",\n"
  doc.add "  \"panelEnabled\":    " &
          (if setting("overlayEnabled").asBool(true): "true" else: "false") & ",\n"
  doc.add "  \"panelAnchor\":     " &
          jstr(setting("overlayAnchor").asText("topleft")) & ",\n"
  doc.add "  \"panelX\":          " & fnum(setting("overlayX").asFloat(16.0)) & ",\n"
  doc.add "  \"panelY\":          " & fnum(setting("overlayY").asFloat(-16.0)) & ",\n"
  doc.add "  \"panelFontSize\":   " & fnum(setting("overlayFontSize").asFloat(18.0)) & ",\n"
  doc.add "  \"panelLineHeight\": " & fnum(setting("overlayLineHeight").asFloat(22.0)) & ",\n"
  doc.add "  \"panelThrottle\":   " & $setting("overlayThrottle").asInt(10) & ",\n"
  doc.add "  \"panelColor\":      " &
          jstr(setting("overlayColor").asText("1,1,0.62")) & ",\n"
  doc.add "  \"panelFields\":     " &
          jstr(setting("overlayFields").asText(DefaultFields)) & ",\n"
  doc.add esp
  doc.add "  \"toggleKey\":       " & $setting("overlayToggleKey").asInt(114) & "\n"
  doc.add "}\n"

  try:
    writeFile(path, doc)
  except:
    gOverlayWriteState = "FAILED: could not write " & path
    return

  # Assert a property of the FINISHED STATE, not of the write: read the file
  # back off disk and check the field list the HOST will parse is the one that
  # was asked for. A `writeFile` that did not raise is not evidence the file on
  # disk says what it should.
  var back = ""
  try: back = readFile(path)
  except: back = ""
  let want = setting("overlayFields").asText(DefaultFields)
  # The COLOUR is checked the same way and for a sharper reason: a colour is the
  # one value here that can come back *plausible but different*. A field list
  # either survives or is visibly mangled, but a colour that drifts from
  # "1,1,0.62" to "1,1,0.6200000000000001" still renders as the right yellow, so
  # nothing on screen would ever reveal it -- and the next save would drift it
  # again. Asserting the EXACT text off disk is what makes that falsifiable.
  let wantColor = setting("overlayColor").asText("1,1,0.62")
  if back.len == 0:
    gOverlayWriteState = "INCONCLUSIVE: wrote " & path &
                         " but could not read it back"
  elif not back.contains(jstr(want)):
    gOverlayWriteState = "FAILED: " & path &
                         " does not read back with the requested line list"
  elif not back.contains(jstr(wantColor)):
    gOverlayWriteState = "FAILED: " & path & " does not read back the colour " &
                         "that was set (wanted " & wantColor & " verbatim) -- " &
                         "the value drifted between the settings edit and disk"
  else:
    gOverlayWrites = gOverlayWrites + 1
    gOverlayWriteState = "PASS: " & path & " reads back with " &
                         $(want.split(',').len) & " lines and colour " &
                         wantColor & " byte-for-byte (write #" &
                         $gOverlayWrites & "). The host picks this up live " &
                         "while the panel is on screen; no F3 cycle needed."

proc applyConfig() =
  gSpinMs = setting("selfTestSpinMs").asFloat(0.0)
  profSetWindow(setting("profilerWindowFrames").asInt(120))
  # The profiler is enabled LAST, so a window size change cannot land in the
  # middle of an already-running window.
  profSetEnabled(setting("profiler").asBool(false))
  writeOverlayConfig()

# ---------------------------------------------------------------------------
# The profile report -- text for the log, JSON for a tool
# ---------------------------------------------------------------------------

proc pct(permille: int): string =
  if permille < 0: "--"
  else: $(permille div 10) & "." & $(permille mod 10) & "%"

proc profileText*(): string =
  ## PASS / FAIL / INCONCLUSIVE, never two outcomes.
  result = "debug profiler (" & ModName & " " & ModVersion & ")\n"
  if not profReady():
    result.add "  state      : FAIL  the shared profile region could not be " &
               "mapped; nothing is measured this session\n"
    return
  if profSelfDisabled():
    result.add "  state      : FAIL  SELF-DISABLED after " & $profFaults() &
               " faults: " & profReason() & "\n"
    return
  if not profEnabled():
    result.add "  state      : INCONCLUSIVE  the profiler is OFF (the " &
               "shipped default). Nothing was measured -- this is not a " &
               "report of zero cost. Turn on 'Per-mod profiler'.\n"
    return
  var anyWindow = false
  var i0 = 0
  while i0 < profSlotCount():
    if profSlotCalls(i0) > 0: anyWindow = true
    i0 = i0 + 1
  if not anyWindow:
    result.add "  state      : INCONCLUSIVE  ON, but no window has completed " &
               "yet, so nothing is reported. This is NOT a report of zero " &
               "cost -- a window closes every " &
               $setting("profilerWindowFrames").asInt(120) &
               " client frames, or every that many loader ticks elsewhere. " &
               "Boundary firings seen: " & $profHeartbeat() &
               "; registered scopes: " & $profLiveSlots() &
               ". ZERO firings means nothing in this process is calling a " &
               "window boundary, so no window can ever close -- which is a " &
               "different failure from 'the mods are cheap'.\n"
    return

  result.add "  state      : PASS  " & $profFaults() & " faults\n"
  if profFrameSourceLive():
    result.add "  frame ms   : min " & profMs(int64(profWinUs(winMin)) * 1000) &
               "  p50 " & profMs(int64(profWinUs(winP50)) * 1000) &
               "  p95 " & profMs(int64(profWinUs(winP95)) * 1000) &
               "  p99 " & profMs(int64(profWinUs(winP99)) * 1000) &
               "  max " & profMs(int64(profWinUs(winMax)) * 1000) &
               "   (" & $profFramesSeen() & " frames)\n"
  else:
    result.add "  frame ms   : NOT A FRAME SOURCE -- nothing in this process " &
               "drives the client's per-frame rider chain, so there is no " &
               "frame time to report and none is invented. The per-mod costs " &
               "below are per LOADER TICK and are real.\n"
  result.add "  instrument : one begin/end pair costs " & $profOverheadNs() &
             " ns, NOT subtracted from any number below\n"
  result.add "  routes     : UNMEASURED -- backend route timing is not " &
             "instrumented by this mod and is reported as absent, not as zero\n"

  var i = 0
  let cap = profSlotCount()
  while i < cap:
    if profSlotKind(i) != profKindFree and profSlotCalls(i) > 0:
      result.add "  " & profKindName(profSlotKind(i)) & "  " &
                 profSlotName(i) & "  " & profMs(profSlotNs(i)) & " ms  " &
                 pct(profSlotPermille(i)) & "  x" & $profSlotCalls(i) &
                 "  peak " & profMs(profSlotMaxNs(i)) & " ms" &
                 (if profAtNoiseFloor(profSlotNs(i)):
                    "  [at the noise floor -- this is the instrument, not a " &
                    "measurement]"
                  else: "") & "\n"
    i = i + 1

proc profileJson(): string =
  var s = "{\"ready\":" & (if profReady(): "true" else: "false") &
          ",\"enabled\":" & (if profEnabled(): "true" else: "false") &
          ",\"selfDisabled\":" & (if profSelfDisabled(): "true" else: "false") &
          ",\"faults\":" & $profFaults() &
          ",\"framesSeen\":" & $profFramesSeen() &
          ",\"overheadNs\":" & $profOverheadNs() &
          ",\"frameSourceLive\":" &
          (if profFrameSourceLive(): "true" else: "false") &
          ",\"frameUs\":{\"min\":" & $profWinUs(winMin) &
          ",\"p50\":" & $profWinUs(winP50) &
          ",\"p95\":" & $profWinUs(winP95) &
          ",\"p99\":" & $profWinUs(winP99) &
          ",\"max\":" & $profWinUs(winMax) & "}" &
          ",\"routesInstrumented\":false" &
          ",\"overlayConfig\":" & jstr(gOverlayWriteState) &
          ",\"slots\":["
  var first = true
  var i = 0
  let cap = profSlotCount()
  while i < cap:
    if profSlotKind(i) != profKindFree and profSlotCalls(i) > 0:
      if not first: s.add ","
      first = false
      s.add "{\"name\":" & jstr(profSlotName(i)) &
            ",\"kind\":" & jstr(profKindName(profSlotKind(i))) &
            ",\"ns\":" & $profSlotNs(i) &
            ",\"maxNs\":" & $profSlotMaxNs(i) &
            ",\"calls\":" & $profSlotCalls(i) &
            ",\"totalNs\":" & $profSlotTotalNs(i) &
            ",\"permille\":" & $profSlotPermille(i) &
            ",\"atNoiseFloor\":" &
            (if profAtNoiseFloor(profSlotNs(i)): "true" else: "false") & "}"
    i = i + 1
  s.add "]}"
  result = s

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onDebugSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok: applyConfig()
  result = declaredSchemaReply(st).text

proc onDebugSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok: applyConfig()
  result = declaredSchemaReply(st).text

proc onProfileRoute(url, body, session: string): string =
  result = profileJson()

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

var gTick = 0'i64
var gReported = false

proc burn(ms: float) =
  ## THE FALSIFIER's engine. A busy spin, deliberately: a sleep would leave the
  ## thread and a wall-clock profiler would still charge this mod for it, which
  ## would make the test pass for the wrong reason. Spinning keeps the cost on
  ## this thread, in this mod's on_update, where the claim says it will land.
  ##
  ## Capped by the schema at 50 ms and by this loop at 200_000 iterations of
  ## the clock check, so a bad `nowMs` cannot turn it into a hang.
  ##
  ## The iteration cap is DERIVED from the requested milliseconds rather than
  ## being a round constant. It was 200_000 first, and that was a bug the
  ## falsifier itself caught: at ~4.5 ns per nowMs() the guard tripped after
  ## ~0.9 ms, so a 5 ms request burned 0.9 ms and the profiler dutifully
  ## reported 0.9 ms. The profiler was right and the test was wrong -- which is
  ## the good version of this failure, and the reason the spin is a separate
  ## knob from the thing it tests.
  if ms <= 0.0: return
  let deadline = nowMs() + int64(ms)
  let cap = int(ms) * 4_000_000 + 4_000_000
  var guard = 0
  while nowMs() < deadline and guard < cap:
    guard = guard + 1

proc onUpdate(elapsedMs: int64): Status =
  gTick = gTick + 1
  burn(gSpinMs)
  # Report once the run has settled. Not on the first tick: at tick 1 no window
  # has completed and the only honest report is "INCONCLUSIVE", which would
  # then be the only line in the log for the rest of the session.
  if not gReported and gTick > 400:
    gReported = true
    info profileText()
  result = Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  declareSettings(debugSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onDebugSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onDebugSettingsReset)
  discard serve("/aowlspt/debug/profile", onProfileRoute)

  if not profReady():
    warn ModName & " " & ModVersion & ": the shared profile region could not " &
         "be mapped, so the profiler measures nothing this session. The F3 " &
         "overlay's settings still work -- they are a file, not a region."
  else:
    profCalibrate()

  applyConfig()

  info ModName & " " & ModVersion & " loaded. F3 opens the debug overlay; " &
       "its lines, order, position and toggle key are settings. The " &
       "profiler is OFF by default -- turn on 'Per-mod profiler' and add " &
       "'prof1'..'prof8' to the overlay lines, or GET /aowlspt/debug/profile."
  info "  overlay config: " & gOverlayWriteState
  result = Ok

proc onUnload(): Status =
  ## Leave the profiler exactly as the player left it: the region outlives this
  ## DLL and the host's own instrumentation reads it. Turning it off here would
  ## silently stop measuring the other mods because THIS one was unloaded.
  result = Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
