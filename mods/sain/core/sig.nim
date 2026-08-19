## The declared-signature rules for the five driving calls, as arithmetic over
## strings.
##
## Everything else in `core/` is the decision model. This file is here for one
## reason: the rule it holds is the sharpest assertion in the mod after the
## Win64 slot count, and like that one it can be proved on a laptop while the
## thing it guards can only be proved in a raid.
##
## ## What it guards against
##
## `il2cpp_class_get_method_from_name` matches on **name and arity** and hands
## back the first thing it finds. Every driving call in `client/bridge.nim`
## goes through it, and every one of them is a name that EFT overloads:
##
##  * `Mover.GoToPoint` exists in a one-argument form and in forms of two
##    through six, and `client/live.nim` asks for each arity in turn. Nothing
##    in that walk says the first argument is a `Vector3` -- only that the
##    method takes one argument.
##  * `Steering.LookToPoint` is the same shape and the same walk.
##  * `Mover.Sprint(bool)` was *stated* rather than checked: `lazyAs` puts the
##    caller's word for the signature on the fast path without ever asking the
##    runtime what the parameter actually is.
##
## None of those failures crashes, which is why they need a gate rather than a
## try. Handing a pointer-to-`Vector3` to a method whose first parameter is a
## `float` puts an address in a general-purpose register the callee reads as a
## distance; handing a bool to a method that declares a `float` leaves the
## speed in whatever was in XMM1. Both answer plausibly and drive the bot
## somewhere. That is the failure shape this mod is arranged against
## everywhere else, and until now the driving calls were the one place it was
## not guarded.
##
## ## What it does *not* decide
##
## Two checks stay at the runtime, because they need a number this file cannot
## have:
##
##  * whether a value type is passed by hidden pointer, which is its **size**
##    and is `live.byPointerSize`'s answer;
##  * whether the fast path will take the shape at all, which is
##    `live.tryShaped`.
##
## So a trailing parameter this file cannot name is passed on to those. What
## this file refuses is what it can decide from the declared type alone: a
## wrong first parameter, a wrong arity, a `double`, a by-reference parameter,
## and a second value type wide enough to need a buffer nobody planned.

type
  DriveShape* = enum
    ## The three shapes the driving calls come in. One value per *call site*
    ## in `bridge.apply`, not per method -- what is being checked is that the
    ## method the runtime found matches the way this mod is about to call it.
    dsNoArgs        ## `Shoot`, `TryReload`, `TryApply`, `TryApplyToCurrentPart`
    dsVectorFirst   ## `GoToPoint`, `LookToPoint`
    dsOneBool       ## `Sprint`

const
  VectorType* = "UnityEngine.Vector3"
  BoolType* = "System.Boolean"
  DoubleType* = "System.Double"

func isByRef*(tn: string): bool =
  ## A `ref`/`out` parameter, however the runtime chooses to render one.
  ##
  ## This matters and is not pedantry: the argument array `live.callVec`
  ## builds hands over the *address of a value* for every slot, which is
  ## exactly right for a by-value struct and exactly wrong for a by-reference
  ## one -- the callee would take that address as the pointer it is meant to
  ## write through and write into this mod's stack frame.
  result = false
  var i = 0
  while i < tn.len:
    if tn[i] == '&' or tn[i] == '*':
      return true
    inc i

func isWideValueType*(tn: string): bool =
  ## The value types Win64 moves into memory that a mover or a steering method
  ## plausibly declares.
  ##
  ## A deny list rather than an allow list, and it is a deny list because the
  ## complete answer is the runtime's: `live.byPointerSize` asks
  ## `il2cpp_class_is_valuetype` and measures the payload. What this list buys
  ## is that the *reflective* fallback -- which has no size to consult in the
  ## boxed argument array it builds -- refuses the cases anybody would meet
  ## rather than writing eight zero bytes into a twelve-byte slot.
  case tn
  of "UnityEngine.Vector2", "UnityEngine.Vector3", "UnityEngine.Vector4",
     "UnityEngine.Quaternion", "UnityEngine.Color", "UnityEngine.Bounds",
     "UnityEngine.Ray", "UnityEngine.RaycastHit", "UnityEngine.Matrix4x4",
     "UnityEngine.AI.NavMeshHit", "UnityEngine.Rect": true
  else: false

func describe*(params: openArray[string]; ret: string): string =
  result = "("
  var i = 0
  while i < params.len:
    if i > 0: result.add ", "
    result.add params[i]
    inc i
  result.add ") -> " & ret

func checkDrive*(shape: DriveShape; params: openArray[string]; ret: string;
                 why: var string): bool =
  ## True when the method the runtime found is the one `bridge.apply` is about
  ## to call. `why` carries a refusal a player could act on: what was found,
  ## what was wanted, and what the bot does instead.
  ##
  ## The return type is deliberately **not** checked, and that is a decision
  ## rather than an omission. Every one of these call sites discards what comes
  ## back, and `live.resolveOn` already refuses the fast path outright for a
  ## return it cannot classify -- a struct return falls to
  ## `il2cpp_runtime_invoke`, which boxes it correctly whatever it is. A gate
  ## on the return would refuse builds that work.
  why = ""
  case shape
  of dsNoArgs:
    if params.len != 0:
      why = "it declares " & $params.len & " argument(s) on this build and " &
            "this mod calls it with none. `callVoidOn` hands over a null " &
            "argument array, so the callee would read whatever the last " &
            "call left in the argument registers"
      return false
    return true
  of dsOneBool:
    if params.len != 1:
      why = "it declares " & $params.len & " argument(s) on this build and " &
            "this mod calls it with exactly one bool"
      return false
    if params[0] != BoolType:
      why = "its one argument is " & params[0] & " and this mod passes a " &
            BoolType & ". A bool travels in a general-purpose register and a " &
            "float is read out of XMM, so the flag would be read from " &
            "whatever was in the register the callee looks at"
      return false
    return true
  of dsVectorFirst:
    if params.len < 1:
      why = "it declares no arguments on this build, and this mod calls it " &
            "with a destination"
      return false
    if params[0] != VectorType:
      why = "its first argument is " & params[0] & " and this mod passes the " &
            "address of a " & VectorType & ". Win64 hands a 12-byte struct " &
            "over by hidden pointer, so a callee expecting anything else " &
            "reads that address as its own argument and answers plausibly"
      return false
    var i = 1
    while i < params.len:
      let tn = params[i]
      if isByRef(tn):
        why = "argument " & $(i + 1) & " is " & tn & ", which is by " &
              "reference. This mod fills trailing arguments with the address " &
              "of a value it owns, and a callee writing through that address " &
              "would write into this mod's own stack frame"
        return false
      if tn == DoubleType:
        why = "argument " & $(i + 1) & " is a " & DoubleType & ", which is " &
              "an XMM slot of a width the shaped trampolines do not carry"
        return false
      if isWideValueType(tn):
        why = "argument " & $(i + 1) & " is a second wide value type (" & tn &
              "), and only one buffer is planned per call -- the slot handed " &
              "over would be eight zero bytes where the callee reads twelve"
        return false
      inc i
    return true

func consequenceOf*(shape: DriveShape): string =
  ## What a bot does when this call is refused. In the log next to the reason,
  ## because a refusal a player cannot act on is a refusal that may as well be
  ## silence.
  case shape
  of dsNoArgs:
    "that action is never performed; the decision still fires and the ladder " &
    "is unchanged"
  of dsVectorFirst:
    "the bot is never told where to go or where to look. It still decides, " &
    "still searches, still picks cover -- and stands still while it does"
  of dsOneBool:
    "the bot moves at whatever speed the game last set. Every decision that " &
    "asks for a sprint gets a walk, and every one that asks for a walk after " &
    "a sprint keeps sprinting"
