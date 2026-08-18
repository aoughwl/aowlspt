# The aowlspt ABI

`abi/aowlspt_abi.h` is the whole contract. This document explains the decisions
behind it — the header itself is the reference.

## Five rules

**1. C ABI only.** No C++, no name mangling, no exceptions across the boundary.
Every cross-boundary function is `cdecl` and returns a status code. This is what
lets a nimony-built DLL and a .NET host, or a Mono host, agree on anything at
all.

**2. One allocator, and it is the host's.** A mingw-built DLL and a .NET host do
not share a CRT heap. A buffer allocated on one side and freed on the other is a
crash waiting for a busy raid — and it will not be the allocation that crashes,
it will be something unrelated, later. So anything that outlives a call is
allocated with `AowlHostApi.alloc` and freed with `AowlHostApi.free`, whichever
side does it.

**3. Borrowed in, owned out.** An `AowlSlice` passed *into* a function is valid
only for that call. To hand data back, fill an `AowlBuffer` from the host
allocator; the receiver frees it. The nimony library copies into a string at
every entry point, so a mod author never has to hold this rule in their head.

**4. Additive versioning.** Every struct carries its own `size` as the first
field. New fields are appended — never inserted, never reordered — and a peer
checks `size` before reading anything added after v1. `AOWLSPT_ABI_VERSION`
bumps only on a genuinely breaking change, and a host refuses a mod whose major
differs before running a single line of its code.

**5. No SPT types.** The typed SPT model surface is generated per SPT version
and travels as encoded payloads. The header stays stable while BSG and SPT churn
underneath it.

## Layout

The structs are plain C on x86-64. `AowlSlice` and `AowlBuffer` are 16 bytes:
an 8-byte pointer, a 4-byte length, and 4 bytes of tail padding. `{.packed.}`
would *break* the match, not tighten it.

| struct | size |
|---|---|
| `AowlSlice`, `AowlBuffer` | 16 |
| `AowlHostInfo` | 120 |
| `AowlHostApi` | 192 |
| `AowlModInfo` | 104 |
| `AowlModApi` | 56 |

`AowlHostApi` was 168 at revision 1 and is 192 at revision 2 — three appended
function pointers, `store_get`/`store_set`/`store_list`, and nothing moved. That
is rule 4 doing its job: a revision-1 host and a revision-2 mod still agree
about every field either of them knew about, and the mod finds out about the
difference from `size`.

`tests/abi_layout.c` computes these with the real compiler over the real header;
`tests/abi_layout.nim` asserts nimony agrees. Both are the first two gates of
`aowl test`. This is not ceremony — a mismatch here does not crash, it reads a
length as a pointer, and the failure surfaces somewhere else entirely.

One deliberate deviation from the obvious design: `last_error` writes through an
out-parameter instead of returning an `AowlSlice` by value. A 16-byte struct
return is exactly where the mingw and MSVC ABIs disagree about hidden-pointer
handling, and that disagreement corrupts silently rather than failing to link.

## The three exports

A mod library exports exactly three symbols:

```c
uint32_t   aowlspt_abi_version(void);
AowlStatus aowlspt_describe(AowlModInfo* out);
AowlStatus aowlspt_init(const AowlHostApi* host, AowlModApi* out);
```

The host calls them in that order, and the order is the point:

1. `aowlspt_abi_version` — the cheapest possible reject. Runs no mod code.
2. `aowlspt_describe` — metadata, before the mod can touch any host service.
3. side and duplicate-guid checks — refuse here rather than half-load.
4. the host builds its API — allocator, callbacks, info block.
5. `aowlspt_init` — the mod may now call back into the host.
6. `on_load` — the host is ready to serve.

`exportMod` in `aowl/src/aowlspt.nim` writes all three for you.

## The escape hatch

`call(target, args) -> result` invokes a host member by name:

```
"Namespace.Type::Member"   a static member, or a DI-resolved service
"#<handle>::Member"        a member on a live handle from `resolve`
```

This exists because the alternative — enumerating SPT's API in the ABI — would
break every SPT point release. It is deliberately the slow path: use it to reach
a corner SPT has that the ABI has not grown a door for, and when a call turns
out to be hot, promote it into the header rather than looping on reflection.

Type lookup accepts simple names as well as fully-qualified ones. That matters
in practice: SPT moves types between namespaces across releases, and EFT's
obfuscated types get renamed every patch.

## The per-mod store (revision 2)

`store_get` / `store_set` / `store_list`: a private key/value store per mod, held
by the host and surviving a restart. `db_get`/`db_patch` address the *shared*
game database, loaded from disk and common to every mod; this is where a mod
keeps what belongs to it alone.

A mod could open files itself, and then every mod would invent its own layout
inside the install and there would be no way for the host to move, back up or
clear a mod's data. Keys are flat, `[A-Za-z0-9._-]`, and a key outside that set
is **rejected rather than sanitised**: silently mapping two keys onto one file is
worse than refusing one of them.

`store_list(prefix)` returns a JSON array of the mod's keys, which is what makes
"every profile" expressible without the mod knowing where the host put them.

Because these are appended fields, a mod must test `AowlHostApi.size` before
using them — `storeReady()` in the nimony library — rather than calling through
a function pointer a revision-1 host never filled in.

## Patching

`patch(target, kind, handler)` bridges to Harmony on the C# hosts and to an x64
inline detour in the IL2CPP host. A prefix handler returning
`AOWLSPT_PATCH_SKIP` suppresses the original and may write a replacement result
into the out-buffer.

`AOWLSPT_PATCH_ARGS` (0x10) is OR'd into `kind` to ask the host for the original
arguments, which then arrive in the handler's `args` slice as a JSON array in
the same shape `call` accepts. A **flag** rather than a fourth patch kind,
because it is orthogonal to prefix and postfix; **opt-in** rather than
always-on, because building that array inside a method the game may call
thousands of times a frame is a cost a patch that only counts calls should not
pay.

Two consequences the header states and the hosts enforce: a patch that did not
ask for arguments cannot suppress — a mod that believes it is suppressing when
it is not would be debugging the game instead of its own registration — and a
suppression is refused unless a return value of the method's declared type can
actually be produced, because skipping with garbage in the return register is
the worst outcome available.

Finalizer patches are **not** bridged, and that is a decision rather than an
omission: a finalizer's whole contract is about the exception in flight, and
exceptions do not cross the C ABI in any form the other side could act on.
Refusing is more honest than pretending.

One Harmony patch is installed per target method however many mods attach to it;
a fixed pair of static hooks fans out to the handlers registered for whichever
method is currently executing. The detour engine's equivalent is a fixed pool of
16 assembly thunks — one per patched method, claimed at attach — which is why a
seventeenth patch is refused with a message about slots rather than silently
sharing one.

## Threading

`on_update` runs on the host's main thread — whatever that host's main thread
is. On the C# hosts it is the server's tick thread or Unity's frame loop. On the
IL2CPP client host it is the host's **own attached thread**, not Unity's frame
loop, and `invoke_main` queues onto that same thread. That distinction is
documented rather than papered over: a mod's own threads reach the game through
`invoke_main`, and in Unity this is not a convenience — touching a GameObject
off the real main thread throws or corrupts — so a mod that needs the frame loop
cannot get there through this host yet. See [IL2CPP.md](IL2CPP.md).

A mod that declares `AOWLSPT_MOD_THREAD_SAFE` is promising its callbacks may be
invoked off the main thread. Most should not.

## Hot reload

**Implemented by the C# hosts only** — `aowlspt-sim`, the SPT server host and the
BepInEx client host share `ModHost.Reload`. `aowlspt-backend` and the IL2CPP
client host do not have it; what they have is unloading, below.

A mod declaring `AOWLSPT_MOD_HOT_RELOADABLE` and implementing
`state_save`/`state_load` can be swapped for a freshly built copy without
restarting the host. The host serialises its state, unloads it, loads the new
binary, restores the state, and calls `on_load`.

The host loads a *shadow copy* of the library rather than the file you built.
Windows locks a mapped DLL, so building over a loaded mod fails with a sharing
violation; loading a copy is what keeps the original writable, and therefore
what makes rebuild-and-reload possible at all.

A mod that does not claim the flag is told to restart rather than being reloaded
anyway — silently losing state is worse than being told to restart.

## Unloading

`host/common/modhost.nim` — the loader both nimony hosts share — can take one
mod out while the host keeps running: `on_unload`, then a **teardown**, then
`FreeLibrary`.

The teardown is the whole of it. Everything the mod registered is a function
pointer into its library: a route, an event subscription, a timer, a detour. A
route still in the table after `FreeLibrary` is a call into unmapped memory on
the next request, which is a crash with no stack worth reading. So the host
supplies the teardown, it runs *before* the library is freed, and `unloadOne`
**refuses outright when no teardown has been registered** — a host that cannot
say what a mod registered cannot safely unload it.

The slot is kept rather than removed from the list. Every context pointer the
host handed a mod is that index, and compacting the sequence would silently
repoint them at their neighbours.

Neither host registers a teardown yet, so today it refuses on both. `loadOne`
takes the same path a cold start takes, deliberately: a mod that loads
differently when added late is a mod whose bugs only appear one way round.

## Faults

A mod that returns a bad status or throws past its own boundary is marked
faulted and dropped from dispatch; the host keeps running. A broken mod should
cost you that mod, not the raid.

Unwinding across a C frame is undefined, which is why the nimony library returns
status codes everywhere instead of raising — and why nimony's own error-code
model is a good fit for this boundary rather than a limitation to work around.
