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
aowl build-tools           # or the direct nimony line at the top of perfbench.nim
perfbench tests\mockil2cpp\GameAssembly.dll
```

| operation | ns/op | × fastest |
|---|---:|---:|
| boxed call, type resolved by name (host `call`) | 1235 | 654 |
| boxed call, class in hand (host `#n::` target) | 952 | 504 |
| `il2cpp_runtime_invoke` alone, arguments prebuilt | 41 | 22 |
| **fast call, static, 2 int args → int** | **10.2** | **5.4** |
| **fast call, instance, 1 float arg → float** | **8.4** | **4.5** |
| **fast call, instance, no args, void** | **6.5** | **3.4** |
| field via property getter, boxed invoke | 48 | 26 |
| field via host `@Name` path (JSON out) | 305 | 162 |
| **field via cached offset, direct load** | **1.88** | **1.00** |
| field via cached offset, int32 | 2.5 | 1.3 |

Binding costs, measured the same run: a field binding is 1–7 µs, a method
binding 3–9 µs. Almost all of that is `findClass`, which walks every loaded
assembly. That is the whole argument for binding once: it costs about as much
as a hundred bound calls, and then it costs nothing.

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
- **Anything the fast path refuses.** `Vector3` and `Quaternion` arguments and
  returns, `double` arguments, five or more arguments, enums, generic
  instantiations, arrays. These stay on the boxed path. The `Vector3` case is
  the one that will bite: Win64 passes a 12-byte struct by hidden pointer,
  which is a different call shape rather than a different register class, and
  covering it means generating more trampolines rather than more cases.
- **Strings.** Passing a `System.String` argument still means
  `il2cpp_string_new`, which allocates in the managed heap. The fast path
  removes the boxing around the call, not the string itself.
- **Reference field writes.** `writePtr` skips IL2CPP's write barrier, because
  `il2cpp_gc_wbarrier_set_field` is not in the binding. Safe for a pointer the
  object already reachably holds; not safe for a fresh allocation.
- **Static fields.** `il2cpp_field_get_offset` on a static field returns an
  offset into the class's static data block, which needs
  `il2cpp_class_get_static_field_data` to reach. `bindField` refuses them.
- **Raycasts, NavMesh, physics.** Unchanged. They are in the engine and cost
  what they cost. Profile the sensing/logic split before rewriting anything.
- **The main thread.** `invoke_main` still queues onto the host's own attached
  thread, not Unity's. A bound call is cheap; it is still not legal to make it
  against a Unity object from an arbitrary thread.

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

## What a mod should actually do

1. Use `aowlspt/game` for everything that is not per-frame. It is the pleasant
   API and 1 µs is nothing at 10 Hz.
2. Bind, in `onUpdate`, guarded on `ok`, on the first frame the type resolves —
   not in `onLoad`, where the game's assemblies do not exist yet.
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
