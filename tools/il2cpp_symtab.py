#!/usr/bin/env python3
"""il2cpp_symtab.py -- an OFFLINE, COMPILE-TIME name -> unique-RVA symbol table.

## Why the resolve happens HERE and never at runtime

A by-name lookup at runtime goes through `il2cpp_class_from_name` /
`il2cpp_class_get_method_from_name`, and on this build those are TOKEN-GATED
exports: they take a trailing argument the stock signature does not have and
compare it before doing any work. Called the stock way, they do not fail -- they
return a plausible RANDOM value. (Measured offline by the export-map work on
`feat-il2cpp-export-map`, `docs/IL2CPP_EXPORTS.md`. An earlier account of this,
including CLAUDE.md 5, described it as "handles into unmapped memory"; that was
the symptom, not the mechanism.)

The consequence for this tool is unchanged and is the whole reason it exists: a
runtime name lookup's failure mode is indistinguishable from success until
something dereferences the answer, so there is no runtime check that can save
it. Resolving offline sidesteps the export ABI completely -- a byte-verified
static RVA calls the compiled body directly -- and being wrong costs a build
error instead of a session.

## The three ways a name is a lie, all of which are checked HERE

1. **SHARED RVA.** The IL2CPP backend folds identical bodies. Measured on this
   DLL (see `selftest`, which prints the histogram it actually computed):
   7,691 of 138,496 distinct RVAs are reached by more than one METHOD
   DEFINITION. (`il2cpp_nameindex.py` reports 6,261 for the same build; it
   counts distinct NAME KEYS after ambiguous ones are dropped, so the two are
   different denominators over the same fold, not a disagreement. This tool
   uses the larger, method-definition count on purpose -- it is the
   conservative one.) CALLING a shared address is fine: it is correct code for
   the receiver you pass. DETOURING one is a write with unbounded blast radius,
   because the detour fires for every method that shares it.
2. **THE UNIVERSAL STUB.** This build has one empty body -- `C2 00 00`,
   `ret 0` -- that 9,614 method definitions resolve to. Resolving
   `TMP_Text::ForceMeshUpdate` lands there. It passes a signature check. It is
   the worst answer we produce, because it looks exactly like success.
   The stub is FOUND, by owner count and by opcode shape, not hardcoded.
3. **THE WRONG SECTION.** Generated METHOD code lives in the `il2cpp` PE
   section, NOT `.text`. An RVA outside it is not a method body whatever the
   name says. This is a rule about methods only: all 386 `il2cpp_*` exports
   live in `.text` and are correctly there, so never apply this gate to one.

## How the build is made to fail

A manifest -- `abi/aowlspt_symbols.txt` -- names every symbol any consumer is
allowed to reference. Generation resolves each one and splits them:

  * ACCEPTED   -> `#define AOWL_SYM_<IDENT>` plus arity, owners, section, the
                  recorded prologue bytes, and the full offline signature.
  * SHARED-CALL-> `#define AOWL_SYMC_<IDENT>` -- a DIFFERENT macro name. This is
                  the escape hatch of requirement 3: legitimate, opt-in per call
                  site, and impossible to reach by writing `AOWL_SYM_`.
  * REJECTED   -> `#define AOWL_SYM_<IDENT> AOWL_SYMBOL_REJECTED__<IDENT>__<reason>`
                  which is an UNDEFINED IDENTIFIER. Referencing it is a
                  compile error whose text names the symbol and the reason.
                  Never referencing it costs nothing -- which is the correct
                  behaviour, since the requirement is that the build fails when
                  code REFERENCES a bad symbol, not when the manifest lists one.

`check` is the second, language-independent gate, and the one `aowl` runs: it
greps the consumer tree for `AOWL_SYM_<IDENT>` / `AOWL_SYMC_<IDENT>` uses and
FAILS THE BUILD, naming file, line, symbol and reason, if a referenced symbol
is rejected, if a shared RVA is referenced through the non-escape-hatch macro,
--- and the rule it applies to a reference, exactly ---
  * COMMENTS ARE NOT SCANNED. `#`, `##` and `#[ ]#` in Nim, `//` and C block
    comments in C/C++ headers (including inside `{.emit.}` bodies) are blanked
    before the scan, byte-for-byte so line numbers survive. String literals are
    NOT blanked: a symbol in a string is a real use. Naming a symbol in prose is
    documentation, not a reference, and it used to fail the build.
  * A token `AOWL_SYM[C]_<TOKEN>` is matched EXACTLY against the manifest first.
    Only if that fails is the LONGEST companion suffix (`_ARITY`, `_OWNERS`,
    `_NAME`, `_SECTION`, `_PROLOGUE`) whose remainder is a declared symbol
    stripped. Unconditional stripping reported `AOWL_SYM_OBJ_GET_NAME` -- a real
    symbol -- as a use of `OBJ_GET`, which nothing had written.
  * A token nothing explains is reported AS WRITTEN, with the source line and
    the declared symbols that are near matches.
--- and check also fails ---
if the header's recorded prologue no longer matches the DLL, or if the header
was generated from a different GameAssembly.dll than the one on disk. That last
one is what makes a Tarkov update fail loudly instead of lying.

## What this deliberately does NOT do

It does not resolve anything at runtime, does not load a file, does not call
one IL2CPP export. It also does not replace `il2cpp_nameindex.py`: that answers
"what RVA does this name have" for a name only known at RUN time. This answers
it for names known at BUILD time, which is every name a mod or the host has
ever actually wanted.

The resolution chain is `il2cpp_resolve.py`'s, IMPORTED rather than
reimplemented, so the two cannot drift.

## Manifest format

    # comment
    IDENT = Ns.Type::Method/arity
    IDENT = Ns.Type::Method/arity  shared-call why="a sentence, >= 20 chars"

`arity` may be `*`, which is accepted only when the name has exactly one
overload -- otherwise the symbol is REJECTED as ambiguous rather than guessed.

## Verbs

    il2cpp_symtab.py find-method <gameasm> <metadec> <substr> [limit]
    il2cpp_symtab.py gen   <gameasm> <metadec> <manifest> <out.h> [out.nim]
    il2cpp_symtab.py verify-header <gameasm> <metadec> <manifest> <header>
    il2cpp_symtab.py check <gameasm> <metadec> <manifest> <header> [srcdir...]
    il2cpp_symtab.py selftest <gameasm> <metadec>   -- the mutation proofs
"""
import hashlib
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from il2cpp_resolve import Resolver              # noqa: E402  (path set above)
# Shell-independent compiler resolution -- see tools/cctool.py. Aliased so the
# names cannot be confused with this module's own helpers.
from cctool import (SHELL_CAUSE as _CCTOOL_SHELL_CAUSE,   # noqa: E402
                    cc_run as _cctool_cc_run,
                    find_cc as _cctool_find_cc)

PROLOGUE_LEN = 16
CODE_SECTION = "il2cpp"
MAGIC = "AOWLSYMTAB"
FORMAT_VERSION = 1

# Reasons. These strings become part of the poisoned identifier, so they are
# C identifier fragments on purpose -- the compiler error has to READ.
R_NOT_FOUND = "no_such_method_in_metadata"
R_AMBIGUOUS = "ambiguous_arity_star_has_multiple_overloads"
R_UNMAPPED = "resolved_to_no_code_pointer"
R_SECTION = "not_in_il2cpp_section"
R_STUB = "resolves_to_the_universal_empty_body_stub"
R_SHARED = "shared_rva_detouring_this_hits_every_owner"
R_NO_REASON = "shared_call_declared_without_a_why_reason"

MIN_WHY = 20


# ----------------------------------------------------------------- build id

def pe_image_key(path):
    """(timeDateStamp << 32) | SizeOfImage -- the pair a mapped module can also
    report, so a header stamp is checkable against a live process later."""
    with open(path, "rb") as f:
        b = f.read(0x400)
    e = struct.unpack_from("<I", b, 0x3C)[0]
    tds = struct.unpack_from("<I", b, e + 8)[0]
    soi = struct.unpack_from("<I", b, e + 24 + 56)[0]
    return (tds << 32) | soi


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ----------------------------------------------------------------- manifest

class Entry(object):
    def __init__(self, ident, key, shared_call, why, line_no):
        self.ident = ident
        self.key = key              # "Ns.Type::Method/arity"
        self.shared_call = shared_call
        self.why = why
        self.line_no = line_no
        # filled by resolve_entry
        self.rva = None
        self.owners = 0
        self.section = None
        self.prologue = b""
        self.arity = None
        self.sig = ""
        self.reject = None          # reason string, or None


IDENT_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
LINE_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\S+)\s*(.*?)\s*$")
WHY_RE = re.compile(r'why\s*=\s*"([^"]*)"')


def parse_manifest(path):
    out = []
    seen = {}
    with open(path, "r", encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            m = LINE_RE.match(line)
            if not m:
                raise SystemExit("%s:%d: not `IDENT = Ns.Type::Method/arity`: %r"
                                 % (path, n, raw.rstrip()))
            ident, key, rest = m.group(1), m.group(2), m.group(3)
            if not IDENT_RE.match(ident):
                raise SystemExit("%s:%d: symbol name %r must be UPPER_SNAKE -- "
                                 "it becomes a C macro" % (path, n, ident))
            if ident in seen:
                raise SystemExit("%s:%d: duplicate symbol %s (first at line %d)"
                                 % (path, n, ident, seen[ident]))
            seen[ident] = n
            if "::" not in key or "/" not in key.rsplit("::", 1)[1]:
                raise SystemExit("%s:%d: key %r must be Ns.Type::Method/arity "
                                 "(arity may be *)" % (path, n, key))
            shared_call = "shared-call" in rest
            wm = WHY_RE.search(rest)
            why = wm.group(1) if wm else ""
            out.append(Entry(ident, key, shared_call, why, n))
    return out


# ---------------------------------------------------------------- resolving

class Table(object):
    """Everything about one GameAssembly.dll that the manifest is resolved
    against. Built once; `find-method`, `gen`, `check` and `selftest` all use
    the same object so they cannot disagree."""

    def __init__(self, gameasm, metadec):
        self.gameasm = gameasm
        self.R = Resolver(gameasm, metadec)
        self.image_key = pe_image_key(gameasm)
        self.file_hash = file_hash(gameasm)
        self.counts = self.R.shared_rva_counts()
        # THE UNIVERSAL STUB IS FOUND, NOT ASSUMED. Two independent conditions
        # must agree: it is the most-shared RVA in the whole image, and its
        # bytes are an immediate-return shape. If they disagree, nothing is
        # treated as the stub and every symbol still has to pass the ordinary
        # shared-RVA rule -- a strictly safer failure than picking one.
        self.stub_rva = None
        if self.counts:
            top = max(self.counts, key=lambda r: self.counts[r])
            th = Resolver.classify_thunk(self.R.code_bytes(top, PROLOGUE_LEN))
            if th and th[0] == "STUB":
                self.stub_rva = top
                self.stub_owners = self.counts[top]
        self._index = None

    # -- name index over ALL methods, built lazily (about 4s)
    def index(self):
        if self._index is not None:
            return self._index
        by_key = {}        # "Ns.Type::Method/arity" -> set(rva)
        by_spec = {}       # "Ns.Type::Method"       -> set((arity, rva))
        meta = {}          # "Ns.Type::Method/arity" -> method index
        R = self.R
        for t in range(R.NTYPES):
            mp = R.MOD.get(R.image_of_type(t))
            if not mp or not mp[0]:
                continue
            base, cnt = mp
            ns, nm = R.tname(t)
            full = (ns + "." + nm) if ns else nm
            for mi in R.type_methods(t):
                rid = R.mtoken(mi) & 0xFFFFFF
                if not (1 <= rid <= cnt):
                    continue
                va = R.rq(base + (rid - 1) * 8)
                if not va:
                    continue
                rva = va - R.IB
                arity = struct.unpack_from("<H", R.m, R.M_OFF + mi * R.MS + 34)[0]
                spec = full + "::" + R.mname(mi)
                key = "%s/%d" % (spec, arity)
                by_key.setdefault(key, set()).add(rva)
                by_spec.setdefault(spec, set()).add((arity, rva))
                meta.setdefault(key, mi)
        self._index = (by_key, by_spec, meta)
        return self._index

    def resolve_entry(self, e):
        by_key, by_spec, meta = self.index()
        spec, _, arity_s = e.key.rpartition("/")
        if arity_s == "*":
            variants = by_spec.get(spec)
            if not variants:
                e.reject = R_NOT_FOUND
                return e
            if len(variants) != 1:
                # `/*` is only ever a shorthand for "there is nothing to be
                # ambiguous about". The moment there is, REFUSE -- do not pick.
                e.reject = R_AMBIGUOUS
                return e
            arity, rva = next(iter(variants))
            key = "%s/%d" % (spec, arity)
        else:
            key = e.key
            rvas = by_key.get(key)
            if not rvas:
                e.reject = R_NOT_FOUND
                return e
            if len(rvas) != 1:
                # one name, two DIFFERENT addresses: there is no right answer.
                e.reject = R_AMBIGUOUS
                return e
            rva = next(iter(rvas))
            arity = int(arity_s)

        e.rva = rva
        e.arity = arity
        e.owners = self.counts.get(rva, 0)
        sec, fo, _ = self.R.section_of_rva(rva)
        e.section = sec
        e.prologue = self.R.code_bytes(rva, PROLOGUE_LEN) or b""
        mi = meta.get(key)
        if mi is not None:
            try:
                e.sig = self.R.sig_string(mi, key.rsplit("::", 1)[1].split("/")[0])[0]
            except Exception:
                e.sig = "<signature unresolvable>"

        # -- the gates, most specific reason first
        if rva <= 0 or fo is None or len(e.prologue) < PROLOGUE_LEN:
            e.reject = R_UNMAPPED
        elif sec != CODE_SECTION:
            e.reject = R_SECTION
        elif self.stub_rva is not None and rva == self.stub_rva:
            e.reject = R_STUB
        elif e.owners > 1 and not e.shared_call:
            e.reject = R_SHARED
        elif e.shared_call and len(e.why.strip()) < MIN_WHY:
            e.reject = R_NO_REASON
        return e


# ----------------------------------------------------------------- emitting

def cbytes(bs):
    return ",".join("0x%02X" % b for b in bs)


def emit_header(T, entries, out_path, manifest_path):
    L = []
    a = L.append
    a("/* aowlspt_symtab.h -- GENERATED. DO NOT EDIT.")
    a(" *")
    a(" * tools/il2cpp_symtab.py gen, from")
    a(" *   %s" % os.path.basename(T.gameasm))
    a(" *   %s" % os.path.basename(manifest_path))
    a(" *")
    a(" * Every RVA here was resolved OFFLINE and passed four gates: it is in")
    a(" * the `%s` PE section, it is not this build's universal empty-body" % CODE_SECTION)
    a(" * stub, exactly one method definition owns it (unless it is declared")
    a(" * shared-call), and its first %d bytes are recorded below so a later" % PROLOGUE_LEN)
    a(" * `il2cpp_symtab.py check` can prove the DLL still starts that way.")
    a(" *")
    a(" * A symbol that failed a gate is defined to an UNDEFINED IDENTIFIER")
    a(" * naming the reason: referencing it is a compile error, and not")
    a(" * referencing it costs nothing. `check` is the second gate and reports")
    a(" * the same thing with a file and line for non-C consumers.")
    a(" *")
    a(" *")
    a(" * HOW TO USE IT")
    a(" * -------------")
    a(" * C / abi headers:  #include \"aowlspt_symtab.h\", then use")
    a(" *   AOWL_SYM_<NAME> where you had a hex literal. `-I abi` is already on")
    a(" *   every host, mod and tool compile (`abiInclude` in tools/aowl.nim).")
    a(" * Nim / Nimony:     import the sibling aowlspt_symtab.nim; the same")
    a(" *   AOWL_SYM_<NAME> identifiers are exported as `uint32` consts.")
    a(" *")
    a(" * The RVA is an offset. Add the RUNTIME base of GameAssembly.dll --")
    a(" * the DLL is ASLR-relocated and 0x180000000 is only its preferred base,")
    a(" * so never add that constant.")
    a(" *")
    a(" * Nothing here replaces the binder's own safety work: prologue")
    a(" * byte-verify against abi/aowlspt_prologue.h's startup snapshot,")
    a(" * VirtualQuery on every hop, flag-gated and default-OFF. What it")
    a(" * replaces is the by-NAME step, and the _PROLOGUE macro below is the")
    a(" * expectation that verify should be fed.")
    a(" *")
    a(" * Add symbols by editing abi/aowlspt_symbols.txt, never this file.")
    a(" */")
    a("#ifndef AOWLSPT_SYMTAB_H")
    a("#define AOWLSPT_SYMTAB_H")
    a("")
    a('#define AOWL_SYMTAB_MAGIC   "%s"' % MAGIC)
    a("#define AOWL_SYMTAB_VERSION %d" % FORMAT_VERSION)
    a("/* Build identity of the GameAssembly.dll every RVA below came from.")
    a(" * (timeDateStamp << 32) | SizeOfImage -- a mapped module can report both,")
    a(" * so a host may cross-check this against the process it is inside. */")
    a("#define AOWL_SYMTAB_IMAGE_KEY 0x%016Xull" % T.image_key)
    a('#define AOWL_SYMTAB_FILE_SHA256 "%s"' % T.file_hash)
    a("#define AOWL_SYMTAB_PROLOGUE_LEN %d" % PROLOGUE_LEN)
    if T.stub_rva is not None:
        a("/* This build's universal empty-body stub, found by owner count AND")
        a(" * opcode shape, not hardcoded. Anything landing here is REJECTED. */")
        a("#define AOWL_SYMTAB_UNIVERSAL_STUB_RVA 0x%08Xu" % T.stub_rva)
        a("#define AOWL_SYMTAB_UNIVERSAL_STUB_OWNERS %d" % T.stub_owners)
    else:
        a("/* No RVA satisfied BOTH stub conditions on this build; the stub gate")
        a(" * is therefore inert and every symbol still passes the shared-RVA")
        a(" * gate on its own. Deliberately not a guess. */")
    a("")

    acc = [e for e in entries if not e.reject and not e.shared_call]
    shc = [e for e in entries if not e.reject and e.shared_call]
    rej = [e for e in entries if e.reject]
    a("/* %d accepted, %d shared-call escape hatch, %d rejected. */"
      % (len(acc), len(shc), len(rej)))
    a("")

    def block(e, macro):
        a("/* %s" % e.sig)
        a(" *   %s" % e.key)
        a(" *   RVA 0x%08X  section %s  owners %d  arity %d"
          % (e.rva, e.section, e.owners, e.arity))
        if e.shared_call:
            a(" *   SHARED-CALL ESCAPE HATCH -- %d method definitions share this"
              % e.owners)
            a(" *   address. Calling it is correct code for the receiver you")
            a(" *   pass. DETOURING it is not, which is why there is no")
            a(" *   AOWL_SYM_%s. Declared why: %s" % (e.ident, e.why))
        a(" */")
        a("#define %s%-30s 0x%08Xu" % (macro, e.ident, e.rva))
        a("#define %s%s_ARITY %d" % (macro, e.ident, e.arity))
        a("#define %s%s_OWNERS %d" % (macro, e.ident, e.owners))
        a('#define %s%s_NAME "%s"' % (macro, e.ident, e.key))
        a('#define %s%s_SECTION "%s"' % (macro, e.ident, e.section))
        a("#define %s%s_PROLOGUE %s" % (macro, e.ident, cbytes(e.prologue)))
        a("")

    if acc:
        a("/* ---- detour-safe and call-safe: exactly one owner ------------- */")
        a("")
        for e in acc:
            block(e, "AOWL_SYM_")
    if shc:
        a("/* ---- CALL ONLY. Deliberately spelled AOWL_SYMC_, not AOWL_SYM_.")
        a(" * There is no AOWL_SYM_ form of these, so a detour site cannot")
        a(" * reach one by accident -- it has to be typed on purpose, and")
        a(" * abi/aowlspt_symbols.txt has to carry a written reason. ------- */")
        a("")
        for e in shc:
            block(e, "AOWL_SYMC_")
    if rej:
        a("/* ---- REJECTED. Each expands to an undefined identifier. ------- */")
        a("")
        for e in rej:
            a("/* %s -> %s" % (e.ident, e.reject))
            if e.rva:
                a(" *   %s resolves to RVA 0x%08X, section %s, %d owner(s)"
                  % (e.key, e.rva, e.section, e.owners))
            else:
                a(" *   %s did not resolve to a unique code address" % e.key)
            a(" */")
            a("#define AOWL_SYM_%s AOWL_SYMBOL_REJECTED__%s__%s"
              % (e.ident, e.ident, e.reject))
            a("#define AOWL_SYMC_%s AOWL_SYMBOL_REJECTED__%s__%s"
              % (e.ident, e.ident, e.reject))
            a("")
    a("#endif /* AOWLSPT_SYMTAB_H */")
    write_lf(out_path, "\n".join(L) + "\n")


def emit_nim(T, entries, out_path, manifest_path):
    L = []
    a = L.append
    a("## aowlspt_symtab.nim -- GENERATED by tools/il2cpp_symtab.py. DO NOT EDIT.")
    a("##")
    a("## The Nim/Nimony face of abi/aowlspt_symtab.h. Same gates, same RVAs.")
    a("## A REJECTED symbol is simply ABSENT here: referencing it is an")
    a("## `undeclared identifier` compile error, and `il2cpp_symtab.py check`")
    a("## turns that into a message naming the file, line and reason.")
    a("##")
    a("## Edit abi/aowlspt_symbols.txt, never this file.")
    a("")
    a("const")
    a("  AowlSymtabImageKey* = 0x%016X'u64" % T.image_key)
    a('  AowlSymtabFileSha256* = "%s"' % T.file_hash)
    a("  AowlSymtabPrologueLen* = %d" % PROLOGUE_LEN)
    a("")
    for e in entries:
        if e.reject:
            continue
        pre = "AOWL_SYMC_" if e.shared_call else "AOWL_SYM_"
        a("const")
        a("  %s%s* = 0x%08X'u32" % (pre, e.ident, e.rva))
        a("    ## %s" % e.sig)
        a("    ## %s -- section %s, owners %d, arity %d"
          % (e.key, e.section, e.owners, e.arity))
        if e.shared_call:
            a("    ## CALL ONLY (%d owners). why: %s" % (e.owners, e.why))
        a("  %s%s_ARITY* = %d" % (pre, e.ident, e.arity))
        a("  %s%s_OWNERS* = %d" % (pre, e.ident, e.owners))
        a('  %s%s_NAME* = "%s"' % (pre, e.ident, e.key))
        a("  %s%s_PROLOGUE* = [%s]"
          % (pre, e.ident, ", ".join("0x%02X'u8" % b for b in e.prologue)))
        a("")
    write_lf(out_path, "\n".join(L) + "\n")


def write_lf(path, text):
    # newline='' + explicit \n: .gitattributes says `* -text` deliberately, so a
    # CRLF file commits as CRLF and conflicts on every line on a later merge.
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


# ------------------------------------------------------------------- check

USE_RE = re.compile(r"\bAOWL_SYM(C?)_([A-Z][A-Z0-9_]*)\b")

# The GENERATED header emits, for a symbol IDENT, both the bare RVA macro
# `AOWL_SYM_<IDENT>` and five companion macros `AOWL_SYM_<IDENT><SUFFIX>`.
# So a reference has to be mapped back to its IDENT by stripping a suffix --
# but ONLY when the whole thing is not itself a declared symbol. Stripping
# unconditionally is what broke `OBJ_GET_NAME` (a real symbol,
# UnityEngine.Object::get_name/0): every reference to it was reported as a
# reference to `OBJ_GET`, a name no source file has ever written.
#
# THE RULE, in order:
#   1. exact match against a declared symbol wins (longest match, since the
#      full token is longer than any suffix-stripped remainder);
#   2. otherwise strip the LONGEST suffix that leaves a declared symbol;
#   3. otherwise it is an undeclared reference, reported with the source line
#      and the declared symbols that are near matches.
SUFFIXES = ("_PROLOGUE", "_SECTION", "_OWNERS", "_ARITY", "_NAME")

SCAN_EXT = (".h", ".c", ".nim", ".cpp")
SKIP_NAMES = ("aowlspt_symtab.h", "aowlspt_symtab.nim", "il2cpp_symtab.py")


def resolve_use(token, declared):
    """token = the text after AOWL_SYM_/AOWL_SYMC_. -> (ident, matched_exactly)
    or (None, False) when nothing declared explains it."""
    if token in declared:
        return token, True
    for s in sorted(SUFFIXES, key=len, reverse=True):
        if token.endswith(s):
            base = token[:-len(s)]
            if base in declared:
                return base, False
    return None, False


def strip_comments(text, ext):
    """Blank out COMMENT text, preserving every byte position and newline so
    line numbers and column offsets are unchanged.

    A symbol named in prose is not a reference. The gate used to fail a build
    because a comment EXPLAINING a symbol mentioned it, which meant the only
    way to document one was to not write its name down.

    Handled: `#` and `#[ ]#` for Nim, `//` and C block comments for C/C++
    headers, `{.emit.}` bodies included (they are Nim string literals holding C,
    and the C comments inside them are blanked by the C pass -- see below).
    String literals are respected in both languages, so a `"# not a comment"`
    keeps its text.
    """
    out = list(text)
    n = len(text)
    i = 0
    nim = ext == ".nim"
    blockdepth = 0          # nim #[ ]# nesting / C /* */ (depth 0 or 1)
    while i < n:
        c = text[i]
        if blockdepth:
            if nim and text.startswith("#[", i):
                blockdepth += 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if nim and text.startswith("]#", i):
                blockdepth -= 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if not nim and text.startswith("*/", i):
                blockdepth = 0
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if c != "\n":
                out[i] = " "
            i += 1
            continue
        if text.startswith('"""', i) and nim:
            j = text.find('"""', i + 3)
            i = n if j < 0 else j + 3
            continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                elif text[i] == "\n" and not nim:
                    break
                i += 1
            i += 1
            continue
        if c == "'" and not nim:
            i += 1
            while i < n and text[i] != "'":
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if nim and text.startswith("#[", i):
            blockdepth = 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if not nim and text.startswith("/*", i):
            blockdepth = 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if (nim and c == "#") or (not nim and text.startswith("//", i)):
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def scan_uses(dirs, declared=None):
    """[(file, line_no, is_call_only, ident, raw_token, line_text)] over every
    consumer source. COMMENTS ARE NOT SCANNED. `ident` is None when no declared
    symbol explains the token; the caller reports that with the source line."""
    declared = declared if declared is not None else set()
    uses = []
    for d in dirs:
        if os.path.isfile(d):
            files = [d]
        else:
            files = []
            for root, _dn, fn in os.walk(d):
                if os.sep + ".git" in root or "nimcache" in root:
                    continue
                for f in fn:
                    if f.endswith(SCAN_EXT) and f not in SKIP_NAMES:
                        files.append(os.path.join(root, f))
        for p in files:
            if os.path.basename(p) in SKIP_NAMES:
                continue
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    raw = f.read()
            except OSError:
                continue
            ext = os.path.splitext(p)[1].lower()
            code = strip_comments(raw, ext)
            raw_lines = raw.split("\n")
            for n, line in enumerate(code.split("\n"), 1):
                for m in USE_RE.finditer(line):
                    token = m.group(2)
                    ident, _exact = resolve_use(token, declared)
                    uses.append((p, n, m.group(1) == "C", ident, token,
                                 raw_lines[n - 1].strip() if n <= len(raw_lines)
                                 else ""))
    return uses


def near_matches(token, declared):
    """Declared symbols a human would call 'close' to what was written."""
    import difflib
    cands = set(difflib.get_close_matches(token, sorted(declared), 5, 0.6))
    for d in declared:
        if d.startswith(token) or token.startswith(d):
            cands.add(d)
    return sorted(cands)


def parse_header(path):
    """Read back the GENERATED header's own claims: stamp + per-symbol RVA and
    prologue. `check` re-derives all of these from GameAssembly.dll and compares,
    so a hand-edited header, a stale header, or a Tarkov update FAILS."""
    txt = open(path, "r", encoding="utf-8", errors="replace").read()
    out = {"image_key": None, "sha": None, "syms": {}}
    m = re.search(r"AOWL_SYMTAB_IMAGE_KEY\s+0x([0-9A-Fa-f]+)ull", txt)
    if m:
        out["image_key"] = int(m.group(1), 16)
    m = re.search(r'AOWL_SYMTAB_FILE_SHA256\s+"([0-9a-f]+)"', txt)
    if m:
        out["sha"] = m.group(1)
    for m in re.finditer(r"#define\s+AOWL_SYMC?_([A-Z][A-Z0-9_]*)\s+0x([0-9A-Fa-f]+)u\s*$",
                         txt, re.M):
        out["syms"].setdefault(m.group(1), {})["rva"] = int(m.group(2), 16)
    for m in re.finditer(r"#define\s+AOWL_SYMC?_([A-Z][A-Z0-9_]*)_PROLOGUE\s+([0-9A-Fa-fx,]+)\s*$",
                         txt, re.M):
        bs = bytes(int(x, 16) for x in m.group(2).split(","))
        out["syms"].setdefault(m.group(1), {})["prologue"] = bs
    return out


def do_check(gameasm, metadec, manifest, header, dirs, header_only=False):
    """`header_only` compares the header ON DISK against GameAssembly.dll and
    stops. It exists because of a real hole in the first wiring of this tool:
    `aowl` ran `gen` and then `check`, and `gen` had just REWRITTEN the header
    from that same DLL -- so the stamp gate and the prologue gate could not
    fail, whatever the DLL was. A gate that cannot fail is not a gate
    (CLAUDE.md 9b). The build now runs this against the COMMITTED header FIRST,
    where a hand-edit, a stale commit, or a Tarkov update genuinely does fail,
    and only then regenerates."""
    fails = []
    notes = []

    if not os.path.exists(header):
        fails.append("FAIL  the generated header %s does not exist -- run "
                     "`il2cpp_symtab.py gen` (aowl does this for you)" % header)
        return fails, notes, 0

    H = parse_header(header)
    cur_key = pe_image_key(gameasm)
    cur_sha = file_hash(gameasm)
    if H["image_key"] != cur_key:
        fails.append(
            "FAIL  STALE TABLE. %s was generated from a DIFFERENT "
            "GameAssembly.dll (header image key 0x%016X, this DLL 0x%016X). "
            "Every RVA in it is a wrong-but-mapped address. Regenerate."
            % (os.path.basename(header), H["image_key"] or 0, cur_key))
    if H["sha"] != cur_sha:
        fails.append(
            "FAIL  STALE TABLE. SHA-256 of GameAssembly.dll is %s..., the "
            "header records %s... Regenerate."
            % (cur_sha[:16], (H["sha"] or "<absent>")[:16]))
    if fails:
        # Comparing per-symbol prologues against a different DLL would produce
        # a wall of noise whose real cause is the one line above.
        return fails, notes, 0

    T = Table(gameasm, metadec)
    entries = {e.ident: T.resolve_entry(e) for e in parse_manifest(manifest)}
    # Pre-gen, the header legitimately lags the manifest by whatever edit is
    # being built right now, so "in the header, gone from the manifest" is a
    # note there and a failure post-gen.
    drift_is_fatal = not header_only

    # 1. the header must still describe THIS DLL, symbol by symbol.
    checked = 0
    for ident, hs in sorted(H["syms"].items()):
        e = entries.get(ident)
        if e is None:
            msg = ("%s is in the header but NOT in %s -- the header is out of "
                   "date with the manifest" % (ident, os.path.basename(manifest)))
            (fails.append("FAIL  " + msg) if drift_is_fatal
             else notes.append("note  " + msg))
            continue
        if e.reject:
            continue
        if hs.get("rva") != e.rva:
            fails.append("FAIL  %s: header records RVA 0x%08X, %s resolves to "
                         "0x%08X" % (ident, hs.get("rva") or 0, e.key, e.rva))
            continue
        live = e.prologue
        rec = hs.get("prologue", b"")
        if rec != live:
            fails.append(
                "FAIL  %s (%s @0x%08X): PROLOGUE MISMATCH. Recorded %s, "
                "GameAssembly.dll has %s. Either the header was edited by hand "
                "or the RVA no longer points at that method's body."
                % (ident, e.key, e.rva, cbytes(rec), cbytes(live)))
            continue
        checked += 1

    if header_only:
        return fails, notes, checked

    # 2. every symbol the manifest declares must have survived its gates, or
    #    no consumer may reference it.
    uses = scan_uses(dirs, set(entries))
    used = {}
    for path, n, call_only, ident, token, text in uses:
        if ident is None:
            # UNDECLARED. Name what the source actually wrote -- never a
            # suffix-stripped invention -- and show the line and the closest
            # declared symbols, because "not declared" with no candidates is
            # indistinguishable from a tool bug.
            near = near_matches(token, set(entries))
            fails.append(
                "FAIL  %s:%d references AOWL_SYM%s_%s, which is not declared in "
                "%s\n        %s\n        near matches in the manifest: %s"
                % (rel(path), n, "C" if call_only else "", token,
                   os.path.basename(manifest), text,
                   ", ".join(near) if near else
                   "(none -- check the spelling against the manifest)"))
            continue
        used.setdefault(ident, []).append((path, n, call_only))

    for ident, sites in sorted(used.items()):
        e = entries.get(ident)
        if e.reject:
            for path, n, _c in sites:
                fails.append("FAIL  %s:%d references %s -- REJECTED: %s (%s)"
                             % (rel(path), n, ident, e.reject, e.key))
            continue
        for path, n, call_only in sites:
            if e.shared_call and not call_only:
                fails.append(
                    "FAIL  %s:%d uses AOWL_SYM_%s, but %s is a SHARED RVA with "
                    "%d owners. Calling it is safe; detouring it is not. If you "
                    "are CALLING it, say AOWL_SYMC_%s."
                    % (rel(path), n, ident, e.key, e.owners, ident))
            if call_only and not e.shared_call:
                notes.append(
                    "note  %s:%d uses the shared-call macro AOWL_SYMC_%s for a "
                    "symbol with exactly one owner. Harmless, but AOWL_SYM_%s "
                    "is the one that keeps its guarantee." % (rel(path), n, ident, ident))

    for ident, e in sorted(entries.items()):
        if e.reject and ident not in used:
            notes.append("note  %s is REJECTED (%s) and nothing references it, "
                         "so nothing fails." % (ident, e.reject))
    return fails, notes, checked


def rel(p):
    try:
        return os.path.relpath(p, REPO)
    except ValueError:
        return p


# ---------------------------------------------------------------- selftest

def _tmpdir():
    import tempfile
    return tempfile.mkdtemp(prefix="aowlsym-")


def do_selftest(gameasm, metadec):
    """MUTATION PROOFS. Each is a PAIR: a control that must PASS and a mutant
    that must FAIL. A check that only ever runs the control cannot fail and is
    therefore not a check (CLAUDE.md 9b).

    Prints PASS / FAIL / INCONCLUSIVE per proof and exits non-zero unless every
    proof is PASS.
    """
    import shutil
    import subprocess

    results = []

    def rec(name, verdict, detail):
        results.append((name, verdict, detail))
        print("%-12s %s\n             %s" % (verdict, name, detail))

    T = Table(gameasm, metadec)
    by_key, by_spec, _meta = T.index()

    print("build      image key 0x%016X  sha %s..." % (T.image_key, T.file_hash[:16]))
    n_shared = sum(1 for v in T.counts.values() if v > 1)
    print("histogram  %d distinct RVAs, %d owned by >1 method definition"
          % (len(T.counts), n_shared))
    if T.stub_rva is None:
        print("stub       NOT identified on this build (gate inert)")
    else:
        print("stub       0x%08X, %d owners, bytes %s"
              % (T.stub_rva, T.stub_owners,
                 cbytes(T.code_prologue(T.stub_rva) if hasattr(T, "code_prologue")
                        else T.R.code_bytes(T.stub_rva, 4))))

    # -- pick real specimens OUT OF THIS DLL, never invented ----------------
    clean = shared = stub_owner = None
    for key, rvas in by_key.items():
        if len(rvas) != 1:
            continue
        rva = next(iter(rvas))
        sec, fo, _ = T.R.section_of_rva(rva)
        if sec != CODE_SECTION or fo is None:
            continue
        n = T.counts.get(rva, 0)
        if n == 1 and clean is None and len(T.R.code_bytes(rva, PROLOGUE_LEN) or b"") == PROLOGUE_LEN:
            clean = (key, rva, n)
        elif T.stub_rva is not None and rva == T.stub_rva and stub_owner is None:
            stub_owner = (key, rva, n)
        elif 1 < n < 500 and shared is None and rva != T.stub_rva:
            shared = (key, rva, n)
        if clean and shared and (stub_owner or T.stub_rva is None):
            break

    if not (clean and shared):
        rec("specimens", "INCONCLUSIVE",
            "could not find both a unique-owner and a shared specimen in this "
            "DLL; the proofs below were NOT run")
        return 2
    print("specimens  clean=%s (0x%08X, %d owner)" % (clean[0], clean[1], clean[2]))
    print("           shared=%s (0x%08X, %d owners)" % (shared[0], shared[1], shared[2]))
    if stub_owner:
        print("           stub=%s (0x%08X, %d owners)"
              % (stub_owner[0], stub_owner[1], stub_owner[2]))

    d = _tmpdir()
    try:
        man = os.path.join(d, "syms.txt")
        hdr = os.path.join(d, "aowlspt_symtab.h")
        lines = ["CLEAN_ONE = %s" % clean[0],
                 "SHARED_BAD = %s" % shared[0],
                 'SHARED_OK = %s  shared-call why="calling a folded body is '
                 'correct code for the receiver we pass"' % shared[0]]
        if stub_owner:
            lines.append("STUB_ONE = %s" % stub_owner[0])
        write_lf(man, "\n".join(lines) + "\n")
        entries = [T.resolve_entry(e) for e in parse_manifest(man)]
        emit_header(T, entries, hdr, man)
        got = {e.ident: e.reject for e in entries}

        # -- PROOF 1: the classifier itself ---------------------------------
        want = {"CLEAN_ONE": None, "SHARED_BAD": R_SHARED, "SHARED_OK": None}
        if stub_owner:
            want["STUB_ONE"] = R_STUB
        bad = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
        rec("gates", "PASS" if not bad else "FAIL",
            ("a unique-owner symbol was accepted, the SAME shared RVA was "
             "rejected as plain and accepted as shared-call%s"
             % (", and the universal stub was rejected" if stub_owner else
                " (no stub specimen on this build)"))
            if not bad else "wrong verdicts: %r" % bad)

        # -- PROOF 2: does the C COMPILER actually fail? ---------------------
        # cctool, not shutil.which: a gcc that is PRESENT is not a gcc that
        # WORKS. Under Git Bash, Git's mingw64\bin precedes msys2's ucrt64 on
        # PATH, cc1.exe dies in the loader with 0xC0000139 and prints nothing,
        # and gcc exits 1. That made the CONTROL TU fail too -- so this proof
        # reported a confident FAIL ("clean rc=1, want 0") for an environment
        # problem that has nothing to do with the header. See tools/cctool.py.
        cc, ccnote = _cctool_find_cc()
        if not cc:
            rec("compile", "INCONCLUSIVE",
                "%s The poisoned-identifier proof was NOT PERFORMED (this is "
                "not a pass)." % ccnote)
        else:
            def compile_using(macro):
                src = os.path.join(d, "tu.c")
                write_lf(src, '#include "aowlspt_symtab.h"\n'
                              "unsigned t(void){ return %s; }\n" % macro)
                p = _cctool_cc_run([cc, "-c", "-I", d, src, "-o",
                                    os.path.join(d, "tu.o")])
                return p.returncode, ((p.stdout or "") + (p.stderr or ""))

            rc_ok, out_ok = compile_using("AOWL_SYM_CLEAN_ONE")
            rc_bad, out_bad = compile_using("AOWL_SYM_SHARED_BAD")
            rc_hatch, _ = compile_using("AOWL_SYMC_SHARED_OK")
            named = ("SHARED_BAD" in out_bad
                     and R_SHARED.split("_")[0] in out_bad)
            if rc_ok != 0 and not out_ok.strip():
                # The CONTROL failed with no diagnostic. That is never a
                # statement about the header -- it is the toolchain. Three
                # outcomes, not two.
                rec("compile", "INCONCLUSIVE",
                    "the CONTROL translation unit (AOWL_SYM_CLEAN_ONE, which "
                    "must compile) exited %d with no output, so the "
                    "poisoned-identifier proof was NOT PERFORMED. %s"
                    % (rc_ok, _CCTOOL_SHELL_CAUSE))
            elif rc_ok == 0 and rc_bad != 0 and rc_hatch == 0 and named:
                rec("compile", "PASS",
                    "control TU using AOWL_SYM_CLEAN_ONE compiled (rc=0); the "
                    "SAME shared RVA referenced as AOWL_SYM_SHARED_BAD FAILED "
                    "(rc=%d) with the symbol and reason in the message; the "
                    "AOWL_SYMC_ escape hatch compiled (rc=0)" % rc_bad)
            else:
                rec("compile", "FAIL",
                    "clean rc=%d (want 0), shared rc=%d (want !=0), hatch rc=%d "
                    "(want 0), message named the symbol: %s"
                    % (rc_ok, rc_bad, rc_hatch, named))

        # -- PROOF 3: corrupt a RECORDED prologue, `check` must fail ---------
        good_fails, _n, nchecked = do_check(gameasm, metadec, man, hdr, [])
        txt = open(hdr, encoding="utf-8").read()
        m = re.search(r"(#define AOWL_SYM_CLEAN_ONE_PROLOGUE )(0x[0-9A-F]{2})", txt)
        if not m or nchecked < 1:
            rec("prologue", "INCONCLUSIVE",
                "could not locate a recorded prologue to mutate, or the control "
                "check verified %d symbols; NOT PERFORMED" % nchecked)
        else:
            orig = int(m.group(2), 16)
            mut = txt[:m.start(2)] + "0x%02X" % (orig ^ 0xFF) + txt[m.end(2):]
            write_lf(hdr, mut)
            bad_fails, _n2, _c2 = do_check(gameasm, metadec, man, hdr, [])
            write_lf(hdr, txt)
            hit = [f for f in bad_fails if "PROLOGUE MISMATCH" in f
                   and "CLEAN_ONE" in f]
            if not good_fails and hit:
                rec("prologue", "PASS",
                    "unmutated header: check PASSED with %d symbols verified "
                    "byte-for-byte; one byte flipped: check FAILED naming "
                    "CLEAN_ONE and both byte strings" % nchecked)
            else:
                rec("prologue", "FAIL",
                    "control produced %d failures (want 0); mutant produced "
                    "%d, prologue hit=%d"
                    % (len(good_fails), len(bad_fails), len(hit)))

        # -- PROOF 4: a stale stamp must be caught --------------------------
        txt = open(hdr, encoding="utf-8").read()
        mut = re.sub(r"(AOWL_SYMTAB_IMAGE_KEY\s+0x)[0-9A-F]{16}",
                     r"\g<1>DEADBEEFDEADBEEF", txt)
        write_lf(hdr, mut)
        stale_fails, _n3, _c3 = do_check(gameasm, metadec, man, hdr, [])
        write_lf(hdr, txt)
        hit = [f for f in stale_fails if "STALE TABLE" in f]
        rec("staleness", "PASS" if hit else "FAIL",
            "a header stamped with a different GameAssembly.dll is refused: %s"
            % (hit[0].split(". ")[1] if hit else "IT WAS NOT -- a Tarkov update "
               "would be used silently"))

        # -- PROOF 5: a reference to a rejected symbol from NON-C source -----
        nimf = os.path.join(d, "consumer.nim")
        write_lf(nimf, "let x = AOWL_SYM_SHARED_BAD\n")
        f5, _n5, _c5 = do_check(gameasm, metadec, man, hdr, [nimf])
        hit5 = [f for f in f5 if "consumer.nim" in f and "REJECTED" in f]
        write_lf(nimf, "let x = AOWL_SYM_CLEAN_ONE\n")
        f5b, _n6, _c6 = do_check(gameasm, metadec, man, hdr, [nimf])
        ok5 = not [f for f in f5b if "consumer.nim" in f]
        rec("source-scan", "PASS" if (hit5 and ok5) else "FAIL",
            "a .nim file referencing the rejected symbol FAILED with file+line "
            "+reason, and the same file referencing the clean symbol did not"
            if (hit5 and ok5) else
            "rejected-ref failures=%d (want >=1), clean-ref failures=%d (want 0)"
            % (len(hit5), len(f5b)))
    finally:
        shutil.rmtree(d, ignore_errors=True)

    nfail = sum(1 for _n, v, _d in results if v == "FAIL")
    ninc = sum(1 for _n, v, _d in results if v == "INCONCLUSIVE")
    print("\n%d PASS, %d FAIL, %d INCONCLUSIVE"
          % (len(results) - nfail - ninc, nfail, ninc))
    if nfail:
        return 1
    return 2 if ninc else 0


# -------------------------------------------------------------------- main

def usage():
    sys.exit(__doc__)


def main():
    if len(sys.argv) < 4:
        usage()
    cmd = sys.argv[1]
    gameasm, metadec = sys.argv[2], sys.argv[3]
    for p in (gameasm, metadec):
        if not os.path.exists(p):
            sys.exit("no such file: %s" % p)

    if cmd == "find-method":
        # The verb `il2cpp_resolve.py find` was missing: it matches TYPE names
        # only, so "which type declares SetLabelText?" had no offline answer.
        if len(sys.argv) < 5:
            usage()
        needle = sys.argv[4].lower()
        limit = int(sys.argv[5]) if len(sys.argv) > 5 else 40
        T = Table(gameasm, metadec)
        by_key, _bs, meta = T.index()
        n = 0
        for key in sorted(by_key):
            if needle not in key.rsplit("::", 1)[1].lower():
                continue
            rvas = by_key[key]
            if len(rvas) != 1:
                print("%-70s AMBIGUOUS: %d different RVAs" % (key, len(rvas)))
                continue
            rva = next(iter(rvas))
            sec, _fo, _ = T.R.section_of_rva(rva)
            own = T.counts.get(rva, 0)
            tag = ""
            if T.stub_rva is not None and rva == T.stub_rva:
                tag = "  <- UNIVERSAL STUB"
            elif own > 1:
                tag = "  <- SHARED, %d owners: call ok, DO NOT DETOUR" % own
            elif sec != CODE_SECTION:
                tag = "  <- section %s, not %s" % (sec, CODE_SECTION)
            print("%-70s 0x%08X  %-8s owners=%-5d%s" % (key, rva, sec, own, tag))
            n += 1
            if n >= limit:
                print("... stopped at %d; pass a larger limit. This is a LIMIT, "
                      "not an exhaustive answer." % limit)
                break
        if n == 0:
            print("no method name contains %r (searched all %d types)"
                  % (sys.argv[4], T.R.NTYPES))
        return 0

    if cmd == "gen":
        if len(sys.argv) < 6:
            usage()
        manifest, out_h = sys.argv[4], sys.argv[5]
        out_nim = sys.argv[6] if len(sys.argv) > 6 else None
        T = Table(gameasm, metadec)
        entries = [T.resolve_entry(e) for e in parse_manifest(manifest)]
        emit_header(T, entries, out_h, manifest)
        if out_nim:
            emit_nim(T, entries, out_nim, manifest)
        acc = [e for e in entries if not e.reject and not e.shared_call]
        shc = [e for e in entries if not e.reject and e.shared_call]
        rej = [e for e in entries if e.reject]
        print("symtab: %d symbols -- %d accepted, %d shared-call, %d rejected"
              % (len(entries), len(acc), len(shc), len(rej)))
        for e in rej:
            print("  REJECTED %-24s %-50s %s" % (e.ident, e.key, e.reject))
        for e in shc:
            print("  SHARED-CALL %-21s %-50s %d owners" % (e.ident, e.key, e.owners))
        print("wrote %s%s" % (out_h, (" and " + out_nim) if out_nim else ""))
        print("A rejected symbol is a compile error ONLY where it is "
              "referenced; `check` reports the file and line.")
        return 0

    if cmd == "verify-header":
        if len(sys.argv) < 6:
            usage()
        manifest, header = sys.argv[4], sys.argv[5]
        if not os.path.exists(header):
            print("verify-header: no %s yet -- nothing to verify. `gen` will "
                  "create it." % os.path.basename(header))
            return 0
        fails, notes, checked = do_check(gameasm, metadec, manifest, header, [],
                                         header_only=True)
        for n in notes:
            print(n)
        for f in fails:
            print(f)
        if fails:
            print("\nverify-header: %d FAILURE(S). The header ON DISK does not "
                  "describe this GameAssembly.dll. Do NOT regenerate over the "
                  "top of this until you know why -- an RVA that moved is a "
                  "wrong-but-mapped address, which is the exact corruption this "
                  "table exists to prevent." % len(fails))
            return 1
        print("verify-header: PASS -- the committed header still matches %s, "
              "%d symbol(s) compared byte-for-byte."
              % (os.path.basename(gameasm), checked))
        return 0

    if cmd == "check":
        if len(sys.argv) < 6:
            usage()
        manifest, header = sys.argv[4], sys.argv[5]
        dirs = sys.argv[6:] or [os.path.join(REPO, "abi"),
                                os.path.join(REPO, "host"),
                                os.path.join(REPO, "mods")]
        fails, notes, checked = do_check(gameasm, metadec, manifest, header, dirs)
        for n in notes:
            print(n)
        for f in fails:
            print(f)
        if fails:
            print("\nsymtab check: %d FAILURE(S). The build stops here on "
                  "purpose -- each of these is a silent client death at "
                  "runtime." % len(fails))
            return 1
        print("symtab check: PASS -- %d symbol(s) verified byte-for-byte "
              "against %s, and no consumer references a rejected or shared "
              "symbol unsafely." % (checked, os.path.basename(gameasm)))
        return 0

    if cmd == "selftest":
        return do_selftest(gameasm, metadec)

    sys.exit("unknown verb %r -- expected find-method, gen, verify-header, "
             "check or selftest"
             % cmd)


if __name__ == "__main__":
    sys.exit(main() or 0)
