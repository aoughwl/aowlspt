## The high-level client API — what writing a mod should actually feel like.
##
## Underneath, everything reaches the game the same way: `resolve` a type by
## name, `call` a method by name, `patch` a method to be told when it runs.
## That is a complete interface and a miserable one to write against:
##
##     var h: Handle = 0
##     discard resolve("EFT.Player", h)
##     var out = ""
##     discard call("EFT.Player::Heal", "[50]", out)
##
## This module is the same three things with the boilerplate gone:
##
##     let Player = gameType("EFT.Player")
##     discard Player.invoke("Heal", 50)
##
##     hook "EFT.Player::OnDead":
##       info "someone died"
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
  ##     {"this":{"handle":3,"type":"EFT.Player"},"args":[1,2.5]}
  ##     {"this":null,"args":[]}                     -- a static method
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
  ## Arguments past the fourth arrive on the stack and are not reported. They
  ## are omitted rather than guessed at.
  gArgHookTargets.add target
  gArgHookHandlers.add handler
  result = patch(target, pkPrefix, argHookDispatch, withArgs = true)
  if result != Ok:
    shrink(gArgHookTargets, gArgHookTargets.len - 1)
    shrink(gArgHookHandlers, gArgHookHandlers.len - 1)

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
