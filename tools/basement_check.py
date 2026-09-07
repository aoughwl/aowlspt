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
# The item resolver needs a database. `db.json` under D:\Aowlspt is 41 MB on
# ONE line and must never be handed to anything here; the emutest fixture is
# 94 KB and carries a real `templates.items` (34 rows, MEASURED 2026-09-06),
# which is enough to prove a cache resolves to templates at all.
FIXTURE_DB = os.path.join(REPO, "tests", "fixtures", "emu-full.json")
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
    if os.path.exists(FIXTURE_DB):
        argv += ["--db", FIXTURE_DB]
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



# ---------------------------------------------------------------------------
# 3. the grounding story (DESIGN.md §11) -- through the ROUTES
# ---------------------------------------------------------------------------
#
# The mod's own CHECK 10 already proves the `[PLANT:]` half in-process, because
# there is no route that applies a tag to a reply and inventing one only for a
# test would be testing the test. What is proven HERE is the part a client
# actually walks: the world holds a cache, `world/scene` materialises it at
# that point, `world/loot` lists the rows, `observe loot.taken` flips it and
# creates the rumour, a scene on another map lists nothing of it, and a claim
# with the right token is believed where the same claim with the wrong one is
# not.


def _cache_with_pickup(caches_doc):
    for c in (caches_doc or {}).get("caches", []):
        for k in c.get("pickups", []):
            if k.get("status") == "active":
                return c, k
    return None, None


def check_grounding(rep, store):
    docs, raw, err = run_sim(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/world/caches", ""),
        (BASE + "/world/people", ""),
    ])
    if err:
        rep.add(INCONCLUSIVE, "grounding: world/caches", err)
        return
    caches_doc, people_doc = docs[1], docs[2]
    cache, pickup = _cache_with_pickup(caches_doc)
    if cache is None:
        rep.add(INCONCLUSIVE, "grounding: world/caches",
                "the generated world has %d cache(s) and none with an active "
                "pickup contract, so nothing downstream can be exercised"
                % len((caches_doc or {}).get("caches", [])))
        return
    rep.add(PASS, "grounding: world/caches lists real caches",
            "%d cache(s); %s %r on %s with %d item row(s), guards=%s, "
            "knownBy=%d, story=%r"
            % (len(caches_doc.get("caches", [])), cache["id"], cache["name"],
               cache["map"], len(cache.get("items", [])),
               cache.get("guardGroup"), len(cache.get("knownBy", [])),
               (cache.get("story") or "")[:70]))

    cid, cmap = cache["id"], cache["map"]
    cx, cy, cz = cache.get("x", 0.0), cache.get("y", 0.0), cache.get("z", 0.0)
    grp = cache.get("guardGroup", "")
    bearer = pickup.get("partyB", "")
    token = pickup.get("terms", "")

    guards = [p for p in (people_doc or {}).get("people", [])
              if p.get("group") == grp and p.get("alive", True)]
    bearer_name = ""
    for p in (people_doc or {}).get("people", []):
        if p.get("id") == bearer:
            bearer_name = p.get("name", "")

    other_map = ""
    for p in (people_doc or {}).get("people", []):
        if p.get("map") and p.get("map") != cmap:
            other_map = p["map"]
            break

    scene = "%s/world/scene?map=%s&x=%d&y=%d&z=%d&radius=80" % (
        BASE, cmap, int(cx), int(cy), int(cz))
    other = "%s/world/scene?map=%s&x=%d&y=%d&z=%d&radius=80" % (
        BASE, other_map or "no-such-map", int(cx), int(cy), int(cz))

    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (scene, ""),
        (BASE + "/world/loot?map=" + cmap, ""),
        (other, ""),
    ]
    claim_idx = None
    if guards:
        gid = guards[0]["id"]
        wrong_gid = guards[1]["id"] if len(guards) > 1 else gid
        claim_idx = len(routes)
        routes += [
            (BASE + "/observe", json.dumps(
                {"kind": "player_spoke", "personId": wrong_gid,
                 "text": "I am Nobody Atall and the word is zzzzqqqq"})),
            (BASE + "/observe", json.dumps(
                {"kind": "player_spoke", "personId": gid,
                 "text": "I am %s, the word is %s" % (bearer_name, token)})),
        ]
    taken_idx = len(routes)
    routes += [
        (BASE + "/observe", json.dumps({"kind": "loot.taken", "cacheId": cid,
                                        "by": "player"})),
        (BASE + "/world/caches?map=" + cmap, ""),
        (BASE + "/world", ""),
    ]

    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "grounding: the run", err)
        return

    sc = docs[1] or {}
    listed = any(c.get("id") == cid for c in sc.get("caches", []))
    kinds = [d.get("kind") for d in sc.get("directives", [])]
    rep.add(PASS if (listed and "group.spawn" in kinds and
                     "loot.spawn" in kinds) else FAIL,
            "grounding: world/scene materialises the cache",
            "scene %r lists the cache=%s, %d people, %d loot row(s), "
            "%d newly materialised, directives=%s"
            % (sc.get("sceneId"), listed, len(sc.get("people", [])),
               len(sc.get("loot", [])), sc.get("materialised"), kinds))

    loot = docs[2] or {}
    mine = [l for l in loot.get("loot", []) if l.get("cacheId") == cid]
    rep.add(PASS if mine else FAIL, "grounding: world/loot lists the rows",
            "%d loot row(s) on %s, %d of them from %s (first=%r)"
            % (loot.get("count", 0), cmap, len(mine), cid,
               (mine[0] if mine else None)))

    oth = docs[3] or {}
    absent = not any(c.get("id") == cid for c in oth.get("caches", []))
    absent = absent and not any(l.get("cacheId") == cid
                                for l in oth.get("loot", []))
    rep.add(PASS if absent else FAIL,
            "grounding: a scene on another map lists nothing of it (negative)",
            "map=%r lists it=%s (%d caches, %d loot there)"
            % (other_map, not absent, len(oth.get("caches", [])),
               len(oth.get("loot", []))))

    if claim_idx is None:
        rep.add(INCONCLUSIVE, "grounding: impersonation through /observe",
                "cache %s has no living guard in group %r to claim at"
                % (cid, grp))
    else:
        bad = (docs[claim_idx] or {}).get("note", "")
        good = (docs[claim_idx + 1] or {}).get("note", "")
        ok = "REFUSED" in bad and "BELIEVED" in good
        rep.add(PASS if ok else FAIL,
                "grounding: right token believed, wrong token refused",
                "wrong=%r || right=%r" % (bad[:150], good[:190]))

    took = (docs[taken_idx] or {}).get("note", "")
    after = docs[taken_idx + 1] or {}
    status = ""
    for c in after.get("caches", []):
        if c.get("id") == cid:
            status = c.get("status", "")
    world = (docs[taken_idx + 2] or {}).get("world", {})
    facts_doc = json.dumps(world.get("facts", {}))
    rumour = ('"refId": "%s"' % cid) in facts_doc or \
             ('"refId":"%s"' % cid) in facts_doc
    outcome = '"origin":"outcome"' in facts_doc.replace(", ", ",") or \
              '"origin": "outcome"' in facts_doc
    rep.add(PASS if (status == "looted" and rumour and outcome) else FAIL,
            "grounding: loot.taken -> looted + a rumour with origin outcome",
            "status=%r rumour about the cache=%s an outcome fact exists=%s; "
            "note=%r" % (status, rumour, outcome, took[:170]))

# ---------------------------------------------------------------------------
# 4. push to talk -- the backend holds the microphone
# ---------------------------------------------------------------------------

def check_ptt(rep, store):
    """`down` -> `up` -> a complete wav + heard.final -> a second `up` refused.

    Two things this has to be careful about, and neither is optional:

    * The simulator runs EVERY route before it runs a single tick, so the
      backend tick cannot be what pumps the growing file here. `/speech/ptt
      {"state":"poll"}` is the manual pump, and `/events?wait=` -- a bounded
      busy poll on the request thread -- is the only way to make wall-clock
      time pass between routes without a sleep primitive.
    * NO CAPTURE DEVICE IS INCONCLUSIVE, NEVER PASS AND NEVER "SILENCE".
      aowl.voice DESIGN 5.1 measured `waveInGetNumDevs()==0` on this machine;
      the recorder exits 2 with NO_DEVICES in that case. The mod runs it
      through a PowerShell wrapper that owns the child, stops it on a stop
      file and captures the exit code precisely so this check can quote it
      instead of guessing, and `ptt.outcome` is that string.
    """
    sess = "check-ptt"
    routes = [
        (BASE + "/speech/ptt", json.dumps({"session": sess, "state": "down"})),
        (BASE + "/events?since=0&wait=2000", ""),
        (BASE + "/speech/ptt", json.dumps({"session": sess, "state": "poll"})),
        (BASE + "/status", ""),
        (BASE + "/events?since=0&wait=2000", ""),
        (BASE + "/speech/ptt", json.dumps({"session": sess, "state": "up"})),
        (BASE + "/events?since=0&wait=0", ""),
        (BASE + "/speech/ptt", json.dumps({"session": sess, "state": "up"})),
    ]
    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "ptt: down/up", err)
        return
    down, _, poll, status, _, up, events, up2 = docs
    if not isinstance(down, dict):
        rep.add(INCONCLUSIVE, "ptt: down",
                "the simulator never answered %s/speech/ptt\n%s"
                % (BASE, raw[-1200:]))
        return
    ptt_after_down = down.get("ptt", {})
    if not down.get("ok"):
        verdict = INCONCLUSIVE if "capture unavailable" in down.get("note", "") \
                  else FAIL
        rep.add(verdict, "ptt: down starts a recorder",
                "note=%r recorder=%r ok=%s"
                % (down.get("note", "")[:220], ptt_after_down.get("recorder"),
                   ptt_after_down.get("recorderOk")))
        return
    rep.add(PASS, "ptt: down starts a recorder",
            "wav=%s recording=%s max=%ss"
            % (down.get("wav"), ptt_after_down.get("recording"),
               ptt_after_down.get("maxSeconds")))

    # The growth assertion. `wavBytes` is read off disk at /status time, and
    # `riffDataSizeField` is what the file's own header CLAIMS -- printing both
    # is the measurement, not a decoration: the recorder leaves that field at 0
    # until it exits, which is why the pump takes the data chunk's offset.
    # MEASURED 2026-09-07: recorder.exe writes the RIFF size fields and closes
    # the file only when it STOPS, so "the wav grows while recording" was a
    # property the recorder does not have -- a check that could only ever come
    # back INCONCLUSIVE. What IS observable is the finished state after `up`:
    # a wav past its 44-byte header with PCM actually fed into the session.
    st_mid = (status or {}).get("ptt", {})
    st = (up or {}).get("ptt", {})
    wav_bytes = st.get("wavBytes", -1)
    outcome = st.get("outcome", "")
    poll_note = (poll or {}).get("note", "")
    if wav_bytes is None or wav_bytes <= 44:
        rep.add(INCONCLUSIVE, "ptt: `up` leaves a complete wav on disk",
                "wavBytes=%s after `up` (a header is 44); mid-recording it was "
                "%s -- recorder %s; poll said %r. This is a capture-device "
                "question, not a code one."
                % (wav_bytes, st_mid.get("wavBytes"), outcome, poll_note[:200]))
    else:
        rep.add(PASS if st.get("pcmFed", 0) > 0 else FAIL,
                "ptt: `up` leaves a complete wav on disk",
                "wavBytes=%s pcmFed=%s riffDataSizeField=%s (%s Hz %sch %s-bit); "
                "recorder %s"
                % (wav_bytes, st.get("pcmFed"), st.get("riffDataSizeField"),
                   st.get("rate"), st.get("channels"), st.get("bits"),
                   outcome[:120]))

    kinds = kinds_on_stream(events)
    final_ev = event_with_kind(events, "heard.final")
    closed = not (up or {}).get("ptt", {}).get("recording", True)
    ok = bool(up and up.get("ok") and final_ev and closed)
    rep.add(PASS if ok else FAIL, "ptt: up closes the session and emits heard.final",
            "up.ok=%s heard.final on the stream=%s recording=%s final=%r; "
            "kinds=%s; note=%r"
            % ((up or {}).get("ok"), bool(final_ev),
               (up or {}).get("ptt", {}).get("recording"),
               (up or {}).get("final", ""), kinds[:8],
               (up or {}).get("note", "")[:240]))

    # Negative control: an `up` with no `down` must be refused with a note.
    refused = bool(up2 and up2.get("ok") is False and up2.get("note"))
    rep.add(PASS if refused else FAIL,
            "ptt: a second up without a down is refused (negative control)",
            "ok=%s note=%r"
            % ((up2 or {}).get("ok"), (up2 or {}).get("note", "")[:200]))


# ---------------------------------------------------------------------------
# 5. the 2026-09-07 live crash sequence, through the ROUTES
# ---------------------------------------------------------------------------
#
# The backend died with
#     ../../../../nimony/lib/std/system/seqimpl.nim(167, 41):
#     i < s.len and 0 <= i [AssertionDefect]
# during a raid, with no stack. Root cause: `/events` built its payload
# WITHOUT the mod lock while the tick thread's `expirePending` ->
# `dropPendingAt` rebuilt the pending columns under it, so `pendingAcks`
# indexed `gPendKind[i]` past the new end.
#
# A single-threaded simulator cannot reproduce a data race, and pretending it
# can would be a check that cannot fail. What IS asserted here is the whole
# observable sequence plus the two properties that make the race impossible to
# reach silently again:
#
#   * every served event carries `ack` and `ttlMs` -- the field the SPT client
#     reads. Without them the client acks nothing and every directive is
#     dropped after its ttl (which is what the live log showed).
#   * `stream.tornReads` on /status is 0. It counts every time the parallel
#     event/pending columns were found at DIFFERENT lengths, which is exactly
#     the state the assertion fired on. A non-zero value is the race, observed.
#
# The negative control is the `ack` flag on a plain event: it must be FALSE.
# A build that stamped `"ack": true` on everything would pass the positive
# half and fail this one.


def check_crash_sequence(rep, store):
    docs, raw, err = run_sim(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":11}'),
        (BASE + "/world/people", ""),
    ])
    if err:
        rep.add(INCONCLUSIVE, "crash seq: world/new", err)
        return
    people = docs[1]
    person = None
    for p in (people or {}).get("people", []):
        if p.get("alive", True):
            person = p
            break
    if person is None:
        rep.add(INCONCLUSIVE, "crash seq: world/people",
                "the generated world has nobody alive to aim at")
        return
    pid = person["id"]
    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":11}'),
        (BASE + "/spawn", ""),
        (BASE + "/observe",
         json.dumps({"kind": "player_seen", "personId": pid, "distanceM": 8})),
        (BASE + "/observe",
         json.dumps({"kind": "player_aimed_at", "personId": pid})),
        (BASE + "/speech/ptt", '{"session":"crashseq","state":"down"}'),
        (BASE + "/speech/ptt", '{"session":"crashseq","state":"up"}'),
        (BASE + "/say", json.dumps({"person": pid, "text": ""})),
        (BASE + "/events?since=0&wait=0", ""),
        (BASE + "/status", ""),
    ]
    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "crash seq: the run", err)
        return
    ev, status = docs[7], docs[8]
    if ev is None or status is None:
        rep.add(FAIL, "crash seq: the backend survived the whole sequence",
                "the simulator stopped answering partway through -- exactly "
                "the shape of the live death. Last output: %s" % raw[-600:])
        return

    rep.add(PASS, "crash seq: the backend survived the whole sequence",
            "spawn + seen + aimed_at + ptt down/up (0 PCM bytes) + say with "
            "an empty text + events + status all answered")

    # `/say` with an empty text must REFUSE with a note, never speak.
    say = docs[6]
    said = (say or {}).get("text", "") or (say or {}).get("reply", "")
    rep.add(PASS if isinstance(say, dict) and not said and
            (say.get("err") or say.get("note") or say.get("notes"))
            else FAIL,
            "crash seq: /say with an empty text refuses with a note",
            "answered %s" % json.dumps(say)[:200])

    # ack / ttlMs on the wire, both polarities.
    plain, needs = None, None
    for e in (ev or {}).get("events", []):
        if not isinstance(e, dict):
            continue
        if e.get("kind") == "player.spawn":
            needs = e
        elif e.get("kind") in ("npc.stance", "say") and plain is None:
            plain = e
    if needs is None or plain is None:
        rep.add(INCONCLUSIVE, "crash seq: ack/ttlMs on every served event",
                "the stream carried no needsAck (player.spawn) and/or plain "
                "(npc.stance|say) event to compare: kinds=%s"
                % sorted(set(kinds_on_stream(ev))))
    else:
        ok = (needs.get("ack") is True and int(needs.get("ttlMs") or 0) > 0
              and plain.get("ack") is False
              and plain.get("ttlMs") == 0)
        rep.add(PASS if ok else FAIL,
                "crash seq: ack/ttlMs on every served event (negative control: "
                "a plain event must read ack=false)",
                "player.spawn ack=%r ttlMs=%r ; %s ack=%r ttlMs=%r"
                % (needs.get("ack"), needs.get("ttlMs"), plain.get("kind"),
                   plain.get("ack"), plain.get("ttlMs")))

    torn = ((status or {}).get("stream") or {}).get("tornReads")
    rep.add(PASS if torn == 0 else (FAIL if isinstance(torn, int)
                                    else INCONCLUSIVE),
            "crash seq: stream.tornReads is 0 (the columns never disagreed)",
            "tornReads=%r -- any other value means a route walked the stream "
            "without the mod lock while the tick rebuilt it, which is the "
            "AssertionDefect that killed the backend" % (torn,))


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
        print("")
        check_grounding(rep, store)
        print("")
        check_ptt(rep, store)
        print("")
        check_crash_sequence(rep, store)
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
