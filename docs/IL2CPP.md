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

This repository used to carry a Mono BepInEx plugin host. It could not load into
a post-1.0 client and no flag changed that, so it is gone along with the SPT 4.x
server mod beside it. `host/Aowlspt.Host.Il2Cpp` is the post-1.0 answer.

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
| `invoke_main`, `schedule` | yes — on Unity's main thread when the host bound its per-frame drain, on the host's own thread when it did not, and the host says which; see below |
| `resolve` / `call` | yes: any type, any method, with arguments, by name |
| live objects | yes: a reference return comes back as a handle you can call on |
| fields | yes: `Type::@Name` reads one, and with an argument writes it |
| `patch` | yes: an x64 inline detour on the compiled method |
| a patch's arguments | yes, with `AOWLSPT_PATCH_ARGS`: up to four, by declared type |
| suppressing the original | yes, if a return value of the declared type can be produced |
| a *postfix* patch | yes: the handler runs after the original, is given `result`, and may replace it — on a method whose shape can carry one |
| `this` on the fast path | yes (ABI revision 3): `handle_pointer` turns a handle into the object's address |
| a *typed* patch | yes (ABI revision 4): `patch_typed` hands the handler the saved registers and the declared kinds instead of JSON — 23–37 ns a firing against 645–1615 |
| `notify_push` | not present: `AowlHostApi.size` stops at the revision-4 boundary, because there is no notifier socket in the game process |
| `event_emit` / `event_subscribe` | yes, delivered between mods |
| `store_get` / `store_set` / `store_list` | yes (ABI revision 2) |
| the fast path | not the host's at all: a mod binds `GameAssembly.dll` itself |
| `db_get` / `db_patch`, `route_register` | `ErrUnsupported` — server-side |

Arguments are bound to the method's **declared** parameter types, read from
`il2cpp_method_get_param`, rather than guessed from the JSON's shape — a boxed
`Single` and a boxed `Int32` are the same shape in memory and only the
declaration tells them apart. A mistyped argument is refused, not coerced.

**An enum is a number, in every direction.** `bindArgs` builds an enum argument
from a JSON number, `describeResult` returns one as a number, and a field of one
can be written from a number. Every one of those used to be wrong in a different
way: an enum argument was refused outright as something the host "cannot build
from a JSON scalar", and an enum *return* came back as
`{"handle":6,"type":"System.Int32"}` — so `asInt()` answered 0 with `ok` true, a
wrong value that reads like a right one, and the handle behind it leaked. Since
most of what this game's methods take is an enum — every state, condition,
damage kind and body part — that was a large hole rather than a corner.
`examples/highlevel` pins both directions against
`EFT.MovementContext::ApplyCondition` and `get_Condition`.

**The object header is measured, not assumed.** Deciding whether a declared type
is a small value type means subtracting the header from
`il2cpp_class_instance_size`, and that number means different things on
different runtimes: the game reports a value type's *boxed* size, header plus
payload, because that is the only form it allocates, and a stand-in can just as
reasonably report the payload. Both answers are self-consistent, so no single
number distinguishes them. One whose payload is known does: `System.Int32` holds
four bytes by definition, so whatever a runtime reports for it minus four is the
header, and `System.Double` checks that answer. `boxHeaderBytes` in `invoke.nim`
is that calibration, and a hard-coded 16 against a runtime reporting the other
way round turned every small value type into a *negative* width — enum arguments
unclassifiable, shaped calls silently falling back to reflection, and the code
looking as though it had checked. Anything here that does size arithmetic on a
value type goes through it. `mods/sain/client/live.nim` does the same for the
same reason.

A call that returns a reference type gives back `{"handle":n,"type":"..."}`, and
that handle addresses the object: `#7::Damage`. Underneath it is an IL2CPP GC
handle rather than a raw pointer, because the collector moves objects and a
pointer held across two frames is a use-after-free waiting for its moment. The
cost is that a handle must be released; a mod that forgets pins one object for
the session, which is a leak rather than a crash and is the right way round.

A handle that *is* released gives its slot back. The table used to be
append-only — `handle_release` emptied a slot and nothing ever reused it — so a
mod that resolved and released once a frame grew it by an entry a frame for the
length of a raid. Released slots now go on a queue, and the tail of the table is
trimmed whenever the top of it is empty, which is what covers the paths that
append directly: `describeResult`, `describeArgs` and `readField` are handed the
table and not the bookkeeping, so every call returning an object extends it by a
slot the queue could only fill later. The table is now the size of the most
handles held at once rather than the number ever taken; `hostharness --churn`
takes and releases eleven thousand and watches it stay at three.

Reuse is delayed as far as it can be — the queue is oldest-first — because a
recycled number is a mod that used a released handle getting somebody else's
object where it used to get "handle 7 has already been released". The sentence
survives for as long as there is anything else to hand out, and no longer.

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

Three refusals stayed for a prefix:

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

## Seeing what a method returned

A prefix can replace a return value, but only by not running the method — which
means reimplementing it, and a reimplementation of a method you cannot read is a
guess. Anything that *adjusts* what the original produced needs a **postfix**.

`patch(target, pkPostfix, handler)`, or `hookReturn` in `aowlspt/game`, runs the
handler after the original and hands it the same payload with one more member:

```
{"this":{"handle":3,"type":"EFT.Player"},"args":[4.0],"result":6.0}
{"result":6.0}                                     -- without PATCH_ARGS
```

`result` is always there. It is one register read, it costs nothing unless the
method returns a reference, and it is the reason the hook exists; the arguments
stay opt-in, because building that array is the expensive half. They are the
values the method was **entered** with — the registers saved on the way in,
which is the only place they still are once the original has run. Returning
`replaceResult(json)` changes what the caller gets, on the same terms a prefix
suppression has: the host refuses a replacement it cannot build a value of the
declared return type from, and the original's answer stands.

### How, and what it costs to do it this way

The prefix thunk tail-jumps into the trampoline. That is not an optimisation —
it is what makes the original's return value, its stack arguments and its return
address correct by construction rather than by luck — and a tail jump never
comes back. So a postfix is a **second path through the same thunk**, chosen by
a load and a branch off a per-slot table at entry, and everything the tail jump
was making correct for free becomes the thunk's problem:

- **The return registers.** RAX holds an integer or reference return and XMM0 a
  floating-point one, and nothing in the machine says which. Both are saved,
  both are published into the saved frame, the host reads whichever the declared
  return type names, and both are restored on the way out — so a postfix that
  changes nothing is bit-for-bit transparent, including on a return type the
  host could not classify.
- **Stack arguments — refused.** Arguments past the fourth register slot sit at
  a fixed offset from the rsp the original was entered with, and a `call` from
  inside the thunk's frame moves that. They could be copied down; that is a
  second thing to get wrong on a path where being wrong is a corrupted argument
  rather than a crash. The host counts the compiled call's slots — the declared
  arguments, `this`, and IL2CPP's trailing `MethodInfo*` — and refuses a postfix
  needing more than four. A prefix on the same method is unaffected.
- **Struct returns — refused.** A value type wider than eight bytes comes back
  through a caller-allocated buffer whose address arrives in RCX and returns in
  RAX. Saving and restoring RAX keeps that ABI intact, but the *value* is in
  memory whose layout the host cannot read, so a postfix there could neither
  report the result nor replace it. Installing one would be a patch that
  silently observes nothing.
- **SEH.** The call happens inside the same `.seh_proc` with the same prologue,
  so an exception thrown out of the original unwinds through the thunk's frame
  as it would through any other. What it does *not* do is run the handler — an
  unwind skips the rest of the function by definition. A postfix means "after it
  returned", not "after it finished". A mod that needs the exception case wants
  a finalizer, and a finalizer does not cross this ABI in any form.

Both refusals are made at **registration**, with a sentence naming which one it
was, rather than at the first firing. A wrong postfix corrupts a return value
silently, which is the worst failure mode available here, and a patch that
refuses to install is one a mod author can read and act on.

`tests/detour_test.c` exercises the path directly: that the postfix dispatcher
fires and the prefix one does not, that an untouched postfix is transparent,
that the handler is given the integer return out of RAX and the float return out
of XMM0 as separate slots, and that a replacement reaches the caller in both.

## The typed path, for a hook that fires per entity per frame

Everything above delivers a firing as JSON, and JSON is the right answer for a
hook that fires when something happens. It is the wrong answer for a hook on a
method the game runs forty times a frame, and the numbers are not close:
measured on `EFT.Player::Ping` against the stand-in, a prefix with arguments is
645 ns and a postfix that replaces a result is 1615 ns, against 3.3 ns for the
unpatched bound call. The thunk is single-digit nanoseconds of that; the rest is
the payload.

`patch(target, kind, handler)` becomes `patch_typed(target, kind, handler)`, or
`hookTyped` / `hookReturnTyped` in `aowlspt/game`, and the handler is given a
`PatchFrame` instead of a string: a borrowed view of the very registers this
thunk saved, plus the declared kind of every slot. The same two rows become 23.3
and 37.3 ns.

```nim
proc onTilt(f: PatchFrame): TypedResult =
  let obj = cast[Il2CppPtr](f.selfPointer())    # `this`, straight out of RCX
  var ok = false
  let a = f.argFloat(0, ok)                     # declared parameter 0, by kind
  if not ok or obj == nil: return frameContinue()
  ...
  if f.setResultVoid(): frameReplace() else: frameContinue()
```

Four things about it, and each is the answer to a way the JSON path spends:

- **The shapes are worked out at registration.** `installPatch` asks
  `il2cpp_method_get_param` and `shapeOfType` what each parameter is, once, and
  keeps a byte per slot. The JSON path asks the same questions on every firing
  for an answer fixed when the assembly was compiled.
- **Nothing is allocated, on either side.** No payload, no GC handle for a
  reference argument — the register holds the address and the mod takes it as an
  address, on the same terms as `handle_pointer` — and no host-allocated buffer
  for a replacement, which is eight bytes written into the saved frame. This is
  measured: `examples/highlevel` fires twenty thousand typed firings and checks
  that the mod's allocation count and the host's `payloadBytes` and
  `handlesTaken` are all unchanged, while the same twenty thousand through the
  JSON hook move all three.
- **Reads are by index *and* by declared kind.** Asking for a float where the
  runtime says integer is refused rather than reinterpreted. Reinterpreting
  answers a number, which is exactly the failure mode this whole file keeps
  coming back to.
- **The frame dies with the handler, and that is a refusal.** Frames come from a
  fixed pool rather than the stack, precisely so that a mod which stored one
  reads a cleared struct and a sentence naming the mistake instead of undefined
  behaviour. `frameWhyText()` returns it.

`AOWLSPT_PATCH_ARGS` is not consulted — the arguments are in the frame either
way — and a typed prefix may always suppress, because the misregistration that
rule exists to catch cannot be made. The two postfix refusals are unchanged.

`tests/detour_test.c` pins the frame's byte offsets to the thunk's own assembly
and exercises the accessors directly: that an untouched typed hook is
bit-for-bit transparent both ways round, that `this` and the arguments come back
by position with the instance shift applied, that the integer and float returns
are two separate slots and reading one as the other is refused, and that a frame
read after its handler returned refuses with `AOWL_FRAME_EXPIRED`.

## `this`, as something a mod can use

`hookArgs` delivers `{"this":{"handle":N,...},...}`, and until revision 3 that
handle was the end of the road: it addresses the object through `call`, and
there was no way to turn it into the `Il2CppPtr` that `bindOnObject` and
`ShapedArgs` take. So a hook that wanted to *do* something to the object it
fired for was on the boxed path at about a microsecond a call. `mods/fov`
measured that at ~1 µs per player per frame and left two members alone;
`mods/classicmovement` the same for two more, which with forty bots is
milliseconds of frame time to remove a lean delay.

`AowlHostApi.handle_pointer` — `pointerOf` in the nimony library, or
`thisPointer(args)` in `aowlspt/game` — writes the address the handle names
right now. Measured against `tests/mockil2cpp`: **8 ns**, against **1112 ns**
for the boxed property read it replaces.

The address is good for the call it was obtained in and no longer. The host
reclaims a patch argument's handle when the handler returns, and asking
afterwards is **refused** — `ErrDisposed`, with a sentence saying it was a patch
argument — rather than answered with the address it used to have. What nothing
can refuse is an address a mod wrote down and used next frame: by then it is a
number, and the collector has moved the object. `pinHandle` is the way to keep
one; it takes a pinned GC handle, whose address does not move, and the cost is
that the object is immovable until the mod releases it — for the session, if it
never does.

A handle from `resolve` names a type rather than an object and is refused: a
class pointer handed back where an instance was expected is the kind of mistake
that produces a plausible number.

## `invoke_main`, and which thread you actually get

**Sometimes Unity's main thread, sometimes the host's, and the host says which
at boot.** This changed recently and the old sentence — "it is never Unity's
thread" — is no longer true, so it is worth reading rather than skimming.

The mechanism: there is no API that hands a native DLL Unity's player loop, so
the host **detours a method Unity runs once per frame** and drains its queue from
inside it. Whichever thread first reaches that detour claims the drain with an
interlocked exchange — nothing guarantees the hooked method is called from one
thread only, and two threads draining one queue would run a mod's callbacks
concurrently. Anyone else who arrives is counted and sent away.

The candidates are tried in order, and each is a different bet:

| | why it is on the list |
|---|---|
| `EFT.MainApplication::Update` | the game's own frame method — best, if this build has it |
| `EFT.GameWorld::Update` | present once a raid exists |
| `UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate` | engine code, driven from `Canvas.willRenderCanvases` on the main thread — the reliable fallback |
| `UnityEngine.Time::get_deltaTime` | last, and reluctantly: a main-thread-only API, so its caller is on that thread, but it runs many times a frame and its compiled body may be shorter than the 14 bytes a jump needs, in which case the engine refuses it and the loop moves on |

If none of them binds, the queue is drained by the host's own tick thread
instead, and the host **warns** — including from a self-test callback that
reports the thread it ran on. A mod can ask outright:

```
call("aowlspt.host::main_thread")
-> {"bound":true,"method":"EFT.MainApplication::Update","mainThreadId":4711,
    "hostThreadId":8120,"frames":9042,"otherThreadFires":0,"stalled":false}
```

`bound` is true only once the hook has **actually fired**: a hook that is
installed but has never been reached has proved nothing, and a mod that trusted
"installed" would touch a Unity object from the wrong thread. That target is
answered before the runtime check, because "the host thread, and no main thread
was found" is a meaningful answer even with no runtime at all — and a dot in the
type part keeps it clear of any real IL2CPP type, whose class name never has
one.

The empty-queue path is two loads, two branches and an increment: no lock, no
allocation, no call into the runtime. Being called ten times a frame instead of
once is a difference in noise rather than in frame time.

The drain hook takes a slot in the same pool a mod's patch does, and is
entered in the host's patch table like one. It has to be: the firing path
indexes that table by slot, so a host hook kept outside it would shift every
mod's slot by one and deliver each patch to the wrong handler.

**Slots come back.** The pool used to be one-way: removing a detour restored the
method's bytes and freed the trampoline, but neither the engine's slot nor the
host's row was ever spare again, so a mod switched off and on again spent one
each time and the sixteenth toggle was the end of patching for the session —
`patch()` answering "no free patch slots" with fifteen of them holding nothing.
The engine now claims and releases (`aowl_hook_claim`, `aowl_hook_release`), the
host writes its row at the slot it was given rather than at the end of its own
table, and `hostharness --churn` installs and removes a thousand detours over
the pool and checks after every removal that the method's first thirty-two
bytes are the game's again.

**And the pool is 256 slots, not sixteen.** Sixteen was never a budget: each
slot needed its own hand-written assembly thunk with its slot number baked into
its instructions, and sixteen was how many had been typed out. Two example mods
reached thirteen. A real install is eight or ten mods. The thunks are gone (see
below), so nothing is enumerated per slot any more and the constant costs only
tables — twenty-five bytes of them per slot, none of which the firing path
reads. `aowl_hook_capacity()` is what the host reports as `hookCapacity`, and it
is still bounded rather than growable, so a mod stuck in an install loop is told
"no free patch slots" instead of quietly eating address space.

A claim takes a slot that has never been used before it takes a recycled one,
and only falls back to the free queue once all 256 have been handed out at least
once. With two live hooks the queue was oscillating over slots 0 and 1, so
"oldest-first puts every other free slot between the two" described a queue that
never held more than one entry.

**And a slot that comes back cannot deliver somebody else's firing.** Removing a
detour puts the method's bytes back, but a thread already inside the thunk keeps
running it, and by the time it reaches the dispatcher the slot may belong to a
different patch — whose handler would then run with the arguments of a method it
was not written for. That is worse than a crash, because it looks like it
worked.

**A firing carries its own hook with it.** There used to be sixteen fixed
thunks, one per slot, each knowing nothing but its slot number and looking the
rest up in slot-indexed tables. That is a window, and it was measured rather
than argued about: a thread preempted between the jump landing on its thunk and
those loads read the trampoline *and* the generation after the slot had been
released and re-claimed. The pair belonged to the new occupant and therefore
agreed with each other, the generation check passed, and the other hook's
handler ran with this method's arguments. `tests/detour_race.c` saw exactly
`decoy(x)` come back — a value only the other function's body computes — in
about one loaded run in six.

So the thunk is bound to the **hook** rather than to the slot. Installing a
patch writes a 24-byte stub into the same never-reclaimed block the trampoline
lives in:

```
mov r11, <this hook's record>
jmp [rip+0] ; aowl_thunk_common
```

and the record holds the trampoline, the slot, the generation and the postfix
flag together. One thunk serves every hook, and everything a firing knows comes
out of one allocation that belongs to one hook for ever and is never written
again after the jump goes in. There is no window in which two of those four can
describe different patches, because there is no lookup.

The generation stays, and its job is now narrow and exact. The **slot** is still
shared — the host indexes its patch table by it, because the alternative is a
lookup on the firing path — so a firing left over from a removed patch must not
be delivered to whichever patch claimed the slot next. The hook's record carries
the generation it was installed under; `aowl_patch_dispatch` compares that
against the slot's current one and, on a mismatch, lets the original run rather
than delivering the firing. Letting it run is safe and true: the trampoline it
will run came out of the same record, and a released trampoline is retired
rather than freed, so it is still mapped and still that method's own prologue.

**And arming one stops the world for the fourteen bytes.** The prologue write is
not one instruction and cannot be made into one, so a thread executing the
method while those bytes go in runs the half of an instruction that is left.
Until commit `1179ef3` the write went in unparked and that was a real if rare
tear. `aowl_hook_arm` now suspends every other thread in the process across it,
enumerating them through `ntdll!NtGetNextThread` and falling back to
`CreateToolhelp32Snapshot` where that is absent — and then checks, with
`GetThreadContext`, that nobody is standing *inside* `[target, target + stolen)`,
because a thread parked there resumes into the middle of the new jump. If
anybody is, everyone is released and it tries again, bounded by
`AOWL_PARK_RETRIES`; on exhaustion the write goes ahead unparked rather than
hanging the client, and the giveup is counted (`aowl_hook_park_giveups`).

The constraint that shapes it is that **nothing inside the freeze may take a
user-mode lock** — a suspended thread keeps whatever it held, and an arming
thread that waits on it is a hang with no thread to blame. So the trampoline,
the site record and the stub are built beforehand in `aowl_hook_prepare_ex`, and
the enumeration, the `GetProcAddress` and every handle open happen in
`aowl_park_begin` before the first `SuspendThread`. What is left in the window
is the suspend sweep, two `VirtualProtect` calls and the stores.

The cost is a product number rather than a test artifact, because live enable
and disable both pay it on a mod-manager click: about 11 µs per thread inside
the freeze and about 0.8 µs per thread outside it, so a park on a 65-thread
process is around 0.9 ms of which 0.7 ms is frozen. A hitch, not a hang. The
Toolhelp fallback adds about 2 ms flat, all of it outside the freeze. A process
with more than `AOWL_PARK_MAX` (512) threads, and any thread created after the
enumeration, are not parked — both deliberately.

None of this costs anything on the firing path: `perfbench` measures a typed prefix firing at 23.6
ns before and after, a typed postfix at 23.5 against 25.7, and one bare firing
at 2.9 ns either way. `aowl_hook_stale_fires()` counts the firings dropped —
counted rather than assumed, because a reuse race being caught and a reuse race
not happening answer identically from outside.

`schedule` runs on the same queue and the same thread, deliberately. Leaving
delayed callbacks on the host thread would give better timing — the host ticks
every 16 ms regardless of what the game is doing, where the drain resolves a
delay at frame granularity and a frame can be long — but then there would be no
way to get a *delayed* callback onto the main thread at all.

**None of this has been seen against BSG's client.** Which candidate binds
there, and whether it is really the player loop's thread, is exactly the sort of
thing the stand-in cannot answer. Read the boot log.

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
ok    nothing the host holds grows with the cycle count
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
[MODDING.md](MODDING.md). This used to point at the one verdict that came out
red on msys2 ucrt64 gcc 15.2, where the stand-in's `Tick` and `Hurt` compiled to
prologues the detour engine would not relocate. That caveat has gone: on gcc
15.2.0 with `GameAssembly.dll` rebuilt from `mockil2cpp.c`, all twenty-four
verdicts are green. If one goes red on your toolchain it is still a stand-in
artefact rather than a hole in the engine, but it is no longer expected.

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
installer stages carries that key set to **0**, with a line above it saying what
it is for, and 0 means "do not ask" — so by default the panel is read-only and
lists what the host pushed into it, which is what is actually running in that
process and the one source that cannot be stale. Set a port and the host also
polls the backend for which client mods should be running; see
[MODMANAGER.md](MODMANAGER.md).

## If you are porting a client mod for performance

Worth knowing before you start, because the obvious port can come out slower.

`il2cpp_runtime_invoke` boxes its arguments and dispatches generically, and the
host's `call` on top of it parses JSON in and formats JSON out. Measured, that
is 952–1235 ns a call against 10 ns for a bound one — so a native mod that stays
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
