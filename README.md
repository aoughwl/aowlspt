# aowlspt

A modding pipeline for post-1.0 Tarkov, in **aowl/nimony**, front to back: a
native client host, a backend server, one mod ABI, one build command.

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():                      # true once, when the game exists
    info "health " & $Player.get("Health").asFloat()
    discard Player.invoke("Heal", 50)

    discard hook("EFT.Player::OnDead",
      proc (target: string) =
        info "someone died")
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
- Three hosts implementing it — the SPT server, the BepInEx client, and a
  simulator — sharing one engine and differing only in a small
  `IHostServices` surface.
- A **reflection escape hatch**, so nothing in SPT is unreachable just because
  the ABI has not grown a door for it yet.

The ABI is small on purpose. SPT renames types between point releases; a bridge
that names fifty of them breaks every release. This one names eleven database
tables and reaches everything else generically.

## Layout

```
abi/aowlspt_abi.h        the contract; everything else is downstream of it
aowl/src/aowlspt.nim     the mod-authoring library (nimony)
host/Aowlspt.Abi         shared host engine — loading, dispatch, hot reload
host/Aowlspt.Sim         aowlspt-sim: run a mod with no game and no server
host/Aowlspt.Host.Server SPT 4.x server mod that hosts native mods
host/Aowlspt.Host.Client BepInEx plugin that hosts native mods (pre-1.0, Mono)
host/Aowlspt.Host.Il2Cpp native client host for post-1.0 (IL2CPP), in nimony
host/common/modhost.nim  mod loading, shared by both nimony hosts
backend/                 aowlspt-backend: the server, in nimony
installer/               aowlspt-install: build an install from a vanilla one
tools/aowl.nim           aowl: the only build command — build, test, package
tools/SptProbe           sptprobe: call a route with SPT's zlib framing
tools/SptReflect         dump SPT's public API surface
tools/aowllaunch.nim     aowlspt-launch: start the game with the host inside it
tools/il2cppprobe.nim    what a post-1.0 client exposes
tools/hostharness.nim    run the client host with no game
tools/aowlprobe.nim      call a backend route with the game's wire framing
examples/hello           the plumbing, end to end
examples/backend         config, database patching, dynamic routes, `call`
examples/clientprobe     reaching into a post-1.0 client by name
examples/highlevel       the same, through the high-level API
examples/gameserver      routes, database and config on the backend
reference/               SPT's public API surface, dumped per version
tests/                   ABI layout, checked against the C header
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

Hot reload works on the server and client too — the same code path — but only
for mods that declare `flags = {mfHotReloadable}` and implement
`stateSave`/`stateLoad`. A mod that does not is told to restart rather than
silently losing state.

For debugging with gdb or Visual Studio, see [docs/DEBUGGING.md](docs/DEBUGGING.md).

## What a mod can do

| | server | client | sim |
|---|---|---|---|
| `log`, `emit`, `on`, config, `schedule` | yes | yes | yes |
| `route` (HTTP) | yes | — | yes |
| `dbGet` / `dbPatch` | yes | — | yes (from `--db`) |
| `patch` (Harmony) | yes | yes | recorded |
| `call` / `resolve` (reflection) | yes | yes | from `--stubs` |
| `onMainThread` | tick thread | Unity main thread | queue |

A capability a side does not have returns `ErrUnsupported` rather than
misbehaving, so `side()` guards are the normal way to write a mod that ships
everywhere.

`dbPatch` **merges**; it does not replace. Two mods editing sibling fields of
the same item do not clobber each other, which is the difference between a mod
system and a pile of mods that happen to coexist.

## Requirements

- **nimony** built for Windows (see `reference/` notes and the memory entry on
  the Windows toolchain — several fixes were needed and are documented).
- **msys2 ucrt64 gcc** plus `mingw-w64-ucrt-x86_64-lld`.
  `C:\msys64\ucrt64\bin` must precede Git-for-Windows' `/mingw64/bin` on PATH or
  gcc dies with no diagnostic at all.
- **.NET 10 SDK** for the hosts.
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
functions, by name — so `host/Aowlspt.Host.Il2Cpp` is a native DLL that drives
it, with no BepInEx, no Il2CppInterop, no generated proxy assemblies and no
second runtime in the process. `aowlspt-launch` starts the game suspended, puts
the host in it, and resumes.

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
| `hook` / `patch` | x64 code detours: fires however the game reaches the method |
| reading a hook's arguments | not yet — refuses rather than reporting the wrong ones |
| `invoke_main` | the host thread, not Unity's main thread |

Writing one: [docs/MODDING.md](docs/MODDING.md) for the client,
[docs/BACKEND.md](docs/BACKEND.md) for the server. Why there is no BepInEx
underneath, and what a performance port actually costs:
[docs/IL2CPP.md](docs/IL2CPP.md).

`aowl test` runs the host against a stand-in IL2CPP runtime that exports the
same C API as `GameAssembly.dll`, so resolve, call-with-arguments and patching
are all exercised for real. What that cannot establish is that BSG's
implementation behaves identically — the one step left is to launch and read
`aowlspt/aowlspt-host.log`.

## Tests

```
aowl test
```

Five gates: the C header's layout, nimony's view of the same layout, the hosts
building, and a nimony mod driven end to end through the simulator.

The second gate is the one that earns its keep. A struct mismatch between the
two sides does not crash — it reads a length as a pointer and fails somewhere
else entirely, under load. So nimony's `sizeof` is checked against the numbers
the real C compiler gives the real header, not against a second copy of the same
arithmetic. It has already caught one error.

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

`curl` will not work, and it is not obvious why. SPT's HTTP listener reads every
request body through a zlib stream — the real client always speaks compressed —
so a plain JSON body fails to inflate *before any router is consulted*. The
server answers 200 with an empty body and logs "unsupported compression method",
which reads like a broken mod rather than a malformed request. `sptprobe` speaks
the protocol:

```
dotnet tools/SptProbe/bin/Release/net10.0/sptprobe.dll   https://127.0.0.1:6969/aowlspt/hello   --body-file body.json --session 000000000000000000000001
```

Two details that cost time to find: the session id must be a 24-character hex
MongoId or SPT rejects the request, and `--body-file` exists because Windows
PowerShell strips double quotes from arguments to native executables, which
silently corrupts inline JSON.

## Regenerating the SPT surface

```
dotnet tools/SptReflect/bin/Release/net10.0/sptreflect.dll D:\SPT\SPT_Runtime \
  --members --json reference/spt-4.1-surface.json
```

Reads assembly metadata only — it never executes SPT code and never writes to
the install. Re-run it when SPT updates; it is how you find out what moved.
