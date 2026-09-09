## ar/press.nim -- PRESSING A CONTROL, BY THE ROUTE ITS KLASS ACTUALLY NEEDS.
##
## THERE IS NO GENERIC PRESS, AND THAT IS THE WHOLE POINT OF THIS FILE.
##
## The host had one. `arOnClickOff` returned `0x120` for an `EFT.UI.
## DefaultUIButton` and the generic `UnityEngine.UI.Button.m_OnClick` offset
## `0x100` for everything else, and then fired whatever was in that slot as a
## `UnityEvent`. On an `EFT.UI.AnimatedToggle` -- which derives from
## `UnityEngine.UI.Toggle` -- `0x100` is `toggleTransition`, an ENUM. A small
## integer is not null, is not a GameObject and is not a known klass, so it
## passed every guard that existed, and was then CALLED as a UnityEvent. The
## client died of it TWICE, deterministically, on the first frame the toggle was
## found (2026-09-02).
##
## A plausible non-null value that is not a pointer is the worst input a guard
## can receive. The fix was not a better guard. It was to stop asking the
## question: THREE KLASSES, THREE ROUTES, each one the entry point the game
## itself uses.
##
##   EFT.UI.AnimatedToggle    ->  Toggle::Set(true, true)
##   EFT.UI.DefaultUIButton   ->  its `_button` (TweenAnimatedButton) ->
##                                OnPointerClick(NULL), the player's own path
##   UnityEngine.UI.Button    ->  Button::Press(), the game's own click path
##
## A node whose klass is none of those is NOT PRESSED. It is reported.
##
## FOUND-AND-PRESSABLE MUST BE ONE STEP
## ------------------------------------
## Several GameObjects share the name `PlayButton` -- a wrapper container plus
## the real button. Returning the first merely-ACTIVE one and pressing it a beat
## later hit a node with no DefaultUIButton and did nothing, while the machine
## advanced believing it had acted. So discovery here returns only a node that
## is BOTH active AND carries the component the press would actually use, and
## the press happens in the SAME tick on the SAME pointer. `pressable` and
## `press` therefore go through ONE function for the component lookup, so the
## check and the action can never again read different things.

import aowlspt
import aowlspt/il2cpp
import native
import calls
import uitree

type
  PressKind* = enum
    pkNone         ## the node carries no control this mod knows how to press
    pkToggle       ## EFT.UI.AnimatedToggle
    pkDefaultUI    ## EFT.UI.DefaultUIButton
    pkUiButton     ## UnityEngine.UI.Button

proc kindName*(k: PressKind): string =
  case k
  of pkNone:      "<none>"
  of pkToggle:    "AnimatedToggle"
  of pkDefaultUI: "DefaultUIButton"
  of pkUiButton:  "Button"

proc controlOn*(node: Il2CppPtr; comp: var Il2CppPtr): PressKind =
  ## Which pressable component this node carries, and the component itself.
  ##
  ## THE THREE KLASSES ARE MEASURED, NOT GUESSED. Read live off the parked
  ## side-selection screen with the inspector's `components` verb, 2026-09-02:
  ##
  ##   the toggle node (`AnimatedToggle`, under `AnimatedToggleSpawner`)
  ##       RectTransform, CanvasRenderer, UI.Image, Animator,
  ##       **EFT.UI.AnimatedToggle**, EFT.UI.UISpawnableToggle, layout groups
  ##   the `Button` node under each side
  ##       RectTransform, CanvasRenderer, **UnityEngine.UI.Button**, EventTrigger
  ##   `NextButton` (under the sibling `ScreenDefaultButtons`)
  ##       RectTransform, **EFT.UI.DefaultUIButton**, DefaultUIButtonAnimation,
  ##       TweenAnimatedButton, layout components
  ##
  ## `UnityEngine.UI.Button` is a THIRD klass the host's original probe never
  ## looked for, which is why an earlier run reported ZERO pressable nodes on a
  ## screen that had two.
  ##
  ## The ORDER is deliberate: a toggle first, because on the side selector the
  ## toggle is the control the screen's own spawner created for that side and
  ## the bare `Button` beside it is the weaker choice.
  comp = nil
  var why = ""
  comp = componentOf(node, TypeRvaAnimatedToggle, why)
  if comp != nil: return pkToggle
  comp = componentOf(node, TypeRvaDefaultUIButton, why)
  if comp != nil: return pkDefaultUI
  comp = componentOf(node, TypeRvaUiButton, why)
  if comp != nil: return pkUiButton
  comp = nil
  result = pkNone

proc buttonCaption*(comp: Il2CppPtr): string =
  ## `DefaultUIButton._text` @0xB8 -- THE TEXT A PERSON READS on the control.
  ## "" means NOT READABLE, and no caller may treat that as a caption.
  result = ""
  if not readable(comp, OffDubText + 8): return
  let sp = readPtr(comp, OffDubText)
  if sp == nil: return
  result = readString(sp)

proc tweenOf(comp: Il2CppPtr): Il2CppPtr =
  ## `DefaultUIButton._button` @0x108 -> the `TweenAnimatedButton` that actually
  ## receives the click.
  result = nil
  if not readable(comp, OffDubButton + 8): return
  let b = readPtr(comp, OffDubButton)
  if b == nil or not readable(b, 0x70) or not alive(b): return
  result = b

proc tweenInteractable(btn: Il2CppPtr; ok: var bool): bool =
  ## `TweenAnimatedButton._interactable` @0x68. `ok` says whether the read
  ## HAPPENED; a caller that ignored it would be reading "not clickable" out of
  ## a failure to look, and would then refuse a control that is perfectly fine.
  ok = false
  result = false
  if btn == nil: return
  result = readBoolField(btn, OffTabInteractable, ok)

proc pressable*(node: Il2CppPtr; k: PressKind; comp: Il2CppPtr): bool =
  ## READ-ONLY: would `press` actually fire something on this node?
  ##
  ## No press, no invoke, nothing called. For a DefaultUIButton this asks the
  ## same three questions `press` will ask -- `_button` reachable, `_interactable`
  ## readable, `_interactable` true -- so the check and the action cannot
  ## disagree. That divergence is the §9b defect this file exists to avoid.
  if comp == nil or not alive(comp): return false
  case k
  of pkNone:
    result = false
  of pkToggle, pkUiButton:
    # Both are pressed through a byte-verified method on the component itself,
    # so a live component IS the precondition. There is no offset read to check.
    result = true
  of pkDefaultUI:
    let btn = tweenOf(comp)
    if btn == nil: return false
    var ok = false
    let inter = tweenInteractable(btn, ok)
    result = ok and inter

proc press*(node: Il2CppPtr; k: PressKind; comp: Il2CppPtr;
            via: var string; why: var string): bool =
  ## Press `node` by the route its klass calls for. `via` names the route that
  ## RAN and `why` names the reason nothing did -- exactly one of the two is
  ## ever non-empty, so a caller cannot log a success sentence for a refusal.
  ##
  ## RE-VALIDATE AT THE POINT OF USE. The node was found on an earlier line, and
  ## between the walk and here the screen may have been torn down: a destroyed
  ## object stays READABLE with `m_CachedPtr` zeroed (fact #182), so readability
  ## alone hands back a corpse and the next managed call faults inside Unity.
  result = false
  via = ""
  why = ""
  if node == nil or comp == nil:
    why = "nothing to press"
    return
  if not readable(node, 0x20) or not alive(node):
    why = "the node stopped being alive between finding it and pressing it " &
          "(a destroyed object stays readable -- fact #182), so NOTHING was " &
          "pressed"
    return
  case k
  of pkNone:
    why = "the node carries no AnimatedToggle, DefaultUIButton or " &
          "UnityEngine.UI.Button. There is deliberately no generic press: the " &
          "generic press is what killed the client."
  of pkToggle:
    # A TOGGLE IS SET, NEVER INVOKED. See the banner.
    if toggleSet(comp, true, true, why):
      via = "Toggle::Set(true, true)"
      result = true
  of pkUiButton:
    if unityButtonPress(comp, why):
      via = "UnityEngine.UI.Button::Press()"
      result = true
  of pkDefaultUI:
    # THE PLAYER'S OWN PATH FIRST. `TweenAnimatedButton::OnPointerClick` gates
    # on `_interactable` and invokes the button's own `Action OnClick`; firing
    # `DefaultUIButton.OnClick` @0x120 directly reaches the same handler but
    # SKIPS that gate, and MEASURED 2026-09-02 that left the profile/mode screen
    # half-transitioned with neither card clickable.
    let btn = tweenOf(comp)
    if btn != nil:
      var ok = false
      let inter = tweenInteractable(btn, ok)
      if not ok:
        why = "could not read `_interactable` on the TweenAnimatedButton, so " &
              "whether the control is clickable at all is UNKNOWN -- which is " &
              "NOT the same as false, and nothing was pressed"
        return
      if not inter:
        why = "the control's TweenAnimatedButton reads `_interactable` = " &
              "FALSE. Its own OnPointerClick would return without invoking " &
              "anything, so pressing it is provably a no-op and NOTHING WAS " &
              "PRESSED"
        return
      var w = ""
      if pointerClick(btn, w):
        via = "TweenAnimatedButton::OnPointerClick (the player's own click path)"
        return true
      why = w
      return
    # THE ANNOUNCED FALLBACK. Reached only when `_button` is unreachable.
    warn "AutoRaid: the player's click path (TweenAnimatedButton::" &
         "OnPointerClick) is not usable on this DefaultUIButton -- it has no " &
         "readable `_button` at +0xB8+0x50. Falling back to firing " &
         "DefaultUIButton.OnClick @+0x120 directly, which is the WEAKER path: " &
         "it reaches the same handler but skips the button's own interactable " &
         "gate."
    if not readable(comp, OffDubOnClick + 8):
      why = "the DefaultUIButton is not readable to +0x128, so its OnClick " &
            "UnityEvent slot could not even be read. Nothing was called."
      return
    let ev = readPtr(comp, OffDubOnClick)
    var w = ""
    if unityEventInvoke(ev, w):
      via = "DefaultUIButton.OnClick @+0x120 -> UnityEvent::Invoke (the " &
            "WEAKER fallback path -- the interactable gate was skipped)"
      return true
    why = w

proc findPressable*(root: Il2CppPtr; name: string; depth, cap: int;
                    visited: var int; names: var string;
                    kind: var PressKind; comp: var Il2CppPtr): Il2CppPtr =
  ## The ACTIVE node named `name` under `root` that is ALSO pressable, found
  ## level by level, with the census the refusal needs.
  ##
  ## ATOMIC BY CONSTRUCTION: the node returned is the node whose component was
  ## looked up, and the caller presses THAT pointer with THAT component in the
  ## same tick. No re-find happens between finding and pressing -- a re-find can
  ## return a transient or a same-named wrapper, which is the exact bug that
  ## made the host's PLAY press a no-op.
  result = nil
  kind = pkNone
  comp = nil
  visited = 0
  names = ""
  if root == nil or name.len == 0: return
  var nodes: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collectBFS(root, depth, b, deadlineNow(), nodes, cap, "")
  visited = nodes.len
  var i = 0
  while i < nodes.len:
    let nm = nodeName(nodes[i])
    if nm.len > 0 and names.len < MaxNamesLen:
      names = names & "[" & nm & "]"
    if result == nil and nm == name:
      var c: Il2CppPtr = nil
      let k = controlOn(nodes[i], c)
      if k != pkNone and pressable(nodes[i], k, c):
        result = nodes[i]
        kind = k
        comp = c
    i = i + 1
