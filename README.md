# aowlspt

A modding pipeline for post-1.0 Tarkov, in **aowl/nimony**, front to back: a
native client host, a backend server, an in-game overlay, one mod ABI, one build
command -- and a Tarkov emulator written as a mod on top of it, using nothing a
mod cannot use.

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():                      # true once, when the game exists
    info "health " & $Player.get("Health").asFloat()
    discard Player.invoke("Heal", 50)

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args           # the arguments the game passed
        stopWith("0.0"))                 # and the original never runs
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient}, onUpdate = onUpdate)
```

## Why it is built this way

SPT 4.x moved the server to C#/.NET 10, so the obvious thing would be to write
mods in C#. This does not, for one reason: **the same compiled mod should run
everywhere, and it should be debuggable without launching Tarkov.**

That gives the shape of the whole system:

- One narrow **C ABI** (`abi/aowlspt_abi.h`) that both sides know and neither
  side's language leaks through.
- Hosts that implement it and differ only in what they can honestly offer: the
  SPT 4.x server mod, a BepInEx client plugin, a simulator (all three in C#,
  sharing one engine and a small `IHostServices` surface), and the two native
  nimony hosts this project actually runs on — `aowlspt-backend` and the
  post-1.0 IL2CPP client host, sharing `host/common/modhost.nim`.
- A **reflection escape hatch**, so nothing in the game or the server is
  unreachable just because the ABI has not grown a door for it yet.
- A **fast path** beside it, because the escape hatch is general and general is
  slow — see [docs/PERF.md](docs/PERF.md) for the measurement that says by how
  much.

The ABI is small on purpose. SPT renames types between point releases; a bridge
that names fifty of them breaks every release. This one names eleven database
tables and reaches everything else generically.

## Layout

```
abi/aowlspt_abi.h        the contract; everything else is downstream of it
abi/aowlspt_shim.h       the indirect calls nimony cannot express
abi/aowlspt_detour.h     the x64 inline-detour engine, 16 hook slots
abi/aowlspt_fast.h       the generated call trampolines behind aowlspt/fast
abi/aowlspt_inject.h     starting the game suspended and loading the host in
abi/aowlspt_net.h        the backend's sockets
abi/aowlspt_overlay.h    the in-game overlay, header-only C

aowl/src/aowlspt.nim     the mod-authoring library (nimony)
aowl/src/aowlspt/game    the high-level client API: types, live objects, hooks
aowl/src/aowlspt/server  the high-level backend API: routes, database, config
aowl/src/aowlspt/json    reading and editing a document without rebuilding it
aowl/src/aowlspt/fast    the per-frame path: bind once, then call
aowl/src/aowlspt/il2cpp  the binding to the runtime's own C API

host/Aowlspt.Abi         shared C# host engine — loading, dispatch, hot reload
host/Aowlspt.Sim         aowlspt-sim: run a mod with no game and no server
host/Aowlspt.Host.Server SPT 4.x server mod that hosts native mods
host/Aowlspt.Host.Client BepInEx plugin that hosts native mods (pre-1.0, Mono)
host/Aowlspt.Host.Il2Cpp native client host for post-1.0 (IL2CPP), in nimony
host/Aowlspt.Overlay     the in-game mod panel, drawn from inside Present
host/common/modhost.nim  mod loading and unloading, shared by both nimony hosts
host/common/modstore.nim the per-mod persistent store (ABI revision 2)

backend/                 aowlspt-backend: the server, in nimony
installer/               aowlspt-install: build an install from a vanilla one
registry/                mods.json: every mod, and the lists that select them

mods/tarkov              the Tarkov emulator, as a mod
mods/manager             the mod manager: the registry, your lists, what is live
mods/sway                SPT-SWAY, natively
mods/fov                 Fontaine's FOV fix, ported
mods/classicmovement     TheBoogle's Old Tarkov Movement, ported
mods/sain                SAIN, rewritten
mods/morebots            the bot-type and faction API other mods build on
mods/blackdivision       a PMC faction, on top of morebots
mods/icebreaker          a map mod

tools/aowl.nim           aowl: the only build command — build, test, package
tools/aowllaunch.nim     aowlspt-launch: start the game with the host inside it
tools/il2cppprobe.nim    what a post-1.0 client exposes
tools/hostharness.nim    run the client host with no game
tools/aowlprobe.nim      call a backend route with the game's wire framing
tools/emutest.nim        drive the emulator through the client's boot sequence
tools/perfbench.nim      what a client-side call costs, in nanoseconds
tools/SptProbe           sptprobe: call an SPT route with SPT's zlib framing
tools/SptReflect         dump SPT's public API surface

examples/hello           the plumbing, end to end
examples/backend         config, database patching, dynamic routes, `call`
examples/clientprobe     reaching into a post-1.0 client by name
examples/highlevel       the same, through the high-level API
examples/gameserver      routes, database and config on the backend

docs/                    why each of the above is the way it is
reference/               SPT's public API surface, dumped per version
tests/abi_layout.*       the ABI's layout, checked against the C header
tests/mockil2cpp         a stand-in IL2CPP runtime exporting the same C API
tests/overlayhost        a D3D11 application that stands in for the game
tests/fixtures           a small database the emulator tests buy things out of
```

## The edit loop

`aowl` is itself a nimony program: the thing that compiles a nimony mod is
written in the language it compiles. The point of `aowlspt-sim` is that this
takes about a second:

```
aowl run examples/hello
```

Edit, save, rebuild — the running mod is swapped for the new binary and its
state is handed across:

```
info  aowl.hello: hello mod unloading after 275 ticks
info  aowlspt: loaded Hello (aowl.hello) v1.0.0 from hello.dll
info  aowl.hello: restored tickCount=275
ok    aowlspt: reloaded Hello (aowl.hello) v1.0.0
```

**Hot reload is the C# hosts' facility, not the nimony ones'.** `aowlspt-sim`,
the SPT server host and the BepInEx client host share `ModHost.Reload`, and it
works for mods that declare `flags = {mfHotReloadable}` and implement
`stateSave`/`stateLoad`; a mod that does not is told to restart rather than
silently losing state. `aowlspt-backend` and the IL2CPP client host do not
implement reload. What they do have is `unloadOne` — see "Taking a mod out"
below — which is the harder half of it.

For debugging with gdb or Visual Studio, see [docs/DEBUGGING.md](docs/DEBUGGING.md).

## What a mod can do

| | backend | client (IL2CPP) | sim |
|---|---|---|---|
| `log`, `emit`, `on`, config, `after`/`every` | yes | yes | yes |
| `save` / `load` / `savedKeys` (revision 2) | yes | yes | yes |
| `route` (HTTP) | yes | — | yes |
| `dbGet` / `dbPatch` | yes | — | yes (from `--db`) |
| `patch` / `hook` | — | x64 detour | recorded |
| `hookArgs` — arguments, and suppression | — | yes | — |
| `call` / `resolve` (reflection) | — | yes | from `--stubs` |
| `aowlspt/fast` — bind once, call per frame | — | yes | — |
| `onMainThread` | the request thread | the host's own thread | queue |

A capability a side does not have returns `ErrUnsupported` rather than
misbehaving, so `side()` guards are the normal way to write a mod that ships
everywhere.

`dbPatch` **merges**; it does not replace, and it **creates a path that is not
there**. Two mods editing sibling fields of the same item do not clobber each
other, which is the difference between a mod system and a pile of mods that
happen to coexist; and a mod whose job is adding content — a new location, a new
bot type, a table of its own — can express that instead of carrying a
workaround.

`onMainThread` is the one name that promises more than it delivers on the
client, and it says so: the IL2CPP host queues onto its own attached thread,
which is not Unity's frame loop. See [docs/IL2CPP.md](docs/IL2CPP.md).

## Requirements

- **nimony** built for Windows (see `reference/` notes and the memory entry on
  the Windows toolchain — several fixes were needed and are documented).
- **msys2 ucrt64 gcc** plus `mingw-w64-ucrt-x86_64-lld`.
  `C:\msys64\ucrt64\bin` must precede Git-for-Windows' `/mingw64/bin` on PATH or
  gcc dies with no diagnostic at all.
- **.NET 10 SDK** for the C# hosts.
- An **SPT 4.1.x install** to compile the server and client hosts against. It is
  read for metadata only.
- A **Tarkov install** for `aowlspt-install` to work from. It is only ever read;
  see "Installing" below.

## Installing

Building, running, testing and debugging all happen inside this repo.
`aowlspt-install` is the one program that writes anywhere else, and it will not
do so without being told what to install and where.

```
aowl payload                                   # stage what you built
aowlspt-install detect                         # what is on this machine
aowlspt-install plan    --source D:\Games\Tarkov --target D:\Aowlspt --payload installer/payload
aowlspt-install install --source D:\Games\Tarkov --target D:\Aowlspt --payload installer/payload
```

`--source` is only ever read. The client is mirrored into `--target` — hard
linked where it is safe to, so a 78 GB install appears in seconds and costs no
disk — and the payload goes over the top. The install your official launcher
maintains stays canonical, stays updatable, and can rebuild the target at any
time. Uninstall is exact, driven by a manifest the install writes.

To add mods to an install that already exists, give it a payload containing
only `aowlspt/` and no `--source`; it becomes an overlay that owns only what it
added. That is what the old deploy script did, and it is why there is no longer
a deploy script.

Full documentation: [installer/README.md](installer/README.md).

### Post-1.0 Tarkov

Tarkov 1.0 changed the client's scripting backend. Pre-1.0 clients are **Mono**:
`EscapeFromTarkov_Data/Managed/Assembly-CSharp.dll` is an ordinary .NET
assembly, BepInEx loads into the Mono runtime, and Harmony patches methods by
name. Post-1.0 clients are **IL2CPP**: there are no managed assemblies at all,
only `GameAssembly.dll` and `il2cpp_data/Metadata/global-metadata.dat`.

Nothing built for one loads into the other. SPT 4.1.2 declares
`compatibleTarkovVersion` `0.16.9.40743`, a pre-1.0 Mono client, and the usual
way people run it is to roll a current client backwards to that build.

**This installer will not do that.** It refuses, and `--force` does not enable
it — a downgrade across a major release is not a patch; it replaces the client's
assemblies and asset bundles with an older game's, and it means the game you
play is not the game you own.

So aowlspt does the other thing: it hosts mods in the post-1.0 client directly.
Unity's IL2CPP runtime exports its whole C API from `GameAssembly.dll` — 242
functions, by name, on the client `il2cppprobe` was run against — so
`host/Aowlspt.Host.Il2Cpp` is a native DLL that drives it, with no BepInEx, no
Il2CppInterop, no generated proxy assemblies and no second runtime in the
process. `aowlspt-launch` starts the game suspended, puts the host in it, and
resumes.

```
aowl payload
aowlspt-install install --source D:\Games\Tarkov --target D:\Aowlspt --payload installer/payload
aowlspt-launch --root D:\Aowlspt
```

| | post-1.0 (IL2CPP) |
|---|---|
| the installer | detects, plans, installs, verifies, uninstalls |
| the backend | `aowlspt-backend`, in nimony: routes, database, mod API, the client's zlib framing |
| client-side mods | load and tick, with a typed high-level API |
| `resolve` / `call` | any type, any method, arguments bound by declared type |
| live objects | a reference return is a handle you can call on, held by the GC |
| fields | reached by name, read and written by their declared type |
| `hook` / `patch` | x64 code detours: fires however the game reaches the method |
| reading a hook's arguments | yes, up to four, with `hookArgs` — the fifth onward is omitted rather than guessed |
| suppressing the original | yes, `stopWith(json)`, if the replacement matches the declared return type |
| the fast path | bind a method or field once, then call it for ~10 ns |
| the overlay | drawn from inside `Present`; Insert toggles it |
| `invoke_main` | the host thread, not Unity's main thread |

Writing one: [docs/MODDING.md](docs/MODDING.md) for the client,
[docs/BACKEND.md](docs/BACKEND.md) for the server. Why there is no BepInEx
underneath, and what a performance port actually costs:
[docs/IL2CPP.md](docs/IL2CPP.md) and [docs/PERF.md](docs/PERF.md).

`aowl test` runs the host against a stand-in IL2CPP runtime that exports the
same C API as `GameAssembly.dll`, so resolve, call-with-arguments, live objects,
fields and patching are all exercised for real. **What that cannot establish is
that BSG's implementation behaves identically.** Nothing in this repository has
been run against BSG's client; every claim here about "the client" is a claim
about a stand-in that exports the same C API. The one step left is to launch and
read `aowlspt/aowlspt-host.log`.

## The emulator

The game needs a server, and SPT's targets a pre-1.0 client. So there is one
here, and it is **a mod**: `mods/tarkov` imports `aowlspt` and `aowlspt/server`
and nothing else. That constraint is the point — a plugin API is only as good as
the largest thing anyone has written with it, and every gap found while writing
this was closed in the API rather than worked around in the mod.

Profiles, the static tables, traders, trading, the inventory, quests with their
conditions actually evaluated, the hideout and its production queue, raids with
generated loot, bots, scavs, skills, the flea market, mail with redeemable
attachments, insurance. [docs/EMULATOR.md](docs/EMULATOR.md) is what is
implemented, what is refused, and why.

## The overlay and the registry

`registry/mods.json` is one file in one git repository: every mod that exists,
and every named **list** that selects a set of them. A list is a document, so
"my raid night setup" is something you commit and send someone rather than a
screenshot of a folder. `mods/manager` reads it, resolves it against your own
selection, and serves the answer — including *why* a mod is not loading — under
`/aowlspt/mods/...`. See [registry/README.md](registry/README.md).

`host/Aowlspt.Overlay` is the panel that shows you the same thing from inside
the game. Post-1.0 there is no `MonoBehaviour` to attach and no managed UI to
call, so it is drawn by hand from a detour on `IDXGISwapChain::Present` — the
same place Steam and Discord draw. The IL2CPP host starts it after its mods are
up; Insert toggles it. See
[host/Aowlspt.Overlay/README.md](host/Aowlspt.Overlay/README.md).

## Ports

Loopback only, everywhere, and there is no flag to change that.

| | |
|---|---|
| `aowlspt-backend` | 6969 by default (`--port`) |
| `aowl test`, backend self test | 6974, so it cannot pass against a server you already had up |
| `aowl test`, `emutest` | 6975, for the same reason |
| the overlay's backend poll | `backendPort` in `aowlspt-host.json`, beside the host |
| SPT's own server | 6969 — which is why the backend answers there too |

The `aowlspt-host.json` the installer stages carries `waitForRuntimeMs` and no
`backendPort`. Without one the overlay is read-only: it lists what the host
pushed into it, which is what is actually running in that process.

## Tests

```
aowl test
```

The gates, in the order they run: the C header's layout under the real compiler;
nimony's view of the same layout; the C# hosts building; the installer's own
tests; the detour engine; the IL2CPP host loaded directly, then injected into a
live process, then run against the stand-in runtime; the fast path measured
rather than asserted; the backend driven over its own wire framing; the emulator
driven through the client's boot sequence and a restart; every example and every
mod in `mods/` through the simulator.

The second gate is the one that earns its keep. A struct mismatch between the
two sides does not crash — it reads a length as a pointer and fails somewhere
else entirely, under load. So nimony's `sizeof` is checked against the numbers
the real C compiler gives the real header, not against a second copy of the same
arithmetic. It has already caught one error.

The fast-path gate is the second-cheapest thing here and worth naming
separately: a performance claim that is not re-checked is a performance claim
that quietly stops being true.

### Verifying against a real SPT server

`aowlspt-verify-live.ps1` is the one thing here still written in PowerShell. It
drives a real SPT server over its zlib-framed HTTP protocol, which needs an
HTTP client and an inflate that nimony does not yet have; porting it is real
work rather than a translation, and it is called out here rather than quietly
left as an exception.

The simulator cannot prove the SPT-side integration: that SPT's mod loader
accepts the host, that DI hands over the database tables, that a native route
survives SPT's HTTP pipeline. Only a real server shows that.

```
powershell tools/aowlspt-verify-live.ps1 -SptRoot D:\SPT
```

It never writes into your install. It builds a throwaway server from a copy of
`SPT_Runtime` plus `SPT_Data` and an empty `user\`, runs it on its own port so
it can coexist with a server you already have up, and deletes it afterwards
(`-Keep` to inspect). What it asserts:

```
ok    aowlspt host version          SPT's loader accepted the host
ok    loaded Hello / Backend        both nimony DLLs loaded
ok    /aowlspt/hello -> nimony      a native route answered over HTTP
ok    /aowlspt/hello -> echo        the request body survived the round trip
ok    /aowlspt/backend/status       dynamic route, live state
ok    weight 0.38 -> 0.5            the live item database was read AND changed
```

That last line is the one worth having. `dbPatch` returning OK only says the
call succeeded; the mod reads the value back, so the log proves the object graph
actually changed.

### Talking to a route by hand

`curl` will not work, and it is not obvious why. Both servers read every request
body through a zlib stream — the real client always speaks compressed — so a
plain JSON body fails to inflate *before any router is consulted*. SPT answers
200 with an empty body and logs "unsupported compression method", which reads
like a broken mod rather than a malformed request.

`aowlprobe` speaks the protocol to `aowlspt-backend`:

```
aowlprobe http://127.0.0.1:6969/aowlspt/status --expect '"ok":true'
```

`sptprobe` speaks it to SPT:

```
dotnet tools/SptProbe/bin/Release/net10.0/sptprobe.dll   https://127.0.0.1:6969/aowlspt/hello   --body-file body.json --session 000000000000000000000001
```

Two details that cost time to find: the session id must be a 24-character hex
MongoId or the request is rejected before any route sees it, and `--body-file`
exists because Windows PowerShell strips double quotes from arguments to native
executables, which silently corrupts inline JSON.

`aowlspt-backend` accepts an *unframed* request as well, deliberately: the tools
people debug with do not compress, and refusing them would make the server
untestable by hand.

## Taking a mod out

`host/common/modhost.nim` can unload one mod while the host keeps running:
`on_unload`, then a **teardown** the host supplies that drops every route, event
subscription, timer and detour the mod registered, then `FreeLibrary`. The order
is the whole of the danger — a route still in the table after the library is
freed is a call into unmapped memory on the next request — so `unloadOne`
refuses outright unless a teardown has been registered.

No host registers one yet, so today it refuses on both. `mods/manager` probes
for the facility over the event channel, finds nothing, and says so rather than
reporting a mod disabled that is still serving. The interface it is waiting for
is written down in `mods/manager/mgr/control.nim`.

## Regenerating the SPT surface

```
dotnet tools/SptReflect/bin/Release/net10.0/sptreflect.dll D:\SPT\SPT_Runtime \
  --members --json reference/spt-4.1-surface.json
```

Reads assembly metadata only — it never executes SPT code and never writes to
the install. Re-run it when SPT updates; it is how you find out what moved.
