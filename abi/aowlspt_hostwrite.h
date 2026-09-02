/* aowlspt_hostwrite.h -- ONE gate for every host store into MANAGED memory.
 *
 * WHY THIS EXISTS (measured, 2026-09-02)
 * -------------------------------------
 * Two crash dumps put a *small integer* in a managed REFERENCE slot:
 *
 *   Crash_2026-09-02_131229783  EFT.UI.SeasonWidgetData::From, Profile == 1
 *   Crash_2026-09-02_161150163  same From, +0x11f, Profile == 0xffffffff (-1),
 *                               the reference having come from
 *                               MainMenuBaseScreenController.Profile@0x58
 *
 * A JSON payload cannot produce that. Only a native store into the wrong
 * object can. The host's write guards were, everywhere, a READABILITY test
 * (`aowl_is_readable` / `duOk` / `nuOk`): non-null plus VirtualQuery. On the
 * IL2CPP GC heap that test CANNOT FAIL -- the pages stay mapped after an
 * object dies, so a stale pointer into recycled memory passes every time and
 * the write lands in whatever type now occupies the address. A check that
 * cannot fail IS the bug (CLAUDE.md 9b).
 *
 * So readability is necessary and NOT sufficient. Three further questions have
 * to be asked of a receiver before anything is written through it:
 *
 *   1. is the Il2CppClass* still the one we recorded when we captured it?
 *      (catches GC recycling into a DIFFERENT type -- the crash above)
 *   2. is the offset inside that klass's instance size?
 *      (catches a right-type/wrong-layout write running off the end)
 *   3. is Unity's own liveness test still true for it?
 *      (`Object::op_Implicit`; a Destroyed object keeps a managed shell that
 *      reads back perfectly and answers false -- the nim side asks this one,
 *      it needs a byte-verified call)
 *
 * This header owns 1 and 2 plus the actual stores; `hostwrite.nim` owns 3 and
 * the per-site bookkeeping and logging.
 *
 * THE EIGHT RULES
 * ---------------
 * Nothing here detours, so there is no prologue to verify. Every entry point
 * VirtualQuery-validates its own pointer (rule 2), opens NO SEH guard of its
 * own -- every caller is already inside one and `aowl_p_p_seh` is not
 * re-entrant (rule 3) -- has no loops at all (rule 4), and never writes
 * without having read and validated first (rule 8). The trace is flag-gated
 * off (rule 5) and site-capped, and the refusal counters are what the nim side
 * self-disables on (rule 6). No allocation of any kind (rule 7).
 *
 * A REFUSAL IS THE POINT. These functions return 0 and write NOTHING when the
 * receiver does not check out. They never "write anyway and log"; a logged
 * corruption is still a corruption.
 */
#ifndef AOWLSPT_HOSTWRITE_H
#define AOWLSPT_HOSTWRITE_H

#include <stdint.h>
#include <windows.h>

/* ---------------------------------------------------------------------------
 * Counters. Read by the nim side for the summary line and the self-disable.
 * ------------------------------------------------------------------------ */
static int64_t g_hw_allowed = 0;
static int64_t g_hw_refused = 0;
static int64_t g_hw_refused_klass = 0;
static int64_t g_hw_refused_size = 0;
static int64_t g_hw_refused_mem = 0;

static int64_t aowl_hw_allowed(void)       { return g_hw_allowed; }
static int64_t aowl_hw_refused(void)       { return g_hw_refused; }
static int64_t aowl_hw_refused_klass(void) { return g_hw_refused_klass; }
static int64_t aowl_hw_refused_size(void)  { return g_hw_refused_size; }
static int64_t aowl_hw_refused_mem(void)   { return g_hw_refused_mem; }
static void    aowl_hw_reset(void) {
    g_hw_allowed = 0; g_hw_refused = 0;
    g_hw_refused_klass = 0; g_hw_refused_size = 0; g_hw_refused_mem = 0;
}

/* ---------------------------------------------------------------------------
 * Memory tests. `readable` mirrors aowl_nu_klass_of's guard; `writable`
 * additionally insists the protection actually permits a store AND that the
 * whole span [p, p+n) lies inside the SAME committed region -- a span that
 * straddles a region boundary is exactly the case a one-page VirtualQuery
 * answers yes to and then faults on.
 * ------------------------------------------------------------------------ */
static int aowl_hw_span_ok(void* p, int32_t n, int need_write) {
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t base, end, q;
    if (!p || n <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (need_write &&
        !(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    base = (uintptr_t)mbi.BaseAddress;
    end  = base + (uintptr_t)mbi.RegionSize;
    q    = (uintptr_t)p;
    if (q < base) return 0;
    if (q + (uintptr_t)n > end) return 0;
    return 1;
}

static int aowl_hw_readable(void* p, int32_t n)  { return aowl_hw_span_ok(p, n, 0); }
static int aowl_hw_writable(void* p, int32_t n)  { return aowl_hw_span_ok(p, n, 1); }

/* The klass pointer, guarded. `*(void**)obj` is all this is -- which is why a
 * bad pointer yields a PLAUSIBLE NUMBER rather than faulting, and why the
 * caller must compare it against a klass it recorded earlier rather than merely
 * checking it is non-null. */
static void* aowl_hw_klass_of(void* obj) {
    if (!aowl_hw_readable(obj, 8)) return NULL;
    return *(void**)obj;
}

/* THE INSTANCE SIZE IS NOT READ FROM Il2CppClass HERE, ON PURPOSE.
 *
 * The bound check needs Il2CppClass::instance_size. This repo has NO measured
 * byte offset for that field -- `il2cpp_class_instance_size` exists only as a
 * TOKEN-GATED export (RVA 0x5B2690, wired as `gateClassInstanceSize` in
 * aowlspt_il2cpp_gates_data.h), never as a struct offset. Reading it at a
 * guessed offset would produce a plausible number and a bound check that
 * passes for the wrong reason, which is the exact failure mode this header
 * exists to remove.
 *
 * So the SIZE IS AN ARGUMENT. The caller passes what it actually knows, and
 * 0 means UNKNOWN -- which is a refusal of the bounded store, not a waiver.
 * Three outcomes, never two: in-bounds / out-of-bounds / unknown. */
#define AOWL_HW_INSTSIZE_MAX 0x100000

/* ---------------------------------------------------------------------------
 * THE GATE. Returns 1 only when every question above answered yes.
 *
 *   recv        the object about to be written
 *   want_klass  the Il2CppClass* recorded when this receiver was CAPTURED.
 *               NULL means "not recorded" -- and that is a REFUSAL, not a
 *               waiver. An unrecorded expectation is precisely the state the
 *               crashing code was in.
 *   off, n      the span about to be stored, relative to recv.
 *   inst_size   the receiver's instance size if the caller knows it; 0 means
 *               UNKNOWN and refuses the write (see the note above).
 * ------------------------------------------------------------------------ */
static int aowl_hw_recv_ok(void* recv, void* want_klass, int32_t off, int32_t n,
                           uint32_t inst_size) {
    void* got;
    if (!recv || !want_klass || off < 0 || n <= 0) { g_hw_refused++; g_hw_refused_mem++; return 0; }
    if (!aowl_hw_readable(recv, 8))                { g_hw_refused++; g_hw_refused_mem++; return 0; }
    got = *(void**)recv;
    if (got != want_klass)                         { g_hw_refused++; g_hw_refused_klass++; return 0; }
    if (inst_size == 0 || inst_size > AOWL_HW_INSTSIZE_MAX ||
        (uint32_t)(off + n) > inst_size)           { g_hw_refused++; g_hw_refused_size++; return 0; }
    if (!aowl_hw_writable((void*)((uint8_t*)recv + off), n)) {
        g_hw_refused++; g_hw_refused_mem++; return 0;
    }
    g_hw_allowed++;
    return 1;
}

/* Klass-only check, for receivers written by CALLING a game setter rather than
 * by storing: there is no offset to bound, but the type question is the same
 * one and it is the one that mattered in both dumps. */
static int aowl_hw_recv_klass_ok(void* recv, void* want_klass) {
    void* got;
    if (!recv || !want_klass)       { g_hw_refused++; g_hw_refused_mem++; return 0; }
    if (!aowl_hw_readable(recv, 8)) { g_hw_refused++; g_hw_refused_mem++; return 0; }
    got = *(void**)recv;
    if (got != want_klass)          { g_hw_refused++; g_hw_refused_klass++; return 0; }
    g_hw_allowed++;
    return 1;
}

/* ---------------------------------------------------------------------------
 * The stores. Each is gate-then-write; none can write without the gate.
 * ------------------------------------------------------------------------ */
#define AOWL_HW_STORE(SUF, T)                                                  \
    static int aowl_hw_store_##SUF(void* recv, void* want_klass,               \
                                   int32_t off, uint32_t inst_size, T val) {   \
        if (!aowl_hw_recv_ok(recv, want_klass, off, (int32_t)sizeof(T),        \
                             inst_size))                                       \
            return 0;                                                          \
        *(T*)((uint8_t*)recv + off) = val;                                     \
        return 1;                                                              \
    }

AOWL_HW_STORE(u8,  uint8_t)
AOWL_HW_STORE(i32, int32_t)
AOWL_HW_STORE(i64, int64_t)
AOWL_HW_STORE(f32, float)
AOWL_HW_STORE(ptr, void*)

#undef AOWL_HW_STORE

#endif /* AOWLSPT_HOSTWRITE_H */
