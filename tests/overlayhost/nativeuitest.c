/* nativeuitest.c -- OFFLINE checks for the native UI layer's pure logic.
 *
 * What can honestly be tested with no client running:
 *
 *   * the LAYOUT ARITHMETIC and the renderability predicate -- the exact thing
 *     whose failure made the invoke2 ladder log eight successes and put nothing
 *     on screen;
 *   * the SLOT REGISTRY's verdict machine, including every refusal path;
 *   * the OWNERSHIP table, so "creating UI that cannot be torn down is a leak"
 *     is a checked property rather than a comment;
 *   * the STRING INTERN table, which is what stands between this layer and a
 *     per-frame managed allocation.
 *
 * What CANNOT be tested here, stated rather than quietly skipped: whether a
 * .data slot really holds `AddComponent<RectTransform>`'s MethodInfo, whether
 * the RVAs are this build's, and whether anything renders. Those are live
 * questions and the host answers them in `nuProofRun` against the finished
 * state.
 *
 * FALSIFIABILITY. Half the cases here assert a NEGATIVE -- that a bad input is
 * REFUSED -- because a self-comparison cannot fail and a negative can. Each
 * such case names the input that breaks it. `main` additionally runs
 * `falsify()`, which feeds the checkers deliberately wrong values and requires
 * them to say no; if the predicates were replaced by `return 1` the suite must
 * go red, and `falsify` is what makes that true.
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

/* --- stand-ins for the host environment ------------------------------------
 * The header verifies prologues through the STARTUP SNAPSHOT in
 * aowlspt_prologue.h and allocates managed strings through GameAssembly.dll.
 * Neither exists here. Providing the snapshot for real (rather than stubbing
 * it) keeps `aowl_nu_fn`'s shape honest; the string allocator is stubbed,
 * because there is no managed heap to allocate in. */
#include "aowlspt_prologue.h"
#include "aowlspt_nativeui.h"

static int g_checks = 0, g_fails = 0;

static void ck(int cond, const char* what) {
    g_checks++;
    if (!cond) { g_fails++; printf("  FAIL  %s\n", what); }
}

/* ------------------------------------------------------------------ *
 * 1. Renderability -- the invoke2 bug, as a predicate
 * ------------------------------------------------------------------ */
static void test_renderable(void) {
    printf("renderability\n");

    /* THE CASE THAT MATTERS. A RectTransform fresh out of AddComponent has
     * sizeDelta (0,0). If this returns 1, the layer will happily "create"
     * invisible elements again and report success. */
    ck(aowl_nu_rect_renderable(0.0f, 0.0f) == 0,
       "a 0x0 rect -- the invoke2 ladder's actual state -- is NOT renderable");
    ck(aowl_nu_rect_renderable(520.0f, 0.0f) == 0,
       "zero HEIGHT alone is not renderable (a wide, flat nothing)");
    ck(aowl_nu_rect_renderable(0.0f, 44.0f) == 0,
       "zero WIDTH alone is not renderable");
    ck(aowl_nu_rect_renderable(-520.0f, -44.0f) == 0,
       "a negative rect is not renderable");
    ck(aowl_nu_rect_renderable(0.1f, 0.1f) == 0,
       "a sub-pixel rect is not renderable (it is zero-area in practice)");
    ck(aowl_nu_rect_renderable(1e9f, 1e9f) == 0,
       "an absurd rect is refused rather than trusted -- a garbage read that "
       "happens to be huge must not pass for a laid-out element");

    /* NaN fails every comparison, so `w <= MIN` would let it through while
     * `!(w > MIN)` catches it. This case is why the predicate is written that
     * way, and it is the one an innocent-looking simplification breaks. */
    {
        float nan = 0.0f;
        nan = nan / nan;
        ck(aowl_nu_rect_renderable(nan, 44.0f) == 0,
           "a NaN width is refused (it must not slip through as 'not <= min')");
        ck(aowl_nu_rect_renderable(520.0f, nan) == 0, "a NaN height is refused");
    }

    ck(aowl_nu_rect_renderable(520.0f, 44.0f) == 1,
       "the proof element's 520x44 IS renderable");
    ck(aowl_nu_rect_renderable(1.0f, 1.0f) == 1, "a 1x1 rect is renderable");
}

/* ------------------------------------------------------------------ *
 * 2. Hit testing -- the polled input path
 * ------------------------------------------------------------------ */
static void test_hit(void) {
    printf("hit testing\n");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, 50, 25) == 1, "centre is inside");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, 0, 0) == 1, "the origin corner is inside");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, 100, 50) == 1, "the far corner is inside");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, 101, 25) == 0, "just past the right edge is outside");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, -1, 25) == 0, "just left of the origin is outside");
    ck(aowl_nu_rect_contains(0, 0, 100, 50, 50, 51) == 0, "just below is outside");
    ck(aowl_nu_rect_contains(-50, -25, 100, 50, 0, 0) == 1,
       "a rect with a negative origin still contains its centre");

    /* The coupling that matters: an element that failed layout must not be
     * clickable either. Without this, a zero-area button would swallow input
     * from whatever is really under the cursor. */
    ck(aowl_nu_rect_contains(0, 0, 0, 0, 0, 0) == 0,
       "a ZERO-AREA rect contains nothing, not even its own origin");
}

/* ------------------------------------------------------------------ *
 * 3. The slot registry's verdict machine
 * ------------------------------------------------------------------ */
static void test_slots(void) {
    /* Fake objects: an Il2CppObject's first qword is its class pointer, which
     * is the only field this layer reads from a header. */
    static void* klass_rt   = (void*)0x1111;
    static void* klass_tmp  = (void*)0x2222;
    static void* obj_rt_a[2];
    static void* obj_rt_b[2];
    static void* obj_tmp[2];
    obj_rt_a[0] = klass_rt;
    obj_rt_b[0] = klass_rt;
    obj_tmp[0]  = klass_tmp;

    printf("slot registry\n");

    ck(aowl_nu_slot_state(AOWL_NU_KIND_RECTTRANSFORM) == AOWL_NU_SLOT_UNKNOWN,
       "a kind starts UNKNOWN -- not 'fine', not 'broken'");
    ck(aowl_nu_slot_state(-1) == AOWL_NU_SLOT_POISONED &&
       aowl_nu_slot_state(AOWL_NU_MAX_KINDS) == AOWL_NU_SLOT_POISONED,
       "an out-of-range kind reads back POISONED, so a bad index cannot be "
       "mistaken for a usable slot");

    /* NO REFERENCE -> INCONCLUSIVE, never a pass. This is the case that stops
     * "I could not look" being reported as success. */
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_IMAGE, obj_rt_a) == AOWL_NU_SLOT_NOREF,
       "with no reference instance the verdict is INCONCLUSIVE, not VERIFIED");

    ck(aowl_nu_ref_set(AOWL_NU_KIND_RECTTRANSFORM, obj_rt_a) == 1,
       "a reference instance is accepted");
    ck(aowl_nu_ref_klass(AOWL_NU_KIND_RECTTRANSFORM) == klass_rt,
       "the reference class is the object header's first qword");

    /* THE POSITIVE. */
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_RECTTRANSFORM, obj_rt_b) ==
       AOWL_NU_SLOT_VERIFIED,
       "a component of the reference class VERIFIES the slot");

    /* THE FALSIFYING CASE -- the whole design turns on this one. A slot
     * attributed to the wrong T returns the wrong class, and the kind must be
     * poisoned rather than used. */
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_RECTTRANSFORM, obj_tmp) ==
       AOWL_NU_SLOT_POISONED,
       "a component of the WRONG class POISONS the slot");
    ck(aowl_nu_slot_state(AOWL_NU_KIND_RECTTRANSFORM) == AOWL_NU_SLOT_POISONED,
       "and the poisoning is remembered");

    /* A NULL result is not 'no opinion'. */
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_BUTTON, NULL) == AOWL_NU_SLOT_POISONED,
       "a null component poisons rather than leaving the kind UNKNOWN");

    /* Re-registering a DIFFERENT reference for a kind means one of the two
     * walks is wrong; taking the newer one silently would make the check
     * depend on call order. */
    ck(aowl_nu_ref_set(AOWL_NU_KIND_RECTTRANSFORM, obj_tmp) == 0,
       "a second, DIFFERENT reference for one kind is refused");
    ck(aowl_nu_ref_klass(AOWL_NU_KIND_RECTTRANSFORM) == klass_rt,
       "and the original reference survives it");
    ck(aowl_nu_ref_set(AOWL_NU_KIND_RECTTRANSFORM, obj_rt_b) == 1,
       "re-registering the SAME class is accepted (it is not a conflict)");

    /* Every kind must carry its evidence, or the table has drifted back to
     * being a list of magic numbers. */
    {
        int k;
        for (k = 0; k < AOWL_NU_MAX_KINDS; k++) {
            ck(aowl_nu_kind_slot_rva(k) >= 0x6B61000u &&
               aowl_nu_kind_slot_rva(k) < 0x737BD74u,
               "every kind's slot RVA is inside .data");
            ck(strlen(aowl_nu_kind_evidence(k)) > 32,
               "every kind carries the call-site evidence it was attributed by");
            ck(strlen(aowl_nu_kind_name(k)) > 0, "every kind is named");
        }
    }
    ck(aowl_nu_kind_slot_rva(AOWL_NU_KIND_RECTTRANSFORM) == 0x6E19580u,
       "the RectTransform slot is the value the invoke2 ladder proved live -- "
       "tools/addcompslots.py must keep reproducing it");
    ck(aowl_nu_kind_slot_rva(-1) == 0 &&
       aowl_nu_kind_slot_rva(AOWL_NU_MAX_KINDS) == 0,
       "an out-of-range kind yields slot 0, which aowl_nu_data_ptr refuses");
}

/* ------------------------------------------------------------------ *
 * 4. Ownership -- teardown is a property, not a promise
 * ------------------------------------------------------------------ */
static void test_owned(void) {
    static char objs[AOWL_NU_MAX_OWNED + 4];
    int i, taken = 0;
    printf("ownership\n");

    aowl_nu_owned_clear();
    ck(aowl_nu_owned_count() == 0, "the table starts empty");
    ck(aowl_nu_own(NULL) == 0, "a null is never owned");

    for (i = 0; i < AOWL_NU_MAX_OWNED + 4; i++)
        taken += aowl_nu_own(&objs[i]);
    ck(taken == AOWL_NU_MAX_OWNED,
       "ownership is CAPPED -- the overflow is refused, not overrun");
    ck(aowl_nu_owned_count() == AOWL_NU_MAX_OWNED, "and the count reflects it");
    ck(aowl_nu_owned_at(AOWL_NU_MAX_OWNED) == NULL &&
       aowl_nu_owned_at(-1) == NULL, "reads outside the table yield NULL");

    aowl_nu_disown(&objs[0]);
    ck(aowl_nu_owned_count() == AOWL_NU_MAX_OWNED - 1, "disown removes exactly one");
    ck(aowl_nu_owned_at(0) == &objs[1], "and closes the gap rather than leaving a hole");
    for (i = 0; i < aowl_nu_owned_count(); i++)
        ck(aowl_nu_owned_at(i) != &objs[0], "the disowned entry is really gone");

    aowl_nu_disown(&objs[0]);
    ck(aowl_nu_owned_count() == AOWL_NU_MAX_OWNED - 1,
       "disowning something not owned is a no-op, not a corruption");

    aowl_nu_owned_clear();
    ck(aowl_nu_owned_count() == 0 && aowl_nu_owned_at(0) == NULL,
       "clear empties it");
}

/* ------------------------------------------------------------------ *
 * 5. String interning -- rule 7, no per-frame managed allocation
 * ------------------------------------------------------------------ */
static void test_intern(void) {
    char big[AOWL_NU_MAX_INTERN_LEN + 8];
    printf("string interning\n");

    /* `il2cpp_string_new` is unavailable here, so every intern returns NULL.
     * What is still checkable -- and is the part that protects the frame
     * budget -- is that the REFUSAL paths are taken before any allocation is
     * attempted at all. */
    ck(aowl_nu_intern(NULL) == NULL, "a null text is refused");
    memset(big, 'x', sizeof(big));
    big[sizeof(big) - 1] = 0;
    ck(aowl_nu_intern(big) == NULL,
       "an over-long text is refused rather than truncated into the table");
    ck(aowl_nu_intern_count() == 0,
       "a refused intern records nothing -- so a caller looping on a bad "
       "string cannot fill the table");
    ck(aowl_nu_intern_overflowed() == 0, "and does not report an overflow");
}

/* ------------------------------------------------------------------ *
 * 6. Target-table hygiene
 * ------------------------------------------------------------------ */
static void test_targets(void) {
    int i, j;
    printf("target table\n");
    ck(aowl_nu_target_count() == 25, "the table has the 25 documented targets");
    for (i = 0; i < aowl_nu_target_count(); i++) {
        ck(aowl_nu_rva(i) != 0, "no target has a zero RVA");
        ck(strlen(aowl_nu_name(i)) > 0, "every target is named");
        ck(aowl_nu_targets[i].siglen == 16,
           "every target asserts a full 16-byte prologue -- a siglen of 0 "
           "would make aowl_pro_verify return 1 unconditionally, which is a "
           "check that cannot fail");
    }
    /* An index typo that pointed two constants at one row would be invisible
     * in the live log and produce a call to the wrong function. */
    for (i = 0; i < aowl_nu_target_count(); i++)
        for (j = i + 1; j < aowl_nu_target_count(); j++)
            ck(!(aowl_nu_rva(i) == aowl_nu_rva(j) &&
                 strcmp(aowl_nu_name(i), aowl_nu_name(j)) == 0),
               "no target appears twice");
    ck(aowl_nu_rva(-1) == 0 && aowl_nu_rva(aowl_nu_target_count()) == 0,
       "an out-of-range index yields RVA 0, not a neighbouring function");
    ck(aowl_nu_fn(-1) == NULL && aowl_nu_fn(aowl_nu_target_count()) == NULL,
       "and yields no code pointer");

    /* The named constants must agree with the table's ORDER. If they drift,
     * `nuLayout` sets the pivot when it means the size and everything still
     * "works". */
    ck(aowl_nu_rva(AOWL_NU_RT_SET_SIZEDELTA)   == 0x52B6FC0u, "set_sizeDelta_Injected");
    ck(aowl_nu_rva(AOWL_NU_RT_SET_PIVOT)       == 0x52B7080u, "set_pivot_Injected");
    ck(aowl_nu_rva(AOWL_NU_RT_GET_RECT)        == 0x52B6CC0u, "get_rect_Injected");
    ck(aowl_nu_rva(AOWL_NU_ADDCOMPONENT_GEN)   == 0x2A9AE90u, "AddComponent<T>");
    ck(aowl_nu_rva(AOWL_NU_TMP_SET_TEXT)       == 0x51BC1E0u, "TMP_Text::set_text");
    ck(aowl_nu_rva(AOWL_NU_OBJ_DESTROY)        == 0x52AE0A0u, "Object::Destroy");

    /* Not one target may be 0x628110: that is this build's universal empty-body
     * stub, shared by 6438 methods, and it passes any signature check aimed at
     * it. A stub that verifies is the worst outcome available. */
    for (i = 0; i < aowl_nu_target_count(); i++)
        ck(aowl_nu_rva(i) != 0x628110u,
           "no target is the universal empty-body stub at 0x628110");
}

/* ------------------------------------------------------------------ *
 * 7. Fault budget
 * ------------------------------------------------------------------ */
static void test_faults(void) {
    int i;
    printf("fault budget\n");
    ck(aowl_nu_disabled() == 0, "the layer starts enabled");
    for (i = 0; i < AOWL_NU_MAX_FAULTS - 1; i++) aowl_nu_note_fault();
    ck(aowl_nu_disabled() == 0, "one fault short of the budget it is still on");
    aowl_nu_note_fault();
    ck(aowl_nu_disabled() == 1, "at the budget it self-disables");
    ck(aowl_nu_fn(AOWL_NU_GO_CTOR_STRING) == NULL,
       "and a disabled layer hands out no code pointers at all");
}

/* ------------------------------------------------------------------ *
 * 8. FALSIFIABILITY
 *
 * If you cannot describe the input that makes a check fail, you have not
 * written a check. Every predicate above is exercised here with a value it
 * MUST reject; a `return 1` stub in place of any of them turns this red.
 * ------------------------------------------------------------------ */
static void falsify(void) {
    static void* klass_a = (void*)0xAAAA;
    static void* klass_b = (void*)0xBBBB;
    static void* obj_a[2];
    static void* obj_b[2];
    int rejected = 0;
    obj_a[0] = klass_a;
    obj_b[0] = klass_b;

    printf("falsifiability\n");

    if (aowl_nu_rect_renderable(0.0f, 0.0f) == 0) rejected++;
    if (aowl_nu_rect_contains(0, 0, 0, 0, 0, 0) == 0) rejected++;
    if (aowl_nu_data_ptr(0x1000u) == NULL) rejected++;      /* not in .data */
    if (aowl_nu_data_ptr(0x7FFFFFFFu) == NULL) rejected++;  /* past .data   */
    if (aowl_nu_klass_of(NULL) == NULL) rejected++;
    if (aowl_nu_klass_of((void*)0x10) == NULL) rejected++;  /* unmapped     */
    if (aowl_nu_own(NULL) == 0) rejected++;
    if (aowl_nu_intern(NULL) == NULL) rejected++;
    if (aowl_nu_ref_set(99, obj_a) == 0) rejected++;        /* bad kind     */
    if (aowl_nu_call_generic0((void*)1, (void*)1, NULL) == NULL) rejected++;
    if (aowl_nu_call_p_p(NULL, (void*)1) == NULL) rejected++;
    if (aowl_nu_call_b_p(NULL, (void*)1) == 0) rejected++;

    ck(rejected == 12,
       "all twelve deliberately-bad inputs were REFUSED (got a different "
       "count? then one of the guards above accepts something it must not)");

    /* And the slot judge, end to end, on a fresh kind. */
    ck(aowl_nu_ref_set(AOWL_NU_KIND_BUTTON, obj_a) == 1, "reference taken");
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_BUTTON, obj_b) == AOWL_NU_SLOT_POISONED,
       "THE case the whole design turns on: a slot that yields the wrong "
       "class is refused, permanently");
}

int main(void) {
    printf("nativeuitest -- offline checks for the native UI layer\n\n");
    test_renderable();
    test_hit();
    test_slots();
    test_owned();
    test_intern();
    test_targets();
    falsify();
    test_faults();        /* LAST: it permanently disables the layer */

    printf("\n%d check(s), %d failure(s)\n", g_checks, g_fails);
    if (g_fails) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
