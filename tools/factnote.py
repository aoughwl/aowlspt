"""Relay a measurement out of a subagent, so it is not lost.

Subagents do not inherit the `aowlfacts` MCP server. Measured repeatedly: an
agent measures a field offset, an RVA, or a false positive, mentions it in a
report, and it reaches the store only if the coordinating session happens to
relay it. Anything an agent measures and does not mention is simply gone.

This does NOT write to the store. Recording a fact requires the scope key
(hashed from GameAssembly.dll and db.json), and a fact filed under the wrong
world is worse than no fact at all -- so the scope logic lives in exactly one
place and this is not it. Instead this appends to a relay file that the
coordinating session drains with `--drain` and files properly.

    python tools/factnote.py \
        --subject "UnityEngine.Object::get_name" \
        --predicate "rva" \
        --object "0x52AD4B0 -- a working name source on this build" \
        --method measured \
        --evidence "resolver + raw PE read; rid=2874 type 23130; prologue 40 53 ..." \
        --note "UNVERIFIED at runtime: never executed"

    python tools/factnote.py --drain        # coordinating session: print + clear

`--method` is `measured` or `inferred`, and it is not decoration. A fact
recorded as measured that was not measured poisons the store. Say `inferred`
when you inferred it.
"""

import argparse
import json
import io
import os
import sys

RELAY = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", ".aowl-relay.jsonl")


def _path():
    return os.path.normpath(RELAY)


def add(args):
    if args.method not in ("measured", "inferred"):
        print("--method must be 'measured' or 'inferred'; say inferred when "
              "you inferred it", file=sys.stderr)
        return 2
    if not args.evidence:
        print("--evidence is required: a fact with no provenance is a rumour",
              file=sys.stderr)
        return 2
    row = {
        "subject": args.subject,
        "predicate": args.predicate,
        "object": args.object,
        "method": args.method,
        "evidence": args.evidence,
        "note": args.note or "",
        "supersedes": args.supersedes,
        "agent": os.environ.get("CLAUDE_AGENT_NAME", "?"),
    }
    with io.open(_path(), "a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    print("relayed: %s | %s" % (args.subject, args.predicate))
    print("NOT yet in the store -- say so in your report; the coordinating "
          "session files it with `factnote.py --drain`.")
    return 0


def drain(_args):
    p = _path()
    if not os.path.exists(p):
        print("no relayed measurements (%s absent)" % p)
        return 0
    rows = []
    with io.open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    print("!! unparseable relay line, kept: %s" % line[:120])
    if not rows:
        print("relay file is empty")
        return 0
    for i, r in enumerate(rows, 1):
        print("--- %d/%d  (from %s)" % (i, len(rows), r.get("agent", "?")))
        for k in ("subject", "predicate", "object", "method", "evidence",
                  "note", "supersedes"):
            if r.get(k):
                print("  %-10s %s" % (k, r[k]))
    print("\n%d relayed measurement(s). File each with fact_record, then "
          "delete %s." % (len(rows), p))
    print("Do NOT file one you cannot stand behind -- check it first; the "
          "agent may have inferred what it labelled measured.")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--drain", action="store_true")
    ap.add_argument("--subject")
    ap.add_argument("--predicate")
    ap.add_argument("--object")
    ap.add_argument("--method", default="measured")
    ap.add_argument("--evidence")
    ap.add_argument("--note")
    ap.add_argument("--supersedes", type=int)
    a = ap.parse_args(argv)
    if a.drain:
        return drain(a)
    if not (a.subject and a.predicate and a.object):
        ap.error("--subject, --predicate and --object are required "
                 "(or use --drain)")
    return add(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
