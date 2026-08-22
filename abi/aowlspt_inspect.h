/* aowlspt_inspect.h -- the native half of the LIVE INSPECTOR / REPL.
 *
 * WHY THIS EXISTS
 * ---------------
 * Every client-side question on this build costs an edit, a full rebuild, a
 * deploy, a launch and ninety seconds to the menu -- and answers exactly ONE
 * log line, the one somebody had to predict in advance. Reflection is dead
 * here (`il2cpp_object_get_class`, `il2cpp_class_get_name`, `il2cpp_value_box`
 * and field iteration all fault), so the only way to learn anything about a
 * live object is to assert an offset and see whether it faults. That is the
 * whole reason the loop is slow: we cannot LOOK.
 *
 * This header is the instrument that lets us look. It provides, to
 * `host/Aowlspt.Host.Il2Cpp/inspect.nim`:
 *
 *   * a lock and a pending flag, so the host's tick thread can hand a batch of
 *     commands to Unity's main thread without a new socket, thread or port;
 *   * a BREADCRUMB -- a short string plus the pointer that was about to be
 *     dereferenced -- written before every hop, so a caught fault names WHERE
 *     it landed instead of only that it happened;
 *   * guarded byte reads and writes;
 *   * code-pointer verification: committed, executable, inside the `il2cpp`
 *     PE section (generated code does NOT live in `.text` on this build), and
 *     NOT already carrying somebody's detour;
 *   * generic direct-RVA call thunks in IL2CPP's convention.
 *
 * THE CALLING CONVENTION, as the project has it disassembled (see
 * `abi/aowlspt_invoke2.h` for the evidence):
 *
 *   instance:  RCX = this, RDX/R8/R9 = args, then a HIDDEN TRAILING
 *              `const MethodInfo*`;
 *   static:    RCX.. = args, then the same hidden trailing MethodInfo*;
 *   floats:    XMM0-3 BY POSITION -- so a C prototype that declares the
 *              argument as `double` in that position lands it in the right
 *              register with no assembly at all. That is why the thunks below
 *              are ordinary C functions: the ABI does the work.
 *
 * A NULL MethodInfo* is fine for everything except SHARED GENERIC code, which
 * dereferences it (`AddComponent<T>` reads it at +0x38). So every thunk takes
 * the MethodInfo* as an explicit parameter rather than hardcoding NULL, and
 * the REPL's `call` grammar has a `mi=` token for the generic case.
 *
 * WHAT IS DELIBERATELY NOT HERE
 * -----------------------------
 * No struct returns. `RectTransform::get_rect` returns a `Rect` by hidden
 * pointer and `Camera::WorldToScreenPoint` takes a `Vector3` by value; both
 * need a shape-specific prototype, and a generic thunk that guessed would
 * corrupt the stack. Those stay in `aowlspt_debugui.h` where they have real
 * prototypes. The REPL reports "unsupported signature" rather than trying.
 *
 * Everything here is `static`, like the rest of `abi/`: these headers are
 * included into the single translation unit nimony emits per module.
 */

#ifndef AOWLSPT_INSPECT_H
#define AOWLSPT_INSPECT_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * The channel's lock.
 *
 * Its own, not the host's `aowl_lock`. The host's one lock guards the patch
 * table and the callback queue and is taken on the firing path; this one is
 * taken by the tick thread when it hands over a batch and by Unity's thread
 * when it takes one, which is a few times a second at most. Keeping them
 * separate means the inspector can never be the reason a frame waits on the
 * patch table, and there is no order between two locks to get wrong because
 * neither is ever held while the other is taken.
 * ------------------------------------------------------------------ */
static volatile LONG aowl_insp_spin = 0;

static void aowl_insp_lock(void) {
    while (InterlockedCompareExchange(&aowl_insp_spin, 1, 0) != 0) {
        Sleep(0);
    }
}
static void aowl_insp_unlock(void) {
    InterlockedExchange(&aowl_insp_spin, 0);
}

/* The lock-free peek. Unity's thread runs this ONCE PER FRAME and must not
 * take a lock to discover that there is nothing to do -- that is the same
 * discipline `aowl_mq_enter` follows for the callback queue. */
static volatile LONG aowl_insp_pending = 0;
static int32_t aowl_insp_have(void) {
    return (int32_t)InterlockedCompareExchange(&aowl_insp_pending, 0, 0);
}
static void aowl_insp_set_pending(int32_t v) {
    InterlockedExchange(&aowl_insp_pending, (LONG)v);
}

/* ------------------------------------------------------------------ *
 * THE BREADCRUMB.
 *
 * "fault caught" with no location is exactly what has been costing cycles.
 * Before every dereference the evaluator writes what it is about to do and
 * the pointer it is about to do it to. If the VEH guard fires, the Nim side
 * reads these two back and reports them -- so a fault says
 *
 *     hop 'deref +0x78 of $verlabel' at 0x0000000000000000
 *
 * rather than "the guarded body faulted".
 *
 * Plain stores, no lock: only one thread is ever inside a guarded body, and a
 * torn read of a diagnostic string is not worth a critical section on the
 * hot path.
 * ------------------------------------------------------------------ */
static char  aowl_insp_crumb[192];
static void* aowl_insp_crumb_ptr = NULL;
static int32_t aowl_insp_crumb_seq = 0;

static void aowl_insp_mark(const char* what, void* p) {
    size_t n;
    if (!what) what = "?";
    n = strlen(what);
    if (n > sizeof(aowl_insp_crumb) - 1) n = sizeof(aowl_insp_crumb) - 1;
    memcpy(aowl_insp_crumb, what, n);
    aowl_insp_crumb[n] = 0;
    aowl_insp_crumb_ptr = p;
    aowl_insp_crumb_seq++;
}
static const char* aowl_insp_crumb_get(void) { return aowl_insp_crumb; }
static void* aowl_insp_crumb_ptr_get(void)   { return aowl_insp_crumb_ptr; }
static int32_t aowl_insp_crumb_seq_get(void) { return aowl_insp_crumb_seq; }

/* ------------------------------------------------------------------ *
 * Guarded raw access.
 *
 * `aowl_is_readable` (aowlspt_shim.h) is the VirtualQuery gate every hop in
 * this host already goes through; these add the byte-granular reads the REPL
 * needs on top of it. Each one re-checks rather than trusting the caller:
 * the REPL's whole job is to be pointed at addresses that are wrong.
 * ------------------------------------------------------------------ */
static int32_t aowl_insp_read_bytes(void* p, int32_t off, int32_t n,
                                    unsigned char* out) {
    unsigned char* q;
    if (!p || n <= 0 || !out) return 0;
    q = (unsigned char*)p + off;
    if (!aowl_is_readable(q, n)) return 0;
    memcpy(out, q, (size_t)n);
    return 1;
}

/* How many of the first `n` bytes at p+off are readable, rounded to the page
 * the query answers for. A dump that runs off the end of a commit should show
 * what IS there and stop, not refuse the whole request. */
static int32_t aowl_insp_readable_span(void* p, int32_t off, int32_t n) {
    int32_t got = 0;
    while (got < n) {
        int32_t step = n - got;
        if (step > 8) step = 8;
        if (!aowl_is_readable((unsigned char*)p + off + got, step)) break;
        got += step;
    }
    return got;
}

/* A write is a separate function from a read on purpose: it re-queries for
 * WRITE protection specifically, so a store into a read-only page is refused
 * here rather than caught by the VEH guard after the fact. */
static int32_t aowl_insp_write_bytes(void* p, int32_t off, int32_t n,
                                     const unsigned char* src) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned char* q;
    if (!p || n <= 0 || !src) return 0;
    q = (unsigned char*)p + off;
    if (VirtualQuery(q, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    /* The whole span must land inside the region the query answered for. */
    if ((uintptr_t)q + (size_t)n >
        (uintptr_t)mbi.BaseAddress + mbi.RegionSize) return 0;
    memcpy(q, src, (size_t)n);
    return 1;
}

/* ------------------------------------------------------------------ *
 * The module and its `il2cpp` section.
 *
 * Generated managed code is NOT in `.text` on this build; it is in a section
 * literally named `il2cpp`. A "call this RVA" command that landed in `.data`
 * or in some imported DLL would be a crash with no diagnosis, so the bounds
 * are computed from the PE headers once and every call target is checked
 * against them.
 * ------------------------------------------------------------------ */
static void*    aowl_insp_ga_base   = NULL;
static uint64_t aowl_insp_il2_start = 0;
static uint64_t aowl_insp_il2_end   = 0;
static uint64_t aowl_insp_img_end   = 0;

static void aowl_insp_bounds(void) {
    HMODULE ga;
    IMAGE_DOS_HEADER* dos;
    IMAGE_NT_HEADERS64* nt;
    IMAGE_SECTION_HEADER* sec;
    unsigned i;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return;
    if (aowl_insp_ga_base == (void*)ga && aowl_insp_img_end) return;
    aowl_insp_ga_base = (void*)ga;
    aowl_insp_il2_start = 0;
    aowl_insp_il2_end = 0;
    aowl_insp_img_end = 0;
    dos = (IMAGE_DOS_HEADER*)ga;
    if (!aowl_is_readable(dos, (int32_t)sizeof(*dos))) return;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS64*)((unsigned char*)ga + dos->e_lfanew);
    if (!aowl_is_readable(nt, (int32_t)sizeof(*nt))) return;
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    aowl_insp_img_end = (uint64_t)(uintptr_t)ga +
                        nt->OptionalHeader.SizeOfImage;
    sec = IMAGE_FIRST_SECTION(nt);
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (!aowl_is_readable(&sec[i], (int32_t)sizeof(sec[i]))) return;
        if (memcmp(sec[i].Name, "il2cpp", 6) == 0) {
            aowl_insp_il2_start = (uint64_t)(uintptr_t)ga +
                                  sec[i].VirtualAddress;
            aowl_insp_il2_end = aowl_insp_il2_start +
                                sec[i].Misc.VirtualSize;
            return;
        }
    }
}

static void* aowl_insp_module_base(void) {
    aowl_insp_bounds();
    return aowl_insp_ga_base;
}
static uint64_t aowl_insp_il2cpp_start(void) {
    aowl_insp_bounds(); return aowl_insp_il2_start;
}
static uint64_t aowl_insp_il2cpp_end(void) {
    aowl_insp_bounds(); return aowl_insp_il2_end;
}

/* ------------------------------------------------------------------ *
 * Code-pointer verification, in four questions.
 *
 * Returns 0 and sets a reason code the Nim side turns into a sentence, so a
 * refusal says WHY. Reasons:
 *   1 GameAssembly.dll not loaded
 *   2 outside the image
 *   3 not committed / not executable
 *   4 outside the `il2cpp` section
 *   5 the first bytes are a JUMP -- somebody's detour is already here, and
 *     what we would be verifying is a TRAMPOLINE, not the function. This is
 *     the exact trap that is currently self-rejecting `uxMenuModeText`.
 *   6 an expected prologue was supplied and does not match
 * ------------------------------------------------------------------ */
static int32_t aowl_insp_reason = 0;
static int32_t aowl_insp_last_reason(void) { return aowl_insp_reason; }

static int32_t aowl_insp_is_detoured(const unsigned char* p) {
    /* The shapes this project's own detour engine and every common inline
     * hook write at a function's first byte. */
    if (p[0] == 0xE9) return 1;                       /* jmp rel32          */
    if (p[0] == 0xFF && p[1] == 0x25) return 1;       /* jmp [rip+disp32]   */
    if (p[0] == 0xEB) return 1;                       /* jmp rel8           */
    if (p[0] == 0x48 && p[1] == 0xB8 && p[10] == 0xFF && p[11] == 0xE0)
        return 1;                                     /* mov rax,imm64;jmp  */
    if (p[0] == 0x68 && p[5] == 0xC3) return 1;       /* push imm32; ret    */
    return 0;
}

static void* aowl_insp_code(uint64_t rva) {
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    aowl_insp_reason = 0;
    aowl_insp_bounds();
    if (!aowl_insp_ga_base) { aowl_insp_reason = 1; return NULL; }
    p = (unsigned char*)aowl_insp_ga_base + rva;
    if (aowl_insp_img_end &&
        (uint64_t)(uintptr_t)p >= aowl_insp_img_end) {
        aowl_insp_reason = 2; return NULL;
    }
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0 ||
        mbi.State != MEM_COMMIT ||
        !(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_insp_reason = 3; return NULL;
    }
    if (aowl_insp_il2_start &&
        ((uint64_t)(uintptr_t)p < aowl_insp_il2_start ||
         (uint64_t)(uintptr_t)p >= aowl_insp_il2_end)) {
        aowl_insp_reason = 4; return NULL;
    }
    if (!aowl_is_readable(p, 16)) { aowl_insp_reason = 3; return NULL; }
    if (aowl_insp_is_detoured(p)) { aowl_insp_reason = 5; return NULL; }
    return (void*)p;
}

/* An OPTIONAL byte-exact prologue check, for a caller who knows what the
 * function should start with. `hex` is an even-length lowercase/uppercase hex
 * string, at most 32 bytes' worth. Empty string = no check requested. */
static int32_t aowl_insp_prologue_ok(void* p, const char* hex) {
    unsigned char want[32];
    int32_t n = 0;
    int32_t i;
    unsigned char* q = (unsigned char*)p;
    if (!hex || !hex[0]) return 1;
    for (i = 0; hex[i] && hex[i + 1] && n < 32; i += 2) {
        int hi = hex[i], lo = hex[i + 1], v;
        if (hi >= '0' && hi <= '9') v = (hi - '0') << 4;
        else if (hi >= 'a' && hi <= 'f') v = (hi - 'a' + 10) << 4;
        else if (hi >= 'A' && hi <= 'F') v = (hi - 'A' + 10) << 4;
        else return 0;
        if (lo >= '0' && lo <= '9') v |= (lo - '0');
        else if (lo >= 'a' && lo <= 'f') v |= (lo - 'a' + 10);
        else if (lo >= 'A' && lo <= 'F') v |= (lo - 'A' + 10);
        else return 0;
        want[n++] = (unsigned char)v;
    }
    if (n == 0) return 1;
    if (!aowl_is_readable(q, n)) return 0;
    if (memcmp(q, want, (size_t)n) != 0) { aowl_insp_reason = 6; return 0; }
    return 1;
}

/* ------------------------------------------------------------------ *
 * THE CALL THUNKS.
 *
 * One per ARGUMENT SHAPE, not per signature: the return value is whatever is
 * left in RAX (integer/pointer/bool) or XMM0 (float/double), and which of the
 * two a caller reads is a question of interpretation, not of the call. So a
 * shape needs exactly two entry points -- integer-class and float-class --
 * and the REPL's `sig` token picks the shape and then the interpretation.
 *
 * `mi` is the hidden trailing `const MethodInfo*` and is ALWAYS passed, NULL
 * or not. Naming it in the prototype rather than hardcoding it is what makes
 * shared generics reachable at all.
 * ------------------------------------------------------------------ */

/* Integer/pointer-class returns (RAX). */
static uint64_t aowl_insp_u_v(void* fn, void* mi) {
    uint64_t (*f)(void*) = (uint64_t (*)(void*))fn;
    return f(mi);
}
static uint64_t aowl_insp_u_p(void* fn, void* a0, void* mi) {
    uint64_t (*f)(void*, void*) = (uint64_t (*)(void*, void*))fn;
    return f(a0, mi);
}
static uint64_t aowl_insp_u_pp(void* fn, void* a0, void* a1, void* mi) {
    uint64_t (*f)(void*, void*, void*) =
        (uint64_t (*)(void*, void*, void*))fn;
    return f(a0, a1, mi);
}
static uint64_t aowl_insp_u_ppp(void* fn, void* a0, void* a1, void* a2,
                                void* mi) {
    uint64_t (*f)(void*, void*, void*, void*) =
        (uint64_t (*)(void*, void*, void*, void*))fn;
    return f(a0, a1, a2, mi);
}
static uint64_t aowl_insp_u_pppp(void* fn, void* a0, void* a1, void* a2,
                                 void* a3, void* mi) {
    uint64_t (*f)(void*, void*, void*, void*, void*) =
        (uint64_t (*)(void*, void*, void*, void*, void*))fn;
    return f(a0, a1, a2, a3, mi);
}
static uint64_t aowl_insp_u_pi(void* fn, void* a0, int32_t a1, void* mi) {
    uint64_t (*f)(void*, int32_t, void*) =
        (uint64_t (*)(void*, int32_t, void*))fn;
    return f(a0, a1, mi);
}
static uint64_t aowl_insp_u_pl(void* fn, void* a0, int64_t a1, void* mi) {
    uint64_t (*f)(void*, int64_t, void*) =
        (uint64_t (*)(void*, int64_t, void*))fn;
    return f(a0, a1, mi);
}
/* A float argument in position 1 lands in XMM1 purely because it is declared
 * `float` there -- that is what "floats XMM0-3 by position" means, and it is
 * why none of this needs assembly. */
static uint64_t aowl_insp_u_pf(void* fn, void* a0, float a1, void* mi) {
    uint64_t (*f)(void*, float, void*) =
        (uint64_t (*)(void*, float, void*))fn;
    return f(a0, a1, mi);
}
static uint64_t aowl_insp_u_pff(void* fn, void* a0, float a1, float a2,
                                void* mi) {
    uint64_t (*f)(void*, float, float, void*) =
        (uint64_t (*)(void*, float, float, void*))fn;
    return f(a0, a1, a2, mi);
}
static uint64_t aowl_insp_u_i(void* fn, int32_t a0, void* mi) {
    uint64_t (*f)(int32_t, void*) = (uint64_t (*)(int32_t, void*))fn;
    return f(a0, mi);
}
static uint64_t aowl_insp_u_f(void* fn, float a0, void* mi) {
    uint64_t (*f)(float, void*) = (uint64_t (*)(float, void*))fn;
    return f(a0, mi);
}

/* Float-class returns (XMM0). Same shapes, read from the other register. */
static float aowl_insp_f_v(void* fn, void* mi) {
    float (*f)(void*) = (float (*)(void*))fn;
    return f(mi);
}
static float aowl_insp_f_p(void* fn, void* a0, void* mi) {
    float (*f)(void*, void*) = (float (*)(void*, void*))fn;
    return f(a0, mi);
}
static float aowl_insp_f_pp(void* fn, void* a0, void* a1, void* mi) {
    float (*f)(void*, void*, void*) = (float (*)(void*, void*, void*))fn;
    return f(a0, a1, mi);
}
static float aowl_insp_f_pi(void* fn, void* a0, int32_t a1, void* mi) {
    float (*f)(void*, int32_t, void*) =
        (float (*)(void*, int32_t, void*))fn;
    return f(a0, a1, mi);
}
static float aowl_insp_f_pf(void* fn, void* a0, float a1, void* mi) {
    float (*f)(void*, float, void*) = (float (*)(void*, float, void*))fn;
    return f(a0, a1, mi);
}
static float aowl_insp_f_i(void* fn, int32_t a0, void* mi) {
    float (*f)(int32_t, void*) = (float (*)(int32_t, void*))fn;
    return f(a0, mi);
}

/* Void-class: identical machine code to the integer-class thunks (RAX is
 * simply not read), so they are not duplicated -- the REPL calls `u_*` and
 * discards. Documented here because its absence is otherwise a question. */

/* Reinterpretation helpers. The REPL reads a call's RAX as a bit pattern and
 * decides what it was afterwards; a float32 return that came back in XMM0 is
 * handled by the `f_*` thunks above, but a float32 stored in a FIELD arrives
 * as four raw bytes and has to be reinterpreted rather than converted. */
static float aowl_insp_bits_to_f32(uint32_t b) {
    float v; memcpy(&v, &b, 4); return v;
}
static double aowl_insp_bits_to_f64(uint64_t b) {
    double v; memcpy(&v, &b, 8); return v;
}
static uint32_t aowl_insp_f32_to_bits(float v) {
    uint32_t b; memcpy(&b, &v, 4); return b;
}
static uint64_t aowl_insp_f64_to_bits(double v) {
    uint64_t b; memcpy(&b, &v, 8); return b;
}

#endif /* AOWLSPT_INSPECT_H */
