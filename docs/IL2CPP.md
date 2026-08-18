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
| `resolve` / `call` | yes: any type, any zero-argument method, by name |
| `event_emit` | logged; delivery between mods is not wired yet |
| `db_get` / `db_patch`, `route_register` | `ErrUnsupported` — server-side |
| `patch` (Harmony) | `ErrUnsupported` — needs a detour engine |

Two limits are deliberate and reported rather than faked:

- **`call` invokes zero-argument methods only.** Given arguments it returns
  `ErrUnsupported` rather than dropping them. A reflection call that quietly
  ignores its arguments surfaces as wrong game behaviour hours later.
- **`invoke_main` is not Unity's main thread.** It queues onto the host's own
  attached thread. A mod touching a Unity object still needs the real main
  thread, and this host cannot yet put it there. Said plainly rather than
  implied by the name.

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

runs the host twice: once loaded directly into a process, once injected into a
live one through the same code path the launcher uses.

```
ok    host loads and runs a mod
ok    host survives injection into a live process
```

Neither run has an IL2CPP runtime in it, and that is the point. The host is
supposed to notice, say so, and keep going:

```
[2172ms] warn   the IL2CPP runtime did not come up within 2s
[2172ms] ok     clientprobe loaded on aowlspt-host-il2cpp
[2172ms] ok     host running
[7343ms] warn   could not resolve EFT.Player: the IL2CPP runtime is not up yet
```

That log line — a mod's own message arriving through `AowlHostApi.log` — is the
one that proves the ABI crosses the boundary intact.

What these cannot prove is `resolve` and `call` against a live runtime. That
needs the game, and it is the one step left to run by hand:

```
aowlspt-launch --root D:\Aowlspt
```

then read `aowlspt/aowlspt-host.log`.

## If you are porting a client mod for performance

Worth knowing before you start, because the obvious port can come out slower.

`il2cpp_runtime_invoke` boxes its arguments and dispatches generically. It is
meaningfully slower than the C# call it replaces, so a native mod that calls
into the game a few hundred times per frame will lose to the C# version it
replaced. The wins are real but they come from a specific shape:

- **No GC.** Per-frame allocations in a large client mod cause collection
  spikes; native code has none. This is usually the biggest single win.
- **Field access by offset.** `il2cpp_field_get_offset` once at load, then raw
  pointer arithmetic — faster than the C# property access it replaces.
- **Threading.** Pull state into native structs once per tick, compute off the
  main thread, write back a minimal result. Unity APIs are main-thread-only, so
  this is the thing a C# mod largely cannot do.

What does not change: raycasts and NavMesh queries stay in the engine and cost
what they cost. Profile the sensing/logic split before committing to a rewrite.
