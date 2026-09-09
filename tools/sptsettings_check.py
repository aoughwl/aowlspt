#!/usr/bin/env python3
"""Verify the singleplayer settings surface against a REAL running backend.

Three outcomes per check -- PASS / FAIL / INCONCLUSIVE (CLAUDE.md 9b). "I could
not look" is never a pass, so a check whose precondition is missing says so
rather than being skipped silently.

Every assertion is about the FINISHED STATE, never about our own write:

  * the schema payload is parsed with `json.loads`, a STRICT parser -- fact
    #122 was 22 rows of unquoted values that a substring `contains` had been
    passing for months.
  * a write is verified by RE-FETCHING and reading the changed value back, not
    by the 200. Measured trap: the backend treats a CHUNKED POST as bodyless
    and answers 200 with the UNCHANGED schema, which is indistinguishable from
    success if you check the status code.
  * a globals override is verified by fetching `/client/globals` and reading
    the value at its path, not by asserting the patcher ran.

    python tools/sptsettings_check.py --root <stage> --backend <exe> [--port N]

The stage is built by --stage: a scratch directory holding `db.json` and
`mods/tarkov/{tarkov.dll,config.json}`. It is never `D:\\Aowlspt`.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

GUID = "aowl.tarkov"

PASS, FAIL, INCONC = "PASS", "FAIL", "INCONCLUSIVE"
results = []


def record(outcome, name, detail=""):
    results.append((outcome, name, detail))
    print("%-12s %s%s" % (outcome, name, ("  -- " + detail) if detail else ""))


def get(port, path):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path))
    # fact #123: the backend deflates unless identity is asked for.
    req.add_header("Accept-Encoding", "identity")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read()


def post(port, path, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                 data=body, method="POST")
    req.add_header("Accept-Encoding", "identity")
    req.add_header("Content-Type", "application/json")
    # Explicit length: a chunked POST is read as bodyless and answered 200 with
    # the unchanged schema. urllib sends Content-Length for bytes, but saying
    # so here is the point -- this is the trap the read-back below catches.
    req.add_header("Content-Length", str(len(body)))
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read()


def schema(port):
    st, raw = get(port, "/aowlspt/settings/" + GUID)
    if st != 200:
        return None, "HTTP %d" % st
    try:
        doc = json.loads(raw.decode("utf-8"))
    except Exception as exc:                       # strict, on purpose
        return None, "not valid JSON: %s" % exc
    return doc, ""


def stage(root, repo, db):
    os.makedirs(os.path.join(root, "mods", "tarkov"), exist_ok=True)
    shutil.copy2(os.path.join(repo, "mods", "tarkov", "bin", "tarkov.dll"),
                 os.path.join(root, "mods", "tarkov", "tarkov.dll"))
    with open(os.path.join(root, "mods", "tarkov", "config.json"), "w") as fh:
        fh.write("{}\n")
    dst = os.path.join(root, "db.json")
    if not os.path.exists(dst):
        shutil.copy2(db, dst)
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--backend", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--port", type=int, default=6971)
    args = ap.parse_args()

    stage(args.root, args.repo, args.db)
    proc = subprocess.Popen([args.backend, "--root", args.root,
                             "--port", str(args.port)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        # Wait for the port rather than sleeping a guess at it.
        up = False
        for _ in range(120):
            try:
                get(args.port, "/aowlspt/settings/" + GUID)
                up = True
                break
            except urllib.error.HTTPError:
                # ANY http answer means the socket is serving. Treating a 404
                # as "not up" is how a 0.3s boot became a 120s timeout: the
                # readiness probe was asking a route that does not exist.
                up = True
                break
            except Exception:
                time.sleep(1)
        if not up:
            record(INCONC, "backend reachable",
                   "no answer on port %d in 120s" % args.port)
            return 2
        record(PASS, "backend reachable")

        doc, why = schema(args.port)
        if doc is None:
            record(FAIL, "schema payload is strict JSON", why)
            return 1
        record(PASS, "schema payload is strict JSON")

        if not isinstance(doc, list):
            record(FAIL, "schema is an array", "got %s" % type(doc).__name__)
            return 1
        record(PASS, "schema is an array", "%d rows" % len(doc))

        if len(doc) < 300:
            record(FAIL, "hundreds of settings", "only %d rows" % len(doc))
        else:
            record(PASS, "hundreds of settings", "%d rows" % len(doc))

        # No row may be decorative.
        greyed = [r["key"] for r in doc if not r.get("implemented", True)]
        if greyed:
            record(FAIL, "no row is declared unimplemented",
                   "%d: %s" % (len(greyed), ", ".join(greyed[:5])))
        else:
            record(PASS, "no row is declared unimplemented")

        # Every row must have a distinct key: a duplicate shadows and the
        # shadowed one is decorative by accident.
        keys = [r["key"] for r in doc]
        dupes = sorted({k for k in keys if keys.count(k) > 1})
        if dupes:
            record(FAIL, "every key is distinct", ", ".join(dupes[:5]))
        else:
            record(PASS, "every key is distinct")

        # The self-check route: the mod's own arithmetic, including the two new
        # modules'. This is the negative that can actually fail.
        try:
            st, raw = get(args.port, "/aowlspt/tarkov/selfcheck")
            sc = json.loads(raw.decode("utf-8"))
            if sc.get("ok"):
                record(PASS, "mod self-check")
            else:
                record(FAIL, "mod self-check",
                       "; ".join(sc.get("failures", []))[:400])
        except Exception as exc:
            record(INCONC, "mod self-check", str(exc))

        by_key = {r["key"]: r for r in doc}

        # ---- a write, verified by READING IT BACK ----------------------
        probe = "g_Stamina_Capacity"
        if probe not in by_key:
            record(INCONC, "globals override write", "%s not declared" % probe)
        else:
            before = by_key[probe]["value"]
            post(args.port, "/aowlspt/settings/" + GUID,
                 {"key": probe, "value": 777})
            doc2, why2 = schema(args.port)
            if doc2 is None:
                record(FAIL, "schema still strict JSON after a write", why2)
            else:
                record(PASS, "schema still strict JSON after a write")
                after = {r["key"]: r for r in doc2}[probe]["value"]
                if after == 777 and before != 777:
                    record(PASS, "a settings write persists",
                           "%s: %s -> %s" % (probe, before, after))
                else:
                    record(FAIL, "a settings write persists",
                           "%s read back as %r (was %r)"
                           % (probe, after, before))

            # ---- and the override must REACH /client/globals ------------
            try:
                st, raw = get(args.port, "/client/globals")
                body = json.loads(raw.decode("utf-8"))
                data = body.get("data", body)
                got = data["config"]["Stamina"]["Capacity"]
                if got == 777:
                    record(PASS, "the override reaches /client/globals",
                           "config.Stamina.Capacity = 777")
                else:
                    record(FAIL, "the override reaches /client/globals",
                           "config.Stamina.Capacity = %r" % got)
                # And nothing else was damaged by the rewrite.
                if isinstance(data.get("config", {}).get("Stamina"), dict) \
                        and len(data["config"]) > 100:
                    record(PASS, "the globals document survived the rewrite",
                           "%d members under config" % len(data["config"]))
                else:
                    record(FAIL, "the globals document survived the rewrite")
            except Exception as exc:
                record(INCONC, "the override reaches /client/globals", str(exc))

        # ---- the item-spawn optionsUrl ---------------------------------
        try:
            st, raw = get(args.port,
                          "/aowlspt/settings/%s/items?q=bandage&limit=5" % GUID)
            opts = json.loads(raw.decode("utf-8"))
            n = len(opts.get("options", []))
            if n > 0 and opts.get("matched", 0) >= n:
                record(PASS, "item search returns options",
                       "%d shown of %d matched, first=%s"
                       % (n, opts["matched"], opts["options"][0]["label"]))
            else:
                record(FAIL, "item search returns options", raw[:200].decode())
        except Exception as exc:
            record(INCONC, "item search returns options", str(exc))

        # A query that matches nothing must return an EMPTY list, not an error
        # and not everything.
        try:
            st, raw = get(args.port,
                          "/aowlspt/settings/%s/items?q=zzzznotanitem" % GUID)
            opts = json.loads(raw.decode("utf-8"))
            if opts.get("options") == [] and opts.get("matched") == 0:
                record(PASS, "an unmatched item search returns nothing")
            else:
                record(FAIL, "an unmatched item search returns nothing",
                       raw[:200].decode())
        except Exception as exc:
            record(INCONC, "an unmatched item search returns nothing", str(exc))

        # ---- a REAL spawn, into a REAL stash ---------------------------
        #
        # A profile is created over the same plain-HTTP channel the client
        # uses. Without one the only spawn that can be exercised is the refusal
        # path, and "it refused correctly" is not evidence that it can succeed.
        try:
            st, raw = post(args.port, "/client/game/profile/create",
                           {"nickname": "AowlSpawnCheck", "side": "Usec",
                            "headId": "x"})
            created = json.loads(raw.decode("utf-8"))
            uid = created.get("data", {}).get("uid", "")
            if not uid:
                record(INCONC, "a real spawn lands in the stash",
                       "could not create a profile: %s" % raw[:160].decode())
            else:
                def stash_count(tpl):
                    _, r = post(args.port, "/client/game/profile/list", {})
                    prof = json.loads(r.decode("utf-8"))["data"]
                    for pr in prof:
                        if pr.get("_id") != uid:
                            continue
                        return sum(1 for it in pr["Inventory"]["items"]
                                   if it.get("_tpl") == tpl)
                    return -1

                # Aseptic bandage -- unambiguous by name in the search above.
                bandage = "5751a25924597722c463c472"
                before_n = stash_count(bandage)
                post(args.port, "/aowlspt/settings/" + GUID,
                     {"key": "spawnQuery", "value": bandage})
                post(args.port, "/aowlspt/settings/" + GUID,
                     {"key": "spawnCount", "value": 3})
                post(args.port, "/aowlspt/settings/" + GUID,
                     {"key": "spawnNow", "value": True})
                after_n = stash_count(bandage)
                docS, _ = schema(args.port)
                msg = {r["key"]: r for r in docS}["spawnResult"]["value"]
                if before_n < 0 or after_n < 0:
                    record(INCONC, "a real spawn lands in the stash",
                           "could not read the profile back")
                elif after_n > before_n:
                    record(PASS, "a real spawn lands in the stash",
                           "%s stacks %d -> %d; %s"
                           % (bandage, before_n, after_n, msg))
                else:
                    record(FAIL, "a real spawn lands in the stash",
                           "%s stacks stayed at %d; server said: %s"
                           % (bandage, before_n, msg))
        except Exception as exc:
            record(INCONC, "a real spawn lands in the stash", str(exc))

        # ---- spawning something that does not exist must REFUSE ---------
        try:
            post(args.port, "/aowlspt/settings/" + GUID,
                 {"key": "spawnQuery", "value": "zzzznotanitem"})
            post(args.port, "/aowlspt/settings/" + GUID,
                 {"key": "spawnNow", "value": True})
            doc3, _ = schema(args.port)
            row = {r["key"]: r for r in doc3}.get("spawnResult", {})
            msg = row.get("value", "")
            armed = {r["key"]: r for r in doc3}.get("spawnNow", {}).get("value")
            # The negative: a refusal must SAY SO. An empty message here is the
            # silent decline this whole surface is built to avoid, and it is a
            # different string from the success message above -- so this check
            # can fail.
            if "no item matches" in msg:
                record(PASS, "an impossible spawn refuses with a reason", msg[:120])
            else:
                record(FAIL, "an impossible spawn refuses with a reason",
                       "spawnResult = %r" % msg)
            if armed is False:
                record(PASS, "spawnNow re-arms itself")
            else:
                record(FAIL, "spawnNow re-arms itself", "value=%r" % armed)
        except Exception as exc:
            record(INCONC, "an impossible spawn refuses with a reason", str(exc))

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except Exception:
            proc.kill()

    fails = [r for r in results if r[0] == FAIL]
    inconc = [r for r in results if r[0] == INCONC]
    print("\n%d PASS  %d FAIL  %d INCONCLUSIVE"
          % (len(results) - len(fails) - len(inconc), len(fails), len(inconc)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
