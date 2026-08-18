"""Drive the *real* backend with the *real* manager mod, and check the shapes.

This is the honest half of the overlay's backend test. `fakebackend.py` proves
the overlay can read a schema; this proves the schema is the one that actually
comes out of `mods/manager` when `aowlspt-backend` serves it, and it writes what
it saw to `panel.golden.json` so the fake can serve the real bytes back.

    python realbackend.py                 stage, run, check, capture
    python realbackend.py --keep 7281     leave the backend up on that port

What it does:

  1. builds nothing -- it uses `mods/manager/bin/manager.dll` as it stands, so
     run `aowl build-mod mods/manager` first,
  2. stages a scratch install: `mods/manager/` plus a copy of `registry/` where
     the manager's own search finds it,
  3. starts `backend/bin/aowlspt-backend.exe --root <stage> --port <p>`,
  4. calls `/aowlspt/mods/panel`, `/aowlspt/mods/toggle/<id>` and `/apply` and
     checks every field the overlay reads is present and the right type,
  5. writes `panel.golden.json`.

## The one thing it cannot do

It cannot hand these bytes to the overlay directly, and the reason is worth
stating rather than working around: `sendResponse` in `backend/aowlbackend.nim`
zlib-deflates every response body, unconditionally, with no `Content-Encoding`
header, because that is what the Tarkov client expects. So everything here
inflates the body before parsing, and the overlay -- which has no inflater and
should not grow one -- sends `Accept-Encoding: identity` and reports a deflated
answer as a named fault instead of an empty panel. The backend change that makes
the two meet is written up in `host/Aowlspt.Overlay/README.md`. Until it lands,
the overlay is tested against these captured bytes through `fakebackend.py
--golden`, which is a replay of the real thing rather than an invention of it.
"""
import http.client
import json
import os
import shutil
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
STAGE = os.path.join(HERE, "backendstage")
GOLDEN = os.path.join(HERE, "panel.golden.json")

failures = []


def ok(msg):
    print("ok    " + msg)


def bad(msg):
    print("error " + msg)
    failures.append(msg)


def request(port, verb, path, body=None):
    """One request, inflated if it comes back framed."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    if body is None:
        c.request(verb, path, headers={"Accept-Encoding": "identity"})
    else:
        c.request(verb, path, body,
                  {"Content-Type": "application/json",
                   "Accept-Encoding": "identity"})
    r = c.getresponse()
    raw = r.read()
    c.close()
    deflated = len(raw) > 1 and raw[0] == 0x78
    text = zlib.decompress(raw).decode() if deflated else raw.decode()
    return r.status, text, deflated


def stage():
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(os.path.join(STAGE, "mods", "manager"))
    os.makedirs(os.path.join(STAGE, "mods", "registry"))
    dll = os.path.join(REPO, "mods", "manager", "bin", "manager.dll")
    if not os.path.isfile(dll):
        bad("mods/manager/bin/manager.dll is not built "
            "(run: aowl build-mod mods/manager)")
        return False
    shutil.copy(dll, os.path.join(STAGE, "mods", "manager"))
    shutil.copy(os.path.join(REPO, "mods", "manager", "config.json"),
                os.path.join(STAGE, "mods", "manager"))
    # `mgr/control.modsRoot()` is the manager's own parent, and
    # `registryCandidates` looks for `<modsRoot>/registry/mods.json` first among
    # the derived paths. Putting it there rather than setting `registryPath`
    # exercises the search, which is what a real install relies on.
    shutil.copy(os.path.join(REPO, "registry", "mods.json"),
                os.path.join(STAGE, "mods", "registry"))
    with open(os.path.join(STAGE, "db.json"), "w") as f:
        f.write("{}\n")
    return True


def check_row(r):
    """Every field `aowl_ov_ingest` reads, and the types it assumes."""
    for key in ("guid", "id", "name", "version"):
        if not isinstance(r.get(key), str) or not r.get(key):
            bad("row %r: %s must be a non-empty string" % (r.get("guid"), key))
            return
    if not isinstance(r.get("enabled"), bool):
        bad("row %s: enabled must be a bool" % r["guid"])
    if not isinstance(r.get("restart"), bool):
        bad("row %s: restart must be a bool" % r["guid"])
    if "live" not in r:
        bad("row %s: live must be present (null when nothing knows)" % r["guid"])
    if r["guid"] != r["id"]:
        bad("row %s: guid and id must be the same string" % r["guid"])
    # The overlay's fixed-width fields. A longer value is not a crash -- the
    # copy truncates -- but it is a row that reads wrong on the panel, and the
    # registry is the place to notice it.
    if len(r["guid"]) >= 80:
        bad("row %s: guid does not fit the overlay's 80-byte field" % r["guid"])
    if len(r["version"]) >= 24:
        bad("row %s: version does not fit the overlay's 24-byte field" % r["guid"])


def drive(port):
    status, text, deflated = request(port, "GET", "/aowlspt/mods/panel")
    if status != 200:
        bad("/aowlspt/mods/panel answered %d" % status)
        return None
    if deflated:
        ok("the backend deflated the panel body (expected today; this is the "
           "one change the overlay needs in backend/aowlbackend.nim)")
    else:
        ok("the backend honoured Accept-Encoding: identity")
    doc = json.loads(text)

    if doc.get("schema") != "aowlspt.panel/1":
        bad("panel schema is %r, expected aowlspt.panel/1" % doc.get("schema"))
    else:
        ok("panel answers schema aowlspt.panel/1")

    # The wrapper's keys have to come before `mods`: the overlay skips to the
    # `"mods"` key and reads every object after it as a row.
    keys = list(doc.keys())
    if keys and keys[-1] != "mods":
        bad("`mods` is not the last key of the panel body (%r); the overlay "
            "would read the key after it as part of the last row" % keys[-1])
    else:
        ok("`mods` is the last key, so no wrapper field lands inside a row")

    rows = doc.get("mods") or []
    if not rows:
        bad("the panel served no rows -- is registry/mods.json staged?")
        return None
    for r in rows:
        check_row(r)
    ok("%d rows, every field the overlay reads present and typed" % len(rows))

    # A mod that is off, toggled on. On a host with no control this is the
    # deferred path, and the row must come back saying so.
    target = None
    for r in rows:
        if not r["enabled"]:
            target = r["guid"]
            break
    if target is None:
        bad("no disabled mod in the registry to toggle")
        return doc

    status, text, _ = request(port, "POST", "/aowlspt/mods/toggle/" + target,
                              '{"enabled":true}')
    reply = json.loads(text)
    if not reply.get("ok"):
        bad("toggle answered %r" % reply)
        return doc
    row = reply.get("row") or {}
    results = (reply.get("apply") or {}).get("results") or []
    outcomes = set(x.get("outcome") for x in results)
    ok("toggle %s -> enabled=%s, outcomes=%s"
       % (target, row.get("enabled"), sorted(outcomes)))
    if row.get("enabled") is not True:
        bad("the toggled row did not come back enabled")
    if reply.get("control") == "absent":
        if row.get("restart") is not True:
            bad("no host control, so the toggled row must say restart:true")
        else:
            ok("no host control: the row says restart:true, which is the `*`")
        if "deferred" not in outcomes:
            bad("no host control, so /apply must report a deferred outcome")
        else:
            ok("/apply reports the change as deferred, per mod")

    # And back off again. The restart flag must *clear*: the selection now
    # matches the one the manager started with, so nothing needs a restart.
    status, text, _ = request(port, "POST", "/aowlspt/mods/toggle/" + target,
                              '{"enabled":false}')
    back = (json.loads(text).get("row") or {})
    if back.get("restart") is False:
        ok("toggled back: restart clears, so the `*` is a difference and not a "
           "one-way latch")
    else:
        bad("toggling back left restart=%r" % back.get("restart"))

    status, text, _ = request(port, "GET", "/aowlspt/mods/panel")
    return json.loads(text)


def main():
    port = 7281
    keep = False
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--keep":
            keep = True
        elif a.isdigit():
            port = int(a)

    if not stage():
        return 1
    # Two places, because `backend/bin` is where `aowl build` puts it and
    # `installer/payload` is where `aowl payload` copies it -- and on a tree
    # where somebody is rebuilding the backend the first one is missing for a
    # minute at a time.
    exe = os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe")
    if not os.path.isfile(exe):
        exe = os.path.join(REPO, "installer", "payload", "aowlspt",
                           "aowlspt-backend.exe")
    if not os.path.isfile(exe):
        bad("aowlspt-backend.exe is not built (looked in backend/bin and "
            "installer/payload/aowlspt)")
        return 1

    log = open(os.path.join(STAGE, "backend.log"), "w")
    proc = subprocess.Popen([exe, "--root", STAGE, "--port", str(port)],
                            stdout=log, stderr=subprocess.STDOUT)
    try:
        # The backend opens its socket after loading every mod. Poll rather than
        # sleep a fixed time: a cold first run is slower than a warm one and a
        # fixed wait is either flaky or wasteful.
        up = False
        for _ in range(60):
            try:
                request(port, "GET", "/aowlspt/mods")
                up = True
                break
            except Exception:
                time.sleep(0.25)
        if not up:
            bad("the backend never answered on port %d" % port)
            return 1
        ok("aowlspt-backend up on %d with mods/manager loaded" % port)

        # Let the control probe settle before capturing anything. `control` is
        # `unknown` for the first `controlProbeMs` after the manager loads --
        # the probe is out and silence has not yet become an answer -- and a
        # golden captured in that window would record a transient as the schema.
        settled = None
        for _ in range(40):
            _, text, _ = request(port, "GET", "/aowlspt/mods/panel")
            settled = json.loads(text).get("control")
            if settled != "unknown":
                break
            time.sleep(0.1)
        if settled == "unknown":
            bad("the control probe never resolved; afterMs never fired")
        else:
            ok("the control probe resolved to %r" % settled)
        doc = drive(port)
        if doc is not None:
            with open(GOLDEN, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=1)
            ok("captured %s" % os.path.relpath(GOLDEN, REPO))
        if keep:
            print("\nbackend left running on %d; ctrl-c to stop" % port)
            proc.wait()
    finally:
        if not keep:
            proc.terminate()
        log.close()

    print("")
    print("all real-backend checks passed" if not failures
          else "%d real-backend check(s) failed" % len(failures))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
