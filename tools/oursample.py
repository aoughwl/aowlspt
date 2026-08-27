#!/usr/bin/env python
"""oursample.py -- stand OUR backend up on a scratch port, sample every route
dtogap maps, and print the FIRST honest hole table for our own emulation.

## Why this exists

dtogap.py can enumerate what the client DECLARES, but its right-hand column --
"the keys this payload carries" -- only means something once you know WHICH
SERVER produced the payload. Every default sample it had was raid1 CAPTURE, and
that capture is REAL BSG TRAFFIC (manifest rows carry `resp_xenc: aes` and a
`PHPSESSID=sh8-...` cookie our backend never emits). So dtogap had never once
looked at our output, and reported ZERO measured emulation-hole rows.

This tool produces the missing half: OUR payloads, labelled OURS by
construction, because this process started the backend itself.

## What it does, in one command

    python tools/oursample.py                       stage, sample, diff, table
    python tools/oursample.py --sample-only         just write the samples
    python tools/oursample.py --keep                leave the backend root behind
    python tools/oursample.py --selfcheck           prove the sampler can FAIL

Staging follows tools/xferproof.py exactly: a scratch ROOT under %TEMP%, the
built `aowlspt-backend.exe` and `mods/tarkov/tarkov.dll` copied IN (so a
concurrent agent rebuilding cannot change the thing being measured mid-run), the
live `db.json` copied in, a one-mod registry and a matching
`aowlspt-selection.json` -- a mod on disk but absent from the selection is
silently not loaded, which looks exactly like a broken mod.

`Accept-Encoding: identity` on every request (fact #123: the backend ALWAYS
deflates otherwise, and the raw bytes are then a zlib stream, not JSON). The
deflate case is handled anyway, because a header the server ignored would
otherwise read as a broken route.

## THE SAMPLER'S OWN CHECK, and why it is a negative

A sampler that writes whatever came back and calls it a sample is the
"verification that cannot fail" shape: a 404 body, an error envelope or an empty
object would all flow into dtogap and print as "everything is missing", which is
a confident wrong answer, not a measurement. So each sample is classified
BEFORE it is handed to dtogap, and the classification is asserted as a negative
about the finished document:

  SERVED        status 200, parses STRICTLY as JSON, `err` is 0/absent, and the
                object at the route's json path is a non-empty object or a
                non-empty array. Only these are diffed.
  ERROR         parsed, but `err` is non-zero -- the route answered, badly.
  NOT-SERVED    404/500, or the body is not JSON at all.
  EMPTY         parsed and errorless, but the object at the path has zero keys.
                THIS IS NOT "nothing is missing" -- it is a route we answer with
                a placeholder, and it is reported as its own outcome.

ERROR / NOT-SERVED / EMPTY are INCONCLUSIVE for the gap question and are never
folded into the hole count.

## What a row in the table IS, and what it is NOT

A row is: the client declares a serializable member; our served payload has no
key for it (its [JsonProperty] wire name included). That is a CANDIDATE HOLE.

It is NOT a proven bug. Metadata gives a member's TYPE, not its use. REF members
(string/class/array/List/Dictionary) stay null when absent and ANY dereference
is a crash or a hang; VALUE members silently take the CLR default. Whether the
client actually dereferences a given member needs disassembly of the CONSUMER,
which nobody has done. The ranking below is "REF first", never "fatal first".

## CANDIDATE HOLE vs CLIENT-TOLERATED, and why the number must converge

A candidate row that has been shown to be absent from BSG'S OWN payload too is
not a hole in our emulation and must stop being counted as one -- otherwise the
total never converges and a real regression hides inside a permanent floor.
Such rows are not dropped: they are moved to a `toler` column and printed in
full under a CLIENT-TOLERATED heading, with the capture that proves it.

The split is DERIVED every run, by asking dtogap the same question a second
time against BSG's captured response for the route (`--provenance bsg`) and
subtracting its DECLARED-BUT-ABSENT-FROM-BSG set. Nothing is written down, so
nothing can go stale: if a game update makes BSG start sending a member, it
moves back into the candidate column by itself. "No BSG capture for this route"
is a third outcome, UNCLASSIFIED -- neither a hole nor tolerance.
"""

import argparse
import hashlib
import http.client
import json
import os
import shutil
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

PORT = int(os.environ.get("AOWL_SAMPLE_PORT", "6981"))
ROOT = os.path.join(os.environ.get("TEMP", "/tmp"), "oursample")
LIVE_DB = os.environ.get("AOWL_LIVE_DB", r"D:\Aowlspt\aowlspt\db.json")
BACKEND = os.environ.get("AOWL_BACKEND_EXE",
                         os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe"))
TARKOV = os.environ.get("AOWL_TARKOV_DLL",
                        os.path.join(REPO, "mods", "tarkov", "bin", "tarkov.dll"))
MODDATA = os.environ.get("AOWL_MOD_DATA",
                         os.path.join(REPO, "mods", "tarkov", "data"))

PRAPOR = "54cb50c76803fa8b248b4571"

TARKOV_ENTRY = {
    "id": "aowl.tarkov", "name": "Tarkov server emulator",
    "author": "aowlspt", "version": "1.0.0", "sides": ["server"],
    "provides": [],
}

_NL = chr(10)

SERVED, ERROR, NOT_SERVED, EMPTY = "SERVED", "ERROR", "NOT-SERVED", "EMPTY"

# route -> (http path to actually call, request body, json path to the object
#           dtogap should diff)
# The path is the dtogap ROUTES key; `url` differs only where the real route is
# a PREFIX (getTraderAssort/<id>) or the DTO lives deeper in the envelope
# (globals -> data.config).
CALLS = [
    ("/client/locations",                   None, {}, "data"),
    ("/client/globals",                     None, {}, "data.config"),
    ("/client/game/profile/list",           None, {}, "data"),
    ("/client/trading/api/getTraderAssort",
     "/client/trading/api/getTraderAssort/" + PRAPOR, {}, "data"),
    ("/client/settings",                    None, {}, "data"),
    ("/client/game/keepalive",              None, {}, "data"),
    ("/client/game/profile/select",         None, {"uid": "__SESSION__"}, "data"),
    ("/client/weather",                     None, {}, "data"),
    ("/client/trading/api/traderSettings",  None, {}, "data"),
    ("/client/quest/chains",                None, {}, "data"),
    ("/client/account/customization",       None, {}, "data"),
    ("/client/items",                       None, {}, "data"),
    ("/client/match/local/end",             None, "__RAIDEND__", "data"),
    # MAIL. Added because a live crash came out of a route this table did not
    # know existed: /client/mail/dialog/list served `systemData: false` where
    # the client declares a class, Newtonsoft threw inside ExecuteRequest and
    # the RAID LOAD died. 13 routes were measured and the client calls ~60 --
    # the most-called route in the client's own backend_000.log (43 hits) was
    # mail/dialog/list, and it was not one of the 13.
    ("/client/mail/dialog/list",             None, {}, "data"),
    ("/client/mail/dialog/view",             None, {"dialogId": "", "type": 2,
                                                    "limit": 100, "time": 0}, "data"),
    ("/client/mail/dialog/getAllAttachments", None, {"dialogId": ""}, "data"),

    # ---------------------------------------------------------------------
    # THE REST OF THE REAL SURFACE.
    #
    # The 16 entries above were a curated table. The AUTHORITY for what the
    # client actually calls is the client's own backend_000.log: aggregating
    # every log under D:\Aowlspt\Logs yields 70 distinct routes (trader-assort
    # and items/prices collapsed to one <id> form each). Everything below is
    # the other 54, so that "we never looked at it" stops being a category.
    #
    # An unlisted route is INCONCLUSIVE, never a pass -- that conflation is
    # exactly what let /client/mail/dialog/list ship `systemData: false`.
    # ---------------------------------------------------------------------
    ("/client/profile/status",              None, {}, "data"),
    ("/client/game/profile/items/moving",   None, {"data": []}, "data"),
    ("/client/seasonal-perks/list",         None, {}, "data"),
    ("/client/match/group/current",         None, {}, "data"),
    ("/client/customization",               None, {}, "data"),
    ("/client/variable/group",              None, {}, "data"),
    ("/client/tape/list",                   None, {}, "data"),
    ("/client/subtitle-track/list",         None, {}, "data"),
    ("/client/season/active",               None, {}, "data"),
    ("/client/quest/list",                  None, {}, "data"),
    ("/client/quest/getMainQuestsList",     None, {}, "data"),
    ("/client/quest/getMainQuestNotesList", None, {}, "data"),
    ("/client/prestige/list",               None, {}, "data"),
    ("/client/hideout/settings",            None, {}, "data"),
    ("/client/hideout/qte/list",            None, {}, "data"),
    ("/client/hideout/production/recipes",  None, {}, "data"),
    ("/client/hideout/customization/offer/list", None, {}, "data"),
    ("/client/hideout/areas",               None, {}, "data"),
    ("/client/handbook/templates",          None, {}, "data"),
    ("/client/game/bot/generate",           None,
     {"conditions": [{"Role": "assault", "Limit": 1, "Difficulty": "normal"}]},
     "data"),
    ("/client/friends",                     None, {}, "data"),
    ("/client/ending/list",                 None, {}, "data"),
    ("/client/dialogue",                    None, {}, "data"),
    ("/client/customization/storage",        None, {}, "data"),
    ("/client/builds/list",                 None, {}, "data"),
    ("/client/battle-pass/active",          None, {}, "data"),
    ("/client/achievement/statistic",       None, {}, "data"),
    ("/client/achievement/list",            None, {}, "data"),
    ("/client/tutor-game/check",            None, {}, "data"),
    ("/client/survey",                      None, {}, "data"),
    ("/client/server/list",                 None, {}, "data"),
    ("/client/repeatalbeQuests/activityPeriods", None, {}, "data"),
    ("/client/ragfair/find",                None,
     {"page": 0, "limit": 15, "sortType": 5, "sortDirection": 0,
      "currency": 0, "priceFrom": 0, "priceTo": 0, "quantityFrom": 0,
      "quantityTo": 0, "conditionFrom": 0, "conditionTo": 100,
      "oneHourExpiration": False, "removeBartering": True,
      "offerOwnerType": 0, "onlyFunctional": True, "updateOfferCount": True,
      "handbookId": "", "linkedSearchId": "", "neededSearchId": "",
      "buildItems": {}, "buildCount": 0, "tm": 1, "reload": 0}, "data"),
    ("/client/notifier/channel/create",     None, {}, "data"),
    ("/v2/client/game/profiles/",           None, {}, "data"),
    ("/client/putLoadMetrics",              None, {"data": {}}, "data"),
    ("/client/putHWMetrics",                None, {"data": {}}, "data"),
    ("/client/putMetrics",                  None, {"data": {}}, "data"),
    ("/client/menu/locale/en",              None, {}, "data"),
    ("/client/locale/en",                   None, {}, "data"),
    ("/client/languages",                   None, {}, "data"),
    ("/client/game/version/validate",       None,
     {"version": {"major": "1.1.0.1.46777", "game": "live", "backend": "6"}},
     "data"),
    ("/client/game/start",                  None, {}, "data"),
    ("/client/game/mode",                   None, {"sessionMode": "regular"}, "data"),
    ("/client/game/config",                 None, {}, "data"),
    ("/client/items/prices",
     "/client/items/prices/" + PRAPOR, {}, "data"),
    ("/client/checkVersion",                None, {}, "data"),
    ("/client/raid/configuration",          None,
     {"keyId": "", "side": "Pmc", "location": "factory4_day",
      "timeVariant": "CURR", "raidMode": "Local", "metabolismDisabled": False,
      "playersSpawnPlace": "SamePlace", "timeAndWeatherSettings": {},
      "botSettings": {}, "wavesSettings": {}}, "data"),
    ("/client/match/local/start",           None,
     {"location": "factory4_day", "timeVariant": "CURR",
      "mode": "PVE", "playerSide": "Pmc"}, "data"),
    ("/client/insurance/items/list/cost",   None,
     {"traders": [PRAPOR], "items": []}, "data"),
    ("/client/getMetricsConfig",            None, {}, "data"),
    ("/client/match/join",                  None, {"servername": "", "version": ""}, "data"),
    ("/client/match/available",             None, {}, "data"),
    ("/client/match/group/exit_from_menu",  None, {}, "data"),
    ("/client/match/group/invite/cancel-all", None, {}, "data"),
    # LAST on purpose: logout invalidates the session token, so any route
    # sampled after it would be measured without a session.
    ("/client/game/logout",                 None, {}, "data"),
]


def slug(route):
    return route.strip("/").replace("/", "_")


# --------------------------------------------------------------- the wire
def call(path, body=None, token=None, timeout=180):
    """One request. Returns (status, raw-text, parsed-or-None).

    Never raises on an HTTP error status: "this route is not served" is exactly
    one of the findings, and letting an exception through would turn a
    measurement into a crash with no verdict.
    """
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    payload = b"" if body is None else json.dumps(body).encode("utf-8")
    c.request("POST" if body is not None else "GET", path, payload, {
        "Accept-Encoding": "identity",
        "Content-Type": "application/json",
        "Cookie": "PHPSESSID=" + (token or ""),
    })
    r = c.getresponse()
    raw = r.read()
    status = r.status
    c.close()
    if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
        try:
            raw = zlib.decompress(raw)
        except zlib.error:
            pass
    text = raw.decode("utf-8", "replace")
    try:
        return status, text, json.loads(text)          # STRICT
    except ValueError:
        return status, text, None


def stage():
    for p, what in ((BACKEND, "backend"), (TARKOV, "tarkov.dll")):
        if not os.path.isfile(p):
            raise SystemExit(
                "INCONCLUSIVE: %s is missing at %s. Nothing was measured.\n"
                "Build it first:  & .\\installer\\build\\aowl.exe build %s"
                % (what, p, "backend" if what == "backend" else "mods"))
    if not os.path.isfile(LIVE_DB):
        raise SystemExit("INCONCLUSIVE: no database at %s, so the emulator "
                         "cannot boot and nothing was measured." % LIVE_DB)
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, "mods", "tarkov"))
    os.makedirs(os.path.join(ROOT, "registry"))
    os.makedirs(os.path.join(ROOT, "samples"))
    shutil.copy(BACKEND, os.path.join(ROOT, "aowlspt-backend.exe"))
    shutil.copy(TARKOV, os.path.join(ROOT, "mods", "tarkov", "tarkov.dll"))
    shutil.copy(LIVE_DB, os.path.join(ROOT, "db.json"))
    src_data = MODDATA
    dst_data = os.path.join(ROOT, "mods", "tarkov", "data")
    if os.path.isdir(src_data) and not os.path.isdir(dst_data):
        # the mod reads its own data dir; a junction avoids copying 50 MB
        try:
            subprocess.run("mklink /J \"%s\" \"%s\""
                           % (dst_data.replace("/", "\\"),
                              src_data.replace("/", "\\")),
                           shell=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        except Exception:
            pass
    with open(os.path.join(ROOT, "registry", "mods.json"), "w") as f:
        json.dump({"schema": "aowlspt.registry/1",
                   "registry": {"id": "oursample", "name": "dto gap sampler",
                                "revision": 1},
                   "mods": [TARKOV_ENTRY]}, f, indent=2)
    with open(os.path.join(ROOT, "mods", "aowlspt-selection.json"), "w") as f:
        json.dump({"schema": "aowlspt.selection/1", "writtenBy": "oursample",
                   "side": "server",
                   "registry": os.path.join(ROOT, "registry", "mods.json"),
                   "load": ["aowl.tarkov"]}, f)
    return {"backend_sha256": sha(BACKEND), "backend_bytes": os.path.getsize(BACKEND),
            "tarkov_sha256": sha(TARKOV), "tarkov_bytes": os.path.getsize(TARKOV),
            "db": LIVE_DB, "db_bytes": os.path.getsize(LIVE_DB)}


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


class Backend(object):
    def __enter__(self):
        self.p = subprocess.Popen(
            [os.path.join(ROOT, "aowlspt-backend.exe"),
             "--root", ROOT, "--port", str(PORT), "--no-store-lock"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=ROOT,
            universal_newlines=True, encoding="utf-8", errors="replace")
        deadline = time.time() + 300
        while time.time() < deadline:
            if self.p.poll() is not None:
                raise SystemExit("INCONCLUSIVE: the backend exited during "
                                 "startup, so nothing was measured:\n"
                                 + (self.p.stdout.read() or "")[-3000:])
            try:
                st, _t, doc = call("/aowlspt/tarkov/launcher/profiles", {}, timeout=10)
                if doc is not None:
                    return self
            except Exception:
                pass
            time.sleep(0.5)
        raise SystemExit("INCONCLUSIVE: the backend never answered on port %d"
                         % PORT)

    def __exit__(self, *a):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()


def at_path(doc, jpath):
    """The object at `jpath`, or None. `None` means 'not reachable', which is
    a different outcome from `{}` -- the caller must keep them apart."""
    cur = doc
    for part in [p for p in jpath.split(".") if p]:
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            if part not in cur:
                return None
            cur = cur[part]
        else:
            return None
    return cur


def classify(status, text, doc, jpath):
    """(verdict, detail). A NEGATIVE about the finished document."""
    if status >= 400:
        return NOT_SERVED, "HTTP %d" % status
    if doc is None:
        return NOT_SERVED, ("the body is not JSON at all (%d bytes, starts %r)"
                            % (len(text), text[:60]))
    err = doc.get("err") if isinstance(doc, dict) else None
    if err not in (None, 0, "0"):
        return ERROR, "envelope err=%r errmsg=%r" % (err, (doc or {}).get("errmsg"))
    obj = at_path(doc, jpath)
    if obj is None:
        return EMPTY, "no object at --path %r in the response" % jpath
    if isinstance(obj, list):
        if not obj:
            return EMPTY, "the array at %r is empty" % jpath
        obj = obj[0]
    if not isinstance(obj, dict):
        return EMPTY, ("%r is a %s, not an object -- there is no key set to diff"
                       % (jpath, type(obj).__name__))
    if not obj:
        return EMPTY, ("the object at %r has ZERO keys. This is NOT 'nothing "
                       "is missing'." % jpath)
    return SERVED, "%d top-level keys" % len(obj)


def raid_end_body(session, pid):
    """A minimal but SHAPE-COMPLETE LocalRaidEnded. The route is client-sent;
    we sample it only to record what we answer with."""
    return {
        "serverId": "oursample.factory4_day.0",
        "results": {"profile": {"_id": pid}, "result": "Survived",
                    "killerId": "", "killerAid": "", "exitName": "Gate 0",
                    "inSession": True, "favorite": False, "playTime": 60},
        "lostInsuredItems": [],
        "transferItems": {},
    }


# ------------------------------------------------------------- the sampling
def sample_all():
    stamp = stage()
    manifest = {"schema": "aowlspt.oursample/1",
                "provenance": "OURS",
                "why": ("this process started backend %s (sha %s) with mod "
                        "tarkov.dll (sha %s) on 127.0.0.1:%d and issued every "
                        "request below itself; no BSG traffic can be present"
                        % (os.path.basename(BACKEND), stamp["backend_sha256"],
                           stamp["tarkov_sha256"], PORT)),
                "port": PORT, "root": ROOT,
                "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "artifacts": stamp, "entries": []}
    with Backend():
        st, _t, made = call("/aowlspt/tarkov/launcher/profile/create",
                            {"nickname": "DtoGap", "side": "Usec",
                             "edition": "standard"})
        if not isinstance(made, dict) or not made.get("ok"):
            raise SystemExit("INCONCLUSIVE: could not create a fresh profile "
                             "(%r); every route below would have been sampled "
                             "without a session, so nothing was measured."
                             % (made,))
        token = made.get("token") or ""
        pid = (made.get("profile") or {}).get("id") or token
        if not token:
            raise SystemExit("INCONCLUSIVE: the launcher returned no token: %r"
                             % (made,))
        manifest["session"] = token
        manifest["profile_id"] = pid

        for route, url, body, jpath in CALLS:
            url = url or route
            b = body
            if b == "__RAIDEND__":
                b = raid_end_body(token, pid)
            elif isinstance(b, dict):
                b = {k: (pid if v == "__SESSION__" else v) for k, v in b.items()}
            t0 = time.time()
            status, text, doc = call(url, b, token)
            ms = int((time.time() - t0) * 1000)
            verdict, detail = classify(status, text, doc, jpath)
            path = os.path.join(ROOT, "samples", slug(route) + ".json")
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            manifest["entries"].append({
                "route": route, "url": url, "path": jpath,
                "status": status, "bytes": len(text), "ms": ms,
                "verdict": verdict, "detail": detail,
                "sample": os.path.relpath(path, ROOT).replace("\\", "/"),
            })
            print("  %-11s %-40s %8d B  %5d ms  %s"
                  % (verdict, route, len(text), ms, detail))
    with open(os.path.join(ROOT, "ours-manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    return manifest


# --------------------------------------------------------------- the diffing
def dtogap_rows(route, sample, jpath, dto=None):
    """Run dtogap for one route against OUR sample.

    Returns (rows, raw). rows is [(name, type, kind)] parsed out of the
    EXPECTED-BUT-MISSING block; raw is the whole report so a caller can print
    it. dtogap is invoked as a SUBPROCESS on purpose: its selfcheck/
    member_selfcheck exit non-zero, and a non-zero exit must abort the table
    rather than being swallowed as 'no holes'.
    """
    cmd = [sys.executable, os.path.join(HERE, "dtogap.py"), route,
           "--sample", sample, "--provenance", "ours", "--path", jpath]
    if dto:
        cmd += ["--dto", dto]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        return None, (p.stdout or "") + (p.stderr or "")
    rows, grab = [], False
    for line in (p.stdout or "").splitlines():
        s = line.strip()
        if s.startswith("EXPECTED-BUT-MISSING"):
            grab = True
            continue
        if grab:
            if s.startswith("MISSING"):
                parts = s.split()
                # MISSING <name[ -> wire]> <type> <KIND> (decl, origin)
                kind = "REF" if " REF " in line else ("VALUE" if " VALUE " in line else "?")
                rows.append((parts[1], kind, line))
                continue
            if s and not s.startswith("MISSING"):
                grab = False
    return rows, p.stdout or ""


# ---------------------------------------- CLIENT-TOLERATED vs CANDIDATE HOLE
#
# A "declared but absent" row was reported as a candidate hole on EVERY run,
# forever, even after it had been proved that BSG'S OWN SERVER omits the same
# member.  That is the shape of a number that never converges: the count stays
# high, nobody can tell a new regression from the permanent floor, and a real
# hole hides in the noise.
#
# The classification is DERIVED, never written down.  For each route we ask
# dtogap the SAME question a second time against BSG's captured response for
# that route, with --provenance bsg, and read its DECLARED-BUT-ABSENT-FROM-BSG
# block.  A member that is absent from BOTH payloads is CLIENT-TOLERATED: the
# real server does not send it and the client boots and plays anyway.  A member
# absent only from OURS stays a CANDIDATE HOLE.
#
# Three properties this has, and a hardcoded exemption list would not:
#   * it cannot go stale -- re-run it after a game update and a member BSG has
#     started sending moves back into the candidate column by itself;
#   * it can FAIL -- if BSG's capture turns out to carry the key, the row is
#     NOT reclassified, and nothing here can quietly pass it;
#   * "no BSG capture for this route" is its own third outcome (UNCLASSIFIED),
#     printed as such.  It is NOT tolerance, and it is NOT a hole.


def bsg_absent(route):
    """(set-of-member-names, evidence) that BSG's own capture also omits.

    Returns (None, why) when the comparison could not be made -- which is
    reported as UNCLASSIFIED, never folded into either column.
    """
    import dtogap as G
    cap = G.find_capture(route)
    if not cap:
        return None, "no BSG capture for this route in %s" % G.CAPTURE_ROOT
    cmd = [sys.executable, os.path.join(HERE, "dtogap.py"), route,
           "--sample", cap, "--provenance", "bsg"]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        return None, "dtogap exited %d on BSG's %s" % (p.returncode,
                                                       os.path.basename(cap))
    names, grab, saw = set(), False, False
    for line in (p.stdout or "").splitlines():
        t = line.strip()
        if t.startswith("DECLARED-BUT-ABSENT-FROM-BSG"):
            grab, saw = True, True
            continue
        if grab:
            if t.startswith("ABSENT"):
                names.add(t.split()[1])
                continue
            grab = False
    if not saw:
        return None, ("dtogap printed no DECLARED-BUT-ABSENT-FROM-BSG block "
                      "for BSG's %s (it went INCONCLUSIVE)"
                      % os.path.basename(cap))
    return names, "BSG's own %s omits %d of them" % (os.path.basename(cap),
                                                     len(names))


# ------------------------------------------- the three routes with NO number
#
# Three routes used to print INCONCLUSIVE forever, and "no number" was being
# read as "no gap". Each is now either a REAL number or a PERMANENT, stated
# reason -- never "we did not look". The reason is asserted from evidence on
# disk, so a wrong reason can still fail.

# The BSG capture. Overridable because `responses/large/*.json` (the DECODED
# large bodies, including seq 045 `/client/items`) are NOT tracked by git --
# a fresh worktree has the 690 small files and none of the 15 large ones, so
# the BSG half of the items measurement would silently go INCONCLUSIVE there.
CAP = os.environ.get("AOWL_CAPTURE",
                     os.path.join(REPO, "mods", "tarkov", "data",
                                  "capture", "raid1"))
CAP_ITEMS = os.path.join(CAP, "responses", "large", "045.json")   # BSG /client/items
CAP_RAIDEND = os.path.join(CAP, "responses", "204.json")          # BSG /client/match/local/end


def _load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return json.load(f)


def _resolver():
    import dtogap as G
    from il2cpp_resolve import Resolver
    import il2cpp_attrs
    r = Resolver(G.GAMEASM, G.METADEC)
    G.selfcheck(r)
    at = il2cpp_attrs.selfcheck(r)
    G.member_selfcheck(r, at)
    return G, r, at


def measure_items(sample):
    """/client/items has no top-level DTO -- it is a dict of templates keyed by
    id. That makes a WHOLE-PAYLOAD diff undefined, NOT absent. Two real numbers
    are produced instead.

    A. THE BSG SUPERSET CHECK (authoritative, cross-server). For every id we
       serve that BSG also served (capture seq 045, `resp_xenc: aes`,
       `PHPSESSID`), how many `_props` keys did BSG send that we do not? This
       is a NEGATIVE about the finished payload and cannot pass by
       construction: it fails the moment one key goes missing.

    B. THE CLIENT-DECLARATION SWEEP. Our items collapse to a small number of
       distinct `_props` key-set SIGNATURES. For each, the best-matching
       `EFT.InventoryLogic.*Template` is picked by wire-key overlap (the
       `--whichdto` method) and its declared members diffed against the UNION
       of the item's outer keys and its `_props` keys -- the union, because the
       client binds `_id`/`_name`/`_parent`/`_type` from the outer object and
       everything else from `_props`. Diffing the outer object alone (which is
       what dtogap's own `--path data.<id>` hint produces) reports ~107
       fictional holes per item.

    B's rows are CANDIDATES in the same currency as every other route; A's rows
    are stronger, because BSG itself sent them.
    """
    G, r, at = _resolver()
    ours = _load(sample).get("data") or {}
    notes = []

    bsg_missing = None
    if not os.path.exists(CAP_ITEMS):
        notes.append("BSG superset check: INCONCLUSIVE -- no capture at %s"
                     % CAP_ITEMS)
    else:
        bsg = _load(CAP_ITEMS).get("data") or {}
        common = sorted(set(bsg) & set(ours))
        miss = {}
        for i in common:
            bp = (bsg[i] or {}).get("_props") or {}
            op = (ours[i] or {}).get("_props") or {}
            for k in bp:
                if k not in op:
                    miss[k] = miss.get(k, 0) + 1
        bsg_missing = miss
        notes.append("BSG superset check: %d of our %d ids were also served by "
                     "BSG. %d distinct `_props` key(s) BSG sent are absent from "
                     "ours (%d key-instances)."
                     % (len(common), len(ours), len(miss), sum(miss.values())))
        for k, c in sorted(miss.items(), key=lambda kv: -kv[1])[:12]:
            notes.append("    BSG-SENDS-WE-OMIT  %-46s %d items" % (k, c))
        notes.append("    %d id(s) BSG served are absent from our database "
                     "entirely; conjuring a whole template is a different and "
                     "much larger question, and is NOT counted here."
                     % len(set(bsg) - set(ours)))

    cands = []
    for t in range(r.NTYPES):
        ns, nm = r.tname(t)
        if ns != "EFT.InventoryLogic" or not nm.endswith("Template"):
            continue
        if nm.startswith("I"):            # the interfaces, not the classes
            continue
        try:
            ms = G.dto_fields(r, t, at)[0]
        except Exception:
            continue
        if len(ms) < 5:
            continue
        cands.append((nm, ms, set((w or n).lower()
                                  for n, w, _t, _k, _d, _s, _o in ms)))
    if not cands:
        return None, ["INCONCLUSIVE: not one EFT.InventoryLogic.*Template type "
                      "was enumerated, so NOTHING was diffed."]

    sigs = {}
    for k, v in ours.items():
        key = tuple(sorted(((v or {}).get("_props") or {}).keys()))
        if key not in sigs:
            sigs[key] = [0, k]
        sigs[key][0] += 1
    rows = {}
    for _sig, pair in sigs.items():
        cnt, rep = pair
        item = ours[rep]
        emitted = set(x.lower() for x in ((item.get("_props") or {})))
        emitted |= set(x.lower() for x in item.keys())
        best = max(cands, key=lambda c: (len(emitted & c[2]) / float(len(emitted) or 1),
                                         -len(c[2])))
        for n, w, ty, kind, _dcl, _st, _o in best[1]:
            wire = w or n
            if wire.lower() in emitted:
                continue
            key = (wire, ty, kind)
            rows[key] = rows.get(key, 0) + cnt
    return {"signatures": len(sigs), "classes": len(cands), "rows": rows,
            "bsg_missing": bsg_missing, "items": len(ours)}, notes


def measure_customization(sample):
    """PERMANENT -- and it is a reason, not a shrug.

    `EFT.AvailableCustomizationsResponse`, the class dtogap maps this route to,
    declares ZERO serializable members on this build (it is a collection type;
    `dto_fields` returns an empty member set AND an empty skipped set, so it is
    not that members were filtered out). A key-set diff against a type with no
    keys is undefined, so the gap number is 0 BY CONSTRUCTION. That is CHECKED
    here, not assumed: the moment the client declares a member, this stops
    claiming permanence and prints the count instead.

    Separately, the empty array is CORRECT rather than a placeholder. This
    route is the suits an ACCOUNT OWNS, which for a fresh profile is none. The
    CATALOGUE is a different route, `/client/customization`, which this server
    answers whole from `templates.customization`.
    """
    G, r, at = _resolver()
    t = r.find_one("EFT.AvailableCustomizationsResponse")
    if t is None:
        return None, ["INCONCLUSIVE: EFT.AvailableCustomizationsResponse is not "
                      "in this build's metadata, so the permanence claim was "
                      "NOT checked."]
    members, skipped = G.dto_fields(r, t, at)
    body = _load(sample).get("data")
    return {"members": len(members), "skipped": len(skipped),
            "is_array": isinstance(body, list), "len": len(body or [])}, None


def measure_raidend(sample):
    """PERMANENT -- and it is a reason, not a shrug.

    This route is client-SENT (`LocalRaidEnded`); the client declares no
    response class, so there is nothing to diff. The open question was whether
    an empty `data` is the right answer. It is, and BSG says so: the captured
    BSG response (seq 204, POST /client/match/local/end, `resp_xenc: aes`) is
    `{"err":0,"data":null,"errmsg":null}`. The assertion made here is therefore
    a NEGATIVE against real BSG traffic -- our `data` must not differ in shape
    from BSG's -- and it fails if we ever start sending an object BSG did not.
    """
    if not os.path.exists(CAP_RAIDEND):
        return None, ["INCONCLUSIVE: no BSG capture at %s, so nothing was "
                      "compared." % CAP_RAIDEND]
    ours = _load(sample)
    bsg = _load(CAP_RAIDEND)
    return {"ours_data": ours.get("data"), "bsg_data": bsg.get("data"),
            "same": (ours.get("data") is None) == (bsg.get("data") is None),
            "ours_err": ours.get("err"), "bsg_err": bsg.get("err")}, None


SPECIAL = {
    "/client/items": measure_items,
    "/client/account/customization": measure_customization,
    "/client/match/local/end": measure_raidend,
}


def special_row(route, sample):
    """(decl, ref, val, tol, verdict, detail_lines) for a route with no
    top-level DTO. Returns None for `decl`/`ref`/`val` only when the measurement itself
    could not be made -- which prints INCONCLUSIVE with the reason, never a
    silent zero."""
    fn = SPECIAL[route]
    try:
        got, notes = fn(sample)
    except Exception as exc:                      # noqa: BLE001
        return (None, None, None, None, "INCONCLUSIVE (measurement raised)",
                ["%s: %r" % (type(exc).__name__, exc)])
    lines = list(notes or [])
    if got is None:
        return (None, None, None, None, "INCONCLUSIVE", lines)

    if route == "/client/items":
        rows = got["rows"]
        ref = sum(1 for _n, _t, k in rows if k == "REF")
        val = sum(1 for _n, _t, k in rows if k == "VALUE")
        bm = got["bsg_missing"]
        head = ("%d template class(es) ranked over %d distinct `_props` "
                "signatures across %d items"
                % (got["classes"], got["signatures"], got["items"]))
        lines.insert(0, head)
        for (n, ty, k), c in sorted(rows.items(),
                                    key=lambda kv: (kv[0][2] != "REF", -kv[1])):
            lines.append("    DECLARED-ABSENT  %-6s %-30s %-26s %d items"
                         % (k, n, ty, c))
        if bm is None:
            verdict = "%d/%d cand (BSG check INCONCLUSIVE)" % (ref, val)
            return (None, ref, val, None, verdict, lines)
        elif bm:
            verdict = "GAP: BSG sends %d key(s) we omit" % len(bm)
            return (None, ref, val, None, verdict, lines)
        else:
            verdict = "no gap; %d client-tolerated" % (ref + val)
            lines.append("    Our `_props` is a strict SUPERSET of BSG's on "
                         "every shared id, so every DECLARED-ABSENT row above "
                         "is necessarily absent from BSG's payload too: they "
                         "are CLIENT-TOLERATED absences, not our holes. That "
                         "follows from the count on the line above being 0; if "
                         "it is ever non-zero, this sentence does not apply. "
                         "They are therefore counted in the `toler` column, "
                         "not as candidate holes.")
            return (None, 0, 0, ref + val, verdict, lines)

    if route == "/client/account/customization":
        n = got["members"]
        if n == 0:
            verdict = ("no gap, PERMANENTLY: the DTO declares 0 members")
            lines.append("EFT.AvailableCustomizationsResponse declares 0 "
                         "serializable members and 0 skipped ones, so there is "
                         "no key set to diff. `data` is an array (%s) of %d "
                         "entr(ies): the suits this ACCOUNT OWNS, which for a "
                         "fresh profile is none. The CATALOGUE is the separate "
                         "route /client/customization, served whole from "
                         "templates.customization."
                         % (got["is_array"], got["len"]))
            return (0, 0, 0, 0, verdict, lines)
        lines.append("the DTO now declares %d member(s); the permanence claim "
                     "no longer holds and this route needs a real diff." % n)
        return (n, None, None, None, "RECHECK", lines)

    if route == "/client/match/local/end":
        if got["same"]:
            verdict = "no gap, PERMANENTLY: BSG sends data:null too"
            lines.append("BSG capture seq 204 answered err=%r data=%r; we "
                         "answer err=%r data=%r. The client declares no "
                         "response class for a route it SENDS, so there is "
                         "nothing to diff -- and an empty `data` is not a "
                         "placeholder, it is what the real server sends."
                         % (got["bsg_err"], got["bsg_data"],
                            got["ours_err"], got["ours_data"]))
            return (0, 0, 0, 0, verdict, lines)
        lines.append("our `data` is %r but BSG's is %r -- the shapes now "
                     "differ, so this is a real divergence."
                     % (got["ours_data"], got["bsg_data"]))
        return (None, None, None, None, "DIVERGES FROM BSG", lines)

    return (None, None, None, None, "INCONCLUSIVE", lines)


def table(manifest, verbose=False):
    import dtogap as G
    print("")
    print("=" * 78)
    print("OUR EMULATION GAPS -- measured against OUR OWN served payloads")
    print("provenance: OURS. %s" % manifest["why"])
    print("=" * 78)
    print("%-40s %5s %5s %5s %5s  %s"
          % ("route", "decl", "REF", "VALUE", "toler", "verdict"))
    print("-" * 78)
    totals = {"REF": 0, "VALUE": 0, "TOL": 0}
    detail_blocks = []
    tolerated_blocks = []
    unclassified = []
    special_blocks = []
    inconclusive = []
    for e in manifest["entries"]:
        route = e["route"]
        ent = G.ROUTES.get(route)
        dto = ent[0] if ent else None
        if e["verdict"] != SERVED and route not in SPECIAL:
            inconclusive.append((route, e["verdict"], e["detail"]))
            print("%-40s %5s %5s %5s %5s  INCONCLUSIVE (%s)"
                  % (route, "-", "-", "-", "-", e["verdict"]))
            continue
        if route in SPECIAL:
            # No top-level DTO -- but "no DTO" is not "no measurement". Each of
            # these three now yields a real number or a PERMANENT stated
            # reason; see SPECIAL above.
            sample = os.path.join(manifest["root"],
                                  e["sample"].replace("/", os.sep))
            decl, ref, val, tol, verdict, lines = special_row(route, sample)
            if ref is not None:
                totals["REF"] += ref
            if val is not None:
                totals["VALUE"] += val
            if tol is not None:
                totals["TOL"] += tol
            print("%-40s %5s %5s %5s %5s  %s"
                  % (route,
                     "-" if decl is None else decl,
                     "-" if ref is None else ref,
                     "-" if val is None else val,
                     "-" if tol is None else tol, verdict))
            special_blocks.append((route, verdict, lines))
            if verdict.startswith("INCONCLUSIVE"):
                inconclusive.append((route, "NO-DTO", verdict))
            continue
        if not dto:
            inconclusive.append((route, "NO-DTO",
                                 (ent[2] if ent else "route not in dtogap ROUTES")))
            print("%-40s %5s %5s %5s %5s  INCONCLUSIVE (no DTO mapped)"
                  % (route, "-", "-", "-", "-"))
            continue
        sample = os.path.join(manifest["root"], e["sample"].replace("/", os.sep))
        rows, raw = dtogap_rows(route, sample, e["path"])
        if rows is None:
            inconclusive.append((route, "DTOGAP-FAILED", raw.strip()[-200:]))
            print("%-40s %5s %5s %5s %5s  INCONCLUSIVE (dtogap refused)"
                  % (route, "-", "-", "-", "-"))
            continue
        tol_names, tol_why = bsg_absent(route)
        if tol_names is None:
            cand, tol = rows, []
            # Only worth reporting when there is something to classify: a route
            # with zero missing rows has no verdict riding on the BSG side.
            if rows:
                unclassified.append((route, tol_why))
        else:
            cand = [x for x in rows if x[0] not in tol_names]
            tol = [x for x in rows if x[0] in tol_names]
        ref = sum(1 for _n, k, _l in cand if k == "REF")
        val = sum(1 for _n, k, _l in cand if k == "VALUE")
        totals["REF"] += ref
        totals["VALUE"] += val
        totals["TOL"] += len(tol)
        decl = raw.count("    ok  ") + len(rows)
        if tol_names is None:
            verdict = ("no gap" if not rows
                       else "%d UNCLASSIFIED (%s)" % (len(rows), tol_why))
        elif cand:
            verdict = "gaps"
        elif tol:
            verdict = "no gap; %d client-tolerated" % len(tol)
        else:
            verdict = "no gap"
        print("%-40s %5d %5d %5d %5s  %s"
              % (route, decl, ref, val,
                 "-" if tol_names is None else len(tol), verdict))
        if cand:
            detail_blocks.append((route, dto, cand))
        if tol:
            tolerated_blocks.append((route, dto, tol, tol_why))
    print("-" * 78)
    print("%-40s %5s %5d %5d %5d  CANDIDATE HOLES (+tolerated)"
          % ("TOTAL", "", totals["REF"], totals["VALUE"], totals["TOL"]))
    print("")
    print("A row is: the client declares a serializable member and OUR payload")
    print("carries no key for it. That is a CANDIDATE, not a proven bug --")
    print("proving fatality needs disassembly of the CONSUMER, which nobody has")
    print("done. REF absent => stays null, any dereference crashes or hangs.")
    print("VALUE absent => silently takes the CLR default.")
    for route, dto, rows in detail_blocks:
        print("")
        print("%s   DTO=%s" % (route, dto))
        for _n, k, line in sorted(rows, key=lambda r: (r[1] != "REF", r[0])):
            print("  " + line.strip())
    for route, dto, rows, why in tolerated_blocks:
        print("")
        print("%s   %d CLIENT-TOLERATED (not counted above)   DTO=%s"
              % (route, len(rows), dto))
        print("  Absent from OUR payload AND from BSG's: %s. The real server"
              % why)
        print("  does not send these either, so their absence is what the")
        print("  client is built to survive -- it is not an emulation hole.")
        print("  This is re-derived from the capture every run: if BSG's own")
        print("  payload ever carries one, it moves back above by itself.")
        for _n, k, line in sorted(rows, key=lambda x: (x[1] != "REF", x[0])):
            print("  " + line.strip().replace("MISSING", "TOLERATED", 1))
    if unclassified:
        print("")
        print("UNCLASSIFIED -- absent from ours, and we could not ask BSG.")
        print("This is neither a hole nor tolerance; it is 'we did not look'.")
        for route, why in unclassified:
            print("  %-40s %s" % (route, why))
    for route, verdict, lines in special_blocks:
        print("")
        print("%s   %s" % (route, verdict))
        for ln in lines:
            print("  " + ln)
    if inconclusive:
        print("")
        print("INCONCLUSIVE -- no gap number exists for these, and 'no number'")
        print("is not 'no gap':")
        for route, why, detail in inconclusive:
            print("  %-40s %-14s %s" % (route, why, detail))
    return totals


# ------------------------------------------------------------- the selfcheck
def selfcheck():
    """Prove the classifier can FAIL. Each case is an input that MUST NOT be
    classified SERVED; a classifier that passes everything is the bug."""
    bad = []
    cases = [
        (200, '{"err":0,"data":{"a":1}}', "data", SERVED),
        (404, "Not Found", "data", NOT_SERVED),
        (200, "<html>nope</html>", "data", NOT_SERVED),
        (200, '{"err":228,"errmsg":"boom","data":null}', "data", ERROR),
        (200, '{"err":0,"data":{}}', "data", EMPTY),
        (200, '{"err":0,"data":[]}', "data", EMPTY),
        (200, '{"err":0,"data":null}', "data", EMPTY),
        (200, '{"err":0,"data":{"config":{}}}', "data.config", EMPTY),
        (200, '{"err":0,"data":[{"x":1}]}', "data", SERVED),
        (200, '{"err":0,"data":{"a":1}}', "data.config", EMPTY),
    ]
    for status, text, jpath, want in cases:
        try:
            doc = json.loads(text)
        except ValueError:
            doc = None
        got, _d = classify(status, text, doc, jpath)
        if got != want:
            bad.append("classify(%d, %r, %r) = %s, expected %s"
                       % (status, text[:40], jpath, got, want))
    if bad:
        sys.stderr.write("SAMPLER SELF-CHECK FAILED -- the classifier does not\n"
                         "separate a served payload from a non-answer, so no\n"
                         "gap number it produces is trustworthy.\n  "
                         + "\n  ".join(bad) + "\n")
        return 1
    print("PASS  sampler selfcheck: %d classifier cases, including the four "
          "that must NOT read as SERVED" % len(cases))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sample-only", action="store_true",
                    help="stage, start, sample, write the manifest; no diff")
    ap.add_argument("--reuse", action="store_true",
                    help="skip staging and reuse the manifest already in ROOT")
    ap.add_argument("--selfcheck", action="store_true",
                    help="prove the classifier can fail, then exit")
    ap.add_argument("--json", help="also write the manifest here")
    a = ap.parse_args()

    if a.selfcheck:
        return selfcheck()
    if selfcheck():
        return 1

    if a.reuse:
        man = os.path.join(ROOT, "ours-manifest.json")
        if not os.path.exists(man):
            sys.stderr.write(
                "INCONCLUSIVE: --reuse was asked for but there is no manifest"
                " at%s  %s%sso NOTHING was measured. Run without --reuse to"
                " sample first.%s" % (_NL, man, _NL, _NL))
            return 3
        with open(man, encoding="utf-8") as f:
            manifest = json.load(f)
    else:
        print("sampling OUR backend on 127.0.0.1:%d over %s" % (PORT, ROOT))
        manifest = sample_all()
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)
    if a.sample_only:
        print("\nsamples under %s" % os.path.join(ROOT, "samples"))
        return 0
    table(manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
