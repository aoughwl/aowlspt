#!/usr/bin/env python3
"""betacheck -- the four ship-blocking beta defects, checked over the wire.

Every check here is an INDEPENDENT RE-READ: nothing asserts on the response to
the write that made the thing.  A profile is created through the launcher route
and then read back from `/client/game/profile/list`; a trader assort is read
from `/client/trading/api/getTraderAssort/<id>`.  Every body is parsed
STRICTLY (`json.loads`), because the backend has shipped documents that were
not valid JSON at all and a `contains` check passed them for months.

Each check states PASS / FAIL / INCONCLUSIVE, never two outcomes.  "The server
did not answer" is INCONCLUSIVE, not a pass.

The expected numbers are read from SPT's own `templates/profiles.json` at run
time rather than written down here -- a constant copied out of the table cannot
detect the table changing, and a check that compares our output to our own
constant is the failure mode this file exists to avoid.

    python tools/betacheck.py --port 7788 --spt D:\\SPT
    python tools/betacheck.py --port 7788 --spt D:\\SPT --mutate inventory

`--mutate` runs a deliberately wrong variant to prove a check can FAIL:

    inventory  compare the served count against the WRONG edition's template
    traders    accept an all-1s loyalty distribution as gated
    tradersinfo  accept an empty TradersInfo
    edition    compare EoD against the standard template
    quests     describe the startable quests as Locked, then accept them
    queststatus  strip the `status` key, as the stored SPT templates do
    hideout    remove area 21 from the profile, as the old constant did
    fence      report Fence's generated assort as empty
    descriptor add a ProfileDescriptor member we correctly never serve on this
               route, which MUST turn the descriptor check red
    lootpos    demand a NON-zero Position on static containers -- which BSG's
               own captured match/local/start does NOT send -- so a correct
               server must go red
    skillids   accept the 17 pre-1.0 skill ids the client rejects, as the
               old 54-entry starter list served -- a correct server, which
               no longer serves them, must go red
    lootmap    add `Icebreaker` to the set of ids REQUIRED to serve loot.
               It is in the post-1.0 location table the real server sent us
               but has no database entry and no parent map to inherit one, so
               a correct server cannot answer it and must go red
    setwrite   demand that a written setting reads back UNCHANGED -- which is
               exactly the silent-revert shape of fact #135, so a server that
               actually persists the edit must go red
    lootloose  raise every map's floor by its whole probabilistic spawn
               point count, so a correct server -- which rolls each point
               against its own probability -- must go red
    orbitmap   add `Icebreaker` to the set of ids REQUIRED to yield an ORBIT
               plan.  It has no database location and therefore no
               SpawnPointParams, so a correct server cannot anchor it and
               must go red
    progression  demand the experience of the level ABOVE the one that was
               set, one skill level above the one asked for, and one mastery
               point past each family's own ceiling -- a correct server must
               go red on all three
    loyalty    accept a trader still sitting at loyalty level 1 as maxed
    weatherarray  demand that /client/weather sends `weather` as an ARRAY --
               the shape a WRONG DTO mapping implied and which BSG's own
               capture contradicts -- so a correct server must go red
    dictshapes demand that the six declared-Dictionary members of the served
               profile arrive as JSON ARRAYS -- which is exactly the defect
               that shipped -- so a correct server must go red
    tolerated  require BSG's own captured payloads to carry `SeasonsSettings`
               and `exchange_rate`.  They do not -- that is the whole basis of
               the CORRECT-AS-IS verdict on those two members -- so a correct
               server plus a correct capture must go red
    setwriteclient  the `setwrite` falsifier for the client-settings route:
               demand the written value read back UNCHANGED
    systemdata  demand that every mail message.systemData is a BOOLEAN -- the
               exact shape that threw inside ExecuteRequest -- so a correct
               server must go red
    senderid   demand 23-character sender ids instead of the 24 a MongoID has,
               so a correct server must go red
    dtomap     hide one route from dtogap.ROUTES, so the coverage check must
               go red.  An UNMAPPED route is INCONCLUSIVE and was silently
               reported as nothing at all -- which is how mail/dialog/list,
               the most-called route in the client's own log and the home of
               both live crashes this week, went 43 hits a session unaudited
    nestedtype plant an ARRAY at a NESTED member the client declares as a
               class, after the response arrives.  The recursive type walk
               must go red -- if it does not, it is only looking at the top
               level, which is the blind spot that hid MainQuestSettings
    shapes     assert the WRONG JSON kind on a served member on purpose; if
               that does not turn the check red, the check is not looking

Every name above is checked at start-up against the names this file actually
branches on (`mut == "..."`), and a typo'd `--mutate` is REFUSED rather than
silently running the unmutated check and printing PASS -- which is what it did
until 2026-08-27, making `--mutate` a proof that could not fail.
"""

import argparse
import atexit
import http.client
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

OK, FAIL, INCONC = "PASS", "FAIL", "INCONCLUSIVE"
JAEGER = "5c0647fdd443bc2504c2d371"
PRAPOR = "54cb50c76803fa8b248b4571"

# Members of the client's `EFT.ProfileDescriptor` that `/client/game/profile/list`
# must carry, with the wire name the [JsonProperty] attribute gives them.
#
# THIS LIST IS A CONSTANT HERE AND THAT IS A LIMITATION, stated rather than
# hidden: a check that compares our output to our own constant cannot notice
# the constant going stale.  The AUTHORITY is `tools/oursample.py`, which
# derives the whole member set from the decrypted global-metadata and diffs it
# against our own served payload; these three are the rows it reported as
# EXPECTED-BUT-MISSING on 2026-08-27.  betacheck's narrower job is to prove
# they are on the wire, on a re-read, and are not null.
#
# `Bonuses` is a real member of the profile document and IS served; the mutant
# below asks instead for `BTRLocalSettings`, which is a member of
# EFT.GlobalConfiguration and has no business on this route -- so the mutated
# run demands something genuinely absent and MUST go red.  That is the input
# which makes this check fail.
DESCRIPTOR_MEMBERS = ["CheckedChambers", "CheckedMagazines", "karmaValue"]
MUTANT_MEMBER = "BTRLocalSettings"
PRAPOR = "54cb50c76803fa8b248b4571"
# The map the ONE captured match/local/start body covers, so our served payload
# is compared against BSG's on the same location and nothing else.
LOOT_MAP = "Sandbox_start"
# A map the generator DOES answer for, so the Position-shape assertion is not
# silently skipped by the unrelated Sandbox_start mapping defect above.
LOOT_SHAPE_MAP = "sandbox"

# Every location id the CLIENT can put in `/client/match/local/start`, which is
# `base.Id` -- NOT the database key.  Measured from the captured request body
# (raid1/requests/158.json names the map "Sandbox_start", an `Id`) and from the
# `Id` member of all 24 maps in `mods/tarkov/data/post1/locations.json`, which
# is the table the real server sent this build.
#
# `LOOT_BEARING` are the ones whose database entry carries static loot tables,
# so an empty `Loot` for one of them is a DEFECT.  The rest -- develop,
# hideout, Private Area, Suburdbs, Terminal, Town -- have a `base` and nothing
# else in the database, and `Icebreaker` has no database entry at all, so an
# empty list for those is the CORRECT answer and asserting otherwise would be
# a check that fails on correct behaviour.
CLIENT_LOCATION_IDS = [
    "bigmap", "factory4_day", "factory4_night", "laboratory", "Interchange",
    "Labyrinth", "Lighthouse", "RezervBase", "Sandbox", "Sandbox_high",
    "Shoreline", "TarkovStreets", "Woods",
    # Variants: their own Id and _Id, sharing a parent map's `Name`.
    "Sandbox_start", "laboratory_dark", "Lighthouse2",
]
LOOT_BEARING = set(CLIENT_LOCATION_IDS)

# Ids the client can send that the database has NOTHING for, directly or by
# `Name`.  An empty `Loot` for these is correct, and `--mutate lootmap` demands
# loot for one of them precisely so that a correct server goes red.
UNMAPPABLE_IDS = ["Icebreaker", "Terminal_ui", "develop", "hideout",
                  "Private Area", "Suburbs", "Terminal", "Town"]
FENCE = "579dc571d53a0658a154fbec"

# Skill ids `SkillManager..ctor` REJECTS on this post-1.0 build.  MEASURED, not
# derived: the client logs `Can't find skill to upgrade: <id>` into
# `D:\Aowlspt\Logs\<ts>\... backend_000.log`, once per profile construction
# (22 identical repeats in log_2026.08.27_12-*).  Every one of these is STILL a
# member of `EFT.ESkillId` (67 members, `tools/fldoff.py enum EFT.ESkillId`),
# so an enum-membership assertion here would be a check that cannot fail --
# `SkillManager.Skills` is a strict subset of the enum and the log is the only
# measured source for it.  Re-derive by re-reading the client log, never by
# reasoning from the enum.
CLIENT_REJECTED_SKILL_IDS = set([
    "AdvancedModding", "Auctions", "Barter", "Cleanoperations", "FieldMedicine",
    "FirstAid", "Freetrading", "Lockpicking", "Memory", "NightOps",
    "ProneMovement", "RecoilControl", "Shadowconnections", "SilentOps",
    "Sniping", "Taskperformance", "WeaponModding",
])

results = []


def record(name, verdict, detail):
    results.append((name, verdict, detail))
    print("%-14s %-12s %s" % (verdict, name, detail))


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE_DB = r"D:\Aowlspt\aowlspt\db.json"
STAMP = ".betacheck-owned"          # proof this root is ours, not a collision


def free_port():
    """Ask the OS for a port nobody is on. --port's 7788 default is the same
    number in every agent's terminal, so two concurrent runs answered each
    other's requests."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def make_root(explicit):
    """A scratch root that is provably OURS.

    Two agents collided on a shared scratchpad path and one overwrote the
    other's staged DLL, so a selfcheck passed against a binary nobody
    intended (fact #153). The default is per-PID, and an EXISTING directory
    is only reused if it carries our stamp file -- otherwise this refuses
    rather than clobbering someone's run.
    """
    root = explicit or os.path.join(
        os.environ.get("TEMP", "/tmp"), "betacheck-%d" % os.getpid())
    if os.path.isdir(root) and os.listdir(root):
        if not os.path.exists(os.path.join(root, STAMP)):
            sys.exit("--root %s already exists, is not empty, and was not "
                     "created by betacheck (no %s). REFUSING to stage into "
                     "it: overwriting another run's staged DLL is how a "
                     "selfcheck passed against the wrong binary (fact "
                     "#153). Pass a different --root, or delete that one."
                     % (root, STAMP))
        shutil.rmtree(root)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, STAMP), "w") as f:
        f.write("pid=%d\n" % os.getpid())
    return root


def spawn_backend(a):
    """Stage a scratch root, start a private backend, wait for the PORT.

    Returns (proc, port, root). Raises SystemExit with a stated reason if
    anything is missing -- never "0 checks, all passed".
    """
    backend = a.backend or os.path.join(REPO, "backend", "bin",
                                        "aowlspt-backend.exe")
    if not os.path.isfile(backend):
        sys.exit("--spawn: no backend at %s. Build it (`aowl build backend`) "
                 "or pass --backend PATH. Nothing was checked." % backend)
    db = a.db or LIVE_DB
    if not os.path.isfile(db):
        sys.exit("--spawn: no db.json at %s. Pass --db PATH. Nothing was "
                 "checked." % db)
    root = make_root(a.root)
    os.makedirs(os.path.join(root, "mods", "tarkov"), exist_ok=True)
    tark = a.tarkov or os.path.join(REPO, "mods", "tarkov", "bin",
                                    "tarkov.dll")
    where = "this worktree's build"
    if not os.path.isfile(tark):
        # Fall back to the DEPLOYED mod so --spawn is usable from a fresh
        # worktree -- but say loudly which binary is under test, because
        # "a selfcheck passed against the wrong binary" is the exact failure
        # this verb exists to stop (fact #153).
        live = os.path.join(r"D:\Aowlspt\aowlspt", "mods", "tarkov",
                            "tarkov.dll")
        if os.path.isfile(live):
            tark, where = live, "the DEPLOYED install (NOT this worktree)"
    if os.path.isfile(tark):
        print("tarkov.dll under test: %s  <- %s" % (tark, where))
        shutil.copy2(tark, os.path.join(root, "mods", "tarkov", "tarkov.dll"))
        # The mod REFUSES TO SERVE without its data/ tables ("this build
        # fails its own arithmetic; refusing to serve"). Staging only the
        # DLL produced a backend that booted, listened, and answered "no
        # route" to everything -- 24 INCONCLUSIVEs that could be skimmed as
        # "it ran". Stage the tables from beside whichever DLL was chosen.
        data_src = os.path.join(os.path.dirname(tark), "data")
        if not os.path.isdir(data_src):
            data_src = os.path.join(REPO, "mods", "tarkov", "data")
        if os.path.isdir(data_src):
            shutil.copytree(data_src,
                            os.path.join(root, "mods", "tarkov", "data"),
                            dirs_exist_ok=True)
        else:
            print("note: no mods/tarkov/data tree found beside %s -- the mod "
                  "will refuse to serve and every check will be "
                  "INCONCLUSIVE." % tark)
        with open(os.path.join(root, "mods", "tarkov", "config.json"),
                  "w", newline="\n") as fh:
            fh.write("{}\n")
        reg = os.path.join(root, "registry")
        os.makedirs(reg, exist_ok=True)
        with open(os.path.join(reg, "mods.json"), "w", newline="\n") as f:
            json.dump({"schema": "aowlspt.registry/1",
                       "registry": {"id": "betacheck",
                                    "name": "betacheck spawn", "revision": 1},
                       "mods": [{"id": "aowl.tarkov",
                                 "name": "Tarkov server emulator",
                                 "author": "aowlspt", "version": "1.0.0",
                                 "sides": ["server"], "provides": []}]},
                      f, indent=2)
        with open(os.path.join(root, "mods", "aowlspt-selection.json"),
                  "w", newline="\n") as f:
            json.dump({"schema": "aowlspt.selection/1",
                       "writtenBy": "betacheck", "side": "server",
                       "registry": os.path.join(reg, "mods.json"),
                       "load": ["aowl.tarkov"]}, f)
    else:
        print("note: no tarkov.dll found (neither %s nor the deployed "
              "install) -- the spawned backend runs WITHOUT the tarkov mod. "
              "Checks that need it will report INCONCLUSIVE, not pass."
              % tark)
    shutil.copy2(db, os.path.join(root, "db.json"))

    port = a.port_explicit if a.port_explicit else free_port()
    # Copy the backend INTO the root and run it with cwd=root, exactly as
    # xferproof.py does -- that is the staging recipe measured to actually
    # load the tarkov mod. --no-store-lock keeps a concurrent run (or the
    # live install) from being locked out.
    local_backend = os.path.join(root, os.path.basename(backend))
    shutil.copy2(backend, local_backend)
    proc = subprocess.Popen([local_backend, "--root", root,
                             "--port", str(port), "--no-store-lock"],
                            cwd=root,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def teardown():
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        if not a.keep:
            shutil.rmtree(root, ignore_errors=True)
    atexit.register(teardown)

    # Wait for the SOCKET, not for a guessed number of seconds. ANY HTTP
    # answer -- including a 404 -- means it is serving; treating 404 as "not
    # up" once turned a 0.3s boot into a 120s timeout.
    for _ in range(120):
        if proc.poll() is not None:
            out = (proc.stdout.read() or b"").decode("utf-8", "replace")
            sys.exit("--spawn: the backend exited with %d before serving. "
                     "Nothing was checked.\n%s"
                     % (proc.returncode, out[-2000:]))
        try:
            urllib.request.urlopen(
                "http://127.0.0.1:%d/aowlspt/status" % port, timeout=2).read()
            break
        except urllib.error.HTTPError:
            break
        except Exception:
            time.sleep(0.5)
    else:
        sys.exit("--spawn: no answer on port %d within 60s. Nothing was "
                 "checked -- this is INCONCLUSIVE, not a pass." % port)
    print("spawned backend pid=%d port=%d root=%s db=%s"
          % (proc.pid, port, root, db))

    # A backend that is LISTENING is not a backend that is SERVING. Ask the
    # mod's own selfcheck route; if it declined, say so once, loudly, instead
    # of emitting two dozen INCONCLUSIVEs that read like a run.
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:%d/aowlspt/tarkov/selfcheck" % port,
                data=b"{}", timeout=10) as r:
            sc = r.read().decode("utf-8", "replace")
        if '"ok":true' not in sc.replace(" ", ""):
            print("WARNING: the tarkov mod's own selfcheck did NOT pass, so "
                  "it is refusing to serve its routes. Everything below will "
                  "be INCONCLUSIVE and NONE of it is evidence about the "
                  "server. selfcheck said: %s" % sc[:400])
    except Exception as exc:                       # noqa: BLE001
        print("WARNING: could not read /aowlspt/tarkov/selfcheck (%r). "
              "Whether the mod is serving was NOT established." % (exc,))
    return proc, port, root


class Wire:
    def __init__(self, port):
        self.port = port

    def call(self, path, body=None, session=""):
        """A route call.  Returns (status, parsed-json-or-None, raw-text).

        `Accept-Encoding: identity` is not optional: the backend deflates
        everything otherwise (fact #123) and the raw bytes are then a zlib
        stream, not JSON.  Both are handled, because a header the server
        ignores would otherwise look like a broken route.
        """
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        payload = b"" if body is None else json.dumps(body).encode()
        headers = {
            "Accept-Encoding": "identity",
            "Content-Type": "application/json",
            "Cookie": "PHPSESSID=" + session,
        }
        c.request("POST", path, payload, headers)
        r = c.getresponse()
        raw = r.read()
        c.close()
        if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
            raw = zlib.decompress(raw)
        text = raw.decode("utf-8", "replace")
        try:
            return r.status, json.loads(text), text
        except Exception:
            return r.status, None, text


def envelope(doc):
    """`data` out of the client envelope, or the document itself."""
    if isinstance(doc, dict) and "data" in doc and "err" in doc:
        return doc["data"]
    return doc


def spt_template(spt, edition, side):
    path = os.path.join(spt, "SPT_Runtime", "SPT_Data", "database",
                        "templates", "profiles.json")
    if not os.path.exists(path):
        path = os.path.join(spt, "SPT_Data", "database", "templates",
                            "profiles.json")
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    return d[edition][side]["character"], d[edition][side]["trader"]


def session_of(doc):
    """The session token out of a launcher create reply.

    The launcher routes answer a BARE object (`ok`/`token`/`profile`), not the
    client envelope, so `envelope()` alone does not reach it.
    """
    d = envelope(doc)
    if not isinstance(d, dict):
        return ""
    for k in ("token", "profileId", "id"):
        if isinstance(d.get(k), str) and d[k]:
            return d[k]
    prof = d.get("profile")
    if isinstance(prof, dict):
        for k in ("token", "id", "profileId"):
            if isinstance(prof.get(k), str) and prof[k]:
                return prof[k]
    return ""


def make_profile(w, nickname, edition):
    st, doc, text = w.call("/aowlspt/tarkov/launcher/profile/create",
                           {"nickname": nickname, "side": "Usec",
                            "edition": edition})
    return st, doc, text


def read_back(w, session):
    """The profile as the CLIENT sees it -- never the create response."""
    st, doc, text = w.call("/client/game/profile/list", {}, session)
    if doc is None:
        return None, "the profile list did not parse as JSON (%d bytes)" % len(text)
    data = envelope(doc)
    if not isinstance(data, list) or not data:
        return None, "the profile list is not a non-empty array"
    # The PMC of THIS session, by id.  Picking "the first PMC in the list" is
    # what made an Edge Of Darkness check read a Standard profile created
    # earlier in the same run and report GameVersion=standard -- a real-looking
    # failure with no defect behind it.
    for p in data:
        if p.get("_id") == session and            p.get("Info", {}).get("Side") in ("Usec", "Bear"):
            return p, ""
    for p in data:
        if p.get("Info", {}).get("Side") in ("Usec", "Bear"):
            return None, ("the profile list has PMCs but none with _id %s "
                          "-- refusing to read someone else's" % session)
    return None, "no PMC in the profile list"



# ---------------------------------------------------------------------------
# 12. the two members we deliberately do NOT send, and the keys we do
#
# `JsonType.WeatherResponse.SeasonsSettings` (REF) and
# `EFT.TraderAssortment.ExchangeRate -> exchange_rate` (VALUE) are declared by
# the client and absent from our payload.  They are also absent from BSG'S OWN
# captured payloads -- every /client/weather body and every getTraderAssort
# body in raid1 -- so serving them would be inventing wire shape, not closing a
# hole.
#
# The check therefore asserts a property of the FINISHED STATE, in both
# directions, and neither half is a comparison against our own output:
#   (a) BSG's capture really does omit both.  Re-read from the capture every
#       run, so the verdict expires if the capture is ever replaced by one that
#       carries them.  `--mutate tolerated` inverts this requirement, and a
#       correct capture must then FAIL.
#   (b) our served payload is a SUPERSET of BSG's key set on both routes -- the
#       regression this pair could otherwise hide, which is us dropping a key
#       BSG does send while everyone stares at the two it does not.
# "Could not read the capture" and "the route did not answer" are INCONCLUSIVE.

TOLERATED = [
    ("/client/weather", "SeasonsSettings", None),
    ("/client/trading/api/getTraderAssort", "exchange_rate", PRAPOR),
]


# ---------------------------------------------------------------------------
# 19. every NESTED member's JSON type, not just the top level
#
# The type audit walked only the top level of a payload, so
# `globals.config.MainQuest` -- and TraderDialogsDTO, and
# AvailableCustomizationsResponse, and SeasonalPerksData -- were structurally
# invisible to it.  All four were found by reading the client's crash log.
# `tools/dtodeep.py` descends; this drives it against the LIVE server.
#
# It is asserted as a negative, on the finished payload: no member at ANY
# depth may carry a JSON kind Newtonsoft would throw on.  A shape BSG's own
# capture also sends is NOT counted -- that falsifies the DTO mapping, not our
# payload, and "fixing" it would be editing correct data.
#
# `--mutate nestedtype` plants an ARRAY at a nested member the client declares
# as a class, AFTER the response is received.  The walker must go red; if it
# does not, it is not descending and this check is worthless.
NESTED_ROUTES = [
    ("/client/globals", "data.config"),
    ("/client/weather", "data"),
    ("/client/settings", "data"),
    ("/client/hideout/areas", "data"),
    ("/client/hideout/settings", "data"),
    ("/client/seasonal-perks/list", "data"),
    ("/client/profile/status", "data"),
    ("/client/game/mode", "data"),
    ("/client/friends", "data"),
    ("/client/getMetricsConfig", "data"),
]


def _nested_resolver():
    """(resolver, attrs, dtogap, dtodeep) or (None, reason)."""
    import dtogap as _g
    if not os.path.isfile(_g.METADEC):
        return None, ("no decrypted metadata at %s -- set AOWL_METADEC or run "
                      "tools/metablob.py. Nothing was type-checked."
                      % _g.METADEC)
    if not os.path.isfile(_g.GAMEASM):
        return None, "no GameAssembly.dll at %s" % _g.GAMEASM
    from il2cpp_resolve import Resolver
    import il2cpp_attrs
    import dtodeep as _d
    r = Resolver(_g.GAMEASM, _g.METADEC)
    _g.selfcheck(r)                      # exits the process if it fails
    at = il2cpp_attrs.selfcheck(r)
    _g.member_selfcheck(r, at)
    return (r, at, _g, _d), ""


def _plant_bad_nested(obj):
    """Replace the first NESTED object-valued member with an array.

    Returns the path it broke, or "". Deliberately not the top level: the
    whole point is to prove the walk goes below it.
    """
    for k, v in obj.items():
        if isinstance(v, dict) and v:
            for k2, v2 in v.items():
                if isinstance(v2, dict):
                    v[k2] = [{"planted": True}]
                    return "%s.%s" % (k, k2)
    return ""


def check_nested_types(w, mut):
    got, err = _nested_resolver()
    if got is None:
        record("nested-types", INCONC, err)
        return
    r, at, _g, _d = got
    fatal, walked, checked, found, seen_routes = [], 0, 0, 0, []
    planted = ""
    for route, jpath in NESTED_ROUTES:
        ent = _g.ROUTES.get(route)
        dto = ent[0] if ent else None
        if not dto:
            continue
        st, doc, text = w.call(route, {})
        if doc is None:
            continue
        node = doc
        for part in jpath.split("."):
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, list):
            node = node[0] if node else None
        if not isinstance(node, dict):
            continue
        if mut == "nestedtype" and not planted:
            planted = _plant_bad_nested(node)
            if planted:
                planted = "%s -> %s" % (route, planted)
        t = r.find_one(dto)
        if t is None:
            continue
        bsg = None
        for p in (_g.find_captures(route) or []):
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    d = json.load(fh)
            except (ValueError, OSError):
                continue
            for part in jpath.split("."):
                d = d.get(part) if isinstance(d, dict) else None
            if isinstance(d, list):
                d = d[0] if d else None
            if isinstance(d, dict) and d:
                bsg = d
                break
        walker = _d.Walk(r, at)
        walker.walk_object(node, t, "", 0, bsg)
        walked += 1
        checked += walker.checked
        found += walker.found
        seen_routes.append(route)
        for v, path, decl, jk, why in walker.rows:
            if v == _d.FATAL:
                fatal.append("%s%s: %s (declared %s, emitted %s)"
                             % (route, path, why, decl, jk))
    if not walked:
        record("nested-types", INCONC,
               "no mapped route answered -- nothing was type-checked")
        return
    if mut == "nestedtype" and not planted:
        record("nested-types", INCONC,
               "--mutate nestedtype found no nested object to break, so it "
               "proved nothing")
        return
    if fatal:
        record("nested-types", FAIL,
               "%d nested member(s) carry a JSON type the client cannot "
               "deserialize: %s" % (len(fatal), "; ".join(fatal[:6])))
    elif mut == "nestedtype":
        record("nested-types", FAIL,
               "the planted array at %s was NOT detected -- the walk is not "
               "descending, so its PASS means nothing" % planted)
    else:
        record("nested-types", OK,
               "%d members type-checked at every depth across %d routes "
               "(%d UNKNOWN, not counted as passes); 0 FATAL"
               % (checked, walked, found - checked))


def check_tolerated(w, mut):
    import dtogap as _g
    missing, superset, notes = [], [], []
    for route, key, trader in TOLERATED:
        # `find_capture` returns the FIRST captured body, and dtogap's own
        # docstring records why that is a trap: seq 083 for
        # /client/game/profile/list was captured before a profile existed, so
        # `data` is EMPTY, and an empty falsifier is indistinguishable from an
        # absent one. dtodeep/dtotype were moved to `find_captures`; this
        # consumer was left behind and would report INCONCLUSIVE (or, worse,
        # compare against nothing) for any route whose first body is empty.
        # Take the first capture that actually carries an object at `data`.
        cap, bsg_data = None, None
        for p in (_g.find_captures(route) or []):
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh).get("data")
            if isinstance(d, dict) and d:
                cap, bsg_data = p, d
                break
        if cap is None:
            record("tolerated", INCONC,
                   "no BSG capture for %s with a non-empty object at `data` "
                   "under %s (an EMPTY captured body is not evidence)"
                   % (route, _g.CAPTURE_ROOT))
            return
        want_present = (mut == "tolerated")
        if (key in bsg_data) != want_present:
            missing.append("BSG's %s %s carry %r"
                           % (os.path.basename(cap),
                              "does not" if want_present else "DOES", key))
        url = route if trader is None else route + "/" + trader
        st, doc, text = w.call(url, {})
        if doc is None or not isinstance(doc.get("data"), dict):
            record("tolerated", INCONC,
                   "%s did not answer a JSON object at `data` (status %s): %r"
                   % (url, st, text[:100]))
            return
        lost = sorted(set(bsg_data) - set(doc["data"]))
        if lost:
            superset.append("%s omits %d key(s) BSG sends: %s"
                            % (url, len(lost), ", ".join(lost)))
        notes.append("%s: %d BSG key(s), all served; %r correctly absent from both"
                     % (route, len(bsg_data), key))
    if missing:
        record("tolerated", FAIL, "; ".join(missing))
    elif superset:
        record("tolerated", FAIL, "; ".join(superset))
    else:
        record("tolerated", OK, "; ".join(notes))



# ---------------------------------------------------------------------------
# 13. the progression floors, and what "unlock the traders" really means
#
# Every assertion below is on an INDEPENDENT RE-READ of
# `/client/game/profile/list` after a settings POST -- never on the reply to
# the write.  And every expected number comes from a SECOND route rather than
# from a constant in this file:
#
#   the experience for a level    `/client/globals` -> config.exp.level.exp_table
#   a family's mastery threshold  `/client/globals` -> config.Mastering
#   a trader's top loyalty level  `/client/trading/api/traderSettings`
#                                 -> len(loyaltyLevels)
#
# That is the point.  Comparing the served profile against a table this file
# also owns is the self-comparison CLAUDE.md 9b is about; comparing it against
# the table the SERVER separately publishes can actually fail.
# ---------------------------------------------------------------------------

PROG_LEVEL = 25
PROG_SKILL = 10


def _set(w, key, value):
    """One settings edit through the mod's own settings route."""
    st, doc, text = w.call("/aowlspt/settings/aowl.tarkov",
                           {"key": key, "value": value})
    if doc is None:
        return False, "settings POST for %s did not parse: %r" % (key, text[:120])
    return True, ""


def _globals(w):
    st, doc, text = w.call("/client/globals", {})
    if doc is None:
        return None, "/client/globals did not parse (%d bytes)" % len(text)
    cfg = envelope(doc)
    if not isinstance(cfg, dict) or "config" not in cfg:
        return None, "/client/globals has no `config`"
    return cfg["config"], ""


def check_progression(w, mut):
    cfg, why = _globals(w)
    if cfg is None:
        record("progression", INCONC, why)
        record("skill-levels", INCONC, why)
        record("mastery", INCONC, why)
        return

    table = cfg.get("exp", {}).get("level", {}).get("exp_table")
    if not isinstance(table, list) or not table:
        record("progression", INCONC,
               "the server's globals carry no config.exp.level.exp_table")
        record("skill-levels", INCONC, "no exp table")
        record("mastery", INCONC, "no exp table")
        return
    want_level = PROG_LEVEL + (1 if mut == "progression" else 0)
    want_xp = sum(int(e.get("exp", 0)) for e in table[:want_level])

    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Prog" + tag, "standard")
    session = session_of(doc) if doc else ""
    if not session:
        record("progression", INCONC, "create gave no profile id: %r" % text[:120])
        record("skill-levels", INCONC, "no profile")
        record("mastery", INCONC, "no profile")
        return

    before, why = read_back(w, session)
    if before is None:
        record("progression", INCONC, why)
        record("skill-levels", INCONC, why)
        record("mastery", INCONC, why)
        return
    was_xp = int(before.get("Info", {}).get("Experience", 0))

    for key, value in (("progressionPlayerLevel", PROG_LEVEL),
                       ("progressionSkillLevel", PROG_SKILL),
                       ("progressionMasteryLevel", 3)):
        ok, why = _set(w, key, value)
        if not ok:
            record("progression", INCONC, why)
            record("skill-levels", INCONC, why)
            record("mastery", INCONC, why)
            return

    after, why = read_back(w, session)
    if after is None:
        record("progression", INCONC, why)
        record("skill-levels", INCONC, why)
        record("mastery", INCONC, why)
        return

    got_xp = int(after.get("Info", {}).get("Experience", 0))
    got_lv = int(after.get("Info", {}).get("Level", 0))
    if was_xp != 0:
        record("progression", INCONC,
               "the fresh profile already had %d experience, so a floor "
               "cannot be told from what was already there" % was_xp)
    elif got_xp != want_xp:
        record("progression", FAIL,
               "served Info.Experience=%d; the server's own exp_table puts "
               "level %d at %d" % (got_xp, want_level, want_xp))
    elif got_lv != PROG_LEVEL:
        record("progression", FAIL,
               "Info.Experience is right but Info.Level=%d, not %d -- the "
               "server and the screen will disagree" % (got_lv, PROG_LEVEL))
    else:
        record("progression", OK,
               "Info.Experience=%d, Info.Level=%d, matching the server's own "
               "exp_table for level %d (was %d before the setting)"
               % (got_xp, got_lv, PROG_LEVEL, was_xp))

    common = after.get("Skills", {}).get("Common")
    if not isinstance(common, list) or not common:
        record("skill-levels", FAIL,
               "the served profile has no Skills.Common array")
    else:
        # The falsifying input: one level higher than was actually asked for.
        want_prog = (PROG_SKILL + (1 if mut == "progression" else 0)) * 100.0
        low = sorted(str(e.get("Id")) for e in common
                     if float(e.get("Progress", 0) or 0) < want_prog)
        bad = sorted(str(e.get("Id")) for e in common
                     if str(e.get("Id")) in CLIENT_REJECTED_SKILL_IDS)
        if low:
            record("skill-levels", FAIL,
                   "%d of %d skills are still below Progress %d: %s"
                   % (len(low), len(common), int(want_prog),
                      ", ".join(low[:6])))
        elif bad:
            record("skill-levels", FAIL,
                   "the raise reintroduced %d skill id(s) the client rejects: "
                   "%s" % (len(bad), ", ".join(bad)))
        else:
            record("skill-levels", OK,
                   "all %d skills served at Progress >= %d (level %d), none "
                   "of the %d ids the client is measured to reject"
                   % (len(common), int(want_prog), PROG_SKILL,
                      len(CLIENT_REJECTED_SKILL_IDS)))

    families = cfg.get("Mastering")
    if not isinstance(families, list) or not families:
        record("mastery", INCONC,
               "the server's globals carry no config.Mastering table")
    else:
        served = dict((str(e.get("Id")), int(e.get("Progress", 0) or 0))
                      for e in (after.get("Skills", {}).get("Mastering") or []))
        short = []
        for f in families:
            name = str(f.get("Name", ""))
            # The falsifying input: one point past the family's own ceiling.
            want = int(f.get("Level3", 0) or 0) + (1 if mut == "progression" else 0)
            if name not in served:
                short.append("%s absent" % name)
            elif served[name] < want:
                short.append("%s %d<%d" % (name, served[name], want))
        if short:
            record("mastery", FAIL,
                   "%d of %d weapon families are not at mastery level 3: %s"
                   % (len(short), len(families), ", ".join(short[:6])))
        else:
            record("mastery", OK,
                   "all %d weapon families served at or above their OWN "
                   "Level3 threshold out of the server's config.Mastering"
                   % len(families))

    for key in ("progressionPlayerLevel", "progressionSkillLevel",
                "progressionMasteryLevel"):
        _set(w, key, 0)


def check_trader_unlock(w, mut):
    """The two DIFFERENT axes of "unlock the traders", proved to be different.

    `traderUnlockAllOffers` moves every OFFER down to loyalty 1 -- a property
    of the served ASSORT.  `traderMaxLoyalty` moves the PLAYER up -- a property
    of the served PROFILE.  Each is turned on alone and the OTHER one's payload
    is required to be UNCHANGED, which is what makes this a check rather than a
    restatement: one switch secretly doing both would fail it.
    """
    st, doc, text = w.call("/client/trading/api/traderSettings", {})
    bases = envelope(doc) if doc else None
    if not isinstance(bases, list) or not bases:
        record("trader-loyalty", INCONC,
               "traderSettings did not answer a non-empty array: %r" % text[:120])
        record("trader-offers", INCONC, "no trader bases")
        return
    tops = dict((str(b.get("_id")), len(b.get("loyaltyLevels") or []))
                for b in bases)

    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Loy" + tag, "standard")
    session = session_of(doc) if doc else ""
    if not session:
        record("trader-loyalty", INCONC, "create gave no profile id")
        record("trader-offers", INCONC, "no profile")
        return
    before, why = read_back(w, session)
    if before is None:
        record("trader-loyalty", INCONC, why)
        record("trader-offers", INCONC, why)
        return
    was = dict((t, int(v.get("loyaltyLevel", 0) or 0))
               for t, v in (before.get("TradersInfo") or {}).items())
    if not was:
        record("trader-loyalty", INCONC, "the fresh profile has no TradersInfo")
        record("trader-offers", INCONC, "no TradersInfo")
        return

    probe = sorted(t for t in was if tops.get(t, 0) > 1)
    if not probe:
        record("trader-loyalty", INCONC,
               "no trader on this server declares more than one loyalty level")
        record("trader-offers", INCONC, "no gated trader")
        return
    tid = probe[0]
    st, doc, text = w.call("/client/trading/api/getTraderAssort/" + tid, {})
    assort = envelope(doc) if doc else None
    gate_before = dict((assort or {}).get("loyal_level_items") or {})

    ok, why = _set(w, "traderMaxLoyalty", True)
    if not ok:
        record("trader-loyalty", INCONC, why)
        record("trader-offers", INCONC, why)
        return
    after, why = read_back(w, session)
    if after is None:
        record("trader-loyalty", INCONC, why)
        _set(w, "traderMaxLoyalty", False)
        record("trader-offers", INCONC, why)
        return
    now = dict((t, int(v.get("loyaltyLevel", 0) or 0))
               for t, v in (after.get("TradersInfo") or {}).items())
    st, doc, text = w.call("/client/trading/api/getTraderAssort/" + tid, {})
    assort = envelope(doc) if doc else None
    gate_after = dict((assort or {}).get("loyal_level_items") or {})
    _set(w, "traderMaxLoyalty", False)

    short = []
    for t, top in tops.items():
        if t not in now or top <= 0:
            continue
        # The falsifying input: demand a level ABOVE the top the trader
        # itself declares, which a correct server cannot reach.
        want = top + 1 if mut == "loyalty" else top
        if now[t] < want:
            short.append("%s %d<%d" % (t[:6], now[t], want))
    moved = sum(1 for t in now if now[t] > was.get(t, 0))
    if short:
        record("trader-loyalty", FAIL,
               "%d trader(s) below the top loyalty level their own "
               "loyaltyLevels array declares: %s"
               % (len(short), ", ".join(short[:6])))
    elif moved == 0:
        record("trader-loyalty", FAIL,
               "no trader's loyaltyLevel moved -- the setting was accepted "
               "and had no effect on the served profile")
    elif gate_after != gate_before:
        record("trader-loyalty", FAIL,
               "traderMaxLoyalty also rewrote the ASSORT's loyal_level_items "
               "(%d -> %d entries) -- that is traderUnlockAllOffers' job and "
               "the two must stay separable"
               % (len(gate_before), len(gate_after)))
    else:
        record("trader-loyalty", OK,
               "%d trader(s) raised to the top level their own loyaltyLevels "
               "declares; the assort's %d loyal_level_items entries untouched "
               "-- the PLAYER axis, not the OFFER axis"
               % (moved, len(gate_before)))

    _set(w, "traderUnlockAllOffers", True)
    st, doc, text = w.call("/client/trading/api/getTraderAssort/" + tid, {})
    assort = envelope(doc) if doc else None
    gate_open = dict((assort or {}).get("loyal_level_items") or {})
    _set(w, "traderUnlockAllOffers", False)
    if not gate_open:
        record("trader-offers", INCONC,
               "the assort for %s carries no loyal_level_items" % tid[:6])
        return
    if mut == "loyalty":
        still = sorted(k for k, v in gate_before.items() if int(v or 0) > 1)
    else:
        still = sorted(k for k, v in gate_open.items() if int(v or 0) > 1)
    gated_off = sum(1 for v in gate_before.values() if int(v or 0) > 1)
    if still:
        record("trader-offers", FAIL,
               "%d of %d offers still gated above loyalty 1 with "
               "traderUnlockAllOffers on" % (len(still), len(gate_open)))
    elif gated_off == 0:
        record("trader-offers", INCONC,
               "nothing was gated above loyalty 1 with the switch OFF, so "
               "turning it on proves nothing")
    else:
        record("trader-offers", OK,
               "all %d offers served at loyalty 1 with traderUnlockAllOffers "
               "on, against %d gated above 1 with it off"
               % (len(gate_open), gated_off))



# ---------------------------------------------------------------------------
# 14. A SETTING, WRITTEN AND READ BACK
#
# The whole reason this check exists: `POST /aowlspt/settings/<guid>` answers
# 200 with the schema whether or not the value was kept (fact #135 -- a chunked
# POST is treated as bodyless and answered 200 unchanged; and a persist that
# fails answers the schema too).  So the STATUS CODE PROVES NOTHING, and neither
# does the POST's own reply body: the only thing that settles it is a SEPARATE
# re-read afterwards, compared against what was asked for.
#
# Fact #122: the schema emits `value` UNQUOTED, so the document can fail to be
# JSON at all.  It is parsed STRICTLY here and an unparseable body is reported
# as such rather than coped with -- coping is how that defect stays invisible.
#
# Three outcomes.  No writable server-side row anywhere is INCONCLUSIVE, not a
# pass: "I could not look" is not "it works".
# ---------------------------------------------------------------------------


def _settings_get(port, path):
    """A GET on a settings route.  Returns (status, raw-text)."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", path, b"", {"Accept-Encoding": "identity"})
    r = c.getresponse()
    raw = r.read()
    c.close()
    if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
        raw = zlib.decompress(raw)
    return r.status, raw.decode("utf-8", "replace")


def _settings_rows(port, guid):
    """The rows a page serves, strictly parsed.

    Returns (rows, why).  `rows` is None when the body is not a schema, and
    `why` then says which of the two failures it was -- a body that is not
    JSON at all, or JSON that is not the shape.  The bare array and the
    `{"err":..,"rows":[..]}` refusal shape are both understood, because the
    refusal is what a correct server sends when the write did NOT persist and
    it must not read here as "the page has no rows".
    """
    st, text = _settings_get(port, "/aowlspt/settings/" + guid)
    if st != 200:
        return None, "the page answered HTTP %d" % st
    try:
        doc = json.loads(text)
    except Exception as exc:                       # noqa: BLE001
        return None, ("the schema is not valid JSON (%s) -- fact #122: `value` "
                      "is emitted unquoted" % exc)
    if isinstance(doc, list):
        return doc, ""
    if isinstance(doc, dict) and isinstance(doc.get("rows"), list):
        return doc["rows"], doc.get("err") or ""
    return None, "the page answered JSON that is not a schema"


def _writable_row(rows):
    """A row this check can flip, and its current value.

    Bools only, and only implemented ones: a bool has exactly one other legal
    value, so the write can never be refused for being out of range and a
    revert can never be confused with a clamp.
    """
    for r in rows:
        if not isinstance(r, dict):
            continue
        if r.get("type") != "bool" or not r.get("implemented"):
            continue
        cur = r.get("value")
        if not isinstance(cur, bool):
            continue
        return r.get("key"), cur
    return None, None


def check_settings_write(w, mut):
    st, text = _settings_get(w.port, "/aowlspt/settings/index")
    try:
        idx = json.loads(text)
    except Exception as exc:                       # noqa: BLE001
        record("settings-write", INCONC,
               "the settings index is not valid JSON (%s)" % exc)
        return
    mods = (idx or {}).get("mods") if isinstance(idx, dict) else None
    if not isinstance(mods, list) or not mods:
        record("settings-write", INCONC,
               "the settings index named no mods, so there was nothing to write")
        return

    # SERVER-SIDE pages only.  A `client:true` page is owned by the game
    # process and its edits are QUEUED, not applied, so an IMMEDIATE
    # re-read shows the old value -- correctly, which is why this case does
    # not touch them.  It is no longer unchecked: `check_settings_write_
    # client` does the same round trip with a bounded wait instead of an
    # immediate re-read.  Leaving that transport out entirely is how the
    # client host shipped for months answering ErrUnsupported to every
    # config write with nothing red anywhere.
    tried = []
    for m in mods:
        if not isinstance(m, dict) or m.get("client"):
            continue
        guid = m.get("guid") or ""
        if not guid:
            continue
        rows, why = _settings_rows(w.port, guid)
        if rows is None:
            tried.append("%s: %s" % (guid, why))
            continue
        key, cur = _writable_row(rows)
        if not key:
            tried.append("%s: no implemented bool row" % guid)
            continue

        want = not cur
        wire = "true" if want else "false"
        st2, _, ptext = w.call("/aowlspt/settings/" + guid,
                               {"key": key, "value": want})

        after, why2 = _settings_rows(w.port, guid)
        if after is None:
            record("settings-write", INCONC,
                   "%s.%s was written but the re-read failed: %s"
                   % (guid, key, why2))
            return
        got = None
        for r in after:
            if isinstance(r, dict) and r.get("key") == key:
                got = r.get("value")
        # Put it back before reporting, so a failing run is not also a
        # destructive one.
        w.call("/aowlspt/settings/" + guid, {"key": key, "value": cur})

        if got is None:
            record("settings-write", INCONC,
                   "%s.%s vanished from the schema after the write" % (guid, key))
            return

        # THE FALSIFYING INPUT.  `--mutate setwrite` demands the value came
        # back UNCHANGED -- the silent-revert shape -- so a server that really
        # persists must go red here.
        applied = (got == want)
        if mut == "setwrite":
            applied = (got == cur)
        if applied:
            record("settings-write", OK,
                   "%s.%s written %s over HTTP %d and READ BACK %s by a "
                   "separate GET" % (guid, key, wire, st2, json.dumps(got)))
        else:
            record("settings-write", FAIL,
                   "%s.%s was set to %s, the server answered HTTP %d, and a "
                   "SEPARATE re-read still says %s -- a 200 with the schema "
                   "unchanged is fact #135's silent no-op, not a write"
                   % (guid, key, wire, st2, json.dumps(got)))
        return

    record("settings-write", INCONC,
           "no server-side page offered an implemented bool row to write (%s)"
           % ("; ".join(tried) if tried else "no server-side pages at all"))


def check_settings_write_client(w, mut):
    """The CLIENT-side round trip: write, wait, re-read from a separate GET.

    This case used to be excluded, with the stated reason that a client page's
    edits are QUEUED rather than applied, so an immediate re-read correctly
    shows the old value.  That reason was true and the conclusion was wrong:
    it made the one transport that was completely broken -- the client host
    answered ErrUnsupported for every config write, so no client-side setting
    could ever change -- the one transport nothing checked.

    Queued is not unbounded.  The bridge cycle is ~5s, so the honest check is
    a BOUNDED WAIT on the finished state: poll a separate GET until the value
    is what was asked for, or until the window closes.  Three outcomes:

      PASS          a separate GET reports the new value inside the window
      FAIL          the window closed and the value is still the old one
      INCONCLUSIVE  no client page is published at all, or it is still
                    `waiting`, or no page offers a flippable bool -- "I could
                    not look" is not a pass
    """
    window_s = 20.0
    poll_s = 1.0

    st, text = _settings_get(w.port, "/aowlspt/settings/index")
    try:
        idx = json.loads(text)
    except Exception as exc:                       # noqa: BLE001
        record("settings-write-client", INCONC,
               "the settings index is not valid JSON (%s)" % exc)
        return
    mods = (idx or {}).get("mods") if isinstance(idx, dict) else None
    if not isinstance(mods, list) or not mods:
        record("settings-write-client", INCONC,
               "the settings index named no mods")
        return

    tried = []
    for m in mods:
        if not isinstance(m, dict) or not m.get("client"):
            continue
        guid = m.get("guid") or ""
        if not guid:
            continue
        rows, why = _settings_rows(w.port, guid)
        if rows is None:
            tried.append("%s: %s" % (guid, why))
            continue
        if not rows:
            # The `waiting` reply: published in the nav, page not pushed yet.
            tried.append("%s: no rows yet (%s)" % (guid, why or "no reason given"))
            continue
        key, cur = _writable_row(rows)
        if not key:
            tried.append("%s: no implemented bool row" % guid)
            continue

        want = not cur
        wire = "true" if want else "false"
        st2, _, _ = w.call("/aowlspt/settings/" + guid,
                           {"key": key, "value": want})

        got = cur
        waited = 0.0
        while waited < window_s:
            time.sleep(poll_s)
            waited += poll_s
            after, why2 = _settings_rows(w.port, guid)
            if after is None:
                continue
            for r in after:
                if isinstance(r, dict) and r.get("key") == key:
                    got = r.get("value")
            if got == want:
                break

        # Put it back, and give the bridge the same window to take it, so a
        # failing run is not also a destructive one.
        w.call("/aowlspt/settings/" + guid, {"key": key, "value": cur})

        # THE FALSIFYING INPUT.  `--mutate setwriteclient` demands the value
        # came back UNCHANGED after the full window -- the shape this whole
        # case exists to catch -- so a host that really persists goes red.
        applied = (got == want)
        if mut == "setwriteclient":
            applied = (got == cur)
        if applied:
            record("settings-write-client", OK,
                   "%s.%s written %s over HTTP %d and READ BACK %s by a "
                   "separate GET after %.0fs"
                   % (guid, key, wire, st2, json.dumps(got), waited))
        else:
            record("settings-write-client", FAIL,
                   "%s.%s was set to %s, the server answered HTTP %d, and a "
                   "SEPARATE re-read still says %s after %.0fs -- the game "
                   "process never applied it (check the host log's `client "
                   "settings bridge:` lines for the refusal)"
                   % (guid, key, wire, st2, json.dumps(got), window_s))
        return

    record("settings-write-client", INCONC,
           "no client-side page offered an implemented bool row to write (%s)"
           % ("; ".join(tried) if tried else "no client-side pages at all -- "
              "the game process has not published, so this was NOT checked"))
# ---------------------------------------------------------------------------
# 15. mail: the TYPE of every member, not its presence
#
# The defect this exists for: `/client/mail/dialog/list` served
# `"systemData": false`.  The client declares
# `DialogueChatMessageSerializer.systemData` as `ChatMessageSystemData`, a
# CLASS (measured with tools/fldoff.py), so Newtonsoft threw
# "Could not cast or convert from System.Boolean" inside ExecuteRequest and the
# RAID LOAD died -- not the inbox.  Every check we had asked "is the member
# there?", and it was.
#
# So this asserts a NEGATIVE about the FINISHED payload: no message in the
# served inbox carries a `systemData` that is anything other than an object or
# null (absent is fine -- a reference member left null is what BSG's own
# ordinary messages produce, and we do NOT invent a populated one).
# `--mutate systemdata` demands a BOOLEAN instead, so a correct payload must
# FAIL -- that is the falsifying input.
def check_mail_types(w, mut):
    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Mail" + tag, "standard")
    if doc is None or not session_of(doc):
        record("mail-types", INCONC, "no profile to post mail to")
        return
    sess = session_of(doc)
    w.call("/client/game/profile/select", {"uid": sess}, sess)
    # A raid that hands an item over is the cheapest way to make the server
    # post real mail; an empty inbox would make this check unfalsifiable.
    body = {"serverId": "betacheck.factory4_day.0",
            "results": {"profile": {"_id": sess}, "result": "Survived",
                        "killerId": "", "killerAid": "", "exitName": "Gate 0",
                        "inSession": True, "favorite": False, "playTime": 60},
            "lostInsuredItems": [],
            "transferItems": {sess: [{"_id": "aaaaaaaaaaaaaaaaaaaaaa01",
                                      "_tpl": "5449016a4bdc2d6f028b456f",
                                      "upd": {"StackObjectsCount": 5000}}]}}
    w.call("/client/match/local/end", body, sess)
    st, doc, text = w.call("/client/mail/dialog/list", {}, sess)
    if doc is None:
        record("mail-types", INCONC,
               "mail/dialog/list did not parse as JSON (%d bytes)" % len(text))
        return
    rows = envelope(doc)
    if not isinstance(rows, list) or not rows:
        record("mail-types", INCONC,
               "the served inbox is empty, so no message TYPE was examined")
        return
    bad = []
    for d in rows:
        m = d.get("message")
        if not isinstance(m, dict):
            bad.append("dialog %r has no message object" % d.get("_id"))
            continue
        if "systemData" not in m:
            sd, kind = None, "absent"
        else:
            sd = m["systemData"]
            kind = ("null" if sd is None else
                    "object" if isinstance(sd, dict) else type(sd).__name__)
        want_bool = (mut == "systemdata")
        ok = isinstance(sd, bool) if want_bool else kind in ("absent", "null", "object")
        if not ok:
            bad.append("dialog %r message.systemData is %s (%r)"
                       % (d.get("_id"), kind, sd))
    if bad:
        record("mail-types", FAIL, "; ".join(bad[:3]))
    elif mut == "systemdata":
        record("mail-types", OK,
               "every message.systemData is a boolean (mutated expectation)")
    else:
        record("mail-types", OK,
               "%d dialog(s): every message.systemData is object/null/absent, "
               "never a scalar" % len(rows))



# ---------------------------------------------------------------------------
# 15b. mail: every sender id the client will build a MongoID from
#
# The defect this exists for, found the same way as 15 -- in the CLIENT's own
# errors log, not in any sweep of ours:
#
#   ArgumentOutOfRangeException: ... Critical MongoId error: incorrect length.
#   Id:
#     at EFT.MongoID..ctor (System.String id)
#     at ChatShared.UpdatableChatMember..ctor (System.String id)
#     at ChatShared.ChatMessagesList+DialogueChatMessageSerializer.Deserialize
#
# `DialogueChatMessageSerializer` hands the message's `uid` straight to
# `MongoID..ctor`, which rejects anything that is not 24 characters.  The BTR
# hand-over posted mail with sender `""` and the flea notices with
# `"ragfair"`; either throws, and the throw takes the WHOLE dialog/list
# response with it -- the inbox does not miss a row, it does not load at all.
#
# The assertion is a NEGATIVE about the finished payload: no dialog `_id` and
# no `message.uid` in the served inbox is anything other than exactly 24
# characters.  `--mutate senderid` demands 23 instead, so a correct payload
# must FAIL -- that is the falsifying input.
def check_mail_sender_id(w, mut):
    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Sender" + tag, "standard")
    if doc is None or not session_of(doc):
        record("mail-sender-id", INCONC, "no profile to post mail to")
        return
    sess = session_of(doc)
    w.call("/client/game/profile/select", {"uid": sess}, sess)
    # The hand-over path is the one that posts a message with NO trader behind
    # it -- the exact case that used to serve an empty uid.
    body = {"serverId": "betacheck.factory4_day.0",
            "results": {"profile": {"_id": sess}, "result": "Survived",
                        "killerId": "", "killerAid": "", "exitName": "Gate 0",
                        "inSession": True, "favorite": False, "playTime": 60},
            "lostInsuredItems": [],
            "transferItems": {sess: [{"_id": "aaaaaaaaaaaaaaaaaaaaaa01",
                                      "_tpl": "5449016a4bdc2d6f028b456f",
                                      "upd": {"StackObjectsCount": 5000}}]}}
    w.call("/client/match/local/end", body, sess)
    st, doc, text = w.call("/client/mail/dialog/list", {}, sess)
    if doc is None:
        record("mail-sender-id", INCONC,
               "mail/dialog/list did not parse as JSON (%d bytes)" % len(text))
        return
    rows = envelope(doc)
    if not isinstance(rows, list) or not rows:
        record("mail-sender-id", INCONC,
               "the served inbox is empty, so no sender id was examined")
        return
    want = 23 if mut == "senderid" else 24
    bad, seen = [], 0
    for d in rows:
        ids = [("_id", d.get("_id"))]
        m = d.get("message")
        if isinstance(m, dict):
            ids.append(("message.uid", m.get("uid")))
        for where, v in ids:
            if not isinstance(v, str):
                bad.append("dialog %s is %s, not a string"
                           % (where, type(v).__name__))
                continue
            seen += 1
            if len(v) != want:
                bad.append("%s = %r is %d chars; EFT.MongoID..ctor requires %d"
                           % (where, v, len(v), want))
    if bad:
        record("mail-sender-id", FAIL, "; ".join(bad[:3]))
    elif mut == "senderid":
        record("mail-sender-id", OK,
               "every sender id is 23 chars (mutated expectation)")
    elif not seen:
        record("mail-sender-id", INCONC, "no sender id was actually examined")
    else:
        record("mail-sender-id", OK,
               "%d sender id(s) across %d dialog(s), all 24 chars, so "
               "MongoID..ctor cannot throw" % (seen, len(rows)))


# ---------------------------------------------------------------------------
# 16. profile/list: Dictionary members must be OBJECTS, never empty arrays
#
# Same class as check 15 above.  Six members of `EFT.ProfileDescriptor` (and of
# its `Hideout`) are declared `Dictionary<...>` -- measured with
# tools/fldoff.py -- and this server emitted `[]` for every one of them,
# because an "empty collection" default reached for a seq.  Newtonsoft does not
# degrade on a Dictionary that arrives as a JSON array: it throws, inside the
# client's own ExecuteRequest, which is how `systemData: false` killed a raid
# load rather than an inbox.
#
# This asserts a NEGATIVE about the FINISHED served payload: no member in
# DICT_MEMBERS is a list.  Absent is INCONCLUSIVE for that member rather than a
# pass -- "I could not look" is not a pass -- and a non-dict scalar is a FAIL.
# `--mutate dictshapes` demands a LIST instead, so a correct server must go red;
# that is the falsifying input.
DICT_MEMBERS = [
    ("Hideout", "MannequinPoses"),   # Dictionary<string, MongoID>
    (None, "WishList"),              # Dictionary<MongoID, byte>
    (None, "Achievements"),          # Dictionary<MongoID, int>
    (None, "Prestige"),              # Dictionary<MongoID, int>
    (None, "CompletableItems"),      # Dictionary<MongoID, bool>
    (None, "SeasonalRewards"),       # Dictionary<MongoID, SeasonalRewardData>
]


def check_dict_shapes(w, mut):
    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Dict" + tag, "standard")
    if doc is None or not session_of(doc):
        record("dict-shapes", INCONC, "no profile to read")
        return
    sess = session_of(doc)
    w.call("/client/game/profile/select", {"uid": sess}, sess)
    p, why = read_back(w, sess)
    if p is None:
        record("dict-shapes", INCONC, why)
        return
    want_list = (mut == "dictshapes")
    bad, missing, seen = [], [], 0
    for parent, name in DICT_MEMBERS:
        holder = p if parent is None else p.get(parent)
        label = name if parent is None else parent + "." + name
        if not isinstance(holder, dict) or name not in holder:
            missing.append(label)
            continue
        seen += 1
        v = holder[name]
        ok = isinstance(v, list) if want_list else isinstance(v, dict)
        if not ok:
            bad.append("%s is %s (%s)" % (label, type(v).__name__,
                                          json.dumps(v)[:40]))
    if bad:
        record("dict-shapes", FAIL, "; ".join(bad))
    elif seen == 0:
        record("dict-shapes", INCONC,
               "none of the %d Dictionary members were on the wire: %s"
               % (len(DICT_MEMBERS), ", ".join(missing)))
    elif missing:
        record("dict-shapes", INCONC,
               "%d/%d checked; absent and therefore not examined: %s"
               % (seen, len(DICT_MEMBERS), ", ".join(missing)))
    elif want_list:
        record("dict-shapes", OK,
               "all %d Dictionary members are arrays (mutated expectation)" % seen)
    else:
        record("dict-shapes", OK,
               "all %d declared-Dictionary members are JSON objects, "
               "never arrays" % seen)


# ---------------------------------------------------------------------------
# 17. /client/weather: `weather` is ONE object, and that is BSG's own shape
#
# This is the check that stops a future "fix" from breaking a working route.
# An audit read `/client/weather` against `JsonType.WeatherResponse`, whose
# `Weathers` is `WeatherNode[]`, and reported that we send an object where an
# array is declared.  The mapping was wrong, not the payload: the route's DTO
# is `JsonType.LocationWeatherTime` (Season, SeasonsSettings, Weather:
# WeatherNode, Acceleration, Date, Time -- a 5/5 key match against the served
# body, versus 2/5 for WeatherResponse), and BSG's OWN captured response
# raid1/responses/131.json sends `"weather": { ... }`, an object.
#
# So the assertion is: `data.weather` is a JSON object, exactly as the capture
# has it.  `--mutate weatherarray` demands an array -- the shape the wrong DTO
# implied -- so a correct server must go red.
def check_weather_shape(w, mut):
    st, doc, text = w.call("/client/weather", {})
    if doc is None:
        record("weather-shape", INCONC,
               "/client/weather did not parse as JSON (%d bytes)" % len(text))
        return
    d = envelope(doc)
    if not isinstance(d, dict) or "weather" not in d:
        record("weather-shape", INCONC,
               "the served body carries no `weather` member to examine")
        return
    v = d["weather"]
    want_list = (mut == "weatherarray")
    ok = isinstance(v, list) if want_list else isinstance(v, dict)
    if not ok:
        record("weather-shape", FAIL,
               "data.weather is %s, not %s" % (type(v).__name__,
                                               "an array" if want_list else "an object"))
    elif want_list:
        record("weather-shape", OK, "data.weather is an array (mutated expectation)")
    else:
        record("weather-shape", OK,
               "data.weather is one object with %d members, as BSG capture 131 "
               "sends it" % len(v))
# The four container shapes below are not guesses. Each one is quoted from a
# Newtonsoft exception the CLIENT ITSELF wrote into
# D:\Aowlspt\Logs\<ts>\...errors_000.log, alongside the systemData boolean
# that check_mail_types already guards:
#
#   20x  "Cannot deserialize the current JSON array ... into type
#         'EFT.Dialogs.TraderDialogsDTO' because the type requires a JSON
#         object"                                        -> /client/dialogue
#    4x  ... 'EFT.GlobalConfiguration+MainQuestSettings' requires a JSON object
#                                          -> /client/globals .config.MainQuest
#    2x  "Cannot deserialize the current JSON object ... into type
#         'EFT.AvailableCustomizationsResponse' because the type requires a
#         JSON array"                     -> /client/account/customization
#    2x  ... 'EFT.SeasonalPerks.SeasonalPerksData' requires a JSON object
#                                          -> /client/seasonal-perks/list
#
# All four are fixed. Nothing re-checked them, so nothing would notice them
# coming back -- and object-vs-array does not degrade, it throws inside
# ExecuteRequest and takes the raid load with it.
#
# The assertion is a NEGATIVE about the finished payload ("this container is
# not the wrong JSON kind"), and `absent` is deliberately NOT a pass for the
# routes whose DTO is the response itself: a 404 or an empty envelope would
# otherwise skim as success, which is the failure mode this file exists for.
SHAPES = [
    # (check-suffix, route, body, dotted path under the envelope, want, mutant)
    ("dialogue",   "/client/dialogue",                {}, "",
     dict, "EFT.Dialogs.TraderDialogsDTO"),
    ("seasonal",   "/client/seasonal-perks/list",     {}, "",
     dict, "EFT.SeasonalPerks.SeasonalPerksData"),
    ("customization", "/client/account/customization", None, "",
     list, "EFT.AvailableCustomizationsResponse"),
    ("mainquest",  "/client/globals",                 {}, "config.MainQuest",
     dict, "EFT.GlobalConfiguration+MainQuestSettings"),
]


def _dig(obj, path):
    """(found, value). `found` is False for 'no such key', which is a DIFFERENT
    outcome from a key holding null -- the caller must keep them apart."""
    cur = obj
    for part in [p for p in path.split(".") if p]:
        if not isinstance(cur, dict) or part not in cur:
            return False, None
        cur = cur[part]
    return True, cur


def check_dto_map(w, mut):
    """Every route we SAMPLE must have a dtogap entry -- mapped, or n/a WITH A
    REASON. Neither is optional and neither is silence.

    ## Why this is a check and not bookkeeping

    An unmapped route produces no row anywhere: dtogap prints INCONCLUSIVE,
    dtotype prints "no DTO mapped -- TYPES NOT CHECKED", and both scroll past.
    Nothing ever goes red. /client/mail/dialog/list was in exactly that state
    -- 43 hits per session in the client's own backend_000.log, the single
    most-called route it has -- while BOTH of the week's live crash-class bugs
    lived on it (`systemData: false` into ChatMessageSystemData, and a sender
    id that was not 24 chars and threw in EFT.MongoID's constructor, killing
    the ENTIRE inbox response). Neither was findable by the audit. That is a
    coverage hole behaving like a pass, which is CLAUDE.md 9b exactly.

    So the assertion is on the FINISHED STATE of the map and is a NEGATIVE:
    no route this repo samples is absent from it, and no entry declines to
    say why it has no DTO. It needs no backend and no payload -- it is a
    property of the two tables -- so it can never be skipped for lack of a
    running server, which is the other way a check quietly stops running.

    Falsifiable by construction: `--mutate dtomap` removes one route from the
    map, and this must go red.
    """
    import dtogap as _g
    import oursample as _o
    routes = [c[0] for c in _o.CALLS]
    table = dict(_g.ROUTES)
    if mut == "dtomap" and routes:
        victim = "/client/mail/dialog/list" if "/client/mail/dialog/list" in table \
            else routes[0]
        table.pop(victim, None)
    unmapped = [r for r in routes if r not in table]
    silent = sorted(k for k, v in table.items()
                    if not v[0] and not (len(v) > 2 and v[2] and v[2].strip()))
    if unmapped:
        record("dto-map", FAIL,
               "%d of %d sampled route(s) have NO dtogap entry, so they are "
               "not INCONCLUSIVE -- they are invisible: %s"
               % (len(unmapped), len(routes), ", ".join(sorted(unmapped))))
        return
    if silent:
        record("dto-map", FAIL,
               "%d entry/entries map to no DTO and give no reason; 'n/a' "
               "without a stated reason is indistinguishable from an "
               "oversight: %s" % (len(silent), ", ".join(silent)))
        return
    withdto = sum(1 for r in routes if table[r][0])
    record("dto-map", OK,
           "all %d sampled routes are accounted for: %d carry a DTO, %d are "
           "explicitly reason-bearing n/a" % (len(routes), withdto,
                                              len(routes) - withdto))


def check_route_shapes(w, mut):
    """Every container the client crashed on, re-asserted against live output."""
    tag = "%04d" % random.randrange(10000)
    st, doc, text = make_profile(w, "Shape" + tag, "standard")
    sess = session_of(doc) if doc else ""
    if not sess:
        record("route-shapes", INCONC, "no profile, so no route was sampled")
        return
    w.call("/client/game/profile/select", {"uid": sess}, sess)

    bad, seen, skipped = [], [], []
    for suffix, route, body, path, want, dto in SHAPES:
        st, doc, text = w.call(route, body, sess)
        if doc is None:
            bad.append("%s: did not parse as JSON (HTTP %d, %d bytes)"
                       % (route, st, len(text)))
            continue
        err = doc.get("err") if isinstance(doc, dict) else None
        if err not in (None, 0, "0"):
            bad.append("%s: envelope err=%r" % (route, err))
            continue
        found, val = _dig(envelope(doc), path)
        if not found:
            # MainQuest is a MEMBER of a larger DTO: absent leaves the field
            # null, which cannot throw. Absence of a whole response body can.
            if path:
                skipped.append("%s .%s absent (null member, not a throw)"
                               % (route, path))
                continue
            bad.append("%s: nothing at %r" % (route, path or "<envelope>"))
            continue
        got = type(val).__name__
        if mut == "shapes":
            # The falsifying input: assert the WRONG kind on purpose. If this
            # does not turn the check red, the check is not looking.
            want = list if want is dict else dict
        ok = isinstance(val, want) and not isinstance(val, bool)
        if ok:
            seen.append("%s%s=%s" % (route, ("." + path) if path else "", got))
        else:
            bad.append("%s%s is %s, client declares %s which requires a JSON %s"
                       % (route, ("." + path) if path else "", got, dto,
                          "object" if want is dict else "array"))
    if bad:
        record("route-shapes", FAIL, "; ".join(bad[:4]))
    elif mut == "shapes":
        record("route-shapes", OK, "every container is the WRONG kind "
                                   "(mutated expectation)")
    elif not seen:
        record("route-shapes", INCONC,
               "no container was actually examined: " + "; ".join(skipped))
    else:
        record("route-shapes", OK,
               "%d container(s) hold the kind the client's DTO requires (%s)%s"
               % (len(seen), ", ".join(seen),
                  ("; not examined: " + "; ".join(skipped)) if skipped else ""))


# ------------------------------------------------------- the mutation table
#
# `--mutate typo` used to fall through every `mut == "..."` branch, run the
# UNMUTATED check and print PASS.  A falsifier that cannot fail is worth less
# than no falsifier, so the name is now validated against a table -- and the
# table itself is validated against the source, so it cannot silently drift
# out of date the way it already had (four mutations existed with no doc line).
def mutations():
    """{name: one-line doc} for every --mutate this file implements.

    Both halves are DERIVED, never written twice: the names come from the
    `mut == "..."` branches in this file's own source, the docs from this
    module's docstring.  A name in one and not the other is a defect in
    betacheck itself and is reported as such -- it does not silently reduce
    to a shorter list.
    """
    doc, started = {}, False
    for line in (__doc__ or "").splitlines():
        if "runs a deliberately wrong variant" in line:
            started = True
            continue
        if not started:
            continue
        m = re.match(r"^    ([a-z]{3,14}) +(\S.*)$", line)
        if m:
            doc[m.group(1)] = m.group(2).strip()
    try:
        with open(os.path.abspath(__file__), encoding="utf-8") as f:
            src = set(re.findall(r'mut == "([a-z]+)"', f.read()))
    except OSError:
        src = set(doc)
    undoc, unimpl = sorted(src - set(doc)), sorted(set(doc) - src)
    if undoc or unimpl:
        sys.exit("betacheck's mutation table disagrees with its own source."
                 "\n  implemented but undocumented: %s"
                 "\n  documented but not implemented: %s\n"
                 "Fix the docstring or the branch; do not ship a --mutate list "
                 "that is wrong about what it can falsify."
                 % (", ".join(undoc) or "none", ", ".join(unimpl) or "none"))
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7788)
    ap.add_argument("--spawn", action="store_true",
                    help="stand up a private backend on a FREE port against a "
                         "scratch root, run the checks, and tear it down. "
                         "Several agents each spent ~20 minutes building this "
                         "root by hand, and two of them collided on the same "
                         "scratchpad path -- one overwrote the other's staged "
                         "DLL, so a selfcheck passed against the wrong binary "
                         "(fact #153). The root here is unique per PID and "
                         "REFUSES a directory it did not create.")
    ap.add_argument("--db", default="",
                    help="db.json to stage into the spawned root "
                         "(default: the live D:/Aowlspt/aowlspt/db.json)")
    ap.add_argument("--root", default="",
                    help="scratch root for --spawn (default: a unique "
                         "per-PID directory under TEMP)")
    ap.add_argument("--backend", default="",
                    help="aowlspt-backend.exe for --spawn "
                         "(default: <repo>/backend/bin/aowlspt-backend.exe)")
    ap.add_argument("--tarkov", default="",
                    help="tarkov.dll to stage for --spawn (default: this "
                         "worktree's build, else the deployed one -- the "
                         "tool always PRINTS which it used)")
    ap.add_argument("--keep", action="store_true",
                    help="do not delete the spawned root, so it can be "
                         "inspected after a failure")
    ap.add_argument("--spt", default="D:\\SPT")
    ap.add_argument("--mutate", default="",
                    help="run a deliberately wrong variant to prove a check "
                         "can FAIL. An unknown name is REFUSED, never ignored. "
                         "--list-mutations prints them all.")
    ap.add_argument("--list-mutations", action="store_true",
                    help="print every valid --mutate name and what it "
                         "falsifies, then exit")
    ap.add_argument("--loose-dir", default="",
                    help="where the backend reads per-map looseLoot "
                         "sidecars from (default <repo>/build/db/looseloot)")
    a = ap.parse_args(namespace=argparse.Namespace())
    known = mutations()
    if a.list_mutations:
        print("valid --mutate names (%d):" % len(known))
        for k in sorted(known):
            print("  %-14s %s" % (k, known[k]))
        return 0
    if a.mutate and a.mutate not in known:
        sys.exit("unknown --mutate %r. betacheck used to accept this, run the "
                 "UNMUTATED check and print PASS -- a falsifier that cannot "
                 "fail.\nValid names: %s"
                 "\n(--list-mutations describes each.)"
                 % (a.mutate, ", ".join(sorted(known))))
    # Remember whether --port was typed, so --spawn can pick a FREE port
    # instead of the shared 7788 default two concurrent runs both grabbed.
    a.port_explicit = a.port if any(
        x == "--port" or x.startswith("--port=") for x in sys.argv[1:]) else 0
    if a.spawn:
        _proc, a.port, _root = spawn_backend(a)
    elif a.db or a.root or a.backend or a.keep or a.tarkov:
        sys.exit("--db/--root/--backend/--keep only mean anything with "
                 "--spawn. Without it betacheck talks to whatever is already "
                 "listening on --port.")
    w = Wire(a.port)
    mut = a.mutate

    tag = "%04d" % random.randrange(10000)
    std_session = ""
    std_profile = None

    # ---------------------------------------------------------------- 1 + 2
    # `a` is the argparse namespace for the whole of main(). Two loops below
    # used to rebind it -- one comprehension variable, one assort body -- so
    # every later `a.spt` / `a.port` died with AttributeError, and the
    # workaround was this local. They are `ar` and `assort` now; `spt_root`
    # stays because it reads better than `a.spt` at seven call sites.
    spt_root = a.spt
    loose_dir = a.loose_dir or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "build", "db", "looseloot")
    std_char, std_trader = spt_template(spt_root, "Standard", "usec")
    eod_char, _ = spt_template(a.spt, "Edge Of Darkness", "usec")
    want_std = len(std_char["Inventory"]["items"])
    want_eod = len(eod_char["Inventory"]["items"])

    st, doc, text = make_profile(w, "Beta" + tag, "standard")
    if doc is None:
        record("inventory", INCONC, "create did not answer JSON: %r" % text[:120])
        record("edition", INCONC, "no profile to read")
        record("tradersinfo", INCONC, "no profile to read")
    else:
        session = session_of(doc)
        if not session:
            record("inventory", INCONC,
                   "create gave no profile id: %s" % json.dumps(doc)[:160])
            session = ""
        std_session = session
        p, why = read_back(w, session) if session else (None, "no session")
        std_profile = p
        if p is None:
            record("inventory", INCONC, why)
            record("edition", INCONC, why)
            record("tradersinfo", INCONC, why)
        else:
            got = len(p.get("Inventory", {}).get("items", []))
            expect = want_eod if mut == "inventory" else want_std
            gv = p.get("Info", {}).get("GameVersion")
            # A negative, so it can be falsified: no slot SPT's template
            # equips may be missing from what was served.
            want_slots = set(i.get("slotId") for i in
                             std_char["Inventory"]["items"]
                             if i.get("parentId") ==
                             std_char["Inventory"]["equipment"])
            got_slots = set(i.get("slotId") for i in
                            p.get("Inventory", {}).get("items", [])
                            if i.get("parentId") ==
                            p.get("Inventory", {}).get("equipment"))
            missing = sorted(x for x in want_slots - got_slots if x)
            ids = [i.get("_id") for i in p.get("Inventory", {}).get("items", [])]
            dupes = len(ids) - len(set(ids))
            if got != expect:
                record("inventory", FAIL,
                       "served %d items, SPT's template has %d" % (got, expect))
            elif missing:
                record("inventory", FAIL,
                       "equipped slots missing: %s" % ",".join(missing))
            elif dupes:
                record("inventory", FAIL,
                       "%d duplicate _id(s) in the served inventory" % dupes)
            else:
                record("inventory", OK,
                       "%d items, all %d slots equipped, ids unique, "
                       "GameVersion=%s" % (got, len(want_slots), gv))

            ti = p.get("TradersInfo")
            if mut == "tradersinfo":
                ti = {}   # what the backend used to write, so the check fails
            if not isinstance(ti, dict) or not ti:
                record("tradersinfo", FAIL,
                       "TradersInfo is %s" % json.dumps(ti)[:60])
            else:
                want_loy = std_trader["initialLoyaltyLevel"]
                bad = [t for t, v in want_loy.items()
                       if t in ti and ti[t].get("loyaltyLevel") != v]
                jaeger = ti.get(JAEGER, {})
                if bad:
                    record("tradersinfo", FAIL,
                           "loyaltyLevel disagrees with the template for %s"
                           % ",".join(bad[:3]))
                elif jaeger and jaeger.get("unlocked") is not False:
                    record("tradersinfo", FAIL,
                           "Jaeger is unlocked on a fresh profile "
                           "(template says jaegerUnlocked:false)")
                else:
                    record("tradersinfo", OK,
                           "%d traders seeded, Jaeger unlocked=%s"
                           % (len(ti), jaeger.get("unlocked")))

    # ----------------------------------------------------------------- 2
    st, doc, text = make_profile(w, "Eod" + tag, "edge_of_darkness")
    if doc is None:
        record("edition", INCONC, "EoD create did not answer JSON")
    else:
        session = session_of(doc)
        p, why = read_back(w, session) if session else (None, "no session")
        if p is None:
            record("edition", INCONC, why)
        else:
            got = len(p.get("Inventory", {}).get("items", []))
            expect = want_std if mut == "edition" else want_eod
            gv = p.get("Info", {}).get("GameVersion")
            stash = [b for b in p.get("Bonuses", [])
                     if b.get("type") == "StashSize"]
            want_stash = [b for b in eod_char["Bonuses"]
                          if b.get("type") == "StashSize"]
            if gv != "edge_of_darkness":
                record("edition", FAIL, "GameVersion reads %r" % gv)
            elif got != expect:
                record("edition", FAIL,
                       "served %d items, EoD's template has %d" % (got, expect))
            elif len(stash) != len(want_stash):
                record("edition", FAIL,
                       "%d StashSize bonus(es), EoD's template has %d"
                       % (len(stash), len(want_stash)))
            else:
                record("edition", OK,
                       "GameVersion=%s, %d items, %d StashSize bonuses "
                       "(standard has %d items)"
                       % (gv, got, len(stash), want_std))

    # An edition the server cannot build must be REFUSED, not downgraded.
    st, doc, text = make_profile(w, "Bogus" + tag, "no_such_edition")
    if doc is None:
        record("edition-refusal", INCONC, "no JSON answer")
    else:
        d = envelope(doc)
        refused = (doc.get("err") not in (0, None)) or \
                  (isinstance(d, dict) and d.get("ok") is False) or \
                  (isinstance(d, dict) and "problem" in d)
        if refused:
            record("edition-refusal", OK, "refused: %s" % json.dumps(d)[:100])
        else:
            record("edition-refusal", FAIL,
                   "accepted an unknown edition: %s" % json.dumps(d)[:120])

    # ----------------------------------------------------------------- 3
    st, doc, text = w.call("/client/trading/api/getTraderAssort/" + PRAPOR,
                           {}, "")
    if doc is None:
        record("loyalty-gate", INCONC,
               "the assort did not parse as JSON (%d bytes)" % len(text))
    else:
        lli = envelope(doc).get("loyal_level_items")
        if not isinstance(lli, dict) or not lli:
            record("loyalty-gate", INCONC,
                   "Prapor's assort has no loyal_level_items")
        else:
            vals = list(lli.values())
            above1 = sum(1 for v in vals if v != 1)
            if mut == "traders":
                # The mutation must make the check FAIL, not pass: pretend the
                # distribution is the all-1s one the sandbox default produced.
                above1 = 0
            if above1 == 0:
                record("loyalty-gate", FAIL,
                       "all %d loyal_level_items entries are 1 -- every "
                       "offer is buyable at level 1" % len(vals))
            else:
                hist = {}
                for v in vals:
                    hist[v] = hist.get(v, 0) + 1
                record("loyalty-gate", OK,
                       "%d entries, distribution %s" %
                       (len(vals), json.dumps(hist, sort_keys=True)))

    # ----------------------------------------------------------------- 4
    # BLOCKER 1 -- a fresh profile with no startable quest.
    #
    # Two independent negatives, because the cheap one cannot fail for the
    # right reason on its own:
    #
    #   (a) no quest is served WITHOUT a `status` key.  A missing key and
    #       `status: 0` are different documents to a deserialiser, and the
    #       stored SPT templates omit the key on 50 of 558.
    #   (b) NO QUEST THE SERVER WOULD ACCEPT IS SERVED AS LOCKED.  This is the
    #       one that matters and the one that can fail: it asks the server to
    #       accept quests it has just described as unstartable, and every
    #       acceptance is a contradiction in what it served.
    #
    # (b) mutates the profile it runs against, so it gets its OWN profile.
    st, doc, text = make_profile(w, "Quest" + tag, "standard")
    qsession = session_of(doc) if doc else ""
    if qsession:
        st, doc, text = w.call("/client/quest/list", {}, qsession)
    else:
        doc, text = None, ""
    quests = envelope(doc) if doc else None
    if not isinstance(quests, list) or not quests:
        record("quest-entry", INCONC,
               "/client/quest/list did not answer a non-empty array "
               "(%d bytes)" % len(text))
    else:
        nokey = [q.get("_id") for q in quests if "status" not in q]
        avail = [q for q in quests if q.get("status") == 1]
        locked = [q.get("_id") for q in quests if q.get("status") == 0]
        if mut == "queststatus":
            # Half of the PRE-FIX payload: the 50 stored templates that carry
            # no `status` key at all.  Proves negative (a) can fail.
            nokey = [q.get("_id") for q in avail][:50]
        if mut == "quests":
            # Reproduce the PRE-FIX payload: SPT's stored templates, where
            # `status` is a static field -- 0 on most and absent on the rest,
            # neither having anything to do with the player.  Both negatives
            # must then fire: (a) on the stripped keys, and (b) because the
            # 14 the server really will accept are described as Locked.
            avail_ids = [q.get("_id") for q in avail]
            locked = avail_ids + locked
        accepted = []
        for qid in locked[:40]:
            _, d2, _ = w.call("/client/game/profile/items/moving",
                              {"data": [{"Action": "QuestAccept", "qid": qid}],
                               "tm": 0, "reload": 0}, qsession)
            d2 = envelope(d2) if d2 else None
            if not isinstance(d2, dict):
                continue
            warns = d2.get("warnings")
            if not warns and d2.get("profileChanges"):
                accepted.append(qid)
        if nokey:
            record("quest-entry", FAIL,
                   "%d quest(s) served with NO status key, e.g. %s"
                   % (len(nokey), nokey[0]))
        elif accepted:
            record("quest-entry", FAIL,
                   "%d quest(s) served as Locked that the server ACCEPTED, "
                   "e.g. %s" % (len(accepted), accepted[0]))
        elif not avail:
            record("quest-entry", FAIL,
                   "%d quests served and not one is AvailableForStart"
                   % len(quests))
        else:
            record("quest-entry", OK,
                   "%d quests, %d AvailableForStart, every one carries a "
                   "status key, %d probed Locked quests all refused"
                   % (len(quests), len(avail), len(locked[:40])))

    # ----------------------------------------------------------------- 4b
    # Dead skill ids on every fresh profile.
    #
    # The negative: no skill id on the profile the server just created may be
    # one the client is on record as REJECTING.  Asserting the opposite (that
    # our ids are ESkillId members) cannot fail -- all 17 rejected ids are in
    # the enum.  Read back from the profile list, never from the create reply.
    if std_profile is None:
        record("skill-ids", INCONC, "no fresh profile to read skills from")
    else:
        common = std_profile.get("Skills", {}).get("Common")
        if not isinstance(common, list) or not common:
            record("skill-ids", INCONC,
                   "the fresh profile carries no Skills.Common array")
        else:
            rejected = set(CLIENT_REJECTED_SKILL_IDS)
            if mut == "skillids":
                rejected = set()      # accept anything, as the old list did
            served_ids = [x.get("Id") for x in common if isinstance(x, dict)]
            bad = sorted(set(served_ids) & rejected)
            missing_id = [x for x in common
                          if not isinstance(x, dict) or not x.get("Id")]
            if mut == "skillids":
                # prove the check can go red: demand an id the client rejects.
                if "Sniping" not in served_ids:
                    record("skill-ids", FAIL,
                           "mutant: `Sniping` (a pre-1.0 id the client logs "
                           "`Can't find skill to upgrade` for) is NOT served, "
                           "which is what a CORRECT server does")
                else:
                    record("skill-ids", OK, "mutant: dead ids still served")
            elif missing_id:
                record("skill-ids", FAIL,
                       "%d Skills.Common entr(ies) have no Id" % len(missing_id))
            elif bad:
                record("skill-ids", FAIL,
                       "%d skill id(s) served that SkillManager..ctor rejects: "
                       "%s" % (len(bad), ", ".join(bad)))
            else:
                record("skill-ids", OK,
                       "%d skill ids on the fresh profile, none of the %d the "
                       "client is measured to reject"
                       % (len(served_ids), len(rejected)))

    # ----------------------------------------------------------------- 5
    # BLOCKER 2 -- hideout area type 21 absent from every new profile.
    #
    # The negative is general, not a test for 21: no area the server SERVES as
    # enabled may be missing from the profile it just created.  A check that
    # looked for `21` specifically could not detect area 28 being added.
    st, doc, text = w.call("/client/hideout/areas", {}, std_session)
    served = envelope(doc) if doc else None
    if not isinstance(served, list) or not served:
        record("hideout-areas", INCONC,
               "/client/hideout/areas did not answer a non-empty array")
    elif std_profile is None:
        record("hideout-areas", INCONC, "no fresh profile to compare against")
    else:
        want = set(ar["type"] for ar in served
                   if ar.get("enabled") and "type" in ar)
        got = set(ar["type"] for ar in
                  std_profile.get("Hideout", {}).get("Areas", [])
                  if "type" in ar)
        if mut == "hideout":
            got.discard(21)   # what the old 27-entry constant produced
        absent = sorted(want - got)
        if absent:
            record("hideout-areas", FAIL,
                   "%d enabled area type(s) served but absent from the fresh "
                   "profile: %s" % (len(absent), absent))
        else:
            record("hideout-areas", OK,
                   "%d enabled area types served, all present among the %d on "
                   "the fresh profile" % (len(want), len(got)))

    # ----------------------------------------------------------------- 6
    # BLOCKER 3 -- traders serving a permanently empty shop.
    #
    # The negative: no trader the client can already reach may serve a
    # zero-item assort unless this file names a REASON.  The allowlist is the
    # point of the check, not a hole in it -- adding to it is a deliberate,
    # reviewable statement that an empty shelf is correct for that trader.
    EMPTY_OK = {
        "638f541a29ffd1183d187f57":
            "Ref trades for GP coins, an Arena currency this server has no "
            "source of; a rouble-priced Ref would be a fabrication",
    }
    st, doc, text = w.call("/client/trading/api/traderSettings", {},
                           std_session)
    bases = envelope(doc) if doc else None
    if not isinstance(bases, list) or not bases:
        record("trader-assort", INCONC, "traderSettings answered no traders")
    else:
        probe = [b for b in bases if b.get("unlockedByDefault")]
        probe += [b for b in bases if b.get("_id") == FENCE
                  and not b.get("unlockedByDefault")]
        silent = []
        checked = 0
        fence_items = -1
        fence_unpriced = 0
        for b in probe:
            tid = b.get("_id")
            _, d3, _ = w.call("/client/trading/api/getTraderAssort/" + tid,
                              {}, std_session)
            assort = envelope(d3) if d3 else None
            if not isinstance(assort, dict):
                continue
            checked += 1
            its = assort.get("items") or []
            if tid == FENCE:
                fence_items = len(its)
                scheme = assort.get("barter_scheme") or {}
                lvl = assort.get("loyal_level_items") or {}
                if mut == "fence":
                    fence_items = 0
                # No Fence offer may lack a price or a loyalty entry -- a
                # generated item the client cannot buy is worse than none.
                fence_unpriced = sum(
                    1 for i in its
                    if not scheme.get(i.get("_id"))
                    or i.get("_id") not in lvl)
            if not its and tid not in EMPTY_OK:
                silent.append(b.get("nickname") or tid)
        if fence_items < 0:
            record("trader-assort", INCONC,
                   "Fence's assort never answered")
        elif fence_items == 0:
            record("trader-assort", FAIL,
                   "Fence serves a zero-item assort -- SPT does not ship his "
                   "stock, it must be generated")
        elif fence_unpriced:
            record("trader-assort", FAIL,
                   "%d of Fence's %d offers have no barter_scheme or no "
                   "loyal_level_items entry" % (fence_unpriced, fence_items))
        elif silent:
            record("trader-assort", FAIL,
                   "%d reachable trader(s) serve an empty assort with no "
                   "stated reason: %s" % (len(silent), ", ".join(silent[:4])))
        else:
            record("trader-assort", OK,
                   "%d reachable trader(s) checked, Fence generates %d fully "
                   "priced offers, %d empty-by-design and named"
                   % (checked, fence_items, len(EMPTY_OK)))
    # ----------------------------------------------------------------- 7
    # ProfileDescriptor members, asserted as a NEGATIVE on the finished
    # document that was READ BACK -- never on the create response.
    st, doc, text = make_profile(w, "Desc" + tag, "standard")
    session = session_of(doc) if doc else ""
    p, why = read_back(w, session) if session else (None, "no session")
    if p is None:
        record("descriptor", INCONC, why or "no profile to read")
    else:
        want = list(DESCRIPTOR_MEMBERS)
        if mut == "descriptor":
            want.append(MUTANT_MEMBER)
        absent = [m for m in want if m not in p]
        null = [m for m in want if m in p and p[m] is None]
        if absent:
            record("descriptor", FAIL,
                   "ProfileDescriptor member(s) absent from the served "
                   "profile: %s" % ", ".join(absent))
        elif null:
            # null and absent are the same thing to Newtonsoft for a reference
            # type, so a null must not read as present.
            record("descriptor", FAIL,
                   "ProfileDescriptor member(s) served as null: %s"
                   % ", ".join(null))
        else:
            record("descriptor", OK,
                   "%s all present and non-null (%s)"
                   % (", ".join(want),
                      ", ".join("%s=%s" % (m, json.dumps(p[m])[:20])
                                for m in want)))

    # ----------------------------------------------------------------- 8
    # locationLoot Position shape, asserted as a NEGATIVE against BSG's OWN
    # captured `/client/match/local/start` body (raid1/responses/158.json).
    #
    # MEASURED there, not assumed: all 41 `IsContainer` entries carry Position
    # (0,0,0) and all 94 non-container entries carry a NON-zero Position.  So
    # a zero on a container is CORRECT -- the client resolves a container by
    # its `Id` against the loaded scene, and 96-100% of every map's container
    # Ids exist verbatim in the client's own levelN files.  A zero on a LOOSE
    # entry is the real defect, and serving zero loose entries at all is the
    # hole this check names.
    #
    # The falsifying input: `--mutate lootpos` demands a NON-zero Position on
    # containers, which BSG itself does not send, so the mutated run must go
    # red on a correct server.
    def _start(loc):
        st, doc, text = w.call("/client/match/local/start",
                               {"serverId": None, "location": loc,
                                "timeVariant": "CURR", "mode": "TUTORIAL",
                                "playerSide": "Pmc", "transitionType": 0,
                                "transition": None},
                               session=std_session)
        body = envelope(doc) if doc else None
        if not isinstance(body, dict):
            return None, text
        ll = body.get("locationLoot")
        if not isinstance(ll, dict):
            return None, text
        _start.last_loc = ll          # kept so a FAIL can REPORT, not diagnose
        return ll.get("Loot"), text
    _start.last_loc = None

    # 8a -- parity with BSG on the ONE request body we actually captured.
    if not std_session:
        record("lootparity", INCONC, "no session to start a raid with")
    else:
        loot, text = _start(LOOT_MAP)
        if loot is None:
            record("lootparity", INCONC,
                   "match/local/start gave no locationLoot.Loot: %s"
                   % text[:140])
        elif not loot:
            # Report the MEASUREMENT, never a diagnosis. This text used to
            # assert "the raid id is not being mapped to a db location",
            # which was FALSE in a `maxLootItems: 0` run -- the id mapped
            # fine and the generator produced nothing. A confidently wrong
            # cause costs more than no cause at all, so state what came back
            # on the wire (including the fields that DISCRIMINATE between
            # those two causes) and stop there.
            ll = _start.last_loc or {}
            ident = ", ".join(
                "%s=%r" % (k, ll.get(k))
                for k in ("_Id", "Id", "Name", "Locale")
                if k in ll)
            record("lootparity", FAIL,
                   "location %r served locationLoot.Loot == [] (0 entries); "
                   "BSG's captured answer to this exact request body "
                   "(158.json) has 135. locationLoot keys present: %s. "
                   "Identity fields echoed back: %s. NOT DIAGNOSED: an empty "
                   "Loot is consistent with the id not resolving to a db "
                   "location AND with a location that resolved but generated "
                   "nothing (e.g. maxLootItems: 0) -- this check does not "
                   "distinguish them; compare the identity fields above "
                   "against the db entry to tell which."
                   % (LOOT_MAP, sorted(ll.keys())[:12], ident or "(none)"))
        else:
            record("lootparity", OK,
                   "%r served %d loot entries (BSG's capture has 135)"
                   % (LOOT_MAP, len(loot)))

    # 8a2 -- THE GENERAL NEGATIVE, over every id the client can send.
    #
    # "No location id the client can send serves an empty `Loot` when its
    # database location has entries."  Stated as a negative on purpose: the
    # positive form ("Sandbox_start serves loot") is one string and was
    # special-cased away twice.
    #
    # This is the check that would have caught the real size of the hole.
    # MEASURED on this backend with the fix reverted: TEN of the thirteen
    # loot-bearing maps served ZERO -- Interchange, Labyrinth, Lighthouse,
    # RezervBase, Sandbox, Sandbox_high, Shoreline, TarkovStreets, Woods and
    # Sandbox_start -- because the id resolver matched only the database key
    # and `base._Id`, never the `base.Id` the client actually sends.  Only
    # bigmap, factory4_day, factory4_night and laboratory happened to spell
    # the key and the `Id` identically, which is why "loot works" was
    # believed: Customs, Factory and Labs are the maps people test on.
    if not std_session:
        record("lootmap", INCONC, "no session to start a raid with")
    else:
        want = list(CLIENT_LOCATION_IDS)
        if mut == "lootmap":
            want.append("Icebreaker")
        empty, unread = [], []
        for loc in want:
            loot, text = _start(loc)
            if loot is None:
                unread.append(loc)
            elif not loot:
                empty.append(loc)
        if unread:
            record("lootmap", INCONC,
                   "%d id(s) gave no locationLoot.Loot at all, so nothing was "
                   "proved about them: %s" % (len(unread), ", ".join(unread)))
        elif empty:
            record("lootmap", FAIL,
                   "%d of %d client-sendable location id(s) served an EMPTY "
                   "locationLoot.Loot: %s"
                   % (len(empty), len(want), ", ".join(empty)))
        else:
            record("lootmap", OK,
                   "all %d client-sendable location id(s) served a non-empty "
                   "Loot" % len(want))

    # 8a3 -- the other half of the same negative, so the fix above cannot be a
    # resolver that maps EVERYTHING to some map.  An id the database genuinely
    # has nothing for must still answer empty rather than silently inherit
    # another map's loot, which would put crates in mid-air.
    if not std_session:
        record("lootunmapped", INCONC, "no session to start a raid with")
    else:
        wrong = []
        for loc in UNMAPPABLE_IDS:
            loot, _ = _start(loc)
            if loot:
                wrong.append("%s(%d)" % (loc, len(loot)))
        if wrong:
            record("lootunmapped", FAIL,
                   "id(s) with no database location of their own were served "
                   "loot anyway -- the resolver is guessing: %s"
                   % ", ".join(wrong))
        else:
            record("lootunmapped", OK,
                   "all %d id(s) the database has nothing for served an empty "
                   "Loot rather than another map's" % len(UNMAPPABLE_IDS))

    # 8a4 -- THE SAME NEGATIVE, FOR ORBIT.
    #
    # "No location id the client can send yields an ORBIT plan with ok=false
    # for want of positional data that `locations.json` actually has."
    #
    # Same defect, same shape, different consumer.  `emu/orbit.buildPlan` read
    # `locations.<clientId>.base.SpawnPointParams` with the id the CLIENT
    # sent, while the table is keyed by the database key, so on a live raid it
    # reported "0 usable containers and 0 player spawn points ... a map with
    # no positional data here" for Interchange -- against a database with
    # 3,762 SpawnPointParams across 24 locations, 100% of them at a non-zero
    # Position.
    #
    # Not merely "the plan is non-empty": ORBIT's own check once returned PASS
    # with 6 anchors and a 587 m spread while an entire loot layer was
    # missing, because it did not count anchors BY KIND.  So this asserts the
    # spawn-point layer was READ -- `spawnRows > 0` and `spawnPointsSeen > 0`
    # -- which is the thing the resolver defect destroys, and reports the
    # per-map counts so a regression names the maps rather than a total.
    #
    # `plan` is fetched AFTER the getLocalloot for that id, because that is
    # the route that calls `emitPlan`, and `/aowlspt/tarkov/orbit/plan` serves
    # the LAST plan built.
    def _plan(loc):
        st, doc, text = w.call("/client/location/getLocalloot",
                               {"locationId": loc}, std_session)
        st, doc, text = w.call("/aowlspt/tarkov/orbit/plan", {}, std_session)
        d = envelope(doc)
        # The route answers `{"plan": {...}}` -- measured, not assumed: reading
        # the outer object as the plan gave `ok` absent for every id, which
        # this reports as INCONCLUSIVE rather than as a pass or a failure.
        if isinstance(d, dict) and isinstance(d.get("plan"), dict):
            d = d["plan"]
        if not isinstance(d, dict) or "ok" not in d:
            return None, text
        return d, text

    if not std_session:
        record("orbitmap", INCONC, "no session to configure a raid with")
    else:
        want = list(CLIENT_LOCATION_IDS)
        if mut == "orbitmap":
            want.append("Icebreaker")
        bad, unread, seen = [], [], []
        for loc in want:
            pl, text = _plan(loc)
            if pl is None:
                unread.append(loc)
                continue
            rows = int(pl.get("spawnRows") or 0)
            used = int(pl.get("spawnPointsSeen") or 0)
            anchors = pl.get("anchors") or []
            kinds = {}
            for an in anchors:
                kinds[an.get("kind")] = kinds.get(an.get("kind"), 0) + 1
            seen.append("%s:%d/%d rows, %d anchors %s"
                        % (loc, used, rows, len(anchors),
                           ",".join("%s=%d" % kv for kv in sorted(kinds.items()))
                           or "-"))
            if not pl.get("ok") or rows == 0 or used == 0 or not anchors:
                bad.append("%s(ok=%s rows=%d used=%d anchors=%d)"
                           % (loc, pl.get("ok"), rows, used, len(anchors)))
        for line in seen:
            print("               orbit %s" % line)
        if unread:
            record("orbitmap", INCONC,
                   "%d id(s) returned no readable plan, so nothing was proved "
                   "about them: %s" % (len(unread), ", ".join(unread)))
        elif bad:
            record("orbitmap", FAIL,
                   "%d of %d client-sendable location id(s) built NO usable "
                   "ORBIT anchor from SpawnPointParams the database has: %s"
                   % (len(bad), len(want), ", ".join(bad)))
        else:
            record("orbitmap", OK,
                   "all %d client-sendable location id(s) read a non-zero "
                   "SpawnPointParams layer and anchored it" % len(want))

    # 8b -- the Position shape, on a map our generator does answer for.
    loot, text = (None, "") if not std_session else _start(LOOT_SHAPE_MAP)
    if not std_session:
        record("lootpos", INCONC, "no session to start a raid with")
    elif not loot:
        record("lootpos", INCONC,
               "%r served no loot to check the Position shape on: %s"
               % (LOOT_SHAPE_MAP, text[:120]))
    else:
        def _nz(e):
            p = e.get("Position") or {}
            return any(abs(p.get(k, 0) or 0) > 1e-6 for k in "xyz")
        conts = [e for e in loot if e.get("IsContainer")]
        loose = [e for e in loot if not e.get("IsContainer")]
        want_container_nonzero = (mut == "lootpos")
        bad_cont = [e["Id"] for e in conts
                    if _nz(e) != want_container_nonzero][:4]
        bad_loose = [e.get("Id") for e in loose if not _nz(e)][:4]
        if not conts:
            record("lootpos", INCONC,
                   "%d loot entries but none is a container" % len(loot))
        elif bad_cont:
            record("lootpos", FAIL,
                   "container Position must be %s (BSG's own 158.json sends "
                   "zeros); wrong on e.g. %s"
                   % ("non-zero" if want_container_nonzero else "(0,0,0)",
                      ", ".join(map(str, bad_cont))))
        elif bad_loose:
            record("lootpos", FAIL,
                   "%d loose entr(ies) served at Position (0,0,0); BSG sends a "
                   "real coordinate for every one: e.g. %s"
                   % (len(bad_loose), ", ".join(map(str, bad_loose))))
        elif not loose:
            record("lootpos", FAIL,
                   "%s served %d containers and ZERO loose loot entries; BSG's "
                   "capture for Sandbox_start sends 94 of 135. db.json has no "
                   "`looseLoot` key, so emu/loot.nim's loose path is dead."
                   % (LOOT_SHAPE_MAP, len(conts)))
        else:
            record("lootpos", OK,
                   "%d container(s) at (0,0,0) as BSG sends them, %d loose "
                   "entr(ies) all with a non-zero Position"
                   % (len(conts), len(loose)))

    # ----------------------------------------------------------------- 8c
    # THE PROBABILISTIC LOOSE-LOOT NEGATIVE.
    #
    # "No map whose database carries N probabilistic `spawnpoints` serves a
    # loose-entry count that is only its `spawnpointsForced` list."
    #
    # Stated that way because the failure it names is invisible to every check
    # above: `looseLoot` was imported, the loose path ran, and the payload came
    # back with a non-empty `Loot` -- so `lootmap`, `lootparity` and `lootpos`
    # all went green while 1232 of sandbox's 1232 probabilistic spawn points
    # emitted NOTHING and only the 15 forced ones survived.  The count is the
    # only thing that distinguishes the two, which is why this asserts on it.
    #
    # Three outcomes, not two.  A server whose database has no `looseLoot` for
    # a map serves zero loose entries, which is CORRECT for that database and
    # proves nothing about this bug -- so it is INCONCLUSIVE, never a pass.
    #
    # The falsifying input: `--mutate lootloose` demands more loose entries
    # than the map has spawn points at all, which no correct server can serve.
    if not std_session:
        record("lootloose", INCONC, "no session to start a raid with")
    else:
        locdir = os.path.join(spt_root, "SPT_Runtime", "SPT_Data", "database",
                              "locations")
        if not os.path.isdir(locdir):
            locdir = os.path.join(spt_root, "SPT_Data", "database", "locations")
        by_dir = dict((i.lower(), i) for i in CLIENT_LOCATION_IDS)
        rows, silent, absent, unread = [], [], [], []
        for d in (sorted(os.listdir(locdir)) if os.path.isdir(locdir) else []):
            loc = by_dir.get(d.lower())
            src = os.path.join(locdir, d, "looseLoot.json")
            if loc is None or not os.path.isfile(src):
                continue
            loot, _ = _start(loc)
            if loot is None:
                unread.append(loc)
                continue
            loose = len([e for e in loot if not e.get("IsContainer")])
            # THE SERVER's copy of the table, not SPT's.  A map the operator
            # did not import serves zero loose entries CORRECTLY, and calling
            # that a pass is the failure this file exists to avoid -- so it is
            # INCONCLUSIVE and named.  Presence is tested as the per-map
            # sidecar `--loose-dir` ships; a table EMBEDDED in db.json with
            # `--loose all` is not detected here, which is stated rather than
            # hidden: such a map that served zero would be reported
            # INCONCLUSIVE when it is really a FAIL.
            have = os.path.isfile(os.path.join(loose_dir, d + ".json"))
            if loose == 0 and not have:
                absent.append(loc)
                continue
            # Only now is the (large) source file worth parsing.
            with open(src, encoding="utf-8") as fh:
                tbl = json.load(fh)
            forced = len(tbl.get("spawnpointsForced") or [])
            points = tbl.get("spawnpoints") or []
            npts = len(points)
            psum = sum(float(sp.get("probability") or 0.0) for sp in points)
            mul = 1.0
            bp = os.path.join(locdir, d, "base.json")
            if os.path.isfile(bp):
                with open(bp, encoding="utf-8") as fh:
                    mul = float(json.load(fh).get(
                        "GlobalLootChanceModifier", 1.0) or 1.0)
            # Each point is rolled INDEPENDENTLY against its own probability,
            # so the served count is forced + a sum of len(points) Bernoullis.
            # Its standard deviation is sqrt(Sigma p(1-p)) after the modifier,
            # and that -- not a flat percentage -- is what "far from the
            # prediction" has to mean: 20% is 6 sigma on TarkovStreets and
            # under 1 sigma on Labyrinth, so a flat band both misses real bugs
            # on big maps and cries wolf on small ones.
            qs = [min(1.0, max(0.0, float(sp.get("probability") or 0.0) * mul))
                  for sp in points]
            expect = forced + sum(qs)
            sigma = sum(q * (1.0 - q) for q in qs) ** 0.5
            del tbl, points, qs
            rows.append((loc, loose, forced, expect, sigma, psum))
            floor = forced + npts if mut == "lootloose" else forced
            if loose <= floor:
                silent.append("%s: %d loose served, needed more than %d "
                              "(%d forced, %.1f probabilistic expected of "
                              "%d point(s))"
                              % (loc, loose, floor, forced,
                                 expect - forced, npts))
        print()
        print("  %-16s %8s %8s %9s %7s %7s" %
              ("map", "served", "forced", "expect", "sigma", "z"))
        for loc, n, f, expect, sigma, psum in rows:
            print("  %-16s %8d %8d %9.1f %7.1f %7s"
                  % (loc, n, f, expect, sigma,
                     "-" if sigma <= 0 else "%+.1f" % ((n - expect) / sigma)))
        for loc in absent:
            print("  %-16s %8s   (no table on the server)" % (loc, "-"))
        # 4 sigma.  One-sided tail probability under 1 in 30,000 per map, so
        # 13 maps false-alarm about once in 2,300 runs -- and a systematic
        # defect (a whole class of point never firing) is tens of sigma, not
        # four.  MEASURED: with the composedKey bug reverted every map sat at
        # its forced count, which is -13 to -40 sigma.
        skewed = ["%s: %d served, expected %.0f +- %.1f (%+.1f sigma)"
                  % (loc, n, expect, sigma, (n - expect) / sigma)
                  for loc, n, f, expect, sigma, psum in rows
                  if sigma > 0 and abs(n - expect) > 4.0 * sigma]
        if unread:
            record("lootloose", INCONC,
                   "%d id(s) gave no locationLoot.Loot at all: %s"
                   % (len(unread), ", ".join(unread)))
        elif not rows:
            record("lootloose", INCONC,
                   "no imported map served any loose loot; no looseLoot table "
                   "is on the server for %s (aowl importdb --loose sidecar)"
                   % (", ".join(absent) or "any map"))
        elif silent:
            record("lootloose", FAIL,
                   "%d map(s) served ONLY their forced loose spawns: %s"
                   % (len(silent), "; ".join(silent)))
        elif skewed:
            record("lootloose", FAIL,
                   "%d map(s) served a loose count more than 4 sigma from "
                   "forced + Sigma(probability x GlobalLootChanceModifier): %s"
                   % (len(skewed), "; ".join(skewed)))
        elif absent:
            record("lootloose", INCONC,
                   "%d of %d map(s) verified (%s); no table on the server for "
                   "%s, so nothing was proved about them"
                   % (len(rows), len(rows) + len(absent),
                      ", ".join(r[0] for r in rows), ", ".join(absent)))
        else:
            record("lootloose", OK,
                   "all %d imported map(s) served a loose count within 4 "
                   "sigma of forced + Sigma(probability x "
                   "GlobalLootChanceModifier)"
                   % len(rows))

    # ------------------------------------------------------------------ 12
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        check_tolerated(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("tolerated", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 13
    try:
        check_progression(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("progression", INCONC, "%s: %r" % (type(exc).__name__, exc))
    try:
        check_trader_unlock(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("trader-loyalty", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 15
    try:
        check_mail_types(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("mail-types", INCONC, "%s: %r" % (type(exc).__name__, exc))

    try:
        check_mail_sender_id(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("mail-sender-id", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 16
    try:
        check_dict_shapes(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("dict-shapes", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 17
    try:
        check_weather_shape(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("weather-shape", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 18
    # `check_route_shapes` used to sit INSIDE the handler above -- legal
    # Python (two statements in one except body, then a second except
    # clause), so nothing complained, and it therefore ran ONLY when
    # check_weather_shape raised. A check that never executes reports
    # nothing and reads exactly like a passing one.
    try:
        check_route_shapes(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("route-shapes", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 18b
    # Offline on purpose: a property of dtogap.ROUTES vs oursample.CALLS, so
    # it still runs (and can still go red) when no backend is reachable.
    try:
        check_dto_map(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("dto-map", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 19
    try:
        check_nested_types(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("nested-types", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 14
    try:
        check_settings_write(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("settings-write", INCONC, "%s: %r" % (type(exc).__name__, exc))

    # ------------------------------------------------------------------ 15
    try:
        check_settings_write_client(w, mut)
    except Exception as exc:                       # noqa: BLE001
        record("settings-write-client", INCONC,
               "%s: %r" % (type(exc).__name__, exc))

    print()
    bad = [r for r in results if r[1] != OK]
    print("%d check(s), %d not PASS" % (len(results), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
