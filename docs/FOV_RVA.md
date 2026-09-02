# FOV mod — static RVAs (byte-verified, offline)

Resolved offline with `tools/il2cpp_resolve.py` against
`D:/Games/Tarkov/GameAssembly.dll` (123,891,024 bytes, 2026-08-12) and the
decrypted metadata `.cache/global-metadata.dec.dat` (build 1.1.0.1.46777).
Imagebase `0x180000000`; runtime address = `GameAssemblyBase + RVA`.

**Mandatory self-check first (must pass before any RVA below is trusted):**
`il2cpp_resolve.py ... verify-fields` →
`_stringLength got=0x10 exp=0x10 OK`, `_firstChar got=0x14 exp=0x14 OK`,
`STRING LAYOUT SELF-CHECK PASSED`. **PASS.**

The calling convention for a direct call / RVA detour is the IL2CPP one:
instance `RCX=this`, remaining args by Win64 position (`RDX/R8/R9`, floats
`XMM0..3` by the same slot index), then a **hidden trailing `const MethodInfo*`**.
NULL `MethodInfo*` is fine here (none is a shared generic).

## The two already-working RVAs (confirmed unchanged)

| method | RVA | kind / signature | prologue (16B) | shared? | verdict |
|---|---|---|---|---|---|
| `EFT.CameraControl.CameraManager::get_Instance` | `0x1263BD0` | static, `CameraManager get_Instance()` | `48 83 EC 28 80 3D E6 8B E5 05 00 75 18 48 8D 0D` | **UNIQUE** (owners=1) | **USABLE** — real body, `il2cpp` section. Matches mod const `RvaCamInstance`. |
| `EFT.CameraControl.CameraManager::SetFov(float,float,bool)` | `0x1268D20` | instance, `void SetFov(float x, float time, bool applyFovOnCamera)` (rid 81746, arity 3) | `48 89 5C 24 10 56 48 83 EC 40 80 3D AD 3A E5 05` | **UNIQUE** (owners=1) | **USABLE** — real body, `il2cpp` section. Matches mod const `RvaSetFov3`. |

Both are already called by RVA in `bindFovStatics`/`applyFov`; the resolver
reproduces the exact addresses the mod hardcodes, so those constants are current
for this build.

## The three previously-REFUSED (by-name, token-gated) methods — now resolved

Each was refused by the mod because confirming its signature/target went through
the token-gated IL2CPP export ABI (fact #217: 38–40 of 241 `il2cpp_*` exports
take a trailing 32-byte token; on mismatch they return a per-thread MT19937-64
random non-zero uint64, so the handle is garbage, the nil check passes, and the
first dereference kills the client). Resolved OFFLINE instead:

| method | RVA | kind / signature | prologue (16B) | shared? | verdict |
|---|---|---|---|---|---|
| `EFT.Player::CalculateScaleValueByFov` | `0x6FC250` | instance, `void CalculateScaleValueByFov(float fov)` (type 7013, rid 42126, arity 1) | `F3 0F 5C 0D 40 A6 EB 05 F3 0F 10 05 A0 9D EB 05` | **UNIQUE** (owners=1) | **USABLE as a detour target** — real float-math body (`subss xmm1,…`), `il2cpp` section, not the `0x628110` stub. |
| `FirearmController::get_AimingSensitivity` | `0x7773F0` | instance, `float get_AimingSensitivity()` (type 6835, rid 43152, arity 0) | `40 53 48 83 EC 20 48 8B 11 48 8B D9 48 8B 82 C8` | **UNIQUE** (owners=1) | **USABLE as a detour target** — real instance-getter body, `il2cpp` section. Returns in XMM0. |
| `EFT.InventoryLogic.SightComponent::get_GetCurrentSensitivity` | `0x104A140` | instance, `float get_GetCurrentSensitivity()` (type 11841, rid 72574, arity 0) | `40 53 48 83 EC 20 80 3D 48 17 07 06 00 48 8B D9` | **UNIQUE** (owners=1) | **USABLE as a detour target** — real body (static-init check + getter), `il2cpp` section. Returns in XMM0. |

Note the type name the mod uses for the aiming-sensitivity getter,
`EFT.Player.FirearmController`, resolves on this build to the un-namespaced
nested type **`FirearmController`** (type index 6835), not
`EFT.ClientFirearmController` (8726, which has no `get_AimingSensitivity`).

Call/detour frames DERIVED from returnType/parameterStart/parameterCount (§5),
not inferred from the names:

* `CalculateScaleValueByFov` — `RCX=Player*`, `XMM1=fov` (arg slot 1),
  `R8=MethodInfo*`. Effect (upstream `CalculateScaleValueByFovPatch`) is a
  **prefix that replaces the body with a constant** — a detour, not a call.
* `get_AimingSensitivity` — `RCX=FirearmController*`, `RDX=MethodInfo*`, result
  `XMM0`. Effect (upstream `AimingSensitivityPatch`) is a **postfix that scales
  the original return** — a detour, not a call.
* `get_GetCurrentSensitivity` — `RCX=SightComponent*`, `RDX=MethodInfo*`, result
  `XMM0`. Effect (upstream `ScopeSensitivityPatch`) is a **prefix that replaces
  the return from the magnification→sensitivity table** — a detour, not a call.

## Wiring status: RESOLVED but NOT wired — blocked on a host facility

All three RVAs are clean (UNIQUE, real body, verified, not the stub), so an
RVA-based **detour** on any of them is safe by the sharedness rule. They are NOT
wired, for a reason that is a host-ABI gap, not an RVA problem:

* All three effects are **detours** (replace/scale a float the game reads), not
  direct calls the mod makes. Calling `get_AimingSensitivity` / `get_GetCurrentSensitivity`
  by RVA would only *read* the base value; it cannot change what the game uses.
  So the "call it by RVA like SetFov" pattern does not apply here.
* The mod ABI exposes only **by-name** patching — `patch`/`patchTyped`
  (`aowl/src/aowlspt/abi.nim`) take `target: AowlSlice` (a string like
  `EFT.Player::CalculateScaleValueByFov`). There is **no mod-facing
  patch-by-RVA**. On the client a by-name host detour is fatal when USED (facts
  #198/#145), which is exactly why `watch`/`hook` decline in-client.
* The host already detours *its own* per-frame targets by RVA via an offline
  nameIndex (e.g. `EFT.TarkovApplication::Update @ il2cpp+0x977B10`,
  byte-verified) — it simply does not expose that path to mods.

**To wire these three, one of the following is needed (a considered decision +,
for the second, a live probe):**

1. A mod-facing **patch-by-RVA** entry in the host ABI (prefix/postfix with the
   typed register frame the effects need: replace a float / read+scale a float
   result). The RVAs + prologues above are exactly what it would consume.
2. OR empirical proof that the host's existing `patch(name)` resolves the target
   through its **offline nameIndex** (safe) rather than the token-gated IL2CPP
   export (fatal) on the client. That is a **live probe**, not something
   resolvable offline.

Until one of those lands, wiring would be a fabricated, unverifiable detour, so
the three effects remain honestly **blocked** — not on a missing/shared/stub
RVA, but on the patch-installation facility.


---

## CORRECTION, measured 2026-09-01: the blocker above had already expired

The section titled "Wiring status: RESOLVED but NOT wired" is **wrong on this
branch**, and it is worth saying how rather than deleting it, because it is what
a later task was briefed from.

Its claim was that "the mod ABI exposes only by-name patching ... there is no
mod-facing patch-by-RVA". Measured against the source instead:
`aowlhost.nim`'s `installPatch` decides `parseRvaSpec` **before** the name
split, and a mod's `patchTyped` target may be
`Type::Method@0xRVA/<shape>[!<hex prologue>]`. `mods/ammoloading` has been
shipping four such specs, and `mods/fov` has been arming all three effects
through them (`armScaleFix`, `armScopeSensitivity`, `armAimingSensitivity`,
gated on `enableRvaDetours`). The JSON patch ABI *is* refused for an `@0x`
target -- it needs a `MethodInfo` to describe the frame -- which is probably
what the original note was remembering.

What was genuinely missing, and is now in place, is not the address path but
the **checks around it**. `resolveByRva` answers everything about the address
(module, code page, `il2cpp` section, prologue-vs-snapshot) and nothing about
the write, so until now a mod's by-RVA detour could:

* declare **no** prologue at all -- `resolveByRva` warns and continues, which
  is right for the host's own binder and wrong for a mod;
* land on a **folded** address -- 28.3% of by-name keys do -- with sharedness
  asserted only in a comment;
* be the **second** detour on a function, overwriting the first's trampoline.

`host/Aowlspt.Host.Il2Cpp/patchrva.nim` gates all three, refuses out loud
naming the gate, and proves the gates can say no with a four-probe read-only
self-check on first use. The mod side is `RvaPatchTarget` +
`hookRva`/`hookReturnRva` (`aowl/src/aowlspt/abi.nim`, `game.nim`).

One measured consequence for this document's own table: the aiming-sensitivity
row's type name is right about the metadata and wrong as an **index key**. The
host now looks the name up to cross-check the RVA and read the share count, and
`il2cpp_nameindex.py lookup` says
`EFT.Player.FirearmController::get_AimingSensitivity/0` -> NOT FOUND while
`FirearmController::get_AimingSensitivity/0` -> `0x7773F0`, not shared. The mod
carries the short form now.
