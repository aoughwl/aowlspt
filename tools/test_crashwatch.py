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


def main():
    for fn in (t_parses_sain_frames, t_parses_ga_two_blocks,
               t_not_a_crash_report, t_attribution, t_our_modules_finds_the_mods,
               t_folder_time_is_utc, t_older_folder_ignored,
               t_run_prints_the_block, t_refuses_a_non_crashes_root,
               t_top_12_is_a_cap):
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
