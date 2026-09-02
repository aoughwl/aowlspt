## ===========================================================================
## nativetabs.nim -- STEP 1 of docs/NATIVETABS.md: one real settings tab.
##
## WHAT THIS REPLACES, AND WHY IT IS DIFFERENT
## -------------------------------------------
## The postfx subtab was built by CLONING a strip out of one stock panel and
## dropping it into another panel's content container. Five attempts, and every
## failure was the same shape: the container was owned by a `LayoutGroup`, so
## adding a sibling made the game re-arrange its own scroll view. Measured:
## `SettingsList` went (0,-20)/(850,755) -> (0,-420.5)/(850,354.5) purely
## because a sibling appeared.
##
## This never enters that argument. A tab here is:
##   * a real `UIAnimatedToggleSpawner` in the STOCK ToggleGroup, so
##     exclusivity is the game's job and we enforce nothing; and
##   * a real cloned `Game Settings` panel, emptied of the rows it came with,
##     whose own Scroll View / Content / LayoutGroup are left untouched.
## Rows go into `_settingsRoot`, the container the game's own rows go into.
## Geometry stops being ours to negotiate.
##
## SCOPE OF THIS FILE, TODAY: ONE PROOF TAB, no rows beyond a single stub, no
## subtabs. Step 1 of the order in the doc, verified live before step 2.
##
## THE ONE CLONE THAT REMAINS, stated plainly (doc 3.1). There is no way to
## construct a NEW `UIAnimatedToggleSpawner`: `SpawnObject` is an instance
## method on a spawner component, and calling it on a stock spawner would add a
## second toggle to THAT tab. So the spawner itself is Instantiated from a
## stock one. It is a materially better clone than the old approach -- the
## clone's `_spawnableToggle @0xC0` prefab reference is shared and correct, so
## the toggle it spawns is a genuine prefab instance -- but fact #93 applies:
## a cloned spawner keeps the toggle it had ALREADY spawned and then spawns a
## second one, so the clone is reaped back to the donor's child count.
##
## SAFETY. Flag-gated `nativeTabs`, default OFF. Built ONCE, lazily, from the
## live SettingsScreen. Every hop `nuOk`/`duOk` guarded. No guard is opened
## here -- the build runs inside `modsBody`'s single `aowl_p_p_seh`, and the
## toggle postfix runs inside the detour dispatcher's own guard. Capped
## iteration everywhere. Self-disables after `NtMaxFaults`.
##
## LIVE STATUS: nothing in this file has been observed in a running client.
## ===========================================================================

const NtMaxFaults = 4
const NtMaxTabs = 4              ## how many tabs this file will own at once
const NtMaxReap = 32             ## rule 4 on the fact-#93 reap walk

## `gNtOn` / `gNtOff` are declared in `aowlhost.nim` beside the other feature
## flags, NOT here. `modstab.nim`'s rider gate must test `gNtOn`, and modstab is
## included BEFORE this file -- nimony forward-resolves PROCS across an include
## boundary but not VARIABLES, so a flag declared here is invisible there.
var gNtBuilt = false
var gNtTried = 0
var gNtFaults = 0
var gNtVerdictSaid = false

## THE BREADCRUMB. Set before EVERY read of game memory and every call into
## game code, and printed by the fault line.
##
## MEASURED NEED: on the first live run the tick faulted on the very first
## frame Settings was known, four frames running, and the only thing the log
## could say was 'the native-tabs tick FAULTED and was caught'. That named no
## step and no expression, so the next move would have been to guess. Same
## device as `gModSetStep` in modsettingsrender.nim, and for the same reason.
var gNtStep = "not started"

## A TICK THAT DECLINES SILENTLY IS A CHECK THAT CANNOT FAIL.
##
## MEASURED: on the second live pass the bind line printed and then NOTHING
## -- no crumb, no fault, no verdict. `ntTick` running and returning quietly
## was indistinguishable from `ntTick` never being called, and the two have
## completely different fixes (one is a gate in modstab, the other is an
## anchor that never arrived). The breadcrumb did not help because it is a
## VARIABLE, only printed by the fault path -- and there was no fault.
##
## So: one line the first time the tick is entered, and one line naming the
## reason each time it declines to build. Throttled by CHANGE, not by a
## counter -- the same reason repeating every frame prints once, but a
## DIFFERENT reason always prints, so a state transition is never swallowed.
var gNtEnteredSaid = false
var gNtWhySaid = ""

proc ntWhy(reason: string) =
  ## Log a decline reason, once per distinct reason.
  if reason == gNtWhySaid:
    return
  gNtWhySaid = reason
  okLog "native tabs: not building yet -- " & reason

## OUR TABS. Parallel seqs rather than a seq-of-object so the toggle table the
## detour postfix scans is a flat pointer list -- that scan is O(n) with n<=4
## on the game's own click path and must not chase a field offset per entry.
var gNtToggle: seq[Il2CppPtr] = @[]   ## the AnimatedToggle the spawner made
var gNtPanelGo: seq[Il2CppPtr] = @[]  ## our cloned panel's GameObject
var gNtTabComp: seq[Il2CppPtr] = @[]  ## its SettingsTab component
var gNtRowRoot: seq[Il2CppPtr] = @[]  ## _settingsRoot, where rows go
var gNtId: seq[string] = @[]
var gNtSpawnerGo: seq[Il2CppPtr] = @[]

## The stock panels we switch off while ours is up, so they can be switched
## back on exactly as they were. Never written to otherwise.
var gNtStockPanels: seq[Il2CppPtr] = @[]
var gNtStockWasOn: seq[bool] = @[]
var gNtShown = -1                     ## index of the tab currently showing

## THE TOGGLE EVENT. Set by the detour postfix, drained by the tick. The
## postfix itself does the absolute minimum -- compare `this` against our
## table and record an index -- because it runs on the game's click path.
var gNtPressed = -1
var gNtToggleSlotFaults = 0

proc ntNoteFault(what: string) =
  gNtFaults = gNtFaults + 1
  warn "native tabs: " & what & " (fault " & $gNtFaults & " of " &
       $NtMaxFaults & ")"
  if gNtFaults >= NtMaxFaults:
    gNtOff = true
    warn "native tabs: fault ceiling reached; this feature is OFF for the " &
         "rest of the session. Nothing stock was hidden or written, so the " &
         "settings screen is exactly the screen the game builds."

# ---------------------------------------------------------------------------
# THE TOGGLE EVENT -- a postfix on `UnityEngine.UI.Toggle::Set`
#
# NOT on `set_isOn`. That is an ELEVEN-BYTE TAIL-JUMP THUNK
# (`xor r9d,r9d; mov r8b,1; jmp +0x15`, then padding), and so is
# `SetIsOnWithoutNotify`; stealing 16 bytes there overwrites past the end of
# the function and leaves the trampoline to relocate a rel32. Both thunks jump
# to `Toggle::Set(bool value, bool sendCallback)` @0x55BA450, which is UNIQUE
# and has a real prologue.
#
# AND IT IS SELF-GUARDING, which is the reason it is the right target rather
# than merely a safe one: `sendCallback` is TRUE for a real press and FALSE for
# `SetIsOnWithoutNotify` -- the call our own `modsSetToggleQuiet` makes. So our
# own writes cannot re-enter this hook.
#
# O(1)-ish and SILENT for foreign toggles: every toggle in the game funnels
# through here, so this compares `this` against at most `NtMaxTabs` pointers
# and returns. It logs NOTHING unless one of ours matched.
# ---------------------------------------------------------------------------
proc ntToggleSetFired(regs: Il2CppPtr) =
  if not gNtOn or gNtOff or gNtToggle.len == 0:
    return
  # REGISTER INDICES, and getting these wrong is silent: index 0 is RCX. For
  # the instance method `Set(this, bool value, bool sendCallback, MethodInfo*)`
  # that is this=0, value=1, sendCallback=2, MethodInfo=3. An earlier draft
  # used 1 and 3 -- it would have compared a bool against our pointer table and
  # simply never matched, which no log would have shown.
  let selfPtr = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
  if selfPtr == nil:
    return
  # sendCallback is R8B. FALSE means SetIsOnWithoutNotify -- including our own
  # quiet writes -- and is deliberately ignored.
  let sendCallback = (cast[uint64](cRegsInt(regs, 2'i32)) and 0xFF'u64) != 0'u64
  if not sendCallback:
    return
  var i = 0
  while i < gNtToggle.len and i < NtMaxTabs:
    if gNtToggle[i] == selfPtr:
      gNtPressed = i
      return
    i = i + 1

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

proc ntReapSpawnerClone(cloneT, donorT: Il2CppPtr; caption: string): int =
  ## FACT #93. Cloning a *ToggleSpawner* clones the toggle it had ALREADY
  ## spawned AND leaves the spawner live inside the clone, so it spawns a
  ## SECOND one. The result is a tab with an extra, unlabelled rectangle beside
  ## it. The donor is asked how many children to expect and the clone is reaped
  ## down to that -- a count comparison, not a guess at names.
  result = 0
  var want = 0
  var have = 0
  if not iChildCount(donorT, want): return
  if not iChildCount(cloneT, have): return
  if have <= want: return
  var i = have - 1
  while i >= want and i >= 0 and result < NtMaxReap:
    let c = iChildAt(cloneT, i)
    if c != nil and duOk(c, 0x20'i32):
      let go = iGameObjectOf(c)
      if go != nil and modsSetActive(go, false):
        result = result + 1
    i = i - 1
  if result > 0:
    okLog "native tabs: reaped " & $result & " extra child(ren) from the '" &
          caption & "' spawner clone (donor has " & $want & ", the clone came " &
          "out with " & $have & "). Fact #93: a cloned spawner keeps the " &
          "toggle it had already spawned and then spawns another."

proc ntBuildOne(screenT, donorSpawnerT, donorPanelT: Il2CppPtr;
                id, header: string): bool =
  ## One tab: a spawner clone joined to the stock group, and a panel clone
  ## emptied of its stock rows.
  result = false
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil: return

  # ---- 1. THE BUTTON -------------------------------------------------------
  gNtStep = "button: donor GameObject + tab bar"
  let donorSpawnerGo = iGameObjectOf(donorSpawnerT)
  let togglesT = modsParentOf(donorSpawnerT)
  let togglesGo = (if togglesT != nil: iGameObjectOf(togglesT) else: nil)
  if donorSpawnerGo == nil or togglesGo == nil:
    ntNoteFault("the donor tab spawner or the tab bar could not be reached; " &
                "no button was made and nothing was changed")
    return
  # THE STOCK GROUP, read from the DONOR's COMPONENT -- and that word is the
  # whole fix.
  #
  # THE BUG THIS REPLACES: `_toggleGroup@0xb0` is a field on the
  # `UIAnimatedToggleSpawner` COMPONENT, and this read it off
  # `donorSpawnerT`, which is the TRANSFORM. A Transform is large enough that
  # `nuOk` cleared the bounds check, so the read succeeded and returned an
  # unrelated qword -- a plausible pointer from the wrong object. Exactly the
  # receiver-type confusion that has bitten this repo before (a GameObject
  # handed to a Transform walker), and it is silent by construction.
  #
  # `modsComponent` REFUSES a GameObject receiver up front, so the component
  # is resolved through it rather than by assuming the Transform will do.
  gNtStep = "button: resolving the donor UIAnimatedToggleSpawner component"
  let donorSpawner = modsComponent(donorSpawnerT, "UIAnimatedToggleSpawner")
  if donorSpawner == nil:
    ntNoteFault("the donor tab button carries no UIAnimatedToggleSpawner " &
                "component, so the stock ToggleGroup cannot be read from it. " &
                "Nothing was changed")
    return
  gNtStep = "button: reading _toggleGroup@0xb0 off the donor COMPONENT"
  let stockGroup = (if nuOk(donorSpawner, NuOffSpawnerToggleGroup + 8'i32):
                      cNuGetRef(donorSpawner, NuOffSpawnerToggleGroup)
                    else: nil)
  if not nuOk(stockGroup, 0x10'i32):
    ntNoteFault("the stock tab bar's ToggleGroup could not be read from " &
                "_toggleGroup@0xb0 on the donor COMPONENT, so a new tab " &
                "could not join it and exclusivity would have to be enforced " &
                "by us. Refusing: that is the design this file exists to avoid")
    return
  gNtStep = "button: Instantiate of the donor tab spawner GameObject"
  let spawnerGo = modsClone(donorSpawnerGo)
  if spawnerGo == nil or not modsSetParent(spawnerGo, togglesGo):
    ntNoteFault("the tab spawner could not be cloned into the tab bar")
    return
  let spawnerT = modsTransformOf(spawnerGo)
  gNtStep = "button: fact-93 reap of the spawner clone"
  discard ntReapSpawnerClone(spawnerT, donorSpawnerT, header)
  gNtStep = "button: resolving the CLONE's UIAnimatedToggleSpawner component"
  let spawner = modsComponent(spawnerT, "UIAnimatedToggleSpawner")
  if spawner == nil:
    ntNoteFault("the cloned tab spawner has no UIAnimatedToggleSpawner " &
                "component, so SpawnObject cannot be called on it")
    discard modsSetActive(spawnerGo, false)
    return
  gNtStep = "button: SpawnObject() on the cloned spawner -- a call into game code"
  let toggle = nuSpawnerSpawn(spawner)
  if toggle == nil:
    ntNoteFault("SpawnObject returned nothing for the '" & header & "' tab")
    discard modsSetActive(spawnerGo, false)
    return
  gNtStep = "button: SetHeaderText / SetActive on the cloned spawner"
  discard nuSpawnerHeader(spawner, header, 24'i32)
  discard nuSpawnerActive(spawner, true)
  # JOIN THE STOCK GROUP. The single most important call in this file: with it,
  # pressing our tab turns the stock ones off natively and vice versa.
  gNtStep = "button: Toggle::set_group -- joining the stock ToggleGroup"
  if not nuToggleSetGroup(toggle, stockGroup):
    ntNoteFault("the new tab's toggle could not join the stock ToggleGroup, " &
                "so two tabs could read selected at once")
    discard modsSetActive(spawnerGo, false)
    return

  # ---- 2. THE PANEL --------------------------------------------------------
  let donorPanelGo = iGameObjectOf(donorPanelT)
  if donorPanelGo == nil:
    ntNoteFault("the donor panel has no GameObject")
    discard modsSetActive(spawnerGo, false)
    return
  gNtStep = "panel: Instantiate of the Game Settings panel"
  let panelGo = modsClone(donorPanelGo)
  if panelGo == nil or not modsSetParent(panelGo, screenGo):
    ntNoteFault("the settings panel could not be cloned")
    discard modsSetActive(spawnerGo, false)
    return
  let panelT = modsTransformOf(panelGo)
  gNtStep = "panel: resolving the cloned GameSettingsTab component"
  let tabComp = modsComponent(panelT, "GameSettingsTab")
  if tabComp == nil:
    ntNoteFault("the cloned panel carries no GameSettingsTab component, so " &
                "its stock rows cannot be cleaned out and it would show the " &
                "donor's settings under our tab's name")
    discard modsSetActive(panelGo, false)
    discard modsSetActive(spawnerGo, false)
    return
  # BOTH MITIGATIONS, IN THIS ORDER (coordinator's decision, doc 2.2):
  #   (a) disable the component BEFORE its first show, so its Awake/Show cannot
  #       re-create the stock rows;
  #   (b) CleanupCreatedControls once, to destroy the rows it was cloned WITH.
  # (a) first: cleaning first and then letting Show run would simply refill it.
  gNtStep = "panel: Behaviour::set_enabled(false) on the cloned GameSettingsTab"
  let disabled = nuBehaviourEnable(tabComp, false)
  let cleaned = nuTabCleanupControls(tabComp)
  okLog "native tabs: '" & header & "' panel clone -- GameSettingsTab " &
        "component disabled=" & $disabled & ", CleanupCreatedControls " &
        "called=" & $cleaned & ". (a) before (b) on purpose: cleaning a live " &
        "component and then letting its Show run would refill the panel with " &
        "the donor's rows."
  gNtStep = "panel: reading _settingsRoot@0x98 off the cloned tab component"
  let rowRoot = (if nuOk(tabComp, NuOffGameTabSettingsRoot + 8'i32):
                   cNuGetRef(tabComp, NuOffGameTabSettingsRoot) else: nil)
  if not nuOk(rowRoot, 0x10'i32):
    ntNoteFault("_settingsRoot@0x98 on the cloned tab read null, so there is " &
                "nowhere to put rows. The panel is hidden again")
    discard modsSetActive(panelGo, false)
    discard modsSetActive(spawnerGo, false)
    return
  discard modsSetActive(panelGo, false)   # ours starts hidden; the game owns the screen

  if gNtToggle.len < NtMaxTabs:
    gNtToggle.add toggle
    gNtPanelGo.add panelGo
    gNtTabComp.add tabComp
    gNtRowRoot.add rowRoot
    gNtId.add id
    gNtSpawnerGo.add spawnerGo
  okLog "native tabs: built the '" & header & "' tab" &
        " -- a real UIAnimatedToggleSpawner in the STOCK ToggleGroup and a " &
        "real cloned SettingsTab panel, emptied of its stock rows. Nothing " &
        "stock was hidden, no stock container gained a child, and no " &
        "LayoutGroup was touched -- which is the entire difference from the " &
        "cloned-strip approach this replaces."
  result = true

proc ntCollectStockPanels(screenT: Il2CppPtr) =
  ## Every direct child of SettingsScreen that is NOT one of ours. Recorded
  ## once, so showing our panel can switch exactly these off and restore
  ## exactly the one that was on.
  gNtStockPanels = @[]
  gNtStockWasOn = @[]
  var n = 0
  if not iChildCount(screenT, n): return
  var i = 0
  while i < n and i < 24:
    let c = iChildAt(screenT, i)
    i = i + 1
    if c == nil or not duOk(c, 0x20'i32): continue
    let go = iGameObjectOf(c)
    if go == nil: continue
    var ours = false
    var k = 0
    while k < gNtPanelGo.len and k < NtMaxTabs:
      if gNtPanelGo[k] == go: ours = true
      k = k + 1
    if ours: continue
    let nm = iObjName(c)
    if nm == "Toggles" or nm == "Overlay Layer": continue
    gNtStockPanels.add go
    gNtStockWasOn.add false

proc ntBuild(): bool =
  result = false
  if gNtBuilt or gNtOff or not gNtOn: return
  # THE SILENT RETRY THAT ATE A LIVE PASS. This used to be one combined
  # `return` with no message AND no `gNtTried` increment, so a tab pointer
  # that was non-nil but not readable made this retry every frame, forever,
  # printing nothing -- indistinguishable from the tick never running.
  if gModsLastTabPtr == nil:
    ntWhy("the settings tab pointer went nil between the tick check and " &
          "here (the screen closed mid-frame)")
    return
  if not duOk(gModsLastTabPtr, 0x20'i32):
    ntWhy("the settings tab pointer " & iPtr(gModsLastTabPtr) & " is NOT " &
          "READABLE, so nothing can be walked from it. This is not a nil " &
          "anchor -- it is a stale or wrong one, and it does NOT count as a " &
          "build attempt, so the feature keeps waiting for a good one " &
          "rather than burning its 8 tries on it.")
    return
  gNtTried = gNtTried + 1
  ntWhy("build attempt " & $gNtTried & " is running from tab " &
        iPtr(gModsLastTabPtr))
  if not nuTargetsBindOk():
    ntNoteFault("the aowl_nu_targets POSITIONAL self-check FAILED, so every " &
                "call here would go to the wrong method. Nothing was built")
    return
  gNtStep = "build: iToTransform(gModsLastTabPtr) -- the live settings tab"
  let tabT = iToTransform(gModsLastTabPtr)
  let screenT = (if tabT != nil: modsParentOf(tabT) else: nil)
  if screenT == nil:
    ntNoteFault("could not reach the SettingsScreen from the live tab")
    return
  gNtStep = "build: walking SettingsScreen children (Toggles / GameToggleSpawner / Game Settings)"
  let toggles = modsChildNamed(screenT, "Toggles")
  let donorSpawner = (if toggles != nil:
                        modsChildNamed(toggles, "GameToggleSpawner") else: nil)
  let donorPanel = modsChildNamed(screenT, "Game Settings")
  if toggles == nil or donorSpawner == nil or donorPanel == nil:
    ntNoteFault("the pieces this needs were not all found (" &
                (if toggles == nil: "Toggles " else: "") &
                (if donorSpawner == nil: "GameToggleSpawner " else: "") &
                (if donorPanel == nil: "Game-Settings" else: "") &
                "). Nothing was changed")
    return
  gNtStep = "build: ntBuildOne"
  if not ntBuildOne(screenT, donorSpawner, donorPanel, "nt-proof", "PROOF"):
    return
  gNtStep = "build: collecting the stock panels under SettingsScreen"
  ntCollectStockPanels(screenT)
  gNtBuilt = true
  result = true

# ---------------------------------------------------------------------------
# ACTIVATION -- the one piece of steering we own (doc 4)
# ---------------------------------------------------------------------------
proc ntShow(idx: int) =
  ## Show ours, switch off whichever stock panel was up. The game switches
  ## panels by `ESettingsGroup` and our tab is not one, so this is the only
  ## thing it will not do for us.
  if idx < 0 or idx >= gNtPanelGo.len: return
  var i = 0
  while i < gNtStockPanels.len and i < 24:
    let on = modsGoActive(gNtStockPanels[i])
    if i < gNtStockWasOn.len: gNtStockWasOn[i] = on
    if on: discard modsSetActive(gNtStockPanels[i], false)
    i = i + 1
  discard modsSetActive(gNtPanelGo[idx], true)
  gNtShown = idx

proc ntHide() =
  ## Ours off FIRST, theirs back on SECOND. The order is deliberate: restoring
  ## theirs while ours is still active is the both-panels-drawn picture the
  ## mods tab shipped once.
  if gNtShown >= 0 and gNtShown < gNtPanelGo.len:
    discard modsSetActive(gNtPanelGo[gNtShown], false)
  gNtShown = -1
  var i = 0
  while i < gNtStockPanels.len and i < 24:
    if i < gNtStockWasOn.len and gNtStockWasOn[i]:
      discard modsSetActive(gNtStockPanels[i], true)
    i = i + 1

proc ntVerdict() =
  ## THE FINISHED-STATE TEST (doc 4/6), read off the live tree. Exactly one
  ## panel under SettingsScreen is active, and it is the one our selection
  ## names. Zero or two is FAIL. Three outcomes.
  if gNtVerdictSaid or not gNtBuilt: return
  var active = 0
  var oursActive = false
  var i = 0
  while i < gNtStockPanels.len and i < 24:
    if modsGoActive(gNtStockPanels[i]): active = active + 1
    i = i + 1
  var k = 0
  while k < gNtPanelGo.len and k < NtMaxTabs:
    if modsGoActive(gNtPanelGo[k]):
      active = active + 1
      oursActive = true
    k = k + 1
  gNtVerdictSaid = true
  if active == 1 and gNtShown >= 0 and oursActive:
    okLog "native tabs VERDICT PASS: our tab is selected and OUR panel is the " &
          "only active panel under SettingsScreen. Read back off the live " &
          "GameObjects, not from what we wrote."
  elif active == 1 and gNtShown < 0 and not oursActive:
    okLog "native tabs VERDICT PASS: a stock tab is selected and exactly one " &
          "STOCK panel is active; ours is off. The stock screen is undisturbed."
  elif active == 0:
    warn "native tabs VERDICT FAIL: NO panel under SettingsScreen is active, " &
         "so the screen is blank. Our selection says " & $gNtShown & "."
  else:
    warn "native tabs VERDICT FAIL: " & $active & " panels are active at once " &
         "under SettingsScreen (ours active=" & $oursActive & ", selection=" &
         $gNtShown & "). Exactly one is the only correct answer."

proc ntTickBody() =
  ## Every frame while armed. Steady state: two boolean tests and, once built,
  ## one integer compare -- the press arrives from the detour, not from a hunt.
  if not gNtOn or gNtOff: return
  gNtStep = "tick: entry"
  if not gNtEnteredSaid:
    # PROOF OF LIFE. Its ABSENCE from the log now means the tick is not being
    # called at all -- which is a gate problem in modstab, not a problem in
    # this file. That distinction cost a whole live pass.
    gNtEnteredSaid = true
    okLog "native tabs: the tick is LIVE and entered for the first time " &
          "(flag on, detour bound). From here every frame either builds, or " &
          "says why it is not building. If you never see this line again " &
          "and never see a 'not building yet' line, the tick stopped being " &
          "called."
  if not gNtBuilt:
    if gModsLastTabPtr == nil:
      ntWhy("no settings tab is known yet (gModsLastTabPtr is nil). The " &
            "settingsUiProbe ShowScreen postfix is what learns it, so this " &
            "clears the moment a settings tab is actually shown.")
      return
    if gNtTried >= 8:
      ntWhy("the build was attempted 8 time(s) and never completed, so it " &
            "has stopped trying. The last step reached was: " & gNtStep)
      return
    gNtStep = "tick: ntBuild (attempt " & $(gNtTried + 1) & ")"
    ntWhy("attempting the build now (attempt " & $(gNtTried + 1) & " of 8)")
    discard ntBuild()
    gNtStep = "tick: ntBuild returned without faulting"
    return
  if gModsLastTabPtr == nil:
    gNtVerdictSaid = false
    return
  # THE EVENT, drained. `gNtPressed` is set by the Toggle::Set postfix only
  # when one of OUR toggles was pressed with sendCallback=true.
  if gNtPressed >= 0:
    let idx = gNtPressed
    gNtPressed = -1
    gNtStep = "tick: reading m_IsOn off the toggle that was pressed"
    let (ok, isOn) = nuToggleIsOn(gNtToggle[idx])
    if ok:
      if isOn: ntShow(idx)
      else: ntHide()
      gNtVerdictSaid = false
  gNtStep = "tick: verdict (reading panel activeSelf off the live tree)"
  ntVerdict()
  gNtStep = "tick: idle"

proc ntBindToggleEvent(verbose: bool): bool =
  ## Bind the ONE detour this feature needs. Prologue-verified through `nuFn`
  ## against the STARTUP SNAPSHOT (never live memory), and `Toggle::Set` is
  ## sharedness UNIQUE -- checked before patching, because detouring a shared
  ## RVA fires for every one of its owners.
  ##
  ## DOUBLE-DETOUR RULE: nothing else in this host patches `Toggle::Set` today
  ## (the host only CALLS set_isOn, from forceOfflinePractice). If that ever
  ## changes, the second bind overwrites the first trampoline and one feature
  ## dies silently -- ride the existing detour as a drain instead of adding a
  ## second.
  result = false
  let fn = nuFn(NuTToggleSet)
  if fn == nil:
    # REPORT THE REASON WE WERE GIVEN, NOT A GUESS AT IT. The first version of
    # this line asserted "did not verify against the startup prologue
    # snapshot", which is only ONE of six reasons `nuFn` can refuse -- and it
    # was the wrong one: live, the real reason was that the bind ran before
    # `cProPrimeAll()` and before GameAssembly.dll was loaded, so the snapshot
    # capture failed and the verify failed closed. A refusal that names a cause
    # it did not measure sent the next reader hunting for a byte mismatch that
    # was never there.
    warn "native tabs: UnityEngine.UI.Toggle::Set could not be bound -- " &
         nuWhyName(cNuWhyOf(NuTToggleSet)) &
         ". Only a PROLOGUE MISMATCH would mean this game build changed; " &
         "every other reason is a fault in our own host, most likely order " &
         "(this must run after cProPrimeAll and after GameAssembly.dll is " &
         "loaded). The feature declines and NOTHING was patched."
    return
  result = attachDrain("UnityEngine.UI.Toggle::Set", fn,
                       cast[Il2CppMethod](0), false, verbose, 28'i32)
  if result:
    okLog "native tabs: bound a read-only detour on UnityEngine.UI.Toggle::Set " &
          "@0x55BA450 (UNIQUE). This is the general toggle-changed event: it " &
          "compares `this` against at most " & $NtMaxTabs & " of our own " &
          "pointers and returns, logs nothing for foreign toggles, and never " &
          "suppresses the original. It ignores sendCallback=false, which is " &
          "what SetIsOnWithoutNotify passes -- so our own quiet writes cannot " &
          "re-enter it."
  else:
    warn "native tabs: the Toggle::Set detour did NOT bind; tab presses will " &
         "not be seen and this feature does nothing. Nothing was changed."

proc ntTick() =
  ## Every frame while armed, through the SAME single guard the other modstab
  ## features use -- `aowl_p_p_seh` is not re-entrant, so this opens none.
  if not gNtOn or gNtOff:
    return
  gModsBranch = 5
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    ntNoteFault("the native-tabs tick FAULTED and was caught; the game " &
                "survived and nothing stock was left changed. THE STEP THAT " &
                "FAULTED WAS: " & gNtStep & " -- that breadcrumb is set " &
                "immediately before each read of game memory and each call " &
                "into game code, so it names where, not merely that.")
