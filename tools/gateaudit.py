#!/usr/bin/env python3
"""gateaudit.py -- X1: no TOKEN-GATED il2cpp export may be called without its
token, and none may be bound by name outside the gate layer.

## The failure this makes visible

40 of the 241 `il2cpp_*` exports on this build take an extra trailing argument
we never pass -- a pointer to 32 bytes -- and `memcmp` it first. On mismatch
they do NOT return NULL: they return a uniform random non-zero uint64 from a
per-thread MT19937-64. So a nil check PASSES and the first dereference kills
the client, arbitrarily later, with nothing of ours on the stack.

The armed path is `aowl_gate_call()` in `abi/aowlspt_il2cpp_gates.h`, which
splices the token in at the argument index the generated map recorded, verifies
the prologue against the startup snapshot, and reports `aowl_gate_call_ok()`
rather than `ret != NULL`. Anything else that reaches one of those 40 exports
by name -- `GetProcAddress(ga, "il2cpp_class_from_name")`, a Nim
`importc: "il2cpp_field_get_offset"`, a plain C call -- is calling it with NO
token, whether or not it looks like it works today.

## Three states, never two

  PASS  (0)   no gated export is bound or called outside the gate layer,
              except sites already recorded in the baseline (printed, loudly,
              every run).
  FAIL  (1)   a NEW site. Named, with file:line and the export.
  INCONCLUSIVE (3)  the export table could not be parsed, or the scan visited
              no files -- "I could not look" is never a pass, and this never
              exits 0 on it.

## Why a baseline and not a clean refusal

Two sites in `abi/` already do this (see `tools/gateaudit_baseline.json`), and
a gate that refuses every build on the day it lands is a gate that gets
`--no-gate-audit`-ed forever. The baseline is therefore an inventory that can
only shrink: every entry is printed on every run with its reason, a site that
is NOT in it fails the build, and a baseline entry whose site has disappeared
is reported as stale so the file cannot rot into a blanket waiver. It is never
edited to make a check pass -- exactly like `tools/deploy.json`.
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

GATES_DATA = os.path.join("abi", "aowlspt_il2cpp_gates_data.h")
BASELINE = os.path.join(HERE, "gateaudit_baseline.json")

# The gate layer itself: these files exist to bind and call the gated exports
# through the armed path, so a name in them is the mechanism, not a violation.
GATE_LAYER = {
    "aowlspt_il2cpp_gates.h",
    "aowlspt_il2cpp_gates_data.h",
    "aowlspt_il2cpp_gatetest.h",
}

SCAN_ROOTS = ("abi", "host", "mods", "aowl")
SKIP_DIRS = {"nimcache", "bin", ".git", "build", "__pycache__"}

ROW_RE = re.compile(r'\{\s*"(il2cpp_[A-Za-z0-9_]+)"\s*,\s*0x[0-9A-Fa-f]+')


class Finding:
    def __init__(self, key, where, kind, name, detail):
        self.key = key
        self.where = where
        self.kind = kind
        self.name = name
        self.detail = detail

    def human(self):
        return "  %-10s %s\n      %s" % (self.kind, self.where, self.detail)


def gated_names(root):
    """(set_of_names, why_not). Parsed from the GENERATED table, never typed."""
    p = os.path.join(root, GATES_DATA)
    if not os.path.exists(p):
        return None, "%s not found (regenerate with tools/il2cpp_gatescan.py)" % p
    text = open(p, encoding="utf-8", errors="replace").read()
    body = text.split("aowl_gate_rows[]", 1)
    if len(body) < 2:
        return None, "%s has no `aowl_gate_rows[]` table" % p
    rows = body[1].split("};", 1)[0]
    names = set(ROW_RE.findall(rows))
    if not names:
        return None, "%s parsed to ZERO gated export names" % p
    return names, None


def strip_c(text):
    def repl(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"/\*.*?\*/", repl, text, flags=re.S)
    return re.sub(r"//[^\n]*", repl, text)


NIM_COMMENT = re.compile(
    r'(""".*?"""|"(?:[^"\\\n]|\\.)*")'
    r'|#\[.*?\]#'
    r'|##?[^\n]*', re.S)


def strip_nim(text):
    def repl(m):
        return m.group(1) if m.group(1) else re.sub(r"[^\n]", " ", m.group(0))
    return NIM_COMMENT.sub(repl, text)


STR_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def blank_strings(text):
    """Double-quoted literals blanked, newlines kept.

    Load-bearing for the `call` pattern and for nothing else. MEASURED on this
    repo before it existed: `debug "sain: gated il2cpp_class_from_name(" & ...`
    -- a LOG MESSAGE -- was reported as a raw call at mods/sain/client/live.nim
    :451, two lines below the armed `sainGateCall` that actually makes the
    call. A confidently wrong FAIL is worse than no tool. The bind patterns
    still run on the unblanked text, because there the literal IS the evidence.
    """
    return STR_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def iter_files(root):
    for base in SCAN_ROOTS:
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
            for fn in sorted(filenames):
                if fn.endswith((".h", ".nim", ".c")):
                    yield os.path.join(dirpath, fn), fn


def scan(root, names):
    """([Finding], files_scanned). One finding per (file, export, kind)."""
    out, seen, nfiles = [], set(), 0
    for p, fn in iter_files(root):
        if fn in GATE_LAYER:
            continue
        try:
            raw = open(p, encoding="utf-8", errors="replace").read()
        except OSError as e:
            out.append(Finding("%s|?|unreadable" % fn, p, "FAIL", "?",
                               "unreadable: %s" % e))
            continue
        nfiles += 1
        text = strip_nim(raw) if fn.endswith(".nim") else strip_c(raw)
        rel = os.path.relpath(p, root).replace("\\", "/")
        # In a .nim file the C inside {.emit.} survives strip_nim as a string
        # literal, which is exactly what we want: an emitted C call is still a
        # call. That is why the C patterns are applied to every file.
        pats = [
            ("bind-gpa",
             re.compile(r'GetProcAddress\s*\(\s*[^,()]*,\s*"(%s)"'
                        % "|".join(sorted(names))),
             "is bound by NAME with GetProcAddress. That handle reaches the "
             "export with NO token: on a mismatch it returns MT19937-64 "
             "output that passes a nil check. Route it through "
             "`aowl_gate_call()`."),
            ("bind-importc",
             re.compile(r'importc\s*:\s*"(%s)"' % "|".join(sorted(names))),
             "is imported directly into Nim. A Nim call on that symbol passes "
             "no token. Route it through `aowl_gate_call()`."),
            ("call",
             re.compile(r'(?<![\w"])(%s)\s*\(' % "|".join(sorted(names))),
             "is CALLED directly by name, so it is called without its token. "
             "Route it through `aowl_gate_call()`."),
        ]
        nostr = blank_strings(text)
        for kind, rx, why in pats:
            for m in rx.finditer(nostr if kind == "call" else text):
                name = m.group(1)
                key = "%s|%s|%s" % (rel, name, kind)
                if key in seen:
                    continue
                seen.add(key)
                line = text.count("\n", 0, m.start()) + 1
                out.append(Finding(key, "%s:%d" % (rel, line), "FAIL", name,
                                   "`%s` is TOKEN-GATED and %s" % (name, why)))
    return out, nfiles


def load_baseline(path):
    if not os.path.exists(path):
        return {}, None
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return {}, "baseline %s does not parse: %s" % (path, e)
    return {k: v for k, v in d.items() if not k.startswith("//")}, None


def audit(root, baseline_path=BASELINE, quiet=False):
    w = (lambda s: None) if quiet else sys.stdout.write
    names, why = gated_names(root)
    if names is None:
        w("INCONCLUSIVE input: %s\n"
          "  Nothing was checked. This is not a pass.\n" % why)
        return INCONCLUSIVE
    base, berr = load_baseline(baseline_path)
    if berr:
        w("INCONCLUSIVE: %s\n" % berr)
        return INCONCLUSIVE

    findings, nfiles = scan(root, names)
    if nfiles == 0:
        w("INCONCLUSIVE: the scan visited ZERO files under %s. A PASS from a "
          "scan that read nothing is the failure this tool exists to "
          "prevent.\n" % ", ".join(SCAN_ROOTS))
        return INCONCLUSIVE

    known = [f for f in findings if f.key in base]
    new = [f for f in findings if f.key not in base]
    stale = [k for k in base if k not in {f.key for f in findings}]

    w("\ngateaudit: %d gated export name(s) from %s; %d file(s) scanned.\n"
      % (len(names), GATES_DATA, nfiles))
    for f in sorted(known, key=lambda x: x.key):
        w("    KNOWN DEBT  %s  %s\n        baselined: %s\n"
          % (f.where, f.name, base[f.key]))
    for k in sorted(stale):
        w("    STALE BASELINE  %s -- no longer found. Remove the entry; a "
          "baseline that outlives its site becomes a blanket waiver.\n" % k)

    if new:
        w("\nFAIL -- %d NEW un-gated site(s):\n\n" % len(new))
        for f in sorted(new, key=lambda x: x.key):
            w(f.human() + "\n\n")
        w("A gated export called without its token does not fail: it returns "
          "a random non-zero uint64 that passes a nil check and kills the "
          "client on first dereference. Call it through `aowl_gate_call()` "
          "and test `aowl_gate_call_ok()`, never `ret != NULL`.\n")
        return FAIL
    w("PASS (%d baselined site(s) still present)\n" % len(known))
    return PASS


# ---------------------------------------------------------------------------
# the positive control

FIXTURE_GATES = '''\
static const aowl_gate_row_t aowl_gate_rows[] = {
    { "il2cpp_class_from_name", 0x5B1B80, 0x5B1B80, 2, 3, 0, 0x2B0, 0x5BA6F0 },
    { "il2cpp_field_get_offset", 0x5B3310, 0x5B3310, 2, 1, 0, 0x198, 0x5B93B0 },
};
'''

FIXTURE_CLEAN = '''\
/* calls the armed path only */
static void* f(void) {
    aowl_gate_call_t c;
    void* a[1]; a[0] = 0;
    if (!aowl_gate_call("il2cpp_field_get_offset", a, 1, &c)) return 0;
    return c.ret;
}
'''

# The measured false positive, as a NEGATIVE control: the export name appears
# in a log message with a following `(`, and must NOT read as a call.
FIXTURE_PROSE = '''\
proc r(ns: string) =
  debug "sain: gated il2cpp_class_from_name(" & ns & ") refused"
'''

FIXTURE_DIRTY = '''\
static void* g(void* ga, void* klass) {
    void* p = GetProcAddress(ga, "il2cpp_class_from_name");
    return p ? il2cpp_field_get_offset(klass) : 0;
}
'''


def selftest():
    import tempfile
    ok = True

    def mk(d, rel, text):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    with tempfile.TemporaryDirectory() as d:
        mk(d, os.path.join("abi", "aowlspt_il2cpp_gates_data.h"), FIXTURE_GATES)
        mk(d, os.path.join("host", "clean.h"), FIXTURE_CLEAN)
        mk(d, os.path.join("mods", "prose.nim"), FIXTURE_PROSE)
        bl = os.path.join(d, "baseline.json")
        with open(bl, "w", encoding="utf-8", newline="\n") as f:
            f.write("{}\n")
        rc = audit(d, bl, quiet=True)
        print("case 1  clean tree + the log-message false positive -> %s (want PASS)"
              % {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}[rc])
        ok &= rc == PASS

        # THE POSITIVE CONTROL: a GetProcAddress bind and a raw call, exactly
        # the shape §7.2 asks this tool to catch.
        mk(d, os.path.join("host", "dirty.h"), FIXTURE_DIRTY)
        rc = audit(d, bl, quiet=True)
        print("case 2  raw bind + raw call   -> %s (want FAIL)"
              % {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}[rc])
        ok &= rc == FAIL

        # and the baseline waives EXACTLY those two keys, nothing wider
        with open(bl, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"host/dirty.h|il2cpp_class_from_name|bind-gpa": "fixture",
                       "host/dirty.h|il2cpp_field_get_offset|call": "fixture"},
                      f, indent=1)
        rc = audit(d, bl, quiet=True)
        print("case 3  the same two, baselined -> %s (want PASS)"
              % {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}[rc])
        ok &= rc == PASS

        # a THIRD site is still a FAIL: the baseline waives sites, not the tool
        mk(d, os.path.join("host", "more.nim"),
           'proc q(): pointer {.importc: "il2cpp_class_from_name".}\n')
        rc = audit(d, bl, quiet=True)
        print("case 4  a new site beside them -> %s (want FAIL)"
              % {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}[rc])
        ok &= rc == FAIL

    with tempfile.TemporaryDirectory() as d:
        rc = audit(d, os.devnull + ".missing", quiet=True)
        print("case 5  no export table        -> %s (want INCONCLUSIVE)"
              % {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}[rc])
        ok &= rc == INCONCLUSIVE

    print("VERDICT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    p = argparse.ArgumentParser(
        description="X1: refuse any token-gated il2cpp export bound or called "
                    "outside the gate layer (exit 0 PASS / 1 FAIL / 3 "
                    "INCONCLUSIVE)")
    p.add_argument("--root", default=REPO)
    p.add_argument("--baseline", default=BASELINE)
    p.add_argument("--selftest", action="store_true",
                   help="run the positive controls: a clean tree, a tree with "
                        "a raw bind and a raw call, and a missing table")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    if a.selftest:
        return selftest()
    return audit(a.root, a.baseline, quiet=a.quiet)


if __name__ == "__main__":
    sys.exit(main())
