#!/usr/bin/env python3
r"""test_il2cpp_symbolize.py -- prove `symbolize` names methods, and REFUSES.

Run:  python tools/test_il2cpp_symbolize.py
      python tools/test_il2cpp_symbolize.py <GameAssembly.dll> <metadec>

Needs GameAssembly.dll and the DECRYPTED metadata (defaults: the same ones
every other tool here uses -- D:/Games/Tarkov/GameAssembly.dll and
.cache/global-metadata.dec.dat, resolved against the repo). It never runs the
game and never writes anything.

WHAT IS ASSERTED, and why each case can FAIL
--------------------------------------------
A nearest-start walk will name a method for ANY address you hand it, so the
positives alone would be a check that cannot fail (CLAUDE.md 9b). Every
refusal below therefore comes with the input that makes it flip:

  * two GROUND-TRUTH addresses, hand-walked by an agent from
    Crash_2026-09-02_045551684 before this tool existed:
        RVA 0x1420103 -> EFT.UI.SeasonWidgetData::From  @0x141ffd0 +0x133
        RVA 0x1539134 -> EFT.UI.MenuScreen::Show        @0x15387a0 +0x994
    The owner, the START and the OFFSET are all asserted -- naming the right
    method at the wrong start would still be a wrong answer.
  * a `.text` address must REFUSE (positive control: an `il2cpp` address in
    the same run does not).
  * an address past the last method start by more than --max-gap must REFUSE,
    and the SAME address with a large enough --max-gap must succeed -- so the
    refusal is demonstrably gap-driven and not unconditional.
  * a generic-SHARED body must REFUSE and name more than one owner.
  * a live ASLR address with no --base must REFUSE rather than be rebased off
    the PE's preferred base 0x180000000.
  * a report WITH a GameAssembly base line symbolizes both frames; the same
    report with that line DELETED must say the base line is missing and must
    produce NO symbol -- the negative control for the whole report path. A
    report whose GameAssembly `size:` disagrees with ours must be refused as a
    different build.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import crashwatch                                    # noqa: E402
from il2cpp_resolve import (Resolver, default_paths, symbol_index,  # noqa: E402
                            parse_module_bases, symbolize_frames,
                            size_of_image, cmd_symbolize, DEFAULT_MAX_GAP)

# Verbatim from Crash_2026-09-02_045551684: base line, then the crash-site
# frames Unity labelled `mono_class_has_parent` (its nearest EXPORT -- there is
# no PDB for GameAssembly.dll, so that label names a function ~20 MB away).
GA_BASE = 0x00007FFB2ABB0000
REPORT = "\n".join([
    r"D:\Aowlspt\GameAssembly.dll:GameAssembly.dll (00007FFB2ABB0000), "
    r"size: 126812160 (result: 0), SymType: '-deferred-', PDB: ''",
    r"D:\Aowlspt\UnityPlayer.dll:UnityPlayer.dll (00007FFB41E00000), "
    r"size: 32014336 (result: 0), SymType: '-deferred-', PDB: ''",
    "",
    crashwatch.STACK_BEGIN,
    "",
    "0x00007FFB2BFD0103 (GameAssembly) mono_class_has_parent",
    "0x00007FFB2C0E9134 (GameAssembly) mono_class_has_parent",
    "0x00007FFB424EEA0F (UnityPlayer) (function-name not available)",
    crashwatch.STACK_END,
])

_fails = []


def case(label, ok, detail=""):
    print("%-4s %s%s" % ("ok" if ok else "FAIL", label,
                         ("  -- " + detail) if detail else ""))
    if not ok:
        _fails.append(label)


def main():
    gameasm, metadec = default_paths()
    if len(sys.argv) > 2:
        gameasm, metadec = sys.argv[1], sys.argv[2]
    for p in (gameasm, metadec):
        if not os.path.exists(p):
            print("INCONCLUSIVE: %s is absent, so NOTHING was checked. This "
                  "is not a pass." % p)
            return 2
    R = Resolver(gameasm, metadec)
    idx = symbol_index(R, key=(gameasm, metadec))
    print("index: %d methodPointers start(s) + %d generic body start(s)%s\n"
          % (idx.n_method_starts, idx.n_generic_starts,
             ("  NOTE: " + idx.generics_note) if idx.generics_note else ""))

    # -- 1/2: the two ground-truth addresses -----------------------------
    for rva, want_owner, want_start, want_off in (
            (0x1420103, "EFT.UI.SeasonWidgetData::", 0x141ffd0, 0x133),
            (0x1539134, "EFT.UI.MenuScreen::", 0x15387a0, 0x994)):
        s = idx.lookup(rva)
        good = (s.ok and s.owner.startswith(want_owner)
                and s.start == want_start and s.offset == want_off)
        case("0x%x -> %s @0x%x +0x%x" % (rva, want_owner, want_start, want_off),
             good, s.line()[:150])
    # the method NAME, not just the type, must be right
    s = idx.lookup(0x1420103)
    case("...and the method is From()", s.ok and "From(" in s.owner,
         s.owner[:90])
    s = idx.lookup(0x1539134)
    case("...and the method is Show()", s.ok and "Show(" in s.owner,
         s.owner[:90])

    # -- 3: a .text address must refuse ----------------------------------
    text_rva = None
    for name, vs, vz, raw, rz in R.SEC:
        if name == ".text":
            text_rva = vs + vz // 2
    s = idx.lookup(text_rva)
    case("a .text RVA (0x%x) REFUSES" % text_rva,
         (not s.ok) and ".text" in s.why, s.why[:110])
    case("...and the refusal is not unconditional: an il2cpp RVA in the same "
         "run still resolves", idx.lookup(0x1420103).ok)

    # -- 4: past the last start by more than --max-gap --------------------
    far = idx.starts[-1] + 0x20000
    in_sec = R.section_of_rva(far)[0] == "il2cpp"
    s = idx.lookup(far, max_gap=DEFAULT_MAX_GAP)
    case("0x%x (last start + 0x20000, still in the il2cpp section) REFUSES on "
         "--max-gap" % far,
         in_sec and (not s.ok) and "max-gap" in s.why, s.why[:110])
    s2 = idx.lookup(far, max_gap=0x40000)
    case("...and the SAME address with --max-gap 0x40000 resolves, so the "
         "refusal is gap-driven, not unconditional", s2.ok, s2.line()[:110])

    # -- 5: a generic-shared body ----------------------------------------
    gshared = next((st for st in idx.starts
                    if sum(1 for e in idx.owners[st] if e[0] == "g") > 1), None)
    if gshared is None:
        case("a generic-SHARED start exists to test", False,
             "none found -- this case was NOT exercised")
    else:
        s = idx.lookup(gshared + 4)
        case("a generic-SHARED body (0x%x) REFUSES and names its owners"
             % gshared,
             (not s.ok) and "GENERIC-SHARED" in s.why, s.why[:110])

    # -- 6: the report path ----------------------------------------------
    lines = REPORT.split("\n")
    bases = parse_module_bases(lines)
    case("the report's GameAssembly SizeOfImage matches ours (%d)"
         % size_of_image(R.b),
         bases.get("gameassembly", (0, 0))[1] == size_of_image(R.b),
         str(bases.get("gameassembly")))
    frames = crashwatch.parse_stack_blocks(lines)[0]
    case("3 crash-site frames parsed", len(frames) == 3, str(frames)[:80])
    rows = symbolize_frames(R, frames, bases, index=idx,
                            key=(gameasm, metadec))
    ok0 = rows[0][1] is not None and rows[0][1].ok and \
        "SeasonWidgetData" in rows[0][1].owner
    ok1 = rows[1][1] is not None and rows[1][1].ok and \
        "MenuScreen" in rows[1][1].owner
    case("report frame 1 (VA 0x%x) symbolizes through the base line"
         % (GA_BASE + 0x1420103), ok0,
         rows[0][1].line()[:100] if rows[0][1] else "None")
    case("report frame 2 symbolizes", ok1,
         rows[1][1].line()[:100] if rows[1][1] else "None")
    case("the UnityPlayer frame is PASSED THROUGH, not guessed at",
         rows[2][1] is None and not rows[2][2], str(rows[2][2])[:80])

    # -- 6b: NEGATIVE CONTROL -- the same report with no base line --------
    nb = [l for l in lines if "GameAssembly.dll" not in l]
    rows_nb = symbolize_frames(R, crashwatch.parse_stack_blocks(nb)[0],
                               parse_module_bases(nb), index=idx,
                               key=(gameasm, metadec))
    said = (rows_nb[0][1] is None and "module base line" in rows_nb[0][2])
    case("a report with NO GameAssembly base line SAYS SO and symbolizes "
         "nothing", said, rows_nb[0][2][:110])

    # -- 6c: a base line from a DIFFERENT build ---------------------------
    wrong = [l.replace("size: 126812160", "size: 999999999") for l in lines]
    rows_w = symbolize_frames(R, crashwatch.parse_stack_blocks(wrong)[0],
                              parse_module_bases(wrong), index=idx,
                              key=(gameasm, metadec))
    case("a report whose GameAssembly size disagrees is refused as a "
         "DIFFERENT BUILD",
         rows_w[0][1] is None and "DIFFERENT BUILD" in rows_w[0][2],
         rows_w[0][2][:110])

    # -- 7: CLI exit codes, in-process (the index is already cached) ------
    rc_ok = cmd_symbolize(R, ["0x1420103"], key=(gameasm, metadec))
    rc_bad = cmd_symbolize(R, [hex(text_rva)], key=(gameasm, metadec))
    rc_live = cmd_symbolize(R, ["0x00007FFB2BFD0103"], key=(gameasm, metadec))
    rc_base = cmd_symbolize(R, ["0x00007FFB2BFD0103", "--base", hex(GA_BASE)],
                            key=(gameasm, metadec))
    case("exit 0 for a resolved address", rc_ok == 0, "rc=%s" % rc_ok)
    case("exit 3 (INCONCLUSIVE) for a .text address", rc_bad == 3,
         "rc=%s" % rc_bad)
    case("exit 3 for a live ASLR address with no --base", rc_live == 3,
         "rc=%s" % rc_live)
    case("exit 0 for the same live address WITH --base", rc_base == 0,
         "rc=%s" % rc_base)

    print("\n%s: %d case(s) failed%s"
          % ("FAIL" if _fails else "PASS", len(_fails),
             ("  -- " + "; ".join(_fails)) if _fails else ""))
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
