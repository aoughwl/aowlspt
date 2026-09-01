#!/usr/bin/env python3
"""Fold the subagent relay backlog into docs/AOWL_FACTS.md.

Subagents cannot reach the `aowlfacts` MCP server, so everything they measure
is written to a relay file by `tools/factnote.py` and waits for a coordinating
session to drain it into the store.

The store has now been retired -- the plugin that served it is uninstalled and
`fact_record` no longer exists -- so a drain is impossible and the backlog would
be lost. `docs/AOWL_FACTS.md` is the store's successor, so the relay is appended
there instead, in the same shape the exporter uses for a stored fact.

Records are keyed on (subject, predicate, object) so re-running is idempotent:
a measurement already in the document is skipped rather than duplicated.

Usage:  python tools/relayexport.py [--relay PATH] [--out PATH] [--dry-run]

The same redaction gate as `tools/factexport.py` applies, and for the same
reason: this document is published to a PUBLIC docs site.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

# Reassembled at runtime, never written literally -- a scrubber that spells out
# the string it scrubs is itself the leak. See tools/factexport.py.
_DOM = "mumfordand" + "miller.com"
_USER = "twill" + "its"
_REDACTIONS = ((_USER + "@" + _DOM, "<REDACTED-ADDRESS>"),
               (_DOM, "<REDACTED-DOMAIN>"))

MARKER = "## Relayed measurements (subagent backlog)"


def scrub(s):
    out = "" if s is None else str(s)
    for bad, good in _REDACTIONS:
        out = out.replace(bad, good)
    return out.strip()


def key_of(rec):
    return (scrub(rec.get("subject")),
            scrub(rec.get("predicate")),
            scrub(rec.get("object")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--relay", default=os.path.expanduser("~/.aowl/relay.jsonl"))
    ap.add_argument("--out", default="docs/AOWL_FACTS.md")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.relay):
        print(f"INCONCLUSIVE: no relay file at {args.relay} -- nothing was "
              f"examined, which is not the same as an empty backlog",
              file=sys.stderr)
        return 2
    if not os.path.exists(args.out):
        print(f"FAIL: {args.out} does not exist; run tools/factexport.py first",
              file=sys.stderr)
        return 1

    records, malformed = [], 0
    with open(args.relay, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # Counted and reported, never silently dropped: a malformed
                # line is a measurement someone took and we could not read.
                malformed += 1

    doc = open(args.out, encoding="utf-8").read()

    # Idempotent: skip anything whose subject+predicate already appears.
    fresh, dupes = [], 0
    seen = set()
    for r in records:
        k = key_of(r)
        if k in seen:
            dupes += 1
            continue
        seen.add(k)
        heading = f"**{k[0]}** — {k[1]}"
        if heading in doc:
            dupes += 1
            continue
        fresh.append(r)

    if args.dry_run:
        print(f"would append {len(fresh)} record(s); {dupes} already present; "
              f"{malformed} malformed")
        return 0

    if not fresh:
        print(f"PASS  nothing to append -- all {len(records)} relayed "
              f"record(s) are already in {args.out}")
        return 0

    L = ["", "", MARKER, "",
         f"Appended {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')} "
         f"by `tools/relayexport.py` from `{args.relay}`.", "",
         "These were measured by subagents, which cannot reach the fact store's "
         "MCP server and so relay to a file. The store has since been retired, "
         "so they are recorded here rather than drained into it. `method` is "
         "the subagent's own claim about how it established the fact -- "
         "`measured` means observed, anything else means it was not.", ""]
    for r in fresh:
        subj, pred, obj = key_of(r)
        L.append(f"**{subj}** — {pred}")
        L.append("")
        if obj:
            L.append(obj)
            L.append("")
        bits = [f"method: `{scrub(r.get('method')) or 'unstated'}`"]
        if r.get("agent") and r["agent"] != "?":
            bits.append(f"agent: {scrub(r['agent'])}")
        L.append("<sub>" + " · ".join(bits) + "</sub>")
        L.append("")
        if scrub(r.get("evidence")):
            L.append(f"- evidence: {scrub(r['evidence'])}")
        if scrub(r.get("note")):
            L.append(f"- note: {scrub(r['note'])}")
        L.append("")

    text = doc + "\n".join(L)

    # The same leak gate as factexport, asserted on the FINISHED text.
    for bad, _ in _REDACTIONS:
        if bad in text:
            print("FAIL: the personal address or domain survived; nothing was "
                  "written", file=sys.stderr)
            return 1

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)

    # A check that can fail: every appended subject must be findable.
    back = open(args.out, encoding="utf-8").read()
    missing = [key_of(r)[0] for r in fresh
               if f"**{key_of(r)[0]}** — {key_of(r)[1]}" not in back]
    if missing:
        print(f"FAIL: {len(missing)} appended record(s) are not in the file: "
              f"{missing[:5]}", file=sys.stderr)
        return 1

    print(f"PASS  appended {len(fresh)} record(s) to {args.out}")
    print(f"      {dupes} already present, {malformed} malformed line(s) "
          f"skipped (reported, not hidden)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
