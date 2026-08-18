# Writing a mod

The whole API, top to bottom, in one page.

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():                      # true once, when the game exists
    let hp = Player.get("Health")        # a C# property
    info "health is " & $hp.asFloat()
    discard Player.invoke("Heal", 50)    # a method, with arguments

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args           # what the game passed
        carryOn())                       # and let it run
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient},
          onUpdate = onUpdate)
```

Build it:

```
aowl build-mod examples/highlevel
```

`examples/highlevel` is the worked version of everything on this page — types,
calls, live objects, fields, hooks with arguments, suppression — and it is built
and run against a stand-in runtime by `aowl test`, so it is the sample worth
copying from. `examples/clientprobe` is the same mod written against the raw
interface, which is worth reading once to see what the layer above is doing.

Every snippet on this page was compiled against the current library before it
was written down. Where something has *not* been verified, it says so.

## The three things underneath

Everything reaches the game through exactly three calls. The high-level API is
these with the boilerplate gone; when something behaves oddly, this is the level
to think at.

| | what it does |
|---|---|
| `resolve(name, handle)` | find a type by name, across every loaded assembly |
| `call(target, argsJson, out)` | invoke `Type::Member` with a JSON argument array |
| `patch(target, kind, handler)` | detour a compiled method and be told when it runs |

There is a fourth way in that does not go through the host at all — see
"Per-frame code" at the bottom. Reach for it when you have measured, not before.

## Types

```nim
var Player = gameType("EFT.Player")
```

Declared at the top of the file, resolved on first use. That split matters:
when a mod loads, the process has an IL2CPP runtime but the game has not
finished loading its own assemblies, so resolving `EFT.Player` at load time is a
false negative. `GameType` closes the gap — name it early, resolve it late.

`gameType` is a **template**, not a proc, and that is load-bearing. In a nimony
`--app:lib` build a global initialised by a *call* is never initialised: literal
initialisers are folded at compile time, anything needing runtime evaluation is
skipped, and the global is left zeroed. As a template it expands to an object
literal at the declaration, which does get folded. If you write your own
helper that returns a `GameType`, make it a template too — or `resolveNow` will
warn you that a `GameType` has no name, which is what that warning means.

The same trap catches `aowlspt/fast`'s bindings, which cannot be templates. The
rule there is the mirror image: declare the global bare and assign to it from
inside a proc.

## Calls

```nim
Player.invoke("Add", 17, 25)      # ints
Player.invoke("Scale", 2.5)       # float
Player.invoke("Greet", "operator")# string
Player.invoke("SetFlag", true)    # bool
Player.get("Health")              # property getter -> get_Health
Player.set("Health", v(100.0))    # property setter -> set_Health
```

Arguments are bound to the **declared** parameter types, read off the method
itself — not guessed from the shape of the value you passed. IL2CPP will not
check for you: hand `il2cpp_runtime_invoke` an object pointer where it wanted a
pointer-to-int and it reads the object header as an integer, with no error
anywhere. A mismatch is refused instead:

```
argument 0 is declared System.Int32 but a string was given
```

Results are typed:

```nim
let r = Player.invoke("Add", 17, 25)
if r.ok:
  echo r.asInt()          # 42
else:
  echo r.error
```

`asInt`, `asFloat`, `asBool`, `asText`, `isNull`, `failed`. Each takes a default
for the case where the value is not what you expected, so a bad read is a
default rather than a crash.

`CallResult` is a record rather than a bare string on purpose: a failed call
would otherwise hand back `""`, which is a perfectly plausible value for plenty
of methods, and the failure would read as data.

## Live objects

A `GameType` is the static half of the game. Almost everything a mod wants is on
the other half — *this* player's health, *this* weapon's animation:

```nim
var GameWorld = gameType("EFT.GameWorld")

let world  = GameWorld.instanceOf()          # get_Instance
let player = world.child("MainPlayer")       # get_MainPlayer, on that world
info $player.get("Health").asFloat()
discard player.invoke("Damage", 25.0)
player.release()
world.release()
```

`instanceOf`, `child` and any call that returns a reference type hand back a
`GameObj`. It holds an IL2CPP GC handle, not a pointer, so keeping one across
frames is safe — the collector moves objects, and a raw pointer that was right
last frame is not right this one. The price is `release()`: a handle held for
the session pins its object. That is a leak rather than a crash, which is the
right way round for a mistake to fall.

`alive()` answers whether the object is still there, so a mod can ask before it
tries. `ok` is false for "the call did not return one", which is an ordinary
answer rather than a failure — `get_Instance` before the world exists returns
null.

### Fields

`get`/`set` reach a C# **property**, which compiles to `get_X`/`set_X`. A
**field** has no method behind it and is unreachable that way — and a great deal
of what a mod wants on this game is a field, often a private one:

```nim
let hp = player.field("Health").asFloat()
discard player.setField("Level", v(7))
```

Underneath, `field` is an ordinary `call` with an `@` in front of the member
name: `EFT.Player::@Health` reads one, and the same target with an argument
writes it. That spelling is what you will see in a log line or in
`examples/clientprobe`, and it is the escape hatch you drop to if you are
building the target string yourself.

Reading a field is not a trick; reflection is what the runtime provides for it.
Values are read and written by the field's **declared** type, so writing a float
into an int field is refused rather than reinterpreted — the bytes for `1` and
`1.0` are different bytes, and nothing downstream would notice until the game
did.

It is also not fast. The `@` path costs more than the property getter it exists
to replace, for reasons [PERF.md](PERF.md) measures. It exists because a great
deal of the game has no property at all.

## Hooks

Two of them, and which you want depends on whether you need to know *what* the
method was called with.

**`hook` — the cheap one.** It costs a name comparison and nothing else, and the
handler is told only that the method fired:

```nim
discard hook("EFT.Player::OnDead",
  proc (target: string) =
    info "someone died")
```

**`hookArgs` — the full Harmony prefix.** The handler is told what the method was
called with, and may stop it running:

```nim
discard hookArgs("EFT.Player::Hurt",
  proc (target, args: string): HookResult =
    info "hurt with " & args        # e.g. [12.5,2]
    carryOn())                      # or stopWith("0.0"), or stopVoid()
```

`args` is a JSON array in the same shape `call` takes, so it is read with
`aowlspt/json` exactly like a request body on the server side. A reference
argument arrives as `{"handle":n,"type":"..."}` — a live object you can call
methods on, which is usually the whole reason to want the arguments.

`stopWith(json)` suppresses the original and hands the caller that value
instead. `stopVoid()` is the same for a method that returns nothing.
`carryOn()` lets it run.

Four things about this are worth holding on to, because each of them is a
refusal that could have been a guess:

- **Arguments past the fourth are not reported.** They arrive on the stack
  rather than in registers, and the host omits them rather than guessing.
  A patch that reported the wrong fifth argument would be worse than one that
  reports four and says so. On an *instance* method `this` occupies the first
  register, so three declared arguments are what fits.
- **A suppression whose replacement does not match the declared return type is
  refused**, and the original runs. Skipping the method with garbage in the
  return register is the worst outcome available, so it is the one thing the
  host will not do.
- **`patchReplace` from a handler that did not ask for arguments is refused
  too.** A mod that believes it is suppressing when it is not would be debugging
  the game instead of its own registration.
- **Arguments are opt-in** because decoding them builds a JSON array inside a
  method the game may call thousands of times a frame. `hookArgs` on a per-bot,
  per-frame method is the wrong tool; `hook` is the right one.

When two mods hook the same method, every handler runs and the *first* one that
asks to stop wins. Running the rest is deliberate: two mods hooking one method
are not in a race, and one of them deciding to suppress is not a reason the
other should stop being told the method fired. Only the decision is first-wins,
because there is one original and it either runs or does not.

Some methods cannot be patched at all, and you will be told which and why:

```
the prologue of EFT.Player::Tick could not be relocated (it holds a relative
branch, or an instruction this decoder does not know)
```

That happens when the first instructions of the function cannot be safely moved
into a trampoline — see [IL2CPP.md](IL2CPP.md). A function shorter than the
12-byte jump is refused for the same reason. Refusing is deliberate: the
alternative is overwriting whatever the linker put next.

There are 16 patch slots.

## What a client mod does not get

| | |
|---|---|
| `db_get` / `db_patch` | server-side; returns `ErrUnsupported` |
| `route_register` | server-side; returns `ErrUnsupported` |
| `invoke_main` | queues onto the host thread, **not** Unity's main thread |

That last one matters if you touch Unity objects. The host runs its own attached
thread; a mod that needs the real main thread cannot get there yet, and the name
is documented rather than left to imply otherwise. There is machinery in the
host for draining the queue from inside a method Unity calls per frame, and it
is not wired to anything, so the sentence above is the one that is true today.

## Keeping things: JSON, and a store of your own

Two facilities every non-trivial mod needs, on either side.

**Reading and editing JSON** — `aowlspt/json`:

```nim
import aowlspt/json

let name  = body.field("Info.Nickname").asText
let first = body.field("items[0]._id").asText
for it in each(body.field("items")):
  info it.field("_tpl").asText
```

It scans; it does not build a tree. A `JsonRef` is a pair of offsets into text
somebody else owns, so `field` costs one walk and no allocation.

For *editing*, take a document apart member-wise and put it back:

```nim
var d = parseObject(itemText)
setNumber(d, "StackObjectsCount", 42)
let updated = text(d)          # every field you did not touch is byte-identical
```

That is not a style preference. Rebuilding a document from a builder silently
drops every field your mod does not model, and the game's documents are full of
them. Member-wise editing keeps what it does not know about.

**A store of your own** — ABI revision 2:

```nim
discard save("profile." & id, profileJson)
let stored = load("profile." & id)
for key in savedKeys("profile."):
  info key
```

One file per key, held by the host under `store/<your-guid>/`. Use it for what
your mod owns; `dbGet`/`dbPatch` is the *shared* game database and is the wrong
place for your save state. Keys are flat `[A-Za-z0-9._-]`, and an invalid key is
refused rather than mangled into a filename that might collide with another one.

Check `storeReady()` before you rely on it — a host older than revision 2 does
not have it, and finding that out from a `false` is better than from a null
function pointer. It is the host's reported `AowlHostApi.size` that answers,
because nimony will not cast a proc field to a pointer to compare it against
null.

Both nimony hosts implement it; so does the simulator.

## Timers, and talking to other mods

```nim
discard on("someone.else.event", proc (payload: string): string =
  info "heard it"
  "")

discard emit("my.mod.event", "{\"id\":\"...\"}")
```

Delivered synchronously, in subscription order, to everyone **but** the emitter —
a mod that owns an event usually subscribes to it too, and delivering it back
would be a loop nobody wrote. Every host implements this, which is what the mod
manager's control protocol is built on.

`after(delayMs, handler)` runs something once, later; `every(intervalMs,
handler)` runs it repeatedly. A repeating timer re-arms itself with the same
cookie rather than registering a new handler per firing — the alternative leaks
one entry per tick, which only shows up in a server left running for a week.

## Per-frame code

`aowlspt/game` is the pleasant API and it is also the general one, which is why
it costs about a microsecond a call. If you are doing something once per frame
per entity, that is the wrong budget, and `aowlspt/fast` is the other shape: bind
a method or a field once, then call through the binding.

```nim
import aowlspt/il2cpp
import aowlspt/fast

var rt: Il2Cpp
var bWorld, bMainPlayer: Binding
var fHealth: FieldBinding

proc bindOnce(): bool =
  ## From onUpdate, on the first frame the type resolves -- never from onLoad,
  ## and never as a global initialiser.
  rt = openIl2Cpp()
  if not rt.loaded: return false
  bWorld = bindMethod(rt, "EFT.GameWorld", "get_Instance", 0)
  if not bWorld.ok:
    warn bWorld.why
    return false
  bMainPlayer = bindMethod(rt, "EFT.GameWorld", "get_MainPlayer", 0)
  fHealth = bindField(rt, "EFT.Player", "Health")
  result = bMainPlayer.ok and fHealth.ok

proc perFrame() =
  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return
  a.reset()
  let player = callPtr(bMainPlayer, w, a)
  if player == nil: return
  let hp = readFloat(fHealth, player)      # a load from player + offset
  writeFloat(fHealth, player, hp + 1.0)
```

A bound call is around 10 ns and a bound field read under 2 ns, against 950–1235
ns for the boxed path. `openIl2Cpp()` binds the already-loaded
`GameAssembly.dll` directly, so the host is not on this path at all — a mod DLL
is in the same process as the runtime.

Three rules, none of them negotiable, all of them in
`aowl/src/aowlspt/fast.nim`:

1. **Bind from inside a proc, never as a global initialiser** — the zeroed-global
   trap again. A zeroed `Binding` has `ok = false`, so it fails safe; it also
   never becomes true.
2. **A bound call takes a raw pointer, not a `Handle`.** Resolve it fresh each
   frame, as above, and do not store it. The collector moves objects.
3. **A binding that cannot express a signature refuses**, with a `why` that names
   it: a `double` argument, a `Vector3`, a fifth argument, an enum, a generic.
   Log the `why` once. A refused binding is a mod that quietly does nothing
   otherwise.

`mods/classicmovement` is the worked example: it binds a four-step chain, checks
every signature against the runtime's own metadata before hooking anything, and
falls back to a property getter where a field is a property on some builds.

The numbers, how they were measured and what they do not prove are in
[PERF.md](PERF.md). Read it before porting anything for speed: a naive native
port that stays on the boxed path loses to the C# it replaced.

## Testing without the game

```
aowl test
```

builds a stand-in IL2CPP runtime (`tests/mockil2cpp`) that exports the same C
API as `GameAssembly.dll`, loads the host against it, and runs
`examples/highlevel` through resolve, call-with-arguments, live objects, fields
and patching:

```
ok    the host booted and reached its tick loop
ok    a mod was loaded through the ABI
ok    the host bound the runtime and attached a thread
ok    4 types resolved by name through the runtime
ok    a method was invoked and its string return marshalled back
ok    arguments were bound by declared type and came back correct
ok    a compiled method was detoured and the patch fired
ok    a live object was reached and an instance call changed it
ok    a field was read by declared type and agreed with its property
```

The field check is stronger than it looks: it passes only when the field and the
property getter for the same storage *agree*. Either alone can be plausibly
wrong; agreeing is what makes the offset right rather than lucky.

**One caveat, current as of this writing.** On msys2 ucrt64 gcc 15.2 the
stand-in's `Tick` and `Hurt` compile to prologues the detour engine refuses to
relocate, so the "patch fired" line comes out as `error no patch fired` and the
gate goes red — while the suppression check on `Boost` passes in the same run,
and 15 bytes are stolen from it cleanly. That is a stand-in and toolchain
artefact rather than a hole in the detour engine, but it is a real red gate and
it is written down here rather than quietly rounded off.

To iterate on a mod against the stand-in:

```
aowl build-mod examples/highlevel
hostharness <stage-dir> --runtime tests/mockil2cpp/GameAssembly.dll --seconds 8
```

Add types and methods to `mockil2cpp.c` as you need them. It is a few hundred
lines and deliberately shaped like the type universe a real mod meets — including
a pair of methods written with the signature a *compiled* IL2CPP method has,
because that is the one the detour path sees.

None of this establishes that BSG's client behaves the same way. It exports the
same C API and that is what is being exercised; the last step is still to launch
and read `aowlspt/aowlspt-host.log`.
