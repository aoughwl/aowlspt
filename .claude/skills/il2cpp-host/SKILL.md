---
name: il2cpp-host
description: Safety discipline and hard facts for writing host code that runs inside the live post-1.0 Tarkov client (IL2CPP). Load before writing or reviewing anything that detours a function, reads a game object field, calls a game method by RVA, touches UI text, or runs on the Unity main thread. Covers the mandatory guard pattern, what IL2CPP reflection can and cannot do, calling convention, how offsets are obtained, and the UI-text and double-detour traps.
---

# Host code inside the live client

The client is **IL2CPP**. There is no Mono, no BepInEx, no managed runtime to be
polite to. Our host DLL is injected into `EscapeFromTarkov.exe` and runs native
code, some of it on the Unity main thread via the `TarkovApplication::Update`
bridge (validated static RVA `0x977B10`).

Every rule here exists because breaking it crashed a live game.

## Safety discipline — non-negotiable

Any code path that touches the live game must do all of these:

1. **16-byte prologue byte-verify** before *any* detour bind or direct call at an
   RVA. If the bytes are not what you expect, refuse and log — never patch.
2. **Validate every pointer hop.** `VirtualQuery` / `aowl_is_readable` on each
   dereference, not just the first. `a->b->c` is three checks, not one.
3. **One `aowl_p_p_seh` around the whole body.** That guard is **not
   re-entrant** — a nested inner guard *disarms the outer one*. If you add a
   guard inside a guarded region you have removed protection, not added it.
4. **Cap every iteration.** No unbounded loops over game collections; a corrupt
   count field becomes an infinite loop inside a frame.
5. **Flag-gated, default OFF.** A new feature ships disabled. Read and set flags
   with `python tools/hostcfg.py show` / `set <key> on|off` — it validates key
   names against the host's actual `readBoolKey` call sites, so a typo cannot
   silently produce a flag nobody reads.
6. **Self-disable after N faults.** A path that has faulted N times must turn
   itself off rather than fault every frame forever.
7. **No per-frame managed allocation.** Nothing that allocates on the managed
   heap in an update path.
8. **Never blind-write.** Read, validate, then write — or do not write.

If a change cannot satisfy all eight, it is not ready to run in the client.

## IL2CPP facts

### Reflection is dead

These **fault**; do not call them, do not build on them:

```
il2cpp_object_get_class   il2cpp_class_get_name   il2cpp_value_box
```

…and any form of field iteration.

What actually works, and is the whole toolkit:

- **Raw static-offset field read/write**
- **Direct calls at a static RVA**
- **`il2cpp_string_new`**

### Calling convention

- **Instance:** `RCX = this`, then `RDX`/`R8`/`R9` = args, then a **hidden
  trailing `const MethodInfo*`**.
- **Static:** args in `RCX`..`R9`, then the trailing `MethodInfo*`.
- **Floats** in `XMM0`–`XMM3`.
- A **NULL `MethodInfo*` is fine — except for shared generics**, where it is not.

### Addresses

- Imagebase `0x180000000`. Runtime address = `GameAssemblyBase + (VA - 0x180000000)`.
- Generated code lives in the **`il2cpp` PE section, not `.text`**. Scanning
  `.text` finds nothing.

### Offsets come from metadata, never from a guess

```powershell
python tools\il2cpp_resolve.py fields <Type>
```

reads `Il2CppMetadataRegistration.fieldOffsets`. **Never guess an offset.** A
guessed offset that happens to read a plausible number is the worst outcome
available.

Metadata strings are **encrypted** (`tools/metablob.py`). String-searching the
metadata blob finds nothing and is not evidence of absence.

The known method VA table for the settings screen path is in **`docs/SETTINGS.md`** —
consult it rather than re-deriving. `docs/IL2CPP.md` has the ABI and patch-kind
details.

### Reach containers by walking, never by a raw offset

**Walk from a verified live object.** The settings container was only reached
this way, after `_rectTransform` at `0x78` kept reading null. An offset that can
read null is not a path; it is a coin flip that crashes half the time.

Get a live object you have already validated, then step, validating each hop.

## UI text traps

- **`ForceMeshUpdate` @ `0x628110` is a stripped stub** — a bare `ret`. Calling it
  does nothing. It is not a way to refresh text.
- Writing raw `m_text` **does not stick**: `LocalizedText` clobbers raw stores.
  You must **call the real setters**:
  - `LocalizedText::SetLabelText` @ `0x140FE70`
  - `TMP_Text::set_text` @ `0x51BC1E0`
- …and then **re-apply**, because the clobber can happen after your write.

## Detour traps

- **Two detours on one function**: the second overwrites the first's trampoline
  and the first feature silently dies. If a function is already detoured, **ride
  the existing detour as a drain** — add your work to it — rather than binding a
  second one.
- **Prologue verification after another feature patched it** reads *trampoline*
  bytes and self-rejects. If a verify fails on a function you know another
  feature hooks, that is this, not a bad RVA. Check the hook order.

## Before you claim a fix works

You cannot verify host behaviour by reading the host source. See the
`empirical-debugging` skill: turn on the client's logging, read
`aowlspt-host.log`, probe with a read-only guarded detour. And see
`aowlspt-deploy` before putting anything into `D:\Aowlspt`.
