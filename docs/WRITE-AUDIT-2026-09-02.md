# Write audit — every host/mod store into game-owned memory
### 2026-09-02, prompted by the raid-LOAD ACCESS_VIOLATION in
### `il2cpp_unity_liveness_calculation_from_root`, `test byte ptr [rcx],1`, RCX = 0x00000000FFFFFFFF

Instruments used: `rg` over `host/`, `abi/`, `mods/`; `python tools/il2cpp_resolve.py
D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat fields <Type>` for the
target field types; `grep` over the deployed `D:/Aowlspt/aowlspt/aowlspt-host.log`.
Nothing was built, deployed, or launched.

Each line is tagged MEASURED (an instrument produced it in this session) or INFERRED.

---

## 0. The value shape, and what it implies

INFERRED. `0x00000000FFFFFFFF` in an 8-byte slot has exactly three producers:

* **(A)** a **4-byte** store of `-1` into a slot whose upper dword was already zero
  (a freshly allocated managed object is zeroed, so this is the common case);
* **(B)** an 8-byte store of the literal `0xFFFFFFFF`;
* **(C)** the game's own `mov [field], rax` after a call whose EAX was `-1` — an
  `int32`-returning body reached where a reference-returning one was expected
  (writing EAX zero-extends RAX, producing exactly this bit pattern).

(A) is the shape this audit was built to enumerate. **No host or mod store matching
(A) or (B) exists outside the inspector `write` verb.** See §3.

---

## 1. The complete inventory of stores into GAME-owned memory

Derived by enumerating every write primitive in `abi/*.h` (`rg` for `memcpy(`,
`*(T*)…=`), then every Nim call site of each. Host-owned buffers
(`AowlOvTheme`, `AowlArgs`, `AowlRegs`, `aowl_cell_*`, `aowl_out_copy`,
`aowl_nav_actual`, `aowl_wg_rg_*`, `aowl_admin_hotkey_*`) are excluded: they never
touch the managed heap.

| # | site | helper | width | offset | how derived | field type (resolver) | klass guard |
|---|------|--------|-------|--------|-------------|----------------------|-------------|
| 1 | `host/Aowlspt.Host.Il2Cpp/botcap.nim:74` | `aowl_botcap_write_i32` | 4 | `0xC0` | `AOWL_BC_MAXBOTS_OFF`, const | MEASURED `EFT.BotSpawner.<MaxBots>k__BackingField : int` | **none** — `bcSanePtr` (range test) + VirtualQuery only. Value written is `0`. |
| 2 | `host/…/botai.nim:123` | `aowl_botai_write_u8` | 1 | `0x80` | `AOWL_BA_ISREADY_OFF`, const | MEASURED `BotWeaponManager.<IsReady>k__BackingField : bool` | **none** |
| 3 | `host/…/natesp.nim:1602` | `aowl_du_write_f32` ×4 | 4 | `0x28 + i*4` | `NeOffGraphicColor`, const | MEASURED `UnityEngine.UI.Graphic.m_Color : Color` (4 floats) | **none** |
| 4 | `host/…/nativeui.nim:1286,1296,1305` | `aowl_nu_set_ref` | 8 | `0x100`, `0x118`, `0x20` | consts | MEASURED `TMP_Text.m_fontAsset : TMP_FontAsset`, `TMP_Text.m_sharedMaterial : Material`, `Graphic.m_Material : Material` — REFERENCE, written 8-byte (correct width) | **none** |
| 5 | `host/…/modstab.nim:1515` | `aowl_uxpatch_write_ptr` | 8 | `0x110` | `ModsOffGroup`, const | MEASURED `UnityEngine.UI.Toggle.m_Group : ToggleGroup` (REFERENCE) | **partial, and the best in the tree**: the slot is read back first and written only if it `== stockGroup`, an identity test on the existing contents |
| 6 | `host/…/settingswrite.nim:283,327`, `host/…/invoke2.nim:475` | `aowl_uxpatch_write_ptr` | 8 | `0x0E0` | `AOWL_SUI_TMP_MTEXT`, const | `TMPro.TMP_Text.m_text : string` (INFERRED — not re-run here) | **none** |
| 7 | `host/…/settingswrite.nim:287,332` | `aowl_du_write_u8` | 1 | `0x378` | `AOWL_SW_TMP_DIRTY`, const | `m_havePropertiesChanged : bool` (INFERRED) | **none** |
| 8 | `host/…/settingswrite.nim:520`, `host/…/settingspages.nim:829` | `aowl_du_write_u8` | 1 | `0x120` | `AOWL_SW_TOGGLE_ISON`, const | MEASURED `UnityEngine.UI.Toggle.m_IsOn : bool` | **none** |
| 9 | `host/…/aowlhost.nim:6583` | `aowl_uxpatch_write_ptr` | 8 | **discovered at runtime** | scans the label component in 8-byte steps for a slot that reads back as a version-looking `String` (`aowlhost.nim` ~6540-6560) | **NONE — this offset never touches the field table** | **none**; flag `uxVersionBrandWrite` |
| 10 | `host/…/inspect.nim:5602` (`iCmdWrite`) | `aowl_insp_write_bytes` | 1/4/8 | **arbitrary**, from the operator's expression | none | none | **none**; `liveInspectorWrite` + an `allow write` line |
| 11 | `mods/textures/redirect.nim:622` | `aowl_bre_writeptr` | 8 | `0x20` | `EbPathOff`, const | MEASURED `Diz.Resources.EasyBundle._path : string` (REFERENCE, 8-byte, correct) | reads the old slot back and refuses unless it holds a readable string |
| 12 | `mods/fov/fov.nim:3153` | `fov_write_float` | 4 | `0xF8` | `fldoff.py` + disassembly of `CameraManager::get_Fov` (`movss xmm0,[rcx+0xF8]`) | `CameraManager._fov : float` (INFERRED, from the two agreeing instruments quoted in the source) | **none** |

**Unused write API — compiled in, zero call sites (MEASURED by `rg`):**
`aowlscene.nim:364-379` `writeI32 / writeF32 / writeU8 / writeBool`;
`hostwrite.nim:211-249` `hostWriteI32 / hostWriteU8 / hostWriteF32 / hostWritePtr`;
`debugui.nim:77` `cDuWriteI32` (only the U8 / F32 / Color siblings are called).

---

## 2. What the hostWrite gate actually covers

MEASURED (`grep -n -i hostwrite D:/Aowlspt/aowlspt/aowlspt-host.log`, run of
2026-09-02 15:0x): the trace **does** emit — 9 lines, all from **one** site,
`modstab.nim:modsReassertLabels`, and every one of them is `hostRecvOk`, the
*setter-call* gate, not a store. `rg hostWrite host mods` finds no other caller
anywhere in the tree.

CONCLUSION. `hostwrite.nim` gates 1 of the 12 sites in §1, in its weakest mode.
"hostWriteTrace was ON and the crash log shows zero `hostwrite` lines" therefore
does **not** narrow the field: it is equally consistent with the write coming from
any of the other 11 sites, and with `modsReassertLabels` simply not having run in
that session.

---

## 3. The negative result, stated so it can be falsified

MEASURED, across all 12 sites: the values stored are `0` (botcap), `1`
(botai / dirty / toggle), a float channel (natesp / fov), a `NULL` pointer
(modstab), an `Il2CppString*` from `il2cpp_string_new` (settingswrite, invoke2,
version brand, textures), or an `Il2CppObject*` read out of a live donor
(nativeui). **No site in host or mod code stores `-1` or `0xFFFFFFFF` at any
width.**

The single exception, and the only host path in the tree that *can* emit a 4-byte
`0xFFFFFFFF`, is the inspector `write` verb (`inspect.nim`, `iCmdWrite` →
`cInspWriteBytes(p, 0, size, buf)`): arbitrary evaluated address, arbitrary width,
arbitrary value; its only guards are the `liveInspectorWrite` flag, an `allow
write` line in the batch, and page writability. `write <expr> i32 -1` is a literal
match for producer (A).

Falsifier for that: a session in which the crash reproduces with
`liveInspectorWrite` off and no `WRITE`/`wrote` line in the host log.

---

## 4. Ranked candidates

### #1 — `mods/sain/client/live.nim:1935-1950`: a **native stack pointer** passed where a managed reference belongs

MEASURED by reading the code. The `il2cpp_runtime_invoke` fallback builds
`void** argv` and does, for **every** parameter past the first:

    argv[i] = cast[Il2CppPtr](addr scratch[i])

The `else:` branch — which the function's own doc comment says covers "an integer,
an enum **or a reference**" — leaves `scratch[i] = 0` and hands the callee
**`&scratch[i]`, a host stack address**, as the object. IL2CPP's convention is
restated verbatim four lines above it, and again in `abi/aowlspt_shim.h:576-582`:
a **reference slot IS the pointer**; only a value-type slot points at storage.
Passing a stack address as a managed reference is exactly the "native pointer into
a game-owned object" class in scope; it runs during raids (sain drive calls); and
the callee storing it into a field makes the next liveness walk follow host stack
memory. A real defect regardless of which crash it explains — but it does **not**
produce `0xFFFFFFFF`.

### #2 — `host/…/aowlhost.nim:6583`: the only host store at a **discovered**, non-metadata offset

MEASURED. Every other site writes a constant taken from `fieldOffsets`. This one
scans the label component 8 bytes at a time, accepts the first slot whose
*contents* look like a version string, and writes an 8-byte pointer there with no
check that the metadata declares that slot a reference at all. The acceptance test
is a test of the contents, not of the declared type — the check-that-cannot-fail
shape (CLAUDE.md 9b). Flag-gated `uxVersionBrandWrite`; if that flag was off in the
crash session it is excluded, which is one `hostcfg.py show` away.

### #3 — `host/…/botcap.nim:74`: an unguarded 4-byte store into a raid-load object

MEASURED that the offset is right (`EFT.BotSpawner.<MaxBots>k__BackingField : int`
@ `0xC0`) and the value is `0`, not `-1`. Ranked third only because of **when** it
runs — it is the one host store that fires on the raid-load path where the crash
happened — and because its receiver check is `bcSanePtr` (a canonical-range test)
plus VirtualQuery, neither of which can fail on the IL2CPP GC heap. It cannot
produce `0xFFFFFFFF`, so it is a candidate for some raid-load corruption, not for
this register value.

**Explicitly ranked out, with the measurement:**

* **postfxrows** — calls `SettingControl::SetText / SetName / SetSiblingIndex` and
  `NumberSlider::Show / SetCurrentValue`, i.e. game setters. No stores, and no
  `-1` argument anywhere; the declared defaults are floats. (It does leave 27
  instantiated rows out of `_createdControls`, a lifetime issue, not a store.)
* **modeskip Submit** — reads `_gameMode`@`0x160` and `_profileData`@`0x178` off
  the slot view the game handed it, range-checks the mode `0..8` and requires the
  profile pointer to be readable before calling. This is the fix for the 12:11 /
  12:42 `Profile = 1` shape; it is in place.
* **`applyPatchReturn`** (`invoke.nim:889-935`) — switches on the method's
  **declared** return type and refuses a type it cannot produce.
* **`aowl_frame_set_ret_*`** (`abi/aowlspt_frame.h:502-562`) — each checks
  `retKind` before writing, and each writes 8 bytes.
* **`aowl_ov_theme_kv`** (`abi/aowlspt_overlay.h:1855`) and
  **`aowl_args_set_i32`** (`abi/aowlspt_shim.h:594`) — 32-bit stores at computed
  offsets, but into host-owned `AowlOvTheme` / `calloc`'d `AowlArgs`, never the
  managed heap.

---

## 5. The one change that makes this class impossible

Make **every** store into managed memory go through one typed helper that is
handed, per call site, the *metadata-declared field descriptor* — not a bare
offset — and that refuses:

1. a store **narrower than 8 bytes into a slot the metadata declares a REFERENCE**.
   This is producer (A), and it is the only rule that would have caught it.
2. a store whose kind does not match the declared type (`ptr` into a `bool`, `i32`
   into a `Color`, …).
3. a receiver whose `*(void**)recv` is not the `Il2CppClass*` recorded when the
   pointer was captured — `hostwrite.nim` already implements exactly this, and
   nothing calls it.
4. an offset that was not produced by the resolver — i.e. **delete the runtime
   offset-scan at `aowlhost.nim:6583`**, and make `cUxWritePtr` / `cNuSetRef` /
   `cDuWrite*` / `cBcWriteI32` / `cBaWriteU8` private to the helper, so a new site
   *cannot* be written without a declared field.

Mechanically: generate a `FieldRef` table offline from
`Il2CppMetadataRegistration.fieldOffsets` — `(typeName, fieldName) -> (offset,
width, isReference, instanceSize)` — emit it as a header, and change the helper's
signature to take a `FieldRef` instead of an `int32`. That turns "is `0x110` on
this object an `int` or a `ToggleGroup`?" from a comment into a compile-time fact,
makes the table in §1 a build step rather than a document, and supplies the
`instSize` that `aowl_hw_recv_ok` currently has to refuse for lack of.

The same table settles the *argument* direction as well: a `runtime_invoke`
argument whose declared type `isReference` must be passed **as** the pointer —
which would have refused `live.nim`'s `argv[i] = addr scratch[i]` statically,
candidate #1 above.
