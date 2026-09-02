#!/usr/bin/env python3
r"""nimlint.py -- refuse the source shapes that make nimony die WITHOUT naming
a file.

    python tools/nimlint.py                 # scan the whole checkout
    python tools/nimlint.py host/ mods/x    # scan given files/dirs
    python tools/nimlint.py --strict        # warnings fail too
    python tools/nimlint.py --json
    python tools/nimlint.py --list          # print the pattern registry
    python tools/nimlint.py --selftest      # positive + negative control

Exit: 0 clean / 1 findings / 3 COULD NOT SCAN.

Three outcomes, never two. "I could not read the tree" is exit 3 and is NOT a
pass -- a lint that returns clean because it found nothing to look at is the
check-that-cannot-fail this repo keeps paying for.

## Why this exists (measured 2026-09-01, 19:49 -> 22:26)

Every host and backend build in this checkout died inside nimony's hexer at the
nifmake graph stage with:

    getOrQuit: missing key

and NOTHING else. No file, no line, no symbol, no traceback into user code.
Two and a half hours of bisecting followed, through an isolated worktree, an
`aowl clean`, a driver pre-step, and an include-bisect that produced a
confident WRONG verdict (`uihooks.nim`) because it classified "the error
changed" as "the cause was removed".

The actual cause was ten lines away from where the session started, in
`host/common/jsonpath.nim`, which a module move had left as:

    import aowlspt/jsonpath
    export jsonpath

`export <module>` -- exporting a whole imported module rather than named
symbols. Replacing it with a plain `include` of the moved file made the
IDENTICAL tree build (commit cb9a816; artifact 4,571,648 bytes).

That is the entire value here: the compiler cannot name the file, so a tool
has to. A grep takes 200ms; the incident took 150 minutes.

## The part that is INFERRED, and is flagged as such

The recorded rule reads "never `export <module>` in this codebase". Measured
against the tree on 2026-09-02, that rule is too broad to be enforced as
fatal: three whole-module re-exports exist today in code that builds --

    aowl/src/aowlspt.nim:40      export abi        (on every mod's command line)
    mods/maps/sp/hud.nim:57      export place
    mods/morebots/bots/dbpath.nim:23  export pending

The one that killed the compiler differs from those three in a way that is
visible in the source and is the obvious suspect for a "missing key" in a
module graph: the re-exporting file and the re-exported module have THE SAME
MODULE NAME. `host/common/jsonpath.nim` re-exported `aowlspt/jsonpath`, so two
distinct files both present themselves to the graph as `jsonpath`, and the
host's `import jsonpath` had to choose.

That discriminator is INFERRED, not measured -- nobody has built a same-named
re-export of some other module to confirm, and this tool is not allowed to
build. So the registry splits the pattern in two:

  * ERROR -- a whole-module re-export whose module name equals the
    re-exporting file's own name. This is the exact measured incident shape.
  * WARN  -- any other whole-module re-export. Present in three building files
    today, so calling it fatal would be a confidently wrong answer. It is
    still worth seeing, because if a tree-wide `getOrQuit` appears again these
    are the first three lines to try.

If a same-name-collision-free re-export is ever measured to kill the hexer,
move `MODULE_REEXPORT_WARN`'s severity to "error" and record the measurement
in docs/AOWL_FACTS.md. Do NOT flip it to make some build pass.

## Adding a pattern

One entry in PATTERNS. It must carry: what it matches, WHY (mechanism, not
folklore), the measured incident it comes from, and the fix that was applied.
A pattern with no measured incident does not belong here -- this file's whole
claim on a caller's trust is that every entry cost somebody hours.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Scanned by default. `tools/` is included because tools/*.nim are compiled by
# the same compiler (aowl.nim, aowllaunch.nim, ...).
DEFAULT_ROOTS = ("host", "aowl", "mods", "backend", "tools")

# Build outputs and compiler scratch. `nimcache` holds generated .nim/.nif that
# legitimately contains anything at all.
SKIP_DIRS = {"build", "bin", "nimcache", ".git", "__pycache__", ".cache",
             "node_modules", ".aowl"}

# The controls live here and the positive one is SUPPOSED to fire, so a
# whole-checkout scan must not walk into it. An explicit path argument still
# scans it (that is how --selftest works).
FIXTURES = os.path.join("tools", "fixtures", "nimlint")

SEV_ERROR = "error"
SEV_WARN = "warn"


# ---------------------------------------------------------------------------
# stripping comments and strings -- a match inside either is a false positive
# ---------------------------------------------------------------------------

def strip_noncode(lines):
    """One pass, THREE parallel lists, all the same length as `lines`.

      code      -- comments AND string literals blanked out
      nocode    -- comments blanked, string literals KEPT
      in_long   -- True if the line STARTED inside a triple-quoted literal

    Two variants are needed because `export foo` and `import "../x"` want
    opposite things. An `export` written inside a string is not code (a
    refusal message quoting the bad form would otherwise fire this linter on
    its own error text -- fixture `good/instring.nim`), so exports are read
    from `code`. But nim's `import "relative/path"` puts the module path IN a
    string literal, so imports read from `code` see nothing at all -- which is
    exactly how the mod-import control silently failed to fire the first time.
    Imports are therefore read from `nocode`, and only on lines that did not
    START inside a long string, so a doc block quoting an import is still
    ignored.

    Handles: `#` line comments, `#[ ]#` nestable block comments, triple-quoted
    long strings, ordinary `"..."` with backslash escapes, and `'c'` chars.

    Deliberately conservative: anything it is unsure about it BLANKS, so the
    failure mode is a missed finding rather than an invented one. A linter that
    invents a finding gets turned off, and then it finds nothing forever.
    """
    code, nocode, starts = [], [], []
    block_depth = 0      # #[ ]# nesting
    in_long = False      # inside a triple-quoted literal
    for raw in lines:
        starts.append(in_long)
        buf, sbuf = [], []
        i = 0
        n = len(raw)
        while i < n:
            if in_long:
                if raw.startswith('"""', i):
                    in_long = False
                    sbuf.append('"""')
                    i += 3
                else:
                    sbuf.append(raw[i])
                    i += 1
                continue
            if block_depth:
                if raw.startswith("#[", i):
                    block_depth += 1
                    i += 2
                elif raw.startswith("]#", i):
                    block_depth -= 1
                    i += 2
                else:
                    i += 1
                continue
            if raw.startswith("#[", i):
                block_depth += 1
                i += 2
                continue
            if raw[i] == "#":
                break  # line comment (## doc comment included)
            if raw.startswith('"""', i):
                in_long = True
                sbuf.append('"""')
                i += 3
                continue
            if raw[i] in '"\'':
                q = raw[i]
                sbuf.append(q)
                i += 1
                while i < n:
                    if raw[i] == "\\":
                        sbuf.append(raw[i:i + 2])
                        i += 2
                        continue
                    sbuf.append(raw[i])
                    if raw[i] == q:
                        i += 1
                        break
                    i += 1
                continue
            buf.append(raw[i])
            sbuf.append(raw[i])
            i += 1
        code.append("".join(buf))
        nocode.append("".join(sbuf))
    return code, nocode, starts


# ---------------------------------------------------------------------------
# the facts a pattern gets to look at
# ---------------------------------------------------------------------------

IMPORT_RE = re.compile(r"^\s*import\s+(.+)$")
FROM_RE = re.compile(r"^\s*from\s+(\S+)\s+import\b")
INCLUDE_RE = re.compile(r"^\s*include\s+(.+)$")
EXPORT_RE = re.compile(r"^\s*export\s+(.+)$")

# `import a/b as c` / `import a except d` -- only the module path matters here.
_AS_RE = re.compile(r"\s+as\s+\S+$")
_EXCEPT_RE = re.compile(r"\s+except\s+.*$")


def _module_name(spec):
    """`aowlspt/jsonpath` -> `jsonpath`; `"../../x/y.nim"` -> `y`."""
    s = spec.strip().strip('"')
    s = _AS_RE.sub("", s)
    s = _EXCEPT_RE.sub("", s)
    s = s.strip().strip('"')
    if not s:
        return ""
    s = s.replace("\\", "/")
    base = s.rsplit("/", 1)[-1]
    if base.endswith(".nim"):
        base = base[:-4]
    return base.strip()


def _split_specs(rest):
    """The comma list after `import` / `export`, minus any trailing junk."""
    parts = []
    for chunk in rest.split(","):
        c = chunk.strip()
        if c:
            parts.append(c)
    return parts


class NimFile(object):
    """Everything the patterns are allowed to know about one file."""

    def __init__(self, path, rel, lines):
        self.path = path
        self.rel = rel
        self.lines = lines                     # raw, for reporting
        # code: strings blanked (exports).  nocode: strings kept (imports).
        self.code, self.nocode, self.in_long = strip_noncode(lines)
        self.module = _module_name(os.path.basename(path))
        self.imports = {}                      # module name -> line no
        self.includes = {}
        self.import_specs = {}                 # module name -> full spec
        for i, ln in enumerate(self.nocode, 1):
            if self.in_long[i - 1]:
                continue
            m = IMPORT_RE.match(ln)
            if m:
                for spec in _split_specs(m.group(1)):
                    nm = _module_name(spec)
                    if nm:
                        self.imports.setdefault(nm, i)
                        self.import_specs.setdefault(nm, spec.strip())
                continue
            m = FROM_RE.match(ln)
            if m:
                nm = _module_name(m.group(1))
                if nm:
                    self.imports.setdefault(nm, i)
                    self.import_specs.setdefault(nm, m.group(1).strip())
                continue
            m = INCLUDE_RE.match(ln)
            if m:
                for spec in _split_specs(m.group(1)):
                    nm = _module_name(spec)
                    if nm:
                        self.includes.setdefault(nm, i)


class Finding(object):
    def __init__(self, pattern, nf, line, text, extra=""):
        self.pattern = pattern
        self.rel = nf.rel
        self.line = line
        self.text = text.rstrip()
        self.extra = extra

    @property
    def severity(self):
        return self.pattern["severity"]

    def as_dict(self):
        return {"pattern": self.pattern["id"],
                "severity": self.severity,
                "file": self.rel, "line": self.line,
                "source": self.text,
                "why": self.pattern["why"],
                "incident": self.pattern["incident"],
                "fix": self.pattern["fix"],
                "detail": self.extra}

    def human(self):
        p = self.pattern
        head = ("%s:%d: [%s] %s: %s"
                % (self.rel, self.line, self.severity.upper(), p["id"],
                   p["title"]))
        out = [head, "    | %s" % self.text]
        if self.extra:
            out.append("    %s" % self.extra)
        out.append("    why:      %s" % p["why"])
        out.append("    incident: %s" % p["incident"])
        out.append("    fix:      %s" % p["fix"])
        return "\n".join(out)


# ---------------------------------------------------------------------------
# THE REGISTRY. One dict per known-bad shape. `check(nf)` yields Findings.
# ---------------------------------------------------------------------------

def _reexports(nf):
    """Yield (lineno, exported-name) for every `export <imported-module>`."""
    for i, ln in enumerate(nf.code, 1):
        m = EXPORT_RE.match(ln)
        if not m:
            continue
        for spec in _split_specs(m.group(1)):
            name = spec.strip()
            # `export foo.bar` / `export foo*` are symbol forms, not a module.
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                continue
            if name in nf.imports:
                yield i, name


def check_reexport_samename(nf):
    for line, name in _reexports(nf):
        if name == nf.module:
            spec = nf.import_specs.get(name, name)
            yield Finding(
                MODULE_REEXPORT_ERROR, nf, line, nf.lines[line - 1],
                extra=("this file IS `%s` and it re-exports `%s`, so two "
                       "different files answer to the module name `%s`"
                       % (nf.module, spec, name)))


def check_reexport_other(nf):
    for line, name in _reexports(nf):
        if name != nf.module:
            yield Finding(
                MODULE_REEXPORT_WARN, nf, line, nf.lines[line - 1],
                extra=("re-exports the whole module `%s`; not the measured "
                       "fatal shape (no module-name collision), and three "
                       "files in this tree do it and build"
                       % nf.import_specs.get(name, name)))


CHECKOUT_REL_RE = re.compile(
    r"^\s*(?:import|include)\s+\"?((?:\.\./){2,}[^\s\",]+)")


def check_checkout_relative_mod_import(nf):
    """A mod that reaches OUT of the mods folder cannot be built by an install.

    Scoped to mods/ deliberately: host/ and backend/ are only ever compiled
    from inside the checkout, so `../..` there is not this bug.
    """
    rel = nf.rel.replace("\\", "/")
    parts = rel.split("/")
    # The LAST `mods` component, so the fixture path
    # tools/fixtures/nimlint/bad_modimport/mods/... is treated exactly like a
    # real mods/... path. A control that is exempted by the path it lives at
    # is not a control.
    idx = max((i for i, p in enumerate(parts) if p == "mods"), default=-1)
    if idx < 0 or len(parts) - idx < 3:
        return
    inside = parts[idx + 1:]              # <mod>/<...>/file.nim
    depth_in_mod = len(inside) - 2        # directories below the mod root
    for i, ln in enumerate(nf.nocode, 1):
        if nf.in_long[i - 1]:
            continue
        m = CHECKOUT_REL_RE.match(ln)
        if not m:
            continue
        spec = m.group(1)
        # Inside one mod, `../..` can still be mod-internal. Count how far up
        # it climbs against how deep the file sits inside its own mod.
        ups = spec.count("../")
        if ups <= depth_in_mod:
            continue
        yield Finding(CHECKOUT_RELATIVE_IMPORT, nf, i, nf.lines[i - 1],
                      extra=("climbs %d levels from a file %d deep inside its "
                             "mod, i.e. out of the mods folder entirely"
                             % (ups, depth_in_mod)))


MODULE_REEXPORT_ERROR = {
    "id": "module-reexport-samename",
    "severity": SEV_ERROR,
    "title": "whole-module re-export under the re-exporting file's OWN name",
    "why": ("`export <module>` re-exports a whole module rather than named "
            "symbols. When the re-exported module has the same name as the "
            "file doing it, two files answer to one module name and nimony's "
            "hexer dies at the nifmake graph stage with `getOrQuit: missing "
            "key`, naming no file, on EVERY target in the tree."),
    "incident": ("2026-09-01 19:49-22:26: every host and backend build died "
                 "this way for 2.5h. host/common/jsonpath.nim held `import "
                 "aowlspt/jsonpath` + `export jsonpath` after a module move. "
                 "An include-bisect first blamed uihooks.nim, wrongly."),
    "fix": ("re-export named symbols, or `include \"<relative>/<mod>.nim\"` "
            "the moved file (what cb9a816 did), or rename this shim so it "
            "does not collide with the module it forwards."),
    "check": check_reexport_samename,
}

MODULE_REEXPORT_WARN = {
    "id": "module-reexport",
    "severity": SEV_WARN,
    "title": "whole-module re-export (no name collision)",
    "why": ("the recorded rule is `never export a whole module`, but MEASURED "
            "2026-09-02 three such lines exist in code that builds "
            "(aowl/src/aowlspt.nim, mods/maps/sp/hud.nim, "
            "mods/morebots/bots/dbpath.nim), so this shape alone is not "
            "proven fatal. Reported so it is the first thing tried if a "
            "tree-wide `getOrQuit: missing key` appears again."),
    "incident": ("same 2.5h incident as module-reexport-samename; the "
                 "discriminator between the two is INFERRED, not measured."),
    "fix": ("prefer re-exporting named symbols. If this line is ever measured "
            "to kill the hexer, promote this entry to severity error and "
            "record the measurement in docs/AOWL_FACTS.md."),
    "check": check_reexport_other,
}

CHECKOUT_RELATIVE_IMPORT = {
    "id": "checkout-relative-mod-import",
    "severity": SEV_ERROR,
    "title": "a mod importing out of the mods folder",
    "why": ("mods are SOURCE compiled in the user's install, where the repo "
            "checkout does not exist. A `../../../host/...` import resolves "
            "here and nowhere else, so the mod is one nobody else can have."),
    "incident": ("2026-09-01: a fresh install with only the bundled toolchain "
                 "built 13/16 mods; mgr/cfgscan.nim(47,1) `file not found: "
                 "<install>\\host\\common\\jsonpath.nim`. Fixed by 531498a, "
                 "which moved jsonpath into aowl/src/aowlspt/ (on every mod's "
                 "-p: path) -- and whose re-export shim then caused the "
                 "incident above."),
    "fix": ("import through `aowlspt/...`, the library already on every mod's "
            "command line."),
    "check": check_checkout_relative_mod_import,
}

PATTERNS = [MODULE_REEXPORT_ERROR, MODULE_REEXPORT_WARN,
            CHECKOUT_RELATIVE_IMPORT]


# ---------------------------------------------------------------------------
# walking
# ---------------------------------------------------------------------------

class ScanResult(object):
    def __init__(self):
        self.findings = []
        self.files = 0
        self.unreadable = []     # (rel, reason) -> INCONCLUSIVE
        self.missing_roots = []

    @property
    def errors(self):
        return [f for f in self.findings if f.severity == SEV_ERROR]

    @property
    def warnings(self):
        return [f for f in self.findings if f.severity == SEV_WARN]

    @property
    def could_not_scan(self):
        return bool(self.unreadable or self.missing_roots)


def iter_nim_files(root, repo, skip_fixtures=True):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if skip_fixtures:
            rel = os.path.relpath(dirpath, repo).replace("\\", "/")
            if rel.replace("/", os.sep).startswith(FIXTURES):
                dirnames[:] = []
                continue
        for fn in sorted(filenames):
            if fn.endswith(".nim"):
                yield os.path.join(dirpath, fn)


def scan(paths, repo=REPO, patterns=None, skip_fixtures=True):
    patterns = patterns or PATTERNS
    res = ScanResult()
    for p in paths:
        full = p if os.path.isabs(p) else os.path.join(repo, p)
        if not os.path.exists(full):
            res.missing_roots.append(p)
            continue
        for f in iter_nim_files(full, repo, skip_fixtures):
            rel = os.path.relpath(f, repo).replace("\\", "/")
            try:
                with open(f, "r", encoding="utf-8", errors="strict") as fh:
                    lines = fh.read().splitlines()
            except (OSError, UnicodeDecodeError) as e:
                res.unreadable.append((rel, "%s: %s" % (type(e).__name__, e)))
                continue
            res.files += 1
            nf = NimFile(f, rel, lines)
            for pat in patterns:
                for finding in pat["check"](nf):
                    res.findings.append(finding)
    return res


def verdict(res, strict=False):
    """0 clean / 1 findings / 3 could not scan.

    A FINDING OUTRANKS AN INCOMPLETE SCAN. "I could not read three of the five
    roots, and also here is a fatal shape in the two I did read" is a definite
    answer, and returning 3 for it would let a real finding be waved through as
    inconclusive. The reverse -- clean, but part of the tree unread -- is not
    an answer and is 3.
    """
    if res.errors or (strict and res.warnings):
        return 1
    if res.could_not_scan:
        return 3
    return 0


def report(res, strict=False, out=sys.stdout):
    # Warnings print even though they do not fail: the caller decides, and a
    # finding you were never shown cannot be judged.
    for f in res.findings:
        out.write(f.human() + "\n\n")
    if res.missing_roots:
        out.write("COULD NOT SCAN: these paths do not exist: %s\n"
                  % ", ".join(res.missing_roots))
    for rel, why in res.unreadable:
        out.write("COULD NOT SCAN: %s (%s)\n" % (rel, why))
    rc = verdict(res, strict)
    if rc == 3:
        out.write("nimlint: INCONCLUSIVE -- %d file(s) scanned, but something "
                  "could not be read. This is NOT a pass.\n" % res.files)
    elif rc == 1:
        out.write("nimlint: %d error(s), %d warning(s) in %d file(s)\n"
                  % (len(res.errors), len(res.warnings), res.files))
    else:
        out.write("nimlint: clean -- %d file(s), 0 errors, %d warning(s)%s\n"
                  % (res.files, len(res.warnings),
                     " (warnings do not fail without --strict)"
                     if res.warnings else ""))
    return rc


# ---------------------------------------------------------------------------
# controls
# ---------------------------------------------------------------------------

POSITIVE = "bad_reexport/jsonpath.nim"
POSITIVE_MOD = "bad_modimport/mods/badmod/sub/cfgscan.nim"
NEGATIVE = "good/"


def fixture_dir(repo=REPO):
    return os.path.join(repo, FIXTURES)


def selftest(repo=REPO, out=sys.stdout):
    """The positive control MUST fire and the negative MUST NOT.

    Both, every time. A linter is exactly the kind of tool that silently stops
    matching -- one regex edit and it returns clean forever, which reads as
    good news.
    """
    fx = fixture_dir(repo)
    ok = True
    if not os.path.isdir(fx):
        out.write("COULD NOT SCAN: fixtures missing at %s\n" % fx)
        return 3

    pos = scan([os.path.join(fx, os.path.dirname(POSITIVE))], repo=repo,
               skip_fixtures=False)
    hits = [f for f in pos.findings
            if f.pattern["id"] == "module-reexport-samename"]
    out.write("positive control (%s): %d file(s), %d error finding(s)\n"
              % (POSITIVE, pos.files, len(hits)))
    if len(hits) == 1 and verdict(pos) == 1:
        out.write("  PASS  the measured fatal shape FIRES\n")
        out.write("\n".join("  " + l for l in hits[0].human().splitlines()))
        out.write("\n")
    else:
        ok = False
        out.write("  FAIL  expected exactly 1 error finding and exit 1, got "
                  "%d findings / exit %d -- the linter cannot fail, so a "
                  "clean run of it proves nothing\n"
                  % (len(hits), verdict(pos)))

    pos2 = scan([os.path.join(fx, os.path.dirname(POSITIVE_MOD))], repo=repo,
                skip_fixtures=False)
    hits2 = [f for f in pos2.findings
             if f.pattern["id"] == "checkout-relative-mod-import"]
    out.write("positive control (%s): %d error finding(s)\n"
              % (POSITIVE_MOD, len(hits2)))
    if len(hits2) == 1:
        out.write("  PASS  the mod-import shape FIRES\n")
    else:
        ok = False
        out.write("  FAIL  expected exactly 1, got %d\n" % len(hits2))

    neg = scan([os.path.join(fx, NEGATIVE)], repo=repo, skip_fixtures=False)
    out.write("negative control (%s): %d file(s), %d finding(s) of any "
              "severity\n" % (NEGATIVE, neg.files, len(neg.findings)))
    if neg.files >= 3 and not neg.findings and verdict(neg) == 0:
        out.write("  PASS  the shapes that are FINE stay quiet "
                  "(symbol re-export, export inside a comment, export inside "
                  "a string, a mod-internal ../ import)\n")
    else:
        ok = False
        out.write("  FAIL  %d file(s) / %d finding(s) / exit %d -- %s\n"
                  % (neg.files, len(neg.findings), verdict(neg),
                     "; ".join("%s:%d %s" % (f.rel, f.line, f.pattern["id"])
                               for f in neg.findings) or "too few files"))

    out.write("\nselftest: %s\n" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def list_patterns(out=sys.stdout):
    for p in PATTERNS:
        out.write("%s  [%s]\n    %s\n    why:      %s\n    incident: %s\n"
                  "    fix:      %s\n\n"
                  % (p["id"], p["severity"], p["title"], p["why"],
                     p["incident"], p["fix"]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="refuse the nim shapes that kill nimony without naming a "
                    "file",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("paths", nargs="*",
                    help="files or directories (default: %s)"
                         % ", ".join(DEFAULT_ROOTS))
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--strict", action="store_true",
                    help="warnings fail too (exit 1)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--list", action="store_true",
                    help="print the pattern registry and exit")
    ap.add_argument("--selftest", action="store_true",
                    help="run the positive and negative controls")
    a = ap.parse_args(argv)

    if a.list:
        return list_patterns()
    if a.selftest:
        return selftest(a.repo)

    paths = a.paths or list(DEFAULT_ROOTS)
    # An explicit path is honoured even under tools/fixtures/nimlint.
    res = scan(paths, repo=a.repo, skip_fixtures=not a.paths)
    if a.json:
        print(json.dumps({"files": res.files,
                          "errors": len(res.errors),
                          "warnings": len(res.warnings),
                          "could_not_scan": res.could_not_scan,
                          "missing_roots": res.missing_roots,
                          "unreadable": res.unreadable,
                          "findings": [f.as_dict() for f in res.findings]},
                         indent=1))
        return verdict(res, a.strict)
    return report(res, a.strict)


if __name__ == "__main__":
    sys.exit(main())
