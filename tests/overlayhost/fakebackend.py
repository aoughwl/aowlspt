"""A stand-in for the aowlspt backend's /aowlspt/mods routes.

The real routes are being built on the server side and their schema is not
settled, so the overlay's HTTP client and its JSON reader need something to be
exercised against that is not the real thing. This serves the shape the overlay
expects and records the POSTs it receives, so a run of

    python fakebackend.py 7261 &
    overlayhost.exe --headless --port 7261 --shot shots

proves the whole path: poll, parse, render backend-sourced rows, click, POST.

Only used by the test host. Nothing ships with it.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODS = [
    {"guid": "aowl.clientprobe", "name": "clientprobe", "version": "0.1.0",
     "enabled": True},
    {"guid": "aowl.sway", "name": "SWAY", "version": "1.4.2", "enabled": True},
    {"guid": "aowl.efmb", "name": "EscapeFromMyBasement", "version": "0.3.0",
     "enabled": False},
    {"guid": "aowl.backendonly", "name": "InstalledNotLoaded", "version": "9.9.9",
     "enabled": False},
]

POSTS = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/aowlspt/mods":
            self._send({"mods": MODS})
        elif self.path == "/posts":
            self._send(POSTS)
        else:
            self.send_error(404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        POSTS.append({"path": self.path, "body": body})
        # Reflect the change, so the next poll shows the overlay's own edit
        # coming back from the server rather than the local optimistic flip.
        want = "true" in body
        guid = self.path.split("/")[3] if len(self.path.split("/")) > 3 else ""
        for m in MODS:
            if m["guid"] == guid:
                m["enabled"] = want
        self._send({"ok": True})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7261
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
