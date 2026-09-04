#!/usr/bin/env python3
r"""test_il2cpp_disasm.py -- prove `disasm` decodes the right bytes, names the
right callee, and REFUSES rather than inventing a field name.

Run:  python tools/test_il2cpp_disasm.py
      python tools/test_il2cpp_disasm.py <GameAssembly.dll> <metadec>

Offline only: it reads GameAssembly.dll and the DECRYPTED global-metadata, it
never runs the game, and it writes nothing.

WHAT IS ASSERTED, and what would make each case FAIL
----------------------------------------------------
A disassembler is trivially "passable": printing SOMETHING for every address
looks like success. So each positive here is paired with a falsifier.

  * GROUND TRUTH A (hand-derived by an agent tonight with a throwaway capstone
    script, which is why this verb exists):
        `From @0x141ffd0 +0x11f`  is  `cmp qword ptr [rbx + 0x118], r12`
    asserted TOGETHER with: the `>>` marker is on THAT line and appears exactly
    once, and the line carries the field annotation `Profile.BattlePass@0x118`.
    A decode that started at the wrong boundary prints different mnemonics
    here; a marker bug puts `>>` elsewhere.
  * The field annotation has three falsifiers:
      - `--no-fields` must print the SAME instruction WITHOUT the name, so the
        name provably comes from the metadata map and not from the mnemonic.
      - EFT.Profile must have NO field at 0x117 (a neighbouring offset), so the
        lookup is exact rather than nearest.
      - an UNINSTANTIATED generic definition must contribute ZERO offsets: its
        fieldOffsets array is all zeros and reading it would fabricate a field
        at 0x0 for every member (CLAUDE.md 5).
      - a register whose type is not derivable must print `?`, and the run must
        contain at least one such line -- otherwise "everything is annotated"
        and the `?` path is untested.
  * GROUND TRUTH B: the `call` at 0x1538790 inside
    `MenuScreen::Show(controller)` @0x1538760 must resolve to
    `MenuScreen::Show(5 args)` @0x15387a0 BY NAME, through the same symbolize
    index `callers` uses -- not merely print the raw target.
  * A `.text` RVA must still disassemble (exit 0) while stating that no owner
    is known and showing NO preceding context; its first printed line must be
    the requested address itself. A verb that refused .text outright would be
    less useful; one that invented an owner would be wrong.
  * THE BOUNDARY RULE, measured rather than asserted: the byte 0x20 before the
    requested address (0x14200cf) is NOT an instruction start, so a naive
    "decode from fault-0x20" would desynchronise. The test proves that
    0x14200cf is mid-instruction AND that every line the tool printed is a real
    instruction start of the owner-start decode.
  * A mid-instruction request must SAY it is mid-instruction.
  * Refusals: an ambiguous name exits 3 and prints both addresses; --len with
    --to exits 2; a live ASLR address with no --base exits 3; and with capstone
    made unimportable the verb exits 4 printing the install hint and NO
    instruction lines (the negative control for "capstone is importable here").
"""

import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from il2cpp_resolve import (Resolver, default_paths, symbol_index,   # noqa: E402
                            cmd_disasm, FieldAtOffset, import_capstone)

# ---- measured ground truth (this GameAssembly.dll only) --------------------
FROM = 0x141FFD0            # EFT.UI.SeasonWidgetData::From(Profile, Seasonal..)
FAULT = FROM + 0x11F        # 0x14200ef -- the cmp
MIDINS = FAULT + 3          # inside that 7-byte cmp
NOT_A_START = 0x14200CF     # FAULT - 0x20: mid-instruction, measured below
SHOW1 = 0x1538760           # MenuScreen::Show(MainMenuBaseScreenController)
SHOW5 = 0x15387A0           # MenuScreen::Show(5 args)
SHOW5_SITE = 0x1538790      # the call
TEXT_RVA = 0x2000           # engine C++, no IL2CPP owner

_fails = []


def case(label, ok, detail=""):
    print("%-4s %s%s" % ("ok" if ok else "FAIL", label,
                         ("  -- " + detail) if detail else ""))
    if not ok:
        _fails.append(label)


def run(R, key, args):
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        rc = cmd_disasm(R, args, key=key)
    finally:
        sys.stdout = old
    return rc, buf.getvalue()


def insn_lines(out):
    """Only the disassembly rows, as (marker, addr, text)."""
    rows = []
    for ln in out.splitlines():
        m = re.match(r"^(>>|  ) 0x([0-9a-f]+) +([0-9a-f]+) +(.*)$", ln)
        if m:
            rows.append((m.group(1), int(m.group(2), 16), m.group(4)))
    return rows


def main():
    gameasm, metadec = default_paths()
    if len(sys.argv) > 2:
        gameasm, metadec = sys.argv[1], sys.argv[2]
    for p in (gameasm, metadec):
        if not os.path.exists(p):
            print("SKIP: %s is not present -- this test needs the real "
                  "GameAssembly.dll and DECRYPTED metadata. NOT A PASS." % p)
            return 3
    cs, refusal = import_capstone()
    if cs is None:
        print("SKIP: capstone is not importable here, so `disasm` can only be "
              "tested for its refusal. NOT A PASS.\n%s" % refusal)
        return 3
    print("gameasm: %s\nmetadec: %s" % (gameasm, metadec))
    R = Resolver(gameasm, metadec)
    key = (gameasm, metadec)
    idx = symbol_index(R, key=key)
    print("index: %d method starts + %d generic bodies"
          % (idx.n_method_starts, idx.n_generic_starts))

    # ---- GROUND TRUTH A ---------------------------------------------------
    rc, out = run(R, key, ["0x%x" % FAULT])
    rows = insn_lines(out)
    marked = [r for r in rows if r[0] == ">>"]
    case("A: exit 0 for a mid-body il2cpp address", rc == 0, "rc=%d" % rc)
    case("A: exactly one line is marked >>", len(marked) == 1,
         "%d marked" % len(marked))
    case("A: the >> line IS the requested address",
         bool(marked) and marked[0][1] == FAULT,
         hex(marked[0][1]) if marked else "none")
    txt = marked[0][2] if marked else ""
    case("A: it decodes as `cmp qword ptr [rbx + 0x118], r12`",
         txt.startswith("cmp qword ptr [rbx + 0x118], r12"), txt[:60])
    case("A: the owner header names From @0x141ffd0 +0x11f",
         "SeasonWidgetData::" in out and "@0x141ffd0 +0x11f" in out)
    case("A: [rbx+0x118] is annotated Profile.BattlePass@0x118",
         "Profile.BattlePass@0x118" in txt, txt[-60:])
    case("A: the value-type return caveat is stated (RCX may be a retbuf)",
         "VALUE TYPE" in out and "shift" in out)

    # falsifier 1: --no-fields must lose the NAME but keep the instruction
    rc2, out2 = run(R, key, ["0x%x" % FAULT, "--no-fields"])
    rows2 = insn_lines(out2)
    m2 = [r for r in rows2 if r[0] == ">>"]
    case("A-falsifier: --no-fields prints the same instruction",
         bool(m2) and m2[0][2].startswith("cmp qword ptr [rbx + 0x118], r12"))
    case("A-falsifier: --no-fields prints NO field name (so the name comes "
         "from metadata, not from the mnemonic)",
         "Profile.BattlePass" not in out2)

    # falsifier 2/3: the offset lookup is EXACT, and generics contribute none
    fmap = FieldAtOffset(R)
    prof = R.find_one("EFT.Profile")
    case("A-falsifier: EFT.Profile has BattlePass at exactly 0x118",
         fmap.at(prof, 0x118) == ["Profile.BattlePass"],
         repr(fmap.at(prof, 0x118)))
    case("A-falsifier: and NOTHING at 0x117 (no nearest-offset match)",
         fmap.at(prof, 0x117) == [])
    gen = R.find_one("System.Collections.Generic.List`1")
    case("A-falsifier: an UNINSTANTIATED generic definition contributes ZERO "
         "offsets (its fieldOffsets array is all zeros)",
         fmap.table(gen) == {}, "%d entries" % len(fmap.table(gen)))
    case("A: at least one [reg+disp] prints `?` (the not-derivable path runs)",
         "-> ?" in out)

    # ---- GROUND TRUTH B: the call target is resolved BY NAME ---------------
    rc, out = run(R, key, ["0x%x" % SHOW1])
    site = [r for r in insn_lines(out) if r[1] == SHOW5_SITE]
    case("B: exit 0 disassembling MenuScreen::Show(controller)", rc == 0)
    case("B: the call at 0x1538790 is present", len(site) == 1)
    t = site[0][2] if site else ""
    case("B: it is a `call 0x15387a0`", t.startswith("call 0x15387a0"), t[:40])
    case("B: whose target is named MenuScreen::...Show(...) @0x15387a0",
         "MenuScreen::" in t and "Show" in t and "@0x15387a0" in t, t[-70:])
    case("B: the `this` register is typed from the declaring type",
         "rcx=this: MenuScreen" in out)

    # ---- .text still disassembles, with no owner and no context -----------
    rc, out = run(R, key, ["0x%x" % TEXT_RVA, "--len", "32"])
    rows = insn_lines(out)
    case("C: a .text RVA still disassembles (exit 0)", rc == 0, "rc=%d" % rc)
    case("C: it says no owner start is known", "no owner start is known" in out)
    case("C: and shows NO preceding context -- the first line IS the address",
         bool(rows) and rows[0][1] == TEXT_RVA,
         hex(rows[0][1]) if rows else "no rows")
    case("C: the owner line is INCONCLUSIVE, not an invented name",
         "INCONCLUSIVE" in out)

    # ---- the boundary rule, MEASURED --------------------------------------
    md = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
    starts = set()
    for ins in md.disasm(bytes(R.code_bytes(FROM, 0x200)), FROM):
        starts.add(ins.address)
    case("D: 0x%x (fault-0x20) is NOT an instruction start, so a naive "
         "backwards decode WOULD desynchronise" % NOT_A_START,
         NOT_A_START not in starts)
    rc, out = run(R, key, ["0x%x" % FAULT])
    printed = [a for _m, a, _t in insn_lines(out)]
    case("D: every line printed is a real instruction start of the "
         "owner-start decode", all(a in starts for a in printed),
         "%d lines" % len(printed))
    case("D: decoding is stated to start at the owner start",
         "decoding from the owner start 0x141ffd0" in out)

    # ---- mid-instruction request ------------------------------------------
    rc, out = run(R, key, ["0x%x" % MIDINS])
    case("E: a mid-instruction address SAYS it is mid-instruction",
         "is INSIDE this instruction" in out, out.splitlines()[-1][:70])
    case("E: and still marks the containing instruction",
         any(m == ">>" and a == FAULT for m, a, _t in insn_lines(out)))

    # ---- refusals ---------------------------------------------------------
    rc, out = run(R, key, ["MenuScreen::Show"])
    case("F: an ambiguous name is REFUSED (exit 3) with both addresses",
         rc == 3 and "AMBIGUOUS" in out and "0x15387a0" in out
         and "0x1538760" in out, "rc=%d" % rc)
    rc, out = run(R, key, ["0x%x" % FROM, "--len", "8", "--to", "0x141fff0"])
    case("F: --len with --to is refused (exit 2)", rc == 2, out.strip()[:60])
    rc, out = run(R, key, ["0x7ff8141ffd0"])
    case("F: a live ASLR address with no --base is refused (exit 3)",
         rc == 3 and "--base" in out, "rc=%d" % rc)
    rc, out = run(R, key, [])
    case("F: no argument prints usage (exit 2)", rc == 2)

    # ---- --to and --len actually bound the window -------------------------
    rc, out = run(R, key, ["0x%x" % FROM, "--to", "0x141fff2"])
    rows = insn_lines(out)
    case("G: --to bounds the window (nothing at or past 0x141fff2)",
         bool(rows) and max(a for _m, a, _t in rows) < 0x141FFF2,
         hex(max(a for _m, a, _t in rows)) if rows else "none")
    rc, out = run(R, key, ["0x%x" % FROM, "--len", "16"])
    rows = insn_lines(out)
    case("G: --len bounds the window", bool(rows)
         and max(a for _m, a, _t in rows) < FROM + 16)

    # ---- the WINDOW is named in the output, and --count is honoured -------
    # The defect this guards: `--count 200` was silently ignored, the default
    # 64-byte window was printed, and 16 instructions read as a whole body.
    rc, out = run(R, key, ["0x%x" % FROM, "--count", "5"])
    rows = insn_lines(out)
    case("W: --count N prints exactly N instructions", rc == 0
         and len(rows) == 5, "rc=%d rows=%d" % (rc, len(rows)))
    case("W: the header states the REQUESTED window",
         "window   requested 5 instructions (--count)" in out)
    case("W: the footer states instructions/bytes decoded and the limit",
         any(ln.startswith("window   5 instructions /") and
             "limit reached: YES" in ln for ln in out.splitlines()),
         " | ".join(ln for ln in out.splitlines()
                    if ln.startswith("window   ")))
    case("W: a truncated window SAYS it is not the end of the function",
         "TRUNCATED" in out and "not at the end of the function" in out)
    case("W: -n is the same flag as --count",
         insn_lines(run(R, key, ["0x%x" % FROM, "-n", "5"])[1]) == rows)
    case("W: --insns is the same flag as --count",
         insn_lines(run(R, key, ["0x%x" % FROM, "--insns", "5"])[1]) == rows)
    rc, out = run(R, key, ["0x%x" % FROM, "--count", "5", "--len", "64"])
    case("W: --count with --len is REFUSED (exit 2), never silently one of "
         "them", rc == 2 and "mutually exclusive" in out, out.strip()[:70])
    rc, out = run(R, key, ["0x%x" % FROM, "0x141fff0"])
    case("W: a stray extra positional is REFUSED (exit 2) rather than "
         "ignored", rc == 2 and "positional" in out, out.strip()[:70])
    # FALSIFIER for the window line: the DEFAULT run must say it is a default,
    # so no run can present a default-sized window as a deliberate one.
    rc, out = run(R, key, ["0x%x" % FAULT])
    case("W-falsifier: a run with NO window flag says so in the header",
         "DEFAULT -- no window flag given" in out)
    case("W-falsifier: and still prints a limit verdict",
         any("limit reached:" in ln for ln in out.splitlines()))

    # ---- capstone absent: the NEGATIVE CONTROL for "it is importable" -----
    saved = sys.modules.get("capstone")
    sys.modules["capstone"] = None      # makes `import capstone` raise
    try:
        rc, out = run(R, key, ["0x%x" % FAULT])
    finally:
        if saved is None:
            del sys.modules["capstone"]
        else:
            sys.modules["capstone"] = saved
    case("H: with capstone unimportable the verb REFUSES (exit 4)", rc == 4,
         "rc=%d" % rc)
    case("H: and prints the install hint", "pip install capstone" in out)
    case("H: and prints NO instruction lines", insn_lines(out) == [],
         "%d rows" % len(insn_lines(out)))
    # and prove the guard is not permanently on
    rc, _out = run(R, key, ["0x%x" % FAULT])
    case("H: capstone is importable again afterwards (the control was the "
         "patch, not the environment)", rc == 0)

    print("\n%d case(s) FAILED: %s" % (len(_fails), ", ".join(_fails))
          if _fails else "\nALL CASES PASSED")
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
