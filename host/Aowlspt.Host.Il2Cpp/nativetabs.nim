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
const NtMaxReap = 32             ## rule 4 on the fact-#93 spawner reap
## THE PANEL EMPTY WALK GETS ITS OWN, LARGER CAP -- and this is why.
##
## MEASURED: '32 of 40 donor row(s) destroyed'. The two walks were sharing
## `NtMaxReap`, which is sized for a spawner clone's handful of children, and
## the Game Settings panel has 40 rows. So 8 survived, silently, and our tab
## would have shown eight of the donor's settings under its own name.
##
## Raised, still bounded (rule 4), and the caller now REPORTS hitting it --
## a cap that can be reached without saying so is how the 8 got through.
const NtMaxRowDestroy = 256

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
## THE CRUMB AS IT WAS WHEN THE LAST BUILD ATTEMPT GAVE UP.
##
## MEASURED REPORTING BUG: the give-up line printed `gNtStep`, but `gNtStep`
## is reset to "tick: entry" at the top of EVERY tick -- so by the time the
## eighth-attempt message ran, on a later frame, the crumb from the failing
## build had already been overwritten. It printed "tick: entry", which sent
## the reader hunting for an early return that was not the one firing. The
## crumb is SNAPSHOTTED the moment each attempt returns, and the give-up line
## prints the snapshot.
var gNtLastAttemptStep = "no attempt has returned yet"

## A GAME CALL WE ENTERED AND HAVE NOT RETURNED FROM.
##
## MEASURED FAILURE CLASS, and it is worth naming because nothing else in this
## host detects it: `CleanupCreatedControls` was entered on all 8 attempts and
## the crumb after it NEVER ran -- yet there was no SEH fault, and the next
## tick ran normally with the attempt counter advanced. A call that neither
## returns to the next line nor trips the guard, while the tick survives, is a
## MANAGED EXCEPTION (IL2CPP C++ EH) thrown inside the callee and unwound
## THROUGH our frame back to the game's own Update. Our SEH guard never sees
## it because it is not an access violation.
##
## So the next occurrence must cost one log line, not a round trip: the name is
## parked before the call and cleared after it, and the next attempt notices a
## name still parked and says exactly what happened.
var gNtCallInFlight = ""
var gNtUnwindSaid = false

proc ntCallBegin(name: string) =
  gNtCallInFlight = name

proc ntCallEnd() =
  gNtCallInFlight = ""

proc ntCheckUnwind() =
  ## Called at the start of each build attempt. A name still parked from the
  ## PREVIOUS attempt means that call never came back.
  if gNtCallInFlight.len == 0:
    return
  let name = gNtCallInFlight
  gNtCallInFlight = ""
  if gNtUnwindSaid:
    return
  gNtUnwindSaid = true
  warn "native tabs: the game call " & name & " DID NOT RETURN -- it was " &
       "entered on the previous attempt and the statement after it never " &
       "ran, yet the SEH guard caught nothing and this tick is running " &
       "normally. That combination is a MANAGED EXCEPTION thrown inside the " &
       "callee and unwound through our frame (IL2CPP C++ EH), which our " &
       "access-violation guard cannot see. Treat the call as unsafe on this " &
       "receiver rather than retrying it."

proc ntCrumb(s: string) =
  ## Set the live crumb AND the durable one, in one call.
  ##
  ## WHY BOTH, AND WHY NOT A SNAPSHOT AT THE CALL SITE. The snapshot used to be
  ## taken in `ntTickBody` right after `ntBuild()` returned. By control flow
  ## that line must run -- `gNtTried` is incremented only inside `ntBuild`, and
  ## `ntBuild` is called only there -- yet after eight attempts the durable
  ## crumb still read its INITIAL value. That is a contradiction I could not
  ## explain by reading the code, and the honest response to a control-flow
  ## assumption that measurably failed is to stop depending on it.
  ##
  ## The guarded body runs under `aowl_p_p_seh`, a setjmp/longjmp guard. Any
  ## unwind out of `ntBuild` -- caught fault, or anything else that does not
  ## return normally -- skips every statement after the call, including a
  ## snapshot. Writing the durable crumb AT THE POINT THE STEP IS ENTERED
  ## cannot be skipped by an unwind, because it has already happened.
  gNtStep = s
  gNtLastAttemptStep = s


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
## THE SELECTION PROOF (`nativeTabsProofSelect`).
##
## Step 1 is not proven by a tab EXISTING. The first live build produced a
## real spawner, a real cloned panel and byte-identical stock geometry -- and
## the verdict still read `selection=-1`, because nothing had ever pressed our
## toggle. 'It is on screen' and 'selecting it shows our panel and only ours'
## are different claims, and only the second is the one doc 4/6 makes.
##
## So the proof presses its own toggle through `Toggle::Set(true, true)` --
## sendCallback TRUE, so the game's own onValueChanged and the stock
## ToggleGroup run exactly as they would for the player -- then judges, then
## presses GAME back and judges again. Both directions, because a tab that
## takes the screen and never gives it back is a worse defect than one that
## never takes it.
##
## Frame-separated on purpose: a panel switched this frame is not laid out
## until the next, and judging on the switching frame is what produced the
## meaningless '6 panels active'.
var gNtProofOn = false            ## `nativeTabsProofSelect`, default ON
var gNtGameToggle: Il2CppPtr = nil ## the stock GAME tab's toggle, for the way back
var gNtProofPhase = 0             ## 0 idle .. 6 done
var gNtProofWait = 0
## Why the NEXT verdict is being taken. Set by whatever prompted it, so every
## verdict line names its occasion rather than all of them saying the same word.
var gNtWhyNext = "steady state"
const NtProofSettle = 20          ## frames to let a switch settle before judging

## STEP 2 -- `defineSubtabs`. Flag `nativeTabsSubtabs`, default OFF so it
## cannot disturb step 1's proof until it has a live PASS of its own.
##
## THE ONE DESIGN DECISION, and it is what makes this different from the five
## failed attempts in `modstab.nim`:
##
##   THE STRIP IS NOT INSIDE EITHER PANEL IT SWITCHES.
##
## The old feature put a strip inside the panel it switched, which forced it
## to exist TWICE (its own comment: 'THE STRIP HAS TO EXIST TWICE, and that
## is a consequence, not a choice') and put it inside a stock LayoutGroup that
## then re-arranged the game's scroll view -- the entire padding saga.
##
## Here the strip is its own container parented to SettingsScreen, a sibling
## of the panels rather than a child of one. It survives every switch because
## nothing it switches owns it, and it is in NO stock layout group, so there
## is no geometry to negotiate and nothing for a backstop to protect.
##
## It is also deliberately NOT named '<x> Settings', so the panel predicate
## does not count it: a strip is not a panel, and the verdict must keep
## meaning 'exactly one PANEL is active'.
var gNtSubOn = false               ## `nativeTabsSubtabs`
var gNtSubBuilt = false
var gNtSubStripGo: Il2CppPtr = nil ## the strip container (ours, a sibling)
var gNtSubToggle: seq[Il2CppPtr] = @[]  ## [0]=GRAPHICS SETTINGS, [1]=POSTFX
var gNtSubSel = 0
var gNtGfxPanelGo: Il2CppPtr = nil ## the STOCK Graphics Settings panel
var gNtSubPressed = -1
## OUR OWN SELECTION WRITES MUST NOT RE-ENTER OUR OWN POSTFIX.
##
## MEASURED: ten `native subtabs VERDICT PASS` lines inside 160ms, alternating
## between POSTFX and GRAPHICS SETTINGS. That is not a noisy cadence, it is a
## FEEDBACK LOOP: `ntSubShow` calls `AnimatedToggle::set_IsToggled`, which
## calls `Toggle::Set` with sendCallback TRUE, which re-enters this feature's
## own postfix, which records a press, which makes the next tick call
## `ntSubShow` again. Each turn also drags the ToggleGroup into turning the
## other button off, so the two alternate until it settles.
##
## `sendCallback=false` already protects us from `SetIsOnWithoutNotify`, but
## `set_IsToggled` is not that call. So the applying window is marked
## explicitly and the postfix ignores anything inside it -- a press we caused
## is not a press the player made, and only the second one means anything.
var gNtApplying = false
## A STOCK tab was selected: hide ours. Set by the postfix when a toggle that
## is NOT one of ours turns ON.
var gNtForeignOn = false
var gNtSubVerdictSaid = false
const NtMaxSubs = 16              ## rule 4: the hard cap on subtabs
var gNtSubN = 0                   ## how many subtabs were actually built
## WHAT A SUBTAB SELECTION DOES. Two kinds, one implementation.
##   NtSubPanels (0) -- step 2: switch between the STOCK Graphics panel and
##                      ours. The two things being switched are whole panels.
##   NtSubRows   (1) -- step 3: our panel stays up and its ROWS are swapped,
##                      because every mod's page lives in the same panel.
## The alternative for step 3 was one cloned row-container per mod, shown and
## hidden. That is more objects, more clones and more state for a screen the
## player sees one page of at a time; swapping rows costs a re-render on each
## switch and nothing else. Stated because it is a trade, not an obvious win.
const NtSubPanels = 0
const NtSubRows = 1
var gNtSubKind = NtSubPanels
## Step 3 state: which mod each subtab shows, and where its rows go.
var gNtSubPageIdx: seq[int] = @[]   ## index into gSwPages, per subtab
var gNtModsRowRoot: Il2CppPtr = nil ## our MODS panel's _settingsRoot
var gNtModsPanelIdx = -1            ## which of our tabs is MODS
var gNtModsOn = false               ## `nativeTabsMods`
var gNtModsArmed = false            ## the index fetch has been asked for
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
  # OUR OWN APPLY IS NOT A PRESS. Without this the feature drives itself in a
  # loop -- see `gNtApplying`.
  if gNtApplying:
    return
  # `value` is RDX (index 1): did this toggle just go ON?
  let turnedOn = (cast[uint64](cRegsInt(regs, 1'i32)) and 0xFF'u64) != 0'u64
  var i = 0
  while i < gNtToggle.len and i < NtMaxTabs:
    if gNtToggle[i] == selfPtr:
      gNtPressed = i
      return
    i = i + 1
  # SUBTABS RIDE THE SAME POSTFIX. No second detour: two detours on one
  # function have the second overwrite the first's trampoline and silently kill
  # the first feature. Still O(1)-ish -- two more pointer compares -- and still
  # silent for every foreign toggle.
  var j = 0
  while j < gNtSubToggle.len and j < NtMaxSubs:
    if gNtSubToggle[j] == selfPtr:
      gNtSubPressed = j
      return
    j = j + 1
  # A FOREIGN TOGGLE WENT ON -- a stock tab was selected.
  #
  # MEASURED FAIL: 'after pressing GAME back: 2 panels are active at once --
  # Game Settings (stock), nt-proof (OURS)'. The stock ToggleGroup turned OUR
  # toggle off for us, but nothing turned our PANEL off, because the only place
  # that happened was our own toggle's OFF edge -- and the group does not send
  # a callback for the toggle it silently clears. So the stock panel came back
  # while ours was still up.
  #
  # This is the missing edge, and it is deliberately noticed on ANY foreign
  # toggle rather than only the tab bar's: whatever it was, if it turned on and
  # it is not ours, our panel has no business still being drawn.
  if turnedOn:
    gNtForeignOn = true

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
  # THE RETURN THAT ATE THE THIRD LIVE PASS. This was a bare `return` with no
  # message and no fault count -- the ONLY failure path in the whole build
  # that did neither. So eight attempts ran, none logged, the fault ceiling
  # was never reached (which is what a logged failure would have done at 4),
  # and the give-up line then printed an overwritten crumb. Everything about
  # the run said 'the tick is not working' and nothing said where.
  ntCrumb("buildOne: iGameObjectOf(SettingsScreen transform)")
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil:
    ntWhy("the SettingsScreen's GameObject could not be reached from its " &
          "transform " & iPtr(screenT) & " (name '" & iObjName(screenT) &
          "'). Component::get_gameObject returned null, which for a live " &
          "Transform should not happen -- so either that pointer is not a " &
          "Transform, or the walk up from the settings tab landed somewhere " &
          "other than the screen. Nothing was cloned and nothing changed.")
    return

  # ---- 1. THE BUTTON -------------------------------------------------------
  ntCrumb("button: donor GameObject + tab bar")
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
  # THE STOCK GAME TOGGLE, for the proof's way back. Captured from the DONOR
  # spawner (the one we cloned), because after our tab joins the stock group
  # pressing GAME is the only way to hand the screen back.
  gNtGameToggle = modsToggleOf(donorSpawnerT)
  ntCrumb("button: resolving the donor UIAnimatedToggleSpawner component")
  let donorSpawner = modsComponent(donorSpawnerT, "UIAnimatedToggleSpawner")
  if donorSpawner == nil:
    ntNoteFault("the donor tab button carries no UIAnimatedToggleSpawner " &
                "component, so the stock ToggleGroup cannot be read from it. " &
                "Nothing was changed")
    return
  ntCrumb("button: reading _toggleGroup@0xb0 off the donor COMPONENT")
  let stockGroup = (if nuOk(donorSpawner, NuOffSpawnerToggleGroup + 8'i32):
                      cNuGetRef(donorSpawner, NuOffSpawnerToggleGroup)
                    else: nil)
  if not nuOk(stockGroup, 0x10'i32):
    ntNoteFault("the stock tab bar's ToggleGroup could not be read from " &
                "_toggleGroup@0xb0 on the donor COMPONENT, so a new tab " &
                "could not join it and exclusivity would have to be enforced " &
                "by us. Refusing: that is the design this file exists to avoid")
    return
  ntCrumb("button: Instantiate of the donor tab spawner GameObject")
  let spawnerGo = modsClone(donorSpawnerGo)
  if spawnerGo == nil or not modsSetParent(spawnerGo, togglesGo):
    ntNoteFault("the tab spawner could not be cloned into the tab bar")
    return
  let spawnerT = modsTransformOf(spawnerGo)
  ntCrumb("button: fact-93 reap of the spawner clone")
  discard ntReapSpawnerClone(spawnerT, donorSpawnerT, header)
  ntCrumb("button: resolving the CLONE's UIAnimatedToggleSpawner component")
  let spawner = modsComponent(spawnerT, "UIAnimatedToggleSpawner")
  if spawner == nil:
    ntNoteFault("the cloned tab spawner has no UIAnimatedToggleSpawner " &
                "component, so SpawnObject cannot be called on it")
    discard modsSetActive(spawnerGo, false)
    return
  ntCrumb("button: SpawnObject() on the cloned spawner -- a call into game code")
  ntCallBegin("UIAnimatedToggleSpawner::SpawnObject")
  let toggle = nuSpawnerSpawn(spawner)
  ntCallEnd()
  if toggle == nil:
    ntNoteFault("SpawnObject returned nothing for the '" & header & "' tab")
    discard modsSetActive(spawnerGo, false)
    return
  ntCrumb("button: SetHeaderText / SetActive on the cloned spawner")
  ntCallBegin("UIAnimatedToggleSpawner::SetHeaderText")
  discard nuSpawnerHeader(spawner, header, 24'i32)
  ntCallEnd()
  discard nuSpawnerActive(spawner, true)
  # JOIN THE STOCK GROUP. The single most important call in this file: with it,
  # pressing our tab turns the stock ones off natively and vice versa.
  ntCrumb("button: Toggle::set_group -- joining the stock ToggleGroup")
  ntCallBegin("UnityEngine.UI.Toggle::set_group")
  let joined = nuToggleSetGroup(toggle, stockGroup)
  ntCallEnd()
  if not joined:
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
  ntCrumb("panel: Instantiate of the Game Settings panel")
  let panelGo = modsClone(donorPanelGo)
  if panelGo == nil or not modsSetParent(panelGo, screenGo):
    ntNoteFault("the settings panel could not be cloned")
    discard modsSetActive(spawnerGo, false)
    return
  let panelT = modsTransformOf(panelGo)
  ntCrumb("panel: resolving the cloned GameSettingsTab component")
  let tabComp = modsComponent(panelT, "GameSettingsTab")
  if tabComp == nil:
    ntNoteFault("the cloned panel carries no GameSettingsTab component, so " &
                "its stock rows cannot be cleaned out and it would show the " &
                "donor's settings under our tab's name")
    discard modsSetActive(panelGo, false)
    discard modsSetActive(spawnerGo, false)
    return
  # NEITHER GAME METHOD IS CALLED ON THE CLONE ANY MORE. Both were tried and
  # both failed the same way, and the second failure is what identified the
  # class:
  #
  #   (a) `Behaviour::set_enabled(false)` -- crumb stopped there, 8 of 8.
  #   (b) `SettingsTab::CleanupCreatedControls` -- crumb stopped at ENTERING,
  #       `RETURNED` never ran, 8 of 8, NO SEH fault, and the next tick ran
  #       normally with the attempt counter advanced.
  #
  # A call that neither reaches the next statement nor trips the guard, while
  # the tick survives, is a MANAGED EXCEPTION thrown inside the callee and
  # unwound through our frame (IL2CPP C++ EH). Our guard only catches access
  # violations, so it sees nothing. The likely throw is a NullReference: the
  # clone's `GameSettingsTab` never ran its own Awake/Start (it is inactive),
  # so `_createdControls@0x88` is null and cleanup dereferences it.
  #
  # SO WE DO THE WORK OURSELVES. The donor rows are children of the clone's
  # `_settingsRoot`, and `Object::Destroy` on each is a call that cannot
  # throw for a valid object. No game method with its own state assumptions is
  # involved, which is the whole point.
  ntCrumb("panel: reading _settingsRoot@0x98 off the cloned tab component")
  let rowRoot = (if nuOk(tabComp, NuOffGameTabSettingsRoot + 8'i32):
                   cNuGetRef(tabComp, NuOffGameTabSettingsRoot) else: nil)
  if not nuOk(rowRoot, 0x10'i32):
    ntNoteFault("_settingsRoot@0x98 on the cloned tab read null, so there is " &
                "nowhere to put rows and nothing to empty. The panel is hidden " &
                "again and nothing stock was touched")
    discard modsSetActive(panelGo, false)
    discard modsSetActive(spawnerGo, false)
    return
  # READ THE LIST FIRST, PURELY TO REPORT IT. If `_createdControls` really is
  # null on the clone, that is the evidence for the NullReference theory, and
  # it costs one guarded read to say so instead of leaving it inferred.
  let createdList = (if nuOk(tabComp, NuOffTabCreatedControls + 8'i32):
                       cNuGetRef(tabComp, NuOffTabCreatedControls) else: nil)
  ntCrumb("panel: destroying the donor rows under _settingsRoot ourselves")
  ntCallBegin("Object::Destroy on the cloned panel's donor rows")
  var destroyed = 0
  var kids = 0
  if iChildCount(rowRoot, kids):
    # BACKWARDS, and capped. Unity defers the actual destruction to end of
    # frame so the child list does not shift under us, but iterating down is
    # correct either way and costs nothing.
    var k = kids - 1
    while k >= 0 and destroyed < NtMaxRowDestroy:
      let c = iChildAt(rowRoot, k)
      k = k - 1
      if c == nil or not duOk(c, 0x20'i32): continue
      let go = iGameObjectOf(c)
      if go == nil: continue
      if nuDestroy(go):
        destroyed = destroyed + 1
  ntCallEnd()
  if destroyed >= NtMaxRowDestroy:
    warn "native tabs: the panel-empty walk hit its " & $NtMaxRowDestroy &
         "-row cap, so donor rows MAY REMAIN under our tab. Reported rather " &
         "than left to be noticed on screen -- the previous cap was 32 and " &
         "quietly left 8 of 40 behind."
  let leftOver = kids - destroyed
  if leftOver > 0:
    warn "native tabs: " & $leftOver & " of " & $kids & " child(ren) under " &
         "_settingsRoot were NOT destroyed. They are the ones whose " &
         "Transform or GameObject could not be read, or that Object::Destroy " &
         "refused -- not a cap. If they render, our tab shows that many of " &
         "the donor's rows."
  okLog "native tabs: '" & header & "' panel clone emptied WITHOUT calling " &
        "any SettingsTab method -- " & $destroyed & " of " & $kids &
        " donor row(s) destroyed under _settingsRoot via Object::Destroy. " &
        "The clone's _createdControls@0x88 reads " &
        (if createdList == nil: "NULL, which is consistent with the managed " &
           "exception CleanupCreatedControls threw here"
         else: "non-null (" & iPtr(createdList) & "), so the throw was " &
           "something other than a null list") &
        ". Neither set_enabled nor CleanupCreatedControls is called on the " &
        "clone; both were measured to unwind a managed exception through " &
        "our frame."
  ntCrumb("panel: hiding our clone, then registering the tab")
  discard modsSetActive(panelGo, false)   # ours starts hidden; the game owns the screen

  if gNtToggle.len < NtMaxTabs:
    gNtToggle.add toggle
    gNtPanelGo.add panelGo
    gNtTabComp.add tabComp
    gNtRowRoot.add rowRoot
    gNtId.add id
    gNtSpawnerGo.add spawnerGo
  ntCrumb("buildOne: COMPLETE -- tab registered")
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
    # A PANEL IS A CHILD NAMED "<something> Settings" -- NOT every child.
    #
    # MEASURED: the old predicate skipped two names and counted the rest, so it
    # reported "6 panels are active at once" while listing `Caption`,
    # `SaveButton`, `BackButton`, `RevertButton` and `BindContainer`. Exactly
    # ONE of those six was a panel. The verdict was not detecting a defect, it
    # was measuring the wrong thing -- and it would have gone on failing on a
    # perfectly healthy screen forever.
    #
    # This is the predicate `tools/acceptance.py` already uses ("children named
    # `* Settings`"), which on the same live screen reported `1 of 5 panel(s)
    # active`. Two checks that disagree about what they are counting cannot
    # both be right, and the one that matches the screen wins.
    if not nm.endsWith("Settings"): continue
    gNtStockPanels.add go
    gNtStockWasOn.add false

proc ntModsPageTitles(): (seq[string], seq[int]) =
  ## The mod pages `modsindex.nim` registered, as captions plus their index in
  ## `gSwPages`. Filtered on `modGuid` exactly as `modsBuildPages` does, so
  ## the host's own pages are not mistaken for mods.
  var caps: seq[string] = @[]
  var idxs: seq[int] = @[]
  var i = 0
  while i < gSwPages.len and caps.len < NtMaxSubs:
    if gSwPages[i].modGuid.len > 0:
      caps.add gSwPages[i].title
      idxs.add i
    i = i + 1
  (caps, idxs)

proc ntBuildModsSubtabs(screenT: Il2CppPtr): bool =
  ## STEP 3: one subtab per mod, inside our own MODS panel.
  ##
  ## Runs only once the index fetch has actually produced pages -- it is armed
  ## on the MODS panel's SHOW EDGE and answered asynchronously on the overlay's
  ## worker thread, so 'no pages yet' is the normal state for the first few
  ## frames and is NOT a failure.
  result = false
  if gNtSubBuilt or not gNtModsOn: return
  let (caps, idxs) = ntModsPageTitles()
  if caps.len == 0:
    return                       # not yet; the fetch is still in flight
  ntCrumb("mods: building one subtab per mod")
  if not ntBuildSubtabs(screenT, caps, NtSubRows):
    return
  gNtSubPageIdx = idxs
  okLog "native mods: built " & $caps.len & " mod subtab(s) from the " &
        "/aowlspt/settings/index fetch -- ONE top-row MODS tab with the mods " &
        "as subtabs, not one top-row tab per mod. The fetch was armed on this " &
        "panel's show edge, is cached for the session, and modSettingsRender " &
        "stays off: its boot-time per-mod fetch is the character-select " &
        "crasher this path exists to avoid."
  ntSubShow(0)
  result = true

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
  # DID THE PREVIOUS ATTEMPT COME BACK? A name still parked here means a
  # game call unwound a managed exception through our frame.
  ntCheckUnwind()
  gNtTried = gNtTried + 1
  ntWhy("build attempt " & $gNtTried & " is running from tab " &
        iPtr(gModsLastTabPtr))
  if not nuTargetsBindOk():
    ntNoteFault("the aowl_nu_targets POSITIONAL self-check FAILED, so every " &
                "call here would go to the wrong method. Nothing was built")
    return
  ntCrumb("build: iToTransform(gModsLastTabPtr) -- the live settings tab")
  let tabT = iToTransform(gModsLastTabPtr)
  let screenT = (if tabT != nil: modsParentOf(tabT) else: nil)
  if screenT == nil:
    ntNoteFault("could not reach the SettingsScreen from the live tab " &
                iPtr(gModsLastTabPtr) & " (iToTransform gave " & iPtr(tabT) &
                ", its parent gave null)")
    return
  # NAME WHAT THE WALK LANDED ON, once. `tab -> transform -> parent` is
  # ASSUMED to be the SettingsScreen and has never been checked; if it is not,
  # every child lookup below searches the wrong node and the failures read as
  # 'the pieces were not found' rather than 'we are in the wrong place'.
  ntWhy("walk: tab " & iPtr(gModsLastTabPtr) & " -> transform " & iPtr(tabT) &
        " ('" & iObjName(tabT) & "') -> parent " & iPtr(screenT) & " ('" &
        iObjName(screenT) & "'). That parent is what this treats as the " &
        "SettingsScreen; if the name is not a settings screen, the walk is " &
        "wrong and everything below it is searching the wrong subtree.")
  ntCrumb("build: walking SettingsScreen children (Toggles / GameToggleSpawner / Game Settings)")
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
  ntCrumb("build: ntBuildOne")
  if not ntBuildOne(screenT, donorSpawner, donorPanel, "nt-proof", "PROOF"):
    return
  # STEP 3'S TAB, built through the SAME `defineTab` path as the proof tab --
  # that is the point of a foundation: a second tab is one more call, not one
  # more implementation.
  if gNtModsOn:
    ntCrumb("build: the MODS tab")
    if ntBuildOne(screenT, donorSpawner, donorPanel, "nt-mods", "MODS"):
      gNtModsPanelIdx = gNtPanelGo.len - 1
      if gNtModsPanelIdx >= 0 and gNtModsPanelIdx < gNtRowRoot.len:
        gNtModsRowRoot = gNtRowRoot[gNtModsPanelIdx]
    else:
      warn "native mods: the MODS tab did not build; step 3 is inert this " &
           "session and step 1's proof tab is unaffected."

  ntCrumb("build: collecting the stock panels under SettingsScreen")
  ntCollectStockPanels(screenT)
  # STEP 2, flag-gated and default OFF: a failure here must not cost step 1.
  if gNtSubOn:
    ntCrumb("build: ntBuildSubtabs")
    discard ntBuildSubtabs(screenT,
                           @["GRAPHICS SETTINGS", "POSTFX"],
                           NtSubPanels)
  gNtBuilt = true
  result = true

# ---------------------------------------------------------------------------
# ACTIVATION -- the one piece of steering we own (doc 4)
# ---------------------------------------------------------------------------
proc ntBuildSubtabs(screenT: Il2CppPtr; captions: seq[string];
                    kind: int): bool =
  ## STEP 2: the GRAPHICS SETTINGS | POSTFX strip, as a SIBLING of the panels.
  ##
  ## The donor is `Control Settings/Toggles` -- the game's own subtab strip,
  ## which brings its `ToggleGroup` along in the clone. That matters: we cannot
  ## construct a `ToggleGroup` (AddComponent for it is not attested), so the
  ## exclusivity has to come from a cloned one. The buttons are then pointed at
  ## THAT group, never at the tab-bar group -- subtab exclusivity must not
  ## fight tab exclusivity.
  result = false
  if gNtSubBuilt or not gNtSubOn: return
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil: return
  ntCrumb("subtabs: locating the strip donor (and, for step 2, the stock panel)")
  # The stock Graphics panel is only needed by the PANEL-SWITCHING kind. For
  # the MODS kind there is no second panel: our own panel stays up and its rows
  # are swapped, so requiring Graphics here would refuse a build that does not
  # need it.
  if kind == NtSubPanels:
    gNtGfxPanelGo = iGameObjectOf(modsChildNamed(screenT, "Graphics Settings"))
  let ctrlPanel = modsChildNamed(screenT, "Control Settings")
  let donorStrip = (if ctrlPanel != nil: modsChildNamed(ctrlPanel, "Toggles")
                    else: nil)
  let donorBtn = (if donorStrip != nil:
                    modsChildNamed(donorStrip, "ControlToggle") else: nil)
  if (kind == NtSubPanels and gNtGfxPanelGo == nil) or
     donorStrip == nil or donorBtn == nil:
    ntNoteFault("subtabs: the stock Graphics panel or the strip donor was " &
                "not found (" &
                (if kind == NtSubPanels and gNtGfxPanelGo == nil:
                   "Graphics-Settings " else: "") &
                (if donorStrip == nil: "Control-Settings/Toggles " else: "") &
                (if donorBtn == nil: "ControlToggle" else: "") &
                "). Nothing was added.")
    return
  let donorStripGo = iGameObjectOf(donorStrip)
  let donorBtnGo = iGameObjectOf(donorBtn)
  if donorStripGo == nil or donorBtnGo == nil: return
  ntCrumb("subtabs: Instantiate of the strip container (brings its ToggleGroup)")
  ntCallBegin("Object::Instantiate of Control Settings/Toggles")
  let stripGo = modsClone(donorStripGo)
  ntCallEnd()
  if stripGo == nil or not modsSetParent(stripGo, screenGo):
    ntNoteFault("subtabs: the strip container could not be cloned onto the " &
                "SettingsScreen. Nothing was changed.")
    return
  let stripT = modsTransformOf(stripGo)
  # The donor's own buttons came with the clone: switch them off, so what is
  # left is exactly ours. Capped.
  ntCrumb("subtabs: switching off the donor buttons that came with the clone")
  var inherited = 0
  if iChildCount(stripT, inherited):
    var h = 0
    while h < inherited and h < NtMaxReap:
      let c = iChildAt(stripT, h)
      h = h + 1
      if c == nil or not duOk(c, 0x20'i32): continue
      let go = iGameObjectOf(c)
      if go != nil: discard modsSetActive(go, false)
  ntCrumb("subtabs: resolving the CLONED ToggleGroup")
  let subGroup = modsComponent(stripT, "ToggleGroup")
  if subGroup == nil:
    ntNoteFault("subtabs: the cloned strip carries no ToggleGroup, so the two " &
                "subtabs could not be made exclusive and both could read " &
                "selected at once. Refusing -- enforcing it ourselves is the " &
                "design this file exists to avoid.")
    discard modsSetActive(stripGo, false)
    return
  gNtSubToggle = @[]
  var made = 0
  var b = 0
  while b < captions.len and b < NtMaxSubs:
    let caption = captions[b]
    ntCrumb("subtabs: cloning the '" & caption & "' button")
    ntCallBegin("Object::Instantiate of ControlToggle")
    let btn = modsClone(donorBtnGo)
    ntCallEnd()
    if btn == nil or not modsSetParent(btn, stripGo):
      b = b + 1
      continue
    let btnT = modsTransformOf(btn)
    discard modsRelabelLike(btnT, donorBtn, caption)
    discard modsReapExtraToggles(btnT, donorBtn, caption)
    let tog = modsToggleOf(btnT)
    if tog == nil:
      discard modsSetActive(btn, false)
      b = b + 1
      continue
    # POINT IT AT THE CLONED GROUP, never the tab bar's: subtab exclusivity
    # must not fight tab exclusivity.
    ntCallBegin("UnityEngine.UI.Toggle::set_group (subtab)")
    discard nuToggleSetGroup(tog, subGroup)
    ntCallEnd()
    discard modsSetActive(btn, true)
    gNtSubToggle.add tog
    made = made + 1
    b = b + 1
  if made != captions.len:
    ntNoteFault("subtabs: only " & $made & " of " & $captions.len & " buttons " &
                "came out usable; hiding the strip rather than shipping a " &
                "half-built one with no way back.")
    discard modsSetActive(stripGo, false)
    gNtSubToggle = @[]
    return
  gNtSubStripGo = stripGo
  gNtSubBuilt = true
  gNtSubN = made
  gNtSubKind = kind
  gNtSubSel = 0
  discard modsSetActive(stripGo, false)   # raised only while our tab is up
  ntCrumb("subtabs: COMPLETE")
  okLog "native subtabs: built the GRAPHICS SETTINGS | POSTFX strip as a " &
        "SIBLING of the panels it switches, not inside either one. That is " &
        "the whole difference from the five earlier attempts: the strip is " &
        "in no stock LayoutGroup, so no stock geometry can be re-arranged by " &
        "its presence, and it does not have to exist twice to survive a " &
        "switch. Exclusivity comes from the CLONED ToggleGroup, not from us."
  result = true

proc ntDestroyChildrenOf(rt: Il2CppPtr): int =
  ## Destroy every child of `rt`, bounded. Used to swap one mod's rows for
  ## another's -- `Object::Destroy` on a valid object cannot throw, which is
  ## why this is done by hand rather than through any SettingsTab method (both
  ## of those were measured to unwind a managed exception through our frame).
  result = 0
  if not nuOk(rt, 0x10'i32): return
  var kids = 0
  if not iChildCount(rt, kids): return
  var k = kids - 1
  while k >= 0 and result < NtMaxRowDestroy:
    let c = iChildAt(rt, k)
    k = k - 1
    if c == nil or not duOk(c, 0x20'i32): continue
    let go = iGameObjectOf(c)
    if go == nil: continue
    if nuDestroy(go): result = result + 1

proc ntRenderModPage(sel: int): int =
  ## Render the selected mod's page into our MODS panel's row root, replacing
  ## whatever was there.
  ##
  ## THE ROWS ARE THE SAME ONES THE F12 OVERLAY DRAWS. `swRenderPage` is the
  ## settings-page renderer `settingspages.nim` already owns -- the row clone +
  ## relabel path that writes each TMP's own LocalizedText and registers it for
  ## re-assert. Reusing it is the point: a second renderer would drift from the
  ## first, and the relabel-that-did-not-take defects all came from paths that
  ## had no re-assert.
  result = 0
  if gNtModsRowRoot == nil: return
  if sel < 0 or sel >= gNtSubPageIdx.len: return
  let pi = gNtSubPageIdx[sel]
  if pi < 0 or pi >= gSwPages.len: return
  let rootGo = iGameObjectOf(gNtModsRowRoot)
  if rootGo == nil: return
  let cleared = ntDestroyChildrenOf(gNtModsRowRoot)
  # `renderedFor` is `swRenderPage`'s own guard against drawing the same page
  # onto the same tab twice. We DO want it drawn again -- the rows it drew
  # last time have just been destroyed -- so the bookkeeping is reset rather
  # than worked around.
  gSwPages[pi].renderedFor = 0'u64
  result = swRenderPage(gModsLastTabPtr, rootGo, gSwPages[pi])
  okLog "native mods: subtab " & $sel & " -> '" & gSwPages[pi].title &
        "' (" & gSwPages[pi].modGuid & ") rendered " & $result & " row(s) " &
        "after clearing " & $cleared & ". Rows come from swRenderPage, the " &
        "same renderer the F12 overlay uses, so they carry its LocalizedText " &
        "write and its re-assert registration rather than a second copy that " &
        "could drift."

proc ntSubShow(sel: int) =
  ## Apply the subtab selection: exactly one of the two panels is active.
  ##
  ## sel 0 -> the STOCK Graphics Settings panel (only ever SetActive'd, never
  ##          re-parented and never written to);
  ## sel 1 -> OUR panel, which is where PostFX rows will go.
  ## The strip itself is untouched by this -- it is a sibling of both, so it
  ## cannot be hidden by the thing it switches.
  if not gNtSubBuilt: return
  if gNtSubKind == NtSubRows:
    # OUR PANEL STAYS UP; only its rows change. Nothing stock is touched at
    # all here, which is why this kind needs no panel bookkeeping.
    gNtApplying = true
    var m = 0
    while m < gNtSubToggle.len and m < NtMaxSubs:
      discard nuAnimToggleSetToggled(gNtSubToggle[m], m == sel)
      m = m + 1
    gNtApplying = false
    gNtSubSel = sel
    discard ntRenderModPage(sel)
    return
  let wantOurs = (sel == 1)
  if gNtGfxPanelGo != nil and modsGoActive(gNtGfxPanelGo) == wantOurs:
    discard modsSetActive(gNtGfxPanelGo, not wantOurs)
  if gNtPanelGo.len > 0 and modsGoActive(gNtPanelGo[0]) != wantOurs:
    discard modsSetActive(gNtPanelGo[0], wantOurs)
  # THE HIGHLIGHT, through the real setter. A raw `m_IsOn` store leaves the
  # Animator untold and the wrong button looks selected -- live-confirmed on
  # the old strip, and the reason `set_IsToggled` exists in the target table.
  gNtApplying = true
  var i = 0
  while i < gNtSubToggle.len and i < NtMaxSubs:
    discard nuAnimToggleSetToggled(gNtSubToggle[i], i == sel)
    i = i + 1
  gNtApplying = false
  gNtSubSel = sel

proc ntSubVerdict(why: string) =
  ## STEP 2's finished state: exactly one subtab reads m_IsOn, its panel is
  ## the only active one of the TWO, and the stock screen is undisturbed.
  if gNtSubVerdictSaid or not gNtSubBuilt: return
  gNtSubVerdictSaid = true
  var on = 0
  var onIdx = -1
  var i = 0
  while i < gNtSubToggle.len and i < NtMaxSubs:
    let (ok, isOn) = nuToggleIsOn(gNtSubToggle[i])
    if ok and isOn:
      on = on + 1
      onIdx = i
    i = i + 1
  let gfxUp = (gNtGfxPanelGo != nil and modsGoActive(gNtGfxPanelGo))
  let oursUp = (gNtPanelGo.len > 0 and modsGoActive(gNtPanelGo[0]))
  let which = (if onIdx == 1: "POSTFX" elif onIdx == 0: "GRAPHICS SETTINGS"
               else: "none")
  if on != 1:
    warn "native subtabs VERDICT FAIL (" & why & "): " & $on & " of " &
         $gNtSubN & " subtabs read m_IsOn=1. Exactly one is the only " &
         "correct answer; 0 means a press never reached m_IsOn and 2 means " &
         "nothing is enforcing exclusivity."
  elif gfxUp and oursUp:
    warn "native subtabs VERDICT FAIL (" & why & "): BOTH the stock Graphics " &
         "panel and ours are active at once, so the visible page is whichever " &
         "draws last rather than the one the strip names (" & which & ")."
  elif not gfxUp and not oursUp:
    warn "native subtabs VERDICT FAIL (" & why & "): NEITHER panel is " &
         "active, so the page is blank while the strip says " & which & "."
  elif (onIdx == 1) != oursUp:
    warn "native subtabs VERDICT FAIL (" & why & "): the strip says " &
         which & " but the panel that is up is the other one. The switch " &
         "ran and did not take."
  else:
    okLog "native subtabs VERDICT PASS (" & why & "): exactly one subtab " &
          "reads m_IsOn=1 (" & which & ") and its panel is the ONLY active " &
          "one of the two -- read back off the live toggles and GameObjects, " &
          "not from what we wrote. The strip is a SIBLING of both panels, so " &
          "it is in no stock layout group and no stock geometry was touched."

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
  if gNtSubBuilt and idx == 0:
    # WITH SUBTABS, OUR TAB DOES NOT SIMPLY SHOW OUR PANEL. It shows whichever
    # of the two the strip names -- and one of those is the game's own Graphics
    # panel, which the loop above just switched off. So the strip is raised and
    # its selection re-applied, which may switch a stock panel back ON. That is
    # the one case where "hide every stock panel" is the wrong instinct.
    if gNtSubStripGo != nil: discard modsSetActive(gNtSubStripGo, true)
    ntSubShow(gNtSubSel)
  else:
    discard modsSetActive(gNtPanelGo[idx], true)
  gNtShown = idx

proc ntHide() =
  ## Ours off FIRST, theirs back on SECOND. The order is deliberate: restoring
  ## theirs while ours is still active is the both-panels-drawn picture the
  ## mods tab shipped once.
  if gNtShown >= 0 and gNtShown < gNtPanelGo.len:
    discard modsSetActive(gNtPanelGo[gNtShown], false)
  # The strip is ours and is a sibling, so nothing else will hide it.
  if gNtSubStripGo != nil: discard modsSetActive(gNtSubStripGo, false)
  gNtShown = -1
  var i = 0
  while i < gNtStockPanels.len and i < 24:
    if i < gNtStockWasOn.len and gNtStockWasOn[i]:
      discard modsSetActive(gNtStockPanels[i], true)
    i = i + 1

proc ntActivePanelNames(oursActive: var bool): (int, string) =
  ## How many panels under SettingsScreen are active, AND WHICH. Naming them
  ## is not decoration: the first verdict said '6 panels are active at once'
  ## and there was no way to tell whether that was six stock panels the game
  ## had not settled yet, or six of ours. A count alone cannot distinguish a
  ## real defect from a moment measured too early.
  oursActive = false
  var n = 0
  var names = ""
  var i = 0
  while i < gNtStockPanels.len and i < 24:
    if modsGoActive(gNtStockPanels[i]):
      n = n + 1
      names = names & (if names.len > 0: ", " else: "") &
              iObjName(gNtStockPanels[i]) & " (stock)"
    i = i + 1
  var k = 0
  while k < gNtPanelGo.len and k < NtMaxTabs:
    if modsGoActive(gNtPanelGo[k]):
      n = n + 1
      oursActive = true
      names = names & (if names.len > 0: ", " else: "") &
              (if k < gNtId.len: gNtId[k] else: "?") & " (OURS)"
    k = k + 1
  (n, names)

proc ntVerdict(why: string) =
  ## THE FINISHED-STATE TEST (doc 4/6), read off the live tree: exactly one
  ## panel under SettingsScreen is active, and it is the one our selection
  ## names. Zero or two is FAIL. Three outcomes.
  ##
  ## NEVER ON THE BUILD FRAME. The first live run judged the screen 63ms after
  ## building and reported '6 panels active' -- true at that instant and
  ## meaningless, because the game had not yet settled its own tab selection
  ## (acceptance measured 1 of 5 on the same screen moments later) and our
  ## toggle had never been pressed (selection=-1). A verdict taken before the
  ## thing it judges has happened is not a failing check, it is a wrong one.
  ## `why` names the occasion, so every verdict line says what prompted it.
  if gNtVerdictSaid or not gNtBuilt: return
  var oursActive = false
  let (active, names) = ntActivePanelNames(oursActive)
  gNtVerdictSaid = true
  if active == 1 and gNtShown >= 0 and oursActive:
    okLog "native tabs VERDICT PASS (" & why & "): our tab is selected and " &
          "OUR panel is the only active panel under SettingsScreen -- " &
          names & ". Read back off the live GameObjects, not from what we " &
          "wrote."
  elif active == 1 and gNtShown < 0 and not oursActive:
    okLog "native tabs VERDICT PASS (" & why & "): a stock tab is selected " &
          "and exactly one STOCK panel is active -- " & names & ". Ours is " &
          "off. The stock screen is undisturbed."
  elif active == 0:
    warn "native tabs VERDICT FAIL (" & why & "): NO panel under " &
         "SettingsScreen is active, so the screen is blank. Our selection " &
         "says " & $gNtShown & "."
  else:
    warn "native tabs VERDICT FAIL (" & why & "): " & $active & " panels " &
         "are active at once under SettingsScreen -- " & names &
         " (ours active=" & $oursActive & ", selection=" & $gNtShown &
         "). Exactly one is the only correct answer."
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
            "has stopped trying. THE LAST STEP THE FINAL ATTEMPT REACHED " &
            "WAS: " & gNtLastAttemptStep & " -- written when that step was " &
            "ENTERED, not snapshotted when the attempt returned, so an " &
            "unwind out of the guard cannot lose it.")
      return
    gNtStep = "tick: ntBuild (attempt " & $(gNtTried + 1) & ")"
    ntWhy("attempting the build now (attempt " & $(gNtTried + 1) & " of 8)")
    discard ntBuild()
    # NO SNAPSHOT HERE ANY MORE. `ntCrumb` writes the durable crumb at the
    # moment each step is ENTERED, so an unwind cannot lose it -- and a
    # snapshot taken here would actively HARM: if `ntBuild` returned at its
    # very first line, this would overwrite the deepest build crumb with a
    # tick-level one and hide the last thing that really ran.
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
      # RE-JUDGE ON THE EVENT, which is what doc 4 actually asks for: the
      # verdict follows a selection change, not a frame counter.
      gNtVerdictSaid = false
      gNtWhyNext = "toggle event -- our tab was pressed " &
                   (if isOn: "ON" else: "OFF")
  # STEP 3: the MODS panel's SHOW EDGE arms the index fetch, ONCE. Never at
  # boot -- `modSettingsRender` does that and it is the measured
  # character-select crasher. A session that never opens MODS pays nothing.
  if gNtModsOn and gNtShown >= 0 and gNtShown == gNtModsPanelIdx:
    if not gNtModsArmed:
      gNtModsArmed = true
      gNtStep = "tick: arming the /aowlspt/settings/index fetch"
      miArm(cNowMs())
    # THE FETCH ALSO HAS TO BE ADVANCED. `miTick` is otherwise only called from
    # `modsTabTickBody`, which is gated on `gModsOn` -- so a session running
    # step 3 WITHOUT the old MODS tab would arm a fetch that nothing ever
    # stepped, and wait forever for pages that were never collected. Calling it
    # from both places is safe: `miTick` returns immediately unless its phase is
    # `miArmed`, so whichever call takes the body handles it and the other is a
    # single enum test.
    gNtStep = "tick: advancing the settings-index fetch"
    miTick(cNowMs())
    if not gNtSubBuilt:
      # The fetch answers on the overlay's worker thread, so the pages arrive a
      # few frames later. Retried every tick until they do -- this is a cheap
      # seq scan, not a walk, and it stops the moment the strip is built.
      gNtStep = "tick: waiting for mod pages, then building subtabs"
      let screenT2 = modsParentOf(iToTransform(gModsLastTabPtr))
      if screenT2 != nil:
        discard ntBuildModsSubtabs(screenT2)
  # A STOCK TAB WAS SELECTED -- hand the screen back. This is the edge that was
  # missing: the stock ToggleGroup clears our toggle silently (no callback for
  # the one it turns off), so our own OFF edge never fires and only this does.
  if gNtForeignOn:
    gNtForeignOn = false
    if gNtShown >= 0:
      gNtStep = "tick: a stock tab was selected -- hiding ours"
      ntHide()
      gNtVerdictSaid = false
      gNtWhyNext = "a stock tab was selected -- ours must be off"
  # THE SUBTAB EVENT, drained from the same postfix as the tab event.
  if gNtSubPressed >= 0:
    let sidx = gNtSubPressed
    gNtSubPressed = -1
    gNtStep = "tick: applying a subtab selection"
    ntSubShow(sidx)
    gNtSubVerdictSaid = false
  if gNtSubBuilt and gNtShown >= 0:
    ntSubVerdict("subtab selection")
  gNtStep = "tick: proof / verdict"
  # THE PROOF, one bounded step per frame. Each phase waits `NtProofSettle`
  # frames before judging, because a panel switched this frame is not laid out
  # until the next -- judging on the switching frame is exactly what produced
  # the meaningless '6 panels active' reading.
  if gNtProofOn and gNtProofPhase < 6:
    if gNtProofWait > 0:
      gNtProofWait = gNtProofWait - 1
    elif gNtProofPhase == 0:
      # Let the GAME's own tab selection settle first, and judge THAT: the
      # stock screen must be sane before we touch it, or a later failure
      # cannot be attributed to us.
      gNtVerdictSaid = false
      ntVerdict("before we press anything -- the stock screen as the game left it")
      gNtProofPhase = 1
      gNtProofWait = 2
    elif gNtProofPhase == 1:
      if gNtToggle.len > 0 and nuTogglePress(gNtToggle[0], true):
        okLog "native tabs PROOF: pressed OUR tab through " &
              "Toggle::Set(true, sendCallback=true) -- the game's own " &
              "onValueChanged and the stock ToggleGroup run exactly as they " &
              "would for the player. Judging in " & $NtProofSettle & " frames."
      else:
        warn "native tabs PROOF: could not press our own toggle; the " &
             "selection half of step 1 is UNPROVEN."
        gNtProofPhase = 5
      gNtProofPhase = (if gNtProofPhase == 5: 5 else: 2)
      gNtProofWait = NtProofSettle
    elif gNtProofPhase == 2:
      gNtVerdictSaid = false
      ntVerdict("after pressing OUR tab -- expect exactly one active, ours")
      gNtProofPhase = 3
      gNtProofWait = 2
    elif gNtProofPhase == 3:
      if gNtGameToggle != nil and nuTogglePress(gNtGameToggle, true):
        okLog "native tabs PROOF: pressed the stock GAME tab back. A tab " &
              "that takes the screen and never returns it is a worse defect " &
              "than one that never takes it, so both directions are judged."
      else:
        warn "native tabs PROOF: the stock GAME toggle was not available, so " &
             "the way BACK is unproven. Our panel may still be up."
      gNtProofPhase = 4
      gNtProofWait = NtProofSettle
    elif gNtProofPhase == 4:
      gNtVerdictSaid = false
      ntVerdict("after pressing GAME back -- expect exactly one active, stock")
      gNtProofPhase = 6
    elif gNtProofPhase == 5:
      gNtProofPhase = 6
    return
  ntVerdict(gNtWhyNext)
  gNtWhyNext = "steady state"
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
