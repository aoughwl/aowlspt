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
import glob
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

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


def enabled_config(overrides=None):
    """The mod ships DISABLED on purpose; the story needs it on.

    A copy of config.json with `enabled: true` (plus any `--set key=value`
    overrides, e.g. `--set ttsEngine=kokoro --set kokoroUrl=http://127.0.0.1:6972`
    to run the selfcheck against a test server) is written over the mod's own
    for the duration of the run and restored afterwards, so this script never
    leaves the repo in a state where the mod is silently live.
    """
    path = os.path.join(MOD, "config.json")
    # BYTES in, BYTES back out. MEASURED 2026-09-07 (agent R): a UTF-8 BOM on
    # config.json made a plain json.load fail and every one of 48 checks report
    # "aowl.basement is disabled" -- 20 minutes lost to 3 bytes. And restoring
    # via json.dumps re-indented and re-ordered the tracked file under
    # concurrent agents. So: decode with utf-8-sig, and hand the caller the
    # exact original bytes to put back.
    with open(path, "rb") as fh:
        original = fh.read()
    doc = json.loads(original.decode("utf-8-sig"))
    doc["enabled"] = True
    for k, v in (overrides or {}).items():
        doc[k] = v
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(doc, indent=2))
    return path, original


def parse_set(items):
    out = {}
    for it in items or []:
        if "=" not in it:
            raise SystemExit("--set wants KEY=VALUE, got %r" % it)
        k, v = it.split("=", 1)
        try:
            out[k] = json.loads(v)
        except ValueError:
            out[k] = v
    return out


# ---------------------------------------------------------------------------
# 0. the voice table -- static, no simulator: every tag gen can emit is mapped,
#    and no two tags collapse to the same voice under either local engine.
# ---------------------------------------------------------------------------

# The 54 ids in voices-v1.0.bin, MEASURED 2026-09-07 from GET /health on the
# kokoro server (tools/kokoro/server.py). A tag pointing at any other id is a
# 400 from the server at synth time, so it is caught here instead.
KOKORO_VOICES = set("""af_alloy af_aoede af_bella af_heart af_jessica af_kore
af_nicole af_nova af_river af_sarah af_sky am_adam am_echo am_eric am_fenrir
am_liam am_michael am_onyx am_puck am_santa bf_alice bf_emma bf_isabella
bf_lily bm_daniel bm_fable bm_george bm_lewis ef_dora em_alex em_santa
ff_siwis hf_alpha hf_beta hm_omega hm_psi if_sara im_nicola jf_alpha
jf_gongitsune jf_nezumi jf_tebukuro jm_kumo pf_dora pm_alex pm_santa
zf_xiaobei zf_xiaoni zf_xiaoxiao zf_xiaoyi zm_yunjian zm_yunxi zm_yunxia
zm_yunyang""".split())


def archetype_rows(doc):
    if isinstance(doc, list):
        return doc
    for k in ("archetypes", "rows", "items"):
        if isinstance(doc.get(k), list):
            return doc[k]
    return [v for v in doc.values() if isinstance(v, dict)]


def check_voices(rep):
    data = os.path.join(MOD, "data")
    try:
        voices = json.load(open(os.path.join(data, "voices.json"), encoding="utf-8"))
        arch = json.load(open(os.path.join(data, "archetypes.json"), encoding="utf-8"))
    except (OSError, ValueError) as e:
        rep.add(FAIL, "voices.json loads", str(e))
        return
    tags = voices.get("tags", {})
    emitted = set()
    for a in archetype_rows(arch):
        for v in a.get("voices", []):
            emitted.add(v)
    if not emitted:
        rep.add(INCONCLUSIVE, "voice tags gen emits",
                "archetypes.json lists no `voices`, nothing to cover")
    missing = sorted(emitted - set(tags))
    rep.add(PASS if not missing else FAIL, "every gen voice tag is mapped",
            "%d tags emitted by archetypes.json, %d in voices.json, missing: %s"
            % (len(emitted), len(tags), missing or "none"))
    vdir = os.path.join(data, "voices")
    stems = set(f[:-4] for f in os.listdir(vdir) if f.lower().endswith(".wav"))         if os.path.isdir(vdir) else set()
    seen_k, seen_c, dup_k, dup_c, bad_id, bad_stem = {}, {}, [], [], [], []
    for t, row in tags.items():
        k = (row.get("kokoro"), round(float(row.get("speed", 1.0)), 3))
        c = (row.get("chatterbox"), round(float(row.get("exaggeration", 0.5)), 3),
             round(float(row.get("cfg_weight", 0.5)), 3))
        if k in seen_k:
            dup_k.append((t, seen_k[k]))
        seen_k[k] = t
        if c in seen_c:
            dup_c.append((t, seen_c[c]))
        seen_c[c] = t
        if row.get("kokoro") not in KOKORO_VOICES:
            bad_id.append((t, row.get("kokoro")))
        if row.get("chatterbox") not in stems and row.get("chatterbox") != "default":
            bad_stem.append((t, row.get("chatterbox")))
    rep.add(PASS if not dup_k else FAIL, "no two tags share a kokoro (id, speed)",
            "%d tags, duplicates: %s" % (len(tags), dup_k or "none"))
    rep.add(PASS if not dup_c else FAIL,
            "no two tags share a chatterbox (stem, exaggeration, cfg_weight)",
            "duplicates: %s" % (dup_c or "none"))
    rep.add(PASS if not bad_id else FAIL, "every kokoro id is one voices-v1.0.bin has",
            "unknown: %s" % (bad_id or "none"))
    rep.add(PASS if not bad_stem else FAIL,
            "every chatterbox stem is a wav under data/voices",
            "%d wavs on disk (%s); unknown: %s"
            % (len(stems), " ".join(sorted(stems)), bad_stem or "none"))
    pools = voices.get("pools", {})
    for pool, ok_set, name in (("kokoro", KOKORO_VOICES, "kokoro pool ids"),
                               ("chatterbox", stems | {"default"}, "chatterbox pool stems")):
        bad = [x for x in pools.get(pool, []) if x not in ok_set]
        rep.add(PASS if not bad else FAIL, "%s exist" % name,
                "%d in pool, unknown: %s" % (len(pools.get(pool, [])), bad or "none"))


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
# ---------------------------------------------------------------------------
# the OFFSCREEN world: objectives, regions, and the map the client owns
# ---------------------------------------------------------------------------

def _groups_of(regions_doc):
    out = []
    for r in regions_doc.get("regions", []):
        for g in r.get("groups", []):
            out.append((r["map"], r["state"], g))
    return out


def _signature(regions_doc, mapname):
    """place + objective target per group on one map, in document order.

    The frozen assertion is made over THIS -- the finished state the route
    reports -- and not over a counter, so it can actually fail.
    """
    sig = []
    for r in regions_doc.get("regions", []):
        if r["map"] != mapname:
            continue
        for g in r.get("groups", []):
            o = g.get("objective") or {}
            sig.append("%s/%s/%s/%s" % (g["groupId"], g.get("place"),
                                        o.get("kind"), o.get("target")))
    return sig


def check_offscreen(rep, store):
    """Objectives exist, the emulator runs, and a raid FREEZES its map.

    Two simulator runs against ONE store: the first generates and reads the
    regions (which is where the map name comes from -- hard-coding one would
    make this pass or fail for the preset rather than for the code), the
    second reloads that saved world, tells the mod a raid started on that map,
    advances two hours and reads the regions again.
    """
    docs, raw, err = run_sim(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":11}'),
        (BASE + "/world/regions", ""),
    ])
    if err or not docs or docs[0] is None or docs[1] is None:
        rep.add(INCONCLUSIVE, "offscreen: world/regions answers",
                err or "the simulator did not answer world/new + world/regions")
        return
    pre = docs[1]
    groups = _groups_of(pre)
    if not groups:
        rep.add(INCONCLUSIVE, "offscreen: every group has an objective",
                "the generated world has no groups on any map")
        return

    without = [g["groupId"] for _, _, g in groups if not g.get("objective")]
    taken = {}
    collisions = []
    for _, _, g in groups:
        o = g.get("objective") or {}
        key = (g.get("factionId"), o.get("targetKind"), o.get("target"))
        if key in taken:
            collisions.append("%s and %s -> %s" % (taken[key], g["groupId"],
                                                   o.get("target")))
        taken[key] = g["groupId"]
    rep.add(PASS if (not without and not collisions) else FAIL,
            "offscreen: every group has an objective and no two of one faction share a target",
            "%d group(s) across %d map(s); without an objective: %s; "
            "same-faction target collisions: %s"
            % (len(groups), len(pre.get("regions", [])),
               without or "none", collisions or "none"))

    # the map with the most groups is the one the player will be raiding
    counts = {}
    for m, _, _ in groups:
        counts[m] = counts.get(m, 0) + 1
    ordered = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    frozen_map = ordered[0][0]
    if len(ordered) < 2:
        rep.add(INCONCLUSIVE, "offscreen: a raid FREEZES its map",
                "groups exist on only one map (%s), so freezing it leaves "
                "nothing to compare against" % frozen_map)
        return
    other_map = ordered[1][0]

    docs2, raw2, err2 = run_sim(store, [
        (BASE + "/observe", '{"kind":"raid_started","map":"%s"}' % frozen_map),
        (BASE + "/world/advance", '{"ms":7200000}'),
        (BASE + "/world/regions", ""),
    ])
    if err2 or not docs2 or docs2[2] is None:
        rep.add(INCONCLUSIVE, "offscreen: a raid FREEZES its map",
                err2 or "the second run did not answer world/regions")
        return
    post = docs2[2]
    state = dict((r["map"], r["state"]) for r in post.get("regions", []))
    frozen_same = _signature(pre, frozen_map) == _signature(post, frozen_map)
    other_moved = _signature(pre, other_map) != _signature(post, other_map)
    rep.add(PASS if (state.get(frozen_map) == "frozen" and frozen_same
                     and other_moved) else FAIL,
            "offscreen: with the player raiding %s it is frozen and %s keeps running"
            % (frozen_map, other_map),
            "state: %s=%s %s=%s; %s unchanged over 2 h: %s; %s changed: %s "
            "(frozenMap on the route: %r)"
            % (frozen_map, state.get(frozen_map), other_map,
               state.get(other_map), frozen_map, frozen_same, other_map,
               other_moved, post.get("frozenMap")))

    narrated = [r for r in post.get("regions", [])
                if (r.get("lastResolution") or {}).get("narrative")]
    rep.add(PASS if narrated else INCONCLUSIVE,
            "offscreen: something resolved where nobody was watching, with a narrative",
            ("%d region(s) report a last resolution; e.g. %s: %s"
             % (len(narrated), narrated[0]["map"],
                narrated[0]["lastResolution"]["narrative"]))
            if narrated else
            "no region resolved anything in 2 h -- possible, and not a "
            "failure of the code; CHECK 24 in the mod's own selfcheck runs 12 h")

    # a person carries the objective their group holds, on the person route
    pid = None
    for _, _, g in groups:
        if g.get("objective"):
            break
    docs3, raw3, err3 = run_sim(store, [(BASE + "/world/people", "")])
    if err3 or not docs3 or docs3[0] is None:
        rep.add(INCONCLUSIVE, "offscreen: /world/person carries the objective",
                err3 or "world/people did not answer")
        return
    people = docs3[0].get("people", [])
    if not people:
        rep.add(INCONCLUSIVE, "offscreen: /world/person carries the objective",
                "world/people listed nobody")
        return
    pid = people[0]["id"]
    docs4, raw4, err4 = run_sim(store, [(BASE + "/world/person/" + pid, "")])
    if err4 or not docs4 or docs4[0] is None:
        rep.add(INCONCLUSIVE, "offscreen: /world/person carries the objective",
                err4 or "the person route did not answer")
        return
    doc = docs4[0]
    obj = doc.get("objective")
    rep.add(PASS if (obj and obj.get("kind") and obj.get("sentence")) else
            (INCONCLUSIVE if obj is None else FAIL),
            "offscreen: /world/person/<id> carries the objective and its sentence",
            "%s: objective=%s; objectiveJournal rows=%d -- a null objective is "
            "INCONCLUSIVE (that person may be in no group), an objective with "
            "no sentence is a FAIL"
            % (pid, obj, len(doc.get("objectiveJournal", []))))


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
# 3b. the dialogue defects measured in the first SPT 4.1.5 raid
# ---------------------------------------------------------------------------
#
# Two of them, both reported by the player and both visible on the wire:
#   (a) every person aimed at barked the same one sentence, over and over,
#       because `player_aimed_at` arrives EVERY CLIENT TICK and re-fired the
#       whole threat transition each time (~40 un-acked npc.attack in two
#       minutes, and 14 TTS cache hits on two sentences);
#   (b) talking to a threatened person answered from the threat row, so the
#       conversation could not move.
#
# Both are asserted THROUGH THE ROUTES, on the served stream and the served
# reply -- not on a return value -- and both carry a negative control that can
# actually fail.


def _says(events_doc, source=None):
    out = []
    for e in (events_doc or {}).get("events", []):
        if not isinstance(e, dict) or e.get("kind") != "say":
            continue
        d = e.get("data") or {}
        if source and d.get("source") != source:
            continue
        out.append(d.get("text", ""))
    return out


def check_dialogue(rep, store):
    docs, raw, err = run_sim(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/world/people", ""),
    ])
    if err:
        rep.add(INCONCLUSIVE, "dialogue: world/new", err)
        return
    people = [p for p in (docs[1] or {}).get("people", []) if p.get("alive", True)]
    if len(people) < 2:
        rep.add(INCONCLUSIVE, "dialogue: two people to talk to",
                "the generated world has %d living person(s)" % len(people))
        return
    a, b = people[0]["id"], people[1]["id"]

    aim = lambda pid: (BASE + "/observe",
                       json.dumps({"kind": "player_aimed_at", "personId": pid}))
    # A NONCE in the utterance, because the brain's line cache is PERSISTED in
    # mods/basement/data/cache/brain.json and outlives the run: without it the
    # second run of this script answers every greeting from the cache, the
    # reply stops saying which row produced it, and the bucket assertion below
    # can only ever report INCONCLUSIVE.
    nonce = "%08x" % random.getrandbits(32)
    line = "hey there, how are you doing " + nonce
    greet = lambda pid: (BASE + "/say",
                         json.dumps({"person": pid, "text": line}))
    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        aim(a), aim(a), aim(a), aim(a), aim(a),          # 1..5, within ~2 s
        (BASE + "/events?since=0&wait=0", ""),           # 6
        greet(a),                                        # 7
        greet(b),                                        # 8  (b is not aimed at)
        greet(a),                                        # 9  negative control
        aim(b),                                          # 10
        greet(b),                                        # 11 threatened + greet
    ]
    docs, raw, err = run_sim(store, routes)
    if err:
        rep.add(INCONCLUSIVE, "dialogue: the run", err)
        return

    ev = docs[6]
    kinds = kinds_on_stream(ev)
    barks = _says(ev, "encounter")
    n_attack = kinds.count("npc.attack")
    n_stance = kinds.count("npc.stance")
    ok = len(barks) == 1 and n_attack <= 1 and n_stance == 1
    rep.add(PASS if ok else FAIL,
            "dialogue: 5 x player_aimed_at within 2 s is ONE bark and at most "
            "one npc.attack",
            "served %d encounter say(s) %r, %d npc.attack, %d npc.stance"
            % (len(barks), barks[:2], n_attack, n_stance))

    g_a, g_b, g_a2 = docs[7], docs[8], docs[9]
    for name, d in (("first greet", g_a), ("second person", g_b)):
        if not isinstance(d, dict) or "__unparsed__" in d:
            rep.add(FAIL, "dialogue: %s answered" % name,
                    "route answered %s" % json.dumps(d)[:300])
            return
    t_a = g_a.get("text", "")
    t_b = g_b.get("text", "")
    t_a2 = g_a2.get("text", "") if isinstance(g_a2, dict) else ""
    bark = barks[0] if barks else ""
    tags = [str(t) for t in (g_a.get("tags") or [])]
    attacked = any(t.upper().startswith("ATTACK") for t in tags)
    ok = (g_a.get("tier") in ("ontology", "cache") and t_a and t_a != bark
          and not attacked)
    rep.add(PASS if ok else FAIL,
            "dialogue: a greeting to a THREATENED person is answered from the "
            "table, not with the bark",
            "tier=%s text=%r ; the bark was %r ; tags=%s"
            % (g_a.get("tier"), t_a[:90], bark[:60], tags))

    rep.add(PASS if (t_a and t_b and t_a != t_b) else FAIL,
            "dialogue: two different people greeted give two different lines",
            "%r vs %r" % (t_a[:70], t_b[:70]))
    rep.add(PASS if (t_a2 == t_a and t_a) else FAIL,
            "dialogue: NEGATIVE CONTROL -- the same person greeted twice gives "
            "the IDENTICAL line (a cache hit, not a dice roll)",
            "first=%r again=%r tier=%s"
            % (t_a[:70], t_a2[:70],
               g_a2.get("tier") if isinstance(g_a2, dict) else None))

    # Which ROW answered, from the reply's own account of itself. The text
    # alone cannot settle this: a person whose attitude is already wary answers
    # a greeting from the wary row whether or not a rifle is on them, and
    # comparing texts would call that a regression.
    def _bucket(d):
        for n in (d or {}).get("notes", []) or []:
            m = re.search(r"ontology row \S+ x (\w+)", str(n))
            if m:
                return m.group(1)
        return None

    g_b2 = docs[11]
    aim_b = docs[10]
    st = ""
    for row in (aim_b or {}).get("encounters", []):
        if row.get("personId") == b:
            st = row.get("state", "")
    calm_bucket = _bucket(g_b)
    threat_bucket = _bucket(g_b2)
    if threat_bucket is None:
        rep.add(INCONCLUSIVE,
                "dialogue: a greeting while threatened is served from the "
                "wary/hostile bucket",
                "the reply did not say which row answered (tier=%s notes=%s)"
                % ((g_b2 or {}).get("tier"), (g_b2 or {}).get("notes")))
    else:
        rep.add(PASS if (st == "threatened" and
                         threat_bucket in ("wary", "hostile")) else FAIL,
                "dialogue: a greeting while threatened is served from the "
                "wary/hostile bucket, not the calm one",
                "state=%r ; calm bucket=%r %r ; threatened bucket=%r %r"
                % (st, calm_bucket, t_b[:50], threat_bucket,
                   (g_b2 or {}).get("text", "")[:50]))


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


# ---------------------------------------------------------------------------
# 7. streaming: sentences reach the client BEFORE the model has finished
# ---------------------------------------------------------------------------
#
# The whole point of the feature is a TIMING property, and a timing property is
# the easy one to write a check for that cannot fail: "the text came out right"
# is true of the synchronous path too. So what is asserted here is the ORDER of
# events -- a `say` segment on the stream while the turn is still in flight --
# plus the things that a per-sentence path is uniquely able to get wrong: a
# bracket tag spoken out loud, a `final` that never arrives, a tag applied
# twice (once per sentence), and a stream that never ends hanging forever.
#
# No key, no curl, no network: `llmFakeStreamFile` points the engine at a
# fixture SSE file which the poller reveals a few bytes at a time, exactly as
# a growing curl output file behaves. `debugTickRoute` drives the tick, because
# the simulator runs every route BEFORE it runs a single tick.

FIXTURE_SSE = (
    'data: {"choices":[{"delta":{"content":"Hold still. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"I know a way out "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"of here. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"[REMEMBER: the player asked '
    'about the medkit]"}}]}\n\n'
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n'
)
FIXTURE_TEXT = "Hold still. I know a way out of here."


def run_sim_cfg(store, routes, overrides, timeout=900):
    """One run with config.json temporarily carrying `overrides` on top."""
    path = os.path.join(MOD, "config.json")
    before = open(path, "r", encoding="utf-8").read()
    doc = json.loads(before)
    doc.update(overrides)
    open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2))
    try:
        return run_sim(store, routes, timeout=timeout)
    finally:
        open(path, "w", encoding="utf-8").write(before)


def _say_segs(doc):
    """Every `say` event on the stream, in order, as (text, final, idx)."""
    out = []
    for e in (doc or {}).get("events", []):
        if not isinstance(e, dict) or e.get("kind") != "say":
            continue
        d = e.get("data")
        if isinstance(d, str):
            try:
                d = json.loads(d)
            except ValueError:
                d = {}
        d = d or {}
        out.append((d.get("text", ""), bool(d.get("final")),
                    d.get("segmentIdx", -1)))
    return out


def check_streaming(rep, store):
    fixture = os.path.join(store, "fake-stream.sse")
    open(fixture, "w", encoding="utf-8").write(FIXTURE_SSE)
    # A PER-RUN cacheDir. The brain's line cache lives under the MOD's data/
    # directory by default, not under --store, so it survives between whole
    # invocations of this script: without this, the second run of the day
    # answers every one of these from tier 0 and the checks below pass without
    # ever touching the streaming path.
    def cfg(n, **kw):
        d = {"llmEngine": "openai",
             "llmFakeStreamFile": fixture.replace("\\", "/"),
             "debugTickRoute": True, "llmFakeChunkBytes": 120,
             "turnTimeoutMs": 60000, "llmFakeStreamStall": False,
             "cacheDir": os.path.join(store, "brain-%s" % n).replace("\\", "/")}
        d.update(kw)
        return d
    base = cfg("probe")

    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/world/people", ""),
    ], base)
    if err:
        rep.add(INCONCLUSIVE, "streaming: world/new", err)
        return
    person = pick_person(docs[1], "grunt") or pick_person(docs[1], "slaver")
    if not person:
        rep.add(INCONCLUSIVE, "streaming: a person to talk to",
                "the generated world has nobody with role grunt or slaver")
        return
    pid = person["id"]
    # A DIFFERENT utterance per sub-run, deliberately: the brain's line cache
    # is keyed on the normalised utterance and PERSISTS in the store between
    # simulator runs, so re-using one makes every later run a tier-0 cache hit
    # -- which is a check that cannot fail, in the exact shape section 9b of
    # CLAUDE.md is about. MEASURED here first time round: the synchronous
    # negative control came back `tier='cache'` and proved nothing.
    utt = "what do you want for the medkit"
    utt_sync = "how much do you want for the bandage"
    utt_stall = "where does the road go at night"

    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/say", json.dumps({"person": pid, "text": utt})),
        # TWO ticks, not one: the parser holds the last fragment back because
        # it may still be growing, so the first sentence can only be emitted
        # on the poll that brings text AFTER it. Three ticks finish this
        # fixture, so at two the turn is provably still in flight.
        (BASE + "/tick", '{"n":2}'),
        (BASE + "/events?since=0&wait=0", ""),
        (BASE + "/tick", '{"n":20}'),
        (BASE + "/events?since=0&wait=0", ""),
        (BASE + "/status", ""),
    ]
    docs, raw, err = run_sim_cfg(store, routes, cfg("stream"))
    if err:
        rep.add(INCONCLUSIVE, "streaming: the run", err)
        return
    say, tick1, ev1, tickN, ev2, status = (docs[1], docs[2], docs[3], docs[4],
                                           docs[5], docs[6])
    if not isinstance(say, dict) or "__unparsed__" in say:
        rep.add(FAIL, "streaming: /say answers with a receipt",
                "route answered %s\n%s" % (json.dumps(say)[:300], raw[-800:]))
        return
    receipt = (say.get("streaming") is True and say.get("turnId", 0) > 0
               and not say.get("text"))
    rep.add(PASS if receipt else FAIL, "streaming: /say answers at once with a receipt",
            "streaming=%s turnId=%s tier=%r text=%r (the reply has not been "
            "generated yet, so text must be empty)"
            % (say.get("streaming"), say.get("turnId"), say.get("tier"),
               (say.get("text") or "")[:60]))
    if not receipt:
        return

    # THE timing assertion. After ONE tick the turn must still be in flight and
    # a sentence must already have been spoken. Either half alone is worthless:
    # a segment after the stream ended is the synchronous path, and an
    # in-flight turn with no segment is just a slow one.
    early = _say_segs(ev1)
    in_flight = (tick1 or {}).get("streamsInFlight", -1)
    ok = bool(early) and in_flight >= 1 and not any(f for _, f, _ in early)
    rep.add(PASS if ok else FAIL,
            "streaming: a sentence is spoken BEFORE the stream ends",
            "after 2 ticks: %d say segment(s) %s, streamsInFlight=%s "
            "(a segment with the turn already finished would be the "
            "synchronous path)"
            % (len(early), [t for t, _, _ in early], in_flight))

    late = _say_segs(ev2)
    finals = [t for t, f, _ in late if f]
    spoken = " ".join(t for t, _, _ in late if t)
    rep.add(PASS if len(finals) == 1 else FAIL,
            "streaming: exactly one segment carries final:true",
            "%d segment(s) total, %d final: %s"
            % (len(late), len(finals), finals))
    bracketed = [t for t, _, _ in late if "[" in t or "]" in t]
    rep.add(PASS if not bracketed else FAIL,
            "streaming: no segment speaks a bracket tag",
            "segments=%s; bracketed=%s" % ([t for t, _, _ in late], bracketed))
    idxs = [i for _, _, i in late]
    rep.add(PASS if idxs == sorted(idxs) and len(set(idxs)) == len(idxs) else FAIL,
            "streaming: segmentIdx is strictly increasing",
            "segmentIdx=%s" % idxs)

    done = event_with_kind(ev2, "turn.done")
    dd = (done or {}).get("data")
    if isinstance(dd, str):
        try:
            dd = json.loads(dd)
        except ValueError:
            dd = {}
    dd = dd or {}
    tags = dd.get("tags") or []
    remembers = [t for t in tags if str(t).upper().startswith("REMEMBER")]
    rep.add(PASS if done and len(remembers) == 1 else FAIL,
            "streaming: the reply's tag is applied ONCE, on completion",
            "turn.done=%s tier=%r text=%r tags=%s directives=%s"
            % (bool(done), dd.get("tier"), (dd.get("text") or "")[:70], tags,
               dd.get("directives")))
    rep.add(PASS if spoken == FIXTURE_TEXT else FAIL,
            "streaming: the spoken text is the fixture's text",
            "spoken=%r expected=%r" % (spoken, FIXTURE_TEXT))
    st = (status or {}).get("stream", {})
    print("    stream stats: %s" % json.dumps(st))

    # ---- negative control 1: llmStreaming:false is synchronous, same text.
    sync = cfg("sync", llmStreaming=False)
    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/say", json.dumps({"person": pid, "text": utt_sync})),
    ], sync)
    if err:
        rep.add(INCONCLUSIVE, "streaming: the synchronous negative control", err)
    else:
        s2 = docs[1] or {}
        segs = [x.get("text", "") for x in (s2.get("segments") or [])]
        same = (s2.get("streaming") is not True
                and " ".join(segs) == FIXTURE_TEXT)
        rep.add(PASS if same else FAIL,
                "streaming OFF: the reply is synchronous and identical in text "
                "(negative control)",
                "streaming=%s tier=%r text=%r segments=%s"
                % (s2.get("streaming"), s2.get("tier"),
                   (s2.get("text") or "")[:70], segs))

    # ---- negative control 2: a stream that never ends hits the timeout.
    stall = cfg("stall", llmFakeStreamStall=True, turnTimeoutMs=1000)
    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/say", json.dumps({"person": pid, "text": utt_stall})),
        (BASE + "/tick", '{"n":1}'),
        # The only way to make wall-clock time pass between routes without a
        # sleep primitive: the bounded busy poll on the request thread.
        (BASE + "/events?since=0&wait=2000", ""),
        (BASE + "/tick", '{"n":1}'),
        (BASE + "/events?since=0&wait=0", ""),
    ], stall)
    if err:
        rep.add(INCONCLUSIVE, "streaming: the timeout path", err)
        return
    tdone = event_with_kind(docs[5], "turn.done")
    td = (tdone or {}).get("data")
    if isinstance(td, str):
        try:
            td = json.loads(td)
        except ValueError:
            td = {}
    td = td or {}
    notes = " ".join(str(n) for n in (td.get("notes") or []))
    says = _say_segs(docs[5])
    timed_out = (td.get("tier") == "timeout" and "TIMED OUT" in notes
                 and any(f for _, f, _ in says))
    rep.add(PASS if timed_out else FAIL,
            "streaming: a stream that never ends times out and says so "
            "(negative control)",
            "tier=%r inFlight-after=%s segments=%s notes=%r"
            % (td.get("tier"), (docs[4] or {}).get("streamsInFlight"),
               [t for t, _, _ in says], notes[:200]))


KOKORO_TEST_URL = "http://127.0.0.1:6972"


def _server_up(url, timeout=3):
    """True when <url>/health answers ok. Never raises; a down server is a
    normal answer here and must read as INCONCLUSIVE, not as a failure."""
    try:
        import urllib.request
        with urllib.request.urlopen(url + "/health", timeout=timeout) as r:
            return b'"ok": true' in r.read(400) or b'"ok":true' in r.read(0)
    except Exception:                              # noqa: BLE001 -- reported
        return False


def _tick_max_ms(status):
    t = (status or {}).get("tick") or {}
    v = t.get("maxMs")
    return v if isinstance(v, int) else None


def check_tts_async(rep, store):
    """A streamed turn must not block the tick, and therefore not a route.

    THE INSTRUMENT is `/status`.tick.maxMs -- the longest single `onTick` the
    mod measured for itself. A route cannot run while `onTick` holds the mod
    lock, so the longest tick IS the worst latency a route could have suffered.
    Measuring it inside the mod is the only place that is true of: the
    simulator runs EVERY ROUTE BEFORE IT RUNS A SINGLE TICK, so an outside
    stopwatch here would time the queue and not the block.

    THIS CHECK CARRIES ITS OWN NEGATIVE CONTROL. The same five-sentence turn
    runs twice against the same real kokoro server, with a FRESH tts cache each
    time so neither half can be answered from disk:

        ttsAsync = true   -> tick.maxMs must be UNDER the bound
        ttsAsync = false  -> tick.maxMs must be OVER it

    If the control does NOT exceed the bound then synthesis was not actually
    slow during this run (a warm cache, a stubbed engine) and the positive half
    proves nothing -- INCONCLUSIVE, never PASS.

    AND THE AUDIO MUST STILL ARRIVE. The mechanism only counts if the detached
    requests really complete, so after the simulator has EXITED this waits on
    the finished state on disk: one `<wav>.done` marker per sentence in the
    asynchronous half's own cache directory. Those files are written by curl
    processes that outlived the simulator, which is what "detached" means and
    is the part a `starts` counter could never establish.
    """
    bound = 300
    want = 5
    if not _server_up(KOKORO_TEST_URL):
        rep.add(INCONCLUSIVE, "tts async: the tick stays under %d ms" % bound,
                "no kokoro test server answering at %s/health, so whether "
                "synthesis blocks the tick cannot be established here -- and "
                "an absent server is never a PASS. Start it with: "
                "%%LOCALAPPDATA%%\\aowlspt\\kokoro\\venv\\Scripts\\python.exe "
                "tools/kokoro/server.py --port 6972" % KOKORO_TEST_URL)
        return

    fixture = os.path.join(store, "async-stream.sse")
    open(fixture, "w", encoding="utf-8").write(FIXTURE_SSE_5)
    cache_async = os.path.join(store, "tts-async")

    def cfg(name, is_async):
        return {"llmEngine": "openai",
                "llmFakeStreamFile": fixture.replace("\\", "/"),
                "llmFakeChunkBytes": 120, "debugTickRoute": True,
                "turnTimeoutMs": 60000, "llmFakeStreamStall": False,
                "ttsEngine": "kokoro", "kokoroUrl": KOKORO_TEST_URL,
                "ttsAsync": is_async, "ttsTimeoutMs": 1500,
                # A FRESH cache per half. Sharing one would let the control
                # answer every sentence from disk in microseconds and report a
                # small maxMs -- the check would then pass for both settings
                # and mean nothing.
                "cacheDir": os.path.join(store,
                                         "tts-%s" % name).replace("\\", "/")}

    def run(name, is_async):
        docs, raw, err = run_sim_cfg(store, [
            (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
            (BASE + "/world/people", ""),
        ], cfg(name, is_async))
        if err:
            return None, err
        person = pick_person(docs[1], "grunt") or pick_person(docs[1], "slaver")
        if not person:
            return None, "the generated world has nobody to talk to"
        routes = [
            (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
            (BASE + "/say",
             json.dumps({"person": person["id"],
                         "text": "tell me about the %s tunnels" % name})),
            (BASE + "/tick", '{"n":80}'),
            (BASE + "/status", ""),
        ]
        docs, raw, err = run_sim_cfg(store, routes, cfg(name, is_async),
                                     timeout=900)
        if err:
            return None, err
        return docs[3], None

    st_a, err = run("async", True)
    if err:
        rep.add(INCONCLUSIVE, "tts async: the tick stays under %d ms" % bound,
                "the asynchronous run did not complete: %s" % err)
        return
    st_c, err_c = run("sync", False)
    max_a, max_c = _tick_max_ms(st_a), _tick_max_ms(st_c)
    stats = (st_a or {}).get("ttsAsync") or {}

    if max_a is None:
        rep.add(FAIL, "tts async: the tick stays under %d ms" % bound,
                "/status carried no tick.maxMs, so the instrument this check "
                "depends on is not reporting: %s" % json.dumps(st_a)[:300])
        return

    # The finished state on disk, AFTER the simulator exited. The bound is
    # generous because a cold kokoro loads its model first; what is being
    # asserted is that the requests complete at all without us waiting on them.
    deadline = time.time() + 90
    markers = []
    tts_dir = os.path.join(cache_async, "tts")
    while time.time() < deadline:
        markers = (glob.glob(os.path.join(tts_dir, "*.wav.done"))
                   if os.path.isdir(tts_dir) else [])
        if len(markers) >= want:
            break
        time.sleep(1.0)
    playable = [m[:-5] for m in markers
                if os.path.exists(m[:-5]) and os.path.getsize(m[:-5]) > 44]

    evidence = ("async run: tick.maxMs=%s over %s ticks; ttsAsync.starts=%s "
                "arrived=%s timedOut=%s pending=%s spawnMode=%s "
                "spawnLastMs=%s; %d/%d wavs finished on disk AFTER the "
                "simulator exited (%d playable). SYNCHRONOUS CONTROL: "
                "tick.maxMs=%s%s"
                % (max_a, ((st_a or {}).get("tick") or {}).get("ticks"),
                   stats.get("starts"), stats.get("arrived"),
                   stats.get("timedOut"), stats.get("pending"),
                   stats.get("spawnMode"), stats.get("spawnLastMs"),
                   len(markers), want, len(playable), max_c,
                   (" (control error: %s)" % err_c) if err_c else ""))

    if err_c or max_c is None:
        rep.add(INCONCLUSIVE, "tts async: the tick stays under %d ms" % bound,
                "the synchronous NEGATIVE CONTROL did not complete, so a small "
                "maxMs on the asynchronous run cannot be told apart from a run "
                "where nothing was synthesised at all. %s" % evidence)
        return
    if max_c <= bound:
        rep.add(INCONCLUSIVE, "tts async: the tick stays under %d ms" % bound,
                "the negative control did NOT exceed the bound, so synthesis "
                "was not actually slow during this run and the positive half "
                "proves nothing. %s" % evidence)
        return

    ok = (max_a < bound and stats.get("starts", 0) >= want
          and len(playable) >= want)
    rep.add(PASS if ok else FAIL,
            "tts async: the tick stays under %d ms while a turn streams" % bound,
            "%s -- the audio must still ARRIVE, or this would pass by going "
            "mute" % evidence)


def check_groq(rep, store):
    """The OpenAI-compatible cloud engines, against Groq, when a key is set."""
    key_env = "GROQ_API_KEY"
    if not os.environ.get(key_env):
        rep.add(INCONCLUSIVE, "groq: chat + transcription",
                "%s is not set in this process's environment, so the cloud "
                "engines cannot be exercised. The key is never read from "
                "config.json or from source -- openAiKeyEnv/sttKeyEnv only "
                "NAME the variable." % key_env)
        return
    base = "https://api.groq.com/openai/v1"

    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/world/people", ""),
    ], {"llmEngine": "openai", "openAiBaseUrl": base,
        "openAiKeyEnv": key_env, "openAiModel": "openai/gpt-oss-120b"})
    if err:
        rep.add(INCONCLUSIVE, "groq: chat + transcription", err)
        return
    person = pick_person(docs[1], "grunt") or pick_person(docs[1], "slaver")
    if not person:
        rep.add(INCONCLUSIVE, "groq: chat + transcription",
                "the generated world has nobody to talk to")
        return

    cfg = {"llmEngine": "openai", "openAiBaseUrl": base,
           "openAiKeyEnv": key_env, "openAiModel": "openai/gpt-oss-120b",
           "openAiExtraJson": '"reasoning_effort":"low"',
           "maxTokens": 220, "llmStreaming": False,
           "sttEngine": "openai-whisper", "sttBaseUrl": base,
           "sttKeyEnv": key_env, "sttModel": "whisper-large-v3-turbo",
           "ttsEngine": "none",
           "cacheDir": os.path.join(store, "groq").replace("\\", "/")}
    t0 = time.time()
    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (BASE + "/say", json.dumps({"person": person["id"],
                                    "text": "who are you and what do you want"})),
        (BASE + "/status", ""),
    ], cfg, timeout=180)
    elapsed = time.time() - t0
    if err:
        rep.add(INCONCLUSIVE, "groq: the chat engine answers", err)
        return
    say, status = docs[1], docs[2]
    probe = ((status or {}).get("engines") or {})
    text = (say or {}).get("text") or ""
    tier = (say or {}).get("tier")
    # `tier` is the ONLY thing that distinguishes "the model answered" from
    # "the model was called, failed, and the ontology/builtin row answered
    # instead" -- and the fallback still returns fluent text of the right
    # length. MEASURED 2026-09-07: the first version of this check asserted
    # only "not refused and >20 chars" and PASSED on tier='builtin' while the
    # notes said `openai answered but had no content: {"error...`. A check
    # that cannot fail is the bug; this one names the tier it requires.
    notes = json.dumps((say or {}).get("notes") or [])
    ok = (tier == "llm" and len(text) > 20 and elapsed < 120)
    rep.add(PASS if ok else FAIL, "groq: the chat engine answers",
            "tier=%r (must be 'llm'; 'builtin'/'ontology'/'cache' means the "
            "request FAILED and a table answered) engine=%r %d chars in "
            "%.2f s (whole simulator run, not just the request); notes=%s"
            % (tier, (say or {}).get("engine"), len(text), elapsed,
               notes[:700]))

    # STT needs REAL SPEECH, and the push-to-talk path needs a microphone, so
    # the fixture is synthesised by the local kokoro test server and fed
    # through the ordinary chunk session -- which is the same funnel the live
    # client uses, so this exercises the code that actually runs.
    spoken = "The basement door is locked and the key is gone."
    wav = os.path.join(store, "groq-stt-fixture.wav")
    if not _server_up(KOKORO_TEST_URL):
        rep.add(INCONCLUSIVE, "groq: whisper transcribes a spoken fixture",
                "no kokoro test server at %s to synthesise the fixture with, "
                "and the push-to-talk path needs a microphone -- so there is "
                "nothing to transcribe. Not a PASS." % KOKORO_TEST_URL)
        return
    try:
        import urllib.request
        body = json.dumps({"text": spoken, "voice": "am_michael",
                           "speed": 1.0}).encode("utf-8")
        req = urllib.request.Request(KOKORO_TEST_URL + "/tts", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            open(wav, "wb").write(r.read())
    except Exception as e:                         # noqa: BLE001 -- reported
        rep.add(INCONCLUSIVE, "groq: whisper transcribes a spoken fixture",
                "could not synthesise the fixture: %r" % (e,))
        return
    if not os.path.exists(wav) or os.path.getsize(wav) <= 44:
        rep.add(INCONCLUSIVE, "groq: whisper transcribes a spoken fixture",
                "the fixture wav is %s bytes"
                % (os.path.getsize(wav) if os.path.exists(wav) else "absent"))
        return

    t1 = time.time()
    docs, raw, err = run_sim_cfg(store, [
        (BASE + "/speech/chunk",
         json.dumps({"session": "groqstt", "seq": 1, "final": True,
                     "path": wav.replace("\\", "/")})),
    ], cfg, timeout=180)
    stt_elapsed = time.time() - t1
    if err or not isinstance(docs[0], dict):
        rep.add(INCONCLUSIVE, "groq: whisper transcribes a spoken fixture",
                "the chunk route did not answer: %s" % (err or json.dumps(docs)[:300]))
        return
    heard = (docs[0].get("final") or docs[0].get("text")
             or docs[0].get("heard") or "")
    # The assertion is on the CONTENT, not merely on a non-empty string: an
    # endpoint that answered "you" would otherwise pass. Two content words from
    # the sentence that was actually spoken have to come back.
    low = heard.lower()
    hits = [w for w in ("basement", "door", "locked", "key") if w in low]
    rep.add(PASS if len(hits) >= 2 else FAIL,
            "groq: whisper transcribes a spoken fixture",
            "spoke %r, heard %r in %.2f s (whole simulator run); matched %s "
            "of basement/door/locked/key -- two are required, so a plausible "
            "but wrong transcription fails. note=%s"
            % (spoken, heard[:160], stt_elapsed, hits,
               json.dumps(docs[0].get("note"))[:200]))


def _find_fixture_wav(store):
    for root, _dirs, files in os.walk(store):
        for f in files:
            if f.lower().endswith(".wav"):
                p = os.path.join(root, f)
                if os.path.getsize(p) > 44:
                    return p
    return None


FIXTURE_SSE_5 = (
    'data: {"choices":[{"delta":{"content":"Hold still and listen. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"There is a way out through '
    'the old service tunnels. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"It floods when it rains, '
    'so move fast. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"Take the left fork at the '
    'broken pipe. "}}]}\n\n'
    'data: {"choices":[{"delta":{"content":"Do not stop for anything you '
    'hear down there. "}}]}\n\n'
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n'
)



# ---------------------------------------------------------------------------
# the hearing model: who can hear a line, and who is allowed to answer
# ---------------------------------------------------------------------------

def _say_rows(doc):
    """Every `say` event in an /events response, as (personId, mode, audible,
    reaction, text)."""
    out = []
    for e in (doc or {}).get("events", []):
        if not isinstance(e, dict) or e.get("kind") != "say":
            continue
        d = e.get("data") or {}
        out.append((d.get("personId", ""), d.get("mode", ""),
                    d.get("audible", None), bool(d.get("reaction", False)),
                    d.get("text", "")))
    return out


def check_hearing(rep, store):
    """THE THREE BANDS, against the SERVED stream, in one simulator run.

    The user, 2026-09-07: *"everyone in the vicinity replies even if I can't
    hear their reply -- that's not good"*.

    The same person is aimed at from three distances -- 500 m, 45 m, 10 m --
    reported the way the live client reports them (`npc_moved` against
    `player_moved`, which is the path that has to work in a raid, NOT a
    hand-set field). The assertions are on what the stream actually carried:

      500 m -> NO say at all, and a `say.suppressed` row in the journal
       45 m -> mode "yell", audible, and text DIFFERENT from the 10 m text
       10 m -> mode "speak", audible

    The last clause is the one that cannot pass vacuously: a build that
    ignored the bands entirely would serve the same sentence at 45 m and at
    10 m, and "they differ" would fail.
    """
    routes = [(BASE + "/world/new", '{"preset":"warlords","seed":7}'),
              (BASE + "/world/people", "")]
    docs, raw, err = run_sim(store, routes)
    if err or docs[1] is None:
        rep.add(INCONCLUSIVE, "hearing bands",
                err or "no /world/people answer\n" + raw[-800:])
        return
    people = (docs[1] or {}).get("people", [])
    if len(people) < 3:
        rep.add(INCONCLUSIVE, "hearing bands",
                "the generated world has %d people; this needs 3" % len(people))
        return
    a, b, cc = people[0]["id"], people[1]["id"], people[2]["id"]

    def moved(x):
        return '{"kind":"player_moved","map":"woods","x":0,"y":0,"z":0}'

    def npc(pid, dist):
        return ('{"kind":"npc_moved","map":"woods","people":[{"personId":"%s",'
                '"x":%f,"y":0,"z":0}]}' % (pid, float(dist)))

    obs = BASE + "/observe"
    ev = BASE + "/events?since=%d"
    routes = [
        (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
        (obs, '{"kind":"raid_started","map":"woods"}'),
        (obs, moved(0)),
        # --- 500 m -----------------------------------------------------------
        (obs, npc(a, 500)),
        (obs, '{"kind":"player_aimed_at","personId":"%s"}' % a),
        (BASE + "/events?since=0&limit=400", ""),
        # --- 45 m ------------------------------------------------------------
        (obs, '{"kind":"raid_started","map":"woods"}'),
        (obs, moved(0)),
        (obs, npc(a, 45)),
        (obs, '{"kind":"player_aimed_at","personId":"%s"}' % a),
        (BASE + "/events?since=0&limit=400", ""),
        # --- 10 m ------------------------------------------------------------
        (obs, '{"kind":"raid_started","map":"woods"}'),
        (obs, moved(0)),
        (obs, npc(a, 10)),
        (obs, '{"kind":"player_aimed_at","personId":"%s"}' % a),
        (BASE + "/events?since=0&limit=400", ""),
    ]
    # barkCooldownMs 0, or the 20 s aim hysteresis (selfcheck 17) swallows the
    # second and third aim at the same person and bands 2 and 3 come back
    # empty for a reason that has nothing to do with hearing. MEASURED: that
    # is exactly how this check first failed.
    docs, raw, err = run_sim_cfg(store, routes, {"barkCooldownMs": 0,
                                                 "ttsEngine": "none"})
    if err:
        rep.add(INCONCLUSIVE, "hearing bands", err)
        return

    def window(i_events, i_prev_events):
        """The say events that appeared between two /events snapshots."""
        now = _say_rows(docs[i_events])
        was = _say_rows(docs[i_prev_events]) if i_prev_events is not None else []
        return now[len(was):]

    far = window(5, None)
    mid = window(10, 5)
    near = window(15, 10)

    # The mod's own account of the 500 m aim. `/journal` has no route, so the
    # journal row itself is asserted by selfcheck 21 (which can read it
    # directly); here the instrument is the note the route returned.
    far_note = (docs[4] or {}).get("note", "")
    suppressed = "not said" in far_note and "beyond" in far_note

    def one(rows, want_mode):
        for pid, mode, aud, react, text in rows:
            if pid == a and not react:
                return mode == want_mode and aud is not False, mode, text
        return False, "(no say)", ""

    ok_mid, mode_mid, text_mid = one(mid, "yell")
    ok_near, mode_near, text_near = one(near, "speak")
    ok = (len(far) == 0 and suppressed and ok_mid and ok_near
          and text_mid and text_near and text_mid != text_near)
    rep.add(PASS if ok else FAIL, "hearing: 500 m silent / 45 m yelled / 10 m spoken",
            "500 m served %d say (expected 0), the route said %r; "
            "45 m mode=%s text=%r; 10 m mode=%s text=%r; the two texts must "
            "DIFFER and they %s"
            % (len(far), far_note, mode_mid, text_mid, mode_near, text_near,
               "do" if text_mid != text_near else "DO NOT"))


def check_one_reply(rep, store):
    """One utterance, three people in earshot: ONE reply, the rest at most
    reactions.

    The reply is the non-`reaction` segment from the person addressed. The
    negative control is the second half of the run, with
    `bystanderReactChance` at 0: the same utterance must then produce ZERO
    reactions, so "nobody else spoke" cannot be passing because nobody was
    ever in range.
    """
    docs, raw, err = run_sim(store, [(BASE + "/world/new", '{"preset":"warlords","seed":7}'),
                                     (BASE + "/world/people", "")])
    if err or docs[1] is None:
        rep.add(INCONCLUSIVE, "only the addressee replies",
                err or "no /world/people answer")
        return
    people = (docs[1] or {}).get("people", [])
    if len(people) < 3:
        rep.add(INCONCLUSIVE, "only the addressee replies",
                "the generated world has %d people; this needs 3" % len(people))
        return
    a, b, cc = people[0]["id"], people[1]["id"], people[2]["id"]
    obs = BASE + "/observe"

    def run(chance):
        routes = [
            (BASE + "/world/new", '{"preset":"warlords","seed":7}'),
            (obs, '{"kind":"raid_started","map":"woods"}'),
            (obs, '{"kind":"player_moved","map":"woods","x":0,"y":0,"z":0}'),
            (obs, '{"kind":"npc_moved","map":"woods","people":['
                  '{"personId":"%s","x":5,"y":0,"z":0},'
                  '{"personId":"%s","x":8,"y":0,"z":0},'
                  '{"personId":"%s","x":12,"y":0,"z":0}]}' % (a, b, cc)),
            # Seen as well, so their once-per-raid `first_sight` greeting is
            # spent BEFORE the baseline snapshot below. Otherwise it lands in
            # the measured window as a non-reaction segment from somebody who
            # was not addressed, and the check fails for the right rule and
            # the wrong reason.
            (obs, '{"kind":"player_seen","personId":"%s","distanceM":5}' % a),
            (obs, '{"kind":"player_seen","personId":"%s","distanceM":8}' % b),
            (obs, '{"kind":"player_seen","personId":"%s","distanceM":12}' % cc),
            (BASE + "/events?since=0&limit=400", ""),
            (BASE + "/say", '{"person":"%s","text":"hey there, how are you doing"}' % a),
            (BASE + "/events?since=0&limit=400", ""),
        ]
        d, r, e = run_sim_cfg(store, routes, {"bystanderReactChance": chance,
                                              "bystanderCooldownMs": 0,
                                              "llmEngine": "builtin",
                                              "ttsEngine": "none"})
        if e or d is None:
            return None, e or "no answer"
        before = _say_rows(d[7])
        after = _say_rows(d[9])
        return after[len(before):], ""

    hot, why1 = run(1.0)
    cold, why2 = run(0.0)
    if hot is None or cold is None:
        rep.add(INCONCLUSIVE, "only the addressee replies", why1 or why2)
        return
    replies = [x for x in hot if not x[3]]
    reactions = [x for x in hot if x[3]]
    cold_reactions = [x for x in cold if x[3]]
    wrong = [x for x in replies if x[0] != a]
    ok = (len(replies) >= 1 and not wrong and len(reactions) >= 1
          and len(cold_reactions) == 0)
    rep.add(PASS if ok else FAIL, "one utterance, three in earshot: one reply",
            "with bystanderReactChance 1.0 the stream carried %d non-reaction "
            "segment(s) (all from the addressee: %s) and %d reaction(s); "
            "NEGATIVE CONTROL at 0.0 carried %d reaction(s), expected 0. "
            "Wrong speakers: %r"
            % (len(replies), not wrong, len(reactions), len(cold_reactions),
               [x[0] for x in wrong]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", default="",
                    help="scratch store dir (default: a fresh temp dir)")
    ap.add_argument("--keep", action="store_true",
                    help="keep the scratch store instead of deleting it")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="override a config.json key for the run (JSON value "
                         "if it parses, else a string); repeatable")
    a = ap.parse_args()

    store = a.store or tempfile.mkdtemp(prefix="basement-check-")
    os.makedirs(store, exist_ok=True)
    print("aowl.basement acceptance -- store %s\n" % store)

    rep = Report()
    cfg_path, original = None, None
    try:
        cfg_path, original = enabled_config(parse_set(a.set))
    except Exception as e:                        # noqa: BLE001 -- reported
        rep.add(INCONCLUSIVE, "config",
                "could not enable the mod for the run: %s" % e)
    try:
        check_voices(rep)
        print("")
        check_selfcheck(rep, store)
        print("")
        check_story(rep, store)
        print("")
        check_hearing(rep, store)
        print("")
        check_one_reply(rep, store)
        print("")
        check_grounding(rep, store)
        print("")
        check_offscreen(rep, store)
        print("")
        check_dialogue(rep, store)
        print("")
        check_ptt(rep, store)
        print("")
        check_crash_sequence(rep, store)
        print("")
        check_streaming(rep, store)
        print("")
        check_tts_async(rep, store)
        print("")
        check_groq(rep, store)
    finally:
        if cfg_path and original is not None:
            with open(cfg_path, "wb") as fh:   # the exact original bytes, BOM and line endings included
                fh.write(original)
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
