#!/usr/bin/env python3
"""A registry server that is wrong on purpose.

    python registry/fakeregistry.py --port 7391 --serve registry/mods.json
    python registry/fakeregistry.py --port 7391 --mode truncate

The mod manager's registry refresh (`mods/manager/mgr/refresh.nim`) is a list of
refusals with one success in the middle of it, and the refusals are the part
worth testing: a fetch that fails, times out, returns garbage, returns a schema
this build does not know, or returns something that fails validation must leave
the registry in place and say so. None of that can be exercised against a real
registry repository, because a real one is correct.

Same shape as `tests/overlayhost/fakebackend.py`: loopback only, one thread, no
dependencies, and it prints every request so a run that hung is distinguishable
from a run that was never asked anything.

Modes, all served at `/mods.json`:

    ok          the file named by --serve, unchanged
    truncate    the first half of it, byte for byte
    garbage     not JSON at all
    schema      valid, with an unknown `schema` string
    invalid     valid JSON, valid schema, a list naming a mod that is not there
    download    valid in every way, with a `download` block on one entry
    empty       valid, with no mods in it
    notfound    404
    error       500
    slow        the file, one byte at a time, with --delay between bytes
    huge        the file repeated until it is larger than any sane maxBytes
    bump        a *newer* revision: one mod dropped, one added, one version up
    older       the file with its revision set to 0

`--mode` may be changed while it runs by GET /mode/<name>, so one server can
walk a whole matrix without being restarted.

Asserting the refusals
----------------------

A refusal nobody has watched fire is a refusal nobody knows is wired up, and a
server that provokes one is only half of that. `--check` is the other half:

    python registry/fakeregistry.py --check \
        --regcheck installer/build/aowl-regcheck.exe

    python registry/fakeregistry.py --check \
        --regcheck installer/build/aowl-regcheck.exe \
        --manager http://127.0.0.1:6979

It runs in three layers, and the difference between them is the whole honesty
of the thing:

* **Document layer** (needs `--regcheck`). Every mode that is refused for what
  the *document says* is refused by `registry/validate.nim`, and
  `aowl-regcheck --file` is that same code with an exit status on it -- the mod
  manager runs the identical validator on a fetched body before it will adopt
  one. So each body is generated, written out and put through it, and the
  expected verdict is asserted. If a refusal stops happening -- a validator that
  starts tolerating an unknown schema, an empty `mods` array, a list naming a
  mod that is not there -- the assertion fails, because what is asserted is the
  exit status and the finding, not the shape of the body.
* **Transport layer** (needs nothing). 404, 500, a body over `maxBytes` and a
  server that dribbles are refused by the manager's *fetch* rather than by the
  validator, so what is asserted here is that this server really does provoke
  them: the status codes over a real socket, the body size against the shipped
  `registryFetchMaxBytes`, and that `slow` at the configured delay cannot
  finish inside the shipped `registryFetchTimeoutMs`.
* **Manager layer** (`--manager URL`, optional). The refusals themselves, end to
  end, against a running manager whose `registryUrl` points at this server:
  each mode is selected, `/aowlspt/mods/registry/fetch` is called, and the
  outcome is polled until it settles. `refused` is asserted for every mode that
  must be refused, `adopted` for the two that must be adopted, and the reason
  is matched -- a manager that started adopting a registry carrying `download`
  blocks fails here and nowhere else.

Without `--manager` the last layer is skipped and said to be skipped. Nothing
else in this repository drives those refusals: `tools/livectl.nim` exercises the
fetch path's *success* and its revert, and stops there.
"""

import argparse
import http.server
import json
import os
import socketserver
import sys
import threading
import time

STATE = {"mode": "ok", "source": b"", "delay": 0.0}
LOCK = threading.Lock()


def source_json():
    return json.loads(STATE["source"].decode("utf-8"))


CACHE = {}


def body_for(mode):
    """(status, bytes, drip) for a mode. `drip` means send it a byte at a time.

    Cached: `huge` costs a second or two to build, and rebuilding it per request
    turns a size test into a timeout test.
    """
    if mode in CACHE:
        return CACHE[mode]
    made = build_body(mode)
    CACHE[mode] = made
    return made


def build_body(mode):
    raw = STATE["source"]
    if mode == "ok":
        return 200, raw, False
    if mode == "truncate":
        return 200, raw[: len(raw) // 2], False
    if mode == "garbage":
        return 200, b"<!doctype html>\n<html><body>404 not found</body></html>\n", False
    if mode == "schema":
        doc = source_json()
        doc["schema"] = "aowlspt.registry/2"
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    if mode == "invalid":
        doc = source_json()
        doc["lists"][0]["entries"].append({"id": "no.such.mod", "enabled": True})
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    if mode == "download":
        doc = source_json()
        doc["mods"][0]["download"] = {
            "url": "https://example.invalid/manager.dll",
            "sha256": "0" * 64,
            "size": 123456,
        }
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    if mode == "empty":
        doc = source_json()
        doc["mods"] = []
        doc["lists"] = []
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    if mode == "notfound":
        return 404, b'{"err":"no such registry"}', False
    if mode == "error":
        return 500, b'{"err":"the publisher is having a day"}', False
    if mode == "slow":
        return 200, raw, True
    if mode == "huge":
        doc = source_json()
        # Repeat the mods with distinct ids so the document is large and still
        # structurally plausible -- a body that is refused for its *size* must
        # not also be refusable for being nonsense, or the test proves nothing.
        #
        # Grown until the *bytes* pass the ceiling, not until some number of
        # entries. It was 4000 entries, which was over the limit when it was
        # written and is 3.0 MB against a 4.0 MB ceiling today -- so the mode
        # that exists to provoke the size refusal had quietly stopped
        # provoking anything, and every manager it was pointed at adopted it.
        # `--check` is what noticed; a mode whose refusal depends on the size
        # of somebody else's registry has to be measured rather than counted.
        base = list(doc["mods"])
        n = 0
        want = FETCH_MAX_BYTES + FETCH_MAX_BYTES // 4
        while True:
            for m in base:
                copy = dict(m)
                copy["id"] = "%s.bulk%d" % (m["id"], n)
                copy["provides"] = []
                copy["requires"] = []
                copy["loadAfter"] = []
                doc["mods"].append(copy)
                n += 1
            if len(json.dumps(doc)) > want:
                break
        return 200, json.dumps(doc).encode("utf-8"), False
    if mode == "bump":
        doc = source_json()
        doc["registry"]["revision"] = doc["registry"].get("revision", 0) + 1
        doc["mods"][1]["version"] = "9.9.9"
        doc["mods"] = [m for m in doc["mods"] if m["id"] != "aowl.icebreaker"]
        doc["lists"] = [l for l in doc["lists"] if l["id"] != "aowl.list.headless"]
        for l in doc["lists"]:
            l["entries"] = [e for e in l["entries"] if e["id"] != "aowl.icebreaker"]
        doc["mods"].append(
            {
                "id": "aowl.brandnew",
                "name": "Brand New",
                "author": "somebody",
                "version": "1.0.0",
                "description": "An entry that did not exist in the previous revision.",
                "pipeline": ">=0.1.0",
                "sides": ["server", "sim"],
                "source": {"kind": "git", "path": None, "url": "https://example.invalid/x"},
                "artifact": {"dir": "brandnew", "library": "brandnew.dll"},
                "upstream": None,
                "license": "MIT",
                "download": None,
                "requires": [],
                "conflicts": [],
                "provides": [],
                "loadAfter": [],
                "tags": [],
            }
        )
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    if mode == "older":
        doc = source_json()
        doc["registry"]["revision"] = 0
        return 200, json.dumps(doc, indent=2).encode("utf-8"), False
    return 500, b'{"err":"unknown mode"}', False


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fakeregistry: " + (fmt % args) + "\n")

    def do_GET(self):
        if self.path.startswith("/mode/"):
            with LOCK:
                STATE["mode"] = self.path[len("/mode/"):]
            payload = json.dumps({"mode": STATE["mode"]}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        with LOCK:
            mode = STATE["mode"]
            delay = STATE["delay"]
        status, payload, drip = body_for(mode)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if not drip:
            self.wfile.write(payload)
            return
        # `slow`: the point is that the manager's timeout fires and the caller
        # of /aowlspt/mods/registry/fetch never waits for any of it.
        #
        # The client hanging up mid-body is the *success* of this mode, so it
        # is caught and reported in one line rather than left to print a
        # socketserver traceback that reads like the harness broke.
        try:
            for i in range(0, len(payload)):
                self.wfile.write(payload[i:i + 1])
                self.wfile.flush()
                time.sleep(delay)
        except OSError as exc:
            sys.stderr.write("fakeregistry: slow: the client hung up after "
                             "%d byte(s) -- %s\n" % (i, exc.__class__.__name__))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# ---------------------------------------------------------------------------
# --check: the assertions
# ---------------------------------------------------------------------------
#
# The numbers below are the *shipped* defaults out of `mods/manager/config.json`.
# They are repeated here rather than read, because what is being asserted is
# that a mode provokes the refusal a manager with the shipped configuration
# would make; a checker that read the config would pass against a config that
# had been widened until nothing was refused any more.

FETCH_MAX_BYTES = 4000000
FETCH_TIMEOUT_MS = 8000

# mode -> (expected regcheck exit status, a fragment the output must contain).
# `None` for the status means the mode is not a document-layer case at all.
DOCUMENT_CASES = {
    "ok":       (0, "well-formed"),
    # Refused, and *not* for being unparseable: `aowlspt/json` scans, so half a
    # registry still reads as an object with a schema and a revision on it --
    # which is exactly the failure the manager's `truncated` refusal exists for
    # and the reason a short body may never be adopted "as far as it got". The
    # finding depends on where the cut lands, so what is asserted is the
    # refusal itself.
    "truncate": (1, ""),
    "garbage":  (1, "the document is a JSON object"),
    "schema":   (1, "the schema is"),
    "invalid":  (1, "no.such.mod"),
    "empty":    (1, "at least one mod"),
    # Valid in every way. The refusal is the manager's and keys on exactly this
    # line: `validate.nim` collects the entry into `withDownload` and
    # `refresh.nim` refuses the document for it. If the naming stops, the input
    # the refusal is made of has gone.
    "download": (0, "carry a `download` block"),
    "bump":     (0, "well-formed"),
    "older":    (0, "well-formed"),
}

TRANSPORT_MODES = ["notfound", "error", "huge", "slow"]

# mode -> (expected outcome, a fragment of the manager's message). The message
# fragments are deliberately short: they name the *reason*, which is the part a
# person reads, and not the sentence, which is allowed to be rewritten.
MANAGER_CASES = {
    "ok":       ("adopted", ""),
    "bump":     ("adopted", ""),
    "truncate": ("refused", ""),
    "garbage":  ("refused", ""),
    "schema":   ("refused", "schema"),
    "invalid":  ("refused", "no.such.mod"),
    "empty":    ("refused", ""),
    "download": ("refused", "download"),
    "older":    ("refused", "revision"),
    "notfound": ("refused", ""),
    "error":    ("refused", ""),
    "huge":     ("refused", ""),
    "slow":     ("refused", ""),
}


class Checks:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.skipped = 0

    def check(self, what, condition, detail=""):
        if condition:
            self.passed += 1
            sys.stdout.write("ok    %s\n" % what)
        else:
            self.failed += 1
            sys.stdout.write("FAIL  %s\n" % what)
            if detail:
                sys.stdout.write("      %s\n" % detail)

    def skip(self, what, why):
        self.skipped += 1
        sys.stdout.write("skip  %s -- %s\n" % (what, why))


def check_documents(ch, regcheck, workdir):
    import subprocess
    for mode in sorted(DOCUMENT_CASES):
        want_status, fragment = DOCUMENT_CASES[mode]
        status, payload, _drip = build_body(mode)
        if status != 200:
            continue
        path = os.path.join(workdir, "fake-%s.json" % mode)
        with open(path, "wb") as fh:
            fh.write(payload)
        run = subprocess.run([regcheck, "--file", path],
                             capture_output=True, text=True)
        out = (run.stdout or "") + (run.stderr or "")
        ch.check("%s: the validator %s it" %
                 (mode, "accepts" if want_status == 0 else "refuses"),
                 run.returncode == want_status,
                 "aowl-regcheck --file exited %d, wanted %d\n%s"
                 % (run.returncode, want_status, out[-1200:]))
        if fragment:
            ch.check("%s: and says so, naming %r" % (mode, fragment),
                     fragment in out, out[-1200:])
    # The two revision modes are about a number rather than about validity, and
    # the number is what the manager compares. Asserted here because a `bump`
    # that stopped being newer would make the adoption test below prove nothing.
    src = json.loads(STATE["source"].decode("utf-8"))
    base = src.get("registry", {}).get("revision", 0)
    newer = json.loads(build_body("bump")[1].decode("utf-8"))
    older = json.loads(build_body("older")[1].decode("utf-8"))
    ch.check("bump: is a newer revision than the file it is built from",
             newer["registry"]["revision"] > base,
             "%r vs %r" % (newer["registry"]["revision"], base))
    ch.check("older: is an older revision than the file it is built from",
             older["registry"]["revision"] < base,
             "%r vs %r" % (older["registry"]["revision"], base))
    ch.check("bump: drops a mod, adds a mod and moves a version",
             ("aowl.brandnew" in [m["id"] for m in newer["mods"]] and
              "aowl.icebreaker" not in [m["id"] for m in newer["mods"]] and
              newer["mods"][1]["version"] == "9.9.9"))
    ch.check("download: the block it adds is the shape the schema states",
             sorted(json.loads(build_body("download")[1].decode("utf-8"))
                    ["mods"][0]["download"]) == ["sha256", "size", "url"])


def check_transport(ch, port):
    import urllib.error
    import urllib.request
    base = "http://127.0.0.1:%d" % port
    for mode in TRANSPORT_MODES:
        urllib.request.urlopen(base + "/mode/" + mode, timeout=5).read()
        if mode in ("notfound", "error"):
            want = 404 if mode == "notfound" else 500
            got = None
            try:
                got = urllib.request.urlopen(base + "/mods.json", timeout=5).status
            except urllib.error.HTTPError as exc:
                got = exc.code
            ch.check("%s: the server really answers %d" % (mode, want),
                     got == want, "it answered %r" % (got,))
            continue
        if mode == "huge":
            body = body_for("huge")[1]
            ch.check("huge: the body is over the shipped registryFetchMaxBytes",
                     len(body) > FETCH_MAX_BYTES,
                     "%d bytes against a %d byte ceiling"
                     % (len(body), FETCH_MAX_BYTES))
            # It also has to be a *registry* rather than padding, or a manager
            # that refused it would be refusing nonsense and the size limit
            # would be untested.
            doc = json.loads(body.decode("utf-8"))
            ch.check("huge: and is still a registry, not padding",
                     doc.get("schema") == "aowlspt.registry/1" and
                     len(doc.get("mods", [])) > 1000)
            continue
        if mode == "slow":
            payload, drip = body_for("slow")[1], body_for("slow")[2]
            span_ms = len(payload) * STATE["delay"] * 1000.0
            ch.check("slow: sends a byte at a time", drip)
            ch.check("slow: cannot finish inside the shipped "
                     "registryFetchTimeoutMs",
                     span_ms > FETCH_TIMEOUT_MS,
                     "%d bytes at %.3fs each is %.0f ms against a %d ms "
                     "deadline" % (len(payload), STATE["delay"], span_ms,
                                   FETCH_TIMEOUT_MS))
    urllib.request.urlopen(base + "/mode/ok", timeout=5).read()


def check_manager(ch, port, manager):
    import urllib.error
    import urllib.request
    base = "http://127.0.0.1:%d" % port

    def get(url, timeout=20):
        # `Accept-Encoding: identity`, and it has to be alone: every backend
        # answer is zlib-deflated because that is what the game's client
        # expects, and only a request that says it cannot inflate gets plain
        # text back (`aowlbackend.nim`). Without this the bodies below arrive
        # as binary and every assertion fails for a reason that has nothing to
        # do with the manager.
        req = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    status = get(manager + "/aowlspt/mods/registry")
    if not status.get("enabled"):
        ch.skip("the manager layer", "this manager has registryFetchEnabled "
                "false; point a staged manager at %s/mods.json and set it "
                "true" % base)
        return
    if base not in (status.get("url") or ""):
        ch.skip("the manager layer",
                "this manager's registryUrl is %r, not this server"
                % (status.get("url"),))
        return

    for mode in sorted(MANAGER_CASES):
        want_state, fragment = MANAGER_CASES[mode]
        urllib.request.urlopen(base + "/mode/" + mode, timeout=5).read()
        get(manager + "/aowlspt/mods/registry/fetch")
        # The route answers immediately and the fetch finishes on a later tick,
        # so the outcome is polled. The deadline is the manager's own plus a
        # margin: a state still `fetching` after that is a failure of the
        # timeout, which is itself worth failing on.
        deadline = time.time() + (FETCH_TIMEOUT_MS / 1000.0) + 10.0
        st = {}
        while time.time() < deadline:
            st = get(manager + "/aowlspt/mods/registry")
            if st.get("state") != "fetching":
                break
            time.sleep(0.25)
        ch.check("%s: the manager answers %r" % (mode, want_state),
                 st.get("state") == want_state,
                 "state=%r message=%r" % (st.get("state"), st.get("message")))
        if fragment:
            blob = (st.get("message") or "") + " " + " ".join(
                st.get("reasons") or [])
            ch.check("%s: and the reason names %r" % (mode, fragment),
                     fragment in blob, blob[:800])
        if want_state == "adopted":
            # Put the shipped file back, so the next mode is measured against
            # the same starting point rather than against whatever the last
            # adoption left in place.
            get(manager + "/aowlspt/mods/registry/revert")


def run_checks(args):
    ch = Checks()
    sys.stdout.write("fakeregistry --check: %s\n" % args.serve)

    if args.regcheck and os.path.exists(args.regcheck):
        check_documents(ch, args.regcheck,
                        args.workdir or os.path.dirname(
                            os.path.abspath(args.serve)))
    else:
        ch.skip("the document layer",
                "no aowl-regcheck at %r; pass --regcheck"
                % (args.regcheck,))

    srv = Server(("127.0.0.1", args.port), Handler)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        check_transport(ch, args.port)
        if args.manager:
            check_manager(ch, args.port, args.manager.rstrip("/"))
        else:
            ch.skip("the manager layer",
                    "no --manager URL, so the refusals themselves are not "
                    "driven; only the documents and the transport are")
    finally:
        srv.shutdown()

    sys.stdout.write("\n%d passed, %d failed, %d skipped\n"
                     % (ch.passed, ch.failed, ch.skipped))
    return 1 if ch.failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7391)
    ap.add_argument("--serve", default="registry/mods.json")
    ap.add_argument("--mode", default="ok")
    ap.add_argument("--delay", type=float, default=0.05,
                    help="seconds between bytes in `slow` mode")
    ap.add_argument("--check", action="store_true",
                    help="assert the refusals rather than serving forever")
    ap.add_argument("--regcheck", default="installer/build/aowl-regcheck.exe",
                    help="aowl-regcheck.exe, for the document layer of --check")
    ap.add_argument("--manager", default="",
                    help="a running manager's base URL, for the end-to-end "
                         "layer of --check")
    ap.add_argument("--workdir", default="",
                    help="where --check writes the bodies it generates")
    args = ap.parse_args()

    with open(args.serve, "rb") as fh:
        STATE["source"] = fh.read()
    STATE["mode"] = args.mode
    STATE["delay"] = args.delay

    if args.check:
        sys.exit(run_checks(args))

    srv = Server(("127.0.0.1", args.port), Handler)
    sys.stderr.write(
        "fakeregistry: http://127.0.0.1:%d/mods.json serving %s in mode %s\n"
        % (args.port, args.serve, args.mode))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
