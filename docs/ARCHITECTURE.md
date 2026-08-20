# The shape of aowlspt

Thirteen other documents in this repository each explain one piece well. This one
explains how they fit, for someone who has not seen the project before. It says
what the parts are, where the boundaries fall and why they fall there, and it
traces a request and a hook end to end. Everything here is checkable against the
source; where a number came from a tool, the tool is named.

> **Nothing in this repository has ever been run against BSG's client.** The
> client host has been exercised against `tests/mockil2cpp`, a stand-in that
> exports the same C API as `GameAssembly.dll`, and against a live process with
> no IL2CPP runtime in it at all. That establishes the mechanism. It does not
> establish that BSG's implementation of the same API behaves identically, and
> nothing in this document should be read as claiming otherwise. Every
> performance figure below is against the stand-in.

## The one-paragraph version

A **mod** is a native `.dll` that exports three C functions. A **host** is
whatever loads it. There are two hosts that matter: `aowlspt-backend`, a
nimony HTTP server that answers the game client, and
`host/Aowlspt.Host.Il2Cpp`, a nimony DLL injected into the running game
process. Both implement the same C ABI, `abi/aowlspt_abi.h`, and refuse the
capabilities they cannot honestly provide rather than faking them. **The Tarkov
server is itself a mod** — `mods/tarkov`, on the same ABI as everyone else's —
and that is the design decision the rest of this follows from.

```
                       abi/aowlspt_abi.h
                     the one contract, C only
                               |
        +----------------------+----------------------+
        |                      |                      |
  aowlspt-backend      Aowlspt.Host.Il2Cpp      aowlspt-sim
  (nimony process)     (nimony DLL, injected)   (nimony, no game)
        |                      |                      |
   routes, db,          resolve/call, hooks,      routes, db, store,
   store, events        fast path, store          events; refuses the rest
        |                      |
  mods/tarkov            mods/sway, fov,
  mods/manager           classicmovement,
  (server side)          sain, perf, ...
                         (client side)

  the game client  <--HTTP, zlib both ways-->  aowlspt-backend
```

## Why a C ABI at all

SPT 4.x moved its server to C#/.NET 10, so the obvious answer would be to write
mods in C#. This project does not, for one reason: **the same compiled mod
should run everywhere, and it should be debuggable without launching Tarkov.**
A C# mod is welded to a managed host; the post-1.0 game has no managed host to
weld it to.

So there is one narrow interface that neither side's language leaks through.
`abi/aowlspt_abi.h` states it and [ABI.md](ABI.md) explains the decisions. Five
rules govern it, and each names a failure it prevents:

1. **C only.** No C++, no name mangling, no exceptions across the boundary.
   Every cross-boundary function is `cdecl` and returns a status code.
2. **One allocator, the host's.** Two separately linked modules need not share a
   CRT heap — a mingw-built DLL and a .NET host certainly do not. A buffer
   allocated on one side and freed on the other is a crash in some unrelated
   place, later, under load.
3. **Borrowed in, owned out.** An `AowlSlice` argument is valid for that call
   only; to hand data back you fill an `AowlBuffer` from the host allocator and
   the receiver frees it.
4. **Additive versioning.** Every struct carries its own `size` first. Fields
   are appended, never inserted or reordered, and a peer checks `size` before
   touching anything added later.
5. **No SPT types in the header.** SPT renames types between point releases; a
   bridge naming fifty of them breaks every release.

The ABI is at **version 1, revision 5** (`AOWLSPT_ABI_VERSION`,
`AOWLSPT_ABI_REVISION` in `abi/aowlspt_abi.h`). The version is the breaking
counter and a host refuses a mod whose version differs before running a line of
its code; the revision counts appended capabilities:

| revision | what it added | `sizeof(AowlHostApi)` |
|---|---|---:|
| 1 | logging, config, the database, routes, events, `call`/`resolve`, `patch`, scheduling | 168 |
| 2 | `store_get` / `store_set` / `store_list` — a private key/value store per mod | 192 |
| 3 | `handle_pointer` / `handle_pin` — a live object's *address*, for a mod's own fast path | 208 |
| 4 | `patch_typed` — a hook handed the saved registers instead of JSON | 216 |
| 5 | `notify_push` — a notification to a session, over the game's notifier websocket | 224 |

Those sizes are not decoration. `AOWLSPT_HOSTAPI_SIZE_REV1..REV5` name each
revision's boundary as an `offsetof`, and a mod tests a capability against the
boundary it appeared at rather than against `sizeof(AowlHostApi)` — which is
right exactly once and then quietly wrong the next time the struct grows.
`tests/abi_layout.c` pins every one of them under the real compiler and
`tests/abi_layout.nim` asserts nimony agrees; both are the first two gates of
`aowl test`.

Revision 5 is where `size` being a *watermark* stopped being free, and it is
worth a paragraph because it changes what a capability test means. Only the
client host can fill revisions 3 and 4 — they need a managed heap and a detour
engine — and only the backend can fill revision 5, which needs a listening
socket. One integer cannot say "the fifth and not the third". Reporting revision
2 would hide `notify_push` from the mod that needs it; reporting revision 5 over
three null pointers would tell a mod to call them, and there is no null check
available to save it, because nimony will not cast a proc field to a pointer to
compare it against null — which is *why* every capability test here is a size
test. So the backend fills the three entries under its watermark with the
refusal it already owed (`AOWLSPT_ERR_UNSUPPORTED`, exactly what those calls
already returned) and only then raises `size`. A boundary test therefore means
"there is a function here that will answer", which is all it ever established.
[ABI.md](ABI.md) has the argument and the alternative that was not taken.

## The three exports, and what a mod is

Every mod library exports exactly three symbols, and the host calls them in
order:

```c
uint32_t   aowlspt_abi_version(void);                              /* cheapest reject; runs no mod code */
AowlStatus aowlspt_describe(AowlModInfo* out);                     /* metadata, before any host service */
AowlStatus aowlspt_init(const AowlHostApi* host, AowlModApi* out); /* the mod may now call back */
```

`exportMod` in `aowl/src/aowlspt.nim` writes all three. A mod's `AowlModInfo`
declares which **sides** it supports — `sideServer`, `sideClient`, `sideSim` —
and a host skips a mod that does not claim its side before `on_load` ever runs.
The rest of a mod is `on_load`, `on_update`, `on_unload`, and optionally
`state_save`/`state_load` — which are in the header and in `exportMod`, and
which **no host calls today**: a `--watch` reload starts the mod from zero, and
anything worth keeping goes in the store.

`host/common/modhost.nim` is the loader, and both nimony hosts share it:
discovery, the version probe, `describe`/`init`/`on_load`, the mod table, and
`unloadOne`. The client host used to carry its own copy of all of it.

What loads, and in what order, comes from `aowlspt-selection.json` — the
document the mod manager resolves and writes. `loadAll` reads it before it opens
anything, matches each id to a library by asking that library what it calls
itself (`describe`, without initialising it), and starts only the mods it names,
in the order it names them. **Absent, unreadable, written for another side, or
naming nothing, it walks the directory and loads everything** — a fresh install
has no such file, and a host that loaded nothing because a file was missing
would be far worse than one that loaded too much. [MODMANAGER.md](MODMANAGER.md)
has the table of cases and why the empty one is a refusal rather than a choice.

## The three hosts

|  | `aowlspt-backend` | `Aowlspt.Host.Il2Cpp` | `aowlspt-sim` |
|---|---|---|---|
| language | nimony | nimony | nimony |
| where it lives | its own process | injected into `EscapeFromTarkov.exe` | its own process |
| `route_register`, `db_get`/`db_patch` | yes | `ErrUnsupported` | yes (`--db`) |
| `resolve` | `ErrUnsupported` | yes, by name, against IL2CPP | a name, no runtime behind it |
| `call` | `ErrUnsupported` | yes, by name, against IL2CPP | canned from `--stubs`, else `ErrUnsupported` |
| `patch` / `patch_typed` | `ErrUnsupported` | yes, x64 inline detour | `ErrUnsupported` |
| `handle_pointer` / `handle_pin` | filled, refusing | yes | filled, refusing |
| `notify_push` | yes | not present — `size` stops below it | not present — `size` stops below it |
| `store_get` / `store_set` / `store_list` | yes | yes | yes |
| events, timers, config, log | yes | yes | yes |
| reload one mod on a file change | no | no | yes (`--watch`) |
| unload one mod live | yes | yes | yes |
| the revision its `AowlHostApi.size` watermark reaches | 5 (224) | 4 (216) | 4 (216) |

A capability a host does not have returns `AOWLSPT_ERR_UNSUPPORTED` rather than
misbehaving, so `side()` guards are the ordinary way to write a mod that ships
everywhere.

The last row is worth reading carefully, and it is the row a mod must read
rather than `AowlHostInfo.abi_revision` — which is `AOWLSPT_ABI_REVISION` from
the header the host was compiled with, and is therefore **5 on all three**.
`size` is the one that answers the question a mod is actually asking: *how much
of this struct did I fill*, not *which header did I compile against*.
`aowl_hostapi_new` (in `abi/aowlspt_shim.h`) builds the block for every nimony
host and reports the revision-2 size — 192, the last boundary every host can
honour with nothing but its own process. Each host then **arms only the part it
owns**, and the two real hosts own disjoint parts:

- the IL2CPP client host calls `aowl_hostapi_arm_live` and then
  `aowl_hostapi_arm_typed` (`abi/aowlspt_live.h`, which only it includes) to
  publish `handle_pointer`, `handle_pin` and `patch_typed` for real, ending at
  216;
- the backend calls `aowl_hostapi_arm_notify` (`abi/aowlspt_notify.h`, which
  only it includes) to publish `notify_push` for real — and, because it must
  raise `size` past three entries it cannot honour, installs
  `AOWLSPT_ERR_UNSUPPORTED` stubs for those three first, ending at 224;
- `aowlspt-sim` does the same trick for the same reason with
  `aowl_hostapi_arm_sim` (`host/Aowlspt.Sim/aowlsim.nim`): three refusing
  stubs, `size` raised to 216, and a stop there because revision 5 is
  `notify_push` and there is no websocket in a simulator.

In all three the ordering is the invariant: the pointers go in first and `size`
rises last, so the watermark is never larger than the part of the struct that
has been filled. And in all three, a capability test therefore means "there is a
function here that will answer" and never "the answer is yes" — which is all a
null check could ever have established either.

**The backend cannot reflect and cannot patch** because there is no managed
runtime and no compiled game code in its process to reflect into or detour.
**The client host cannot serve routes or read the database** because those are
the server's. Neither is a gap waiting to be filled; each is the honest answer
for that process.

`aowlspt-sim` exists so that the edit loop is a second rather than several
minutes. It was C# until it was rewritten as `host/Aowlspt.Sim/aowlsim.nim`,
and the rewrite is why it has a store: it loads mods through the same
`host/common/modhost.nim` the other two use and answers `store_*` out of the
same `host/common/modstore.nim` the backend writes profiles with, so a mod that
persists anything — `mods/tarkov` above all — can be simulated at all. What
differs from a real host is only what sits under the host API: no managed
runtime, so `call` is scripted or refused, and no compiled game code, so
`patch` is refused.

It is also the only host that reloads a mod when its library changes on disk
(`--watch`); the other two unload, which is the harder half and what live
enable/disable is built on.

## Where the language boundaries fall

Almost everything is nimony. C appears in exactly the places nimony cannot
reach, and each of those is one header under `abi/`:

| header | what it is, and why it is C |
|---|---|
| `aowlspt_abi.h` | the contract itself. C because it is the thing two languages have to agree on. |
| `aowlspt_shim.h` | the indirect calls nimony cannot express — it refuses to `cast` between a `pointer` and a `proc`. |
| `aowlspt_fast.h` | 189 call trampolines. Calling an IL2CPP-compiled method directly is a function-pointer call *with the right type*, and C needs that type at compile time while a mod only knows it at bind time. So the space is enumerated: on Win64 a parameter's type only decides which register file it lands in, which collapses to two kinds per slot, five slots, three return forms. |
| `aowlspt_detour.h` | the x64 inline-detour engine: a length decoder, a trampoline, and **one** assembly thunk shared by all 256 hook slots (`AOWL_MAX_HOOKS`). Hand-written assembly is not something nimony emits. This row said "a fixed pool of 16 assembly thunks" until the thunks were replaced by one common thunk entered with the firing's own site record in R11; sixteen was never a budget, it was how many `aowl_thunk_N` macro expansions fitted on a screen. |
| `aowlspt_frame.h` | the typed patch frame. A struct rather than accessor function pointers, because it is read inside a method the game may run per entity per frame. |
| `aowlspt_net.h` | the backend's sockets: `WSAPoll`, the connection table, zlib, the per-session lock table, and websocket frame boundaries. The websocket *handshake* is not here — it is SHA-1 and base64, which nimony ships. |
| `aowlspt_overlay.h` | the in-game panel, drawn from a detour on `IDXGISwapChain::Present`. Header-only C, D3D11. |
| `aowlspt_inject.h` | starting the game suspended, `LoadLibrary` in the remote process, resuming. |
| `aowlspt_live.h` | arming the revision-3 and revision-4 entries of `AowlHostApi`, included only by the host that can honour them. |
| `aowlspt_notify.h` | arming revision 5 the same way, included only by the backend — plus the refusing stubs that let one integer say "the fifth and not the third". |
| `aowlspt_lock.h` | the process-wide lock, and nothing else. |
| `aowlspt_hostboot.h` | starting the client host from inside the game: a C constructor that does nothing but `CreateThread`, because a constructor runs under the loader lock and nimony's `--app:lib` output already owns `DllMain`. |

(That table listed eleven headers and `abi/` has held twelve since
`aowlspt_hostboot.h` was split out; the twelfth row was added 2026-08-19.)

`aowlspt_lock.h` is worth one sentence as an example of the habit: it was split
out of `aowlspt_net.h`, which begins with `winsock2.h` and `zlib.h`, so anything
that wanted a critical section was linking a socket library and a compression
library to get one. That is tolerable in the backend and wrong in a DLL injected
into a game. Splitting it changed no declaration and no field order, so the ABI
revision did not move — rule 4 is about the interface, not about which header a
`static` function lives in.

Everything in `abi/` other than the contract is `static` and gets included into
the single translation unit nimony emits.

**What is generated**, and by what:

- The mod entry points, by the `exportMod` macro in `aowl/src/aowlspt.nim`.
- `reference/spt-4.1-surface.json` and `.txt`, by `tools/SptReflect` — SPT's
  public API surface, read from assembly metadata. It never executes SPT code
  and never writes to the install. Re-run it when SPT updates; it is how you
  find out what moved.
- `build/db/db.json`, by `aowl importdb --from D:\SPT` — the real game's tables,
  out of an SPT install you already own. It is never committed and never in a
  release. See [IMPORTDB.md](IMPORTDB.md).
- The 189 trampolines in `aowlspt_fast.h` were enumerated once and are checked
  in; there is no generator step in the build.
- The generated regions of `docs/EMULATOR-COVERAGE.md`, by
  `tools/coverage.nim` (`aowl-coverage`). It computes the four sweeps that
  document's "How it was derived" section states — in nimony, by reading
  `reference/spt-4.1-surface.txt` and `mods/tarkov` — and it derives the
  served / empty / absent split from `docs/coverage-rows.json`, one row per
  callback method, joined against the routes `mods/tarkov/tarkov.nim` actually
  registers. The row file is the only hand-maintained half and it is
  cross-checked both ways: a route no row names, a row naming a route nothing
  serves, a callback method with no row and a row naming no callback method are
  all errors. `aowl test` runs `aowl-coverage --check`, which writes nothing and
  fails if the document on disk is stale. The prose around the two marked
  regions is hand-written and the generator never touches it.

## The server: a poller, sixteen workers, and a lock per session

`aowlspt-backend` listens on loopback only, and there is no flag to change that.
A single-player game server that binds every interface by accident is how a LAN
party becomes an incident.

The shape is one **poller** thread and a fixed pool of **sixteen** request
workers (`AOWL_NET_WORKERS`, `abi/aowlspt_net.h`). The poller owns the listening
socket and every connection that is not currently being answered; it sits in
`WSAPoll`, accepts, and reads. A connection reaches a worker only when a
*complete* request is buffered — headers and the whole declared body — and goes
back to the poller when the answer has gone out.

That division is the whole point. A worker used to be taken at `accept` and
given back at `close`, and keep-alive means a connection lives for a session, so
the pool size *was* the number of connections the server could have: twelve
sockets that declared a body and never sent it shut every other client out. Now
a connection that stalls, dribbles, or opens and says nothing never touches a
worker at all. **The bound is sockets and memory, not threads** —
`AOWL_NET_MAX_CONNS` is 1024 and `AOWL_NET_MAX_BUFFERED` is 64 MiB, and buffers
are allocated on the first byte received rather than on accept. `fuzzwire` holds
256 stalled connections open in three shapes and times an ordinary request
behind them; it arrives in 0 ms.

`WSAPoll` rather than IOCP is a stated trade, written at the head of
`aowlspt_net.h`: an O(connections) scan per wakeup and one thread doing all the
reads, against turning "have I got a whole request yet" into a set of
completions with a buffer lifetime attached to each — the bug class this file
must not have.

There are three receive deadlines rather than one timeout, because one number
could not be right for all three: `AOWL_IDLE_MS` 5 s between requests on a
kept-alive connection, `AOWL_HEAD_MS` 3 s from the first byte to a complete
header, `AOWL_BODY_MS` 5 s from there to a complete body. Idle is what a
kept-alive connection is *for*; idle mid-request is a stall. The poller holds
the clock, so a stalled connection wakes nobody.

**Request handling is serialised per session id.** A route handler on this
server is a read-modify-write of a whole profile document, and two requests
carrying the same session used to run that concurrently and lose one — six
concurrent purchases each answered `err:0`, three rifles delivered. Dispatch now
takes a lock from a fixed table of 128 slots keyed on the exact session id
(`aowl_session_lock` / `aowl_session_unlock`, `abi/aowlspt_net.h`), across the
*whole* callback rather than around the store call. Two profiles do not wait on
each other; a route with no session takes no lock; the lock is released before
the connection waits for its next request. A handler that never returns holds
its own session and nothing else, and a request that cannot get the lock within
ten seconds is answered `503` rather than pinning a worker for good.

Bodies are **zlib-framed in both directions** — the real client always speaks
compressed. A server that answers plain JSON gets a client that fails to parse
it, with a 200 on both sides and nothing in either log, which is why `curl`
cannot tell a working route from a broken one and why `tools/aowlprobe.nim`
exists. Unframed *requests* are accepted anyway, deliberately: refusing them
would make the server untestable by hand, and the check is the two-byte zlib
header rather than a guess.

The session id must be a 24-character hex MongoId and is rejected before any
route sees it, so a malformed id is never reported as some mod's bug.

[BACKEND.md](BACKEND.md) is the writer's guide and [PERF-SERVER.md](PERF-SERVER.md)
is how it got fast, one change at a time.

## The client host: no BepInEx, no second runtime

Tarkov 1.0 changed the client's scripting backend from Mono to IL2CPP. There are
no managed assemblies any more, only `GameAssembly.dll` and an encrypted
`global-metadata.dat`. Nothing built for Mono loads into it, and SPT 4.1.2
targets a pre-1.0 build — which is why the usual advice is to roll a current
client backwards. **This project's installer refuses to do that, and `--force`
does not enable it.** A downgrade across a major release replaces the client's
assemblies and asset bundles with an older game's; the game you play is then not
the game you own.

The expected alternative is BepInEx 6 IL2CPP: a CoreCLR inside the process,
Cpp2IL reconstructing proxy assemblies from metadata, and Il2CppInterop
marshalling between the proxies and the real objects — a second runtime, a
code-generation step per game update, and a marshalling layer, to arrive back at
"call a method by name".

None of it is necessary, because **Unity's IL2CPP runtime exports its whole C
API from `GameAssembly.dll`, by name and unmangled**. On the client
`tools/il2cppprobe.nim` was run against, 242 functions. `il2cpp_class_from_name`,
`il2cpp_class_get_method_from_name`, `il2cpp_runtime_invoke`,
`il2cpp_field_get_offset` — that is the shape the ABI already wanted. So the host
is a native DLL that drives the runtime directly, written in the same language
as the mods it hosts. `aowl/src/aowlspt/il2cpp.nim` is the binding.

It does **not** read `global-metadata.dat`. BSG ship it encrypted and the runtime
decrypts it for itself during `il2cpp_init`; going around that would be breaking
a protection rather than using an interface. One consequence: the runtime cannot
be started outside the game, so type resolution has to happen in-process, which
is what the host is for.

`tools/aowllaunch.nim` starts the game suspended, `LoadLibrary`s the host into
it, waits for the remote thread and reads its exit code, then resumes. It
terminates the client rather than resuming one whose host failed to load —
being in a raid before noticing the mods are missing is worse than not starting.

**Which thread a mod gets is conditional, and the host says which.** There is no
API that hands a native DLL Unity's player loop, so the host detours a method
Unity runs once per frame and drains `invoke_main`'s queue from inside it,
trying `EFT.MainApplication::Update`, then `EFT.GameWorld::Update`, then
`UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate`, then reluctantly
`UnityEngine.Time::get_deltaTime`. If none binds, the queue is drained by the
host's own thread and the host warns at boot. A mod asks with
`call("aowlspt.host::main_thread")`, and `bound` is true only once the hook has
actually *fired* — a hook that is installed but never reached has proved
nothing. None of this has been seen against BSG's client; which candidate binds
there is exactly what a stand-in cannot answer.

**Three threads touch the client host's tables**, and one lock guards them.
The host's own tick loop loads and unloads mods; the game's thread runs every
patch firing and the per-frame drain; and any thread a mod creates may call
`resolve`, `call`, `handle_release`, `event_subscribe` or `patch`. The handle
table and its free queue, the subscription list, the rows of the patch table and
the main-thread queue are all taken under the one process-wide critical section
in `abi/aowlspt_lock.h` — coarse on purpose, for the reason that header gives.

**The firing path is deliberately off it.** A detour fires on the game's thread
thousands of times a second, and an uncontended `EnterCriticalSection`/
`LeaveCriticalSection` pair is of the same order as the whole ~24 ns of a typed
prefix firing (the table below) — so guarding it would cost most of what the
typed path was built to save. It takes no lock, and is made safe by construction instead: it touches
no host table at all, and `gPatches` is filled to the detour engine's full slot
capacity once at startup (`reservePatchRows`) so the backing array can never
move under a firing. The JSON firing path *does* register a GC handle per
reference argument, and it does take the lock for exactly that — around the
describe and around the reclaim, never around the call into the mod — where it
is a few percent of a path that already costs ~640 ns. What the client host
costs per *frame*, as opposed to per firing, is measured in
[PERF.md](PERF.md), "What the host costs per frame"; this page deliberately does
not carry a second copy of those figures.

What is still unguarded and known to be: `modhost.gMods`, which grows on the
tick thread and is read from mod threads. The lock for it belongs in `modhost`,
which the backend shares, so the client host cannot add it alone.

[IL2CPP.md](IL2CPP.md) is the whole of it.

## The two paths into the game, and why there are two

**The boxed path** is `AowlHostApi.call`: name a target as a string, pass
arguments as JSON, get JSON back. Underneath, the host resolves the type by
walking every loaded assembly, finds the method by name and arity, parses the
JSON, asks the runtime for each declared parameter type, boxes each argument,
calls `il2cpp_runtime_invoke`, unboxes a heap-allocated return, and formats it
back. Every step buys the generality, and the generality is the point: this is
how a mod reaches a corner of the game the ABI has not grown a door for, with a
target it might have read out of its own config file.

**The fast path** is `aowl/src/aowlspt/fast.nim`. A mod *binds* a method or a
field once and holds a small handle; a bound call packs up to five 8-byte slots,
switches on a packed byte, and makes one indirect call to the function IL2CPP
compiled. A bound field read is a load from `object + offset`. No name lookup,
no allocation, no JSON — and **no crossing the ABI at all**, because a mod DLL is
in the same process as the runtime, so `openIl2Cpp()` binds `GameAssembly.dll`
directly and the host is simply not on the path.

Measured by `tools/perfbench.nim` against `tests/mockil2cpp`: a boxed call is
956–1217 ns and a bound one is 6.0–10.2 ns; a boxed field read through a
property getter is 43 ns and a bound field read is 1.87 ns. Binding costs
1–12 µs, almost all of it `findClass` walking every assembly, which is the whole
argument for binding once. (Re-derived 2026-08-19, median of three runs; the
figures here were 952–1235, 6.5–10.2, 48 and 1.88, and the bind range was 1–9 µs.
Note that the boxed spread is *not* ordered the way the wording elsewhere
assumes: on two of the three runs the "class in hand" target was the faster of
the two, on the third it was the slower.)

`handle_pointer` (revision 3) is what joins the two halves. A handle is the only
safe *durable* reference to a managed object — the collector moves objects, so
the host holds a GC handle underneath and re-asks it for the address every time —
and that is exactly what makes a handle useless to a mod's own fast path, which
needs the address. Before it, a hook that fired *for* an object could only reach
that object back through `call`, at about a microsecond a time; two mods measured
that and left five features out. `handle_pin` is the honest way to keep an
address, and its cost is stated rather than hidden: the object is immovable for
the rest of the session unless the mod releases the pin.

## Hooks, and the two payloads

`patch(target, kind, handler)` detours a compiled method. The engine is
`abi/aowlspt_detour.h`: it decodes enough of the prologue to relocate it into a
trampoline, writes a 14-byte `jmp [rip+0]` over the start, and dispatches through
**256 hook slots** (`AOWL_MAX_HOOKS`), one per patched method, claimed at
attach. A 257th patch is refused with a message about slots rather than silently
sharing one.

**This paragraph said sixteen, and a seventeenth patch, until 2026-08-19.** That
was true while each slot needed its own hand-written `aowl_thunk_N`; two example
mods exhausted it (`hostharness --churn 120` stopped with thirteen slots live
and three left to install) and a real install is eight or ten mods. With one
common thunk entered through a per-hook site record nothing is enumerated per
slot any more, so a slot costs 25 bytes of tables — 6.4 KB of BSS for all 256 —
and the bound exists only so a mod stuck in an install loop reports "no free
patch slots" instead of quietly eating address space. The client host spends one
of those slots on its own main-thread drain and enters it in the same table a
mod's patch goes into — the
engine hands slots out in ascending order and the firing path indexes that table
by slot, so a host hook kept outside it would shift every mod's slot by one and
deliver each patch to the wrong handler.

A prefix thunk **tail-jumps** into the trampoline, which is what makes the
original's return value, its stack arguments and its return address correct by
construction. A postfix has to `call` it and regain control, and pays for that
with two refusals made at *registration* rather than at the first firing: a
return type wider than a register comes back through a caller-allocated buffer
whose layout the host cannot read, and a compiled call needing more than four
register slots has stack arguments a *called* original would look for in the
thunk's frame. Neither is silently downgraded to a prefix, because a postfix
behaving like one would hand a mod scaling a getter a value the original had not
produced yet — a wrong number rather than an absent one.

There are now two payload shapes, and choosing between them is the main
performance decision a client mod makes.

`patch` delivers a firing as **JSON**: a host-side string, a GC handle per
reference argument, a copy into the mod's heap, and a parse. `patch_typed`
(revision 4) delivers the same detour with none of that — the handler is given a
borrowed view of the registers the thunk already saved, plus the declared kind of
every slot, worked out once at registration. It allocates nothing on either side
and asks the runtime nothing per firing.

Measured by `perfbench` on `EFT.Player::Ping` against the stand-in, median of
three runs on one machine. Re-derived 2026-08-19 with
`installer\build\perfbench.exe --runtime tests\mockil2cpp\GameAssembly.dll`,
three runs, median; the "was" column is what this table carried before that:

| | ns/op | was |
|---|---:|---:|
| bound call, unpatched | 3.33 | 3.3 |
| prefix hook, JSON arguments | 643 | 645 |
| **prefix hook, typed frame** | **24.3** | 23.3 |
| postfix hook, JSON result and arguments | 1140 | 1144 |
| **postfix hook, typed frame** | **25.8** | 24.9 |
| postfix hook, JSON + replacement | 1614 | 1615 |
| **postfix hook, typed frame + replacement** | **38.6** | 37.3 |

The four JSON rows and the unpatched call came back within a nanosecond of what
was written down; the three typed rows are all about a nanosecond higher, which
is the same direction on all three and inside the spread a fourth, cold run gave
(35.0 / 45.4 / 72.2 — a first run on a machine with a build going is not a
measurement). Nothing here has moved by enough to change a decision.

The typed path does not replace the JSON one and a mod should not reach for it
by default. JSON is self-describing, survives an argument the host cannot
classify, reads a `System.String` for you, and a 2 µs hook at 10 Hz is 20 µs a
second — 0.002 percent of the machine. The typed path is for the hook that fires
forty times a frame: at 60 fps that is 2400 firings a second, so the JSON
postfix at 1140 ns costs **2.7 ms of every second** and the typed one at 25.8 ns
costs **62 µs**, which is the difference between a stutter and a mod.

(Both figures in this paragraph used to be stated per *frame* — "0.002 percent
of a frame" and "5.3 ms a frame against 60 µs". The arithmetic behind them was
per second all along: 2400 firings times ~2.2 µs is 5.3 ms **a second**, and
2400 times 23.3 ns is 56 µs. The ratio was right and the unit was not.
Recomputed against the re-derived table above, 2026-08-19.)
[PERF.md](PERF.md) has the full tables, the provenance, and what they do not
prove.

Two refusals in the typed path are worth naming because both could have been
guesses. Reads are by index **and by declared kind** — asking for a float where
the runtime says integer is refused rather than reinterpreted, because
reinterpreting answers a number. And the frame must not outlive the handler,
which is enforced rather than asked for: frames come from a fixed pool with a
`live` flag, so a stored pointer reads a cleared struct and
`aowl_frame_why_text` returns a sentence naming that exact mistake.

Finalizer patches are not bridged at all. A finalizer's whole contract is about
the exception in flight, and exceptions do not cross this ABI in any form the
other side could act on. Refusing is more honest than pretending.

## The Tarkov server is a mod

This is the piece that makes the rest make sense.

The game needs a server, and SPT's targets a pre-1.0 client. So there is one
here — `mods/tarkov`, guid `aowl.tarkov` — and it is an ordinary mod. It imports
`aowlspt`, `aowlspt/server` and `aowlspt/json` and **nothing else**. It has no
private door into the host. It registers its 99 routes with the same `serve`
and `servePrefix` any mod uses, persists profiles through the same `save`/`load`
every mod gets, and is loaded by the same `modhost.loadMod` as everything else.
Its `exportMod` declares `sides = {sideServer, sideSim}`.

(95, not the 94 this paragraph carried: `grep -o 'serve\(Prefix\)\?("[^"]*"'
mods/tarkov/tarkov.nim | sort -u | wc -l` answers 95 on 2026-08-19 — 85 `serve`,
9 `servePrefix`, and one `serve` whose status is checked rather than discarded.
The count went 69 → 95 in one commit; 94 does not appear to have been right for
either state of the file.)

The constraint is the point: **a plugin API is only as good as the largest thing
anyone has written with it.** Every gap found while writing a game server was
closed in the API rather than worked around in the mod — persistence, reading a
request body, building arrays and envelopes, events, timers. If the emulator had
needed a private door, the plugin API would not be enough to build a game server
with, and everyone else's mods would have hit the same wall one endpoint later.

`backend/aowlbackend.nim` therefore has no game routes at all. Its route table
starts empty and is filled only through `route_register`. What the backend is, is
the pipeline — sockets, the client's wire framing, routing, a database, the mod
ABI and the plugin API on top. What runs on it is content.

The same argument produces `mods/manager` (`aowl.manager`), which is also just a
mod: it reads `registry/mods.json`, resolves it against your selection, and
serves the answer under `/aowlspt/mods/...`.

[EMULATOR.md](EMULATOR.md) is what the emulator implements and refuses;
[EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md) is the gap list, derived from
`reference/` rather than from memory.

## The store: atomic, write-through, and what that costs

`<root>/store/<mod-guid>/<key>` holds the only thing this project has that
cannot be rebuilt. The database, the mods and the hosts are generated,
downloaded or compiled; a profile is not. So the promises are exact, and they
are all in `host/common/modstore.nim`:

**A value is never half-written.** A write goes into a temporary file inside
`.hist/` and is renamed over the key with `MoveFileEx` /
`MOVEFILE_REPLACE_EXISTING`. Replacing a directory entry is atomic on NTFS, so a
reader sees either the whole previous value or the whole new one — never a
mixture. That holds against `TerminateProcess`, against the window being closed,
and against the disk filling mid-write, which leaves the temporary behind and the
key untouched.

**A write is on disk before the call that made it returns.** Nothing is held in
memory for a later moment. There is no `storeTick`, no write-behind queue and no
deferred commit anywhere in this repository. (This sentence also said "no
`storeFlush`"; `storeFlushOnWrite` does exist in `host/common/modstore.nim:548`,
but it is the `--store-flush` switch three paragraphs down — a `FlushFileBuffers`
*before* the rename, not a flush of anything deferred. Corrected 2026-08-19.)
There was
one, it bought throughput, and it reopened exactly the hole this paragraph
exists to close. The removal is written up above `commitNow` so the next person
does not re-derive it. Killing the server the instant after a trade, a loadout
save or a raid ending loses none of them.

The price is stated rather than hidden: about 1 ms a commit against 25 µs for the
bytes, because the cost is creating the temporary and renaming it and a real-time
virus scanner inspects both. It took the write-heavy endpoint from 0.44 ms to
about 1.1 and the benchmark mix from ~1500 requests a second to ~800 — still six
times what a client asks for across a whole session, which is why the gate's
floor is 500.

`--store-flush` adds `FlushFileBuffers` before the rename, which is the expensive
step by an order of magnitude — 3.9 ms of a 4.3 ms write on the machine
`modstore.nim` records. It does **not** protect against a crash: the rename does
that, and the bytes are in the operating system's cache before it. What it
protects against is the machine losing power in the seconds after a write, which
can otherwise come back with the rename applied and the contents not yet
written — the one case where this store can hand back a file that will not parse.

`tools/storecrash.nim` is the evidence rather than the claim: it kills a writing
process with `TerminateProcess` at jittered points, restarts, and demands a whole
value, reporting how many kills landed inside a commit, and runs the same kills
against the in-place write the store used to do so the coverage figure is
checkable. It is a gate in `aowl test`.

One backend per store, claimed with a `FILE_FLAG_DELETE_ON_CLOSE` file that
cannot go stale. The client host takes a different claim, because the two are
meant to share a store.

## Live mod control, on both hosts

A mod can be enabled or disabled without restarting anything — on the server
while it is serving, and on the client while the game is running. Neither needs a
mod rebuild, an ABI revision, or a change to `aowlspt_abi.h`.

`host/common/modcontrol.nim` is the host half and is shared by both hosts,
because the wire is the same on either side and two implementations of it would
drift. `mods/manager/mgr/control.nim` is the mod half.

**On the server** it is an event protocol. The manager and the host share a
process and therefore an event channel, so control is four request events in a
reserved `aowlspt.host.*` namespace, answered by emitting:

```
aowlspt.host.mods.probe   -> aowlspt.host.mods.capabilities
aowlspt.host.mods.load    -> aowlspt.host.mods.result
aowlspt.host.mods.unload  -> aowlspt.host.mods.result
aowlspt.host.mods.list    -> aowlspt.host.mods.listed
```

Events rather than new ABI functions, because the channel already exists on every
host: this needed no header change, no revision bump and no rebuild of any mod
that does not care. Two rules the host must keep, both being things a manager
cannot work around: **every request produces exactly one `result`, failures
included** — silence is indistinguishable from a host that never implemented any
of this — and **`load` is idempotent**, because `/apply` restates the whole
desired set every time rather than a diff computed from a stale picture.

**On the client** there is no shared channel: nothing inside the game process
ever emits `aowlspt.host.mods.unload`. So the client **asks**. The host starts a
poll of `/aowlspt/mods/client/<version>` on the overlay's existing worker thread
— the one HTTP client already in the process — every `modSyncMs` (3000 by
default; `0`, or a missing `backendPort`, switches it off with a line in the
log). `<version>` is the *client host's* own version, so the manager checks each
mod's `pipeline` range against the program that will load it rather than against
the backend, which is a different program allowed to be at a different version.

The direction is the safety argument: **the backend is asked, never listened
to.** `parseDesired` refuses a body failing any of four checks — the schema
(`aowlspt.clientset/1`), the manager's own `ok`, a trailing `complete` key the
manager writes last, and a `count` that must equal the rows actually read. The
last two exist because the reader is fed by a fixed buffer inside the game
process, and a body cut in half by that buffer parses perfectly and says the mods
that did not fit should be unloaded. Every failure of the far end — down,
starting, restarting, serving a 404, serving too much — converges on "leave the
mods alone".

**Nothing is loaded or unloaded inside the emit.** `submit` records the request
and returns; `drain` performs it, from the host's own loop — once a tick in the
backend's serve loop, and immediately after `takeModSet()` in the client host's
tick loop. The reason is specific and fatal: broadcast is synchronous, so at the
moment a control request arrives the stack runs through the manager's route
handler and, for an unload, quite possibly through the mod being unloaded.
`FreeLibrary` there means returning into unmapped memory.

The other half of the danger is the **teardown**. Everything a mod registered is
a function pointer into its library — a route, an event subscription, a timer, a
detour — so `unloadOne` runs `on_unload`, then a teardown the *host* supplies
that drops all of them, and only then frees the library. `unloadOne` **refuses
outright when no teardown has been registered**: a host that cannot say what a
mod registered cannot safely unload it. The backend installs
`dropModRegistrations` (routes, subscriptions, timers) before it loads a single
mod; the client host owns its own (subscriptions, pending main-thread callbacks
under the drain's lock, and each detour removed through `cHookRemove`).

`tools/livectl.nim` proves the server half every `aowl test` run: it disables a
mod on a live backend, checks its routes are gone from the router while the mods
beside it keep answering, enables it again, and checks the mod that came back is
a fresh instance. **There is no equivalent gate for the client half.** The
mechanism is wired end to end and has been run against the stand-in runtime only.
[MODMANAGER.md](MODMANAGER.md) is the whole of it, including what is refused.

### What is still holding a pointer when the mod goes

The teardown drops every registration the host can see. What it cannot drop is a
pointer a *thread* is already carrying, and there are two of those. They have
different answers, and the difference is worth stating as a rule rather than
rediscovering.

**A trampoline is retired, never freed, and that is now load-bearing.** A patch
is removed with `aowl_hook_remove`, which used to `VirtualFree` the trampoline —
while a thread was very likely executing inside it, because the trampoline is how
a firing reaches the original method. `tests/detour_race.c` counted that: six
threads calling a patched function while another installs and removes the patch
faulted on essentially every cycle. The fix is that a trampoline is never given
back. It is suballocated out of 64 KB blocks near its target, **512 to a block
and 128 blocks at most — 8 MB and 65536 installs** (`AOWL_TRAMP_SLOT` 128 bytes,
`AOWL_TRAMP_BLOCK` 0x10000, `AOWL_TRAMP_BLOCKS` 128; this read "1024 to a block
and 64 blocks" until 2026-08-19, which was the arithmetic of a 64-byte slot,
before the per-hook site record and stub moved into the slot beside the
trampoline). Never freeing therefore costs address space that is bounded and
countable rather than the 64 KB per install a `VirtualAlloc` each would burn —
and, far more sharply, it stops the +/-2 GB window the stolen RIP-relative
displacements need from filling up. `hostharness --churn 2000` sees no trend.

Three rules follow, and breaking any of them reopens the hole:

* **A firing never looks anything up.** There was a slot-indexed
  `aowl_tramp_table`, and it was the hole: a thread preempted between the jump
  landing on the thunk and its first load read the trampoline *and* the
  generation **after** the slot had been released and re-claimed by another
  hook. The pair was self-consistent, so the generation check passed and the
  firing ran the other hook's handler with the wrong arguments. The tell was
  that the wrong answer was always exactly the other function's arithmetic on
  this function's argument — which a torn instruction stream cannot produce.

  The stub is now per **hook**, not per slot: installing writes
  `mov r11, <this hook's site>` + a jump into one common thunk, where the site
  is a 24-byte record holding `{tramp, gen, slot, post}`, written once before
  the jump goes in and never written again. Four facts that came out of one
  immutable record cannot describe two different occupants. The table is gone.
* **The thunk reads the trampoline *before* the generation.** Only in that order
  does a generation that has since moved on prove the pointer is the departed
  hook's own, which is what lets a stale firing run the original instead of being
  suppressed. Suppressing it hands the caller a zero for a method whose patch was
  merely switched off: 1048 wrong answers in a three-second run.
* **A trampoline slot is never handed out twice.** The retired bytes are the only
  thing keeping a late firing correct.

The cost of all this on the firing path is 0.22 ns, measured: one store and one
load into a frame slot, and one byte compared in the dispatcher. That is the
whole reason it is shaped this way. An uncontended `InterlockedIncrement` /
`InterlockedDecrement` pair measures 7.3 ns on this machine against a bare firing
of 2.9 ns, so a refcount taken around every patched call would have cost more
than tripling the thing it protects — and that is the *uncontended* figure, on
one thread, on a line nobody else wants.

**A mod's library is no longer freed while a worker is inside a route handler.**
This one is closed, and it is closed by a reference rather than by a lock.
`matchRoute` copies the route out under the registration lock and `runRoute`
invokes it with no lock held — deliberately, because a handler is allowed to
register a route and a walk holding the lock across the call would wait on
itself — so a worker can be between the copy and the call, or inside the call,
when the serve loop reaches `cFreeLibrary`.

Retirement does not transfer from the trampoline to the library, and it is worth
saying why, because it is the first thing anyone will try. A trampoline is 46
bytes at most (128 with the site record and stub it shares a pool slot with);
a mod image is hundreds of kilobytes, and `hostharness --churn 2000` does
500 load/unload cycles, which is the trend that check exists to catch.
`LoadLibrary` of a path already mapped returns the same image with a bumped
reference count rather than a fresh one, so a mod loaded again after a retirement
would come back with its statics as it left them and its mimalloc heap already
torn down by `mi_process_done`. There is no version of "just do not free it" that
survives a reload.

What closes it is a reference taken around the dispatch, and the argument that
rules that out for a patch firing does not apply here: a route handler costs
about 423 us (`docs/PERF-SERVER.md`), so the pair is measured in nanoseconds
against it. The shape is fixed by the order:

1. `modhost.modEnter(index)` **increments first and then tests** whether the mod
   is draining, and gives the reference back and refuses if it is. Testing first
   loses to a drain that starts in between.
2. `unloadOne` **sets draining first and then reads the count**, before
   `on_unload` and before the teardown, so that a worker which matched a route a
   moment ago is refused rather than admitted; then it waits for the count to
   reach zero, with a 5 s deadline, and on expiry **declines the unload** and
   clears the flag rather than freeing the library under a live thread. The mod
   stays loaded and answering, and the manager is told why.
3. Both flag and counter live outside any `seq` — fixed C arrays in
   `host/common/modhost.nim`, `AOWL_MOD_SLOTS` (16384) of them, indexed by the
   mod index every host already keys on. `gMods` grows from the control thread,
   and a worker reading a growing `seq` is the same use-after-free one table
   over. A slot is spent per *load*, because `unloadOne` keeps a dead mod's slot
   rather than compacting `gMods`; `loadMod` refuses past the end rather than
   loading a mod whose routes could never be entered.

Both stores are followed by a load of the *other* location and both are
interlocked, so neither pair can be reordered. That is what makes the argument
finite: suppose an enter succeeded — it read `draining == 0` after its own
increment — and suppose the drain's read of the count still missed that
increment. Then the count read precedes the increment, the draining store
precedes the count read, and so the draining store precedes the increment, which
precedes the enter's read of draining. The enter would have seen `1` and
refused. No enter can succeed unnoticed, so a drain that reaches zero has nobody
inside.

The backend takes the reference in two places, not one: around `runRoute` (under
the session lock rather than over it — taken first, a request waiting ten seconds
for another request on the same profile would hold a mod open for those ten
seconds and turn a live unload into a timeout) and around each subscriber in
`deliverEvent`, which is the same copied function pointer reached from a worker
thread. A refused route is a `503` naming the unload; a refused subscriber is
simply skipped, because an event is a broadcast and skipping rather than waiting
is also what keeps a mod that emits from deadlocking against its own drain.
Timers need none of it: they fire from the serve loop, which is the thread that
performs the unload.

Measured on this machine with the shipped bodies: **11.2 ns** per
enter/leave uncontended, **33 ns** with sixteen threads on one mod's counter —
0.003% and 0.008% of a 423 us handler. `benchbackend` sees no difference outside
its noise.

**Neither of those two numbers was re-derived on 2026-08-19, because nothing in
this tree measures them.** `modrace` counts answers rather than timing the pair,
and there is no `--bench` on it. What the source does state is the figure for
the bare interlocked pair alone — 7.3 ns (`host/common/modhost.nim:164`,
`backend/aowlbackend.nim:949`), against a 2.9 ns detour firing — and
[MODMANAGER.md](MODMANAGER.md) quotes that one for `modEnter`/`modLeave`, where
this page quotes 11.2 for the shipped bodies, which do a bounds check and a
second load on top of it. Both may be right; only one of them has a stated
provenance. Treat 11.2/33 as unverified until something re-measures them.

`backend/modrace.nim` is the gate, and it asserts on **answers**: sixteen
workers (the gate runs `--cycles 24 --workers 16`; the tool's own default is
eight and forty cycles)
call a route while another thread loads and unloads the library under them, and
every attempt is counted as a whole current answer, a clean refusal (the mod is
draining), an empty table (the mod is gone), or a failure. Two kinds of failure
are what it exists for — a worker that faults inside a freed image, caught by a
vectored handler and *counted* rather than allowed to end the run, and an answer
that carries the wrong incarnation's generation, which is what a late call
returns when the image has been freed and mapped again at the same base address
and does not fault at all. `--unguarded` skips the two calls and nothing else:
16 of 16 workers fault and stale answers appear, five runs out of five.
`--wedge-ms` holds a handler open past the deadline and asserts the other half —
the unload refused, the mod still answering, and the same unload succeeding once
the handlers are out.

**And the rule the store version of this leaves behind:** any `seq` a worker
thread touches is under `aowl_lock`, including the ones that look like
bookkeeping. `modstore.storeWrite` walked and appended `gMadeDirs` — the list of
directories this process has already created — outside the lock, from sixteen
workers. It is the same reallocation-under-a-reader bug as `gRoutes`, in its
nastiest shape: the append happens only on the *first* write to each new
directory, so it is invisible in every steady-state test and waits for a second
mod to start writing while the first is busy.

## A request, end to end

A client asks for its profile. `GET /client/game/profile/list`, body zlib-framed,
session in a `PHPSESSID` cookie.

1. **`abi/aowlspt_net.h`, poller thread.** `WSAPoll` reports the socket readable.
   The connection's buffer is allocated on this first byte, counted against
   `AOWL_NET_MAX_BUFFERED`. Bytes are read; the header block is found; the
   declared `Content-Length` is checked against `AOWL_BODY_CAP` (16 MiB) — a
   declared length over it is a `413` before anything is allocated, which is the
   bug `fuzzwire` found with `Content-Length: 9000000000000000000`.
2. **Still the poller.** Only once the whole body is buffered does the connection
   go on the ready queue. Until then it costs a socket and the bytes it sent.
3. **A worker takes it.** The session id is checked: 24 hex characters or the
   request is refused here, before any route.
4. **The session lock.** `aowl_session_lock` on the exact id, from a 128-slot
   table. Ten seconds without it is a `503`.
5. **Inflate.** `inflateBody` in `backend/aowlbackend.nim`. An unframed body
   passes straight through, deliberately, so hand-testing works.
6. **Route match.** Exact match wins, then longest prefix — never
   order-of-registration, which would make behaviour depend on filenames.
7. **Into the mod.** The route handler is a function pointer in `tarkov.dll`,
   registered through `route_register`. It gets `url`, `body`, `session` as
   borrowed `AowlSlice`s; the nimony library copies each into a string at the
   entry point, so a mod author never has to hold the borrowing rule.
8. **The mod works.** `load("profile." & id)` goes back across the ABI to
   `store_get` and reads the file. `dbRead(...)` addresses the shared database by
   dotted path, which is a hash lookup per segment against a per-object index
   built lazily over the document's byte offsets.
9. **The answer.** The mod builds `{"err":0,"errmsg":null,"data":...}` — the
   client's envelope, via `envelope`; a route that returns bare data gets a
   client that reads a good response as a failure, silently. It fills an
   `AowlBuffer` from the host allocator and returns `AOWLSPT_OK`.
10. **Back out.** The host takes the buffer and frees it with its own allocator.
    The response is deflated (from a cache keyed on the response *text*, so a
    stale hit is impossible by construction) unless the caller sent
    `Accept-Encoding: identity`.
11. **Send, unlock, hand back.** The session lock is released before the
    connection waits for its next request. The worker lingers a couple of
    milliseconds in case the next request is already on the wire — but only while
    the ready queue is empty and another worker is free — then gives the
    connection back to the poller. After 512 requests the connection is closed
    regardless, so no client can hold a poller slot for the life of the process.

## A hook, end to end

A client mod wants the game's aiming sensitivity halved.

1. **`on_update`, not `on_load`.** At load the process has an IL2CPP runtime but
   not yet a game — EFT's assemblies come up later — so resolving `EFT.Player`
   at load time is a false negative. Bindings and hooks are armed on the first
   frame the type resolves.
2. **`hookReturnTyped("...::get_AimingSensitivity", onSens)`** in
   `aowl/src/aowlspt/game.nim` calls `patch_typed` across the ABI, having checked
   `typedPatchesReady()` — which tests `AowlHostApi.size` against
   `HostApiSizeRev4`, the boundary `patch_typed` appeared at, rather than against
   `sizeof(AowlHostApi)`. Those are the same number today and will not be after
   the next appended field; `livePointersReady()` tests `HostApiSizeRev3` for
   exactly that reason, and would have started answering "no addresses" on every
   revision-3 host the day `patch_typed` landed if it had not been changed.
3. **`installPatch` in the host.** It finds the `MethodInfo`, reads
   `methodPointer` (checked for landing in an executable page), asks
   `il2cpp_method_get_param` and `shapeOfType` for the declared kind of every
   parameter and of the return — **once, here** — and keeps a byte per slot. It
   refuses a postfix on the two method shapes that cannot carry one, with a
   sentence saying which.
4. **`cHookAttach`.** The detour engine decodes the prologue, relocates the
   stolen instructions into a trampoline that ends with a jump back, writes
   `jmp [rip+0]` over the first 14 bytes, and claims one of the 256 hook slots
   (it was 16, which was never a budget — it was the number of thunk macros
   somebody had typed out; with one common thunk a slot costs 25 bytes of
   tables). A
   prologue holding a relative branch, or a function shorter than the jump, is
   refused by name rather than overwritten.
5. **The game calls the method.** The thunk's first instruction reads the
   slot's **generation** into its own frame, and everything else follows: the
   argument and return registers are saved, and because this is a postfix it
   `call`s the trampoline rather than tail-jumping, regaining control with RAX
   and XMM0 both saved. The generation is bumped when a slot is released, so a
   firing that was in flight when its patch was removed is dropped by the
   dispatcher instead of being delivered to whichever patch took the slot next
   — the failure that looks like a working handler with somebody else's
   arguments. It costs one load and one compare, and it is not measurable next
   to the two table loads already on that path (`perfbench`: 23 ns a typed
   prefix firing, before and after).
6. **The host publishes a frame.** Six words into a pooled `AowlPatchFrame`
   indexed by patch depth — not the heap, and deliberately not the host's stack,
   because a stored pointer to a stack frame is undefined behaviour while a
   pooled one is still there with `live` clear.
7. **The mod's handler runs.** It reads slot by index and declared kind,
   multiplies, writes eight bytes back with `aowl_frame_set_ret_*`, and returns
   `frameReplace()`. Nothing was allocated on either side: no payload string, no
   GC handle, no host buffer.
8. **The thunk restores and returns.** A postfix that changed nothing is
   bit-for-bit transparent, including on a return type the host could not
   classify. The host clears the frame; every accessor now refuses it and
   `aowl_frame_why_text` names the mistake if the mod kept a pointer.

Twenty-five nanoseconds, against 1144 for the same hook delivered as JSON and
3.3 for the unpatched call — measured against the stand-in, on one machine.

## Building, testing, installing

`aowl` is itself a nimony program: the thing that compiles a nimony mod is
written in the language it compiles. It has eleven subcommands — `build`,
`build-mod`, `build-hosts`, `build-installer`, `test`, `doctor`, `run`,
`payload`, `release`, `importdb`, `clean` — and `aowl doctor` is the one to run
first. Every check in it is there because something went wrong once and pointed
somewhere else while it did; the sharpest is PATH order, because a
Git-for-Windows `mingw64` ahead of `C:\msys64\ucrt64\bin` gives gcc a `cc1` that
loads the wrong libgcc and dies with **no diagnostic at all**.

The other tools are separate binaries rather than `aowl` subcommands, most of
them built and run as phases of `aowl test`: `emutest`, `realtest`, `soak`,
`fuzzwire`, `wstest`, `livectl`, `allmods`, `modresolve`, `storecrash`,
`regcheck`, `perfbench`, `benchbackend`, `hostharness`, `dbrace`, `modrace`,
`modreport`, `modclient`, `framelen`, `tickrace`, `mgrguard`, `detour_race`,
`coverage`, plus `aowlprobe`, `il2cppprobe`, `firstrun`,
`aowlspt-launch` and `aowlspt-verify` for use by hand. (`coverage` —
`aowl-coverage --check` — was missing from this list; it is a gate,
`tools/aowl.nim:1712-1737`. `modrace` is on it and is genuinely run,
`tools/aowl.nim:1297-1314`.)

Two gates earn their keep out of proportion to their cost. The **layout** gate
compares nimony's `sizeof` against the numbers the real C compiler gives the real
header, rather than against a second copy of the same arithmetic: a struct
mismatch between the two sides does not crash, it reads a length as a pointer and
fails somewhere else entirely, under load. It has already caught one error. The
**fast-path** gate re-measures rather than asserting, because a performance claim
that is not re-checked is a performance claim that quietly stops being true.

Building, running, testing and debugging all happen inside the repository.
`aowlspt-install` is the one program that writes anywhere else and will not do so
without being told what to install and where. `--source` is only ever read; the
client is mirrored into `--target`, hard linked where that is safe, so a 78 GB
install appears in seconds and costs no disk, and the payload goes over the top.
The install your official launcher maintains stays canonical and can rebuild the
target at any time. See [INSTALL.md](INSTALL.md) and `installer/README.md`.

## The line that matters most

The modded client plays against a backend on your own machine. The installer does
not carry BattlEye across and the launcher does not start it. **This client must
never talk to the live service** — injecting a DLL into a process talking to
BSG's servers is a decision with consequences for your account. These tools will
not stop you pointing the client somewhere else, and they will not help you
either.

And, again, because it is the single most important sentence in this repository
and it should not become a footnote: **nothing here has ever run against BSG's
client.** The host has been run against a stand-in runtime that exports the same
C API, against a live process with no runtime in it, and against a mock's type
universe. Every "the client" claim in every document here is a claim about that
stand-in. The one step left is to launch and read
`aowlspt/aowlspt-host.log`.

## Where to go next

| you want to | read |
|---|---|
| write a client mod | [MODDING.md](MODDING.md) |
| write a server mod | [BACKEND.md](BACKEND.md) |
| understand the contract | [ABI.md](ABI.md) |
| know why there is no BepInEx | [IL2CPP.md](IL2CPP.md) |
| make a client mod fast | [PERF.md](PERF.md) |
| make the server fast | [PERF-SERVER.md](PERF-SERVER.md) |
| find a bug | [DEBUGGING.md](DEBUGGING.md) |
| know what the emulator answers | [EMULATOR.md](EMULATOR.md), [EMULATOR-COVERAGE.md](EMULATOR-COVERAGE.md) |
| get real game data | [IMPORTDB.md](IMPORTDB.md) |
| turn mods on and off live | [MODMANAGER.md](MODMANAGER.md) |
| install it | [INSTALL.md](INSTALL.md) |
