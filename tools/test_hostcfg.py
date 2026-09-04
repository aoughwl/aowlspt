#!/usr/bin/env python3
"""test_hostcfg.py -- hostcfg.py must print the flag's TRUE default.

## The defect this exists for, measured 2026-09-04

`python tools/hostcfg.py keys` printed `default off` for EVERY boolean key,
including `forceOfflinePractice`, `uiShowEvents` and `settingsNativePostFx`,
each of which is a literal `readBoolKeyDef("name", true)` in
`host/Aowlspt.Host.Il2Cpp/aowlhost.nim`. `tools/flagaudit.py` listed those same
three as DEFAULT ON in the same second. Two tools, two parsers, one of them
confidently wrong about the single bit that decides whether a feature is live
on a machine nobody configured (CLAUDE.md 9b).

The fix was to delete hostcfg's parser and import flagaudit's. This test is
what stops the second parser growing back, and it does NOT trust either tool as
its ground truth: the real-host cases below take their expected answers from a
plain `grep` of the host sources, which is an independent measurement.

## Three outcomes, never two

A default that is not a literal `true`/`false` -- an expression, a constant, a
key read by a hand-rolled needle with no default argument at all -- must print
`INCONCLUSIVE` and say why. Printing `off` for it is the original bug wearing a
different hat.

## The falsifier

`python tools/test_hostcfg.py --falsify` restores the pre-fix behaviour (the
default column hardcoded to `off`) and asserts THIS FILE then reports FAIL. A
test whose failing input is unknown is not a test.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import hostcfg  # noqa: E402

PASS, FAIL = 0, 1

SYN = '''\
## a doc comment naming readBoolKeyDef("commentedOnly", true) -- not a call site
proc a() =
  gA = readBoolKeyDef("shipsOn", true)
  gB = readBoolKeyDef("shipsOff", false)
  gC = readBoolKey("plainFlag")
  gD = readBoolKeyDef("computed", gSomething)
  # gE = readBoolKeyDef("commentedOut", true)
'''


class Run:
    def __init__(self):
        self.bad = 0
        self.n = 0

    def case(self, label, got, want):
        self.n += 1
        ok = got == want
        if not ok:
            self.bad += 1
        print("%-4s %-62s want=%-14r got=%r"
              % ("ok" if ok else "FAIL", label[:62], want, got))


def keys_lines(hostdir, root):
    """`hostcfg.py keys` output, as {key: [columns]}."""
    import contextlib
    import io

    keys = hostcfg.scrape_keys(hostdir)

    class A:
        pass
    a = A()
    a.host = hostdir
    a.root = root
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        hostcfg.cmd_keys(a, keys, False)
    out = {}
    for line in buf.getvalue().splitlines():
        if not line.startswith("  "):
            continue
        parts = line.split()
        if len(parts) >= 6 and parts[1] in ("bool", "int", "str"):
            out[parts[0]] = parts
    return out, buf.getvalue()


def col(parts, name):
    """The token after the `default` / `value` heading, positionally."""
    i = parts.index(name)
    return parts[i + 1]


def synthetic(r):
    d = tempfile.mkdtemp(prefix="test-hostcfg-")
    hostdir = os.path.join(d, "host")
    os.makedirs(hostdir)
    with open(os.path.join(hostdir, "syn.nim"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write(SYN)
    # A config that DISAGREES with the default in both directions, so the
    # `default` and `value` columns cannot be the same expression.
    with open(os.path.join(d, "aowlspt-host.json"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write('{\n  "shipsOn": false,\n  "shipsOff": true\n}\n')

    lines, whole = keys_lines(hostdir, d)

    r.case("readBoolKeyDef(x, true) prints default on",
           col(lines["shipsOn"], "default"), "on")
    r.case("readBoolKeyDef(x, false) prints default off",
           col(lines["shipsOff"], "default"), "off")
    r.case("readBoolKey(x) (no default) prints default off",
           col(lines["plainFlag"], "default"), "off")
    r.case("a NON-LITERAL default prints INCONCLUSIVE, not off",
           col(lines["computed"], "default"), "INCONCLUSIVE")
    r.case("and it says WHY it could not be parsed",
           "not the literal" in whole, True)
    # The value column is the FILE, and it is not a copy of the default.
    r.case("a default-ON flag turned off in the file reads value off",
           col(lines["shipsOn"], "value"), "off")
    r.case("a default-OFF flag turned on in the file reads value on",
           col(lines["shipsOff"], "value"), "on")
    # strip_nim: neither a doc comment nor a commented-out line is a flag.
    r.case("a flag named only in a COMMENT is not a key",
           "commentedOnly" in lines, False)
    r.case("a COMMENTED-OUT call site is not a key",
           "commentedOut" in lines, False)


REAL_DEF = re.compile(
    r'\breadBoolKeyDef\s*\(\s*"([A-Za-z0-9_]+)"\s*,\s*(true|false)\s*\)')


def real_host(r):
    """Ground truth by grep, not by either tool's parser."""
    hostdir = os.path.join(REPO, "host")
    if not os.path.isdir(hostdir):
        print("INCONCLUSIVE: no host/ under %s -- the real-host cases were "
              "NOT run. That is not a pass." % REPO)
        return 3
    want = {}
    for base, dirs, files in os.walk(hostdir):
        dirs[:] = [x for x in dirs if x not in ("nimcache", "bin")]
        for fn in files:
            if not fn.endswith(".nim"):
                continue
            with open(os.path.join(base, fn), encoding="utf-8",
                      errors="replace") as f:
                text = f.read()
            for m in REAL_DEF.finditer(text):
                want.setdefault(m.group(1), m.group(2) == "true")
    if not want:
        print("INCONCLUSIVE: grep found no readBoolKeyDef site under host/ -- "
              "nothing was compared.")
        return 3

    lines, _whole = keys_lines(hostdir, os.path.join(REPO, "no-such-root"))
    on = [k for k, v in want.items() if v]
    off = [k for k, v in want.items() if not v]
    r.case("grep found at least one default-ON and one default-OFF site",
           (bool(on), bool(off)), (True, True))
    for k in sorted(want):
        if k not in lines:
            r.case("%s appears in `keys` at all" % k, False, True)
            continue
        r.case("%s: hostcfg agrees with grep" % k,
               col(lines[k], "default"), "on" if want[k] else "off")

    # The three flags named in the defect report, asserted BY NAME, so a
    # future refactor that loses them from the scrape is not a silent pass.
    for k in ("forceOfflinePractice", "uiShowEvents", "settingsNativePostFx"):
        r.case("the reported flag %s is present and default on" % k,
               col(lines.get(k, ["", "", "default", "<ABSENT>"]), "default"),
               "on")
    return 0


def run():
    r = Run()
    synthetic(r)
    rc = real_host(r)
    print("\n%s: %d of %d case(s) failed"
          % ("FAIL" if r.bad else ("INCONCLUSIVE" if rc == 3 else "PASS"),
             r.bad, r.n))
    return FAIL if r.bad else (3 if rc == 3 else PASS)


def falsify():
    """Restore the pre-fix `keys` column and demand this test go red."""
    print("-- falsifier: hardcoding the default column to `off`, as it was "
          "before 2026-09-04 --")
    orig = hostcfg.default_str
    hostcfg.default_str = lambda key, kind: (
        str(hostcfg.INT_KEYS.get(key, 0)) if kind == "int"
        else ('""' if kind == "str" else "off"))
    try:
        rc = run()
    finally:
        hostcfg.default_str = orig
    ok = rc == FAIL
    print("\n%s: the old behaviour %s (exit %d)"
          % ("PASS" if ok else "FAIL",
             "is reported as FAIL, so this test can fail"
             if ok else "PASSED -- this test asserts nothing", rc))
    return PASS if ok else FAIL


if __name__ == "__main__":
    sys.exit(falsify() if "--falsify" in sys.argv else run())
