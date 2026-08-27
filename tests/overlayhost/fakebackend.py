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
#
# The first row is protected, which is what the real manager answers about
# itself: `isProtected` in `mods/manager/manager.nim` puts `"protected": true`
# on its own panel row, because a selection that can switch off the mod serving
# every route on this panel is a selection nothing left running can undo. The
# hand-written rows carried no `protected` key at all before, so the overlay's
# `KEEP` label and its local refusal of SPACE had no stand-in that exercised
# them -- the test host said as much and passed anyway.
#
# Four of the five rows carry what the *client* host said about them, and one
# carries nothing at all. That last one is not an oversight: a guid with no
# `clientLive` key is how this whole protocol says "no answer yet", the overlay
# has to draw it as unknown rather than as off, and a fixture in which every row
# has an answer cannot tell the two apart. `aowl.manager` is the row with no
# answer -- a server-side mod, which the game has no reason to speak about and
# whose `live` comes from `mgr/control` instead; `CLIENT` below is the wrapper
# that says why the silence might yet end.
#
# `aowl.sway` is the interesting one. The test host pushes it in through
# `aowl_ov_set_mod` as loaded in this process, and the client host's own ledger
# then says it is not -- same process, later fact. The panel is required to
# believe the later one. Before the report existed the overlay pinned a
# host-pushed row's `loaded` at 1 forever, which meant a mod the host had
# unloaded read `running yes` until the game was restarted.
ROWS = [
    {"guid": "aowl.manager", "id": "aowl.manager", "name": "Mod Manager",
     "version": "1.0.0", "enabled": True, "live": True, "restart": False,
     "protected": True,
     "verdict": "loaded", "reason": "enabled by aowl.list.core"},
    {"guid": "aowl.tarkov", "id": "aowl.tarkov", "name": "Tarkov Emulator",
     "version": "0.1.0", "enabled": True, "live": True, "restart": False,
     "protected": False,
     "clientLive": True, "clientWant": True, "clientOutcome": "settled",
     "verdict": "loaded", "reason": "enabled by aowl.list.core"},
    {"guid": "aowl.sway", "id": "aowl.sway", "name": "SWAY",
     "version": "1.4.2", "enabled": True, "live": False, "restart": False,
     "protected": False,
     "clientLive": False, "clientWant": True, "clientOutcome": "skipped",
     "clientCode": "nofile",
     "verdict": "loaded",
     "reason": "enabled by aowl.list.core -- the client host did not try -- "
               "it is not installed on the client side"},
    {"guid": "aowl.efmb", "id": "aowl.efmb", "name": "EscapeFromMyBasement",
     "version": "0.3.0", "enabled": False, "live": False, "restart": False,
     "protected": False,
     "clientLive": False, "clientWant": False, "clientOutcome": "settled",
     "verdict": "not-selected", "reason": "no active list mentions it"},
    {"guid": "aowl.backendonly", "id": "aowl.backendonly",
     "name": "InstalledNotLoaded", "version": "9.9.9", "enabled": False,
     "live": True, "restart": False,
     "protected": False,
     "clientLive": True, "clientWant": False, "clientOutcome": "refused",
     "clientCode": "noteardown",
     "verdict": "disabled",
     "reason": "you turned it off -- the client host tried and could not -- "
               "that host cannot take any mod out while it runs"},
]

# The wrapper's half. `clientMore` is what turns "this row has no answer" into
# "this row has no answer *yet*", and it is the difference between a panel that
# says wait and a panel that says nothing.
CLIENT = {
    "clientHost": True,
    "clientSession": "b7f0",
    "clientSeq": 12,
    "clientRows": 4,
    "clientMore": True,
}

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
        **CLIENT,
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
    # The manager's own refusal, from `routeToggle` in
    # `mods/manager/manager.nim`: it takes `{"enabled":true}` on a protected mod
    # like any other row and refuses only the *off* direction. The overlay is
    # supposed to answer this one locally and never send it, so a stand-in that
    # honoured it would let a regression in the panel pass silently -- the POST
    # would go out, the row would flip, and nothing in the run would notice.
    if r.get("protected") and not want:
        return {"ok": False,
                "error": "%s is what you are using to ask. Switching it off "
                         "takes every /aowlspt/mods route with it, and nothing "
                         "running could switch it back on -- not even a "
                         "restart, because the selection would be on disk. "
                         "Remove it from the install if you want it gone."
                         % guid}
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

    # And what the client host would have said about it on its next poll, for
    # the rows it has a record for. Left alone for the rows it has not: a toggle
    # cannot make the game answer about a mod it has never mentioned, and a
    # stand-in that grew a `clientLive` here would be teaching the panel that
    # clicking a switch is a source of truth about the other process.
    if "clientLive" in r:
        if outcome == "applied":
            r["clientLive"] = want
            r["clientWant"] = want
            r["clientOutcome"] = "changed"
            r.pop("clientCode", None)
        else:
            r["clientWant"] = want
            r["clientOutcome"] = "on-restart"
            r["clientCode"] = "noteardown"

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


# ---------------------------------------------------------------------------
# The other three routes the panel reads
#
# `/panel` alone is not a mod manager: it carries no `from` or `explicit` (which
# list decided this, and did you), no named lists, and nothing about what was
# excluded. The overlay merges four routes, so a stand-in that serves one proves
# only the easy quarter.
#
# The shapes here are the real manager's, from `mods/manager/manager.nim`:
# `decisionJson` for a `/list` row, `routeLists` for a list, `routeConflicts`
# for an exclusion, `changeReply` for a clear, `applySelection` for an apply.
# ---------------------------------------------------------------------------

# Which list last decided each mod, and whether you overrode it. Parallel to
# ROWS by guid.
DECIDED = {
    "aowl.manager": ("aowl.list.core", False),
    "aowl.tarkov": ("aowl.list.core", False),
    "aowl.sway": ("aowl.list.core", False),
    "aowl.efmb": ("", False),
    "aowl.backendonly": ("override", True),
}

LISTS = [
    {"id": "aowl.list.core", "name": "Core", "author": "aowlspt",
     "version": "1.0.0",
     "description": "The mod manager and the game server, and nothing else.",
     "inherits": [],
     "entries": [{"id": "aowl.manager", "enabled": True,
                  "note": "protected; it is what serves this panel"},
                 {"id": "aowl.tarkov", "enabled": True,
                  "note": "the emulator; nothing works without it"},
                 {"id": "aowl.sway", "enabled": True}]},
    {"id": "aowl.list.raidnight", "name": "Raid Night", "author": "savannt",
     "version": "1.0.0",
     "description": "Core with the bots turned up and a map that is not in the "
                    "base game.",
     "inherits": ["aowl.list.core"],
     "entries": [{"id": "aowl.efmb", "enabled": True},
                 {"id": "aowl.backendonly", "enabled": False,
                  "note": "server-side only; there is nothing here for it"}]},
]
ACTIVE = ["aowl.list.core"]


def decisions():
    mods = []
    for r in ROWS:
        frm, explicit = DECIDED.get(r["guid"], ("", False))
        mods.append({"id": r["guid"], "name": r["name"],
                     "verdict": r["verdict"], "reason": r["reason"],
                     "from": frm, "explicit": explicit,
                     "order": 0 if r["enabled"] else -1})
    return {"ok": True, "side": "server",
            "order": [r["guid"] for r in ROWS if r["enabled"]],
            "mods": mods, "problems": []}


def lists():
    return {"ok": True, "active": ACTIVE, "lists": LISTS}


def conflicts():
    # One of each kind the resolver can produce, so the ISSUES view has
    # something to be right or wrong about. A stand-in that always answers
    # "nothing is wrong" cannot fail.
    excluded = [r for r in ROWS
                if r["verdict"] not in ("loaded", "disabled", "not-selected",
                                        "wrong-side")]
    return {"ok": len(excluded) == 0,
            "excluded": [{"id": r["guid"], "name": r["name"],
                          "verdict": r["verdict"], "reason": r["reason"],
                          "from": DECIDED.get(r["guid"], ("", False))[0],
                          "explicit": DECIDED.get(r["guid"], ("", False))[1],
                          "order": -1}
                         for r in excluded],
            "problems": ([] if CONTROL == "present" else
                         ["no host answered the control probe, so this host has "
                          "no live enable/disable"])}


def apply_all():
    results = []
    deferred = 0
    for r in ROWS:
        if not r["enabled"]:
            continue
        if CONTROL == "present":
            outcome, msg = "applied", "%s is already loaded" % r["guid"]
        else:
            outcome, msg = "deferred", ("this host has no live mod control, so "
                                        "the change is saved and takes effect "
                                        "when it restarts")
            deferred += 1
        results.append({"id": r["guid"], "action": "load",
                        "outcome": outcome, "message": msg})
    out = {"ok": True, "requested": 0, "deferred": deferred,
           "restartRequired": deferred > 0, "control": CONTROL,
           "results": results}
    if deferred:
        out["note"] = ("the selection is saved; %d change(s) cannot take effect "
                       "until the host restarts" % deferred)
    return out


def clear(guid):
    r = row(guid)
    if r is None:
        return {"ok": False, "error": "no mod called %s in the registry" % guid}
    frm, _ = DECIDED.get(guid, ("", False))
    DECIDED[guid] = (frm, False)
    return {"ok": True, "id": guid, "action": "clear",
            "decision": {"id": guid, "name": r["name"], "verdict": r["verdict"],
                         "reason": r["reason"], "from": frm, "explicit": False,
                         "order": 0},
            "loaded": sum(1 for x in ROWS if x["enabled"]),
            "control": CONTROL,
            "inEffect": ("apply it with /aowlspt/mods/apply"
                         if CONTROL == "present" else
                         "saved, but this host cannot load or unload a mod "
                         "while it runs; it takes effect on the next start"),
            "problems": []}


def select(list_id):
    if not any(l["id"] == list_id for l in LISTS):
        return {"ok": False, "error": "no list called %s in the registry" % list_id}
    ACTIVE[:] = [list_id]
    return {"ok": True, "active": list_id,
            "loaded": sum(1 for x in ROWS if x["enabled"]), "problems": []}



# ---------------------------------------------------------------------------
# The SETTINGS surface, deliberately DEEP.
#
# The overlay's settings screen had two levels and now has a tree, so the
# fixture has to have more than two or the nesting is untested by construction.
# `aowl.deep` declares rows at depths 1, 2, 3 and 4 -- including the exact
# "Player / Health" the report named, now as "Player > Health > Regeneration".
#
# `path` is emitted the way `aowl/src/aowlspt/settings.nim` emits it, so the
# overlay is parsing the real wire shape and not a convenience.
# ---------------------------------------------------------------------------

def _row(key, label, path, kind="bool", value=True, desc=""):
    r = {"key": key, "label": label, "type": kind, "value": value,
         "default": value, "implemented": True, "path": path,
         "category": "/".join(path[:1]), "subcategory": "/".join(path[1:])}
    if desc:
        r["description"] = desc
    return r

def _num(key, label, path, value, lo=None, hi=None, step=None, kind="float"):
    """A numeric row. `lo`/`hi` omitted means the schema declares NO range, and
    the overlay must draw a stepper plus a type box rather than inventing one."""
    r = {"key": key, "label": label, "type": kind, "value": value,
         "default": value, "implemented": True, "path": path,
         "category": "/".join(path[:1]), "subcategory": "/".join(path[1:])}
    if lo is not None:
        r["min"] = lo
    if hi is not None:
        r["max"] = hi
    if step is not None:
        r["step"] = step
    return r


DEEP_ROWS = (
    [_row("hp%d" % i, "Regen tick %d" % i,
          ["Player", "Health", "Regeneration"]) for i in range(4)] +
    [_row("hd%d" % i, "Damage rule %d" % i,
          ["Player", "Health", "Damage", "Bleeding"]) for i in range(3)] +
    [_row("pi%d" % i, "Inertia %d" % i, ["Player", "Movement"]) for i in range(5)] +
    [_row("bt%d" % i, "Bot cap %d" % i, ["Bots"]) for i in range(6)] +
    # --- the numeric controls, one per range shape the overlay must tell apart.
    #
    # `sliderok` is the only one of these that may draw a slider. The other four
    # are the range shapes that have to FALL BACK, and a fixture with only a
    # well-formed range cannot catch a panel that sliders everything.
    # An INT with a wide-but-addressable range, and both of those are for the
    # INSTRUMENT rather than for the panel. The back-buffer glyph decoder
    # ignores any run shorter than 6 characters, so a value the test types has
    # to BE at least 6 digits to be readable back off the screen at all -- a
    # 0..100 slider can only ever hold a 1-to-3 digit value, and "is 42 on
    # screen" is unanswerable, not false. 999999/step 10 is 99,999 steps, just
    # inside AOWL_OV_SLIDER_MAX_STEPS, so it still legitimately draws a slider.
    [_num("sliderok",  "Slider with a range",   ["Numbers"], 25,
          lo=0, hi=999999, step=10, kind="int"),
     _num("norange",   "No range at all",       ["Numbers"], 7.0),
     _num("onlymax",   "Only a max declared",   ["Numbers"], 3.0, hi=10.0),
     _num("onlymin",   "Only a min declared",   ["Numbers"], 3.0, lo=1.0),
     _num("inverted",  "Max below min",         ["Numbers"], 3.0,
          lo=10.0, hi=2.0),
     _num("astronomic", "Range too wide to drag", ["Numbers"], 5.0,
          lo=0.0, hi=1.0e9, step=1.0, kind="int")] +
    # --- rows that are DECLARED BUT NOT IMPLEMENTED. Hidden by default.
    #
    # A whole group of them ("Cultists"), so the check that no group is left
    # empty has something to be wrong about, plus one mixed into a group that
    # also has implemented rows, so hiding cannot simply drop whole groups.
    [dict(_row("cc%d" % i, "Cultist circle %d" % i, ["Cultists"]),
          implemented=False) for i in range(3)] +
    [dict(_row("btx", "Bot cap NOT DONE", ["Bots"]), implemented=False)] +
    [_row("zz", "Ungrouped switch", [])]
)
# The last row declares NO path at all: the overlay must still put it under a
# NAMED group. A fixture where every row is well-formed cannot catch the
# nameless-group defect.
for _k in ("path", "category", "subcategory"):
    DEEP_ROWS[-1].pop(_k, None)

UIHUB_ROWS = [
    {"key": "launchHint", "label": "Show the launch hint", "type": "bool",
     "value": True, "default": True, "implemented": True,
     "path": ["Overlay", "Launch"], "category": "Overlay",
     "subcategory": "Launch"}
]

# A page every one of whose rows is unimplemented. `done: 0` in the index says
# so WITHOUT the page being fetched, which is how 28 SPT pages are hidden for
# the cost of one index read. The overlay must not list it with the filter on --
# and must not have fetched it to find out.
DEAD_ROWS = [dict(_row("d%d" % i, "Placeholder %d" % i, ["Nothing"]),
                  implemented=False) for i in range(4)]

# How many times each page was actually fetched, so a check can assert the
# NEGATIVE "the hidden page was never requested" rather than only that it is
# absent from the nav.
FETCHES = {}


def _impl_count(rows):
    return sum(1 for r in rows if r.get("implemented"))


def settings_index():
    # `done` is now sent for MOD pages too -- see `onIndexQuery` in
    # `aowl/src/aowlspt/settings.nim`. A page with count > 0 and done == 0 is
    # one the overlay may hide without loading it.
    return {"mods": [{"guid": "aowl.deep", "name": "Deep tree fixture",
                      "count": len(DEEP_ROWS), "done": _impl_count(DEEP_ROWS)},
                     {"guid": "aowl.uihub", "name": "Browser Settings Page",
                      "count": len(UIHUB_ROWS), "done": _impl_count(UIHUB_ROWS)},
                     {"guid": "aowl.dead", "name": "Nothing Implemented",
                      "count": len(DEAD_ROWS), "done": 0}]}


def apply_setting(guid, key, value):
    """Store a write the way a real mod does -- into the row the next GET
    serves. Without this the panel could be checked only against its own
    optimistic copy, which is a check that cannot fail (CLAUDE.md 9b): the row
    would read back the value the panel wrote into itself whether or not one
    byte ever reached the backend."""
    rows = {"aowl.deep": DEEP_ROWS, "aowl.uihub": UIHUB_ROWS,
            "aowl.dead": DEAD_ROWS}.get(guid)
    if rows is None:
        return False
    for r in rows:
        if r["key"] == key:
            r["value"] = value
            return True
    return False


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
        if self.path == "/aowlspt/settings/index":
            self._send(settings_index())
            return
        for guid, rows in (("aowl.deep", DEEP_ROWS), ("aowl.uihub", UIHUB_ROWS),
                           ("aowl.dead", DEAD_ROWS)):
            if self.path.startswith("/aowlspt/settings/" + guid):
                FETCHES[guid] = FETCHES.get(guid, 0) + 1
                self._send(rows)
                return
        if self.path == "/fetches":
            self._send(FETCHES)
            return
        if self.path in ("/aowlspt/mods/panel", "/aowlspt/mods"):
            self._send(panel())
        elif self.path == "/aowlspt/mods/list":
            self._send(decisions())
        elif self.path == "/aowlspt/mods/lists":
            self._send(lists())
        elif self.path == "/aowlspt/mods/conflicts":
            self._send(conflicts())
        elif self.path == "/aowlspt/mods/apply":
            self._send(apply_all())
        elif self.path.startswith("/aowlspt/mods/clear/"):
            POSTS.append({"path": self.path, "body": "", "accept-encoding":
                          self.headers.get("Accept-Encoding", "")})
            self._send(clear(self.path[len("/aowlspt/mods/clear/"):]))
        elif self.path.startswith("/aowlspt/mods/select/"):
            POSTS.append({"path": self.path, "body": "", "accept-encoding":
                          self.headers.get("Accept-Encoding", "")})
            self._send(select(self.path[len("/aowlspt/mods/select/"):]))
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
        # A SETTINGS WRITE. Applied to the served rows, so the next GET returns
        # what was actually stored and the panel can be checked by INDEPENDENT
        # RE-READ rather than against its own optimistic copy.
        #
        # Deliberately strict about the body: fact #135 is that a chunked POST
        # to a settings write is treated as BODYLESS and answered 200 with the
        # schema UNCHANGED -- success by status code, no effect. So a request
        # that arrives with no parseable body is answered 400 HERE, loudly,
        # rather than 200. A fixture that shrugs at an empty body reproduces the
        # exact bug the real backend has and calls it a pass.
        sp = "/aowlspt/settings/"
        if self.path.startswith(sp) and "/spt/" not in self.path:
            guid = self.path[len(sp):]
            try:
                o = json.loads(body)
                key, value = o["key"], o["value"]
            except Exception as e:
                self.send_error(400, "unparseable settings write: %s" % e)
                return
            if apply_setting(guid, key, value):
                self._send({"ok": True, "key": key, "value": value})
            else:
                self.send_error(404, "no such key %r on %r" % (key, guid))
            return
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
            # Rows, and the client host's wrapper. The control state is
            # behaviour, not shape, and it comes from --control -- a capture
            # taken in the first 750 ms of a backend's life records `unknown`,
            # which is a real state and the least interesting one to test in.
            #
            # The `client*` scalars are *shape*, and taking them is what makes
            # `--golden` exercise the same path the hand-written rows do:
            # `realbackend.py` polls the client route with a report before it
            # captures, so the capture carries a real ledger. Serving the
            # capture's rows under a hand-written `clientHost: True` would be
            # the worst of both -- a wrapper that says four rows were reported
            # over rows that say nothing.
            ROWS[:] = captured["mods"]
            for key in CLIENT:
                if key in captured:
                    CLIENT[key] = captured[key]
            i += 1
        else:
            port = int(args[i])
            i += 1
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
