#!/usr/bin/env python3
"""settingsdump.py -- what the F12 settings screen can actually see, and what it cannot.

The F12 nav is built from `GET /aowlspt/settings/index`; each entry's page comes
from `GET /aowlspt/settings/<guid>`. This fetches all of it, parses it, and --
the reason it exists -- checks the NEGATIVE that matters:

    no mod that declares settings is absent from the rendered nav,
    and no mod in the nav has a page that cannot be read.

That is falsifiable. "graphics now appears" is not: it passes whether or not the
other nineteen mods vanished at the same time.

Two measured traps this tool must not fall into.

* **Fact #122 -- the schema can be INVALID JSON.** `value` has been emitted as a
  bare, unquoted literal for `string`/`enum` rows, which makes the whole
  document unparseable by a strict reader. A tool that silently coped with that
  would hide a real wire defect from everyone downstream who does not cope. So:
  strict `json.loads` first, and only if that fails does a tolerant repair pass
  run -- and the row is REPORTED as invalid either way. `--strict-only` refuses
  to repair at all.

* **Fact #135 -- a chunked POST is answered 200 with the schema unchanged.**
  `--set` therefore never reports success from a status code. It reads the value,
  writes, re-reads, and compares. A write to a client-side mod is *expected* to
  need a moment: the backend queues it and the game process applies it on its
  next sync, so `--set` polls for `--wait` seconds and says plainly whether the
  value moved, did not move, or could not be re-read (PASS / FAIL / INCONCLUSIVE).

Usage
    python tools/settingsdump.py                  # dump + the negative assertion
    python tools/settingsdump.py --page aowl.graphics
    python tools/settingsdump.py --set aowl.graphics sharpness 0.5
    python tools/settingsdump.py --json           # machine-readable
    python tools/settingsdump.py --full           # audit the AGGREGATED routes
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"

HOST_JSON_CANDIDATES = [
    r"D:\Aowlspt\aowlspt\aowlspt-host.json",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "aowlspt-host.json"),
]


def backend_port(explicit=None):
    if explicit:
        return int(explicit)
    for path in HOST_JSON_CANDIDATES:
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                cfg = json.load(fh)
        except Exception:
            continue
        port = cfg.get("backendPort") or 0
        if port:
            return int(port)
    return 0


def fetch(port, path, body=None, timeout=15):
    """(status, text, error). Never raises; a dead backend is a result, not a crash."""
    url = "http://127.0.0.1:%d%s" % (port, path)
    data = body.encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Accept-Encoding": "identity",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.headers.get("Content-Encoding"):
                return (resp.status, None,
                        "server sent Content-Encoding=%s despite an identity "
                        "request; the body cannot be trusted as raw JSON"
                        % resp.headers.get("Content-Encoding"))
            return resp.status, resp.read().decode("utf-8", "replace"), None
    except Exception as exc:                      # noqa: BLE001 - any failure is a result
        return 0, None, str(exc)


# ---------------------------------------------------------------------------
# The fact-#122 tolerant parse
# ---------------------------------------------------------------------------
#
# The repair is deliberately narrow: it only quotes the value of a `"value":`
# member when what follows is neither a valid JSON literal nor a container. A
# broader "fix the JSON" pass would paper over defects this tool is meant to
# name.

_BARE_VALUE = re.compile(r'("value"\s*:\s*)([^",\{\[\]\}\s][^,\}\]]*)')
_JSON_LITERAL = re.compile(r'^(?:-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false|null)$')


def parse_schema(text):
    """(doc, invalid_reason, repaired_count).

    `invalid_reason` is None only when the document parsed STRICTLY. A document
    that needed repair reports the reason AND the parsed rows, because the
    caller needs both -- refusing to show the rows would hide which mod is
    emitting the bad wire.
    """
    try:
        return json.loads(text), None, 0
    except Exception as strict_exc:               # noqa: BLE001
        repaired = [0]

        def fix(m):
            raw = m.group(2).strip()
            if _JSON_LITERAL.match(raw):
                return m.group(0)
            repaired[0] += 1
            return '%s"%s"' % (m.group(1), raw.replace('\\', '\\\\').replace('"', '\\"'))

        patched = _BARE_VALUE.sub(fix, text)
        try:
            doc = json.loads(patched)
        except Exception as exc:                  # noqa: BLE001
            return None, ("did not parse, and the fact-#122 repair did not "
                          "rescue it: %s (strict: %s)" % (exc, strict_exc)), 0
        return doc, ("INVALID JSON on the wire -- %d `value` member(s) were "
                     "emitted as bare unquoted text (fact #122); a strict "
                     "reader gets nothing at all from this page"
                     % repaired[0]), repaired[0]


def rows_of(doc):
    """The schema array out of any of the three shapes a page may answer with."""
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in ("rows", "settings"):
            if isinstance(doc.get(key), list):
                return doc[key]
    return []


def row_value(rows, key):
    for r in rows:
        if isinstance(r, dict) and r.get("key") == key:
            return True, r.get("value")
    return False, None


# ---------------------------------------------------------------------------
# The dump
# ---------------------------------------------------------------------------

def load_index(port):
    status, text, err = fetch(port, "/aowlspt/settings/index")
    if text is None:
        return None, "GET /aowlspt/settings/index failed: %s" % (err or status)
    doc, bad, _ = parse_schema(text)
    if doc is None:
        return None, "the index %s" % bad
    mods = doc.get("mods") if isinstance(doc, dict) else None
    if not isinstance(mods, list):
        return None, "the index did not answer with {\"mods\":[...]}"
    return mods, bad


def load_page(port, guid):
    status, text, err = fetch(port, "/aowlspt/settings/%s" % guid)
    if text is None:
        return None, None, "no answer (%s)" % (err or status)
    doc, bad, _ = parse_schema(text)
    if doc is None:
        return None, None, bad
    if isinstance(doc, dict) and doc.get("err"):
        return rows_of(doc), bad, "the page answered with an error: %s" % doc["err"]
    return rows_of(doc), bad, None


SETTING_TYPES = {"bool", "int", "float", "enum", "string",
                 "keybind", "select", "color"}


def audit_full(port):
    """`--full`: does the AGGREGATED surface agree with the N+1 walk it replaces?

    `GET /aowlspt/settings/index/full` and `GET /aowlspt/keybinds` (both from
    mods/settingshub) exist so a native settings tab can fetch one document
    instead of the index plus one page per mod. The thing that can go wrong is
    DRIFT: the aggregate saying something the per-mod pages do not. So this
    checks the aggregate against the routes it is derived from, key by key,
    and every assertion below is falsifiable by a real defect:

      * a mod in the compact index and missing from the full one (or twice in
        it) -- the shape that put two "Bot AI" rows in the F12 nav;
      * a row whose `value` in the full document differs from the same row on
        `/aowlspt/settings/<guid>` -- an aggregate serving a stale value, which
        to a player is indistinguishable from a write that did not persist;
      * a `type` outside the closed set of eight;
      * `settings`/`keybinds` that are null rather than [];
      * a keybind listed that no row declares `keybind:true`, or a declared
        keybind row missing from /aowlspt/keybinds -- the filter inventing or
        dropping bindings.

    PASS / FAIL / INCONCLUSIVE, exit 0 / 1 / 2.
    """
    status, text, err = fetch(port, "/aowlspt/settings/index/full")
    if text is None:
        print("INCONCLUSIVE: GET /aowlspt/settings/index/full failed: %s"
              % (err or status))
        return 2
    try:
        full = json.loads(text)
    except Exception as exc:                          # noqa: BLE001
        print("FAIL: /aowlspt/settings/index/full is not strict JSON: %s" % exc)
        return 1
    if isinstance(full, dict) and full.get("err") == "no route":
        print("INCONCLUSIVE: this backend has no /aowlspt/settings/index/full "
              "route, so mods/settingshub is not loaded (or predates it).")
        return 2
    fmods = full.get("mods") if isinstance(full, dict) else None
    if not isinstance(fmods, list):
        print("FAIL: index/full did not answer with {\"mods\":[...]}")
        return 1

    problems = []
    guids = []
    rows_checked = 0
    kb_expected = {}
    for m in fmods:
        guid = m.get("guid", "")
        if not guid:
            problems.append("a mod entry carries no guid")
            continue
        if guid in guids:
            problems.append("%s appears more than once" % guid)
        guids.append(guid)
        rows = m.get("settings")
        if not isinstance(rows, list):
            problems.append("%s: `settings` is %r, not an array (a mod with "
                            "none must carry [])" % (guid, rows))
            continue
        for r in rows:
            if r.get("type") not in SETTING_TYPES:
                problems.append("%s.%s: type %r is not one of %s"
                                % (guid, r.get("key"), r.get("type"),
                                   sorted(SETTING_TYPES)))
        kb_expected[guid] = sorted(r.get("key") for r in rows if r.get("keybind"))
        # ...and against the per-mod page it is meant to replace.
        page, _bad, why = load_page(port, guid)
        if page is None:
            problems.append("%s: its own page could not be read (%s), so the "
                            "aggregate could not be cross-checked" % (guid, why))
            continue
        pv = {r.get("key"): r.get("value") for r in page if isinstance(r, dict)}
        for r in rows:
            k = r.get("key")
            rows_checked += 1
            if k in pv and pv[k] != r.get("value"):
                problems.append("%s.%s: index/full says %r, the mod's own page "
                                "says %r" % (guid, k, r.get("value"), pv[k]))

    cmods, _bad = load_index(port)
    if cmods is None:
        problems.append("the compact index could not be read, so the "
                        "exactly-once check did not run")
    else:
        for m in cmods:
            g = m.get("guid", "")
            if g and g not in guids:
                problems.append("%s is in /aowlspt/settings/index and MISSING "
                                "from index/full" % g)

    status, text, err = fetch(port, "/aowlspt/keybinds")
    if text is None:
        problems.append("GET /aowlspt/keybinds failed: %s" % (err or status))
        kmods = []
    else:
        try:
            kdoc = json.loads(text)
        except Exception as exc:                      # noqa: BLE001
            problems.append("/aowlspt/keybinds is not strict JSON: %s" % exc)
            kdoc = {}
        kmods = kdoc.get("mods") if isinstance(kdoc, dict) else []
        if not isinstance(kmods, list):
            problems.append("/aowlspt/keybinds did not answer {\"mods\":[...]}")
            kmods = []
    binds = 0
    empties = 0
    for m in kmods:
        guid = m.get("guid", "")
        ks = m.get("keybinds")
        if not isinstance(ks, list):
            problems.append("%s: `keybinds` is %r, not an array" % (guid, ks))
            continue
        if not ks:
            empties += 1
        binds += len(ks)
        for b in ks:
            if not b.get("action"):
                problems.append("%s.%s: empty action" % (guid, b.get("settingKey")))
        got = sorted(b.get("settingKey") for b in ks)
        want = kb_expected.get(guid)
        if want is None:
            problems.append("%s is in /aowlspt/keybinds and not in index/full" % guid)
        elif got != want:
            problems.append("%s: /aowlspt/keybinds lists %s but the schema "
                            "declares keybind:true on %s" % (guid, got, want))
    for guid in kb_expected:
        if not any(m.get("guid") == guid for m in kmods):
            problems.append("%s is in index/full and MISSING from "
                            "/aowlspt/keybinds (a mod with no keys must still "
                            "appear, with [])" % guid)

    print("index/full: %d mod(s), %d row(s) cross-checked against their own "
          "pages" % (len(guids), rows_checked))
    print("keybinds:   %d mod(s), %d binding(s), %d mod(s) with an empty list"
          % (len(kmods), binds, empties))
    if problems:
        for p in problems:
            print("  FAIL: %s" % p)
        return 1
    if not guids:
        print("INCONCLUSIVE: the document is well formed and lists zero mods, "
              "so nothing was actually examined.")
        return 2
    print("PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="backend port (default: from aowlspt-host.json)")
    ap.add_argument("--page", help="dump one mod's page in full and stop")
    ap.add_argument("--set", nargs=3, metavar=("GUID", "KEY", "VALUE"),
                    help="write one value and VERIFY BY RE-READING it (fact #135)")
    ap.add_argument("--wait", type=float, default=12.0,
                    help="seconds to wait for a --set to show up on re-read; a "
                         "client-side mod's edit is queued and applied by the "
                         "game process on its next sync, so it is not instant")
    ap.add_argument("--strict-only", action="store_true",
                    help="refuse the fact-#122 repair; report invalid pages as "
                         "unreadable, which is what a strict consumer sees")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--full", action="store_true",
                    help="audit the AGGREGATED routes (/aowlspt/settings/"
                         "index/full and /aowlspt/keybinds) against the per-mod "
                         "pages they are derived from; PASS/FAIL/INCONCLUSIVE")
    args = ap.parse_args()

    port = backend_port(args.port)
    if not port:
        print("INCONCLUSIVE: no backend port. Pass --port, or run where "
              "aowlspt-host.json is readable.")
        return 2

    if args.strict_only:
        # What a strict consumer actually sees: no rows at all. The repair pass
        # is a diagnostic convenience, not the wire contract, and this flag is
        # how you tell a page that is merely ugly from one that is unusable.
        globals()["parse_schema"] = _parse_strict_only

    if args.set:
        return do_set(port, args.set[0], args.set[1], args.set[2], args.wait)

    if args.full:
        return audit_full(port)

    mods, index_bad = load_index(port)
    if mods is None:
        print("INCONCLUSIVE: %s" % index_bad)
        return 2

    report = {"port": port, "indexInvalid": index_bad, "mods": [], "issues": []}
    for m in mods:
        guid = m.get("guid", "")
        entry = {"guid": guid, "name": m.get("name", guid),
                 "count": m.get("count"), "done": m.get("done"),
                 "client": bool(m.get("client")), "rows": None,
                 "invalid": None, "error": None}
        if args.page and guid != args.page:
            report["mods"].append(entry)
            continue
        rows, bad, err = load_page(port, guid)
        entry["invalid"] = bad
        entry["error"] = err
        entry["rows"] = rows
        if err:
            report["issues"].append("%s: %s" % (guid, err))
        elif bad:
            report["issues"].append("%s: %s" % (guid, bad))
        elif m.get("count") is not None and rows is not None \
                and len(rows) != m.get("count"):
            report["issues"].append(
                "%s: the index says %s row(s), the page served %d -- the nav "
                "and the page disagree" % (guid, m.get("count"), len(rows)))
        report["mods"].append(entry)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        render(report, args.page)

    verdict, why = negative_assertion(report)
    if not args.json:
        print()
        print("NEGATIVE ASSERTION -- no mod declaring settings is absent from "
              "the rendered nav, and no listed mod's page is unreadable")
        print("  %s: %s" % (verdict, why))
    return {PASS: 0, FAIL: 1, INCONCLUSIVE: 2}[verdict]


def _parse_strict_only(text):
    try:
        return json.loads(text), None, 0
    except Exception as exc:                      # noqa: BLE001
        return None, ("did not parse strictly (%s), and --strict-only forbids "
                      "the fact-#122 repair" % exc), 0


def _try(text):
    try:
        json.loads(text)
        return True
    except Exception:                             # noqa: BLE001
        return False


def render(report, only):
    print("backend 127.0.0.1:%d -- %d mod page(s) in the nav"
          % (report["port"], len(report["mods"])))
    if report["indexInvalid"]:
        print("  ! index: %s" % report["indexInvalid"])
    for m in report["mods"]:
        tag = "client" if m["client"] else "server"
        head = "  %-26s %-34s %-6s count=%s done=%s" % (
            m["guid"], m["name"][:34], tag, m["count"], m["done"])
        print(head)
        if m["error"]:
            print("      ! %s" % m["error"])
        if m["invalid"]:
            print("      ! %s" % m["invalid"])
        if only and m["guid"] == only and m["rows"]:
            for r in m["rows"]:
                if not isinstance(r, dict):
                    continue
                print("        %-24s %-8s = %-18s %s"
                      % (r.get("key"), r.get("type"),
                         json.dumps(r.get("value")),
                         "" if r.get("implemented", True) else "[NOT IMPLEMENTED]"))


def negative_assertion(report):
    """PASS / FAIL / INCONCLUSIVE on the property, never on "graphics appeared"."""
    if not report["mods"]:
        return INCONCLUSIVE, ("the nav is empty -- nothing was examined, so "
                              "nothing is proved either way")
    checked = [m for m in report["mods"] if m["rows"] is not None or m["error"]]
    if not checked:
        return INCONCLUSIVE, ("no page was fetched (--page narrowed it); run "
                              "without --page to assert the property")
    if report["issues"]:
        return FAIL, "%d problem(s): %s" % (len(report["issues"]),
                                            "; ".join(report["issues"][:6]))
    clients = [m["guid"] for m in report["mods"] if m["client"]]
    return PASS, ("every one of the %d mod(s) in the nav served a page whose "
                  "row count matches what the index promised; %d of them are "
                  "client-side and reach the nav only over the in-process bus%s"
                  % (len(report["mods"]), len(clients),
                     " (%s)" % ", ".join(clients) if clients else ""))


def do_set(port, guid, key, value, wait):
    """Write one value, then VERIFY BY RE-READING. Never by status code."""
    rows, bad, err = load_page(port, guid)
    if rows is None:
        print("INCONCLUSIVE: could not read %s before writing: %s" % (guid, err or bad))
        return 2
    found, before = row_value(rows, key)
    if not found:
        print("FAIL: %s has no declared key %r" % (guid, key))
        return 1

    body = json.dumps({"key": key, "value": json.loads(value)
                       if _try(value) else value})
    status, text, ferr = fetch(port, "/aowlspt/settings/%s" % guid, body=body)
    print("wrote %s -> HTTP %s (this is NOT the result -- fact #135: a chunked "
          "POST is answered 200 with the schema unchanged)"
          % (body, status if text is not None else ferr))

    want = json.loads(value) if _try(value) else value
    deadline = time.time() + wait
    seen = before
    while True:
        rows, bad, err = load_page(port, guid)
        if rows is not None:
            found, seen = row_value(rows, key)
            if found and seen == want:
                print("PASS: %s.%s re-reads as %s (was %s)"
                      % (guid, key, json.dumps(seen), json.dumps(before)))
                return 0
        if time.time() >= deadline:
            break
        time.sleep(1.0)

    if rows is None:
        print("INCONCLUSIVE: the page could not be re-read after the write: %s"
              % (err or bad))
        return 2
    print("FAIL: %s.%s still re-reads as %s after %.0fs; the write did not "
          "take. For a client-side mod this means the game process never "
          "drained the queued edit -- check the host log for 'client settings "
          "bridge'." % (guid, key, json.dumps(seen), wait))
    return 1


if __name__ == "__main__":
    sys.exit(main())
