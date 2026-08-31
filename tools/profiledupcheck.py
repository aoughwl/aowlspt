#!/usr/bin/env python3
r"""profiledupcheck.py - assert the served profile list contains no duplicate `_id`.

This is the falsifiable half of the 2026-08-31 duplicate-profile fix. It needs
NO game client: the backend answers on its own, and the whole defect lives in
one response body.

    python tools/profiledupcheck.py

The port is 6969, NOT 80. The client talks to the backend on 6969 and a check
pointed at 80 gets a connection refused that reads, wrongly, as "the backend is
down" -- which is why it is spelled out here rather than left to a default.

## What it asserts, and why that shape

It asserts a property of the FINISHED PAYLOAD -- "no `_id` appears twice in what
the server actually sent" -- and not a property of the dedup code. That is the
whole point: the OLD dedup would have passed any check written against its own
key (the store filename), because a backup named
`profile.<id>.bak-availableAfter-<ts>` has a different filename and the same
`_id` inside. Only reading back the served list can catch that.

Three outcomes, never two:
  PASS          the list parsed and no `_id` repeats
  FAIL          a duplicate `_id` is present -- this is the bug, and the client
                would throw InvalidOperationException: Sequence contains more
                than one matching element (EFT.TarkovApplication.IsLeaving)
  INCONCLUSIVE  the backend was not reachable, or the body was not the shape
                this check knows how to read. NOT a pass. "I could not look" has
                never been a pass in this repo.

Exit codes: 0 PASS, 1 FAIL, 2 INCONCLUSIVE.

## Reproducing the original bug on purpose

To prove this check can FAIL (a check you cannot make fail is not a check):
copy a profile file in the backend's store dir to a name that still begins
`profile.` -- e.g. `profile.<id>.bak-x` -- restart the backend, and run this. It
must report FAIL and name the repeated `_id`. Delete the copy afterwards. The
migration's own `profilebak.` prefixed backups are NOT picked up by
`allProfileIds` and will not reproduce it.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "http://127.0.0.1:6969/client/game/profile/list"


def fetch(url, timeout):
    req = urllib.request.Request(
        url, data=b"{}",
        headers={"Content-Type": "application/json",
                 "User-Agent": "UnityPlayer/2019.4 profiledupcheck"},
        method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--url", default=DEFAULT_URL,
                   help="profile list endpoint (default %s)" % DEFAULT_URL)
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--show", action="store_true",
                   help="print every _id/nickname served, in order")
    args = p.parse_args()

    print("profiledupcheck: POST %s" % args.url)
    try:
        raw = fetch(args.url, args.timeout)
    except urllib.error.URLError as e:
        print("INCONCLUSIVE: could not reach the backend (%s)." % e)
        print("  Start aowlspt-backend.exe and try again. NOTE the port is")
        print("  6969, not 80 -- a refused connection on 80 means only that")
        print("  nothing listens on 80.")
        return 2
    except Exception as e:
        print("INCONCLUSIVE: request failed: %r" % e)
        return 2

    print("profiledupcheck: %d bytes" % len(raw))
    try:
        doc = json.loads(raw.decode("utf-8", "replace"))
    except ValueError as e:
        # Strict parse on purpose. A `contains` substring assertion let an
        # invalid-JSON payload pass the backend selftest for months.
        print("INCONCLUSIVE: the body is not valid JSON (%s)." % e)
        print("  first 300 bytes: %r" % raw[:300])
        return 2

    data = doc.get("data") if isinstance(doc, dict) else doc
    if not isinstance(data, list):
        print("INCONCLUSIVE: expected a JSON array of profiles (or an envelope "
              "with a `data` array); got %s." % type(data).__name__)
        if isinstance(doc, dict):
            print("  envelope keys: %s" % sorted(doc.keys()))
        return 2

    if not data:
        # An empty list is the legitimate first-run state, and it is trivially
        # duplicate-free -- but it also cannot demonstrate the check works, so
        # it is reported as INCONCLUSIVE rather than banked as a PASS.
        print("INCONCLUSIVE: the server served ZERO profiles. That is the")
        print("  correct first-run state, but an empty list proves nothing")
        print("  about dedup. Create a character and run this again.")
        return 2

    seen = {}
    dups = []
    for i, ent in enumerate(data):
        if not isinstance(ent, dict):
            print("INCONCLUSIVE: entry %d is a %s, not an object."
                  % (i, type(ent).__name__))
            return 2
        pid = ent.get("_id")
        nick = (ent.get("Info") or {}).get("Nickname") if isinstance(
            ent.get("Info"), dict) else None
        side = (ent.get("Info") or {}).get("Side") if isinstance(
            ent.get("Info"), dict) else None
        if args.show:
            print("  [%d] _id=%s  %s  %s" % (i, pid, nick, side))
        if pid is None:
            print("INCONCLUSIVE: entry %d has no `_id`. The client keys on it, "
                  "so this check cannot speak for that entry." % i)
            return 2
        if pid in seen:
            dups.append((pid, seen[pid], i, nick))
        else:
            seen[pid] = i

    print("profiledupcheck: %d entries, %d distinct _id" % (len(data), len(seen)))

    if dups:
        print("\nFAIL: the served list repeats an _id. This is exactly what")
        print("      makes the client's SingleOrDefault throw")
        print("      'Sequence contains more than one matching element'")
        print("      (EFT.TarkovApplication.IsLeaving / ProfileDataLoader.Apply).")
        for pid, first, again, nick in dups:
            print("  _id %s served at index %d AND index %d  (%s)"
                  % (pid, first, again, nick))
        print("\n      Look for a stray file beside the real profile in the")
        print("      backend's store dir. The server also logs each duplicate")
        print("      it drops, naming the store key.")
        return 1

    print("\nPASS: no _id appears twice in what the server actually served.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
