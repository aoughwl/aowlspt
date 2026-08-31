#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""modctl.py -- mod lifecycle state and control, for the inspector REPL.

WHERE THE TRUTH LIVES (surveyed, not assumed). Mod state is NOT in the game
host. `docs/MOD-ENABLE-PATH.md` names four gates and `mods/manager/manager.nim`
serves all of them over HTTP:

    gate 1  the DLL is on disk under <install>\\aowlspt\\mods\\<dir>\\<lib>
    gate 2  `registry/mods.json` names it, with "client" in `sides`
    gate 3  something SELECTS it (an active list, or a user override)
    gate 4  pipeline range / requires / conflicts

Gates 2-4 are exactly what `GET /aowlspt/mods/list` reports per row, as
`verdict` + `reason` (`mgr/resolve.verdictName`: loaded, disabled,
not-selected, wrong-side, pipeline, missing-dependency, conflict, cycle).
Gate 1 is a filesystem question this module answers locally against
`registry/mods.json`'s `artifact.dir` / `artifact.library`.

So none of this needs a new game-thread verb, no IL2CPP, no new detour. That
is deliberate: putting an HTTP request on the Unity main thread to answer
"which mods are on" would be the worst possible way to get this answer.

THREE OUTCOMES, NEVER TWO (CLAUDE.md 9b). Every classification here returns
one of PASS / FAIL / INCONCLUSIVE and, when it is not PASS, a NAMED refusal:

    BACKEND_UNREACHABLE   nobody answered; we could not look
    NOT_IN_REGISTRY       gate 2; the id is not a mod this manager knows
    DLL_MISSING           gate 1
    NOT_SELECTED          gate 3, the manager's own verdict
    BLOCKED               gate 4 (pipeline/dep/conflict/cycle), verdict carried
    NO_CLIENT_ANSWER      the manager has heard nothing from the client host
                          about this guid -- `clientLive` is ABSENT from the
                          row. manager.nim is explicit that absence means "no
                          answer yet"; rendering that as "not loaded" is the
                          bug this field exists to prevent.
    RELOAD_UNSUPPORTED    no live hot-reload entry point exists here

The last one matters: `GET /aowlspt/mods/reload` is a REGISTRY reload (re-read
mods.json from disk), NOT the quiesce -> detach -> unload -> load -> re-arm
cycle. Those are different operations and calling the first when you asked for
the second is precisely the "approximate" behaviour we refuse to ship. See
`reload()`.
"""
import json
import os
import ssl
import urllib.error
import urllib.request

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"
# docs/MOD-ENABLE-PATH.md writes https://127.0.0.1 (port 80, NOT 6969). The
# client's own TLS is self-signed, so plain http is tried first and https
# second; whichever answered is reported, never guessed.
BASES = ("http://127.0.0.1", "https://127.0.0.1")

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


class Refusal(Exception):
    """A named refusal. `.name` is the machine-readable one; str() is the
    sentence a human reads. Never raised without both."""

    def __init__(self, name, message):
        Exception.__init__(self, message)
        self.name = name
        self.outcome = INCONCLUSIVE


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def http_get(path, bases=BASES, timeout=6.0, opener=None):
    """GET `path` off the first base that answers. Returns (base, body-text).
    Raises Refusal(BACKEND_UNREACHABLE) naming every base tried and why each
    failed -- a bare "backend unreachable" is not an answer."""
    opener = opener or (lambda url: urllib.request.urlopen(
        url, timeout=timeout, context=_ctx()).read().decode("utf-8", "replace"))
    why = []
    for base in bases:
        url = base.rstrip("/") + path
        try:
            return base, opener(url)
        except Exception as e:  # noqa: BLE001 -- every failure mode is reported
            why.append("%s: %s" % (url, e.__class__.__name__ + ": " + str(e)))
    raise Refusal("BACKEND_UNREACHABLE",
                  "no aowlspt backend answered. Tried -- " + " | ".join(why))


def registry_path(repo=None):
    repo = repo or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo, "registry", "mods.json")


def load_registry(path=None, text=None):
    """id -> {dir, library, sides, name}. `text` is for tests."""
    if text is None:
        p = path or registry_path()
        if not os.path.isfile(p):
            raise Refusal("NO_REGISTRY", "registry/mods.json not found at " + p)
        with open(p, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    doc = json.loads(text)
    out = {}
    for m in doc.get("mods", []):
        art = m.get("artifact") or {}
        out[m.get("id")] = {
            "dir": art.get("dir"),
            "library": art.get("library"),
            "sides": m.get("sides") or [],
            "name": m.get("name"),
        }
    return out


def dll_present(entry, live_dir=None):
    """Gate 1, three-valued. True / False / None where None means we could not
    look (the entry names no artifact, or the install dir is not here)."""
    live = live_dir or os.environ.get("AOWLSPT_LIVE", LIVE_DEFAULT)
    if not entry or not entry.get("dir") or not entry.get("library"):
        return None
    if not os.path.isdir(live):
        return None
    return os.path.isfile(os.path.join(live, "mods", entry["dir"], entry["library"]))


# gate 4 verdicts: the manager resolved it and said no, for a structural reason
_GATE4 = ("wrong-side", "pipeline", "missing-dependency", "conflict", "cycle")


def classify(row, reg_entry=None, live_dir=None):
    """One mod row -> a verdict dict. `row` is a `/aowlspt/mods/list` entry.

    This is the whole point of the `mods` verb: it names WHICH GATE is
    blocking, because "off" is the answer that made `aowl.ammoloading` look
    broken for a day when the platform had simply never selected it.
    """
    mid = row.get("id") or row.get("guid")
    verdict = row.get("verdict") or "unknown"
    reason = row.get("reason") or ""
    on_disk = dll_present(reg_entry, live_dir)

    # `clientLive` ABSENT (not false) == the client host has said nothing.
    has_client = "clientLive" in row
    live = row.get("clientLive") if has_client else None

    out = {
        "id": mid,
        "name": row.get("name") or (reg_entry or {}).get("name"),
        "want": bool(row.get("enabled")),
        "verdict": verdict,
        "reason": reason,
        "on_disk": on_disk,
        "live": live,
        "client_outcome": row.get("clientOutcome"),
        "client_code": row.get("clientCode"),
        "client_message": row.get("clientMessage"),
        # AOWLSPT_MOD_HOT_RELOADABLE, as the client host reports it
        # (`host/common/modcontrol.nim:ModHotReloadable`). Since ba46898 this
        # GATES the unload: a mod that has not claimed it is refused BY NAME
        # and stays loaded. Three-valued for the same reason `live` is --
        # `mgr/control.nim` defaults it to false when the host has said
        # nothing, so absence from the row is "not reported", not "no".
        "hot_reloadable": row.get("hotReloadable"),
    }

    # Gates are reported in the order they are evaluated by the platform, so
    # the FIRST one that is shut is the one named.
    if on_disk is False:
        out.update(outcome=FAIL, gate=1, refusal="DLL_MISSING",
                   detail="gate 1: no %s\\%s under the install's mods dir" %
                          (reg_entry.get("dir"), reg_entry.get("library")))
        return out
    if verdict == "not-selected" or verdict == "disabled":
        out.update(outcome=FAIL, gate=3, refusal="NOT_SELECTED",
                   detail="gate 3: the manager says %r -- %s. Enable it with "
                          "`modenable %s`, or add it to a list in "
                          "registry/mods.json. Do NOT hand-edit "
                          "aowlspt-selection.json." % (verdict, reason or
                                                       "no reason given", mid))
        return out
    if verdict in _GATE4:
        out.update(outcome=FAIL, gate=4, refusal="BLOCKED",
                   detail="gate 4: verdict %r -- %s" % (verdict, reason or
                                                        "no reason given"))
        return out
    if verdict != "loaded":
        out.update(outcome=INCONCLUSIVE, gate=None, refusal="UNKNOWN_VERDICT",
                   detail="the manager returned a verdict this tool has no "
                          "wording for: %r (%s). Printed verbatim rather than "
                          "guessed at." % (verdict, reason))
        return out

    # Selected. Now: is it actually RUNNING? Only the client host can say, and
    # silence is not a no.
    if not has_client:
        out.update(outcome=INCONCLUSIVE, gate=None, refusal="NO_CLIENT_ANSWER",
                   detail="selected by the manager, but the client host has "
                          "said nothing about this guid -- `clientLive` is "
                          "absent from the row, which this protocol uses to "
                          "mean NO ANSWER YET, not 'not loaded'. Is the game "
                          "running?")
        return out
    if live:
        out.update(outcome=PASS, gate=None, refusal=None,
                   detail="selected and the client host reports it LIVE" +
                          (" (%s)" % out["client_outcome"] if out["client_outcome"] else ""))
        return out
    out.update(outcome=FAIL, gate=None, refusal="SELECTED_BUT_NOT_LIVE",
               detail="the manager selected it and the client host says it is "
                      "NOT live%s%s" %
                      (" -- outcome %s" % out["client_outcome"] if out["client_outcome"] else "",
                       ": " + out["client_message"] if out["client_message"] else ""))
    return out


def fetch_rows(get=http_get):
    base, body = get("/aowlspt/mods/list")
    try:
        doc = json.loads(body)
    except ValueError as e:
        raise Refusal("BAD_BACKEND_REPLY",
                      "%s/aowlspt/mods/list did not return JSON (%s). First "
                      "120 bytes: %r" % (base, e, body[:120]))
    if not doc.get("ok"):
        raise Refusal("BAD_BACKEND_REPLY",
                      "%s/aowlspt/mods/list answered ok=false" % base)
    return base, doc.get("mods", [])


def list_mods(pattern=None, get=http_get, registry=None, live_dir=None):
    """The `mods` verb. Returns (rows, batch_outcome). Never raises for a mod
    being off -- that is a per-row FAIL, which is data. Raises Refusal only
    when we could not LOOK."""
    _base, raw = fetch_rows(get)
    reg = registry if registry is not None else load_registry()
    rows = []
    for r in raw:
        mid = r.get("id") or r.get("guid") or ""
        if pattern and pattern.lower() not in mid.lower():
            continue
        rows.append(classify(r, reg.get(mid), live_dir))
    if not rows:
        raise Refusal("NO_SUCH_MOD",
                      "no mod id contains %r. `mods` with no filter lists "
                      "every id the manager knows." % pattern)
    return rows, roll_up([r["outcome"] for r in rows])


def roll_up(outcomes):
    """FAIL > INCONCLUSIVE > PASS, matching the inspector's BATCH VERDICT
    precedence. No outcomes at all -> None (no verdict), never PASS."""
    if not outcomes:
        return None
    if FAIL in outcomes:
        return FAIL
    if INCONCLUSIVE in outcomes:
        return INCONCLUSIVE
    return PASS


def _known_id(mid, get, registry=None):
    reg = registry if registry is not None else load_registry()
    if mid in reg:
        return reg
    raise Refusal("NOT_IN_REGISTRY",
                  "gate 2: %r is not in registry/mods.json, so nothing can "
                  "select it. The backend refuses an unknown id too, so a typo "
                  "cannot leave a permanent override naming nothing." % mid)


def set_enabled(mid, on, get=http_get, registry=None):
    """`modenable` / `moddisable`. Writes a persistent USER OVERRIDE via the
    one supported path (`docs/MOD-ENABLE-PATH.md`); the override outranks
    every list. Returns (outcome, message)."""
    _known_id(mid, get, registry)
    verb = "enable" if on else "disable"
    base, body = get("/aowlspt/mods/%s/%s" % (verb, mid))
    try:
        doc = json.loads(body)
    except ValueError:
        return INCONCLUSIVE, ("%s/aowlspt/mods/%s/%s answered non-JSON; the "
                              "override may or may not have been written: %r"
                              % (base, verb, mid, body[:160]))
    if not doc.get("ok", False):
        return FAIL, "the manager refused: %s" % (doc.get("error") or body[:200])
    return PASS, ("override written: %s is now %sd. The client host picks it "
                  "up on its next poll (a few seconds) -- re-run `mods %s` to "
                  "see whether it went LIVE. This call proves the OVERRIDE, "
                  "not the load." % (mid, verb, mid))


# ---------------------------------------------------------------------------
# reload -- deliberately not implemented here
# ---------------------------------------------------------------------------

def reload_entry_point():
    """Detect the live hot-reload entry point another agent is building
    (quiesce -> detach -> unload -> load -> re-arm). Returns a callable or
    None. It is looked up by IMPORT, so the day their module lands this verb
    starts working with no change here."""
    try:
        import modreload  # noqa: F401 -- built in parallel; may not exist
    except ImportError:
        return None
    return getattr(modreload, "reload_mod", None)


def reload(mid, get=http_get, registry=None, row=None):
    """`modreload`. Three outcomes, and TWO DISTINCT named refusals.

    There IS a `GET /aowlspt/mods/reload` route, and calling it here would be
    the wrong thing: it re-reads `registry/mods.json` from disk. It does not
    quiesce the mod, detach its detours, FreeLibrary it or re-arm it. Today's
    raid-load crash was a FreeLibrary landing during scene teardown with
    detours still armed -- that is the operation being built, and approximating
    it with a registry re-read would report success for something that did not
    happen."""
    _known_id(mid, get, registry)

    # Gate first, driver second -- because this refusal is the one the user
    # will actually hit. Since ba46898 the client host REFUSES to unload a mod
    # that has not set AOWLSPT_MOD_HOT_RELOADABLE, and no mod in the repo
    # declares it. Reporting "no driver" for a mod that would be refused
    # anyway would name the wrong cause.
    if row is not None and row.get("hot_reloadable") is False:
        raise Refusal(
            "RELOAD_NOT_DECLARED",
            "%s has not declared AOWLSPT_MOD_HOT_RELOADABLE, so the client "
            "host will REFUSE to unload it live and it stays loaded. That gate "
            "exists because two undeclared mod DLLs were FreeLibrary'd during "
            "scene teardown and took the client down inside a second. This is "
            "a property of the mod, not of this tool: the mod must claim it. "
            "Restart the client to pick up a new build of it." % mid)

    fn = reload_entry_point()
    if fn is None:
        raise Refusal(
            "RELOAD_UNSUPPORTED",
            "live mod reload is NOT available on this build. The quiesce -> "
            "detach -> unload -> load -> re-arm cycle is being built "
            "separately and this verb calls its entry point "
            "(`tools/modreload.py:reload_mod`) the moment it exists. What this "
            "verb will NOT do is substitute `GET /aowlspt/mods/reload`, which "
            "only re-reads registry/mods.json from disk and would report "
            "success for an operation that never ran. To cycle %s today: "
            "`moddisable %s`, wait for the host to unload it, `modenable %s`."
            % (mid, mid, mid))
    return fn(mid)
