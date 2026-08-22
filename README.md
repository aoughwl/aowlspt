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
  two native nimony hosts this project runs on — `aowlspt-backend` and the
  post-1.0 IL2CPP client host — and `aowlspt-sim`, a simulator with no game and
  no server behind it. All three are nimony and all three load mods through the
  same `host/common/modhost.nim`.
- A **reflection escape hatch**, so nothing in the game or the server is
  unreachable just because the ABI has not grown a door for it yet.
- A **fast path** beside it, because the escape hatch is general and general is
  slow — see [docs/PERF.md](docs/PERF.md) for the measurement that says by how
  much.

The ABI is small on purpose. SPT renames types between point releases; a bridge
that names fifty of them breaks every release. This one names **none** of them:
the database is addressed by dotted path, the game is reached by string target
through `call`, and `abi/aowlspt_abi.h` says so as its fifth rule. What churns
underneath is data, not a header.

New here? [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the shape of the whole
thing in one document — the two hosts, where C stops and nimony starts, and how
a request and a hook travel end to end.

> **Nothing in this repository has ever been run against BSG's client.** The
> client host has been run against `tests/mockil2cpp`, a stand-in that exports
> the same C API as `GameAssembly.dll`, and against a live process with no
> IL2CPP runtime in it at all. That establishes the mechanism and nothing about
> BSG's implementation of the same API. Every claim anywhere in this repository
> about "the client" is a claim about that stand-in, and every performance
> figure is measured against it. The one step left is to launch and read
> `aowlspt/aowlspt-host.log`.
>
> [docs/BACKLOG.md](docs/BACKLOG.md) collects everything this project says it
> has not done, grouped by *why*, and re-checked item by item against the code —
> including the fifteen open questions that one real session would settle, the
> four things that are broken rather than merely undone, and the sixteen that
> turned out to be finished already.

## Layout

```
abi/aowlspt_abi.h        the contract; everything else is downstream of it
abi/aowlspt_frame.h      the typed patch frame, read field-wise by a mod
abi/aowlspt_shim.h       the indirect calls nimony cannot express, and the host block
abi/aowlspt_detour.h     the x64 inline-detour engine, 16 hook slots
abi/aowlspt_fast.h       the 189 call trampolines behind aowlspt/fast
abi/aowlspt_live.h       arming the live-object and typed-patch entries
abi/aowlspt_notify.h     arming the notifier entry, and the stubs under it
abi/aowlspt_hostboot.h   getting the injected client host running: DllMain, a thread
abi/aowlspt_lock.h       the process-wide lock, and nothing else
abi/aowlspt_inject.h     starting the game suspended and loading the host in
abi/aowlspt_net.h        the backend's sockets: a poller and sixteen workers
abi/aowlspt_overlay.h    the in-game overlay, header-only C

aowl/src/aowlspt.nim     the mod-authoring library (nimony)
aowl/src/aowlspt/game    the high-level client API: types, live objects, hooks
aowl/src/aowlspt/server  the high-level backend API: routes, database, config
aowl/src/aowlspt/json    reading and editing a document without rebuilding it
aowl/src/aowlspt/fast    the per-frame path: bind once, then call
aowl/src/aowlspt/il2cpp  the binding to the runtime's own C API

host/Aowlspt.Sim          aowlspt-sim: run a mod with no game and no server
host/Aowlspt.Host.Il2Cpp  native client host for post-1.0 (IL2CPP), in nimony
host/Aowlspt.Overlay      the in-game mod panel, drawn from inside Present
host/common/modhost.nim   mod loading and unloading, shared by all three hosts
host/common/modstore.nim  the per-mod persistent store (ABI revision 2)
host/common/modcontrol.nim the load/unload control protocol, shared by all three

backend/                 aowlspt-backend: the server, in nimony
installer/               aowlspt-install: build an install from a vanilla one
registry/                mods.json: every mod, and the lists that select them

mods/tarkov              the Tarkov emulator, as a mod
mods/manager             the mod manager: the registry, your lists, what is live
mods/sway                SPT-SWAY, natively
mods/fov                 Fontaine's FOV fix, ported
mods/classicmovement     TheBoogle's Old Tarkov Movement, ported
mods/sain                SAIN, rewritten
mods/perf                engine-level performance settings, and a frame sampler
mods/morebots            the bot-type and faction API other mods build on
mods/blackdivision       a PMC faction, on top of morebots
mods/icebreaker          a map mod

tools/aowl.nim           aowl: the only build command — doctor, build, test, package
tools/aowllaunch.nim     aowlspt-launch: start the game with the host inside it
tools/il2cppprobe.nim    what a post-1.0 client exposes
tools/hostharness.nim    run the client host with no game
tools/aowlprobe.nim      call a backend route with the game's wire framing
tools/bsgwire.py         decode a captured body — the shuffle, the zlib, the AES
tools/bsgaes.py          the AES bsgwire needs, stdlib only, FIPS-197 checked
tools/coverage.nim       aowl-coverage: generate and check EMULATOR-COVERAGE.md
tools/emutest.nim        drive the emulator through the client's boot sequence
tools/realtest.nim       the emulator against a database imported from SPT
tools/livectl.nim        turn a mod off and on again on a running backend
tools/soak.nim           the emulator over a long session, checked by invariant
tools/fuzzwire.nim       what the server does when the client is hostile
tools/wstest.nim         the notifier websocket: does a push reach the session
tools/storecrash.nim     kill the writer mid-commit and demand a whole value
tools/allmods.nim        every mod in the registry, loaded into one backend
tools/modresolve.nim     the manager's resolver, with no process under it
tools/firstrun.nim       a vanilla tree to a serving install, end to end
tools/regcheck.nim       the registry against the mods it claims to describe
tools/verifyinstall.nim  aowlspt-verify: is this install complete, and does it serve
tools/importdb.nim       aowl importdb: a real database, out of an SPT install
tools/release.nim        aowl release: a versioned, verified, reproducible bundle
tools/perfbench.nim      what a client-side call costs, in nanoseconds
tools/benchbackend.nim   what the server costs, in requests per second
tools/SptReflect         dump SPT's public API surface

VERSION                  the release version, and the only place it is written

examples/hello           the plumbing, end to end
examples/backend         config, database patching, dynamic routes, `call`
examples/clientprobe     reaching into a post-1.0 client by name
examples/highlevel       the same, through the high-level API
examples/gameserver      routes, database and config on the backend
examples/lesson          every part of the API, in the order a mod needs it

docs/ARCHITECTURE.md     the shape of the whole thing — start here
docs/INSTALL.md          getting from a vanilla install to a modded one
docs/ABI.md              the contract, and the decisions behind it
docs/MODDING.md          writing a client mod, top to bottom
docs/BACKEND.md          writing a backend mod, and the wire protocol
docs/WIRE.md             what a post-1.0 client actually puts on the wire
docs/IL2CPP.md           why there is no BepInEx underneath the client host
docs/EMULATOR.md         what the Tarkov emulator implements, and refuses
docs/EMULATOR-COVERAGE.md  the gap list: every client operation, served or not
docs/coverage-rows.json  its input: one row per callback method, hand-maintained
docs/IMPORTDB.md         building a real database out of an SPT install
docs/MODMANAGER.md       enabling and disabling mods while everything is running
docs/PERF.md             what a client-side call costs, measured
docs/PERF-SERVER.md      what a request costs, measured
docs/DEBUGGING.md        the three levels, cheapest first
docs/BACKLOG.md          everything not done, triaged: broken, blocked, playtest, open
docs/CAPTURE-GAP.md      the real client's routes against the ones we serve
docs/CAPTURE-TIMELINE.md what the client does, in order, over a whole session
docs/POST1-DATA-DELTA.md the pre-1.0 database against post-1.0's own data
reference/               SPT's public API surface, dumped per version
tests/abi_layout.*       the ABI's layout, checked against the C header
tests/mockil2cpp         a stand-in IL2CPP runtime exporting the same C API
tests/overlayhost        a D3D11 application that stands in for the game
tests/fixtures           a small database the emulator tests buy things out of
```

## The edit loop

**See [DEVLOOP.md](DEVLOOP.md) first** for the client-side loop — the fast path
for "I changed one host file", the deploy check that refuses to ship a binary
with a feature missing, launching and capturing a run without a human, and
reading the host log. The rest of this section is the *mod* loop, which is the
fast one and always has been.

`aowl` is itself a nimony program: the thing that compiles a nimony mod is
written in the language it compiles. The point of `aowlspt-sim` is that this
takes about a second:

```
aowl run examples/hello
```

Leave `aowlspt-sim --watch` open, edit, save, rebuild — the running mod is
unloaded and the new binary is loaded in its place, without restarting the
simulator.

**Reload-on-change is the simulator's facility, not the nimony hosts'.**
`aowlspt-sim --watch` is the one host that watches a library's timestamp; it
unloads the mod through the shared `unloadOne` and loads the rebuilt file.
`aowlspt-backend` and the IL2CPP client host do not watch anything. What all
three have is `unloadOne` — see "Taking a mod out" below — which is the harder
half of it, and which is what live enable/disable is built on.

**Nothing carries a mod's state across a reload yet.** `AowlModApi` has
`state_save`/`state_load` and `exportMod` will fill them in for a mod that
declares `flags = {mfHotReloadable}`, but no host calls either one, so a
`--watch` reload starts the mod from zero. The flag is reported in the mod
manager's `listed` payload and nowhere else. Persist through the store
(`save`/`load`) if the value has to survive.

For debugging with gdb or Visual Studio, see [docs/DEBUGGING.md](docs/DEBUGGING.md).

## What a mod can do

| | backend | client (IL2CPP) | sim |
|---|---|---|---|
| `log`, `emit`, `on`, config, `after`/`every` | yes | yes | yes |
| `save` / `load` / `savedKeys` (revision 2) | yes | yes | yes |
| `route` (HTTP) | yes | — | yes |
| `dbGet` / `dbPatch` | yes | — | yes (from `--db`) |
| `patch` / `hook` | — | x64 detour | — |
| `hookArgs` — arguments, and suppression | — | yes | — |
| `hookReturn` — the postfix, and replacement | — | yes | — |
| `hookTyped` / `hookReturnTyped` (revision 4) | — | yes | — |
| `pointerOf` / `pinHandle` (revision 3) | — | yes | — |
| `notifyPush` — a push down the session's websocket (revision 5) | yes | — | — |
| `call` / `resolve` (reflection) | — | yes | from `--stubs` |
| `aowlspt/fast` — bind once, call per frame | — | yes | — |
| `onMainThread` | the request thread | Unity's, if a per-frame method binds | queue |
| the revision its `AowlHostApi.size` watermark reaches | 5 | 4 | 4 |

A capability a side does not have returns `ErrUnsupported` rather than
misbehaving, so `side()` guards are the normal way to write a mod that ships
everywhere. That is true of the ones *above* a host's watermark too: the backend
and the simulator both fill `pointerOf`, `pinHandle` and `hookTyped` with a
refusal so that `size` can rise past them, which means a capability test says
"there is a function here that will answer" and never "the answer is yes".

`dbPatch` **merges**; it does not replace, and it **creates a path that is not
there**. Two mods editing sibling fields of the same item do not clobber each
other, which is the difference between a mod system and a pile of mods that
happen to coexist; and a mod whose job is adding content — a new location, a new
bot type, a table of its own — can express that instead of carrying a
workaround.

`onMainThread` on the client is conditional and says which it gave you. There is
no API that hands a native DLL Unity's player loop, so the host detours a method
Unity runs every frame and drains the queue from inside it; if none of its
candidates binds, it warns at boot and falls back to its own thread. A mod can
ask with `call("aowlspt.host::main_thread")`, and `bound` is true only once the
hook has actually fired. See [docs/IL2CPP.md](docs/IL2CPP.md).

## Requirements

- **nimony** built for Windows (see `reference/` notes and the memory entry on
  the Windows toolchain — several fixes were needed and are documented).
- **msys2 ucrt64 gcc** plus `mingw-w64-ucrt-x86_64-lld`.
  `C:\msys64\ucrt64\bin` must precede Git-for-Windows' `/mingw64/bin` on PATH or
  gcc dies with no diagnostic at all.
- **.NET 10 SDK** for `SptReflect`, the one C# program left. It reads SPT's
  assembly metadata, which is why it stays managed; every host here is nimony.
- An **SPT 4.1.x install** to compile the server and client hosts against. It is
  read for metadata only.
- A **Tarkov install** for `aowlspt-install` to work from. It is only ever read;
  see "Installing" below.

```
aowl doctor
```

checks all of that before it can waste an afternoon: nimony, ucrt64 gcc, `lld`,
the ABI headers, whether the build caches still match those headers, and **PATH
order** — the one that is worth the whole command on its own, because a
Git-for-Windows `mingw64` ahead of ucrt64 gives gcc a `cc1` that loads the wrong
libgcc and dies with no diagnostic at all. Every check in it is there because
something went wrong once and pointed somewhere else while it did.

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

### Cutting a release

```
aowl release                 # dist/aowlspt-<version>-<date>.zip + .sha256
aowl release --check-only    # run every gate, write nothing
aowl release --mod sway      # one mod, in the layout SPT 4.x needs
```

The version lives in `VERSION` at the repo root and nowhere else; the archive
name, the manifest, the changelog and the payload's own `version` are all
derived from it.

A release refuses to be built rather than shipping something broken: every mod
the registry names must have a library staged **and** that library must be named
after its directory, because the host finds a mod by scanning for
`<dir>/<dir>.dll` and a wrongly named one installs as a directory nothing loads,
silently. `aowl-regcheck` and `aowlspt-verify --offline --staged` both have to
pass first. Then the archive it just wrote is opened again and checked from its
own central directory — the shape is verified against the file, not against the
list the writer was handed.

Archives are byte-identical across runs (stored entries, fixed timestamps,
sorted names, and no build time inside), so two people building the same tree
can compare hashes. The changelog is generated from the registry and the
previous release's mod list rather than written by hand, which is why it cannot
drift.

The imported Tarkov database is never in a release: it is BSG's data by way of
SPT's, and it is produced locally from your own install.

Step by step, including what to do when one of these refuses:
[docs/INSTALL.md](docs/INSTALL.md). How the installer itself works:
[installer/README.md](installer/README.md).

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

**The client this produces must never talk to the live service.** The installer
does not carry BattlEye across and the launcher does not start it, because the
modded client plays against a backend on your own machine. Injecting a DLL into
a process that is talking to BSG's servers is a decision with consequences for
your account; these tools will not stop you pointing the client somewhere else,
and they will not help you either.

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
| adjusting what it returned | yes, `hookReturn` — the postfix, on a method whose shape can carry one |
| a hook on the per-frame path | `hookTyped` / `hookReturnTyped`: the saved registers instead of JSON, 23–37 ns against 645–1615 |
| a hook's object, on the fast path | `pointerOf` turns a handle into an address; `pinHandle` keeps one, at the stated cost |
| the fast path | bind a method or field once, then call it for ~10 ns |
| the overlay | drawn from inside `Present`; Insert toggles it |
| `invoke_main` | Unity's main thread when a per-frame method could be detoured; the host's own otherwise, and it says which |

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
up; **F12** opens it (the settings key). See
[host/Aowlspt.Overlay/README.md](host/Aowlspt.Overlay/README.md).

## In-game settings (F12) and the config schema

F12 opens an in-game settings panel. A mod declares its settings once with the
`aowlspt/settings` API — `declareSettings(@[floatSetting(...), boolSetting(...),
keybindSetting(..., implemented = false)])` — and the panel draws the right
control per value, marks anything aowlspt does not yet back **not implemented
yet**, persists edits back to `config.json`, and hot-applies them. The same
screen carries the Tarkov emulator's own settings and the full SPT server config
surface (`reference/spt-config-settings.json`, 28 pages / 323 values). The panel
is the hand-drawn overlay rather than Tarkov's real IL2CPP settings screen,
because live managed UI construction crashes this client — the full reasoning,
the reverse-engineering of the real screen, and the schema API reference are in
[docs/SETTINGS.md](docs/SETTINGS.md).

## Ports

Loopback only, everywhere, and there is no flag to change that.

| | |
|---|---|
| `aowlspt-backend` | 6969 by default (`--port`) |
| `aowl test`, backend self test | 6974, so it cannot pass against a server you already had up |
| `aowl test`, `emutest` | 6975, for the same reason |
| `aowl test`, `soak` | 6976 |
| `aowl test`, `fuzzwire` and `benchbackend` | 6977 |
| `aowl test`, `realtest` | 6978 |
| `aowl test`, `livectl` | 6979 |
| `aowl test`, `allmods` | 6980 |
| `aowl test`, `wstest` | 6982 |
| `firstrun`, by hand | 6990, and the two after it |
| the overlay's backend poll | `backendPort` in `aowlspt-host.json`, else the port in `backend.json` |
| SPT's own server | 6969 — which is why the backend answers there too |

Every gate gets a port of its own so that none of them can pass against a
server somebody already had running, and so that two of them cannot collide
when the suite is run twice at once.

The `aowlspt-host.json` the installer stages carries `waitForRuntimeMs`,
`backendPort: 0` and `modSyncMs`, each with a line above it saying what it is
for. A `backendPort` of 0 means "do not ask", and the host then falls back to
the port named in `backend.json` — the file the *installer* writes, naming the
backend it just installed — so an ordinary install reaches its own server
without anyone editing anything.

With neither, the overlay is read-only: it lists what the host pushed into it,
which is what is actually running in that process, and the client host cannot
ask the server which mods should be running either, so a mod you switch off
takes effect when the game next starts.

With a `backendPort`, the client host also polls `/aowlspt/mods/client` every
`modSyncMs` (default 3000, `0` switches it off) and loads or unloads client-side
mods to match what the manager decided — while the game is running. Only mods
the registry names are touched; a dll dropped into `mods/` by hand is listed
once in the host log and then left alone. A backend that is down, starting or
answering anything unexpected changes nothing at all.

## Tests

```
aowl test
```

The gates, in the order they run: the C header's layout under the real compiler;
nimony's view of the same layout; the installer's own tests; the detour engine;
the IL2CPP host loaded directly, then injected into a live process, then run
against the stand-in runtime; the fast path measured rather than asserted;
nothing the host holds growing with the cycle count; the mod manager's resolver,
manifest reader and selection reader with no process under them; the backend
driven over its own wire framing; the emulator driven through the client's boot
sequence and a restart, and again against a database imported from a real SPT
install if one is present; the server given input no client would send; the
notifier websocket holding a connection and pushing down it; the emulator over a
long session, checked by invariant; the backend's throughput against a floor; a
mod disabled and enabled while the server is serving; every mod in the registry
loaded into one backend at once; the store's writer killed mid-commit; every
example and every mod in `mods/` through the simulator; and the registry checked
against the mods it claims to describe.

The second gate is the one that earns its keep. A struct mismatch between the
two sides does not crash — it reads a length as a pointer and fails somewhere
else entirely, under load. So nimony's `sizeof` is checked against the numbers
the real C compiler gives the real header, not against a second copy of the same
arithmetic. It has already caught one error.

The fast-path gate is the second-cheapest thing here and worth naming
separately: a performance claim that is not re-checked is a performance claim
that quietly stops being true.

### Verifying a real install

The simulator cannot prove the integration: that an installed tree is coherent,
that the backend starts out of it, that a native route survives the wire. Only a
real install, driven over the real protocol, shows that.

`aowlspt-verify` is that check, and it is nimony like everything else
(`tools/verifyinstall.nim`, built by `aowl build` into
`installer\build\aowlspt-verify.exe`). It replaced two PowerShell scripts that
stood up a throwaway *SPT* server; the sandbox is gone with them, because SPT's
server targets a pre-1.0 client and the backend is ours now. What survived is
the shape of the check: stand up the real server, over the real wire, and ask it
things.

```
installer\build\aowlspt-verify.exe --root D:\Aowlspt
installer\build\aowlspt-verify.exe --root D:\Aowlspt --offline   # files only
```

It writes only inside `<root>\aowlspt`, and only what the backend itself writes
when it runs. It refuses to start anything when `<root>\aowlspt\aowlspt-backend.exe`
is not there, which is the same as saying it will not run against somebody
else's game directory. What it asserts:

```
ok    there is a Tarkov client here     and it is post-1.0, and IL2CPP
ok    the client host is installed      host, launcher and backend all present
ok    mod tarkov has its library        a mod directory is not an empty one
ok    the registry declares a schema this build knows
ok    the backend starts / answers      spawned on a spare port, over the wire
ok    the emulator serves /client/game/config
ok    a request body survives the round trip
ok    the profile store answers
ok    an unknown route is refused rather than hung
```

`installer\build\aowlspt-install.exe verify` is a different check and both are
worth having: that one asks whether the files the installer wrote are still
where it left them, from the uninstall manifest. This one asks whether what is
there adds up to a working install, and then talks to it.

### Talking to a route by hand

`curl` will not work, and it is not obvious why. The server reads every request
body through a zlib stream — the real client always speaks compressed — so a
plain JSON body fails to inflate *before any router is consulted*, and what
comes back is a 200 with a body the caller cannot read: a malformed request
that presents as a broken mod.

`aowlprobe` speaks the protocol to `aowlspt-backend`:

```
aowlprobe http://127.0.0.1:6969/aowlspt/status --expect '"ok":true'
```

One detail that cost time to find: the session id must be a 24-character hex
MongoId, or the request is rejected in `aowlbackend.nim` before any route sees
it — so a malformed id is never reported as some mod's bug.

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

All three hosts supply one. `aowlspt-backend` installs
`dropModRegistrations` (routes, subscriptions, timers) before it loads a single
mod; the IL2CPP host owns its own (subscriptions, pending main-thread callbacks
under the drain's lock, and detours); `aowlspt-sim` has a third. All are wired to
`host/common/modcontrol.nim`, which answers `mods/manager`'s control protocol
over the event channel, so **a mod can be enabled or disabled while the server
is serving** — and, on the client, while the game is running. What is refused,
what is deferred to a restart, and what has never been run against BSG's client:
[docs/MODMANAGER.md](docs/MODMANAGER.md).

`aowl test` proves the server half every run: `tools/livectl.nim` disables a mod
on a live backend, checks its routes are gone from the router while the mods
beside it keep answering, enables it again, and checks the mod that came back is
a fresh instance.

## Regenerating the SPT surface

```
dotnet tools/SptReflect/bin/Release/net10.0/sptreflect.dll D:\SPT\SPT_Runtime \
  --members --json reference/spt-4.1-surface.json
```

Reads assembly metadata only — it never executes SPT code and never writes to
the install. Re-run it when SPT updates; it is how you find out what moved.
