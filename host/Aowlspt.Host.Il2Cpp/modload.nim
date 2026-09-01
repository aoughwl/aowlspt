# modload.nim -- THE IN-GAME MOD LOADING STEP. `include`d into `aowlhost.nim`
# AFTER `nuikit.nim` (for `nuFindCanvas`/`nuLabel`/`nuSetText`/`nuStyle*`),
# `inspect.nim` (for `iChildCount`/`iChildAt`/`iObjName`/`iFindTarget`) and
# `splrebrand.nim` (for `splAnchor`/`splTmpOf`), because it consumes all three.
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
# ## WHAT IT LOOKS LIKE, and why it changed
#
# The first version was a bordered dark panel listing every mod, one row each,
# floating in the middle of the screen. Seen live, the verdict was that it read
# as a debug overlay bolted onto the game rather than as part of the load, and
# the specific faults were:
#
#   1. it never went away when the main menu appeared;
#   2. it rendered ASYNC, beside the client's own loading flow, not as a step
#      in it;
#   3. it had a background;
#   4. it showed the whole HISTORY -- every mod, forever -- instead of what is
#      happening now;
#   5. it did not match the game's own "Loading profile data..." caption.
#
# So this is now THREE LINES OF TEXT, no background, laid out in the game's own
# caption's frame, directly under it, in its font and size -- Minecraft's mod
# loading screen, which is one line of what it is doing plus two progress
# readings, not a scrolling ledger.
#
# ### On (2), honestly
#
# This is NOT injected into the client's own step list -- doing that means
# detouring whatever drives those captions, and that method is not identified
# on this build. What it does instead is CO-LOCATE: it reparents itself into
# the caption's own parent and adopts the caption's anchors, pivot, height and
# font, so it lives inside the loading UI's container and dies with it. That is
# a real improvement and it is not the same thing as being a step. The log says
# which of the two you got; do not let "STEP-PARENTED" be read as the stronger
# claim.
#
# ## THE FILE FORMAT -- AT MOST THREE LINES, RENDERED VERBATIM
#
# `tools/modbuild.py --screen <file>` rewrites a small plain-text file, in
# full, on every event. The host renders it VERBATIM and parses NOTHING except
# the two control words on line 0. Since the redesign the format is:
#
#     line 0   WHAT IT IS DOING NOW, and the control line.
#              "MODS READY" anywhere at its start = the build is done.
#              "FAILED" anywhere in it            = it finished badly.
#     line 1   OVERALL progress, e.g. "Mods 7 of 15"
#     line 2   THE CURRENT STEP's progress, e.g. "maps  building  12s"
#
#     Loading mods: maps
#     Mods 7 of 15
#     maps  building  12s
#
# Lines past the third are DROPPED, and the host says so once. The writer, not
# the host, decides what the text says -- that is the point of rendering
# verbatim, and it is why a format change belongs in BOTH this comment and
# `Progress.render` in `tools/modbuild.py`, which is the only writer.
#
# The writer swaps it in with `os.replace`, so a torn file is never observed.
#
# ## Failure is visible, never silent
#
# If the compile never starts the file never appears, and this BUILDS NOTHING
# -- an empty caption is indistinguishable from a broken one. If a mod FAILED
# the line naming it is what stays on screen for the whole linger, and the log
# carries it loudly; it is no longer left on screen FOREVER, because defect (1)
# above outranks it and a stuck caption over the main menu is its own bug.

const
  MlPollMs = 250'u64
    ## How often the file is re-read. The compile emits an event every few
    ## seconds at most, so polling faster buys nothing.
  MlMaxRows = 2
    ## Rows BELOW the status line. Three lines total: what it is doing now, the
    ## overall progress, the current step's progress. This was 24 when the
    ## screen was a history list; it is 2 because a loading caption that grows
    ## is not a loading caption.
  MlLingerMs = 1500'u64
    ## How long a clean "MODS READY" stays up, so the step is legible rather
    ## than a flicker.
  MlFailLingerMs = 6_000'u64
    ## How long a run WITH FAILURES stays up. Longer, because that is the one
    ## outcome worth reading -- but bounded, because the old behaviour was "for
    ## ever", and for ever means over the main menu.
  ModLoadNoFileMs* = 3_000'u64
    ## How long to wait for the build to write its FIRST line before concluding
    ## that no build is running at all. Short on purpose: this is the normal
    ## path for an install whose mods are already compiled, and it must not cost
    ## the player a visible pause.
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
  MlSweepBudget = 2000
    ## Nodes the ONE-SHOT survivor sweep may visit after teardown. It calls
    ## `Object::get_name` per node, so it is far more expensive than the other
    ## walks -- it runs exactly once, on the frame we dismiss, and it reports
    ## INCONCLUSIVE rather than PASS if it runs out.
  MlMaxTries = 900
    ## SELF-DISABLE. Attempts at building or at re-matching the style before
    ## this gives up permanently. At a 250ms poll that is ~225s, which outlasts
    ## the 240s deferral deadline's useful window. A feature that retries for
    ## ever is a feature that faults for ever.
  MlLineW = 560.0'f32
  MlRowH = 26.0'f32
    ## Used ONLY on the unmatched path. When a donor caption IS matched, the
    ## line height comes from the donor's own frame, not from here.
  MlPanelFallbackX = 40.0'f32
  MlPanelFallbackY = -40.0'f32
    ## Used ONLY when the canvas rect cannot be read. Top-left is a poor place
    ## for this text -- it reads as a debug overlay pasted on the corner rather
    ## than as a step in the game's own loading. It is kept solely so a rect
    ## read that fails still produces VISIBLE text instead of nothing.
  MlPanelVerticalFrac = 0.62'f32
    ## Where the first line sits as a fraction of canvas height, on the
    ## unmatched path only. Low enough to sit under the splash art.
  MlPadX = 28.0'f32
  MlNeedle = "loading"
    ## The DISPLAYED-TEXT needle for the game's own caption. This is LOCALIZED:
    ## on a non-English client it will not match, `nuStyleNote` says so on every
    ## line it prints, and the honest reading of a miss there is "wrong word",
    ## not "no caption exists". Matching structurally -- the TMP the client's
    ## own loading flow writes into -- is the real fix and needs that method
    ## identified first.
  MlNamePrefix = "aowlspt-modload"
    ## Every GameObject this feature creates is named with this prefix, and the
    ## teardown check is stated as a NEGATIVE over it: after dismissal, no node
    ## under the canvas may still carry it.

# The globals (gModLoad, gModLoadScreenPath, gModLoadBuilt, gModLoadRows,
# gModLoadPanel, gModLoadTitle, gModLoadText, gModLoadPolledAt, gModLoadReadyAt,
# gModLoadDone, gModLoadDonor, gModLoadDonorWarned, gModLoadCanvasTr,
# gModLoadStyled, gModLoadTries, gModLoadFailed) are declared in aowlhost.nim
# beside the other feature globals.

proc mlSplitLines(text: string; maxRows: int): seq[string] =
  ## The file, split, with a trailing PARTIAL line dropped. The writer always
  ## terminates its last line, so a non-empty remainder means a short read --
  ## and half a line on a loading screen reads as corruption, not as progress.
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

proc mlParentTransformOf(node: Il2CppPtr): Il2CppPtr =
  ## `Transform::get_parent`, guarded, by target name -- the same resolution
  ## `iParentName` uses, so the two cannot drift onto different methods.
  result = nil
  if node == nil: return
  var idx = 0
  var hits = 0
  if not iFindTarget("Transform::get_parent", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(node):
    return
  iMark("Transform::get_parent", node)
  let par = cast[Il2CppPtr](cInspUP(fn, node, nil))
  if par == nil or not nuOk(par, 0x20'i32) or not nuAlive(par):
    return
  result = par

proc mlSweepSurvivors(rootTr: Il2CppPtr; found: var int): bool =
  ## THE NEGATIVE CHECK, and the deliverable of the teardown fix.
  ##
  ## "We called destroy" is not evidence of anything -- a destroyed Unity
  ## object stays perfectly readable and a handle table can lie about it. This
  ## walks the LIVE TREE and counts nodes still named with our prefix. The
  ## property asserted is one that can FAIL: a leak, a reparent we forgot, or a
  ## label whose handle went stale before we destroyed it all show up as a
  ## non-zero count.
  ##
  ## Returns false when the budget ran out before the walk finished -- that is
  ## INCONCLUSIVE, not PASS. "I could not look" is not a clean bill of health.
  found = 0
  if rootTr == nil or not nuOk(rootTr, 0x10'i32) or not nuAlive(rootTr):
    return false
  var budget = MlSweepBudget
  var frontier: seq[Il2CppPtr] = @[rootTr]
  while frontier.len > 0 and budget > 0:
    var nextRow: seq[Il2CppPtr] = @[]
    for node in frontier:
      if budget <= 0: break
      dec budget
      let nm = iObjName(node)
      if nm.len > 0 and find(nm, MlNamePrefix) >= 0:
        inc found
      var n = 0
      if iChildCount(node, n):
        for i in 0 ..< n:
          if nextRow.len >= budget: break
          let c = iChildAt(node, i)
          if c != nil: nextRow.add c
    frontier = nextRow
  result = frontier.len == 0        # the walk finished on its own terms

proc mlDestroy() =
  ## Tear the text down. Every handle goes through nuikit's generation-checked
  ## table, so a stale one is REFUSED rather than dereferenced -- which matters
  ## because a destroyed UnityEngine.Object stays perfectly readable with
  ## m_CachedPtr zeroed, and a pointer check on it passes.
  ##
  ## Reparenting into the game's loading container makes that MORE likely, not
  ## less: Unity destroys our labels with their parent, so by the time we get
  ## here the handles may already be dead. That is expected and must not be an
  ## error -- what matters is the survivor sweep afterwards, not these calls.
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) != 0'u32:
      if nuLive(gModLoadRows[i]):
        discard nuDestroy(gModLoadRows[i])
      gModLoadRows[i] = nuNone
  gModLoadRows.setLen(0)
  if uint32(gModLoadTitle) != 0'u32:
    if nuLive(gModLoadTitle):
      discard nuDestroy(gModLoadTitle)
    gModLoadTitle = nuNone
  # There is no background any more (defect 3). This stays so that a handle
  # left over from a build that predates the redesign is still torn down rather
  # than orphaned on screen.
  if uint32(gModLoadPanel) != 0'u32:
    if nuLive(gModLoadPanel):
      discard nuDestroy(gModLoadPanel)
    gModLoadPanel = nuNone
  gModLoadBuilt = false

proc mlDismiss(why: string) =
  ## Destroy, then PROVE it, then stop for good. Three outcomes, never two.
  if gModLoadDone and not gModLoadBuilt:
    return
  mlDestroy()
  gModLoadDone = true
  var survivors = 0
  let complete = mlSweepSurvivors(gModLoadCanvasTr, survivors)
  if not complete:
    warn "mod loading step: dismissed (" & why & ") -- teardown check " &
         "INCONCLUSIVE: the survivor sweep hit its " & $MlSweepBudget &
         "-node budget before finishing, so it did NOT establish that nothing " &
         "named \"" & MlNamePrefix & "*\" is left under the canvas. It found " &
         $survivors & " so far. This is not a pass."
  elif survivors != 0:
    warn "mod loading step: dismissed (" & why & ") -- teardown FAILED: " &
         $survivors & " node(s) named \"" & MlNamePrefix & "*\" are STILL " &
         "under the canvas after every handle was destroyed. Something we " &
         "created outlived its handle; that is a leak on the player's screen."
  else:
    okLog "mod loading step: dismissed (" & why & ") -- teardown PASSED: a " &
          "walk of the live canvas subtree found ZERO nodes named \"" &
          MlNamePrefix & "*\". This is read back off the tree, not off our " &
          "own handles."

proc mlFindDonorTmp(rootTr: Il2CppPtr): Il2CppPtr =
  ## A live TextMeshProUGUI to copy font + materials from.
  ##
  ## `nuLabel` REFUSES without one, deliberately and correctly: TMP's Awake
  ## reaches for the default font through TMP_Settings and faults, so a
  ## best-effort label would crash the client rather than look wrong.
  ##
  ## Every other proof in this host takes its donor from `gMi2Tmp`, which is
  ## only populated once somebody opens Settings and invoke2 walks to a tab.
  ## That is useless here -- this has to exist DURING BOOT, long before any of
  ## that. So the canvas subtree is searched breadth-first, bounded, for any
  ## node that carries a TMP.
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

proc mlStyleUsable(s: NuStyle): bool =
  ## A style we can actually LAY OUT from -- matched AND with a complete frame.
  ## `ok` alone is not enough: a font size without anchors positions nothing.
  s.ok and s.geom and s.node != nil and s.donor != nil

proc mlApplyStyle(s: NuStyle): bool =
  ## Put the existing lines into the donor's frame and font. Called both right
  ## after a build and, crucially, on a LATER poll once the game's caption has
  ## finally appeared -- which is the whole reason the match kept failing.
  if not mlStyleUsable(s): return false
  if uint32(gModLoadTitle) == 0'u32: return false
  var okAll = true
  # Line 0 sits ONE line below the caption; each row one further down. The
  # donor's own height is the line height, so this tracks the game's leading
  # instead of a number we made up.
  let lh = (if s.h > 1.0'f32 and s.h < 400.0'f32: s.h else: MlRowH)
  if not nuStyleFont(gModLoadTitle, s): okAll = false
  if not nuStyleLayout(gModLoadTitle, s, 0.0'f32, -lh): okAll = false
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) == 0'u32: continue
    if not nuStyleFont(gModLoadRows[i], s): okAll = false
    if not nuStyleLayout(gModLoadRows[i], s, 0.0'f32,
                         -(lh * float32(i + 2))): okAll = false
  result = okAll

proc mlVerifyStyle(s: NuStyle) =
  ## READ BACK what landed and compare it against the DONOR -- not against what
  ## we passed in. A check that re-reads its own write cannot fail; this one
  ## fails whenever `set_fontSize` declines or lands on the wrong component.
  if not mlStyleUsable(s):
    warn "mod loading step: style NOT verified -- there was no usable donor " &
         "frame to compare against. " & nuStyleNote(s)
    return
  let (gotOk, got) = nuElemFontSize(gModLoadTitle)
  if not gotOk:
    warn "mod loading step: style check INCONCLUSIVE -- the live TMP's " &
         "m_fontSize could not be read back, so whether the caption font " &
         "took is UNKNOWN. It is not a pass."
    return
  let diff = (if got > s.fontSize: got - s.fontSize else: s.fontSize - got)
  if diff > 0.01'f32:
    warn "mod loading step: style check FAILED -- our line reads back font " &
         nuF(got) & " while the game's caption is font " & nuF(s.fontSize) &
         ". The setter was called and did NOT take."
  else:
    okLog "mod loading step: style check PASSED -- our line reads back font " &
          nuF(got) & " off the live TMP, equal to the game's own caption " &
          "\"" & s.text & "\" (font " & nuF(s.fontSize) & "), in that " &
          "caption's own anchors/pivot, one line below it."

proc mlBuild(lines: seq[string]): bool =
  ## Build the three lines once. Returns false having destroyed anything
  ## partial: a half-built caption is never left on the display, and nuikit has
  ## already logged which hop refused.
  # EVERY refusal below says which hop refused, ONCE. The first version of this
  # returned nil silently from the anchor and canvas hops, and the result was a
  # screen that never appeared with nothing at all in the log to say why -- the
  # exact silent-decline failure CLAUDE.md section 6 calls the worst outcome we
  # produce. `gModLoadWhy` makes each distinct reason print once and then stop,
  # so a six-minute compile does not repeat it 1400 times.
  template mlWhyOnce(tag: string; msg: string) =
    if gModLoadWhy != tag:
      gModLoadWhy = tag
      warn "mod loading step: not built yet -- " & msg

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
    mlWhyOnce("kitoff", "the native UI toolkit is OFF, so nothing can be " &
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
  gModLoadCanvasTr = canvasTr        # remembered so the survivor sweep has a root

  # PREFER THE GAME'S OWN LOADING CAPTION as the donor. It gives us its font
  # and materials for free, and its frame tells us where the player is already
  # looking. Falling back to "any TMP under the canvas" still renders -- it
  # just will not match, and the log will say NOT matched rather than pretend.
  #
  # nuikit's nuStyleFind, not a private copy: matching the game's look is a
  # TOOLKIT capability, so the mods tab and the settings rows get it too.
  let style = nuStyleFind(canvasTr, MlNeedle)
  var donor = style.donor
  if donor == nil:
    donor = mlFindDonorTmp(canvasTr)
  if donor == nil:
    # Say this ONCE. Repeating it every 250ms for a six-minute compile would
    # bury the log this project reads to find out what happened.
    if not gModLoadDonorWarned:
      gModLoadDonorWarned = true
      gModLoadWhy = "donor"
      warn "mod loading step: a canvas was found but no live " &
           "TextMeshProUGUI donor exists under it yet, and nuLabel REFUSES " &
           "without one (TMP's Awake faults reaching for the default font " &
           "through TMP_Settings). It will build as soon as one appears. The " &
           "compile itself is unaffected -- its progress is in " &
           gModLoadScreenPath & "."
    return false

  let rows = min(lines.len - 1, MlMaxRows)
  if rows < 0:
    return false

  # WHERE THE LINES GO, and under WHAT PARENT.
  #
  # Matched: into the caption's own parent, in the caption's anchors and pivot,
  # one line below it -- so this reads as the next line of the load the player
  # is already watching, and Unity tears it down with the loading UI.
  #
  # Unmatched: centred low on the canvas from a READ canvas rect, or, if even
  # that read fails, the fallback corner -- because text in the wrong place is
  # still better than nothing, and the log says which happened rather than
  # leaving it to be guessed.
  var parentGo = canvasGo
  var px = MlPanelFallbackX
  var py = MlPanelFallbackY
  var lineH = MlRowH
  var fontSize = 18.0'f32
  var placed = "FALLBACK top-left (the canvas rect could not be read)"
  let (rectOk, _, _, cw, ch) = nuGetRect(canvasTr)
  if rectOk and cw > 1.0'f32 and ch > 1.0'f32:
    px = (cw - MlLineW) * 0.5'f32 + MlPadX
    py = -(ch * MlPanelVerticalFrac)
    placed = "centred on a " & nuF(cw) & "x" & nuF(ch) & " canvas"

  let usable = mlStyleUsable(style)
  if usable:
    let par = mlParentTransformOf(style.node)
    if par != nil:
      let pgo = nuGameObjectOf(par)
      if pgo != nil and nuOk(pgo, 0x10'i32) and nuAlive(pgo):
        parentGo = pgo
        placed = "STEP-PARENTED into the game caption's own parent (it dies " &
                 "with the loading UI), " & placed
    if style.h > 1.0'f32 and style.h < 400.0'f32:
      lineH = style.h
    fontSize = style.fontSize
  placed = nuStyleNote(style) & "; " & placed

  # NO PANEL. Defect (3): the game's own loading captions are bare text, so
  # this is bare text. Nothing here creates an Image, which is also what makes
  # the "no background among our objects" check trivially true and checkable --
  # the survivor sweep looks for `aowlspt-modload-panel` and must find none.
  gModLoadTitle = nuLabel(parentGo, donor,
                          px, py, MlLineW, lineH,
                          (if lines.len > 0: lines[0] else: "Loading mods..."),
                          fontSize, 1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32,
                          MlNamePrefix & "-line0")
  if uint32(gModLoadTitle) == 0'u32:
    return false

  gModLoadRows.setLen(rows)
  for i in 0 ..< rows:
    gModLoadRows[i] = nuNone
  for i in 0 ..< rows:
    let y = py - lineH * float32(i + 1)
    gModLoadRows[i] = nuLabel(parentGo, donor,
                              px, y, MlLineW, lineH,
                              lines[i + 1], fontSize,
                              0.80'f32, 0.80'f32, 0.80'f32, 1.0'f32,
                              MlNamePrefix & "-line" & $(i + 1))
    if uint32(gModLoadRows[i]) == 0'u32:
      mlDestroy()
      return false

  gModLoadBuilt = true
  if usable:
    gModLoadStyled = mlApplyStyle(style)
    if gModLoadStyled:
      # THE DISMISSAL SIGNAL. From here on `gModLoadDonor` is the game's OWN
      # loading caption, not just any TMP we borrowed a font from, and
      # `mlLoadPhaseOver` watches THAT object for destruction. Keep the two in
      # step: if this assignment is dropped, the menu check silently watches an
      # unrelated label that never dies, and the text never goes away -- which
      # is the exact defect this rewrite exists to fix.
      gModLoadDonor = style.donor
  okLog "mod loading step: BUILT -- " & $(rows + 1) & " text line(s), NO " &
        "background, " & placed & ", from " & gModLoadScreenPath &
        ". This is what the player sees while the mods folder compiles."
  if usable:
    mlVerifyStyle(style)
  return true

proc mlRetryStyle() =
  ## THE FIX FOR DEFECT (5). The game's "Loading profile data..." caption is
  ## TRANSIENT -- measured: `findtext "Loading" $preloader 60000 all` at the
  ## MENU searched 4,095 nodes EXHAUSTIVELY and found none, so at the menu it
  ## genuinely does not exist. It exists only DURING the load, which may well
  ## be after we built. Matching only once, at build time, therefore fails
  ## whenever we are early -- and being early is the normal case for a feature
  ## whose whole purpose is to be on screen before the load finishes.
  ##
  ## So: keep looking on later polls, and RE-APPLY when it finally shows up.
  if gModLoadStyled or not gModLoadBuilt: return
  if gModLoadCanvasTr == nil: return
  let s = nuStyleFind(gModLoadCanvasTr, MlNeedle)
  if not mlStyleUsable(s): return
  if not mlApplyStyle(s): return
  gModLoadStyled = true
  gModLoadDonor = s.donor      # see mlBuild: this is the dismissal signal
  # Reparenting an existing label would mean re-aligning it under a new parent
  # mid-flight; the layout above already puts it in the caption's frame, so the
  # position matches even when the parent does not. SAY THAT, rather than let
  # a later reader assume this took the STEP-PARENTED path.
  okLog "mod loading step: RE-STYLED on a later frame -- the game's own " &
        "caption had not spawned when we built, and has now. " & nuStyleNote(s) &
        " (position matched; NOT reparented, because the lines already exist " &
        "under the canvas)"
  mlVerifyStyle(s)

proc mlRefresh(lines: seq[string]) =
  ## Update the existing labels in place: `set_text` only, no GameObject
  ## allocation, which is what makes refreshing affordable while the client is
  ## otherwise busy. A render with MORE lines than we built for rebuilds rather
  ## than silently truncating.
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

proc mlLoadPhaseOver(): bool =
  ## HAS THE MAIN MENU ARRIVED? Answered only when we can answer it honestly.
  ##
  ## The signal is the game's OWN loading caption: we matched it, we hold its
  ## transform, and it exists only while the load runs. When Unity reports it
  ## destroyed, the load phase it belonged to is over. That is a property of
  ## the client's state, not of our timers.
  ##
  ## When we never matched a caption there IS no such signal here, and this
  ## says NO rather than guessing -- the linger timers below are what dismiss
  ## us on that path. Do not "improve" this into a heuristic that returns true
  ## on a timeout; a false positive here erases the screen mid-build.
  if not gModLoadStyled: return false
  if gModLoadDonor == nil: return false
  result = not nuAlive(gModLoadDonor)

proc modLoadTick() =
  ## Runs from the shared per-frame drain, on the Unity main thread, inside the
  ## existing guard -- this adds NO guard of its own, because `aowl_p_p_seh` is
  ## not re-entrant and a nested one would disarm the outer. Cheap when idle:
  ## one clock compare, then one small file read, and it returns immediately
  ## when the contents have not changed.
  if not gModLoad or gModLoadDone:
    return
  let now = cNowMs()
  if now - gModLoadPolledAt < MlPollMs:
    return
  gModLoadPolledAt = now

  # SELF-DISABLE. Bounded attempts, then stop for good -- and say so, because
  # a feature that quietly stops is the failure mode this host least tolerates.
  inc gModLoadTries
  if gModLoadTries > MlMaxTries:
    warn "mod loading step: SELF-DISABLED after " & $MlMaxTries & " polls " &
         "without reaching a finished state. Anything already on screen is " &
         "torn down now rather than left over the menu. The mods themselves " &
         "are released by the deadline path, independently of this."
    modLoadReleaseMods("the loading step self-disabled after " &
                       $MlMaxTries & " polls")
    mlDismiss("self-disabled after " & $MlMaxTries & " polls")
    return

  # THE MENU CHECK, BEFORE ANYTHING ELSE. Defect (1): the old code had exactly
  # one dismissal path -- a clean READY plus a linger -- so a run that never
  # reported READY, or reported FAILED, left the text on screen for ever,
  # including over the main menu. This is now checked every tick regardless of
  # what the file says.
  if gModLoadBuilt and mlLoadPhaseOver():
    modLoadReleaseMods("the client's own loading caption is gone, so the " &
                       "load phase ended; the mods must not be withheld past it")
    mlDismiss("the game's own loading caption was destroyed -- the load " &
              "phase is over and the menu is up")
    return

  var text = ""
  if not readTextFile(gModLoadScreenPath, text) or text.len == 0:
    # NO FILE: nothing is compiling. Build NOTHING -- an empty caption is
    # indistinguishable from a broken one, and this must not invent a screen it
    # has no content for.
    #
    # But it must also RELEASE THE MODS, quickly, and that is a correctness fix
    # rather than a nicety: `deferModLoad` skips loadAll at boot and waits for
    # this file, so on an install whose mods are already built -- where no
    # compile ever runs and the file never appears -- every single boot would
    # sit modless until the 240s deadline. A feature that makes the normal case
    # four minutes slower is worse than no feature.
    #
    # A short grace is still allowed, because the compile may not have written
    # its first line yet; after that, absence is an answer.
    if gModLoadDeferMods and not gModsReleased and
       gModLoadDeferredAt != 0'u64 and
       now - gModLoadDeferredAt > ModLoadNoFileMs:
      modLoadReleaseMods("no build is running (" & gModLoadScreenPath &
                         " never appeared within " &
                         $int(ModLoadNoFileMs div 1000'u64) & "s), so there is " &
                         "nothing to wait for. This is the NORMAL path on an " &
                         "install whose mods are already built.")
    return

  let changed = text != gModLoadText
  gModLoadText = text
  # MlMaxRows + 1 lines total. Anything past that is DROPPED -- and said once,
  # because a writer that outgrew the protocol is a real bug and silently
  # truncating it is how the screen would go back to being a history list.
  # Split ONE line past the protocol on purpose, so the overrun can be SEEN.
  # Splitting exactly at the cap makes "the writer sent too much" and "the
  # writer sent exactly enough" produce identical output -- a check that
  # cannot fail, which is the bug shape CLAUDE.md 9b names.
  let raw = mlSplitLines(text, MlMaxRows + 1)
  if raw.len == 0:
    return
  let keep = min(raw.len, MlMaxRows + 1)
  var lines: seq[string] = @[]
  for i in 0 ..< keep:
    lines.add raw[i]
  if raw.len > MlMaxRows + 1 and gModLoadWhy != "toolong":
    gModLoadWhy = "toolong"
    warn "mod loading step: " & gModLoadScreenPath & " carries more than " &
         $(MlMaxRows + 1) & " lines. Only the first " & $(MlMaxRows + 1) &
         " are rendered (what it is doing now, overall progress, current step " &
         "progress). The writer -- Progress.render in tools/modbuild.py -- is " &
         "the thing to fix; the host renders verbatim on purpose."

  if not gModLoadBuilt:
    # RETRY EVERY POLL while unbuilt, not only when the file changes.
    #
    # The first version only attempted a build on a file change, and that is
    # wrong for the reason this feature exists: the compile starts BEFORE the
    # client has a canvas, so the first attempt reliably fails ("no anchor
    # yet"), and the file may then never change again -- a cached build writes
    # its final state once and stops. It would then never appear, and the log
    # would carry a single "not built yet" line explaining a permanent
    # condition as if it were transient. Measured exactly that: `$preloader`
    # was live minutes later and nothing had re-tried.
    #
    # Retrying is cheap: mlBuild returns at its first refusal, and mlWhyOnce
    # keeps the log to one line per distinct reason.
    discard mlBuild(lines)
  else:
    if changed:
      mlRefresh(lines)
    mlRetryStyle()

  # The done marker is only acted on ONCE THE TEXT IS ACTUALLY UP. A fully
  # cached build writes "MODS READY" as its very first (and only) render, so
  # arming the dismiss timer on the reading rather than on the display would
  # start the clock before a canvas even exists -- and it would be torn down
  # having never been shown. `linger` means "after it is visible".
  if gModLoadBuilt:
    # "MODS READY" is the writer's own done marker.
    if lines[0].startsWith("MODS READY"):
      if gModLoadReadyAt == 0'u64:
        gModLoadReadyAt = now
      if find(lines[0], "FAILED") < 0:
        # The build is done and clean: this is the intended release point.
        modLoadReleaseMods("the mod build reported READY: " & lines[0])
      elif not gModLoadFailed:
        gModLoadFailed = true
        # A run with a failed mod stays up LONGER, on purpose -- but it is no
        # longer left up for ever. "For ever" meant "over the main menu", which
        # is defect (1) and outranks this. The failure is shouted into the log,
        # which is where it survives the dismissal.
        warn "mod loading step: the build finished with FAILURES. The line " &
             "naming them stays on screen for " &
             $int(MlFailLingerMs div 1000'u64) & "s and is recorded here so " &
             "it outlives the screen: " & lines[0]
        # Release anyway. Some mods failed; the ones that BUILT are still real
        # and withholding them helps nobody.
        modLoadReleaseMods("the build finished WITH FAILURES; the mods that " &
                           "did build are loaded and the line keeps naming " &
                           "the ones that did not")

  # THE DEADLINE. Checked every tick, and deliberately independent of whether
  # anything ever built: the text is cosmetic, the mods are not.
  if gModLoadDeferMods and not gModsReleased and gModsDirDeferred.len > 0 and
     gModLoadDeferredAt != 0'u64 and
     now - gModLoadDeferredAt > ModLoadDeferMaxMs:
    modLoadReleaseMods("the build never reported ready within " &
                       $int(ModLoadDeferMaxMs div 1000'u64) & "s, so the " &
                       "deadline fired. The loading step did not finish; " &
                       "the mods are loaded anyway rather than lost.")

  if gModLoadReadyAt != 0'u64:
    let linger = (if gModLoadFailed: MlFailLingerMs else: MlLingerMs)
    if now - gModLoadReadyAt > linger:
      mlDismiss((if gModLoadFailed:
                   "the build finished WITH FAILURES and its linger expired"
                 else: "a clean build, after its linger"))

proc bindModLoad(verbose: bool): bool =
  ## Nothing is detoured: this rides the existing per-frame drain. It resolves
  ## the file it will render and states once what it is doing -- including the
  ## normal case where there is nothing to render.
  if not gModLoad:
    return false
  if gModLoadScreenPath.len == 0:
    gModLoadScreenPath = joinPath(gDir, "aowlspt-modload.txt")
  if verbose:
    okLog "mod loading step ARMED: renders the first " & $(MlMaxRows + 1) &
          " lines of " & gModLoadScreenPath & " verbatim -- what it is doing " &
          "now, the overall progress, the current step's progress -- as bare " &
          "text with NO background, in the game's own loading caption's font " &
          "and frame where that caption can be found, and builds NOTHING at " &
          "all until that file exists. `modLoadScreen: false` turns it off."
  return true
