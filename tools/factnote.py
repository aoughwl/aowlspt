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

WHERE THE RELAY FILE LIVES, AND WHY IT MOVED
--------------------------------------------
It is `%USERPROFILE%\\.aowl\\relay.jsonl` -- ONE absolute path, beside facts.db.

It used to be `<repo>/.aowl-relay.jsonl`, resolved relative to this file. Every
subagent is dispatched into a NEW git worktree by standing policy, so each one
appended to a relay file inside its own throwaway worktree, and `--drain` from
the coordinating session saw only its own. Measured 2026-08-31: 52 queued
measurements sitting across FOUR separate files, none of them the one the
coordinator was draining. That was a path bug, not a discipline problem: the
tool reported "relayed" truthfully and the entry was still unreachable.

`--drain` also sweeps any stray repo-relative `.aowl-relay.jsonl` it can find,
so entries written by an OLDER copy of this tool -- in this worktree or a
sibling checkout under the same Projects root -- are not stranded. A swept file
is migrated into the shared path and then emptied, so draining twice does not
duplicate.
"""

import argparse
import glob
import json
import io
import os
import sys

LEGACY_BASENAME = ".aowl-relay.jsonl"


def _shared_path():
    """The one true relay file: %USERPROFILE%\\.aowl\\relay.jsonl."""
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.normpath(os.path.join(home, ".aowl", "relay.jsonl"))


def _repo_root():
    return os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def _legacy_paths():
    """Stray repo-relative relay files an older copy of this tool may have
    written. This worktree first, then every sibling checkout under the same
    parent directory -- that is where the four measured files were."""
    seen, out = set(), []
    cands = [os.path.join(_repo_root(), LEGACY_BASENAME)]
    parent = os.path.dirname(_repo_root())
    cands.extend(sorted(glob.glob(os.path.join(parent, "*", LEGACY_BASENAME))))
    for p in cands:
        n = os.path.normpath(p)
        if n not in seen and n != _shared_path() and os.path.exists(n):
            seen.add(n)
            out.append(n)
    return out


def _read_rows(path):
    """Return (rows, malformed). A malformed line is KEPT and wrapped, never
    dropped -- a measurement we cannot parse is still a measurement someone
    made, and silently discarding it is exactly the failure this tool exists
    to prevent."""
    rows, bad = [], []
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                obj = None
            if isinstance(obj, dict):
                rows.append(obj)
            else:
                bad.append({"_malformed": True, "_source": path,
                            "_line": lineno, "_raw": line})
    return rows, bad


def _key(row):
    """Identity for exact de-duplication. Two entries are the same entry only
    if every relayed field matches; anything else is kept."""
    if row.get("_malformed"):
        return ("_malformed", row.get("_raw", ""))
    return tuple(str(row.get(k, "")) for k in
                 ("subject", "predicate", "object", "method", "evidence",
                  "note", "supersedes", "agent"))


def _append(path, rows):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with io.open(path, "a", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


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
    _append(_shared_path(), [row])
    print("relayed: %s | %s" % (args.subject, args.predicate))
    print("  -> %s" % _shared_path())
    print("NOT yet in the store -- say so in your report; the coordinating "
          "session files it with `factnote.py --drain`.")
    return 0


def migrate(_args, quiet=False):
    """Fold every stray repo-relative relay file into the shared path.

    Exactly-identical entries are dropped; anything that differs in any field
    is kept. A source file is emptied only AFTER its rows are durably in the
    shared file, so an interruption duplicates rather than loses -- and the
    de-duplication makes the duplicate harmless on the next run."""
    shared = _shared_path()
    existing, existing_bad = ([], [])
    if os.path.exists(shared):
        existing, existing_bad = _read_rows(shared)
    have = set(_key(r) for r in existing + existing_bad)
    before_shared = len(existing) + len(existing_bad)

    moved = dupes = bad_count = 0
    sources = _legacy_paths()
    for src in sources:
        rows, bad = _read_rows(src)
        take = []
        for r in rows + bad:
            k = _key(r)
            if k in have:
                dupes += 1
                continue
            have.add(k)
            take.append(r)
            if r.get("_malformed"):
                bad_count += 1
        if take:
            _append(shared, take)
            moved += len(take)
        if not quiet:
            print("  %-60s %d entr(ies), %d new" % (src, len(rows) + len(bad),
                                                    len(take)))
        # Empty, do not delete: a zero-byte file is visible evidence that this
        # location was swept, and an older tool appending here still works.
        with io.open(src, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("")

    after, after_bad = _read_rows(shared) if os.path.exists(shared) else ([], [])
    if not quiet:
        print("\nmigration: %d source file(s); shared file %d -> %d entr(ies) "
              "(%d migrated, %d exact duplicates dropped, %d malformed kept)"
              % (len(sources), before_shared, len(after) + len(after_bad),
                 moved, dupes, bad_count))
    return len(after) + len(after_bad)


def drain(args):
    shared = _shared_path()
    # Compatibility read: sweep stray repo-relative files first, so entries
    # written by an older copy of the tool are never stranded.
    strays = _legacy_paths()
    if strays:
        print("compat: sweeping %d stray repo-relative relay file(s)"
              % len(strays))
        migrate(args, quiet=False)
        print("")

    if not os.path.exists(shared):
        print("0 relayed measurements (%s absent)" % shared)
        return 0
    rows, bad = _read_rows(shared)
    allrows = rows + bad
    if not allrows:
        print("0 relayed measurements (%s is empty)" % shared)
        return 0

    for i, r in enumerate(allrows, 1):
        if r.get("_malformed"):
            print("--- %d/%d  !! MALFORMED, kept verbatim (from %s line %d)"
                  % (i, len(allrows), r.get("_source"), r.get("_line")))
            print("  raw        %s" % r.get("_raw"))
            continue
        print("--- %d/%d  (from %s)" % (i, len(allrows), r.get("agent", "?")))
        for k in ("subject", "predicate", "object", "method", "evidence",
                  "note", "supersedes"):
            if r.get(k):
                print("  %-10s %s" % (k, r[k]))

    # Count by the _malformed FLAG, not by which parse bucket the row landed
    # in: once a malformed line has been wrapped and written to the shared
    # file, the wrapper is itself valid JSON and re-reads as "well-formed".
    # Tallying by bucket made the summary say "0 malformed" on the same run
    # that had just printed a MALFORMED entry.
    n_bad = sum(1 for r in allrows if r.get("_malformed"))
    print("\n%d relayed measurement(s) (%d well-formed, %d malformed)."
          % (len(allrows), len(allrows) - n_bad, n_bad))
    print("Do NOT file one you cannot stand behind -- check it first; the "
          "agent may have inferred what it labelled measured.")
    if args.clear:
        with io.open(shared, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("")
        print("CLEARED %s -- draining again now reports 0." % shared)
    else:
        print("Nothing was cleared. File each with fact_record, then re-run "
              "with --drain --clear (or empty %s)." % shared)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--drain", action="store_true")
    ap.add_argument("--clear", action="store_true",
                    help="with --drain: empty the relay file afterwards")
    ap.add_argument("--migrate", action="store_true",
                    help="fold stray repo-relative relay files into the "
                         "shared path and report counts")
    ap.add_argument("--path", action="store_true",
                    help="print the shared relay path and exit")
    ap.add_argument("--subject")
    ap.add_argument("--predicate")
    ap.add_argument("--object")
    ap.add_argument("--method", default="measured")
    ap.add_argument("--evidence")
    ap.add_argument("--note")
    ap.add_argument("--supersedes", type=int)
    a = ap.parse_args(argv)
    if a.path:
        print(_shared_path())
        return 0
    if a.migrate:
        migrate(a)
        return 0
    if a.drain:
        return drain(a)
    if not (a.subject and a.predicate and a.object):
        ap.error("--subject, --predicate and --object are required "
                 "(or use --drain)")
    return add(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
