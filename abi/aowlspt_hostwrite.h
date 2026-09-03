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
#include "aowlspt_fieldrefs.h"

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

/* ===========================================================================
 * THE TYPED PATH -- a FieldRef instead of a bare offset.
 *
 * INTERACTION-LAYER-MAP M3/M6, and WRITE-AUDIT section 5. Everything above
 * takes an `int32_t off` and an `inst_size` the caller supplies, so the caller
 * can still be wrong about BOTH -- and about the one thing that produced the
 * `0x00000000FFFFFFFF` crash: whether the slot is a managed REFERENCE.
 *
 * `AowlFieldRef` (abi/aowlspt_fieldrefs.h, GENERATED from
 * Il2CppMetadataRegistration.fieldOffsets by tools/fieldrefs.py) answers all
 * three from the metadata. These five refusals are the deliverable:
 *
 *   R1 NARROW-INTO-REFERENCE  a store of fewer than 8 bytes into a slot the
 *                             metadata declares a reference. This is producer
 *                             (A) in WRITE-AUDIT section 0 and it is the only
 *                             rule that would have caught the crash.
 *   R2 TOO-WIDE               a store wider than the declared field.
 *   R3 KLASS                  the receiver's `*(void**)recv` is not one of the
 *                             klasses ADMITTED for this FieldRef. Admission is
 *                             explicit (aowl_fr_admit) and capped; a FieldRef
 *                             with zero admitted klasses refuses everything.
 *   R4 RECV                   null, or the span is not readable/writable.
 *   R5 BOUND                  off+n outside `inst_size_min`.
 *
 * HOW HONEST EACH ONE IS, since a check that cannot fail IS the bug:
 *   R1, R2  strong and falsifiable -- they compare the caller's width against
 *           a fact taken from the metadata, not against the caller's own idea.
 *   R3      strong against GC RECYCLING (the measured crash class): a pointer
 *           whose object died and whose memory now holds a different type has
 *           a different klass and is refused. It is TRUST-ON-FIRST-USE, so it
 *           is NOT a defence against admitting a wrong klass in the first
 *           place; that is why admission is a separate, explicit call the site
 *           has to justify, and why it is capped at AOWL_FR_MAX_KLASS (a
 *           polymorphic receiver -- AnimatedToggle for a Toggle FieldRef -- is
 *           a different concrete klass, so an allowlist is required, and an
 *           unbounded one would degenerate into "admit anything").
 *   R5      WEAK BY CONSTRUCTION here, and said so rather than dressed up: for
 *           a generated FieldRef the offset came out of the same table as the
 *           bound, so it cannot fire. It is kept because it costs nothing and
 *           because it DOES fire on a hand-edited or stale header.
 *
 * No loops except the capped klass scan. No allocation. No SEH of its own --
 * every caller is already inside `aowl_p_p_seh`, which is not re-entrant.
 *
 * NOTE ON LINKAGE: aowlspt_fieldrefs.h declares each row `static`, so the
 * admission set is per translation unit. The host is built as a single TU, so
 * this is currently a non-issue; if that ever stops being true the rows must
 * become a single non-static table, not silently re-admitted per TU.
 * ======================================================================== */

static int64_t g_fr_refused_narrow_ref = 0;   /* R1 */
static int64_t g_fr_refused_width      = 0;   /* R2 */
static int64_t g_fr_refused_klass      = 0;   /* R3 */
static int64_t g_fr_admitted           = 0;

static int64_t aowl_fr_refused_narrow_ref(void) { return g_fr_refused_narrow_ref; }
static int64_t aowl_fr_refused_width(void)      { return g_fr_refused_width; }
static int64_t aowl_fr_refused_klass(void)      { return g_fr_refused_klass; }
static int64_t aowl_fr_admitted(void)           { return g_fr_admitted; }

/* Field metadata, for the nim side's refusal messages. A refusal that does not
 * NAME the value it refused is half a refusal (map section 7, rule 11). */
static const char* aowl_fr_type(AowlFieldRef* fr)  { return fr ? fr->type_name : "(null FieldRef)"; }
static const char* aowl_fr_field(AowlFieldRef* fr) { return fr ? fr->field_name : "(null FieldRef)"; }
static int32_t aowl_fr_off(AowlFieldRef* fr)       { return fr ? fr->off : -1; }
static int32_t aowl_fr_width(AowlFieldRef* fr)     { return fr ? fr->width : 0; }
static int32_t aowl_fr_isref(AowlFieldRef* fr)     { return fr ? fr->is_reference : 0; }
static int32_t aowl_fr_nklass(AowlFieldRef* fr)    { return fr ? fr->nklass : 0; }

/* ADMIT the klass of a receiver the caller vouches for.
 *
 * "Vouches for" has one legitimate meaning: the pointer came straight out of a
 * place whose type is a fact -- a detour's `this` on a method declared by that
 * type, or a component the game itself handed back. It NEVER means "it read
 * back plausibly".
 *
 * Returns 1 if the klass is now admitted (or already was), 0 on refusal. */
static int aowl_fr_admit(AowlFieldRef* fr, void* recv) {
    void* k;
    int i;
    if (!fr || !recv)                  { g_hw_refused++; g_hw_refused_mem++; return 0; }
    if (!aowl_hw_readable(recv, 8))    { g_hw_refused++; g_hw_refused_mem++; return 0; }
    k = *(void**)recv;
    if (!k || !aowl_hw_readable(k, 8)) { g_hw_refused++; g_hw_refused_mem++; return 0; }
    for (i = 0; i < fr->nklass && i < AOWL_FR_MAX_KLASS; ++i)
        if (fr->klass[i] == k) return 1;
    if (fr->nklass >= AOWL_FR_MAX_KLASS) { g_hw_refused++; g_fr_refused_klass++; return 0; }
    fr->klass[fr->nklass++] = k;
    g_fr_admitted++;
    return 1;
}

/* The klass the receiver actually presents -- for the refusal message. Returns
 * NULL rather than faulting on an unreadable receiver. */
static void* aowl_fr_klass_of(AowlFieldRef* fr, void* recv) {
    (void)fr;
    if (!recv || !aowl_hw_readable(recv, 8)) return 0;
    return *(void**)recv;
}

/* THE GATE. `n` is the width the CALLER is about to store -- passed in rather
 * than taken from the FieldRef, precisely so R1/R2 have something to compare.
 *
 * `sub` is the byte offset WITHIN the field (natesp writes Color one f32
 * channel at a time: sub = 0/4/8/12). It is bounded by the field width, so a
 * sub-field store can never leave the field.
 *
 * Returns 1 only when every question answers yes. Out-param `why` gets a
 * stable reason code so the nim side can name the refusal:
 *   0 ok, 1 narrow-into-reference, 2 too-wide, 3 klass, 4 recv/mem, 5 bound,
 *   6 the FieldRef itself is unusable (null, or width 0 = generator could not
 *     derive it and refused to guess). */
static int aowl_fr_gate(AowlFieldRef* fr, void* recv, int32_t sub, int32_t n,
                        int32_t* why) {
    void* got;
    int i, seen = 0;
    int32_t off;
    if (why) *why = 6;
    if (!fr || fr->width <= 0 || fr->off < 0) { g_hw_refused++; return 0; }

    /* R1 -- the rule that would have caught the crash. A reference slot is 8
     * bytes and is written 8 bytes or not at all. A 4-byte store of -1 into a
     * zeroed reference slot is exactly `0x00000000FFFFFFFF`. */
    if (fr->is_reference && (n != 8 || sub != 0)) {
        if (why) *why = 1;
        g_hw_refused++; g_fr_refused_narrow_ref++; return 0;
    }
    /* R2 */
    if (n <= 0 || sub < 0 || sub + n > fr->width) {
        if (why) *why = 2;
        g_hw_refused++; g_fr_refused_width++; return 0;
    }
    /* R4 */
    if (!recv || !aowl_hw_readable(recv, 8)) {
        if (why) *why = 4;
        g_hw_refused++; g_hw_refused_mem++; return 0;
    }
    /* R3 -- capped scan, and zero admitted klasses refuses. */
    got = *(void**)recv;
    for (i = 0; i < fr->nklass && i < AOWL_FR_MAX_KLASS; ++i)
        if (fr->klass[i] == got) { seen = 1; break; }
    if (!seen) {
        if (why) *why = 3;
        g_hw_refused++; g_fr_refused_klass++; return 0;
    }
    /* R5 */
    off = fr->off + sub;
    if (fr->inst_size_min == 0 || fr->inst_size_min > AOWL_HW_INSTSIZE_MAX ||
        (uint32_t)(off + n) > fr->inst_size_min) {
        if (why) *why = 5;
        g_hw_refused++; g_hw_refused_size++; return 0;
    }
    if (!aowl_hw_writable((void*)((uint8_t*)recv + off), n)) {
        if (why) *why = 4;
        g_hw_refused++; g_hw_refused_mem++; return 0;
    }
    if (why) *why = 0;
    g_hw_allowed++;
    return 1;
}

#define AOWL_FR_STORE(SUF, T)                                                  \
    static int aowl_fr_store_##SUF(AowlFieldRef* fr, void* recv, int32_t sub,  \
                                   T val, int32_t* why) {                      \
        if (!aowl_fr_gate(fr, recv, sub, (int32_t)sizeof(T), why)) return 0;    \
        *(T*)((uint8_t*)recv + fr->off + sub) = val;                           \
        return 1;                                                              \
    }

AOWL_FR_STORE(u8,  uint8_t)
AOWL_FR_STORE(i32, int32_t)
AOWL_FR_STORE(f32, float)
AOWL_FR_STORE(ptr, void*)

#undef AOWL_FR_STORE

/* The receiver-only form, for a field written by CALLING a game setter
 * (`Toggle::Set`, `SetToggleGroup`, `TMP_Text::set_text`). There is no offset
 * to bound -- the callee chooses it -- so the FieldRef contributes exactly one
 * thing, and it is the thing that mattered in both dumps: the receiver's TYPE.
 * Kept separate from `aowl_hw_recv_klass_ok` so the site names the FIELD it is
 * about to have the game write, not just a klass pointer. */
static int aowl_fr_recv_ok(AowlFieldRef* fr, void* recv, int32_t* why) {
    void* got;
    int i;
    if (why) *why = 6;
    if (!fr) { g_hw_refused++; return 0; }
    if (!recv || !aowl_hw_readable(recv, 8)) {
        if (why) *why = 4; g_hw_refused++; g_hw_refused_mem++; return 0;
    }
    got = *(void**)recv;
    for (i = 0; i < fr->nklass && i < AOWL_FR_MAX_KLASS; ++i)
        if (fr->klass[i] == got) { if (why) *why = 0; g_hw_allowed++; return 1; }
    if (why) *why = 3;
    g_hw_refused++; g_fr_refused_klass++; return 0;
}

/* ---------------------------------------------------------------------------
 * THE ADVISORY LOOKUP -- for the inspector `write` verb ONLY.
 *
 * `inspect.nim`'s `write` is the ONE deliberate escape hatch in the tree
 * (WRITE-AUDIT #10): an arbitrary evaluated address, an arbitrary width, an
 * arbitrary value, gated by `liveInspectorWrite` plus an `allow write` line in
 * the batch. It stays raw -- an operator debugging a live client needs to be
 * able to write things the metadata has never heard of.
 *
 * What it should not do is write into a slot the metadata DOES know about
 * without saying so. `write <expr> i32 -1` into a reference slot is a literal
 * match for producer (A) of the 0x00000000FFFFFFFF crash, and the operator has
 * no way to know that from the expression alone.
 *
 * So: given the address and width about to be written, find a FieldRef this
 * address could BE -- i.e. some row whose `recv = p - off` presents a klass
 * that row has already admitted -- and report the verdict `aowl_fr_gate` would
 * have returned. ADVISORY: it neither writes nor refuses.
 *
 * A row with zero admitted klasses cannot match, so this says nothing at all
 * until the corresponding feature has actually run. That is a real limitation
 * and it is the honest one: without a klass there is no way to tell a Toggle
 * at +0x120 from any other object with a byte there, and inventing a match
 * from the offset alone would be a confidently wrong answer.
 *
 * Returns the matching row index (0..AOWL_FR_TABLE_ROWS-1), or -1 for "no row
 * in the table can claim this address" -- which is NOT "this write is safe".
 * ------------------------------------------------------------------------ */
static int32_t aowl_fr_lookup(void* p, int32_t n, int32_t* why) {
    int r, i;
    if (why) *why = -1;
    if (!p || n <= 0) return -1;
    for (r = 0; r < AOWL_FR_TABLE_ROWS; ++r) {
        AowlFieldRef* fr = AOWL_FR_ALL[r];
        uint8_t* recv;
        void* got;
        int32_t sub;
        if (!fr || fr->nklass <= 0) continue;
        /* The address may be the field itself or a sub-field offset inside it
         * (natesp writes Color one channel at a time), so try each sub-offset
         * the field's own width allows. Capped by that width: no unbounded
         * loop over game data. */
        for (sub = 0; sub < fr->width; ++sub) {
            recv = (uint8_t*)p - fr->off - sub;
            if ((void*)recv == p && sub != 0) continue;
            if (!aowl_hw_readable(recv, 8)) continue;
            got = *(void**)recv;
            for (i = 0; i < fr->nklass && i < AOWL_FR_MAX_KLASS; ++i) {
                if (fr->klass[i] != got) continue;
                /* Found it. Report what the gate WOULD say, without touching
                 * the refusal counters -- this is not a refusal, it is a
                 * remark, and inflating the counters would make the run
                 * summary lie. */
                if (why) {
                    if (fr->is_reference && (n != 8 || sub != 0)) *why = 1;
                    else if (sub + n > fr->width)                 *why = 2;
                    else                                          *why = 0;
                }
                return (int32_t)r;
            }
        }
    }
    return -1;
}

static const char* aowl_fr_row_type(int32_t r) {
    if (r < 0 || r >= AOWL_FR_TABLE_ROWS) return "";
    return AOWL_FR_ALL[r]->type_name;
}
static const char* aowl_fr_row_field(int32_t r) {
    if (r < 0 || r >= AOWL_FR_TABLE_ROWS) return "";
    return AOWL_FR_ALL[r]->field_name;
}
static int32_t aowl_fr_row_isref(int32_t r) {
    if (r < 0 || r >= AOWL_FR_TABLE_ROWS) return 0;
    return AOWL_FR_ALL[r]->is_reference;
}
static int32_t aowl_fr_row_width(int32_t r) {
    if (r < 0 || r >= AOWL_FR_TABLE_ROWS) return 0;
    return AOWL_FR_ALL[r]->width;
}

#endif /* AOWLSPT_HOSTWRITE_H */
