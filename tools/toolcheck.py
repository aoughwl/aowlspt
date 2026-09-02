#!/usr/bin/env python3
r"""toolcheck.py -- catch the live inspector LYING, after a host build.

    python tools/toolcheck.py list
    python tools/toolcheck.py run                    # replay every runnable case
    python tools/toolcheck.py run --case roots-shape comp-anchor-not-stale
    python tools/toolcheck.py run --at menu          # declare where the client is
    python tools/toolcheck.py record --at menu       # save today's answers as the baseline
    python tools/toolcheck.py show comp-anchor-not-stale

The inspector has repeatedly produced confidently wrong answers, and every one
was found BY ACCIDENT. This replays a fixed set of batches after a host build
and asserts what the answers must and must not look like.

## The expectation model, and why it has two tiers

Pointers change every run. Names, shapes, counts and the FORM of an answer do
not. So nothing here asserts an address: answers are normalised (`0x…` ->
`<PTR>`, bare counts -> `<N>`) before any match. Beyond that there are two
kinds of expectation, kept deliberately separate because they carry different
authority:

  * **assert / refuse / deny** -- hand-written invariants in toolcheck.json.
    These are the contract. A `deny` miss is a FAILURE: the tool answered in
    the shape of a known bug. These were written from behaviour that is
    documented or was observed, and each case carries a `why` naming the bug it
    locks in.

  * **baseline** -- the normalised answer text recorded by `record` on a run
    that a human vouched for. A difference is reported as DRIFT, not failure.
    Drift is a prompt to look, not a verdict, because the answer may legitimately
    have changed. Promoting drift to a hard failure would manufacture exactly the
    kind of confident wrongness this tool is against.

`record` never invents an expectation and never edits the hand-written ones. It
only writes toolcheck-baseline.json.

## Telling a GAME change from a TOOL regression

Same idea as the fact store's scope key. Every baseline records:

  * `scope`  -- from GameAssembly.dll (PE image key + file hash) and db.json
                (size + streamed sha256). If this differs, the GAME changed:
                every difference is reported as WITHHELD, exit 3, and no
                failure is claimed. Blaming the tool for a Tarkov update is a
                wrong answer too.
  * `host`   -- sha256 of the DEPLOYED aowlspt-host-il2cpp.dll. If scope is
                unchanged and host changed, a difference IS attributable to the
                host build. That is the case this tool exists for, and it is
                labelled as such in the report.
  * `at`     -- where the client was (`menu` / `raid`). Comparing a menu
                baseline against a raid run is meaningless; it is refused.

## Asserting a REFUSAL

Half these bugs were the tool ANSWERING when it should have declined. A case
therefore has a `refuse` list, separate from `assert`, whose entries must
appear -- and it is expected to carry a `deny` list holding the shape of the
wrong answer. `refuse` without `deny` proves only that a refusal was printed,
not that an answer was not ALSO printed, so the runner warns about such a case
rather than treating it as fully protective.

## Running it without a human

This does NOT launch anything. Bring the client up first, then run:

    python tools/harness.py run --until "host running" --keep
    python tools/toolcheck.py run --at menu

`--keep` leaves the client alive for the replay. For the raid-only cases a
human has to be in a raid; those cases SKIP, and a skip is never a pass.

Exit codes: 0 all runnable cases passed, 1 at least one FAILED (a regression),
2 the inspector did not answer a batch, 3 scope changed so the verdict is
withheld, 4 nothing ran.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LIVE = os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt")
CASES = os.path.join(HERE, "toolcheck.json")
BASELINE = os.path.join(HERE, "toolcheck-baseline.json")

sys.path.insert(0, HERE)
import inspector  # noqa: E402  -- the ONE batch driver; do not write a second

RESET, RED, GREEN, YELLOW, DIM, BOLD = (
    "\033[0m", "\033[31m", "\033[32m", "\033[33m", "\033[2m", "\033[1m")
_C = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def c(s, col):
    return (col + s + RESET) if _C else s


# ------------------------------------------------------------- normalisation

PTR = re.compile(r"0x[0-9A-Fa-f]{6,}")
SMALLPTR = re.compile(r"\b0x[0-9A-Fa-f]{2,5}\b")
NODES = re.compile(r"\b\d+ nodes?\b")
MS = re.compile(r"\b\d+(\.\d+)? ?ms\b")
BATCHID = re.compile(r"batch \d+")


def normalise(text):
    """Strip everything that legitimately changes run to run.

    Addresses are the big one: an assertion on an address fails for a reason
    that is not a regression, which trains you to ignore the tool. Small hex
    OFFSETS are deliberately kept (`+0x78` is a fact about the type), so only
    6+ hex digits are treated as a pointer.
    """
    t = PTR.sub("<PTR>", text)
    t = NODES.sub("<N> nodes", t)
    t = MS.sub("<N>ms", t)
    t = BATCHID.sub("batch <N>", t)
    return t


# -------------------------------------------------------------- scope keys

def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def scope_key():
    """(key, detail). key is None when it could NOT be computed.

    A missing scope key is reported, never defaulted to 'unchanged' -- a
    baseline compared under an unknown scope is a comparison whose meaning is
    unknown, and this tool says so instead of guessing.
    """
    parts, detail = [], {}
    ga = None
    for p in (os.path.join(os.path.dirname(LIVE), "GameAssembly.dll"),
              os.path.join(LIVE, "GameAssembly.dll")):
        if os.path.isfile(p):
            ga = p
            break
    if not ga:
        return None, {"why": "GameAssembly.dll not found near %s" % LIVE}
    try:
        import il2cpp_nameindex as NI
        ikey, _ = NI.pe_image_key(ga)
        fh = NI.file_hash(ga)
        parts.append("ga:%016x:%016x" % (ikey, fh))
        detail["gameassembly"] = "imageKey=0x%016X fileHash=0x%016X" % (ikey, fh)
    except Exception as e:
        return None, {"why": "il2cpp_nameindex could not stamp %s: %s" % (ga, e)}

    db = None
    for cand in (os.path.join(LIVE, "db.json"),
                 os.path.join(LIVE, "mods", "tarkov", "db.json"),
                 os.path.join(LIVE, "mods", "tarkov", "data", "db.json")):
        if os.path.isfile(cand):
            db = cand
            break
    if db:
        # 41 MB on ONE line. Streamed, never read into a variable.
        s = os.stat(db)
        parts.append("db:%d:%s" % (s.st_size, sha_file(db)[:16]))
        detail["db.json"] = "%d bytes" % s.st_size
    else:
        detail["db.json"] = "ABSENT (not part of the key)"
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16], detail


def host_key():
    p = os.path.join(LIVE, "aowlspt-host-il2cpp.dll")
    if not os.path.isfile(p):
        return None
    return sha_file(p)[:16]


# ------------------------------------------------------------------- cases

def load_cases():
    with open(CASES, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    out = []
    for cs in cfg["cases"]:
        if not cs.get("why"):
            sys.exit("case %r has no `why` -- a case that cannot say which bug "
                     "it stops is not a case." % cs.get("name"))
        out.append(cs)
    return out


def write_allowed():
    p = os.path.join(LIVE, "aowlspt-host.json")
    if not os.path.isfile(p):
        return None
    try:
        import hostcfg
        with open(p, "r", encoding="utf-8-sig") as f:
            text = f.read()
        _pres, _raw, truthy = hostcfg.value_of(text, "liveInspectorWrite")
        return truthy
    except Exception:
        return None


def inspector_healthy():
    """The fault budget gates every result. At 8 the inspector is off for the
    session and every subsequent 'pass' would be a pass against silence."""
    try:
        import doctor
        res, err = doctor.scan_log(LIVE, {"b": doctor.FAULT_BUDGET})
        if res is None:
            return None, err
        if not res["b"]["hits"]:
            return True, "fault budget untouched"
        m = doctor.FAULT_BUDGET.search(res["b"]["hits"][-1][1])
        spent, cap = int(m.group(1)), int(m.group(2))
        return spent < cap, "fault budget %d of %d spent" % (spent, cap)
    except Exception as e:
        return None, "could not read the fault budget: %s" % e


# ------------------------------------------------------------------ running

class Skip(Exception):
    pass


def run_case(cs, at, allow_write, timeout):
    if cs.get("needs", "any") not in ("any", at):
        raise Skip("needs the client %s; --at says %s" % (cs["needs"], at))
    if cs.get("write") and allow_write is not True:
        raise Skip("needs liveInspectorWrite, which is %s"
                   % ("off" if allow_write is False else "UNREADABLE"))
    chunks = []
    for batch in cs["batches"]:
        # NOTE: `write:true` cases still do NOT get `allow write` prepended
        # here -- several of them exist precisely to prove the gate holds. A
        # case that wants the gate open says `allow write` in its own batch.
        chunks.append(inspector.run_batch(batch, timeout=timeout))
    return normalise("\n".join(chunks))


def judge(cs, answer):
    """Returns (verdict, notes). verdict in PASS/FAIL."""
    notes = []
    bad = False
    for rx in cs.get("assert", []):
        if not re.search(rx, answer, re.M):
            bad = True
            notes.append("MISSING (assert): /%s/" % rx)
    for rx in cs.get("refuse", []):
        if not re.search(rx, answer, re.M):
            bad = True
            notes.append("REFUSAL NOT PRINTED: /%s/ -- the tool answered where "
                         "it should have declined" % rx)
    for rx in cs.get("deny", []):
        m = re.search(rx, answer, re.M)
        if m:
            bad = True
            notes.append("WRONG-ANSWER SHAPE PRESENT: /%s/ matched %r"
                         % (rx, m.group(0)[:60]))
    if cs.get("refuse") and not cs.get("deny"):
        notes.append("weak case: asserts a refusal but does not deny the wrong "
                     "answer's shape, so it cannot tell 'declined' from "
                     "'declined AND answered anyway'")
    return ("FAIL" if bad else "PASS"), notes


def load_baseline():
    if not os.path.isfile(BASELINE):
        return None
    with open(BASELINE, "r", encoding="utf-8") as f:
        return json.load(f)


def cmd_list(a):
    for cs in load_cases():
        tags = [cs.get("needs", "any")]
        if cs.get("write"):
            tags.append("write")
        kinds = []
        for k in ("assert", "refuse", "deny"):
            if cs.get(k):
                kinds.append("%s x%d" % (k, len(cs[k])))
        print("%-42s [%s] %s" % (cs["name"], ",".join(tags), ", ".join(kinds)))
        print("    " + c(cs["why"], DIM))
    return 0


def cmd_show(a):
    for cs in load_cases():
        if cs["name"] in a.case:
            print(json.dumps(cs, indent=2))
    bl = load_baseline()
    if bl:
        for n in a.case:
            if n in bl.get("answers", {}):
                print("\n-- recorded baseline (%s, at=%s) --"
                      % (bl.get("recorded"), bl.get("at")))
                print(bl["answers"][n])
    return 0


def preflight(a):
    print(c("toolcheck", BOLD) + "  live=%s  at=%s" % (LIVE, a.at))
    sk, detail = scope_key()
    if sk is None:
        print("  scope    " + c("NOT COMPUTED", YELLOW) + " -- %s" % detail.get("why"))
        print("           a baseline comparison under an unknown scope cannot "
              "separate a game change from a tool regression.")
    else:
        print("  scope    %s  (%s)" % (sk, "; ".join("%s %s" % kv for kv in detail.items())))
    hk = host_key()
    print("  host dll %s" % (hk or c("ABSENT", RED)))
    ok, why = inspector_healthy()
    if ok is None:
        print("  budget   " + c("NOT READ", YELLOW) + " -- %s" % why)
    elif ok:
        print("  budget   " + c(why, GREEN))
    else:
        print("  budget   " + c(why + " -- THE INSPECTOR IS OFF FOR THIS "
                                "SESSION. Every result below would be a pass "
                                "against silence. Restart the client.", RED))
        sys.exit(2)
    return sk, hk


def cmd_run(a, record=False):
    cases = load_cases()
    if a.case:
        cases = [cs for cs in cases if cs["name"] in a.case]
    sk, hk = preflight(a)
    aw = write_allowed()
    bl = load_baseline()

    scope_changed = False
    if bl and sk and bl.get("scope") and bl["scope"] != sk:
        scope_changed = True
    at_mismatch = bool(bl and bl.get("at") and bl["at"] != a.at)

    results, answers = [], {}
    print()
    for cs in cases:
        try:
            ans = run_case(cs, a.at, aw, a.timeout)
        except Skip as e:
            print("%-42s %s -- %s" % (cs["name"], c("SKIP", YELLOW), e))
            print("    " + c("a skip is NOT a pass: this behaviour was not checked.", DIM))
            results.append((cs["name"], "SKIP"))
            continue
        except inspector.Timeout as e:
            print("%-42s %s" % (cs["name"], c("NO ANSWER", RED)))
            print("    " + str(e))
            results.append((cs["name"], "NOANSWER"))
            continue
        answers[cs["name"]] = ans
        if record:
            print("%-42s %s (%d chars)" % (cs["name"], c("recorded", GREEN), len(ans)))
            results.append((cs["name"], "RECORDED"))
            continue
        verdict, notes = judge(cs, ans)
        col = GREEN if verdict == "PASS" else RED
        print("%-42s %s" % (cs["name"], c(verdict, col)))
        for n in notes:
            print("    " + n)
        if verdict == "FAIL":
            print("    " + c("locks in: " + cs["why"], DIM))
        # drift, informational only
        old = (bl or {}).get("answers", {}).get(cs["name"])
        if old is not None and old != ans:
            if scope_changed:
                print("    " + c("DRIFT WITHHELD -- the scope key changed "
                                 "(the GAME changed); this difference is not "
                                 "attributable to the tool.", YELLOW))
            elif at_mismatch:
                print("    " + c("DRIFT WITHHELD -- baseline was recorded at=%s"
                                 % bl["at"], YELLOW))
            else:
                who = ("the host build changed (%s -> %s), so this IS attributable "
                       "to it" % (bl.get("host"), hk)) if bl.get("host") != hk else \
                      "the host build is UNCHANGED, so this is a behaviour change "\
                      "with no build behind it -- look hard"
                print("    " + c("DRIFT from baseline: %s" % who, YELLOW))
        results.append((cs["name"], verdict))
        if cs["name"] == "channel-alive" and verdict != "PASS":
            print(c("\nthe channel itself failed; every later case would match "
                    "against nothing. Stopping.", RED))
            return 2

    if record:
        out = {"recorded": time.strftime("%Y-%m-%d %H:%M:%S"), "at": a.at,
               "scope": sk, "host": hk, "answers": answers}
        with open(BASELINE, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
        print("\nwrote %s (%d answer(s))" % (BASELINE, len(answers)))
        if sk is None:
            print(c("scope could NOT be computed, so this baseline cannot later "
                    "distinguish a game change from a tool regression.", YELLOW))
        return 0

    n = {}
    for _name, v in results:
        n[v] = n.get(v, 0) + 1
    print("\n%s  %d pass, %d FAIL, %d skip, %d no-answer"
          % (c("summary", BOLD), n.get("PASS", 0), n.get("FAIL", 0),
             n.get("SKIP", 0), n.get("NOANSWER", 0)))
    if not bl:
        print(c("no baseline recorded -- drift was NOT checked for any case. "
                "Only the hand-written invariants ran.", YELLOW))
    if scope_changed:
        print(c("SCOPE CHANGED since the baseline: the game changed. Hand-written "
                "assertions still stand, but drift verdicts are withheld.", YELLOW))
    if n.get("NOANSWER"):
        return 2
    if n.get("FAIL"):
        return 1
    if scope_changed:
        return 3
    if not n.get("PASS"):
        return 4
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "record"):
        p = sub.add_parser(name)
        p.add_argument("--at", choices=["menu", "raid", "unknown"], default="unknown",
                       help="where the client is. Cases needing elsewhere SKIP.")
        p.add_argument("--case", nargs="*", default=[])
        p.add_argument("--timeout", type=float, default=40.0)
    sub.add_parser("list")
    # `selftest` sends NOTHING to the client either. It is the OFFLINE half of
    # this tool: `run` catches the inspector lying, `selftest` catches the
    # PARSERS of the inspector lying, by replaying the measured corpus in
    # tools/fixtures/inspector/ through acceptance.py, nativetabs_check.py and
    # uihooks_check.py. Two of those three passed vacuously on their own
    # command echo before it existed, and neither needed a running client to
    # do so.
    sub.add_parser("selftest")
    # `preflight` sends NOTHING to the client. It answers "would a run mean
    # anything right now" -- scope, host build, fault budget, write gate --
    # which is the question you want answered before spending a launch.
    q = sub.add_parser("preflight")
    q.add_argument("--at", choices=["menu", "raid", "unknown"], default="unknown")
    p = sub.add_parser("show")
    p.add_argument("case", nargs="+")
    a = ap.parse_args()
    if a.cmd == "list":
        return cmd_list(a)
    if a.cmd == "selftest":
        return subprocess.call(
            [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "inspectfixtures.py"), "selftest"])
    if a.cmd == "show":
        return cmd_show(a)
    if a.cmd == "preflight":
        preflight(a)
        aw = write_allowed()
        print("  write    %s" % ("liveInspectorWrite ON" if aw is True else
                                 ("off -- write cases will SKIP" if aw is False
                                  else "UNREADABLE -- write cases will SKIP")))
        bl = load_baseline()
        print("  baseline %s" % (("%s at=%s scope=%s host=%s, %d answer(s)"
                                  % (bl.get("recorded"), bl.get("at"), bl.get("scope"),
                                     bl.get("host"), len(bl.get("answers", {}))))
                                 if bl else "NONE -- drift will not be checked"))
        print("  NOTHING WAS SENT to the client; no case ran.")
        return 0
    return cmd_run(a, record=(a.cmd == "record"))


if __name__ == "__main__":
    sys.exit(main())
