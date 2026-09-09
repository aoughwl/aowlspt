"""Mutation proof: items handed to the BTR must survive the end of the raid.

The defect this proves against is silent and permanent. `/client/match/local/end`
carries `transferItems` -- everything the player put in the BTR container or the
transit hold -- and nothing in this server ever read it. `onMatchEnd` then
replaces the stored profile with the profile the client posts back, which by
construction does NOT contain those items, because handing an item over is
exactly how it leaves the character. Pay the BTR, load it, extract, and the kit
is in neither the stash nor the mail. The wire says 200.

THE ASSERTION IS A NEGATIVE, and it is asserted on the FINISHED STATE:

    after a raid-end whose body carried `transferItems`, NO item id from
    `transferItems` may be absent from the profile the server has saved --
    counting the stash and the mailbox as the two places it may be.

That is a check that can fail, and the mutant below is the input that makes it
fail. It is read back over the wire in a SEPARATE request from the one that
wrote it (`/client/game/profile/list` and
`/client/mail/dialog/getAllAttachments`), because a 200 from `match/local/end`
proves nothing at all -- that route answers 200 for every outcome, including the
one where it threw the items away (fact #135).

Every body is parsed with `json.loads`, STRICT. Never a substring test: this
repo's own backend selftest asserted with `contains` and passed a payload that
was not JSON at all for months (fact #122 -- `value` is emitted UNQUOTED, so an
invalid document is a thing that really happens here).

`Accept-Encoding: identity` on every request, because the backend always deflates
otherwise (fact #123).

Usage:

    python tools/xferproof.py --dll PATH        run against one built tarkov.dll
    python tools/xferproof.py --dll A --mutant B
                                                run both; A must PASS and B must
                                                FAIL, and a mutant that PASSES is
                                                itself a failure of this tool

Exit code 0 only when every expectation held.
"""

import argparse
import http.client
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 6973
ROOT = os.path.join(os.environ.get("TEMP", "/tmp"), "xferproof")
LIVE_DB = r"D:\Aowlspt\aowlspt\db.json"

TARKOV_ENTRY = {
    "id": "aowl.tarkov", "name": "Tarkov server emulator",
    "author": "aowlspt", "version": "1.0.0", "sides": ["server"],
    "provides": [],
}

# Two ordinary items with real template ids out of the database. Their `_id`s
# are minted here so that a hit on them in the saved profile can only have come
# from this request.
CARRIED = [
    {"_id": "aowlxferproof000000000a1", "_tpl": "5449016a4bdc2d6f028b456f",
     "parentId": "aowlxferproofcontainer0", "slotId": "main",
     "upd": {"StackObjectsCount": 12345}},
    {"_id": "aowlxferproof000000000a2", "_tpl": "590c657e86f77412b013051d",
     "parentId": "aowlxferproofcontainer0", "slotId": "main"},
]


def stage(dll):
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, "mods", "tarkov"))
    os.makedirs(os.path.join(ROOT, "registry"))
    shutil.copy(os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe"),
                os.path.join(ROOT, "aowlspt-backend.exe"))
    if not os.path.isfile(LIVE_DB):
        raise SystemExit("INCONCLUSIVE: no database at %s, so the emulator "
                         "cannot boot and nothing was proved" % LIVE_DB)
    shutil.copy(LIVE_DB, os.path.join(ROOT, "db.json"))
    shutil.copy(dll, os.path.join(ROOT, "mods", "tarkov", "tarkov.dll"))
    with open(os.path.join(ROOT, "registry", "mods.json"), "w") as f:
        json.dump({"schema": "aowlspt.registry/1",
                   "registry": {"id": "xferproof", "name": "transfer proof",
                                "revision": 1},
                   "mods": [TARKOV_ENTRY]}, f, indent=2)
    with open(os.path.join(ROOT, "mods", "aowlspt-selection.json"), "w") as f:
        json.dump({"schema": "aowlspt.selection/1", "writtenBy": "xferproof",
                   "side": "server",
                   "registry": os.path.join(ROOT, "registry", "mods.json"),
                   "load": ["aowl.tarkov"]}, f)


def call(path, body=None, token=None):
    """One request, strictly parsed. Returns (status, doc)."""
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path),
                                 data=data, method="POST" if data else "GET")
    req.add_header("Accept-Encoding", "identity")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Cookie", "PHPSESSID=" + token)
    # A 404 is an ANSWER here, not an exception: "this route is not served" is
    # exactly the finding some of these checks are looking for, and letting
    # urllib raise would turn a FAIL into a crash with no verdict.
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read().decode("utf-8", "replace")
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        status = e.code
    try:
        return status, json.loads(raw)            # STRICT
    except ValueError as e:
        raise AssertionError("%s answered something that is not JSON (%s): %r"
                             % (path, e, raw[:300]))


class Backend(object):
    def __enter__(self):
        self.p = subprocess.Popen(
            [os.path.join(ROOT, "aowlspt-backend.exe"),
             "--root", ROOT, "--port", str(PORT), "--no-store-lock"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            cwd=ROOT, universal_newlines=True, encoding="utf-8",
            errors="replace")
        deadline = time.time() + 240
        while time.time() < deadline:
            if self.p.poll() is not None:
                raise RuntimeError("backend exited during startup:\n"
                                   + self.p.stdout.read()[-3000:])
            try:
                call("/aowlspt/tarkov/launcher/profiles", {})
                return self
            except Exception:
                time.sleep(0.5)
        raise RuntimeError("backend never answered on port %d" % PORT)

    def __exit__(self, *a):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()


def ids_reachable(token, profile_id):
    """Every item id the player can reach: the stash, and the mailbox.

    Two INDEPENDENT reads, neither of them the request that wrote anything.
    """
    seen = set()
    _, prof = call("/client/game/profile/list", {}, token)
    for doc in (prof.get("data") or []):
        for item in ((doc.get("Inventory") or {}).get("items") or []):
            if isinstance(item, dict) and item.get("_id"):
                seen.add(item["_id"])
    _, mail = call("/client/mail/dialog/getAllAttachments", {}, token)
    for msg in ((mail.get("data") or {}).get("messages") or []):
        for item in ((msg.get("items") or {}).get("data") or []):
            if isinstance(item, dict) and item.get("_id"):
                seen.add(item["_id"])
    return seen


def run(dll, label):
    """Returns (verdict, detail). verdict is PASS / FAIL / INCONCLUSIVE."""
    stage(dll)
    with Backend():
        st, made = call("/aowlspt/tarkov/launcher/profile/create",
                        {"nickname": "XferProof", "side": "Bear"})
        if not made.get("ok"):
            return "INCONCLUSIVE", "could not create a profile: %r" % made
        token = made.get("token") or ""
        pid = (made.get("profile") or {}).get("id") or token
        if not token:
            return "INCONCLUSIVE", "the launcher returned no token: %r" % made

        st, prof = call("/client/game/profile/list", {}, token)
        pmc = None
        for doc in (prof.get("data") or []):
            if doc.get("_id") == pid:
                pmc = doc
        if pmc is None:
            return "INCONCLUSIVE", ("profile/list did not contain %s, so the "
                                    "raid body could not be built" % pid)

        before = ids_reachable(token, pid)
        for it in CARRIED:
            if it["_id"] in before:
                return "INCONCLUSIVE", ("%s was already reachable before the "
                                        "raid; the check would pass for the "
                                        "wrong reason" % it["_id"])

        # The raid ends. `results.profile` is the profile the client played
        # with -- which does NOT contain the transferred items, exactly as a
        # real client's would not, because handing them over is what took them
        # off the character.
        st, _ = call("/client/match/local/end", {
            "serverId": "XFERPROOF_1_20_08_2026_01_20_33",
            "results": {"profile": pmc, "result": "Survived",
                        "killerId": "", "killerAid": "", "exitName": "RUAF",
                        "inSession": True, "favorite": False, "playTime": 120},
            "lostInsuredItems": [],
            "transferItems": {pid: CARRIED},
            "locationTransit": None,
        }, token)

        after = ids_reachable(token, pid)

    missing = [it["_id"] for it in CARRIED if it["_id"] not in after]
    if missing:
        return "FAIL", ("%d of %d transferred item(s) are in neither the stash "
                        "nor the mailbox after the raid: %s"
                        % (len(missing), len(CARRIED), ", ".join(missing)))
    return "PASS", ("all %d transferred item(s) are reachable after the raid"
                    % len(CARRIED))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll", required=True,
                    help="the FIXED tarkov.dll; must PASS")
    ap.add_argument("--mutant",
                    help="a tarkov.dll built with the splice removed; must FAIL")
    args = ap.parse_args()

    ok = True
    verdict, detail = run(args.dll, "fixed")
    print("[%s] fixed build -- %s" % (verdict, detail))
    if verdict != "PASS":
        ok = False

    if args.mutant:
        verdict, detail = run(args.mutant, "mutant")
        print("[%s] mutant build (splice removed) -- %s" % (verdict, detail))
        if verdict == "PASS":
            print("      A MUTANT THAT PASSES MEANS THE CHECK CANNOT FAIL, "
                  "which is the bug this file exists to avoid.")
            ok = False
        elif verdict != "FAIL":
            ok = False

    print("RESULT:", "ok" if ok else "not ok")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
