#!/usr/bin/env python3
"""Byte-level literal scanning shared by `deploy.py` and `markers.py`.

This module exists because the SAME question -- "is this string really in that
built artifact?" -- is asked of the host DLL (tools/deploy.py) and of the mod
DLLs (tools/markers.py), and answering it twice means the two answers drift.
The logic below was factored OUT of deploy.py at 27e6d58, unchanged in
behaviour; deploy.py now imports it.

Two facts drive everything here, and both were measured, not assumed:

1.  DECODING THE FILE IS THE BUG. The PowerShell idiom
    `[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(p)).Contains(s)`
    returns SELECTIVE false negatives -- it decodes every byte >= 0x80 to
    U+FFFD and can split or mangle a run that `grep -a` finds in the same
    bytes. One hand-rolled use of it against the mod DLLs reported FOURTEEN
    markers missing, including a literal that predated the change under test.
    So: never decode. Encode the NEEDLE, search the RAW bytes, and report
    WHICH encoding matched.

2.  A MISS IS NOT AN ABSENCE. Nimony stores each `&`-concatenated source
    fragment as a SEPARATE rodata entry, so a sentence assembled from
    fragments never appears contiguously and no substring search at any
    encoding can match it. Hence three outcomes, never two, and hence
    `fragment_cover()`: a miss whose word-runs still cover most of the literal
    is a SPLIT, while a miss with low coverage is the shape of a removal.

Nothing in this module reads a config file or decides policy; the callers do.
"""

import re

OK = "ok"
FAIL = "fail"
INCONCLUSIVE = "inconclusive"

# Exit codes. INCONCLUSIVE must NEVER exit as success (CLAUDE.md 9b): "I could
# not look" is not a pass, and a release script that treats 3 as 0 has built
# itself a check that cannot fail.
EXIT = {OK: 0, FAIL: 1, INCONCLUSIVE: 3}

FRAGMENT_NOTE = (
    "a literal that spans a Nim `&` concatenation is stored as SEPARATE "
    "rodata fragments and can NEVER appear contiguously, at any encoding. "
    "Neither can text assembled from variables ($, %, formatIt), nor a C "
    "function name from abi/*.h (a symbol, not a runtime string). Pick a "
    "substring that lives inside ONE source fragment.")

# Below this many characters a "longest present fragment" is noise ("the ").
MIN_FRAGMENT = 6

# For `--absent`: what share of the literal has to still be present, as
# word-aligned fragments, before a non-contiguous miss is read as "this was
# merely SPLIT, not removed". Below it the leftovers are generic English
# ("the walk finished") that any binary of this size carries, and treating
# those as evidence made `--absent` unable to pass AT ALL -- a check with no
# reachable PASS is the same defect class as one with no reachable FAIL.
ABSENT_COVERAGE = 0.60


def _enc_ascii(s):
    try:
        return s.encode("ascii")
    except UnicodeEncodeError:
        return None


def _enc_utf8(s):
    return s.encode("utf-8")


def _enc_utf16(s):
    return s.encode("utf-16-le")


def _enc_latin1(s):
    try:
        return s.encode("latin-1")
    except UnicodeEncodeError:
        return None


# Order matters only for reporting. `ascii` is listed even though an
# ASCII-representable literal encodes to the SAME bytes as utf8 -- naming it
# explicitly is what makes "as ascii+utf8" readable to someone who came here
# from the PowerShell ASCII idiom and needs to see that the ASCII form was in
# fact searched for. An encoder returning None means "this literal has no
# representation in that encoding", which is skipped, not a miss.
_ALL = [("ascii", _enc_ascii), ("utf8", _enc_utf8),
        ("utf16le", _enc_utf16), ("latin1", _enc_latin1)]

_MODES = {
    "any": ["ascii", "utf8", "utf16le", "latin1"],
    # deploy.py's historical default set, kept so its output does not change.
    "deploy": ["utf8", "utf16le"],
    "ascii": ["ascii"],
    "utf8": ["utf8"],
    "utf16": ["utf16le"],
    "latin1": ["latin1"],
}


def encodings(mode):
    """(label, encoder) pairs to search for, in order. Unknown mode -> any."""
    want = _MODES.get(mode, _MODES["any"])
    return [(lbl, fn) for lbl, fn in _ALL if lbl in want]


def _needles(encs, lit):
    for lbl, fn in encs:
        b = fn(lit)
        if b:
            yield lbl, b


def find_at(blob, encs, lit):
    """(encodings that matched, lowest byte offset) of a contiguous hit.

    ([], -1) when the literal does not appear contiguously in any encoding.
    Duplicate byte-encodings (ascii and utf8 agree for ASCII text) are both
    reported, on purpose: the reader wants to know the ASCII form was tried.
    """
    hits = []
    off = -1
    for lbl, needle in _needles(encs, lit):
        i = blob.find(needle)
        if i >= 0:
            hits.append(lbl)
            if off < 0 or i < off:
                off = i
    return hits, off


def fragments(lit):
    """Contiguous whitespace-delimited word runs of `lit`, longest first.

    The whole literal is excluded (the caller already searched for it) and so
    is anything shorter than MIN_FRAGMENT. Bounded: a literal of n words
    yields n*(n+1)/2 runs, and these literals are one sentence.
    """
    parts = re.split(r"(\s+)", lit)                 # words AND separators
    runs = []
    for a in range(0, len(parts), 2):
        for b in range(a, len(parts), 2):
            frag = "".join(parts[a:b + 1])
            if frag and frag != lit and len(frag) >= MIN_FRAGMENT:
                runs.append(frag)
    runs.sort(key=len, reverse=True)
    return runs


def longest_present_fragment(blob, encs, lit):
    """(fragment, encodings) for the longest word-run of `lit` in `blob`.

    Returns (None, []) when nothing above MIN_FRAGMENT is present -- which is
    the shape of a literal that is genuinely not in the binary, as opposed to
    one that is merely split across rodata fragments.
    """
    for frag in fragments(lit):
        hits, _ = find_at(blob, encs, frag)
        if hits:
            return frag, hits
    return None, []


def fragment_cover(blob, encs, lit):
    """Greedily decompose `lit` into the longest word-aligned runs present.

    Returns (frags, covered_chars), frags as (text, encodings) in source
    order. This models the ONE thing a non-contiguous miss has to be
    distinguished from: a Nim `&` concatenation is stored as several separate
    rodata strings, so the whole sentence is missing from the bytes while
    every piece of it is present. Near-total coverage is that shape; a single
    short generic run is not.

    A miss with LOW coverage is what a genuine removal looks like, and the
    number is reported either way so the reader can judge rather than trust.
    """
    parts = re.split(r"(\s+)", lit)                 # words AND separators
    n = len(parts)
    frags = []
    covered = 0
    a = 0
    while a < n:
        best = None
        for b in range(n - 1, a - 1, -2):           # longest run at word `a`
            frag = "".join(parts[a:b + 1])
            if len(frag) < MIN_FRAGMENT or frag == lit:
                continue
            hits, _ = find_at(blob, encs, frag)
            if hits:
                best = (frag, hits, b)
                break
        if best is None:
            a += 2
            continue
        frags.append((best[0], best[1]))
        covered += len(best[0])
        a = best[2] + 2
    return frags, covered


def coverage_ratio(covered, lit):
    return (float(covered) / len(lit)) if lit else 0.0


def pick_control(blob, encs, controls):
    """The first positive control that DOES match, or None.

    A positive control is a literal already known to be in this artifact --
    for deploy.py, the artifact's own declared markers from deploy.json; for
    markers.py, the declared marker set. It is what makes an `--absent` PASS
    mean something: it proves the encoding handling, the file and the needle
    path can find text in these bytes, so "not found" is a finding and not
    merely "we could not look" (CLAUDE.md 9b).
    """
    for label, lit in controls or []:
        hits, off = find_at(blob, encs, lit)
        if hits:
            return (label, lit, hits, off)
    return None
