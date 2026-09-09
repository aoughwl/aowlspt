#!/usr/bin/env python3
"""test_hostwrite_gate -- the hostWrite receiver gate, and the line it prints.

WHY THIS EXISTS (measured 2026-09-04, boot 6bd304e3). Four refusals read:

    hostWrite[modstab.nim:modsReassertLabels] REFUSED: recv=1da1ef71000
    klass=1d72283cda0 but wanted 1d72283cda0 ...

The two klass values are EQUAL, so the line reads as a gate that refused a
receiver it should have allowed -- a check that cannot pass. It is not. The
refusal was the DESTROYED-object branch; `aowl_hw_recv_klass_ok` never ran a
failing comparison. The defect was the MESSAGE asserting a cause the numbers on
the same line contradict.

So there are two things to prove, and neither can pass vacuously:

  A. THE GATE (compiled and executed, not read). An EQUAL klass is ACCEPTED and
     an UNEQUAL one is REFUSED, and the refusal is counted as a klass refusal
     rather than a memory one. If a future edit makes the compare a masked or
     truncated one, the 64-bit-distinct case below catches it: the two klass
     pointers differ ONLY above bit 32.
  B. THE MESSAGE (source assertion). `hwSay`'s refusal branch must not emit
     "but wanted" unconditionally -- it must be inside a `got != want` arm.

Three outcomes: PASS / FAIL / INCONCLUSIVE. No compiler is INCONCLUSIVE (exit
3), never a pass -- "I could not look" is not a pass (CLAUDE.md 9b).
"""

import io
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import cctool  # noqa: E402

NIM = os.path.join(ROOT, "host", "Aowlspt.Host.Il2Cpp", "hostwrite.nim")
ABI = os.path.join(ROOT, "abi")

# The harness calls the real static from the real header. Nothing is
# reimplemented here; a copy of the gate would prove only that the copy works.
HARNESS = r"""
#include "aowlspt_hostwrite.h"
#include <stdio.h>

/* Two klass pointers that are equal in their low 32 bits and differ above
   them. A 32-bit compare, a masked compare or an int-truncating one would call
   these EQUAL; a pointer compare will not. They are never dereferenced. */
static char k_storage[64];

int main(void) {
    void* obj[2];
    void* kA = (void*)k_storage;
    /* XOR, not OR: MEASURED on this machine k_storage lands at 0x7FF7_6CFF_80A0,
       which ALREADY has bit 40 set, so `|` produced kB == kA and the negative
       control could not fail. XOR always flips it. */
    void* kB = (void*)((uintptr_t)k_storage ^ ((uintptr_t)1 << 40));
    int fails = 0;
    long long r0;

    /* The negative control must be capable of failing. */
    if (kA == kB) { printf("FAIL test bug: kA == kB\n"); return 1; }

    /* POSITIVE CONTROL: the klass at *recv IS the wanted one -> ACCEPT. */
    obj[0] = kA;
    r0 = (long long)aowl_hw_refused_klass();
    if (aowl_hw_recv_klass_ok((void*)obj, kA) != 1) {
        printf("FAIL equal-klass receiver was REFUSED\n"); fails++;
    }
    if ((long long)aowl_hw_refused_klass() != r0) {
        printf("FAIL equal-klass bumped the klass-refusal counter\n"); fails++;
    }

    /* NEGATIVE CONTROL: a different klass -> REFUSE, counted as klass. */
    r0 = (long long)aowl_hw_refused_klass();
    if (aowl_hw_recv_klass_ok((void*)obj, kB) != 0) {
        printf("FAIL unequal-klass receiver was ACCEPTED "
               "(compare is truncating or masked)\n"); fails++;
    }
    if ((long long)aowl_hw_refused_klass() != r0 + 1) {
        printf("FAIL unequal-klass was not counted as a klass refusal\n");
        fails++;
    }

    /* NEGATIVE CONTROL: a null receiver is a memory refusal, not a klass one. */
    r0 = (long long)aowl_hw_refused_klass();
    if (aowl_hw_recv_klass_ok(NULL, kA) != 0) {
        printf("FAIL null receiver was ACCEPTED\n"); fails++;
    }
    if ((long long)aowl_hw_refused_klass() != r0) {
        printf("FAIL null receiver was counted as a KLASS refusal, which "
               "would make the summary blame a stale type for a bad pointer\n");
        fails++;
    }

    /* NEGATIVE CONTROL: nothing recorded to want is a refusal, not a waiver. */
    if (aowl_hw_recv_klass_ok((void*)obj, NULL) != 0) {
        printf("FAIL a NULL wanted-klass was treated as a waiver\n"); fails++;
    }

    printf(fails ? "GATE-FAIL\n" : "GATE-OK\n");
    return fails ? 1 : 0;
}
"""


def check_message():
    """B. The refusal line must not claim a klass mismatch unconditionally."""
    try:
        src = io.open(NIM, encoding="utf-8", newline="").read()
    except OSError as e:
        return ("INCONCLUSIVE", "%s: %s" % (NIM, e))
    m = re.search(r"proc hwSay\(.*?\n(?=\S)", src, re.S)
    if not m:
        return ("INCONCLUSIVE", "could not locate `proc hwSay` in hostwrite.nim")
    body = m.group(0)
    tail = body.split("else:", 1)
    if len(tail) < 2:
        return ("INCONCLUSIVE", "hwSay has no refusal branch to inspect")
    refusal = tail[1]
    if '"but wanted "' not in refusal and "but wanted" not in refusal:
        # No claim made at all is acceptable -- it cannot be wrong.
        return ("PASS", "the refusal line makes no klass-mismatch claim")
    if not re.search(r"got\s*==\s*want|got\s*!=\s*want", refusal):
        return ("FAIL",
                "hwSay's refusal branch prints 'but wanted' without ever "
                "comparing got against want, so it asserts a klass mismatch "
                "on refusals that are not about the klass (the destroyed-"
                "object branch prints 'klass=X but wanted X').")
    return ("PASS", "'but wanted' is guarded by a got/want comparison")


def main():
    print("test_hostwrite_gate -- the receiver gate and its refusal line\n")
    bad = 0

    verdict, why = check_message()
    print("B. refusal message: %s -- %s" % (verdict, why))
    if verdict == "FAIL":
        bad += 1
    elif verdict == "INCONCLUSIVE":
        print("\nINCONCLUSIVE"); return 3

    cc, note = cctool.find_cc()
    if not cc:
        print("A. gate: INCONCLUSIVE -- no working compiler (%s)" % note)
        print("\nINCONCLUSIVE -- the gate itself was NOT executed.")
        return 3

    with tempfile.TemporaryDirectory() as td:
        c = os.path.join(td, "hwgate.c")
        exe = os.path.join(td, "hwgate.exe")
        io.open(c, "w", encoding="utf-8", newline="\n").write(HARNESS)
        r = cctool.cc_run([cc, "-I", ABI, "-O0", "-w", c, "-o", exe])
        if r.returncode != 0:
            print("A. gate: INCONCLUSIVE -- harness did not compile:\n%s"
                  % (r.stderr or "")[:1500])
            return 3
        r = cctool.cc_run([exe])
        out = (r.stdout or "") + (r.stderr or "")
        for line in out.strip().splitlines():
            print("   %s" % line)
        if r.returncode != 0 or "GATE-OK" not in out:
            print("A. gate: FAIL")
            bad += 1
        else:
            print("A. gate: PASS -- equal klass ACCEPTED, unequal REFUSED "
                  "(compiler: %s)" % note)

    print("\n%s" % ("FAIL" if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
