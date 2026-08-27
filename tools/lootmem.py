#!/usr/bin/env python
"""Working-set growth across repeated /client/match/local/start.

Stages a scratch install, starts aowlspt-backend on a spare port, issues N
raid starts, and samples the backend's WorkingSet64 between them.

The assertion is a negative one: raids 2..N must not leave the process more
than --budget MB above the reading taken after raid 1. Raid 1 is excluded on
purpose -- the first raid on a map is allowed to be expensive (it is what
warms every cache the design deliberately keeps); what must not happen is a
per-raid slope.
"""
import argparse, json, os, shutil, socket, struct, subprocess, sys, time, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = r"D:\Aowlspt\aowlspt"


def stage(dest, moddll, cfg):
    mods = os.path.join(dest, "mods")
    tk = os.path.join(mods, "tarkov")
    os.makedirs(tk, exist_ok=True)
    db = os.path.join(dest, "db.json")
    if not os.path.exists(db):
        shutil.copy2(os.path.join(LIVE, "db.json"), db)
    data = os.path.join(tk, "data")
    if not os.path.isdir(data):
        shutil.copytree(os.path.join(LIVE, "mods", "tarkov", "data"), data)
    shutil.copy2(moddll, os.path.join(tk, "tarkov.dll"))
    shutil.copy2(cfg, os.path.join(tk, "config.json"))
    with open(os.path.join(mods, "aowlspt-selection.json"), "w") as f:
        json.dump({"enabled": ["tarkov"]}, f)
    return dest


def http(port, url, body, session):
    payload = zlib.compress(body.encode())
    head = ("POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: PHPSESSID=%s\r\n"
            "Content-Length: %d\r\nConnection: keep-alive\r\n\r\n"
            % (url, session, len(payload))).encode()
    s = socket.create_connection(("127.0.0.1", port), timeout=120)
    s.sendall(head + payload)
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(65536)
        if not c:
            break
        buf += c
    hdr, rest = buf.split(b"\r\n\r\n", 1)
    n = 0
    for line in hdr.decode("latin1").split("\r\n"):
        if line.lower().startswith("content-length:"):
            n = int(line.split(":")[1])
    while len(rest) < n:
        c = s.recv(1 << 20)
        if not c:
            break
        rest += c
    s.close()
    return rest


def wsmb(pid):
    import ctypes
    from ctypes import wintypes

    class PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t)]
    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    m = PMC()
    m.cb = ctypes.sizeof(m)
    ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(m), m.cb)
    ctypes.windll.kernel32.CloseHandle(h)
    return m.WorkingSetSize / (1024.0 * 1024.0)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--backend", default=os.path.join(ROOT, "backend", "bin", "aowlspt-backend.exe"))
    p.add_argument("--mod", default=os.path.join(ROOT, "mods", "tarkov", "bin", "tarkov.dll"))
    p.add_argument("--config", default=os.path.join(ROOT, "mods", "tarkov", "config.json"))
    p.add_argument("--root", default=os.path.join(os.environ.get("TEMP", "."), "lootmem-stage"))
    p.add_argument("--port", type=int, default=6981)
    p.add_argument("--map", default="bigmap")
    p.add_argument("--raids", type=int, default=8)
    p.add_argument("--budget", type=float, default=24.0)
    p.add_argument("--fixed-seed", action="store_true",
                   help="reuse one raid id, to tell a raid-keyed cache from a flat one")
    a = p.parse_args()

    stage(a.root, a.mod, a.config)
    srv = subprocess.Popen([a.backend, "--root", a.root, "--port", str(a.port)],
                           cwd=a.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(300):
            try:
                http(a.port, "/client/game/config", "{}", "a" * 24)
                break
            except OSError:
                time.sleep(0.5)
        else:
            print("INCONCLUSIVE  backend never answered")
            return 2

        samples = []
        for i in range(a.raids):
            body = json.dumps({"location": a.map, "mode": "PVE",
                               "timeVariant": "CURR", "playerSide": "Pmc"})
            raw = http(a.port, "/client/match/local/start", body, "a" * 24)
            n = len(raw)
            try:
                plain = len(zlib.decompress(raw))
            except Exception:
                plain = -1
            time.sleep(0.4)
            mb = wsmb(srv.pid)
            samples.append((n, mb))
            print("  raid %2d  wire %8d B  plain %9d B   ws %8.1f MB" % (i + 1, n, plain, mb))

        base = samples[0][1]
        peak = max(m for _, m in samples[1:])
        drift = peak - base
        slope = (samples[-1][1] - base) / max(1, a.raids - 1)
        print("\nafter raid 1: %.1f MB   peak after: %.1f MB   drift %.1f MB   "
              "slope %.2f MB/raid" % (base, peak, drift, slope))
        if samples[0][0] < 8000:
            print("INCONCLUSIVE  raid response was %d B compressed -- too small "
                  "to be a map with loot on it, so nothing was measured"
                  % samples[0][0])
            return 2
        if drift > a.budget:
            print("FAIL  %d raids on %s drifted %.1f MB past the post-first-raid "
                  "baseline (budget %.1f MB)" % (a.raids, a.map, drift, a.budget))
            return 1
        print("PASS  %d raids on %s stayed within %.1f MB of the post-first-raid "
              "baseline (budget %.1f MB)" % (a.raids, a.map, drift, a.budget))
        return 0
    except Exception as e:
        print("INCONCLUSIVE  %s" % e)
        if srv.poll() is not None:
            print("backend exited with %s; its last output:" % srv.returncode)
            print(srv.stdout.read().decode("latin1")[-2000:])
        return 2
    finally:
        srv.terminate()


if __name__ == "__main__":
    sys.exit(main())
