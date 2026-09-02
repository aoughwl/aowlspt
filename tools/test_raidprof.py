r"""test_raidprof.py -- prove raidprof's phase attribution CAN be wrong.

`raidprof.py --phases` splits launch -> GameRunned into phases and blames
each second on server / parse / client. A splitter that always sums to the
total cannot be caught lying by looking at real sessions, because real
sessions have no known answer. These synthetic logs do.

Cases:
  1. known attribution: two overlapping requests (server union must count
     the overlap ONCE) whose Response lines are stamped AFTER ParseSeconds
     (server must NOT swallow parse), and 3 bots before GamePooled.
  2. mirrored lines: the same request/response and AIDATA lines present in
     both application_000.log and output_000.log count once.
  3. a menu-only session (no GameRunned) is INCONCLUSIVE, exit 3, and
     --compare against it refuses to print a delta.

    python tools/test_raidprof.py
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RAIDPROF = os.path.join(HERE, "raidprof.py")
V = "1.1.0.1.46777"


def line(sec, msg, ch="application"):
    base = 10 * 60 * 60  # 10:00:00
    t = base + sec
    h, rem = divmod(int(t), 3600)
    m, s = divmod(rem, 60)
    frac = int(round((t - int(t)) * 1000))
    return "2026-09-01 %02d:%02d:%02d.%03d|%s|Info|%s|%s" % (h, m, s, frac, V, ch, msg)


def req(sec, rid, route):
    return line(sec, "backend|---> Request HTTPS, id [%d]: URL: https://127.0.0.1%s. " % (rid, route))


def rsp(sec, rid, route, dl, ps):
    return line(sec, "backend|<--- Response HTTPS, id [%d]: URL: https://127.0.0.1%s, "
                     "DownloadSeconds: %.3f, ParseSeconds: %.3f, SumSeconds: %.3f, responseText: x"
                % (rid, route, dl, ps, dl + ps))


def raid_session(mirror=False):
    """A full launch->GameRunned session with a known answer."""
    app = [
        line(0.0, "driveType:SSD"),
        req(10.0, 1, "/client/game/mode"),
        rsp(10.1, 1, "/client/game/mode", 0.05, 0.02),
        # two overlapping statics: server union = [12.0,14.0] = 2.0s, parse = 3.0s
        req(12.0, 2, "/client/items"),
        req(12.0, 3, "/client/locale/en"),
        rsp(13.5, 3, "/client/locale/en", 1.0, 0.5),   # server end 13.0
        rsp(16.5, 2, "/client/items", 2.0, 2.5),       # server end 14.0
        req(20.0, 4, "/client/game/profile/select"),
        rsp(20.1, 4, "/client/game/profile/select", 0.05, 0.02),
        line(30.0, "scene preset path:maps/woods_preset.bundle rcid:x"),
        line(30.0, "TRACE-NetworkGameMatching G"),
        line(40.0, "TRACE-NetworkGameMatching I"),
        line(90.0, "LocationLoaded:56 real:66.5 diff:10.5"),
        line(92.0, "GameCreated:57.7(1.34) real:68.33(1.36) diff:10.63"),
        line(100.0, "PlayerSpawnEvent:61.28(61.28) real:78.9(78.9) diff:17.62"),
        line(101.0, "AIDATA create   Player id:41", "aiData"),
        line(102.0, "AIDATA create   Player id:42", "aiData"),
        line(103.0, "AIDATA create   Player id:43", "aiData"),
        line(120.0, "GamePooled:80.08(22.38) real:99.12(30.79) diff:19.04"),
        line(140.0, "GameRunned:92.53(12.44) real:120.81(21.68) diff:28.28"),
    ]
    out = list(app) if mirror else [line(0.0, "Version: x", "output")]
    return app, out


def menu_session():
    app = [
        line(0.0, "driveType:SSD"),
        req(10.0, 1, "/client/game/mode"),
        rsp(10.1, 1, "/client/game/mode", 0.05, 0.02),
        req(12.0, 2, "/client/items"),
        rsp(16.5, 2, "/client/items", 2.0, 2.5),
        line(200.0, "Empty _formatTemplate in LocalizedText"),
    ]
    return app, [line(0.0, "Version: x", "output")]


def write_session(root, name, app, out):
    d = os.path.join(root, name)
    os.makedirs(d)
    with open(os.path.join(d, "%s application_000.log" % name), "w", encoding="utf-8") as f:
        f.write("\n".join(app) + "\n")
    with open(os.path.join(d, "%s output_000.log" % name), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return d


def run(*args):
    p = subprocess.run([sys.executable, RAIDPROF] + list(args),
                       capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    root = tempfile.mkdtemp(prefix="raidprof-test-")
    fails = []

    def check(cond, what):
        print("  %s  %s" % ("ok  " if cond else "FAIL", what))
        if not cond:
            fails.append(what)

    try:
        write_session(root, "log_a", *raid_session())
        write_session(root, "log_b", *raid_session(mirror=True))
        write_session(root, "log_c", *menu_session())

        for name in ("log_a", "log_b"):
            print("[%s]" % name)
            rc, out = run("--logs", root, "--session", name, "--phases", "--json")
            check(rc == 0, "exit 0 on a session that reached GameRunned")
            j = json.loads(out)
            check(j["reached_gamerunned"] is True, "reached_gamerunned")
            ph = {p["name"]: p for p in j["phases"]}
            total = sum(p["seconds"] for p in j["phases"])
            check(abs(total - 140.0) < 0.01, "total = 140.0s (got %.2f)" % total)
            ls = ph["login+statics"]
            # request id 1 is the line that STARTS login+statics, so its own
            # interval [10.0, 10.1-0.02] = 0.08s and parse 0.02 are in here too.
            check(abs(ls["server_s"] - 2.08) < 0.01,
                  "server union counts the overlap once and excludes parse (%.2f, want 2.08)" % ls["server_s"])
            check(abs(ls["parse_s"] - 3.02) < 0.01, "parse sum 3.02 (%.2f)" % ls["parse_s"])
            check(ls["requests"] == 3, "3 requests in login+statics, mirrored lines not double counted (%d)" % ls["requests"])
            check(ph["pooling"]["bots"] == 3, "3 bots in pooling, mirrored AIDATA not double counted (%d)" % ph["pooling"]["bots"])
            check(ph["initial spawn"]["bots"] == 0, "0 bots in initial spawn")
            check(abs(ph["scene load"]["seconds"] - 50.0) < 0.01, "scene load 50.0s")

        print("[log_c: never reached GameRunned]")
        rc, out = run("--logs", root, "--session", "log_c", "--phases")
        check(rc == 3, "exit 3 (INCONCLUSIVE) when GameRunned never logged (got %d)" % rc)
        check("INCONCLUSIVE" in out, "says INCONCLUSIVE")
        check("initial spawn" not in out, "does not print phases it never reached")

        print("[compare a vs c]")
        rc, out = run("--logs", root, "--compare", "log_a", "log_c")
        check(rc == 3, "compare against an unfinished session exits 3 (got %d)" % rc)
        check("INCONCLUSIVE" in out and "->" not in out.split("\n")[3],
              "compare refuses to print a total delta it cannot stand behind")

        print("[compare a vs b]")
        rc, out = run("--logs", root, "--compare", "log_a", "log_b")
        check(rc == 0, "compare of two finished sessions exits 0")
        check("140.0s -> 140.0s" in out, "identical sessions show a zero delta")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    if fails:
        print("\nFAIL: %d check(s) failed" % len(fails))
        return 1
    print("\nPASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
