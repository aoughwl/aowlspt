#!/usr/bin/env python3
"""Time the SERVER share of the client's raid-load path, route by route.

Why this exists: the client's own `*_backend_000.log` reports DownloadSeconds
per request, but only for a real launch (~161 s, a human at the profile
screen). This drives the SAME routes, in the same order, against a real
backend + the real mods/tarkov/bin/tarkov.dll + the real 41 MB db.json, over
plain HTTP on a scratch port -- no client, no TLS, no game.

It reports FIRST-HIT and SECOND-HIT time separately, because that difference
is the whole subject: first hit pays serialization + deflate, second hit pays
the compressed-body cache hit only.

    python tools/loadpathbench.py --backend backend/bin/aowlspt-backend.exe \
        --root <scratch-root> --port 7969 --label before

Never reads db.json or the backend log into this process's output; it prints
one line per route.
"""
import argparse
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import time
import zlib

SESSION_DEFAULT = "00000000000a00000000004f"

# The load path, in the order the client's backend log shows it. `post` marks a
# request the client sends as POST with a body (most of them are).
LOAD_PATH = [
    ("GET",  "/client/metadata", ""),
    ("POST", "/client/game/config", "{}"),
    ("POST", "/client/game/start", "{}"),
    ("POST", "/client/game/version/validate", '{"version":{"major":"1.1.0.46777"}}'),
    ("POST", "/client/game/profile/list", "{}"),
    ("POST", "/v2/client/game/profiles/", "{}"),
    ("POST", "/client/items", "{}"),
    ("POST", "/client/customization", "{}"),
    ("POST", "/client/globals", "{}"),
    ("POST", "/client/settings", "{}"),
    ("POST", "/client/locale/en", "{}"),
    ("POST", "/client/menu/locale/en", "{}"),
    ("POST", "/client/languages", "{}"),
    ("POST", "/client/handbook/templates", "{}"),
    ("POST", "/client/seasonal-perks/list", "{}"),
    ("POST", "/client/ending/list", "{}"),
    ("POST", "/client/prestige/list", "{}"),
    ("POST", "/client/trading/api/traderSettings", "{}"),
    ("POST", "/client/quest/list", "{}"),
    ("POST", "/client/achievement/list", "{}"),
    ("POST", "/client/achievement/statistic", "{}"),
    ("POST", "/client/mail/dialog/list", "{}"),
    ("POST", "/client/hideout/areas", "{}"),
    ("POST", "/client/hideout/settings", "{}"),
    ("POST", "/client/locations", "{}"),
    ("POST", "/client/weather", "{}"),
    ("POST", "/client/raid/configuration", "{}"),
]

# The raid-entry burst, after the map is picked.
RAID_PATH = [
    ("POST", "/client/match/local/start",
     '{"location":"bigmap","savage":false,"timeVariant":"CURR",'
     '"mode":"deathmatch","playerSide":"Pmc"}'),
    ("POST", "/client/game/bot/generate",
     '{"conditions":[{"Role":"assault","Limit":5,"Difficulty":"normal"}]}'),
    ("POST", "/client/game/bot/generate",
     '{"conditions":[{"Role":"pmcBEAR","Limit":3,"Difficulty":"normal"}]}'),
    ("POST", "/client/game/bot/generate",
     '{"conditions":[{"Role":"assault","Limit":5,"Difficulty":"normal"}]}'),
]


def free_port(start):
    p = start
    while p < start + 200:
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", p))
            s.close()
            return p
        except OSError:
            p += 1
        finally:
            try:
                s.close()
            except OSError:
                pass
    raise SystemExit("no free port")


def wait_up(port, proc, timeout=180.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            raise SystemExit("backend exited %s before listening" % proc.returncode)
        s = socket.socket()
        s.settimeout(0.5)
        try:
            s.connect(("127.0.0.1", port))
            s.close()
            return time.time() - t0
        except OSError:
            time.sleep(0.25)
        finally:
            try:
                s.close()
            except OSError:
                pass
    raise SystemExit("backend never listened on %d" % port)


class Client:
    def __init__(self, port, session):
        self.port = port
        self.session = session
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=120)

    def call(self, verb, url, body):
        raw = zlib.compress(body.encode()) if body else b""
        headers = {
            "Cookie": "PHPSESSID=" + self.session,
            "Content-Type": "application/json",
            "Content-Length": str(len(raw)),
            "Connection": "keep-alive",
        }
        t0 = time.perf_counter()
        # `skip_accept_encoding`, and it is the whole reason this is not
        # `conn.request()`: http.client sends `Accept-Encoding: identity` by
        # default, the backend honours it (parseHead), and the measurement then
        # silently omits the deflate -- which is the largest single cost on
        # this path. The game client sends no Accept-Encoding at all.
        self.conn.putrequest(verb, url, skip_accept_encoding=True)
        for k, v in headers.items():
            self.conn.putheader(k, v)
        self.conn.endheaders(raw if raw else None)
        r = self.conn.getresponse()
        data = r.read()
        ms = (time.perf_counter() - t0) * 1000.0
        return ms, r.status, len(data), data


def inflate(data):
    try:
        return zlib.decompress(data)
    except zlib.error:
        return data


def run(args):
    port = free_port(args.port)
    log = os.path.join(args.root, "aowlspt-backend.log")
    if os.path.exists(log):
        try:
            os.remove(log)
        except OSError:
            pass
    cmd = [args.backend, "--root", args.root, "--port", str(port)]
    if args.perf:
        cmd.append("--perf")
    if args.verbose:
        cmd.append("--verbose")
    cmd += args.arg
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    try:
        boot = wait_up(port, proc)
        if args.settle:
            time.sleep(args.settle)
        c = Client(port, args.session)
        rows = []
        seq = list(LOAD_PATH)
        if args.raid:
            seq += RAID_PATH
        for verb, url, body in seq:
            ms1, st1, n1, d1 = c.call(verb, url, body)
            ms2, st2, n2, _ = c.call(verb, url, body)
            rows.append((url, ms1, ms2, st1, n1, len(inflate(d1))))
        # The duplicate /client/items the client really makes.
        ms1, st1, n1, d1 = c.call("POST", "/client/items", "{}")
        rows.append(("/client/items (dup)", ms1, ms1, st1, n1, len(inflate(d1))))

        print("label=%s port=%d boot=%.2fs" % (args.label, port, boot))
        print("%-44s %9s %9s %6s %10s %11s" %
              ("route", "first ms", "2nd ms", "code", "wire B", "body B"))
        tot1 = tot2 = 0.0
        for url, ms1, ms2, st, n, raw in rows:
            print("%-44s %9.1f %9.1f %6d %10d %11d" % (url, ms1, ms2, st, n, raw))
            tot1 += ms1
            tot2 += ms2
        print("%-44s %9.1f %9.1f" % ("TOTAL", tot1, tot2))
        if args.json:
            with open(args.json, "w") as f:
                json.dump({"label": args.label, "boot": boot,
                           "rows": [{"url": u, "first": a, "second": b,
                                     "code": s, "wire": n, "body": r}
                                    for u, a, b, s, n, r in rows],
                           "total_first": tot1, "total_second": tot2}, f, indent=1)
        return 0
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=20)
        except Exception:
            proc.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="backend/bin/aowlspt-backend.exe")
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=7969)
    ap.add_argument("--session", default=SESSION_DEFAULT)
    ap.add_argument("--label", default="run")
    ap.add_argument("--json", default="")
    ap.add_argument("--settle", type=float, default=0.0,
                    help="seconds to wait after the port opens, before the "
                         "first request -- how a background warm-up is given "
                         "its chance")
    ap.add_argument("--raid", action="store_true",
                    help="also drive match/local/start and bot/generate")
    ap.add_argument("--perf", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--arg", action="append", default=[],
                    help="one extra argument passed straight to the backend, "
                         "repeatable -- `--arg --no-warm` is how the control "
                         "run for the warm cache is taken")
    sys.exit(run(ap.parse_args()))


if __name__ == "__main__":
    main()
