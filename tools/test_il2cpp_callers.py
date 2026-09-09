#!/usr/bin/env python3
r"""test_il2cpp_callers.py -- prove `callers` finds the real edges, and REFUSES.

Run:  python tools/test_il2cpp_callers.py
      python tools/test_il2cpp_callers.py <GameAssembly.dll> <metadec>

Offline only: it reads GameAssembly.dll and the DECRYPTED global-metadata, it
never runs the game, and it writes only into a temporary cache directory it
deletes afterwards. The SHARED .cache graph is read but never written by the
cache cases.

WHAT IS ASSERTED, and what would make each case FAIL
----------------------------------------------------
A rel32 scan can be made to "pass" trivially -- an empty graph answers "0
callers" for everything, and a graph that matched loosely would answer
"1 caller" for anything. So every positive here is paired with something that
can falsify it:

  * GROUND TRUTH A, hand-derived twice tonight by agents with throwaway
    scanners before this verb existed:
        MenuScreen::Show(5 args) @0x15387a0 has EXACTLY ONE caller,
        the `call` at 0x1538790, which lies at +0x30 inside
        MenuScreen::Show(MainMenuBaseScreenController) @0x1538760.
    The site, the kind, the owner START and the offset are all asserted; a
    scan that found the right count at the wrong site still fails.
  * GROUND TRUTH B: OnActionButtonPressed @0x13f61b0 has ZERO direct callers
    (it is wired through CompositeDisposable::SubscribeEvent). This is the
    case an empty graph would also "pass", which is why A runs in the SAME
    graph -- A proves the graph is not empty, B is then meaningful.
  * a `.text` RVA must REFUSE with exit 3 (negative control), while an
    `il2cpp` method start in the same run exits 0 (positive control) -- so the
    refusal is section/start-driven, not unconditional.
  * a MID-BODY il2cpp address must REFUSE and must name the enclosing start,
    because answering "0 callers" for it would be a confidently wrong answer.
  * an ambiguous NAME must refuse and print BOTH addresses; a unique name must
    resolve to the address the RVA form gives.
  * generic-body attribution: a site inside an inflated generic body must be
    labelled `generic-body`, not credited to the ordinary method before it --
    the exact bug in the scratchpad callers.py this verb replaces.
  * a tail `jmp` (E9) edge must be reported as `jmp`, separately from calls.
  * an edge that lands in NO attributable body must be tagged
    `<unattributed>` and must NOT be counted as a caller.
  * CACHE: a fresh build and a load of what it wrote must produce byte-equal
    arrays; the load must be materially faster (timings printed); and a
    TRUNCATED cache file must read as a MISS (None), never as a smaller graph
    -- a short cache that loaded would silently under-report callers.
"""

import io
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from il2cpp_resolve import (Resolver, default_paths, symbol_index,   # noqa: E402
                            call_graph, CallGraph, cmd_callers, site_tag,
                            resolve_callee_name, cache_dir_for)

# ---- measured ground truth (this GameAssembly.dll only) --------------------
SHOW5 = 0x15387A0           # MenuScreen::Show(matchmaker, ..., seasonal)
SHOW1 = 0x1538760           # MenuScreen::Show(MainMenuBaseScreenController)
SHOW5_SITE = 0x1538790      # the one call, +0x30 into SHOW1
ONACTION = 0x13F61B0        # CharacterSelectionSlotViewBase::OnActionButtonPressed
MIDBODY = 0x1539134         # +0x994 inside SHOW5 -- a real crash frame
TEXT_RVA = 0x2000           # in `.text`: engine C++, not IL2CPP output
TAILJMP = 0x641800          # ColorCorrectionCurves::UpdateParameters: 1 call + 1 jmp
UNATTR = 0x628160           # AnimatorStateInfoWrapper::IsName: only a .text coincidence
GENERIC = 0x691200          # callers include two sites in an inflated generic body

_fails = []


def case(label, ok, detail=""):
    print("%-4s %s%s" % ("ok" if ok else "FAIL", label,
                         ("  -- " + detail) if detail else ""))
    if not ok:
        _fails.append(label)


def run(R, key, args):
    """(exit_code, stdout) for one cmd_callers invocation."""
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        rc = cmd_callers(R, args, key=key)
    finally:
        sys.stdout = old
    return rc, buf.getvalue()


def main():
    gameasm, metadec = default_paths()
    if len(sys.argv) > 2:
        gameasm, metadec = sys.argv[1], sys.argv[2]
    for p in (gameasm, metadec):
        if not os.path.exists(p):
            print("SKIP: %s is not present -- this test needs the real "
                  "GameAssembly.dll and DECRYPTED metadata. NOT A PASS." % p)
            return 3
    print("gameasm: %s\nmetadec: %s" % (gameasm, metadec))
    t0 = time.time()
    R = Resolver(gameasm, metadec)
    key = (gameasm, metadec)
    idx = symbol_index(R, key=key)
    print("resolver + symbolize index: %.2fs (%d method starts + %d generic)"
          % (time.time() - t0, idx.n_method_starts, idx.n_generic_starts))

    # ---- cache timing, on a PRIVATE directory so the shared one is untouched
    tmp = tempfile.mkdtemp(prefix="aowl-callgraph-")
    try:
        t0 = time.time()
        g = CallGraph.build(R)
        build_s = time.time() - t0
        path = CallGraph.cache_path(R.b, tmp)
        g.save(path)
        size = os.path.getsize(path)
        t0 = time.time()
        g2 = CallGraph.load(path, list(g.sections))
        load_s = time.time() - t0
        print("cache: MISS build %.2fs -> %d edges, %.1f MB on disk; "
              "HIT load %.2fs (%.0fx faster)"
              % (build_s, len(g.T), size / 1048576.0, load_s,
                 build_s / load_s if load_s else float("inf")))
        case("cache round-trip is byte-identical",
             g2 is not None and g2.T == g.T and g2.S == g.S and g2.K == g.K,
             "%d edges in, %d out" % (len(g.T), len(g2.T) if g2 else -1))
        case("cache HIT is faster than the MISS that wrote it",
             load_s < build_s, "%.3fs vs %.2fs" % (load_s, build_s))
        case("the graph is not empty (an empty graph would pass every "
             "zero-caller case below)", len(g.T) > 1000000,
             "%d edges" % len(g.T))
        # the falsifier for the cache: a short file must be a MISS
        with open(path, "r+b") as fh:
            fh.truncate(size - 64)
        case("a TRUNCATED cache file reads as a MISS, not as a smaller graph",
             CallGraph.load(path, list(g.sections)) is None)
        with open(path, "r+b") as fh:
            fh.seek(0)
            fh.write(b"XXXXXXXX")
        case("a wrong-magic cache file reads as a MISS",
             CallGraph.load(path, list(g.sections)) is None)
        case("the cache path is keyed by the GameAssembly bytes",
             os.path.basename(CallGraph.cache_path(R.b, tmp))
             != os.path.basename(CallGraph.cache_path(R.b + b"\0", tmp)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # From here on use the process/shared cache (read-only in practice).
    g = call_graph(R, key=key)

    # ---- GROUND TRUTH A -----------------------------------------------
    e = g.edges_to(SHOW5)
    case("Show(5 args) @0x%x has exactly ONE caller site" % SHOW5,
         len(e) == 1, "got %d: %s" % (len(e), [hex(s) for s, _ in e]))
    if len(e) == 1:
        site, kind = e[0]
        case("that site is 0x%x" % SHOW5_SITE, site == SHOW5_SITE,
             "got 0x%x" % site)
        case("it is a call (E8), not a jmp", kind == 0)
        owner, start, off, tag = site_tag(R, idx, site)
        case("its owner starts at 0x%x (Show(controller))" % SHOW1,
             start == SHOW1, "got %s" % (hex(start) if start else None))
        case("at offset +0x30", off == 0x30,
             "got %s" % (hex(off) if off is not None else None))
        case("owner names MenuScreen::Show",
             bool(owner) and "MenuScreen" in owner and "Show" in owner,
             str(owner))
        case("owner start is tagged unique", tag == "unique", tag)
    rc, out = run(R, key, ["0x%x" % SHOW5])
    case("CLI exits 0 for Show(5)", rc == 0, "rc=%d" % rc)
    case("CLI prints the site, the owner and the count",
         ("0x%x" % SHOW5_SITE) in out and "@0x%x" % SHOW1 in out
         and "1 direct caller site(s)" in out)

    # ---- GROUND TRUTH B -----------------------------------------------
    case("OnActionButtonPressed @0x%x has ZERO direct edges" % ONACTION,
         len(g.edges_to(ONACTION)) == 0,
         "got %d" % len(g.edges_to(ONACTION)))
    rc, out = run(R, key, ["0x%x" % ONACTION])
    case("zero callers is exit 0 -- a real answer, not a failure", rc == 0,
         "rc=%d" % rc)
    case("and it SAYS vtable/delegate/event rather than implying absence",
         "0 direct callers" in out and "vtable/delegate" in out)

    # ---- refusals, each with its positive control ----------------------
    rc, out = run(R, key, ["0x%x" % TEXT_RVA])
    case("a `.text` RVA REFUSES (exit 3)", rc == 3, "rc=%d" % rc)
    case("...and says INCONCLUSIVE + offers symbolize",
         "INCONCLUSIVE" in out and "symbolize" in out)
    rc, _ = run(R, key, ["0x%x" % SHOW1])
    case("positive control: an il2cpp method start in the same run exits 0",
         rc == 0, "rc=%d" % rc)

    rc, out = run(R, key, ["0x%x" % MIDBODY])
    case("a MID-BODY address REFUSES (exit 3)", rc == 3, "rc=%d" % rc)
    case("...and names the enclosing start 0x%x as the thing to ask about"
         % SHOW5, ("callers 0x%x" % SHOW5) in out)

    # ---- name resolution ----------------------------------------------
    rva, msg = resolve_callee_name(R, "MenuScreen::Show")
    case("an AMBIGUOUS name refuses", rva is None)
    case("...and prints BOTH candidate addresses",
         rva is None and ("0x%x" % SHOW1) in msg and ("0x%x" % SHOW5) in msg)
    rva, msg = resolve_callee_name(
        R, "CharacterSelectionSlotViewBase::OnActionButtonPressed")
    case("a UNIQUE name resolves to the same RVA as the numeric form",
         rva == ONACTION, "got %s" % (hex(rva) if rva else msg.splitlines()[0]))
    rva, msg = resolve_callee_name(R, "MenuScreen::NoSuchMethodHere")
    case("a name that matches nothing refuses and says so",
         rva is None and "NO METHOD NAMED" in msg)

    # ---- generic-body attribution (the scratchpad callers.py bug) -------
    tags = [site_tag(R, idx, s)[3] for s, _ in g.edges_to(GENERIC)]
    case("a site inside an inflated generic body is tagged generic-body",
         any("generic-body" in t for t in tags), str(tags))
    case("...and a non-generic site in the same list is not",
         any(t == "unique" for t in tags), str(tags))

    # ---- tail jmp vs call ----------------------------------------------
    kinds = sorted(k for _, k in g.edges_to(TAILJMP))
    case("0x%x has one call and one tail jmp" % TAILJMP, kinds == [0, 1],
         str(kinds))
    rc, out = run(R, key, ["0x%x" % TAILJMP])
    case("the CLI distinguishes them", "1 call (E8), 1 tail jmp (E9)" in out
         and " jmp  in " in out and " call in " in out)

    # ---- unattributed edges are not counted as callers -----------------
    rc, out = run(R, key, ["0x%x" % UNATTR])
    case("an edge in no method body is tagged <unattributed>",
         "<unattributed>" in out)
    case("...is NOT counted as a caller, and the verdict stays 0",
         "0 direct callers" in out and "not callers" in out, out.strip()[-90:])

    print("")
    if _fails:
        print("FAILED: %d case(s): %s" % (len(_fails), "; ".join(_fails)))
        return 1
    print("ALL CASES PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
