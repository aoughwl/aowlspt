#!/usr/bin/env python3
"""sehnest.py -- D8: one `aowl_p_p_seh` per body, never nested.

## The failure this makes visible

`aowl_p_p_seh` is the host's ONE structured-exception guard. It is not
re-entrant: opening a second one inside a body that is already guarded
DISARMS the outer guard, so any unrelated fault anywhere in that body stops
being a caught refusal and becomes a hard client kill -- and the symptom lands
arbitrarily far from the nesting, in a body that looks guarded when you read it.

`abi/aowlspt_il2cpp_gates.h` states the rule in a comment ("rule 3: ONE guard
around the whole body, never nested"). A comment is a convention. This is the
check.

## What it actually computes

A static call graph, in one namespace, over:

  * C functions in `abi/*.h` and in `{.emit.}` blocks inside `host/**/*.nim`
    (`static <ret> name(args) { ... }`, brace-matched),
  * Nim procs in `host/**/*.nim`, keyed by their `exportc`/`importc` name when
    they have one, so a C body calling into Nim and back into C is one graph
    and not three.

A GUARD BODY is the first argument of an `aowl_p_p_seh(...)` call -- the repo
writes them all as `aowl_p_p_seh((void*)aowl_x_body, a)`. From each guard body
the tool walks callees breadth-first; if any reachable function itself calls
`aowl_p_p_seh`, that is a nested guard and the CHAIN is printed.

## What it is NOT

An over-approximation, deliberately, and stated as one. Edges are name matches
on `ident(`, so a function pointer stored and called indirectly is an edge this
tool does not have -- a PASS means "no nesting is reachable through the calls
we can see by name", never "no nesting exists". It is also depth-limited
(`--depth`, default 6): a chain longer than that is not searched, and the
summary says so rather than implying the graph was exhausted.

## Three states, never two

  PASS  (0)   no guard body reaches a second `aowl_p_p_seh`, except chains
              already in `tools/sehnest_baseline.json` (printed every run).
  FAIL  (1)   a NEW chain, printed whole.
  INCONCLUSIVE (3)  no guard body was found at all, or nothing was scanned --
              a graph with no guards in it cannot fail, and a check that cannot
              fail IS the bug.
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

GUARD = "aowl_p_p_seh"
BASELINE = os.path.join(HERE, "sehnest_baseline.json")
SKIP_DIRS = {"nimcache", "bin", ".git", "build", "__pycache__"}
DEFAULT_DEPTH = 6

KEYWORDS = {"if", "for", "while", "switch", "return", "sizeof", "do", "else",
            "case", "defined", "static", "cast", "addr", "proc", "echo", "and",
            "or", "not", "when", "of", "int32", "uint64", "int64", "uint32",
            "var", "let", "result", "discard", "template", "func", "type"}


def strip_c(text):
    def repl(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"/\*.*?\*/", repl, text, flags=re.S)
    text = re.sub(r"//[^\n]*", repl, text)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"',
                  lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


NIM_COMMENT = re.compile(
    r'(""".*?"""|"(?:[^"\\\n]|\\.)*")'
    r'|#\[.*?\]#'
    r'|##?[^\n]*', re.S)


def strip_nim(text, keep_emit=True):
    """Nim comments out. String literals are KEPT when they may be an
    `{.emit.}` block -- that C is real code -- and blanked otherwise."""
    def repl(m):
        if m.group(1):
            return m.group(1) if keep_emit else re.sub(r"[^\n]", " ",
                                                       m.group(0))
        return re.sub(r"[^\n]", " ", m.group(0))
    return NIM_COMMENT.sub(repl, text)


C_FUNC = re.compile(
    r"^[ \t]*(?:static\s+)?(?:inline\s+)?[A-Za-z_][\w \t\*]*?"
    r"\b(\w+)\s*\([^;{)]*\)\s*\{", re.M)


def c_functions(text, path, out):
    """{name: (body, path, line)} for brace-matched C function definitions."""
    for m in C_FUNC.finditer(text):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        i = text.index("{", m.end() - 1)
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        line = text.count("\n", 0, m.start()) + 1
        out.setdefault(name, (text[i:j], path, line))


PROC_RE = re.compile(r"^(?:proc|func)\s+(\w+|`[^`]+`)\s*[\*\(]", re.M)
EXPORTC_RE = re.compile(r'(?:exportc|importc)\s*:\s*"(\w+)"')


def nim_procs(text, path, out):
    """Nim procs as graph nodes, keyed by exportc/importc name when present."""
    lines = text.split("\n")
    starts = []
    for m in PROC_RE.finditer(text):
        starts.append((text.count("\n", 0, m.start()), m.group(1).strip("`")))
    for k, (ln, name) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        # A proc body ends at the first COLUMN-0 line after its header, not at
        # the next `proc`. MEASURED: slicing to the next proc swallowed the
        # top-level `{.emit."""...aowl_p_p_seh((void*)aowl_botai_body...""".}`
        # block that sits between two procs, and the tool then reported five
        # bots' guarded wrappers as guards nested inside the very body they
        # guard -- a confidently wrong FAIL naming real files.
        j = ln + 1
        seen_eq = "=" in lines[ln]
        while j < end:
            t = lines[j]
            if t.strip() and not t[:1].isspace():
                if seen_eq:
                    break
            if "=" in t:
                seen_eq = True
            j += 1
        body = "\n".join(lines[ln:j])
        ex = EXPORTC_RE.search(body[:body.find("=") + 1] if "=" in body
                               else body)
        key = ex.group(1) if ex else name
        out.setdefault(key, (body, path, ln + 1))


EMIT_RE = re.compile(r'\{\.\s*emit\s*:\s*"""(.*?)"""\s*\.\}', re.S)


def build_graph(root):
    """({name: (body, path, line)}, files_scanned)."""
    funcs, nfiles = {}, 0
    for base in ("abi", "host"):
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
            for fn in sorted(filenames):
                p = os.path.join(dirpath, fn)
                rel = os.path.relpath(p, root).replace("\\", "/")
                try:
                    raw = open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                if fn.endswith(".h") or fn.endswith(".c"):
                    nfiles += 1
                    c_functions(strip_c(raw), rel, funcs)
                elif fn.endswith(".nim"):
                    nfiles += 1
                    stripped = strip_nim(raw)
                    for m in EMIT_RE.finditer(stripped):
                        pad = "\n" * stripped.count("\n", 0, m.start(1))
                        c_functions(strip_c(pad + m.group(1)), rel, funcs)
                    # Comments out, string literals KEPT: the exportc name in
                    # `{.exportc: "aowl_ar_tick_body".}` IS the graph key, and
                    # blanking literals here left 30 of the 43 guarded bodies
                    # unresolved under a PASS -- a check that could not fail.
                    nim_procs(stripped, rel, funcs)
    return funcs, nfiles


CALL_RE = re.compile(r"(?<![\w.])(\w+)\s*\(")

STR_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def code(body):
    """The body with double-quoted literals blanked.

    Nim string literals are KEPT when a node is built, because the exportc name
    inside `{.exportc: "aowl_x_body".}` is the graph key. They must NOT be kept
    when looking for calls: a log line reading `"... aowl_p_p_seh, and nesting
    a second guard ..."` was parsed as a guard whose body is the word `that`.
    """
    return STR_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), body)


def callees(body, funcs):
    return sorted({n for n in CALL_RE.findall(code(body))
                   if n in funcs and n not in KEYWORDS})


def opens_guard(body):
    return re.search(r"(?<![\w])%s\s*\(" % GUARD, code(body)) is not None


GUARD_ARG = re.compile(r"%s\s*\(\s*\(?\s*(?:void\s*\*\s*\)?\s*)?(\w+)"
                       % GUARD)


def guard_bodies(funcs):
    """{body_fn_name: [(opener, path, line)]} -- the first argument of every
    `aowl_p_p_seh(...)` call, which is the function that runs GUARDED."""
    out = {}
    for name, (body, path, line) in sorted(funcs.items()):
        for m in GUARD_ARG.finditer(code(body)):
            tgt = m.group(1)
            out.setdefault(tgt, []).append((name, path, line))
    return out


class Finding:
    def __init__(self, key, chain, detail):
        self.key = key
        self.chain = chain
        self.detail = detail

    def human(self):
        return "  FAIL      %s\n      %s" % (" -> ".join(self.chain),
                                             self.detail)


def find_nesting(funcs, depth):
    """[Finding] -- a guard body from which a second guard is reachable."""
    out = []
    bodies = guard_bodies(funcs)
    for start in sorted(bodies):
        if start not in funcs:
            continue                        # the body is not in our graph
        seen = {start}
        queue = [(start, [start], 0)]
        while queue:
            cur, chain, d = queue.pop(0)
            body = funcs[cur][0]
            if cur != start and opens_guard(body):
                out.append(Finding(
                    "%s>%s" % (start, cur), chain,
                    "`%s` runs INSIDE the guard opened around `%s` (%s:%d) and "
                    "opens a second `%s` of its own. The inner guard DISARMS "
                    "the outer one, so any unrelated fault in the outer body "
                    "becomes a hard client kill instead of a caught refusal."
                    % (cur, start, funcs[start][1], funcs[start][2], GUARD)))
                continue                    # one chain per (start, offender)
            if d >= depth:
                continue
            for c in callees(body, funcs):
                if c in seen:
                    continue
                seen.add(c)
                queue.append((c, chain + [c], d + 1))
    return out, bodies


def load_baseline(path):
    if not os.path.exists(path):
        return {}, None
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return {}, "baseline %s does not parse: %s" % (path, e)
    return {k: v for k, v in d.items() if not k.startswith("//")}, None


def audit(root, baseline_path=BASELINE, depth=DEFAULT_DEPTH, quiet=False):
    w = (lambda s: None) if quiet else sys.stdout.write
    base, berr = load_baseline(baseline_path)
    if berr:
        w("INCONCLUSIVE: %s\n" % berr)
        return INCONCLUSIVE
    funcs, nfiles = build_graph(root)
    if nfiles == 0 or not funcs:
        w("INCONCLUSIVE: %d file(s) scanned, %d function(s) in the graph. "
          "Nothing was checked; this is not a pass.\n" % (nfiles, len(funcs)))
        return INCONCLUSIVE
    findings, bodies = find_nesting(funcs, depth)
    if not bodies:
        w("INCONCLUSIVE: %d function(s) parsed but NO `%s(...)` call was "
          "found, so there is no guarded body to check and this check could "
          "not have failed. A check that cannot fail IS the bug.\n"
          % (len(funcs), GUARD))
        return INCONCLUSIVE

    # VACUITY. A guarded body whose function is not in the graph is not
    # searched, and a PASS built out of those is a check that could not fail.
    # MEASURED while writing this: 30 of 43 bodies were unresolved (the
    # exportc name lived in a string literal that had been blanked) and the
    # tool printed PASS.
    resolved = [b for b in bodies if b in funcs]
    if not resolved:
        w("INCONCLUSIVE: %d guarded body/bodies were named by an `%s(...)` "
          "call and NONE of them resolves to a function in the graph, so "
          "nothing was searched.\n" % (len(bodies), GUARD))
        return INCONCLUSIVE

    known = [f for f in findings if f.key in base]
    new = [f for f in findings if f.key not in base]
    stale = [k for k in base if k not in {f.key for f in findings}]

    w("\nsehnest: %d file(s), %d function(s), %d guarded body/bodies of which "
      "%d resolve in the graph and were searched, depth %d. Edges are NAME "
      "matches on `ident(`, so an indirect call is an edge this tool does not "
      "have.\n" % (nfiles, len(funcs), len(bodies), len(resolved), depth))
    for b in sorted(set(bodies) - set(resolved)):
        w("    NOT SEARCHED  %s -- named as a guarded body but no definition "
          "was parsed for it. This one was not checked.\n" % b)
    for f in sorted(known, key=lambda x: x.key):
        w("    KNOWN DEBT  %s\n        baselined: %s\n"
          % (" -> ".join(f.chain), base[f.key]))
    for k in sorted(stale):
        w("    STALE BASELINE  %s -- no longer found. Remove the entry.\n" % k)
    if new:
        w("\nFAIL -- %d NESTED guard chain(s):\n\n" % len(new))
        for f in sorted(new, key=lambda x: x.key):
            w(f.human() + "\n\n")
        w("`%s` is not re-entrant. Hoist the inner guard out, or make the "
          "inner body a plain call.\n" % GUARD)
        return FAIL
    w("PASS (%d baselined chain(s) still present)\n" % len(known))
    return PASS


# ---------------------------------------------------------------------------
# the positive control

CLEAN = '''\
static void* aowl_x_leaf(void* a) { return a; }
static void* aowl_x_body(void* a) { return aowl_x_leaf(a); }
static void* aowl_x_tick(void* a) {
    return aowl_p_p_seh((void*)aowl_x_body, a);
}
'''

NESTED = '''\
static void* aowl_y_inner(void* a) {
    return aowl_p_p_seh((void*)aowl_x_leaf, a);
}
static void* aowl_y_mid(void* a) { return aowl_y_inner(a); }
'''

REACH = '''\
static void* aowl_x_leaf2(void* a) { return aowl_y_mid(a); }
'''


def selftest():
    import tempfile
    names = {0: "PASS", 1: "FAIL", 3: "INCONCLUSIVE"}
    ok = True

    def mk(d, rel, text):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    with tempfile.TemporaryDirectory() as d:
        bl = os.path.join(d, "bl.json")
        with open(bl, "w", encoding="utf-8", newline="\n") as f:
            f.write("{}\n")

        mk(d, os.path.join("abi", "a.h"), CLEAN)
        rc = audit(d, bl, quiet=True)
        print("case 1  one guard, one body        -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

        # A second guard EXISTS but is not reachable from the first body: that
        # is two features, not a nesting. Without this control the tool could
        # be firing on "the file contains two guards".
        mk(d, os.path.join("abi", "b.h"), NESTED)
        rc = audit(d, bl, quiet=True)
        print("case 2  two UNRELATED guards       -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

        # THE POSITIVE CONTROL: now the guarded body reaches the second guard,
        # three calls down.
        mk(d, os.path.join("abi", "a.h"),
           CLEAN.replace("return aowl_x_leaf(a);",
                         "return aowl_y_mid(a);"))
        rc = audit(d, bl, quiet=True)
        print("case 3  guarded body reaches a 2nd -> %s (want FAIL)"
              % names[rc])
        ok &= rc == FAIL

        # depth 1 must NOT silently pass: it reports what it searched, and the
        # chain here is 3 hops. This asserts the depth limit is real.
        rc = audit(d, bl, depth=1, quiet=True)
        print("case 4  the same tree at --depth 1 -> %s (want PASS, and the "
              "summary says depth 1)" % names[rc])
        ok &= rc == PASS

        with open(bl, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"aowl_x_body>aowl_y_inner": "fixture"}, f)
        rc = audit(d, bl, quiet=True)
        print("case 5  the same chain, baselined  -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

    # The measured FALSE POSITIVE, as a control: a Nim guard body with the C
    # wrapper that guards it emitted at top level BETWEEN two procs. The proc
    # does not call the wrapper; the wrapper calls the proc. Reporting this is
    # a confidently wrong FAIL naming a real file, and it happened.
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "host", "H"))
        with open(os.path.join(d, "host", "H", "b.nim"), "w",
                  encoding="utf-8", newline="\n") as f:
            f.write('proc botaiBody(a: pointer): pointer {.\n'
                    '    exportc: "aowl_z_body", cdecl.} =\n'
                    '  result = a\n'
                    '\n'
                    '{.emit: """\n'
                    'extern void* aowl_z_body(void* a);\n'
                    'static void* aowl_z_guarded(void* a) {\n'
                    '    return aowl_p_p_seh((void*)aowl_z_body, a);\n'
                    '}\n'
                    '""".}\n'
                    '\n'
                    'proc other(a: pointer): pointer =\n'
                    '  result = a\n')
        rc = audit(d, os.path.join(d, "none.json"), quiet=True)
        print("case 7  guard body + its own C wrapper -> %s (want PASS)"
              % names[rc])
        ok &= rc == PASS

    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "abi"))
        with open(os.path.join(d, "abi", "n.h"), "w", newline="\n") as f:
            f.write("static void* f(void* a) { return a; }\n")
        rc = audit(d, os.path.join(d, "none.json"), quiet=True)
        print("case 6  a tree with NO guard at all-> %s (want INCONCLUSIVE)"
              % names[rc])
        ok &= rc == INCONCLUSIVE

    print("VERDICT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    p = argparse.ArgumentParser(
        description="D8: no `aowl_p_p_seh` inside a body that is already "
                    "guarded (exit 0 PASS / 1 FAIL / 3 INCONCLUSIVE)")
    p.add_argument("--root", default=REPO)
    p.add_argument("--baseline", default=BASELINE)
    p.add_argument("--depth", type=int, default=DEFAULT_DEPTH,
                   help="call-graph hops searched from each guarded body "
                        "(default %d). A longer chain is NOT searched and the "
                        "summary says so." % DEFAULT_DEPTH)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    if a.selftest:
        return selftest()
    return audit(a.root, a.baseline, a.depth, quiet=a.quiet)


if __name__ == "__main__":
    sys.exit(main())
