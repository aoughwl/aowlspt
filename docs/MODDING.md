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

    discard hook("EFT.Player::OnDead",
      proc (target: string) =
        info "someone died")
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient},
          onUpdate = onUpdate)
```

Build it:

```
aowl build-mod examples/highlevel
```

`examples/highlevel` is that program, complete and tested. `examples/clientprobe`
is the same mod written against the raw interface, which is worth reading once
to see what the layer above is doing.

## The three things underneath

Everything reaches the game through exactly three calls. The high-level API is
these with the boilerplate gone; when something behaves oddly, this is the level
to think at.

| | what it does |
|---|---|
| `resolve(name, handle)` | find a type by name, across every loaded assembly |
| `call(target, argsJson, out)` | invoke `Type::Member` with a JSON argument array |
| `patch(target, kind, handler)` | detour a compiled method and be told when it runs |

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

## Hooks

```nim
discard hook("EFT.Player::OnDead",
  proc (target: string) =
    info "someone died")
```

This is the client-side equivalent of a Harmony prefix. It detours the compiled
function, so it fires however the game reaches the method — not only through
reflection.

Two limits, both real and both reported rather than approximated:

- **The handler cannot read the method's arguments.** Doing that correctly needs
  a thunk generated per signature. A hook that reported the *wrong* arguments
  would be worse than one that reports none.
- **The handler cannot suppress the original.** It runs before, and the original
  runs after.

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
tries.

### Fields

`get`/`set` reach a C# **property**, which compiles to `get_X`/`set_X`. A
**field** has no method behind it and is unreachable that way — and a great deal
of what a mod wants on this game is a field, often a private one:

```nim
let hp = player.field("Health").asFloat()
discard player.setField("Level", v(7))
```

Reading a field is not a trick; reflection is what the runtime provides for it.
Values are read and written by the field's **declared** type, so writing a float
into an int field is refused rather than reinterpreted — the bytes for `1` and
`1.0` are different bytes, and nothing downstream would notice until the game
did.

## What a client mod does not get

| | |
|---|---|
| `db_get` / `db_patch` | server-side; returns `ErrUnsupported` |
| `route_register` | server-side; returns `ErrUnsupported` |
| `invoke_main` | queues onto the host thread, **not** Unity's main thread |

That last one matters if you touch Unity objects. The host runs its own attached
thread; a mod that needs the real main thread cannot get there yet, and the name
is documented rather than left to imply otherwise.

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
function pointer.

## Talking to other mods

```nim
discard on("someone.else.event", proc (payload: string): string =
  info "heard it"
  "")

discard emit("my.mod.event", "{\"id\":\"...\"}")
```

Delivered synchronously, in subscription order, to everyone **but** the emitter —
a mod that owns an event usually subscribes to it too, and delivering it back
would be a loop nobody wrote. Both hosts implement this.

## Testing without the game

```
aowl test
```

builds a stand-in IL2CPP runtime (`tests/mockil2cpp`) that exports the same C
API as `GameAssembly.dll`, loads the host against it, and runs a mod through
resolve, call-with-arguments and patch:

```
ok    the host bound the runtime and attached a thread
ok    4 types resolved by name through the runtime
ok    a method was invoked and its string return marshalled back
ok    arguments were bound by declared type and came back correct
ok    a compiled method was detoured and the patch fired
```

To iterate on a mod against the stand-in:

```
aowl build-mod examples/highlevel
hostharness <stage-dir> --runtime tests/mockil2cpp/GameAssembly.dll --seconds 8
```

Add types and methods to `mockil2cpp.c` as you need them. It is a few hundred
lines and deliberately shaped like the type universe a real mod meets.

## Performance

If you are porting a client mod for speed, read the last section of
[IL2CPP.md](IL2CPP.md) first. The short version: `il2cpp_runtime_invoke` boxes
its arguments and dispatches generically, so a naive native port that calls into
the game a few hundred times a frame will lose to the C# it replaced. The wins
come from not allocating, reading fields by cached offset, and moving work off
the main thread — not from the language.
