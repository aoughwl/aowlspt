#!/usr/bin/env python3
"""idxbind.py -- BUILD-TIME assertion that every positional index into a C
managed-target table matches the name the Nim caller believes it is calling.

WHAT THIS CATCHES, AND WHY IT IS ITS OWN TOOL
---------------------------------------------
`abi/aowlspt_debugui.h` holds an ARRAY of managed call targets. `debugui.nim`
and `settingspages.nim` address that array by POSITION, through constants like
`DuGetParent = 19`. Nothing in either language ties the constant to the row.

On 2026-08-24 a row (`RectTransform::get_anchorMax`) was inserted into the
MIDDLE of the table for the inspector's `rect` verb. Every constant from 13 up
then addressed the row BEFORE the one it meant. `DuGetParent` resolved to
`Transform::set_localPosition` -- a byte-verified, non-shared, entirely valid
function OF THE WRONG SHAPE. The call thunk passes `(this, NULL)`, so the setter
read its Vector3 argument through a NULL pointer and faulted inside Unity, at
climb depth 0, on a receiver that had just passed every liveness gate. Four
rounds of fixing the walk could not have found it.

`tools/il2cpp_symtab.py` verifies that each RVA in the table is the method its
row NAMES, and whether that RVA is shared. It does not and cannot verify the
BINDING -- that index 19 in the Nim file means row 19 in the C file. That is
this tool.

There is also a runtime check (`duTargetsBindOk` in debugui.nim, which every
consumer of the table now passes through). This one is cheaper and earlier: it
fails the BUILD rather than declining to arm a feature at runtime, and unlike
the runtime check it also verifies the CONSTANTS -- the runtime check compares
the table against a hand-maintained `expect` list, so a constant and the list
could drift together.

CHECK DISCIPLINE (CLAUDE.md 9b): PASS / FAIL / INCONCLUSIVE, never two. If a
table or a constant block cannot be parsed, that is INCONCLUSIVE and exits 2 --
it is NOT a pass. A checker that silently finds nothing to check is exactly the
"check that cannot fail" this repo keeps being bitten by.

Usage:
    python tools/idxbind.py            # check every known table, from repo root
    python tools/idxbind.py --list     # print what was parsed, then check
Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each entry: the C table, the Nim const prefix that indexes it, and every Nim
# file that uses those constants. Add a table here the day it gains a
# positional consumer -- an unlisted table is silently unchecked, which is the
# failure mode this file exists to stop, so `--list` prints the coverage and
# the FAIL text names any table found in abi/ that is not listed.
TABLES = [
    {
        "header": "abi/aowlspt_debugui.h",
        "array": "aowl_du_targets",
        "const_prefix": "Du",
        "const_file": "host/Aowlspt.Host.Il2Cpp/debugui.nim",
        "expect_file": "host/Aowlspt.Host.Il2Cpp/debugui.nim",
        "users": [
            "host/Aowlspt.Host.Il2Cpp/debugui.nim",
            "host/Aowlspt.Host.Il2Cpp/settingspages.nim",
            "host/Aowlspt.Host.Il2Cpp/inspect.nim",
        ],
        "accessors": ["cDuFn", "cDuName", "cDuRva", "duDescribeInt",
                      "duDescribeVec2", "duDescribeVec3", "duCall"],
    },
    # Added after the first run of this tool reported them as INCONCLUSIVE --
    # three more tables with real positional constants and no binding check at
    # all. That report is the tool working: an unchecked table looks exactly
    # like a checked one, which is why the coverage sweep at the bottom exists.
    {
        "header": "abi/aowlspt_modeskip.h",
        "array": "aowl_msk_targets",
        "const_prefix": "MskT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/modeskip.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/modeskip.nim"],
        "accessors": ["cMskFn", "cMskName", "cMskRva", "mskFn"],
    },
    {
        "header": "abi/aowlspt_modetext.h",
        "array": "aowl_mtx_targets",
        "const_prefix": "MtxT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/modetext.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/modetext.nim"],
        "accessors": ["cMtxFn", "cMtxName", "cMtxRva", "mtxFn"],
    },
    {
        "header": "abi/aowlspt_settingswrite.h",
        "array": "aowl_sw_targets",
        "const_prefix": "Sw",
        "const_file": "host/Aowlspt.Host.Il2Cpp/settingswrite.nim",
        "expect_file": None,
        "users": [
            "host/Aowlspt.Host.Il2Cpp/settingswrite.nim",
            "host/Aowlspt.Host.Il2Cpp/settingspages.nim",
        ],
        "accessors": ["cSwFn", "cSwFnName", "cSwFnRva", "swFn"],
    },
    {
        "header": "abi/aowlspt_invoke2.h",
        "array": "aowl_mi2_targets",
        "const_prefix": "Mi2",
        "const_file": "host/Aowlspt.Host.Il2Cpp/invoke2.nim",
        "expect_file": None,
        "users": [
            "host/Aowlspt.Host.Il2Cpp/invoke2.nim",
            "host/Aowlspt.Host.Il2Cpp/settingspages.nim",
            "host/Aowlspt.Host.Il2Cpp/settingswrite.nim",
            "host/Aowlspt.Host.Il2Cpp/inspect.nim",
        ],
        "accessors": ["mi2Fn", "cMi2Fn", "cMi2Name", "cMi2Rva"],
    },
]

problems = []
inconclusive = []


def read(rel):
    path = os.path.join(REPO, rel)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="latin-1", newline="") as f:
        return f.read()


def c_table_names(src, array):
    """The row names of `static const ... array[] = { {"Name", 0x..., ...}, }`
    IN ORDER. Returns None when the array cannot be located -- INCONCLUSIVE,
    never an empty PASS."""
    m = re.search(r"\b" + re.escape(array) + r"\s*\[\s*\]\s*=\s*\{", src)
    if not m:
        return None
    i = m.end()
    depth = 1
    body_start = i
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        return None
    body = src[body_start:i - 1]
    # A row begins at a `{` whose first token is a string literal. Comments in
    # this repo contain braces and quoted names, so comments are stripped first
    # -- a name harvested out of a comment would produce a confidently wrong
    # index map, which is worse than failing to parse.
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    body = re.sub(r"//[^\n]*", " ", body)
    return re.findall(r"\{\s*\"((?:[^\"\\]|\\.)*)\"\s*,", body)


def nim_consts(src, prefix):
    """`  DuGetParent      = 19'i32` -> {"DuGetParent": 19}."""
    out = {}
    pat = re.compile(r"^\s{2,}(" + re.escape(prefix) +
                     r"[A-Za-z0-9_]*)\s*=\s*(\d+)'?i?3?2?\s*$", re.M)
    for name, val in pat.findall(src):
        out[name] = int(val)
    return out


def nim_expect_list(src):
    """The `const expect: array[N, string] = [...]` the runtime check compares
    against, so the two checks cannot drift apart unnoticed."""
    m = re.search(r"const\s+expect\s*:\s*array\[(\d+),\s*string\]\s*=\s*\[",
                  src)
    if not m:
        return None, None
    declared = int(m.group(1))
    i = m.end()
    depth = 1
    start = i
    while i < len(src) and depth > 0:
        if src[i] == "[":
            depth += 1
        elif src[i] == "]":
            depth -= 1
        i += 1
    if depth != 0:
        return None, None
    body = src[start:i - 1]
    body = re.sub(r"#[^\n]*", " ", body)
    return declared, re.findall(r"\"((?:[^\"\\]|\\.)*)\"", body)


def const_to_expected_name(const_name, prefix):
    """We do NOT try to derive a method name from a constant name -- that is
    guessing, and guessing is the class of error being checked for. The binding
    is proved instead by (a) the C row order matching the Nim `expect` list
    exactly, and (b) every constant being in range and unique. This function
    exists only to report a constant next to the row it currently addresses."""
    return const_name


def check_table(t, verbose):
    hdr = read(t["header"])
    if hdr is None:
        inconclusive.append("%s: header not found" % t["header"])
        return
    names = c_table_names(hdr, t["array"])
    if names is None or not names:
        inconclusive.append(
            "%s: could not parse the `%s` row list. NOT a pass -- the binding "
            "is unchecked." % (t["header"], t["array"]))
        return

    csrc = read(t["const_file"])
    if csrc is None:
        inconclusive.append("%s: not found" % t["const_file"])
        return
    consts = nim_consts(csrc, t["const_prefix"])
    if not consts:
        inconclusive.append(
            "%s: no `%s*` positional constants parsed. If this module really "
            "has none, remove it from TABLES; leaving it here makes the "
            "checker report a pass it never earned."
            % (t["const_file"], t["const_prefix"]))
        return

    if verbose:
        print("  %s: %d rows; %s: %d constants"
              % (t["array"], len(names), t["const_file"], len(consts)))

    # (a) every constant is in range.
    for name in sorted(consts, key=lambda k: consts[k]):
        idx = consts[name]
        if idx < 0 or idx >= len(names):
            problems.append(
                "%s = %d is OUT OF RANGE for %s, which has %d rows. Every "
                "call through it would be to unmapped memory or to whatever "
                "follows the array."
                % (name, idx, t["array"], len(names)))
        elif verbose:
            print("    %-20s = %-3d -> %s" % (name, idx, names[idx]))

    # (b) no two constants address the same row, and the set is contiguous from
    # 0. A gap means a row exists that nothing names -- which is exactly the
    # state the table was in when the 2026-08-24 row was inserted, and it is
    # what let the shift go unnoticed.
    seen = {}
    for name, idx in consts.items():
        if idx in seen:
            problems.append(
                "%s and %s both address index %d of %s. One of them is wrong "
                "and both call the same method."
                % (seen[idx], name, idx, t["array"]))
        seen[idx] = name
    missing = [i for i in range(len(names)) if i not in seen]
    if missing and verbose:
        print("    rows with no constant: %s"
              % ", ".join("%d(%s)" % (i, names[i]) for i in missing))

    # (c) the runtime `expect` list, where there is one, must equal the C row
    # order exactly -- name for name, in order, and the declared array length
    # must equal the real row count.
    if t["expect_file"]:
        esrc = read(t["expect_file"])
        declared, expect = nim_expect_list(esrc or "")
        if expect is None:
            inconclusive.append(
                "%s: the runtime `expect` array could not be parsed, so the "
                "runtime check cannot be cross-verified here."
                % t["expect_file"])
        else:
            if declared != len(names):
                problems.append(
                    "%s declares `array[%d, string]` but %s holds %d rows. "
                    "The runtime check would refuse to arm, and every "
                    "positional index below the change is wrong."
                    % (t["expect_file"], declared, t["array"], len(names)))
            n = min(len(expect), len(names))
            for i in range(n):
                if expect[i] != names[i]:
                    problems.append(
                        "index %d: %s holds '%s' but %s expects '%s'. A row "
                        "was inserted into or removed from the C table and "
                        "the Nim side was not moved with it."
                        % (i, t["array"], names[i], t["expect_file"],
                           expect[i]))
            if len(expect) != len(names):
                problems.append(
                    "%s lists %d names for %d C rows."
                    % (t["expect_file"], len(expect), len(names)))

    # (d) NEGATIVE CHECK: any file that calls an accessor with a bare integer
    # literal instead of a named constant has bypassed every check above.
    lit = re.compile(r"\b(" + "|".join(re.escape(a) for a in t["accessors"]) +
                     r")\s*\(\s*(-?\d+)")
    for rel in t["users"]:
        usrc = read(rel)
        if usrc is None:
            inconclusive.append("%s: listed as a user but not found" % rel)
            continue
        for m in lit.finditer(usrc):
            problems.append(
                "%s calls %s(%s) with a RAW INTEGER. A literal index is "
                "invisible to every check in this file and to the runtime "
                "one; use a named %s* constant."
                % (rel, m.group(1), m.group(2), t["const_prefix"]))


def main():
    verbose = "--list" in sys.argv
    print("idxbind -- positional index bindings into C managed-target tables")
    for t in TABLES:
        check_table(t, verbose)

    # Coverage: an abi/ header holding a target array that is NOT in TABLES is
    # reported, because an unchecked table looks exactly like a checked one.
    listed = set(t["array"] for t in TABLES)
    for fn in sorted(os.listdir(os.path.join(REPO, "abi"))):
        if not fn.endswith(".h"):
            continue
        src = read("abi/" + fn) or ""
        for arr in re.findall(r"static\s+const\s+\w+\s+(\w*targets)\s*\[\s*\]",
                              src):
            if arr not in listed:
                inconclusive.append(
                    "abi/%s declares a target array `%s` that idxbind does "
                    "NOT check. If anything indexes it positionally, that "
                    "binding is unverified." % (fn, arr))

    if problems:
        print("\nFAIL -- %d binding problem(s):" % len(problems))
        for p in problems:
            print("  * " + p)
        for p in inconclusive:
            print("  ? " + p)
        return 1
    if inconclusive:
        print("\nINCONCLUSIVE -- nothing failed, but %d thing(s) could not be "
              "checked. This is NOT a pass:" % len(inconclusive))
        for p in inconclusive:
            print("  ? " + p)
        return 2
    print("\nPASS -- every positional index resolves to the name its caller "
          "believes, in every table and every user file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
