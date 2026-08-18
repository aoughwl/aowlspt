# The post-1.0 client host

Tarkov 1.0 changed the client's scripting backend from **Mono** to **IL2CPP**.
That is not a version bump; it removes the thing every existing client mod
loads into.

| | pre-1.0 | post-1.0 |
|---|---|---|
| backend | Mono | IL2CPP |
| managed assemblies | `EscapeFromTarkov_Data/Managed/Assembly-CSharp.dll` | none |
| what is there instead | — | `GameAssembly.dll`, `il2cpp_data/Metadata/global-metadata.dat` |
| mod loader | BepInEx 5 | — |
| patching | Harmony, by method name | — |

`host/Aowlspt.Host.Client` is a Mono BepInEx plugin. It cannot load into a
post-1.0 client and no flag changes that. `host/Aowlspt.Host.Il2Cpp` is the
post-1.0 answer.

## Why there is no BepInEx underneath it

The expected way to mod an IL2CPP game is to rebuild the managed world:
BepInEx 6 IL2CPP starts a CoreCLR inside the process, Cpp2IL reconstructs proxy
assemblies from the metadata, and Il2CppInterop marshals between the proxies and
the real objects. It works. It is also a second runtime, a code-generation step
per game update, and a marshalling layer — to arrive back at "call a method by
name", which is what the mod wanted in the first place.

None of it is necessary, because **Unity's IL2CPP runtime exports its own C API
from `GameAssembly.dll`**. On this client, 242 functions, by name, unmangled:

```
> il2cppprobe D:\Games\Tarkov

Runtime
-------
ok    GameAssembly.dll loaded
ok    every entry point aowlspt uses is exported
ok    every essential entry point is present
```

That API — `il2cpp_class_from_name`, `il2cpp_class_get_method_from_name`,
`il2cpp_runtime_invoke`, `il2cpp_field_get_offset` — is the exact shape
aowlspt's ABI already wanted. So the host is a native DLL that calls the runtime
directly: no second runtime in the process, no generated assemblies, no interop
layer, and the host is written in the same language as the mods it hosts.

`aowl/src/aowlspt/il2cpp.nim` is the binding. `abi/aowlspt_shim.h` holds the
indirect calls, because nimony will not `cast` between a `pointer` and a `proc`
type — see the header for why that layering turned out to be the right one
anyway.

## What it does not do

It does not read `global-metadata.dat`. BSG ship that file encrypted and the
runtime decrypts it for itself during `il2cpp_init`. Going around that would be
breaking a protection rather than using an interface, so everything here goes in
through the runtime's own front door.

One consequence, worth knowing before you go looking for it: the runtime cannot
be started outside the game.

```
> il2cppprobe D:\Games\Tarkov --init

error il2cpp_init returned no domain
```

That is the real answer, not a broken tool. Type resolution has to happen
in-process, which is what the host is for.

## Getting into the process

`aowlspt-launch` starts the game suspended, loads the host into it, and resumes.
The alternative — dropping a fake `winhttp.dll` or `version.dll` next to the
executable and forwarding its exports — depends on the exact export set of the
system DLL on the machine it runs on, and leaves a file in the install
impersonating a Windows component. `abi/aowlspt_inject.h` has the mechanism.

The step people skip is waiting for the remote `LoadLibrary` thread and reading
its exit code. Without it a failed injection looks exactly like a successful one
until the mods do not appear. The launcher also terminates the client rather
than resuming one whose host failed to load: being in a raid before noticing the
mods are missing is worse than not starting.

## What a client mod gets

| | client (IL2CPP) |
|---|---|
| `log`, `config_get`, `now_ms` | yes |
| `invoke_main`, `schedule` | yes, on the host's own thread — see below |
| `resolve` / `call` | yes: any type, any method, with arguments, by name |
| live objects | yes: a reference return comes back as a handle you can call on |
| fields | yes: `Type::@Name` reads one, and with an argument writes it |
| `patch` | yes: an x64 inline detour on the compiled method |
| a patch's arguments | yes, with `AOWLSPT_PATCH_ARGS`: up to four, by declared type |
| suppressing the original | yes, if a return value of the declared type can be produced |
| `event_emit` / `event_subscribe` | yes, delivered between mods |
| `store_get` / `store_set` / `store_list` | yes (ABI revision 2) |
| the fast path | not the host's at all: a mod binds `GameAssembly.dll` itself |
| `db_get` / `db_patch`, `route_register` | `ErrUnsupported` — server-side |

Arguments are bound to the method's **declared** parameter types, read from
`il2cpp_method_get_param`, rather than guessed from the JSON's shape — a boxed
`Single` and a boxed `Int32` are the same shape in memory and only the
declaration tells them apart. A mistyped argument is refused, not coerced.

A call that returns a reference type gives back `{"handle":n,"type":"..."}`, and
that handle addresses the object: `#7::Damage`. Underneath it is an IL2CPP GC
handle rather than a raw pointer, because the collector moves objects and a
pointer held across two frames is a use-after-free waiting for its moment. The
cost is that a handle must be released; a mod that forgets pins one object for
the session, which is a leak rather than a crash and is the right way round.

## Reading a patch's arguments

This used to be refused. It is not any more, and the reason it took a while is
the reason it is safe now: the detour saves the argument registers on entry, and
the host decodes them **by the method's declared parameter types**, read from
`il2cpp_method_get_param`, exactly as `call` binds arguments on the way in. A
`float` comes out of the SSE register at that *position*; a reference comes out
of the general-purpose register at that position and is registered as a GC
handle, so the patch can call methods on the very object the game was about to
act on. A host that counted integer and float registers separately rather than
by position would read the float out of the wrong one and hand a mod `this`
reinterpreted as a double — which is the mistake `mockil2cpp`'s `Hurt` exists to
catch.

`AOWLSPT_PATCH_ARGS` (0x10) is OR'd into `kind` to ask for them. A flag rather
than a fourth patch kind, because it is orthogonal to prefix and postfix; opt-in
rather than always-on, because building that JSON array inside a method the game
calls thousands of times a frame is a cost a patch that only counts calls should
not pay.

Three refusals stayed:

- **Arguments past the fourth are not reported.** They arrive on the stack, and
  they are omitted rather than guessed at. On an instance method `this` takes
  the first register, so three declared arguments fit.
- **A suppression is refused unless a return value of the declared type can
  actually be produced.** The original never running with garbage in the return
  register is the worst outcome available, so `applyPatchReturn` answering
  "no" means the original runs after all.
- **A patch that did not ask for arguments cannot suppress.** It registered as
  an observer; honouring a skip from it would leave the mod author debugging the
  game instead of their own registration.

## `invoke_main` is not Unity's main thread

It queues onto the host's own attached thread and the tick loop drains it. A mod
touching a Unity object still needs the real main thread, and this host cannot
yet put it there. Said plainly rather than implied by the name.

There is machinery in `aowlhost.nim` for the real thing — a lock, a queue
counter, and an interlocked claim of whichever thread first reaches a method
Unity calls once per frame, so the queue could be drained from inside the
player loop. It is written and it is not wired to anything: nothing calls
`aowl_mq_enter`, and no drain hook is installed. Until it is, the sentence above
is the one that is true.

## Writing one

```nim
import aowlspt

proc onLoad(): Status =
  success "running on " & hostName()
  Ok

proc onUpdate(elapsedMs: int64): Status =
  var handle: Handle = 0
  if resolve("EFT.Player", handle) == Ok:
    info "the game is up"
    release(handle)
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient},
          onLoad = onLoad, onUpdate = onUpdate)
```

`examples/clientprobe` is a worked version. Note what it does with timing: it
does **not** resolve game types in `onLoad`. At load the process has a runtime
but not yet a game — EFT's assemblies come up later — so resolving `EFT.Player`
then reports a false negative. It waits in the tick loop instead.

## Testing without the game

```
aowl test
```

runs the host three ways: loaded directly into a process, injected into a live
one through the same code path the launcher uses, and then against
`tests/mockil2cpp` — a stand-in that exports the same C API as
`GameAssembly.dll`.

```
ok    host loads and runs a mod
ok    host survives injection into a live process
ok    resolve, call and patch against a runtime
ok    the fast path is measurably faster
```

The first two runs have no IL2CPP runtime in them, and that is the point. The
host is supposed to notice, say so, and keep going:

```
[2172ms] warn   the IL2CPP runtime did not come up within 2s
[2172ms] ok     clientprobe loaded on aowlspt-host-il2cpp
[2172ms] ok     host running
[7343ms] warn   could not resolve EFT.Player: the IL2CPP runtime is not up yet
```

That log line — a mod's own message arriving through `AowlHostApi.log` — is the
one that proves the ABI crosses the boundary intact.

The third run is the one that exercises `resolve`, `call` with arguments, live
objects, fields and a detour for real — see the check list in
[MODDING.md](MODDING.md), including the one check that is currently red on this
toolchain and why.

What none of them can prove is that **BSG's** implementation of the same C API
behaves identically. Nothing here has been run against the real client. That is
the one step left to run by hand:

```
aowlspt-launch --root D:\Aowlspt
```

then read `aowlspt/aowlspt-host.log`.

## The overlay

The host starts `host/Aowlspt.Overlay` on its boot thread, after the mods are
loaded and never from `DllMain` — the overlay creates a window, a D3D11 device
and a thread, all three of which deadlock under the loader lock, and that
presents as the game hanging on a black screen rather than as an error. A
failure to start is a warning: a host that refuses to load because a panel would
not draw is a worse trade than no panel.

It reads `backendPort` out of `aowlspt-host.json` beside the host. The file the
installer stages does not have that key, so by default the panel is read-only
and lists what the host pushed into it — which is what is actually running in
that process, and the one source that cannot be stale.

## If you are porting a client mod for performance

Worth knowing before you start, because the obvious port can come out slower.

`il2cpp_runtime_invoke` boxes its arguments and dispatches generically, and the
host's `call` on top of it parses JSON in and formats JSON out. Measured, that
is 950–1235 ns a call against 10 ns for a bound one — so a native mod that stays
on the boxed path and calls into the game a few hundred times per frame will
lose to the C# version it replaced. The wins are real but they come from a
specific shape:

- **Bind, then call.** `aowlspt/fast` removes the name lookup, the boxing and
  the JSON. This is the difference that dominates every other one.
- **No GC.** Per-frame allocations in a large client mod cause collection
  spikes; native code has none.
- **Field access by offset.** `il2cpp_field_get_offset` once at bind, then raw
  pointer arithmetic — under 2 ns, against 48 ns through a property getter.
- **Threading.** Pull state into native structs once per tick, compute off the
  main thread, write back a minimal result. Unity APIs are main-thread-only, so
  this is the thing a C# mod largely cannot do.

What does not change: raycasts and NavMesh queries stay in the engine and cost
what they cost. Profile the sensing/logic split before committing to a rewrite.

The numbers above, how they were taken and what they do not establish are in
[PERF.md](PERF.md). They are against the stand-in runtime, not BSG's.
