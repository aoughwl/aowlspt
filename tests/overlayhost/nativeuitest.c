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

    /* THE VERDICT AS PURE ARITHMETIC. aowl_nu_slot_judge on THIS build only
     * ever sees attested kinds (all four slots are offline-proven), which would
     * leave the strict unattested-poison branch untestable -- a check that
     * cannot fail. aowl_nu_verdict takes `attested` as an argument, so BOTH
     * branches are exercised here with named falsifying inputs. */
    /* A null produced class is a real failure regardless of anything else. */
    ck(aowl_nu_verdict(1, klass_rt, NULL) == AOWL_NU_SLOT_POISONED &&
       aowl_nu_verdict(0, NULL, NULL) == AOWL_NU_SLOT_POISONED,
       "a NULL produced class POISONS, attested or not");
    /* Donor and slot agree -> the strongest outcome, either way. */
    ck(aowl_nu_verdict(0, klass_rt, klass_rt) == AOWL_NU_SLOT_VERIFIED &&
       aowl_nu_verdict(1, klass_rt, klass_rt) == AOWL_NU_SLOT_VERIFIED,
       "got == ref VERIFIES");
    /* THE FALSIFYING CASE for an UNATTESTED slot: wrong class must POISON. */
    ck(aowl_nu_verdict(0, klass_rt, klass_tmp) == AOWL_NU_SLOT_POISONED,
       "an UNATTESTED slot that produces the WRONG class is POISONED");
    ck(aowl_nu_verdict(0, NULL, klass_tmp) == AOWL_NU_SLOT_NOREF,
       "an UNATTESTED slot with no reference is INCONCLUSIVE, never a pass");
    /* THE ATTESTED CASE: the slot's T is offline-proven, so a mismatch means
     * the DONOR is mistyped -> ATTESTED (proceed), NOT poisoned. This must NOT
     * collapse to VERIFIED (that would hide a genuinely null result) nor to
     * POISONED (that is the bug we are fixing). */
    ck(aowl_nu_verdict(1, klass_rt, klass_tmp) == AOWL_NU_SLOT_ATTESTED,
       "an ATTESTED slot whose class != the (mistyped) donor is ATTESTED");
    ck(aowl_nu_verdict(1, NULL, klass_tmp) == AOWL_NU_SLOT_ATTESTED,
       "an ATTESTED slot with no donor still proceeds on the offline proof");

    /* Now through the TABLE-DRIVEN judge, which uses each kind's real attested
     * flag. Every kind on this build is attested, so a wrong-class result is
     * ATTESTED, not POISONED -- the exact live bug: the slot was correct, the
     * walked donor was not. */
    ck(aowl_nu_kind_attested(AOWL_NU_KIND_RECTTRANSFORM) == 1,
       "the RectTransform slot is offline-attested");
    ck(aowl_nu_ref_set(AOWL_NU_KIND_RECTTRANSFORM, obj_rt_a) == 1,
       "a reference instance is accepted");
    ck(aowl_nu_ref_klass(AOWL_NU_KIND_RECTTRANSFORM) == klass_rt,
       "the reference class is the object header's first qword");
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_RECTTRANSFORM, obj_rt_b) ==
       AOWL_NU_SLOT_VERIFIED,
       "a component of the reference class VERIFIES the slot");
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_RECTTRANSFORM, obj_tmp) ==
       AOWL_NU_SLOT_ATTESTED,
       "an attested kind whose produced class != the donor is ATTESTED "
       "(the donor is the suspect), not POISONED");

    /* A NULL result is still not 'no opinion', even for an attested kind. */
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
            ck(aowl_nu_kind_attested(k) == 1,
               "every kind on this build is offline token-attested to its T "
               "(reproduce with tools/addcompslots.py --slottype)");
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
    ck(aowl_nu_target_count() == 26, "the table has the 26 documented targets "
       "(25 managed + the codegen metadata resolver that warms cold slots)");
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
 * 6b. REFUSAL REASONS -- the regression test for the first live failure
 *
 * Live run 1 logged "0 of 25 managed targets verified ... (25 REJECTED)" at
 * boot and then went on to add a component and read a real rect. The census
 * had run before GameAssembly.dll was loaded, and reported that benign
 * condition as 25 prologue rejections blaming the game build.
 *
 * This test process has NO GameAssembly.dll either -- which makes it the exact
 * condition that caused the bug, and therefore the right place to pin it.
 * ------------------------------------------------------------------ */
static void test_why(void) {
    int i;
    printf("refusal reasons\n");

    ck(aowl_nu_base_ok() == 0,
       "GameAssembly.dll is absent in the test process -- the same condition "
       "that produced the false '25 REJECTED' live");

    for (i = 0; i < aowl_nu_target_count(); i++)
        ck(aowl_nu_fn(i) == NULL, "with no module, every target refuses");

    for (i = 0; i < aowl_nu_target_count(); i++)
        ck(aowl_nu_why_of(i) == AOWL_NU_WHY_NO_MODULE,
           "and each names NO_MODULE as the reason -- NOT a prologue mismatch");

    /* THE ASSERTION THAT WOULD HAVE CAUGHT THE LIVE BUG. */
    ck(aowl_nu_mismatch_count() == 0,
       "zero targets are counted as a BYTE MISMATCH. If this is 25, the layer "
       "is again blaming the game build for a host start-order problem");
    ck(aowl_nu_bad_count() == 0,
       "and the prologue-rejection counter is untouched by a missing module");

    ck(aowl_nu_why_of(-1) == AOWL_NU_WHY_BADINDEX &&
       aowl_nu_why_of(aowl_nu_target_count()) == AOWL_NU_WHY_BADINDEX,
       "an out-of-range index reports BADINDEX rather than a plausible reason");
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

    /* THE case the whole design turns on, in its CURRENT form: attribution is
     * settled by the OFFLINE token proof, so for an attested kind a wrong-class
     * result is ATTESTED (the walked donor is the suspect), not a poisoned
     * slot. The falsifiable poison check now lives in aowl_nu_verdict(0,...)
     * (an UNATTESTED slot with a wrong class IS poisoned -- asserted in
     * test_slots), and the attribution's falsifiability is that distinct slot
     * tokens decode to distinct T (asserted in test_token_decode). */
    ck(aowl_nu_ref_set(AOWL_NU_KIND_BUTTON, obj_a) == 1, "reference taken");
    ck(aowl_nu_slot_judge(AOWL_NU_KIND_BUTTON, obj_b) == AOWL_NU_SLOT_ATTESTED,
       "an attested kind whose produced class != the donor is ATTESTED "
       "(the offline token proof, not the donor, is the authority)");
    ck(aowl_nu_verdict(0, klass_a, klass_b) == AOWL_NU_SLOT_POISONED,
       "and an UNATTESTED wrong-class result is still POISONED -- the strict "
       "guard is intact for any kind not offline-proven");
}

/* ------------------------------------------------------------------ *
 * The from-scratch dependency wiring, as pure logic: a reference-field
 * copy from a "donor" buffer to a "fresh" buffer, plus the region gating
 * that makes it never a blind write. The offsets used live (0x100/0x118/
 * 0x20) are DATA measured from metadata and cannot be checked offline;
 * this checks the MECHANISM -- read the pointer at an offset, store it at
 * the same offset in another object, and refuse every bad address.
 * ------------------------------------------------------------------ */
static void test_wire_refs(void) {
    /* Two heap-like buffers big enough to hold a field past 0x118. */
    static unsigned char donor[0x140];
    static unsigned char fresh[0x140];
    void* font = (void*)0xF0F0F0F0;
    void* mat  = (void*)0xADADADAD;
    int rejected = 0;

    printf("from-scratch dependency wiring\n");

    memset(donor, 0, sizeof(donor));
    memset(fresh, 0, sizeof(fresh));
    memcpy(donor + 0x100, &font, sizeof(void*));   /* m_fontAsset */
    memcpy(donor + 0x118, &mat,  sizeof(void*));    /* m_sharedMaterial */

    /* read-back through the guarded getter */
    ck(aowl_nu_get_ref(donor, 0x100) == font,
       "get_ref reads the font asset pointer at the donor's m_fontAsset");
    ck(aowl_nu_get_ref(donor, 0x118) == mat,
       "get_ref reads the shared material pointer");

    /* the store lands, and reads back independently of the store call */
    ck(aowl_nu_set_ref(fresh, 0x100, font) == 1, "set_ref stores the font");
    ck(aowl_nu_set_ref(fresh, 0x118, mat) == 1, "set_ref stores the material");
    {
        void* got = NULL;
        memcpy(&got, fresh + 0x100, sizeof(void*));
        ck(got == font, "the fresh object's m_fontAsset now equals the donor's");
    }

    /* REFUSALS -- a bad address must never fault or clobber. */
    if (aowl_nu_get_ref(NULL, 0x100) == NULL) rejected++;
    if (aowl_nu_get_ref(donor, -1) == NULL) rejected++;
    if (aowl_nu_get_ref((void*)0x10, 0) == NULL) rejected++;      /* unmapped */
    if (aowl_nu_set_ref(NULL, 0x100, font) == 0) rejected++;
    if (aowl_nu_set_ref(donor, -8, font) == 0) rejected++;
    if (aowl_nu_set_ref((void*)0x10, 0, font) == 0) rejected++;   /* unmapped */
    ck(rejected == 6,
       "all six bad get/set addresses were REFUSED (a different count means a "
       "guard accepts an address it must not, which is exactly a blind write)");

    /* The cold-MethodInfo discriminator, pinned to the exact value measured
     * live. 0xc00804f3 is an UNRESOLVED IL2CPP metadata-usage token, not a
     * pointer; the readability check that gates the AddComponent<T> call must
     * judge it NON-readable so a cold slot is REFUSED, not passed to the call.
     * A real MethodInfo* (a mapped region) would pass -- this asserts only the
     * negative, which is the one that stops the crash. */
    ck(aowl_nu_region_ok((void*)(uintptr_t)0xc00804f3u, 0x48, 0) == 0,
       "the live cold-slot token 0xc00804f3 is judged NON-readable, so the "
       "AddComponent<T> guard refuses it instead of faulting");
    ck(aowl_nu_region_ok((void*)(uintptr_t)0xc00804f3u, 0x48, 1) == 0,
       "same token is non-writable too");
    ck(aowl_nu_region_ok(donor, 0x48, 0) == 1,
       "a genuinely mapped region IS judged readable (the guard is not a "
       "blanket reject-everything)");
}

/* ------------------------------------------------------------------ *
 * The metadata-usage TOKEN DECODE -- Route 1's pure arithmetic.
 *
 * The runtime resolver il2cpp_codegen_initialize_runtime_metadata@0x5251C0
 * decodes an unresolved slot value as: kind = token>>29, index =
 * (token>>1)&0x0FFFFFFF, and treats bit0 as the "unresolved" marker (a real,
 * aligned MethodInfo* has bit0 == 0). This mirrors that arithmetic and pins it
 * to the value measured LIVE in TMP's slot 0x6D50040. Each case names the input
 * that would break it; the falsifying cases assert a NEGATIVE.
 * ------------------------------------------------------------------ */
static void test_token_decode(void) {
    printf("metadata-usage token decode (Route 1)\n");

    /* The live measurement: 0xc00804f3 -> MethodRef (kind 6), index 0x40279. */
    ck(aowl_nu_token_kind(0xc00804f3u) == 6,
       "0xc00804f3 decodes to usage kind 6 (MethodRef), as the resolver's "
       "`shr eax,0x1d` computes");
    ck(aowl_nu_token_index(0xc00804f3u) == 0x40279u,
       "0xc00804f3 decodes to usage index 0x40279, via (token>>1)&0x0FFFFFFF");

    /* All four kinds' STATIC .data tokens (read offline from GameAssembly.dll)
     * decode to DISTINCT indices, each resolving via methodSpecs to the right
     * AddComponent<T>. Pinning them here makes a shuffled slot fail the suite,
     * and the distinctness is the falsifiability -- a swapped RVA names a
     * different T. Index<->T proven with tools/addcompslots.py --slottype. */
    ck(aowl_nu_token_index(0xC0080485u) == 0x40242u,
       "RectTransform slot token 0xC0080485 -> index 0x40242");
    ck(aowl_nu_token_index(0xC008040Bu) == 0x40205u,
       "UI.Image slot token 0xC008040B -> index 0x40205");
    ck(aowl_nu_token_index(0xC0080391u) == 0x401C8u,
       "UI.Button slot token 0xC0080391 -> index 0x401C8");
    ck(aowl_nu_token_index(0xC0080485u) != aowl_nu_token_index(0xc00804f3u),
       "distinct slots decode to distinct indices (a swapped RVA is caught)");
    ck(aowl_nu_token_kind(0xC0080485u) == 6 && aowl_nu_token_kind(0xC008040Bu) == 6 &&
       aowl_nu_token_kind(0xC0080391u) == 6,
       "every AddComponent<T> slot token is a MethodRef (kind 6)");

    /* The discriminator the resolver itself uses: bit0. A cold token has it
     * set; a real MethodInfo* (aligned) does not. */
    ck(aowl_nu_is_cold_token(0xc00804f3u) == 1,
       "the live token 0xc00804f3 is recognised as a COLD token");
    ck(aowl_nu_is_cold_token(0) == 0,
       "a NULL slot is LAZY-NOT-YET, never a cold token (there is nothing to "
       "decode)");
    ck(aowl_nu_is_cold_token(0x17b0718a4d0ull) == 0,
       "the live WARM RectTransform slot value 0x17b0718a4d0 (bit0 clear, a "
       "real heap pointer) is NOT a token -- so warming would never touch it");
    ck(aowl_nu_is_cold_token(0x17b0718a4d1ull) == 0,
       "a high heap pointer that merely happens to be ODD is still NOT a token "
       "(the 32-bit-fit test rejects it), so we never feed a real pointer to "
       "the resolver");
    ck(aowl_nu_is_cold_token(0xffffffffffffffffull) == 0,
       "a full 64-bit gated-export random value is NOT mistaken for a token");
}

int main(void) {
    printf("nativeuitest -- offline checks for the native UI layer\n\n");
    test_renderable();
    test_hit();
    test_slots();
    test_owned();
    test_intern();
    test_targets();
    test_why();
    test_wire_refs();
    test_token_decode();
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
