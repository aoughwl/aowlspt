/* aowlspt_detour.h — x64 inline hooks, for `AowlHostApi.patch`.
 *
 * Harmony patches a managed method by rewriting IL. There is no IL in an
 * IL2CPP build, so the equivalent here is a code detour: overwrite the first
 * instructions of the compiled function with a jump to our own, and keep the
 * instructions we overwrote in a trampoline so the original can still run.
 *
 * Two notes before the mechanism, because both are easy to get wrong in ways
 * that only show up as a crash somewhere else.
 *
 * **Why not just swap `MethodInfo.methodPointer`.** It is a field, and writing
 * it is trivial. But only reflective dispatch reads it — IL2CPP compiles a
 * direct call site into a direct `call`, so a pointer swap intercepts
 * `il2cpp_runtime_invoke` and nothing the game itself does. That is worse than
 * useless: it would appear to work in a test and never fire in a raid. So the
 * code gets patched and `methodPointer` is left alone.
 *
 * **Why there is a length decoder below.** The jump needs 12 bytes, and x64
 * instructions are variable length, so the bytes being overwritten have to be
 * decoded to find a whole number of them. Copying a partial instruction into
 * the trampoline produces garbage that then executes.
 *
 * The decoder is deliberately conservative: it covers the instruction forms a
 * function prologue actually contains and refuses anything it does not
 * recognise rather than guessing a length. A refused patch is an error a mod
 * author can read. A guessed length is a corrupted game.
 *
 * RIP-relative instructions encode a displacement from their own address, so
 * copying one into a trampoline silently changes where it points. They are
 * also extremely common in a prologue — `mov eax, [rip+off]` is how any access
 * to a global compiles — so refusing them would refuse most real functions.
 * They are relocated instead: the displacement is adjusted by the distance the
 * instruction moved, and the patch is refused if the result no longer fits in
 * 32 bits.
 *
 * Relative branches (`call rel32`, `jmp rel8/32`, `jcc`) are still refused.
 * They could be rewritten too, but they are rare this early in a function, and
 * a refusal a mod author can read beats a rewrite nobody has checked.
 */

#ifndef AOWLSPT_DETOUR_H
#define AOWLSPT_DETOUR_H

#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AOWL_JMP_SIZE 12   /* mov rax, imm64 ; jmp rax */
#define AOWL_MAX_STOLEN 32

typedef struct AowlHook {
    void*   target;                       /* the function that was patched   */
    void*   detour;                       /* what it now jumps to            */
    void*   trampoline;                   /* stolen bytes + jump back        */
    uint8_t original[AOWL_MAX_STOLEN];    /* for unpatching                  */
    int32_t stolen;                       /* how many bytes were replaced    */
    int32_t installed;
} AowlHook;

/* ------------------------------------------------------------------ *
 * Instruction length
 * ------------------------------------------------------------------ */

/* The result of decoding one instruction. `len` is 0 when this decoder does
 * not recognise the instruction or cannot relocate it. `ripDisp` is the offset
 * within the instruction of a RIP-relative disp32, or -1 when there is none. */
typedef struct AowlInsn {
    int32_t len;
    int32_t ripDisp;
    int32_t terminal;   /* the instruction ends the function (ret) */
} AowlInsn;

static AowlInsn aowl_insn(const uint8_t* p) {
    AowlInsn out;
    out.len = 0;
    out.ripDisp = -1;
    out.terminal = 0;

    int32_t i = 0;
    int32_t opsize = 4;       /* immediate size for the 0x81/0xC7 group */
    int rexW = 0;

    /* Legacy prefixes. */
    for (;;) {
        uint8_t b = p[i];
        if (b == 0x66) { opsize = 2; i++; continue; }
        if (b == 0x67 || b == 0x2E || b == 0x3E || b == 0x26 ||
            b == 0x36 || b == 0x64 || b == 0x65 || b == 0xF0 ||
            b == 0xF2 || b == 0xF3) { i++; continue; }
        break;
    }

    /* REX. */
    if ((p[i] & 0xF0) == 0x40) {
        rexW = (p[i] & 0x08) != 0;
        i++;
    }

    uint8_t op = p[i++];

    /* Two-byte opcodes. Only the ones that turn up in a prologue. */
    if (op == 0x0F) {
        uint8_t op2 = p[i++];
        if (op2 >= 0x80 && op2 <= 0x8F) return out;    /* jcc rel32 */
        if ((op2 >= 0x10 && op2 <= 0x17) ||            /* movups/movss etc  */
            (op2 >= 0x28 && op2 <= 0x2F) ||
            (op2 >= 0x40 && op2 <= 0x4F) ||            /* cmovcc            */
            (op2 >= 0x54 && op2 <= 0x5F) ||
            (op2 >= 0x90 && op2 <= 0x9F) ||            /* setcc             */
            op2 == 0xB6 || op2 == 0xB7 ||              /* movzx             */
            op2 == 0xBE || op2 == 0xBF ||              /* movsx             */
            op2 == 0x1E || op2 == 0x1F) {              /* endbr64 / long nop */
            goto modrm;
        }
        return out;
    }

    /* One-byte opcodes with no ModRM. */
    if ((op >= 0x50 && op <= 0x57) ||                  /* push r64 */
        (op >= 0x58 && op <= 0x5F) ||                  /* pop r64  */
        op == 0x90 || op == 0xC3 || op == 0xCC || op == 0x99) {
        if (op == 0xC3) out.terminal = 1;              /* ret */
        out.len = i;
        return out;
    }
    if (op == 0xC2) { out.terminal = 1; out.len = i + 2; return out; }  /* ret imm16 */
    if (op >= 0xB8 && op <= 0xBF) {                    /* mov r, imm */
        out.len = i + (rexW ? 8 : (opsize == 2 ? 2 : 4));
        return out;
    }
    if (op == 0x68) { out.len = i + 4; return out; }   /* push imm32 */
    if (op == 0x6A) { out.len = i + 1; return out; }   /* push imm8  */

    /* Relative branches: the length is knowable, but relocating one would
     * change where it goes, so no length is reported. */
    if (op == 0xE8 || op == 0xE9) return out;          /* call/jmp rel32 */
    if (op == 0xEB) return out;                        /* jmp rel8       */
    if (op >= 0x70 && op <= 0x7F) return out;          /* jcc rel8       */

    /* One-byte opcodes with ModRM. */
    if ((op <= 0x3B && (op & 0x07) <= 0x03) ||         /* alu r/m, r */
        op == 0x84 || op == 0x85 ||                    /* test       */
        op == 0x88 || op == 0x89 || op == 0x8A || op == 0x8B ||  /* mov */
        op == 0x8D ||                                  /* lea        */
        op == 0x63) {                                  /* movsxd     */
        goto modrm;
    }
    if (op == 0x80 || op == 0x83) { opsize = 1; goto modrm; }
    if (op == 0x81) goto modrm;
    if (op == 0xC6) { opsize = 1; goto modrm; }
    if (op == 0xC7) goto modrm;
    if (op == 0xFF) goto modrm;                        /* inc/dec/call/jmp r/m */

    return out;

modrm: {
        uint8_t modrm = p[i++];
        uint8_t mod = modrm >> 6;
        uint8_t rm  = modrm & 0x07;
        uint8_t sibBase = 0xFF;

        if (mod != 3 && rm == 4) {                     /* SIB */
            sibBase = p[i] & 0x07;
            i++;
        }

        if (mod == 1) {
            i += 1;
        } else if (mod == 2) {
            i += 4;
        } else if (mod == 0) {
            if (rm == 5) {
                /* RIP-relative. Note where the displacement is so the copier
                 * can fix it up, then keep going for the length. */
                out.ripDisp = i;
                i += 4;
            } else if (rm == 4 && sibBase == 5) {
                i += 4;                                /* disp32, no base */
            }
        }

        if (op == 0x80 || op == 0x83 || op == 0xC6) i += 1;
        else if (op == 0x81 || op == 0xC7) i += (opsize == 2 ? 2 : 4);

        out.len = i;
        return out;
    }
}

/* Length only. The tests check lengths; the copier needs the whole record. */
static int32_t aowl_insn_len(const uint8_t* p) {
    return aowl_insn(p).len;
}

/* How many whole instructions must be taken to cover `need` bytes.
 *
 * Returns 0 if a `ret` is reached first. That is not a decoder limitation but
 * the most dangerous case there is: the function is shorter than the jump, so
 * stealing enough bytes would run off its end into whatever the linker put
 * next. The hook would then overwrite an unrelated function and the trampoline
 * would jump into the middle of one. It presents as a crash a long way from
 * the patch, which is exactly why it is checked here.
 */
static int32_t aowl_stolen_len(const uint8_t* p, int32_t need) {
    int32_t total = 0;
    while (total < need) {
        AowlInsn in = aowl_insn(p + total);
        if (in.len <= 0) return 0;
        if (total + in.len > AOWL_MAX_STOLEN) return 0;
        total += in.len;
        if (in.terminal && total < need) return 0;
    }
    return total;
}

/* Copies instructions from `src` to `dst`, rewriting the displacement of every
 * RIP-relative one so it still points where it did. Returns 0, or -1 if a
 * displacement no longer fits in 32 bits — which happens when the trampoline
 * lands more than 2 GB from the function the bytes came from. */
static int32_t aowl_copy_relocated(uint8_t* dst, const uint8_t* src, int32_t bytes) {
    int32_t at = 0;
    while (at < bytes) {
        AowlInsn in = aowl_insn(src + at);
        if (in.len <= 0) return -1;
        memcpy(dst + at, src + at, (size_t)in.len);
        if (in.ripDisp >= 0) {
            int32_t oldDisp;
            memcpy(&oldDisp, src + at + in.ripDisp, 4);
            /* The displacement is measured from the end of the instruction.
             * Both the instruction and its end moved by the same distance, so
             * the correction is exactly that distance. */
            int64_t delta = (int64_t)(intptr_t)(src + at) -
                            (int64_t)(intptr_t)(dst + at);
            int64_t newDisp = (int64_t)oldDisp + delta;
            if (newDisp > 2147483647LL || newDisp < -2147483648LL) return -1;
            int32_t nd = (int32_t)newDisp;
            memcpy(dst + at + in.ripDisp, &nd, 4);
        }
        at += in.len;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Installing
 * ------------------------------------------------------------------ */

static void aowl_write_jmp_abs(uint8_t* at, void* dest) {
    /* mov rax, imm64 ; jmp rax — 12 bytes, no displacement to get wrong, and
     * reaches anywhere in the address space. The 5-byte rel32 form is smaller
     * but only reaches +/-2 GB, which a DLL loaded far from the game image
     * cannot rely on. */
    at[0] = 0x48; at[1] = 0xB8;
    memcpy(at + 2, &dest, 8);
    at[10] = 0xFF; at[11] = 0xE0;
}

/* Executable memory within +/-2 GB of `near`.
 *
 * This is not an optimisation. The stolen instructions can be RIP-relative,
 * and their displacements are 32-bit — so if the trampoline lands further than
 * 2 GB from the function the bytes came from, no correction fits and the patch
 * has to be refused. A plain `VirtualAlloc(NULL, ...)` puts it wherever it
 * likes, which on a 64-bit process is usually far too far.
 *
 * So the address space is walked outward from the target in allocation-
 * granularity steps, trying to reserve at each free region until one takes.
 */
static void* aowl_alloc_near(void* anchor, size_t size) {
    /* `near` would be the obvious name; windef.h still defines it as a macro
     * for 16-bit compatibility, so it cannot be a parameter. */
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const uintptr_t gran = si.dwAllocationGranularity ?
                           si.dwAllocationGranularity : 0x10000;
    const uintptr_t base = (uintptr_t)anchor;
    const uintptr_t limit = 0x7FFF0000u;   /* stay comfortably inside 2 GB */

    for (uintptr_t delta = gran; delta < limit; delta += gran) {
        /* Above first: the region after a function is more often free than the
         * one before it, which tends to hold the rest of the module. */
        uintptr_t up = (base + delta) & ~(gran - 1);
        void* p = VirtualAlloc((void*)up, size, MEM_COMMIT | MEM_RESERVE,
                               PAGE_EXECUTE_READWRITE);
        if (p) return p;

        if (base > delta) {
            uintptr_t down = (base - delta) & ~(gran - 1);
            p = VirtualAlloc((void*)down, size, MEM_COMMIT | MEM_RESERVE,
                             PAGE_EXECUTE_READWRITE);
            if (p) return p;
        }
    }
    return NULL;
}

static void* aowl_hook_new(void) { return calloc(1, sizeof(AowlHook)); }
static void  aowl_hook_free(void* p) { free(p); }
static void* aowl_hook_trampoline(void* p) {
    return p ? ((AowlHook*)p)->trampoline : NULL;
}
static int32_t aowl_hook_installed(void* p) {
    return p ? ((AowlHook*)p)->installed : 0;
}
static int32_t aowl_hook_stolen(void* p) {
    return p ? ((AowlHook*)p)->stolen : 0;
}

/* 0 on success; negative codes describe the refusal so the host can report it.
 *   -1  no target or detour
 *   -2  the prologue could not be decoded, held a relative branch, or could
 *       not be relocated
 *   -3  the trampoline could not be allocated
 *   -4  the target pages could not be made writable
 */
static int32_t aowl_hook_install(void* handle, void* target, void* detour) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !target || !detour) return -1;

    uint8_t* t = (uint8_t*)target;
    int32_t stolen = aowl_stolen_len(t, AOWL_JMP_SIZE);
    if (stolen == 0) return -2;

    uint8_t* tramp = (uint8_t*)aowl_alloc_near(target,
                                               (size_t)(stolen + AOWL_JMP_SIZE));
    if (!tramp) return -3;

    if (aowl_copy_relocated(tramp, t, stolen) != 0) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        return -2;
    }
    aowl_write_jmp_abs(tramp + stolen, t + stolen);

    DWORD old = 0;
    if (!VirtualProtect(t, (SIZE_T)stolen, PAGE_EXECUTE_READWRITE, &old)) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        return -4;
    }

    memcpy(h->original, t, (size_t)stolen);
    aowl_write_jmp_abs(t, detour);
    /* Bytes between the jump and the end of the last stolen instruction are
     * filled with int3 rather than left as the tail of a half-overwritten
     * instruction. Unreachable either way; this traps instead of executing if
     * that ever turns out to be wrong. */
    for (int32_t k = AOWL_JMP_SIZE; k < stolen; k++) t[k] = 0xCC;

    VirtualProtect(t, (SIZE_T)stolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)stolen);

    h->target = target;
    h->detour = detour;
    h->trampoline = tramp;
    h->stolen = stolen;
    h->installed = 1;
    return 0;
}

static int32_t aowl_hook_remove(void* handle) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !h->installed) return -1;

    DWORD old = 0;
    uint8_t* t = (uint8_t*)h->target;
    if (!VirtualProtect(t, (SIZE_T)h->stolen, PAGE_EXECUTE_READWRITE, &old))
        return -4;
    memcpy(t, h->original, (size_t)h->stolen);
    VirtualProtect(t, (SIZE_T)h->stolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)h->stolen);

    if (h->trampoline) VirtualFree(h->trampoline, 0, MEM_RELEASE);
    h->trampoline = NULL;
    h->installed = 0;
    return 0;
}

/* ------------------------------------------------------------------ *
 * The detour body
 *
 * A patched method must land somewhere with the same calling convention as the
 * original, and there is one of those per patch. Rather than generate code per
 * hook, a fixed pool of thunks is used: each knows its own slot, and they all
 * funnel into one dispatcher.
 *
 * The dispatcher takes no arguments and returns nothing, which bounds what a
 * patch can do: it fires, it cannot read the original arguments, and it cannot
 * suppress the original. That is a real limit and the honest one to ship
 * first — reading arguments correctly needs a thunk per signature, and a patch
 * that reports the wrong arguments is worse than one that reports none.
 * ------------------------------------------------------------------ */

#define AOWL_MAX_HOOKS 16

extern void aowlspt_nim_patch_fired(int32_t slot);

typedef void (*AowlThunk)(void);

static AowlHook* g_hookSlots[AOWL_MAX_HOOKS];
static int32_t   g_hookCount = 0;

#define AOWL_THUNK(n) \
    static void aowl_thunk_##n(void) { \
        aowlspt_nim_patch_fired(n); \
        ((void(*)(void))g_hookSlots[n]->trampoline)(); \
    }

AOWL_THUNK(0)  AOWL_THUNK(1)  AOWL_THUNK(2)  AOWL_THUNK(3)
AOWL_THUNK(4)  AOWL_THUNK(5)  AOWL_THUNK(6)  AOWL_THUNK(7)
AOWL_THUNK(8)  AOWL_THUNK(9)  AOWL_THUNK(10) AOWL_THUNK(11)
AOWL_THUNK(12) AOWL_THUNK(13) AOWL_THUNK(14) AOWL_THUNK(15)

static AowlThunk g_thunks[AOWL_MAX_HOOKS] = {
    aowl_thunk_0,  aowl_thunk_1,  aowl_thunk_2,  aowl_thunk_3,
    aowl_thunk_4,  aowl_thunk_5,  aowl_thunk_6,  aowl_thunk_7,
    aowl_thunk_8,  aowl_thunk_9,  aowl_thunk_10, aowl_thunk_11,
    aowl_thunk_12, aowl_thunk_13, aowl_thunk_14, aowl_thunk_15
};

static int32_t aowl_hook_capacity(void) { return AOWL_MAX_HOOKS; }
static int32_t aowl_hook_used(void) { return g_hookCount; }

/* Claims a slot, installs the hook, and returns the slot index — which is what
 * `aowlspt_nim_patch_fired` receives, so the host knows which patch fired with
 * no lookup on the hot path. Negative values are the install errors above, or
 * -5 when the pool is exhausted. */
static int32_t aowl_hook_attach(void* handle, void* target) {
    if (g_hookCount >= AOWL_MAX_HOOKS) return -5;
    int32_t slot = g_hookCount;
    g_hookSlots[slot] = (AowlHook*)handle;
    int32_t rc = aowl_hook_install(handle, target, (void*)g_thunks[slot]);
    if (rc != 0) {
        g_hookSlots[slot] = NULL;
        return rc;
    }
    g_hookCount++;
    return slot;
}

#endif /* AOWLSPT_DETOUR_H */
