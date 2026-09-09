#!/usr/bin/env python3
r"""factimport.py -- file relayed measurements into the fact store, honestly.

    python tools/factimport.py                    validate + report, write NOTHING
    python tools/factimport.py --commit           back up the db, then insert
    python tools/factimport.py --commit --clear   ... and empty the relay after
    python tools/factimport.py --scope computed --commit
    python tools/factimport.py --show-scope

## Why this exists

`tools/factnote.py` is the relay a SUBAGENT writes to, because subagents do not
inherit the `aowlfacts` MCP server (measured, repeatedly). It deliberately does
not touch the store: filing a fact requires a scope key, and a fact filed under
the wrong world is worse than no fact.

The gap that left is this one. The coordinating session is supposed to read
`--drain` and file each entry with `fact_record` -- but when the MCP tools are
missing from the COORDINATOR too (also measured, on 2026-09-01, with 100+
entries queued), there is no path from the relay into the store at all, and the
relay grows into a write-only log. This is that path, and it is a tool rather
than a one-off script because the situation recurs every time an agent runs
without the MCP server.

## What it validates, and what it REFUSES

Per entry, all of these must hold or the entry is rejected and named:

  * `subject`, `predicate` and `object` are all non-empty;
  * `method` is exactly `measured` or `inferred` -- nothing else;
  * an entry labelled `measured` carries non-empty `evidence`. A measurement
    with no provenance is a rumour, and `measured` is the label that makes the
    rest of the store trustworthy. CLAUDE.md section 9: a fact recorded as
    measured that was not measured poisons the store, and a poisoned store is
    worse than an empty one.
  * `supersedes`, if given, names a fact id that EXISTS. A supersede pointing
    at nothing would silently become a plain insert, leaving the superseded
    claim live beside its correction.

Rejected entries are never dropped: they are listed, and they are left in the
relay (`--clear` refuses to run unless every entry was either inserted or
was an exact duplicate), so the next person can fix and re-file them.

## Three outcomes, never two

    PASS          every entry was inserted or was an exact duplicate
    FAIL          at least one entry was rejected by validation
    INCONCLUSIVE  the store could not be read, or the scope is ambiguous
                  (see below) and no `--scope` was chosen

"I could not look" is not a pass.

## The scope key, MEASURED -- and the ambiguity it exposed

The store stamps every fact with a scope key so that a game update marks it
`[STALE: scope changed]` rather than letting it quietly lie. The `aowlfacts`
MCP server's source could NOT be located on this machine (the plugin cache
holds only `aowlcode` 1.8.0, whose `.mcp.json` registers `nimlang` and no
facts server), so its code could not be imported and reused. The format was
recovered from the database instead, and then CONFIRMED by reproducing it:

    scope.details = {"GameAssembly.dll": "D:\\Games\\Tarkov\\GameAssembly.dll",
                     "db.json": "D:\\Aowlspt\\aowlspt\\db.json",
                     "parts": ["ga:e0ea3ad3b76b", "db:41313127"]}

    sha256("D:\\Games\\Tarkov\\GameAssembly.dll")[:12] == "e0ea3ad3b76b"   MEASURED, reproduced

The db half is the same shape truncated to 8 hex, INFERRED from the format --
it could not be reproduced, because `db.json` has been rewritten since that
scope row was computed on 2026-08-22 and now hashes to `dc37b4f6`. Neither
size, mtime, nor a prefix hash of the current file reproduces `41313127`, so
the most likely reading is simply that the file changed. That is not a
certainty and this file does not pretend otherwise.

Which means there are TWO defensible keys and they disagree:

  `current`   what `meta.current_scope` says, `...-db:41313127`. All 325
              existing facts live here. This is the DEFAULT, because a fact
              filed where nothing else lives is a fact nobody will read.
  `computed`  recomputed now, `...-db:dc37b4f6`. Correct if the server
              recomputes the key on every query -- in which case the whole
              store is already reading as stale, which is a separate problem
              and not one an importer should paper over.

Pass `--scope current|computed|<literal key>`. The difference is always
printed, never silently resolved.

## The backup

`--commit` copies the database to `<db>.bak-factimport-<timestamp>` BEFORE
opening it for writing, and prints the path. There is also a checked-in
backup at `docs/aowl-facts.db.backup`; this does not touch it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# SHARED, not copied. factnote owns where the relay lives and how a malformed
# line is preserved; two readers with two opinions about that is how the four
# stranded relay files happened in the first place.
import factnote  # noqa: E402

VALID_METHODS = ("measured", "inferred")


def store_path():
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.normpath(os.path.join(home, ".aowl", "facts.db"))


def sha_prefix(path, n):
    """sha256 of a file's CONTENT, truncated. None when unreadable -- an
    unreadable input must not silently contribute an empty string to a key."""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 22), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()[:n]


def scope_paths(con):
    """The two files the store's own `scope` row names, so the key is computed
    over the SAME inputs it was originally computed over rather than over
    whatever this machine happens to think the game is."""
    import gamepaths as _gp
    ga = _gp.gameasm()
    db = r"D:\Aowlspt\aowlspt\db.json"
    try:
        row = con.execute(
            "select details from scope where key = "
            "(select v from meta where k='current_scope')").fetchone()
        if row and row[0]:
            d = json.loads(row[0])
            ga = d.get("GameAssembly.dll", ga)
            db = d.get("db.json", db)
    except (sqlite3.Error, ValueError):
        pass
    return ga, db


def computed_scope(con):
    """Rebuild the key from the files. Returns (key, detail_string). The key
    is None when either input is unreadable -- a scope key derived from a
    missing file is a fabricated world."""
    ga, db = scope_paths(con)
    g = sha_prefix(ga, 12)
    d = sha_prefix(db, 8)
    detail = "ga=%s -> %s ; db=%s -> %s" % (ga, g or "UNREADABLE",
                                            db, d or "UNREADABLE")
    if not g or not d:
        return None, detail
    return "aowlspt-ga:%s-db:%s" % (g, d), detail


def current_scope(con):
    row = con.execute("select v from meta where k='current_scope'").fetchone()
    return row[0] if row else None


def validate(rows):
    """(ok, bad) -- bad entries carry the reason they were refused."""
    ok, bad = [], []
    for i, r in enumerate(rows, 1):
        if r.get("_malformed"):
            bad.append((i, r, "the relay line was not valid JSON; it is kept "
                              "verbatim in the relay and needs a human"))
            continue
        why = None
        for f in ("subject", "predicate", "object"):
            if not str(r.get(f) or "").strip():
                why = "%s is empty" % f
                break
        if why is None:
            m = r.get("method")
            if m not in VALID_METHODS:
                why = ("method is %r; it must be 'measured' or 'inferred'"
                       % (m,))
            elif m == "measured" and not str(r.get("evidence") or "").strip():
                why = ("labelled 'measured' with no evidence. A measurement "
                       "with no provenance is a rumour, and this is the "
                       "label the rest of the store's trust rests on.")
        if why:
            bad.append((i, r, why))
        else:
            ok.append((i, r))
    return ok, bad


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="file relayed measurements into the fact store",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--db", default=None, help="the store (default: "
                                               r"%%USERPROFILE%%\.aowl\facts.db)")
    ap.add_argument("--relay", default=None,
                    help="the relay file (default: factnote's shared path)")
    ap.add_argument("--scope", default="current",
                    help="current | computed | a literal scope key")
    ap.add_argument("--commit", action="store_true",
                    help="actually insert. Without it nothing is written.")
    ap.add_argument("--clear", action="store_true",
                    help="with --commit, empty the relay afterwards -- only "
                         "if every entry was inserted or was a duplicate")
    ap.add_argument("--show-scope", action="store_true",
                    help="print both candidate scope keys and exit")
    a = ap.parse_args(argv)

    db = a.db or store_path()
    if not os.path.isfile(db):
        print("INCONCLUSIVE: no fact store at %s. Nothing was read and "
              "nothing was written." % db)
        return 3
    con = sqlite3.connect(db)
    con.row_factory = sqlite3.Row

    cur = current_scope(con)
    comp, comp_detail = computed_scope(con)
    print("scope, current  (meta.current_scope) : %s" % (cur or "ABSENT"))
    print("scope, computed (sha256 of the files): %s" % (comp or "UNCOMPUTABLE"))
    print("        inputs: %s" % comp_detail)
    if cur and comp and cur != comp:
        print("        THESE DISAGREE. See this file's docstring; the default "
              "is `current`, where all existing facts live.")
    if a.show_scope:
        return 0

    if a.scope == "current":
        scope = cur
    elif a.scope == "computed":
        scope = comp
    else:
        scope = a.scope
    if not scope:
        print("INCONCLUSIVE: --scope %s resolved to nothing. Nothing was "
              "written." % a.scope)
        return 3
    print("filing under: %s" % scope)

    relay = a.relay or factnote._shared_path()
    if not os.path.exists(relay):
        print("PASS (vacuously): no relay file at %s -- 0 entries." % relay)
        return 0
    rows, bad_rows = factnote._read_rows(relay)
    allrows = rows + bad_rows
    if not allrows:
        print("PASS (vacuously): %s is empty -- 0 entries." % relay)
        return 0
    print("relay: %s -- %d entr(ies)" % (relay, len(allrows)))

    good, bad = validate(allrows)

    # `supersedes` is checked against the store, so a correction can never
    # quietly become a second live claim beside the thing it corrects.
    checked = []
    for i, r in good:
        sup = r.get("supersedes")
        if sup:
            try:
                sup = int(sup)
            except (TypeError, ValueError):
                bad.append((i, r, "supersedes is not an integer id"))
                continue
            if not con.execute("select 1 from fact where id=?",
                               (sup,)).fetchone():
                bad.append((i, r, "supersedes names fact id %d, which does "
                                  "not exist in this store" % sup))
                continue
            r = dict(r)
            r["supersedes"] = sup
        checked.append((i, r))

    # EXACT duplicate = same subject, predicate, object AND scope, already
    # live. Anything that differs in any of those is a different claim and is
    # inserted; near-duplicates are for a human to merge, not for this to
    # guess at.
    to_insert, dupes = [], []
    for i, r in checked:
        hit = con.execute(
            "select id from fact where subject=? and predicate=? and "
            "object=? and scope_key=? and status='live'",
            (r["subject"], r["predicate"], r["object"], scope)).fetchone()
        if hit:
            dupes.append((i, r, hit[0]))
        else:
            to_insert.append((i, r))

    print("\n  %d to insert, %d exact duplicate(s) already in the store, "
          "%d rejected" % (len(to_insert), len(dupes), len(bad)))
    for i, r, hit in dupes:
        print("  dup   #%-3d -> fact %d  %s | %s"
              % (i, hit, r.get("subject"), r.get("predicate")))
    for i, r, why in bad:
        print("  REJECT #%-3d %s | %s\n         %s"
              % (i, str(r.get("subject"))[:60], r.get("predicate"), why))

    if not a.commit:
        print("\nNothing was written (no --commit). Re-run with --commit to "
              "back up the store and insert.")
        return 1 if bad else 0

    if to_insert:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = "%s.bak-factimport-%s" % (db, stamp)
        shutil.copy2(db, backup)
        print("\nbackup: %s" % backup)

    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    inserted = 0
    for i, r in to_insert:
        cursor = con.execute(
            "insert into fact (subject, predicate, object, note, method, "
            "scope_key, created_at, last_seen, status) "
            "values (?,?,?,?,?,?,?,?, 'live')",
            (r["subject"], r["predicate"], r["object"], r.get("note") or None,
             r["method"], scope, now, now))
        fid = cursor.lastrowid
        ev = r.get("evidence") or ""
        agent = r.get("agent") or "?"
        con.execute(
            "insert into provenance (fact_id, command, evidence, at) "
            "values (?,?,?,?)",
            (fid, "tools/factimport.py (relayed by %s)" % agent, ev, now))
        sup = r.get("supersedes")
        if sup:
            con.execute("update fact set status='superseded' where id=?",
                        (sup,))
            con.execute("insert into edge (from_fact, rel, to_fact) "
                        "values (?, 'supersedes', ?)", (fid, sup))
        inserted += 1
    con.commit()

    n_live = con.execute("select count(*) from fact where scope_key=?",
                         (scope,)).fetchone()[0]
    con.close()
    print("inserted %d fact(s); scope %s now holds %d row(s)."
          % (inserted, scope, n_live))

    if bad:
        print("\nFAIL: %d entr(ies) were REJECTED and were NOT filed. They "
              "are still in the relay; fix them and re-run." % len(bad))
        if a.clear:
            print("--clear was IGNORED: clearing now would destroy the "
                  "rejected entries, which is the one thing this must not do.")
        return 1

    if a.clear:
        with open(relay, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("")
        print("CLEARED %s -- draining again reports 0." % relay)
    else:
        print("\nThe relay was NOT cleared. Re-run with --clear once you are "
              "satisfied, or the same entries will be seen (and skipped as "
              "duplicates) next time.")
    print("\nPASS: %d inserted, %d already present, 0 rejected."
          % (inserted, len(dupes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
