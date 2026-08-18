"""A stand-in for `mods/manager`'s panel routes.

Not a guess any more. The rows and the reply shapes below are the ones the real
manager produces -- `tests/overlayhost/panel.golden.json` is a capture taken off
`aowlspt-backend` with `mods/manager` loaded by `realbackend.py`, and
`--golden` serves that file verbatim. What is hand-written here is only the
*behaviour*: what the manager does between the POST and the next GET, which a
static capture cannot show.

    python fakebackend.py 7261 &
    overlayhost.exe --headless --port 7261 --shot shots

proves the whole path: poll, parse, render backend-sourced rows, click, POST,
see the answer come back on the next poll.

Three control modes, because the panel has to be honest in all three and they
are the three the manager can actually be in:

    --control absent    no host answered the probe. Every change is deferred,
                        `live` is null, and a toggled row comes back
                        `restart:true`. This is every host that exists today.
    --control present   a host answered and can unload. A toggle is applied
                        live: the row comes back `live:false` and `restart`
                        stays false -- the row greys out instead of starring.
    --control stubborn  a host that answered but refuses to unload this
                        particular mod (no `mfHotReloadable`, an unrevertable
                        patch). The change is recorded, `restart:true`, and the
                        mod stays live. The state the `*` exists for.

Only used by the test host. Nothing ships with it.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "panel.golden.json")

# The registry's view, in the manager's row shape. `enabled` is what the
# selection resolves to; `live` is what the host says is running (null when no
# host has said anything); `restart` is per-mod and starts false.
ROWS = [
    {"guid": "aowl.tarkov", "id": "aowl.tarkov", "name": "Tarkov Emulator",
     "version": "0.1.0", "enabled": True, "live": None, "restart": False,
     "verdict": "loaded", "reason": "enabled by aowl.list.core"},
    {"guid": "aowl.sway", "id": "aowl.sway", "name": "SWAY",
     "version": "1.4.2", "enabled": True, "live": None, "restart": False,
     "verdict": "loaded", "reason": "enabled by aowl.list.core"},
    {"guid": "aowl.efmb", "id": "aowl.efmb", "name": "EscapeFromMyBasement",
     "version": "0.3.0", "enabled": False, "live": None, "restart": False,
     "verdict": "not-selected", "reason": "no active list mentions it"},
    {"guid": "aowl.backendonly", "id": "aowl.backendonly",
     "name": "InstalledNotLoaded", "version": "9.9.9", "enabled": False,
     "live": None, "restart": False,
     "verdict": "disabled", "reason": "you turned it off"},
]

CONTROL = "absent"
POSTS = []


def row(guid):
    for r in ROWS:
        if r["guid"] == guid:
            return r
    return None


def panel():
    body = {
        "ok": True,
        "schema": "aowlspt.panel/1",
        "side": "server",
        "control": CONTROL,
        "liveKnown": CONTROL == "present" or CONTROL == "stubborn",
        "summary": "%d of %d registry mods resolve on the server side"
                   % (sum(1 for r in ROWS if r["enabled"]), len(ROWS)),
        # Last, and it has to stay last: the overlay's reader skips to the
        # `"mods"` key and then treats every `{`..`}` after it as a row, so a
        # wrapper key placed after the array would be read as part of the last
        # one. The real manager orders it the same way for the same reason.
        "mods": ROWS,
    }
    return body


def apply_toggle(guid, want):
    """What the manager does between the POST and the next GET.

    The mod half of this is `applySelection` in `mods/manager/manager.nim` and
    `requestUnload` in `mgr/control.nim`; the outcome names are that module's
    `ApplyOutcome`.
    """
    r = row(guid)
    if r is None:
        return {"ok": False, "error": "no mod called %s in the registry" % guid}
    r["enabled"] = want

    # `unknown` -- the probe is out and nothing has answered yet -- behaves
    # exactly like `absent` here, because `mgr/control.requestLoad` defers on
    # anything that is not `present`. It is a real state and a short one: the
    # manager turns it into `absent` on a timer.
    if CONTROL == "absent" or CONTROL == "unknown":
        outcome = "deferred"
        message = ("this host has no live mod control, so the change is saved "
                   "and takes effect when it restarts")
        r["live"] = None
        r["restart"] = True
    elif CONTROL == "stubborn":
        outcome = "deferred"
        message = "it is not marked hot-reloadable, so it cannot be taken out"
        r["live"] = True
        r["restart"] = True
    else:
        outcome = "applied"
        message = "the host %sed it" % ("load" if want else "unload")
        r["live"] = want
        r["restart"] = False

    return {
        "ok": True,
        "id": guid,
        "guid": guid,
        "action": "enable" if want else "disable",
        "control": CONTROL,
        "row": r,
        "apply": {
            "ok": True,
            "requested": 0,
            "deferred": 1 if outcome == "deferred" else 0,
            "restartRequired": outcome == "deferred",
            "control": CONTROL,
            "results": [{"id": guid,
                         "action": "load" if want else "unload",
                         "outcome": outcome,
                         "message": message}],
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        # Deliberately *not* deflated. `aowlspt-backend` deflates every body it
        # sends and the overlay cannot read that -- which is the one change this
        # work needs in a file it does not own, written up in
        # host/Aowlspt.Overlay/README.md. Serving it compressed here would hide
        # the problem behind a test that passes.
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/aowlspt/mods/panel", "/aowlspt/mods"):
            self._send(panel())
        elif self.path == "/posts":
            self._send(POSTS)
        elif self.path == "/rows":
            self._send(ROWS)
        else:
            self.send_error(404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        POSTS.append({"path": self.path,
                      "body": body,
                      "accept-encoding": self.headers.get("Accept-Encoding", "")})
        prefix = "/aowlspt/mods/toggle/"
        if self.path.startswith(prefix):
            guid = self.path[len(prefix):]
            want = "true" in body
            self._send(apply_toggle(guid, want))
        else:
            self.send_error(404)


if __name__ == "__main__":
    port = 7261
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--control" and i + 1 < len(args):
            CONTROL = args[i + 1]
            i += 2
        elif args[i] == "--golden":
            with open(GOLDEN, encoding="utf-8") as f:
                captured = json.load(f)
            # Rows only. The control state is behaviour, not shape, and it
            # comes from --control -- a capture taken in the first 750 ms of a
            # backend's life records `unknown`, which is a real state and the
            # least interesting one to test in.
            ROWS[:] = captured["mods"]
            i += 1
        else:
            port = int(args[i])
            i += 1
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
