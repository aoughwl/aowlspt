#!/usr/bin/env python3
"""test_mqpolicy.py -- the offline test for `abi/aowlspt_mqpolicy.h`, and its
falsifier.

## What it is testing, and why it can be tested at all

MEASURED 2026-09-02. Two boots died at ~8.7 s (Unity crash reports
Crash_2026-09-02_204346544 and Crash_2026-09-02_211541986) because the host ran
queued MAIN-THREAD work on its OWN thread. The host detours
`EFT.TarkovApplication::Update` at ~0:00:01 and the game does not call it until
~15 s, so the tick loop's 2 s "the drain has stalled" test fired on every boot,
and its response was to empty the queue here instead of there. A mod's tick
called `UnityEngine.Input::GetKey`, whose native body dereferences Unity's
per-thread input manager with no null test, and the client died.

The rule that makes that impossible is `aowl_mq_may_run_here`, and it is in a
header with no <windows.h> and no host types for exactly one reason: so this
file can COMPILE IT AND RUN IT. A safety rule that only exists inside a DLL
injected into a live game cannot be tested, and an untested safety rule is a
comment.

## The cases

  0  positive control  a HEALTHY drain, asked on the drain's own thread, MUST
                       run the work. Without this every other case could pass
                       vacuously -- a policy that answers "no" to everything
                       would satisfy cases 1-4 perfectly and ship a host in
                       which no mod ever ticks.
  1  the crash         a STALLED drain, asked on the host's thread, must NOT
                       run the work.
  2  the boot          a drain that is bound and has NEVER FIRED must NOT run
                       the work on the host's thread -- `owner_tid == 0`, so
                       there is no thread that matches, by construction rather
                       than by a timer.
  3  unbound           nothing bound at all is still not a licence.
  4  host-safe         the host's own thread-proof entry MAY run anywhere; this
                       is the escape hatch and it must genuinely be open, or
                       the host would lose the one line that says which thread
                       the drain claimed.
  5  health            the four states must be four. In particular a bound
                       drain that has never fired must be NEVER_FIRED and not
                       STALLED however long ago the host booted -- that
                       conflation IS the 2 s fallback.

## The falsifier

Case F re-compiles the SAME header with `AOWL_MQ_FALSIFY` defined, which
restores the pre-2026-09-02 behaviour ("a stalled drain may run its work on the
caller's thread"). The test asserts that case 1 then FAILS. If it does not, this
file is not testing anything and says so: a green run whose negative control is
also green is INCONCLUSIVE, never PASS.

Run:  python tools/test_mqpolicy.py
Exit: 0 all cases behaved / 1 a case behaved wrongly / 3 INCONCLUSIVE (no C
      compiler, so the policy could not be executed -- "I could not look" is
      not a pass).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
# Compiler resolution is SHELL-DEPENDENT on this machine unless it goes through
# cctool: Git Bash prepends Git's mingw64\bin, cc1.exe then binds Git's DLLs and
# dies in the loader with 0xC0000139, printing nothing. This file reported
# INCONCLUSIVE from Bash and 11 PASS from PowerShell, same second, same command.
# See tools/cctool.py for the measurement.
from cctool import SHELL_CAUSE, cc_run, find_cc           # noqa: E402

REPO = os.path.dirname(HERE)
ABI = os.path.join(REPO, "abi")
HEADER = os.path.join(ABI, "aowlspt_mqpolicy.h")

DRAIN_TID = 4242            # the thread the drain claimed
HOST_TID = 1717             # the host's own tick thread -- never the same

# The driver. It prints one line per case: `name expected actual`. The
# comparison is done in Python so a case that the C cannot even express shows
# up as a missing line rather than as a pass.
MAIN = r"""
#include <stdio.h>
#include <string.h>
#include "aowlspt_mqpolicy.h"

/* The falsifier: the host as it was before 2026-09-02. A stalled drain was
 * taken as permission to run the work on whatever thread noticed. Compiled
 * from the SAME header so the control cannot drift away from the thing it is
 * controlling. */
#ifdef AOWL_MQ_FALSIFY
static int32_t may_run(uint32_t caller, uint32_t owner, int32_t host_safe,
                       AowlDrainHealth health) {
    if (health == AOWL_DRAIN_STALLED || health == AOWL_DRAIN_UNBOUND) return 1;
    return aowl_mq_may_run_here(caller, owner, host_safe);
}
#else
static int32_t may_run(uint32_t caller, uint32_t owner, int32_t host_safe,
                       AowlDrainHealth health) {
    (void)health;   /* THE POINT: health is not an input to the rule. */
    return aowl_mq_may_run_here(caller, owner, host_safe);
}
#endif

int main(void) {
    /* 0: healthy drain, on the drain's own thread. */
    printf("run_on_drain %d\n",
           may_run(__DRAIN__u, __DRAIN__u, 0, AOWL_DRAIN_LIVE));
    /* 1: stalled drain, on the host thread. THE CRASH. */
    printf("stalled_on_host %d\n",
           may_run(__HOST__u, __DRAIN__u, 0, AOWL_DRAIN_STALLED));
    /* 2: bound, never fired -- owner is 0 because nothing has claimed. */
    printf("neverfired_on_host %d\n",
           may_run(__HOST__u, 0u, 0, AOWL_DRAIN_NEVER_FIRED));
    /* 3: nothing bound at all. */
    printf("unbound_on_host %d\n",
           may_run(__HOST__u, 0u, 0, AOWL_DRAIN_UNBOUND));
    /* 4: the host's own proof entry, on the host thread. */
    printf("hostsafe_on_host %d\n",
           may_run(__HOST__u, 0u, 1, AOWL_DRAIN_NEVER_FIRED));
    /* 5: the four states. `since_ms` is deliberately enormous in the
     * never-fired case -- that is the boot, where the host had been up far
     * longer than the stall threshold and the drain had simply not started. */
    printf("health_unbound %d\n",   (int)aowl_mq_health(-1, 0, 999999u, 2000u));
    printf("health_neverfired %d\n",(int)aowl_mq_health(0, 0, 999999u, 2000u));
    printf("health_stalled %d\n",   (int)aowl_mq_health(0, 7, 5000u, 2000u));
    printf("health_live %d\n",      (int)aowl_mq_health(0, 7, 10u, 2000u));
    /* 6: the four states must produce four DIFFERENT sentences, and the
     * unknown one must not read as the healthy one. A diagnosis that says the
     * same thing about "never bound" and "the game stopped calling it" is the
     * one sentence the host used to print for all of them. */
    {
        const char* t[5];
        int i, j, distinct = 1;
        t[0] = aowl_mq_health_text(AOWL_DRAIN_UNBOUND);
        t[1] = aowl_mq_health_text(AOWL_DRAIN_NEVER_FIRED);
        t[2] = aowl_mq_health_text(AOWL_DRAIN_STALLED);
        t[3] = aowl_mq_health_text(AOWL_DRAIN_LIVE);
        t[4] = aowl_mq_health_text((AowlDrainHealth)99);
        for (i = 0; i < 5; i++)
            for (j = i + 1; j < 5; j++)
                if (strcmp(t[i], t[j]) == 0) distinct = 0;
        printf("health_text_distinct %d\n", distinct);
    }
    return 0;
}
""".replace("__DRAIN__", str(DRAIN_TID)).replace("__HOST__", str(HOST_TID))

EXPECTED = {
    "run_on_drain": 1,
    "stalled_on_host": 0,
    "neverfired_on_host": 0,
    "unbound_on_host": 0,
    "hostsafe_on_host": 1,
    "health_unbound": 0,
    "health_neverfired": 1,
    "health_stalled": 2,
    "health_live": 3,
    "health_text_distinct": 1,
}

results = []


def note(state, name, detail=""):
    results.append((state, name, detail))
    print("%-14s %s%s" % (state, name, ("  -- " + detail) if detail else ""))


def build_and_run(cc, tmp, falsify):
    """Compile the real header with a driver and run it. Returns a dict of
    name -> int, or (None, why) with a printed reason.

    Returns a 2-tuple so a caller can put the MEASURED cause into its
    INCONCLUSIVE line. "the header did not compile clean" is not a cause; it
    reads as a defect in the header when the real answer was the shell's PATH.
    """
    src = os.path.join(tmp, "mqmain%d.c" % (1 if falsify else 0))
    exe = os.path.join(tmp, "mqmain%d.exe" % (1 if falsify else 0))
    with open(src, "w", newline="\n") as f:
        f.write(MAIN)
    cmd = [cc, "-std=c99", "-Wall", "-Werror", "-I", ABI, src, "-o", exe]
    if falsify:
        cmd.insert(1, "-DAOWL_MQ_FALSIFY")
    r = cc_run(cmd)
    if r.returncode != 0:
        msg = ((r.stdout or "") + (r.stderr or "")).strip()
        print(msg)
        if not msg:
            return None, ("the compiler exited %d with NO output at all, so "
                          "this is an ENVIRONMENT failure, not a header "
                          "defect. %s" % (r.returncode, SHELL_CAUSE))
        return None, ("the header did not compile clean with -Wall -Werror: %s"
                      % msg.splitlines()[0][:200])
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        return None, ("the compiled driver exited %d instead of running the "
                      "cases" % r.returncode)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            out[parts[0]] = int(parts[1])
    return out, ""


def main():
    if not os.path.isfile(HEADER):
        note("INCONCLUSIVE", "header", "%s is absent" % HEADER)
        return 3
    cc, ccnote = find_cc()
    if cc is None:
        note("INCONCLUSIVE", "compiler",
             "%s The policy could not be EXECUTED; this is not a pass."
             % ccnote)
        return 3

    tmp = tempfile.mkdtemp(prefix="aowl-mqpolicy-")
    try:
        real, why = build_and_run(cc, tmp, falsify=False)
        if real is None:
            note("INCONCLUSIVE", "compile", why)
            return 3
        for name, want in EXPECTED.items():
            got = real.get(name)
            if got is None:
                note("INCONCLUSIVE", name, "the driver printed no such line")
            elif got == want:
                note("PASS", name, "= %d" % got)
            else:
                note("FAIL", name, "expected %d, got %d" % (want, got))

        # THE NEGATIVE CONTROL. The same header, the pre-fix policy, and the
        # one case that must go red. If it does not, every PASS above is
        # meaningless and this run is INCONCLUSIVE rather than green.
        bad, whybad = build_and_run(cc, tmp, falsify=True)
        if bad is None:
            note("INCONCLUSIVE", "falsifier-compile",
                 "the negative control did not build, so the PASSes above are "
                 "unattributable: %s" % whybad)
        elif bad.get("stalled_on_host") == 1:
            note("PASS", "falsifier",
                 "the pre-2026-09-02 policy DOES run stalled work on the "
                 "caller's thread, so case 1 is a real test")
        else:
            note("INCONCLUSIVE", "falsifier",
                 "the negative control also refused; case 1 cannot fail and "
                 "therefore proves nothing")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    fails = [r for r in results if r[0] == "FAIL"]
    incs = [r for r in results if r[0] == "INCONCLUSIVE"]
    print("")
    print("%d PASS  %d FAIL  %d INCONCLUSIVE" %
          (len(results) - len(fails) - len(incs), len(fails), len(incs)))
    if fails:
        return 1
    if incs:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
