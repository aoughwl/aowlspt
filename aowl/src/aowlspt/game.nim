## The high-level client API — what writing a mod should actually feel like.
##
## Underneath, everything reaches the game the same way: `resolve` a type by
## name, `call` a method by name, `patch` a method to be told when it runs.
## That is a complete interface and a miserable one to write against:
##
##     var h: Handle = 0
##     discard resolve("EFT.Player", h)
##     var res = ""
##     discard call("EFT.Player::Heal", "[50]", res)
##
## This module is the same three things with the boilerplate gone:
##
##     var Player = gameType("EFT.Player")
##     discard Player.invoke("Heal", 50)
##
##     proc onDead(target: string) =
##       info "someone died"
##
##     discard hook("EFT.Player::OnDead", onDead)
##
## Two things it does beyond tidying.
##
## **It caches.** A `GameType` resolves once, on first use, and holds the
## handle. Resolving walks every loaded assembly, so doing it per call in a
## tick loop is the difference between a mod you can ship and one that hitches.
##
## **It waits.** The game's own assemblies are not loaded when a mod starts, so
## a type resolved at load time is a false negative. A `GameType` is declared
## eagerly and resolved lazily, which means a mod can name its types at the top
## of the file the way it wants to and still be correct.

import std/strutils
import ".." / aowlspt

type
  ValueKind* = enum
    vkInt, vkFloat, vkBool, vkString, vkObject

  Value* = object
    ## One argument. A variant rather than a generic so that a call site can
    ## mix types: `invoke("Move", 1, 2.5, true)`.
    kind*: ValueKind
    i*: int64
    f*: float
    s*: string
    h*: Handle

proc v*(x: int): Value =
  ## No separate `int64` overload: nimony's `int` is 64-bit, so the two would
  ## be the same signature and every call site would be ambiguous.
  Value(kind: vkInt, i: int64(x), f: float(x), s: "", h: 0)
proc v*(x: float): Value =
  Value(kind: vkFloat, i: int64(x), f: x, s: "", h: 0)
proc v*(x: bool): Value =
  Value(kind: vkBool, i: (if x: 1'i64 else: 0'i64), f: 0.0, s: "", h: 0)
proc v*(x: string): Value =
  Value(kind: vkString, i: 0, f: 0.0, s: x, h: 0)

proc escapeJson(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add ch

proc toJson*(v: Value): string =
  case v.kind
  of vkInt: result = $v.i
  of vkFloat: result = $v.f
  of vkBool: result = (if v.i != 0: "true" else: "false")
  of vkString: result = "\"" & escapeJson(v.s) & "\""
  of vkObject: result = "\"#" & $int(v.h) & "\""

proc argsJson*(args: openArray[Value]): string =
  result = "["
  for i in 0 ..< args.len:
    if i > 0: result.add ","
    result.add toJson(args[i])
  result.add "]"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

type
  CallResult* = object
    ## Deliberately not a bare string. A call can fail, and a mod that reads
    ## the result without noticing gets `""` -- which is a plausible value for
    ## plenty of methods, so the failure would look like data.
    ok*: bool
    raw*: string
    error*: string

proc failed*(r: CallResult): bool = not r.ok

proc unquote(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"':
    result = ""
    var i = 1
    while i < s.len - 1:
      if s[i] == '\\' and i + 1 < s.len - 1:
        inc i
        case s[i]
        of 'n': result.add '\n'
        of 't': result.add '\t'
        of 'r': result.add '\r'
        else: result.add s[i]
      else:
        result.add s[i]
      inc i
  else:
    result = s

proc asText*(r: CallResult): string =
  ## The result as text, with the JSON quoting removed if it was a string.
  result = unquote(r.raw)

proc asInt*(r: CallResult; default: int = 0): int =
  result = default
  if not r.ok or r.raw.len == 0:
    return
  var value = 0
  var neg = false
  var any = false
  var i = 0
  if r.raw[0] == '-':
    neg = true
    i = 1
  while i < r.raw.len:
    let ch = r.raw[i]
    if ch >= '0' and ch <= '9':
      value = value * 10 + (ord(ch) - ord('0'))
      any = true
    elif ch == '.':
      break
    else:
      return default
    inc i
  if not any:
    return default
  result = (if neg: -value else: value)

proc asFloat*(r: CallResult; default: float = 0.0): float =
  result = default
  if not r.ok or r.raw.len == 0:
    return
  var whole = 0.0
  var frac = 0.0
  var scale = 0.1
  var neg = false
  var any = false
  var seenDot = false
  var i = 0
  if r.raw[0] == '-':
    neg = true
    i = 1
  while i < r.raw.len:
    let ch = r.raw[i]
    if ch >= '0' and ch <= '9':
      any = true
      if seenDot:
        frac = frac + float(ord(ch) - ord('0')) * scale
        scale = scale * 0.1
      else:
        whole = whole * 10.0 + float(ord(ch) - ord('0'))
    elif ch == '.' and not seenDot:
      seenDot = true
    else:
      return default
    inc i
  if not any:
    return default
  let value = whole + frac
  result = (if neg: -value else: value)

proc asBool*(r: CallResult; default: bool = false): bool =
  if not r.ok:
    return default
  if r.raw == "true": return true
  if r.raw == "false": return false
  result = default

proc isNull*(r: CallResult): bool =
  result = r.ok and (r.raw.len == 0 or r.raw == "null")

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  GameType* = object
    ## A type in the running game, resolved on first use.
    ##
    ## Declared with `gameType` at the top of a mod and used whenever; the
    ## resolution happens the first time it is needed, which is the only point
    ## at which the game is guaranteed to have loaded its assemblies.
    name*: string
    handle*: Handle
    tried*: bool

template gameType*(typeName: string): GameType =
  ## Names a type. Does not resolve it yet — see the note above.
  ##
  ## A template rather than a proc, and that is not a style choice. In a nimony
  ## `--app:lib` build, a global initialised by a *call* is never initialised:
  ## literal initialisers are folded at compile time, anything needing runtime
  ## evaluation is skipped, and the global is left zeroed. A mod written the
  ## obvious way —
  ##
  ##     var Player = gameType("EFT.Player")
  ##
  ## would therefore hold an empty name and fail every lookup, silently. As a
  ## template this expands to an object literal at the declaration, which does
  ## get folded, so the obvious way is also the correct one.
  GameType(name: typeName, handle: 0, tried: false)

proc resolveNow*(t: var GameType): bool =
  ## Resolves if it has not been resolved. Returns whether the type is
  ## available; a failure is retried on the next call, because "not yet" and
  ## "never" are the same answer early in a run and only one of them is final.
  if t.handle != 0:
    return true
  if t.name.len == 0:
    # A zeroed GameType. The usual cause is a global initialised by a call
    # rather than a literal, which a nimony DLL never runs -- see `gameType`.
    # Saying so beats failing every lookup with "no such type: ".
    warn "a GameType has no name; if it is a global, initialise it with " &
         "gameType(...) rather than a proc that returns one"
    return false
  t.tried = true
  var h: Handle = 0
  if resolve(t.name, h) == Ok:
    t.handle = h
    return true
  result = false

proc available*(t: var GameType): bool = resolveNow(t)

proc invoke*(t: var GameType; member: string;
             args: openArray[Value] = []): CallResult =
  ## Calls a static member.
  result = CallResult(ok: false, raw: "", error: "")
  if not resolveNow(t):
    result.error = "type not available: " & t.name
    return
  var out1 = ""
  let st = call(t.name & "::" & member, argsJson(args), out1)
  if st == Ok:
    result.ok = true
    result.raw = out1
  else:
    result.error = lastError()

# The arity-specific overloads are what makes the call site read well; nimony
# has no variadic sugar that would produce them from one definition.
proc invoke*(t: var GameType; member: string; a: Value): CallResult =
  invoke(t, member, [a])
proc invoke*(t: var GameType; member: string; a, b: Value): CallResult =
  invoke(t, member, [a, b])
proc invoke*(t: var GameType; member: string; a, b, c: Value): CallResult =
  invoke(t, member, [a, b, c])

proc invoke*(t: var GameType; member: string; a: int): CallResult =
  invoke(t, member, [v(a)])
proc invoke*(t: var GameType; member: string; a: float): CallResult =
  invoke(t, member, [v(a)])
proc invoke*(t: var GameType; member: string; a: string): CallResult =
  invoke(t, member, [v(a)])
proc invoke*(t: var GameType; member: string; a: bool): CallResult =
  invoke(t, member, [v(a)])
proc invoke*(t: var GameType; member: string; a, b: int): CallResult =
  invoke(t, member, [v(a), v(b)])

proc field*(t: var GameType; name: string): CallResult =
  ## A static field.
  invoke(t, "@" & name)

proc setField*(t: var GameType; name: string; value: Value): CallResult =
  invoke(t, "@" & name, [value])

proc get*(t: var GameType; property: string): CallResult =
  ## A property getter. In IL2CPP a C# property compiles to `get_Name`, so
  ## this is the same call with the convention applied — which is worth
  ## wrapping, because forgetting the prefix produces "no such method" and no
  ## hint as to why.
  invoke(t, "get_" & property)

proc set*(t: var GameType; property: string; value: Value): CallResult =
  invoke(t, "set_" & property, [value])

# ---------------------------------------------------------------------------
# Live objects
# ---------------------------------------------------------------------------
#
# A type gets you the static half of the game. Almost everything a mod wants is
# on the other half: *this* player's health, *this* weapon's animation, *this*
# world's time. Those are instances, and an instance arrives as the return value
# of a call -- `GameWorld::get_Instance`, `Player::get_Physical`.
#
# The host hands one back as `{"handle":7,"type":"EFT.Player"}`, and the handle
# is what `invoke` on an object addresses. Underneath it is an IL2CPP GC handle,
# so holding one across frames is safe in the way holding a raw pointer is not:
# the collector moves objects, and a pointer that was right last frame is not a
# pointer that is right this one.
#
# The cost of that safety is that a handle must be released. A mod that forgets
# pins one object for the session -- a leak rather than a crash, which is the
# right way round for a mistake to fall.

type
  GameObj* = object
    ## A live object in the game. `ok` is false for "the call did not return
    ## one", which is an ordinary answer -- `get_Instance` before the world
    ## exists returns null, and that is not a failure.
    handle*: Handle
    typeName*: string
    ok*: bool

proc noObject*(): GameObj = GameObj(handle: 0, typeName: "", ok: false)

proc asObject*(r: CallResult): GameObj =
  ## The object a call returned, if it returned one.
  result = noObject()
  if not r.ok:
    return
  let at = find(r.raw, "\"handle\":")
  if at < 0:
    return
  var i = at + len("\"handle\":")
  var n = 0
  var any = false
  while i < r.raw.len and r.raw[i] >= '0' and r.raw[i] <= '9':
    n = n * 10 + (ord(r.raw[i]) - ord('0'))
    any = true
    inc i
  if not any or n <= 0:
    return
  var tn = ""
  let tat = find(r.raw, "\"type\":\"")
  if tat >= 0:
    var k = tat + len("\"type\":\"")
    while k < r.raw.len and r.raw[k] != '"':
      tn.add r.raw[k]
      inc k
  result = GameObj(handle: Handle(n), typeName: tn, ok: true)

proc isObject*(r: CallResult): bool = asObject(r).ok

proc target(o: GameObj): string = "#" & $int(o.handle)

proc invoke*(o: GameObj; member: string;
             args: openArray[Value] = []): CallResult =
  ## Calls a member **on this object**.
  result = CallResult(ok: false, raw: "", error: "")
  if not o.ok:
    result.error = "not a live object"
    return
  var out1 = ""
  let st = call(target(o) & "::" & member, argsJson(args), out1)
  if st == Ok:
    result.ok = true
    result.raw = out1
  else:
    result.error = lastError()

proc invoke*(o: GameObj; member: string; a: Value): CallResult =
  invoke(o, member, [a])
proc invoke*(o: GameObj; member: string; a, b: Value): CallResult =
  invoke(o, member, [a, b])
proc invoke*(o: GameObj; member: string; a, b, c: Value): CallResult =
  invoke(o, member, [a, b, c])
proc invoke*(o: GameObj; member: string; a: int): CallResult =
  invoke(o, member, [v(a)])
proc invoke*(o: GameObj; member: string; a: float): CallResult =
  invoke(o, member, [v(a)])
proc invoke*(o: GameObj; member: string; a: string): CallResult =
  invoke(o, member, [v(a)])
proc invoke*(o: GameObj; member: string; a: bool): CallResult =
  invoke(o, member, [v(a)])

proc get*(o: GameObj; property: string): CallResult =
  invoke(o, "get_" & property)

proc set*(o: GameObj; property: string; value: Value): CallResult =
  invoke(o, "set_" & property, [value])

proc field*(o: GameObj; name: string): CallResult =
  ## A **field**, not a property.
  ##
  ## `get`/`set` reach a C# property, which compiles to `get_X`/`set_X`. A field
  ## has no method behind it and is unreachable that way -- and a great deal of
  ## what a mod wants to read on this game is a field, often a private one.
  ## Reaching it is not a trick: reflection is what the runtime provides for it.
  invoke(o, "@" & name)

proc setField*(o: GameObj; name: string; value: Value): CallResult =
  invoke(o, "@" & name, [value])

proc child*(o: GameObj; property: string): GameObj =
  ## The object a property returns -- `player.child("Physical")`. Walking a
  ## chain of these is how a mod gets from a world to a weapon.
  result = asObject(get(o, property))

proc alive*(o: GameObj): bool =
  ## Whether the object is still there. A handle to something the collector has
  ## taken answers false rather than crashing when it is next used, and this is
  ## how a mod can ask before it tries.
  if not o.ok:
    return false
  var out1 = ""
  result = call(target(o) & "::GetType", "[]", out1) == Ok

proc release*(o: GameObj) =
  ## Lets go. A handle held for the session is a pinned object.
  if o.ok:
    release(o.handle)

proc instanceOf*(t: var GameType; property: string = "Instance"): GameObj =
  ## The singleton behind a type -- `GameWorld`, `CameraManager` and most of the
  ## game's managers expose exactly this. Separated out because reaching for the
  ## singleton is the first thing almost every client mod does.
  result = asObject(get(t, property))

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

type
  HookHandler* = proc (target: string)

  ArgHookHandler* = proc (target, args: string): HookResult
    ## A hook that is told what the method was called with, and may answer.
    ##
    ## `args` is a JSON array in the same shape `call` takes, so it is read with
    ## `aowlspt/json` exactly like a request body on the server side. A
    ## reference argument arrives as `{"handle":n,...}` -- the live object the
    ## game was about to act on, which is usually the reason to want the
    ## arguments at all.

  HookResult* = object
    ## What a hook decided. `stop` suppresses the original; `replaceWith` is the
    ## value the caller gets instead, as JSON, and must match the method's
    ## declared return type or the suppression is refused.
    stop*: bool
    replaceWith*: string

func carryOn*(): HookResult = HookResult(stop: false, replaceWith: "")

func stopWith*(json: string): HookResult =
  ## Suppress the original and return this value instead.
  HookResult(stop: true, replaceWith: json)

func stopVoid*(): HookResult =
  ## Suppress a method that returns nothing.
  HookResult(stop: true, replaceWith: "null")

func replaceResult*(json: string): HookResult =
  ## For a `hookReturn` handler: hand the caller this instead of what the
  ## original returned.
  ##
  ## The same `HookResult` a prefix uses, and the same field, because it is the
  ## same single decision -- what the caller ends up with. Named separately
  ## because "stop" is the wrong word once the original has already run, and a
  ## postfix handler reading `stopWith` would reasonably wonder what it was
  ## stopping.
  HookResult(stop: true, replaceWith: json)

func keepResult*(): HookResult = HookResult(stop: false, replaceWith: "")
  ## For a `hookReturn` handler: leave the original's answer alone.

## Hooks are kept as two parallel sequences and dispatched by matching the
## target name the host hands back.
##
## The obvious design — capture the index in a closure per hook — is not
## available: nimony will not let a nested proc touch its enclosing scope
## without being made a closure, and the ABI wants a plain function pointer.
## Matching on the name keeps every callback a top-level proc.
##
## The scan is linear in the number of hooks, on the path inside a patched
## game method. That is fine for the handful of hooks a mod installs and would
## not be for hundreds; if it ever is, the fix is a sorted table here, not a
## change to the ABI.
var gHookTargets: seq[string] = @[]
var gHookHandlers: seq[HookHandler] = @[]

var gArgHookTargets: seq[string] = @[]
var gArgHookHandlers: seq[ArgHookHandler] = @[]

var gRetHookTargets: seq[string] = @[]
var gRetHookHandlers: seq[ArgHookHandler] = @[]

proc hookDispatch(target, args: string): PatchResult =
  for i in 0 ..< gHookTargets.len:
    if gHookTargets[i] == target:
      gHookHandlers[i](target)
  patchContinue()

proc argHookDispatch(target, args: string): PatchResult =
  ## The first handler that asks to stop wins, and the rest still run.
  ##
  ## Running the rest is deliberate: two mods hooking the same method are not
  ## in a race, and one deciding to suppress the original is not a reason the
  ## other should stop being told the method fired. Only the *decision* is
  ## first-wins, because there is one original and it either runs or does not.
  var decided = false
  var answer = ""
  for i in 0 ..< gArgHookTargets.len:
    if gArgHookTargets[i] != target:
      continue
    let r = gArgHookHandlers[i](target, args)
    if r.stop and not decided:
      decided = true
      answer = r.replaceWith
  if decided:
    return patchReplace(if answer.len > 0: answer else: "null")
  patchContinue()

proc retHookDispatch(target, args: string): PatchResult =
  ## The postfix half of `argHookDispatch`, and the same first-wins rule for the
  ## same reason: two mods may both want to be told, and only one value can
  ## reach the caller.
  ##
  ## Kept as its own registry rather than folded into the prefix one, because a
  ## prefix and a postfix on the same method are two different patches with two
  ## different payloads, and a shared table would deliver a prefix payload to a
  ## handler expecting a `result`.
  var decided = false
  var answer = ""
  for i in 0 ..< gRetHookTargets.len:
    if gRetHookTargets[i] != target:
      continue
    let r = gRetHookHandlers[i](target, args)
    if r.stop and not decided:
      decided = true
      answer = r.replaceWith
  if decided:
    return patchReplace(if answer.len > 0: answer else: "null")
  patchContinue()

proc hookReturn*(target: string; handler: ArgHookHandler;
                 withArgs = true): Status =
  ## Be told what a game method **returned**, and be able to change it.
  ##
  ## This is Harmony's postfix, and it is the shape a mod needs whenever the
  ## answer depends on the original's own answer -- scaling a sensitivity,
  ## clamping a speed, filtering a list the game just built. The prefix
  ## alternative is `stopWith`, which means reimplementing the method, and a
  ## reimplementation of a method you cannot read is a guess.
  ##
  ## **What the handler is given.** The `hookArgs` payload with one more member:
  ##
  ##     {"this":{"handle":3,...},"args":[4.0],"result":6.0}
  ##     {"result":6.0}                              -- withArgs = false
  ##
  ## `hookResult(payload)` reads it as a `CallResult`, so `asFloat()`,
  ## `asInt()`, `asBool()` and `asObject()` all work on it. Return
  ## `replaceResult(...)` to change it, `keepResult()` to leave it alone.
  ##
  ## `result` is always present, whether or not arguments were asked for: it is
  ## one register read and it is the reason the hook exists. The arguments stay
  ## opt-in, and they are the values the method was **entered** with -- the
  ## registers saved on the way in, which is the only place they still are once
  ## the original has run.
  ##
  ## **Two methods cannot carry one, and the host says which.** A method
  ## returning a value type wider than eight bytes returns it through a buffer
  ## the host cannot read the layout of, so a postfix there could neither report
  ## the result nor replace it. And a method whose compiled call uses more than
  ## four register slots -- its declared arguments, `this`, and IL2CPP's
  ## trailing `MethodInfo*` -- has stack arguments, which a postfix cannot pass
  ## on, because it must *call* the original rather than jump to it. Both are
  ## refused at registration with a sentence naming which; check the status and
  ## read `lastError()`.
  ##
  ## An exception thrown out of the original does not reach the handler. A
  ## postfix means "after it returned", not "after it finished".
  gRetHookTargets.add target
  gRetHookHandlers.add handler
  result = patch(target, pkPostfix, retHookDispatch, withArgs = withArgs)
  if result != Ok:
    shrink(gRetHookTargets, gRetHookTargets.len - 1)
    shrink(gRetHookHandlers, gRetHookHandlers.len - 1)

proc hookArgs*(target: string; handler: ArgHookHandler): Status =
  ## Be told whenever a game method runs, **with its arguments**, and be able to
  ## stop it.
  ##
  ## This is the full Harmony prefix: read what the method was called with, and
  ## return `stopWith(...)` to keep it from running at all. The cost over `hook`
  ## is one JSON payload built per call, which is why it is a separate function
  ## rather than the default -- a hook on a method the game calls every frame
  ## for every bot should be a `hook`.
  ##
  ## **What the handler is given.** An object, not an array:
  ##
  ##     {"this":{"handle":3,"type":"EFT.Player"},"argc":2,"stackArgs":0,
  ##      "args":[1,2.5]}
  ##     {"this":null,"argc":0,"stackArgs":0,"args":[]}   -- a static method
  ##
  ## `this` is Harmony's `__instance`, and it is separate from `args` on
  ## purpose: it is not a declared parameter, and folding it into the array
  ## would make every argument index depend on whether the method happens to be
  ## static -- a difference that shows up as reading the wrong argument, far
  ## from the hook. A static method's `this` is `null` rather than missing, so
  ## "there is no instance" cannot be read as "the host did not say".
  ##
  ## `this` and any reference argument arrive as handles, and they are valid
  ## **only until the handler returns**. The host frees them at that point: a
  ## handler on a per-frame method would otherwise pin one object per call, and
  ## a contract that depends on a mod remembering to release on that path is a
  ## leak with extra steps. Read what you need inside the handler; do not store
  ## the handle.
  ##
  ## An `enum` argument arrives as its integer, and a value type too large for
  ## a register arrives as `{"valueType":"..."}` -- named and refused, because
  ## it is passed by hidden pointer and there is nothing in the register to
  ## report. A type the runtime cannot classify is `{"type":"..."}`.
  ##
  ## **An argument past the register window is named, not dropped.** Win64
  ## passes four arguments in registers and the thunk saves those four; on an
  ## instance method `this` is one of them, so a method with four declared
  ## parameters has its **fourth** on the stack and a static one has its fifth.
  ## There is nothing in the frame to report for it and nothing here can
  ## invent it -- but the payload says so rather than falling silent:
  ##
  ##     {"onStack":true,"type":"System.Single"}
  ##
  ## sits in that slot, so argument *n* is always declared parameter *n*, and
  ## "the host did not report this" can never be read as "this was empty".
  ## `argc` is the declared parameter count and `stackArgs` is how many of them
  ## are in that state, so a handler that wants nothing to do with a truncated
  ## firing can check one number before it reads anything.
  ##
  ## This was the last silent wrong answer on this path. The array used to stop
  ## early, so a handler reading argument 3 of a four-argument instance method
  ## got the same empty answer an empty argument would give it, and went on to
  ## decide something on a value the game never supplied.
  gArgHookTargets.add target
  gArgHookHandlers.add handler
  result = patch(target, pkPrefix, argHookDispatch, withArgs = true)
  if result != Ok:
    shrink(gArgHookTargets, gArgHookTargets.len - 1)
    shrink(gArgHookHandlers, gArgHookHandlers.len - 1)

# ---------------------------------------------------------------------------
# Typed hooks (ABI revision 4)
# ---------------------------------------------------------------------------
#
# `hookArgs` and `hookReturn` describe a firing as JSON. `hookTyped` and
# `hookReturnTyped` hand over the registers instead.
#
# The difference is not a percentage. Measured against the stand-in runtime on
# the same machine, in the same run: a bound call is 3 ns unpatched, a JSON
# prefix with arguments is about 2.2 us, and the typed equivalent is tens of
# nanoseconds -- because the JSON one builds a string, registers a GC handle per
# reference argument, copies the string into this mod's heap and parses it, and
# the typed one reads the register the argument is already in.
#
# Neither of these has a dispatcher scanning a list of target names, which the
# JSON hooks need because the host tells them only *what* fired. A typed handler
# is registered with its own cookie and is called directly, so a mod with twenty
# typed hooks pays nothing for the other nineteen.
#
# **When to use which.** `hookArgs` unless the hook fires per entity per frame.
# JSON survives an argument the host cannot classify, reads a `System.String`
# for you, and 2 us at 10 Hz is 0.002 percent of a frame. The typed form asks
# the mod to know the signature -- which it should check with `signatureOf`
# before installing either -- and gives back the frame budget.

proc hookTyped*(target: string; handler: TypedPatchHandler): Status =
  ## A prefix hook that is given the registers rather than a description of
  ## them, and may suppress the original.
  ##
  ## The handler receives a `PatchFrame`:
  ##
  ## ```nim
  ## proc onTilt(f: PatchFrame): TypedResult =
  ##   let obj = cast[Il2CppPtr](f.selfPointer())   # `this`, no handle, no call
  ##   var ok = false
  ##   let a = f.argFloat(0, ok)                    # declared parameter 0
  ##   if not ok: return frameContinue()
  ##   ...
  ##   if f.setResultVoid(): frameReplace() else: frameContinue()
  ## ```
  ##
  ## `selfPointer` is the address `thisPointer(payload)` costs a JSON build, a
  ## GC handle and a `pointerOf` round trip to produce; here it is the register
  ## the method was entered with. The same lifetime rule applies to it and to
  ## every `argPointer`: they are addresses, the collector moves objects, use
  ## them inside the handler. The frame itself is checked -- reading one after
  ## the handler has returned is refused and `frameWhyText()` says so.
  ##
  ## Arguments past the fourth register position report `akStack` and cannot be
  ## read; they are named rather than omitted, so argument *n* is always
  ## declared parameter *n*.
  ##
  ## `ErrUnsupported` on a host older than revision 4 -- test `typedPatchesReady()`
  ## and fall back to `hookArgs`, which is the point of keeping both.
  patchTyped(target, pkPrefix, handler)

proc hookReturnTyped*(target: string; handler: TypedPatchHandler): Status =
  ## The postfix half: the original has run, and `resultFloat`, `resultInt` and
  ## `resultPointer` read what it produced -- out of the register the declared
  ## return type says it is in. `setResultFloat` and friends change it, and
  ## `frameReplace()` makes the change stick.
  ##
  ## Reading a result on a *prefix* frame is refused rather than answered,
  ## because the original has not run and scaling a number that does not exist
  ## yet is worse than not scaling one.
  ##
  ## The same two method shapes the host refuses for a JSON postfix are refused
  ## here, for the same reasons and with the same sentences: a value-type return
  ## wider than a register, and a compiled call needing more than four register
  ## slots. See `hookReturn`.
  patchTyped(target, pkPostfix, handler)

# ---------------------------------------------------------------------------
# Typed hooks on a VERIFIED STATIC ADDRESS (`patchRva`)
# ---------------------------------------------------------------------------
#
# `hookTyped(name)` asks the runtime to find the method. On the post-1.0 client
# that lookup is not merely unreliable, it is fatal when USED: `findClass` and
# `findMethod` hand back non-nil handles into unmapped memory, the nil check
# passes, and the first dereference kills the game. Every effect that needs a
# detour there has to name its target by an address derived OFFLINE instead.
#
# The host has accepted an `@0xRVA` spec string for a while, and mods have been
# hand-concatenating one. This is the same path with the parts named, and the
# reason to prefer it is not tidiness:
#
#   * a spec string is validated only by the host, in the client, at install
#     time -- the one place where being wrong is expensive. `rvaSpecOf` refuses
#     the same mistakes here, in the mod, with the same sentences, and the sim
#     self-test can run it with no game at all.
#   * `expect` makes sharedness a value the caller had to write down. The host
#     checks the offline name index's share count either way; what this adds is
#     that a mod which never thought about folded bodies cannot accidentally
#     spell "unique".
#   * the four parts stop hiding in one literal. The FOV mod carried
#     `EFT.Player.FirearmController::get_AimingSensitivity` -- not a key on this
#     build -- harmlessly for weeks, because in a spec string the name is only
#     ever printed.
#
# What the HOST checks, and what a mod therefore cannot talk it out of: the
# prologue against its startup snapshot, the il2cpp-section and code-page
# checks, UNIQUE sharedness from the offline index (with the name/RVA
# cross-check), and that no other detour already owns the function -- the second
# detour on a function overwrites the first's trampoline and kills it silently.
# Each refusal names the gate. `why` carries it back.

const RvaMinPrologue* = 8
  ## The shortest prologue the host accepts, repeated here so a mod refuses
  ## before the call rather than after it. Declare all 16 that
  ## `il2cpp_resolve.py bytes <RVA> 16` prints; this is the floor.

proc rvaHexDigit(v: int): char =
  const D = "0123456789ABCDEF"
  result = D[v and 15]

proc rvaHexNum(v: uint32): string =
  ## Uppercase, no leading zeroes. Not `$`: the spec grammar is hex.
  if v == 0'u32:
    return "0"
  var rev = ""
  var x = v
  while x > 0'u32:
    rev.add rvaHexDigit(int(x and 15'u32))
    x = x shr 4
  result = ""
  var i = rev.len - 1
  while i >= 0:
    result.add rev[i]
    dec i

proc rvaHexNibblePair(b: uint8): string =
  result = ""
  result.add rvaHexDigit(int(b) shr 4)
  result.add rvaHexDigit(int(b) and 15)

proc rvaArgLetterOk(c: char; allowVoid: bool): bool =
  result = c == 'i' or c == 'f' or c == 'd' or c == 'o' or c == 'v' or c == 'V'
  if not result and allowVoid:
    result = c == 'x'

proc rvaShapeWhy(shape: string): string =
  ## "" if the shape is well formed. The host says the same things; saying them
  ## here means a self-test can prove a shape wrong without a game.
  if shape.len < 3:
    return "the shape " & shape & " is too short: it needs at least i/s, > " &
           "and a return letter (a no-argument instance float getter is i>f)"
  if shape[0] != 'i' and shape[0] != 's':
    var g = ""
    g.add shape[0]
    return "the shape must start with i (instance) or s (static), got " & g
  if shape[shape.len - 2] != '>':
    return "the shape must end with > and exactly ONE return letter, got " &
           shape
  var i = 1
  while i < shape.len - 2:
    if not rvaArgLetterOk(shape[i], false):
      var g = ""
      g.add shape[i]
      return g & " is not an argument letter in " & shape & " (i f d o v V)"
    inc i
  if not rvaArgLetterOk(shape[shape.len - 1], true):
    var g = ""
    g.add shape[shape.len - 1]
    return g & " is not a return letter in " & shape & " (i f d o v V x)"
  result = ""

proc rvaArity*(t: RvaPatchTarget): int =
  ## How many arguments the shape DECLARES. This is the arity the host looks
  ## the name up at, so a mod checking its own target offline must use the same
  ## number -- `i>f` is arity 0, `if>x` is arity 1.
  result = 0
  if t.shape.len >= 3:
    result = t.shape.len - 3

proc rvaSpecOf*(t: RvaPatchTarget; why: var string): string =
  ## The spec string this target becomes, or "" with `why` naming what is
  ## wrong. Public because it is the thing to log and the thing a self-test
  ## asserts on.
  why = ""
  result = ""
  if t.name.len == 0:
    why = "an RVA target needs the Type::Method name the offline index " &
          "spells it with; it is what the host looks up to cross-check the " &
          "address and read the share count, not a label"
    return
  var sep = -1
  var k = 0
  while k < t.name.len:
    let c = t.name[k]
    if c == '@' or c == '!' or c == '/' or c == '>':
      var g = ""
      g.add c
      why = "the name " & t.name & " contains " & g &
            ", which is spec-grammar punctuation: the name is a plain " &
            "Ns.Type::Method, and the address, shape and prologue are " &
            "separate fields here precisely so they are not concatenated by " &
            "hand"
      return
    if c == ':' and k + 1 < t.name.len and t.name[k + 1] == ':' and sep < 0:
      sep = k
    inc k
  if sep <= 0 or sep + 2 >= t.name.len:
    why = "the name " & t.name & " is not Ns.Type::Method (a non-empty type, " &
          "then ::, then a non-empty member)"
    return
  if t.rva == 0'u32:
    why = "an RVA of 0 is the module header, not code"
    return
  let shapeWhy = rvaShapeWhy(t.shape)
  if shapeWhy.len > 0:
    why = shapeWhy & ". There is no MethodInfo behind an RVA on this build, " &
          "so the host cannot derive the frame and a guessed one is a hook " &
          "that is silently wrong rather than absent"
    return
  if t.prologue.len < RvaMinPrologue:
    why = "the prologue is " & $t.prologue.len & " byte(s) and at least " &
          $RvaMinPrologue & " are required: a shorter one matches thousands " &
          "of functions, so it is a check that cannot fail. Paste what " &
          "il2cpp_resolve.py bytes 0x" & rvaHexNum(t.rva) & " 16 printed"
    return
  if t.prologue.len > 16:
    why = "the prologue is " & $t.prologue.len & " bytes; the host's startup " &
          "snapshot holds 16, so more than that cannot be verified and is " &
          "refused rather than silently truncated"
    return
  result = t.name & "@0x" & rvaHexNum(t.rva) & "/" & t.shape & "!"
  var b = 0
  while b < t.prologue.len:
    result.add rvaHexNibblePair(t.prologue[b])
    inc b
  if t.expect == rvaAllowShared:
    result.add "!shared"

proc patchRva*(t: RvaPatchTarget; kind: PatchKind; handler: TypedPatchHandler;
               why: var string): Status =
  ## Detour a method named by verified static address, handing the handler the
  ## registers (the typed frame `hookTyped` uses).
  ##
  ## `ErrBadArg` and a `why` means this mod's own description is malformed and
  ## nothing was sent to the host. Any other non-`Ok` means the HOST refused,
  ## and `why` is its refusal verbatim -- which gate declined and what to do --
  ## rather than a status a caller has to interpret.
  ##
  ## Typed only, deliberately. The JSON patch path needs a `MethodInfo` to
  ## describe the arguments and the return, an RVA has none, and the host
  ## refuses it there rather than handing a handler an empty payload and
  ## calling it a hook.
  why = ""
  let spec = rvaSpecOf(t, why)
  if spec.len == 0:
    return ErrBadArg
  result = patchTyped(spec, kind, handler)
  if result != Ok:
    why = lastError()

proc hookRva*(t: RvaPatchTarget; handler: TypedPatchHandler;
              why: var string): Status =
  ## A typed PREFIX on a verified static address: the handler runs instead of
  ## the original when it returns `frameReplace()` after a `setResult*`.
  patchRva(t, pkPrefix, handler, why)

proc hookReturnRva*(t: RvaPatchTarget; handler: TypedPatchHandler;
                    why: var string): Status =
  ## A typed POSTFIX on a verified static address: the original has run and
  ## `resultFloat` and friends read what it produced.
  ##
  ## The host refuses two shapes here, decided from the DECLARED shape rather
  ## than from a `MethodInfo`: a return wider than a register (`V`), which
  ## Win64 returns through a buffer whose layout the host cannot read, and a
  ## call needing more than four register slots, whose arguments arrive on the
  ## stack where a called original would look in the wrong frame.
  patchRva(t, pkPostfix, handler, why)

# ---------------------------------------------------------------------------
# Reading a hook payload
# ---------------------------------------------------------------------------
#
# The payload is a flat object with three possible members -- `this`, `args`
# and (for a postfix) `result` -- and the host is its only producer. So this is
# a scanner over that shape rather than a JSON parser: it finds a member by
# name and returns its value verbatim, balancing braces and brackets so that a
# nested object comes back whole and a `}` inside a string does not end it.

proc memberRaw*(payload: string; key: string): string =
  ## The raw JSON of one top-level member of a hook payload, or "" if absent.
  ##
  ## Only *top-level* members: the scan starts at depth 0 and a `"result"` that
  ## appeared inside a nested object would be skipped rather than mistaken for
  ## the one being asked for. Worth the extra state, because a game string in an
  ## argument can contain anything at all.
  result = ""
  let needle = "\"" & key & "\":"
  var i = 0
  var depth = 0
  var inStr = false
  while i < payload.len:
    let ch = payload[i]
    if inStr:
      if ch == '\\':
        inc i
      elif ch == '"':
        inStr = false
      inc i
      continue
    if ch == '"':
      # Only a key at the object's own level can be the one wanted.
      if depth == 1 and i + needle.len <= payload.len and
         payload.substr(i, i + needle.len - 1) == needle:
        i = i + needle.len
        break
      inStr = true
      inc i
      continue
    if ch == '{' or ch == '[': inc depth
    elif ch == '}' or ch == ']': dec depth
    inc i
  if i >= payload.len:
    return ""

  # The value, up to the comma or the brace that ends it at this level.
  var vdepth = 0
  var vstr = false
  var out1 = ""
  while i < payload.len:
    let ch = payload[i]
    if vstr:
      out1.add ch
      if ch == '\\' and i + 1 < payload.len:
        inc i
        out1.add payload[i]
      elif ch == '"':
        vstr = false
      inc i
      continue
    if ch == '"':
      vstr = true
      out1.add ch
      inc i
      continue
    if ch == '{' or ch == '[':
      inc vdepth
      out1.add ch
      inc i
      continue
    if ch == '}' or ch == ']':
      # At depth 0 this is the brace closing the payload itself, not part of
      # the value.
      if vdepth == 0: break
      dec vdepth
      out1.add ch
      inc i
      continue
    if ch == ',' and vdepth == 0: break
    out1.add ch
    inc i
  result = out1

proc handleIn*(json: string): Handle =
  ## The handle in a `{"handle":n,"type":"..."}`, or 0.
  result = 0'u64
  let at = find(json, "\"handle\":")
  if at < 0:
    return
  var i = at + len("\"handle\":")
  var n = 0
  var any = false
  while i < json.len and json[i] >= '0' and json[i] <= '9':
    n = n * 10 + (ord(json[i]) - ord('0'))
    any = true
    inc i
  if any and n > 0:
    result = Handle(n)

proc thisHandle*(payload: string): Handle =
  ## The handle for `__instance`, or 0 for a static method.
  result = handleIn(memberRaw(payload, "this"))

proc thisPointer*(payload: string): uint64 =
  ## The **address** of the object a hook fired for, for the fast path.
  ##
  ## This is the one line that turns a hook from a notification into a place to
  ## do work. `hookArgs` gives `this` as a handle, and everything reached through
  ## a handle goes through `call` -- roughly a microsecond, which on a method the
  ## game runs per entity per frame is a frame tax rather than a feature. The
  ## address is what `aowlspt/fast`'s `bindOnObject`, `callFloat` and `readFloat`
  ## take, and those are tens of nanoseconds.
  ##
  ## **Valid only while the handler runs.** The host reclaims the handle when the
  ## handler returns, and asking afterwards is refused rather than answered with
  ## a stale address -- but nothing can refuse an address the mod wrote down and
  ## used next frame, because by then it is just a number. Read what you need
  ## inside the handler. `pinHandle` is the way to keep an object, and says what
  ## pinning costs.
  ##
  ## Zero means there is no address: a static method, a host without a managed
  ## heap, or a handler that has already returned. `lastError()` says which.
  result = 0'u64
  let h = thisHandle(payload)
  if h == 0'u64:
    return
  var addr1 = 0'u64
  if pointerOf(h, addr1) == Ok:
    result = addr1

proc hookResult*(payload: string): CallResult =
  ## What the original returned, for a postfix handler.
  ##
  ## A `CallResult` rather than a bare string for the same reason `invoke`
  ## returns one: `asFloat()` on a missing member would answer 0.0, and 0.0 is a
  ## plausible sensitivity. `ok` is false when the payload carries no `result`,
  ## which is what a *prefix* handler's payload looks like -- so a handler
  ## registered the wrong way round finds out here rather than scaling a zero.
  result = CallResult(ok: false, raw: "", error: "")
  let raw = memberRaw(payload, "result")
  if raw.len == 0:
    result.error = "this payload has no result; it is not a postfix hook"
    return
  result.ok = true
  result.raw = raw

proc hook*(target: string; handler: HookHandler): Status =
  ## Be told whenever a game method runs.
  ##
  ## The cheap one: it costs a name comparison and nothing else, and the handler
  ## is told only that the method fired. Use `hookArgs` when you need to know
  ## what it was called with or want to stop it.
  gHookTargets.add target
  gHookHandlers.add handler
  result = patch(target, pkPrefix, hookDispatch)
  if result != Ok:
    # Do not leave a handler registered for a patch that was refused: it would
    # never fire, and the mod would have no way to tell that from a method that
    # never runs.
    shrink(gHookTargets, gHookTargets.len - 1)
    shrink(gHookHandlers, gHookHandlers.len - 1)

# ---------------------------------------------------------------------------
# Waiting for the game
# ---------------------------------------------------------------------------

type
  WhenReady* = object
    ## A one-shot that fires the first tick after a type becomes resolvable.
    ##
    ## This exists because "the game is up" is not an event the client host can
    ## observe -- assemblies arrive when they arrive. Polling for a type that
    ## only exists once the world does is the honest way to wait for it, and
    ## doing it once here beats every mod inventing its own counter.
    probe*: GameType
    fired*: bool

template whenReady*(typeName: string): WhenReady =
  ## A template for the same reason `gameType` is one.
  WhenReady(probe: GameType(name: typeName, handle: 0, tried: false),
            fired: false)

proc ready*(w: var WhenReady): bool =
  ## Call from `onUpdate`. True exactly once, on the first tick where the type
  ## resolves.
  if w.fired:
    return false
  if resolveNow(w.probe):
    w.fired = true
    return true
  result = false
