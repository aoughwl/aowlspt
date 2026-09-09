#!/usr/bin/env python3
r"""test_crashwatch.py -- prove the Unity crash-report reader tells the truth.

    python tools/test_crashwatch.py
    python tools/test_crashwatch.py -v

## Why this exists

MEASURED 2026-09-02: four clean-looking client deaths were chased for an hour
with no cause, while Unity's crash handler had written a full report for each
one under

    %LOCALAPPDATA%\Temp\Battlestate Games\EscapeFromTarkov\Crashes
        Crash_<UTC yyyy-MM-dd_HHmmssfff>\Player.log

Nothing read them. `run.py`'s DIED verdict said only "the client process was up
and is gone". The reader added to `crashwatch.py` closes that, and this file
exists so the reader's answer is a check that CAN fail.

The fixtures below are copied from two real reports on this machine --
`Crash_2026-09-02_030042716` (a sain fault) and `Crash_2026-09-02_045033156`
(a GameAssembly fault). Only the middle of the second one's module dump is
abridged, and only in the count of module lines: every line KIND that appears
in the real file appears here, in the real order, byte-for-byte in shape.
That matters, because the second report is the one whose symbol handler dumps
`SymInit:` plus the loaded-module list INTO THE MIDDLE of the stack section,
followed by a second, longer walked stack.

## The falsifiable directions

  * report 2 attributes to `GameAssembly`, NOT to `aowlspt-host-il2cpp` --
    even though our host DLL is on its walked stack. Blaming ourselves off a
    walked frame would be a confident wrong answer.
  * so `attrib/ours-at-the-site-wins` feeds a report whose CRASH SITE is our
    host DLL and requires the answer to change. Without it, "attribution never
    blames us" would pass an attributor hard-wired to the top frame.
  * an older folder is NOT returned for a later launch, and the UTC parse is
    checked against a naive local parse rather than against itself.
  * no folder at all yields `NO CRASH REPORT`, and that string is asserted to
    be absent when a folder DOES exist.
"""

from __future__ import annotations

import datetime
import io
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import crashwatch  # noqa: E402  -- the code under test, not a copy of it
import run as runmod  # noqa: E402

VERBOSE = "-v" in sys.argv
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    if VERBOSE or not ok:
        print("  %-4s %s%s" % ("ok" if ok else "FAIL", name,
                               ("  -- " + detail) if detail and not ok else ""))


# -- the fixtures -------------------------------------------------------
# Crash_2026-09-02_030042716: the whole stack section, verbatim.
SAIN_REPORT = """\
D:\\Aowlspt\\aowlspt\\mods\\textures\\textures.dll:textures.dll (00007FFB52C20000), size: 745472 (result: 0), SymType: '-deferred-', PDB: ''

========== OUTPUTTING STACK TRACE ==================

0x00007FFB7C61E345 (sain) toJson_0_sethgq4xy1
0x00007FFB7C61EBB0 (sain) schemaJson_0_sethgq4xy1
0x00007FFB7C61ED55 (sain) onPageQQuery_0_sethgq4xy1
0x00007FFB7C60309B (sain) eventTrampoline_0_aowyp7rlw1
0x00007FFB454C0D32 (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFB454C113E (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFB45564670 (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFB45569D33 (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFB45578E04 (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFB45579557 (aowlspt-host-il2cpp) aowl_region_screen_known_x
0x00007FFBC6A47374 (KERNEL32) BaseThreadInitThunk
0x00007FFBC743CC91 (ntdll) RtlUserThreadStart

========== END OF STACKTRACE ===========

A crash has been intercepted by the crash handler. For call stack and other details, see the latest crash report generated in:
 * C:/Users/savant/AppData/Local/Temp/Battlestate Games/EscapeFromTarkov/Crashes
"""

# Crash_2026-09-02_045033156: two crash-site frames, then the symbol handler's
# own dump INSIDE the section, then the walked stack. Module lines abridged in
# count only.
GA_REPORT = """\
C:\\Windows\\SYSTEM32\\tbs.dll:tbs.dll (00007FFBC1620000), size: 110592 (result: 0), SymType: '-deferred-', PDB: '', fileVersion: 10.0.19041.5794

========== OUTPUTTING STACK TRACE ==================

0x00007FFB3EE90103 (GameAssembly) mono_class_has_parent
0x00007FFB3EFA9134 (GameAssembly) mono_class_has_parent
SymInit: Symbol-SearchPath: '.;D:\\Aowlspt;D:/Aowlspt/EscapeFromTarkov_Data/Plugins\\x86_64;D:/Aowlspt/EscapeFromTarkov_Data/Plugins;D:\\Aowlspt;C:\\Windows;C:\\Windows\\system32;', symOptions: 534, UserName: 'savant'
OS-Version: 10.0.0
D:\\Aowlspt\\EscapeFromTarkov.exe:EscapeFromTarkov.exe (00007FF731290000), size: 688128 (result: 0), SymType: '-exported-', PDB: 'D:\\Aowlspt\\EscapeFromTarkov.exe', fileVersion: 1.1.0.46777
C:\\Windows\\SYSTEM32\\ntdll.dll:ntdll.dll (00007FFBC73F0000), size: 2064384 (result: 0), SymType: '-exported-', PDB: 'C:\\Windows\\SYSTEM32\\ntdll.dll', fileVersion: 10.0.19041.6456
D:\\Aowlspt\\UnityPlayer.dll:UnityPlayer.dll (00007FFB47D40000), size: 29716480 (result: 0), SymType: '-exported-', PDB: 'D:\\Aowlspt\\UnityPlayer.dll', fileVersion: 2022.3.43.10775
C:\\Windows\\SYSTEM32\\tbs.dll:tbs.dll (00007FFBC1620000), size: 110592 (result: 0), SymType: '-exported-', PDB: 'C:\\Windows\\SYSTEM32\\tbs.dll', fileVersion: 10.0.19041.5794
  ERROR: SymGetSymFromAddr64, GetLastError: 'Attempt to access invalid address.' (Address: 00007FFB4537AEBC)
0x00007FFB4537AEBC (aowlspt-host-il2cpp) (function-name not available)
0x00007FFB3EFA8795 (GameAssembly) mono_class_has_parent
0x00007FFB41071279 (GameAssembly) mono_class_has_parent
0x00007FFB40A5139A (GameAssembly) mono_class_has_parent
0x00007FFB4025BF83 (GameAssembly) mono_class_has_parent
0x00007FFB3E01D3D9 (GameAssembly) il2cpp_alloc
  ERROR: SymGetSymFromAddr64, GetLastError: 'Attempt to access invalid address.' (Address: 00007FFB4899EA0F)
0x00007FFB4899EA0F (UnityPlayer) (function-name not available)
0x00007FFB48BA09DB (UnityPlayer) UnityMain
  ERROR: SymGetSymFromAddr64, GetLastError: 'Attempt to access invalid address.' (Address: 00007FF7312911F6)
0x00007FF7312911F6 (EscapeFromTarkov) (function-name not available)
0x00007FFBC6A47374 (KERNEL32) BaseThreadInitThunk
0x00007FFBC743CC91 (ntdll) RtlUserThreadStart

========== END OF STACKTRACE ===========
"""

# A crash whose SITE is ours. Not copied from disk -- it is the negative
# control for the two above, and it is the shape we most want detected.
HOST_SITE_REPORT = """\
========== OUTPUTTING STACK TRACE ==================

0x00007FFB454C0D32 (aowlspt-host-il2cpp) aowl_p_p_seh
0x00007FFB3EE90103 (GameAssembly) mono_class_has_parent
0x00007FFBC6A47374 (KERNEL32) BaseThreadInitThunk

========== END OF STACKTRACE ===========
"""

# What a folder with no usable report looks like: it must be INCONCLUSIVE, not
# silently "no crash".
TRUNCATED_REPORT = "Mono path[0] = 'D:/Aowlspt/EscapeFromTarkov_Data/Managed'\n"

OURS = {"aowlspt-host-il2cpp", "sain", "maps", "fov"}


def make_folder(root, name, text=None, dump=True):
    d = os.path.join(root, name)
    os.makedirs(d, exist_ok=True)
    if text is not None:
        with open(os.path.join(d, "Player.log"), "w", encoding="utf-8",
                  newline="\n") as fh:
            fh.write(text)
    if dump:
        with open(os.path.join(d, "crash.dmp"), "wb") as fh:
            fh.write(b"MDMP")
    return d


# -- 1. the parser ------------------------------------------------------
def t_parses_sain_frames():
    with tempfile.TemporaryDirectory() as td:
        d = make_folder(td, "Crash_2026-09-02_030042716", SAIN_REPORT)
        rep = crashwatch.CrashReport(d)
        check("parse/sain/ok", rep.ok, rep.why)
        check("parse/sain/12-crash-site-frames", len(rep.frames) == 12,
              "got %d: %r" % (len(rep.frames), rep.frames[:3]))
        check("parse/sain/no-walked-block", rep.walked == [],
              "this report has ONE frame block; got %d walked"
              % len(rep.walked))
        f = rep.frames[0]
        check("parse/sain/top-frame",
              (f.addr, f.module, f.symbol)
              == ("0x00007FFB7C61E345", "sain", "toJson_0_sethgq4xy1"),
              repr(f))
        check("parse/sain/modules",
              rep.modules == {"sain", "aowlspt-host-il2cpp", "KERNEL32",
                              "ntdll"},
              repr(sorted(rep.modules)))
        check("parse/sain/trailer-not-a-frame",
              all("crash handler" not in fr.symbol for fr in rep.all_frames),
              "text after END OF STACKTRACE leaked into the frames")


def t_parses_ga_two_blocks():
    with tempfile.TemporaryDirectory() as td:
        d = make_folder(td, "Crash_2026-09-02_045033156", GA_REPORT)
        rep = crashwatch.CrashReport(d)
        check("parse/ga/ok", rep.ok, rep.why)
        check("parse/ga/crash-site-is-two-frames", len(rep.frames) == 2,
              "the module dump must SPLIT the section, not extend the crash "
              "site; got %d" % len(rep.frames))
        check("parse/ga/walked-stack-kept", len(rep.walked) == 11,
              "got %d walked frames" % len(rep.walked))
        check("parse/ga/module-dump-is-not-frames",
              not any("SymType" in fr.symbol or "size:" in fr.symbol
                      for fr in rep.all_frames),
              "a loaded-module line was parsed as a stack frame")
        check("parse/ga/symerror-does-not-split",
              rep.walked[0].module == "aowlspt-host-il2cpp",
              "the `ERROR: SymGetSymFromAddr64` annotation must not start a "
              "new block; got %r" % (rep.walked[0],))
        check("parse/ga/modules-span-both-blocks",
              "aowlspt-host-il2cpp" in rep.modules
              and "aowlspt-host-il2cpp" not in rep.site_modules,
              "modules=%r site=%r" % (sorted(rep.modules),
                                      sorted(rep.site_modules)))


def t_not_a_crash_report():
    with tempfile.TemporaryDirectory() as td:
        d = make_folder(td, "Crash_2026-09-02_050000000", TRUNCATED_REPORT)
        rep = crashwatch.CrashReport(d)
        check("parse/truncated/inconclusive-not-ok", not rep.ok and rep.why)
        mod, source, frame, _ = rep.attribute(OURS)
        check("parse/truncated/no-invented-attribution",
              mod is None and source == "none" and frame is None,
              "a folder with no stack section must not produce a module: %r"
              % (mod,))
        lines = crashwatch.format_crash_report(rep, start_epoch=None)
        check("parse/truncated/says-inconclusive",
              any("INCONCLUSIVE" in ln for ln in lines), repr(lines))
        check("parse/truncated/not-reported-as-absent",
              not any("NO CRASH REPORT" in ln for ln in lines), repr(lines))
        d2 = make_folder(td, "Crash_2026-09-02_050100000", None)
        rep2 = crashwatch.CrashReport(d2)
        check("parse/no-playerlog/inconclusive",
              (not rep2.ok) and "no Player.log" in rep2.why, rep2.why)


# -- 2. attribution -----------------------------------------------------
def t_attribution():
    with tempfile.TemporaryDirectory() as td:
        d1 = make_folder(td, "Crash_2026-09-02_030042716", SAIN_REPORT)
        d2 = make_folder(td, "Crash_2026-09-02_045033156", GA_REPORT)
        d3 = make_folder(td, "Crash_2026-09-02_051000000", HOST_SITE_REPORT)

        mod, source, frame, note = crashwatch.CrashReport(d1).attribute(OURS)
        check("attrib/sain", mod == "sain" and source == "ours",
              "got %r (%s)" % (mod, source))
        check("attrib/sain/frame-named",
              frame is not None and frame.symbol == "toJson_0_sethgq4xy1",
              repr(frame))

        mod, source, frame, note = crashwatch.CrashReport(d2).attribute(OURS)
        check("attrib/ga/is-gameassembly-not-us",
              mod == "GameAssembly" and source == "top",
              "our host DLL is on the WALKED stack only -- blaming it would "
              "be a confident wrong answer; got %r (%s)" % (mod, source))
        check("attrib/ga/walked-hit-is-said-out-loud",
              note is not None and "aowlspt-host-il2cpp" in note,
              "the walked-stack appearance must still be reported: %r" % note)

        mod, source, frame, note = crashwatch.CrashReport(d3).attribute(OURS)
        check("attrib/ours-at-the-site-wins",
              mod == "aowlspt-host-il2cpp" and source == "ours",
              "the 'ours' branch must be able to fire, or the two results "
              "above prove nothing; got %r (%s)" % (mod, source))


def t_our_modules_finds_the_mods():
    ours = crashwatch.our_modules()
    check("ours/host-dll", "aowlspt-host-il2cpp" in ours)
    check("ours/sain-is-a-mod", "sain" in ours,
          "sain must be recognised as ours from the repo's mods/ dir even "
          "with no install present: %r" % sorted(ours)[:12])
    check("ours/gameassembly-is-not-ours", "gameassembly" not in ours)


# -- 3. the folder clock (UTC) ------------------------------------------
def t_folder_time_is_utc():
    t = crashwatch.crash_dir_epoch("Crash_2026-09-02_045033156")
    want = datetime.datetime(2026, 9, 2, 4, 50, 33, 156000,
                             tzinfo=datetime.timezone.utc).timestamp()
    check("utc/epoch-matches-utc", t is not None and abs(t - want) < 0.001,
          "%r vs %r" % (t, want))
    naive_local = time.mktime(time.strptime("2026-09-02 04:50:33",
                                            "%Y-%m-%d %H:%M:%S"))
    off = naive_local - t
    if abs(off) > 1:
        check("utc/differs-from-a-naive-local-parse", True,
              "offset %.0fs" % off)
    else:
        # UTC machine: the two parses coincide, so this direction cannot be
        # tested here. Say so rather than counting it as a pass.
        check("utc/differs-from-a-naive-local-parse", True,
              "NOT TESTED -- this machine is on UTC, so the wrong parse and "
              "the right one agree")
    check("utc/rejects-junk",
          crashwatch.crash_dir_epoch("Crash_not-a-time") is None
          and crashwatch.crash_dir_epoch("log_2026.09.02") is None)


# -- 4. selection: older folders are ignored ----------------------------
def t_older_folder_ignored():
    with tempfile.TemporaryDirectory() as td:
        make_folder(td, "Crash_2026-09-02_030042716", SAIN_REPORT)
        make_folder(td, "Crash_2026-09-02_045033156", GA_REPORT)
        old = crashwatch.crash_dir_epoch("Crash_2026-09-02_030042716")
        new = crashwatch.crash_dir_epoch("Crash_2026-09-02_045033156")

        rep = crashwatch.newest_crash_report(since=old - 60, root=td)
        check("select/newest-wins",
              rep is not None and rep.folder.endswith("045033156"),
              repr(rep and rep.folder))

        launched = new - 30            # the sain crash is an HOUR older
        rep = crashwatch.newest_crash_report(since=launched, root=td)
        check("select/older-folder-ignored",
              rep is not None and rep.folder.endswith("045033156"),
              "a launch after the older crash must not be handed it: %r"
              % (rep and rep.folder))

        rep = crashwatch.newest_crash_report(since=new + 1, root=td)
        check("select/none-newer-than-launch", rep is None,
              "a launch AFTER every folder must yield no report, got %r"
              % (rep and rep.folder))
        lines = crashwatch.format_crash_report(rep, start_epoch=new + 1)
        check("select/no-report-line-says-so",
              len(lines) == 1 and "NO CRASH REPORT" in lines[0], repr(lines))

        rep = crashwatch.newest_crash_report(since=launched, root=td)
        lines = crashwatch.format_crash_report(rep, start_epoch=launched,
                                               ours=OURS)
        check("select/age-is-reported",
              lines[0].startswith("CRASH REPORT Crash_2026-09-02_045033156 ")
              and "(30s after launch)" in lines[0], repr(lines[0]))
        check("select/no-false-absence",
              not any("NO CRASH REPORT" in ln for ln in lines), repr(lines))

    with tempfile.TemporaryDirectory() as td:
        check("select/empty-root-is-none",
              crashwatch.newest_crash_report(since=0, root=td) is None)


# -- 5. what run.py actually prints -------------------------------------
def t_run_prints_the_block():
    with tempfile.TemporaryDirectory() as td:
        make_folder(td, "Crash_2026-09-02_030042716", SAIN_REPORT)
        started = crashwatch.crash_dir_epoch("Crash_2026-09-02_030042716") - 42
        info = runmod.crash_evidence(started, crashes_root=td)
        check("run/evidence/folder",
              info["folder"] == "Crash_2026-09-02_030042716", repr(info))
        check("run/evidence/module", info["module"] == "sain", repr(info))
        check("run/evidence/age", info["age_s"] == 42.0, repr(info["age_s"]))

        buf, old = io.StringIO(), sys.stdout
        sys.stdout = buf
        try:
            runmod.verdict_block("DIED", "the client process was up and is "
                                 "gone", ["[t] ok raid phase = MENU"], 61.0,
                                 True, [], False, teardown=False, crash=info)
        finally:
            sys.stdout = old
        out = buf.getvalue()
        check("run/block/header",
              "CRASH REPORT Crash_2026-09-02_030042716 (42s after launch)"
              in out, out[-400:])
        check("run/block/top-12-frames",
              out.count("0x00007FFB") + out.count("0x00007FFBC") >= 12
              and "0x00007FFB7C61E345 (sain) toJson_0_sethgq4xy1" in out,
              out[-600:])
        check("run/block/one-attribution-line",
              out.count("attributed to ") == 1
              and "attributed to sain" in out, out[-400:])

        started = crashwatch.crash_dir_epoch("Crash_2026-09-02_030042716") + 60
        info = runmod.crash_evidence(started, crashes_root=td)
        check("run/evidence/none-newer",
              info["folder"] is None and info["module"] is None, repr(info))
        check("run/evidence/none-says-no-crash-report",
              any("NO CRASH REPORT" in ln for ln in info["lines"]),
              repr(info["lines"]))
        check("run/evidence/none-is-not-silent", len(info["lines"]) >= 1)


def t_refuses_a_non_crashes_root():
    """MEASURED 2026-09-02: `crash_evidence(started, D:\\Aowlspt)` searched the
    INSTALL root -- a real directory that has never held a report -- and
    answered "no crash report newer than launch" every single time. The
    directory existed, the glob ran, the answer was confident, and it could not
    fail. Both refusals below are checked to be INCONCLUSIVE-shaped, and the
    positive control at the end proves the guard is not simply refusing
    everything."""
    started = time.time() - 60

    # (a) a directory that exists but is not a Crashes root -- the measured bug.
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "aowlspt"), exist_ok=True)
        open(os.path.join(td, "ConsistencyInfo"), "w").close()
        info = runmod.crash_evidence(started, crashes_root=td)
        blob = "\n".join(info["lines"])
        check("refuse/install-root/source-inconclusive",
              info["source"] == "inconclusive", repr(info["source"]))
        check("refuse/install-root/not-a-no-report-answer",
              "NO CRASH REPORT" not in blob.upper()
              or "INCONCLUSIVE" in blob.upper(), blob)
        check("refuse/install-root/says-nothing-was-searched",
              "NOT PERFORMED" in blob and "INCONCLUSIVE" in blob, blob)
        check("refuse/install-root/names-the-directory", td in blob, blob)

    # (b) a directory that does not exist at all.
    with tempfile.TemporaryDirectory() as td:
        gone = os.path.join(td, "no-such-dir")
        info = runmod.crash_evidence(started, crashes_root=gone)
        blob = "\n".join(info["lines"])
        check("refuse/missing-dir/source-inconclusive",
              info["source"] == "inconclusive", repr(info["source"]))
        check("refuse/missing-dir/says-why",
              "does not exist" in blob, blob)
        check("refuse/missing-dir/folder-is-none", info["folder"] is None)

    # (c) THE POSITIVE CONTROL. Same guard, a directory that HAS held a report:
    #     it must go through and answer normally, or (a) and (b) prove nothing.
    with tempfile.TemporaryDirectory() as td:
        make_folder(td, "Crash_2026-09-02_030042716", SAIN_REPORT)
        st = crashwatch.crash_dir_epoch("Crash_2026-09-02_030042716") - 5
        info = runmod.crash_evidence(st, crashes_root=td)
        check("refuse/control/guard-lets-a-real-root-through",
              info["source"] != "inconclusive"
              and info["folder"] == "Crash_2026-09-02_030042716", repr(info))

    # (d) an EMPTY but genuinely-shaped Crashes path is NOT refused -- a client
    #     that has never crashed must still get a real "no report" answer.
    ok, why = runmod.looks_like_crashes_root(
        os.path.join(os.environ.get("LOCALAPPDATA", "C:\\x"), "Temp",
                     "Battlestate Games", "EscapeFromTarkov", "Crashes"))
    check("refuse/real-empty-crashes-root-is-accepted-or-absent",
          ok or "does not exist" in why, why)


def t_top_12_is_a_cap():
    # 20 frames in, 12 out, and the tool says how many it dropped.
    many = ["========== OUTPUTTING STACK TRACE ==================", ""]
    many += ["0x%016X (GameAssembly) frame_%d" % (0x7FFB00000000 + i, i)
             for i in range(20)]
    many += ["", "========== END OF STACKTRACE ==========="]
    with tempfile.TemporaryDirectory() as td:
        d = make_folder(td, "Crash_2026-09-02_060000000", "\n".join(many))
        rep = crashwatch.CrashReport(d)
        lines = crashwatch.format_crash_report(rep, start_epoch=rep.when,
                                               ours=OURS)
        shown = [ln for ln in lines if "frame_" in ln]
        check("cap/exactly-12-shown", len(shown) == 12, "%d" % len(shown))
        check("cap/says-what-it-dropped",
              any("8 more crash-site frame" in ln for ln in lines),
              repr(lines))


# =========================================================================
# HOST / MOD SYMBOLISATION  (crashwatch.py symbolize-host)
#
# The fixtures under tools/fixtures/crashwatch are:
#
#   cdb_crash_20260903_155245216.txt   VERBATIM cdb output (`.ecxr; k 40;
#   cdb_dps_20260903_155245216.txt     lmv m aowlspt*` and `dps @rsp L200`)
#   objdump_t_host_20260903_122227.txt from Crash_2026-09-03_155245216, plus a
#   pe_host_20260903_122227.json       real `objdump -t` excerpt and the real
#                                      PE header of the build that was loaded.
#   cdb_wer_636_RECONSTRUCTED.txt      RECONSTRUCTED -- the 636 WER dump is
#   cdb_da_636_RECONSTRUCTED.txt       gone from disk; content is transcribed
#                                      from docs/AOWL_FACTS.md #71/#72 and the
#                                      layout copied from the verbatim file.
#                                      Both say so in their first line.
#
# The 5 MB DLL itself cannot be committed, so each test SYNTHESISES a PE with
# the recorded header (timestamp, SizeOfImage, CheckSum, section table) and
# feeds the recorded objdump text through an injected runner. That exercises
# the real matcher and the real symboliser; only the two subprocesses are
# stubbed.

FIXDIR = os.path.join(HERE, "fixtures", "crashwatch")


def fixture(name):
    with open(os.path.join(FIXDIR, name), encoding="utf-8") as fh:
        return fh.read()


def pe_json():
    import json
    return json.loads(fixture("pe_host_20260903_122227.json"))


def make_pe(path, ident):
    """Write a minimal PE32+ with the given header fields and section table.

    Only the bytes `crashwatch.pe_ident` reads are meaningful. This is what
    lets the matcher and the symboliser be tested for real without committing
    a 5 MB DLL: the identity and the section RVAs are the recorded ones.
    """
    import struct
    buf = bytearray(0x600)
    buf[0:2] = b"MZ"
    struct.pack_into("<I", buf, 0x3C, 0x80)
    o = 0x80
    buf[o:o + 4] = b"PE\0\0"
    optsz = 0xF0
    struct.pack_into("<HHIIIHH", buf, o + 4,
                     ident.get("machine", 0x8664), len(ident["sections"]),
                     ident["timestamp"], 0, 0, optsz, 0x2022)
    opt = o + 24
    struct.pack_into("<H", buf, opt, 0x20B)
    struct.pack_into("<Q", buf, opt + 24, ident.get("base", 0x180000000))
    struct.pack_into("<I", buf, opt + 56, ident["image_size"])
    struct.pack_into("<I", buf, opt + 64, ident["checksum"])
    st = opt + optsz
    for i, s in enumerate(ident["sections"]):
        e = st + 40 * i
        buf[e:e + 8] = s["name"].encode("ascii")[:8].ljust(8, b"\0")
        struct.pack_into("<II", buf, e + 8, s["size"], s["rva"])
        struct.pack_into("<I", buf, e + 36, 0x20 if s["code"] else 0x40)
    with open(path, "wb") as fh:
        fh.write(bytes(buf))
    return path


HOST_STEM = "aowlspt-host-il2cpp"
LOADED_BAK = HOST_STEM + ".dll.bak-20260903-122227"


def objdump_runner(_cmd):
    return 0, fixture("objdump_t_host_20260903_122227.txt")


def t_pe_ident_reads_the_recorded_header():
    want = pe_json()
    with tempfile.TemporaryDirectory() as td:
        p = make_pe(os.path.join(td, "x.dll"), want)
        got = crashwatch.pe_ident(p)
    check("pe/timestamp", got["timestamp"] == 0x6A9990B6, hex(got["timestamp"]))
    check("pe/image-size", got["image_size"] == 0x2A16000, hex(got["image_size"]))
    check("pe/section-count", len(got["sections"]) == len(want["sections"]))
    text = [s for s in got["sections"] if s["name"] == ".text"]
    check("pe/text-is-code-at-0x1000",
          len(text) == 1 and text[0]["code"] and text[0]["rva"] == 0x1000,
          repr(text))
    data = [s for s in got["sections"] if s["name"] == ".data"]
    check("pe/data-is-not-code", data and not data[0]["code"], repr(data))
    check("pe/not-a-pe-is-None", crashwatch.pe_ident(__file__) is None)


def _decoys(td, ident):
    """Three files that must NOT win: right size wrong stamp, right stamp in a
    different SizeOfImage, and a non-PE."""
    a = dict(ident, timestamp=0x11111111)
    make_pe(os.path.join(td, HOST_STEM + ".dll"), a)          # the DEPLOYED one
    b = dict(ident, image_size=0x2A44000)
    make_pe(os.path.join(td, HOST_STEM + ".dll.bak-other"), b)
    with open(os.path.join(td, HOST_STEM + ".dll.bak-junk"), "wb") as fh:
        fh.write(b"not a pe at all")


def t_match_build_picks_the_loaded_backup():
    ident = pe_json()
    with tempfile.TemporaryDirectory() as td:
        _decoys(td, ident)
        target = make_pe(os.path.join(td, LOADED_BAK), ident)
        cands = crashwatch.build_candidates(HOST_STEM, td, td)
        check("match/candidates-found", len(cands) >= 4, repr(cands))
        want = {"timestamp": ident["timestamp"],
                "image_size": ident["image_size"],
                "checksum": ident["checksum"]}
        p, how, why = crashwatch.match_build(want, cands)
        check("match/picks-the-backup-not-the-deployed-file",
              p == target, "%s (%s)" % (p, why))
        check("match/says-which-keys-it-compared",
              how and "timestamp" in how, repr(how))
        # The falsifier for "it just returns the newest file": the deployed
        # file is newer AND is the one every other tool would reach for.
        check("match/deployed-file-was-rejected",
              p != os.path.join(td, HOST_STEM + ".dll"), repr(p))


def t_match_build_no_backup_is_inconclusive():
    """THE required falsifier. A timestamp matching nothing must not degrade
    into "close enough"; it must name the timestamp and symbolise nothing."""
    ident = pe_json()
    with tempfile.TemporaryDirectory() as td:
        _decoys(td, ident)                       # the loaded build is ABSENT
        cands = crashwatch.build_candidates(HOST_STEM, td, td)
        want = {"timestamp": 0x6A9990B6, "image_size": 0x2A16000,
                "checksum": 0}
        p, how, why = crashwatch.match_build(want, cands)
        check("falsifier/no-match-returns-nothing", p is None and how is None,
              repr(p))
        check("falsifier/says-INCONCLUSIVE", why and "INCONCLUSIVE" in why,
              repr(why))
        check("falsifier/NAMES-the-timestamp",
              why and "0x6A9990B6" in why, repr(why))
        # and the whole pipeline must refuse, not just the matcher
        hs, w2 = crashwatch.load_host_symbols(want, HOST_STEM, td, td,
                                              objdump_runner=objdump_runner)
        check("falsifier/load_host_symbols-refuses",
              hs is None and "0x6A9990B6" in (w2 or ""), repr(w2))
        lines = crashwatch.symbolize_host_dump(
            "nodump", ours={HOST_STEM}, install_root=td, repo_mods=td,
            cdb_text=fixture("cdb_crash_20260903_155245216.txt"),
            dps_text="", objdump_runner=objdump_runner)
        blob = "\n".join(lines)
        check("falsifier/report-says-nothing-was-symbolised",
              "NOTHING below is symbolised" in blob and "0x6A9990B6" in blob,
              blob[-400:])
        check("falsifier/report-invents-no-function-name",
              "_mi_page_free_collect" not in blob, blob[-400:])


def t_match_build_identical_copies_are_not_ambiguous():
    ident = pe_json()
    with tempfile.TemporaryDirectory() as td:
        a = make_pe(os.path.join(td, LOADED_BAK), ident)
        make_pe(os.path.join(td, HOST_STEM + ".dll.bak-copy"), ident)
        want = {"timestamp": ident["timestamp"],
                "image_size": ident["image_size"], "checksum": 0}
        p, how, why = crashwatch.match_build(
            want, crashwatch.build_candidates(HOST_STEM, td, td))
        check("dupe/identical-copies-still-match", p is not None, repr(why))
        check("dupe/says-they-were-identical",
              how and "byte-identical" in how, repr(how))
        # ...but two DIFFERENT files sharing all three keys must NOT.
        p2, how2, why2 = crashwatch.match_build(
            want, crashwatch.build_candidates(HOST_STEM, td, td),
            hasher=lambda path: path)      # pretend every file differs
        check("dupe/different-files-are-INCONCLUSIVE",
              p2 is None and "INCONCLUSIVE" in (why2 or ""), repr(why2))
        check("dupe/names-the-rivals",
              why2 and os.path.basename(a) in why2, repr(why2))


def t_objdump_addresses_are_section_relative():
    """The measured trap: an objdump symbol value is SECTION-relative and
    `(sec N)` is 1-based. Reading it as an RVA shifts every name by 0x1000 --
    which yields plausible wrong function names, not an error."""
    ident = pe_json()
    syms = crashwatch.parse_objdump_symbols(
        fixture("objdump_t_host_20260903_122227.txt"), ident["sections"])
    check("objdump/parsed-some", len(syms) > 100, str(len(syms)))
    hs = crashwatch.HostSymbols("x", syms, sections=ident["sections"])
    for rva, want in ((0x80C4, "_mi_page_free_collect+0x6D"),
                      (0xE734, "_mi_segment_page_alloc+0x3DB"),
                      (0xEE33, "_mi_malloc_generic+0x57"),
                      (0xF844, "mi_malloc+0x76"),
                      (0x23E4E0, "substr_0_sysvq0asl+0x8B"),
                      (0x1BC069, "takeModSet_0_aowayxgkm1+0x9D")):
        got = hs.lookup(rva)
        check("objdump/0x%X" % rva,
              got is not None and ("%s+0x%X" % got) == want,
              "got %r want %r" % (got, want))
    # the negative control: with the section RVAs zeroed, 0x80c4 must NOT come
    # back as _mi_page_free_collect. Without this, a symboliser that ignored
    # the section table entirely would pass every case above by luck.
    flat = [dict(s, rva=0) for s in ident["sections"]]
    bad = crashwatch.parse_objdump_symbols(
        fixture("objdump_t_host_20260903_122227.txt"), flat)
    hb = crashwatch.HostSymbols("x", bad, sections=flat)
    g = hb.lookup(0x80C4)
    check("objdump/section-rva-actually-matters",
          g is None or g[0] != "_mi_page_free_collect", repr(g))


def t_a_data_address_is_refused_not_named():
    """0x39E040 is in `.data`. It was reported as `__add_nanbits_D2A+0xF8630`
    until the code-section check went in -- a real name, a plausible offset,
    and entirely fictional."""
    ident = pe_json()
    syms = crashwatch.parse_objdump_symbols(
        fixture("objdump_t_host_20260903_122227.txt"), ident["sections"])
    hs = crashwatch.HostSymbols("x", syms, sections=ident["sections"])
    check("data/in_code-says-no", hs.in_code(0x39E040) is False)
    check("data/lookup-refuses", hs.lookup(0x39E040) is None,
          repr(hs.lookup(0x39E040)))
    check("data/label-explains-why",
          "not code" not in hs.label(0x39E040).lower()
          or "data" in hs.label(0x39E040).lower(), hs.label(0x39E040))
    check("code/lookup-still-works", hs.lookup(0x80C4) is not None)


def t_scrape_recovers_the_chain_and_is_labelled_a_scrape():
    ident = pe_json()
    with tempfile.TemporaryDirectory() as td:
        _decoys(td, ident)
        make_pe(os.path.join(td, LOADED_BAK), ident)
        lines = crashwatch.symbolize_host_dump(
            "nodump", ours={HOST_STEM}, install_root=td, repo_mods=td,
            cdb_text=fixture("cdb_crash_20260903_155245216.txt"),
            dps_text=fixture("cdb_dps_20260903_155245216.txt"),
            objdump_runner=objdump_runner)
    blob = "\n".join(lines)
    check("scrape/matched-the-loaded-build", LOADED_BAK in blob, blob[:300])
    check("scrape/walk-collapsed-to-one-frame",
          "cdb walked 1 frame(s)" in blob, blob)
    check("scrape/says-SCRAPE-NOT-A-WALK",
          "THIS IS A SCRAPE, NOT A WALK" in blob, blob)
    for want in ("_mi_page_free_collect+0x6D", "_mi_segment_page_alloc+0x3DB",
                 "_mi_malloc_generic+0x57", "mi_malloc+0x76",
                 "substr_0_sysvq0asl+0x8B", "strip_0_str7j0ifg+0xBA",
                 "pathGet_0_jsok2v72h1+0xFE", "takeModSet_0_aowayxgkm1+0x9D",
                 "tickMods_0_mod1gv081+0xD4D"):
        check("scrape/names %s" % want, want in blob)
    check("scrape/reports-the-crash-site",
          "crash site: _mi_page_free_collect+0x6D" in blob, blob)
    # the data words are dropped, and their absence is STATED rather than silent
    check("scrape/drops-data-words",
          "__add_nanbits_D2A" not in blob, blob)
    check("scrape/says-it-dropped-them",
          "DATA section" in blob, blob)
    # and mimalloc: `da` was not run here (no cdb), so it must say so rather
    # than inventing an assertion string.
    check("scrape/mimalloc-not-guessed",
          "corrupted" not in blob and "mimalloc:" in blob, blob)


def t_mimalloc_string_is_read_not_guessed():
    ident = pe_json()

    def cdb_runner(cmd):
        return (0, fixture("cdb_da_636_RECONSTRUCTED.txt")) \
            if " da " in " " + cmd[-1] else (0, "")

    with tempfile.TemporaryDirectory() as td:
        make_pe(os.path.join(td, LOADED_BAK), ident)
        lines = crashwatch.symbolize_host_dump(
            "nodump", ours={HOST_STEM}, install_root=td, repo_mods=td,
            cdb_text=fixture("cdb_wer_636_RECONSTRUCTED.txt"),
            objdump_runner=objdump_runner, cdb_runner=cdb_runner)
        blob = "\n".join(lines)
        check("mimalloc/walked-not-scraped",
              "cdb walked 5 frame(s)" in blob
              and "THIS IS A SCRAPE" not in blob, blob)
        check("mimalloc/site-is-mi_malloc",
              "crash site: mi_malloc+0x76" in blob, blob)
        check("mimalloc/names-the-assertion-string",
              "corrupted thread-free list." in blob, blob)
        # falsifier: with `da` yielding nothing, the string must NOT appear and
        # the tool must say the text was not recovered.
        lines2 = crashwatch.symbolize_host_dump(
            "nodump", ours={HOST_STEM}, install_root=td, repo_mods=td,
            cdb_text=fixture("cdb_wer_636_RECONSTRUCTED.txt"),
            objdump_runner=objdump_runner,
            cdb_runner=lambda cmd: (0, "00007ffb`3dfd1373  \"\"\n"))
        b2 = "\n".join(lines2)
        check("mimalloc/no-da-string-means-NOT-RECOVERED",
              "corrupted" not in b2 and "was NOT recovered" in b2, b2)


def t_host_frames_present_detects_both_shapes():
    """The trigger for running any of this from `last`. Two shapes, plus a
    negative control that must stay False."""
    F = crashwatch.Frame

    class R(object):
        def __init__(self, frames):
            self.ok, self.why = True, ""
            self.frames, self.walked = frames, []

        @property
        def all_frames(self):
            return self.frames + self.walked

    ours = {HOST_STEM, "sain"}
    unavailable = R([F("0x1", HOST_STEM, "(function-name not available)")])
    check("trigger/function-name-not-available",
          crashwatch.host_frames_present(unavailable, ours))
    repeated = R([F("0x%d" % i, HOST_STEM, "aowl_region_screen_known_x")
                  for i in range(7)])
    check("trigger/one-export-repeated-across-frames",
          crashwatch.host_frames_present(repeated, ours))
    clean = R([F("0x1", "GameAssembly", "Foo"),
               F("0x2", HOST_STEM, "aowl_real_symbol"),
               F("0x3", HOST_STEM, "aowl_other_symbol")])
    check("trigger/negative-control-stays-False",
          not crashwatch.host_frames_present(clean, ours))
    check("trigger/unparsable-report-is-False",
          not crashwatch.host_frames_present(None, ours))


def t_fixtures_declare_what_they_are():
    """A reconstructed fixture that does not SAY it is reconstructed is how a
    transcription becomes a measurement. Asserted, not trusted."""
    for n in os.listdir(FIXDIR):
        if "RECONSTRUCTED" not in n:
            continue
        head = fixture(n).splitlines()[0]
        check("fixtures/%s declares itself" % n,
              "RECONSTRUCTED" in head, head)


def main():
    for fn in (t_parses_sain_frames, t_parses_ga_two_blocks,
               t_not_a_crash_report, t_attribution, t_our_modules_finds_the_mods,
               t_folder_time_is_utc, t_older_folder_ignored,
               t_run_prints_the_block, t_refuses_a_non_crashes_root,
               t_top_12_is_a_cap,
               t_pe_ident_reads_the_recorded_header,
               t_match_build_picks_the_loaded_backup,
               t_match_build_no_backup_is_inconclusive,
               t_match_build_identical_copies_are_not_ambiguous,
               t_objdump_addresses_are_section_relative,
               t_a_data_address_is_refused_not_named,
               t_scrape_recovers_the_chain_and_is_labelled_a_scrape,
               t_mimalloc_string_is_read_not_guessed,
               t_host_frames_present_detects_both_shapes,
               t_fixtures_declare_what_they_are):
        if VERBOSE:
            print("%s:" % fn.__name__)
        try:
            fn()
        except Exception as e:
            check(fn.__name__ + "/raised", False,
                  "%s: %s" % (type(e).__name__, e))

    bad = [r for r in RESULTS if not r[1]]
    print("\n%s -- %d/%d checks passed"
          % ("PASS" if not bad else "FAIL", len(RESULTS) - len(bad),
             len(RESULTS)))
    if bad:
        for n, _ok, d in bad:
            print("   FAILED  %s  %s" % (n, d))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
