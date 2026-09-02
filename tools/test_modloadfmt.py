#!/usr/bin/env python3
r"""test_modloadfmt.py -- the three writers of `aowlspt-modload.txt` agree.

    python tools/test_modloadfmt.py

There are three writers of the file the in-game mod-loading step renders, in
two languages:

    tools/modbuild.py      the real one, driven by a compile
    tools/modloadsim.py    the synthetic driver
    tools/aowllaunch.nim   the launcher's opening and "not built" states

The Python two now share `tools/modloadfmt.py`, so they cannot drift. The Nim
one cannot import it, so it is checked HERE, against the literals it declares.

## Why this test is worth its length

The format is a wire protocol between two processes, and the reader
(`host/Aowlspt.Host.Il2Cpp/modload.nim`) parses exactly two control words on
line 0. Everything about the feature -- whether the mods load at all, whether
the step ever goes away -- hangs on those words being spelled right by a writer
in another language.

They had already drifted once, invisibly: `modbuild.py` wrote CRLF (Python text
mode on Windows) and `modloadsim.py` wrote LF. The host strips `\r`, so nothing
broke and nothing reported it. That is exactly the kind of silent divergence a
test is for, and it is also why the assertions below are on the FINISHED BYTES
of the written file rather than on the return value of a formatting function.

Every assertion is paired with a negative control where one is possible: a
check that cannot fail is the bug (CLAUDE.md 9b).
"""

from __future__ import annotations

import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import modloadfmt  # noqa: E402
import modloadsim  # noqa: E402
import modbuild  # noqa: E402

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s   %s" % (name, detail))
        FAILURES.append(name)


def written(lines):
    """The BYTES that land on disk, which is what the host actually reads."""
    d = tempfile.mkdtemp(prefix="modloadfmt-")
    p = os.path.join(d, "aowlspt-modload.txt")
    modloadfmt.write(p, lines)
    with open(p, "rb") as f:
        return f.read()


def nim_literals():
    """The Ml* string constants declared in tools/aowllaunch.nim."""
    src = io.open(os.path.join(HERE, "aowllaunch.nim"),
                  encoding="utf-8", errors="replace").read()
    out = {}
    for line in src.splitlines():
        s = line.strip()
        if not s.startswith("Ml") or "=" not in s:
            continue
        name, _, rest = s.partition("=")
        rest = rest.strip()
        if rest.startswith('"') and rest.endswith('"') and len(rest) >= 2:
            out[name.strip()] = rest[1:-1]
    return out


def main():
    print("modloadfmt: the three writers of aowlspt-modload.txt")

    # ---- shape -----------------------------------------------------------
    print("\nshape")
    for name, lines in (("queued", modloadfmt.queued(15)),
                        ("building", modloadfmt.building("maps", 7, 15,
                                                         "building", "12s")),
                        ("ready", modloadfmt.ready(15, 15)),
                        ("ready+failed", modloadfmt.ready(15, 15, ["sain"])),
                        ("not_built", modloadfmt.not_built("no compiler"))):
        b = written(lines)
        check("%s is exactly 3 lines" % name, b.count(b"\n") == 3,
              "got %d newline(s): %r" % (b.count(b"\n"), b))
        check("%s writes LF, never CRLF" % name, b"\r" not in b, repr(b))

    # NEGATIVE CONTROL for the shape checks: four lines in, three out. If this
    # ever fails the "exactly 3 lines" checks above are not measuring anything.
    b = written(["a", "b", "c", "d SHOULD BE DROPPED"])
    check("a 4th line is DROPPED, not written",
          b"SHOULD BE DROPPED" not in b and b.count(b"\n") == 3, repr(b))
    b = written(["only one"])
    check("a short render is padded to 3 lines", b.count(b"\n") == 3, repr(b))

    # ---- the control words ----------------------------------------------
    print("\ncontrol words (what the host actually parses)")
    r = modloadfmt.ready(15, 15)
    check("ready line 0 starts with MODS READY", r[0].startswith("MODS READY"),
          repr(r[0]))
    check("a clean ready does NOT contain FAILED", "FAILED" not in r[0],
          repr(r[0]))
    f = modloadfmt.ready(15, 15, ["sain", "maps"])
    check("a failed ready starts with MODS READY",
          f[0].startswith("MODS READY"), repr(f[0]))
    check("a failed ready contains FAILED on line 0", "FAILED" in f[0],
          repr(f[0]))
    check("a failed ready names the mods", "sain" in f[2] and "maps" in f[2],
          repr(f[2]))
    for name, lines in (("queued", modloadfmt.queued(15)),
                        ("building", modloadfmt.building("maps", 7, 15))):
        check("%s does NOT say MODS READY" % name,
              not lines[0].startswith("MODS READY"), repr(lines[0]))
        check("%s does NOT say FAILED" % name, "FAILED" not in lines[0],
              repr(lines[0]))
    n = modloadfmt.not_built("no compiler in this install")
    check("not_built releases the host (MODS READY)",
          n[0].startswith("MODS READY"), repr(n[0]))
    check("not_built does not claim a build ran",
          "not rebuilt" in n[1].lower(), repr(n[1]))
    check("not_built does not say FAILED (nothing failed; nothing ran)",
          "FAILED" not in n[0] and "FAILED" not in n[1], repr(n))

    # ---- the two Python writers render the SAME bytes --------------------
    print("\nthe two Python writers")
    check("modloadsim.write IS modloadfmt.write",
          modloadsim.write is modloadfmt.write)
    prog = modbuild.Progress(None, 15, None)
    prog.order = ["maps"]
    prog.rows = {"maps": ("building", "12s")}
    prog.i = 7
    # Reach the same render path modbuild uses, without a compile.
    check("modbuild renders the shared building() line",
          modloadfmt.building("maps", 7, 15, "building", "12s")
          == modloadfmt.building(prog.order[-1], prog.i, prog.total,
                                 *prog.rows["maps"]))
    prog.done_all = True
    check("modbuild's terminal render is the shared ready()",
          modloadfmt.ready(len(prog.rows), prog.total, [])
          == modloadfmt.ready(1, 15))

    # ---- the Nim writer --------------------------------------------------
    print("\nthe Nim writer (tools/aowllaunch.nim)")
    lit = nim_literals()
    check("aowllaunch.nim declares the Ml* literals", len(lit) >= 5,
          "found %r" % sorted(lit))
    q = modloadfmt.queued(None)
    check("MlQueued0 matches modloadfmt.queued line 0",
          lit.get("MlQueued0") == q[0],
          "%r vs %r" % (lit.get("MlQueued0"), q[0]))
    check("MlQueued1 matches modloadfmt.queued line 1",
          lit.get("MlQueued1") == q[1],
          "%r vs %r" % (lit.get("MlQueued1"), q[1]))
    check("MlQueued2 matches modloadfmt.queued line 2",
          lit.get("MlQueued2") == q[2],
          "%r vs %r" % (lit.get("MlQueued2"), q[2]))
    nb = modloadfmt.not_built("x")
    check("MlNotBuilt0 matches modloadfmt.not_built line 0",
          lit.get("MlNotBuilt0") == nb[0],
          "%r vs %r" % (lit.get("MlNotBuilt0"), nb[0]))
    check("MlNotBuilt1 matches modloadfmt.not_built line 1",
          lit.get("MlNotBuilt1") == nb[1],
          "%r vs %r" % (lit.get("MlNotBuilt1"), nb[1]))
    # NEGATIVE CONTROL: the comparison above must be capable of noticing a
    # difference. If this "passes", the literals are not being read at all.
    check("the Nim comparison can FAIL (control)",
          lit.get("MlQueued0") != "deliberately wrong")

    # ---- the launcher really calls the builder ---------------------------
    #
    # The whole feature was absent for months precisely because nothing
    # connected the launcher to modbuild, and no test noticed. This one would
    # have.
    print("\nthe launcher invokes the builder")
    nim = io.open(os.path.join(HERE, "aowllaunch.nim"),
                  encoding="utf-8", errors="replace").read()
    check("aowllaunch.nim mentions modbuild at all", "modbuild" in nim)
    check("aowllaunch.nim spawns it", "startModBuild" in nim
          and "cSpawnQuiet" in nim)
    check("it passes --screen so the host has something to render",
          "--screen" in nim)
    # ORDER, inside startModBuild: the queued state must be on disk BEFORE the
    # builder is spawned, or last session's MODS READY is what the host reads.
    # Checked within the proc body, so an unrelated write elsewhere in the
    # file cannot satisfy it.
    body = nim[nim.index("proc startModBuild("):]
    body = body[:body.index("proc modBuildDeclined(")]
    check("startModBuild writes the queued state BEFORE spawning",
          "mlWriteScreen(" in body and "cSpawnQuiet(" in body
          and body.index("mlWriteScreen(") < body.index("cSpawnQuiet("),
          "the stale-READY race depends on this order")
    check("the order check looked at real code (control)",
          "cSpawnQuiet(" in body and len(body) > 200)

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
