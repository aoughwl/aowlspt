"""Mutation proof for the mod-to-mod capability facility.

Runs the STANDALONE backend (no game client, no TLS -- the cheapest rung) over a
scratch install root, and drives `examples/capconsumer`'s route through four
worlds that differ by ONE fact each:

  1 both mods loaded            -> outcome must be "ok" and applied true
  2 provider dll present, in the registry, REMOVED FROM THE SELECTION
                                -> "provider-not-loaded", applied false
  3 provider dll and registry entry both gone
                                -> "no-provider", applied false
  4 provider loaded, consumer asks for version 2
                                -> "version-mismatch", applied false, versions [1]
  5 consumer sends a malformed request
                                -> refused before it reaches the wire

Every response is parsed with json.loads (STRICT), never with a substring test:
the backend's own selftest asserted with `contains` for months and let a payload
that was not JSON at all pass. A 200 proves nothing here -- the route answers 200
for every refusal on purpose -- so the assertion is on `outcome`/`applied`.

  python tools/capproof.py            build the root from bin/, run all five
  python tools/capproof.py --keep     leave the scratch root behind
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.join(os.environ.get("TEMP", "/tmp"), "capproof")
PORT = 6971

PROVIDER_ENTRY = {
    "id": "aowl.capprovider", "name": "Capability provider example",
    "author": "aowlspt", "version": "1.0.0", "sides": ["server", "sim"],
    "provides": ["items.spawn/1"],
}
CONSUMER_ENTRY = {
    "id": "aowl.capconsumer", "name": "Capability consumer example",
    "author": "aowlspt", "version": "1.0.0", "sides": ["server", "sim"],
    "provides": [],
}


def stage(with_provider_dll=True, with_provider_registry=True,
          with_provider_selected=True):
    """Build the scratch root. Each flag is one of the three loading gates."""
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, "mods", "capconsumer"))
    os.makedirs(os.path.join(ROOT, "registry"))
    shutil.copy(os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe"),
                os.path.join(ROOT, "aowlspt-backend.exe"))
    shutil.copy(os.path.join(REPO, "examples", "backend", "testdb.json"),
                os.path.join(ROOT, "db.json"))
    shutil.copy(os.path.join(REPO, "examples", "capconsumer", "bin",
                             "capconsumer.dll"),
                os.path.join(ROOT, "mods", "capconsumer", "capconsumer.dll"))
    if with_provider_dll:
        os.makedirs(os.path.join(ROOT, "mods", "capprovider"))
        shutil.copy(os.path.join(REPO, "examples", "capprovider", "bin",
                                 "capprovider.dll"),
                    os.path.join(ROOT, "mods", "capprovider",
                                 "capprovider.dll"))
    mods = ([PROVIDER_ENTRY] if with_provider_registry else []) + [CONSUMER_ENTRY]
    reg = {"schema": "aowlspt.registry/1",
           "registry": {"id": "capproof", "name": "capability proof",
                        "revision": 1},
           "mods": mods}
    with open(os.path.join(ROOT, "registry", "mods.json"), "w") as f:
        json.dump(reg, f, indent=2)
    load = (["aowl.capprovider"] if with_provider_selected else []) + \
           ["aowl.capconsumer"]
    sel = {"schema": "aowlspt.selection/1", "writtenBy": "capproof",
           "side": "server",
           "registry": os.path.join(ROOT, "registry", "mods.json"),
           "load": load}
    with open(os.path.join(ROOT, "mods", "aowlspt-selection.json"), "w") as f:
        json.dump(sel, f)


def fetch(path):
    """One request. `Accept-Encoding: identity` because the backend ALWAYS
    deflates otherwise (fact #123) and a deflated body is not a readable one.
    The body is parsed strictly; a parse failure is a FAIL, not a warning."""
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path))
    req.add_header("Accept-Encoding", "identity")
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read().decode("utf-8", "replace")
        return r.status, raw


class Backend(object):
    def __init__(self):
        self.p = None

    def __enter__(self):
        # NOT Start-Process/detached: a detached standalone backend exits
        # silently with no shutdown line in the log. Held as a child instead.
        self.p = subprocess.Popen(
            [os.path.join(ROOT, "aowlspt-backend.exe"),
             "--root", ROOT, "--port", str(PORT), "--no-store-lock"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            cwd=ROOT, universal_newlines=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.p.poll() is not None:
                raise RuntimeError("backend exited during startup:\n" +
                                   self.p.stdout.read())
            try:
                fetch("/aowlspt/capdemo")
                return self
            except Exception:
                time.sleep(0.3)
        raise RuntimeError("backend never answered on port %d" % PORT)

    def __exit__(self, *a):
        if self.p and self.p.poll() is None:
            self.p.kill()
            self.p.wait()


results = []


def check(label, path, want_outcome, want_applied, extra=None):
    status, raw = fetch(path)
    try:
        doc = json.loads(raw)          # STRICT. No substring test anywhere.
    except ValueError as e:
        results.append(("FAIL", label,
                        "response is not valid JSON (%s): %r" % (e, raw[:200])))
        return
    if not isinstance(doc, dict) or "outcome" not in doc or "applied" not in doc:
        results.append(("FAIL", label, "envelope missing outcome/applied: %r"
                        % raw[:200]))
        return
    if doc["outcome"] != want_outcome or doc["applied"] is not want_applied:
        results.append(("FAIL", label,
                        "wanted outcome=%s applied=%s, got outcome=%s "
                        "applied=%s -- %s" % (want_outcome, want_applied,
                                              doc["outcome"], doc["applied"],
                                              doc.get("message", ""))))
        return
    if want_applied and doc.get("result") is None:
        results.append(("FAIL", label,
                        "applied is true and there is no provider result"))
        return
    if not want_applied and doc.get("result") is not None:
        results.append(("FAIL", label,
                        "applied is false and a result came back anyway"))
        return
    if not want_applied and not doc.get("message"):
        results.append(("FAIL", label, "a refusal with no message"))
        return
    if extra:
        bad = extra(doc)
        if bad:
            results.append(("FAIL", label, bad))
            return
    results.append(("PASS", label, doc.get("message") or
                    json.dumps(doc.get("result"))))


def main():
    # --- world 1: everything present -------------------------------------
    stage()
    with Backend():
        check("1 provider loaded -> the call APPLIES", "/aowlspt/capdemo",
              "ok", True,
              lambda d: None if d["result"].get("spawned") == 243 else
              "wanted spawned=243, got %r" % d["result"].get("spawned"))
        # --- world 4 rides the same backend: same provider, wrong version --
        check("4 wrong version -> version-mismatch", "/aowlspt/capdemo?v=2",
              "version-mismatch", False,
              lambda d: None if d["versions"] == [1] else
              "wanted versions [1], got %r" % (d["versions"],))
        # --- world 5: the consumer's own request is malformed --------------
        check("5 malformed request -> refused before the wire",
              "/aowlspt/capdemo?bad=1", "unavailable", False)

    # --- world 2: dll on disk, in the registry, NOT in the selection ------
    stage(with_provider_dll=True, with_provider_registry=True,
          with_provider_selected=False)
    with Backend():
        check("2 installed but not selected -> provider-not-loaded",
              "/aowlspt/capdemo", "provider-not-loaded", False,
              lambda d: None if "switched off" in d["message"] else
              "the refusal does not say it is switched off: " + d["message"])

    # --- world 3: not installed at all ------------------------------------
    stage(with_provider_dll=False, with_provider_registry=False,
          with_provider_selected=False)
    with Backend():
        check("3 not installed -> no-provider", "/aowlspt/capdemo",
              "no-provider", False,
              lambda d: None if "no installed mod declares" in d["message"]
              else "the refusal does not say it is uninstalled: " +
                   d["message"])

    width = max(len(r[1]) for r in results)
    failed = 0
    for verdict, label, note in results:
        if verdict != "PASS":
            failed += 1
        print("%-4s  %-*s  %s" % (verdict, width, label, note[:140]))
    print("")
    print("%d/%d PASS" % (len(results) - failed, len(results)))
    if "--keep" not in sys.argv:
        shutil.rmtree(ROOT, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
