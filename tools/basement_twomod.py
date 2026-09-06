#!/usr/bin/env python3
r"""basement_twomod.py -- prove the CROSS-MOD planting path with a real backend.

    python tools\basement_twomod.py [--keep] [--db PATH] [--map Woods]

Why this exists: `aowlspt-sim` delivers an emit to every subscriber EXCEPT
those in the emitting mod (host/Aowlspt.Sim/aowlsim.nim:540), so neither
mods/tarkov's nor mods/basement's own selfcheck can prove that

    tarkov  --tarkov.loot.compose-->  basement
    basement --tarkov.loot.plant--->  tarkov   (from INSIDE the handler)

actually lands a basement cache item in the loose loot tarkov serves. Only a
backend running BOTH mods can. This stages one (the betacheck.py recipe),
generates a world, asks tarkov for the map's loot, and asserts:

  PASS  every `placed` loot item basement reports for the map is in the
        served loose-loot array at its planted position with its tpl
  PASS  (negative) a map basement holds NO loot for gains no planted item
  INCONCLUSIVE when a piece is missing (no backend, no DLL, basement has no
        loot on any map because the item resolver had no usable db, ...)

Exit 0 PASS, 1 FAIL, 3 INCONCLUSIVE. Nothing here touches D:\Aowlspt.
"""
import argparse
import atexit
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, "backend", "bin", "aowlspt-backend.exe")
TARKOV = os.path.join(REPO, "mods", "tarkov", "bin", "tarkov.dll")
BASEMENT = os.path.join(REPO, "mods", "basement", "bin", "basement.dll")
FIXTURE = os.path.join(REPO, "tests", "fixtures", "emu-full.json")

PASS, FAIL, INC = "PASS", "FAIL", "INCONCLUSIVE"
verdicts = []


def say(v, name, detail):
    verdicts.append(v)
    print("%-12s %s -- %s" % (v, name, detail))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def stage(db):
    root = tempfile.mkdtemp(prefix="basement-twomod-")
    for name, dll, cfg_dir in (("tarkov", TARKOV, os.path.join(REPO, "mods", "tarkov")),
                               ("basement", BASEMENT, os.path.join(REPO, "mods", "basement"))):
        d = os.path.join(root, "mods", name)
        os.makedirs(d)
        shutil.copy2(dll, os.path.join(d, os.path.basename(dll)))
        data = os.path.join(cfg_dir, "data")
        if os.path.isdir(data):
            shutil.copytree(data, os.path.join(d, "data"), dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("cache"))
    with open(os.path.join(root, "mods", "tarkov", "config.json"), "w", newline="\n") as f:
        f.write("{}\n")
    # basement must be ON, with every subprocess-spawning engine OFF: this
    # proves the bus path, not whisper or piper.
    cfg = json.load(open(os.path.join(REPO, "mods", "basement", "config.json"), encoding="utf-8"))
    cfg["enabled"] = True
    for k in ("sttEngine", "ttsEngine"):
        if k in cfg:
            cfg[k] = "none"
    if "llmEngine" in cfg:
        cfg["llmEngine"] = "builtin"
    with open(os.path.join(root, "mods", "basement", "config.json"), "w", newline="\n") as f:
        json.dump(cfg, f, indent=1)
    reg = os.path.join(root, "registry")
    os.makedirs(reg)
    mods = [{"id": "aowl.tarkov", "name": "Tarkov server emulator", "author": "aowlspt",
             "version": "1.0.0", "sides": ["server"], "provides": []},
            {"id": "aowl.basement", "name": "Escape From My Basement", "author": "savannt",
             "version": "0.1.0", "sides": ["server"], "provides": [],
             "loadAfter": ["aowl.tarkov"]}]
    with open(os.path.join(reg, "mods.json"), "w", newline="\n") as f:
        json.dump({"schema": "aowlspt.registry/1",
                   "registry": {"id": "twomod", "name": "basement twomod", "revision": 1},
                   "mods": mods}, f, indent=2)
    with open(os.path.join(root, "mods", "aowlspt-selection.json"), "w", newline="\n") as f:
        json.dump({"schema": "aowlspt.selection/1", "writtenBy": "basement_twomod",
                   "side": "server", "registry": os.path.join(reg, "mods.json"),
                   "load": ["aowl.tarkov", "aowl.basement"]}, f)
    shutil.copy2(db, os.path.join(root, "db.json"))
    local = os.path.join(root, os.path.basename(BACKEND))
    shutil.copy2(BACKEND, local)
    return root, local


class Wire:
    def __init__(self, port):
        self.port = port

    def call(self, path, body=None, method="POST", timeout=60):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        payload = b"" if body is None else json.dumps(body).encode()
        # No cookie: the backend answers 400 "bad session id" to a made-up
        # PHPSESSID (measured 2026-09-06), and none of these routes needs one.
        c.request(method, path, payload, {"Accept-Encoding": "identity",
                                          "Content-Type": "application/json"})
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


def unwrap(doc):
    if isinstance(doc, dict) and "data" in doc and "err" in doc:
        return doc["data"]
    return doc


def positions(loose):
    """{itemId: (tpl, x, y, z)} over the served loose-loot array."""
    out = {}
    for entry in loose or []:
        items = entry.get("Items") or []
        pos = entry.get("Position") or {}
        for it in items:
            out[it.get("_id")] = (it.get("_tpl"),
                                  round(float(pos.get("x", 0)), 3),
                                  round(float(pos.get("y", 0)), 3),
                                  round(float(pos.get("z", 0)), 3))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=FIXTURE)
    ap.add_argument("--map", default="Woods")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    for p, how in ((BACKEND, "aowl build backend"), (TARKOV, "buildlock build mod tarkov"),
                   (BASEMENT, "buildlock build-mod mods\\basement"), (a.db, "--db PATH")):
        if not os.path.isfile(p):
            say(INC, "prerequisite", "%s is missing (%s)" % (p, how))
            return 3

    root, local = stage(a.db)
    port = free_port()
    log = open(os.path.join(root, "backend.log"), "wb")
    proc = subprocess.Popen([local, "--root", root, "--port", str(port), "--no-store-lock"],
                            cwd=root, stdout=log, stderr=subprocess.STDOUT)

    def teardown():
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()
        if a.keep:
            print("kept: %s" % root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    atexit.register(teardown)

    w = Wire(port)
    # Wait for the SOCKET first (any HTTP answer, a 404 included), the way
    # betacheck.py does; a backend that holds requests while mods warm would
    # otherwise eat the whole deadline inside one blocked call.
    deadline = time.time() + 180
    status = None
    last = ""
    while time.time() < deadline and proc.poll() is None:
        try:
            st, doc, text = w.call("/aowlspt/basement/status", method="GET", timeout=5)
            last = "%s %s" % (st, text[:200])
            if st == 200 and isinstance(doc, dict):
                status = doc
                break
        except Exception as exc:  # noqa: BLE001
            last = repr(exc)
        time.sleep(1.0)
    if status is None:
        say(INC, "backend", "no /aowlspt/basement/status within 180 s (backend exit %r, last: %s); "
            "log: %s" % (proc.poll(), last, os.path.join(root, "aowlspt-backend.log")))
        a.keep = True
        return 3
    if not status.get("enabled", False):
        say(INC, "basement", "mod loaded but reports enabled=false: %s" % json.dumps(status)[:300])
        return 3

    st, doc, text = w.call("/aowlspt/basement/world/new",
                           {"preset": "warlords", "seed": a.seed})
    if st != 200 or not isinstance(doc, dict) or not doc.get("ok", True):
        say(FAIL, "world/new", "%s %s" % (st, text[:300]))
        return 1

    # Loot rows exist only once a SCENE has materialised a cache (DESIGN §11):
    # pick a cache on the requested map, materialise the scene at it, then
    # read the placed rows back.
    st, caches, text = w.call("/aowlspt/basement/world/caches", method="GET")
    clist = caches.get("caches", caches) if isinstance(caches, dict) else caches
    onmap = [c for c in (clist or []) if c.get("map") == a.map]
    if not onmap:
        maps = sorted(set(c.get("map", "?") for c in (clist or [])))
        say(INC, "basement caches", "no cache on %s for seed %d; caches exist on %s (pass --map)"
            % (a.map, a.seed, maps))
        return 3
    c0 = onmap[0]
    st, scene, text = w.call("/aowlspt/basement/world/scene?map=%s&x=%s&y=%s&z=%s&radius=60"
                             % (a.map, c0.get("x", 0), c0.get("y", 0), c0.get("z", 0)), method="GET")
    st, loot, text = w.call("/aowlspt/basement/world/loot?map=%s" % a.map, method="GET")
    rows = loot.get("loot", loot.get("items", [])) if isinstance(loot, dict) else (loot or [])
    items = [i for i in rows if i.get("status", "placed") == "placed"]
    if not items:
        say(INC, "basement loot", "scene at cache %s materialised nothing placed on %s (scene: %s; loot: %s)"
            % (c0.get("id"), a.map, json.dumps(scene)[:200], text[:200]))
        return 3

    st, served, text = w.call("/client/location/getLocalloot", {"locationId": a.map})
    body = unwrap(served)
    loose = None
    if isinstance(body, dict):
        loose = body.get("Loot") if "Loot" in body else body.get("loot")
        if loose is None and "Location" in body:
            loose = body["Location"].get("Loot")
    if not isinstance(loose, list):
        say(INC, "getLocalloot", "no loose-loot array in the reply (%s): %s" % (st, text[:300]))
        return 3
    have = positions(loose)
    missing = []
    for it in items:
        iid = it.get("id")
        want = (it.get("tpl"), round(float(it.get("x", 0)), 3), round(float(it.get("y", 0)), 3),
                round(float(it.get("z", 0)), 3))
        got = have.get(iid)
        if got != want:
            missing.append("%s want %s got %s" % (iid, want, got))
    if missing:
        say(FAIL, "planted in served loot", "%d of %d basement item(s) NOT served as planted: %s"
            % (len(missing), len(items), "; ".join(missing[:5])))
    else:
        say(PASS, "planted in served loot", "%d basement item(s) present at their planted "
            "positions among %d served loose entries" % (len(items), len(loose)))

    # negative control: a map basement has nothing on gains nothing of ours
    other = "factory4_day" if a.map != "factory4_day" else "Woods"
    st, oloot, _ = w.call("/aowlspt/basement/world/loot?map=%s" % other, method="GET")
    oitems = (oloot.get("loot", oloot.get("items", [])) if isinstance(oloot, dict) else oloot) or []
    if oitems:
        say(INC, "negative control", "basement also holds loot on %s; pick a map it does not "
            "(--map)" % other)
    else:
        st, served2, text2 = w.call("/client/location/getLocalloot", {"locationId": other})
        body2 = unwrap(served2)
        loose2 = body2.get("Loot") if isinstance(body2, dict) else None
        if not isinstance(loose2, list):
            say(INC, "negative control", "no loose-loot array for %s" % other)
        else:
            ours = set(i.get("id") for i in items)
            leaked = [i for i in positions(loose2) if i in ours]
            say(FAIL if leaked else PASS, "negative control",
                "%d basement item id(s) from %s leaked into %s" % (len(leaked), a.map, other)
                if leaked else "none of %s's planted ids appear in %s" % (a.map, other))

    worst = FAIL if FAIL in verdicts else (INC if INC in verdicts else PASS)
    print("BASEMENT TWOMOD %s" % worst)
    return {PASS: 0, FAIL: 1, INC: 3}[worst]


if __name__ == "__main__":
    sys.exit(main())
