/* spilltest.c -- an OFFLINE check that the generated dispatch table puts a
 * spilled argument where a real callee reads it.
 *
 * This does NOT replace the live proof in `aowl/src/aowlspt/callproof.nim`.
 * It cannot: it compiles the callee with the same compiler as the caller, so
 * it proves the table is self-consistent and says nothing about what
 * GameAssembly.dll expects. What it IS good for is catching a generator bug in
 * two seconds instead of in a client start -- a case emitted with `a[4].f`
 * where the prototype says int64_t, a code collision between two shapes, an
 * off-by-one in the mask width. Every one of those would otherwise present as
 * a plausible wrong number on the live run.
 *
 * Build and run (PowerShell, msys2 ucrt64 gcc):
 *   gcc -I abi -o spilltest.exe examples/callproof/spilltest.c ; ./spilltest.exe
 *
 * Prints one line per case and a final PASS/FAIL count. Exit code is the
 * number of failures.
 */
#include <stdio.h>
#include <string.h>
#include "aowlspt_fast.h"

static int fails = 0;
static int checks = 0;

static void eq(const char* what, double got, double want) {
    checks++;
    if (got == want) {
        printf("  PASS %-42s = %g\n", what, got);
    } else {
        printf("  FAIL %-42s = %g (wanted %g)\n", what, got, want);
        fails++;
    }
}

/* The shape of UnityEngine.Matrix4x4::Ortho as this build compiles it:
 * pos0 retbuf, pos1..3 float in XMM1..3, pos4..6 float ON THE STACK,
 * pos7 MethodInfo*. Written out by hand so the CALLEE is a normal C function
 * with a normal prototype and nothing about it is generated. */
static void ortho_like(float* ret, float l, float r, float b, float t,
                       float zn, float zf, const void* mi) {
    (void)mi;
    ret[0] = 2.0f / (r - l);
    ret[1] = 2.0f / (t - b);
    ret[2] = -2.0f / (zf - zn);
    ret[3] = 1.0f;
}

/* Nine integer arguments plus the MethodInfo*: ten slots, six of them on the
 * stack. This is the `GoToPoint`-shaped case that was refused outright. */
static int64_t wide9(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e,
                     int64_t f, int64_t g, int64_t h, int64_t i,
                     const void* mi) {
    (void)mi;
    /* Distinct weights, so ANY two arguments swapped changes the answer. */
    return a * 1 + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000
         + g * 1000000 + h * 10000000 + i * 100000000;
}

/* A float in a spilled position next to integers, mixed, to check the mask
 * really does stop mattering past position 3. */
static float mixed6(void* self, float x, int64_t n, float y,
                    float spilled, int64_t tail, const void* mi) {
    (void)self; (void)mi;
    return x * 1.0f + (float)n * 10.0f + y * 100.0f
         + spilled * 1000.0f + (float)tail * 10000.0f;
}

int main(void) {
    AowlFastSlot a[AOWL_FAST_MAX_SLOTS];
    float ret[16];
    int64_t g;
    double d;
    uint32_t mask;
    int i;

    printf("AOWL_FAST_MAX_SLOTS = %d\n", AOWL_FAST_MAX_SLOTS);

    /* ---- 8 slots, sret + three register floats + three SPILLED floats ---- */
    memset(a, 0, sizeof(a));
    memset(ret, 0, sizeof(ret));
    aowl_fast_set_p(a, 0, ret);
    aowl_fast_set_f(a, 1, -1.0);    /* left   */
    aowl_fast_set_f(a, 2,  1.0);    /* right  */
    aowl_fast_set_f(a, 3, -4.0);    /* bottom */
    aowl_fast_set_f(a, 4,  4.0);    /* top    -- FIRST STACK SLOT */
    aowl_fast_set_f(a, 5, -16.0);   /* zNear  -- second           */
    aowl_fast_set_f(a, 6,  16.0);   /* zFar   -- third            */
    mask = (1u << 1) | (1u << 2) | (1u << 3);   /* only positions 0..3 count */
    printf("ortho-like, 8 slots (3 floats spilled):\n");
    (void)aowl_fast_g((void*)ortho_like, NULL, 7, mask, a);
    eq("m00 = 2/(r-l)", ret[0], 1.0);
    eq("m11 = 2/(t-b)  [top is SPILLED]", ret[1], 0.25);
    eq("m22 = -2/(zf-zn) [both SPILLED]", ret[2], -0.0625);

    /* ---- the same call ONE SLOT SHORT: the live negative control ---- */
    memset(ret, 0, sizeof(ret));
    printf("ortho-like, 7 slots (zFar dropped, MethodInfo NULL lands in it):\n");
    (void)aowl_fast_g((void*)ortho_like, NULL, 6, mask, a);
    eq("m11 unchanged", ret[1], 0.25);
    eq("m22 = -2/(0-zn) [zFar read as 0]", ret[2], -0.125);

    /* ---- 10 slots, six on the stack ---- */
    memset(a, 0, sizeof(a));
    for (i = 0; i < 9; i++) aowl_fast_set_g(a, i, (int64_t)(i + 1));
    printf("wide9, 10 slots (6 spilled):\n");
    g = aowl_fast_g((void*)wide9, NULL, 9, 0, a);
    checks++;
    if (g == 987654321LL) {
        printf("  PASS %-42s = %lld\n", "1..9 by descending place value", (long long)g);
    } else {
        printf("  FAIL %-42s = %lld (wanted 987654321)\n",
               "1..9 by descending place value", (long long)g);
        fails++;
    }

    /* ---- mixed classes with a float past position 3 ---- */
    memset(a, 0, sizeof(a));
    aowl_fast_set_p(a, 0, (void*)0x1234);
    aowl_fast_set_f(a, 1, 1.0);
    aowl_fast_set_g(a, 2, 2);
    aowl_fast_set_f(a, 3, 3.0);
    aowl_fast_set_f(a, 4, 4.0);     /* SPILLED float */
    aowl_fast_set_g(a, 5, 5);
    mask = (1u << 1) | (1u << 3);
    printf("mixed6, 7 slots (a float and an int spilled):\n");
    d = aowl_fast_f((void*)mixed6, NULL, 6, mask, a);
    eq("1 + 20 + 300 + 4000 + 50000", d, 54321.0);

    /* ---- a caller that still sets a float bit for slot 4 must not fall off
     * the table. That is the backward-compatibility claim in the CODE macro,
     * and it is asserted rather than described. ---- */
    printf("stale mask with bit 4 set (pre-spill callers):\n");
    memset(ret, 0, sizeof(ret));
    aowl_fast_set_p(a, 0, ret);
    aowl_fast_set_f(a, 1, -1.0);
    aowl_fast_set_f(a, 2, 1.0);
    aowl_fast_set_f(a, 3, -4.0);
    aowl_fast_set_f(a, 4, 4.0);
    aowl_fast_set_f(a, 5, -16.0);
    aowl_fast_set_f(a, 6, 16.0);
    mask = (1u << 1) | (1u << 2) | (1u << 3) | (1u << 4) | (1u << 5);
    (void)aowl_fast_g((void*)ortho_like, NULL, 7, mask, a);
    eq("same answer with bits 4,5 set too", ret[1], 0.25);

    printf("\n%d checks, %d FAIL\n", checks, fails);
    return fails;
}
