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
  MlSweepDelayMs = 750'u64
    ## How long AFTER teardown the survivor sweep waits before walking.
    ##
    ## `nuDestroy` calls `UnityEngine.Object::Destroy`, which is DEFERRED to
    ## the end of the frame -- NOT `DestroyImmediate`. The first version swept
    ## in the same frame as the destroy and therefore found every one of our
    ## own nodes still parented, and reported "teardown FAILED: 3 node(s) ...
    ## STILL under the canvas". That reading was measured and real, and its
    ## conclusion ("a leak") did not follow: the check was simply looking
    ## before Unity had done the work. A check that fires too early is as
    ## useless as one that cannot fail -- it just fails the other way.
  MlSweepSlice = 400
    ## Nodes the survivor sweep visits PER FRAME. The sweep is resumable, so
    ## this is a frame-cost knob, not a correctness one -- unlike the single
    ## budget it replaces, running out of it ends the frame, never the check.
  MlSweepMaxNodes = 250_000
    ## Ceiling on the WHOLE walk, across all frames. A real ceiling still has
    ## to exist -- an unbounded walk on the Unity thread is a hang -- but it is
    ## set far above any canvas we have measured, so hitting it means the tree
    ## is not what we think it is, and that is reported as INCONCLUSIVE.
  MlSweepMaxSlices = 900
    ## Frames the sweep may span. At ~1 frame per slice this is ~15s at 60fps.
  MlSweepStackMax = 20_000
    ## Depth-first stack ceiling. Dropping a child would make the walk
    ## non-exhaustive, so a drop is COUNTED and forces INCONCLUSIVE rather than
    ## being silently tolerated.
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
  MlCaptionPollMs = 1000'u64
    ## How often the LOAD-PHASE WITNESS is searched for while we do not have
    ## one. The search walks scene roots, so it is far more expensive than the
    ## 250ms file poll and must not run at that rate. Once a caption is held,
    ## no search happens at all -- a liveness check on the held node answers
    ## the question for free.
  MlCaptionSlice = 500
    ## Nodes the caption search visits PER POLL. THIS CONSTANT IS THE FIX FOR A
    ## CLIENT-KILLING BUG, so do not raise it casually.
    ##
    ## MEASURED, live, 2026-09-01: the previous version gave EACH of up to 24
    ## scene roots the full 3,000-node NuStyleBudget, in ONE frame -- up to
    ## 72,000 nodes, every one of them doing a `GetComponent` for a TMP and a
    ## managed string read -- and then ran a 6,000-node census with an
    ## `Object::get_name` per hit on the SAME frame. The client died ~15s into
    ## boot, natively, with `il2cpp_alloc` on the stack under UnityPlayer, and
    ## the mod-loading log stopped dead after "COULD NOT LOOK": the tick never
    ## returned. Nothing was logged because nothing got the chance to be.
    ##
    ## The guard was not the problem and neither was any single hop. ~78,000
    ## managed calls with their allocations inside one frame is the problem, and
    ## an `aowl_p_p_seh` does not save you from that -- it catches a fault, not
    ## an allocator brought down by the volume of work handed to it.
  MlCaptionMaxNodes = 120_000
    ## Ceiling on ONE search pass across all its slices. Far above any scene
    ## measured here; hitting it means the scene is not the shape we assume,
    ## and it ends the pass rather than running for ever.
  MlCapStackMax = 20_000
    ## Depth-first stack ceiling. A drop makes the pass non-exhaustive, so it is
    ## COUNTED and reported, never silently tolerated.
  MlCapParent = "LoadingSpinner"
    ## The caption's PARENT object name. Structural, not localized -- this is
    ## the gate. Measured live off the running client (see mlCapStep).
  MlCapChild = "Text"
    ## The caption object's own name. Checked FIRST because it is one
    ## `Object::get_name` on the node we already hold, and it rejects almost
    ## everything before we pay for a parent lookup. Empty = accept any child.
  MlCensusMax = 14
    ## Identities remembered while searching, for the log when no caption
    ## matches. These now cost NOTHING extra: they are collected by the walk
    ## that is already happening, instead of by a second 6,000-node walk.
  MlNeedleDefault = "loading"
    ## The DISPLAYED-TEXT needle for the game's own caption, and the DEFAULT
    ## only -- `modLoadCaption` in aowlspt-host.json overrides it, so a
    ## non-English client is a config edit rather than a rebuild. It is still
    ## LOCALIZED and `nuStyleNote` says so on every line it prints; matching
    ## structurally, by the container the client's own loading flow owns, is
    ## the real fix and needs those object names measured during a boot.
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

proc mlSweepPush(node: Il2CppPtr) =
  if node == nil: return
  if gModLoadSweepFrontier.len >= MlSweepStackMax:
    inc gModLoadSweepDropped
    return
  gModLoadSweepFrontier.add node

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
  # DEACTIVATE BEFORE DESTROYING, always. `Object::Destroy` is deferred to
  # the end of the frame, so on the frame we dismiss the text is still drawn;
  # `SetActive(false)` takes effect immediately. The player's complaint was
  # "it remains open when we load into the main menu", and a frame of extra
  # text is exactly what that looks like if the destroy is ever delayed
  # further or declines. Hiding costs one call and cannot leave the element in
  # a worse state than destroying alone.
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) != 0'u32:
      if nuLive(gModLoadRows[i]):
        discard nuSetActive(gModLoadRows[i], false)
        discard nuDestroy(gModLoadRows[i])
      gModLoadRows[i] = nuNone
  gModLoadRows.setLen(0)
  if uint32(gModLoadTitle) != 0'u32:
    if nuLive(gModLoadTitle):
      discard nuSetActive(gModLoadTitle, false)
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
  ## Hide, destroy, and SCHEDULE the proof. The verdict is not available yet
  ## and this must not pretend otherwise -- see MlSweepDelayMs.
  if gModLoadDone or gModLoadSweepAt != 0'u64:
    return
  mlDestroy()
  gModLoadSweepWhy = why
  gModLoadSweepAt = cNowMs() + MlSweepDelayMs
  okLog "mod loading step: torn down (" & why & "). Every line was " &
        "deactivated and passed to Object::Destroy, which Unity defers to the " &
        "end of the frame -- so the survivor sweep that PROVES nothing is left " &
        "runs in " & $int(MlSweepDelayMs) & "ms, not now. No verdict yet."

proc mlSweepVerdict(exhaustive: bool; whyNot: string) =
  ## ONE place that ends the sweep, so the three outcomes cannot drift apart.
  gModLoadSweeping = false
  gModLoadSweepFrontier.setLen(0)
  gModLoadDone = true
  let roots = (if gModLoadParentTr != nil and
                  gModLoadParentTr != gModLoadCanvasTr:
                 "the canvas AND the caption container we reparented into"
               else: "the canvas")
  let scope = $gModLoadSweepNodes & " node(s) over " & $gModLoadSweepSlices &
              " frame(s) of " & roots
  if not exhaustive or gModLoadSweepDropped > 0:
    var extra = whyNot
    if gModLoadSweepDropped > 0:
      extra = extra & (if extra.len > 0: "; " else: "") & $gModLoadSweepDropped &
              " child node(s) were DROPPED at the " & $MlSweepStackMax &
              "-entry stack ceiling, so parts of the tree were never visited"
    warn "mod loading step: dismissed (" & gModLoadSweepWhy & ") -- teardown " &
         "check INCONCLUSIVE after " & scope & ": " & extra &
         ". It found " & $gModLoadSweepFound & " so far. \"I could not " &
         "finish looking\" is NOT a pass."
  elif gModLoadSweepFound != 0:
    warn "mod loading step: dismissed (" & gModLoadSweepWhy & ") -- teardown " &
         "FAILED: " & $gModLoadSweepFound & " node(s) named \"" & MlNamePrefix &
         "*\" are STILL under " & roots & " " & $int(MlSweepDelayMs) &
         "ms after every one was deactivated and destroyed, across an " &
         "EXHAUSTIVE walk of " & scope & ". Unity's deferred destroy has had " &
         "whole frames to run, so this IS a leak on the player's screen, not " &
         "an early read."
  else:
    okLog "mod loading step: dismissed (" & gModLoadSweepWhy & ") -- teardown " &
          "PASSED: an EXHAUSTIVE walk of " & scope & " found ZERO nodes named " &
          "\"" & MlNamePrefix & "*\". Read back off the live tree " &
          $int(MlSweepDelayMs) & "ms after the destroy, not off our own handles."

proc mlSweepBegin() =
  ## Seed the resumable survivor sweep.
  ##
  ## WHY RESUMABLE. Measured live: with the Settings screen open the canvas was
  ## bigger than the old 2,000-node single-frame budget, and the check reported
  ## INCONCLUSIVE -- honestly, and uselessly. A check that structurally cannot
  ## complete in a common state of the UI is not a check; the previous boot
  ## PASSED only because the tree happened to be smaller. So the walk now keeps
  ## its own frontier and continues across frames until it is EXHAUSTIVE, the
  ## same way the inspector's `find` does, and the per-frame cost is the knob
  ## instead of the verdict.
  ##
  ## BOTH ROOTS are seeded. Once the lines are reparented into the game
  ## caption's container, a sweep rooted only at the canvas we originally built
  ## under may not reach them at all -- and "did not look there" would come
  ## back as ZERO survivors, a PASS that cannot fail.
  gModLoadSweepFrontier.setLen(0)
  gModLoadSweepFound = 0
  gModLoadSweepNodes = 0
  gModLoadSweepSlices = 0
  gModLoadSweepDropped = 0
  gModLoadSweeping = true
  mlSweepPush(gModLoadCanvasTr)
  if gModLoadParentTr != nil and gModLoadParentTr != gModLoadCanvasTr:
    mlSweepPush(gModLoadParentTr)
  if gModLoadSweepFrontier.len == 0:
    mlSweepVerdict(false, "there was no readable root to sweep from (the " &
                   "canvas transform was never recorded), so NOTHING was " &
                   "examined")

proc mlSweepStep() =
  ## One frame's slice of the walk. Depth-first with an explicit stack, so
  ## suspending and resuming is free and needs no per-frame allocation.
  var n = 0
  while gModLoadSweepFrontier.len > 0 and n < MlSweepSlice:
    inc n
    inc gModLoadSweepNodes
    if gModLoadSweepNodes > MlSweepMaxNodes:
      mlSweepVerdict(false, "the walk passed its " & $MlSweepMaxNodes &
                     "-node ceiling, which is far above any canvas measured " &
                     "here -- the tree is not the shape we assume")
      return
    let node = gModLoadSweepFrontier.pop()
    if node == nil or not nuOk(node, 0x10'i32) or not nuAlive(node):
      continue
    let nm = iObjName(node)
    if nm.len > 0 and find(nm, MlNamePrefix) >= 0:
      inc gModLoadSweepFound
    var c = 0
    if iChildCount(node, c):
      for i in 0 ..< c:
        mlSweepPush(iChildAt(node, i))
  inc gModLoadSweepSlices
  if gModLoadSweepFrontier.len == 0:
    mlSweepVerdict(true, "")
  elif gModLoadSweepSlices > MlSweepMaxSlices:
    mlSweepVerdict(false, "the walk was still going after " &
                   $MlSweepMaxSlices & " frames and was stopped rather than " &
                   "kept running on the Unity thread")

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

proc mlIdentity(node: Il2CppPtr): string =
  ## name + parent name for a transform. Two `Object::get_name` calls, used
  ## only on nodes we have already decided are interesting.
  if node == nil: return "<nil>"
  result = "name=\"" & iObjName(node) & "\""
  let par = mlParentTransformOf(node)
  if par != nil:
    result = result & " parent=\"" & iObjName(par) & "\""
  else:
    result = result & " parent=<none/unreadable>"

proc mlCapSeed(): bool =
  ## Start ONE caption-search pass: seed the frontier from the anchor's scene
  ## roots. Returns false for COULD NOT LOOK -- no anchor yet, or Unity would
  ## not say which scene it is in. That is not "there is no caption"; the two
  ## want opposite responses (wait, versus tear down).
  gModLoadCapFrontier.setLen(0)
  gModLoadCapNodes = 0
  gModLoadCapDropped = 0
  gModLoadCapCensus.setLen(0)
  var roots: seq[Il2CppPtr] = @[]
  if not splAnchorSceneRoots(roots):
    return false
  # THE ROOTS ARE ALREADY TRANSFORMS. Do NOT call GameObject::get_transform
  # on them.
  #
  # THIS LINE KILLED THE CLIENT, TWICE. `iRootsOfHandle` (inspect.nim) converts
  # each root GameObject to its Transform AT THE BOUNDARY -- `into.add t`,
  # deliberately, so that a $rN means the same kind of thing as $c0 and $f1 --
  # and `splAnchorSceneRoots` hands that seq straight out. Calling
  # `nuTransformOf` on one therefore invoked `GameObject::get_transform` with a
  # TRANSFORM receiver. IL2CPP does not type-check a receiver: it read the
  # native side of the wrong object and UnityPlayer faulted, on the FIRST root,
  # before a single line could be logged. Both crash dumps had the identical
  # host offset for exactly this reason.
  #
  # `iRefuseIfGameObject` exists in the inspector for the mirror-image mistake.
  # The lesson is the same one CLAUDE.md 5 states: a receiver is part of a
  # call's contract, and "it is a UI object" is not a type.
  for tr in roots:
    if gModLoadCapFrontier.len >= MlCapStackMax: break
    if tr != nil and nuOk(tr, 0x10'i32) and nuAlive(tr):
      # BELT AND BRACES: refuse a GameObject here if the contract ever changes
      # upstream. A walk that faults is worse than a walk that reports nothing.
      if iIsGameObject(tr):
        warn "mod loading step: a scene root read back as a GAMEOBJECT where " &
             "splAnchorSceneRoots promises a TRANSFORM. Skipping it rather " &
             "than calling Transform methods on it -- that confusion is what " &
             "killed the client on 2026-09-01."
        continue
      if gModLoadWalkLevel == 1:
        okLog "mod loading step: WALK LEVEL 1 -- scene root name=\"" &
              iObjName(tr) & "\" reads as a TRANSFORM (not a GameObject), " &
              "readable and Unity-alive. Enumeration only; no walk is run."
      gModLoadCapFrontier.add tr
  if gModLoadWalkLevel == 1:
    okLog "mod loading step: WALK LEVEL 1 -- " & $gModLoadCapFrontier.len &
          " root(s) enumerated and validated. STOPPING HERE by config " &
          "(modLoadWalkLevel=1). Set it to 3 for normal behaviour."
    gModLoadCapFrontier.setLen(0)
  true

proc mlCapStep(found: var NuStyle): bool =
  ## ONE SLICE of the caption search. Depth-first with an explicit stack, so
  ## suspending between polls is free and needs no per-frame allocation.
  ##
  ## It does two jobs in one walk, which is the whole point: it looks for the
  ## caption, and it remembers the identity of every other TMP that has text.
  ## The census used to be a SECOND full walk; folding it in here means the
  ## diagnostic that tells us how to drop the localized needle costs nothing
  ## beyond the search we were already doing.
  result = false
  var n = 0
  let slice = (if gModLoadWalkLevel == 2: 5 else: MlCaptionSlice)
    ## LEVEL 2 walks FIVE nodes and narrates every managed call it is about to
    ## make, so a boot that dies still names the exact hop it died on. The
    ## normal level narrates nothing: one line per node would be a log bomb.
  while gModLoadCapFrontier.len > 0 and n < slice:
    inc n
    inc gModLoadCapNodes
    if gModLoadCapNodes > MlCaptionMaxNodes:
      gModLoadCapFrontier.setLen(0)
      return false
    let node = gModLoadCapFrontier.pop()
    # EVERY hop validated. A destroyed Unity object stays perfectly readable
    # with m_CachedPtr zeroed, so the pointer check alone is not the question.
    if node == nil or not nuOk(node, 0x10'i32) or not nuAlive(node):
      continue
    if gModLoadWalkLevel == 2:
      okLog "mod loading step: WALK LEVEL 2 -- node " & $gModLoadCapNodes &
            " ptr=0x" & hexOf(cast[uint64](node)) & " klass=0x" &
            hexOf(cast[uint64](nuKlassOf(node))) & " isGameObject=" &
            $iIsGameObject(node) & ". About to call Component::GetComponent " &
            "for TMP_Text on it. If this is the last line, THAT call is the " &
            "one that does not return."
    let tmp = splTmpOf(node)
    if tmp != nil and nuOk(tmp, 0x10'i32) and nuAlive(tmp):
      let t = splTmpText(tmp)
      if t.len > 0:
        let nm = iObjName(node)
        if find(nm, MlNamePrefix) < 0:
          # THE MATCH IS STRUCTURAL: the caption is the TMP named `Text` under
          # a parent named `LoadingSpinner`. MEASURED live 2026-09-01, read off
          # the running client by this very walk, after 798 nodes:
          #   name="Text" parent="LoadingSpinner" text="Loading..." font=26.0
          #
          # The displayed text is NO LONGER THE GATE. It was, and that made the
          # whole feature depend on the client's language: an English needle
          # finds nothing on a Russian client, and the honest reading of that
          # miss ("wrong word") is indistinguishable in a log from the true one
          # ("no caption"). Object names are not localized. The text is still
          # read, and still reported -- as a CROSS-CHECK that says whether the
          # configured needle agrees with reality, never as the condition.
          #
          # A NOTE ON HOW THIS OBJECT WAS NEARLY MISSED. An external tool DID
          # find `LoadingSpinner/Text` on the first attempt, and it was
          # rejected as "an INACTIVE 6px spinner sub-label, not the caption" --
          # both observations were accurate and the conclusion was wrong. It is
          # inactive and tiny OUTSIDE the load window, and 26pt and live DURING
          # it, which is exactly the object we want and exactly why a transient
          # thing must be measured while it exists. Do not re-reject it.
          var structural = false
          if MlCapChild.len == 0 or find(nm, MlCapChild) >= 0:
            let par = mlParentTransformOf(node)
            if par != nil:
              let pn = iObjName(par)
              if find(pn, MlCapParent) >= 0:
                structural = true
                gModLoadCapIdent = "name=\"" & nm & "\" parent=\"" & pn & "\""
              elif gModLoadCapSawParent.len == 0 and pn.len > 0:
                gModLoadCapSawParent = pn
          if structural:
            var cand = nuStyleCapture(tmp, node)
            cand.text = t
            if cand.ok:
              # THE CROSS-CHECK, logged, never gating. If these disagree the
              # feature still works and the log says the config needle is stale
              # or the client is not English -- which is information, not a
              # failure.
              gModLoadCapLocale =
                (if find(toLowerAscii(t), gModLoadNeedle) >= 0:
                   "LOCALE OK (its text \"" & t & "\" does contain the " &
                   "configured needle \"" & gModLoadNeedle & "\")"
                 else:
                   "LOCALE MISMATCH (its text \"" & t & "\" does NOT contain " &
                   "the configured needle \"" & gModLoadNeedle & "\" -- " &
                   "harmless, because the match is STRUCTURAL; it means " &
                   "modLoadCaption is stale or this client is not English)")
              found = cand
              return true
          elif gModLoadCapCensus.len < MlCensusMax:
            gModLoadCapCensus.add("[" & $(gModLoadCapCensus.len + 1) & "] " &
                                  mlIdentity(node) & " text=\"" &
                                  (if t.len > 48: t[0 ..< 48] & "..." else: t) &
                                  "\"")
    var c = 0
    if iChildCount(node, c):
      for i in 0 ..< c:
        if gModLoadCapFrontier.len >= MlCapStackMax:
          inc gModLoadCapDropped
          break
        let ch = iChildAt(node, i)
        if ch != nil: gModLoadCapFrontier.add ch

proc mlCapCensusLine(): string =
  ## What the finished pass saw, for the log. This is the instrument that
  ## replaces the external catchcaption tool: two boots of it could not reach
  ## the caption (rooted at $preloader it found only an inactive 6px `Text`
  ## under `LoadingSpinner`; rooted at every scene root it STOPPED EARLY on the
  ## inspector's per-round frame cap in all six rounds). The host is already
  ## walking these roots DURING the window, so it is the thing that can answer.
  result = ""
  for e in gModLoadCapCensus:
    result = result & "  |  " & e
  if result.len == 0:
    result = "  |  (no TMP with any text was seen at all)"

proc mlPhaseLive(): bool =
  ## Is the client in the load phase RIGHT NOW? Answered from the held caption
  ## alone -- one liveness check, no walk. A caption we are holding that Unity
  ## reports destroyed means the phase that owned it has ended.
  gModLoadCaptionNode != nil and nuAlive(gModLoadCaptionNode)

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

proc mlBuild(lines: seq[string]; style: NuStyle): bool =
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

  # THE CAPTION IS THE DONOR, and it is not optional any more.
  #
  # There used to be a fallback here: "any TMP under the canvas" would do, and
  # the log would say NOT matched. That fallback is what let this render over
  # the main menu with our own defaults -- it made a caption-less client a
  # cosmetic downgrade instead of a reason not to draw. The caller establishes
  # the caption BEFORE calling; if it is somehow gone by now, refuse.
  var donor = style.donor
  if donor == nil or not mlStyleUsable(style):
    # Say this ONCE. Repeating it every 250ms for a six-minute compile would
    # bury the log this project reads to find out what happened.
    if not gModLoadDonorWarned:
      gModLoadDonorWarned = true
      gModLoadWhy = "donor"
      warn "mod loading step: REFUSING to build -- the game's own loading " &
           "caption is not usable as a donor/frame (" & nuStyleNote(style) &
           "). Nothing is drawn: a step with no loading sequence to be a step " &
           "OF is an overlay, and drawing one over the menu is the defect " &
           "this gate exists to prevent. The compile itself is unaffected -- " &
           "its progress is in " & gModLoadScreenPath & "."
    return false

  let rows = min(lines.len - 1, MlMaxRows)
  if rows < 0:
    return false
  # NEVER BUILD OVER LIVE HANDLES. If anything is still standing from a
  # previous attempt, tear it down first: overwriting `gModLoadTitle` with a
  # new handle orphans the old GameObject, which is untracked, undestroyable
  # and permanently on the player's screen. This is a leak class the survivor
  # sweep would catch AFTERWARDS; not creating it is better than reporting it.
  if gModLoadBuilt or uint32(gModLoadTitle) != 0'u32 or gModLoadRows.len > 0:
    mlDestroy()

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

  let usable = true      # guaranteed by the refusal above; kept for clarity
  block:
    let par = mlParentTransformOf(style.node)
    if par != nil:
      let pgo = nuGameObjectOf(par)
      if pgo != nil and nuOk(pgo, 0x10'i32) and nuAlive(pgo):
        parentGo = pgo
        gModLoadParentTr = par
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

proc mlRetryStyle(s: NuStyle) =
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
  if not mlStyleUsable(s): return
  if not mlApplyStyle(s): return
  # NOW DO THE REPARENT (defect 2). Previously this path logged "position
  # matched; NOT reparented", which was honest and was still a miss: the whole
  # point of matching is to sit INSIDE the client's loading container so we
  # live and die with it. The order matters -- SetParentAndAlign resets the
  # local transform, so the layout is applied AFTER the move, never before.
  var parented = false
  let par = mlParentTransformOf(s.node)
  if par != nil:
    let pgo = nuGameObjectOf(par)
    if pgo != nil and nuOk(pgo, 0x10'i32) and nuAlive(pgo):
      var moved = 0
      if nuReparent(gModLoadTitle, pgo): inc moved
      for i in 0 ..< gModLoadRows.len:
        if uint32(gModLoadRows[i]) != 0'u32 and nuReparent(gModLoadRows[i], pgo):
          inc moved
      parented = moved == gModLoadRows.len + 1
      # Remembered ONLY so the teardown sweep knows where else to look.
      if moved > 0: gModLoadParentTr = par
      if not parented:
        warn "mod loading step: reparent was PARTIAL -- " & $moved & " of " &
             $(gModLoadRows.len + 1) & " lines moved into the caption's " &
             "container. The lines are now split across two parents, which " &
             "is worse than either; re-laying all of them out below."
      # RE-LAY OUT AFTER THE MOVE, unconditionally, including after a partial
      # move: aligned children sit at the parent's origin until this runs.
      if not mlApplyStyle(s):
        warn "mod loading step: the post-reparent layout REFUSED, so the " &
             "lines are now at their new parent's origin rather than under " &
             "the game's caption. This is visible and wrong; the style note " &
             "above says what was matched."
  gModLoadStyled = true
  gModLoadDonor = s.donor      # see mlBuild: this is the dismissal signal
  # Reparenting an existing label would mean re-aligning it under a new parent
  # mid-flight; the layout above already puts it in the caption's frame, so the
  # position matches even when the parent does not. SAY THAT, rather than let
  # a later reader assume this took the STEP-PARENTED path.
  okLog "mod loading step: RE-STYLED on a later frame -- the game's own " &
        "caption had not spawned when we built, and has now. " & nuStyleNote(s) &
        (if parented:
           " STEP-PARENTED into that caption's own parent, so these lines now " &
           "die with the loading UI."
         else:
           " NOT reparented (no readable parent for the caption); the position " &
           "matches but these lines still hang off the canvas and must be " &
           "torn down explicitly.")
  mlVerifyStyle(s)

proc mlRefresh(lines: seq[string]) =
  ## Update the existing labels in place: `set_text` only, no GameObject
  ## allocation, which is what makes refreshing affordable while the client is
  ## otherwise busy. A render with MORE lines than we built for rebuilds rather
  ## than silently truncating.
  if lines.len - 1 > gModLoadRows.len and lines.len - 1 <= MlMaxRows:
    mlDestroy()
    discard mlBuild(lines, gModLoadCapStyle)
    return
  if uint32(gModLoadTitle) != 0'u32 and lines.len > 0:
    discard nuSetText(gModLoadTitle, lines[0])
  for i in 0 ..< gModLoadRows.len:
    if uint32(gModLoadRows[i]) == 0'u32: continue
    discard nuSetText(gModLoadRows[i],
                      (if i + 1 < lines.len: lines[i + 1] else: ""))

proc mlSinceBoot(t: uint64): string =
  ## `t` as seconds since the deferral started, to one decimal. Returns "?" when
  ## there is no origin to measure from, rather than printing a raw epoch that
  ## reads like a duration.
  if t == 0'u64 or gModLoadDeferredAt == 0'u64 or t < gModLoadDeferredAt:
    return "?"
  let ms = t - gModLoadDeferredAt
  result = $(ms div 1000'u64) & "." & $((ms mod 1000'u64) div 100'u64) & "s"

proc mlGateOpen(): bool =
  ## HAS THE MAIN MENU BEEN SHOWN AT LEAST ONCE?
  ##
  ## The gate is open when either
  ##   * it was never armed (`gModLoadGateOn` false -- the hook did not bind, or
  ##     deferral is off), in which case this is the OLD behaviour and the boot
  ##     log has already said so loudly; or
  ##   * `EFT.UI.MenuScreen::Show(5-arg)` has fired at least once with a live
  ##     receiver.
  ##
  ## It is NOT a timer and it does NOT poll the scene for a UI element: the only
  ## thing read here is an integer the postfix detour increments.
  if not gModLoadGateOn: return true
  if gModLoadGateHold: return false
  result = gModLoadMenuShownAt != 0'u64

proc modLoadReleaseMods(why: string; force: bool = false) =
  ## Load the mods that boot deliberately skipped.
  ##
  ## Called on four paths now, and all of them must exist:
  ##   * the build reported ready              -- the intended one   (GATED)
  ##   * no build is running at all            -- the cached install (GATED)
  ##   * the client's load phase ended         -- the screen died    (GATED)
  ##   * the 240s deadline / the self-disable  -- the safety nets    (FORCED)
  ##
  ## THE GATE, and why it is not a timer. MEASURED 2026-09-01: with the mod
  ## build cached (0.7s) the file reads "MODS READY" before the client is even
  ## up, so the release landed at 16-22s -- inside the client's own
  ## character-select / profile-Submit transition -- and the client DIED there
  ## twice with no crash folder and no dialog (client log ends at "Session
  ## mode: Regular"). Every run that survived released after the main menu was
  ## up. A timer tuned to "after 25s" would encode that measurement as a
  ## constant and break on a slower machine; so the release is gated on the
  ## EVENT instead, and the deadline below remains the only clock involved.
  ##
  ## `force` is for the safety nets ONLY. Failing towards "your mods work"
  ## outranks this gate: a gate that can withhold every mod for ever is worse
  ## than the crash it prevents.
  if gModsReleased or gModsDirDeferred.len == 0:
    return
  if not force and not mlGateOpen():
    # HOLD. Remember the FIRST reason -- it is the one that is true; a later
    # tick's reason is just the same condition observed again.
    if gModLoadPendingWhy.len == 0:
      gModLoadPendingWhy = why
      gModLoadPendingAt = cNowMs()
      okLog "mod loading: release HELD -- everything the mod build has to say " &
            "is in (" & why & "), but EFT.UI.MenuScreen::Show has not fired " &
            "yet, so the client is still in its character-select / " &
            "profile-Submit transition. Releasing there killed the client " &
            "twice on 2026-09-01 with no crash folder and no dialog. The " &
            "mods are released the moment that show event arrives, or by the " &
            $int(ModLoadDeferMaxMs div 1000'u64) & "s deadline, whichever is " &
            "first. Nothing is lost either way."
    return
  gModsReleased = true
  if gModLoadPendingWhy.len > 0 and not force:
    okLog "mod loading: release gated -- READY at " &
          mlSinceBoot(gModLoadPendingAt) & ", MenuScreen::Show at " &
          mlSinceBoot(gModLoadMenuShownAt) & ", releasing now"
  # APPROVED HERE, PERFORMED ON THE OPS THREAD.
  #
  # This proc runs on the UNITY MAIN THREAD -- `modLoadTick` rides the
  # `TarkovApplication::Update` drain. The load itself must NOT run here.
  #
  # MEASURED 2026-09-02 13:18 (WER dump `EscapeFromTarkov.exe.16972.dmp`,
  # 0xc0000409 FAST_FAIL_FATAL_APP_EXIT, no Unity Crash_* report because a
  # fail-fast bypasses Unity's handler): the boot that released the deferred
  # mods from HERE at 0:00:44.4 died in `ucrtbase!abort <- admin!mi_assert_fail
  # <- admin!mi_malloc <- ... <- admin onUpdate <- modOnUpdate`, on
  # `heap->thread_id == 0 || heap->thread_id == tid` in
  # `mi_heap_malloc_small_zero`. The mod had been INITIALISED on this thread
  # and was being TICKED on the ops thread. The previous surviving boot loaded
  # the same mod on the ops thread at 0:00:01.4 and ran fine.
  #
  # INFERRED, not measured: that the heap binds to the init thread (rather
  # than, say, an emutls slot reused after this boot's unload/reload of six mod
  # DLLs). What is enforced is the invariant either explanation implies -- a
  # mod is initialised on the same thread that ticks it -- so the gate stays
  # here, where the event is, and the WORK moves to `modLoadReleaseDrain`,
  # which the ops loop calls immediately before `modhost.tickMods`.
  #
  # `gModsReleased` was set above, so nothing asks again while this is pending.
  gModLoadReleaseWhy = why
  gModLoadReleaseTid = modhost.cSysThreadId()
  gModLoadReleaseApproved = true
  okLog "mod loading: release APPROVED on thread " &
        $int(gModLoadReleaseTid) & " (Unity main thread) -- " & why &
        ". The load itself is NOT done here; the ops thread performs it on " &
        "its next pass, so the mods are initialised on the same thread that " &
        "ticks them."

proc modLoadPerformRelease(why: string) =
  ## THE ACTUAL LOAD. Called only by `modLoadReleaseDrain`, only from the ops
  ## thread. Every log line below is the one this used to write inline from
  ## `modLoadReleaseMods`; only the thread it runs on has changed.
  okLog "mod loading: releasing deferred mods now -- " & why

  # THE READBACK, and it is a DELTA rather than a total on purpose.
  #
  # `loadAll` answers `gMods.len` -- every slot this session has ever used,
  # dead ones included. Tested against zero, that is a check that cannot fail
  # once anything else has already loaded a mod: on 2026-09-02 the backend's
  # mod-set poll had six mods up by 4.5s, so this release could have brought
  # up NOTHING at all and still read "not zero, fine". What is actually being
  # asked here is "did the deferral deliver the mods it withheld", and only
  # the difference answers that.
  #
  # The other half of the same measurement is `already`: mods the release
  # found already running and did NOT initialise a second time. That number
  # is expected to be non-zero -- two load paths legitimately reach this same
  # directory -- and `loadMod` names each one it skipped.
  var liveBefore = 0
  for i in 0 ..< modhost.modCount():
    if modhost.modIsLive(i): inc liveBefore
  let rowsBefore = modhost.modCount()
  let total = modhost.loadAll(gModsDirDeferred, modhost.SideClient,
                              HostName, HostVersion)
  let broughtUp = modhost.modCount() - rowsBefore
  if total == 0:
    warn "mod loading: the deferred load produced NO mods from " &
         gModsDirDeferred & ". If mods were expected, this is the failure to " &
         "chase -- the client started clean on purpose and nothing filled it."
  elif broughtUp == 0:
    warn "mod loading: the deferred release brought up NO NEW mods -- all " &
         $liveBefore & " were already running before it ran. The deferral " &
         "therefore withheld nothing, and whatever loaded them (the " &
         "backend's mod-set poll is the one that does) is the real load " &
         "path in this session. Not a failure; but the loading screen was " &
         "showing a wait that had already ended."
  else:
    okLog "mod loading: the deferred release brought up " & $broughtUp &
          " mod(s); " & $liveBefore & " were already running and were " &
          "SKIPPED rather than initialised a second time (each names " &
          "itself above with 'init #2 SKIPPED'). Every mod in this " &
          "session has had exactly one init and one on_load."

proc modLoadReleaseDrain*() =
  ## Perform an approved deferred-mod release, ON THE OPS THREAD.
  ##
  ## Called from the ops loop immediately before `modhost.tickMods`, which is
  ## the whole point: `loadMod` runs `init` and `on_load` here, and `tickMods`
  ## runs `on_update` here, so a mod's thread-bound mimalloc heap is only ever
  ## touched by one thread. See `gModLoadReleaseApproved`.
  ##
  ## Idle cost is one boolean compare. It is deliberately NOT guarded by an
  ## `aowl_p_p_seh` of its own -- `loadMod` is the same call the boot path and
  ## `modcontrol.drain()` already make from this thread unguarded, and the
  ## abort this fixes is a fail-fast that no SEH guard can catch anyway.
  if gModLoadReleaseDone or not gModLoadReleaseApproved:
    return
  gModLoadReleaseApproved = false
  gModLoadReleaseDone = true
  let tid = modhost.cSysThreadId()
  # THE ORDERING LEDGER for the native step's verdicts (3) and (4). Integers
  # only, and this is the ONE place they are written -- see `mlnNoteRelease`
  # for why a Nim string must not be assigned from this thread.
  mlnNoteRelease(tid)
  okLog "mod loading: release performed on thread " & $int(tid) &
        " (ops thread), gate opened on thread " & $int(gModLoadReleaseTid) &
        " (Unity)"
  if tid == gModLoadReleaseTid:
    warn "mod loading: the ops thread and the Unity thread report the SAME " &
         "id (" & $int(tid) & "). That is not expected; the split that moved " &
         "this work off the Unity thread is then not doing anything, and the " &
         "mimalloc abort of 2026-09-02 13:18 is still reachable."
  modLoadPerformRelease(gModLoadReleaseWhy)

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
  ## Since the load-phase gate landed, we cannot be built without holding a
  ## caption, so this no longer depends on whether a re-style happened.
  if gModLoadCaptionNode == nil: return false
  result = not mlPhaseLive()

const MlNativeLineBreak = "\x0A"
  ## The line separator for the native caption. Written as an explicit code
  ## point rather than as an escape inside the join expression so that no
  ## editing tool between here and the compiler can turn it into a REAL
  ## newline in the source -- which is a parse error, and is exactly what
  ## happened once while this proc was being written.

proc mlNativeCaption(lines: seq[string]): string =
  ## The three protocol lines as ONE caption string for the game's own status
  ## field, joined with newlines.
  ##
  ## RENDERED VERBATIM, exactly as the overlay renders them, and for the same
  ## reason: `tools/modbuild.py`'s `Progress.render` is the only writer and it
  ## decides what the player reads. Nothing is parsed here and nothing is
  ## reformatted -- a host that rewrote the writer's words would make the two
  ## renderers disagree about what the build is doing.
  ##
  ## Empty lines are dropped so a two-line report does not leave a blank row
  ## in the middle of the client's own caption.
  result = ""
  var n = 0
  for i in 0 ..< lines.len:
    if lines[i].len == 0: continue
    if n > 0: result.add MlNativeLineBreak
    result.add lines[i]
    inc n
    if n >= MlMaxRows + 1: break


proc mlReleaseFromLines(lines: seq[string]; now: uint64; visible: bool) =
  ## THE RELEASE HALF of the tick, factored out of `modLoadTick` so that BOTH
  ## renderers can drive it: the from-scratch three-line overlay (`visible` =
  ## `gModLoadBuilt`) and the NATIVE step in `modloadnative.nim`, which drives
  ## the client's own caption instead and never sets `gModLoadBuilt` at all.
  ##
  ## It was extracted rather than duplicated on purpose. The mods being
  ## released is the half that is NOT cosmetic, and a second copy of it that
  ## drifted from this one would strand every mod on whichever path had the
  ## stale copy -- silently, because a mod that never loads looks exactly like
  ## a mod that was never written.
  ##
  ## `visible` is "the progress text is actually on screen", whichever renderer
  ## put it there. The done marker is only acted on once it is, because a fully
  ## cached build writes "MODS READY" as its first and only render.
  # The done marker is only acted on ONCE THE TEXT IS ACTUALLY UP. A fully
  # cached build writes "MODS READY" as its very first (and only) render, so
  # arming the dismiss timer on the reading rather than on the display would
  # start the clock before a canvas even exists -- and it would be torn down
  # having never been shown. `linger` means "after it is visible".
  if visible:
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
                       "deadline fired. The loading step did not finish, or " &
                       "the main-menu show event never arrived; the mods are " &
                       "loaded anyway rather than lost.", true)


proc modLoadTick() =
  ## Runs from the shared per-frame drain, on the Unity main thread, inside the
  ## existing guard -- this adds NO guard of its own, because `aowl_p_p_seh` is
  ## not re-entrant and a nested one would disarm the outer. Cheap when idle:
  ## one clock compare, then one small file read, and it returns immediately
  ## when the contents have not changed.
  if not gModLoad:
    return
  let nowFrame = cNowMs()
  # THE RELEASE GATE, before every early return below. Two integer compares
  # when there is nothing to do, and it must run even while the survivor sweep
  # or the done-gate is short-circuiting the rest of the tick -- a held release
  # that only drains on the paths that happen to reach the bottom of this proc
  # is a gate that can stick shut, which is the failure this must not have.
  if gModLoadGateOn and gModLoadMenuShownAt == 0'u64 and
     uihEpoch(UihSiteMenuShow) > 0:
    gModLoadMenuShownAt = nowFrame
    okLog "mod loading: the main menu SHOW EVENT fired (" &
          "EFT.UI.MenuScreen::Show 5-arg @0x15387A0, " &
          $uihEpoch(UihSiteMenuShow) & " good firing(s)) at " &
          mlSinceBoot(nowFrame) & " after the deferral started. Observed on " &
          "the frame AFTER the detour, so this time is within one frame, not " &
          "exact. The release gate is now OPEN."
  # THE NATIVE STEP'S OWN PUMP, before every early return below and for the
  # same reason the release gate is: the read-only MenuLoadProfiler stage
  # drains must report even on the boots where NO build file ever appears (the
  # normal path on an install whose mods are already compiled), and the
  # verdicts must be printed even when this tick short-circuits. With
  # `modLoadNative` off both calls return on one boolean compare.
  mlnDrive()
  mlnVerdicts()
  if gModLoadPendingWhy.len > 0 and not gModsReleased and mlGateOpen():
    let why = gModLoadPendingWhy
    modLoadReleaseMods(why)
  # THE PENDING TEARDOWN PROOF, before the done-gate. `mlDismiss` deliberately
  # leaves the verdict unfinished, and `gModLoadDone` is only set when the
  # sweep actually runs -- so an early return here would swallow the check
  # entirely and we would be back to "we called destroy", which is not
  # evidence of anything.
  if gModLoadSweepAt != 0'u64:
    if nowFrame >= gModLoadSweepAt:
      gModLoadSweepAt = 0'u64
      mlSweepBegin()
    return
  if gModLoadSweeping:
    # One slice per frame until EXHAUSTIVE. This is the only path in this
    # feature that runs every frame rather than every 250ms, and it runs only
    # between a teardown and its verdict -- a second or two, once.
    mlSweepStep()
    return
  if gModLoadDone:
    return
  let now = nowFrame
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
                       $MlMaxTries & " polls", true)
    # NOTHING BUILT MEANS NOTHING TO TEAR DOWN. Running the teardown+sweep here
    # was cheap but it LIED in the log: a "dismissed ... teardown INCONCLUSIVE"
    # line reads as though something had been on screen and its removal could
    # not be confirmed, when in fact nothing was ever drawn. A verdict about a
    # thing that never existed is noise at best and misleading at worst.
    if gModLoadBuilt or uint32(gModLoadTitle) != 0'u32 or
       gModLoadRows.len > 0:
      mlDismiss("self-disabled after " & $MlMaxTries & " polls")
    else:
      gModLoadDone = true
      okLog "mod loading step: nothing was ever built this session, so there " &
            "is nothing to tear down and NO survivor sweep is run. No " &
            "teardown verdict is claimed either way."
    return

  # THE MENU CHECK, BEFORE ANYTHING ELSE. Defect (1): the old code had exactly
  # one dismissal path -- a clean READY plus a linger -- so a run that never
  # reported READY, or reported FAILED, left the text on screen for ever,
  # including over the main menu. This is now checked every tick regardless of
  # what the file says.
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


  # ===================================================================
  # THE NATIVE STEP (modloadnative.nim, flag `modLoadNative`, DEFAULT OFF).
  #
  # F1 of docs/BOOT-FLOW-MAP.md: put this progress on the CLIENT'S OWN loading
  # caption -- `ProfileLoadingScreen._statusField@0xb0`, reached by walking
  # from the screen receiver the game itself hands us -- instead of drawing a
  # from-scratch three-line overlay beside it.
  #
  # The two renderers are MUTUALLY EXCLUSIVE and the switch is a property of
  # the FINISHED STATE, not of our own write: `mlnDrives()` is true only once
  # a caption write has been READ BACK off the live TMP. Until that happens
  # the old overlay keeps running, so a native step that cannot reach the
  # caption never costs the player their progress display. When it does become
  # true, anything the overlay had already built is TORN DOWN here -- two
  # progress readings on one screen is worse than either alone.
  #
  # `modLoadNative` off => `mlnCaptionSet`/`mlnDrive`/`mlnDrives` return on one
  # boolean compare and this block costs nothing.
  mlnCaptionSet(mlNativeCaption(lines))
  mlnDrive()
  mlnVerdicts()
  if mlnDrives():
    if gModLoadBuilt:
      mlDismiss("the native loading step is driving the client's OWN caption " &
                "now, so this overlay is redundant -- two progress readings " &
                "on one screen is worse than either alone")
    # The RELEASE still has to run on this path, and it is the half that is
    # not cosmetic. `visible = true` because the progress text IS on screen --
    # on the game's own caption rather than on ours, which is the whole point.
    mlReleaseFromLines(lines, now, true)
    return

  # ===================================================================
  # THE LOAD-PHASE GATE. Nothing below this draws unless the client's own
  # loading caption is on screen right now.
  #
  # Cheap when we already hold one: `mlPhaseLive` is a single liveness check.
  # The scene walk only runs when we do NOT hold a caption, and then at most
  # once a second, because it is the expensive call in this feature.
  # ===================================================================
  var cap = gModLoadCapStyle
  if gModLoadWalkLevel == 0:
    # LEVEL 0: the gate never opens and no scene walk ever runs. This exists to
    # prove the REST of the tick innocent -- if the client still dies with this
    # set, the cause is not this feature's walk.
    if gModLoadWhy != "walkoff":
      gModLoadWhy = "walkoff"
      warn "mod loading step: WALK LEVEL 0 -- the caption search is DISABLED " &
           "by config (modLoadWalkLevel=0), so the gate can never open and " &
           "nothing is drawn. This is a bisect setting, not a normal one."
    return
  if not mlPhaseLive():
    gModLoadCaptionNode = nil
    # ONE SLICE PER POLL, and a pass that continues across polls instead of
    # restarting. The version this replaces re-walked every scene root, at full
    # budget, in a single frame, every second -- see MlCaptionSlice for what
    # that did to the client.
    if gModLoadCapFrontier.len == 0 and now - gModLoadCaptionAt >= MlCaptionPollMs:
      gModLoadCaptionAt = now
      if not mlCapSeed():
        if gModLoadWhy != "nophase:look":
          gModLoadWhy = "nophase:look"
          warn "mod loading step: NOT DRAWING -- COULD NOT LOOK: " &
               "splAnchorSceneRoots refused (no DontDestroyOnLoad anchor yet, " &
               "or Unity would not say which scene it is in). Nothing was " &
               "examined, so this is WAITING, not a verdict."
    if gModLoadCapFrontier.len > 0:
      var found: NuStyle
      if mlCapStep(found):
        cap = found
        gModLoadCapStyle = found
        gModLoadCaptionNode = found.node
        gModLoadDonor = found.donor
        gModLoadCapFrontier.setLen(0)         # pass over: we have our answer
        if not gModLoadPhaseSaid:
          gModLoadPhaseSaid = true
          okLog "mod loading step: the client's own loading caption is up (" &
                nuStyleNote(found) & "), so this IS a load phase and the step " &
                "may draw. It will be torn down when that caption is. " &
                "CAPTION IDENTITY: " &
                gModLoadCapIdent & " (matched STRUCTURALLY on child \"" &
                MlCapChild & "\" under parent \"" & MlCapParent &
                "\", not on localized text) " & gModLoadCapLocale &
                " text=\"" & found.text & "\" font=" &
                nuF(found.fontSize) &
                " frame=" & (if found.geom: "READ" else: "NOT read") &
                " (found after " & $gModLoadCapNodes & " node(s))"
      elif gModLoadCapFrontier.len == 0 and not gModLoadCensusDone:
        # THE PASS FINISHED WITH NO MATCH. Say so once, with everything the
        # walk saw -- that is the evidence needed to drop the localized needle.
        gModLoadCensusDone = true
        warn "mod loading step: NOT DRAWING -- the client is not in a load " &
             "phase: an EXHAUSTIVE walk of the anchor's scene (" &
             $gModLoadCapNodes & " node(s), " & $gModLoadCapDropped &
             " dropped) found no TMP displaying the needle \"" &
             gModLoadNeedle & "\" (override it with modLoadCaption in " &
             "aowlspt-host.json) NOR the structural pattern \"" &
             MlCapChild & "\" under a parent named \"" & MlCapParent &
             "\" -- and " &
             (if gModLoadCapSawParent.len > 0:
                "a TMP WAS seen under a parent named \"" &
                gModLoadCapSawParent & "\", so the scene has labels but not " &
                "that container: the container name may have changed"
              else:
                "no candidate parent was seen at all") &
             ". Measured live: writing the build file while " &
             "the user sat on the MAIN MENU used to make this render there, " &
             "which is an overlay, not a step. The file's contents are kept " &
             "and will be rendered on the next load phase if one begins. " &
             "WHAT THE WALK DID SEE, so the localized needle can be replaced " &
             "by a structural name/parent match:" & mlCapCensusLine()
  if not mlPhaseLive():
    # If we were up, the phase we belonged to has ended -- that is the
    # dismissal signal, and it is the same signal as the gate.
    if gModLoadBuilt:
      mlDismiss("the client's own loading caption is gone, so the load phase " &
                "this step belonged to has ended")
      modLoadReleaseMods("the load phase ended; the mods must not be " &
                         "withheld past it")
    return

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
    discard mlBuild(lines, cap)
  else:
    if changed:
      mlRefresh(lines)
    mlRetryStyle(cap)

  mlReleaseFromLines(lines, now, gModLoadBuilt)

  if gModLoadReadyAt != 0'u64:
    let linger = (if gModLoadFailed: MlFailLingerMs else: MlLingerMs)
    if now - gModLoadReadyAt > linger:
      mlDismiss((if gModLoadFailed:
                   "the build finished WITH FAILURES and its linger expired"
                 else: "a clean build, after its linger"))

proc modLoadWantShowHook() =
  ## Subscribe to the main-menu show event. MUST run before the single
  ## `uihArm`, like every other subscriber -- arming per-feature would install
  ## a second detour on a shared site and the second would overwrite the
  ## first's trampoline (CLAUDE.md sec.5).
  ##
  ## Only wanted when the release is actually deferred: an unwanted site is
  ## never patched at all, so a client with `deferModLoad` off carries no extra
  ## detour for this.
  if gModLoad and gModLoadDeferMods:
    uihWant(UihSiteMenuShow)

proc modLoadShowHookVerdict() =
  ## Read back whether the site REALLY bound, after `uihArm`. This decides
  ## whether the gate exists at all, and it must be read back rather than
  ## assumed: `uihWant` is a request, not an outcome.
  if not (gModLoad and gModLoadDeferMods):
    return
  if uihBound(UihSiteMenuShow):
    gModLoadGateOn = true
    okLog "mod loading: the deferred mod release is GATED ON AN EVENT -- " &
          "EFT.UI.MenuScreen::Show(5-arg) @0x15387A0 (UNIQUE, 16-byte " &
          "prologue matched, POSTFIX). The mods are released when READY is on " &
          "disk AND that show event has fired at least once, never on a timer " &
          "and never by polling the scene for a UI element. HARD DEADLINE " &
          $int(ModLoadDeferMaxMs div 1000'u64) & "s regardless." &
          (if gModLoadGateHold:
             " modLoadGateHold IS ON: the show event is IGNORED, so the gate " &
             "can never open and only the deadline will release. That is the " &
             "falsification path -- it is NOT a normal setting."
           else: "")
  else:
    gModLoadGateOn = false
    warn "mod loading: REFUSING TO GATE the deferred mod release -- the " &
         "show-event hook on EFT.UI.MenuScreen::Show(5-arg) @0x15387A0 did " &
         "NOT bind (see the uihooks line above for the engine's own reason: " &
         "prologue mismatch, a different game build, or the drain disabled). " &
         "FALLING BACK to the OLD behaviour: the mods are released as soon as " &
         "the build reports READY, WHICH IS THE BEHAVIOUR THAT KILLED THE " &
         "CLIENT TWICE ON 2026-09-01 when READY was already on disk at boot " &
         "(release at 16-22s, inside the character-select / profile-Submit " &
         "transition, no crash folder, no dialog). This is a loud refusal, " &
         "not a silent degradation. Set deferModLoad: false to avoid it " &
         "entirely."

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
