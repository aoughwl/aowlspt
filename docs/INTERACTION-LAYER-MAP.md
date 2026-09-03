# The interaction layer — how the aowlspt host touches the live client

Every crash of 2026-09-02 and 2026-09-03 was a defect in **this layer**, not in a
feature. A feature bug makes a label wrong; an interaction-layer bug kills a
running game, sometimes ten minutes later, sometimes only for one user. This
document is the map of that layer, in the rigour of `docs/SETTINGS-UI-MAP.md`
and `docs/BOOT-FLOW-MAP.md`: **every claim is tagged MEASURED (with the
instrument that produced it) or INFERRED**, and every section ends in testable
predicates with the tool that enforces each, or **UNENFORCED**.

Build under discussion: `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes),
decrypted metadata `.cache/global-metadata.dec.dat`. Imagebase `0x180000000`;
addresses are RVAs. Game-side claims were re-run with

```
python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat <verb> ...
```

abbreviated **`R <verb>`**.

## 0. The eight defects this map exists to make un-writable

| # | Defect | Date | Section that forbids it |
|---|---|---|---|
| 1 | POSTFIX thunk shifted the stack arguments of a >4-slot site (`MenuScreen::Show`, 7 slots); `Profile == 1` | 09-02 | §2.4 |
| 2 | Nonce-gated export returned a random uint64 that passed `!= nil`; first deref killed the client | 09-02 | §3.2 |
| 3 | The main-thread drain had been binding **on that random handle** for weeks; the real route was the name index all along | 09-02 | §3.4 |
| 4 | Main-thread work run on the host ops thread after a 2 s "stall" that was a 15 s cold start | 09-02 | §1.4 |
| 5 | An ARC global string (`gLastError`) assigned from two threads inside `exportc` entry points → cross-thread free | 09-03 | §1.5 |
| 6 | mimalloc compiled `MI_DEBUG=2` in **every** binary we ever shipped → `abort()` on any heap anomaly | 09-03 | §1.5 |
| 7 | A cached toggle pointer from a **lazy factory** (`` UISpawner`1::get_SpawnedObject ``) became an orphan when its object died | 09-02 | §4.3 |
| 8 | The consistency manifest is an **encrypted blob inside the exe**; the plain `ConsistencyInfo` next to it is the launcher's and is never read by the client | 09-03 | §6 |

Note the shape they share: **a check that could only say yes.** #2 and #3 are a
nil test on random data; #4 is a stopwatch that always expires; #7 is a pointer
that still reads back perfectly. CLAUDE.md §9b is the governing rule, and every
predicate below is written as a *negative* wherever a negative is available.

---

## 1. Process model

### 1.1 How the host gets in

MEASURED, `abi/aowlspt_inject.h:11-30`. Not DLL hijacking. Explicit, ordered:

1. `CreateProcess(..., CREATE_SUSPENDED)` — the process exists, its main thread
   has executed no instruction, kernel32 is mapped.
2. `VirtualAllocEx` + `WriteProcessMemory` of the host DLL path.
3. `CreateRemoteThread` at `LoadLibraryA` (the same address in every process in a
   session).
4. **Wait, and read the exit code** — the low 32 bits of the returned HMODULE.
   Zero means the load failed. `aowlspt_inject.h:26` names step 4 as the one
   people skip: *"Without it a failed injection looks exactly like a successful
   one until the mods do not appear."*
5. `ResumeThread` on the main thread.

INFERRED consequence, and it is the timing fact the rest of the host is built
around: **`DllMain` runs before `GameAssembly.dll` is mapped and long before the
IL2CPP runtime is initialised.** Nothing in the interaction layer may resolve,
verify or bind at attach time; it must wait for the readiness gate
(`abi/aowlspt_il2cppready.h`).

### 1.2 The threads

| thread | who creates it | what may run on it |
|---|---|---|
| **Unity main** | the game | anything that touches the engine — and *only* this thread |
| **host ops** | the host, from the thread `DllMain` spawns | file I/O, logging, backend RPC, mod *loading*, ABI entry points called by mods |
| **Unity render** | the game | render-drain work only (`aowl_rq_thread`) |
| **mod ticks** | routed to the Unity main thread through the queue | mod code |
| **backend** | a separate process (`aowlspt-backend`) | nothing in this address space |

MEASURED: the host publishes both drain owner ids —
`aowlhost.nim:2684` `"mainThreadId": cMqThread()` and `:2723`
`"renderThreadId": cRqThread()`, backed by the C accessors
`aowl_mq_thread` / `aowl_rq_thread` (`aowlhost.nim:822,891`).

### 1.3 The main-thread bridge

MEASURED `R type EFT.TarkovApplication` → `void Update() rid=50571 arity=0
RVA=0x977b10`, and `R shared 0x977b10` → **`sharedness=UNIQUE owners=1`**. So the
per-frame bridge is a unique RVA and detouring it has no blast radius beyond
itself. (This is the one detour target re-checked in this document; §2.7 is the
general rule.)

MEASURED `abi/aowlspt_mqpolicy.h:8-16`: the detour **binds** at ~0:00:01, as soon
as the runtime can resolve the method, but the game does not **call** it until
the preloader has constructed the `TarkovApplication` behaviour — measured at
**~15 s**. For fourteen seconds the queue holds work and the drain has never
fired. That is not a stall.

### 1.4 The main-thread queue contract — `abi/aowlspt_mqpolicy.h`

Four health states, and MEASURED (`mqpolicy.h:52-64`) the middle two are the
whole point; collapsing them is what produced defect #4:

```
AOWL_DRAIN_UNBOUND     no per-frame method was detoured at all
AOWL_DRAIN_NEVER_FIRED bound, the game has not called it YET  (the first ~15 s)
AOWL_DRAIN_STALLED     it fired before and has gone quiet
AOWL_DRAIN_LIVE        firing
```

`since_ms` is consulted **only once `fires > 0`** — before the first firing the
host would be measuring how long ago *it* started, not how long ago the *game*
stopped (`mqpolicy.h:70-73`).

THE RULE, and there is exactly one copy of it (`mqpolicy.h:92-98`):

```c
aowl_mq_may_run_here(caller_tid, owner_tid, host_safe)
    host_safe                -> 1
    owner_tid == 0           -> 0     /* nobody has claimed the drain yet */
    caller_tid == owner_tid
```

Two properties, stated explicitly because both were violated:

* **The drain's health is absent from the rule.** A stalled drain does not widen
  who may run; it only changes what the host *says* (`aowl_mq_health_text`).
  There is no thread other than the drain's on which a callback that touches the
  engine is correct, so the only safe response to a genuine stall is to **defer**.
* `host_safe` is set **only** by `enqueueHostSafe`, whose entries carry no mod
  function pointer and make no managed call. It is **not** reachable from
  `invoke_main` or `schedule` (`mqpolicy.h:83-88`).

MEASURED cause of defect #4 (`mqpolicy.h:17-22`): a mod's queued tick called
`UnityEngine.Input::GetKey`, whose native body dereferences Unity's input
manager — a **per-thread table slot that is NULL off the main thread, with no
null test**. Access violation. Two Unity crash reports,
`Crash_2026-09-02_204346544` and `Crash_2026-09-02_211541986`, both ~8.7 s into
boot.

The header is deliberately free of `<windows.h>` and of every host type so that
`tools/test_mqpolicy.py` can **compile this file with a tiny main and execute the
real function** against a fake stalled drain and a fake healthy one
(`mqpolicy.h:40-44`). That is the pattern: *a safety rule that only exists inside
a DLL injected into a game cannot be tested, and an untested safety rule is a
comment.*

### 1.5 The allocator contract

**Per-DLL mimalloc.** Each Nim binary links its own. A buffer allocated in one
module must never be freed in another.

MEASURED `tools/allocasserts.py:6-35`, from WER dump
`EscapeFromTarkov.exe.636.dmp` read with cdb (`.ecxr; k 40`): a fail-fast
`abort()` — **no Unity `Crash_*` report at all**, because `abort()`/`__fastfail`
(0xc0000409) bypasses Unity's handler. The stack was `ucrtbase!abort` ← host DLL
← `mi_malloc` ← `sain!resolve_0`, on the ops thread, and `da` over the abort
frame printed `"corrupted thread-free list."` = `vendor/mimalloc/src/page.c:205`.
The **abort** is `mi_error_default`, `src/options.c:541`, compiled in purely
because `MI_DEBUG > 0` — and `include/mimalloc/types.h:69-75` defaults `MI_DEBUG`
to **2** unless `MI_BUILD_RELEASE` or `NDEBUG` is defined, which nimony only does
under `-d:release`/`-d:danger`, which `tools/aowl.nim` never passed. **Every DLL
we had ever shipped linked a debug allocator that turns a heap anomaly into an
instant client kill.** Fixed by `mimallocFlags` in `tools/aowl.nim` and the
matching literal in `tools/modbuild.py:compile_cmd` (commit `969da6b`).

**ARC globals.** MEASURED `tools/abilint.py:5-16`: the *cause* of the heap anomaly
was not a cross-module free. It was `var gLastError = ""` in
`host/Aowlspt.Host.Il2Cpp/aowlhost.nim`, a plain module-level Nim string assigned
from ~40 sites inside `exportc` ABI entry points that run on the **mod ops
thread**, and from `installPatch` on the **Unity main thread**, with no lock.
Under ARC an assignment to a global string **frees the previous buffer on the
assigning thread** — a cross-thread free, and under a race a double free.
`backend/aowlbackend.nim` had declared its identically-named `gLastError`
`{.threadvar.}` and was fine; **the divergence was the defect** (commit `6ededb6`).

### 1.6 ABI ownership — "borrowed in, owned out"

MEASURED `docs/ABI.md:22-23`: an `AowlSlice` passed *into* a function is valid
only for that call; to hand data back, fill an `AowlBuffer` from the host. Both
are 16 bytes (`ABI.md:39-45`). Consequence, enforced by `abilint.py` check 1:
**no `exportc` proc may have a Nim `string`/`seq` in its signature**, because
those are ARC-managed and their allocator is the *defining* module's.

### 1.7 Invariants

| id | predicate | enforcement |
|---|---|---|
| P1 | injection reads the remote thread's exit code and fails loudly on 0 | in code (`aowlspt_inject.h` step 4) |
| P2 | no resolve/verify/bind happens in `DllMain` | **UNENFORCED** |
| P3 | `aowl_mq_may_run_here` is the only predicate deciding where queued work runs, and there is one copy | `tools/test_mqpolicy.py` (compiles + runs the real function) |
| P4 | "bound but never fired" is never reported or treated as a stall | `tools/test_mqpolicy.py` |
| P5 | no `exportc` proc takes or returns a Nim `string`/`seq` | `tools/abilint.py` check 1 |
| P6 | no module-level ARC `var` is assigned inside an `exportc` body unless `{.threadvar.}` or locked | `tools/abilint.py` check 2 |
| P7 | no shipped binary contains mimalloc's assertion strings (`MI_DEBUG=0`) | `tools/allocasserts.py` |
| P8 | a buffer allocated by one module is never freed by another | **UNENFORCED** (P5/P6 cover two known instances, not the property) |

---

## 2. The detour engine — `abi/aowlspt_detour.h`

### 2.1 Why code, not `methodPointer`

MEASURED `detour.h:11-16`: swapping `MethodInfo.methodPointer` is trivial and
**useless** — IL2CPP compiles a direct call site into a direct `call`, so a
pointer swap intercepts `il2cpp_runtime_invoke` and nothing the game itself does.
*"That is worse than useless: it would appear to work in a test and never fire in
a raid."*

### 2.2 The patch

`AOWL_JMP_SIZE = 14` (`jmp [rip+0]; qword dest`), `AOWL_MAX_STOLEN = 32`. A
length decoder finds a whole number of instructions to steal (`aowl_insn`,
`detour.h:128`). Its refusals are kept **apart** on purpose (`detour.h:96-116`):

```
AOWL_INSN_UNKNOWN   not in this decoder's tables      -> a gap in our file
AOWL_INSN_RELATIVE  decoded, operand is relative      -> a property of the target
AOWL_INSN_SHORT     the function ends before the jump -> neither
```

RIP-relative displacements are **relocated** (adjusted by the distance moved,
refused if the result no longer fits in 32 bits — discovered in
`aowl_copy_relocated`, not in the decode, which is why there is deliberately no
`AOWL_INSN_FAR`: *a refusal reason that could not be reported is one nobody can
act on*). Relative branches are refused outright.

Fourteen bytes is not an atomic store, so **every other thread is suspended
across the write and checked for standing in the stolen bytes**
(`aowl_park_begin`, `detour.h:1176`; `NtGetNextThread` with a Toolhelp fallback,
`:1083`/`:1141`).

### 2.3 The thunk, and the register frame

There is exactly **one** thunk, `aowl_thunk_common`, entered with **R11 holding
this firing's `AowlSite`** (`detour.h:1579`). MEASURED `detour.h:653-660`:

```
AowlSite  +0x00 tramp   +0x08 gen   +0x0C slot   +0x10 post
          (24 bytes, _Static_assert'd against the assembly)
```

MEASURED `detour.h:1434-1436` — the frame the assembly writes, which is
`AowlRegs`, `AOWL_REGS_BYTES = 0x50`:

```
+0x00 RCX  +0x08 RDX  +0x10 R8  +0x18 R9
+0x20 XMM0 +0x28 XMM1 +0x30 XMM2 +0x38 XMM3
+0x40 replacement / original integer return
+0x48 original float return                (postfix path only)
```

`aowlspt_nim_patch_fired(slot, regs)` returns 0 to run the original, 1 to
suppress it. `aowlspt_nim_patch_returned(slot, regs)` is the postfix half.

There used to be **sixteen** thunks with their slot numbers baked in, looking
everything else up in slot-indexed tables. MEASURED `detour.h:1476-1486`: a thread
preempted between the jump landing on the thunk and those loads read the
trampoline and the generation **after the slot had been released and re-claimed**
— a self-consistent pair belonging to a *different* hook. Now the site record
carries all four facts together, and the dispatcher additionally rejects a firing
whose `gen != aowl_gen_table[slot]` (`detour.h:1535`, `:1551`), counted in
`aowl_stale_fires` — *"Zero is the number this should be."*

**Stack arguments** (>4 slots) are read at `[entry_rsp + 0x28 + 8*(n-4)]` on the
prefix / tail-jump path, which preserves rsp. §2.4 is why that is the *only* path
on which they are readable.

### 2.4 The slot-count rule — defect #1

MEASURED `tools/drainaudit.py:5-24` and `detour.h:1375-1384`. A postfix cannot
tail-jump — it must regain control — so it does `sub rsp,0x98` and `call *tramp`.
The original then runs with a **different rsp** and reads its stack arguments out
of **our** frame:

```
0x1538a4f  mov rax,[rsp+0xc0]      ; = [entry_rsp+0x28], argument 5
0x1538a57  mov [r14+0x18],rax
0x1539126  mov rdx,[r14+0x18]
0x153912f  call SeasonWidgetData::From
```

`[entry_rsp+0x28]` lands on thunk-frame `+0x20`, the slot the thunk parks RAX in
and **has not written yet**. `EFT.UI.MenuScreen::Show` @`0x15387A0` takes five
declared arguments = **seven slots** (`this` + 5 + the trailing `MethodInfo*`).
Three consecutive boots died in `SeasonWidgetData::From` with `Rcx=1`: a
`Profile` that was the integer 1.

**slots = parameterCount + 1 (MethodInfo\*) + (1 unless static).**
`PostfixMaxSlots = 4`. A site is matched to the metadata **by RVA, not by name** —
28.3% of by-name lookups on this build land on a shared RVA, and some table names
carry a disambiguating suffix (`::Show(5-arg)`) that is not a metadata name at
all — and where an RVA folds several methods the audit takes the **maximum** slot
count: being wrong in the safe direction is the only acceptable direction
(`drainaudit.py:56-66`).

Three enforcement points, and it took all three:

* `invoke.nim:postfixRefusal` — a **mod's** patch. Present since it was written.
* `attachDrain` — the **host's** runtime half. Added `eb39963`; it previously
  trusted each caller's `postfix` flag.
* `tools/drainaudit.py` — the **offline** half. It refuses the *build*, so the bad
  shape never reaches a client. PASS / FAIL(1) / **INCONCLUSIVE(3)** when the
  metadata is absent: *"I could not look" is not a pass.*

MEASURED consequence for a >4-slot site that must be hooked: bind it as a
**PREFIX** (commit `3e30117`, uihooks).

### 2.5 Exception unwinding through our frames

MEASURED `detour.h:1386-1394`. The postfix `call` happens inside the same
`.seh_proc` with the same `.seh_stackalloc 0x98` prologue, so the frame is
describable and a managed exception thrown out of the original **unwinds through
it exactly as through any other frame**. What it does *not* do is run the postfix
handler — an unwind skips the rest of the function by definition. So:

> **A postfix means "after the original returned", not "after the original
> finished".** A mod that needs the exception case wants a finalizer, which does
> not cross this ABI at all.

INFERRED: a prefix that suppresses the original (returns 1) cannot observe a
throw either, because the throw does not happen. **There is no path in this
engine that observes a managed exception.** A feature that needs one is
unbuildable today and must say so rather than approximate it.

### 2.6 Prologue verification — against the **snapshot**, never live memory

MEASURED `abi/aowlspt_prologue.h:5-30`. Every feature compares 16 prologue bytes
against a signature baked in from the decrypted metadata. That check is real — it
is what makes a stale RVA on a different game build a silent no-op instead of a
jump into the middle of an unrelated function. But it used to read **live**
memory at bind time, so as soon as two features shared a target the first
binder's jump overwrote the bytes the second was about to compare. Observed live,
twice, on two builds, with `debugUi` and `uxMenuModeText` both on:

```
menu mode text: PreloaderUI.Update did not verify on this build
                (0 target(s) verified, 1 rejected); nothing bound
```

Nothing was wrong with the RVA, the signature or the multiplex — **only with WHEN
the bytes were read**, and the message blamed the game build. This is a whole
class, not one feature's mistake.

The fix is one RVA-keyed table captured **before anything is patched**: eagerly
from `aowl_pro_prime_all` at host startup, lazily on the first verify of an RVA
nobody remembered to prime (correct only because a feature cannot patch what it
has not yet verified). **A snapshot is written exactly once per RVA and never
updated** — a second capture after a detour landed would record the trampoline
and re-introduce the bug. Capture does `VirtualQuery` first, insists on
`MEM_COMMIT` and an executable protection, and a capture that cannot satisfy that
records **nothing**, so the verify fails closed rather than comparing against a
zeroed row.

### 2.7 Sharedness

MEASURED (CLAUDE.md §5): 6,261 RVAs on this build have more than one owner; 28.3%
of by-name lookups land on one. **Calling** a shared address is fine — it is
correct code for the receiver you pass. **Detouring** one is a write with
unbounded blast radius. `R shared <RVA>` has **three** outcomes — `shared` /
`unique` / `unknown` — and `unknown` (not in the methodPointers histogram: a live
ASLR address, a typo, a non-code RVA) is a **refusal**, not "safe to assume
unshared". Never re-derive this from `shared_rva_counts()` with a `.get(rva, 1)`
default; that default made every unknown address read back as "1 owner, safe".

### 2.8 Two detours on one function, and the rider pattern

MEASURED (CLAUDE.md §5, `il2cpp-host` skill): the second install overwrites the
first's trampoline and the first feature **silently dies**. The pattern is to
**ride the existing detour as a drain** — add your work to the one hook — rather
than binding a second. A prologue verify that fails on a function you know
another feature hooks is §2.6, i.e. a hook-*order* problem, not a bad RVA.

### 2.9 Invariants

| id | predicate | enforcement |
|---|---|---|
| D1 | no postfix site in `host/` or `mods/` exceeds 4 register slots | `tools/drainaudit.py` (build-gating) + `attachDrain` + `invoke.nim:postfixRefusal` |
| D2 | every postfix/drain site declares a slot count agreeing with the metadata **by RVA** | `tools/drainaudit.py` |
| D3 | no prologue verify reads live memory; all compare against the startup snapshot | **UNENFORCED** (the mechanism exists; nothing stops a new site doing `VirtualQuery`+`memcmp` itself) |
| D4 | every detour target is `sharedness == UNIQUE`; `unknown` refuses | **UNENFORCED** offline |
| D5 | no function is detoured twice | **UNENFORCED** |
| D6 | `aowl_stale_fires == 0` | reported by the host; **UNENFORCED** as a gate |
| D7 | the length decoder never guesses a length; three distinct refusal codes | in code; **UNENFORCED** by test |
| D8 | exactly one `aowl_p_p_seh` per guarded body, never nested | **UNENFORCED** |
| D9 | every loop over game data is capped | **UNENFORCED** |
| D10 | every feature is flag-gated and defaults OFF | `tools/hostcfg.py` validates key *names* only; the default is **UNENFORCED** |

---

## 3. The IL2CPP export ABI

### 3.1 The correction that has to be made first

**"Reflection is dead" is FALSE and must never be written again.** MEASURED
(CLAUDE.md §5; `docs/IL2CPP_EXPORTS.md`, which currently lives only on the
unmerged branch `feat-il2cpp-export-map`): this is stock IL2CPP with a **gated
export ABI**. 386 exports, none at the universal stub; the 9 `ret0` ones are
ordinary release no-ops. `il2cpp_value_box` is intact and ungated.
`il2cpp_object_get_class` does **not** fault — it is `mov rax,[rcx]; ret`, so a
bad pointer yields a *plausible number silently*, which is worse. The correct
sentence is: **the export is token-gated, and its failure mode is a plausible
random value.**

### 3.2 The 40 gated exports — defect #2

MEASURED `abi/aowlspt_il2cpp_gates.h:10-18`: 40 of the 241 `il2cpp_*` exports take
an **extra trailing argument stock IL2CPP does not have** — a pointer to 32
bytes, which the callee `memcmp`s before doing any work. On mismatch it does
**not** return NULL and does **not** abort: it tail-calls a trap that lazily seeds
a per-thread MT19937-64 and returns a **uniform random non-zero uint64**.

The falsifiable pair, measured offline by mapping the DLL into a scratch process —
never the running game — and calling against a **staged receiver buffer we filled
ourselves**, so the right answer was known independently (`gates.h:29-38`):

```
il2cpp_method_get_param_count(staged, correct_token) -> 7, 7, 7, 7, 7
il2cpp_method_get_param_count(staged, corrupt_token) -> 8551E516, 23DBF07, DA01ECF3, ...
il2cpp_method_get_param_count(staged, NULL)          -> 1AD46590, E65AE66A, F4201CA4
```

The last line is what we always did. *"It returned something" proves nothing here,
because the trap also returns something.*

Two flavours (`gates.h:41-58`):

* **STATIC, 22 exports.** The expected 32 bytes are a constant in `.rdata`. Read
  them **from the mapped image at runtime** (`base + token_rva`); never hardcode
  an absolute address and never copy the bytes into source — they are
  build-specific.
* **NONCE, 18 exports.** The callee reads a 64-bit nonce from a per-API TLS slot,
  **zeroes it (single use)**, calls a per-API derivation function and memcmps the
  result. The nonce comes from the exported, non-stock `il2cpp_nonce(apiId)` @
  `0x5B3D60`, which also *returns* the value it stores, so the caller never reads
  TLS. The apiId→slot map is in no symbol; it was recovered mechanically by
  calling `il2cpp_nonce(id)` for every id and observing which TLS slot became
  non-zero.

(22 + 18 = 40. An earlier count of 38 was wrong.)

### 3.3 The handle shape filter — `abi/aowlspt_handle.h`

MEASURED, Unity crash report `Crash_2026-09-02_224920325`, host build sha256
`350dba69`, ~10 s after boot on the Unity drain thread, symbolised from the host's
own `.pdata` (the DLL has no pdb):

```
aowl_thunk_common+0x66 -> ... -> bridgeProof+0x105 -> valueBox+0x1b -> GameAssembly, 0xC0000005
RCX = 0x6e11f7fc349b3101   the Il2CppClass* handed to il2cpp_value_box
RDX = 0x000001ed62c8c1f0   a real, readable cell
```

The handle came from `il2cpp_class_from_name`, `AOWL_GATE_KIND_NONCE`. Two pure
filters — no OS calls, no dereference, no globals (`handle.h:47-53`):

```c
v == 0    -> 0
(v >> 47) -> 0    /* not a Win64 user-mode address */
(v & 7)   -> 0    /* not pointer-aligned            */
```

A uniform random value fails filter 1 with probability `1 - 2^-17` and filter 2
seven times in eight; together they let a trap through with probability ≈ `2^-20`.
The caller adds `VirtualQuery` as a third, independent filter — that one needs the
OS, which is why it is not in this header.

**This is a refusal, not a guarantee.** It narrows a certain crash to an
improbable one. *The only thing that makes a gated export safe is
`aowl_host_gate_call` with a real token; nothing here should ever be quoted as
permission to call one without.* `tools/test_handleshape.py` compiles and runs it
with positive controls, so "the filter rejects things" and "the filter rejects
everything" cannot be confused.

MEASURED positive controls (`AOWL_FACTS.md`, 2026-09-02 19:46): live klass
`0x230e2951810` ✓, live receiver `0x1ebcd25c100` ✓, RDX at the crash
`0x1ed62c8c1f0` ✓, code pointer `0x7ffb180d9a78` ✓, trap `0x6e11f7fc349b3101` ✗.
**Loosening the filter to admit the trap value would restore the 10-second crash;
the filter was never the bug.**

### 3.4 Defect #3 — the drain that bound on garbage for weeks

MEASURED (`AOWL_FACTS.md`, 2026-09-02 19:46). `bindMainDrain` did, per candidate:

```
let cls = findClass(gRt, typePart)        # il2cpp_class_from_name            (NONCE)
if cls == nil: continue
let m = findMethod(gRt, cls, member, -1)  # il2cpp_class_get_method_from_name (NONCE)
if m == nil: continue
let fn = resolveDrainPointer(m, spec, verbose)
```

`il2cpp.nim` called both through `rt.fns[...]` — the raw `GetProcAddress` pointer,
**with no token** — so both returned MT19937-64 output and both `!= nil` checks
passed on it. `resolveDrainPointer` then found the MethodInfo unreadable and fell
through to `nameIndexResolve(spec, …)`, **which takes only the spec string and had
never looked at either handle.**

> A random 64-bit number was the ticket past two nil checks into a route that
> never dereferenced it.

The instant `gatedHandle` correctly refused it, `if cls == nil: continue` skipped
the candidate, the name-index route became unreachable, the drain never bound,
`invoke_main` work was held, `Submit` never ran, and the client sat on the
character screen for **28 minutes** — reporting only

```
no per-frame candidate UnityEngine.UI.CanvasUpdateRegistry in this build
```

a sentence about the build, and false.

**The expensive lesson, quoted:** *a nil check that a garbage value passes is not
a gate, it is a turnstile. Hardening it is correct AND is a behaviour change,
because anything downstream that never dereferenced the value was being kept
alive by the garbage. Before tightening a validity check, ask what the invalid
value was reaching — the answer here was "the only route that actually worked".*

Fixes: `resolveDrainByName(spec, verbose)` extracted so there is ONE
implementation, tried by both `bindMainDrain` and `bindRenderDrain`; and
`gatedHandle` records `gGatedHandleLastValue` / `gGatedHandleLastWhy` so **every
refusal names the value it refused** (commit `0a9d871`) — *nobody prints a
counter.*

### 3.5 The route that actually works: the offline name index

MEASURED `abi/aowlspt_nameindex.h:5-30`. By-name resolution through the runtime is
dead on this build: handles come back non-nil into unmapped memory and every
probed `MethodInfo` is unreadable — **6/6 on the host thread AND 6/6 on the Unity
main thread, so it is not thread affinity**. No MethodInfo means no token, so the
sound `Il2CppCodeGenModule.methodPointers` table (hand-walked live and prologue
byte-verified) cannot be indexed *by name* at run time.

Every input is available **offline**, so `tools/il2cpp_nameindex.py` walks the
metadata on the build machine — it *imports* `il2cpp_resolve.py` rather than
reimplementing the walk, so the two cannot drift — and freezes the answer into a
sorted binary index: `"AOWLNIDX"`, version 2, header 40 bytes, with an `imageKey`
build identity and a `SHA-256(GameAssembly.dll)[0:8]` guard, plus four parallel
arrays (`hash[]` ascending and unique, `rva[]`, `check[]`, `share[]` = how many
method keys resolve to that RVA). The header **calls nothing in IL2CPP** — not one
export, not one `MethodInfo` dereference. *The dead path is not made more robust
here, it is removed from the question.*

It answers exactly one question — "what RVA does this name have" — and hands it to
the by-RVA binder, which owns address substitution, snapshot prologue
verification, `VirtualQuery` and the `il2cpp`-section check. **There is
deliberately no second copy of any of that.**

### 3.6 What is safe today

Three primitives, and they are the whole toolkit:

1. **Raw static-offset field read/write** (offsets from metadata, §4.1).
2. **A direct call at a byte-verified static RVA** — this bypasses the export ABI
   entirely and no gate affects it.
3. **`il2cpp_string_new`** (ungated).

Generated code is in the **`il2cpp` PE section, not `.text`**. Runtime address =
`GameAssemblyBase + (VA - 0x180000000)`.

INFERRED (CLAUDE.md §5): runtime managed **type injection is plausible, not
blocked** — `object_new`, `gc_alloc_fixed`, `gchandle_*`, `runtime_class_init`,
`runtime_invoke`, `add_internal_call`, `type_get_object` are all ungated — but
constructing a valid `Il2CppClass` has **not** been checked. "Plausible" means the
export surface does not block it, not that it works.

### 3.7 Invariants

| id | predicate | enforcement |
|---|---|---|
| X1 | no gated export is called through a raw `GetProcAddress` pointer without a token | **UNENFORCED** |
| X2 | every handle returned by a gated export passes `aowl_handle_shape_ok` before any use | in code (`gatedHandle`, `838fec4`); **UNENFORCED** that every site uses it |
| X3 | the shape filter accepts every real pointer shape ever observed | `tools/test_handleshape.py` case 0 |
| X4 | every refusal names the value it refused | in code (`gatedRefusalNote`); **UNENFORCED** |
| X5 | static gate tokens are read from the mapped image, never hardcoded | **UNENFORCED** |
| X6 | the name index's `fileHash`/`imageKey` match the mapped `GameAssembly.dll` | the header's own load path, fails closed |
| X7 | no source, doc or refusal message says "reflection is dead" | **UNENFORCED** |

---

## 4. Managed memory

### 4.1 Reads

Offsets come from `Il2CppMetadataRegistration.fieldOffsets` via `R fields <Type>`
or `tools/fldoff.py`, each with a mandatory self-check
(`System.String._stringLength@0x10`, `_firstChar@0x14`) that must pass before any
offset is trusted. **Never guess one.**

Offsets are **three-state, never two**: a real offset, `--` for a const (no
storage), or **`GENERIC` / `GENERIC-NO-LAYOUT`** for an uninstantiated generic
definition. IL2CPP writes an **all-zero** fieldOffsets array for those 1,569
types; the tools used to print `0x0` for every field of `` List`1 ``, which is a
fabricated offset that reads the object header.

**Instantiated generic layouts (`List<int>`) are not reachable offline** — all
33,464 `Il2CppGenericClass` entries are present but every `cached_class` in the
file is null. Take that layout from a live object or a verified header, and **say
it is borrowed**.

Where the table cannot answer, an offset may be **derived from use** and must be
labelled so: `SettingsScreen.ScreenController@0x90` is MEASURED-BY-USE
(`R disasm 0x1720de0` reads `[this+0x90]`), and `SETTINGS-UI-MAP.md` states
plainly that *the offline offset table cannot confirm this.*

**Walk from a verified live object; never trust an offset that can read null.**
`SettingsTab._rectTransform@0x78` reads null; the row container was only ever
reached by walking up from a live control.

### 4.2 Writes

MEASURED `abi/aowlspt_hostwrite.h:5-18`. Two dumps put a *small integer* in a
managed reference slot: `Crash_2026-09-02_131229783` (`SeasonWidgetData::From`,
`Profile == 1`) and `Crash_2026-09-02_161150163` (same method, `+0x11f`,
`Profile == 0xffffffff`, the reference having come from
`MainMenuBaseScreenController.Profile@0x58`). A JSON payload cannot produce that;
only a native store into the wrong object can.

The host's write guards were, everywhere, a **readability** test
(`aowl_is_readable` / `duOk` / `nuOk` — non-null plus `VirtualQuery`). **On the
IL2CPP GC heap that test cannot fail**: the pages stay mapped after an object
dies, so a stale pointer into recycled memory passes every time and the write
lands in whatever type now occupies the address. A check that cannot fail IS the
bug.

So readability is necessary and **not sufficient**. Three further questions have
to be asked of a receiver before anything is written through it:

1. is the `Il2CppClass*` still the one we recorded when we captured the pointer?
   (catches GC recycling into a **different type** — the crash above)
2. is the offset inside that klass's instance size? (catches a
   right-type/wrong-layout write running off the end)
3. is Unity's own liveness test still true — `Object::op_Implicit`? A Destroyed
   object keeps a managed shell that **reads back perfectly** and answers false.

`aowlspt_hostwrite.h` owns 1 and 2 plus the stores; `hostwrite.nim` owns 3 and the
per-site bookkeeping. It opens **no SEH guard of its own** — every caller is
already inside one and `aowl_p_p_seh` is not re-entrant — has no loops at all, and
allocates nothing. **A refusal is the point**: these return 0 and write nothing.
*They never "write anyway and log"; a logged corruption is still a corruption.*

MEASURED `docs/WRITE-AUDIT-2026-09-02.md`: **12 store sites** into game-owned
memory across `host/` and `mods/`. Of those, **klass-guarded: 0**. Partially
guarded by reading the slot back first: **2** — `modstab.nim:1515` (identity test
against `stockGroup`, "the best in the tree") and `mods/textures/redirect.nim:622`
(refuses unless the old slot holds a readable string). Site 9
(`aowlhost.nim:6583`, the version brand) **discovers its offset at runtime by
scanning the label component in 8-byte steps for a slot that reads back as a
version-looking `String`** — that offset never touches the field table. Site 10 is
the inspector's `write` verb: arbitrary offset from the operator's expression,
gated by `liveInspectorWrite` **plus** an `allow write` line in the batch.

MEASURED conclusion of the same audit: `hostwrite.nim` gates **1 of the 12 sites,
in its weakest mode** — 9 log lines, all `hostRecvOk`, the *setter-call* gate and
not a store, all from `modstab.nim:modsReassertLabels`. Therefore *"hostWriteTrace
was ON and the crash log shows zero `hostwrite` lines" does not narrow the field.*
Compiled in with zero call sites (MEASURED by `rg`): `aowlscene.nim:364-379`
`writeI32/writeF32/writeU8/writeBool`; `hostwrite.nim:211-249`
`hostWriteI32/hostWriteU8/hostWriteF32/hostWritePtr`; `debugui.nim:77`
`cDuWriteI32`.

INFERRED (`WRITE-AUDIT §0`), and worth keeping as a diagnostic:
`0x00000000FFFFFFFF` in an 8-byte slot has exactly three producers — a **4-byte**
store of `-1` into a slot whose upper dword was already zero (a freshly allocated
managed object is zeroed, so this is the common case); an 8-byte store of the
literal; or the game's own `mov [field], rax` after a call whose EAX was `-1`.
**Never do a 4-byte store into a reference slot.**

### 4.3 Unity object lifetime — defect #7

* `m_CachedPtr@0x10 == 0` is Unity-dead. The managed shell survives and reads back
  perfectly.
* `Destroy` takes effect at end of frame; the pointer is live *and* doomed in
  between.
* MEASURED `host/Aowlspt.Host.Il2Cpp/nativetabs.nim:180-198` (`R disasm 0x37ea0c0`,
  confirmed live on the 15:42 boot): `` UISpawner`1::get_SpawnedObject `` is a
  **lazy factory, not an accessor.** It reads `_spawnedObject@0xa0`, and if that is
  null **or the object behind it is Unity-dead**, it calls `SpawnObject` through
  the vtable, re-applies the header/width/ellipsis and **rewrites the field.
  Nothing announces it.** Every pointer cached from `SpawnObject()` therefore
  became an orphan the moment its toggle was destroyed — *still readable, still
  reporting `m_IsOn = 0` forever, and no longer the object the player clicks.*
  There is no `OnEnable` involved: MEASURED, neither `` UISpawner`1 `` (9 declared
  methods) nor `UIAnimatedToggleSpawner` (9) declares one, so no amount of care
  about `SetActive` would have avoided it.

  **THE RULE: hold the SPAWNER, resolve the object at the instant of use.**
  Generalised: **never cache a pointer produced by a factory across a frame.**

* The liveness walk at scene load
  (`il2cpp_unity_liveness_calculation_from_root`) dereferences every reachable
  reference — `test byte ptr [rcx],1` — so a corrupt reference planted at any
  earlier time detonates *there*, arbitrarily far from its cause. That crash
  (RCX = `0x00000000FFFFFFFF`) is what prompted the write audit.

### 4.4 Calling conventions

* Instance: `RCX = this`, `RDX/R8/R9` = args, then a **hidden trailing
  `const MethodInfo*`**. Static: `RCX..R9` then `MethodInfo*`. Floats `XMM0-3`.
* A NULL `MethodInfo*` is fine **except for shared generics**.
* MEASURED Win64 ABI on this build (CLAUDE.md §2): a **Vector2** (8 bytes) comes
  back **packed in RAX**; a **Rect** (16 bytes) comes back via **hidden-buffer
  sret** — `retbuf in RCX, this in RDX, MethodInfo* in R8`. INFERRED
  generalisation: any struct return > 8 bytes shifts every argument right by one.
* MEASURED `detour.h:1368-1372`: a struct return's *value* lives in memory the
  detour engine cannot read the layout of, so a **postfix on such a method could
  neither report nor replace the result**; `hostPatch` refuses it at registration
  rather than installing one that silently observes nothing.
* **Pass the values the game itself would pass.** MEASURED 2026-09-02: the
  character-select `Submit` frame was correct for two weeks while the host computed
  its own `gameMode`/`profileData`; the game's flow then met `EGameMode.Pve == 1`
  where a `Profile` belongs, crashing 1 boot in 3. Reading `_gameMode@0x160` /
  `_profileData@0x178` **off the slot view the game handed us** fixed it in one
  call (commit `b3c4047`). Full signatures are reachable offline (`returnType@8`,
  `parameterStart@16`, `parameterCount@34`), so **a patch frame shape must be
  derived, never inferred from a method name.**

### 4.5 UI text

`ForceMeshUpdate` resolves to `0x628110`, which is `C2 00 00` (`ret 0`) — and is
**not that method's own code**: it is this build's universal empty-body stub,
shared by **6,438** methods. A stub that passes a signature check is the worst
case. Writing raw `m_text` does not stick (`LocalizedText` clobbers it); call
`LocalizedText::SetLabelText` @`0x140FE70` and `TMP_Text::set_text` @`0x51BC1E0`,
and **re-apply**.

### 4.6 Invariants

| id | predicate | enforcement |
|---|---|---|
| M1 | no field-offset literal without resolver-derived provenance | **UNENFORCED** |
| M2 | no offset taken from an uninstantiated generic's zeroed table | the resolvers print `GENERIC`; **UNENFORCED** at the call site |
| M3 | every managed store passes klass-identity + instance-size + Unity-liveness | `aowlspt_hostwrite.h` exists; measured **1 of 12** sites use it → **UNENFORCED** |
| M4 | no 4-byte store into a reference-typed slot | **UNENFORCED** |
| M5 | no factory-produced pointer is cached across a frame | **UNENFORCED** |
| M6 | readability alone is never a write guard | **UNENFORCED** |
| M7 | no postfix on a method returning a struct > 8 bytes | `hostPatch` registration refusal |
| M8 | call arguments are read off the live receiver, not computed | **UNENFORCED** |
| M9 | UI text goes through the real setters and is re-applied | `tools/acceptance.py` (behavioural, live) |

---

## 5. The live inspector

**Channel.** Write commands to `D:\Aowlspt\aowlspt\aowlspt-inspect.txt`; answers
land in `aowlspt-inspect-out.txt` and in the host log. The trigger is a **content
change**, so bump a serial line (`#12`) to re-run the same batch. Write it
**without a BOM** — PowerShell 5.1's `Set-Content -Encoding utf8` emits one.
Flags: `liveInspector` (read-only) and `liveInspectorWrite` **plus** an
`allow write` line in the batch for anything that writes or calls into game code.

**Anchors** rebind per batch (`$preloader $verlabel $modetext $tab1 $settings
$gameworld $you $_`). `state` explains *why* an anchor is null — but check that
explanation against the host log: `$settings` is populated by whichever of two
independent hooks fires first, so a null anchor while the log shows "settings
probe: ShowScreen (postfix) first fired" means a flag gating one of those hooks is
off, not that Settings was never opened.

**Expressions.** `$anchor | 0xhex ( +0xNN | @0xNN )*` — `+` moves, `@`
**dereferences**. `$rN` binds a Transform, `$rgoN` the GameObject; feeding a
GameObject to a Transform walker is **refused** — it used to read a plausible
`childCount` and invent a hierarchy of wrong children **without faulting at all**.

**Reach.** `roots` is how you reach anything: the live UI is in
`DontDestroyOnLoad`, which `sceneCount`/`GetSceneAt` exclude by design, so all
three listed scenes truthfully report `rootCount=0`.

**Three outcomes, never two.** `find` auto-resumes across frames and says
`searched EXHAUSTIVELY` vs `STOPPED EARLY`; **STOPPED EARLY is not proof of
absence.** An explicit ROOT that does not read back as a valid Transform is refused
up front, so the tool never reports "genuinely NOT PRESENT" when zero valid nodes
were visited. `findtext` shares `find`'s root/budget parser and reporter so the two
cannot drift; every hit is checked against `GameObject::get_activeInHierarchy`,
because pressing an **inactive** node returns success and does nothing.
`findtext` searches active-only by default; `find` has the identical blind spot
and was **deliberately left unchanged**.

**Fault budget.** `gInspFaults` against `InspMaxFaults` (`inspect.nim:346`,
`:8761`); on exhaustion `inspGoOff("too many caught faults in one session")` — the
inspector disables itself rather than faulting forever. `state` reports
`faults=… escapes=…` (`:5223`, `:8672`).

**What it cannot answer.** Klass **names** (`il2cpp_class_get_name` is gated, §3).
Instantiated generic layouts (§4.1).

**Known rough edges, from use on 2026-09-03 — report these, do not route around
them (CLAUDE.md §10):**

* `klass EXPR` prints a **pointer, not a name**. Correct given §3, but the verb
  name promises otherwise. *Proposed:* resolve the pointer through the offline name
  index and print the type name, or rename the verb `klassptr`.
* `parent EXPR` does **not bind `$_`**, so a walk up cannot be chained the way a
  walk down can. *Proposed:* bind `$_` from every navigating verb, uniformly.
* `component EXPR TypeName` takes a **short name** while everything else in the
  IL2CPP layer is fully qualified; the two routes can disagree about which type was
  found. *Proposed:* accept both and print which matched.
* `find NAME $f1` **rebinds `$f1`** while using it as the root, so a second `find`
  in the same batch searches somewhere else. *Proposed:* snapshot root anchors at
  batch-parse time.

*(Historical, all fixed, and each found only by USING the tool: a failed
`component` left `$comp` holding the previous batch's pointer, so `click` pressed
the wrong object twice and printed a complete, entirely fictional field map of a
Button that does not exist; `click`/`invoke` imposed `UnityEngine.UI.Button`'s
layout on any pointer, calling `UnityEvent::Invoke` on a GameObject and escaping
the guard; `label` on a Transform reported `text = ""`, which reads as "the label
is empty" and is not an answer; `open` rejected a correct target because the
prologue snapshot had recorded our own trampoline.)*

| id | predicate | enforcement |
|---|---|---|
| I1 | the inspector self-disables after `InspMaxFaults` caught faults | in code; **UNENFORCED** by test |
| I2 | search verbs report EXHAUSTIVE vs STOPPED EARLY and never convert the latter into absence | `tools/test_inspect_silence.py`, recorded `toolcheck` cases |
| I3 | a press target is `activeInHierarchy`-checked first | in `findtext`; **UNENFORCED** for `click`/`invoke` on a hand-built expression |
| I4 | an anchor that failed to bind never keeps a previous batch's value | in code (fixed); **UNENFORCED** by test |
| I5 | inspector writes need `liveInspectorWrite` **and** `allow write` | in code; **UNENFORCED** by test |
| I6 | consumers of inspector output model three outcomes, not two | `tools/acceptance.py`; **UNENFORCED** generally |

---

## 6. Game-side integrity

### 6.1 The manifest the client actually reads — defect #8

MEASURED `tools/consistency.py:5-30`, by offline disassembly plus a decrypt that
round-trips. `tools/dlss.py` resynced `D:\Aowlspt\ConsistencyInfo` — the plain JSON
next to the exe — and the client still refused to boot:

```
files-checker|Consistency ensurance failed. File size does not match.
File: "EscapeFromTarkov_Data\Plugins\x86_64\nvngx_dlss.dll"
```

**The client never reads that file.**
`FilesChecker.ConsistencyController::TryFillConsistencyMetadatas` @`0x27d4310`
builds its dictionary from an **AES-256-CBC blob injected into
`EscapeFromTarkov.exe` itself**, via `FilesChecker.ResourceInjector::Read`
@`0x27d8dd0`. There is **no fallback**: both catch blocks in that method only call
`AbstractLogger::LogException`, so a failure to read the resource leaves the
dictionary **empty** rather than reaching for the plain file. The plain
`ConsistencyInfo` is the **launcher's** manifest — it lists `ConsistencyInfo`,
`EscapeFromTarkov.exe` and `Uninstall.exe`, which the embedded copy does not.

Container format, appended to the exe in front of the Authenticode certificate:

```
P              : u8  ivLen (16)
P+1            : u8[ivLen] IV
P+1+ivLen      : i32 cipherLen (little endian)
P+5+ivLen      : u8[cipherLen] ciphertext
S-8            : i64 P                     (a back-pointer to the record)
S              : u8[32] signature
```

`Read` seeks to `S-8`, follows the pointer, and reads the fields in that order, so
`P + 5 + ivLen + cipherLen == S - 8` **exactly** — that identity is the tool's
first structural check. `signature = SHA-256(ASCII("BSG_RESOURCE_V1"))`, a
**resource marker, not a key or a secret**; it was not read out of a string table
by eye — every one of the 32,305 metadata string literals was SHA-256'd and the
digests searched for in the exe, and **exactly one** matched, at file offset
`0x27066d`. `GetHash(s)` @`0x27d9de0` is
`new SHA256Managed().ComputeHash(Encoding.ASCII.GetBytes(s))`, 32 bytes, hence
AES-256. The cipher key is `GetHash(buildId)`; **no BSG key literal is stored in
the tool** — the build id is derived at runtime and every candidate is *proved by
decryption*, never assumed: the plaintext must be valid JSON **and** its own
`"Version"` must equal the candidate. `Aes.Create()` with no Mode/Padding ⇒ CBC +
PKCS#7.

The payload was written by Newtonsoft with HTML string escaping (`&` → `\u0026`),
and `inject` **refuses to write anything unless re-serialising the UNMODIFIED
document reproduces the decrypted plaintext byte for byte** — the check that
cannot pass vacuously.

### 6.2 What the checker enforces, and the hardlinks

* **Size** (and, in the plain launcher manifest, a checksum = byte-sum mod 2^32);
  entries can be marked **critical**.
* **`Logging.config` is hardlinked** to `D:\Games\Tarkov\Logging.config`. Keep
  level names the same length — `Trace`/`Debug`/`Error` are 5 characters,
  `Information` is 11 — and re-sync the manifest entry.
* MEASURED `tools/consistency.py:333-341`: the live exe is **hardlinked to
  `\ripstage`**, so an in-place write would edit the pristine copy too. The tool
  writes a temp file and `os.replace`s it — **a new inode, breaking the hardlink**
  — with a timestamped backup taken first.
* Files **added** beside the exe are fine only if they are absent from the embedded
  dictionary; a file that is *listed* and differs in size refuses the boot.

| id | predicate | enforcement |
|---|---|---|
| G1 | the embedded manifest round-trips byte-for-byte before any injection | `tools/consistency.py inject` + `consistency.py selftest` |
| G2 | the structural identity `P+5+ivLen+cipherLen == S-8` holds | `tools/consistency.py` |
| G3 | no write to the exe or `Logging.config` propagates through a hardlink | `consistency.py`'s hardlink-breaking writer |
| G4 | any file we add or resize beside the exe is reflected in the **embedded** manifest, not just the plain one | **UNENFORCED** as a pre-launch gate |
| G5 | `Logging.config` level-name lengths are preserved | **UNENFORCED** |

---

## 7. What a correct feature must do

Derived from §1–§6. If a change cannot satisfy all of these, **say so and stop**;
do not ship it "just to see".

**Before writing any code**

1. Resolve the target with `R type` / `R fields` / `R member` — never a guess,
   never a name-derived signature. Record the RVA and the offsets together with the
   command that produced them.
2. `R shared <RVA>`. `shared` → do not detour. `unknown` → **refuse**.
3. Count the slots: `parameterCount + 1 + (1 unless static)`. **>4 ⇒ prefix, never
   postfix.** A struct return > 8 bytes ⇒ never postfix.
4. Check whether the target is already detoured. If it is, **ride the existing
   drain**; do not bind a second hook.
5. Check the offset's three-state answer. `GENERIC` is not an offset. An
   instantiated generic layout must be borrowed live and labelled *borrowed*.

**In the code**

6. 16-byte prologue verify **against `aowlspt_prologue.h`'s startup snapshot**.
7. `VirtualQuery` / `aowl_is_readable` on **every** hop — `a->b->c` is three checks.
8. Exactly **one** `aowl_p_p_seh` around the whole body. It is **not re-entrant**:
   a nested inner guard *disarms the outer one*.
9. Every loop capped.
10. Flag-gated, **default OFF**, key name checked with `tools/hostcfg.py`.
11. Self-disable after N faults, and **the refusal names the value it refused**.
12. No per-frame managed allocation. No ARC global assigned from an `exportc` body
    unless `{.threadvar.}`. No Nim `string`/`seq` in an `exportc` signature.
13. Main-thread work goes through `invoke_main` and runs **only** where
    `aowl_mq_may_run_here` says. Never widen that on a stall — **defer**.
14. Never blind-write: klass identity, instance size, Unity liveness, correct
    width. Readability is **not** a guard.
15. Never cache a factory-produced pointer across a frame; hold the producer.
16. Call with the values the game itself would pass, read off the live receiver.

**Before claiming it works**

17. `python tools/drainaudit.py`, `tools/abilint.py`, `tools/allocasserts.py` on the
    built artifact; then `tools/deploy.py check` for markers.
18. Assert a property of the **finished state**, preferably a negative. Three
    outcomes: PASS / FAIL / **INCONCLUSIVE**. If you cannot describe the input that
    would make your check fail, you have not written a check.

### 7.1 The invariant table — the deliverable

**41 invariants: 15 enforced by a tool or a test, 26 UNENFORCED.**

"Enforced" means a tool or test **fails closed** on violation. "In code, no test"
counts as UNENFORCED, because a mechanism nothing checks is a convention — and
every one of the eight defects in §0 lived behind a convention.

| id | invariant | enforcing tool | state |
|---|---|---|---|
| P1 | injection checks the remote thread's exit code | in code | **UNENFORCED** |
| P2 | nothing resolves or binds in `DllMain` | — | **UNENFORCED** |
| P3 | one copy of `aowl_mq_may_run_here` decides thread placement | `test_mqpolicy.py` | enforced |
| P4 | "never fired" is never treated as a stall | `test_mqpolicy.py` | enforced |
| P5 | no ARC type in an `exportc` signature | `abilint.py` #1 | enforced |
| P6 | no unlocked ARC global assigned in an `exportc` body | `abilint.py` #2 | enforced |
| P7 | no shipped binary carries mimalloc assertions | `allocasserts.py` | enforced |
| P8 | no cross-module free | — | **UNENFORCED** |
| D1 | no postfix site above 4 slots | `drainaudit.py` | enforced |
| D2 | declared slot counts agree with the metadata, matched by RVA | `drainaudit.py` | enforced |
| D3 | prologue verify reads the snapshot, not live memory | — | **UNENFORCED** |
| D4 | every detour target is UNIQUE; `unknown` refuses | — | **UNENFORCED** |
| D5 | no function is detoured twice | — | **UNENFORCED** |
| D6 | `aowl_stale_fires == 0` | — | **UNENFORCED** |
| D7 | the length decoder never guesses a length | in code | **UNENFORCED** |
| D8 | one `aowl_p_p_seh` per body, never nested | — | **UNENFORCED** |
| D9 | every game-data loop is capped | — | **UNENFORCED** |
| D10 | every feature flag defaults OFF | `hostcfg.py` (names only) | **UNENFORCED** |
| X1 | no gated export called without its token | — | **UNENFORCED** |
| X2 | every gated-export handle passes the shape filter | in code | **UNENFORCED** |
| X3 | the shape filter accepts real pointers (positive controls) | `test_handleshape.py` | enforced |
| X4 | a refusal names the value it refused | in code | **UNENFORCED** |
| X5 | static gate tokens are read from the mapped image | — | **UNENFORCED** |
| X6 | the name index's build identity matches the mapped DLL | the loader, fails closed | enforced |
| X7 | nothing says "reflection is dead" | — | **UNENFORCED** |
| M1 | every offset literal has resolver provenance | — | **UNENFORCED** |
| M2 | no offset from a zeroed generic table | resolvers print `GENERIC` | **UNENFORCED** |
| M3 | every managed store is klass + size + liveness gated | `hostwrite.h` exists, 1/12 sites | **UNENFORCED** |
| M4 | no 4-byte store into a reference slot | — | **UNENFORCED** |
| M5 | no factory pointer cached across a frame | — | **UNENFORCED** |
| M6 | readability is never the write guard | — | **UNENFORCED** |
| M7 | no postfix on a struct return above 8 bytes | `hostPatch` refusal | enforced |
| M8 | call arguments read off the live receiver | — | **UNENFORCED** |
| M9 | UI text uses the real setters and re-applies | `acceptance.py` | enforced |
| I1 | the inspector self-disables after N faults | in code | **UNENFORCED** |
| I2 | search verbs never convert STOPPED EARLY into absence | `test_inspect_silence.py` | enforced |
| I3 | a press target is active-checked | in `findtext` only | **UNENFORCED** |
| I5 | inspector writes need both gates | in code | **UNENFORCED** |
| G1 | the embedded manifest round-trips before injection | `consistency.py selftest` | enforced |
| G2 | the container's structural identity holds | `consistency.py` | enforced |
| G3 | no hardlink-propagating write | `consistency.py` | enforced |
| G4 | added/resized files reflected in the **embedded** manifest | — | **UNENFORCED** |
| G5 | `Logging.config` level-name lengths preserved | — | **UNENFORCED** |

### 7.2 The top five UNENFORCED invariants by blast radius, with the smallest fail-closed check

1. **X1 — a gated export called without its token.** Blast radius: the whole
   client, silently, for weeks. Defects #2 *and* #3 came from this one root, and #3
   was invisible for weeks because the garbage was load-bearing. *Smallest check:*
   `tools/gateaudit.py` — parse the 40 names out of
   `abi/aowlspt_il2cpp_gates_data.h`, grep every call site in `host/` and `mods/`,
   FAIL any that does not route through `aowl_host_gate_call` / `gatedHandle`. Pure
   text over two inputs already in the repo; register it in `selftests.py --fast`
   with a falsifier that inserts a raw call.
2. **D5 and D4 — a second detour on one function, or a shared RVA detoured.** Blast
   radius: one feature silently dies with no error at all (D5), or a hook fires for
   every one of a shared RVA's owners (D4) — up to thousands of unrelated methods.
   *Smallest check:* extend `drainaudit.py`, which **already** parses every target
   table and `attachDrain` site and already loads the metadata: FAIL on a duplicate
   RVA across all tables, and FAIL on `sharedness != UNIQUE`, with `unknown` as
   INCONCLUSIVE. Perhaps thirty lines in a tool that already gates the build.
3. **M3 and M6 — a managed store guarded only by readability.** Blast radius: heap
   corruption that detonates arbitrarily later, in the liveness walk, with no line
   of ours on the stack — this is the class that ate 2026-09-02. *Smallest check:*
   `tools/writeaudit.py` — the §4.2 inventory as code: enumerate every call site of
   the write primitives declared in `abi/*.h` and FAIL any not preceded by a
   klass-identity guard. Baseline the 12 known sites so the count can only go down,
   never up.
4. **D8 — a nested `aowl_p_p_seh`.** Blast radius: the outer guard is *disarmed*, so
   any unrelated fault in that body becomes a hard client kill, and the symptom is
   arbitrarily far from the nesting. *Smallest check:* a `nimlint.py` pattern — any
   `aowl_p_p_seh` reachable from a proc already inside one, over the static
   intra-module call graph. Conservative, and a false positive is cheap to silence
   with an explicit annotation.
5. **D10 — a feature flag that does not default OFF.** Blast radius: a new,
   unproven path runs for every user on the very next deploy, which is how an
   experiment becomes a release. *Smallest check:* `hostcfg.py` already knows every
   `readBoolKey` call site; make it also read the **default argument** and FAIL on
   any `true`, and assert the shipped `aowlspt-host.json` contains no key absent
   from that list.

*(Runner-up, and the cheapest of all: **X7**, one grep for "reflection is dead"
across `host/`, `mods/`, `abi/`, `docs/` and `.claude/`. It costs a line and it
stops a false fact from being re-learned — the `il2cpp-host` skill still asserts
it, and CLAUDE.md §5 explicitly corrects it.)*
