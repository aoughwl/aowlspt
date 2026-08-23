#!/usr/bin/env python3
r"""doctor.py -- "what is the state of the world", in one command.

Run this BEFORE a debugging session, and again whenever an answer surprises
you. Every line here was, at some point, hand-checked with a separate command,
and several dead ends were state that could have been read in one line.

    python tools/doctor.py                 # the whole report
    python tools/doctor.py --section build flags
    python tools/doctor.py --root D:\Aowlspt\aowlspt

Sections: proc build flags index inspector bindings raid backups

## The rule this tool is built around

**A check that could not run must say so.** Every section prints either a
measured fact or the literal `UNKNOWN` / `NOT PERFORMED`, with the reason. A
green light from a check that compared nothing is exactly the failure mode this
tool exists to remove, so there is no code path here that prints "ok" without
having compared two things it names.

Consequences you will see in the output:

  * the deployed DLL is reported as matching a local build only when the SHA-256
    of both files was actually computed and found equal; "no local build
    matches" is a real, distinct answer from "no local build was found to
    compare against".
  * the raid question answers UNKNOWN unless there is positive evidence. See
    `raid_state` for why `RegisterPlayer > 0` is NOT that evidence.

## Token discipline

`aowlspt-host.log` is routinely 10+ MB. It is never read whole into anything
that gets printed: it is streamed a line at a time and only aggregates
(counts, the last match, a deduped set) survive. `nettrace.log` and `db.json`
are not read at all -- nothing here needs them.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"

sys.path.insert(0, HERE)

RESET, RED, GREEN, YELLOW, CYAN, DIM, BOLD = (
    "\033[0m", "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[2m", "\033[1m")

_C = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def c(s, col):
    return (col + s + RESET) if _C else s


def head(title):
    print("\n" + c("== " + title, BOLD))


def unknown(why):
    """The only way this file is allowed to not answer."""
    return c("UNKNOWN", YELLOW) + " -- " + why


def notperformed(why):
    return c("NOT PERFORMED", YELLOW) + " -- " + why


def ago(ts):
    d = time.time() - ts
    for n, u in ((86400, "d"), (3600, "h"), (60, "m")):
        if d >= n:
            return "%.0f%s ago" % (d / n, u)
    return "%.0fs ago" % d


def sha(path, cap=None):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            n += len(b)
            h.update(b)
            if cap and n >= cap:
                break
    return h.hexdigest()


# ---------------------------------------------------------------- processes

PROCS = ["EscapeFromTarkov.exe", "aowlspt-backend.exe", "aowlspt-launch.exe"]


def section_proc(root):
    head("processes")
    try:
        out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=20)
    except Exception as e:
        print("  " + notperformed("tasklist did not run: %s" % e))
        return
    if out.returncode != 0:
        print("  " + notperformed("tasklist exited %d" % out.returncode))
        return
    live = {}
    for line in out.stdout.splitlines():
        f = [x.strip('"') for x in line.split('","')]
        if len(f) < 2:
            continue
        live.setdefault(f[0].lstrip('"').lower(), []).append(f[1])
    for p in PROCS:
        pids = live.get(p.lower(), [])
        if pids:
            print("  %-24s %s pid %s" % (p, c("RUNNING", GREEN), ",".join(pids)))
        else:
            print("  %-24s %s" % (p, c("not running", DIM)))
    if live.get("escapefromtarkov.exe"):
        print("  " + c("a human may be playing -- do not deploy or kill anything", YELLOW))


# ------------------------------------------------------------ deployed build

def local_candidates():
    """Every place a host DLL could have been built on this machine.

    The repo itself plus any git worktree of it. Worktrees matter because the
    deployed DLL is very often built in one, and "which build is that" is
    unanswerable if we only look at the main checkout.
    """
    roots = [REPO]
    try:
        out = subprocess.run(["git", "-C", REPO, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=20).stdout
        for line in out.splitlines():
            if line.startswith("worktree "):
                p = line[9:].strip()
                if p and p not in roots:
                    roots.append(p)
    except Exception:
        pass
    cands = []
    for r in roots:
        p = os.path.join(r, "host", "Aowlspt.Host.Il2Cpp", "bin",
                         "aowlspt-host-il2cpp.dll")
        if os.path.isfile(p):
            cands.append(p)
    return roots, cands


def section_build(root):
    head("deployed build")
    dll = os.path.join(root, "aowlspt-host-il2cpp.dll")
    if not os.path.isfile(dll):
        print("  " + unknown("no %s -- nothing is deployed" % dll))
        return
    st = os.stat(dll)
    dh = sha(dll)
    print("  host dll   %d bytes  %s  (%s)"
          % (st.st_size, time.strftime("%Y-%m-%d %H:%M:%S",
                                       time.localtime(st.st_mtime)), ago(st.st_mtime)))
    print("             sha256 %s" % dh[:16])

    roots, cands = local_candidates()
    if not cands:
        print("  " + notperformed(
            "no local host build exists to compare against (looked in %d checkout(s): %s)"
            % (len(roots), ", ".join(os.path.basename(r) or r for r in roots))))
    else:
        matched = []
        for p in cands:
            if sha(p) == dh:
                matched.append(p)
        if matched:
            for m in matched:
                print("  %s %s" % (c("MATCHES local build", GREEN), m))
        else:
            print("  %s -- compared against %d local build(s):"
                  % (c("no local build matches", RED), len(cands)))
            for p in cands:
                s = os.stat(p)
                print("      %s  %d bytes  %s"
                      % (p, s.st_size,
                         time.strftime("%H:%M:%S", time.localtime(s.st_mtime))))
            print("      the deployed DLL was built somewhere that no longer has it,")
            print("      or has been rebuilt since. Do NOT assume the source you are")
            print("      reading is the code that is running.")

    # mods
    md = os.path.join(root, "mods")
    if not os.path.isdir(md):
        print("  mods       " + unknown("no mods dir at %s" % md))
        return
    rows = []
    for name in sorted(os.listdir(md)):
        d = os.path.join(md, name)
        if not os.path.isdir(d):
            continue
        newest, total, count = 0, 0, 0
        for base, _dirs, files in os.walk(d):
            for f in files:
                fp = os.path.join(base, f)
                try:
                    s = os.stat(fp)
                except OSError:
                    continue
                newest = max(newest, s.st_mtime)
                total += s.st_size
                count += 1
        rows.append((name, count, total, newest))
    print("  mods       %d installed" % len(rows))
    for name, n, total, newest in rows:
        print("      %-18s %2d file(s) %8d B  %s"
              % (name, n, total,
                 time.strftime("%m-%d %H:%M", time.localtime(newest)) if newest else "?"))


# ------------------------------------------------------------------- flags

# Flags whose effect is INVISIBLE until something else goes wrong. These are
# the ones that have cost cycles: the run behaves differently and nothing in
# the output says why.
SILENT = {
    "liveInspector": "off = the inspector answers NOTHING; batches vanish silently",
    "liveInspectorWrite": "off = every write/call in a batch is refused",
    "nameIndex": "on = patch targets resolve from aowlspt-names.idx (offline metadata), not the runtime",
    "codeGenResolve": "on = code pointers come from the codeGenModule walk",
    "codeGenAudit": "on = audit-only, changes no behaviour",
    "bridgeStaticRva": "on = static-RVA bridge instead of by-name binding",
    "debugUi": "off = F3 panel absent AND debugEsp cannot work",
    "backendPort": "0 = the host never contacts the backend; overlay shows only host-local state",
}


def section_flags(root):
    head("host flags")
    try:
        import hostcfg
    except Exception as e:
        print("  " + notperformed("cannot import hostcfg.py: %s" % e))
        return
    hostdir = os.path.join(REPO, "host")
    try:
        keys = hostcfg.scrape_keys(hostdir)
    except SystemExit as e:
        print("  " + notperformed(
            "the key list could not be scraped from %s (%s), so an unknown key "
            "here cannot be distinguished from a real one" % (hostdir, e)))
        keys = None
    p = os.path.join(root, "aowlspt-host.json")
    if not os.path.isfile(p):
        print("  " + unknown("no config at %s" % p))
        return
    with open(p, "r", encoding="utf-8-sig") as f:
        text = f.read()

    on, off = [], []
    src = sorted(keys) if keys else sorted(
        set(re.findall(r'"([A-Za-z0-9_]+)"\s*:', text)))
    for k in src:
        if k.startswith("//"):
            continue
        present, raw, truthy = hostcfg.value_of(text, k)
        if not present:
            off.append((k, "absent"))
        elif truthy:
            on.append((k, raw))
        else:
            off.append((k, raw))
    print("  ON : " + (", ".join(k for k, _ in on) if on else c("(none)", DIM)))
    print("  OFF: " + (", ".join(k for k, _ in off) if off else c("(none)", DIM)))
    print("  behaviour-changing flags:")
    for k, why in sorted(SILENT.items()):
        present, raw, truthy = hostcfg.value_of(text, k)
        if not present:
            state = c("absent -> host default", DIM)
        elif k == "backendPort":
            state = c(raw, GREEN if truthy else YELLOW)
        else:
            state = c("ON", GREEN) if truthy else c("off", DIM)
        print("      %-22s %-28s %s" % (k, state, c(why, DIM)))

    if keys:
        unk = [m.group(1) for m in re.finditer(r'"([A-Za-z0-9_]+)"\s*:', text)
               if m.group(1) not in keys]
        unk = [u for u in unk if not u.startswith("//")]
        if unk:
            print("  " + c("KEYS THE HOST IGNORES SILENTLY: " + ", ".join(sorted(set(unk))), RED))
    else:
        print("  " + notperformed("unknown-key check needs the scraped key list"))


# --------------------------------------------------------------- name index

def find_gameassembly(root):
    for p in (os.path.join(os.path.dirname(root), "GameAssembly.dll"),
              os.path.join(root, "GameAssembly.dll")):
        if os.path.isfile(p):
            return p
    return None


def section_index(root):
    head("name index (aowlspt-names.idx)")
    idx = os.path.join(root, "aowlspt-names.idx")
    if not os.path.isfile(idx):
        print("  " + unknown("no aowlspt-names.idx in %s. If `nameIndex` is on, "
                             "the host has nothing to resolve through." % root))
        return
    s = os.stat(idx)
    print("  present    %d bytes  %s" % (s.st_size, ago(s.st_mtime)))
    ga = find_gameassembly(root)
    if not ga:
        print("  " + notperformed(
            "GameAssembly.dll was not found next to the install, so the index's "
            "build stamp could NOT be compared. A stale index is wrong-but-mapped "
            "addresses, and that state is indistinguishable from a good one here."))
        return
    checker = os.path.join(HERE, "il2cpp_nameindex.py")
    if not os.path.isfile(checker):
        print("  " + notperformed("il2cpp_nameindex.py is not in %s" % HERE))
        return
    try:
        r = subprocess.run([sys.executable, checker, "check", ga, idx],
                           capture_output=True, text=True, timeout=180)
    except Exception as e:
        print("  " + notperformed("check did not run: %s" % e))
        return
    out = (r.stdout or "") + (r.stderr or "")
    for line in out.splitlines():
        if line.startswith(("index:", "dll:", "STALE INDEX", "INDEX MATCHES",
                            "stamp matched")):
            print("  " + line)
        elif "MISMATCH" in line or "CROSS-CHECK FAILED" in line:
            print("  " + c(line, RED))
    if r.returncode == 0:
        print("  " + c("FRESH: stamp and cross-checks agree with the DLL present", GREEN))
    else:
        print("  " + c("STALE OR BROKEN (il2cpp_nameindex.py check exited %d)"
                       % r.returncode, RED))
        print("  " + c("every RVA resolved through it is a wrong-but-mapped address", RED))


# ------------------------------------------------------------------ the log

def logpath(root):
    return os.path.join(root, "aowlspt-host.log")


def scan_log(root, wants):
    """Stream the host log once, collecting only what `wants` asks for.

    `wants` maps a name -> compiled regex. Returns name -> list of (lineno,
    text) capped, plus a total count. The file is 10+ MB and is never held in
    memory or printed whole.
    """
    p = logpath(root)
    if not os.path.isfile(p):
        return None, "no host log at %s -- the host has not run" % p
    res = {k: {"hits": [], "n": 0} for k in wants}
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f, 1):
            for k, rx in wants.items():
                if rx.search(line):
                    res[k]["n"] += 1
                    if len(res[k]["hits"]) < 400:
                        res[k]["hits"].append((i, line.rstrip()))
                    else:
                        res[k]["hits"][-1] = (i, line.rstrip())
    return res, None


FAULT_BUDGET = re.compile(
    r"fault (\d+) of (\d+) before the inspector switches itself off")
# CAREFUL. The budget line itself contains the words "before the inspector
# switches itself off", so the obvious regex for "the inspector died" matches
# every ordinary fault line and reports a dead inspector on fault 1 of 8. That
# is precisely the confidently-wrong answer this tool exists to stop, and it
# was caught on this tool's first run. A switch-off is only real when the
# sentence is NOT the "N of M before ..." warning.
SWITCHED_OFF = re.compile(
    r"inspector.*switch(?:es|ed|ing) itself off", re.I)
BUDGET_WARNING = re.compile(r"fault \d+ of \d+ before")


def section_inspector(root):
    head("inspector fault budget")
    res, err = scan_log(root, {
        "budget": FAULT_BUDGET,
        "dead": SWITCHED_OFF,
        "armed": re.compile(r"live inspector.*armed"),
        "batch": re.compile(r"live inspector -- batch (\d+)"),
    })
    if res is None:
        print("  " + unknown(err))
        return
    if not res["armed"]["hits"]:
        print("  " + unknown("the log never says the inspector armed. Either "
                             "`liveInspector` is off, or this log predates it."))
    else:
        for _n, l in res["armed"]["hits"][-2:]:
            print("  " + c("armed", GREEN) + ": " + l.split("  ", 1)[-1][:150])
    if not res["budget"]["hits"]:
        print("  faults     " + c("0 recorded", GREEN) + " -- the budget is untouched")
    else:
        last = res["budget"]["hits"][-1][1]
        m = FAULT_BUDGET.search(last)
        spent, cap = int(m.group(1)), int(m.group(2))
        col = RED if spent >= cap - 1 else YELLOW
        print("  faults     %s (last at log line %d)"
              % (c("%d of %d spent" % (spent, cap), col), res["budget"]["hits"][-1][0]))
        if spent >= cap:
            print("  " + c("THE INSPECTOR IS DEAD FOR THIS SESSION -- restart the "
                           "client before believing any further batch", RED))
    real_dead = [(n, l) for n, l in res["dead"]["hits"]
                 if not BUDGET_WARNING.search(l)]
    if real_dead:
        print("  " + c("SWITCH-OFF LINE PRESENT: " + real_dead[-1][1][-120:], RED))
    if res["batch"]["hits"]:
        m = re.search(r"batch (\d+)", res["batch"]["hits"][-1][1])
        print("  batches    %s seen (last id %s)" % (res["batch"]["n"], m.group(1)))


BOUND = re.compile(r"^\[.*?\]\s+\S+\s+(.*?) bound to (\S+) \(")
NOPTR = re.compile(r"no usable code pointer for (\S+)")


def section_bindings(root):
    head("what actually bound this run")
    res, err = scan_log(root, {"bound": BOUND, "noptr": NOPTR})
    if res is None:
        print("  " + unknown(err))
        return
    seen = {}
    for _n, line in res["bound"]["hits"]:
        m = BOUND.search(line)
        if m:
            seen[m.group(1).strip()] = m.group(2)
    if not seen:
        print("  " + unknown("no `bound to` line in the log -- nothing patched, "
                             "or the log is from before binding"))
    else:
        print("  %d feature(s) bound (%d log lines):" % (len(seen), res["bound"]["n"]))
        for k in sorted(seen):
            print("      %-26s -> %s" % (k, seen[k]))
    if res["noptr"]["hits"]:
        refused = sorted({NOPTR.search(l).group(1) for _n, l in res["noptr"]["hits"]})
        print("  " + c("REFUSED (no usable code pointer): " + ", ".join(refused), RED))
    else:
        print("  refusals   " + c("none", GREEN) + " (no `no usable code pointer for` line)")


# --------------------------------------------------------------------- raid

def client_running():
    """None when we could not tell -- which is NOT the same as 'not running'."""
    try:
        out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return "escapefromtarkov.exe" in out.stdout.lower()


def section_raid(root):
    head("in a raid?")
    # A log is only evidence about the PRESENT while the client that wrote it
    # is still alive. Reading raid state off a finished run's log and calling
    # it "probably in a raid" is a wrong answer dressed as a measurement; the
    # first run of this tool did exactly that with the game shut down.
    alive = client_running()
    if alive is False:
        print("  verdict    " + unknown(
            "EscapeFromTarkov.exe is not running. The host log is a finished "
            "run, so nothing in it describes the present."))
        return
    if alive is None:
        print("  " + notperformed("could not determine whether the client is "
                                  "running; the log below may be stale"))
    res, err = scan_log(root, {
        "roots": re.compile(r'inspect\|.*name="Menu UI"'),
        "anyroots": re.compile(r"inspect\|.*\[\$r\d+\] transform="),
        "reg": re.compile(r"RegisterPlayer"),
    })
    if res is None:
        print("  " + unknown(err))
        return
    reg = res["reg"]["n"]
    print("  " + c("RegisterPlayer lines: %d -- NOT evidence either way." % reg, DIM))
    print("  " + c("  it fires at server start too (~5 events), so a positive "
                   "count proves nothing.", DIM))
    if not res["anyroots"]["hits"]:
        print("  verdict    " + unknown(
            "no `roots` enumeration in this log. The only signal we trust is "
            "the PRESENCE or ABSENCE of a `Menu UI` scene root, and nobody has "
            "asked for one. Run: python tools/inspector.py roots"))
        return
    last_roots_line = res["anyroots"]["hits"][-1][0]
    menu = [n for n, _l in res["roots"]["hits"] if n >= last_roots_line - 60]
    if menu:
        print("  verdict    " + c("NOT in a raid", GREEN) +
              " -- the most recent `roots` (log line %d) lists a `Menu UI` root"
              % last_roots_line)
    else:
        print("  verdict    " + c("probably IN a raid", YELLOW) +
              " -- the most recent `roots` (log line %d) has NO `Menu UI` root."
              % last_roots_line)
        print("             This is the best signal available, not a certainty; "
              "re-run `roots` to make it current.")


# ------------------------------------------------------------------ backups

BAK = re.compile(r"\.bak-(.+)$")


def section_backups(root):
    head("rollback backups")
    if not os.path.isdir(root):
        print("  " + unknown("no install at %s" % root))
        return
    groups = {}
    for name in os.listdir(root):
        m = BAK.search(name)
        if m:
            base = name[:m.start()]
            groups.setdefault(base, []).append(name)
    if not groups:
        print("  " + c("NONE", RED) + " -- a bad deploy cannot be undone from here")
        return
    for base in sorted(groups):
        baks = sorted(groups[base],
                      key=lambda n: os.stat(os.path.join(root, n)).st_mtime,
                      reverse=True)
        print("  %-28s %d backup(s), newest:" % (base, len(baks)))
        for n in baks[:3]:
            s = os.stat(os.path.join(root, n))
            print("      %-58s %8d B  %s"
                  % (n, s.st_size,
                     time.strftime("%m-%d %H:%M", time.localtime(s.st_mtime))))
    print("  " + c("roll back with: python tools/deploy.py rollback", DIM))


SECTIONS = [
    ("proc", section_proc),
    ("build", section_build),
    ("flags", section_flags),
    ("index", section_index),
    ("inspector", section_inspector),
    ("bindings", section_bindings),
    ("raid", section_raid),
    ("backups", section_backups),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--section", nargs="*", choices=[n for n, _ in SECTIONS],
                    help="only these sections (default: all)")
    a = ap.parse_args()
    want = set(a.section) if a.section else None

    lp = logpath(a.root)
    print(c("aowlspt doctor", BOLD) + "  install=%s" % a.root)
    if os.path.isfile(lp):
        s = os.stat(lp)
        print("  host log %.1f MB, last written %s (the host truncates it at "
              "every start, so this file is exactly ONE run)"
              % (s.st_size / 1048576.0, ago(s.st_mtime)))
    else:
        print("  " + unknown("no host log -- every log-derived section below "
                             "will say so rather than guess"))

    for name, fn in SECTIONS:
        if want and name not in want:
            continue
        try:
            fn(a.root)
        except Exception as e:
            print("  " + notperformed("section %r raised %s: %s"
                                      % (name, type(e).__name__, e)))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
