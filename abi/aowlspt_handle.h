/* aowlspt_handle.h -- is this 64-bit value even SHAPED like a handle?
 *
 * WHY THIS IS A HEADER OF ITS OWN, WITH NO <windows.h>
 * ===================================================
 * Same reason as `aowlspt_mqpolicy.h`: a safety rule that only exists inside a
 * DLL injected into a live game cannot be tested, and an untested safety rule
 * is a comment. `tools/test_handleshape.py` compiles and RUNS this, with
 * positive controls, so "the filter rejects things" and "the filter rejects
 * everything" cannot be confused.
 *
 * THE MEASUREMENT
 * ===============
 * Unity crash report `Crash_2026-09-02_224920325`, host build sha256 350dba69,
 * ~10 s after boot, on the Unity drain thread. Symbolised from the host's own
 * `.pdata` (the DLL has no pdb) and from the disassembly at each return
 * address:
 *
 *   aowl_thunk_common+0x66     the PREFIX dispatch return address
 *     -> ... -> bridgeProof+0x105 -> valueBox+0x1b -> GameAssembly, 0xC0000005
 *   RCX = 0x6e11f7fc349b3101   the Il2CppClass* handed to il2cpp_value_box
 *   RDX = 0x000001ed62c8c1f0   a real, readable cell
 *
 * The handle came from `il2cpp_class_from_name`, which is
 * `AOWL_GATE_KIND_NONCE` in `abi/aowlspt_il2cpp_gates_data.h`: called with the
 * stock signature it returns MT19937-64 output -- uniform random and always
 * NON-ZERO, so every `!= NULL` check in the path passed.
 *
 * TWO FILTERS, AND WHAT EACH ONE IS WORTH
 * =======================================
 *   1. CANONICAL ADDRESS. Every Win64 user-mode pointer has bits 47..63 clear.
 *      A uniform random 64-bit value does not, with probability 1 - 2^-17.
 *   2. ALIGNMENT. Every IL2CPP metadata record (Il2CppClass, MethodInfo,
 *      FieldInfo, Il2CppType, PropertyInfo) is at least pointer-aligned. A
 *      uniform random value is not, seven times in eight.
 *
 * Together they let a trap return through with probability about 2^-20. The
 * caller adds a VirtualQuery as a third, independent filter -- that one needs
 * the OS, which is why it is NOT here.
 *
 * THIS IS A REFUSAL, NOT A GUARANTEE. It narrows a certain crash to an
 * improbable one. The only thing that makes a gated export SAFE is
 * `aowl_host_gate_call` with a real token. Nothing here should ever be quoted
 * as permission to call one without.
 *
 * NULL answers 0 as well: a caller that wants to distinguish "the export said
 * no" from "the export was trapped" has already branched on NULL before
 * arriving here, and folding them is the safe direction for everyone else. */
#ifndef AOWLSPT_HANDLE_H
#define AOWLSPT_HANDLE_H

#include <stdint.h>

/* 1 when `v` could be a real IL2CPP metadata handle, 0 when it certainly is
 * not. Pure: no OS calls, no dereference, no globals -- so it is total, and a
 * test can enumerate it. */
static inline int aowl_handle_shape_ok(uint64_t v) {
    if (v == 0u)             return 0;   /* nothing to check                  */
    if ((v >> 47) != 0u)     return 0;   /* not a Win64 user-mode address     */
    if ((v & 7u) != 0u)      return 0;   /* not pointer-aligned               */
    return 1;
}

#endif /* AOWLSPT_HANDLE_H */
