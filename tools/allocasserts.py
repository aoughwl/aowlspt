#!/usr/bin/env python3
"""No aowlspt binary may ship mimalloc's DEBUG build. Measured, not assumed.

WHY THIS FILE EXISTS
--------------------
MEASURED 2026-09-03 09:21:51, host build b3c4047 (deployed sha 36c5b198). The
client died with a fail-fast `abort()` -- no Unity Crash_* report, only
`%LOCALAPPDATA%\\CrashDumps\\EscapeFromTarkov.exe.636.dmp`. Read with cdb
(`.ecxr; k 40`), the stack was `ucrtbase!abort` <- our host DLL <- `mi_malloc`
<- `sain!resolve_0`, on the ops thread. `dpp` over the abort frame produced one
string pointer; `da 00007ffb3dfd1373` printed:

    "corrupted thread-free list."

That is `vendor/mimalloc/src/page.c:205` -- mimalloc walking a page's
thread-free list, finding `count > page->capacity`, and reporting `EFAULT`. The
abort is NOT in that check. It is in `mi_error_default`, `src/options.c:541`:

    static void mi_error_default(int err) {
    #if (MI_DEBUG>0)
      if (err==EFAULT) { __debugbreak(); abort(); }
    #endif
    #if (MI_SECURE>0)
      if (err==EFAULT) { abort(); }
    #endif

MI_SECURE is 0 here. So the process-killing branch was compiled in purely
because MI_DEBUG > 0 -- and `include/mimalloc/types.h:69-75` defaults MI_DEBUG
to **2** unless `MI_BUILD_RELEASE` or `NDEBUG` is defined. nimony only defines
`MI_BUILD_RELEASE` under `-d:release`/`-d:danger` (`lib/std/system/mimalloc.nim`
line 27), and `tools/aowl.nim` never passed either. Every DLL we have ever
shipped therefore linked a debug allocator that turns a heap anomaly into an
instant client kill.

The fix is `mimallocFlags` in `tools/aowl.nim` (and the matching literal in
`tools/modbuild.py:compile_cmd`): `--passC:-DMI_BUILD_RELEASE
--passC:-DMI_DEBUG=0`.

THE TRADE, STATED HONESTLY
--------------------------
With MI_DEBUG=0 the corruption check at page.c:205 still runs and still refuses
to free the suspect list -- it returns instead of aborting, so those blocks
leak. `mi_assert_internal` and per-block padding checks are gone entirely. A
real heap bug (a double free, or a cross-thread free that races) now surfaces
later and less precisely than it did. That is the correct bargain for a mod
host: the allocator must not be a crash source in a game the user is playing.
MI_SECURE (types.h:55-63) would restore the abort and is deliberately NOT
enabled; if we ever want the loud behaviour for a debugging session, that is
the switch, and it should be per-build, never in a shipped artifact.

The underlying anomaly is a separate, still-open question: something allocated
on one thread is being freed on another in a way mimalloc reads as a corrupted
thread-free list, on the `sain` resolve path driven from the ops thread. This
tool does not fix that and does not claim to. It removes the allocator's
licence to kill the process over it.

WHAT IS CHECKED, AND WHY IT CANNOT PASS VACUOUSLY
-------------------------------------------------
Per binary, three outcomes, never two:

  * CONTROL   `corrupted thread-free list` must be PRESENT. It is a mimalloc
              string that survives MI_DEBUG=0, so it proves two things at once:
              mimalloc really is linked into this file, and a literal search
              over these bytes really can find text. Without it, "the assertion
              strings are not here" is "we could not look" -> INCONCLUSIVE.
  * SENTINELS five literals that exist ONLY when MI_DEBUG > 0 (assertion
              expressions and __FILE__ strings passed to `_mi_assert_fail`,
              which is itself inside `#if MI_DEBUG`). Any one present -> FAIL.
  * verdict   PASS only when the control matched AND all sentinels are absent.

`mimalloc: assertion failed` is deliberately NOT a sentinel: measured on the
fixed host DLL, markers.py reports it INCONCLUSIVE because the unrelated words
"assertion" and "failed" survive elsewhere in rodata (81% word-run coverage).
A sentinel that answers INCONCLUSIVE on a correct binary is not a check.

Usage:
    python tools/allocasserts.py                # scan the shipping artifacts
    python tools/allocasserts.py <path> [...]   # scan arbitrary binaries
    python tools/allocasserts.py --selftest     # the falsifier (see below)

Exit: 0 PASS, 1 FAIL, 3 INCONCLUSIVE.
"""

from __future__ import annotations

import argparse
import glob
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import markers  # noqa: E402

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"

# Present in EVERY mimalloc build, debug or release (page.c:205). The positive
# control: it proves mimalloc is in this file and that the search works.
CONTROL = "corrupted thread-free list"

# Present ONLY when MI_DEBUG > 0. Each is an assertion expression or a __FILE__
# handed to `_mi_assert_fail`, which is compiled under `#if MI_DEBUG`
# (src/options.c:527). Measured 2026-09-03 against the two host DLLs:
# all five PRESENT in the pre-fix 5,083,136-byte build, all five absent in the
# 5,019,648-byte build made with -DMI_DEBUG=0.
SENTINELS = [
    "mi_page_queue_contains",
    "mi_heap_is_initialized",
    "mi_page_all_free",
    "_mi_ptr_page",
    "page-queue.c",
]


def shipping_artifacts():
    """The binaries that reach a player's machine, in this checkout.

    Named EXACTLY, not globbed. A `bin/` directory also accumulates things a
    player never runs -- the backend's `dbrace`/`framelen`/`modrace` race
    harnesses, and hand-kept host snapshots like
    `aowlspt-host-il2cpp.osclose-57df598.dll` -- and reporting those as FAIL
    would make the default run permanently red for a reason nobody would act
    on, which is how a gate gets routed around. Any path can still be scanned
    explicitly by passing it as an argument.
    """
    out = [
        os.path.join(REPO, "host", "Aowlspt.Host.Il2Cpp", "bin",
                     "aowlspt-host-il2cpp.dll"),
        os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe"),
        os.path.join(REPO, "installer", "build", "aowlspt-launch.exe"),
    ]
    for d in sorted(glob.glob(os.path.join(REPO, "mods", "*", "bin"))):
        mod = os.path.basename(os.path.dirname(d))
        out.append(os.path.join(d, mod + ".dll"))
    return [p for p in out if os.path.isfile(p)]


def check(path, mode="all"):
    """(verdict, lines) for ONE file. Never raises on content."""
    res = markers.scan(path, [CONTROL], list(SENTINELS), [CONTROL], mode)
    lines = []
    if res.get("note"):
        return INCONCLUSIVE, [res["note"]]
    # markers.scan reports the control it actually matched; results/absent
    # entries are dicts whose "outcome" is one of present/missing/pass/fail/
    # INCONCLUSIVE. Read them by key, never by position.
    ctrl_ok = any(r.get("outcome") == markers.PRESENT for r in res["results"])
    if not ctrl_ok:
        return INCONCLUSIVE, [
            "the control %r did not match, so this file was not proved to "
            "contain mimalloc at all and nothing below is evidence." % CONTROL]
    hits = []
    unclear = []
    for r in res["absent"]:
        if r.get("outcome") == "fail":
            hits.append(r["marker"])
        elif r.get("outcome") != "pass":
            unclear.append(r["marker"])
    if hits:
        return FAIL, ["MI_DEBUG>0 sentinel still present: " + ", ".join(hits),
                      "this binary's mimalloc can abort() the client on a heap "
                      "anomaly (src/options.c:541). Rebuild through aowl/"
                      "modbuild so -DMI_DEBUG=0 is applied."]
    if unclear:
        return INCONCLUSIVE, ["sentinel(s) neither clearly present nor clearly "
                              "removed: " + ", ".join(unclear)]
    return PASS, ["mimalloc present (control matched), %d MI_DEBUG sentinel(s) "
                  "absent" % len(SENTINELS)]


# --------------------------------------------------------------------------
# The falsifier. A scanner whose only reachable answer is PASS is not a check,
# so this builds three synthetic files and asserts all THREE verdicts fire.
# --------------------------------------------------------------------------

def _fake_pe(literals):
    """A byte blob shaped enough like a PE that markers.pe_short() is happy."""
    # markers.pe_short only complains about a TRUNCATED read (sections claiming
    # more bytes than the file has), so a plain blob with a DOS/NT header and
    # no section table is fine; keep it simple and self-evident.
    blob = bytearray(b"MZ" + b"\x00" * 0x3a)
    blob += struct.pack("<I", 0x40)             # e_lfanew
    blob += b"PE\x00\x00"
    blob += b"\x00" * 0x100
    for lit in literals:
        blob += lit.encode("ascii") + b"\x00"
        blob += b"\x00" * 16
    return bytes(blob)


def selftest():
    cases = [
        # (label, literals in the file, expected verdict, why)
        ("debug build", [CONTROL, SENTINELS[0], SENTINELS[4]], FAIL,
         "mimalloc is present AND an MI_DEBUG-only assertion string is too -- "
         "exactly the shape of every DLL shipped before 2026-09-03"),
        ("release build", [CONTROL], PASS,
         "mimalloc is present and no MI_DEBUG sentinel is"),
        ("no mimalloc at all", ["something else entirely"], INCONCLUSIVE,
         "the control did not match, so absence of the sentinels proves "
         "nothing -- this must NOT read as a pass"),
        ("one sentinel of five", [CONTROL, SENTINELS[3]], FAIL,
         "a single surviving sentinel is enough; the check is an OR"),
    ]
    ok = True
    tmp = tempfile.mkdtemp(prefix="allocasserts-")
    for label, lits, expect, why in cases:
        p = os.path.join(tmp, label.replace(" ", "_") + ".bin")
        with open(p, "wb") as f:
            f.write(_fake_pe(lits))
        got, lines = check(p)
        good = (got == expect)
        ok = ok and good
        print("  %-6s %-20s expected %-13s got %-13s"
              % ("ok" if good else "FAIL", label, expect, got))
        if not good:
            for ln in lines:
                print("           " + ln)
        else:
            print("           %s" % why)
    # A verdict set that never varies would let all four "pass" trivially.
    seen = set()
    for label, lits, expect, why in cases:
        seen.add(expect)
    if len(seen) < 3:
        print("  FAIL   the cases do not exercise all three verdicts")
        ok = False
    print("selftest: %s (%d cases, verdicts exercised: %s)"
          % ("PASS" if ok else "FAIL", len(cases), ", ".join(sorted(seen))))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="refuse any binary whose mimalloc was built with MI_DEBUG>0")
    ap.add_argument("paths", nargs="*", help="binaries to scan "
                    "(default: this checkout's shipping artifacts)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--mode", default="all", help="litscan encoding set")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    paths = a.paths or shipping_artifacts()
    if not paths:
        print("INCONCLUSIVE: no binaries to scan. Nothing was checked, which "
              "is not evidence that anything is clean. Build first.")
        return 3

    verdicts = []
    for p in paths:
        v, lines = check(p, a.mode)
        verdicts.append(v)
        print("%-13s %s" % (v, p))
        if v != PASS:
            for ln in lines:
                print("              " + ln)
    n_fail = verdicts.count(FAIL)
    n_inc = verdicts.count(INCONCLUSIVE)
    if n_fail:
        print("verdict: FAIL  (%d of %d binaries carry MI_DEBUG assertions)"
              % (n_fail, len(paths)))
        return 1
    if n_inc:
        print("verdict: INCONCLUSIVE  (%d of %d could not be judged)"
              % (n_inc, len(paths)))
        return 3
    print("verdict: PASS  (%d binaries, mimalloc release-built in each)"
          % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
