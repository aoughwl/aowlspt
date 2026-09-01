# modload.nim -- THE IN-GAME MOD LOADING SCREEN. `include`d into `aowlhost.nim`
# AFTER `nuikit.nim` (for `nuFindCanvas`/`nuPanel`/`nuLabel`/`nuSetText`),
# `inspect.nim` (for `iChildCount`/`iChildAt`) and `splrebrand.nim` (for
# `splAnchor`/`splTmpOf`), because it consumes all three.
#
# ## What it is for
#
# aowlspt ships its mods as SOURCE and compiles what changed at startup. That
# takes real time: measured on this machine, a cold build of all 15 mods is
# about six minutes, and `maps` alone is 83 seconds. Without a screen every
# second of that is an unexplained wait, and the player cannot tell "compiling"
# from "hung" -- which is the same indistinguishability problem the error-dialog
# catch exists to solve, one layer up.
#
# So the client shows OUR step: a panel listing every mod and what is happening
# to it -- building, cached, built in Ns, or FAILED. It is the moment the
# source-shipping design becomes visible instead of mysterious.
#
# ## Where the content comes from, and why the host parses nothing
#
# `tools/modbuild.py --screen <file>` rewrites a small plain-text file, in full,
# on every event:
#
#     BUILDING MODS  3 of 15
#       tarkov         cached
#       fov            built     0.2s
#       maps           building
#
# The host renders those lines VERBATIM, one label each. It deliberately does
# NOT read the JSON progress stream beside it: parsing JSON on the Unity main
# thread every frame, inside the guard, would allocate per frame -- against this
# host's own rule. The file is under a kilobyte, so it is simply read and
# compared as a whole string; when it is unchanged, nothing else happens.
#
# The writer swaps it in with `os.replace`, so a torn file is never observed.
#
# ## Failure is visible, never silent
#
# If the compile never starts the file never appears, and this BUILDS NOTHING --
# an empty panel with no rows is indistinguishable from a broken one. If a mod
# FAILED, that row stays on screen and the panel does not auto-dismiss, because
# that is the one outcome the player actually needs to read.

const
  MlPollMs = 250'u64
    ## How often the file is re-read. The compile emits an event every few
    ## seconds at most, so polling faster buys nothing.
  MlMaxRows = 24
    ## Hard cap on labels: a mods folder with hundreds of entries must not turn
    ## a loading screen into a thousand-GameObject storm on the Unity thread.
  MlLingerMs = 1500'u64
    ## How long a clean "MODS READY" stays up, so the step is legible rather
    ## than a flicker.
  ModLoadDeferMaxMs* = 240_000'u64
    ## HARD DEADLINE on the deferral. A cold build of all 15 mods measured ~6
    ## minutes here, but the common case is a fully cached start that reports in
    ## under a second. Four minutes is generous for the usual case and still
    ## bounded: past it the mods are loaded regardless, because a screen that
    ## never finishes must not silently cost the player every mod they have.
  MlDonorBudget = 3000
    ## Nodes the donor search may visit, total. Bounded like every other walk in
    ## this host: an unbounded descent on a scene full of geometry is how
    ## natesp's own walk burned 20,000 nodes and never reached any UI.
  MlPanelW = 560.0'f32
  MlRowH = 26.0'f32
  MlPanelX = 40.0'f32
  MlPanelY = -40.0'f32
  MlPadX = 28.0'f32
  MlPadY = 22.0'f32

# The globals (gModLoad, gModLoadScreenPath, gModLoadBuilt, gModLoadRows,
# gModLoadPanel, gModLoadTitle, gModLoadText, gModLoadPolledAt, gModLoadReadyAt,
# gModLoadDone, gModLoadDonor, gModLoadDonorWarned) are declared in aowlhost.nim
# beside the other feature globals.

proc mlSplitLines(text: string; maxRows: int): seq[string] =
  ## The file, split, with a trailing PARTIAL line dropped. The writer always
  ## terminates its last line, so a non-empty remainder means a short read --
  ## and half a row on a loading screen reads as corruption, not as progress.
  result = @[]
  var cur = ""
  for ch in text:
    if ch == '\n':
      result.add cur
      cur = ""
      if result.len > maxRows:
        return
    elif ch != '\r':
      cur.add ch

proc mlDestroy() =
  ## Tear the panel down. Every handle goes through nuikit's generation-checked
  ## table, so a stale one is REFUSED rather than dereferenced -- which matters
  ## because a destroyed UnityEngine.Object stays perfectly readable with
  ## m_CachedPtr zeroed, and a pointer check on it passes.
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) != 0'u32:
      discard nuDestroy(gModLoadRows[i])
      gModLoadRows[i] = nuNone
  gModLoadRows.setLen(0)
  if uint32(gModLoadTitle) != 0'u32:
    discard nuDestroy(gModLoadTitle)
    gModLoadTitle = nuNone
  if uint32(gModLoadPanel) != 0'u32:
    discard nuDestroy(gModLoadPanel)
    gModLoadPanel = nuNone
  gModLoadBuilt = false

proc mlFindDonorTmp(rootTr: Il2CppPtr): Il2CppPtr =
  ## A live TextMeshProUGUI to copy font + materials from.
  ##
  ## `nuLabel` REFUSES without one, deliberately and correctly: TMP's Awake
  ## reaches for the default font through TMP_Settings and faults, so a
  ## best-effort label would crash the client rather than look wrong.
  ##
  ## Every other proof in this host takes its donor from `gMi2Tmp`, which is
  ## only populated once somebody opens Settings and invoke2 walks to a tab.
  ## That is useless here -- this screen has to exist DURING BOOT, long before
  ## any of that. So the canvas subtree is searched breadth-first, bounded, for
  ## any node that carries a TMP.
  if gModLoadDonor != nil and nuAlive(gModLoadDonor):
    return gModLoadDonor
  if rootTr == nil:
    return nil
  var budget = MlDonorBudget
  var frontier: seq[Il2CppPtr] = @[rootTr]
  # Breadth-first, not depth-first: a TMP under a menu canvas is shallow, and a
  # DFS would spend the whole budget in the first large subtree it entered.
  while frontier.len > 0 and budget > 0:
    var nextRow: seq[Il2CppPtr] = @[]
    for node in frontier:
      if budget <= 0: break
      dec budget
      let tmp = splTmpOf(node)
      if tmp != nil:
        gModLoadDonor = tmp
        return tmp
      var n = 0
      if iChildCount(node, n):
        for i in 0 ..< n:
          if nextRow.len >= budget: break
          let c = iChildAt(node, i)
          if c != nil: nextRow.add c
    frontier = nextRow
  result = nil

proc mlBuild(lines: seq[string]): bool =
  ## Build the panel once. Returns false having destroyed anything partial: a
  ## half-built screen is never left on the display, and nuikit has already
  ## logged which hop refused.
  # EVERY refusal below says which hop refused, ONCE. The first version of this
  # returned nil silently from the anchor and canvas hops, and the result was a
  # screen that never appeared with nothing at all in the log to say why -- the
  # exact silent-decline failure CLAUDE.md section 6 calls the worst outcome we
  # produce. `gModLoadWhy` makes each distinct reason print once and then stop,
  # so a six-minute compile does not repeat it 1400 times.
  template mlWhyOnce(tag: string; msg: string) =
    if gModLoadWhy != tag:
      gModLoadWhy = tag
      warn "mod loading screen: not built yet -- " & msg

  let anchor = splAnchor()
  if anchor == nil:
    mlWhyOnce("anchor", "splAnchor() has no DontDestroyOnLoad anchor yet " &
              "(the PreloaderUI::Update `this` has not been captured). This " &
              "is normal very early in boot and resolves itself.")
    return false
  # THE KIT'S OWN FLAGS FIRST. `nkReady` returns false SILENTLY when
  # `nativeUiKit` (or `nativeUi`) is off, so `nuFindCanvas` returns nil for a
  # reason that has nothing to do with canvases. Reporting that as "no usable
  # Canvas" is a confidently wrong diagnostic -- measured: it sent this
  # investigation after the scene graph when the real answer was one config key.
  # Distinguish them, or say nothing.
  if not gNkOn or not gNuOn:
    mlWhyOnce("kitoff", "the native UI toolkit is OFF, so no panel can be " &
              "built: nativeUiKit=" & $gNkOn & " nativeUi=" & $gNuOn &
              ". This is a CONFIG state, not a missing canvas -- set both in " &
              "aowlspt-host.json. Nothing about the scene was examined.")
    return false
  let canvasGo = nuFindCanvas(anchor)
  if canvasGo == nil:
    mlWhyOnce("canvas", "the toolkit is on and an anchor exists, but " &
              "nuFindCanvas found no usable Canvas from the scene roots. Its " &
              "own `nuikit: findCanvas REFUSED` ledger line above says how " &
              "many roots were walked, asked and rejected. Nothing was created.")
    return false
  let canvasTr = nuTransformOf(canvasGo)
  let donor = mlFindDonorTmp(canvasTr)
  if donor == nil:
    # Say this ONCE. Repeating it every 250ms for a six-minute compile would
    # bury the log this project reads to find out what happened.
    if not gModLoadDonorWarned:
      gModLoadDonorWarned = true
      gModLoadWhy = "donor"
      warn "mod loading screen: a canvas was found but no live " &
           "TextMeshProUGUI donor exists under it yet, and nuLabel REFUSES " &
           "without one (TMP's Awake faults reaching for the default font " &
           "through TMP_Settings). The screen will build as soon as one " &
           "appears. The compile itself is unaffected -- its progress is in " &
           gModLoadScreenPath & "."
    return false

  # Panel and labels share ONE parent and are positioned absolutely. That is
  # nuikit's own proven idiom (its self-test parents both into `parentGo`), and
  # it avoids needing the panel's GameObject back out of its handle.
  let rows = min(lines.len - 1, MlMaxRows)
  if rows < 0:
    return false
  let h = MlPadY * 2.0'f32 + MlRowH * float32(rows + 2)
  gModLoadPanel = nuPanel(canvasGo, MlPanelX, MlPanelY, MlPanelW, h,
                          0.05'f32, 0.05'f32, 0.06'f32, 0.92'f32,
                          "aowlspt-modload-panel")
  if uint32(gModLoadPanel) == 0'u32:
    return false

  gModLoadTitle = nuLabel(canvasGo, donor,
                          MlPanelX + MlPadX, MlPanelY - MlPadY,
                          MlPanelW - MlPadX * 2.0'f32, MlRowH,
                          (if lines.len > 0: lines[0] else: "BUILDING MODS"),
                          24.0'f32, 1.0'f32, 0.85'f32, 0.35'f32, 1.0'f32,
                          "aowlspt-modload-title")
  if uint32(gModLoadTitle) == 0'u32:
    mlDestroy()
    return false

  gModLoadRows.setLen(rows)
  for i in 0 ..< rows:
    gModLoadRows[i] = nuNone
  for i in 0 ..< rows:
    let y = MlPanelY - (MlPadY + MlRowH * float32(i + 2))
    gModLoadRows[i] = nuLabel(canvasGo, donor,
                              MlPanelX + MlPadX + 8.0'f32, y,
                              MlPanelW - MlPadX * 2.0'f32 - 8.0'f32, MlRowH,
                              lines[i + 1], 18.0'f32,
                              0.85'f32, 0.85'f32, 0.85'f32, 1.0'f32,
                              "aowlspt-modload-row" & $i)
    if uint32(gModLoadRows[i]) == 0'u32:
      mlDestroy()
      return false

  gModLoadBuilt = true
  okLog "mod loading screen: BUILT -- 1 panel + " & $(rows + 1) &
        " label(s) from " & gModLoadScreenPath &
        ". This is what the player sees while the mods folder compiles."
  return true

proc mlRefresh(lines: seq[string]) =
  ## Update the existing labels in place: `set_text` only, no GameObject
  ## allocation, which is what makes refreshing affordable while the client is
  ## otherwise busy. A render with MORE rows than the panel was built for
  ## rebuilds rather than silently truncating the list.
  if lines.len - 1 > gModLoadRows.len and lines.len - 1 <= MlMaxRows:
    mlDestroy()
    discard mlBuild(lines)
    return
  if uint32(gModLoadTitle) != 0'u32 and lines.len > 0:
    discard nuSetText(gModLoadTitle, lines[0])
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) == 0'u32: continue
    discard nuSetText(gModLoadRows[i],
                      (if i + 1 < lines.len: lines[i + 1] else: ""))

proc modLoadReleaseMods(why: string) =
  ## Load the mods that boot deliberately skipped.
  ##
  ## Called on exactly two paths, and BOTH must exist:
  ##   * the build reported ready -- the intended one;
  ##   * the deadline expired -- the safety net.
  ## `why` names which, in the log, because "my mods are missing" and "my mods
  ## loaded four minutes late" have completely different causes and a single
  ## message for both would hide that.
  if gModsReleased or gModsDirDeferred.len == 0:
    return
  gModsReleased = true
  okLog "mod loading: releasing deferred mods now -- " & why
  if modhost.loadAll(gModsDirDeferred, modhost.SideClient,
                     HostName, HostVersion) == 0:
    warn "mod loading: the deferred load produced NO mods from " &
         gModsDirDeferred & ". If mods were expected, this is the failure to " &
         "chase -- the client started clean on purpose and nothing filled it."

proc modLoadTick() =
  ## Runs from the shared per-frame drain, on the Unity main thread, inside the
  ## existing guard. Cheap when idle: one clock compare, then one small file
  ## read, and it returns immediately when the contents have not changed.
  if not gModLoad or gModLoadDone:
    return
  let now = cNowMs()
  if now - gModLoadPolledAt < MlPollMs:
    return
  gModLoadPolledAt = now

  var text = ""
  if not readTextFile(gModLoadScreenPath, text) or text.len == 0:
    # No file: the compile has not started, or this install does not compile at
    # startup at all. Build NOTHING. An empty panel is indistinguishable from a
    # broken one, and this feature must not invent a screen it has no content
    # for.
    return

  let changed = text != gModLoadText
  gModLoadText = text
  let lines = mlSplitLines(text, MlMaxRows)
  if lines.len == 0:
    return

  if not gModLoadBuilt:
    # RETRY EVERY POLL while unbuilt, not only when the file changes.
    #
    # The first version only attempted a build on a file change, and that is
    # wrong for the reason this feature exists: the compile starts BEFORE the
    # client has a canvas, so the first attempt reliably fails ("no anchor
    # yet"), and the file may then never change again -- a cached build writes
    # its final state once and stops. The panel would then never appear, and
    # the log would carry a single "not built yet" line explaining a permanent
    # condition as if it were transient. Measured exactly that: `$preloader`
    # was live minutes later and nothing had re-tried.
    #
    # Retrying is cheap: mlBuild returns at its first refusal, and mlWhyOnce
    # keeps the log to one line per distinct reason.
    discard mlBuild(lines)
  elif changed:
    mlRefresh(lines)

  # The done marker is only acted on ONCE THE PANEL IS ACTUALLY UP. A fully
  # cached build writes "MODS READY" as its very first (and only) render, so
  # arming the dismiss timer on the reading rather than on the display would
  # start the 1.5s clock before a canvas even exists -- and the screen would be
  # torn down having never been shown. `linger` means "after it is visible".
  if gModLoadBuilt:
    # "MODS READY" is the writer's own done marker.
    if lines[0].startsWith("MODS READY"):
      if find(lines[0], "FAILED") < 0:
        if gModLoadReadyAt == 0'u64:
          gModLoadReadyAt = now
        # The build is done and clean: this is the intended release point.
        modLoadReleaseMods("the mod build reported READY: " & lines[0])
      else:
        # A run with a failed mod keeps the panel up ON PURPOSE. Dismissing it
        # would hide the only evidence the player has that a mod is missing.
        warn "mod loading screen: the build finished with FAILURES, so the " &
             "panel is LEFT ON SCREEN deliberately -- that is the one outcome " &
             "worth reading. " & lines[0]
        # Release anyway. Some mods failed; the ones that BUILT are still real
        # and withholding them helps nobody. The panel stays up naming the
        # failures, which is where that information belongs.
        modLoadReleaseMods("the build finished WITH FAILURES; the mods that " &
                           "did build are loaded and the panel keeps naming " &
                           "the ones that did not")
        gModLoadDone = true

  # THE DEADLINE. Checked every tick, before the dismiss logic, and
  # deliberately independent of whether the panel ever built: the panel is
  # cosmetic, the mods are not.
  if gModLoadDeferMods and not gModsReleased and gModsDirDeferred.len > 0 and
     gModLoadDeferredAt != 0'u64 and
     now - gModLoadDeferredAt > ModLoadDeferMaxMs:
    modLoadReleaseMods("the build never reported ready within " &
                       $int(ModLoadDeferMaxMs div 1000'u64) & "s, so the " &
                       "deadline fired. The loading screen did not finish; " &
                       "the mods are loaded anyway rather than lost.")

  if gModLoadReadyAt != 0'u64 and now - gModLoadReadyAt > MlLingerMs:
    mlDestroy()
    gModLoadDone = true
    okLog "mod loading screen: dismissed after a clean build."

proc bindModLoad(verbose: bool): bool =
  ## Nothing is detoured: this rides the existing per-frame drain. It resolves
  ## the file it will render and states once what it is doing -- including the
  ## normal case where there is nothing to render.
  if not gModLoad:
    return false
  if gModLoadScreenPath.len == 0:
    gModLoadScreenPath = joinPath(gDir, "aowlspt-modload.txt")
  if verbose:
    okLog "mod loading screen ARMED: renders " & gModLoadScreenPath &
          " verbatim while the mods folder compiles, and builds NOTHING at " &
          "all until that file exists. `modLoadScreen: false` turns it off."
  return true
