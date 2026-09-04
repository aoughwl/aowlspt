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
    # SAIN's member table. Keyed by STRING, not by index, so it gets the
    # `keymap` mode rather than the positional one -- see check_keymap for
    # exactly which three properties that asserts and how each can fail.
    {
        "mode": "keymap",
        "array": "sainRvaRows/sainRvaRefusals",
        "table_file": "mods/sain/client/rvatable.nim",
        "user_file": "mods/sain/client/live.nim",
    },
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
    # autoraid's PRE-MENU dismissal: ONE row today. Registered anyway, and
    # deliberately: a one-row table is exactly the table someone appends a
    # second row to later, and the coverage sweep at the bottom of this file
    # FAILS the build for an unregistered array precisely so that the second
    # row cannot arrive unguarded.
    {
        "mode": "positional",
        "header": "abi/aowlspt_premenu.h",
        "array": "aowl_pmn_targets",
        "const_prefix": "PmnT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/autoraid.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/autoraid.nim"],
        "accessors": ["cPmnFn", "cPmnName", "cPmnRva"],
        # 4 rows now: SettingsScreen::Close, Toggle::Set,
        # TweenAnimatedButton::OnPointerClick, MenuScreen::ShowInRaid.
    },
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
    # The POSTFX subtab's NATIVE row set (nativepostfx.nim): the twelve
    # appliers and getters that drive the GAME'S OWN post-processing and
    # shading. Registered the day the table was written, not the day it gained
    # its second consumer, because the coverage sweep at the bottom FAILS the
    # build for an unregistered array precisely so a later row cannot arrive
    # unguarded.
    #
    # This table is exactly the shape the check exists for. Rows [3..8] are six
    # PostFxSettingsController::TryUpdate* methods with an IDENTICAL frame
    # (RCX=this, EDX=int, R8=MethodInfo*) and different targets, so a shifted
    # constant would call a VALID, byte-verified, correctly-shaped function
    # that changes the WRONG setting -- brightness moving when the player drags
    # saturation, with every call reporting success. Nothing but this check
    # would catch that.
    {
        "mode": "positional",
        "header": "abi/aowlspt_nativepostfx.h",
        "array": "aowl_npf_targets",
        "const_prefix": "NpfT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/nativepostfx.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/nativepostfx.nim"],
        "accessors": ["cNpfFn", "cNpfName", "cNpfRva"],
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
    # The camera API's fifteen Camera/Transform accessors, indexed positionally
    # from camera.nim by the annotated CamT* constants. Getter and setter of the
    # same property sit adjacent here (get_fieldOfView/set_fieldOfView,
    # get_position/set_position, ...), which is exactly the shift that would be
    # invisible without this check: calling `set_position` with `get_position`'s
    # sret shape hands the setter a retbuf pointer where it expects `this`.
    {
        "mode": "positional",
        "header": "abi/aowlspt_camera.h",
        "array": "aowl_cam_targets",
        "const_prefix": "CamT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/camera.nim",
        "expect_file": None,
        "users": ["host/Aowlspt.Host.Il2Cpp/camera.nim"],
        "accessors": ["cCamFn", "cCamName", "cCamRva"],
    },
    # The thirty-one in-raid player-actuation targets, indexed positionally from
    # pact.nim by the annotated PactT* constants. This is the highest-stakes
    # table in the repo to get wrong: adjacent rows carry DIFFERENT calling
    # shapes on purpose -- get_Position is sret (retbuf, this, MI*) and Move is
    # (this, packed-Vector2-in-RDX, MI*) -- so a one-row shift hands a setter a
    # return buffer where it expects `this` and faults inside a perfectly valid,
    # byte-verified function. pact.nim ALSO checks the same agreement at runtime
    # by comparing the C table's name at each index against the name it calls
    # it; the two checks are deliberately independent.
    {
        "mode": "positional",
        "header": "abi/aowlspt_pact.h",
        "array": "aowl_pact_targets",
        "const_prefix": "PactT",
        "const_file": "host/Aowlspt.Host.Il2Cpp/pact.nim",
        # MEASURED 2026-09-04: this was None, so only the (c2) annotation path
        # ran and the runtime `expect` list went unchecked -- the C table grew
        # get_Rotation to 32 rows while pact.nim still named 31, and idxbind
        # exited 0. pact.nim carries BOTH bindings, so BOTH are checked here.
        "expect_file": "host/Aowlspt.Host.Il2Cpp/pact.nim",
        "users": ["host/Aowlspt.Host.Il2Cpp/pact.nim"],
        "accessors": ["cPactFn", "cPactName", "cPactRva", "pactFn"],
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
    # The in-game error-dialog catcher. A sweep, and deliberately one whose row
    # order carries NO meaning the body depends on: the argument shape (R8 is a
    # System.String on two rows and a System.Exception on the third) and the
    # reported kind are stored IN the row and read back through
    # aowl_ed_target_shape/_kind, not computed from the index. Reading an
    # Exception with the string shape would walk an object header as a UTF-16
    # length, so this is fact #187 at its worst.
    {
        "mode": "sweep",
        "header": "abi/aowlspt_errdlg.h",
        "array": "aowl_ed_targets",
        "at": "cEdTargetAt",
        "name": "cEdTargetName",
        "count": "cEdTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/errdlg.nim"],
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
        # The two AfterGameStarted subscribers that carry the TRUE deploy signal.
        # Swept, not indexed by name -- but the sweep DOES map row i to detour
        # kind 20+i, so `bindRaidStart` refuses aloud any row beyond the two
        # slots that exist rather than binding it to nothing.
        "mode": "sweep",
        "header": "abi/aowlspt_raidstart.h",
        "array": "aowl_rs_targets",
        "at": "cRsTargetAt",
        "name": "cRsTargetName",
        "count": "cRsTargetCount",
        "users": ["host/Aowlspt.Host.Il2Cpp/raidphase.nim"],
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
    if m:
        declared = int(m.group(1))
    else:
        # The other shape actually in the tree: `let expect = [ ... ]`, which
        # declares no length. MEASURED 2026-09-04: pact.nim uses exactly this,
        # so the regex above returned (None, None), check_table skipped the
        # whole comparison, and idxbind printed PASS while the C table had 32
        # rows and pact.nim named 31. A parser that silently matches nothing is
        # a check that cannot fail.
        m = re.search(r"let\s+expect\s*=\s*\[", src)
        if not m:
            return None, None
        declared = None
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


def check_keymap(t, verbose):
    """A table indexed by STRING KEY, not by position.

    `mods/sain/client/rvatable.nim` is not a C array and cannot shift an index,
    so the positional check does not apply to it. The failure it CAN have is
    the same shape one layer up: a `keyed(lazy("get_X"), "kX")` call site whose
    key names no row and no refusal binds nothing, silently, and the member
    then behaves exactly like a member nobody wired -- which is the outcome
    this whole conversion exists to abolish.

    So three properties are asserted, and each of them can fail:

      * every key used at a call site EXISTS, as a row or as a refusal;
      * no key is BOTH a row and a refusal (that would make binding depend on
        lookup order, and `resolveFromRva` deliberately prefers the refusal);
      * every declared row and refusal IS used by a call site -- an unreferenced
        row is a member somebody meant to convert and did not, and it would sit
        in the table looking converted.
    """
    src = read(t["table_file"])
    if src is None:
        inconclusive.append("%s: table file not found" % t["table_file"])
        return
    usrc = read(t["user_file"])
    if usrc is None:
        inconclusive.append("%s: user file not found" % t["user_file"])
        return

    # Two KINDS of bound row, one namespace of keys. `SainRvaRow` is a call at
    # a byte-verified RVA; `SainRvaFieldRow` is a guarded field read. They bind
    # differently and are checked identically on purpose: from the call site's
    # point of view a key either binds something or it does not, and a key that
    # is a field row AND a stated refusal is the same latent bug as a key that
    # is a call row and a stated refusal. Adding the field table to `rows` here
    # is what makes the duplicate check and the unreferenced check cover it.
    rows = (re.findall(r'SainRvaRow\(\s*key:\s*"([^"]+)"', src) +
            re.findall(r'SainRvaFieldRow\(\s*key:\s*"([^"]+)"', src))
    refs = re.findall(r'SainRvaRefusal\(\s*key:\s*"([^"]+)"', src)
    # A `keyed(...)` call site, on one line or wrapped onto two. Both forms
    # occur in live.nim and matching only the first would under-count `used`,
    # which would turn the "declared but never referenced" check below into a
    # false alarm rather than into silence -- the safe direction, but still a
    # tool telling a lie.
    used = set(re.findall(r'keyed\(.*?,\s*"([^"]+)"\)', usrc, re.S))

    if verbose:
        print("  %s: %d row(s), %d refusal(s), %d call-site key(s)"
              % (t["array"], len(rows), len(refs), len(used)))

    for dup in sorted(set(k for k in rows if rows.count(k) > 1)):
        problems.append("%s: key %r is declared as a ROW twice."
                        % (t["array"], dup))
    for dup in sorted(set(k for k in refs if refs.count(k) > 1)):
        problems.append("%s: key %r is declared as a REFUSAL twice."
                        % (t["array"], dup))
    for both in sorted(set(rows) & set(refs)):
        problems.append(
            "%s: key %r is BOTH a bound row and a stated refusal. Binding "
            "would then depend on lookup order." % (t["array"], both))

    known = set(rows) | set(refs)
    for k in sorted(used - known):
        problems.append(
            "%s:%s calls keyed(..., %r) but %s declares neither a row nor a "
            "refusal with that key. That member would bind NOTHING and refuse "
            "SILENTLY, which is the exact failure this table removes."
            % (t["user_file"], "", k, t["table_file"]))
    for k in sorted(known - used):
        problems.append(
            "%s declares %r but no keyed(...) call site in %s uses it. An "
            "unreferenced entry looks converted and is not."
            % (t["table_file"], k, t["user_file"]))
    if not rows:
        problems.append("%s: zero rows parsed out of %s -- the regex no "
                        "longer matches the table, so this check silently "
                        "passed on nothing." % (t["array"], t["table_file"]))


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
            if declared is not None and declared != len(names):
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
    # Both bindings are checked whenever both exist; the annotation check is
    # only *required* when there is no `expect` array to stand in for it.
    if True:
        ann = nim_const_annotations(csrc, t["const_prefix"])
        unannotated = sorted(k for k in consts if k not in ann)
        if unannotated and not t["expect_file"]:
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
        elif mode == "keymap":
            check_keymap(t, verbose)
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
