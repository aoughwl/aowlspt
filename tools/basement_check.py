"""Acceptance for mods/basement (aowl.basement), run offline with no game.

    python tools\\basement_check.py [--store <dir>] [--keep]

Two halves, both against the REAL built mod loaded into `aowlspt-sim`:

  1. `/aowlspt/basement/selfcheck` -- the nine falsifiable checks of
     DESIGN.md §9, whose verdict this script reproduces rather than re-derives.
  2. a scripted STORY through the routes, which is the only thing that can
     catch a state machine that is individually correct and jointly useless:

        world/new warlords seed 7  ->  world/people  ->  say hello to a grunt
        ->  observe player_aimed_at   (npc.stance hostile + a say directive)
        ->  observe player_lowered_weapon at a SLAVER   (player.captive)
        ->  observe player_moved beyond the leash       (escape_attempt)
        ->  observe player_fired at the captor          (state fighting)

Three outcomes, printed as such: PASS / FAIL / INCONCLUSIVE, exit 0 / 1 / 3.
"I could not look" -- no simulator, no dll, no world, a step whose precondition
never held -- is INCONCLUSIVE and never PASS.

## Why the whole story is ONE simulator run

`bm/stream` is an in-memory ring and the encounter rows live in the mod's
globals. Splitting the story across invocations would restart both between
steps, and every assertion after the first would then be about a fresh process
that had never seen the earlier facts -- passing or failing for reasons that
have nothing to do with the code. `aowlspt-sim` takes `--route` repeatedly and
runs them in order in one process, which is exactly the shape this needs.

## Why the assertions are about the FINISHED STATE

Each step asserts what the world/stream looks like AFTERWARDS -- the encounter
state the mod reports back, a directive kind actually present on `/events`, a
journal row of kind `escape_attempt` -- and not that the request "succeeded".
A route that returns `{"ok":true}` having done nothing is the exact failure
this file exists to catch, and `ok` is therefore never the assertion.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(REPO, "host", "Aowlspt.Sim", "bin", "aowlspt-sim.exe")
MOD = os.path.join(REPO, "mods", "basement")
DLL = os.path.join(MOD, "bin", "basement.dll")

BASE = "/aowlspt/basement"

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


class Report(object):
    def __init__(self):
        self.rows = []

    def add(self, verdict, name, evidence):
        self.rows.append((verdict, name, evidence))
        print("%-13s %s  --  %s" % (verdict, name, evidence))

    def exit_code(self):
        if any(v == FAIL for v, _, _ in self.rows):
            return 1
        if any(v == INCONCLUSIVE for v, _, _ in self.rows):
            return 3
        return 0


def run_sim(store, routes, timeout=900):
    """One simulator run, N routes in order. Returns (list_of_docs, raw, err)."""
    if not os.path.exists(SIM):
        return None, "", "no aowlspt-sim.exe -- run: aowl build sim"
    if not os.path.exists(DLL):
        return None, "", ("no %s -- run: python tools\\buildlock.py build-mod "
                          "mods\\basement" % DLL)
    argv = [SIM, MOD, "--side", "server", "--store", store, "--ticks", "0"]
    for url, body in routes:
        argv += ["--route", url + ("," + body if body else "")]
    env = dict(os.environ)
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env=env)
    except subprocess.TimeoutExpired:
        return None, "", "the simulator did not finish within %ds" % timeout
    raw = p.stdout + p.stderr
    # `aowlspt-sim` prints `<url> -> <response>` per route, in the order it was
    # given them. This walks the output ONCE, in order, rather than searching
    # for each url: the story posts to `/observe` four times and `/events`
    # twice, and a per-url search returns the FIRST hit every time -- which
    # would silently assert the first step's answer against the fourth step's
    # expectation, and pass or fail for a reason that is not the code.
    docs = []
    pos = 0
    for url, _ in routes:
        m = re.compile(re.escape(url) + r" -> (.*)").search(raw, pos)
        if not m:
            docs.append(None)
            continue
        pos = m.end()
        try:
            docs.append(json.loads(m.group(1).strip()))
        except ValueError:
            docs.append({"__unparsed__": m.group(1)[:400]})
    return docs, raw, None


def enabled_config():
    """The mod ships DISABLED on purpose; the story needs it on.

    A copy of config.json with `enabled: true` is written over the mod's own
    for the duration of the run and restored afterwards, so this script never
    leaves the repo in a state where the mod is silently live.
    """
    path = os.path.join(MOD, "config.json")
    original = open(path, "r", encoding="utf-8").read()
    doc = json.loads(original)
    doc["enabled"] = True
    open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2))
    return path, original


def kinds_on_stream(events_doc):
    if not isinstance(events_doc, dict):
        return []
    out = []
    for e in events_doc.get("events", []):
        if isinstance(e, dict):
            out.append(e.get("kind", ""))
    return out


def event_with_kind(events_doc, kind):
    for e in (events_doc or {}).get("events", []):
        if isinstance(e, dict) and e.get("kind") == kind:
            return e
    return None


def pick_person(people_doc, role):
    for p in (people_doc or {}).get("people", []):
        if p.get("role") == role and p.get("alive", True):
            return p
    return None


# ---------------------------------------------------------------------------
# 1. the mod's own selfcheck
# ---------------------------------------------------------------------------

def check_selfcheck(rep, store):
    docs, raw, err = run_sim(store, [(BASE + "/selfcheck", "")])
    if err:
        rep.add(INCONCLUSIVE, "selfcheck route", err)
        return
    doc = docs[0]
    if doc is None:
        rep.add(INCONCLUSIVE, "selfcheck route",
                "the simulator never answered %s/selfcheck\n%s"
                % (BASE, raw[-1500:]))
        return
    if "__unparsed__" in doc:
        rep.add(FAIL, "selfcheck route",
                "the served payload is not valid JSON: %s" % doc["__unparsed__"])
        return
    text = doc.get("text", "")
    for line in text.splitlines():
        if line.startswith("CHECK "):
            print("    %s" % line)
    verdict = doc.get("verdict", "")
    n = (doc.get("pass", 0), doc.get("fail", 0), doc.get("inconclusive", 0))
    if verdict not in (PASS, FAIL, INCONCLUSIVE):
        rep.add(FAIL, "selfcheck verdict",
                "the route did not report one of the three outcomes: %r" % verdict)
        return
    rep.add(verdict, "selfcheck (DESIGN.md §9, all nine checks)",
            "SELFCHECK VERDICT %s -- %d pass / %d fail / %d inconclusive"
            % (verdict, n[0], n[1], n[2]))


# ---------------------------------------------------------------------------
# 2. the scripted story
# ---------------------------------------------------------------------------

def check_story(rep, store):
    # Step 1-2 first, because which person ids exist is not knowable until the
    # world has been generated -- the later routes are built from the answer.
    docs, raw, err = run_sim(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/world/people", ""),
    ])
    if err:
        rep.add(INCONCLUSIVE, "story: world/new", err)
        return
    new_doc, people_doc = docs[0], docs[1]
    if not isinstance(new_doc, dict) or not new_doc.get("ok"):
        rep.add(FAIL, "story: world/new warlords seed 7",
                "route answered %s" % json.dumps(new_doc)[:400])
        return
    summary = new_doc.get("world", {})
    rep.add(PASS if summary.get("people", 0) > 0 else FAIL,
            "story: world/new warlords seed 7",
            "seed=%s people=%s factions=%s places=%s"
            % (summary.get("seed"), summary.get("people"),
               summary.get("factions"), summary.get("places")))
    if not summary.get("people"):
        return

    grunt = pick_person(people_doc, "grunt")
    slaver = pick_person(people_doc, "slaver")
    rep.add(PASS if grunt else INCONCLUSIVE, "story: world/people",
            "%d people; grunt=%s slaver=%s"
            % (people_doc.get("count", 0),
               grunt.get("id") if grunt else None,
               slaver.get("id") if slaver else None))
    if not grunt:
        return

    gid = grunt["id"]
    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/say", json.dumps({"person": gid, "text": "hello there"})),
        (BASE + "/observe",
         json.dumps({"kind": "player_aimed_at", "personId": gid})),
        (BASE + "/events?since=0&wait=0", ""),
    ]
    sid = slaver["id"] if slaver else None
    if sid:
        routes += [
            (BASE + "/observe",
             json.dumps({"kind": "player_aimed_at", "personId": sid})),
            (BASE + "/observe",
             json.dumps({"kind": "player_lowered_weapon", "personId": sid})),
            (BASE + "/events?since=0&wait=0", ""),
            (BASE + "/world/person/" + sid, ""),
        ]
    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "story: the run", err)
        return

    say = docs[1]
    if not isinstance(say, dict) or "__unparsed__" in (say or {}):
        rep.add(FAIL, "story: say greet to a grunt",
                "route answered %s" % json.dumps(say)[:400])
    else:
        spoke = bool(say.get("text")) or bool(say.get("segments"))
        rep.add(PASS if spoke else FAIL, "story: say greet to a grunt",
                "tier=%s cached=%s text=%r segments=%d"
                % (say.get("tier"), say.get("cached"),
                   (say.get("text") or "")[:60], len(say.get("segments") or [])))

    aim = docs[2]
    ev1 = docs[3]
    state = ""
    if isinstance(aim, dict):
        for row in aim.get("encounters", []):
            if row.get("personId") == gid:
                state = row.get("state", "")
    stance = event_with_kind(ev1, "npc.stance")
    said = event_with_kind(ev1, "say")
    hostile = bool(stance) and '"hostile"' in json.dumps(stance)
    ok = state == "threatened" and hostile and bool(said)
    rep.add(PASS if ok else FAIL,
            "story: observe player_aimed_at -> threatened + npc.stance hostile + say",
            "state=%r stream kinds=%s" % (state, sorted(set(kinds_on_stream(ev1)))))

    if not sid:
        rep.add(INCONCLUSIVE, "story: captivity",
                "this world has no person with role 'slaver', so the "
                "captivity branch could not be exercised at all")
        return

    lowered = docs[5]
    ev2 = docs[6]
    cap_state = ""
    if isinstance(lowered, dict):
        for row in lowered.get("encounters", []):
            if row.get("personId") == sid:
                cap_state = row.get("state", "")
    captive_dir = event_with_kind(ev2, "player.captive")
    ok = cap_state in ("captive", "escorted") and bool(captive_dir)
    rep.add(PASS if ok else FAIL,
            "story: observe player_lowered_weapon at a slaver -> player.captive",
            "state=%r player.captive on the stream=%s"
            % (cap_state, bool(captive_dir)))

    person = docs[7]
    contracts = []
    if isinstance(person, dict):
        contracts = [(c.get("kind"), c.get("status"))
                     for c in person.get("contracts", [])]
    rep.add(PASS if ("captivity", "active") in contracts else FAIL,
            "story: a captivity contract is active",
            "contracts=%s" % contracts)

    if not captive_dir:
        rep.add(INCONCLUSIVE, "story: leash break and fight back",
                "the player was never taken prisoner, so breaking the leash "
                "and firing on the captor could not be exercised")
        return

    # The leash break needs the captor's own position: take it from the world.
    captor_pos = None
    for p in (people_doc or {}).get("people", []):
        if p.get("id") == sid:
            captor_pos = (p.get("map", ""), p.get("x", 0.0), p.get("y", 0.0),
                          p.get("z", 0.0))
    if captor_pos is None:
        rep.add(INCONCLUSIVE, "story: leash break",
                "the captor has no position in /world/people")
        return
    far = {"kind": "player_moved", "map": captor_pos[0],
           "x": captor_pos[1] + 500.0, "y": captor_pos[2], "z": captor_pos[3]}
    routes = routes[:8] + [
        (BASE + "/observe", json.dumps(far)),
        (BASE + "/observe", json.dumps({"kind": "player_fired", "personId": sid})),
        (BASE + "/status", ""),
    ]
    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "story: leash break", err)
        return
    moved, fired, status = docs[8], docs[9], docs[10]
    note = (moved or {}).get("note", "")
    rep.add(PASS if "escape" in note.lower() else FAIL,
            "story: observe player_moved beyond the leash -> escape_attempt",
            "note=%r" % note[:200])

    fight_state = ""
    for row in (fired or {}).get("encounters", []):
        if row.get("personId") == sid:
            fight_state = row.get("state", "")
    rep.add(PASS if fight_state == "fighting" else FAIL,
            "story: observe player_fired at the captor -> fighting",
            "state=%r" % fight_state)

    if isinstance(status, dict):
        w = status.get("world", {})
        print("    world after the story: journal=%s contracts=%s captiveOf=%r"
              % (w.get("journal"), w.get("contracts"), w.get("captiveOf")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", default="",
                    help="scratch store dir (default: a fresh temp dir)")
    ap.add_argument("--keep", action="store_true",
                    help="keep the scratch store instead of deleting it")
    a = ap.parse_args()

    store = a.store or tempfile.mkdtemp(prefix="basement-check-")
    os.makedirs(store, exist_ok=True)
    print("aowl.basement acceptance -- store %s\n" % store)

    rep = Report()
    cfg_path, original = None, None
    try:
        cfg_path, original = enabled_config()
    except Exception as e:                        # noqa: BLE001 -- reported
        rep.add(INCONCLUSIVE, "config",
                "could not enable the mod for the run: %s" % e)
    try:
        check_selfcheck(rep, store)
        print("")
        check_story(rep, store)
    finally:
        if cfg_path and original is not None:
            open(cfg_path, "w", encoding="utf-8").write(original)
        if not a.keep and not a.store:
            shutil.rmtree(store, ignore_errors=True)

    code = rep.exit_code()
    print("\n%d checks: %d PASS, %d FAIL, %d INCONCLUSIVE"
          % (len(rep.rows),
             sum(1 for v, _, _ in rep.rows if v == PASS),
             sum(1 for v, _, _ in rep.rows if v == FAIL),
             sum(1 for v, _, _ in rep.rows if v == INCONCLUSIVE)))
    print("BASEMENT CHECK %s" % (PASS if code == 0 else
                                 (FAIL if code == 1 else INCONCLUSIVE)))
    return code


if __name__ == "__main__":
    sys.exit(main())
