#!/usr/bin/env python3
"""Falsifications for the boot race that produced

    Fatal error [EscapeFromTarkov.exe] Unable to check the client version

MEASURED 2026-09-01: the launcher spawned the backend at 22:48:25 and the
client at 22:48:27, while the backend's own "listening on" was not written
until 0:00:05.9 into its run.  The client's version check therefore ran
against a port nothing was listening on.  Two independent defects made that
possible, and this file has a test for each.

    1  THE LAUNCHER BELIEVED A STALE LOG.  In TLS mode it cannot open an
       HTTPS request, so readiness was "listening on" appearing in
       aowlspt-backend.log -- a file that is the PREVIOUS run's until the new
       backend truncates it, ~40 ms after spawn.  aowl_tail_read cannot catch
       that on the first read: it detects truncation by size < offset (the
       offset is 0 on a first read) or by a change in
       creationTime ^ fileIndex (CREATE_ALWAYS over an existing file keeps
       both).  Readiness is now a real TCP accept, corroborated by the log
       only once the log has been rotated out of the way.

    2  THE BACKEND LISTENED LAST.  aowl_net_serve* was called AFTER every
       server mod's on_load.  The listen now happens before them, and a
       request that arrives during the load is held rather than 404ed.

Run:

    python tools/test_startup_race.py                      # launcher only
    python tools/test_startup_race.py --backend EXE --root DIR [--port N]

The launcher tests need only aowlspt-launch.exe.  The backend tests need an
install-shaped scratch root and are SKIPPED, loudly, without one -- a skip is
never counted as a pass.

Three outcomes, never two: PASS / FAIL / SKIP (inconclusive).
"""

import argparse
import os
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCH = os.path.join(REPO, "installer", "build", "aowlspt-launch.exe")

# What the previous run leaves behind.  The literal "listening on" is the exact
# sentence the launcher used to accept as proof, so a fixture without it would
# not be testing anything.
STALE_LOG = (
    "aowlspt-backend 0.1.0\r\n"
    "[47ms] info  database loaded from D:\\Aowlspt\\aowlspt\\db.json (41313127 bytes)\r\n"
    "[1340ms] ok   loaded aowl.tarkov\r\n"
    "[4656ms] ok   listening on https://127.0.0.1:443\r\n"
)

results = []


def record(name, verdict, detail):
    results.append((name, verdict, detail))
    print("%-5s %-48s %s" % (verdict, name, detail))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def make_root(tmp, with_stale_log):
    """An install-shaped tree: <tmp>/aowlspt/aowlspt-backend.log."""
    inner = os.path.join(tmp, "aowlspt")
    os.makedirs(inner, exist_ok=True)
    log = os.path.join(inner, "aowlspt-backend.log")
    if with_stale_log:
        with open(log, "w", encoding="utf-8", newline="") as f:
            f.write(STALE_LOG)
    elif os.path.exists(log):
        os.remove(log)
    with open(os.path.join(inner, "backend.json"), "w") as f:
        f.write('{"url":"https://127.0.0.1/"}\n')
    return tmp


def probe(root, port, timeout=60):
    return subprocess.run(
        [LAUNCH, "--root", root, "--port", str(port), "--ready-probe",
         "--plain"],
        capture_output=True, text=True, timeout=timeout, cwd=REPO)


# --------------------------------------------------------------- the launcher

def launcher_tests():
    if not os.path.exists(LAUNCH):
        record("launcher: binary present", "SKIP",
               "no %s -- build launch first; NOTHING was tested" % LAUNCH)
        return

    tmp = tempfile.mkdtemp(prefix="aowl-race-")
    port = free_port()

    # THE NEGATIVE CONTROL, and the point of the whole file: the exact input
    # that made the old launcher say "ready" must now say "not ready".
    root = make_root(tmp, with_stale_log=True)
    r = probe(root, port)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode == 4:
        record("stale 'listening on' + dead port -> NOT READY", "SKIP",
               "the probe could not load winsock, so nothing was asked")
    elif r.returncode == 3 and "NOT READY" in out:
        record("stale 'listening on' + dead port -> NOT READY", "PASS",
               "exit 3; the log line was read and overruled")
    else:
        record("stale 'listening on' + dead port -> NOT READY", "FAIL",
               "exit %d -- a stale log is still being believed" % r.returncode)

    # Without this, the refusal above could be passing because the probe never
    # opened the log at all, which is a different bug wearing the same result.
    if "log says listening   yes" in out:
        record("...and the stale line WAS read, not merely missed", "PASS",
               "the probe reports it and refuses anyway")
    else:
        record("...and the stale line WAS read, not merely missed", "FAIL",
               "the probe did not report the stale line, so the refusal above "
               "may be for the wrong reason")

    # THE POSITIVE CONTROL.  A check that cannot pass proves as little as one
    # that cannot fail.  Same stale log, same port, but now something listens.
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", port))
        srv.listen(8)
        r2 = probe(root, port)
        out2 = (r2.stdout or "") + (r2.stderr or "")
        if r2.returncode == 0 and "READY" in out2:
            record("a real listener on the same port -> READY", "PASS",
                   "exit 0")
        else:
            record("a real listener on the same port -> READY", "FAIL",
                   "exit %d -- the probe cannot pass, so its refusal above "
                   "proves nothing" % r2.returncode)
    finally:
        srv.close()

    # A BIND WITHOUT A LISTEN is what the backend's reservePort holds for the
    # first seconds of its startup.  If that read as ready, the launcher would
    # go straight back to clearing the client too early.
    port2 = free_port()
    bound = socket.socket()
    bound.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        bound.bind(("127.0.0.1", port2))          # bound, never listen()
        r3 = probe(root, port2)
        if r3.returncode == 3:
            record("bound-but-not-listening -> NOT READY", "PASS", "exit 3")
        else:
            record("bound-but-not-listening -> NOT READY", "FAIL",
                   "exit %d -- a reserved port reads as ready, which would "
                   "clear the client to start during reservePort"
                   % r3.returncode)
    finally:
        bound.close()


# ---------------------------------------------------------------- the backend

def wait_accept(port, deadline):
    """Wall seconds until 127.0.0.1:port accepts a TCP connection, or None."""
    t0 = time.time()
    while time.time() - t0 < deadline:
        s = socket.socket()
        s.settimeout(0.25)
        try:
            s.connect(("127.0.0.1", port))
            return time.time() - t0
        except OSError:
            pass
        finally:
            try:
                s.close()
            except OSError:
                pass
        time.sleep(0.02)
    return None


def validate_call(port, timeout=40.0):
    """POST the client's own handshake over TLS.

    Returns (elapsed_ms, status_line) or (None, why).  This is the request
    whose failure draws the dialog, so it is the request the test makes --
    not a cheaper stand-in on another route.
    """
    import ssl
    ctx = ssl._create_unverified_context()
    body = b'{"version":"live","develop":false}'
    req = (b"POST /client/game/version/validate HTTP/1.1\r\n"
           b"Host: 127.0.0.1\r\n"
           b"Cookie: PHPSESSID=000000000000000000000001\r\n"
           b"Accept-Encoding: identity\r\n"
           b"Content-Type: application/json\r\n"
           b"Content-Length: " + str(len(body)).encode() + b"\r\n"
           b"Connection: close\r\n\r\n" + body)
    t0 = time.time()
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        raw.settimeout(timeout)
        s = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
        s.sendall(req)
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            chunk = s.recv(4096)
            if not chunk:
                break
            head += chunk
        s.close()
    except Exception as e:                                       # noqa: BLE001
        return None, "%s: %s" % (type(e).__name__, e)
    ms = (time.time() - t0) * 1000.0
    line = head.split(b"\r\n", 1)[0].decode("latin1") if head else "(no head)"
    return ms, line


def stamp_of(text, phrase):
    """Milliseconds since process start, from the first line carrying `phrase`.

    The backend writes [0:00:02.219]; older builds and the host write [2219ms].
    Both are read here, because a parser that silently matched neither made
    every timing assertion below report SKIP -- an "I could not look" dressed
    up as a result.
    """
    for line in text.splitlines():
        if phrase not in line or not line.startswith("["):
            continue
        close = line.find("]")
        if close < 0:
            continue
        stamp = line[1:close]
        if stamp.endswith("ms"):
            try:
                return int(stamp[:-2])
            except ValueError:
                return None
        parts = stamp.split(":")
        if len(parts) == 3:
            try:
                h = int(parts[0])
                m = int(parts[1])
                s = float(parts[2])
                return int((h * 3600 + m * 60) * 1000 + s * 1000)
            except ValueError:
                return None
    return None


def backend_tests(exe, root, port):
    if not exe:
        record("backend: listen precedes the mod load", "SKIP",
               "no --backend EXE given; NOTHING about the backend was tested")
        return
    inner = os.path.join(root, "aowlspt")
    os.makedirs(inner, exist_ok=True)
    log = os.path.join(inner, "aowlspt-backend.log")
    if os.path.exists(log):
        os.remove(log)
    proc = subprocess.Popen(
        [exe, "--root", inner, "--port", str(port), "--tls",
         "--asset-port", "0", "--control-port", str(port + 1),
         "--no-store-lock"],
        cwd=inner, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        accept = wait_accept(port, 180.0)
        if accept is None:
            record("backend: accepts a TCP connection", "FAIL",
                   "nothing accepted on %d within 180 s" % port)
            return
        record("backend: accepts a TCP connection", "PASS",
               "%d ms after spawn" % int(accept * 1000))

        # The handshake, issued the instant the socket accepts -- i.e. during
        # the mod load, which is precisely the window the client hits.
        ms, line = validate_call(port)
        if ms is None:
            record("backend: version/validate answers at all", "FAIL",
                   "no answer: %s" % line)
        else:
            served = ("200" in line) or ("503" in line)
            record("backend: version/validate answers at all",
                   "PASS" if served else "FAIL",
                   "%s in %d ms (%d ms after spawn)"
                   % (line, int(ms), int(accept * 1000 + ms)))
            if "503" in line:
                record("...and 'not ready' is a well-formed HTTP answer",
                       "PASS",
                       "503, not a reset -- the client gets an answer either "
                       "way")

        deadline = time.time() + 180
        text = ""
        while time.time() < deadline:
            try:
                text = open(log, encoding="utf-8", errors="replace").read()
            except OSError:
                text = ""
            if "mods loaded (" in text:
                break
            time.sleep(0.2)
        listen_ms = stamp_of(text, "listening on")
        ready_ms = stamp_of(text, "mods loaded (")
        if listen_ms is None or ready_ms is None:
            record("backend: listen precedes the mod load", "SKIP",
                   "the log does not carry both lines (listening=%s, "
                   "mods loaded=%s)" % (listen_ms, ready_ms))
        elif listen_ms < ready_ms:
            record("backend: listen precedes the mod load", "PASS",
                   "listening at %d ms, mods ready at %d ms -- %d ms that "
                   "used to be a dead port"
                   % (listen_ms, ready_ms, ready_ms - listen_ms))
        else:
            record("backend: listen precedes the mod load", "FAIL",
                   "listening at %d ms, mods ready at %d ms"
                   % (listen_ms, ready_ms))

        # The warm gate.  Warm must not have begun before the handshake was
        # answered; if it had, the gate is not doing anything.
        gate = stamp_of(text, "warm gate open")
        first_warm = stamp_of(text, "warm /")
        if gate is None:
            record("backend: the warm gate is reported", "SKIP",
                   "no 'warm gate open' line yet")
        elif first_warm is None:
            record("backend: warm begins only after the gate", "PASS",
                   "gate opened at %d ms; nothing warmed yet" % gate)
        elif first_warm >= gate:
            record("backend: warm begins only after the gate", "PASS",
                   "gate at %d ms, first warmed route at %d ms"
                   % (gate, first_warm))
        else:
            record("backend: warm begins only after the gate", "FAIL",
                   "a route was warmed at %d ms, before the gate opened at "
                   "%d ms" % (first_warm, gate))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    ap = argparse.ArgumentParser(
        description="falsifications for the aowlspt startup race")
    ap.add_argument("--backend", help="aowlspt-backend.exe to measure")
    ap.add_argument("--root", help="an install-shaped scratch root; the "
                                   "backend runs in <root>/aowlspt")
    ap.add_argument("--port", type=int, default=0,
                    help="scratch TLS port; 0 picks a free one")
    a = ap.parse_args()

    if a.port in (80, 443):
        print("refusing to test on port %d: that is the live install's port, "
              "and a human may be playing on it" % a.port)
        return 2

    launcher_tests()
    if a.backend and a.root:
        backend_tests(a.backend, a.root, a.port or free_port())
    else:
        backend_tests(None, None, None)

    fails = [r for r in results if r[1] == "FAIL"]
    skips = [r for r in results if r[1] == "SKIP"]
    print("\n%d pass, %d FAIL, %d skipped (inconclusive)"
          % (len(results) - len(fails) - len(skips), len(fails), len(skips)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
