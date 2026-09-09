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
  5. polls `/aowlspt/mods/client/<ver>` **as the game's host would**, carrying a
     report, and then checks what the panel says about it,
  6. writes `panel.golden.json`.

Step 5 is the only way a test run can have a client host at all -- there is no
game here -- and it is worth being clear about what is real in it. The report is
hand-written; the route, the parser (`mgr/clientreport.nim`), the arbitration
(`liveVerdict`) and the panel rows that come back are all the shipping ones. The
capture it writes therefore carries a real ledger, four rows answered and six
left alone, which is what lets `fakebackend.py --golden` replay a panel body
with the `client*` keys in it instead of a body from before they existed.

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
    # The overlay draws `KEEP` instead of a button from this flag and refuses
    # SPACE on it locally, so a manager that stopped sending it would put a
    # working ON/OFF button on the row that unloads every route this panel
    # reads. Absent is not false: `aowl_ov_read_panel` deliberately leaves the
    # flag alone when the key is missing, so an older manager cannot grow a
    # button -- but a *current* manager must say.
    if not isinstance(r.get("protected"), bool):
        bad("row %s: protected must be a bool (the overlay draws KEEP from it)"
            % r["guid"])
    if r["guid"] != r["id"]:
        bad("row %s: guid and id must be the same string" % r["guid"])
    # The overlay's fixed-width fields. A longer value is not a crash -- the
    # copy truncates -- but it is a row that reads wrong on the panel, and the
    # registry is the place to notice it.
    if len(r["guid"]) >= 80:
        bad("row %s: guid does not fit the overlay's 80-byte field" % r["guid"])
    if len(r["version"]) >= 24:
        bad("row %s: version does not fit the overlay's 24-byte field" % r["guid"])


# The report one poll from the game's host carries, as `host/common/modcontrol`
# writes it and `mgr/clientreport.nim` reads it. Sent here by hand because there
# is no game in a test run -- but it goes in through the real route, is parsed
# by the real parser, and comes back out of the real `/panel`, which is the
# whole point: the overlay is then reading a shape nobody wrote for it.
#
# Four records and six mods left out, deliberately. The rows that are here cover
# every state the panel draws differently -- running and settled, not running
# and settled, wanted-on and skipped, wanted-on and deferred -- and the ones
# that are not are what proves the panel can say `unknown` about a mod while
# saying facts about its neighbours. `more=1` says the rest are still coming,
# which is the difference between "the host has not got to it" and "the host
# says it is not there".
CLIENT_SESSION = "a1b2"
CLIENT_SEQ = 3
CLIENT_RECORDS = [
    ("com.savannt.sptsway", "+n", ""),      # running, and where it should be
    ("aowl.fovfix", "+s", "nofile"),        # wanted on, never attempted
    ("aowl.classicmovement", "-n", ""),     # wanted off, and off
    ("aowl.sain", "+d", "noteardown"),      # wanted on, refused live
]

# Client-only, and deliberately left out of the report above. It is the row that
# proves the rule: nothing that could answer about it has, so the manager must
# send `live:null` and the panel must draw `unknown`. A server-side mod cannot
# stand in for it -- `mgr/control` answers about those, so their `live` is a
# fact whatever the game says.
CLIENT_UNMENTIONED = "aowl.perf"


def report_as_client(port):
    """One client-host poll, carrying a report, through the route it rides on."""
    recs = "!".join(g + "~" + s + (("~" + c) if c else "")
                    for g, s, c in CLIENT_RECORDS)
    path = ("/aowlspt/mods/client/1.0.0?hs=%s&sq=%d&r=%s&more=1"
            % (CLIENT_SESSION, CLIENT_SEQ, recs))
    status, text, _ = request(port, "GET", path)
    if status != 200:
        bad("the client route answered %d to a poll with a report" % status)
        return
    doc = json.loads(text)
    if doc.get("schema") != "aowlspt.clientset/1":
        bad("the client route did not answer the client set: %r" % doc.get("schema"))
    else:
        ok("a client host reported %d rows and got its mod set back unchanged"
           % len(CLIENT_RECORDS))


def check_client(port, doc):
    """What the panel now carries about the *other* host.

    Every check here is about one rule: absence is not a negative. A row with no
    `clientLive` is a row nothing has answered about, and the manager must not
    invent a `false` for it -- if it did, the overlay would grey out every mod
    the rotation had not reached yet and a player would read that as "your mods
    are not loading".
    """
    for key, want in (("clientHost", True), ("clientSession", CLIENT_SESSION),
                      ("clientSeq", CLIENT_SEQ), ("clientRows", len(CLIENT_RECORDS)),
                      ("clientMore", True)):
        if doc.get(key) != want:
            bad("panel wrapper %s is %r, expected %r" % (key, doc.get(key), want))
    ok("the panel wrapper says which client host reported, how much, and that "
       "there is more coming")

    rows = {r["guid"]: r for r in doc.get("mods") or []}
    said = [g for g in rows if "clientLive" in rows[g]]
    quiet = [g for g in rows if "clientLive" not in rows[g]]
    if not said:
        bad("no row carries clientLive, so nothing the client host reported "
            "reached the panel")
        return
    if not quiet:
        bad("every row carries clientLive; nothing is left unknown, so the "
            "panel's `no answer yet` path has no fixture")
    else:
        ok("%d row(s) carry the client host's answer and %d are left with no "
           "key at all, which is how the panel is told `unknown`"
           % (len(said), len(quiet)))

    for guid, state, code in CLIENT_RECORDS:
        r = rows.get(guid)
        if r is None:
            bad("%s is not a panel row, so this fixture proves nothing about it"
                % guid)
            continue
        if "clientLive" not in r:
            bad("%s was reported on and the panel row carries no clientLive"
                % guid)
            continue
        for key in ("clientLive", "clientWant"):
            if not isinstance(r.get(key), bool):
                bad("row %s: %s must be a bool" % (guid, key))
        if not isinstance(r.get("clientOutcome"), str) or not r.get("clientOutcome"):
            bad("row %s: clientOutcome must be a non-empty string" % guid)
        # The overlay's fixed fields. Longer is a truncated word on the panel.
        if len(r.get("clientOutcome", "")) >= 12:
            bad("row %s: clientOutcome %r does not fit the overlay's 12-byte "
                "field" % (guid, r["clientOutcome"]))
        if code:
            if r.get("clientCode") != code:
                bad("row %s: clientCode is %r, expected %r"
                    % (guid, r.get("clientCode"), code))
            elif len(code) >= 24:
                bad("row %s: clientCode does not fit the overlay's 24-byte field"
                    % guid)
        elif "clientCode" in r:
            bad("row %s: a settled row carries a clientCode (%r); the slug only "
                "rides on skipped/refused/on-restart"
                % (guid, r.get("clientCode")))
    ok("every reported row carries live/want/outcome, and the slug only where "
       "there is one")

    # The one that matters most: a mod the client host says is *running* must
    # come back live, and a mod nobody mentioned must come back null.
    sway = rows.get("com.savannt.sptsway") or {}
    if sway.get("clientLive") is not True or sway.get("live") is not True:
        bad("the client host said com.savannt.sptsway is running and the panel "
            "answered live=%r clientLive=%r"
            % (sway.get("live"), sway.get("clientLive")))
    else:
        ok("a client-only mod the game says is running comes back live:true, "
           "which is what stops the overlay greying it")
    missed = rows.get(CLIENT_UNMENTIONED) or {}
    if "clientLive" in missed:
        bad("%s was left out of the report and the panel carries a clientLive "
            "for it anyway" % CLIENT_UNMENTIONED)
    elif "live" not in missed:
        bad("%s has no live key at all" % CLIENT_UNMENTIONED)
    elif missed["live"] is not None:
        bad("the panel answered live=%r for %s -- a client-only mod that only "
            "the game could answer about, and the game has not. Absence has "
            "become a negative, and the overlay will grey it out"
            % (missed["live"], CLIENT_UNMENTIONED))
    else:
        ok("a client-only mod the report has not reached answers live:null, so "
           "absence is never drawn as off")

    # And the ledger route. `/panel` withholds the dull rows to keep the body
    # inside the overlay's 32 KB buffer, so this is the only place the whole
    # ledger is visible -- and the only place a player can be pointed when a
    # mod they expected to see has no row on the panel at all.
    status, text, _ = request(port, "GET", "/aowlspt/mods/clientreport")
    if status != 200:
        bad("/aowlspt/mods/clientreport answered %d" % status)
        return
    led = json.loads(text)
    if led.get("schema") != "aowlspt.clientreport/1":
        bad("clientreport schema is %r" % led.get("schema"))
    elif not led.get("reporting"):
        bad("clientreport says nothing has reported, after a report")
    elif led.get("rows") != len(CLIENT_RECORDS):
        bad("clientreport holds %r rows, expected %d"
            % (led.get("rows"), len(CLIENT_RECORDS)))
    else:
        ok("/aowlspt/mods/clientreport carries the whole ledger: %d rows, "
           "session %s, seq %s, silentPolls %s, sessions %s"
           % (led["rows"], led.get("session"), led.get("seq"),
              led.get("silentPolls"), led.get("sessions")))


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

    # Before anything is reported, nothing is known about the game -- and the
    # manager has to say that as absence rather than as `false`. Checked first
    # because it is the state a fresh backend is in and the state a player with
    # no game running stays in.
    if doc.get("clientHost") is not False:
        bad("clientHost is %r before any client host has polled" % doc.get("clientHost"))
    elif any("clientLive" in r for r in rows):
        bad("a row carries clientLive before any client host has reported")
    else:
        ok("with no client host, the wrapper says so and no row claims anything "
           "about the game")

    report_as_client(port)

    # --- protected -------------------------------------------------------
    #
    # The whole KEEP path -- the label instead of a button, and SPACE refused
    # without a round trip -- hangs off this one flag, and until now nothing
    # checked it end to end. The capture this file writes had no `protected`
    # key on any row at all, so `fakebackend.py --golden` served rows the
    # overlay could happily offer an OFF button on, and the test host printed
    # "nothing protected was on screen" and passed.
    prot = [r["guid"] for r in rows if r.get("protected")]
    if not prot:
        bad("no row is protected; the manager protects itself, so either "
            "isProtected stopped answering or its own row left the panel")
    else:
        ok("%d protected row(s): %s" % (len(prot), ", ".join(prot)))
    if len(prot) == len(rows):
        bad("every row is protected, so nothing on the panel has a button")

    # And the refusal itself, which is the property the flag exists for. The
    # overlay answers this locally and never sends it; this checks the *other*
    # half, so that neither side is the only thing standing between a player
    # and a panel that unloads the mod serving it.
    if prot:
        status, text, _ = request(port, "POST",
                                  "/aowlspt/mods/toggle/" + prot[0],
                                  '{"enabled":false}')
        reply = json.loads(text)
        if reply.get("ok"):
            bad("the manager honoured a request to switch off the protected "
                "mod %s -- that unloads every /aowlspt/mods route" % prot[0])
        elif not reply.get("error"):
            bad("the protected toggle was refused with no reason to show")
        else:
            ok("the manager refuses `enabled:false` on %s, with a sentence the "
               "panel can print" % prot[0])
        # It must not have moved anyway.
        _, text, _ = request(port, "GET", "/aowlspt/mods/panel")
        after = {r["guid"]: r for r in json.loads(text).get("mods") or []}
        if after.get(prot[0], {}).get("enabled") is not True:
            bad("%s came back disabled after a refused toggle" % prot[0])
        else:
            ok("the refused toggle left the protected row on")
        # The other direction is allowed, and has to stay allowed: a protected
        # mod that is somehow off is one you must be able to switch back on.
        status, text, _ = request(port, "POST",
                                  "/aowlspt/mods/toggle/" + prot[0],
                                  '{"enabled":true}')
        if json.loads(text).get("ok"):
            ok("`enabled:true` on a protected mod is still accepted")
        else:
            bad("the manager refuses to *enable* a protected mod, so one that "
                "is off can never be recovered from the panel")
        # Put it back. That last POST recorded an *explicit* override on the
        # manager's own row, and the capture below is what `fakebackend.py
        # --golden` replays -- a golden that says "decided by override" on a row
        # nobody chose is a fixture that quietly disagrees with a fresh install.
        request(port, "GET", "/aowlspt/mods/clear/" + prot[0])

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
    final = json.loads(text)
    check_client(port, final)
    return final


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
