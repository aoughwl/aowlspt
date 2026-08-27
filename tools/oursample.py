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


def table(manifest, verbose=False):
    import dtogap as G
    print("")
    print("=" * 78)
    print("OUR EMULATION GAPS -- measured against OUR OWN served payloads")
    print("provenance: OURS. %s" % manifest["why"])
    print("=" * 78)
    print("%-40s %6s %6s %6s  %s"
          % ("route", "decl", "REF", "VALUE", "verdict"))
    print("-" * 78)
    totals = {"REF": 0, "VALUE": 0}
    detail_blocks = []
    inconclusive = []
    for e in manifest["entries"]:
        route = e["route"]
        ent = G.ROUTES.get(route)
        dto = ent[0] if ent else None
        if e["verdict"] != SERVED:
            inconclusive.append((route, e["verdict"], e["detail"]))
            print("%-40s %6s %6s %6s  INCONCLUSIVE (%s)"
                  % (route, "-", "-", "-", e["verdict"]))
            continue
        if not dto:
            inconclusive.append((route, "NO-DTO",
                                 (ent[2] if ent else "route not in dtogap ROUTES")))
            print("%-40s %6s %6s %6s  INCONCLUSIVE (no DTO mapped)"
                  % (route, "-", "-", "-"))
            continue
        sample = os.path.join(manifest["root"], e["sample"].replace("/", os.sep))
        rows, raw = dtogap_rows(route, sample, e["path"])
        if rows is None:
            inconclusive.append((route, "DTOGAP-FAILED", raw.strip()[-200:]))
            print("%-40s %6s %6s %6s  INCONCLUSIVE (dtogap refused)"
                  % (route, "-", "-", "-"))
            continue
        ref = sum(1 for _n, k, _l in rows if k == "REF")
        val = sum(1 for _n, k, _l in rows if k == "VALUE")
        totals["REF"] += ref
        totals["VALUE"] += val
        decl = raw.count("    ok  ") + len(rows)
        print("%-40s %6d %6d %6d  %s"
              % (route, decl, ref, val, "gaps" if rows else "no gap"))
        if rows:
            detail_blocks.append((route, dto, rows))
    print("-" * 78)
    print("%-40s %6s %6d %6d  CANDIDATE HOLES"
          % ("TOTAL", "", totals["REF"], totals["VALUE"]))
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
