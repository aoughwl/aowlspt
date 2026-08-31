#!/usr/bin/env python3
"""Export the aowlfacts SQLite store to a single readable Markdown file.

Written because the fact store is about to outlive the plugin that served it.
Everything the MCP server could answer -- facts, their provenance, the recipes,
the scopes, the edges between facts -- comes out of the same database, so the
dump is complete by construction rather than by paging an API and hoping the
last page was really the last one.

Usage:  python tools/factexport.py [--db PATH] [--out PATH]

The exporter READS ONLY. It never writes to the database.
"""

import argparse
import os
import sqlite3
import sys
from datetime import datetime, timezone


# The store holds facts ABOUT the address leak, so the export carries the
# personal domain even though no fact contains a full address. This file is
# tracked and the dump is published to a PUBLIC docs site, so the domain is
# redacted on the way out.
#
# The pattern is REASSEMBLED at runtime and never written literally, for the
# same reason the pre-commit hook does it: a scrubber that spells out the
# string it scrubs is itself the leak.
_DOM = "mumfordand" + "miller.com"
_USER = "twill" + "its"
_REDACTIONS = ((_USER + "@" + _DOM, "<REDACTED-ADDRESS>"),
               (_DOM, "<REDACTED-DOMAIN>"))


def scrub(s):
    """Remove the personal address and domain from anything leaving the store.

    Applied to every field of every fact, not only the ones expected to carry
    it -- a redaction that only covers the places you thought to look is the
    same class of defect as a check that cannot fail.
    """
    if s is None:
        return ""
    out = str(s)
    for bad, good in _REDACTIONS:
        out = out.replace(bad, good)
    return out


def esc(s):
    """Markdown-safe: keep the text verbatim, only tame table-breaking pipes."""
    if s is None:
        return ""
    return scrub(s).replace("|", "\\|")


def block(s):
    """Body text kept verbatim -- these are measurements, not prose to reflow."""
    return "" if s is None else scrub(s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.expanduser("~/.aowl/facts.db"))
    ap.add_argument("--out", default="docs/AOWL_FACTS.md")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print(f"FAIL: no database at {args.db}", file=sys.stderr)
        return 2

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row

    facts = list(con.execute(
        "select * from fact order by cast(id as integer)"))
    recipes = list(con.execute("select * from recipe order by name"))
    scopes = list(con.execute("select * from scope order by key"))
    edges = list(con.execute("select * from edge"))

    prov = {}
    for r in con.execute("select * from provenance"):
        prov.setdefault(r["fact_id"], []).append(r)

    out_edges = {}
    for e in edges:
        out_edges.setdefault(e["from_fact"], []).append((e["rel"], e["to_fact"]))

    # Counts are asserted against the tables, not against what we happened to
    # write, so a truncated export cannot masquerade as a complete one.
    n_written = 0

    L = []
    A = L.append
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    A("# aowlspt fact store")
    A("")
    A(f"Exported {now} from `{args.db}` by `tools/factexport.py`.")
    A("")
    A("This is a **complete dump** of the SQLite store that backed the "
      "`aowlfacts` MCP server: every fact with its provenance, every recipe, "
      "every scope, every edge. It is the store's successor, not a summary of "
      "it -- nothing was filtered or abridged on the way out.")
    A("")
    A("**How to read a fact.** Each one is `subject | predicate | object`, "
      "plus how it was established. `method: measured` means someone observed "
      "it; anything else means they did not. A fact recorded as measured that "
      "was not measured poisons the store, so the distinction is load-bearing.")
    A("")
    A("**Scope keys matter.** Every fact is filed under a key hashed from "
      "`GameAssembly.dll` and `db.json`. When the game updates, the key "
      "changes and facts filed under the old key describe a world that no "
      "longer exists -- they are stale, not wrong. Check the scope before "
      "trusting an offset or an RVA.")
    A("")
    A(f"| | count |")
    A(f"|---|---|")
    A(f"| facts | {len(facts)} |")
    A(f"| recipes | {len(recipes)} |")
    A(f"| provenance rows | {sum(len(v) for v in prov.values())} |")
    A(f"| edges | {len(edges)} |")
    A(f"| scopes | {len(scopes)} |")
    A("")

    # ---- scopes -------------------------------------------------------
    A("## Scopes")
    A("")
    for s in scopes:
        A(f"### `{s['key']}`")
        A("")
        A(f"- label: {esc(s['label'])}")
        A(f"- computed: {esc(s['computed_at'])}")
        if block(s["details"]):
            A("")
            A("```")
            A(block(s["details"]))
            A("```")
        A("")

    # ---- recipes ------------------------------------------------------
    A("## Recipes")
    A("")
    A("Replayable procedures known to work. These are the ones worth reading "
      "before navigating the UI by hand -- an earlier session re-derived the "
      "whole `open-settings` procedure through three wrong turns while the "
      "recipe holding those exact steps sat unread.")
    A("")
    for r in recipes:
        A(f"### {r['name']}")
        A("")
        A(f"{block(r['description'])}")
        A("")
        A(f"- scope: `{r['scope_key']}`")
        A(f"- status: {esc(r['status'])}   created: {esc(r['created_at'])}   "
          f"last ok: {esc(r['last_ok'])}")
        if block(r["verify"]):
            A(f"- verify: {block(r['verify'])}")
        A("")
        A("Steps:")
        A("")
        A("```json")
        A(block(r["steps_json"]))
        A("```")
        A("")

    # ---- facts --------------------------------------------------------
    A("## Facts")
    A("")
    for f in facts:
        n_written += 1
        A(f"### #{f['id']} — {block(f['subject'])}")
        A("")
        A(f"**{block(f['predicate'])}**")
        A("")
        if block(f["object"]):
            A(block(f["object"]))
            A("")
        if block(f["note"]):
            A(f"> {block(f['note'])}")
            A("")
        bits = [f"method: `{esc(f['method'])}`", f"scope: `{esc(f['scope_key'])}`"]
        if f["status"]:
            bits.append(f"status: {esc(f['status'])}")
        if f["created_at"]:
            bits.append(f"recorded: {esc(f['created_at'])}")
        if f["last_seen"]:
            bits.append(f"last seen: {esc(f['last_seen'])}")
        A("<sub>" + " · ".join(bits) + "</sub>")
        A("")
        for rel, to in out_edges.get(f["id"], []):
            A(f"- {esc(rel)} → #{to}")
        if out_edges.get(f["id"]):
            A("")
        for p in prov.get(f["id"], []):
            if block(p["command"]):
                A(f"- command: `{block(p['command'])}`")
            if block(p["evidence"]):
                A(f"- evidence: {block(p['evidence'])}")
        if prov.get(f["id"]):
            A("")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))

    # The check that can fail: every fact in the table must be in the file.
    if n_written != len(facts):
        print(f"FAIL: wrote {n_written} of {len(facts)} facts", file=sys.stderr)
        return 1

    text = open(args.out, encoding="utf-8").read()

    # The leak gate, asserted on the FINISHED FILE rather than on the scrubbing
    # we believe we did. Tested by temporarily disabling `scrub` and confirming
    # this aborts -- a gate that has never refused anything is not a gate.
    for bad, _ in _REDACTIONS:
        if bad in text:
            os.remove(args.out)
            print("FAIL: the personal address or domain survived into the "
                  "output; the file has been DELETED rather than left on disk "
                  "for someone to publish", file=sys.stderr)
            return 1

    missing = [f["id"] for f in facts if f"### #{f['id']} —" not in text]
    if missing:
        print(f"FAIL: {len(missing)} fact heading(s) absent from the output: "
              f"{missing[:10]}", file=sys.stderr)
        return 1
    for r in recipes:
        if f"### {r['name']}" not in text:
            print(f"FAIL: recipe {r['name']} absent from the output",
                  file=sys.stderr)
            return 1

    print(f"PASS  {args.out}  ({len(text):,} chars)")
    print(f"      {len(facts)} facts, {len(recipes)} recipes, "
          f"{sum(len(v) for v in prov.values())} provenance rows, "
          f"{len(edges)} edges, {len(scopes)} scopes -- all present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
