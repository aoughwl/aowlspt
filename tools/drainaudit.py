#!/usr/bin/env python3
"""drainaudit.py -- what a host detour target may be: not a stack-argument
POSTFIX (D1/D2), not a function already detoured (D5), not a SHARED RVA (D4).

## The crash this makes impossible

MEASURED 2026-09-02. `EFT.UI.MenuScreen::Show` @0x15387A0 takes five declared
arguments, so its compiled IL2CPP call uses SEVEN register slots: `this`, the
five arguments, and the trailing `MethodInfo*`. Win64 passes four in registers
and the rest on the stack.

The host's POSTFIX thunk (`abi/aowlspt_detour.h`) cannot tail-jump into the
original -- it has to regain control afterwards -- so it does `sub rsp,0x98`
and then `call *tramp`. The original therefore runs with a DIFFERENT rsp and
reads its stack arguments out of the THUNK'S OWN FRAME:

    0x1538a4f  mov rax,[rsp+0xc0]      ; = [entry_rsp+0x28], argument 5
    0x1538a57  mov [r14+0x18],rax
    0x1539126  mov rdx,[r14+0x18]
    0x153912f  call SeasonWidgetData::From

`[entry_rsp+0x28]` lands on thunk-frame +0x20, the slot the thunk parks RAX in
and has not written yet. Three consecutive boots died in `SeasonWidgetData::From`
with `Rcx=1`: a `Profile` that was the integer 1.

`invoke.nim`'s `postfixRefusal` (`PostfixMaxSlots = 4`) has encoded this rule
for a MOD's patch since it was written. It was applied only in `hostPatch`;
`attachDrain` trusted each caller's `postfix` flag. That gate now exists in
`attachDrain` too, which is the runtime half. THIS is the offline half: it
refuses the BUILD, so the bad shape never reaches a client at all.

## Three states, never two

  PASS          every postfix site declares a slot count, every declared count
                agrees with the metadata, none exceeds four, no RVA is a target
                twice (D5), and every target's sharedness is UNIQUE (D4).
  FAIL   (1)    at least one is not. Named, with the number.
  INCONCLUSIVE  the metadata inputs are absent, so the declared counts could
         (3)    not be CHECKED and sharedness was not checked AT ALL -- only
                internal consistency and D5 were. "I could not look" is not a
                pass, and this never exits 0 on it.

## What it reads

  * C target tables in `abi/*.h` and in `{.emit.}` blocks inside `host/**/*.nim`
    -- any `typedef struct ... { ... int32_t slots; } X;` plus every
    `static const X name[] = { ... }` array of it. Each row's name literal, RVA
    and declared slot count are extracted positionally.
  * every `attachDrain(...)` call site in `host/` and `mods/`, with its
    `postfix` and `slots` arguments.
  * the metadata, for the ground truth: `Il2CppMethodDefinition.parameterCount`
    @34 and `flags`@28 & STATIC, via `tools/il2cpp_resolve.py`. slots =
    parameterCount + 1 (the MethodInfo*) + (1 unless static).

## Why the derivation is not trusted to a name

A row is matched to the metadata by its RVA, not by its name string: 28.3% of
by-name lookups on this build land on a SHARED RVA, and some table names carry
a disambiguating suffix (`::Show(5-arg)`) that is not a metadata name at all.
The RVA is what the host actually detours, so it is what is audited. Where the
RVA resolves to several folded methods, the audit takes the MAXIMUM slot count
of them -- being wrong in the safe direction is the only acceptable direction
here.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PASS, FAIL, INCONCLUSIVE = 0, 1, 3

POSTFIX_MAX_SLOTS = 4
    # Mirrors `PostfixMaxSlots` in host/Aowlspt.Host.Il2Cpp/invoke.nim. Four,
    # because that is what Win64 passes in registers.

import gamepaths as _gp  # noqa: E402  (the binary the host runs against)
GAMEASM_DEFAULT = _gp.gameasm()
METADEC_DEFAULT = os.path.join(REPO, ".cache", "global-metadata.dec.dat")

STATIC_FLAG = 0x0010    # MethodAttributes.Static, in Il2CppMethodDefinition.flags@28


# ---------------------------------------------------------------------------
# findings

class Finding:
    def __init__(self, where, what, detail):
        self.where = where
        self.what = what
        self.detail = detail

    def human(self):
        return "  %-9s %s\n      %s" % (self.what, self.where, self.detail)


# ---------------------------------------------------------------------------
# the C tables

STRUCT_RE = re.compile(
    r"typedef\s+struct\s*(\w*)\s*\{(.*?)\}\s*(\w+)\s*;", re.S)
    # The tag is OPTIONAL. `aowl_uih_sites` -- the one table that already had a
    # `slots` column before this tool existed -- is an ANONYMOUS
    # `typedef struct { ... } AowlUihSite;`, and requiring a tag silently
    # dropped all nine of its rows from the audit while the summary still said
    # PASS. A gate that skips the table it was written for is worse than no
    # gate; the accessor cross-check below now makes that specific hole
    # impossible to reopen quietly.


def structs_with_slots(text):
    """{struct_name: index_of_slots_field_among_the_row's_scalar_tail}.

    The value is not a byte offset; it is 'slots is the LAST scalar in a row',
    which is how the rows are actually written and the only thing a text parse
    can honestly claim. A struct whose `slots` is not last is reported rather
    than guessed at -- a positional parse that silently reads the wrong column
    is precisely the confidently-wrong answer this file exists to prevent.
    """
    out = {}
    for m in STRUCT_RE.finditer(text):
        body, name = m.group(2), m.group(3)
        fields = [f.strip() for f in body.split(";") if f.strip()]
        fields = [f for f in fields
                  if not f.lstrip().startswith("/*") and " " in f]
        if not fields:
            continue
        # A SCALAR `int32_t slots`, not merely a member whose name contains
        # the word. Two earlier iterations of this predicate were wrong in the
        # confidently-wrong direction and each FAILED an innocent header:
        # matching `slots` anywhere in the field text caught the comments, and
        # matching the field NAME alone caught `AowlProfSlot slots[N]` in
        # aowlspt_profile.h -- an ARRAY of structs, which is not a column at
        # all. A gate that cries wolf is routed around, so the predicate is
        # narrow on purpose: an audited table declares `int32_t slots;` last.
        def is_col(f):
            return re.match(r"^int32_t\s+slots$", " ".join(f.split()))
        if any(is_col(f) for f in fields):
            out[name] = bool(is_col(fields[-1]))
    return out


ARRAY_RE_T = r"static\s+const\s+%s\s+(\w+)\s*\[\s*\]\s*=\s*\{"


def strip_comments(text):
    """Block and line comments out, newlines preserved so line numbers hold."""
    def repl(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"/\*.*?\*/", repl, text, flags=re.S)
    text = re.sub(r"//[^\n]*", repl, text)
    return text


def parse_rows(text, open_brace):
    """Rows of one initialiser. `open_brace` is the index of the array's `{`.

    Returns [(row_text, line_no)]. Brace-balanced, so the nested
    `{ 0x48, ... }` signature array does not end a row, and scanning STOPS at
    the array's own closing brace -- an earlier version kept going and read the
    function bodies after the table as further "rows", which is exactly the
    confidently-wrong answer this tool exists to prevent.
    """
    rows = []
    i, n = open_brace + 1, len(text)
    depth = 0
    row_start = None
    while i < n:
        c = text[i]
        if c == "{":
            if depth == 0:
                row_start = i + 1
            depth += 1
        elif c == "}":
            if depth == 0:
                break                       # the array's own closing brace
            depth -= 1
            if depth == 0:
                rows.append((text[row_start:i],
                             text.count(chr(10), 0, row_start) + 1))
        i += 1
    return rows


NIM_COMMENT = re.compile(
    r'(""".*?"""|"(?:[^"\\\n]|\\.)*")'       # keep string literals verbatim
    r'|#\[.*?\]#'                            # block comment
    r'|##?[^\n]*',                           # line / doc comment
    re.S)


def strip_nim_comments(text):
    """Nim comments out; string literals and the line count preserved.

    Load-bearing, not tidiness. `attachDrain` call sites in this repo carry doc
    comments containing unbalanced parentheses and apostrophes, and a paren
    matcher that reads them runs clean past the end of the call and reports the
    next hundred lines as an argument -- which this tool did, on its first run,
    for eleven sites at once.
    """
    def repl(m):
        if m.group(1):
            return m.group(1)
        return re.sub(r"[^\n]", " ", m.group(0))
    return NIM_COMMENT.sub(repl, text)


def table_rows(path, text):
    """[(table, index, name, rva, slots, line)] for every table with a `slots`
    column, in one file."""
    clean = strip_comments(text)
    kinds = structs_with_slots(clean)
    out, bad = [], []
    for sname, slots_is_last in kinds.items():
        if not slots_is_last:
            bad.append(Finding(
                "%s: struct %s" % (os.path.relpath(path, REPO), sname),
                "FAIL",
                "declares a `slots` field that is NOT the last member. This "
                "audit reads it positionally, as the last scalar of each row, "
                "so it cannot check this table -- and a positional parse that "
                "guessed would be worse than none. Move `slots` last."))
            continue
        for am in re.finditer(ARRAY_RE_T % sname, clean):
            rows = parse_rows(clean, am.end() - 1)
            for idx, (row, line) in enumerate(rows):
                nm = re.search(r'"((?:[^"\\]|\\.)*)"', row)
                rv = re.search(r"0x([0-9A-Fa-f]+)u", row)
                tail = re.findall(r"(-?\d+)\s*,?\s*$", row.strip())
                if not (nm and rv and tail):
                    bad.append(Finding(
                        "%s:%d %s[%d]" % (os.path.relpath(path, REPO), line,
                                          am.group(1), idx),
                        "FAIL",
                        "row does not parse: needs a name literal, an "
                        "`0x...u` RVA and a trailing integer `slots`. Got: "
                        + " ".join(row.split())[:120]))
                    continue
                out.append((am.group(1), idx, nm.group(1), int(rv.group(1), 16),
                            int(tail[-1]), path, line))
    return out, bad


def emit_blocks(text):
    """The C inside Nim `{.emit: \"\"\"...\"\"\".}` blocks, newline-preserving."""
    out = []
    for m in re.finditer(r'\{\.\s*emit\s*:\s*"""(.*?)"""\s*\.\}', text, re.S):
        pad = "\n" * text.count("\n", 0, m.start(1))
        out.append(pad + m.group(1))
    return out


# ---------------------------------------------------------------------------
# the Nim call sites

def split_args(s):
    """Top-level comma split, respecting (), [] and string literals."""
    args, depth, buf, q = [], 0, [], None
    i = 0
    while i < len(s):
        c = s[i]
        if q:
            buf.append(c)
            if c == "\\":
                if i + 1 < len(s):
                    buf.append(s[i + 1])
                    i += 2
                    continue
            elif c == q:
                q = None
            i += 1
            continue
        if c == '"':
            # ONLY the double quote. Nim spells a typed literal `8'i32` and a
            # char literal `'x'`, so treating the apostrophe as a string
            # delimiter desynchronises the scanner for the rest of the file --
            # MEASURED on this repo: it made five call sites report a hundred
            # lines of unrelated source as their `slots` argument.
            q = c
            buf.append(c)
        elif c in "([":
            depth += 1
            buf.append(c)
        elif c in ")]":
            depth -= 1
            buf.append(c)
        elif c == "," and depth == 0:
            args.append("".join(buf).strip())
            buf = []
        else:
            buf.append(c)
        i += 1
    if "".join(buf).strip():
        args.append("".join(buf).strip())
    return args


def find_calls(text, fname="attachDrain"):
    """[(args, line)] for each `fname(...)`, paren-balanced across lines."""
    out = []
    for m in re.finditer(r"\b%s\(" % re.escape(fname), text):
        i, depth, q = m.end() - 1, 0, None
        while i < len(text):
            c = text[i]
            if q:
                if c == "\\":
                    i += 2
                    continue
                if c == q:
                    q = None
            elif c == '"':
                q = c            # only `"` -- see split_args
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        else:
            continue
        out.append((text[m.end():i], text.count("\n", 0, m.start()) + 1))
    return out


PARAMS = ["spec", "fn", "meth", "perFrame", "verbose", "kind", "postfix",
          "slots"]


def bind_args(args):
    """Positional + named -> {param: expr}. Unknown named args are ignored;
    they cannot exist without the proc signature changing, and if it does this
    audit's own parameter list is what has to change with it."""
    out, pos = {}, 0
    for a in args:
        m = re.match(r"^(\w+)\s*=\s*(.*)$", a, re.S)
        if m and m.group(1) in PARAMS:
            out[m.group(1)] = m.group(2).strip()
        else:
            if pos < len(PARAMS):
                out[PARAMS[pos]] = a
            pos += 1
    return out


INT_LIT = re.compile(r"^(-?\d+)(?:'i32|'i64|'u32)?$")


def audit_sites(root, tables_by_accessor):
    """Findings for every attachDrain call site under `root`."""
    findings, sites = [], []
    for base in ("host", "mods"):
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames
                           if x not in ("nimcache", "bin", ".git")]
            for fn in filenames:
                if not fn.endswith(".nim"):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    text = open(p, encoding="utf-8", errors="replace").read()
                except OSError as e:
                    findings.append(Finding(p, "FAIL", "unreadable: %s" % e))
                    continue
                for args, line in find_calls(strip_nim_comments(text)):
                    a = split_args(args)
                    if len(a) < 6:
                        continue            # a definition, not a call
                    b = bind_args(a)
                    post = b.get("postfix", "false").strip()
                    if post == "false":
                        continue
                    where = "%s:%d %s" % (os.path.relpath(p, root), line,
                                          b.get("spec", "?")[:60])
                    slots = b.get("slots")
                    if slots is None:
                        findings.append(Finding(
                            where, "FAIL",
                            "asks for a POSTFIX (postfix=%s) and declares NO "
                            "`slots`. attachDrain refuses that at run time, so "
                            "this site would bind NOTHING and the feature "
                            "would decline. Pass the target's register-slot "
                            "count." % post))
                        continue
                    m = INT_LIT.match(slots.strip())
                    if m:
                        n = int(m.group(1))
                        if n < 1:
                            findings.append(Finding(
                                where, "FAIL",
                                "declares slots=%d. A real method uses at "
                                "least one (the MethodInfo* alone); this "
                                "reads as UNDECLARED and is refused." % n))
                        elif n > POSTFIX_MAX_SLOTS:
                            findings.append(Finding(
                                where, "FAIL",
                                "asks for a POSTFIX on a call with %d "
                                "register slots -- %d argument(s) arrive on "
                                "the STACK, and the postfix thunk would make "
                                "the ORIGINAL read them out of its own frame. "
                                "Bind it PREFIX." % (n, n - POSTFIX_MAX_SLOTS)))
                        else:
                            sites.append((where, b.get("spec", ""), n))
                        continue
                    acc = re.match(r"^(?:int32\()?\s*(\w+)\s*\(", slots.strip())
                    known = acc and acc.group(1) in tables_by_accessor
                    if not known and not re.match(r"^int32\(\w+\)$",
                                                  slots.strip()):
                        findings.append(Finding(
                            where, "FAIL",
                            "passes `slots` as %r, which this audit cannot "
                            "trace to an audited table column or an integer "
                            "literal. A slot count that cannot be checked "
                            "offline is not a checked slot count. Either pass "
                            "a literal, or read it from a table with a "
                            "`slots` column." % slots.strip()))
    return findings, sites


# ---------------------------------------------------------------------------
# the metadata ground truth

def metadata_slots(gameasm, metadec):
    """({rva: max_slots}, resolver, why). The resolver is returned so the
    D4 sharedness pass reads the SAME opened metadata rather than paying for a
    second one -- and so a PASS can never come from a resolver that failed to
    open while the slot pass silently used a cached table.

    {rva: max_slots} spans every method with generated code.

    MAX, where an RVA is shared by folded bodies: being wrong in the safe
    direction is the only acceptable direction for a gate.
    """
    if not os.path.exists(gameasm):
        return None, None, "GameAssembly.dll not found at %s" % gameasm
    if not os.path.exists(metadec):
        return None, None, ("decrypted metadata not found at %s (make it with "
                            "tools/metablob.py)" % metadec)
    sys.path.insert(0, HERE)
    try:
        import struct
        import il2cpp_resolve as R
    except Exception as e:                                  # pragma: no cover
        return None, None, "tools/il2cpp_resolve.py unimportable: %s" % e
    try:
        r = R.Resolver(gameasm, metadec)
    except Exception as e:                                  # pragma: no cover
        return None, None, "the resolver would not open the inputs: %s" % e
    idx = {}
    for t in range(r.NTYPES):
        try:
            mp = r.MOD.get(r.image_of_type(t))
        except Exception:
            continue
        if not mp or not mp[0]:
            continue
        base, cnt = mp
        for mi in r.type_methods(t):
            rid = r.mtoken(mi) & 0xFFFFFF
            if not (1 <= rid <= cnt):
                continue
            va = r.rq(base + (rid - 1) * 8)
            if not va:
                continue
            pc = struct.unpack_from("<H", r.m, r.M_OFF + mi * r.MS + 34)[0]
            slots = pc + 1 + (0 if (r.mflags(mi) & STATIC_FLAG) else 1)
            rva = va - r.IB
            if slots > idx.get(rva, 0):
                idx[rva] = slots
    return idx, r, None


# ---------------------------------------------------------------------------

ACCESSOR_RE = re.compile(
    r"static\s+int32_t\s+(\w+)\s*\(\s*int32_t\s+\w+\s*\)\s*\{[^}]*?"
    r"\.slots\s*;", re.S)


def collect_tables(root):
    """([rows], [findings], {accessor_name: table_name})."""
    rows, findings, accessors = [], [], {}
    roots = [os.path.join(root, "abi"),
             os.path.join(root, "host")]
    for d in roots:
        if not os.path.isdir(d):
            continue
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames
                           if x not in ("nimcache", "bin", ".git")]
            for fn in filenames:
                p = os.path.join(dirpath, fn)
                if fn.endswith(".h"):
                    texts = [open(p, encoding="utf-8", errors="replace").read()]
                elif fn.endswith(".nim"):
                    whole = open(p, encoding="utf-8", errors="replace").read()
                    texts = emit_blocks(whole)
                else:
                    continue
                for text in texts:
                    got, bad = table_rows(p, text)
                    rows.extend(got)
                    findings.extend(bad)
                    for am in ACCESSOR_RE.finditer(strip_comments(text)):
                        accessors[am.group(1)] = p
    return rows, findings, accessors


def nim_accessor_names(root, c_accessors):
    """Nim `importc:` wrappers around the C slot accessors -> the C name."""
    out = {}
    for base in ("host", "mods"):
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames
                           if x not in ("nimcache", "bin", ".git")]
            for fn in filenames:
                if not fn.endswith(".nim"):
                    continue
                text = open(os.path.join(dirpath, fn),
                            encoding="utf-8", errors="replace").read()
                for m in re.finditer(
                        r"proc\s+(\w+)\s*\([^)]*\)\s*:\s*int32\s*\{\.\s*"
                        r'importc:\s*"(\w+)"', text, re.S):
                    if m.group(2) in c_accessors:
                        out[m.group(1)] = m.group(2)
    return out


def duplicate_targets(rows, root):
    """D5 -- no function is detoured twice.

    Two detours on one function do not fail loudly: the SECOND overwrites the
    first's trampoline, and the first feature simply stops firing, with no
    error anywhere. Every row in every audited table is a detour target, so two
    rows carrying the same RVA -- in one table or across two -- is that shape,
    offline, before it is built.

    Needs no metadata: it is a property of our own tables.
    """
    by = {}
    for tbl, idx, name, rva, slots, path, line in rows:
        by.setdefault(rva, []).append(
            "%s:%d %s[%d] %s" % (os.path.relpath(path, root), line, tbl, idx,
                                 name))
    out = []
    for rva, where in sorted(by.items()):
        if len(where) > 1:
            out.append(Finding(
                "RVA 0x%X" % rva, "FAIL",
                "is a detour target in %d places: %s. The second patch "
                "overwrites the first's trampoline, so one of these features "
                "silently stops firing and nothing reports it. Ride the "
                "existing detour as a drain instead of adding a second one."
                % (len(where), "; ".join(where))))
    return out


def sharedness_findings(rows, resolver, root):
    """D4 -- every detour target is UNIQUE; `unknown` refuses.

    28.3% of by-name lookups on this build land on a SHARED RVA. CALLING one is
    fine -- it is correct code for the receiver passed. DETOURING one is a write
    with unbounded blast radius: the hook fires for every method folded onto
    that address (up to 6,438 for the universal empty-body stub 0x628110).

    `unknown` -- the address is not in the methodPointers histogram at all -- is
    a REFUSAL, not "probably fine". Never re-derive this from
    shared_rva_counts() with a `.get(rva, 1)` default: that default made every
    unknown address read back as "1 owner, safe to detour".
    """
    out = []
    seen = set()
    for tbl, idx, name, rva, slots, path, line in rows:
        if rva in seen:
            continue                      # duplicate_targets already says so
        seen.add(rva)
        where = "%s:%d %s[%d] %s @0x%X" % (os.path.relpath(path, root), line,
                                           tbl, idx, name, rva)
        try:
            state, n = resolver.sharedness(rva)
        except Exception as e:             # pragma: no cover
            out.append(Finding(where, "FAIL",
                               "sharedness could not be computed (%s: %s). An "
                               "unchecked detour target is a refusal."
                               % (type(e).__name__, e)))
            continue
        if state == "shared":
            out.append(Finding(where, "FAIL",
                               "is a SHARED RVA: %d methods resolve here, so a "
                               "detour on it fires for all of them. Detouring "
                               "a shared address is a write with unbounded "
                               "blast radius. Find the unique body, or ride an "
                               "existing detour." % n))
        elif state != "unique":
            out.append(Finding(where, "FAIL",
                               "sharedness is UNKNOWN -- this RVA is not in "
                               "the methodPointers histogram at all. That is "
                               "NOT 'not shared': it is a static RVA from a "
                               "different GameAssembly.dll, a live ASLR "
                               "address, or not code. A target that cannot be "
                               "checked is refused."))
    return out


def audit(root, gameasm, metadec, quiet=False):
    w = (lambda s: None) if quiet else sys.stdout.write
    rows, findings, c_accessors = collect_tables(root)
    accessors = dict(c_accessors)
    accessors.update(nim_accessor_names(root, c_accessors))

    site_findings, sites = audit_sites(root, accessors)
    findings.extend(site_findings)

    # EVERY C SLOT ACCESSOR MUST HAVE ROWS. An accessor `return X[i].slots;`
    # proves a table with a slots column exists and is read at run time; if
    # this tool parsed no rows for it, the tool cannot see the table and the
    # PASS it would print is vacuous. That is not hypothetical: the anonymous
    # typedef in aowlspt_uihooks.h hid nine rows behind a summary that said
    # PASS. A check that cannot fail IS the bug.
    tabled = set()
    for tbl, idx, name, rva, slots, path, line in rows:
        tabled.add(os.path.abspath(path))
    for acc, path in c_accessors.items():
        if os.path.abspath(path) not in tabled:
            findings.append(Finding(
                "%s %s()" % (os.path.relpath(path, root), acc),
                "FAIL",
                "is a slot-count accessor, so a table with a `slots` column "
                "is read from this file at run time -- but this audit parsed "
                "NO rows here. Its rows are therefore unaudited and a PASS "
                "would be vacuous. Check the struct/array shape this tool "
                "expects: `typedef struct [tag] { ...; int32_t slots; } T;` "
                "and `static const T name[] = { ... };`."))

    # Internal consistency of the tables, which needs no metadata: a declared
    # count that is out of range is wrong whatever the client build is.
    for tbl, idx, name, rva, slots, path, line in rows:
        if slots < 1:
            findings.append(Finding(
                "%s:%d %s[%d] %s" % (os.path.relpath(path, root), line, tbl,
                                     idx, name),
                "FAIL",
                "declares slots=%d. Zero means UNDECLARED and a real method "
                "always uses at least one (the trailing MethodInfo*). Fill "
                "the column in." % slots))

    # D5: a property of our own tables, so it is checked with or without the
    # metadata and never reported as INCONCLUSIVE.
    findings.extend(duplicate_targets(rows, root))

    meta, resolver, why = metadata_slots(gameasm, metadec)
    checked = 0
    shared_checked = 0
    if meta is None:
        w("INCONCLUSIVE input: %s\n" % why)
        w("  The %d table row(s) and %d postfix site(s) were checked for "
          "INTERNAL consistency only. Their declared slot counts were NOT "
          "verified against the metadata, and their SHAREDNESS (D4) was not "
          "checked at all -- a detour target that was not checked for "
          "sharedness is not a checked target.\n" % (len(rows), len(sites)))
    else:
        for tbl, idx, name, rva, slots, path, line in rows:
            truth = meta.get(rva)
            where = "%s:%d %s[%d] %s @0x%X" % (
                os.path.relpath(path, root), line, tbl, idx, name, rva)
            if truth is None:
                findings.append(Finding(
                    where, "FAIL",
                    "no method resolves to this RVA in the metadata, so its "
                    "declared slots=%d cannot be checked and the row is not "
                    "auditable. An unauditable detour target is a refusal, "
                    "not a pass." % slots))
                continue
            checked += 1
            if truth != slots:
                findings.append(Finding(
                    where, "FAIL",
                    "declares slots=%d but the metadata says %d "
                    "(parameterCount + MethodInfo* + `this` unless static). "
                    "The declared column is what the host binds on; a wrong "
                    "one in the LOW direction binds a postfix on a call with "
                    "stack arguments." % (slots, truth)))
        sf = sharedness_findings(rows, resolver, root)
        shared_checked = len({r[3] for r in rows})
        findings.extend(sf)

    w("\ndrainaudit: %d table row(s) with a `slots` column, %d verified "
      "against the metadata; %d distinct detour RVA(s) checked for sharedness "
      "(D4) and duplication (D5); %d literal POSTFIX site(s) within the "
      "%d-slot limit.\n" % (len(rows), checked, shared_checked, len(sites),
                            POSTFIX_MAX_SLOTS))
    for where, spec, n in sorted(sites):
        w("    ok  postfix %d slot(s)  %s\n" % (n, where))

    if findings:
        w("\nFAIL -- %d finding(s):\n\n" % len(findings))
        for f in findings:
            w(f.human() + "\n\n")
        w("D1/D2: a POSTFIX on a call using more than %d register slots makes "
          "the ORIGINAL read its stack arguments out of the detour thunk's own "
          "frame -- bind it PREFIX, or read the stack arguments at "
          "[entry_rsp+0x28+8*(n-4)].\n"
          "D5: a second detour on one function overwrites the first's "
          "trampoline and the first feature silently stops firing.\n"
          "D4: a detour on a SHARED RVA fires for every method folded onto "
          "that address.\n" % POSTFIX_MAX_SLOTS)
        return FAIL
    if meta is None:
        return INCONCLUSIVE
    w("PASS\n")
    return PASS


def main(argv=None):
    p = argparse.ArgumentParser(
        description="refuse any host POSTFIX detour on a call with stack "
                    "arguments (exit 0 PASS / 1 FAIL / 3 INCONCLUSIVE)")
    p.add_argument("--root", default=REPO,
                   help="tree to audit (default: this repo). A fixture tree "
                        "is how this tool's own falsifier works.")
    p.add_argument("--gameasm", default=GAMEASM_DEFAULT)
    p.add_argument("--metadec", default=METADEC_DEFAULT)
    p.add_argument("--no-metadata", action="store_true",
                   help="skip the metadata cross-check. Exits 3 unless "
                        "something already FAILED -- it is never a pass.")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    ga = "" if a.no_metadata else a.gameasm
    return audit(a.root, ga, a.metadec, quiet=a.quiet)


if __name__ == "__main__":
    sys.exit(main())
