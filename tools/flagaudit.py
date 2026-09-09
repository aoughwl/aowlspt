#!/usr/bin/env python3
"""flagaudit.py -- D10: every host feature flag defaults OFF.

## The failure this makes visible

A flag that defaults ON runs an unproven path for every user on the very next
deploy. That is how an experiment becomes a release: nobody decided to ship it,
the default just was `true`. `tools/hostcfg.py` already knows the flag NAMES;
it does not read the DEFAULT, so the one thing that decides whether a feature
is live on a machine nobody configured has never been checked by anything.

## What it reads

Every `readBoolKey("name")` and `readBoolKeyDef("name", default)` call site in
`host/**/*.nim`. `readBoolKey` has no default and returns false when the key is
absent, so it is OFF by construction and is only counted. `readBoolKeyDef` is
the one that can ship a feature: a literal `true` there FAILS unless the flag
name is in `tools/deploy.json` under `flagDefaultsOn`, with a REASON.

A default that is not a literal `true`/`false` -- an expression, a constant --
also FAILS: a default that cannot be read offline is not a checked default.

## Three states, never two

  PASS  (0)   no `readBoolKeyDef` defaults true except the allowlisted ones,
              each of which is printed with its reason on every run.
  FAIL  (1)   one does, or an allowlist entry has no reason, or a default is
              not a literal.
  INCONCLUSIVE (3)  no call site was found at all, or deploy.json is missing or
              unparseable -- a scan that read nothing is not a pass.

## The allowlist is data, and it is not a waiver

`flagDefaultsOn` lives in `tools/deploy.json` next to the markers, under the
same rule: **never edit it to make a check pass.** An entry is a decision that
this feature ships ON, written down with the measurement behind it. An entry
whose flag no longer defaults true is reported as stale, so the list cannot rot
into a blanket permission.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PASS, FAIL, INCONCLUSIVE = 0, 1, 3

DEPLOY_JSON = os.path.join("tools", "deploy.json")
ALLOW_KEY = "flagDefaultsOn"
SKIP_DIRS = {"nimcache", "bin", ".git", "build", "__pycache__"}

NIM_COMMENT = re.compile(
    r'(""".*?"""|"(?:[^"\\\n]|\\.)*")'
    r'|#\[.*?\]#'
    r'|##?[^\n]*', re.S)


def strip_nim(text):
    def repl(m):
        return m.group(1) if m.group(1) else re.sub(r"[^\n]", " ", m.group(0))
    return NIM_COMMENT.sub(repl, text)


# `readBoolKeyDef("x", true)` and `readBoolKey("x")`. The `Def` suffix is
# OPTIONAL and captured, because the two readers differ in exactly the thing
# this tool is about.
CALL_RE = re.compile(
    r'\breadBoolKey(Def)?\s*\(\s*"([^"]+)"\s*(?:,\s*([^,)]+?)\s*)?\)')


class Site:
    def __init__(self, name, default, where, is_def):
        self.name = name
        self.default = default
        self.where = where
        self.is_def = is_def


def sites(root):
    out = []
    d = os.path.join(root, "host")
    if not os.path.isdir(d):
        return out
    for dirpath, dirnames, filenames in os.walk(d):
        dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".nim"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = strip_nim(open(p, encoding="utf-8",
                                      errors="replace").read())
            except OSError:
                continue
            rel = os.path.relpath(p, root).replace("\\", "/")
            for m in CALL_RE.finditer(text):
                # The proc DEFINITION reads `proc readBoolKeyDef(key: string;
                # dflt: bool)`, which this regex cannot match (no string
                # literal), so definitions are excluded by construction.
                line = text.count("\n", 0, m.start()) + 1
                out.append(Site(m.group(2),
                                (m.group(3) or "").strip(),
                                "%s:%d" % (rel, line),
                                bool(m.group(1))))
    return out


def load_allow(root):
    p = os.path.join(root, DEPLOY_JSON)
    if not os.path.exists(p):
        return None, "%s not found" % p
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception as e:
        return None, "%s does not parse: %s" % (p, e)
    allow = d.get(ALLOW_KEY)
    if allow is None:
        return {}, None
    if not isinstance(allow, dict):
        return None, "%s.%s is not an object of name -> reason" % (p, ALLOW_KEY)
    return {k: v for k, v in allow.items() if not k.startswith("//")}, None


class Finding:
    def __init__(self, where, detail):
        self.where, self.detail = where, detail

    def human(self):
        return "  FAIL      %s\n      %s" % (self.where, self.detail)


def audit(root, quiet=False):
    w = (lambda s: None) if quiet else sys.stdout.write
    allow, why = load_allow(root)
    if allow is None:
        w("INCONCLUSIVE: %s. Nothing was checked.\n" % why)
        return INCONCLUSIVE
    found = sites(root)
    if not found:
        w("INCONCLUSIVE: no readBoolKey/readBoolKeyDef call site was found "
          "under host/. A scan that read nothing is not a pass.\n")
        return INCONCLUSIVE

    findings, on = [], []
    for s in found:
        if not s.is_def:
            continue                       # no default: OFF by construction
        if s.default == "false":
            continue
        if s.default != "true":
            findings.append(Finding(
                "%s %s" % (s.where, s.name),
                "readBoolKeyDef's default is %r, which is not the literal "
                "`true` or `false`. A default that cannot be read offline is "
                "not a checked default -- pass a literal."
                % (s.default or "<missing>")))
            continue
        reason = allow.get(s.name)
        if not reason:
            findings.append(Finding(
                "%s %s" % (s.where, s.name),
                "defaults TRUE and is not in tools/deploy.json %s. A flag that "
                "defaults ON runs its path for every user on the next deploy, "
                "whether or not anyone asked for it. Default it false, or add "
                "it to the allowlist WITH the measurement that says why it "
                "ships on." % ALLOW_KEY))
            continue
        on.append((s.name, s.where, reason))

    default_true = {s.name for s in found if s.is_def and s.default == "true"}
    for k, v in sorted(allow.items()):
        if k not in default_true:
            findings.append(Finding(
                "tools/deploy.json %s.%s" % (ALLOW_KEY, k),
                "allows a default-ON flag that no `readBoolKeyDef(\"%s\", "
                "true)` site declares any more. Remove the entry: an allowlist "
                "that outlives its site is a blanket permission." % k))
        elif not isinstance(v, str) or len(v.strip()) < 20:
            findings.append(Finding(
                "tools/deploy.json %s.%s" % (ALLOW_KEY, k),
                "has no usable reason (%r). The entry IS the decision to ship "
                "this on; write down what makes it safe." % v))

    w("\nflagaudit: %d flag read(s) under host/ -- %d readBoolKey (OFF by "
      "construction), %d readBoolKeyDef, %d of which default ON.\n"
      % (len(found), sum(1 for s in found if not s.is_def),
         sum(1 for s in found if s.is_def), len(default_true)))
    for name, where, reason in sorted(on):
        w("    DEFAULT ON  %-28s %s\n        allowed: %s\n"
          % (name, where, reason))
    if findings:
        w("\nFAIL -- %d finding(s):\n\n" % len(findings))
        for f in sorted(findings, key=lambda x: x.where):
            w(f.human() + "\n\n")
        return FAIL
    w("PASS\n")
    return PASS


# ---------------------------------------------------------------------------
# the positive control

FIX_OFF = '''\
proc a() =
  gX = readBoolKey("plainFlag")
  gY = readBoolKeyDef("explicitOff", false)
'''
FIX_ON = 'proc b() =\n  gZ = readBoolKeyDef("shipsOn", true)\n'
FIX_EXPR = 'proc c() =\n  gW = readBoolKeyDef("computed", gSomething)\n'


def selftest():
    import tempfile
    names = {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}
    ok = True

    def mk(d, rel, text):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    def deploy(d, allow):
        mk(d, os.path.join("tools", "deploy.json"),
           json.dumps({"artifacts": [], ALLOW_KEY: allow}, indent=1) + "\n")

    with tempfile.TemporaryDirectory() as d:
        deploy(d, {})
        mk(d, os.path.join("host", "h", "a.nim"), FIX_OFF)
        rc = audit(d, quiet=True)
        print("case 1  flags that default OFF        -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

        # THE POSITIVE CONTROL
        mk(d, os.path.join("host", "h", "b.nim"), FIX_ON)
        rc = audit(d, quiet=True)
        print("case 2  a flag defaulting TRUE        -> %s (want FAIL)"
              % names[rc])
        ok &= rc == FAIL

        deploy(d, {"shipsOn": "measured 2026-01-01: it writes nothing and a "
                              "default-off version is not legible"})
        rc = audit(d, quiet=True)
        print("case 3  the same flag, allowlisted    -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

        deploy(d, {"shipsOn": "because"})
        rc = audit(d, quiet=True)
        print("case 4  allowlisted with no reason    -> %s (want FAIL)"
              % names[rc])
        ok &= rc == FAIL

        deploy(d, {"shipsOn": "measured 2026-01-01: it writes nothing and a "
                              "default-off version is not legible",
                   "goneAway": "a flag that no longer defaults on at all"})
        rc = audit(d, quiet=True)
        print("case 5  a STALE allowlist entry       -> %s (want FAIL)"
              % names[rc])
        ok &= rc == FAIL

        deploy(d, {"shipsOn": "measured 2026-01-01: it writes nothing and a "
                              "default-off version is not legible"})
        mk(d, os.path.join("host", "h", "c.nim"), FIX_EXPR)
        rc = audit(d, quiet=True)
        print("case 6  a default that is not literal -> %s (want FAIL)"
              % names[rc])
        ok &= rc == FAIL

    with tempfile.TemporaryDirectory() as d:
        deploy(d, {})
        rc = audit(d, quiet=True)
        print("case 7  no call site anywhere         -> %s (want "
              "INCONCLUSIVE)" % names[rc])
        ok &= rc == INCONCLUSIVE

    print("VERDICT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    p = argparse.ArgumentParser(
        description="D10: every host feature flag defaults OFF unless "
                    "tools/deploy.json allows it with a reason (exit 0 PASS / "
                    "1 FAIL / 3 INCONCLUSIVE)")
    p.add_argument("--root", default=REPO)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    if a.selftest:
        return selftest()
    return audit(a.root, quiet=a.quiet)


if __name__ == "__main__":
    sys.exit(main())
