#!/usr/bin/env python3
"""Falsifiable checks over the native settings schemas declared in mods/*/*.nim.

Not "is the description non-empty" -- that check cannot fail once anyone types a
space. Each check below names an input that makes it FAIL:

  P1 provenance   every description starts with one of the registered
                  provenance sentences in PROVENANCE.  FAILS when a new
                  setting is added with prose but no attribution.
  P2 placeholder  no description contains TODO / TBD / FIXME / "description
                  here".  FAILS on a stub left behind.
  P3 unique keys  no mod declares the same key twice.  FAILS on copy-paste.
  P4 backing      every declared key resolves to a path in that mod's
                  config.json.  FAILS on a row wired to nothing (a control
                  that renders and changes no stored value).

Exit 0 only if every check passes.  P4 reports separately as WARN-listed
"unbacked" rows because some mods intentionally proxy keys they do not own
(morebots rows are persisted by mods/sain); those are listed, not fatal, and
the list is the gap report.

    python tools/check_settings.py [repo-root]
"""
import re, sys, os, json, glob
from collections import Counter

BS = chr(92)
STRRE = '"((?:[^"' + BS + BS + ']|' + BS + BS + '.)*)"'

PROVENANCE = [
    "From SAIN (Solarint, maintained by ArchangelWTF)",
    "From MoreBotsAPI (TacticalToaster)",
    "From Fontaine's FOV Fix (com.fontaine.fovfix)",
    "From TarkovTextures",
    "From TarkovGraphics",
    "Specified from the pre-1.0 BepInEx map/radar mods",
    "aowlspt original",
    "provenance unknown",
]
PLACEHOLDERS = ("TODO", "TBD", "FIXME", "description here", "XXX")

CALL = re.compile(r'\b(bool|int|float|enum|string|keybind|select)Setting\s*\(')
STR = re.compile(STRRE)


def parse(root):
    rows = []
    for f in sorted(glob.glob(os.path.join(root, 'mods', '**', '*.nim'), recursive=True)):
        if 'nimcache' in f or f.endswith('tuning.nim'):
            continue
        rel = os.path.relpath(f, root).replace(BS, '/')
        mod = rel.split('/')[1]
        s = open(f, encoding='utf-8').read()
        for m in CALL.finditer(s):
            i = m.end() - 1
            d = 0
            j = i
            instr = False
            while j < len(s):
                c = s[j]
                if instr:
                    if c == BS:
                        j += 2
                        continue
                    if c == '"':
                        instr = False
                else:
                    if c == '"':
                        instr = True
                    elif c == '(':
                        d += 1
                    elif c == ')':
                        d -= 1
                        if d == 0:
                            break
                j += 1
            body = s[i + 1:j]
            strs = STR.findall(body)
            if not strs:
                continue
            dm = re.search(r'description\s*=\s*(?=")', body)
            desc = ''
            if dm:
                k = dm.end()
                parts = []
                while True:
                    mo = STR.match(body, k)
                    if not mo:
                        break
                    parts.append(mo.group(1))
                    k = mo.end()
                    mo2 = re.match(r'\s*&\s*', body[k:])
                    if not mo2:
                        break
                    k += mo2.end()
                desc = ''.join(parts)
            rows.append(dict(mod=mod, file=rel, key=strs[0], desc=desc,
                             line=s[:m.start()].count('\n') + 1))
    return rows


def resolves(cfg, key):
    cur = cfg
    for part in key.split('.'):
        if not isinstance(cur, dict) or part not in cur:
            return False
        cur = cur[part]
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rows = parse(root)
    fail = []

    for r in rows:
        if not any(r['desc'].startswith(p) for p in PROVENANCE):
            fail.append("P1 %s:%d %s -- description carries no registered provenance" % (r['file'], r['line'], r['key']))
        for ph in PLACEHOLDERS:
            if ph in r['desc']:
                fail.append("P2 %s:%d %s -- placeholder %r" % (r['file'], r['line'], r['key'], ph))

    for mod in sorted(set(r['mod'] for r in rows)):
        keys = [r['key'] for r in rows if r['mod'] == mod]
        for k, n in Counter(keys).items():
            if n > 1:
                fail.append("P3 %s -- key %r declared %d times" % (mod, k, n))

    unbacked = []
    for mod in sorted(set(r['mod'] for r in rows)):
        p = os.path.join(root, 'mods', mod, 'config.json')
        cfg = json.load(open(p, encoding='utf-8')) if os.path.exists(p) else {}
        for r in rows:
            if r['mod'] == mod and not resolves(cfg, r['key']):
                unbacked.append("%s:%d %s.%s" % (r['file'], r['line'], mod, r['key']))

    print("settings parsed: %d across %d mods" % (rows and len(rows) or 0, len(set(r['mod'] for r in rows))))
    if unbacked:
        print("\nP4 unbacked (no path in that mod's config.json) -- %d:" % len(unbacked))
        for u in unbacked:
            print("   " + u)
    for f in fail:
        print("FAIL " + f)
    print("\n%s" % ("PASS" if not fail else "FAIL (%d)" % len(fail)))
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main())
