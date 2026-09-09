# The aowlspt ABI

`abi/aowlspt_abi.h` is the whole contract. This document explains the decisions
behind it — the header itself is the reference.

## Five rules

**1. C ABI only.** No C++, no name mangling, no exceptions across the boundary.
Every cross-boundary function is `cdecl` and returns a status code. Every host
in this repository is nimony today; the rule is what lets that stop being true
without anything having to be rewritten — any host somebody writes later, in any
language with a C FFI, agrees with an already-compiled mod.

**2. One allocator, and it is the host's.** Two separately linked modules do not
share a CRT heap — a mingw-built DLL and a .NET host certainly do not, and even
two mingw modules need not. A buffer allocated on one side and freed on the other is a
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
| `AowlHostApi` | 224 |
| `AowlPatchFrame` | 48 |
| `AowlModInfo` | 104 |
| `AowlModApi` | 56 |

`AowlHostApi` was 168 at revision 1, 192 at revision 2 — three appended
function pointers, `store_get`/`store_set`/`store_list` — 208 at revision 3,
which appended `handle_pointer` and `handle_pin`, 216 at revision 4, which
appended `patch_typed`, and is 224 at revision 5, which appended `notify_push`.
Nothing moved any of those times. That is rule 4 doing its job: a revision-1
host and a revision-5 mod still agree about every field either of them knew
about, and the mod finds out about the difference from `size`.

`AowlPatchFrame` is the one struct in this ABI a mod reads *fields* of rather
than calling through, and its layout is therefore as much a contract as
`AowlHostApi`'s. It is a struct rather than a set of accessor function pointers
because it is read inside a method the game runs per entity per frame: an
accessor reached through a pointer in `AowlHostApi` would be an indirect
cross-module call per argument, which is a handful of nanoseconds each and a
barrier the optimiser cannot see through. `tests/abi_layout.c` pins its size and
the register offsets its accessors read — `AOWL_FRAME_OFF_GPR/XMM/RET/RETF`,
which are the thunk's own numbers and are pinned to the assembly itself by
`tests/detour_test.c` — and it carries its own `size` like everything else here.
(The struct's *field* offsets are not individually pinned; the size check plus
`size`-before-anything-appended is what stands behind them. The struct itself
lives in `abi/aowlspt_frame.h`, not in `aowlspt_abi.h`, which declares only the
`const AowlPatchFrame*` a typed handler is given.)

Revision 3 also fixed a way of *reading* `size` that was right exactly once. A
mod tested a capability with `size >= sizeof(AowlHostApi)`, which is true while
the struct's current size is the size of the revision that added the field —
and false the moment the struct grows again, so a mod wanting only the
revision-2 store would have started refusing revision-2 hosts that have it.
`AOWLSPT_HOSTAPI_SIZE_REV1/2/3/4/5` name each revision's boundary, and a
capability is tested against the boundary it appeared at. Revision 4 is where
that stopped being theoretical: `livePointersReady` still read
`size >= sizeof(HostApi)`, so appending `patch_typed` would have made every
revision-3 host answer "no addresses" to a mod that only wanted addresses. It
tests `HostApiSizeRev3` now. `tests/abi_layout.c` pins them to
the real offsets from one side and `abi_layout.nim` holds them as the literals
they have to be from the other.

`size` also means "how much of this struct did I fill", not "which header did I
compile against". `aowl_hostapi_new` builds the block for *every* nimony host
and stops at the revision-2 size, 192, because everything after it needs
something a bare process does not have. Each host then arms the part it can
answer for and raises `size` itself — the IL2CPP client host with
`aowl_hostapi_arm_live` (in `abi/aowlspt_live.h`, which only it includes), the
backend with `aowl_hostapi_arm_notify` (`abi/aowlspt_notify.h`), the simulator
with its own `aowl_hostapi_arm_sim`. In every case the pointers go in first and
`size` rises last: a host that reported 208 with two null pointers in it would
be telling a mod to call them.

Revision 4 is armed the same way and *separately*, by `aowl_hostapi_arm_typed`
in the same header. Two calls rather than one because they are two capabilities:
`handle_pointer` needs a managed heap and `patch_typed` needs a working detour
engine, and a host could have the first without the second. `size` only ever
grows, so the order is arm-live then arm-typed.

### Revision 5, and where the watermark stopped being free

`size` is a **watermark**. It says how much of the struct was filled and a peer
reads everything under it as present, and that was enough while capabilities
arrived in the order hosts acquired them. Revision 5 is where it stopped being.

`notify_push` needs a listening socket, so the only host that can fill it is
`aowlspt-backend` — which has neither a managed heap nor a detour engine and so
cannot honestly answer revision 3 or revision 4. One integer cannot say "the
fifth and not the third", and both obvious answers are wrong. Reporting revision
2 hides `notify_push` from the mod that needs it. Reporting revision 5 over
three null pointers tells a mod to call them, and there is no null check
available to save it: nimony will not cast a proc field to a pointer to compare
it against null, which is *why* every capability test in this project is a size
test.

The answer is the rule this ABI already follows everywhere else: **a capability
a host does not have returns `AOWLSPT_ERR_UNSUPPORTED` rather than
misbehaving.** `call`, `resolve` and `patch` on the backend are already
filled-and-refusing for exactly that reason. So `aowl_hostapi_arm_notify` (in
`abi/aowlspt_notify.h`, which only the backend includes) installs refusing
implementations of `handle_pointer`, `handle_pin` and `patch_typed`, fills
`notify_push`, and only then raises `size` to `AOWLSPT_HOSTAPI_SIZE_REV5`.

Nothing a mod can observe changed: `pointerOf` on the backend answered
`ErrUnsupported` from its own guard before and answers `ErrUnsupported` from the
host now, with the same status from the same call. What changed is the meaning
of a boundary test, and it is worth stating plainly: **`livePointersReady()` and
`typedPatchesReady()` are "there is a function here that will answer", not "this
capability works".** They are true on the backend now and were false before.
That is the only thing a size test could ever have established — a non-null
pointer is not a working detour engine either — and a mod that needs to know
whether a call *succeeds* has to look at the status it returns, which it had to
do anyway.

The alternative, and why it was not taken: `size` could have become a bitmask of
capabilities, which says exactly the right thing and breaks every host and mod
compiled against the field's current meaning. That is a version bump, not a
revision, and it buys a distinction one host currently needs.

`tests/abi_layout.c` computes these with the real compiler over the real header;
`tests/abi_layout.nim` asserts nimony agrees. Both are the first two gates of
`aowl test`. This is not ceremony — a mismatch here does not crash, it reads a
length as a pointer, and the failure surfaces somewhere else entirely.

One deliberate deviation from the obvious design: `last_error` writes through an
out-parameter instead of returning an `AowlSlice` by value. A 16-byte struct
return is exactly where the mingw and MSVC ABIs disagree about hidden-pointer
handling, and that disagreement corrupts silently rather than failing to link.

## The headers around it

`aowlspt_abi.h` is the contract; the rest of `abi/` is the C the nimony hosts
cannot write for themselves. One of those files is smaller than it looks:
`aowlspt_lock.h` holds the process-wide lock and nothing else.

It was split out of `aowlspt_net.h`, which begins with `winsock2.h` and
`zlib.h`. Anything that wanted a critical section was therefore linking a socket
library and a compression library to get one — tolerable in the backend, which
links both anyway, and wrong in the IL2CPP client host, which is a DLL injected
into the running game and should import exactly what its job needs. The client
host's answer had been to carry its own byte-identical copy of the lock with a
comment explaining why it could not include the header that already had one;
both now include `aowlspt_lock.h`, and `aowlspt_net.h` includes it too, so every
file that used to get `aowl_lock` from it still does.

This changed no declaration, no struct, and no field order, so
`AOWLSPT_ABI_VERSION` and `AOWLSPT_ABI_REVISION` stay where they are. Rule 4 is
about the interface; moving two `static` functions between headers on the same
side of the boundary is not one.

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

## Server-pushed notifications (revision 5)

```c
AowlStatus (AOWLSPT_CALL *notify_push)(void* ctx, AowlSlice session, AowlSlice payload);
```

The game opens a websocket at login and expects the server to push down it: new
mail, an insurance return, a flea offer sold, a raid invitation. Everything a
server decides on its own has nowhere to go without one — the profile can change
all it likes and the player finds out on the next screen that happens to reload.

The entry is this small on purpose. A mod names the player and the event; where
that goes is the host's problem. `mods/tarkov` builds the JSON the client
dispatches on and calls this, `backend/websocket.nim` finds the connection and
frames it, and `abi/aowlspt_net.h` owns the socket, the read loop and the write
lock. Nothing in the mod knows a socket exists, which is what lets the same mod
run on a host that has no websocket at all.

Three answers carry the whole contract:

| | |
|---|---|
| `AOWLSPT_OK` | the frame went out on that session's websocket |
| `AOWLSPT_ERR_NOT_FOUND` | there is no websocket for that session |
| `AOWLSPT_ERR_UNSUPPORTED` | this host has nothing to push down |

**`ERR_NOT_FOUND` is a normal answer, not a failure.** A client that has not
upgraded, has not finished logging in, or has just lost its connection is in
that state, and the mod's job is to fall back to whatever it did before — a
queue drained by a poll, in the emulator's case. A host that answered `OK` for a
notification it dropped would be telling the mod the player has been informed,
which is the one thing this call must never do.

There is no `notify_broadcast` and no push by profile id. A session is what the
request layer has and what a connection is keyed on; a mod that knows a profile
resolves it to sessions itself, which is eight lines — `notifyProfile` in
`mods/tarkov/emu/notify.nim`, a loop over the bound sessions — and would be a
policy decision in the host.

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

`patch(target, kind, handler)` is an x64 inline detour in the IL2CPP host. It is
refused with `AOWLSPT_ERR_UNSUPPORTED` in `aowlspt-sim` and in
`aowlspt-backend`, for the same reason in both: there is no compiled game code
in either process to detour, and a host that accepted a registration it can
never fire would be telling a mod its hook is installed. (The design below
carries the shape of the Harmony bridge the removed C# server and BepInEx hosts
used, which is why prefix, postfix and finalizer are named the way Harmony names
them.) A prefix handler returning
`AOWLSPT_PATCH_SKIP` suppresses the original and may write a replacement result
into the out-buffer.

`AOWLSPT_PATCH_ARGS` (0x10) is OR'd into `kind` to ask the host for the original
arguments, which then arrive in the handler's `args` slice as a JSON array in
the same shape `call` accepts. A **flag** rather than a fourth patch kind,
because it is orthogonal to prefix and postfix; **opt-in** rather than
always-on, because building that array inside a method the game may call
thousands of times a frame is a cost a patch that only counts calls should not
pay.

`patch(target, AOWLSPT_PATCH_POSTFIX, handler)` runs the handler **after** the
original and hands it what the method returned, in a `result` member beside
`this` and `args`; returning `AOWLSPT_PATCH_SKIP` with a value replaces it.
Before this, a mod that wanted to *adjust* a return value had exactly one
option — `stopWith`, which means reimplementing the method — and a
reimplementation of a method you cannot read is a guess.

The two kinds are two thunk paths rather than two readings of one. A prefix
tail-jumps into the trampoline, which is what makes the original's return value,
its stack arguments and its return address correct by construction. A postfix
has to `call` it and regain control, and pays for that with two refusals, both
made at registration rather than found at run time: a method returning a value
type wider than a register returns it through a caller-allocated buffer whose
layout the host cannot read, so a postfix there could neither report the result
nor replace it; and a method whose compiled call needs more than four register
slots has stack arguments, which a *called* original would look for in the
thunk's frame. Neither is ever silently downgraded to a prefix — a postfix that
behaved like one would hand a mod scaling a getter a value the original had not
produced yet, and the number written would be wrong rather than absent.

A reference argument is handed over as a GC handle, and the host **frees it when
the handler returns** — a per-frame hook whose author forgot would pin objects
at several per second, and that is a trap rather than a contract. Handles the
handler acquired for itself are left alone.

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

However many mods attach to one method, there is one detour on it. The engine
holds a fixed pool of **256** slots — one per patched method, claimed at attach —
which is why the two-hundred-and-fifty-seventh patch is refused with a message
about slots rather than silently sharing one. It was 16 until commit `1179ef3`,
and 16 was never a budget: each slot needed its own hand-written `aowl_thunk_N`
macro expansion and sixteen was what fitted on a screen. Two example mods
exhausted it. The thunks are gone — a slot's stub is written at attach — so
nothing is enumerated per slot any more and the constant costs only tables, 25
bytes a slot, 6.4 KB of BSS for the lot and nothing at all on the firing path.
A slot is also released and reused now (`aowl_hook_claim`/`aowl_hook_release`),
where it used only ever to be handed out, so a mod switched off and on again no
longer spends the pool down permanently.

Installing a detour **stops the world for the fourteen bytes**, as of the same
commit: `aowl_hook_arm` suspends every other thread in the process across the
prologue write, enumerating them through `ntdll!NtGetNextThread` and falling
back to `CreateToolhelp32Snapshot` where that is absent. Everything that can be
done outside the freeze is — resolving the enumerator, opening the handles,
`VirtualProtect` — so the window is the suspend sweep and the write.

The IL2CPP host spends one of those slots on its own main-thread drain,
and enters it in the same patch table a mod's patch goes into: the engine hands
slots out in ascending order — an unused slot before any recycled one, and the
free queue only once the high-water mark reaches the end of the pool — and the
firing path indexes that table by slot, so a host hook kept outside it would
shift every mod's slot by one and deliver each patch to the wrong handler.

## Typed patch frames (revision 4)

Everything above delivers a firing as JSON. Measured against the stand-in
runtime, on `EFT.Player::Ping` and with the same detour underneath: an unpatched
bound call is 3.3 ns, a prefix with JSON arguments is 645 ns, a postfix with the
result and the arguments is 1144 ns, and one that also parses a replacement back
is 1615 ns. The thunk is single-digit nanoseconds of that. The rest is the
payload — a host-side string, a GC handle per reference argument, a copy into
the mod's own heap, and a parse — and all of it exists to describe a handful of
machine words the thunk had already saved.

`patch_typed` is the same detour with none of it. The handler is an
`AowlTypedPatchFn` and is given a `const AowlPatchFrame*`: a borrowed view of
the saved registers, plus the declared kind of every slot. The same three rows
become 23.3, 24.9 and 37.3 ns. `tools/perfbench.nim` prints the table and
`aowl test` runs it every time; [PERF.md](PERF.md) has the whole of it,
including which row is noisy and why.

Three things make it work, and each is the answer to a way the JSON path spends:

**Shapes are computed once, at registration.** `installPatch` asks the runtime
what every parameter and the return type are — `il2cpp_method_get_param`,
`shapeOfType` — and keeps a byte per slot. The JSON path asks the same questions
on every firing for an answer that cannot have changed since the assembly was
compiled. Per firing the host now stores six words into a pooled frame.

**Nothing is allocated on either side.** No payload string, no GC handle for a
reference argument (the register holds the address and the mod takes it as an
address), no host-allocated buffer for a replacement — a replacement is eight
bytes written into the saved frame by `aowl_frame_set_ret_*`. That is measured
rather than asserted: `examples/highlevel` fires a typed postfix twenty thousand
times and checks that mimalloc's cumulative allocation count in the *mod* is
unchanged, and that the host's own `payloadBytes` and `handlesTaken` counters —
readable through `call("aowlspt.host::patch_stats")` — are unchanged too. The
same twenty thousand through the JSON hook move all three.

**The frame must not outlive the handler, and that is a refusal.** Frames come
from a fixed pool indexed by patch depth, not from the heap and — deliberately —
not from the host's stack. A stack frame would make a stored pointer undefined
behaviour; a pooled one is still there with `live` clear, so every accessor
refuses it and `aowl_frame_why_text` returns a sentence naming that exact
mistake. It is the same standard `handle_pointer` already holds a stored patch
argument to.

Reading is by index *and* by declared kind. `aowl_frame_flt` on a slot the
runtime says is an integer is refused rather than reinterpreted, because
reinterpreting answers a number; a `System.Single` occupies the low 32 bits of
its XMM register and reading it as a `double` gives a value unrelated to the
argument. Arguments past the fourth register position report `AOWLSPT_ARG_STACK`
and cannot be read — named rather than omitted, so argument *n* is always
declared parameter *n*.

Two things `patch` has that `patch_typed` deliberately does not:
`AOWLSPT_PATCH_ARGS` is not consulted, because the arguments are in the frame
either way and the flag exists to avoid a cost that no longer arises; and a
typed prefix may always suppress, because the rule that a prefix which never
asked for arguments may not skip exists to catch a misregistration there is no
longer any way to make.

It does **not** replace `patch`, and a mod should not reach for it by default.
JSON is self-describing, survives an argument the host cannot classify, reads a
`System.String` for you, and 2 µs at 10 Hz is 0.002 percent of a frame. This is
for the hook that fires forty times a frame. `mods/classicmovement`'s
`InertiaSmoothTilt` redirect is the worked example: it arms the typed form when
`typedPatchesReady()` and the JSON one otherwise, and says which in its state
line.

The same two method shapes are refused for a typed postfix as for a JSON one,
at registration and with the same sentences.

## Handles, and addresses (revision 3)

A handle is the only safe *durable* reference to a host object: the IL2CPP
collector moves objects, so the host holds a GC handle underneath and asks it
for the address afresh every time. That is what lets a handle survive a frame.

It is also what made a handle useless inside a frame. Everything reached through
one goes via `call` — a name lookup, a JSON build, a boxed invoke and a JSON
parse — and a mod's own fast path, binding against `GameAssembly.dll` directly,
needs the address. So a hook that fired *for* an object could only reach it back
through the slow path, at about a microsecond a time, which on a method the game
runs per entity per frame is a frame tax rather than a feature. `mods/fov` and
`mods/classicmovement` each measured exactly that and left features out.

`handle_pointer` writes the address the handle names right now. Everything about
it is refusals, and that is the design: a handle is safe *because* the host
re-asks the GC handle, an address is the thing that is not safe, and the only
useful guarantee to add is that a bad one is never produced.

- The address is read from the GC handle on every call and never cached.
- A handle from `resolve` names a *type*, and is refused with `ERR_BAD_ARG`
  rather than answered with a class pointer where an instance was expected.
- A collected or released handle is refused with `ERR_DISPOSED`.
- A patch argument whose handler has already returned is refused with
  `ERR_DISPOSED` **and a sentence saying so**, because that is the mistake a mod
  will actually make and "no such handle" would send the reader looking at their
  own bookkeeping instead of at the lifetime.

What no ABI can refuse is an address a mod wrote down and used next frame; by
then it is a number. `handle_pin` is the honest way to keep one — a second,
*pinned* GC handle over the same object, whose address does not move — and the
cost is stated rather than hidden: the collector may not move that object, and
may not for the rest of the session unless the mod calls `handle_release` on the
pin. Pin the two or three long-lived things a mod really tracks; take an address
and drop it for everything else.

## Threading

`on_update` runs on the host's main thread — whatever that host's main thread
is. In `aowlspt-sim` it is the simulator's own loop. On the
IL2CPP client host it is the host's **own attached thread**, and `invoke_main`
does *not* queue onto that one: it queues onto whichever thread drains the
queue, which is Unity's when the host managed to detour a per-frame method and
the host's own when it did not. The host reports which at boot and answers
`call("aowlspt.host::main_thread")` for a mod that needs to branch on it.

That distinction is not pedantry: touching a GameObject off Unity's real main
thread throws or corrupts, so a mod that needs the frame loop needs to know
whether it got it. See [IL2CPP.md](IL2CPP.md).

A mod that declares `AOWLSPT_MOD_THREAD_SAFE` is promising its callbacks may be
invoked off the main thread. Most should not.

## Reload

**`aowlspt-sim --watch` only.** The simulator notices its mod's library changing
on disk, unloads it and loads it again — which is the edit loop, and is why it
is the one host that does this. `aowlspt-backend` and the IL2CPP client host do
not reload; what they have is unloading, below.

`state_save`/`state_load` and `AOWLSPT_MOD_HOT_RELOADABLE` are still in the
header and are still what a mod declares to say it can survive being swapped.
No host in this repository carries state across a reload today: the C# engine
that did (`ModHost.Reload`) went with the C# simulator, and the nimony reload is
a plain unload-and-load. A mod that keeps anything worth keeping should keep it
in the **store**, which survives the reload, the process and the machine.

Windows locks a mapped DLL, so rebuilding over a loaded mod fails with a sharing
violation. Under `--watch` the simulator therefore loads a **shadow copy** of
the library, in its scratch directory, which is what leaves the file you built
writable and is therefore what makes rebuild-and-reload possible at all. An
ordinary run loads the file where it sits, so the module a debugger attaches to
is the one you built.

## Unloading

`host/common/modhost.nim` — the loader all three hosts share — can take one
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

All three hosts have one, installed with `setModTeardown` before any mod is
loaded. `aowlspt-backend`'s drops routes, event subscriptions and timers. The
IL2CPP host's drops event subscriptions, pending callbacks (under the
main-thread drain's lock, since that runs on the game thread and may be part way
through the same list) and detours. `aowlspt-sim` has a third. All three go
through the same `modhost.unloadOne`; the client host used to carry its own copy
of the loader and does not any more.

That is what live enable/disable is built on: `host/common/modcontrol.nim`
answers `mods/manager` over the event channel, and every host drains its queue
from its own loop rather than unloading inside the emit.
[MODMANAGER.md](MODMANAGER.md) is the whole of it, including what is refused and
what has never been run against a real client.

`loadOne` takes the same path a cold start takes, deliberately: a mod that loads
differently when added late is a mod whose bugs only appear one way round.

## Faults

A mod that fails its tick over and over is marked faulted and dropped from the
tick; the host keeps running. A broken mod should cost you that mod, not the
raid.

Precisely, as of commit `be5598a` and in `host/common/modhost.nim`: `tickMods`
counts **consecutive** non-`Ok` answers from `on_update`, and at
`TickFaultLimit` — **120** in a row, which is about two seconds at the client
host's 16 ms tick and about six at the backend's 50 ms — it logs
`faulted, mod disabled` and stops ticking that mod. Any `Ok` resets the run to
zero, so a mod that fails one tick in fifty all session is never disabled. The
mod stays loaded and **only its tick stops**: its routes, events, timers and
detours go on working, it is still `live`, and the manager can still list and
unload it. The status is said twice per mod for the life of the process and no
more — one `warn` on the first failure ever, one `error` on crossing the
threshold.

Until that commit the return value of `on_update` was `discard`ed, so this
paragraph described an intent rather than a mechanism.

The other half of the old sentence — "or throws past its own boundary" — was
never true and cannot be made true. A hard crash inside a mod takes the process
with it; there is no frame between the host and the mod's fault that could
catch it. What the boundary can do is refuse to *carry* an exception, which is
the next paragraph.

Unwinding across a C frame is undefined, which is why the nimony library returns
status codes everywhere instead of raising — and why nimony's own error-code
model is a good fit for this boundary rather than a limitation to work around.
