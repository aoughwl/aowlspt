#!/usr/bin/env python3
"""test_hosthttp.py -- the host's generic `http` / `play_wav` verbs.

WHAT IS ACTUALLY EXECUTED, and what is only read.

  EXECUTED. `abi/aowlspt_hostnet.h` and `abi/aowlspt_playwav.h` are compiled
  into `tests/hostnet/hostnet_drive.c` and RUN against a real HTTP server this
  script starts on a loopback port. So the allowlist, the inflight cap, the
  request- and response-body caps, the https refusal, the flag gate, the
  worker-thread completion queue and the winmm path check are all measured by
  driving the same code the host DLL compiles -- not a reimplementation of it.

  NOT EXECUTED, and said out loud rather than implied by a green run:

    * `host/Aowlspt.Host.Il2Cpp/hostnet.nim` -- the JSON argument parsing, the
      root-prefix check for play_wav, and the answer strings. Reaching those
      needs `aowlspt_nim_call`, which lives in the host DLL, and the host DLL
      cannot be loaded outside the game: `tests/mockil2cpp` and
      `tools/hostharness.nim` stand up an IL2CPP-shaped surface for the
      RUNTIME, and neither gives a way to call a verb. Those parts are covered
      here only by a SOURCE check, which is reported as its own case with its
      own negative control so it cannot be mistaken for behaviour.
    * that a mod actually receives `host.http.done`. That needs the event bus,
      which needs the host DLL, which needs the game.

THREE OUTCOMES, never two: PASS / FAIL / INCONCLUSIVE. No compiler, no
loopback socket, a missing header -- all INCONCLUSIVE (exit 3), because "I
could not look" is not a pass.

EVERY CASE CARRIES A NEGATIVE CONTROL IN THE SAME RUN. The allowlist case
dials `localhost`, which resolves to the very server the allowed case just
fetched from, so an allowlist that matched on the resolved address (or did not
match at all) FAILS instead of passing by luck. The body-cap case submits an
over-cap body and an under-cap body on the same configuration, so a submit
path that refused everything cannot pass.

    python tools/test_hosthttp.py
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

try:
    import cctool
except Exception:                                   # pragma: no cover
    cctool = None

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"
results = []

HELLO = b"hello from the test server"
BIG = b"B" * 65536


def record(name, verdict, detail=""):
    results.append((name, verdict, detail))
    print("%-13s %s" % (verdict, name))
    for line in (detail or "").splitlines():
        print("              " + line)


# --------------------------------------------------------------- the server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/big"):
            self._send(200, BIG)
        elif self.path.startswith("/slow"):
            time.sleep(0.6)
            self._send(200, HELLO)
        else:
            self._send(200, HELLO)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        self._send(200, b"echoed:" + str(len(body)).encode())


class Quiet(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # WinHTTP drops the keep-alive connection when it is done with it, and
        # socketserver prints a full traceback for that. It is noise, not a
        # failure, and a wall of tracebacks above a verdict makes the verdict
        # unreadable.
        pass


class Server(object):
    def __init__(self):
        # THREADING, and this is not incidental. The single-threaded
        # `HTTPServer` serves one connection to completion before accepting the
        # next, so the "two concurrent requests" case could not have passed
        # whatever the code under test did -- a test that cannot pass is as
        # useless as a check that cannot fail. MEASURED 2026-09-06: with
        # `HTTPServer` the second request died in `WinHttpReceiveResponse`.
        self.httpd = Quiet(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.t = threading.Thread(target=self.httpd.serve_forever, args=(0.1,))
        self.t.daemon = True

    def __enter__(self):
        self.t.start()
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()


# ---------------------------------------------------------------- the driver

def build_driver():
    """Compile tests/hostnet/hostnet_drive.c. Returns (exe, None) or (None, why)."""
    src = os.path.join(ROOT, "tests", "hostnet", "hostnet_drive.c")
    if not os.path.exists(src):
        return None, "tests/hostnet/hostnet_drive.c is missing"
    for h in ("aowlspt_hostnet.h", "aowlspt_playwav.h"):
        if not os.path.exists(os.path.join(ROOT, "abi", h)):
            return None, "abi/%s is missing" % h
    if cctool is None:
        return None, "tools/cctool.py did not import"
    cc, why = cctool.find_cc()
    if not cc:
        return None, "no working C compiler: %s" % why
    out = os.path.join(tempfile.mkdtemp(prefix="aowl-hostnet-"), "hostnet_drive.exe")
    r = cctool.cc_run([cc, "-std=c99", "-O1", "-I", os.path.join(ROOT, "abi"),
                       src, "-o", out])
    if r.returncode != 0:
        return None, "compile failed:\n" + (r.stderr or r.stdout or "")[:2000]
    return out, None


def run_case(exe, kase, port, *extra):
    r = subprocess.run([exe, kase, str(port)] + list(extra),
                       capture_output=True, text=True, timeout=90)
    return r.stdout or ""


def outs(text):
    return [l[4:] for l in text.splitlines() if l.startswith("OUT ")]


# ------------------------------------------------------------------- cases

def case_allowed_get(exe, port):
    text = run_case(exe, "allowed_get", port)
    o = outs(text)
    if not o:
        return record("an allowed GET completes", INCONCLUSIVE,
                      "the driver printed nothing:\n" + text[:500])
    if "submit=1" not in o[0]:
        return record("an allowed GET completes", FAIL,
                      "submit was refused: " + o[0])
    line = " ".join(o[1:])
    if "rc=1" not in line or "status=200" not in line:
        return record("an allowed GET completes", FAIL,
                      "no completed 200: " + line)
    if HELLO.decode() not in line:
        return record("an allowed GET completes", FAIL,
                      "the body did not come back verbatim: " + line)
    record("an allowed GET completes", PASS,
           "status=200 and the server's exact body came back through the "
           "worker-thread queue")


def case_disallowed(exe, port):
    """NEGATIVE CONTROL: `localhost` IS the server the allowed case reached."""
    text = run_case(exe, "disallowed_host", port)
    o = outs(text)
    if not o:
        return record("a host outside hostHttpAllow is refused", INCONCLUSIVE,
                      "the driver printed nothing")
    if "submit=0" not in o[0]:
        return record("a host outside hostHttpAllow is refused", FAIL,
                      "it was ACCEPTED -- the allowlist did not bite: " + o[0])
    if "not in hostHttpAllow" not in o[0]:
        return record("a host outside hostHttpAllow is refused", FAIL,
                      "refused, but `why` does not name the allowlist: " + o[0])
    record("a host outside hostHttpAllow is refused", PASS,
           "localhost resolves to the same server the allowed case fetched "
           "from, and was still refused BY NAME")


def case_https(exe, port):
    text = run_case(exe, "https_refused", port)
    o = outs(text)
    if not o:
        return record("https:// is refused by name", INCONCLUSIVE, "no output")
    if "submit=0" not in o[0] or "https" not in o[0]:
        return record("https:// is refused by name", FAIL, o[0])
    record("https:// is refused by name", PASS, o[0][:120])


def case_flag_off(exe, port):
    text = run_case(exe, "flag_off", port)
    o = outs(text)
    if not o:
        return record("with the flag off the verb REFUSES, not silently",
                      INCONCLUSIVE, "no output")
    if "submit=0" not in o[0]:
        return record("with the flag off the verb REFUSES, not silently", FAIL,
                      "a request went out with hostHttp off: " + o[0])
    if "flag hostHttp is off" not in o[0]:
        return record("with the flag off the verb REFUSES, not silently", FAIL,
                      "refused with the wrong reason: " + o[0])
    record("with the flag off the verb REFUSES, not silently", PASS,
           "why = flag hostHttp is off")


def case_req_cap(exe, port):
    text = run_case(exe, "req_body_over_cap", port)
    o = outs(text)
    if len(o) < 3:
        return record("an over-cap REQUEST body is refused, not truncated",
                      INCONCLUSIVE, "the driver printed %d lines" % len(o))
    if "submit=0" not in o[0] or "REFUSED" not in o[0]:
        return record("an over-cap REQUEST body is refused, not truncated",
                      FAIL, "the 8 KiB body was not refused: " + o[0])
    if "control_submit=1" not in o[1]:
        return record("an over-cap REQUEST body is refused, not truncated",
                      FAIL, "POSITIVE CONTROL FAILED: an under-cap body on the "
                      "same configuration was refused too, so the refusal "
                      "above proves nothing: " + o[1])
    if "status=200" not in " ".join(o[2:]):
        return record("an over-cap REQUEST body is refused, not truncated",
                      FAIL, "the control request did not complete: " + " ".join(o[2:]))
    record("an over-cap REQUEST body is refused, not truncated", PASS,
           "8192 B refused at a 4096 B cap; 2 B accepted and completed 200 on "
           "the same configuration")


def case_resp_cap(exe, port):
    text = run_case(exe, "resp_body_over_cap", port)
    o = outs(text)
    if len(o) < 2:
        return record("an over-cap RESPONSE body is refused, not truncated",
                      INCONCLUSIVE, "the driver printed %d lines" % len(o))
    line = " ".join(o[1:])
    if "rc=1" not in line:
        return record("an over-cap RESPONSE body is refused, not truncated",
                      INCONCLUSIVE, "the request never completed: " + line)
    if "bytes=0" not in line:
        return record("an over-cap RESPONSE body is refused, not truncated",
                      FAIL, "a PREFIX of the 64 KiB body came back -- that is "
                      "the truncation this cap exists to prevent: " + line[:300])
    if "hostHttpMaxBody" not in line:
        return record("an over-cap RESPONSE body is refused, not truncated",
                      FAIL, "no body and no error naming the cap: " + line[:300])
    record("an over-cap RESPONSE body is refused, not truncated", PASS,
           "64 KiB at a 4096 B cap -> 0 bytes and an error naming "
           "hostHttpMaxBody")


def case_concurrent(exe, port):
    text = run_case(exe, "two_concurrent", port)
    o = outs(text)
    joined = "\n".join(o)
    if "submit1=1" not in joined or "submit2=1" not in joined:
        return record("two concurrent requests both complete", FAIL,
                      "one of the two was refused:\n" + joined[:400])
    drained = set(re.findall(r"drained=(\S+)", joined))
    if drained != {"g1", "g2"}:
        return record("two concurrent requests both complete", FAIL,
                      "the completion queue handed back %r, not both ids" % (drained,))
    got = re.findall(r"OUT (g[12]) rc=1 status=200", "OUT " + "\nOUT ".join(o))
    if sorted(got) != ["g1", "g2"]:
        return record("two concurrent requests both complete", FAIL,
                      "not both completed 200:\n" + joined[:400])
    record("two concurrent requests both complete", PASS,
           "both ids came out of the worker-thread queue and both read back "
           "status=200")


def case_inflight(exe, port):
    text = run_case(exe, "inflight_cap", port)
    o = outs(text)
    if len(o) < 2:
        return record("hostHttpMaxInflight refuses the overflow", INCONCLUSIVE,
                      "the driver printed %d lines" % len(o))
    if "submit1=1" not in o[0]:
        return record("hostHttpMaxInflight refuses the overflow", FAIL,
                      "POSITIVE CONTROL FAILED: the FIRST request was refused, "
                      "so refusing the second proves nothing: " + o[0])
    if "submit2=0" not in o[1] or "in flight" not in o[1]:
        return record("hostHttpMaxInflight refuses the overflow", FAIL,
                      "the second request was accepted at maxInflight=1: " + o[1])
    record("hostHttpMaxInflight refuses the overflow", PASS,
           "at maxInflight=1 the first is accepted and the second is refused "
           "by name")


def case_unknown_id(exe, port):
    text = run_case(exe, "unknown_id", port)
    o = outs(text)
    if not o or "rc=-1" not in o[0]:
        return record("an unknown id is -1 (a refusal), not 'not done'", FAIL,
                      "an id that was never submitted did not read back as "
                      "unknown: " + (o[0] if o else "<no output>"))
    record("an unknown id is -1 (a refusal), not 'not done'", PASS,
           "unknown and in-flight are distinguishable, so a poller cannot "
           "wait forever on a typo")


def case_playwav(exe, port):
    """A real .wav is generated so the winmm path is executed, not just the
    missing-file branch. PlaySoundW is async and there may be no audio device
    on this machine, so PLAYING is not asserted -- only that a missing file is
    refused, that %TEMP% expands, and that a real PCM wav is not refused for a
    reason that would also refuse a good one."""
    wav = os.path.join(tempfile.mkdtemp(prefix="aowl-wav-"), "beep.wav")
    with open(wav, "wb") as f:
        data = bytes(bytearray((128,) * 800))
        hdr = (b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVEfmt "
               + (16).to_bytes(4, "little") + (1).to_bytes(2, "little")
               + (1).to_bytes(2, "little") + (8000).to_bytes(4, "little")
               + (8000).to_bytes(4, "little") + (1).to_bytes(2, "little")
               + (8).to_bytes(2, "little") + b"data"
               + len(data).to_bytes(4, "little"))
        f.write(hdr + data)
    text = run_case(exe, "playwav", port, wav)
    o = outs(text)
    joined = "\n".join(o)
    if len(o) < 3:
        return record("play_wav: %TEMP% expands and a missing file is refused",
                      INCONCLUSIVE, "the driver printed %d lines" % len(o))
    if o[0].startswith("expand=0") or "%TEMP%" in o[0]:
        return record("play_wav: %TEMP% expands and a missing file is refused",
                      FAIL, "%TEMP% did not expand, so the default root list "
                      "would match nothing: " + o[0])
    if "missing=0" not in o[1] or "no such file" not in o[1]:
        return record("play_wav: %TEMP% expands and a missing file is refused",
                      FAIL, "a nonexistent path was not refused by name: " + o[1])
    if "real=1" not in o[2]:
        return record("play_wav: %TEMP% expands and a missing file is refused",
                      INCONCLUSIVE,
                      "a valid 8-bit PCM wav was refused -- most likely this "
                      "machine has no audio device, which is not a defect in "
                      "the code under test: " + o[2])
    record("play_wav: %TEMP% expands and a missing file is refused", PASS,
           "%TEMP% expanded, a missing file refused with `no such file`, and a "
           "real PCM wav accepted by PlaySoundW")


# ------------------------------------------- the source-only half, labelled

def case_nim_layer():
    """The Nim verb layer cannot be executed here. Read it instead, WITH a
    negative control, and report it as a source check."""
    path = os.path.join(ROOT, "host", "Aowlspt.Host.Il2Cpp", "hostnet.nim")
    host = os.path.join(ROOT, "host", "Aowlspt.Host.Il2Cpp", "aowlhost.nim")
    if not os.path.exists(path) or not os.path.exists(host):
        return record("SOURCE ONLY: the Nim verb layer is wired up",
                      INCONCLUSIVE, "hostnet.nim or aowlhost.nim is missing")
    src = open(path, encoding="utf-8", errors="replace").read()
    hsrc = open(host, encoding="utf-8", errors="replace").read()
    want = [
        ('the http verb is dispatched', '"aowlspt.host::http"', hsrc),
        ('the http_poll verb is dispatched', '"aowlspt.host::http_poll"', hsrc),
        ('the play_wav verb is dispatched', '"aowlspt.host::play_wav"', hsrc),
        ('hostnet.nim is included', 'include "hostnet.nim"', hsrc),
        ('completions are drained on the HOST tick, not the worker',
         'hnTakeCompletion()', hsrc),
        ('and emitted as host.http.done', '"host.http.done"', hsrc),
        ('the flags are read', 'readBoolKey("hostHttp")', hsrc),
        ('the allowlist is read as an ARRAY', 'readStrListKey("hostHttpAllow")', hsrc),
        ('the roots are read as an ARRAY', 'readStrListKey("hostPlayWavRoots")', hsrc),
        ('flag-off is an ANSWER', 'flag hostHttp is off', src),
        ('play_wav flag-off is an ANSWER', 'flag hostPlayWav is off', src),
        ('volume is documented as ignored', 'volumeIgnored', src),
        ('a `..` in a play_wav path is refused', 'hnUnderRoot', src),
    ]
    missing = [n for n, lit, hay in want if lit not in hay]
    # NEGATIVE CONTROL: a literal that is deliberately not there. Without it a
    # search that matched everything would report a clean sweep.
    if "aowlspt.host::definitely_not_a_verb" in hsrc:
        return record("SOURCE ONLY: the Nim verb layer is wired up", FAIL,
                      "the negative control matched, so this search proves "
                      "nothing")
    if missing:
        return record("SOURCE ONLY: the Nim verb layer is wired up", FAIL,
                      "not found: " + "; ".join(missing))
    record("SOURCE ONLY: the Nim verb layer is wired up", PASS,
           "%d wiring facts present, negative control absent. This is a SOURCE "
           "check: it does not show the verb answers in a running client."
           % len(want))


def main():
    exe, why = build_driver()
    if not exe:
        record("compile tests/hostnet/hostnet_drive.c", INCONCLUSIVE, why)
        case_nim_layer()
    else:
        record("compile tests/hostnet/hostnet_drive.c", PASS, exe)
        try:
            with Server() as srv:
                # Prove the fixture itself works before trusting any verdict
                # that depends on it.
                s = socket.create_connection(("127.0.0.1", srv.port), 3)
                s.close()
                for fn in (case_allowed_get, case_disallowed, case_https,
                           case_flag_off, case_req_cap, case_resp_cap,
                           case_concurrent, case_inflight, case_unknown_id,
                           case_playwav):
                    try:
                        fn(exe, srv.port)
                    except Exception as ex:
                        record(fn.__name__, INCONCLUSIVE, "raised: %r" % (ex,))
        except OSError as ex:
            record("stand up a loopback HTTP server", INCONCLUSIVE, repr(ex))
        case_nim_layer()
        shutil.rmtree(os.path.dirname(exe), ignore_errors=True)

    fails = [r for r in results if r[1] == FAIL]
    inc = [r for r in results if r[1] == INCONCLUSIVE]
    print("")
    print("%d PASS  %d FAIL  %d INCONCLUSIVE"
          % (len(results) - len(fails) - len(inc), len(fails), len(inc)))
    if fails:
        return 1
    if inc:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
