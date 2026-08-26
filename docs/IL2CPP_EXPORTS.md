# The il2cpp export surface of GameAssembly.dll — a measured map

Build: `D:\Games\Tarkov\GameAssembly.dll`, 123,891,024 bytes, 2026-08-12.
Everything below was produced **offline and read-only**, by disassembling the
file on disk. The game was never started and no export was ever called.

Tools added by this work, both offline:

* `tools/il2cpp_exportmap.py <GameAssembly.dll> [--all] [--json=out]`
  — parses the PE export directory, classifies every export's prologue.
  Full output for the 241 `il2cpp_*` exports is checked in as
  `docs/il2cpp-export-map.txt`.
* `tools/il2cpp_gatemap.py <GameAssembly.dll>`
  — finds the exports that check a 32-byte caller-supplied token, and prints
  the expected token for the ones where it is a static constant.

---

## 0. The headline

**This build is not "IL2CPP with reflection removed". It is stock IL2CPP with a
token-gated export ABI bolted on, and a failure path that deliberately returns
random garbage.**

Nothing is stubbed out. `il2cpp_class_from_name`, `il2cpp_class_get_name`,
`il2cpp_object_get_class`, `il2cpp_value_box`, `il2cpp_class_get_fields` are all
full, real, working implementations. What defeated us is that **38 of the 241
`il2cpp_*` exports take an EXTRA trailing argument we never passed** — a pointer
to 32 bytes — and when that check fails they return a **uniformly distributed
random non-zero 64-bit value**.

That single fact explains every symptom this project has recorded: a non-nil
handle, a nil check that passes, a first dereference that kills the client, and
an API that "works" for some calls and not others (the ungated ones work).

### The trap, measured

`il2cpp_class_from_system_type` @ `0x5B1960`:

```
1805b196c  test rdx, rdx
1805b196f  je   0x1805b19a9          <- no token supplied
1805b1971  mov  r8d, 0x20            <- 32 bytes
1805b1977  lea  rdx, [rip + 0x5fb3072]   <- expected token, .rdata 0x65649F0
1805b197e  mov  rcx, rax             <- token the CALLER passed
1805b1981  call 0x1806206d0          <- memcmp
1805b1986  test eax, eax
1805b1988  jne  0x1805b19a9          <- mismatch
...
1805b19ae  jmp  0x1805b64e0          <- the trap
```

`0x5B64E0` sets two per-thread flag bits at `TLS+0x16B4`, lazily seeds a
per-thread **MT19937-64** (`0x52B7E0`: multiplier `0x5851F42D4C957F2D`, 312
words, seeded from `0x5EE0A8`), stores distribution bounds `a=1`,
`b=0xFFFFFFFFFFFFFFFF` at `TLS+0x6540`, and tail-calls `0x52A570` — a uniform
integer draw. **The return value on a failed token check is a random non-zero
integer.** `il2cpp_class_get_name` uses a sibling trap at `0x5B67E0`.

Note the flag bits: a violation is *recorded* in thread-local state.
Whether anything reads or reports them is **INCONCLUSIVE** — not traced.

### The two gate flavours

| flavour | count | what the caller must pass |
|---|---|---|
| STATIC-token | 20 | 32 constant bytes that sit in `.rdata`. Extracted; see below. |
| NONCE-token  | 18 | 32 bytes derived from a per-API single-use nonce. |

The 20 static tokens are overlapping 32-byte windows, at 8-byte granularity,
into one pseudorandom byte array around `.rdata:0x6564880`. Each gated API gets
its own window offset. They are printed in full by `tools/il2cpp_gatemap.py`.

The nonce flavour, measured at `il2cpp_class_from_name` @ `0x5B1B80`:

* the callee reads a 64-bit nonce from a **per-API TLS slot** (`+0x2B0` for
  `class_from_name`, `+0x280` for `class_get_name`), then **zeroes the slot** —
  single use;
* if the slot is zero, it goes straight to the trap;
* otherwise it calls a per-API derivation function (`0x5BA6F0` for
  `class_from_name`, `0x5B9BF0` for `class_get_name`) with the nonce in RCX and
  **memcmps its return pointer against the caller's 32 bytes**;
* the nonce is produced by an exported, **non-stock** function:
  **`il2cpp_nonce(uint32 apiId)`** @ `0x5B3D60` → `0x5B1010`, a jump table over
  `apiId` in `[0x19, 0x95]` (125 arms). Each arm draws fresh entropy
  (`0x5575B0`), writes it to that API's TLS slot, and **returns it**.

So the caller-side protocol is: `nonce = il2cpp_nonce(id)`; derive 32 bytes from
`nonce`; pass them as the last argument. The derivation function is *in the
module* and callable by RVA, which is how we already call everything else.

**What is measured here:** the callee-side sequence, the TLS slots, the
zeroing, the derivation call's ABI *at its call site* (`RCX = nonce`, returns a
pointer to 32 readable bytes), the trap's random return, `il2cpp_nonce`'s
dispatch shape.
**What is NOT measured (INCONCLUSIVE):** which `apiId` maps to which API; what
the derivation functions compute internally; whether calling them out of band
has side effects.

### Argument position

The token is the **last** parameter, appended to the stock signature.
Measured: `il2cpp_class_get_name(RCX=klass, RDX=token)`;
`il2cpp_class_from_name(RCX=image, RDX=ns, R8=name, R9=token)`;
`il2cpp_class_from_system_type(RCX=?, RDX=token)` — and note that one reads its
real argument from `[RCX+0x10]`, so its RCX is **not** a bare
`Il2CppReflectionType*`. Anyone using these must derive each frame from its own
disassembly, not from this sentence.

---

## 1. Structural map

* **386 exports total; 241 begin with `il2cpp_`.**
* **All 386 live in `.text`.** None in the `il2cpp` section. No forwarders.
  No export RVA is unmapped. **No export is the universal empty-body stub at
  `0x628110`** — the 6,438-method stub applies to *generated* methods, not to
  the runtime API.
* No export's prologue jumps outside a code section. Three (`il2cpp_free`,
  `mono_metadata_free_mh`, `mono_string_free`) are `jmp qword [rip+0x6b0cb69]`
  — a `.data` function pointer, which is the stock `il2cpp_set_memory_callbacks`
  indirection, not a hook.
* **Static hook detection is a PASS only for the file on disk. Whether anything
  hooks these at RUNTIME is INCONCLUSIVE** and cannot be settled offline; it
  would need a live memory read, which this task forbade.

Prologue classification of the 241 `il2cpp_*` exports:

| class | n | meaning |
|---|---|---|
| `body` | 149 | real function |
| `tailjump` | 43 | `jmp` to the real implementation |
| `accessor` | 33 | ≤3 instructions: dereference the receiver, return the value |
| `ret0-stub` | 9 | returns 0/does nothing |
| `const-stub` | 7 | returns a literal |

**The `accessor` class is the second booby trap, and it is not malice — it is
inlining.** `il2cpp_object_get_class` is literally `mov rax,[rcx]; ret`;
`il2cpp_class_instance_size` is `mov eax,[rcx+0xF8]; ret`;
`il2cpp_array_length` is `mov eax,[rcx+0x18]; ret`. These validate nothing. Pass
a pointer that is not what they expect and you get a plausible number or a
plausible pointer, with no error. CLAUDE.md §5's claim that
`il2cpp_object_get_class` "faults" is **wrong about the mechanism**: it faults
only because the pointer handed to it was bad, or because a *gated* call
upstream already returned a random pointer.

The 9 `ret0-stub`s are the ordinary release-build no-ops — debugger agent,
external allocation/wbarrier trackers, android network state, unhandled
exception policy, thread affinity. 8 of them share `0x2FC0` (`C2 00 00`) with
23 exports total. **Nothing a mod needs is stubbed.**

---

## 2. Status of every API a class injector needs

Status vocabulary: **INTACT** = real code, no token; **GATED-STATIC** = real
code, needs 32 known constant bytes; **GATED-NONCE** = real code, needs
`il2cpp_nonce` + derivation; **TRAP** = returns random garbage if you get it
wrong (all gated entries are also TRAP).

| API | RVA | status |
|---|---|---|
| `il2cpp_object_new` | `0x5B4AF0` | INTACT |
| `il2cpp_gc_alloc_fixed` | — | INTACT |
| `il2cpp_gc_free_fixed` | — | INTACT |
| `il2cpp_gchandle_new` | `0x5B3A20` | INTACT |
| `il2cpp_gchandle_new_weakref` | — | INTACT |
| `il2cpp_gchandle_get_target` | `0x5B3A70` | INTACT |
| `il2cpp_gchandle_free` | `0x5B3B10` | INTACT |
| `il2cpp_runtime_class_init` | `0x5B4BF0` | INTACT |
| `il2cpp_runtime_object_init` | `0x5B4C00` | INTACT |
| `il2cpp_runtime_invoke` | `0x5B4BE0` | INTACT |
| `il2cpp_object_get_virtual_method` | `0x5B4AE0` | INTACT |
| `il2cpp_object_get_class` | `0x005520` | INTACT (accessor — validates nothing) |
| `il2cpp_class_is_assignable_from` | `0x5B19F0` | INTACT |
| `il2cpp_class_instance_size` | `0x5B2690` | INTACT (accessor) |
| `il2cpp_class_value_size` | `0x5B2700` | INTACT |
| `il2cpp_class_set_userdata` / `_get_userdata_offset` | — | INTACT |
| `il2cpp_type_get_object` | `0x5B52E0` | INTACT |
| `il2cpp_type_get_name` | `0x5B5330` | INTACT |
| `il2cpp_string_new` / `_utf16` | `0x5B4C30` / `0x5B4C50` | INTACT |
| `il2cpp_domain_get` / `_get_assemblies` | `0x5B2DB0` / `0x5B2DD0` | INTACT |
| `il2cpp_assembly_get_image` | `0x005520` | INTACT (accessor) |
| `il2cpp_image_get_class` / `_class_count` | `0x5B55C0` / `0x00F2C0` | INTACT |
| `il2cpp_add_internal_call`, `il2cpp_resolve_icall` | `0x5B1860`, `0x5B1870` | INTACT |
| `il2cpp_value_box`, `il2cpp_object_unbox` | `0x5B4B10` | INTACT |
| `il2cpp_class_get_type` | `0x5B2870` | **GATED-STATIC** token@`.rdata:0x6564AF0` |
| `il2cpp_class_from_system_type` | `0x5B1960` | **GATED-STATIC** token@`0x65649F0` |
| `il2cpp_class_get_parent` | `0x5B2610` | **GATED-STATIC** token@`0x6564DA0` |
| `il2cpp_field_get_offset` / `_type` / `_value` | `0x5B3310` / `0x5B34F0` / `0x5B3530` | NONCE / STATIC / STATIC |
| `il2cpp_class_from_name` | `0x5B1B80` | **GATED-NONCE** |
| `il2cpp_class_from_il2cpp_type`, `_from_type` | `0x5B1A70`, `0x5B2760` | **GATED-NONCE** |
| `il2cpp_class_get_methods` / `_get_method_from_name` | `0x5B2270` / `0x5B23E0` | **GATED-NONCE** |
| `il2cpp_class_get_fields` / `_get_field_from_name` | `0x5B1CB0` / `0x5B2150` | **GATED-NONCE** |
| `il2cpp_class_get_name` | `0x5B2500` | **GATED-NONCE** |
| `il2cpp_method_get_object` / `_from_reflection` | `0x5B3EC0` / `0x5B3DB0` | **GATED-NONCE** |
| `il2cpp_method_get_class` / `_declaring_type` | `0x5B4350` / `0x5B44F0` | **GATED-NONCE** |
| `il2cpp_method_get_return_type` / `_param` / `_param_count` | `0x5B3D70` / `0x5B42E0` / `0x5B42A0` | GATED-STATIC |

Full gate list: run `tools/il2cpp_gatemap.py`.

### Verdict on runtime type injection

**PLAUSIBLE — not blocked. The "IL2CPP made it impossible" verdict is
overstated and should be retired.**

Reasoning, strictly from the above:

1. No API a class injector needs is missing, stubbed, or redirected. Every one
   is a real implementation in `.text`.
2. Allocation, GC handles, `object_new`, `runtime_class_init`, `runtime_invoke`,
   `add_internal_call` and `type_get_object` — the load-bearing half — are all
   **ungated**, so they can be called today with the stock signature.
3. The gated half is a **calling-convention problem, not a capability
   problem**. 20 of the 38 need 32 bytes that are already extracted and printed
   above. The other 18 need a two-step handshake through an exported function.
4. Metadata-string encryption is irrelevant to injection: we resolve names
   offline already, and the injector works with pointers.

**The export that decides it is `il2cpp_class_from_name` (NONCE), and behind it
the derivation function `0x5BA6F0`.** If the nonce handshake is reproducible,
injection is an engineering problem of the ordinary Il2CppInterop kind. If it is
not — e.g. if the derivation is keyed by something only the legitimate caller
has — then every by-name entry point stays trapped and injection has to be done
entirely from statically-resolved pointers, which is harder but still not
obviously impossible.

**Honest limits of this verdict.** I have shown nothing about the parts of
injection that do *not* go through exports: constructing a valid `Il2CppClass`
for this build's layout, splicing it into `MetadataCache`'s type table, and
making Unity's native `AddComponent` accept it. Those are internal-symbol work
and this map does not touch them. "Plausible" means *the export surface does not
block it*, not *it will work*.

---

## 3. The safest first live experiment — SPECIFIED, NOT RUN

Do not start with injection. Start with the cheapest possible test of the
**static-token hypothesis**, because it is one call, needs no nonce, and has a
reading that is unambiguous.

**Target:** `il2cpp_method_get_param_count(const MethodInfo* m, void* token32)`
@ `0x5B42A0`, token = the 32 bytes at `.rdata:0x65648B0`.

**Why this one:** its correct answer is *known offline*. Pick a method whose
parameter count `tools/il2cpp_resolve.py` already prints (it reads
`parameterCount@34` from metadata), and whose `MethodInfo*` you can obtain
without any gated call. Returns a small integer, so a random 64-bit trap value
is instantly distinguishable from a correct answer. It dereferences only a
pointer you supplied, so a wrong token cannot make it write anything.

**Protocol:**
1. Read the 32 token bytes from the DLL **at runtime, from the mapped image**,
   at `imagebase + 0x65648B0` — never hardcode `0x180000000`.
2. Call it inside one `aowl_p_p_seh`, flag-gated, default off, once.
3. Readings:
   * **PASS** — the return equals the offline `parameterCount`, and repeating
     the call returns the same value. Static tokens work; proceed to
     `il2cpp_class_get_type` next.
   * **FAIL** — the return is a large or varying value, or the two calls
     disagree. The token model is wrong; stop.
   * **INCONCLUSIVE** — a fault, the guard trips, or the offline expected count
     is itself ambiguous (shared RVA, generic). Not a pass.
4. **Control, and it is mandatory:** the same call with a deliberately
   corrupted token must produce a *different, non-repeating* value. Without
   that control, a correct-looking answer proves nothing — this is exactly the
   check-that-cannot-fail shape from CLAUDE.md §9b.

Only after that should anyone touch `il2cpp_nonce`.

---

## 4. The cheap alternative: hijack an existing MonoBehaviour

**Offline status of what it needs: all INTACT or GATED-STATIC. Nothing it needs
is nonce-gated.**

* `UnityEngine.GameObject::AddComponent(System.Type)` — **RVA `0x52A8A80`**,
  measured via `il2cpp_resolve.py type 23102`. It shares that RVA with
  `Internal_AddComponentWithType` (2 owners, an ordinary alias — calling it is
  fine; **detouring it is not**).
* The generic `AddComponent<T>()` (rid 2755) has **no RVA** — an
  un-instantiated generic definition. Do not chase it.
* Getting the `System.Type` argument: `il2cpp_class_get_type` (GATED-STATIC,
  token known) then `il2cpp_type_get_object` (INTACT). The `Il2CppClass*` itself
  can come from a live instance's first qword — no gated call at all.
  `il2cpp_string_new` (INTACT) also makes the `Type.GetType(string)` route
  available.

**Honest cost.** This does not give you a new type; it gives you *someone
else's* type with your code in its `Update`. Concretely:

* It spends a detour slot on that `Update`, and two detours on one function
  overwrite each other's trampoline. If the chosen component ever appears twice
  in the scene, your code runs twice per frame.
* You must detour a method that is **not shared**. Check sharedness first —
  28.3% of by-name lookups land on a shared RVA, and a shared `Update` detour
  fires for every type that folded onto it. This is the single largest risk in
  the approach.
* An empty `Update` body is very likely to be ICF-folded onto the universal
  `0x628110` stub, which is the worst possible detour target. **So the right
  candidate is a component with a real, non-shared, non-trivial `Update` that
  the game does not depend on** — and I have **not** identified one. Naming a
  candidate without checking its RVA's owner count would be a guess, and this
  document does not guess. That check is one `il2cpp_resolve.py type <idx>
  --shared` per candidate and is the obvious next task.

---

## 5. Corrections to CLAUDE.md §5

Both of these are measured, and both should be fixed:

* "Reflection is **dead** (`il2cpp_object_get_class`, `il2cpp_class_get_name`,
  `il2cpp_value_box`, field iteration all fault)" — **not accurate.**
  `il2cpp_value_box` and `il2cpp_object_get_class` are ungated and intact;
  `il2cpp_object_get_class` is a 3-byte `mov rax,[rcx]; ret` that cannot fault
  unless its argument is already bad. `il2cpp_class_get_name` and field
  iteration are token-gated, and returned random garbage because we called them
  with the stock signature.
* "`il2cpp_class_from_name` returns NON-NIL handles into UNMAPPED memory" —
  **true, and now explained**: that is MT19937-64 output from the token-check
  failure path, not a corrupted lookup.
