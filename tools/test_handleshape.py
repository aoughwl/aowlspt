#!/usr/bin/env python3
"""test_handleshape.py -- the offline test for `abi/aowlspt_handle.h`.

## What is being tested

`aowl_handle_shape_ok` is the first two thirds of the filter that
`aowl/src/aowlspt/il2cpp.nim:gatedHandle` applies to every handle that came out
of a TOKEN-GATED il2cpp export. It exists because on 2026-09-02 a handle from
`il2cpp_class_from_name` -- an export that returns MT19937-64 output when
called without its token -- passed a `!= nil` check and killed the client on
the first dereference inside `il2cpp_value_box`
(`Crash_2026-09-02_224920325`, RCX = 0x6e11f7fc349b3101).

## Why it is a real test and not a ritual

PASS / FAIL / INCONCLUSIVE, three outcomes, and a POSITIVE CONTROL first.
Without case 0 every other case could pass vacuously: a predicate that answered
0 to everything would satisfy all the negative cases perfectly, and would also
disable every by-name lookup in the host.

Case 5 is the one that decides whether the filter is worth anything: it runs
200,000 values from a seeded PRNG -- the shape of the trap's own output -- and
requires that essentially all of them are rejected. A filter that lets the trap
through is not a filter, and "it rejected the one value I happened to write
down" does not establish that.

Run:  python tools/test_handleshape.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

try:
    from cctool import find_cc, cc_run, why_no_cc     # noqa: E402
except Exception as exc:                              # pragma: no cover
    print("INCONCLUSIVE -- tools/cctool.py did not import: %s" % exc)
    sys.exit(3)

HARNESS = r'''
#include <stdio.h>
#include <stdint.h>
#include "aowlspt_handle.h"

/* The trap is a per-thread MT19937-64. We do not need ITS bits, we need bits of
 * the same SHAPE -- uniform over all 64 -- so a plain xorshift64* stands in.
 * Seeded fixed, so a failure is reproducible. */
static uint64_t s = 0x9E3779B97F4A7C15ull;
static uint64_t rnd64(void) {
    s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
    return s * 0x2545F4914F6CDD1Dull;
}

int main(void) {
    int fails = 0;
    /* 0  POSITIVE CONTROL: a real handle from the same crash dump (RDX, a live
     *    readable object) and three other plausible aligned user addresses.
     *    These MUST be accepted or the filter would disable every by-name
     *    lookup in the host. */
    {
        static const uint64_t real[] = {
            0x000001ed62c8c1f0ull,   /* MEASURED: RDX at the fault            */
            0x0000000180001000ull,   /* a module .text address                */
            0x00007ffb180d9a78ull,   /* RIP at the fault, rounded to 8        */
            0x0000000000001000ull,   /* the lowest plausible mapped page      */
            /* MEASURED 2026-09-02, real pointer shapes taken from today's host
             * logs -- a live Il2CppClass* and a live managed receiver. They are
             * here because a live regression was reported as "the shape filter
             * rejected a real klass". It does not, and this is the control that
             * SAYS so instead of an argument that says so. The real cause was
             * control flow: see `resolveDrainByName` in
             * host/Aowlspt.Host.Il2Cpp/aowlhost.nim. */
            0x00000230e2951810ull,   /* klass                                 */
            0x000001ebcd25c100ull    /* receiver                              */
        };
        int i;
        for (i = 0; i < 6; i++) {
            if (!aowl_handle_shape_ok(real[i])) {
                printf("FAIL case0 positive control: rejected 0x%016llx\n",
                       (unsigned long long)real[i]);
                fails++;
            }
        }
        if (!fails) printf("PASS case0 positive control: 6 real handles accepted\n");
    }
    /* 1  THE MEASURED TRAP VALUE. */
    if (aowl_handle_shape_ok(0x6e11f7fc349b3101ull)) {
        printf("FAIL case1: the measured trap value 0x6e11f7fc349b3101 was accepted\n");
        fails++;
    } else {
        printf("PASS case1: the measured trap value is rejected\n");
    }
    /* 2  NULL folds to reject. */
    if (aowl_handle_shape_ok(0ull)) { printf("FAIL case2: NULL accepted\n"); fails++; }
    else printf("PASS case2: NULL rejected\n");
    /* 3  Non-canonical but perfectly aligned -- alignment alone is not enough. */
    if (aowl_handle_shape_ok(0x6e11f7fc349b3100ull)) {
        printf("FAIL case3: a non-canonical but 8-aligned value was accepted\n");
        fails++;
    } else printf("PASS case3: non-canonical rejected even when aligned\n");
    /* 4  Canonical but misaligned -- canonicality alone is not enough either.
     *    This is the case that shows the two filters are independent. */
    if (aowl_handle_shape_ok(0x000001ed62c8c1f1ull)) {
        printf("FAIL case4: a canonical but misaligned value was accepted\n");
        fails++;
    } else printf("PASS case4: misaligned rejected even when canonical\n");
    /* 5  THE ONE THAT MATTERS: uniform random 64-bit values, the shape of the
     *    trap's own output. Expected leak rate is 2^-17 * 1/8 = 2^-20, so out
     *    of 200000 the expected number accepted is 0.19. Anything above a
     *    handful means the filter does not do what this header claims. */
    {
        long n = 200000, accepted = 0, i;
        for (i = 0; i < n; i++) if (aowl_handle_shape_ok(rnd64())) accepted++;
        if (accepted > 5) {
            printf("FAIL case5: %ld of %ld uniform random values accepted "
                   "(expected ~0)\n", accepted, n);
            fails++;
        } else {
            printf("PASS case5: %ld of %ld uniform random 64-bit values "
                   "accepted (expected ~0.19)\n", accepted, n);
        }
    }
    printf(fails ? "\n%d FAIL\n" : "\nALL PASS\n", fails);
    return fails ? 1 : 0;
}
'''


def main():
    cc, note = find_cc()
    if cc is None:
        print("INCONCLUSIVE -- no working C compiler: %s" % why_no_cc())
        return 3
    tmp = tempfile.mkdtemp(prefix="aowl_handleshape_")
    src = os.path.join(tmp, "t.c")
    exe = os.path.join(tmp, "t.exe")
    with open(src, "w", encoding="utf-8") as fh:
        fh.write(HARNESS)
    r = cc_run([cc, "-std=c99", "-Wall", "-Werror", "-O1",
                "-I", os.path.join(REPO, "abi"), src, "-o", exe])
    if r.returncode != 0:
        print("INCONCLUSIVE -- abi/aowlspt_handle.h did not compile clean "
              "with -Wall -Werror:\n%s\n%s" % (r.stdout, r.stderr))
        return 3
    r = subprocess.run([exe], capture_output=True, text=True)
    print(r.stdout.strip())
    if r.stderr.strip():
        print(r.stderr.strip())
    return 0 if r.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
