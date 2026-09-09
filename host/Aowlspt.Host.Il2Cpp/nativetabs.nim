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
## THE SPAWNER COMPONENTS -- the ONLY stable identity a spawned toggle has.
##
## TRAP T13, MEASURED `R disasm 0x37ea0c0` and confirmed live on the 15:42
## boot: ``UISpawner`1::get_SpawnedObject`` is a LAZY FACTORY, not an
## accessor. It reads `_spawnedObject@0xa0`, and if that is null OR the object
## behind it is Unity-dead (`m_CachedPtr@0x10 == 0`) it calls `SpawnObject`
## through the vtable, re-applies the header/width/ellipsis and REWRITES the
## field. Nothing announces it. Every pointer this file used to cache from
## `SpawnObject()` therefore became an orphan the moment its toggle was
## destroyed -- still readable, still reporting `m_IsOn = 0` forever, and no
## longer the object the player clicks.
##
## There is no `OnEnable` involved: MEASURED, neither ``UISpawner`1`` (9
## declared methods) nor `UIAnimatedToggleSpawner` (9) declares one. The
## trigger is "the old one is dead when someone asks", which no amount of
## being careful about SetActive would have avoided.
##
## So: hold the SPAWNER, resolve the toggle at the instant of use. These seqs
## are index-parallel with `gNtToggle`/`gNtSubToggle`, which survive only as a
## build-time record for the inventory line and are never read for state.
var gNtSpawnerComp: seq[Il2CppPtr] = @[]
var gNtGameSpawner: Il2CppPtr = nil   ## the stock GAME tab spawner component
var gNtKbSpawner: Il2CppPtr = nil     ## our CONTROLS>MODS spawner component

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
var gNtProofOn = false            ## `nativeTabsProofSelect`, now default OFF
var gNtProofTabOn = false         ## `nativeTabsProofTab`, default OFF
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
var gNtSubToggle: seq[Il2CppPtr] = @[]  ## [0]=GENERAL, [1]=POSTFX
var gNtSubSel = 0
var gNtGfxPanelGo: Il2CppPtr = nil ## the STOCK Graphics Settings panel
var gNtSubPressed = -1
## THE STRIP BELONGS TO THE STOCK GRAPHICS TAB, NOT TO ONE OF OURS.
##
## USER-VISIBLE DEFECT this corrects, reported verbatim: "when I clicked
## Settings I saw the GRAPHICS+POSTFX subtabs flash then get deleted under the
## default main GAME tab; when I clicked into GRAPHICS I don't see the subtabs
## and it overlays the GAME tab onto the GRAPHICS tab".
##
## Three mistakes, all mine, all from one wrong assumption -- that the strip
## was OUR tab's furniture:
##   * it was built ACTIVE, while GAME was the selected tab (the flash);
##   * it was then hidden by the foreign-toggle edge and never raised again,
##     because nothing tied it to GRAPHICS;
##   * `ntSubShow` drove the stock Graphics panel regardless of which tab was
##     selected, so it fought the stock group's own panel switching and left
##     two `* Settings` panels active -- the GAME-over-GRAPHICS overlay.
##
## The strip is furniture of the STOCK GRAPHICS TAB. It is visible if and only
## if the stock GRAPHICS toggle is on, and it switches the two STOCK panels
## (Graphics Settings and PostFX Settings) -- not one of ours. Nothing here
## touches the Game panel, ever.
var gNtGfxTabToggle: Il2CppPtr = nil  ## the STOCK GRAPHICS tab toggle
var gNtGfxTabOn = false               ## is GRAPHICS the selected tab?
var gNtSubHiddenSaid = false          ## the 'not judged, tab hidden' line, said once
var gNtSubPanelA: Il2CppPtr = nil     ## stock Graphics Settings
var gNtSubPanelB: Il2CppPtr = nil     ## stock PostFX Settings
var gNtSubPressedGfx = -1             ## 1 = GRAPHICS on, 0 = off, -1 = nothing
## True when the LAST subtab press came through the postfix rather than from
## our own apply -- i.e. a real mouse click. Logged, because 'our code can
## press it' and 'the player can press it' are different claims and only the
## second was in doubt.
var gNtSubPressedByPlayer = false
## Toggles we have already reported once. Capped: this is a census, not a
## log of every press.
const NtMaxSeenToggles = 24
var gNtSeenToggles: seq[Il2CppPtr] = @[]
## OUR OWN SELECTION WRITES MUST NOT RE-ENTER OUR OWN POSTFIX.
##
## MEASURED: ten `native subtabs VERDICT PASS` lines inside 160ms, alternating
## between POSTFX and GENERAL. That is not a noisy cadence, it is a
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
## THE STOCK GRAPHICS TAB WENT ON. Separate from `gNtForeignOn` because the
## GRAPHICS edge is classified BEFORE the foreign-toggle branch (it is the
## strip's furniture) and therefore never reached it -- MEASURED, host log
## 2026-09-04: 'native subtabs VERDICT FAIL: P1 2 panel(s) active: Graphics
## Settings (stock), nt-mods (OURS)', repeatedly, after pressing GRAPHICS
## while the MODS tab was up. Our panel is not the strip, so its ON edge has
## to hide ours as any other stock selection would.
var gNtStockGfxOn = false
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

## STEP 4 -- CONTROLS > MODS. Offsets MEASURED offline (tools/fldoff.py,
## System.String self-check passing), so no live probe was needed and no
## inspector batch was written while the client was mid-run.
##
## `EFT.UI.Settings.ControlSettingsTab`:
##   0x98  _commandKeyPairTemplate : CommandKeyPair   <- THE ROW PREFAB
##   0xa8  _commandsContainer      : RectTransform    <- where rows go
##   0xd8  _controlButton          : UIAnimatedToggleSpawner  (stock strip)
##   0xe0  _gesturesButton         : UIAnimatedToggleSpawner
##   0xe8  _controlPanel / 0xf0 _gesturesPanel : GameObject
##
## CONTROLS ALREADY HAS A STOCK SUBTAB STRIP -- that is what `_controlButton`
## and `_gesturesButton` are. So ours JOINS it as a third entry rather than
## building a strip of its own, exactly as POSTFX joined GRAPHICS.
##
## `EFT.UI.Settings.CommandKeyPair` (the row):
##   0x70  _commandName : LocalizedText   <- action name. NOT a plain TMP.
##   0x80  _keyName     : TMP_Text        <- key label
##   0x90  _key2Name    : TMP_Text        <- secondary key
##   0x78  _keyButton / 0x88 _key2Button : Button  (rebinding -- NOT touched)
##
## `_commandName` being a LocalizedText is the whole reason the relabel has to
## go through `LocalizedText::SetLabelText` and be RE-APPLIED: a raw `m_text`
## store is clobbered by the component, which is the documented trap and the
## source of every 'the caption did not take' defect in this repo.
const NtOffCtrlKeyTemplate = 0x98'i32
const NtOffCtrlCommandsRoot = 0xa8'i32
const NtOffCtrlControlBtn = 0xd8'i32
const NtOffKpCommandName = 0x70'i32
const NtOffKpKeyName = 0x80'i32
const NtOffKpKey2Name = 0x90'i32
var gNtKbOn = false                 ## `nativeTabsKeybinds`
var gNtKbBuilt = false
var gNtKbArmed = false
var gNtKbPanelGo: Il2CppPtr = nil   ## our CONTROLS>MODS panel
var gNtKbRowRoot: Il2CppPtr = nil   ## its row container
var gNtKbTemplate: Il2CppPtr = nil  ## the stock CommandKeyPair prefab
var gNtKbToggle: Il2CppPtr = nil    ## our subtab toggle in the STOCK strip
var gNtKbRows = 0
var gNtKbVerdictSaid = false
var gNtKbPressed = -1               ## 1 = shown, 0 = hidden, -1 = nothing
var gNtToggleSlotFaults = 0

## ===========================================================================
## STEP 5 -- THE GRAPHICS SUBTABS, REBUILT ON THE GAME'S OWN MECHANISM.
##
## THE VERDICTS ARE WRITTEN HERE, BEFORE THE CODE, and every one of them names
## the input that makes it FAIL. A check whose failing input cannot be stated
## is not a check (CLAUDE.md 9b). All are judged AT LEAST ONE FRAME after the
## change (`NtVerdictDelay`), because a LayoutGroup rebuild is deferred to
## `willRenderCanvases` and `Object.Destroy` to end of frame -- a same-frame
## read is INCONCLUSIVE, never PASS.
##
##  P1  Exactly one of the SettingsScreen children named `* Settings` reports
##      activeInHierarchy, plus our own panel if one of our tabs is up.
##      FAILS ON: two active (the GAME-over-GRAPHICS overlay), or zero (blank).
##  P2  `_currentTab@0x118` is non-null and its GameObject is that panel.
##      FAILS ON: we SetActive'd a panel without telling the game, so
##      `_currentTab` names a different one -- exactly what the old
##      hide-all-then-show-one did.
##  P3  Exactly one toggle in the STOCK tab-bar ToggleGroup reads
##      `m_IsOn@0x120 != 0`, and while the PostFX panel is up it is GRAPHICS.
##      FAILS ON: ShowScreen(PostFX) leaving the hidden stock POSTFX toggle on
##      and GRAPHICS off, so the top row lights nothing.
##  P4  Exactly one toggle in OUR cloned subtab group reads m_IsOn, and the
##      panel that is up is the one that subtab names.
##      FAILS ON: zero (a press never reached m_IsOn) or two (nothing is
##      enforcing exclusivity), or the strip saying POSTFX while Graphics is up.
##  P5  No TMP under a page of ours still reads the donor's caption.
##      FAILS ON: a relabel that "landed" without changing the glyphs -- this
##      repo's signature defect. Enforced for the keybind page by comparing
##      each row's `_keyName` against the template's captured text.
##  P6  The strip's `childCount == 2`. FAILS ON: cloning two more
##      ControlToggles beside the two the clone already carried (§5 T12 -- it
##      is 4 today, and 2 of those 4 are toggles we never reparented).
##  P7  The strip's parent carries no LayoutGroup, OR the strip's
##      LayoutElement has ignoreLayout set. FAILS ON: reading it back off the
##      resulting rect instead of off the component, which is measuring a
##      coincidence (§3: Graphics and PostFX agree on height only because
##      1010-225 == 785 at this window size).
##  P8  CLOSE: after Back, judged one frame later, the close drain logged
##      ENTERED and CloseAll logged RETURNED, and every ToggleGroup we joined
##      has stopped naming a toggle of ours.
##      FAILS ON: "entered, never returned" -- a throw or fault unwound
##      through the close, which is what all three of 2026-09-02's deaths
##      looked like and what nothing in this host could see.
## ===========================================================================

## ESettingsGroup, MEASURED `R fields ESettingsGroup` 2026-09-02: exactly five
## values and no spare. The GRAPHICS tab is `Screen == 0`; there is no
## "Graphics" member. A sixth value is not merely unsupported -- it makes
## `EnsureTabInitialized`'s default case throw, and a managed throw is
## invisible to `aowl_p_p_seh` (§5 T1 / T9).
const NtGroupScreen = 0'i32       ## the tab the UI calls GRAPHICS
const NtGroupPostFx = 4'i32
## How long to ignore ON edges on our own subtab toggles after WE asked for a
## selection. Nothing we issue carries a callback any more, so in principle
## this window should never catch anything -- and that is exactly why it is
## kept and LOGGED: if it ever fires, something we did is still producing a
## synthetic press and the log says so instead of the screen flickering.
const NtSettleFrames = 12
const NtVerdictDelay = 2          ## frames between a change and judging it

var gNtScreen: Il2CppPtr = nil        ## the live SettingsScreen, from the rider
var gNtSubGroup: Il2CppPtr = nil      ## OUR cloned subtab ToggleGroup
var gNtSubSpawner: seq[Il2CppPtr] = @[]  ## UIAnimatedToggleSpawner per subtab
var gNtTabGroup: Il2CppPtr = nil      ## the STOCK tab-bar ToggleGroup
var gNtGfxTabSpawner: Il2CppPtr = nil ## stock GraphicsToggleSpawner component
var gNtPostFxTabSpawner: Il2CppPtr = nil
## RETIRED BY T13: there is no stable pointer to a spawned toggle, so the
## stock PostFX toggle is resolved through `gNtPostFxTabSpawner` at every
## point of use instead of being remembered here.
var gNtPostFxTabToggle: Il2CppPtr = nil
var gNtLastGroup = -1'i32             ## the last group ShowScreen reported
var gNtSettleFrames = 0
var gNtVerdictDue = 0
var gNtSettleAteSaid = false
var gNtStripParentLayout = "not examined"
var gNtStripIgnoreLayout = false
## THE CLOSE PAIR's bookkeeping. Two counters and two flags; the postfix
## handler touches nothing else, which is why it needs no guard.
var gNtCloseEnters = 0
var gNtCloseAllReturns = 0
var gNtCloseInFlight = false
var gNtCloseUnreturnedSaid = false
var gNtKbDonorKey = ""                ## the row template's own key caption
var gNtGfxEdgeSaid = false
var gNtSpawnerMissSaid = false

proc ntSpawnerToggleNow(spawner: Il2CppPtr): Il2CppPtr =
  ## The CURRENT LIVE toggle of one spawner, or nil -- for STATE reads.
  ## Raw `_spawnedObject@0xa0` plus the game's own `m_CachedPtr@0x10` test,
  ## never the property getter, which would SPAWN (T13).
  nuSpawnerCurrentToggle(spawner)

proc ntSpawnerEnsureToggle(spawner: Il2CppPtr; who: string): Il2CppPtr =
  ## BUILD-TIME ONLY: return the spawner's toggle, CREATING it if there is
  ## none yet. Never called from a drain, a tick or a verdict.
  ##
  ## THE MEASURED DEFECT THIS FIXES (host log 17:38, lines 873-875): both
  ## cloned subtab spawners read `_spawnedObject@0xa0` as null-or-dead AT
  ## BUILD, so the build refused both and hid the strip -- "only 0 of 2
  ## subtabs came out usable". The strip never appeared at all.
  ##
  ## The refusal was right about the fact and wrong about the moment. T13 says
  ## the spawner is a LAZY factory: the field stays null until somebody asks,
  ## and a freshly `Instantiate`d spawner has never been asked. Verifying
  ## before asking is checking for a thing whose absence we ourselves caused.
  ##
  ## So the build ASKS ONCE. `UIAnimatedToggleSpawner::SpawnObject` @0x16BC7F0
  ## is UNIQUE, non-generic and already in the target table, so there is no
  ## shared-generic `MethodInfo*` hazard -- unlike `get_SpawnedObject`
  ## @0x37EA0C0, whose generic body needs a real `MethodInfo*` we have no way
  ## to supply. MEASURED (`R disasm 0x16bc7f0`) it does exactly what is
  ## wanted: base `SpawnObject` (which fills `_spawnedObject@0xa0`), then
  ## `SetToggleGroup(tog, this._toggleGroup@0xb0, true)` and
  ## `set_interactable`. The header caption is applied by the caller
  ## afterwards, as it already was.
  ##
  ## THE READ COMES FIRST AND IS OBEYED. If a toggle is already there we do
  ## NOT spawn -- fact #93: calling `SpawnObject` on a spawner that already
  ## has one produces a SECOND toggle, which is the extra unlabelled
  ## rectangle this file has reaped before.
  result = ntSpawnerToggleNow(spawner)
  if result != nil:
    return
  if spawner == nil:
    return
  ntCallBegin("UIAnimatedToggleSpawner::SpawnObject (" & who & ")")
  discard nuSpawnerSpawn(spawner)
  ntCallEnd()
  # VERIFY BY RE-READING THE FIELD, not by trusting the return. The whole
  # point of T13 is that the field is the authority and a returned pointer is
  # a snapshot; and `SpawnObject`'s own return is a different local from the
  # thing it stored, so reading back is the only way to know the field took.
  result = ntSpawnerToggleNow(spawner)
  if result == nil:
    warn "gfx strip: asked '" & who & "' spawner " & iPtr(spawner) &
         " to SpawnObject and _spawnedObject@0xa0 STILL reads null or " &
         "Unity-dead afterwards. That is not the lazy-factory case -- the " &
         "spawn itself did not take -- so this subtab has no toggle and " &
         "cannot be made to work."

proc ntSpawnerToggleId(spawner: Il2CppPtr): Il2CppPtr =
  ## The spawner's toggle for POINTER IDENTITY ONLY, on the game's click path.
  ##
  ## Deliberately does NOT test liveness: a pointer that equals the `this` of
  ## a `Toggle::Set` currently executing is alive by construction, and the
  ## liveness test used to be `Object::op_Implicit` -- a managed call issued
  ## from inside a prefix drain for EVERY toggle in the game. That call is the
  ## prime suspect for the live 17:38 miss, where the stock GraphicsToggle
  ## press fell through to the by-name branch with
  ## "the spawner read did not match".
  nuSpawnerSpawnedRaw(spawner)

proc ntTabToggleNow(i: int): Il2CppPtr =
  ## Our i-th TOP-ROW tab's live toggle.
  if i < 0 or i >= gNtSpawnerComp.len: return nil
  ntSpawnerToggleNow(gNtSpawnerComp[i])

proc ntSubToggleNow(i: int): Il2CppPtr =
  ## Our i-th SUBTAB's live toggle. This is the read that was wrong: the
  ## verdict used to ask a build-time pointer for `m_IsOn` and got 0 from a
  ## dead object while a live one sat on screen unselected.
  if i < 0 or i >= gNtSubSpawner.len: return nil
  ntSpawnerToggleNow(gNtSubSpawner[i])

proc ntSubCount(): int =
  ## How many subtabs exist, counted from the STABLE handles.
  result = gNtSubSpawner.len
  if result > NtMaxSubs: result = NtMaxSubs

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
## ---- WHERE THE STRIP SITS IN THE SIBLING LIST -------------------------
##
## THE DEFECT, reported by the user on the deployed build: the strip drew
## ABOVE EVERYTHING, including each panel's 'Overlay Layer/SettingsTooltip'.
## Every stock tab and panel draws UNDER the tooltip; ours drew over it.
##
## THE CAUSE was one line, `nuSetAsLastSibling(stripT)`, and the comment next
## to it -- "sibling order IS raycast order" -- was true and was the wrong
## conclusion. In a Unity canvas sibling order is BOTH draw order and raycast
## order, and LAST means topmost in both. That is right for a floating overlay
## with nothing else to answer to; it is wrong for a strip that is furniture
## of the screen and must live in the same stacking band as the tab bar.
##
## THE FIX IS A POSITION, NOT A Z-HACK: the strip goes at the FRONT of the
## list, before the tab bar and before every '* Settings' panel, so it draws
## under all of them and under their tooltips.
##
## WHY IT STILL RECEIVES ITS CLICKS, and this is the part that must be checked
## rather than asserted: a bottom sibling only loses a click to something that
## OVERLAPS it. The body offset (`ntBodyApply`) already moves both panels out
## of the strip's 128..174 px band, and the tab bar sits above that band. So
## nothing overlaps the strip and index 0 costs nothing -- but if that ever
## stops being true the strip goes inert with no other symptom, which is why
## the verdict below measures the overlap instead of trusting this paragraph.
##
## DEVIATION, STATED: the request was "immediately after the 'Toggles' tab bar
## (index 3)". There is no `UnityEngine.Transform::SetSiblingIndex` in the
## target table -- only SetAsFirstSibling / SetAsLastSibling -- and adding one
## means editing the ABI header, which correctly drops every cache and forces
## a full rebuild. Reaching index 3 without it would mean moving the GAME'S
## OWN tab bar to index 0, i.e. writing stock draw order to fix ours. FIRST
## satisfies the stated property exactly ("strip index < index of every
## '* Settings' panel") and writes nothing but our own object.
proc ntStripOrder(stripT: Il2CppPtr): bool =
  result = nuFirstSibling(stripT)
  if not result:
    warn "gfx strip: SetAsFirstSibling was refused, so the strip keeps " &
         "whatever sibling index it has -- if that is LAST it will draw over " &
         "the panels' SettingsTooltip, which is the reported defect. Nothing " &
         "else was changed."

proc ntStripOrderVerdict() =
  ## THE NEGATIVE, read back one frame later off `Transform::GetSiblingIndex`:
  ## NO '* Settings' panel has a LOWER sibling index than the strip.
  ##
  ## FAIL looks like: any panel at an index below the strip's (the strip is
  ## drawing over that panel and over its tooltip), or the strip's band
  ## intersecting the tab bar's (at index 0 an overlapping sibling would
  ## swallow every click and the strip would look disabled while
  ## `m_Interactable` is true).
  if not gNtSubBuilt or gNtSubKind != NtSubPanels: return
  if gNtSubStripGo == nil: return
  let stripT = modsTransformOf(gNtSubStripGo)
  let screenT = modsParentOf(stripT)
  if stripT == nil or screenT == nil:
    warn "gfx strip ORDER VERDICT INCONCLUSIVE: the strip's transform or its " &
         "parent could not be read, so no sibling index can be compared."
    return
  let (sok, sidx) = nuSiblingIndex(stripT)
  if not sok:
    warn "gfx strip ORDER VERDICT INCONCLUSIVE: Transform::GetSiblingIndex " &
         "refused on the strip. 'I could not look' is not a pass."
    return
  var n = 0
  if not iChildCount(screenT, n):
    warn "gfx strip ORDER VERDICT INCONCLUSIVE: the SettingsScreen's " &
         "childCount could not be read."
    return
  var panels = 0
  var above = 0
  var firstAbove = ""
  var togIdx = -1
  var i = 0
  while i < n and i < 48:
    let c = iChildAt(screenT, i)
    if c != nil and duOk(c, 0x20'i32):
      let nm = iObjName(c)
      if nm == "Toggles": togIdx = i
      if modsNameHas(nm, "Settings") and c != stripT:
        panels = panels + 1
        if i < sidx:
          above = above + 1
          if firstAbove.len == 0: firstAbove = nm & " at index " & $i
    i = i + 1
  if panels == 0:
    warn "gfx strip ORDER VERDICT INCONCLUSIVE: not one '* Settings' panel " &
         "was found among the SettingsScreen's " & $n & " child(ren), so " &
         "there is nothing to compare the strip against."
    return
  if above > 0:
    warn "gfx strip ORDER VERDICT FAIL: the strip is at sibling index " &
         $sidx & " and " & $above & " of " & $panels & " '* Settings' " &
         "panel(s) sit BELOW it (first: " & firstAbove & "), so the strip " &
         "draws over those panels and over their 'Overlay Layer/" &
         "SettingsTooltip'. Every stock tab draws UNDER the tooltip; this is " &
         "the reported defect, read back from Transform::GetSiblingIndex."
    return
  okLog "gfx strip ORDER VERDICT PASS: the strip is at sibling index " &
        $sidx & " and NO '* Settings' panel (of " & $panels &
        ") has a lower index, so it draws under every panel and under their " &
        "SettingsTooltip. The 'Toggles' tab bar is at index " &
        (if togIdx >= 0: $togIdx else: "NOT FOUND") &
        ". Read back from Transform::GetSiblingIndex one frame after the " &
        "change, not from the call that made it."

## THE POSTFX GRAY-OUT RIDES THIS DRAIN. Forward-declared because
## `postfxrows.nim` is `include`d after this file; the alternative -- a second
## physical detour on `UnityEngine.UI.Toggle::Set` -- would overwrite this
## one's trampoline and silently kill the subtab strip, which is the
## double-detour rule stated as code rather than as a comment.
proc pfxOnToggleSet(tog: Il2CppPtr; turnedOn: bool)

proc ntToggleSetFired(regs: Il2CppPtr) =
  ## THE `gNtToggle.len == 0` GUARD THAT USED TO BE HERE WAS THE BUG.
  ##
  ## It meant "we own no tabs, so no toggle event can concern us" -- true when
  ## the only thing this feature watched was its OWN tab toggles. It stopped
  ## being true the moment the subtab strip became furniture of the STOCK
  ## GRAPHICS tab, and it became FATAL in the same change that defaulted the
  ## PROOF tab off: with no tab of ours, `gNtToggle` is empty, so this returned
  ## on every event and the stock GraphicsToggle edge was never seen. The user
  ## saw the strip build and then never appear, with nothing in the log --
  ## because this line ran before anything could be logged.
  ##
  ## The subtab path is now INDEPENDENT of whether we own any tab at all.
  if not gNtOn or gNtOff:
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
  # THE POSTFX GRAY-OUT DRAINS HERE, FIRST, and returns immediately unless
  # this pointer is one of the two toggles it follows. It is placed before the
  # tab loops on purpose: the GAME'S 'Enable PostFX' toggle is not one of our
  # tabs or subtabs, so every loop below would fall through to the "other"
  # classification and the event would be lost. Two pointer compares.
  pfxOnToggleSet(selfPtr, turnedOn)
  # MATCH AGAINST THE CURRENT SPAWNED TOGGLE, NEVER A CACHED ONE (T13).
  # This is <=4 guarded 8-byte reads on the game's click path, which is a real
  # cost and is accepted deliberately: the alternative -- comparing against a
  # pointer captured at build time -- is what made the strip stop responding
  # after the player cycled the top-row tabs, silently, with every press
  # classified `matched-as=other`.
  var i = 0
  while i < gNtSpawnerComp.len and i < NtMaxTabs:
    if ntSpawnerToggleId(gNtSpawnerComp[i]) == selfPtr:
      # ONLY THE ON EDGE, and this is the measured order, not a preference.
      # §2.3: pressing B while A is on runs `A.Set(false, sendCallback)` from
      # INSIDE `B.Set`, with the flag propagated VERBATIM -- so every OFF edge
      # of ours arrives with sendCallback=true and arrives BEFORE the ON edge.
      # Recording both meant the last write won by accident rather than by
      # rule. The OFF direction is not lost: the stock group clears our toggle
      # SILENTLY when a stock tab is chosen (no callback for the one it turns
      # off), so `gNtForeignOn` -- not this -- is the edge that hides our panel,
      # and it always was.
      if turnedOn:
        gNtPressed = i
      return
    i = i + 1
  # SUBTABS RIDE THE SAME POSTFIX. No second detour: two detours on one
  # function have the second overwrite the first's trampoline and silently kill
  # the first feature. Still O(1)-ish -- two more pointer compares -- and still
  # silent for every foreign toggle.
  var j = 0
  while j < gNtSubSpawner.len and j < NtMaxSubs:
    if ntSpawnerToggleId(gNtSubSpawner[j]) == selfPtr:
      # ONLY THE ON EDGE IS A PRESS. This drain is a PREFIX, and a press on
      # one subtab makes the cloned ToggleGroup call Set(false, true) on the
      # OTHER one from inside the first call -- so the nested OFF arrives
      # LAST and, before this test, overwrote the press with the index of the
      # toggle that was switched OFF. Live, every press then read as POSTFX:
      # GENERAL lit up, the PostFX panel stayed, both looked
      # selected. The OFF edge carries no information the ON edge does not.
      if turnedOn:
        # THE SETTLE WINDOW, and the measurement it exists for.
        #
        # MEASURED (deployed build a1fa38, host log 2026-09-02 6:59.469 and
        # 7:25.532): every GENERAL press was followed 0.4-1.0s later
        # by a POSTFX ON edge the player never made, so GRAPHICS lit while the
        # page flipped back to PostFX and both looked selected. MEASURED CAUSE
        # (`R disasm 0x16ad190`): `AnimatedToggle::set_IsToggled` -- which
        # `ntSubShow` used for the highlight -- calls
        # `Toggle::Set(value, sendCallback)` with `mov r8b,1`. Every highlight
        # we applied WAS a real press.
        #
        # The fix is that nothing this file issues carries a callback any more
        # (`nuSpawnerToggleSilently` / `nuToggleSetQuiet`). This window is the
        # BACKSTOP, and it is deliberately loud: if it ever swallows an edge,
        # something we do is still synthesising presses, and the log says so
        # rather than the screen flickering.
        if gNtSettleFrames > 0:
          if not gNtSettleAteSaid:
            gNtSettleAteSaid = true
            warn "native subtabs: IGNORED an ON edge on subtab " & $j &
                 " that arrived inside our own " & $NtSettleFrames &
                 "-frame settle window. Nothing this host issues is supposed " &
                 "to be able to produce one any more -- every selection we " &
                 "apply goes through ToggleSilently, which is MEASURED to " &
                 "call Toggle::Set with sendCallback=0. So this line means a " &
                 "synthetic press is still being generated somewhere and the " &
                 "0.4-1.0s phantom POSTFX press is not fully gone."
          return
        gNtSubPressed = j
        gNtSubPressedByPlayer = true
      return
    j = j + 1
  # THE CONTROLS>MODS SUBTAB, on the same postfix as everything else.
  if gNtKbSpawner != nil and ntSpawnerToggleId(gNtKbSpawner) == selfPtr:
    gNtKbPressed = (if turnedOn: 1 else: 0)
    return
  # NAME THE EVENT, ONCE PER DISTINCT TOGGLE. Every toggle in the game funnels
  # through here, so this must not be per-event work -- it is per NEW pointer,
  # capped, and it is what turns "nothing happened" into a list of what
  # actually arrived and how each one was classified.
  var matchedAs = "other"
  if gNtGfxTabSpawner != nil and
     ntSpawnerToggleId(gNtGfxTabSpawner) == selfPtr:
    matchedAs = "graphics(spawned-object identity)"
  # MATCH BY NAME TOO, not only by the pointer captured at build. A spawner
  # respawns its toggle, so a cached pointer can go stale while the button on
  # screen is the same button -- and a stale pointer fails silently, which is
  # the failure mode this whole pass has been chasing.
  var goName = ""
  var parentName = ""
  let selfGo = nuGameObjectOf(selfPtr)
  if selfGo != nil:
    goName = iObjName(selfGo)
    let pt = modsParentOf(modsTransformOf(selfGo))
    if pt != nil: parentName = iObjName(pt)
  if matchedAs == "other" and
     (parentName.contains("GraphicsToggleSpawner") or
      goName.contains("GraphicsToggle")):
    # NO RE-CACHING. The by-name branch used to store the pointer it had just
    # seen, which is the T13 mistake written down: the very next respawn made
    # it an orphan again. The spawner is what gets remembered, and it is
    # remembered at build time and never revised.
    matchedAs = "graphics(by name -- the spawner read did not match)"
    # AND IT MUST SAY WHY, ONCE. Live at 17:38 this branch fired for the stock
    # GraphicsToggle and the log could only report that the read "did not
    # match" -- a symptom, not a cause, and it cost a round trip. These four
    # numbers separate every candidate cause from every other. Printed once
    # per session, and never on a matching event.
    if not gNtSpawnerMissSaid:
      gNtSpawnerMissSaid = true
      let raw = nuSpawnerSpawnedRaw(gNtGfxTabSpawner)
      let alt = (if nuOk(raw, 0xd8'i32): cNuGetRef(raw, 0xd0'i32) else: nil)
      warn "native subtabs SPAWNER-IDENTITY MISS on the stock GraphicsToggle:" &
           " spawner=" & iPtr(gNtGfxTabSpawner) &
           " _spawnedObject@0xa0=" & iPtr(raw) &
           " [that+0xd0]=" & iPtr(alt) &
           " event this=" & iPtr(selfPtr) &
           ". _spawnedObject@0xa0 IS the AnimatedToggle -- PROVEN from " &
           "R disasm 0x16bc7f0, where the base SpawnObject return is handed " &
           "to Selectable::set_interactable, and UISpawnableToggle is NOT a " &
           "Selectable (its _sizeLabel@0xb0 collides with " &
           "Selectable.m_SpriteState@0xb0, so one type cannot be both). The " &
           "+0xd0 hop printed here for comparison belongs to " &
           "_spawnableToggle@0xc0, the serialized PREFAB that " &
           "get_SpawnableToggle @0x16BC670 reads (mov rdi,[rbx+0xc0]) -- NOT " &
           "to @0xa0. READ IT THIS WAY: if `this` equals the @0xa0 value, our " &
           "gate is at fault; if it equals the +0xd0 value, this build's " &
           "layout is not what the disassembly says and nothing here should " &
           "be trusted until that is settled; if it equals neither, this " &
           "spawner does not own the toggle that fired."
  var known = false
  var si = 0
  while si < gNtSeenToggles.len and si < NtMaxSeenToggles:
    if gNtSeenToggles[si] == selfPtr:
      known = true
      break
    si = si + 1
  if not known and gNtSeenToggles.len < NtMaxSeenToggles:
    gNtSeenToggles.add selfPtr
    okLog "native subtabs TOGGLE EVENT (first time for this toggle): this=" &
          iPtr(selfPtr) & " go='" & goName & "' parent='" & parentName &
          "' value=" & $turnedOn & " matched-as=" & matchedAs &
          ". Every Toggle::Set in the game passes through here; this line is " &
          "printed once per distinct toggle, so the whole tab strip appears " &
          "in the log exactly once and a toggle we FAIL to classify is " &
          "visible rather than silent."
  # THE STOCK GRAPHICS TAB. The strip is its furniture, so its edges -- ON and
  # OFF -- are what raise and hide it. This is checked BEFORE the generic
  # foreign-toggle branch so that selecting GRAPHICS does not read as "some
  # stock tab was selected, hide everything of ours".
  if matchedAs != "other":
    gNtSubPressedGfx = (if turnedOn: 1 else: 0)
    # ...BUT THE STRIP IS NOT THE ONLY THING OF OURS ON THIS SCREEN. If one of
    # OUR top-level panels (MODS) is up, a GRAPHICS ON edge is a stock
    # selection like any other and our panel must go. Recorded as its own flag
    # and drained in the tick, because `ntHide` is defined far below this
    # postfix and nothing here may call into the game.
    if turnedOn:
      gNtStockGfxOn = true
    return
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
  # THE STOCK GAME TAB, held as its SPAWNER (T13): the toggle it spawned is
  # replaced without notice, so a pointer to it is a pointer to an orphan by
  # the time the proof wants to press GAME back.
  gNtGameToggle = modsToggleOf(donorSpawnerT)
  gNtGameSpawner = modsComponent(donorSpawnerT, "UIAnimatedToggleSpawner")
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
  ntCrumb("panel: retiring the donor rows under _settingsRoot (no Destroy)")
  ntCallBegin("SetActive(false) on the cloned panel's donor rows")
  var kids = 0
  discard iChildCount(rowRoot, kids)
  let retired = ntRetireChildrenOf(rowRoot)
  ntCallEnd()
  if retired >= NtMaxRowDestroy:
    warn "native tabs: the panel-retire walk hit its " & $NtMaxRowDestroy &
         "-row cap, so donor rows MAY REMAIN VISIBLE under our tab."
  let stillOn = ntActiveChildCount(rowRoot)
  if stillOn > 0:
    warn "native tabs: " & $stillOn & " of " & $kids & " child(ren) under " &
         "_settingsRoot are STILL ACTIVE after the retire pass, so our tab " &
         "shows that many of the donor's rows."
  okLog "native tabs: '" & header & "' panel clone emptied by SWITCHING THE " &
        "DONOR ROWS OFF, not by destroying them -- " & $retired & " of " &
        $kids & " row(s) retired, " & $stillOn & " still active. Destroy was " &
        "used here until the client died in the raid LOAD right after a boot " &
        "that destroyed 80 of them (top frame " &
        "il2cpp_unity_liveness_calculation_from_root): a destroyed row is " &
        "still referenced from stock managed lists we cannot audit, and the " &
        "liveness walk dereferences it. An inactive row does not render, " &
        "which is all we ever needed. The clone's _createdControls@0x88 " &
        "reads " & (if createdList == nil: "NULL" else: iPtr(createdList)) & "."

  ntCrumb("panel: hiding our clone, then registering the tab")
  discard modsSetActive(panelGo, false)   # ours starts hidden; the game owns the screen

  if gNtToggle.len < NtMaxTabs:
    # `gNtToggle` survives ONLY as a build-time record for the inventory line.
    # Nothing reads it for state: `gNtSpawnerComp` is the stable handle and
    # `ntTabToggleNow` is the only way the live toggle is obtained (T13).
    gNtSpawnerComp.add spawner
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

proc ntBuildControlsMods(screenT: Il2CppPtr): bool =
  ## STEP 4: a MODS entry on the STOCK Controls subtab strip.
  ##
  ## Controls already HAS a strip -- `_controlButton` and `_gesturesButton` are
  ## `UIAnimatedToggleSpawner`s with `_controlPanel`/`_gesturesPanel` behind
  ## them. So this does NOT build a strip: it clones one stock spawner into the
  ## same parent and joins the SAME ToggleGroup, exactly as POSTFX joined
  ## GRAPHICS. The game then enforces exclusivity across all three and we
  ## enforce nothing.
  result = false
  if gNtKbBuilt or not gNtKbOn: return
  ntCrumb("keybinds: resolving the stock Control Settings tab")
  let ctrlPanelT = modsChildNamed(screenT, "Control Settings")
  if ctrlPanelT == nil:
    ntNoteFault("keybinds: no 'Control Settings' panel under SettingsScreen")
    return
  let ctrlTab = modsComponent(ctrlPanelT, "ControlSettingsTab")
  if ctrlTab == nil:
    ntNoteFault("keybinds: the Control Settings panel carries no " &
                "ControlSettingsTab component, so neither the row prefab nor " &
                "the stock subtab strip can be reached. Nothing was changed.")
    return
  ntCrumb("keybinds: reading _commandKeyPairTemplate@0x98 and the stock strip")
  gNtKbTemplate = (if nuOk(ctrlTab, NtOffCtrlKeyTemplate + 8'i32):
                     cNuGetRef(ctrlTab, NtOffCtrlKeyTemplate) else: nil)
  let stockBtn = (if nuOk(ctrlTab, NtOffCtrlControlBtn + 8'i32):
                    cNuGetRef(ctrlTab, NtOffCtrlControlBtn) else: nil)
  if not nuOk(gNtKbTemplate, 0x10'i32) or not nuOk(stockBtn, 0x10'i32):
    ntNoteFault("keybinds: the CommandKeyPair row prefab (@0x98) or the stock " &
                "_controlButton spawner (@0xd8) read null. Both are " &
                "serialized references populated when the prefab loads, so " &
                "this is 'asked too early' rather than a wrong offset. " &
                "Nothing was cloned.")
    return
  # CAPTURE THE TEMPLATE'S OWN KEY CAPTION, for P5's negative.
  #
  # A count of rows cannot see a relabel that did not take -- that is this
  # repo's signature defect and the reason 9b exists. The falsifiable question
  # is "does any row still read what the PREFAB read", and it can only be
  # asked if the prefab's own text was recorded before we wrote anything.
  # MEASURED offsets: `_keyName@0x80` is a plain `TMP_Text` on
  # `EFT.UI.Settings.CommandKeyPair` (fldoff.py, 2026-09-02), NOT a
  # LocalizedText -- unlike `_commandName@0x70`, which is.
  gNtKbDonorKey = ""
  if nuOk(gNtKbTemplate, NtOffKpKeyName + 8'i32):
    let dtmp = cNuGetRef(gNtKbTemplate, NtOffKpKeyName)
    if nuOk(dtmp, 0x10'i32):
      gNtKbDonorKey = nuGetText(dtmp)
  # THE BUTTON: clone the stock spawner into the same parent, join its group.
  let stockBtnGo = nuGameObjectOf(stockBtn)
  let stripT = (if stockBtnGo != nil:
                  modsParentOf(modsTransformOf(stockBtnGo)) else: nil)
  let stripGo = (if stripT != nil: iGameObjectOf(stripT) else: nil)
  if stockBtnGo == nil or stripGo == nil:
    ntNoteFault("keybinds: the stock Controls strip could not be reached from " &
                "_controlButton. Nothing was changed.")
    return
  let stockGroup = (if nuOk(stockBtn, NuOffSpawnerToggleGroup + 8'i32):
                      cNuGetRef(stockBtn, NuOffSpawnerToggleGroup) else: nil)
  if not nuOk(stockGroup, 0x10'i32):
    ntNoteFault("keybinds: the stock Controls strip has no readable " &
                "ToggleGroup, so a third entry could not be made exclusive " &
                "with the other two. Refusing.")
    return
  ntCrumb("keybinds: Instantiate of the stock Controls subtab button")
  ntCallBegin("Object::Instantiate of the Controls subtab spawner")
  let btnGo = modsClone(stockBtnGo)
  ntCallEnd()
  if btnGo == nil or not modsSetParent(btnGo, stripGo):
    ntNoteFault("keybinds: the MODS subtab button could not be cloned into " &
                "the stock Controls strip.")
    return
  let btnT = modsTransformOf(btnGo)
  discard ntReapSpawnerClone(btnT, modsTransformOf(stockBtnGo), "MODS")
  let spawner = modsComponent(btnT, "UIAnimatedToggleSpawner")
  if spawner == nil:
    ntNoteFault("keybinds: the cloned Controls subtab has no spawner component")
    discard modsSetActive(btnGo, false)
    return
  ntCallBegin("UIAnimatedToggleSpawner::SpawnObject (controls MODS)")
  gNtKbSpawner = spawner
  gNtKbToggle = nuSpawnerSpawn(spawner)
  ntCallEnd()
  if gNtKbToggle == nil:
    ntNoteFault("keybinds: SpawnObject produced no toggle for CONTROLS>MODS")
    discard modsSetActive(btnGo, false)
    return
  discard nuSpawnerHeader(spawner, "MODS", 24'i32)
  discard nuSpawnerActive(spawner, true)
  ntCallBegin("UnityEngine.UI.Toggle::set_group (controls MODS)")
  discard nuToggleJoinGroup(gNtKbToggle, stockGroup)
  ntCallEnd()
  # THE PANEL: clone the stock Controls panel and empty it, the same way the
  # MODS tab's panel is made -- and by the same route, because both
  # SettingsTab methods that would 'do it properly' were measured to unwind a
  # managed exception through our frame.
  ntCrumb("keybinds: Instantiate of the Controls panel for our subpage")
  ntCallBegin("Object::Instantiate of Control Settings")
  let panelGo = modsClone(iGameObjectOf(ctrlPanelT))
  ntCallEnd()
  if panelGo == nil or not modsSetParent(panelGo, iGameObjectOf(screenT)):
    ntNoteFault("keybinds: our CONTROLS>MODS panel could not be cloned")
    discard modsSetActive(btnGo, false)
    return
  let panelT = modsTransformOf(panelGo)
  let ourTab = modsComponent(panelT, "ControlSettingsTab")
  gNtKbRowRoot = (if ourTab != nil and
                     nuOk(ourTab, NtOffCtrlCommandsRoot + 8'i32):
                    cNuGetRef(ourTab, NtOffCtrlCommandsRoot) else: nil)
  if not nuOk(gNtKbRowRoot, 0x10'i32):
    ntNoteFault("keybinds: _commandsContainer@0xa8 on our cloned Controls " &
                "panel read null, so there is nowhere to put rows.")
    discard modsSetActive(panelGo, false)
    discard modsSetActive(btnGo, false)
    return
  discard ntRetireChildrenOf(gNtKbRowRoot)
  gNtKbPanelGo = panelGo
  discard modsSetActive(panelGo, false)
  gNtKbBuilt = true
  ntCrumb("keybinds: COMPLETE")
  okLog "keybinds: added a MODS entry to the STOCK Controls subtab strip -- " &
        "cloned from _controlButton and joined to the SAME ToggleGroup, so " &
        "the game makes it exclusive with KEYBOARD AND MOUSE and GESTURES " &
        "and we enforce nothing. Its page is a cloned Controls panel emptied " &
        "of the donor's rows; rows are the stock CommandKeyPair prefab."
  result = true

proc ntKeybindRow(idx: int): bool =
  ## ONE keybind row, cloned from the game's own `CommandKeyPair` prefab.
  ##
  ## THE TWO LABELS ARE NOT THE SAME KIND OF OBJECT, and treating them alike
  ## is the trap: `_commandName@0x70` is a `LocalizedText`, which CLOBBERS a
  ## raw `m_text` store, while `_keyName@0x80` is a plain `TMP_Text`.
  ## `nuSetText` is given the LocalizedText for the first and nil for the
  ## second, so each goes through its own real setter and is re-applied.
  result = false
  if gNtKbTemplate == nil or gNtKbRowRoot == nil: return
  if idx < 0 or idx >= kbCount(): return
  let row = nuInstantiateUnder(gNtKbTemplate, gNtKbRowRoot)
  if row == nil: return
  let go = nuGameObjectOf(row)
  if go == nil: return
  let b = gKbBinds[idx]
  # THE MOD NAME IS ITS OWN ROW NOW, so a bind row shows only its action --
  # prefixing every action with the mod would repeat the heading on every line
  # and push the useful text off the column.
  let caption = (if b.heading: "-- " & b.modName & " --" else: b.action)
  # ACTION NAME -- through its own LocalizedText, and re-applied.
  var okName = false
  if nuOk(row, NtOffKpCommandName + 8'i32):
    let loc = cNuGetRef(row, NtOffKpCommandName)
    if nuOk(loc, 0x10'i32):
      okName = nuSetText(loc, caption, loc)
  # KEY LABEL -- a plain TMP.
  var okKey = false
  if nuOk(row, NtOffKpKeyName + 8'i32):
    let tmp = cNuGetRef(row, NtOffKpKeyName)
    if nuOk(tmp, 0x10'i32):
      # A heading has no key. Writing "" is deliberate rather than skipping:
      # the cloned row arrives carrying the DONOR's key text, and leaving it
      # would put a real-looking bind next to a mod name.
      okKey = nuSetText(tmp, b.key)
  # SECONDARY KEY -- blanked, not left showing the donor's second bind.
  if nuOk(row, NtOffKpKey2Name + 8'i32):
    let tmp2 = cNuGetRef(row, NtOffKpKey2Name)
    if nuOk(tmp2, 0x10'i32):
      discard nuSetText(tmp2, "")
  discard nuSetActive(go, true)
  if not okName or not okKey:
    warn "keybinds: row " & $idx & " (" & caption & ") did not fully " &
         "relabel (action=" & $okName & " key=" & $okKey & "), so it may " &
         "still read the donor's caption. Left up and reported rather than " &
         "hidden -- the verdict below reads the finished text back."
  result = true

proc ntBuildKeybindRows(): int =
  ## Render every served bind, once. Capped by `kbCount` itself, which the
  ## fetch already bounded.
  result = 0
  if gNtKbRowRoot == nil: return
  discard ntRetireChildrenOf(gNtKbRowRoot)
  var i = 0
  while i < kbCount() and i < NtMaxRowDestroy:
    if ntKeybindRow(i): result = result + 1
    i = i + 1
  gNtKbRows = result
  okLog "keybinds: rendered " & $result & " of " & $kbCount() & " served " &
        "bind(s) as VANILLA CommandKeyPair rows, cloned from the stock " &
        "prefab the Keyboard and Mouse page uses. DISPLAY ONLY -- the row's " &
        "_keyButton is left exactly as cloned and nothing here rebinds " &
        "anything; rebinding is a later pass."

proc ntKbVerdict() =
  ## STEP 4's finished state, read off the live rows: as many rows as binds
  ## served, and NO row still reading the donor's caption. The negative is the
  ## one that matters -- a relabel that did not take is this repo's signature
  ## defect and a count alone cannot see it.
  if gNtKbVerdictSaid or not gNtKbBuilt: return
  gNtKbVerdictSaid = true
  var kids = 0
  discard iChildCount(gNtKbRowRoot, kids)
  # ---- P5, THE NEGATIVE: no row still reads the TEMPLATE's key caption ----
  #
  # This is the check that CAN fail. The counts below compare our own
  # bookkeeping against a container we filled -- useful, but a self-comparison,
  # and a self-comparison passed while sixteen rows were visibly wrong on
  # screen (9b). Reading each finished row's `_keyName@0x80` back through
  # `TMP_Text::get_text` and asking whether ANY of them still reads what the
  # prefab read is a property of the finished tree, and it fails the moment a
  # relabel lands in the model without reaching the glyphs.
  #
  # THE ONE HONEST AMBIGUITY, stated rather than hidden: if a served bind's
  # key text legitimately EQUALS the template's, this cannot tell a stale row
  # from a correct one. That is INCONCLUSIVE, not PASS.
  var stale = 0
  var firstStale = ""
  var unread = 0
  var legit = 0
  if gNtKbDonorKey.len > 0:
    var r = 0
    while r < kids and r < NtMaxRowDestroy:
      let c = iChildAt(gNtKbRowRoot, r)
      r = r + 1
      if c == nil or not duOk(c, 0x20'i32): continue
      let rowComp = modsComponent(c, "CommandKeyPair")
      if rowComp == nil or not nuOk(rowComp, NtOffKpKeyName + 8'i32):
        unread = unread + 1
        continue
      let tmp = cNuGetRef(rowComp, NtOffKpKeyName)
      if not nuOk(tmp, 0x10'i32):
        unread = unread + 1
        continue
      if nuGetText(tmp) == gNtKbDonorKey:
        stale = stale + 1
        if firstStale.len == 0: firstStale = iObjName(c)
    var q = 0
    while q < kbCount() and q < NtMaxRowDestroy:
      if gKbBinds[q].key == gNtKbDonorKey: legit = legit + 1
      q = q + 1
  if gNtKbDonorKey.len == 0:
    warn "keybinds VERDICT INCONCLUSIVE: the CommandKeyPair template's own " &
         "key caption could not be read, so 'no row still reads the donor's " &
         "caption' -- the only predicate here that CAN fail -- was never " &
         "asked. The counts below are a self-comparison and cannot detect a " &
         "relabel that landed in the model without reaching the glyphs."
  elif stale > legit:
    warn "keybinds VERDICT FAIL: " & $stale & " row(s) still read the " &
         "TEMPLATE's key caption '" & gNtKbDonorKey & "' (first: " &
         firstStale & ") while only " & $legit & " served bind(s) " &
         "legitimately carry that text. The relabel did not take on the " &
         "difference. `_keyName@0x80` is a plain TMP_Text and goes through " &
         "TMP_Text::set_text @0x51BC1E0; `_commandName@0x70` is a " &
         "LocalizedText and goes through SetLabelText @0x140FE70 and must be " &
         "RE-APPLIED, because UpdateLocale clobbers a raw store."
  elif unread > 0:
    warn "keybinds VERDICT INCONCLUSIVE: " & $unread & " of " & $kids &
         " row(s) could not be read back, so the donor-caption negative was " &
         "asked of only " & $(kids - unread) & " of them. 'I could not look' " &
         "is not a pass."
  if gNtKbRows != kbCount():
    warn "keybinds VERDICT FAIL: " & $gNtKbRows & " row(s) rendered but " &
         $kbCount() & " bind(s) were served. Every served bind must have a " &
         "row; the difference is binds the player cannot see."
  elif kids != gNtKbRows:
    warn "keybinds VERDICT FAIL: " & $gNtKbRows & " row(s) were built but " &
         "the container holds " & $kids & " child(ren) -- something else " &
         "added or removed rows after we did."
  else:
    okLog "keybinds VERDICT PASS: " & $gNtKbRows & " row(s) rendered for " &
          $kbCount() & " served bind(s), and the container holds exactly " &
          "that many children -- read back off the live tree. Rows are the " &
          "game's own CommandKeyPair prefab, so the format is vanilla by " &
          "construction rather than by imitation."

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
  # THE PROOF TAB IS OFF BY DEFAULT NOW. Step 1 is proven and the player does
  # not want a PROOF tab in their settings row. Everything below is
  # deliberately NOT gated on it: the subtab strip belongs to the STOCK
  # GRAPHICS tab and must build whether or not any tab of ours exists.
  if gNtProofTabOn:
    if not ntBuildOne(screenT, donorSpawner, donorPanel, "nt-proof", "PROOF"):
      warn "native tabs: the PROOF tab did not build; the subtab strip is " &
           "independent of it and still will."
  else:
    okLog "native tabs: the PROOF tab is OFF (nativeTabsProofTab), so no tab " &
          "of ours is added to the row. The GENERAL|POSTFX subtab strip is " &
          "unaffected -- it belongs to the STOCK Graphics tab, not to ours."
  # STEP 3'S TAB, built through the SAME `defineTab` path as the proof tab --
  # that is the point of a foundation: a second tab is one more call, not one
  # more implementation.
  # STEP 4: the CONTROLS > MODS subpage. Independent of the MODS TAB above --
  # it joins the game's own Controls strip rather than adding a top-row tab.
  if gNtKbOn:
    ntCrumb("build: CONTROLS > MODS")
    discard ntBuildControlsMods(screenT)
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
    let subOk = ntBuildGfxStrip(screenT)
    okLog "native subtabs: build attempted (nativeTabsSubtabs is ON) and " &
          "returned " & $subOk & ". NOTE FOR ACCEPTANCE: this strip is a " &
          "SIBLING of the panels, parented to SettingsScreen -- it is NOT a " &
          "Toggles(Clone) under Graphics Settings, and looking for one there " &
          "will not find it. That relocation is the fix, not a regression: " &
          "inside the panel is where it re-arranged the game's scroll view."
  elif gGfxOn:
    warn "native subtabs: settingsPostFxSubtab is ON but nativeTabsSubtabs " &
         "is OFF, so the strip was NOT built and the stock POSTFX tab is " &
         "hidden with nothing able to reach PostFX. The flag chain should " &
         "have prevented this -- report it."
  gNtBuilt = true
  ntInventory("build complete")
  result = true

# ---------------------------------------------------------------------------
# ACTIVATION -- the one piece of steering we own (doc 4)
# ---------------------------------------------------------------------------
proc ntBuildGfxStrip(screenT: Il2CppPtr): bool =
  ## STEP 5: the GENERAL | POSTFX strip, built the way the map says
  ## and switched by the game's own `ShowScreen`.
  ##
  ## WHAT CHANGED FROM THE VERSION THIS REPLACES, and each line is a measured
  ## defect, not a preference:
  ##
  ##  * IT CLONES `Control Settings/Toggles` ONCE AND REUSES THE TWO TOGGLES
  ##    THAT CAME WITH IT. The old build cloned the container (which brought
  ##    ControlToggle and GesturesToggle along) and then cloned TWO MORE
  ##    ControlToggles into it -- §5 T12, MEASURED LIVE: `childCount = 4`, of
  ##    which two were the donor's own toggles that we never reparented and
  ##    never took out of whatever group they name. Switching them off did not
  ##    make them ours. P6 is `childCount == 2` and it FAILS on exactly that.
  ##
  ##  * NOTHING IS WIRED TO THEM AND NOTHING NEEDS UNWIRING. §2.10a, MEASURED
  ##    LIVE by the coordinator: on both the stock GesturesToggle and the
  ##    clone's, `onValueChanged@0x118 -> m_PersistentCalls@0x18 ->
  ##    m_Calls@0x10 -> _size@0x18` is 0, and `m_Calls@0x10 ->
  ##    m_RuntimeCalls@0x18 -> _size` is 0. The prefab-serialized-handler
  ##    inference in §2.10 is REFUTED; a cloned strip is inert until our drain
  ##    rides it.
  ##
  ##  * THE GROUP IS JOINED BY READING, NOT BY ASSUMING. Instantiating a
  ##    subtree remaps an internal reference to the clone -- so the cloned
  ##    toggles' `m_Group@0x110` SHOULD already name the cloned ToggleGroup.
  ##    "Should" is not a measurement, and if it named the STOCK Controls group
  ##    instead, our two subtabs would be fighting KEYBOARD AND MOUSE for
  ##    exclusivity. So `m_Group` is READ and only corrected when it disagrees,
  ##    and only through `SetToggleGroup` @0x55BA150 -- the REGISTERING join
  ##    (§6.2.1). `set_group` @0x55B9D30 writes the field alone, which is
  ##    precisely the §5 T3 throw on the next `Set(true, ...)`.
  ##
  ##  * `m_AllowSwitchOff@0x20` IS LEFT FALSE. §2.3 step 3a then refuses to
  ##    turn the last-on toggle off, so the strip can never end up with zero
  ##    selected. We enforce nothing.
  result = false
  if gNtSubBuilt:
    return
  if not gNtSubOn:
    warn "native subtabs: NOT BUILDING -- nativeTabsSubtabs is OFF at the " &
         "moment ntBuildGfxStrip was called. The flag chain " &
         "(settingsPostFxSubtab -> nativeTabsSubtabs -> nativeTabs) is what " &
         "should have set it."
    return
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil:
    warn "native subtabs: NOT BUILDING -- the SettingsScreen GameObject could " &
         "not be reached from " & iPtr(screenT) & "."
    return
  gNtScreen = modsComponent(screenT, "SettingsScreen")
  ntCrumb("gfx strip: locating the two stock panels and the tab-bar toggles")
  # THE TWO STOCK PANELS ARE RECORDED FOR THE VERDICT ONLY. Nothing in this
  # file SetActives either of them any more: `ShowScreen` does that, and doing
  # it ourselves as well is what left GAME and GRAPHICS both drawn.
  gNtSubPanelA = iGameObjectOf(modsChildNamed(screenT, "Graphics Settings"))
  gNtSubPanelB = iGameObjectOf(modsChildNamed(screenT, "PostFX Settings"))
  gNtGfxPanelGo = gNtSubPanelA
  let tg = modsChildNamed(screenT, "Toggles")
  let gfxSpawnT = (if tg != nil:
                     modsChildNamed(tg, "GraphicsToggleSpawner") else: nil)
  let pfxSpawnT = (if tg != nil:
                     modsChildNamed(tg, "PostFxToggleSpawner") else: nil)
  # THE SPAWNERS ARE WHAT IS KEPT (T13). `gNtGfxTabToggle` is read ONCE here,
  # only to find the tab-bar ToggleGroup, and is never used as an identity
  # afterwards -- every later question about the stock GRAPHICS toggle goes
  # through `gNtGfxTabSpawner` and a fresh `_spawnedObject@0xa0` read.
  gNtGfxTabSpawner = (if gfxSpawnT != nil:
                        modsComponent(gfxSpawnT, "UIAnimatedToggleSpawner")
                      else: nil)
  gNtPostFxTabSpawner = (if pfxSpawnT != nil:
                           modsComponent(pfxSpawnT, "UIAnimatedToggleSpawner")
                         else: nil)
  gNtGfxTabToggle = (if gNtGfxTabSpawner != nil:
                       ntSpawnerToggleNow(gNtGfxTabSpawner)
                     elif gfxSpawnT != nil: modsToggleOf(gfxSpawnT) else: nil)
  gNtTabGroup = nuToggleGroupOf(gNtGfxTabToggle)
  if gNtSubPanelA == nil or gNtSubPanelB == nil or gNtGfxTabToggle == nil or
     gNtScreen == nil:
    ntNoteFault("gfx strip: the pieces were not all found (" &
                (if gNtSubPanelA == nil: "Graphics-Settings " else: "") &
                (if gNtSubPanelB == nil: "PostFX-Settings " else: "") &
                (if gNtGfxTabToggle == nil: "GraphicsToggle " else: "") &
                (if gNtScreen == nil: "SettingsScreen-component" else: "") &
                "). Nothing was added and no stock object was touched.")
    return
  ntCrumb("gfx strip: cloning Control Settings/Toggles ONCE")
  let ctrlPanel = modsChildNamed(screenT, "Control Settings")
  let donorStrip = (if ctrlPanel != nil: modsChildNamed(ctrlPanel, "Toggles")
                    else: nil)
  let donorStripGo = (if donorStrip != nil: iGameObjectOf(donorStrip) else: nil)
  if donorStripGo == nil:
    ntNoteFault("gfx strip: Control Settings/Toggles -- the donor that brings " &
                "its own ToggleGroup along in the clone -- was not found. We " &
                "cannot construct a ToggleGroup, so there is no way to make " &
                "two subtabs exclusive without it. Refusing.")
    return
  ntCallBegin("Object::Instantiate of Control Settings/Toggles")
  let stripGo = modsClone(donorStripGo)
  ntCallEnd()
  if stripGo == nil or not modsSetParent(stripGo, screenGo):
    ntNoteFault("gfx strip: the strip container could not be cloned onto the " &
                "SettingsScreen. Nothing was changed.")
    return
  let stripT = modsTransformOf(stripGo)
  let subGroup = modsComponent(stripT, "ToggleGroup")
  if subGroup == nil:
    ntNoteFault("gfx strip: the cloned strip carries no ToggleGroup, so the " &
                "two subtabs could not be made exclusive and both could read " &
                "selected at once. Refusing -- enforcing it ourselves is the " &
                "design this file exists to avoid.")
    discard modsSetActive(stripGo, false)
    return
  gNtSubGroup = subGroup
  # P6, READ BEFORE ANYTHING IS ADDED. The clone must arrive with exactly the
  # donor's two toggles. If it does not, this is not the tree the map
  # describes and reusing children by index would be guessing.
  var kids = 0
  var donorKids = 0
  if not iChildCount(stripT, kids) or not iChildCount(donorStrip, donorKids):
    ntNoteFault("gfx strip: the cloned strip's childCount could not be read, " &
                "so which objects are ours is UNKNOWN. Refusing.")
    discard modsSetActive(stripGo, false)
    return
  if kids != 2 or donorKids != 2:
    ntNoteFault("gfx strip: the clone has " & $kids & " child(ren) and the " &
                "donor has " & $donorKids & "; this path reuses the donor's " &
                "TWO cloned toggles (ControlToggle, GesturesToggle) as " &
                "GENERAL and POSTFX and expects exactly two. " &
                "Refusing rather than reusing children by index in a tree " &
                "that is not the one the map describes.")
    discard modsSetActive(stripGo, false)
    return
  gNtSubToggle = @[]
  gNtSubSpawner = @[]
  var made = 0
  var joined = 0
  var alreadyOurs = 0
  var b = 0
  while b < 2 and b < NtMaxSubs:
    let caption = (if b == 0: "GENERAL" else: "POSTFX")
    let c = iChildAt(stripT, b)
    let donorC = iChildAt(donorStrip, b)
    if c == nil or not duOk(c, 0x20'i32):
      b = b + 1
      continue
    let cgo = iGameObjectOf(c)
    if cgo == nil:
      b = b + 1
      continue
    ntCrumb("gfx strip: enabling and relabelling '" & caption & "'")
    # ENABLE FIRST. `Toggle::OnEnable` @0x55B9F50 calls
    # `SetToggleGroup(this, m_Group@0x110)` unconditionally (§2.10), so a
    # toggle whose serialized group is already the cloned one registers itself
    # here without us writing anything.
    discard modsSetActive(cgo, true)
    let sp = modsComponent(c, "UIAnimatedToggleSpawner")
    # SAY WHAT THE CLONE ARRIVED HOLDING, before we touch it. The 17:38 boot
    # could not distinguish "the clone came out empty" from "the donor strip
    # was itself never spawned" (the stock Controls strip is plausibly
    # unspawned until `ControlSettingsTab::Show` runs, and the player may
    # never have opened Controls). One raw read each answers it for good.
    let donorSp = (if donorC != nil:
                     modsComponent(donorC, "UIAnimatedToggleSpawner") else: nil)
    okLog "gfx strip: at clone time '" & caption & "' spawner=" & iPtr(sp) &
          " _spawnedObject@0xa0=" & iPtr(nuSpawnerSpawnedRaw(sp)) &
          "; its DONOR spawner=" & iPtr(donorSp) & " _spawnedObject@0xa0=" &
          iPtr(nuSpawnerSpawnedRaw(donorSp)) & ". A null on the donor means " &
          "the stock Controls strip has not been shown this session and had " &
          "nothing to clone; a null on ours alone means Instantiate did not " &
          "carry the reference. Either way the next line spawns it."
    # ASK ONCE, THEN VERIFY (T13's lazy factory). Refusing before asking is
    # what hid the whole strip at 17:38.
    let tog = (if sp != nil: ntSpawnerEnsureToggle(sp, caption)
               else: nil)
    # NO SPAWNER MEANS NO STABLE IDENTITY (T13). A subtab whose toggle can
    # only ever be named by a pointer we captured is a subtab that will stop
    # responding the first time that toggle is replaced -- which is exactly
    # what the 15:42 boot measured. Refusing is still the honest answer HERE,
    # but only after the spawn has actually been attempted.
    if sp == nil or tog == nil:
      warn "gfx strip: '" & caption & "' has " &
           (if sp == nil: "no UIAnimatedToggleSpawner component"
            else: "a spawner that produced no toggle even after SpawnObject") &
           ", so its live toggle cannot be resolved at press time and the " &
           "subtab would be dead. Switching it off rather than shipping a " &
           "button that does nothing."
      discard modsSetActive(cgo, false)
      b = b + 1
      continue
    # FACT #93: a cloned spawner can arrive already carrying the donor's
    # toggle AND then spawn a second. Reap back to the donor's child count.
    discard ntReapSpawnerClone(c, donorC, caption)
    # THE SPAWNER'S OWN GROUP FIELD IS THE DURABLE ONE, and under T13 that
    # distinction decides whether this survives a respawn.
    #
    # MEASURED (map 2.10, `R disasm 0x16bc7f0`): `SpawnObject` joins the new
    # toggle to `this._toggleGroup@0xb0` -- the SPAWNER's field, not the old
    # toggle's. So joining the toggle we can see fixes only the toggle we can
    # see; the next respawn re-reads `_toggleGroup@0xb0` and puts the
    # replacement wherever THAT points. If it pointed at the stock Controls
    # group, our two subtabs would silently start fighting KEYBOARD AND MOUSE
    # for exclusivity.
    #
    # Instantiating a subtree remaps an internal reference to the clone, and
    # the ToggleGroup lives on the strip root we cloned, so this SHOULD
    # already be our cloned group. "Should" is not a measurement. It is READ,
    # and a disagreement REFUSES the subtab rather than being written over:
    # `_toggleGroup@0xb0` is an 8-byte managed reference slot, and this whole
    # change adds no raw store to any such slot anywhere.
    let spGrp = (if nuOk(sp, NuOffSpawnerToggleGroup + 8'i32):
                   cNuGetRef(sp, NuOffSpawnerToggleGroup) else: nil)
    if spGrp != subGroup:
      warn "gfx strip: '" & caption & "' spawner's _toggleGroup@0xb0 is " &
           iPtr(spGrp) & " but our cloned ToggleGroup is " & iPtr(subGroup) &
           ". SpawnObject joins a RESPAWNED toggle to the spawner's field, " &
           "not to whatever we joined the old toggle to (T13), so this " &
           "subtab would leave our group the first time its toggle is " &
           "replaced -- and land in whatever group that pointer names, " &
           "plausibly the stock Controls strip's. REFUSING this subtab " &
           "rather than writing an 8-byte reference slot to paper over it."
      discard modsSetActive(cgo, false)
      b = b + 1
      continue
    # THE GROUP THE LIVE TOGGLE IS IN, from what the field SAYS.
    let grp = nuToggleGroupOf(tog)
    if grp == subGroup:
      alreadyOurs = alreadyOurs + 1
    else:
      ntCallBegin("UnityEngine.UI.Toggle::SetToggleGroup (subtab)")
      if nuToggleJoinGroup(tog, subGroup):
        joined = joined + 1
      ntCallEnd()
    discard nuSpawnerHeader(sp, caption, 24'i32)
    discard modsRelabelLike(c, donorC, caption)
    gNtSubToggle.add tog
    gNtSubSpawner.add sp
    made = made + 1
    b = b + 1
  if made != 2 or gNtSubSpawner.len != 2:
    ntNoteFault("gfx strip: only " & $made & " of 2 subtabs came out usable; " &
                "hiding the strip rather than shipping a half-built one with " &
                "no way back to PostFX.")
    discard modsSetActive(stripGo, false)
    gNtSubToggle = @[]
    gNtSubSpawner = @[]
    return
  okLog "gfx strip: reused the CLONE'S OWN two toggles as GENERAL " &
        "and POSTFX -- " & $alreadyOurs & " already named the cloned " &
        "ToggleGroup (Instantiate remapped the reference, as expected) and " &
        $joined & " were joined with Toggle::SetToggleGroup @0x55BA150, the " &
        "REGISTERING call. No ControlToggle was cloned a second time, so the " &
        "strip holds 2 children and not the 4 that trap T12 measured live. " &
        "m_AllowSwitchOff is left FALSE, so Toggle::Set step 3a refuses to " &
        "turn the last-on subtab off and the strip can never read zero."
  # THE CLONE INHERITED THE DONOR'S CANVASGROUP STATE, and the donor
  # (`Control Settings/Toggles`) was HIDDEN when we cloned it. alpha 0 or
  # blocksRaycasts false makes every Selectable under it inert while our own
  # calls still succeed -- the "renders but will not click" shape.
  let stripCg = modsComponent(stripT, "CanvasGroup")
  if stripCg == nil:
    okLog "gfx strip: the cloned strip carries NO CanvasGroup, so that is not " &
          "why a subtab would refuse a click. Nothing was forced."
  else:
    let (cgOk, cgA, cgI) = nuCgRead(stripCg)
    if cgOk:
      okLog "gfx strip: the cloned strip's CanvasGroup arrived alpha=" &
            nuF(cgA) & " interactable=" & $cgI & ", inherited from a donor " &
            "panel that was HIDDEN at clone time. Forcing alpha 1 / " &
            "interactable / blocksRaycasts."
    else:
      warn "gfx strip: the strip HAS a CanvasGroup that could not be read, so " &
           "whether it is why a subtab refuses a click is UNKNOWN. Forcing it."
    discard nuCgMakeUsable(stripCg)
  # P7, READ OFF THE COMPONENTS -- never inferred from the resulting rect (§3:
  # the two panels' heights agree only by arithmetic coincidence at this
  # window size, so any geometry-derived conclusion here measures nothing).
  gNtStripParentLayout = "none"
  if modsComponent(screenT, "VerticalLayoutGroup") != nil:
    gNtStripParentLayout = "VerticalLayoutGroup"
  elif modsComponent(screenT, "HorizontalLayoutGroup") != nil:
    gNtStripParentLayout = "HorizontalLayoutGroup"
  elif modsComponent(screenT, "GridLayoutGroup") != nil:
    gNtStripParentLayout = "GridLayoutGroup"
  if gNtStripParentLayout != "none":
    let le = modsComponent(stripT, "LayoutElement")
    if le != nil and nuSetIgnoreLayout(le, true):
      gNtStripIgnoreLayout = true
  discard ntStripOrder(stripT)   # UNDER the panels and their tooltips
  gNtSubStripGo = stripGo
  gNtSubBuilt = true
  gNtSubN = made
  gNtSubKind = NtSubPanels
  gNtSubSel = 0
  discard modsSetActive(stripGo, false)   # raised by the ShowScreen rider
  ntCrumb("gfx strip: COMPLETE")
  okLog "gfx strip: built GENERAL | POSTFX as a SIBLING of the " &
        "panels, parented to SettingsScreen. Selection is now the GAME's: a " &
        "press calls SettingsScreen::ShowScreen(screen, group, NULL) " &
        "@0x1720DE0 and NOTHING else is SetActive'd by us -- ShowScreen does " &
        "OLD-OFF -> EnsureTabInitialized -> NEW-ON and keeps _currentTab@0x118 " &
        "consistent, which no amount of our own SetActive can. Strip " &
        "visibility and the highlight come back through the SAME ShowScreen " &
        "postfix, so our own switch and the player's are indistinguishable. " &
        "Parent LayoutGroup: " & gNtStripParentLayout & "; ignoreLayout " &
        "forced: " & $gNtStripIgnoreLayout & "."
  result = true

proc ntBuildSubtabs(screenT: Il2CppPtr; captions: seq[string];
                    kind: int): bool =
  ## STEP 2: the GENERAL | POSTFX strip, as a SIBLING of the panels.
  ##
  ## The donor is `Control Settings/Toggles` -- the game's own subtab strip,
  ## which brings its `ToggleGroup` along in the clone. That matters: we cannot
  ## construct a `ToggleGroup` (AddComponent for it is not attested), so the
  ## exclusivity has to come from a cloned one. The buttons are then pointed at
  ## THAT group, never at the tab-bar group -- subtab exclusivity must not
  ## fight tab exclusivity.
  result = false
  # NO SILENT RETURN HERE. This used to be one bare `if ... return`, and on the
  # boot where the strip did not appear it was the only candidate that left
  # nothing in the log at all -- indistinguishable from the build never being
  # attempted.
  if gNtSubBuilt:
    return
  # THE PANEL-SWITCHING KIND HAS ITS OWN BUILDER NOW. `ntBuildGfxStrip` reuses
  # the clone's two toggles instead of cloning two more (§5 T12) and switches
  # through `ShowScreen` instead of `SetActive`. Routing the panel kind here
  # would silently rebuild the old shape, so it is refused rather than aliased.
  if kind == NtSubPanels:
    warn "native subtabs: ntBuildSubtabs was asked for the PANEL-SWITCHING " &
         "kind, which now belongs to ntBuildGfxStrip. Refusing -- building it " &
         "here would clone two extra ControlToggles into the strip (trap T12: " &
         "childCount 4 where it must be 2) and switch panels with SetActive " &
         "instead of ShowScreen, leaving _currentTab@0x118 disagreeing with " &
         "the pixels."
    return
  if not gNtSubOn:
    warn "native subtabs: NOT BUILDING -- nativeTabsSubtabs is OFF at the " &
         "moment ntBuildSubtabs was called. The flag chain " &
         "(settingsPostFxSubtab -> nativeTabsSubtabs -> nativeTabs) is what " &
         "should have set it; if settingsPostFxSubtab is on in the config and " &
         "this still prints, the chain ran after the build."
    return
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil:
    warn "native subtabs: NOT BUILDING -- the SettingsScreen GameObject could " &
         "not be reached from " & iPtr(screenT) & "."
    return
  ntCrumb("subtabs: locating the strip donor (and, for step 2, the stock panel)")
  # The stock Graphics panel is only needed by the PANEL-SWITCHING kind. For
  # the MODS kind there is no second panel: our own panel stays up and its rows
  # are swapped, so requiring Graphics here would refuse a build that does not
  # need it.
  if kind == NtSubPanels:
    gNtSubPanelA = iGameObjectOf(modsChildNamed(screenT, "Graphics Settings"))
    gNtSubPanelB = iGameObjectOf(modsChildNamed(screenT, "PostFX Settings"))
    gNtGfxPanelGo = gNtSubPanelA
    # THE STOCK GRAPHICS TOGGLE. The strip is ITS furniture: visible iff this
    # is on. Without this the strip had nothing to belong to, so it flashed at
    # build time under GAME and was never raised again.
    let tg = modsChildNamed(screenT, "Toggles")
    let gfxSpawnT = (if tg != nil:
                       modsChildNamed(tg, "GraphicsToggleSpawner") else: nil)
    gNtGfxTabToggle = (if gfxSpawnT != nil: modsToggleOf(gfxSpawnT) else: nil)
    if gNtGfxTabToggle == nil:
      warn "native subtabs: the STOCK GraphicsToggle could not be found, so " &
           "the strip cannot be tied to the GRAPHICS tab and would flash " &
           "under whatever tab happens to be up. REFUSING to build it."
      return
  let ctrlPanel = modsChildNamed(screenT, "Control Settings")
  let donorStrip = (if ctrlPanel != nil: modsChildNamed(ctrlPanel, "Toggles")
                    else: nil)
  let donorBtn = (if donorStrip != nil:
                    modsChildNamed(donorStrip, "ControlToggle") else: nil)
  if (kind == NtSubPanels and (gNtSubPanelA == nil or gNtSubPanelB == nil)) or
     donorStrip == nil or donorBtn == nil:
    ntNoteFault("subtabs: the stock Graphics panel or the strip donor was " &
                "not found (" &
                (if kind == NtSubPanels and gNtSubPanelA == nil:
                   "Graphics-Settings " else: "") &
                (if kind == NtSubPanels and gNtSubPanelB == nil:
                   "PostFX-Settings " else: "") &
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
  gNtSubSpawner = @[]
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
    # THE REGISTERING JOIN, not `set_group`. MEASURED (map §7.10): the setter
    # writes `m_Group@0x110` alone, so the group's `m_Toggles@0x28` never
    # learns about us -- and `NotifyToggleOn` calls `ValidateToggleIsInGroup`,
    # which THROWS a managed exception on the first press (§5 T3). That throw
    # unwinds through our frame without tripping `aowl_p_p_seh`.
    ntCallBegin("UnityEngine.UI.Toggle::SetToggleGroup (subtab)")
    discard nuToggleJoinGroup(tog, subGroup)
    ntCallEnd()
    discard modsSetActive(btn, true)
    gNtSubSpawner.add modsComponent(btnT, "UIAnimatedToggleSpawner")
    gNtSubToggle.add tog
    made = made + 1
    b = b + 1
  if made != captions.len:
    ntNoteFault("subtabs: only " & $made & " of " & $captions.len & " buttons " &
                "came out usable; hiding the strip rather than shipping a " &
                "half-built one with no way back.")
    discard modsSetActive(stripGo, false)
    gNtSubToggle = @[]
    gNtSubSpawner = @[]
    return
  # THE CLONE INHERITED THE DONOR'S CANVASGROUP STATE, and the donor
  # (`Control Settings/Toggles`) was HIDDEN when we cloned it. A CanvasGroup
  # carrying alpha 0 / interactable false / blocksRaycasts false makes every
  # Selectable under it inert -- which is EXACTLY the reported defect: POSTFX
  # visible but unclickable, while our own `Toggle::Set` call still worked.
  # Read it, say what it was, and only then make it usable.
  # ALWAYS SAY WHAT WAS FOUND. The previous version only logged when a
  # CanvasGroup existed AND read back cleanly, so "no CanvasGroup" and "could
  # not read it" were both silent -- and silence is what this whole pass has
  # been spent turning into sentences.
  let stripCg = modsComponent(stripT, "CanvasGroup")
  if stripCg == nil:
    okLog "native subtabs: the cloned strip carries NO CanvasGroup, so that " &
          "is not why a subtab would refuse a click. Nothing was forced."
  else:
    let (cgOk, cgA, cgI) = nuCgRead(stripCg)
    if cgOk:
      okLog "native subtabs: the cloned strip's CanvasGroup arrived alpha=" &
            nuF(cgA) & " interactable=" & $cgI & " (inherited from the donor " &
            "panel, which was HIDDEN when we cloned it). Forcing alpha 1 / " &
            "interactable / blocksRaycasts -- a CanvasGroup with alpha 0 or " &
            "blocksRaycasts false makes every Selectable under it inert while " &
            "our own Toggle::Set call still works, which is exactly the " &
            "'renders but will not click' shape."
    else:
      warn "native subtabs: the cloned strip HAS a CanvasGroup but it could " &
           "not be read, so whether it is the reason a subtab refuses a click " &
           "is UNKNOWN. Forcing it usable anyway."
    discard nuCgMakeUsable(stripCg)
  # UNDER THE PANELS, AND STILL CLICKABLE BECAUSE NOTHING OVERLAPS IT.
  # See ntStripOrder: LAST made the strip draw over every SettingsTooltip.
  discard ntStripOrder(stripT)
  gNtSubStripGo = stripGo
  gNtSubBuilt = true
  gNtSubN = made
  gNtSubKind = kind
  gNtSubSel = 0
  # HIDDEN UNTIL THE STOCK GRAPHICS TAB IS SELECTED. Building it active is
  # what the user saw as "subtabs flash then get deleted under GAME".
  discard modsSetActive(stripGo, false)
  ntCrumb("subtabs: COMPLETE")
  var capList = ""
  var ci = 0
  while ci < captions.len and ci < NtMaxSubs:
    capList = capList & (if ci > 0: " | " else: "") & captions[ci]
    ci = ci + 1
  okLog "native subtabs: built the " & capList & " strip as a " &
        "SIBLING of the panels it switches, not inside either one. That is " &
        "the whole difference from the five earlier attempts: the strip is " &
        "in no stock LayoutGroup, so no stock geometry can be re-arranged by " &
        "its presence, and it does not have to exist twice to survive a " &
        "switch. Exclusivity comes from the CLONED ToggleGroup, not from us."
  result = true

proc ntRetireChildrenOf(rt: Il2CppPtr): int =
  ## Take the donor's rows OUT OF THE WAY -- by switching them off, NEVER by
  ## destroying them.
  ##
  ## THIS REPLACES `Object::Destroy`, AND IT REPLACES IT BECAUSE THE CLIENT
  ## DIED. The first boot that emptied TWO panel clones (80 rows destroyed)
  ## crashed during the next raid LOAD, top frame
  ## `il2cpp_unity_liveness_calculation_from_root` -- the managed liveness walk
  ## at the scene transition. The boot before it emptied ONE clone (40 rows)
  ## and loaded a raid fine.
  ##
  ## The mechanism that fits: a destroyed row is still REFERENCED from a stock
  ## managed list -- the tab's `_createdControls`, the screen's tab list, a
  ## ToggleGroup's toggle list -- and the liveness walk dereferences the dead
  ## native object behind a live managed shell (fact #182 is the same hazard
  ## seen from the other side). We cannot audit those lists: they are
  ## `List<T>`, an instantiated generic whose layout is NOT reachable offline,
  ## and reading one with a guessed offset to prove safety would be its own
  ## defect.
  ##
  ## So the object stays ALIVE and merely stops rendering. An inactive child is
  ## excluded from layout and from draw, which is everything we actually
  ## needed; it was never necessary for it to cease to exist. This is strictly
  ## less invasive than what it replaces and it removes the whole class.
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
    if modsGoActive(go) and modsSetActive(go, false):
      result = result + 1

proc ntActiveChildCount(rt: Il2CppPtr): int =
  ## How many children of `rt` are ACTIVE. The verdict counts these rather
  ## than all children, because the donor's rows are now retired-in-place
  ## instead of destroyed, so the container legitimately still holds them.
  result = 0
  if not nuOk(rt, 0x10'i32): return
  var kids = 0
  if not iChildCount(rt, kids): return
  var k = 0
  while k < kids and k < NtMaxRowDestroy:
    let c = iChildAt(rt, k)
    k = k + 1
    if c == nil or not duOk(c, 0x20'i32): continue
    let go = iGameObjectOf(c)
    if go != nil and modsGoActive(go): result = result + 1
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
  let cleared = ntRetireChildrenOf(gNtModsRowRoot)
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

proc ntSubGroupOf(sel: int): int32 =
  ## Which `ESettingsGroup` a subtab names. MEASURED `R fields ESettingsGroup`:
  ## the tab the UI calls GRAPHICS is `Screen == 0`, and PostFX is 4. There is
  ## no "Graphics" member and there is no sixth value to invent (§5 T1).
  (if sel == 1: NtGroupPostFx else: NtGroupScreen)

proc ntSubHighlight(sel: int) =
  ## Move the strip's highlight WITHOUT sending a callback.
  ##
  ## `UIAnimatedToggleSpawner::ToggleSilently` @0x16BCBA0, MEASURED
  ## `R disasm`: `get_SpawnedObject()` -> `Toggle::Set(tog, value, 0)` ->
  ## `TriggerAnimation` iff `m_Transition@0x50 == 3`. It is
  ## `AnimatedToggle::set_IsToggled` @0x16AD190 with the callback flag flipped,
  ## and set_IsToggled's `mov r8b,1` is the MEASURED cause of the phantom
  ## "subtab pressed by the player: POSTFX" that followed every GRAPHICS press
  ## by 0.4-1.0s in the deployed build.
  ##
  ## READ `m_IsOn@0x120` FIRST (§5 T2): `Toggle::Set` returns immediately when
  ## the value already matches, which looks exactly like success. The read is
  ## what makes "we changed it" and "it was already that" distinguishable, and
  ## it also keeps this from calling into the game at all in the common case.
  ##
  ## ToggleSilently THROWS when the spawner has no spawned object (`call
  ## 0x5D2530`), and a managed throw is invisible to `aowl_p_p_seh` (§5 T9).
  ## The precondition is checked FRESH, every time: `ntSubToggleNow` reads
  ## `_spawnedObject@0xa0` and returns nil if it is null or Unity-dead, which
  ## is the same test the getter itself makes. A build-time pointer was not a
  ## precondition at all -- it was an orphan (T13).
  ##
  ## Note the division of labour: the READ goes through the raw field, because
  ## it must not be able to spawn; the WRITE goes through `ToggleSilently` on
  ## the SPAWNER, which re-resolves through `get_SpawnedObject` internally and
  ## so is correct even in the frame where a respawn happens.
  var i = 0
  while i < ntSubCount():
    let want = (i == sel)
    let tog = ntSubToggleNow(i)
    if tog != nil:
      let (ok, isOn) = nuToggleIsOn(tog)
      if ok and isOn != want:
        discard nuSpawnerToggleSilently(gNtSubSpawner[i], want)
    i = i + 1
  gNtSubSel = sel

proc ntTabBarSync(group: int32) =
  ## Keep the STOCK top row honest while the PostFX panel is up.
  ##
  ## `ShowScreen` does not touch toggles (§2.4/§6.1), which is what lets the
  ## GRAPHICS tab stay lit while we show PostFX -- requirement A.3. But
  ## `ScreenController[+0x60]` now remembers 4, so the NEXT time the screen
  ## opens, `OpenGroup(4)` presses `_tabs[4].Toggle` -- the stock POSTFX
  ## spawner, which the modstab fold has HIDDEN. The tab-bar group would then
  ## hold a hidden toggle on and GRAPHICS off, and the top row would light
  ## nothing at all.
  ##
  ## So on every PostFX switch the top row is corrected SILENTLY: GRAPHICS on,
  ## the hidden POSTFX off. Both edges are sendCallback=false, so neither can
  ## re-enter `ShowScreen` and neither is a press. The result is exactly one
  ## toggle on in the tab group (P3), and it is the one the player can see.
  if group != NtGroupPostFx:
    return
  # BOTH READS ARE FRESH (T13). The STOCK spawners replace their toggles
  # too -- they are the same class of object as ours -- so a cached stock
  # pointer is exactly as much of an orphan as a cached one of ours.
  let pfxTog = ntSpawnerToggleNow(gNtPostFxTabSpawner)
  if pfxTog != nil:
    let (okP, onP) = nuToggleIsOn(pfxTog)
    if okP and onP:
      discard nuSpawnerToggleSilently(gNtPostFxTabSpawner, false)
  let gfxTog = ntSpawnerToggleNow(gNtGfxTabSpawner)
  if gfxTog != nil:
    let (okG, onG) = nuToggleIsOn(gfxTog)
    if okG and not onG:
      discard nuSpawnerToggleSilently(gNtGfxTabSpawner, true)

proc ntSubApply(sel: int) =
  ## A subtab press, applied the way the game applies a tab press: ONE call.
  ##
  ## `SettingsScreen::ShowScreen(screen, group, NULL)` @0x1720DE0 (UNIQUE,
  ## prologue byte-verified through `nuFn` against the STARTUP SNAPSHOT).
  ## MEASURED §2.4: OLD-OFF via `_currentTab.set_IsSelected(false)` ->
  ## `EnsureTabInitialized(group)` -> `_currentTab = _tabs[group].Tab` ->
  ## NEW-ON. We `SetActive` NOTHING. That is the entire change: the old path
  ## drove two stock panels by hand and `_currentTab` disagreed with the
  ## pixels, which is P2's failing input.
  if not gNtSubBuilt or gNtSubKind != NtSubPanels:
    return
  if gNtScreen == nil:
    warn "native subtabs: a subtab was pressed but the live SettingsScreen " &
         "pointer is nil, so ShowScreen cannot be called and NOTHING was " &
         "done. The pointer is learned by the ShowScreen postfix rider; if " &
         "this prints, that rider has not fired, which means settingsUiProbe " &
         "is off or its detour did not bind."
    return
  let g = ntSubGroupOf(sel)
  # The window in which an ON edge on one of our subtabs is not a press.
  gNtSettleFrames = NtSettleFrames
  ntCallBegin("EFT.UI.Settings.SettingsScreen::ShowScreen")
  let ok = nuShowScreen(gNtScreen, g)
  ntCallEnd()
  if not ok:
    ntNoteFault("subtabs: ShowScreen(group=" & $g & ") was REFUSED, so the " &
                "page did not change. Nothing was SetActive'd as a " &
                "consolation -- doing that by hand is what left _currentTab " &
                "naming a different panel than the one on screen.")
    return
  okLog "native subtabs: " & (if sel == 1: "POSTFX" else: "GENERAL") &
        " -> SettingsScreen::ShowScreen(group=" & $g & ", MethodInfo*=NULL). " &
        "The strip's visibility and highlight now come back through the " &
        "ShowScreen POSTFIX, the same path a stock tab click takes, so our " &
        "own switch and the player's are handled by one piece of code."

# =========================================================================
# THE BODY OFFSET -- give the subtab strip a band of its own.
#
# THE DEFECT, MEASURED on the live tree (inspector, 2026-09-03 11:45):
#
#   [15] "Toggles(Clone)"    -- our strip -- anchoredPosition (0,-128)
#                               sizeDelta (-1428.56, 46), i.e. it occupies
#                               128..174 px below the screen top.
#   [4]  "Graphics Settings" -- BOTTOM-anchored: anchorMin (0.5,0)
#                               anchorMax (0.5,1) pivot (0.5,0)
#                               anchoredPosition (0,60) sizeDelta (1000,-225)
#                               -> rect h=785, top edge 165 px below the top.
#   [5]  "PostFX Settings"   -- TOP-anchored: anchoredPosition (0,-165)
#                               sizeDelta (930,785).
#
# Both bodies therefore START 165 px down while the strip ENDS at 174. The
# overlap is 9 px and the visible symptom is the first row crowded under the
# strip. Nothing about this is a layout-group problem: it is two siblings
# authored against a screen with no strip in it.
#
# THE FIX, and why the two panels need DIFFERENT arithmetic. "Shrink from the
# top by N" is not one operation in Unity; it depends on where the rect is
# anchored, which is why a single formula applied to both would move one of
# them and resize the other:
#
#   Graphics is bottom-pivoted and vertically stretched, so its TOP edge is
#   `parentHeight + sizeDelta.y` measured from the bottom -- reducing
#   sizeDelta.y alone lowers the top edge and leaves the bottom where it is.
#   anchoredPosition MUST NOT change.
#
#   PostFX is top-anchored with a fixed height, so its top edge is
#   anchoredPosition.y and its bottom is that minus sizeDelta.y. BOTH must
#   move by the same amount: the position to push the top down, the height to
#   keep the bottom still.
#
# THE ORIGINALS ARE READ, NEVER HARDCODED. The numbers above are this
# machine's, at this user's 1.5x display scaling, on this window size; a
# constant transcribed from them would be wrong on the next resolution. The
# only constant here is the SHRINK, which is a fraction of nothing -- it is
# the strip's own measured height plus clearance.
const NtBodyShrink = 55.0'f32     ## px removed from the top of each body
const NtBodyStripBottom = 174.0'f32
  ## MEASURED: the strip's lower edge, px below the screen top (128 + 46).
  ## The verdict asserts each body's top edge is at least this far down.
const NtBodyMaxFaults = 4         ## rule 6

var gNtBodyInit = false
var gNtBodyOn = false             ## `settingsSubtabBodyOffset`, DEFAULT OFF
var gNtBodyOff = false            ## self-disabled
var gNtBodyFaults = 0
var gNtBodyHave = false           ## the originals have been captured
var gNtBodyGfx0 = nuNoGeom()      ## "Graphics Settings" as the game authored it
var gNtBodyPfx0 = nuNoGeom()      ## "PostFX Settings"   as the game authored it
var gNtBodyApplied = false        ## our offset is currently in effect
var gNtBodyJudge = 0              ## frames until the verdict may be read
var gNtBodyWant = false           ## what the pending verdict must find

proc ntBodyNoteFault(what: string) =
  inc gNtBodyFaults
  warn "subtab body offset: " & what & " (fault " & $gNtBodyFaults & " of " &
       $NtBodyMaxFaults & ")"
  if gNtBodyFaults >= NtBodyMaxFaults:
    gNtBodyOff = true
    warn "subtab body offset: fault ceiling reached; OFF for the rest of the " &
         "session. The last write stands, so the bodies keep whatever offset " &
         "was applied -- nothing is left half-written mid-panel."

proc ntBodyCapture(): bool =
  ## Read both bodies ONCE, before anything of ours has ever written to them.
  ## `gNtBodyHave` is the interlock that makes "capture the originals" and
  ## "capture our own shrunken values" distinguishable: an apply cannot run
  ## before a capture, and a capture cannot run twice.
  if gNtBodyHave: return true
  if gGfxPanelT == nil or gGfxPostT == nil: return false
  if not iUnityAlive(gGfxPanelT) or not iUnityAlive(gGfxPostT): return false
  let g = nuReadGeom(gGfxPanelT)
  let p = nuReadGeom(gGfxPostT)
  if not g.ok or not p.ok: return false
  gNtBodyGfx0 = g
  gNtBodyPfx0 = p
  gNtBodyHave = true
  okLog "subtab body offset: captured the AUTHORED geometry of both bodies " &
        "before writing anything. Graphics Settings " & nuGeomNote(g) &
        "; PostFX Settings " & nuGeomNote(p) & ". Every restore goes back to " &
        "exactly these numbers; none of them is hardcoded."
  true

proc ntBodySet(rt: Il2CppPtr; g0: NuGeom; dPos, dSd: float32): bool =
  ## Read-validate-write, always ABSOLUTE and always relative to the captured
  ## original -- never `current + delta`, which accumulates if it is ever
  ## called twice and is the shape that walks a panel off the screen.
  result = false
  if not g0.ok: return
  if not nuOk(rt, 0x10'i32) or not iUnityAlive(rt): return
  if not nuSetV2(rt, NuTRtSetSizeDelta, g0.sdX, g0.sdY + dSd): return
  if not nuSetV2(rt, NuTRtSetAnchoredPos, g0.posX, g0.posY + dPos): return
  result = true

proc ntBodyApply(up: bool) =
  ## Called from the ShowScreen rider, on the EDGE only. `up` is "our strip is
  ## on screen", which is exactly the condition under which the bodies must
  ## make room for it.
  if not gNtBodyInit:
    gNtBodyInit = true
    gNtBodyOn = readBoolKeyDef("settingsSubtabBodyOffset", false)
  if not gNtBodyOn or gNtBodyOff: return
  if not gNtSubBuilt or gNtSubKind != NtSubPanels: return
  if not ntBodyCapture():
    ntBodyNoteFault("neither body's geometry could be read, so there is no " &
                    "original to restore to and NOTHING was written. This is " &
                    "'asked before the panels exist', not a wrong pointer.")
    return
  if up == gNtBodyApplied: return
  let d = (if up: -NtBodyShrink else: 0.0'f32)
  let okG = ntBodySet(gGfxPanelT, gNtBodyGfx0, 0.0'f32, d)
  let okP = ntBodySet(gGfxPostT, gNtBodyPfx0, d, d)
  if not (okG and okP):
    ntBodyNoteFault("the write was refused on " &
                    (if not okG: "Graphics Settings" else: "PostFX Settings") &
                    ". Both bodies are being put back to their captured " &
                    "originals so the screen cannot be left half-offset.")
    discard ntBodySet(gGfxPanelT, gNtBodyGfx0, 0.0'f32, 0.0'f32)
    discard ntBodySet(gGfxPostT, gNtBodyPfx0, 0.0'f32, 0.0'f32)
    gNtBodyApplied = false
    return
  gNtBodyApplied = up
  gNtBodyWant = up
  gNtBodyJudge = NtVerdictDelay

proc ntBodyVerdict() =
  ## THE FINISHED STATE, read off the live tree one frame after the write --
  ## never the value we passed in.
  ##
  ## RAISED asserts a NEGATIVE that can actually fail: no body's top edge is
  ## still inside the strip's band. HIDDEN asserts equality with the captured
  ## original, which is the only reading that distinguishes "restored" from
  ## "never written".
  let screenT = modsParentOf(gGfxPanelT)
  if screenT == nil:
    warn "subtab body offset VERDICT INCONCLUSIVE: the SettingsScreen " &
         "transform (the bodies' own parent, walked from 'Graphics Settings') " &
         "could not be reached, so a screen-relative edge cannot be computed. " &
         "'I could not look' is not a pass."
    return
  let sg = nuReadGeom(screenT)
  let gg = nuReadGeom(gGfxPanelT)
  let pg = nuReadGeom(gGfxPostT)
  if not sg.ok or not gg.ok or not pg.ok:
    var which = "PostFX Settings"
    if not sg.ok: which = "the screen"
    elif not gg.ok: which = "Graphics Settings"
    warn "subtab body offset VERDICT INCONCLUSIVE: " & which &
         " did not read back a valid rect, so no edge can be judged."
    return
  if not gNtBodyWant:
    let dG = (gg.sdY - gNtBodyGfx0.sdY)
    let dP = (pg.posY - gNtBodyPfx0.posY)
    let dP2 = (pg.sdY - gNtBodyPfx0.sdY)
    if dG > -0.5'f32 and dG < 0.5'f32 and dP > -0.5'f32 and dP < 0.5'f32 and
       dP2 > -0.5'f32 and dP2 < 0.5'f32:
      okLog "subtab body offset VERDICT PASS (hidden): both bodies read back " &
            "EQUAL to the geometry captured before we ever wrote -- Graphics " &
            "sizeDelta.y " & nuF(gg.sdY) & ", PostFX anchoredPosition.y " &
            nuF(pg.posY) & " / sizeDelta.y " & nuF(pg.sdY) & ". The strip is " &
            "down and the screen is exactly as the game authored it."
    else:
      warn "subtab body offset VERDICT FAIL (hidden): the restore did not " &
           "take. Graphics sizeDelta.y is " & nuF(gg.sdY) & " against a " &
           "captured " & nuF(gNtBodyGfx0.sdY) & "; PostFX is " &
           nuF(pg.posY) & "/" & nuF(pg.sdY) & " against " &
           nuF(gNtBodyPfx0.posY) & "/" & nuF(gNtBodyPfx0.sdY) & ". A body " &
           "left short with no strip above it is a visible defect."
    return
  let (okG, topG, leftG) = nuChildEdgeInParent(sg, gg)
  let (okP, topP, leftP) = nuChildEdgeInParent(sg, pg)
  discard leftG
  discard leftP
  if not okG or not okP:
    let which = (if not okG: "Graphics Settings" else: "PostFX Settings")
    warn "subtab body offset VERDICT INCONCLUSIVE: the child-edge arithmetic " &
         "refused for " & which & " (a NaN or an absurd magnitude), so no " &
         "screen-relative top edge exists to judge."
    return
  let screenTop = sg.rectY + sg.rectH
  let belowG = screenTop - topG
  let belowP = screenTop - topP
  if belowG >= NtBodyStripBottom and belowP >= NtBodyStripBottom:
    okLog "subtab body offset VERDICT PASS (raised): NO body's top edge is " &
          "still inside the strip's band. Graphics Settings starts " &
          nuF(belowG) & " px below the screen top and PostFX Settings " &
          nuF(belowP) & " px, both at or past the strip's measured lower " &
          "edge of " & nuF(NtBodyStripBottom) & " px. Read from get_rect on " &
          "the live RectTransforms and the live screen, one frame after the " &
          "write."
  else:
    warn "subtab body offset VERDICT FAIL (raised): a body still overlaps " &
         "the strip. Graphics Settings top edge " & nuF(belowG) &
         " px below the screen top, PostFX Settings " & nuF(belowP) &
         " px; the strip ends at " & nuF(NtBodyStripBottom) & " px. The " &
         "first row of the offending page is drawn under the strip."

proc ntOnShowScreen(screen: Il2CppPtr; group: int32) =
  ## THE ONE PLACE STRIP VISIBILITY AND HIGHLIGHT ARE DECIDED.
  ##
  ## Called from `settingsui.nim`'s ShowScreen-POSTFIX body -- the detour
  ## `settingsUiProbe` already installs -- so this installs NOTHING of its own.
  ## §7.9/the double-detour rule: a second physical detour on ShowScreen would
  ## overwrite the first's trampoline and silently kill Phase 1/2/3. It runs
  ## INSIDE that body's single `aowl_p_p_seh` and must not open another; the
  ## guard is not re-entrant and a nested one DISARMS the outer.
  ##
  ## A POSTFIX and not a prefix, deliberately: after ShowScreen returns,
  ## `_currentTab@0x118` and the panel `SetActive`s have already happened, so
  ## everything read or set here is read against the finished state rather
  ## than the one being left.
  ##
  ## It fires for EVERY route into a group -- the player's tab click, our own
  ## `ntSubApply`, and `OpenGroup` when the screen first opens on GRAPHICS --
  ## which is why the strip raises itself on open with no extra code.
  if not gNtOn or gNtOff:
    return
  if screen != nil:
    gNtScreen = screen
  gNtLastGroup = group
  if not gNtSubBuilt or gNtSubKind != NtSubPanels:
    return
  let wanted = (group == NtGroupScreen or group == NtGroupPostFx)
  gNtGfxTabOn = wanted
  if gNtSubStripGo != nil:
    discard modsSetActive(gNtSubStripGo, wanted)
  if wanted:
    ntSubHighlight(if group == NtGroupPostFx: 1 else: 0)
    ntTabBarSync(group)
  # THE BODIES MAKE ROOM FOR THE STRIP, and they do it here for the same
  # reason the strip is raised here: this rider is the ONE place that fires
  # for every route into a group -- the player's click, our own ntSubApply,
  # and OpenGroup on first open. Doing it at the click site would miss two of
  # the three. It runs inside the ShowScreen postfix's single `aowl_p_p_seh`
  # and opens no guard of its own (the guard is not re-entrant).
  ntBodyApply(wanted)
  # JUDGE ONE FRAME LATER, NEVER THIS ONE. A LayoutGroup rebuild is deferred
  # to `willRenderCanvases` and `Object.Destroy` to end of frame, so a
  # same-frame read is INCONCLUSIVE (§6.5 predicate 9).
  # ...AND ONLY WHEN GRAPHICS IS THE TAB COMING UP. MEASURED 2026-09-06
  # (inspector `open graphics` then `open game`, twice): the switch AWAY
  # scheduled a verdict too, which then judged the Graphics subtab panels
  # while the whole Graphics tab was hidden -- "P2b the strip says GENERAL
  # but the panel up is the other one (Graphics active=false, PostFX
  # active=false)" -- a FAIL about panels nobody could see, on every visit to
  # any other tab. The verdict's precondition is the tab being up.
  if wanted:
    gNtVerdictDue = NtVerdictDelay
    gNtSubVerdictSaid = false
    gNtWhyNext = "ShowScreen(group=" & $group & ")"
  else:
    gNtVerdictDue = 0

proc ntSubShow(sel: int) =
  ## The ROW-SWAPPING kind only (step 3's MODS subtabs). The panel-switching
  ## kind is `ntSubApply` and goes through `ShowScreen`; it is not reachable
  ## from here any more, and this refuses rather than falling through to code
  ## that would `SetActive` two stock panels by hand.
  if not gNtSubBuilt: return
  if gNtSubKind == NtSubPanels:
    ntSubApply(sel)
    return
  # OUR PANEL STAYS UP; only its rows change. Nothing stock is touched at all
  # here, which is why this kind needs no panel bookkeeping.
  #
  # THE HIGHLIGHT IS SILENT, exactly as on the panel kind. It used to go
  # through `AnimatedToggle::set_IsToggled`, which MEASURED
  # (`R disasm 0x16ad190`) calls `Toggle::Set` with `mov r8b,1` -- a real
  # press, re-entering our own drain. `gNtApplying` was the plaster over that;
  # it only covered the synchronous window, and the phantom edge arrived
  # 0.4-1.0s later, outside it. Not sending a callback at all removes the
  # class instead of narrowing the window.
  ntSubHighlight(sel)
  discard ntRenderModPage(sel)

proc ntPanelOfTab(tab: Il2CppPtr): Il2CppPtr =
  ## The GameObject a `SettingsTab` IS. MEASURED §2.5: `set_IsSelected` does
  ## `GameObject::SetActive(get_gameObject(this), value)` -- a "panel" is
  ## literally the tab component's own GameObject, nothing more.
  result = nil
  if tab == nil or not duOk(tab, 0x20'i32): return
  result = nuGameObjectOf(tab)

proc ntSubVerdict(why: string) =
  ## THE FINISHED-STATE VERDICT for the GRAPHICS strip: P1, P2, P3, P4, P6, P7
  ## from the contract at the head of this file, each read off the LIVE tree
  ## one frame after the change, and each with three outcomes.
  ##
  ## NOTHING HERE COMPARES ANYTHING WE WROTE AGAINST ITSELF. That is the whole
  ## point: the version this replaces asked "is the panel I SetActive'd
  ## active", which cannot fail, and it passed while the wrong page was on
  ## screen. Every predicate below is a property of the finished tree and
  ## every one names the input that makes it FAIL.
  if gNtSubVerdictSaid or not gNtSubBuilt: return
  if not gNtGfxTabOn:
    # THE PRECONDITION, stated instead of failed: the subtab panels live under
    # the Graphics tab and are hidden with it, so nothing here is observable.
    # Not marked as said -- the next time Graphics comes up, it is judged.
    if not gNtSubHiddenSaid:
      gNtSubHiddenSaid = true
      info "native subtabs: verdict (" & why & ") NOT JUDGED -- Graphics is " &
           "not the selected tab, so its subtab panels are hidden with it; " &
           "it is judged the next time Graphics comes up (said once)"
    return
  gNtSubVerdictSaid = true
  var fails = ""
  var incon = ""

  # ---- P4: exactly one subtab on, in OUR cloned group -------------------
  var on = 0
  var onIdx = -1
  var readable = 0
  var i = 0
  while i < ntSubCount():
    # THE READ THAT WAS WRONG, LIVE, AT 15:45. It used to ask a build-time
    # pointer for `m_IsOn` and got 0 from a destroyed object while a live,
    # unselected toggle sat on screen -- so the verdict reported `0 of 2`
    # accurately about an object nobody was looking at, which is worse than
    # reporting nothing. `ntSubToggleNow` re-resolves through the spawner
    # every time (T13).
    let tog = ntSubToggleNow(i)
    if tog != nil:
      let (ok, isOn) = nuToggleIsOn(tog)
      if ok:
        readable = readable + 1
        if isOn:
          on = on + 1
          onIdx = i
    i = i + 1
  let which = (if onIdx == 1: "POSTFX" elif onIdx == 0: "GENERAL"
               else: "none")
  if readable != ntSubCount():
    incon = incon & "[P4 only " & $readable & " of " & $ntSubCount() &
            " subtab toggles could be re-resolved through their spawners " &
            "(_spawnedObject@0xa0 read null or Unity-dead)] "
  elif on != 1:
    fails = fails & "[P4 " & $on & " of " & $ntSubCount() &
            " subtabs read m_IsOn=1; 0 means a press never reached m_IsOn " &
            "and 2 means nothing is enforcing exclusivity] "

  # ---- P1: exactly one `* Settings` panel active -------------------------
  var oursAct = false
  let (nAct, actNames) = ntActivePanelNames(oursAct)
  if nAct != 1:
    fails = fails & "[P1 " & $nAct & " panel(s) active: " & actNames &
            "; two is the GAME-over-GRAPHICS overlay and zero is a blank " &
            "page] "

  # ---- P2: `_currentTab@0x118` names the panel that is up ----------------
  let cur = nuCurrentTabOf(gNtScreen)
  let curGo = ntPanelOfTab(cur)
  var curName = "(unreadable)"
  if curGo != nil: curName = iObjName(curGo)
  if gNtScreen == nil or cur == nil:
    incon = incon & "[P2 _currentTab could not be read from the screen] "
  elif curGo == nil or not modsGoActive(curGo):
    fails = fails & "[P2 _currentTab names '" & curName & "' but that " &
            "GameObject is NOT active, so the game and the pixels disagree " &
            "-- the signature of a switch done with SetActive instead of " &
            "ShowScreen] "

  # ---- P2b: the panel that is up is the one the strip names --------------
  let wantB = (onIdx == 1)
  let upB = (gNtSubPanelB != nil and modsGoActive(gNtSubPanelB))
  let upA = (gNtSubPanelA != nil and modsGoActive(gNtSubPanelA))
  if gNtSubPanelA == nil or gNtSubPanelB == nil:
    incon = incon & "[P2b a stock panel handle is nil] "
  elif on == 1 and (upB != wantB or upA == wantB):
    fails = fails & "[P2b the strip says " & which & " but the panel up is " &
            "the other one (Graphics active=" & $upA & ", PostFX active=" &
            $upB & "); the switch ran and did not take] "

  # ---- P3: exactly one toggle on in the STOCK tab-bar group --------------
  var tabOnPtr: Il2CppPtr = nil
  var tabTotal = 0
  let tabOn = nuGroupTogglesOn(gNtTabGroup, tabOnPtr, tabTotal)
  if tabOn < 0:
    incon = incon & "[P3 the tab-bar ToggleGroup's m_Toggles could not be " &
            "walked] "
  elif tabOn != 1:
    fails = fails & "[P3 " & $tabOn & " of " & $tabTotal & " tab-bar toggles " &
            "read m_IsOn=1; with the PostFX panel up this is how the top row " &
            "ends up lighting nothing, because ShowScreen(4) leaves the " &
            "HIDDEN stock POSTFX toggle on and GRAPHICS off] "
  elif gNtLastGroup == NtGroupPostFx and
       tabOnPtr != ntSpawnerToggleNow(gNtGfxTabSpawner):
    fails = fails & "[P3 the PostFX page is up but the tab-bar toggle that " &
            "is on is not GRAPHICS, so the lit tab is one the modstab fold " &
            "has hidden] "

  # ---- P6: the strip holds exactly the subtabs we made -------------------
  var stripKids = 0
  let stripT = modsTransformOf(gNtSubStripGo)
  if stripT == nil or not iChildCount(stripT, stripKids):
    incon = incon & "[P6 the strip's childCount could not be read] "
  elif stripKids != ntSubCount():
    fails = fails & "[P6 the strip holds " & $stripKids & " child(ren) for " &
            $ntSubCount() & " subtab(s); trap T12 measured 4 where it must be " &
            "2, " &
            "and the two extras were the donor's own toggles, never " &
            "reparented and still naming whatever group they came with] "

  # ---- P7: no layout to fight, or explicitly opted out -------------------
  if gNtStripParentLayout == "not examined":
    incon = incon & "[P7 the strip's parent was never examined for a " &
            "LayoutGroup] "
  elif gNtStripParentLayout != "none" and not gNtStripIgnoreLayout:
    fails = fails & "[P7 the strip's parent carries a " &
            gNtStripParentLayout & " and the strip has no LayoutElement with " &
            "ignoreLayout, so the strip's presence re-arranges the game's " &
            "own children] "

  if fails.len > 0:
    warn "native subtabs VERDICT FAIL (" & why & "): " & fails &
         (if incon.len > 0: "ALSO INCONCLUSIVE: " & incon else: "") &
         " Strip says " & which & "; _currentTab names '" & curName & "'."
  elif incon.len > 0:
    warn "native subtabs VERDICT INCONCLUSIVE (" & why & "): " & incon &
         "-- 'I could not look' is not a pass. Everything that COULD be read " &
         "agreed: strip says " & which & ", _currentTab names '" & curName &
         "'."
  else:
    okLog "native subtabs VERDICT PASS (" & why & "): exactly one subtab " &
          "reads m_IsOn=1 (" & which & "); exactly one `* Settings` panel is " &
          "active and it is the one the strip names; _currentTab@0x118 names " &
          "'" & curName & "' and that GameObject IS the active one; exactly " &
          "one of " & $tabTotal & " tab-bar toggles is on" &
          (if gNtLastGroup == NtGroupPostFx: " and it is GRAPHICS, with the " &
             "PostFX page up -- ShowScreen does not touch toggles, so the " &
             "stock GRAPHICS tab stays lit exactly as required" else: "") &
          "; the strip holds " & $stripKids & " child(ren) for " & $ntSubCount() &
          " subtab(s); parent LayoutGroup = " & gNtStripParentLayout &
          ". Every one of these was read back off the live tree " &
          $NtVerdictDelay & " frame(s) after the change, not from what we " &
          "wrote."

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
  # FOLD THE STOCK PANEL WITH THE GAME'S OWN CALL, not only with SetActive.
  #
  # §6.3: `ESettingsGroup` cannot be extended (§5 T1), so a MODS tab is ours
  # end to end and `ShowScreen` will never hear about it. But `_currentTab`
  # still names a stock tab, and leaving that tab thinking it is selected
  # while its GameObject is off is precisely P2's failing input. So the stock
  # tab is told: `SettingsTab::set_IsSelected(false)` @0x171BCA0 (UNIQUE),
  # MEASURED §2.5 to be `SetActive(gameObject, false)` and nothing else on the
  # false edge -- no OnSelect, no first-select gate, no allocation.
  #
  # The sweep above stays as a backstop: `_currentTab` names ONE tab, and the
  # screen can have more than one panel active if something else left it that
  # way. Two mechanisms for the same end is not duplication here, it is the
  # difference between "the game agrees" and "the pixels are right".
  let cur = nuCurrentTabOf(gNtScreen)
  if cur != nil:
    ntCallBegin("EFT.UI.Settings.SettingsTab::set_IsSelected(false)")
    discard nuTabSetSelected(cur, false)
    ntCallEnd()
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

proc ntHideOursOnly() =
  ## OURS OFF, AND NOTHING PUT BACK. Used when the GAME is already raising a
  ## stock panel of its own (the stock GRAPHICS tab going ON): `ntHide`'s
  ## restore would put back whichever stock panel was up when we took the
  ## screen, which -- with Graphics now coming up -- is the two-stock-panels
  ## picture, the same defect in the other direction. The remembered flags are
  ## cleared as well, so a LATER `ntHide` cannot resurrect a panel the game has
  ## since moved on from.
  if gNtShown >= 0 and gNtShown < gNtPanelGo.len:
    discard modsSetActive(gNtPanelGo[gNtShown], false)
  if gNtSubStripGo != nil: discard modsSetActive(gNtSubStripGo, false)
  gNtShown = -1
  var i = 0
  while i < gNtStockWasOn.len and i < 24:
    gNtStockWasOn[i] = false
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
    # SAY WHETHER THAT WAS THE POINT. During the proof we have just pressed one
    # of ours, so "a stock tab is selected" is a FAILURE of the press dressed
    # as a pass. Outside the proof it is the correct resting state.
    if gNtProofPhase == 2:
      warn "native tabs VERDICT FAIL (" & why & "): we pressed our tab '" &
           (if gNtId.len > 0: gNtId[0] else: "?") & "' and yet a STOCK panel " &
           "is the one active -- " & names & " -- with our selection reading " &
           $gNtShown & ". The press did not take: either the postfix never " &
           "saw it, or the stock ToggleGroup cleared ours again."
    else:
      okLog "native tabs VERDICT PASS (" & why & "): a stock tab is selected " &
            "and exactly one STOCK panel is active -- " & names & ". Ours is " &
            "off, which is the correct resting state when the player has not " &
            "chosen one of our " & $gNtPanelGo.len & " tab(s)."
  elif active == 0:
    warn "native tabs VERDICT FAIL (" & why & "): NO panel under " &
         "SettingsScreen is active, so the screen is blank. Our selection " &
         "says " & $gNtShown & "."
  else:
    warn "native tabs VERDICT FAIL (" & why & "): " & $active & " panels " &
         "are active at once under SettingsScreen -- " & names &
         " (ours active=" & $oursActive & ", selection=" & $gNtShown &
         "). Exactly one is the only correct answer."
proc ntInventory(when0: string) =
  ## ONE LINE naming every object we created and where it is parented.
  ##
  ## Logged at build and at teardown so the next crash report can be matched
  ## against what we actually put in the scene. The crash that prompted this
  ## (`il2cpp_unity_liveness_calculation_from_root`, during the raid load,
  ## only on boots where Settings was opened) could not be attributed because
  ## nothing recorded WHAT we had left behind or WHERE.
  var s2 = "native tabs INVENTORY (" & when0 & "): "
  s2 = s2 & $gNtPanelGo.len & " tab panel(s)"
  var i = 0
  while i < gNtPanelGo.len and i < NtMaxTabs:
    s2 = s2 & " [" & (if i < gNtId.len: gNtId[i] else: "?") & " panel=" &
         iPtr(gNtPanelGo[i]) & " toggle=" &
         (if i < gNtToggle.len: iPtr(gNtToggle[i]) else: "nil") & "]"
    i = i + 1
  s2 = s2 & "; " & $gNtToggle.len & " tab toggle(s) in the STOCK tab-bar " &
       "ToggleGroup; " & $ntSubCount() & " subtab spawner(s) in a CLONED " &
       "group; strip=" & iPtr(gNtSubStripGo) & "; controls-MODS toggle=" &
       iPtr(gNtKbToggle) & " panel=" & iPtr(gNtKbPanelGo) & "; " &
       "donor rows are RETIRED (SetActive false), never destroyed."
  okLog s2

proc ntDetachFromStockGroups(): int =
  ## Take every toggle of ours OUT of the game's ToggleGroups.
  ##
  ## THE CRASH HYPOTHESIS THIS ADDRESSES. The client died in the raid LOAD,
  ## in `il2cpp_unity_liveness_calculation_from_root`, on every boot where
  ## Settings had been opened and on none where it had not. A `ToggleGroup`
  ## holds a managed list of its member Toggles; ours joined the STOCK group
  ## (that is what makes tab exclusivity native) and then went away with the
  ## SettingsScreen. A member that is destroyed while still listed is exactly
  ## the kind of dangling reference a liveness walk trips over.
  ##
  ## THE VERSION THIS REPLACES DID NOT ACTUALLY LEAVE THE GROUP, and that is
  ## the whole point of this change. It called `nuToggleSetGroup`, i.e.
  ## `Toggle::set_group` @0x55B9D30 -- and MEASURED (map §7.10, and
  ## `SpawnObject` @0x16BC7F0 makes the OTHER call for exactly this reason)
  ## that setter writes `m_Group@0x110` and NOTHING ELSE. It does not
  ## unregister. So every "detached N toggle(s)" line this feature ever
  ## printed was true about a field and false about the list: our toggles
  ## stayed in the stock group's `m_Toggles@0x28` with `m_Group` nulled, which
  ## is a strictly WORSE dangling shape than before the call.
  ##
  ## `Toggle::SetToggleGroup(null, false)` @0x55BA150 is the real thing:
  ## MEASURED `R disasm 0x55ba150` -- `UnregisterToggle` from the old group
  ## @0x55BADD0, store `m_Group`, `RegisterToggle` into the new (skipped for
  ## null). That is how the game itself leaves a group.
  ##
  ## docs/WRITE-AUDIT-2026-09-02.md establishes that none of the host's 12
  ## store sites writes -1 at any width, so the 0x00000000FFFFFFFF reference
  ## the raid-load liveness walk met was written by GAME code operating on a
  ## state we left inconsistent. A stock `List<Toggle>` still naming a toggle
  ## whose GameObject went away with the SettingsScreen is exactly such a
  ## state, and this is the call that prevents it.
  ## AND IT MUST UNREGISTER THE CURRENT TOGGLE, NOT THE ONE WE REMEMBER.
  ## Under T13 a cached pointer names an object that is already destroyed, so
  ## unregistering THAT achieves nothing while the live toggle stays in the
  ## stock group -- which is the dangling shape this proc exists to prevent.
  ## Resolving through the spawner is the difference between a detach that
  ## works and a log line that says it did.
  result = 0
  var i = 0
  while i < gNtSpawnerComp.len and i < NtMaxTabs:
    let t = ntTabToggleNow(i)
    if t != nil and nuToggleJoinGroup(t, nil): result = result + 1
    i = i + 1
  var j = 0
  while j < ntSubCount():
    let t2 = ntSubToggleNow(j)
    if t2 != nil and nuToggleJoinGroup(t2, nil): result = result + 1
    j = j + 1
  let kt = ntSpawnerToggleNow(gNtKbSpawner)
  if kt != nil and nuToggleJoinGroup(kt, nil): result = result + 1

proc ntSettingsCloseEntered(regs: Il2CppPtr) =
  ## PREFIX on `SettingsScreen::Close()` @0x1720B10 (UNIQUE), dispatched by
  ## slot identity from `patchFired`. It NEVER suppresses the original.
  ##
  ## WHY HERE AND NOWHERE ELSE. MEASURED `R disasm 0x1720b10`: this method
  ## calls `CloseAll()` @0x17207A0 at +0x2F, which (§2.8) walks each
  ## initialized tab's `Close()` -> `CleanupCreatedControls` ->
  ## `Object::Destroy` on every entry of `_createdControls@0x88`, then clears
  ## `_initializedTabs` and nulls `_currentTab@0x118`. This prefix is the LAST
  ## instant at which every object of ours AND every stock list that might
  ## name one are both still alive. Doing the unregister on the next tick is
  ## too late by a whole cleanup.
  ##
  ## THE THREE DEATHS THIS IS AIMED AT (2026-09-02 12:11, 12:42, 14:52) each
  ## followed closing the settings screen with objects of ours in it, and at
  ## 14:51 the inspector's BackButton press faulted inside `UnityEvent::Invoke`
  ## with NO managed exception in the client's own log. Pairing this with the
  ## `CloseAll` POSTFIX makes "entered, never returned" a LOG LINE instead of a
  ## silence.
  ##
  ## WHAT OF OURS THE CLEANUP CAN AND CANNOT SEE, stated so the next reader
  ## does not have to re-derive it:
  ##   * Rows we instantiate into a stock tab's row container are NOT in that
  ##     tab's `_createdControls`, because we never add them. So
  ##     `CleanupCreatedControls` will not Destroy them -- which is the SAFE
  ##     side of that choice, and the cost is that they persist until the
  ##     SettingsScreen itself goes away. We do not add them, precisely
  ##     because we cannot audit `List<SettingControl>` (an instantiated
  ##     generic with no offline layout) to know the cleanup could dispose them.
  ##   * Our strip's toggles live in a CLONED ToggleGroup, so no stock list
  ##     names them. The MODS tab toggle and the CONTROLS>MODS toggle DO join
  ##     stock groups, and those are what the unregister below is for.
  ##   * We Destroy nothing at close. `ntRetireChildrenOf` switches objects
  ##     off; it never destroys. Nothing of ours can be dead behind a live
  ##     managed shell.
  discard regs
  if not gNtOn or gNtOff:
    return
  gNtCloseEnters = gNtCloseEnters + 1
  gNtCloseInFlight = true
  gNtStep = "close: SettingsScreen::Close entered"
  let detached = ntDetachFromStockGroups()
  okLog "settings CLOSE ENTERED (#" & $gNtCloseEnters & "): unregistered " &
        $detached & " toggle(s) of ours from the game's ToggleGroups with " &
        "Toggle::SetToggleGroup(null) @0x55BA150 -- the REGISTERING call, " &
        "which really does UnregisterToggle. The previous build used " &
        "set_group @0x55B9D30, which writes m_Group and leaves us in " &
        "m_Toggles. If the matching 'settings CLOSE: CloseAll RETURNED' line " &
        "does not appear, a throw or fault unwound through the close."

proc ntSettingsCloseAllReturned() =
  ## POSTFIX on `SettingsScreen::CloseAll()` @0x17207A0 (UNIQUE), a DIFFERENT
  ## function from the prefix above -- two detours on ONE function is what
  ## kills the first one silently; two on two is fine. Reads no register and
  ## touches no game memory, so it needs no guard, and it returns 0 always.
  if not gNtOn or gNtOff:
    return
  gNtCloseAllReturns = gNtCloseAllReturns + 1
  gNtCloseInFlight = false
  okLog "settings CLOSE: CloseAll RETURNED (#" & $gNtCloseAllReturns &
        " for " & $gNtCloseEnters & " Close entries). The cleanup walked " &
        "every initialized tab's _createdControls and came back, so nothing " &
        "threw through it this time."

proc ntCloseVerdict() =
  ## P8, judged from the tick on the frame AFTER a close was seen.
  ##
  ## FAIL looks like: `settings CLOSE ENTERED` with no matching
  ## `CloseAll RETURNED`. That is a throw or a fault unwound through the close
  ## -- the exact shape of 2026-09-02's three deaths, which produced no
  ## managed exception in the client log and nothing at all in ours.
  if not gNtCloseInFlight:
    return
  if gNtCloseUnreturnedSaid:
    return
  gNtCloseUnreturnedSaid = true
  warn "settings CLOSE VERDICT FAIL: SettingsScreen::Close was ENTERED (" &
       $gNtCloseEnters & " time(s)) and CloseAll has RETURNED only " &
       $gNtCloseAllReturns & " time(s), yet a later frame is running. A call " &
       "that neither reaches its own return nor trips aowl_p_p_seh, while " &
       "the game survives, is a MANAGED exception thrown inside the callee " &
       "and unwound through our frame (IL2CPP C++ EH) -- our " &
       "access-violation guard cannot see it. Treat the settings screen as " &
       "having been left half-closed: _initializedTabs may still hold " &
       "groups whose tabs were already cleaned up."

proc ntTeardown(why: string) =
  ## The SettingsScreen is going away. Leave nothing of ours registered in
  ## anything of the game's, and forget every pointer.
  if not (gNtBuilt or gNtSubBuilt or gNtKbBuilt): return
  ntInventory("teardown: " & why)
  let detached = ntDetachFromStockGroups()
  okLog "native tabs TEARDOWN (" & why & "): detached " & $detached &
        " toggle(s) from the game's ToggleGroups via set_group(null), and " &
        "dropped every cached pointer. Nothing of ours is left registered in " &
        "a stock collection across the scene transition -- which is the " &
        "shape the raid-load liveness crash had. Our objects are not " &
        "destroyed here: they belong to the SettingsScreen and go with it."
  gNtToggle = @[]
  gNtPanelGo = @[]
  gNtTabComp = @[]
  gNtRowRoot = @[]
  gNtId = @[]
  gNtSpawnerGo = @[]
  gNtSpawnerComp = @[]
  gNtSubSpawner = @[]
  gNtGameSpawner = nil
  gNtKbSpawner = nil
  gNtGfxTabSpawner = nil
  gNtPostFxTabSpawner = nil
  gNtStockPanels = @[]
  gNtStockWasOn = @[]
  gNtForeignOn = false
  gNtStockGfxOn = false
  gNtSubToggle = @[]
  gNtSubPageIdx = @[]
  gNtSubStripGo = nil
  gNtGfxPanelGo = nil
  gNtGameToggle = nil
  gNtModsRowRoot = nil
  gNtKbToggle = nil
  gNtKbPanelGo = nil
  gNtKbRowRoot = nil
  gNtKbTemplate = nil
  gNtShown = -1
  gNtSubSel = 0
  gNtSubN = 0
  gNtKbRows = 0
  gNtBuilt = false
  gNtSubBuilt = false
  gNtKbBuilt = false
  gNtModsPanelIdx = -1
  gNtProofPhase = 0
  gNtVerdictSaid = false
  gNtSubVerdictSaid = false
  gNtKbVerdictSaid = false

proc ntTickBody() =
  ## Every frame while armed. Steady state: two boolean tests and, once built,
  ## one integer compare -- the press arrives from the detour, not from a hunt.
  if not gNtOn or gNtOff: return
  gNtStep = "tick: entry"
  # THE TWO FRAME COUNTERS, first, so nothing below can skip them.
  if gNtSettleFrames > 0: gNtSettleFrames = gNtSettleFrames - 1
  # P8: a close that was entered and never came back is only visible from a
  # LATER frame, which is what this is.
  ntCloseVerdict()
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
    # THE SCREEN IS GONE. Detach and forget BEFORE the scene transition, not
    # after: the crash happened during the raid load, which is after this.
    ntTeardown("the settings screen closed")
    gNtVerdictSaid = false
    return
  # THE EVENT, drained. `gNtPressed` is set by the Toggle::Set postfix only
  # when one of OUR toggles was pressed with sendCallback=true.
  if gNtPressed >= 0:
    let idx = gNtPressed
    gNtPressed = -1
    gNtStep = "tick: reading m_IsOn off the toggle that was pressed"
    let pressedTog = ntTabToggleNow(idx)
    let (ok, isOn) = (if pressedTog != nil: nuToggleIsOn(pressedTog)
                      else: (false, false))
    if ok:
      if isOn: ntShow(idx)
      else: ntHide()
      # RE-JUDGE ON THE EVENT, which is what doc 4 actually asks for: the
      # verdict follows a selection change, not a frame counter.
      gNtVerdictSaid = false
      gNtWhyNext = "toggle event -- our tab was pressed " &
                   (if isOn: "ON" else: "OFF")
  # STEP 4: our CONTROLS>MODS subtab was pressed.
  if gNtKbPressed >= 0:
    let shown = (gNtKbPressed == 1)
    gNtKbPressed = -1
    gNtStep = "tick: CONTROLS>MODS subtab pressed"
    if gNtKbPanelGo != nil:
      discard modsSetActive(gNtKbPanelGo, shown)
    if shown and not gNtKbArmed:
      gNtKbArmed = true
      gNtStep = "tick: arming the /aowlspt/keybinds fetch"
      kbArm(cNowMs())
  # Advance the keybind fetch and render the rows the first time they land.
  if gNtKbOn and gNtKbArmed:
    gNtStep = "tick: advancing the keybind fetch"
    kbTick(cNowMs())
    if gNtKbBuilt and gNtKbRows == 0 and kbReady() and kbCount() > 0:
      gNtStep = "tick: rendering the keybind rows"
      discard ntBuildKeybindRows()
      gNtKbVerdictSaid = false
    if gNtKbBuilt and gNtKbRows > 0:
      ntKbVerdict()
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
  # THE STOCK GRAPHICS TAB GOING ON IS ALSO A STOCK SELECTION.
  # It is classified above the foreign-toggle branch (it owns the strip), so it
  # never set `gNtForeignOn` and our MODS panel stayed up beside Graphics --
  # the P1 FAIL measured 2026-09-04. Drained here, and only when one of ours is
  # actually shown, so a GRAPHICS press with nothing of ours up is still a
  # no-op.
  if gNtStockGfxOn:
    gNtStockGfxOn = false
    if gNtShown >= 0:
      gNtStep = "tick: the stock GRAPHICS tab went ON -- hiding ours"
      ntHideOursOnly()
      gNtVerdictSaid = false
      gNtWhyNext = "the stock GRAPHICS tab was selected -- ours must be off"
  # THE STOCK GRAPHICS TAB EDGE IS NO LONGER ACTED ON HERE.
  #
  # It used to raise and hide the strip and re-apply the selection. That is
  # now the ShowScreen POSTFIX rider's job, and for a reason that is not
  # tidiness: a toggle edge is not the same event as a panel switch. The edge
  # fires for GRAPHICS only, so nothing raised the strip when the screen
  # OPENED on Graphics through `OpenGroup` (§2.7, no toggle press of ours to
  # observe), and nothing lowered it when the game switched groups by any
  # route other than a click. `ShowScreen` fires for ALL of them -- the
  # player's click, our own `ntSubApply`, and `OpenGroup` -- so one drain
  # covers every case and there is no second copy to drift.
  #
  # The edge is still DRAINED, because leaving a flag set forever is its own
  # bug, and it is logged once so the classification the postfix made stays
  # visible.
  if gNtSubPressedGfx >= 0:
    let gfxOn = (gNtSubPressedGfx == 1)
    gNtSubPressedGfx = -1
    gNtStep = "tick: stock GRAPHICS tab edge (informational)"
    if not gNtGfxEdgeSaid:
      gNtGfxEdgeSaid = true
      okLog "native subtabs: saw the stock GRAPHICS tab toggle go " &
            (if gfxOn: "ON" else: "OFF") & ". This is INFORMATIONAL only -- " &
            "strip visibility is decided by the ShowScreen postfix rider, " &
            "which fires for the player's click, for our own ShowScreen call " &
            "and for OpenGroup when the screen first opens. A toggle edge " &
            "cannot see that last one, which is why the strip used to fail " &
            "to appear when Settings opened straight onto GRAPHICS."
  # THE SUBTAB EVENT, drained from the same postfix as the tab event.
  if gNtSubPressed >= 0:
    let sidx = gNtSubPressed
    gNtSubPressed = -1
    gNtStep = "tick: applying a subtab selection"
    if gNtSubPressedByPlayer:
      gNtSubPressedByPlayer = false
      okLog "native subtabs: subtab pressed by the player: " &
            (if sidx == 1: "POSTFX" else: "GENERAL") &
            " -- the click reached the toggle through the game's own raycast, " &
            "not through our code. That is the half that was in doubt."
    ntSubShow(sidx)
    gNtSubVerdictSaid = false
  # THE VERDICT RUNS WHENEVER THE GRAPHICS TAB IS UP, not only when a tab of
  # ours is shown -- and it runs `NtVerdictDelay` frames AFTER the change that
  # prompted it, never on the frame of the change (§6.5 predicate 9: a layout
  # rebuild is deferred to `willRenderCanvases`, so a same-frame read is
  # INCONCLUSIVE, not PASS).
  #
  # It used to be gated on `gNtShown`, which is only ever set for a tab of
  # OURS -- so under the stock GRAPHICS tab, which is where this strip
  # actually lives, it never ran at all and a boot with BOTH subtabs lit
  # printed no FAIL whatsoever.
  # THE BODY-OFFSET VERDICT, judged `NtVerdictDelay` frames after the write
  # and never on the frame of the write: a RectTransform change is not
  # reflected in `get_rect` until the driven-property/layout rebuild that
  # Unity defers to `willRenderCanvases`.
  if gNtBodyJudge > 0:
    gNtBodyJudge = gNtBodyJudge - 1
    if gNtBodyJudge == 0 and gNtBodyOn and not gNtBodyOff:
      ntBodyVerdict()
  if gNtVerdictDue > 0:
    gNtVerdictDue = gNtVerdictDue - 1
    if gNtVerdictDue == 0 and gNtSubBuilt and gNtSubKind == NtSubPanels:
      ntSubVerdict(gNtWhyNext)
      ntStripOrderVerdict()
      gNtWhyNext = "steady state"
  elif gNtSubBuilt and gNtSubKind == NtSubRows and gNtShown >= 0:
    ntSubVerdict("mod subtab selection")
  elif gNtSubBuilt and gNtSubKind == NtSubPanels and gNtGfxTabOn:
    ntSubVerdict("steady state with the GRAPHICS tab up")
  gNtStep = "tick: proof / verdict"
  # THE PROOF, one bounded step per frame. Each phase waits `NtProofSettle`
  # frames before judging, because a panel switched this frame is not laid out
  # until the next -- judging on the switching frame is exactly what produced
  # the meaningless '6 panels active' reading.
  if gNtProofOn and gNtProofTabOn and gNtToggle.len > 0 and
     gNtProofPhase < 6:
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
      let proofId = (if gNtId.len > 0: gNtId[0] else: "?")
      let proofTog = ntTabToggleNow(0)
      if proofTog != nil and nuTogglePress(proofTog, true):
        okLog "native tabs PROOF: pressed OUR tab '" & proofId & "' (index 0 " &
              "of " & $gNtToggle.len & " native tab(s) -- naming it because " &
              "with more than one of ours, 'our tab' is ambiguous and a " &
              "verdict that says 'ours is off' cannot be read without it) " &
              "through " &
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
      let gameTog = ntSpawnerToggleNow(gNtGameSpawner)
      if gameTog != nil and nuTogglePress(gameTog, true):
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

proc ntBindCloseProbe(verbose: bool): bool =
  ## THE CLOSE PAIR: a PREFIX on `SettingsScreen::Close` @0x1720B10 and a
  ## POSTFIX on `SettingsScreen::CloseAll` @0x17207A0.
  ##
  ## TWO DETOURS ON TWO DIFFERENT FUNCTIONS, never two on one. Both are
  ## MEASURED sharedness=UNIQUE (`R shared`), both prologue byte-verified
  ## through `nuFn` against the STARTUP SNAPSHOT (never live memory -- a
  ## verify run after another feature patched a function reads its trampoline
  ## and self-rejects), and nothing else in this host patches either.
  ##
  ## Neither handler suppresses its original and neither writes a field. The
  ## prefix's only effect on game state is `Toggle::SetToggleGroup(null)` on
  ## toggles WE put into stock groups -- the game's own way to leave one.
  result = false
  let fnClose = nuFn(NuTScreenClose)
  let fnAll = nuFn(NuTScreenCloseAll)
  if fnClose == nil or fnAll == nil:
    warn "native tabs: the settings CLOSE pair could not be bound -- Close: " &
         nuWhyName(cNuWhyOf(NuTScreenClose)) & "; CloseAll: " &
         nuWhyName(cNuWhyOf(NuTScreenCloseAll)) & ". Only a PROLOGUE " &
         "MISMATCH would mean this game build changed; every other reason is " &
         "a fault in our own host, most likely ORDER (this must run after " &
         "cProPrimeAll and after GameAssembly.dll is loaded). NOTHING was " &
         "patched, and the consequence is that a throw unwinding through the " &
         "settings close stays invisible exactly as it was."
    return
  let a = attachDrain("EFT.UI.Settings.SettingsScreen::Close", fnClose,
                      cast[Il2CppMethod](0), false, verbose, 30'i32)
  # 2 register slots (`this` + MethodInfo*); `CloseAll()` declares no
  # parameters, so the postfix thunk moves nothing.
  let b = attachDrain("EFT.UI.Settings.SettingsScreen::CloseAll", fnAll,
                      cast[Il2CppMethod](0), false, verbose, 31'i32, true,
                      2'i32)
  if a and b:
    okLog "native tabs: bound the settings CLOSE pair -- a PREFIX on " &
          "SettingsScreen::Close @0x1720B10 and a POSTFIX on " &
          "SettingsScreen::CloseAll @0x17207A0, both UNIQUE. Close calls " &
          "CloseAll at +0x2F (MEASURED), so 'CLOSE ENTERED' with no " &
          "'CloseAll RETURNED' is a throw or fault unwound through the " &
          "close. All three of 2026-09-02's deaths followed closing this " &
          "screen and produced no managed exception in the client's own log; " &
          "this is the instrument that would have named it."
    result = true
  else:
    warn "native tabs: the settings CLOSE pair bound only partially (Close=" &
         $a & " CloseAll=" & $b & "). A half-bound pair cannot distinguish " &
         "'never entered' from 'entered and never returned', which is the " &
         "one question it exists to answer."

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
