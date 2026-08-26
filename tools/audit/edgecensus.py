"""Cross-reference the recorded real-client capture against the registered route table.

Prints, in three sections:
  ASKED-AND-UNSERVED  urls the real client asked for that no `serve`/`servePrefix` covers
  ASKED-AND-SERVED    counts only
  SERVED-NEVER-ASKED  registered routes the capture never exercised (NOT evidence of dead code)

Reads only the capture manifest (small) -- never a response body.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def routes():
    exact, prefix = set(), set()
    pat = re.compile(r'\b(serve|servePrefix)\("([^"]+)"')
    for base in ("mods", "backend"):
        for dirpath, _, names in os.walk(os.path.join(ROOT, base)):
            for n in names:
                if not n.endswith(".nim"):
                    continue
                with open(os.path.join(dirpath, n), encoding="utf-8", errors="replace") as f:
                    for kind, url in pat.findall(f.read()):
                        (prefix if kind == "servePrefix" or url.endswith("/") else exact).add(url)
    return exact, prefix


def served(url, exact, prefix):
    path = url.split("?", 1)[0]
    if path in exact:
        return True
    return any(path.startswith(p) for p in prefix)


def main(manifest):
    with open(manifest, encoding="utf-8") as f:
        entries = json.load(f)
    exact, prefix = routes()
    asked = {}
    for e in entries:
        u = (e.get("url") or e.get("path") or "").split("?", 1)[0]
        if u:
            asked[u] = asked.get(u, 0) + 1
    miss = sorted(u for u in asked if not served(u, exact, prefix))
    hit = sorted(u for u in asked if served(u, exact, prefix))
    print("capture entries: %d   distinct urls: %d" % (len(entries), len(asked)))
    print("registered: %d exact + %d prefix" % (len(exact), len(prefix)))
    print("\nASKED-AND-UNSERVED (%d):" % len(miss))
    for u in miss:
        print("  %-52s x%d" % (u, asked[u]))
    print("\nASKED-AND-SERVED: %d" % len(hit))
    never = sorted(r for r in exact | prefix if not any(a.startswith(r) for a in asked))
    print("\nSERVED-NEVER-ASKED-IN-THIS-CAPTURE (%d):" % len(never))
    for r in never:
        print("  " + r)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1
         else os.path.join(ROOT, "mods", "tarkov", "data", "capture", "raid1", "manifest.json"))
