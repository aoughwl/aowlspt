#!/usr/bin/env python3
"""abilint.py -- find memory-ownership hazards on the host/mod DLL boundary.

WHY THIS EXISTS, MEASURED 2026-09-03 09:21:51 (WER dump
EscapeFromTarkov.exe.636.dmp, cdb): the host's mimalloc hit "corrupted
thread-free list." (vendor/mimalloc/src/page.c:205) inside mi_malloc, reached
from sain!resolve_0 -> the host's `aowlspt_nim_resolve`.

The cause was NOT a cross-module free. It was `var gLastError = ""` in
host/Aowlspt.Host.Il2Cpp/aowlhost.nim: a plain module-level Nim string assigned
from ~40 sites inside `exportc` ABI entry points that run on the mod ops thread,
AND from `installPatch` on the Unity main thread, with no lock. Under ARC an
assignment to a global string frees the previous buffer, so the free happened on
whichever thread assigned -- a cross-thread free, and under a race a double free
of the same buffer. backend/aowlbackend.nim had declared its identically-named
`gLastError` as `{.threadvar.}` and was fine. The divergence was the defect.

TWO CHECKS. Check 2 is the one that would have caught the crash above.

  1. OWNED-MEMORY-IN-SIGNATURE -- an `exportc` proc whose params or return type
     use Nim `string` / `seq`. Those are ARC-managed and their allocator is the
     DEFINING module's; passing one across a DLL boundary means one module
     allocates and the other frees. The ABI's rule is "borrowed in, owned out":
     raw pointer + length in, host-allocated AowlBuffer out.

  2. SHARED-MUTABLE-GLOBAL -- a module-level `var` of an ARC-managed type
     (string/seq) that is ASSIGNED inside the body of an `exportc` proc, and is
     not `{.threadvar.}`. Every such assignment frees the old buffer on the
     calling thread. If more than one thread can reach any of the exports, that
     is a cross-thread free and a double-free race.

Three outcomes, never two: CLEAN (0) / HAZARD (1) / INCONCLUSIVE (3). A file
that does not parse, or a directory with no .nim in it, is INCONCLUSIVE -- "I
could not look" is not a pass.

    python tools/abilint.py                       # lint the host + abi tree
    python tools/abilint.py host/ backend/        # explicit paths
    python tools/abilint.py --selftest            # the falsifier
"""

import argparse
import os
import re
import sys

DEFAULT_PATHS = ["host", "backend", "aowl/src"]

# `proc name(...)` possibly spanning lines, ending in a pragma block.
PROC_RE = re.compile(r"^\s*(?:proc|func)\s+([A-Za-z_][\w]*)\s*\*?\s*\(", re.M)
# A module-level var: column 0 `var`, one declaration on the line.
GLOBAL_VAR_RE = re.compile(
    r"^var\s+([A-Za-z_]\w*)\s*(\{\.[^}]*\.\})?\s*(?::\s*([^=\n]+?))?\s*(?:=\s*(.+))?$"
)
ARC_TYPE_RE = re.compile(r"\b(?:string|seq\s*\[|cstringArray)\b")


class Finding:
    def __init__(self, kind, path, line, name, detail):
        self.kind, self.path, self.line = kind, path, line
        self.name, self.detail = name, detail

    def __str__(self):
        return f"{self.path}:{self.line}: {self.kind}: {self.name} -- {self.detail}"


def strip_comments(text):
    """Blank out `##`/`#` comment tails and long string literals, preserving
    line structure so line numbers stay honest. Without this, the huge measured
    comment blocks in aowlhost.nim (which quote `gLastError = ...`) are read as
    code and every one becomes a false assignment site."""
    out = []
    in_long = False
    for line in text.split("\n"):
        if in_long:
            if '"""' in line:
                in_long = False
                line = line.split('"""', 1)[1]
            else:
                out.append("")
                continue
        if '"""' in line:
            head, _, rest = line.partition('"""')
            if '"""' in rest:
                line = head + rest.split('"""', 1)[1]
            else:
                in_long = True
                line = head
        # Comment tail, but not a `#` inside a string literal. Cheap and correct
        # enough: count unescaped quotes before the hash.
        idx = -1
        q = 0
        for i, ch in enumerate(line):
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                q ^= 1
            elif ch == "#" and not q:
                idx = i
                break
        if idx >= 0:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)


def proc_spans(code):
    """(name, start_line, end_line, header_text, is_exportc) per top-level proc.

    A proc's body is everything up to the next column-0 `proc`/`var`/`type`/
    `template`, which is how Nim's indentation actually delimits it here."""
    lines = code.split("\n")
    starts = []
    for i, ln in enumerate(lines):
        m = re.match(r"^(?:proc|func)\s+([A-Za-z_]\w*)", ln)
        if m:
            starts.append((i, m.group(1)))
    spans = []
    for idx, (i, name) in enumerate(starts):
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if re.match(r"^(?:proc|func|var|let|const|type|template|macro)\b", lines[j]):
                end = j
                break
        # The header runs until the line holding the closing pragma / `=`.
        header = []
        for j in range(i, min(end, i + 12)):
            header.append(lines[j])
            if re.search(r"=\s*$", lines[j]) or ".}" in lines[j]:
                break
        htext = "\n".join(header)
        spans.append((name, i + 1, end, htext, "exportc" in htext))
    return spans


def lint_file(path):
    findings = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        raise RuntimeError(f"{path}: {exc}")

    code = strip_comments(raw)
    spans = proc_spans(code)

    # --- Check 1: owned memory in an exported signature -------------------
    for name, start, _end, header, is_exp in spans:
        if not is_exp:
            continue
        sig = header.split("(", 1)[1] if "(" in header else ""
        if ARC_TYPE_RE.search(sig):
            findings.append(
                Finding(
                    "HAZARD-OWNED-SIGNATURE", path, start, name,
                    "exportc signature uses an ARC-managed string/seq; ownership "
                    "crosses the DLL boundary. Pass raw pointer+length in, and "
                    "return a host-allocated AowlBuffer out.",
                )
            )

    # --- Check 2: shared mutable ARC global written from an export --------
    globals_ = {}
    for i, ln in enumerate(code.split("\n")):
        m = GLOBAL_VAR_RE.match(ln)
        if not m:
            continue
        gname, pragma, gtype, ginit = m.groups()
        decl = (gtype or "") + " " + (ginit or "")
        if not ARC_TYPE_RE.search(decl) and not (ginit or "").strip().startswith('"'):
            continue
        is_seq = bool(re.search(r"\bseq\s*\[", decl)) or "@[" in (ginit or "")
        globals_[gname] = (i + 1, pragma or "", is_seq)

    raw_lines = raw.split("\n")
    lines = code.split("\n")
    for gname, (gline, pragma, is_seq) in globals_.items():
        if "threadvar" in pragma:
            continue
        # An explicit, reviewed waiver. State the reason in the source, next to
        # the declaration, so the next reader sees the argument and not just a
        # suppressed warning:
        #   var gRoutes: seq[Route] = @[]  ## abilint: shared-by-design -- ...
        window = "\n".join(raw_lines[max(0, gline - 3):gline + 1])
        if "abilint: shared-by-design" in window:
            continue

        assign = re.compile(r"^\s+" + re.escape(gname) + r"\s*(?:=|\.add\b|&=)")
        writers = []
        for name, start, end, _h, is_exp in spans:
            if not is_exp:
                continue
            if any(assign.match(lines[j]) for j in range(start, min(end, len(lines)))):
                writers.append(name)
        if not writers:
            continue
        shown = ", ".join(sorted(set(writers))[:6])
        more = "" if len(set(writers)) <= 6 else f" (+{len(set(writers)) - 6} more)"

        # THE SPLIT, and it is the difference between a useful lint and a
        # confidently wrong one. A `seq` global here is nearly always a REGISTRY
        # -- routes, subscriptions, timers, handles -- which is shared across
        # threads ON PURPOSE. Making one `{.threadvar.}` would be a correctness
        # disaster: a route registered on the ops thread would be invisible to
        # the main thread. Those need a LOCK. A plain `string` global is the
        # scratch/diagnostic shape that actually crashed the client, and for
        # that a threadvar is both the fix and an improvement in meaning.
        if is_seq:
            findings.append(
                Finding(
                    "REVIEW-SHARED-REGISTRY", path, gline, gname,
                    f"shared `seq` global mutated inside exportc proc(s) "
                    f"[{shown}{more}]. If more than one thread can reach those "
                    f"exports this needs a LOCK -- NOT a threadvar, which would "
                    f"hide the registry from every other thread. If it is "
                    f"single-threaded or already locked, say so with a "
                    f"`## abilint: shared-by-design -- <reason>` comment on the "
                    f"declaration.",
                )
            )
        else:
            findings.append(
                Finding(
                    "HAZARD-SHARED-ARC-GLOBAL", path, gline, gname,
                    f"module-level ARC string global assigned inside exportc "
                    f"proc(s) [{shown}{more}] and NOT {{.threadvar.}}. Each "
                    f"assignment frees the previous buffer on the CALLING "
                    f"thread; two threads racing free the same buffer twice. "
                    f"This is the exact shape of the 2026-09-03 'corrupted "
                    f"thread-free list' crash (gLastError). Prefer "
                    f"{{.threadvar.}}; if the value must genuinely be shared, "
                    f"lock it and add `## abilint: shared-by-design -- <reason>`.",
                )
            )
    return findings


def collect(paths):
    files = []
    for p in paths:
        if os.path.isfile(p) and p.endswith(".nim"):
            files.append(p)
            continue
        for root, dirs, names in os.walk(p):
            dirs[:] = [d for d in dirs
                       if d not in (".git", "nimcache", "worktrees", ".claude")]
            files.extend(os.path.join(root, n) for n in names if n.endswith(".nim"))
    return sorted(files)


# --------------------------------------------------------------------------
# THE FALSIFIER. A check you cannot make fail is not a check. These assert the
# lint fires on the exact shape that crashed the client, and stays silent on the
# fixed shape -- so a future edit that guts the detection is caught here.
# --------------------------------------------------------------------------
BAD = '''
var gLastError = ""

proc hostResolve(ctx: pointer; name: pointer): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  gLastError = "no such type"
  result = 0
'''

GOOD = '''
var gLastError {.threadvar.}: string

proc hostResolve(ctx: pointer; name: pointer): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  gLastError = "no such type"
  result = 0
'''

BAD_SIG = '''
proc hostThing(ctx: pointer; s: string): int32 {.
    exportc: "aowlspt_nim_thing", cdecl.} =
  result = 0
'''

# The negative control that matters most: the real file quotes `gLastError = `
# inside its measured-evidence comment block dozens of times. If comment
# stripping regresses, this shape starts reporting a hazard that is not there.
COMMENTED = '''
var gLastError {.threadvar.}: string
## As a plain global it was assigned by `gLastError = "x"` from every export.

proc hostResolve(ctx: pointer): int32 {.exportc: "r", cdecl.} =
  result = 0
'''

# A non-exported proc writing the global is NOT this hazard: nothing outside the
# DLL can reach it, so the boundary is not crossed.
INTERNAL_ONLY = '''
var gCache = ""

proc helper(x: int) =
  gCache = "internal"
'''


def selftest():
    import tempfile
    cases = [
        ("BAD (the crash shape)", BAD, "HAZARD-SHARED-ARC-GLOBAL", True),
        ("GOOD (threadvar fix)", GOOD, "HAZARD-SHARED-ARC-GLOBAL", False),
        ("BAD signature", BAD_SIG, "HAZARD-OWNED-SIGNATURE", True),
        ("comment-only mention", COMMENTED, "HAZARD-SHARED-ARC-GLOBAL", False),
        ("internal writer only", INTERNAL_ONLY, "HAZARD-SHARED-ARC-GLOBAL", False),
    ]
    failures = 0
    tmp = tempfile.mkdtemp(prefix="abilint")
    for label, src, kind, want in cases:
        p = os.path.join(tmp, "t.nim")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(src)
        got = any(f.kind == kind for f in lint_file(p))
        ok = got == want
        failures += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}: "
              f"expected {kind}={want}, got {got}")
    print(f"\nselftest: {len(cases) - failures}/{len(cases)} passed")
    return 0 if failures == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=None)
    ap.add_argument("--selftest", action="store_true",
                    help="run the falsifier and exit")
    args = ap.parse_args()

    if args.selftest:
        print("abilint falsifier -- each case must come out as stated:")
        return selftest()

    paths = args.paths or [p for p in DEFAULT_PATHS if os.path.exists(p)]
    if not paths:
        print("INCONCLUSIVE: none of the default paths exist here "
              f"({', '.join(DEFAULT_PATHS)}); run from the repo root or name paths.")
        return 3

    files = collect(paths)
    if not files:
        print(f"INCONCLUSIVE: no .nim files under {', '.join(paths)} -- "
              "nothing was examined, which is not a pass.")
        return 3

    findings, errors = [], []
    for f in files:
        try:
            findings.extend(lint_file(f))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{f}: {exc}")

    hazards = [f for f in findings if f.kind.startswith("HAZARD")]
    reviews = [f for f in findings if f.kind.startswith("REVIEW")]

    for f in hazards:
        print(f)
    if reviews:
        print("\n-- REVIEW (not a failure; needs a human decision) --")
        for f in reviews:
            print(f)
    if errors:
        print("\nCould not examine:")
        for e in errors:
            print("  " + e)

    print(f"\nscanned {len(files)} file(s): {len(hazards)} hazard(s), "
          f"{len(reviews)} review(s), {len(errors)} unreadable")
    # Only HAZARD fails the exit code. REVIEW is a question, and a question that
    # blocks a build gets waived reflexively, which is how a lint stops meaning
    # anything.
    if errors and not hazards:
        return 3
    return 1 if hazards else 0


if __name__ == "__main__":
    sys.exit(main())
