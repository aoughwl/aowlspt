# What a client-side call costs

The pitch for a native client mod is that it beats the C#/BepInEx mod it
replaces. That is true, and it is not automatic: the same mod written against
two different aowlspt APIs differs by a factor of five hundred, and only one of
those two beats C#.

This document is the numbers, how they were obtained, and what they do not
prove.

## The two paths

**The boxed path** is `AowlHostApi.call` and everything on top of it —
`aowlspt/game`'s `invoke`, `get`, `field`, and the `GameObj` chain. A mod names
a target as a string, passes arguments as JSON, and gets JSON back. Underneath:
the host splits the target, resolves the type by walking every loaded assembly,
finds the method by name and arity, parses the JSON, asks the runtime for each
declared parameter type *by name* (an allocation the runtime makes and the host
frees), boxes each argument to match, calls `il2cpp_runtime_invoke`, unboxes a
heap-allocated return, and formats it back to JSON.

That is the right design for what it is for: a mod that calls into the game
when something happens, with a target it might have read out of its own config
file. Nothing about it is wasted — every step is buying the generality.

**The fast path** is `aowlspt/fast`. A mod *binds* a method or a field once and
holds a small handle. A bound call is: pack up to five 8-byte slots, one switch
on a byte, one indirect call to the method IL2CPP compiled. A bound field read
is a load from `object + offset`. No name lookup, no allocation, no JSON, and
no crossing the host ABI at all — a mod DLL is in the same process as the
runtime, so `openIl2Cpp()` binds `GameAssembly.dll` directly and the host is
simply not on the path.

## The numbers

`tools/perfbench.nim`, against `tests/mockil2cpp`, on an Intel i9-10850K,
gcc 15.2 (ucrt64) at nimony's default optimisation. Median of three runs.

```
aowl build                                          # builds perfbench too
installer\build\perfbench.exe tests\mockil2cpp\GameAssembly.dll
```

`aowl test` builds it and runs it every time, and prints this table, because a
performance claim that is not re-checked is a performance claim that quietly
stops being true.

Be exact about what that gate asserts, though, because it is **correctness and
not a threshold**. `perfbench` exits non-zero when `methodPointer` does not land
in an executable page, when the fast call, the boxed property getter and the
direct field read disagree about `Health`, when `Add(2, 40)` is not 42, or when
the hook target's compiled body turns out to be the generic invoker — a
benchmark of a path that returns the wrong answer is a benchmark of nothing. It
also counts the detour's firings and says so if a "patched" row was really
measuring an unpatched function. What it does *not* do is compare any number
against a budget: a row that got slower appears in the printed table and does
not fail the run. Reading the table is still a person's job.

There is no `aowl build-tools`; the direct nimony line is at the top of
`perfbench.nim` if you want to build only this.

Re-run unchanged on 2026-08-19 and every row landed within noise of the figures
below, so nothing here was stale: the largest move was the boxed call by name at
1099 against 1104. That is worth saying rather than silently leaving the table
alone, because "still true" is a result of re-running it and not a property of
having written it down.

Re-derived on 2026-08-18 with msys2 ucrt64 gcc 15.2.0, by running
`installer\build\perfbench.exe --runtime tests\mockil2cpp\GameAssembly.dll`
and copying its table. The hook rows below the fold are from the same run,
which is why they are here rather than in a second table of their own.

| operation | ns/op | × fastest |
|---|---:|---:|
| boxed call, type resolved by name (host `call`) | 1103.6 | 590 |
| boxed call, class in hand (host `#n::` target) | 951.5 | 509 |
| `il2cpp_runtime_invoke` alone, arguments prebuilt | 42.9 | 23 |
| **fast call, static, 2 int args → int** | **10.07** | **5.4** |
| **fast call, instance, 1 float arg → float** | **8.40** | **4.5** |
| **fast call, instance, no args, void** | **5.95** | **3.2** |
| field via property getter, boxed invoke | 42.6 | 22.8 |
| field via host `@Name` path (JSON out) | 381.7 | 204 |
| **field via cached offset, direct load** | **1.87** | **1.00** |
| field via cached offset, int32 | 2.44 | 1.30 |
| bound call, unpatched | 3.47 | 1.85 |
| prefix hook, JSON arguments | 626.5 | 335 |
| **prefix hook, typed frame** | **23.08** | **12.3** |
| postfix hook, JSON result and arguments | 1101.7 | 589 |
| postfix hook, JSON + replacement | 1524.9 | 815 |
| **postfix hook, typed frame** | **24.11** | **12.9** |
| **postfix hook, typed frame + replacement** | **36.70** | **19.6** |

Two of these moved enough since the numbers this page used to carry to be worth
naming rather than quietly overwriting: the boxed call by name was **1235** and
is 1104, and `field via host @Name path` was **305** and is 382. Both are the
same code on a newer compiler; neither changed for a reason anybody intended,
which is the argument for re-running the table rather than remembering it.

Binding costs, measured the same run: a field binding is 1–7 µs, a method
binding 3–9 µs. Almost all of that is `findClass`, which walks every loaded
assembly. That is the whole argument for binding once: it costs about as much
as a hundred bound calls, and then it costs nothing.

### Handles, addresses and postfix patches

Two paths the table above predates, measured by `examples/highlevel` against the
same stand-in on the same machine, in the run `hostharness` drives. They are
reported here because both are new prices a mod has to choose between.

| operation | ns/op |
|---|---:|
| `pointerOf(handle)` — the address behind a handle | 8 |
| the boxed property read it replaces (`get_Health` through a handle) | 1112 |
| a bound call, unpatched | 3 |
| the same call with a postfix that only *watches* the return value | 443 |
| the same call with a postfix that reads the arguments and replaces the result | 2320 |
| **the same hook on the typed path** (`hookReturnTyped`, result read and replaced) | **80** |

**The address bridge is the cheap one and it is not close.** 8 ns against 1112:
a hook that wants anything from the object it fired for should take the address
and use its own bindings, not call back through the handle. That is the whole
capability — before it, `hookArgs` could tell a mod *which* object, and reaching
that object cost a microsecond.

**A postfix is not cheap, and the two prices are far apart.** 440 ns to watch a
return value; 2.4 µs to also build `this` and the argument list and parse a
replacement back. Both are dominated by the payload, not by the thunk — the
thunk's extra `call`/`ret` and register save are single-digit nanoseconds. So:
`hookReturn(..., withArgs = false)` when the result is all you need on the JSON
path, and `hookReturnTyped` when the hook fires once per entity per frame. At
2.3 µs, forty bots at 60 fps would be 5.5 ms a frame, which is not a patch, it
is a stutter; the same hook on the typed path is 80 ns, which is 190 µs.

Neither number includes what a mod does *inside* its handler.

### A hook's price is the payload, and there are now two payloads

`perfbench` measures all six forms on one method — `EFT.Player::Ping`, a static
compiled `Single -> Single` in the stand-in, reached through a bound call so
that the unpatched row is a real bound call and every other row is that same
call with the detour in the middle. The bench asks the mock whether that method
has a compiled body before reporting anything, because a row whose
`methodPointer` is the invoker would time the invoker and say nothing about the
method.

Median of three runs, same machine as the tables above.

| operation | ns/op | × unpatched | × the JSON form |
|---|---:|---:|---:|
| bound call, unpatched | 3.3 | 1 | — |
| prefix hook, JSON arguments | 645 | 194 | 1 |
| **prefix hook, typed frame** | **23.3** | **7** | **28× faster** |
| postfix hook, JSON result and arguments | 1144 | 344 | 1 |
| **postfix hook, typed frame** | **24.9** | **7** | **46× faster** |
| postfix hook, JSON + replacement | 1615 | 485 | 1 |
| **postfix hook, typed frame + replacement** | **37.3** | **11** | **43× faster** |

The two tables report the same hook at two different prices -- 80 ns in the
`examples/highlevel` row above and 37 ns here -- and the gap is real rather than
noise. `perfbench` arms the frame and reads it inside one binary; the mod-side
figure crosses the ABI into a mod DLL, and every accessor there is an ordinary
call rather than an inlined load, because `{.emit.}` is scoped to the module
that has the header and an inline body copied into an importing mod would not
compile. Roughly forty nanoseconds for a handler that makes six reads. Both
numbers are worth having: the first is what a mod pays, the second is what the
mechanism costs.

The JSON-plus-replacement row is the noisiest of the seven — 1590 to 2225 across
runs — because it is the only one that formats a float to text and parses it
back, and that is two allocator round trips whose cost depends on what the heap
looks like. The typed rows do not vary, because they do not allocate.

Twenty-seven to forty-two times, and the thunk is identical in every row. What
differs is what the host does with the registers the thunk saved: the JSON rows
build a string, ask the runtime what every parameter is, register a GC handle
per reference, hand the string across the ABI where the mod copies it into its
own heap and parses it, and take a host-allocated buffer back. The typed rows
store six words into a pooled frame and call.

Two of those costs are worth naming separately because they do not appear in
this table at all. `Ping` takes a float and no references, so the JSON rows here
pay **no** `il2cpp_gchandle_new`; a hook on a method with an object argument —
which is most of the interesting ones — pays one allocation and one free per
reference per firing on top of the figures above, and the typed path pays
neither. And the runtime interrogation the JSON path does per firing is exactly
what the typed path moved to registration: shapes are computed once, out of
`il2cpp_method_get_param` and `shapeOfType`, when the patch is installed.

**Allocation-free is measured, not asserted.** `examples/highlevel` fires a
typed postfix twenty thousand times and checks three counters that must not
move: mimalloc's cumulative allocation count inside the *mod* (mimalloc counters
only ever increase, so an unchanged count means no allocations at all rather
than none *net*), and the host's own `payloadBytes` and `handlesTaken`, readable
through `call("aowlspt.host::patch_stats")`. The measured result on the
stand-in: **0 allocations in the mod and 0 payload bytes in the host over 20000
typed firings, against 20000 allocations and 780000 payload bytes for the same
20000 through the JSON hook.**

The control matters as much as the result, and finding that out cost a rewrite.
The first control was the *watching* JSON postfix, whose payload is
`{"result":5.0}` — fourteen bytes, which a nimony string keeps inside the string
object with no heap block. So both paths reported zero, which proves nothing
rather than proving the typed path is free. The control is the full form now.

**When to use which.** `hookArgs`/`hookReturn` unless the hook fires per entity
per frame. JSON is self-describing, survives an argument the host cannot
classify, reads a `System.String` for you, and 2 µs at 10 Hz is 0.002 percent of
a frame. `hookTyped`/`hookReturnTyped` when the hook is on the per-frame path:
at forty bots and 60 fps the difference is 5.3 ms a frame against 60 µs, which
is the difference between a stutter and a mod.

`mods/classicmovement`'s `InertiaSmoothTilt` redirect is the worked conversion.
It reads `this` and two floats and suppresses, once per movement context per
frame, and it now arms the typed form when the host reports revision 4 and the
JSON form otherwise — saying which in its own state line, because the two differ
by roughly a hundredfold and "armed" alone would hide that.

### Reading the table

**A boxed call is ~120× a bound call, and a boxed field read is ~160× a bound
one.** In absolute terms: 1000 boxed calls per frame is a millisecond, which at
60 fps is six percent of the frame budget gone to marshalling. The same 1000
bound calls are ten microseconds.

**Most of the boxed cost is not the runtime.** `il2cpp_runtime_invoke` with the
arguments already built is 41 ns; the full host path is 950–1200. The other
900+ ns is the string and sequence work around it — JSON in, type names out of
the runtime, JSON back. Which is to say: the boxed path is slow because it is
*general*, not because IL2CPP is slow.

**`findClass` is 280 ns of every named call.** The gap between the first two
rows is the assembly walk. A mod that must stay on the boxed path should hold a
handle (`GameObj`) rather than naming its type each call — that is free and it
is a quarter of the cost.

**The `@Name` field path is six times the property getter it exists to avoid.**
Reading a field through `GameObj.field` is *slower* than a property getter,
because it does the same work plus a type-name allocation plus JSON formatting.
It exists because a great deal of what a mod wants has no property at all, not
because it is fast.

## How the fast path works

`abi/aowlspt_fast.h` has the mechanism in detail; the short version:

IL2CPP compiles every managed method to an ordinary C function, whose address
is `MethodInfo`'s first field. Its signature is the declared one plus two
conventions: an instance method takes `this` first, and every method takes a
trailing `const MethodInfo*`. Calling it is therefore a function-pointer call
with the right type — and nimony cannot form one, since it refuses to `cast`
between a `pointer` and a `proc`. So the call happens in C, which needs the
signature at compile time when the mod only knows it at bind time.

The way out is that Win64 does not care about types, only register classes.
Every integer, bool, pointer and reference is one general-purpose register;
`float` is one SSE register. Two kinds per slot, five slots (`this` plus four
arguments), three return forms — 189 generated cases, dispatched by a switch on
a packed byte. A jump table and a call.

Field offsets come from `il2cpp_field_get_offset` once at bind, bounded against
`il2cpp_class_instance_size` so a static field's offset cannot be mistaken for
an instance one, and then it is a load.

## What is still slow, and why

- **Binding.** 3–9 µs, dominated by `findClass` walking every assembly. Not
  worth fixing: it happens once. It *is* worth not doing in `onLoad` — the
  game's assemblies are not up yet then, and the binding will correctly refuse.
- **Anything `bindMethod` refuses.** `Vector3` and `Quaternion` arguments and
  returns, `double` arguments, five or more arguments, enums, generic
  instantiations, arrays. `bindMethodAs` lets a mod assert the register classes
  the inference would not commit to; `bindRaw` goes further and is described
  below. What is left after both stays on the boxed path.

  The `Vector3` case turned out **not** to need more trampolines, which is
  worth correcting because this document said it did. Win64 passes anything
  larger than eight bytes and not a power of two by hidden pointer and returns
  it the same way, so `Vector3 get_Position()` is really
  `void* f(void* sret, void* this, MethodInfo*)` — every slot a plain pointer,
  which the existing table already passes. What was missing was a way to *say*
  that a method's slot shape differs from its signature. `bindRaw` is that, and
  it is the sharpest tool in the module: the mod asserts a calling convention,
  and a wrong slot count reads an uninitialised register as an argument, which
  is a plausible number rather than a crash. Last resort, with a comment at
  every use saying why the shape is what it claims.

- **Virtual dispatch, which the fast path does not do.** A bound call goes
  straight to a compiled body, so a binding taken *by name* against
  `EFT.Player` calls `EFT.Player`'s implementation even on a subclass that
  overrides it — silently, with a plausible answer. `bindOnObject` binds against
  the class the live object actually is, walking its base chain, and
  `bindInClass` takes a class the mod already holds. That is also the only way
  to reach a generic instantiation like `List<Player>`: it has no name
  `findClass` accepts, but any instance of one can hand over its class.
- **Strings.** Passing a `System.String` argument still means
  `il2cpp_string_new`, which allocates in the managed heap. The fast path
  removes the boxing around the call, not the string itself.
- **Reference field writes.** `writePtr` goes **through** the collector's write
  barrier now, resolved once at bind time; `writePtrRaw` is the deliberate
  opt-out for a pointer the object already reachably holds, and `barrierReady`
  says which you are getting. The stand-in exports the barrier and counts
  calls, so the gate asserts both the mod's line and the runtime's counter —
  one alone proves nothing, since a stand-in without the export leaves the
  binding silently on a plain store.
- **Static fields.** `bindStaticField` reads them, through
  `il2cpp_class_get_static_field_data` and with `il2cpp_runtime_class_init`
  first, so "zero" cannot mean "the static constructor has not run". Its
  readers take **no object** — a static and an instance field share an offset
  space, and the stand-in deliberately puts `Player::SpawnCount` (static Int32)
  and `Player::Health` (instance Single) both at offset 16, where the wrong
  binding answers `1091567616` with `ok` true. Only the type system catches
  that; a `bool` flag would read the same either way.
- **Raycasts, NavMesh, physics.** Unchanged. They are in the engine and cost
  what they cost. Profile the sensing/logic split before rewriting anything.
- **The main thread.** `invoke_main` now drains from inside a per-frame method
  the host detoured, so on a build where one binds it *is* Unity's thread — and
  on one where none does it is the host's own, with a warning at boot. A bound
  call is cheap; it is still not legal to make it against a Unity object from an
  arbitrary thread, so branch on
  `call("aowlspt.host::main_thread")` rather than on the name. The drain itself
  is a handful of instructions when the queue is empty, which is most frames.

## What this measurement does not prove

**It is a stand-in runtime.** `tests/mockil2cpp` implements the same C API over
a small hand-built type universe. What the benchmark establishes is the
*mechanism*: that the argument packing, the register classes, the offset
arithmetic and the dispatch are right, and what each layer of the boxed path
costs in string and allocation work. What it cannot establish is BSG's
implementation of the same API. In particular `il2cpp_runtime_invoke`'s 41 ns
here is the mock's — it boxes into a `calloc`, and the real one does more work,
so the real boxed/bound ratio is larger than the table says, not smaller.

**The bound call is measured against a stand-in method.** The mock is faithful
about almost everything, but its `methodPointer` is a generic invoker taking
`void**` where the real runtime's is the compiled method with the declared
signature. A typed trampoline aimed at it would read a `float` out of a
register holding a `void**`. So the benchmark brings its own compiled methods,
shaped exactly as IL2CPP compiles one, reached through a `MethodInfo` whose
first field is the function pointer — the whole mechanism is on the measured
path (`methodPointer` is still read by offset and still checked for landing in
an executable page), but the callee is in the benchmark's own binary rather
than across a DLL boundary. Expect a real call to be slightly more.

The *binding* is measured against the mock's real metadata: `bindMethod`
infers `EFT.Player::Damage`'s signature from `il2cpp_method_get_param` and
`il2cpp_method_get_return_type` and reports it, and `bindField` resolves
`Health` to offset 16 and reads it — which the benchmark cross-checks against
the same value read through `il2cpp_runtime_invoke`. Three paths, one number.

**It is one machine.** Absolute nanoseconds will differ. The ratios are the
part worth quoting.

## Measuring your own loop

`allocationCount()` is exported from `aowlspt/fast` beside them, and is how
"this loop allocates nothing" becomes a measurement. It reads mimalloc's
cumulative block count out of the allocator statically linked into the calling
binary. Cumulative is the whole point: a string built and freed once per firing
leaves `getOccupiedMem` exactly where it was, so a live-bytes figure cannot tell
"allocated nothing" from "allocated and freed at frame rate".

`allocProbeOk()` checks that the counter is reading the allocator at all, by
making an allocation of known size and confirming the count moved. That is not
ceremony: the first version of this read `malloc_requested`, which mimalloc only
maintains under `MI_STAT > 1` — a debug build — and reported a confident zero
for a loop allocating at frame rate. A permanent zero is exactly the answer this
is used to establish, which makes it the worst possible field to have picked and
the reason the probe exists.

Take the counter *outside* the window you are measuring if the reading itself
allocates. `hostPatchStat` in `examples/highlevel` goes through `call`, which is
a host-allocated buffer, a string copy and a key to search for — five
allocations, which read as "20000 typed firings made 5 allocations" until they
were moved out.

`perfCounter()` and `perfFreq()` are exported from `aowlspt/fast`, with
`nanosBetween(a, b)` to turn a pair into nanoseconds — the same clock the
bindings report their own cost on, which is the point of using it rather than
`nowMs()`.

They were `importc`/`nodecl` declarations against a header included only in
`fast.nim`'s own translation unit, so a mod that imported the module and called
`perfCounter` got an **implicit-declaration error from the C compiler** rather
than anything a nimony message could explain. Two mods gave up and measured a
hot loop with a millisecond clock, which is the wrong resolution by three orders
of magnitude. They are ordinary nimony procs now: the wrapper is in the module
that has the header, and an importer calls the wrapper.

`nanosBetween` multiplies before dividing, because the frequency is around
10 MHz and dividing first turns every measurement under a microsecond into
zero.

## Measuring frame time rather than frame rate

Everything above is the cost of a *call*. The other half of a client mod's
performance story is the frame it runs in, and `mods/perf` is where that is
measured. Two things there are worth knowing outside it.

**A frames-per-second figure is a mean, and a mean cannot see a hitch.** A
second holding fifty-five even frames and one 200 ms freeze reports about the
same number as a second of sixty even ones. Best and worst over one-second
windows do not rescue it — a hitch has to last most of a second to move either.
Anything claiming to have made the client smoother has to report percentiles and
a hitch count, and `mods/perf`'s `hist.nim` is a 4 KB fixed histogram (1024
buckets of 64 µs, plus an exact tail) that does it at **26 ns a sample with zero
allocations**, measured against mimalloc's cumulative counter.

**The ABI has no repeating main-thread callback, and one can be built from the
two it has.** `every` repeats on the host's thread; `onMainThread` reaches
Unity's and does not repeat. A one-shot that queues *itself* before returning
does both — it runs inside the host's drain, the drain runs inside a per-frame
method, and `drainDue` snapshots the due list before running it, so the re-queue
lands next frame rather than spinning inside this one. `claimTick` reuses freed
slots, so the chain holds **3 scheduler slots over a thousand firings** rather
than one per frame.

Measured on the stand-in, in `mods/perf`'s own self-test:

| operation | ns | note |
|---|---:|---|
| recording one frame interval into the histogram | 26 | clock read, subtract, array store; 0 allocations over 20000 |
| one firing of the self-re-arming chain, inside the mod | ~1000 | see the correction below: the attribution in this row was wrong |
| the host's drain overhead for a non-empty queue | **89** | measured 2026-08-19; was `not measured`, and was 627 |
| `hookTyped` on a per-frame method, for comparison | 23 | the alternative, at the price of a second detour on the hottest path |

**The second row used to say `not measured`, and the note beside the first was
wrong.** It read "nearly all of it `onMainThread`'s enqueue: a host lock and a
seq append". The host's half of that is now measured — see *What the host costs
per frame* below — and it is 89 ns, of which the lock is 51 and the seq append
is not visible at all. So roughly nine hundred of that microsecond is somewhere
else: the two ABI crossings and whatever the mod does around them. `mods/perf`
is where the mod-side figure comes from and it is not re-derived here; what is
corrected is the claim about *where the time went*, which was a guess sitting in
a table of measurements.

One microsecond a frame is 64 parts per million of a 16.7 ms frame, which is why
the chain is the right trade for a *readout*. It is the wrong trade for anything
firing per entity per frame: at forty bots that is 40 µs against the typed
hook's 0.9 µs, and the queue is a lock the typed path does not take at all.

**A differential A/B against the stand-in could not resolve the chain's cost**,
and that is reported rather than hidden: four alternating 14-second runs gave
53.48 / 53.65 / 50.50 / 54.67 fps, so the stand-in's own run-to-run variance is
several percent against an effect of 0.006 percent. Measuring from inside the
firing is what resolves it. The general lesson is the one this document opens
with: measure the thing, not the difference, when the difference is smaller than
the noise.

## What the host costs per frame

Everything above is measured either inside a mod or inside `perfbench`, and
`perfbench` never loads the host at all — it links the fast path and the
stand-in into one binary. That is the right shape for the *call* costs and the
wrong shape for the host's own per-frame work, which runs on whichever thread
won the detoured method, with the host's allocator and the host's lock. A loop
in another binary would be timing a copy.

So it is measured where it runs. `hostharness --frame-bench N` arms a benchmark
through `call("aowlspt.host::frame_bench_arm")`; the next firing of the drain
hook runs the loops **inside that frame, on that thread**, and the harness reads
the table back through `call("aowlspt.host::frame_bench")`. Same machine and
stand-in as every other table here, 20000 iterations of the dispatch rows and
200000 of the cheap ones, median of three runs.

```
hostharness.exe installer\build\hoststage --runtime tests\mockil2cpp\GameAssembly.dll --frame-bench 20000
```

| operation | ns/op | note |
|---|---:|---|
| **`mainDrain`, queue empty** | **2.8** | what every frame costs when no mod has anything queued, which is most frames |
| `mainDrain`, one entry queued, not yet due | 32.1 | a `schedule` waiting out its delay: the gate lets the frame through and the walk finds nothing to run |
| `enqueue` + `takeDue`, no dispatch | 84.6 | the queue turned around once |
| **`enqueue` + `mainDrain`, one armed chain frame** | **89.9** | what `everyMain` costs the host per frame |
| `cMqEnter` alone, the gate | 1.65 | |
| `cMqLock` + `cMqUnlock`, uncontended | 25.5 | |
| `cNowMs` | 1.24 | |

**The empty frame is at its ceiling and the numbers say so.** 2.8 ns against a
`cMqEnter` of 1.65: the gate is two loads, a compare and an increment, and the
rest is the call around it. There is nothing to win there and no rewrite of it
should be believed without a number.

**Everything else on this path is the lock.** A chain frame is 89.9 ns and two
uncontended `EnterCriticalSection`/`LeaveCriticalSection` pairs are 51 of them —
one taken by `enqueue` and one by `takeDue`. The queue walk, the compaction and
the trampoline into the callback are the remaining forty between them.

A `gNextDueMs` published lock-free beside `aowl_mq_count` would let a frame
holding a not-yet-due timer skip the lock entirely and take row two from 32 ns
to about 4. It is **measured and declined**: 28 ns of a 16.7 ms frame is 0.0002
percent, and the price is a second racy invariant on the one path in this host
where a wrong answer is a callback that never arrives. The number is here so
that the next person to have the idea can see what it is worth before spending
an afternoon on it.

### What the boxed path costs before it does anything

Two rows the harness times from *its own* binary, because half of the cost is
the caller's — copying the reply out of the buffer the host allocated and
freeing it, which is exactly what a mod does.

| operation | ns/op |
|---|---:|
| `call("aowlspt.host::patch_stats")` — a host-internal target, no type resolved, no method invoked | 900 |
| the same crossing with a malformed target, refused before any reply is built | 338 |

That is the boxed path's floor, and it is most of the boxed path's cost: a
`call` that reaches the game is 1100 ns (top of this document), and 900 of that
is spent before any game work happens. 338 ns is the crossing itself — two
argument buffers copied into nimony strings and a status back — and the other
560 is building a hundred bytes of JSON and handing it over: a `calloc`, a
`memcpy`, a `free`, and a concatenation per field.

Which sharpens the advice at the top rather than changing it. The boxed path is
not slow because IL2CPP is slow, and it is not even mostly slow because of the
type lookup: it is slow because *asking* costs 900 ns before anything is asked.
Ask once per second, not once per frame.

### What this one does not prove either

The same caveat as every other table here, plus one of its own. The stand-in's
frame loop is a thread in a test DLL, not Unity's; the drain hook is attached to
`UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate` in the mock's own type
universe. What the table establishes is the cost of the host's code on the
thread that runs it. What it cannot establish is contention: every lock figure
here is uncontended, and it is uncontended because nothing else in a stand-in
run is calling `invoke_main` from a worker thread at the same moment. A mod that
does will pay more, and how much more is not measurable outside the game.

`--frame-bench` **is** in `aowl test`, in the "Against a live runtime" section
next to `perfbench`. This paragraph said it was not, and that it could be
because the assertions below are real ones; it was wired in the same day, once
`tools/aowl.nim` was free to edit. The timings are printed and only the three
assertions can fail the run, which is the right split: a number that moves is
information, and a drain that stopped dispatching or started allocating is a
regression.

### The assertions it makes

Four things, and each one is written so that it fails when the thing it names
stops happening rather than when a number moves:

1. **The loop dispatched.** The host counts every callback the bench's own
   `AowlCallbackFn` received, and the harness checks that it moved once per
   armed frame. Without this every row is a benchmark of a drain that dropped
   its queue on the floor, which would time beautifully.
2. **An armed chain costs the host zero allocations.** mimalloc's cumulative
   block count inside the host, bracketed around the chain loop. Cumulative, so
   nothing on the free path can lower it back to a passing figure. Against the
   drain as it stood the day before this was written the figure is **40000 over
   20000 frames** — exactly two — and the check fails.
3. **The empty-queue gate short-circuits.** An empty frame must be cheaper than
   one that walks the queue. 2.8 against 32 is an order of magnitude, so this
   is a check rather than a coin toss; if `cMqEnter` ever stopped answering
   early the two would converge and nothing else here would notice.
4. There is no fourth. There was: it asserted that a chain frame costs more
   than the same turnaround without a dispatch. True, and about 5 ns of truth
   against two rows whose run-to-run spread is fifteen — it failed on the first
   run where the noise went the other way. A check that reports the weather is
   not a check. The dispatch difference is printed and not asserted, and what
   it was trying to establish is what assertion 1 establishes exactly.

### What changed, and by how much

One change: `drainDue` was split into `takeDue` and `runDue`, `takeDue`
compacts `gPending` in place instead of building a replacement seq, and the
drain thread reuses one snapshot buffer instead of allocating a fresh one every
frame. The two callers that are *not* the drain thread — `runPending` when the
hook has gone quiet, and a drain re-entered from inside a callback — still take
a local buffer, which is what makes the shared one safe to have.

| operation | before | after | |
|---|---:|---:|---:|
| `mainDrain`, queue empty | 3.13 | 2.84 | unchanged; both are the gate |
| `mainDrain`, one entry queued, not due | 248.2 | 32.1 | **7.7×** |
| `enqueue` + `takeDue` | 349.8 | 84.6 | **4.1×** |
| `enqueue` + `mainDrain`, one chain frame | 626.8 | 89.9 | **7.0×** |
| host allocations per chain frame | 2 | **0** | |

The before column is the same binary with `takeDue` restored to the shape it
had and `mainDrain` calling `drainDue`, built and measured the same afternoon —
one run of it against a median of three of the after, which is fine at these
ratios and would not be at a ratio near one.
Two allocations a frame is 120 a second at 60 fps, which is not a stutter and
was never going to be one — the point is the seven-fold, and that the number
existed at all where the table said `not measured`.

## What a mod should actually do

1. Use `aowlspt/game` for everything that is not per-frame. It is the pleasant
   API and 1 µs is nothing at 10 Hz.
2. Bind, in `onUpdate`, guarded on `ok`, on the first frame the type resolves —
   not in `onLoad`, where the game's assemblies do not exist yet. Bind against
   the *object* rather than a type name whenever the method might be overridden.
3. Read the binding's `why` into the log once. It says what the signature was
   inferred to be, or why it was refused. A refused binding is a mod that will
   quietly do nothing otherwise.
4. Never store a raw object pointer across frames. The collector moves objects.
   Hold a `Handle`, resolve it to a pointer once per frame, and spend the frame
   on the fast path.
5. Do the work off the main thread. This is the win a C# mod largely cannot
   have: pull state into native structs once per tick, compute, write back a
   minimal result. No GC, no allocation spikes, and the arithmetic is not on
   the frame's critical path at all.
