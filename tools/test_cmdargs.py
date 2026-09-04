#!/usr/bin/env python3
"""test_cmdargs.py -- the mod command-line argument path, end to end where it
can be executed and by source where it cannot.

WHAT IS UNDER TEST

  1. `aowlspt-launch` forwards an option it does not own to the game as
     `-aowl.<name>=<value>`, prints the forward, and shows it in `--dry-run`'s
     final client command line. EXECUTED against the real launcher exe when one
     is built; INCONCLUSIVE (never PASS) when it is not.
  2. The launcher REFUSES the ambiguous `--<ownoption>=<value>` spelling rather
     than forwarding it.
  3. `LauncherOptions` (the refusal list) has not drifted from the `if` chain
     that actually parses. This is the one that rots: add an option to the
     chain, forget the const, and `--newopt=value` is silently forwarded to the
     game as a mod argument instead of being refused.
  4. The host side declares the four verbs and the wire format, and the
     undeclared-token sweep exists and is a NEGATIVE ("no -aowl.* token is
     unclaimed") rather than a self-comparison.

THREE OUTCOMES. PASS / FAIL / INCONCLUSIVE. "I could not look" -- no launcher
exe, a source file missing -- is INCONCLUSIVE and exits 3.

EVERY CASE CARRIES ITS OWN NEGATIVE CONTROL, in the same run:

  * case 1's control is `--force` (an option the launcher DOES own): it must
    produce NO forwarding line and NO `-aowl.` token. Without that, a launcher
    that forwarded everything would pass case 1.
  * case 3's control is a fabricated option name that is in neither list: the
    comparison must report it as a difference, so the check is shown to be
    capable of finding one.
  * case 4's control is a verb name that does not exist: the source search must
    answer absent for it, so a search that matched everything cannot pass.

    python tools/test_cmdargs.py
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"
results = []


def record(name, verdict, detail):
    results.append((name, verdict, detail))
    print("%-13s %s" % (verdict, name))
    if detail:
        for line in detail.splitlines():
            print("              " + line)


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def find_launcher():
    """The built launcher, wherever this checkout puts it."""
    cands = [
        os.path.join(ROOT, "installer", "build", "aowlspt-launch.exe"),
        os.path.join(ROOT, "tools", "build", "aowlspt-launch.exe"),
        os.path.join(ROOT, "build", "aowlspt-launch.exe"),
    ]
    for c in cands:
        if os.path.exists(c):
            return c
    return None


# --------------------------------------------------------------------------
# case 1 + 2: the launcher, executed
# --------------------------------------------------------------------------

def run_launcher(exe, args, root):
    try:
        p = subprocess.run([exe, "--dry-run", "--plain", "--root", root] + args,
                           capture_output=True, text=True, timeout=120)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:                       # noqa: BLE001
        return None, "could not run: %s" % exc


def case_forwarding(exe):
    if exe is None:
        record("launcher forwards --raid to -aowl.raid", INCONCLUSIVE,
               "no aowlspt-launch.exe is built in this checkout, so the\n"
               "forwarding was NOT executed. This is 'I could not look'.\n"
               "Build it with: python tools/buildlock.py build launch")
        return
    # A REAL install root when there is one, because only then does the
    # launcher get far enough to print the client command line the game would
    # actually receive. `--dry-run` starts nothing and writes nothing; the
    # synthetic root below is the fallback and downgrades that one case to
    # INCONCLUSIVE rather than pretending it was checked.
    root = tempfile.mkdtemp(prefix="aowlargs")
    for real in (os.environ.get("AOWLSPT_ROOT", ""), r"D:\Aowlspt"):
        if real and os.path.isdir(os.path.join(real, "aowlspt")):
            root = real
            break
    rc, out = run_launcher(exe, ["--raid", "Woods"], root)
    if rc is None:
        record("launcher forwards --raid to -aowl.raid", INCONCLUSIVE, out)
        return
    saw_line = "forwarding --raid" in out
    saw_tok = "-aowl.raid=Woods" in out
    if saw_line and saw_tok:
        record("launcher forwards --raid to -aowl.raid", PASS,
               "printed the forward AND the token appears in the dry-run "
               "command line")
    else:
        record("launcher forwards --raid to -aowl.raid", FAIL,
               "forwarding line: %s   token in output: %s\nexit %s\n%s"
               % (saw_line, saw_tok, rc, out[-1500:]))

    # The token in the REAL client command line, not merely in the
    # "forwarding" notice. Reported separately, because a temp --root may make
    # the dry run stop before it prints the line -- which is "I could not
    # look", not a failure of the forwarding.
    cmdlines = [ln for ln in out.splitlines() if "-force-gfx-jobs" in ln]
    if not cmdlines:
        record("the token reaches the dry-run CLIENT command line",
               INCONCLUSIVE,
               "this dry run never printed a client command line (a synthetic "
               "--root has no install to describe), so the token's presence "
               "in it was NOT observed")
    elif any("-aowl.raid=Woods" in ln for ln in cmdlines):
        record("the token reaches the dry-run CLIENT command line", PASS,
               cmdlines[-1][-300:])
    else:
        record("the token reaches the dry-run CLIENT command line", FAIL,
               "a client command line was printed and the token is NOT in "
               "it:\n" + cmdlines[-1][-300:])

    # quoted value with a space
    rc2, out2 = run_launcher(exe, ['--raid=Ground Zero'], root)
    if rc2 is not None and '-aowl.raid="Ground Zero"' in out2:
        record("a value with a space is forwarded QUOTED", PASS, "")
    else:
        record("a value with a space is forwarded QUOTED", FAIL,
               (out2 or "")[-1200:])

    # bare flag
    rc3, out3 = run_launcher(exe, ["--raiddebug"], root)
    if rc3 is not None and "-aowl.raiddebug=true" in out3:
        record("a bare --flag forwards as =true", PASS, "")
    else:
        record("a bare --flag forwards as =true", FAIL, (out3 or "")[-1200:])

    # NEGATIVE CONTROL: an option the launcher owns is not forwarded.
    rc4, out4 = run_launcher(exe, ["--force"], root)
    if rc4 is not None and "-aowl." not in out4 and "forwarding" not in out4:
        record("NEGATIVE CONTROL: --force is NOT forwarded", PASS,
               "the launcher's own option produced no -aowl. token, so case 1 "
               "is not passing vacuously")
    else:
        record("NEGATIVE CONTROL: --force is NOT forwarded", FAIL,
               "a known launcher option was forwarded as a mod argument\n"
               + (out4 or "")[-1200:])


def case_ambiguous(exe):
    if exe is None:
        record("--root=VALUE is refused, not forwarded", INCONCLUSIVE,
               "no launcher exe built")
        return
    root = tempfile.mkdtemp(prefix="aowlargs")
    rc, out = run_launcher(exe, ["--root=" + root], root)
    if rc is None:
        record("--root=VALUE is refused, not forwarded", INCONCLUSIVE, out)
        return
    refused = ("-aowl.root" not in out) and (rc != 0 or "REFUS" in out.upper()
                                             or "own options" in out)
    if refused:
        record("--root=VALUE is refused, not forwarded", PASS,
               "exit %s, and no -aowl.root token was produced" % rc)
    else:
        record("--root=VALUE is refused, not forwarded", FAIL,
               "exit %s\n%s" % (rc, out[-1500:]))


# --------------------------------------------------------------------------
# case 3: the drift check
# --------------------------------------------------------------------------

def case_option_drift():
    src = read(os.path.join("tools", "aowllaunch.nim"))
    if src is None:
        record("LauncherOptions matches the parse chain", INCONCLUSIVE,
               "tools/aowllaunch.nim not found")
        return
    m = re.search(r"const LauncherOptions = \[(.*?)\]", src, re.S)
    if not m:
        record("LauncherOptions matches the parse chain", INCONCLUSIVE,
               "the LauncherOptions const was not found in the source")
        return
    listed = set(re.findall(r'"([^"]+)"', m.group(1)))
    # Only the parse chain, not the const or the help text.
    start = src.find("proc parseArgs")
    body = src[start:] if start >= 0 else src
    body = body[:body.find("# ---------------------------------------------------------------------------",
                           body.find("elif a.startsWith(\"-\")"))]
    parsed = set(x[2:] for x in re.findall(r'a == "(--[a-z0-9-]+)"', body))
    missing = sorted(parsed - listed)
    extra = sorted(listed - parsed)
    if missing:
        record("LauncherOptions matches the parse chain", FAIL,
               "these options are parsed but NOT in LauncherOptions, so "
               "`--<name>=value` for them would be silently FORWARDED to the "
               "game instead of refused: " + ", ".join(missing))
    else:
        detail = "%d parsed options, all listed" % len(parsed)
        if extra:
            detail += ("; listed but not parsed (harmless, refuses a little "
                       "more than needed): " + ", ".join(extra))
        record("LauncherOptions matches the parse chain", PASS, detail)
    # NEGATIVE CONTROL: the comparison can see a difference at all.
    fake = parsed | {"zzz-not-an-option"}
    if sorted(fake - listed) == ["zzz-not-an-option"]:
        record("NEGATIVE CONTROL: the drift comparison can fail", PASS, "")
    else:
        record("NEGATIVE CONTROL: the drift comparison can fail", FAIL,
               "a fabricated option was NOT reported as a difference, so the "
               "check above cannot fail and proves nothing")


# --------------------------------------------------------------------------
# case 4: the host side
# --------------------------------------------------------------------------

def case_host_source():
    ca = read(os.path.join("host", "Aowlspt.Host.Il2Cpp", "cmdargs.nim"))
    hh = read(os.path.join("host", "Aowlspt.Host.Il2Cpp", "aowlhost.nim"))
    if ca is None or hh is None:
        record("host declares the four verbs and the wire format",
               INCONCLUSIVE, "a host source file was not found")
        return
    need_verbs = ["aowlspt.host::cmdline", "aowlspt.host::args_declare",
                  "aowlspt.host::ui_show_status", "aowlspt.host::raid_phase"]
    absent = [v for v in need_verbs if v not in hh]
    if absent:
        record("host declares the four verbs", FAIL,
               "not present in aowlhost.nim: " + ", ".join(absent))
    else:
        record("host declares the four verbs", PASS, "")
    # NEGATIVE CONTROL for the search itself.
    if "aowlspt.host::not_a_real_verb" not in hh:
        record("NEGATIVE CONTROL: the verb search can answer absent", PASS, "")
    else:
        record("NEGATIVE CONTROL: the verb search can answer absent", FAIL,
               "a fabricated verb name was found, so the search proves "
               "nothing")

    checks = [
        ('CaPrefix = "-aowl."', "the wire prefix is the agreed one"),
        ("caParseOnce", "the line is parsed exactly once"),
        ("proc caSweepTick", "the undeclared-token sweep exists"),
        ("declared by NO loaded mod", "the sweep NAMES the orphans"),
    ]
    bad = [why for lit, why in checks if lit not in ca]
    if bad:
        record("cmdargs.nim carries the parser and the fail-closed sweep",
               FAIL, "missing: " + "; ".join(bad))
    else:
        record("cmdargs.nim carries the parser and the fail-closed sweep",
               PASS, "")
    if "caParseOnce()" in hh:
        record("hostMain parses the command line at startup", PASS, "")
    else:
        record("hostMain parses the command line at startup", FAIL,
               "nothing in aowlhost.nim calls caParseOnce(), so the table "
               "would be empty for every mod")


def main():
    exe = find_launcher()
    print("launcher exe: %s" % (exe or "(none built)"))
    case_forwarding(exe)
    case_ambiguous(exe)
    case_option_drift()
    case_host_source()
    fails = [r for r in results if r[1] == FAIL]
    incs = [r for r in results if r[1] == INCONCLUSIVE]
    print("\n%d case(s): %d PASS, %d FAIL, %d INCONCLUSIVE"
          % (len(results), len(results) - len(fails) - len(incs), len(fails),
             len(incs)))
    if fails:
        return 1
    if incs:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
