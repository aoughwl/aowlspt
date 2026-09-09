#!/usr/bin/env python3
"""Negative assertion: NO skill's Progress advances while nobody is in a raid.

The question this answers is "does the SERVER grant skill progress from
elapsed wall-clock".  It is deliberately a negative -- "nothing moved" can be
falsified; "the number I wrote is the number I read" cannot (CLAUDE.md 9b).

Read-only.  It creates no profile and touches no file in the live install; it
POSTs `/client/game/profile/list` exactly twice, the same call the client makes
on its own every menu refresh.

Three verdicts, never two.  INCONCLUSIVE is returned -- not PASS -- when the
window cannot be trusted: a raid started or ended inside it (skill progress
SHOULD move then), the two reads did not see the same set of profiles, or the
backend did not answer.  "I could not look" is not a pass.

  python tools/skillstill.py --minutes 5
  python tools/skillstill.py --minutes 0.1 --mutate   # must go red

`--mutate` forges a +1.0 Progress into the second snapshot.  A comparator that
still says PASS under `--mutate` is not a check.

Fact #123: the backend ALWAYS deflates unless the request asks for identity.
"""
import argparse, glob, http.client, json, os, ssl, sys, time, zlib

LOGS = r"D:\Aowlspt\Logs"


def call(port, path, body=b"{}", session=""):
    ctx = ssl._create_unverified_context()
    c = http.client.HTTPSConnection("127.0.0.1", port, timeout=30, context=ctx)
    c.request("POST", path, body, {"Accept-Encoding": "identity",
                                   "Content-Type": "application/json",
                                   "Cookie": "PHPSESSID=" + session})
    r = c.getresponse()
    raw = r.read()
    c.close()
    if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
        raw = zlib.decompress(raw)
    return r.status, json.loads(raw.decode("utf-8", "replace"))


def snapshot(port):
    """{profileId: {skillId: Progress}} for every PMC the server serves."""
    st, doc = call(port, "/client/game/profile/list")
    if st != 200 or doc.get("err"):
        raise RuntimeError("profile/list answered %s err=%s" % (st, doc.get("err")))
    out = {}
    for p in doc.get("data") or []:
        if p.get("Info", {}).get("Side") not in ("Usec", "Bear"):
            continue
        out[p["_id"]] = {s["Id"]: float(s.get("Progress") or 0.0)
                         for s in p.get("Skills", {}).get("Common", [])}
    return out


def raid_markers():
    """Count of raid start/end lines the CLIENT has logged, so far.

    Read from the client's own backend log rather than inferred from our
    server's state: the point is to notice a raid we did not cause.  Returns
    None when there is no client log at all, which is itself inconclusive
    rather than clean.
    """
    dirs = sorted(glob.glob(os.path.join(LOGS, "log_*")), key=os.path.getmtime)
    if not dirs:
        return None
    hits = glob.glob(os.path.join(dirs[-1], "*backend_000.log"))
    if not hits:
        return None
    n = 0
    with open(hits[-1], encoding="utf-8", errors="replace") as f:
        for line in f:
            if "/client/match/local/start" in line or "/client/match/local/end" in line \
               or "/client/raid/configuration" in line:
                n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=443)
    ap.add_argument("--minutes", type=float, default=5.0)
    ap.add_argument("--mutate", action="store_true",
                    help="forge progress into the second read; the check MUST fail")
    args = ap.parse_args()

    try:
        before = snapshot(args.port)
        marks0 = raid_markers()
    except Exception as e:
        print("INCONCLUSIVE  skillstill  first read failed: %s" % e)
        return 2
    if not before:
        print("INCONCLUSIVE  skillstill  the server served no PMC profile")
        return 2

    time.sleep(args.minutes * 60.0)

    try:
        after = snapshot(args.port)
        marks1 = raid_markers()
    except Exception as e:
        print("INCONCLUSIVE  skillstill  second read failed: %s" % e)
        return 2

    if marks0 is None or marks1 is None:
        print("INCONCLUSIVE  skillstill  no client log to rule a raid out of the window")
        return 2
    if marks1 != marks0:
        print("INCONCLUSIVE  skillstill  a raid started or ended inside the window "
              "(%d -> %d markers); skill progress is ALLOWED to move" % (marks0, marks1))
        return 2
    if set(after) != set(before):
        print("INCONCLUSIVE  skillstill  the profile set changed inside the window")
        return 2

    if args.mutate:
        pid = sorted(after)[0]
        sid = sorted(after[pid])[0] if after[pid] else "Endurance"
        after[pid][sid] = after[pid].get(sid, 0.0) + 1.0

    moved = []
    for pid, sk in after.items():
        for sid, prog in sk.items():
            was = before[pid].get(sid)
            if was is None or prog > was:
                moved.append("%s.%s %s -> %s" % (pid[-6:], sid, was, prog))
    if moved:
        print("FAIL          skillstill  %d skill(s) advanced with no raid: %s"
              % (len(moved), "; ".join(moved[:6])))
        return 1
    n = sum(len(v) for v in before.values())
    print("PASS          skillstill  none of %d served skill entries advanced over %.1f min"
          % (n, args.minutes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
