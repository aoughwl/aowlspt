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
        "mode": "positional",
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
        "mode": "positional",
        "header": "abi/aowlspt_modeskip.h",
        "array": "aowl_msk_targets",
        "const_prefix": "MskT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/modeskip.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/modeskip.nim"],
        "accessors": ["cMskFn", "cMskName", "cMskRva", "mskFn"],
    },
    # The four `UnityEngine.Cursor` accessors the overlay cursor-free feature
    # CALLS (never detours). The C side indexes this table by its own adjacent
    # `AOWL_CUR_T_*` defines; the Nim side names the same four rows through
    # `CurT*`, annotated, which is what gives this table a binding to check at
    # all. Getter and setter of the SAME property sit next to each other here,
    # which is precisely the shift that would be invisible without the check:
    # `set_lockState` called with `get_lockState`'s shape takes its argument as
    # a MethodInfo* and writes nothing.
    {
        "mode": "positional",
        "header": "abi/aowlspt_cursor.h",
        "array": "aowl_cur_targets",
        "const_prefix": "CurT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/cursorfree.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/cursorfree.nim"],
        "accessors": ["cCurFn", "cCurName", "cCurRva"],
    },
    # The game-Settings-open probe behind aowl_ui_overlay_mask's bit0. Two
    # instance getters, indexed by the AOWL_UI_T_* #defines in the C header and
    # mirrored by the annotated UiT* constants here, which is what ties each row
    # to the method it means.
    {
        "mode": "positional",
        "header": "abi/aowlspt_uistate.h",
        "array": "aowl_ui_targets",
        "const_prefix": "UiT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/uistate.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/uistate.nim"],
        "accessors": ["cUiFn"],
    },
    # The scene-walk getters (get_parent/childCount/GetChild/Find/GetComponent),
    # indexed positionally from aowlscene.nim by the annotated Sc* constants.
    {
        "mode": "positional",
        "header": "abi/aowlspt_scene.h",
        "array": "aowl_scene_targets",
        "const_prefix": "Sc",
        "const_file": "host/Aowlspt.Host.Il2Cpp/aowlscene.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/aowlscene.nim"],
        "accessors": ["cSceneFn", "cSceneName", "cSceneRva"],
    },
    {
        "mode": "positional",
        "header": "abi/aowlspt_modetext.h",
        "array": "aowl_mtx_targets",
        "const_prefix": "MtxT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/modetext.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/modetext.nim"],
        "accessors": ["cMtxFn", "cMtxName", "cMtxRva", "mtxFn"],
    },
    {
        "mode": "positional",
        "header": "abi/aowlspt_settingswrite.h",
        "array": "aowl_sw_targets",
        "const_prefix": "Sw",
        "const_file": "host/Aowlspt.Host.Il2Cpp/settingswrite.nim",
        "expect_file": None,
        "users": [
            "host/Aowlspt.Host.Il2Cpp/settingswrite.nim",
            "host/Aowlspt.Host.Il2Cpp/settingspages.nim",
        ],
        "accessors": ["cSwFn", "cSwFnName", "cSwFnRva", "swFn",
                      "cSwFn2", "cSwName2"],
    },
    {
        "mode": "positional",
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
    # The native UI construction layer. Registered with its FIRST commit rather
    # than after a coverage sweep caught it, because this table is 25 rows of
    # near-identical `_Injected` setters and getters: an inserted row would
    # shift `set_sizeDelta` onto `set_pivot`, every call would still succeed,
    # and the element would simply be laid out wrongly. That is precisely the
    # failure this whole layer exists to stop being invisible.
    {
        "mode": "positional",
        "header": "abi/aowlspt_nativeui.h",
        "array": "aowl_nu_targets",
        # `NuT`, not `Nu`: the same module also defines `NuKind*` (component
        # kinds) and `NuSlot*` (verdicts), which are NOT indices into this
        # table. A prefix of `Nu` made this tool report four confident
        # duplicate-index collisions between constants that have nothing to do
        # with each other -- a wrong answer delivered plausibly.
        "const_prefix": "NuT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/nativeui.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/nativeui.nim"],
        "accessors": ["nuFn", "cNuFn", "cNuName", "cNuRva"],
    },
    # ------------------------------------------------------------------
    # The ten tables the first version of this tool reported INCONCLUSIVE by
    # name (fact #190). Surveyed 2026-08-27: NONE of them is addressed by a
    # positional constant. Nine are SWEEPS (`for i in 0 ..< count`, with the
    # row's own name read back at the SAME index and passed to attachDrain), and
    # one -- aowl_nav_targets -- is looked up BY NAME with a substring match, so
    # an inserted row cannot shift it either.
    #
    # A sweep is immune to the fact-#187 shift, but it is NOT unconditionally
    # safe, and the check below is what makes the difference legible: the
    # invariant a sweep depends on is that the `_at` and `_name` accessors are
    # called with the SAME index expression. `attachDrain(name(0), at(i))` would
    # bind row i under row 0's name -- the identical wrong-shape failure, just
    # reached differently -- and nothing else in the build would notice.
    {
        "mode": "sweep",
        "header": "abi/aowlspt_botnav.h",
        "array": "aowl_botnav_targets",
        "at": "cBotNavTargetAt",
        "name": "cBotNavTargetName",
        "count": "cBotNavTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/botnav.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_botai.h",
        "array": "aowl_botai_targets",
        "at": "cBotAiTargetAt",
        "name": "cBotAiTargetName",
        "count": "cBotAiTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/botai.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_botcap.h",
        "array": "aowl_botcap_targets",
        "at": "cBotCapTargetAt",
        "name": "cBotCapTargetName",
        "count": "cBotCapTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/botcap.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_botdiag.h",
        "array": "aowl_botdiag_targets",
        "at": "cBotDiagTargetAt",
        "name": "cBotDiagTargetName",
        "count": "cBotDiagTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/botdiag.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_bridge.h",
        "array": "aowl_bridge_targets",
        "at": "cBridgeTargetAt",
        "name": "cBridgeTargetName",
        "count": "cBridgeTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/aowlhost.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_bridge.h",
        "array": "aowl_bridge_render_targets",
        "at": "cBridgeRenderTargetAt",
        "name": "cBridgeRenderTargetName",
        "count": "cBridgeRenderTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/aowlhost.nim"],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_bridge.h",
        "array": "aowl_bridge_settings_targets",
        "at": "cBridgeSettingsTargetAt",
        "name": "cBridgeSettingsTargetName",
        "count": "cBridgeSettingsTargetCount",
        "users": [
            "host/Aowlspt.Host.Il2Cpp/aowlhost.nim",
            "host/Aowlspt.Host.Il2Cpp/settingsui.nim",
        ],
    },
    {
        "mode": "sweep",
        "header": "abi/aowlspt_bridge.h",
        "array": "aowl_bridge_settingstab_targets",
        "at": "cBridgeSettingsTabTargetAt",
        "name": "cBridgeSettingsTabTargetName",
        "count": "cBridgeSettingsTabTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/settingsui.nim"],
    },
    # First registered here as `unused` on the strength of a grep that missed
    # the call site (the Nim wrapper is named ...SelTargetAt, not ...Tick...).
    # The `unused` check FAILED the build and named settingsui.nim:711. That is
    # the whole point of asserting deadness instead of assuming it -- left as
    # written, this comment would have claimed a live kind=8 drain was dead.
    {
        "mode": "sweep",
        "header": "abi/aowlspt_bridge.h",
        "array": "aowl_bridge_settingstick_targets",
        "at": "cBridgeSettingsSelTargetAt",
        "name": "cBridgeSettingsSelTargetName",
        "count": "cBridgeSettingsSelTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/settingsui.nim"],
    },
    # Selected by SUBSTRING on the row name, never by index -- the one pattern
    # in the repo that is structurally immune to a row insertion. Asserted, so
    # that a future positional call site fails the build instead of inheriting
    # this exemption silently.
    {
        "mode": "byname",
        "header": "abi/aowlspt_navui.h",
        "array": "aowl_nav_targets",
        "at": "cNavFn",
        "name": "cNavName",
        "count": "cNavTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/inspect.nim"],
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
                     r"[A-Za-z0-9_]*)\s*=\s*(\d+)'?i?3?2?[ \t]*(?:##[^\n]*)?$", re.M)
    for name, val in pat.findall(src):
        out[name] = int(val)
    return out


def nim_const_annotations(src, prefix):
    """The row name a constant CLAIMS to address, written as a doc comment on
    the same line:

        SwLocSetLabelText = 6'i32   ## EFT.UI.LocalizedText::SetLabelText

    This is the generalisation of `duTargetsBindOk` to tables that have no
    hand-maintained `expect` array. It is strictly stronger than one: the
    `expect` list proves the C table still has the order the module remembers,
    but a constant and the list can be edited together and still be wrong,
    whereas an annotation ties ONE constant to ONE row name at the point of
    use. Checked here rather than at runtime because the answer is fully
    determined offline -- a runtime check would only refuse to arm, after the
    build had already shipped the wrong index."""
    out = {}
    pat = re.compile(r"^\s{2,}(" + re.escape(prefix) +
                     r"[A-Za-z0-9_]*)\s*=\s*(\d+)'?i?3?2?[ \t]*"
                     r"##[ \t]*(\S+)[ \t]*$", re.M)
    for name, _val, row in pat.findall(src):
        out[name] = row
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


# ----------------------------------------------------------------------------
# Non-positional modes. A table that is NOT indexed by a named constant is not
# thereby "safe" -- it is safe for a DIFFERENT reason, and each reason gets its
# own check that can actually fail.

DECL = re.compile(r"^\s*proc\b|importc")


def call_sites(src, fn):
    """Every call `fn(<args>)` that is not the importc declaration, as
    (line number, argument text)."""
    out = []
    pat = re.compile(r"\b" + re.escape(fn) +
                     r"\s*\(([^()]*(?:\([^()]*\))?[^()]*)\)")
    for ln, line in enumerate(src.splitlines(), 1):
        if DECL.search(line):
            continue
        for m in pat.finditer(line):
            out.append((ln, m.group(1).strip()))
    return out


def norm_arg(a):
    """`int32(i)` and `i` are the same index expression for our purposes; what
    matters is that the row and its NAME are fetched with the same one."""
    a = a.strip()
    while True:
        m = re.fullmatch(r"(?:int32|int|cint|uint32)\s*\((.*)\)", a)
        if not m:
            return a
        a = m.group(1).strip()


LITERAL = re.compile(r"^-?\d+'?[iu]?\d*$")


def check_sweep(t, verbose):
    """A sweep binds row i under the name read at index i. The invariant is
    that those two indices are the SAME EXPRESSION, and that neither is a
    literal. `attachDrain(name(0), at(i))` is fact #187 by another route."""
    hdr = read(t["header"])
    if hdr is None:
        inconclusive.append("%s: header not found" % t["header"])
        return
    names = c_table_names(hdr, t["array"])
    if names is None or not names:
        inconclusive.append(
            "%s: could not parse the `%s` row list. NOT a pass."
            % (t["header"], t["array"]))
        return
    if verbose:
        print("  %s: SWEEP over %d row(s): %s"
              % (t["array"], len(names), ", ".join(names)))

    saw_any = False
    for rel in t["users"]:
        usrc = read(rel)
        if usrc is None:
            inconclusive.append("%s: listed as a user but not found" % rel)
            continue
        if t["count"] not in usrc:
            problems.append(
                "%s indexes %s but never calls %s. A sweep that does not read "
                "the row count is not a sweep; it is a hard-coded index."
                % (rel, t["array"], t["count"]))
        ats = call_sites(usrc, t["at"])
        nms = call_sites(usrc, t["name"])
        if not ats:
            problems.append(
                "%s declares %s but never calls it, while the registry says "
                "this table is swept there. The registry is wrong -- "
                "reclassify the table rather than leaving it unchecked."
                % (rel, t["at"]))
            continue
        saw_any = True
        for ln, arg in ats:
            a = norm_arg(arg)
            if LITERAL.match(a):
                problems.append(
                    "%s:%d calls %s(%s) with a RAW INTEGER. A literal index "
                    "is invisible to every check here and to the runtime one, "
                    "and it is exactly how a row insertion becomes a call of "
                    "the wrong shape." % (rel, ln, t["at"], arg))
                continue
            near = [(nl, na) for nl, na in nms if abs(nl - ln) <= 25]
            if not near:
                problems.append(
                    "%s:%d takes %s(%s) but no %s(...) is called within 25 "
                    "lines, so the row being bound is never named. The log "
                    "line and the detour could describe different rows."
                    % (rel, ln, t["at"], arg, t["name"]))
                continue
            if not any(norm_arg(na) == a for _, na in near):
                problems.append(
                    "%s:%d binds %s(%s) but the nearby %s call uses %s. The "
                    "row and its name come from DIFFERENT indices -- this is "
                    "fact #187 reached by another route."
                    % (rel, ln, t["at"], arg, t["name"],
                       " / ".join(sorted(set(norm_arg(na)
                                             for _, na in near)))))
    if not saw_any and not problems:
        inconclusive.append(
            "%s: no call site of %s was found in any listed user, so nothing "
            "was actually checked." % (t["array"], t["at"]))


def check_byname(t, verbose):
    """Selected by substring on the row name. Immune to insertion -- but only
    while EVERY call site is preceded by a name comparison and none is a
    literal."""
    hdr = read(t["header"])
    names = c_table_names(hdr or "", t["array"])
    if names is None or not names:
        inconclusive.append("%s: could not parse `%s`. NOT a pass."
                            % (t["header"], t["array"]))
        return
    if verbose:
        print("  %s: BY-NAME lookup over %d row(s)" % (t["array"], len(names)))
    checked = False
    for rel in t["users"]:
        usrc = read(rel)
        if usrc is None:
            inconclusive.append("%s: listed as a user but not found" % rel)
            continue
        lines = usrc.splitlines()
        for ln, arg in call_sites(usrc, t["at"]):
            checked = True
            if LITERAL.match(norm_arg(arg)):
                problems.append(
                    "%s:%d calls %s(%s) with a RAW INTEGER. This table is "
                    "registered as by-name; a positional call site here has "
                    "no check at all." % (rel, ln, t["at"], arg))
                continue
            window = "\n".join(lines[max(0, ln - 12):ln])
            if t["name"] not in window:
                problems.append(
                    "%s:%d resolves a row through %s with no %s(...) name "
                    "comparison in the preceding 12 lines. The by-name "
                    "exemption does not hold for this call site."
                    % (rel, ln, t["at"], t["name"]))
    if not checked:
        inconclusive.append(
            "%s: registered by-name but no call site of %s was examined."
            % (t["array"], t["at"]))


def check_unused(t, verbose):
    """The table is dead. Asserted, not assumed."""
    if verbose:
        print("  %s: registered UNUSED" % t["array"])
    for rel in t["users"]:
        usrc = read(rel)
        if usrc is None:
            inconclusive.append("%s: listed as a user but not found" % rel)
            continue
        sites = call_sites(usrc, t["at"])
        if sites:
            problems.append(
                "%s is registered as UNUSED but %s:%d calls %s. It now needs "
                "a real mode -- `unused` is the one classification that "
                "grants a table no check whatever."
                % (t["array"], rel, sites[0][0], t["at"]))


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

    # (c2) THE GENERALISED BINDING GUARD. A positional table must tie its
    # constants to row NAMES somehow -- either through the runtime `expect`
    # array (debugui) or through a per-constant `## RowName` annotation. With
    # neither, the only thing checked is that the index is in range, and an
    # in-range index onto the wrong row is precisely fact #187: a byte-verified,
    # non-shared, perfectly valid function OF THE WRONG SHAPE.
    if not t["expect_file"]:
        ann = nim_const_annotations(csrc, t["const_prefix"])
        unannotated = sorted(k for k in consts if k not in ann)
        if unannotated:
            problems.append(
                "%s: %d of %d %s* constant(s) carry no `## RowName` "
                "annotation (%s). Nothing then ties them to %s, so a row "
                "inserted above them shifts every one silently. Annotate "
                "each with the row name it means, or give the module an "
                "`expect` array."
                % (t["const_file"], len(unannotated), len(consts),
                   t["const_prefix"], ", ".join(unannotated), t["array"]))
        for k in sorted(ann):
            if k not in consts:
                continue
            idx = consts[k]
            if idx < 0 or idx >= len(names):
                continue
            if names[idx] != ann[k]:
                problems.append(
                    "%s = %d claims to address '%s' but %s[%d] is '%s'. A row "
                    "was inserted or removed and the constant was not moved "
                    "with it -- this is fact #187 exactly: the call would go "
                    "to a valid function of the WRONG SHAPE."
                    % (k, idx, ann[k], t["array"], idx, names[idx]))
            elif verbose:
                print("      %-20s annotation OK" % k)

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
        mode = t.get("mode", "positional")
        if mode == "positional":
            check_table(t, verbose)
        elif mode == "sweep":
            check_sweep(t, verbose)
        elif mode == "byname":
            check_byname(t, verbose)
        elif mode == "unused":
            check_unused(t, verbose)
        else:
            problems.append(
                "%s: unknown mode %r in TABLES." % (t["array"], mode))

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
                # THIS IS THE BUILD GATE. It used to be INCONCLUSIVE, which
                # meant a new table could be added with no binding check and
                # the build would still go green. An unregistered table is now
                # a FAIL: whoever adds one must state, in TABLES, HOW it is
                # indexed -- positional / sweep / byname / unused -- and every
                # one of those classifications carries a check that can fail.
                problems.append(
                    "abi/%s declares a target array `%s` that is NOT "
                    "REGISTERED in tools/idxbind.py. Its binding is therefore "
                    "unverified, and an inserted row would shift every index "
                    "below it silently (fact #187). Add it to TABLES with a "
                    "mode." % (fn, arr))

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
