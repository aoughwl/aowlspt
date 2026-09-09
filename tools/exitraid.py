#!/usr/bin/env python
"""exitraid.py -- leave an in-progress raid and get back to the main menu,
hands-off, via the live inspector.

THE BLOCKER THIS REMOVES
------------------------
The documented manual procedure (`.claude/commands/exitraid.md`, recipe
`exit-raid-to-menu`) needed a HUMAN to press ESC first: the in-raid buttons
live on `Common UI/MenuScreen/RaidButtonsGroup`, which persists into the raid
but is INACTIVE until the ESC menu opens, and pressing an inactive control
reports success and does nothing (fact #72).

So we call the game's own opener instead of synthesising a key press:

    EFT.UI.MenuScreen::ShowInRaid()   void, arity 0
    RVA 0x1539650  (VA 0x181539650)   sharedness = UNIQUE (owners=1)
    prologue       48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48
    section        il2cpp (generated code, not .text)

    OFFLINE-DERIVED, 2026-09-01, from GameAssembly.dll + the decrypted
    global-metadata: signature from Il2CppMethodDefinition (returnType@8 =
    void, parameterCount@34 = 0), RVA from the per-image methodPointers table,
    sharedness from the methodPointers histogram. It is a real body -- not the
    build's universal empty stub (0x628110) and not a recognised thunk shape.
    NOT YET LIVE-VERIFIED -- see the report and `verdict()`.

    Only one instance argument is passed (RCX = the MenuScreen component) plus
    the hidden trailing MethodInfo* (NULL; not a shared generic). Nothing is
    detoured, so UNIQUE-vs-SHARED was only a sanity check -- calling a shared
    RVA would have been correct anyway.

Identity comes from FIELDS, not object names (names lie):
    EFT.UI.MenuScreen._disconnectButton   @ +0xC0   DefaultUIButton
    EFT.UI.MenuScreen._inGameScreenStatus @ +0x110  bool
Both offline-derived from Il2CppMetadataRegistration.fieldOffsets.
The inspector's `press` prints the button's own `_text` (+0xB8), so the log
records WHICH button was pressed -- evidence, not a claim.

EXIT CODES -- three outcomes, never two (CLAUDE.md 9b):

    0  BACK AT THE MAIN MENU, proven by the FINISHED STATE: the `Game Scene`
       scene root is inactive AND `Menu UI` is active (ui.in_raid() is False).
    1  FAIL -- a step ran and did not do what it was supposed to.
    2  INCONCLUSIVE -- we could not look. The inspector never answered, a tree
       walk was TRUNCATED, or the roots would not speak. "I could not look" is
       never a pass.
"""
import re
import sys
import time

import ui

OK, FAIL, INCONCLUSIVE = 0, 1, 2

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

# --- offline-derived constants (see the module docstring) -------------------
SHOWINRAID_RVA = "0x1539650"
# Byte-exact prologue check, so `call` REFUSES if this build is not the one
# these offsets were read from. A wrong RVA that happens to be executable is
# exactly the failure this guards against.
SHOWINRAID_SIG = "48895C240848897424105748"
OFF_DISCONNECT_BUTTON = 0xC0
OFF_INGAME_STATUS = 0x110

_HIT = re.compile(r'HIT (0x[0-9a-fA-F]+)\s+name="([^"]+)"')
_READ_PTR = re.compile(r'as ptr = (0x[0-9a-fA-F]+)')
_READ_BOOL = re.compile(r'as bool = (true|false)')
_COMP = re.compile(r'^\s*\[\d+\]\s+(\S+)\s+(0x[0-9a-fA-F]+)', re.M)


def log(m):
    print("[exitraid] " + m, flush=True)


def find_named(name, root_ptr):
    """Nodes named <name>. Returns None when the walk STOPPED EARLY -- a
    truncated walk is INCONCLUSIVE and must never read as an empty result."""
    out = ui._run(["find %s %s" % (name, root_ptr)])
    if "STOPPED EARLY" in out:
        return None
    return [m.group(1) for m in _HIT.finditer(out)]


def menuscreen_component(common_ui_t):
    """The live EFT.UI.MenuScreen COMPONENT pointer, or None.

    `find MenuScreen` is a name lookup and names lie, so the name only narrows
    candidates; identity is settled by `components`, which resolves every
    component's FULLY QUALIFIED type through the offline index and costs no
    faults (unlike `component EXPR Type`, which charges for wrong guesses).
    """
    hits = find_named("MenuScreen", common_ui_t)
    if hits is None:
        log("  find MenuScreen STOPPED EARLY -- TRUNCATED, absence proves "
            "nothing.")
        return None
    for t in hits:
        go = ui.go_of(t)
        if not go:
            continue
        out = ui._run(["components %s UnityEngine.MonoBehaviour" % go],
                      write=True)
        for tname, ptr in _COMP.findall(out):
            if tname == "EFT.UI.MenuScreen":
                return ptr
    return None


def open_in_raid_menu(ms):
    """Call MenuScreen::ShowInRaid() and PROVE the ESC menu opened.

    The proof is a property of the FINISHED STATE and is falsifiable in the
    way that matters: the DISCONNECT button's GameObject must be
    activeInHierarchy False BEFORE and True AFTER. If ShowInRaid is the wrong
    method, or lands on a stub, this says so instead of reporting the call's
    clean return as success.

    Returns (status, disconnect_button_ptr), status in
    "OPENED" / "ALREADY-OPEN" / "NO-EFFECT" / "UNKNOWN".
    """
    out = ui._run(["read %s+0x%X ptr" % (ms, OFF_DISCONNECT_BUTTON),
                   "read %s+0x%X bool" % (ms, OFF_INGAME_STATUS)])
    m = _READ_PTR.search(out)
    if not m or int(m.group(1), 16) == 0:
        log("  MenuScreen._disconnectButton (+0xC0) is NULL or unreadable -- "
            "either the offset is stale for this build or the screen has not "
            "built its buttons. Nothing was called.")
        return "UNKNOWN", None
    dbtn = m.group(1)
    b = _READ_BOOL.search(out)
    log("  _disconnectButton=%s  _inGameScreenStatus=%s"
        % (dbtn, b.group(1) if b else "?"))

    dgo = ui.go_of(dbtn)
    if not dgo:
        log("  could not reach the DISCONNECT button's GameObject.")
        return "UNKNOWN", dbtn
    before = ui.is_active(dgo)
    log("  DISCONNECT activeInHierarchy BEFORE = %s" % before)
    if before is True:
        return "ALREADY-OPEN", dbtn
    if before is None:
        return "UNKNOWN", dbtn

    out = ui._run(["allow write",
                   "call rva:%s/%s v_p %s"
                   % (SHOWINRAID_RVA, SHOWINRAID_SIG, ms),
                   "wait 400"], write=True)
    if "FAULTED" in out or "returned without faulting" not in out:
        log("  ShowInRaid() did not run cleanly:\n%s" % out[-700:])
        return "NO-EFFECT", dbtn

    if ui.wait_until(lambda: ui.is_active(dgo) is True, timeout=10.0, poll=0.5):
        return "OPENED", dbtn
    log("  ShowInRaid() returned cleanly but DISCONNECT is STILL INACTIVE. "
        "That is the false-positive shape: a clean return is not an effect.")
    return "NO-EFFECT", dbtn


def press_button(ptr, what):
    """Press a DefaultUIButton COMPONENT pointer, refusing an inactive one."""
    go = ui.go_of(ptr)
    act = ui.is_active(go) if go else None
    if act is not True:
        log("  %s: activeInHierarchy=%s -- REFUSING to press. Pressing an "
            "inactive control reports success and does nothing." % (what, act))
        return False
    out = ui._run(["press %s" % ptr, "wait 400"], write=True)
    label = re.search(r'_text\(\+0xB8\) = "([^"]*)"', out)
    log("  pressed %s (%s) label=%s"
        % (what, ptr, ('"%s"' % label.group(1)) if label else "unreadable"))
    return "FAULTED" not in out and "Nothing was called" not in out


def confirm_leave():
    """CONFIRM LEAVE -- Common UI/ReconnectionScreen/LeaveButton.
    True / False / None, where None is TRUNCATED (inconclusive)."""
    hits, complete = ui.find_text("CONFIRM LEAVE", root="Common UI")
    if not hits:
        if not complete:
            log("  CONFIRM LEAVE: the walk was TRUNCATED -- absence proves "
                "nothing.")
            return None
        log("  CONFIRM LEAVE: 0 hits on a COMPLETE walk of Common UI.")
        return False
    b = ui.button_for(hits[0]["t"])
    if not b:
        log("  CONFIRM LEAVE has no pressable component on it or its "
            "ancestors.")
        return False
    ok, _ = ui.actuate(b["at"], b["type"])
    log("  CONFIRM LEAVE pressed via %s -> fired=%s" % (b["type"], ok))
    return ok


def press_next_pages(rounds=6):
    """The post-raid results pages. `Session End UI` is a scene root that does
    not exist until the raid is left; Common UI has no NEXT, so 0 hits there
    would be WRONG TREE, not a missing control. The NextButton GameObject is
    REBUILT on each page, so re-find it every round rather than reusing a
    pointer."""
    for i in range(rounds):
        try:
            rs = ui.roots()
        except Exception:
            time.sleep(2.0)
            continue
        if "Session End UI" not in rs:
            if ui.in_raid() is False:
                return True                       # already home
            time.sleep(2.0)
            continue
        hits, complete = ui.find_text("NEXT", root="Session End UI")
        if not hits:
            if not complete:
                log("  page %d: the NEXT walk was TRUNCATED" % i)
            time.sleep(2.0)
            continue
        b = ui.button_for(hits[0]["t"])
        if not b:
            time.sleep(2.0)
            continue
        ok, _ = ui.actuate(b["at"], b["type"])
        log("  results page %d: NEXT -> fired=%s" % (i, ok))
        time.sleep(2.0)
        if ui.in_raid() is False:
            return True
    return False


def verdict():
    """THE deliverable. Assert the finished state, never our own action.

    ui.in_raid() is built only from positively-observed scene-root activity:
    True  = `Game Scene` is active.
    False = `Game Scene` is inactive AND `Menu UI` is active.
    None  = neither root spoke -- reported as UNKNOWN, never rounded to False.
    """
    st = ui.in_raid()
    if st is False:
        return OK, "BACK AT THE MAIN MENU (Game Scene inactive, Menu UI active)."
    if st is True:
        return FAIL, "STILL IN THE RAID (Game Scene is active)."
    return INCONCLUSIVE, ("UNKNOWN: neither `Game Scene` nor `Menu UI` "
                          "answered, so where the client is was NOT "
                          "established.")


def main():
    try:
        rs = ui.roots()
    except Exception as e:
        log("INCONCLUSIVE: the inspector did not answer (%s). Nothing about "
            "the raid was established." % e)
        try:
            state, note = ui.channel_verdict()
            log("  channel: %s -- %s" % (state, note))
        except Exception:
            pass
        return INCONCLUSIVE

    st = ui.in_raid()
    if st is False:
        log("already at the main menu; nothing to do.")
        return OK
    if st is None:
        log("INCONCLUSIVE: could not establish whether the client is in a "
            "raid, so leaving one is not something to attempt blind.")
        return INCONCLUSIVE

    cu = rs.get("Common UI", {}).get("t")
    if not cu:
        log("INCONCLUSIVE: no `Common UI` scene root. Roots present: %s"
            % ", ".join(sorted(rs)))
        return INCONCLUSIVE

    log("in a raid. Locating the live MenuScreen component ...")
    ms = menuscreen_component(cu)
    if not ms:
        log("INCONCLUSIVE: no EFT.UI.MenuScreen component found under "
            "Common UI, so the opener had nothing to be called on.")
        return INCONCLUSIVE
    log("MenuScreen component = %s" % ms)

    status, dbtn = open_in_raid_menu(ms)
    log("open-in-raid-menu: %s" % status)
    if status == "UNKNOWN":
        return INCONCLUSIVE
    if status == "NO-EFFECT":
        log("FAIL: the ESC menu did not open, so DISCONNECT is not pressable.")
        return FAIL

    if not press_button(dbtn, "DISCONNECT"):
        return FAIL
    time.sleep(1.0)

    cl = confirm_leave()
    if cl is None:
        return INCONCLUSIVE
    if not cl:
        return FAIL

    press_next_pages()
    code, msg = verdict()
    log(("OK: " if code == OK else
         "FAIL: " if code == FAIL else "INCONCLUSIVE: ") + msg)
    return code


def selftest():
    """Prove the exit codes cannot collapse to 0. Falsifiable by construction:
    each case forces a specific observable state and demands a specific code.
    No live client is touched."""
    bad = 0

    def case(label, got, want):
        nonlocal bad
        ok = (got == want)
        if not ok:
            bad += 1
        print("%-4s %-56s want=%-3s got=%s"
              % ("ok" if ok else "FAIL", label[:56], want, got))

    g = globals()
    saved = {k: g.get(k) for k in
             ("menuscreen_component", "open_in_raid_menu", "press_button",
              "confirm_leave", "press_next_pages")}
    r_roots, r_inraid = ui.roots, ui.in_raid
    seq = []
    try:
        ui.roots = lambda *a, **k: {"Common UI": {"t": "0x1", "go": "0x2"}}

        ui.in_raid = lambda *a, **k: None
        case("in_raid UNKNOWN -> INCONCLUSIVE (2)", main(), INCONCLUSIVE)

        ui.in_raid = lambda *a, **k: False
        case("already at the menu -> OK (0)", main(), OK)

        ui.in_raid = lambda *a, **k: True
        g["menuscreen_component"] = lambda cu: None
        case("no MenuScreen component -> INCONCLUSIVE (2)",
             main(), INCONCLUSIVE)

        g["menuscreen_component"] = lambda cu: "0xAA"
        g["open_in_raid_menu"] = lambda ms: ("NO-EFFECT", "0xBB")
        case("ShowInRaid ran but the menu stayed shut -> FAIL (1)",
             main(), FAIL)

        g["open_in_raid_menu"] = lambda ms: ("OPENED", "0xBB")
        g["press_button"] = lambda p, w: False
        case("DISCONNECT inactive / refused -> FAIL (1)", main(), FAIL)

        g["press_button"] = lambda p, w: True
        g["confirm_leave"] = lambda: None
        case("CONFIRM LEAVE walk TRUNCATED -> INCONCLUSIVE (2)",
             main(), INCONCLUSIVE)

        # The case that keeps the rest honest: every press "works", but the
        # FINISHED STATE still says we are in the raid. A script that asserted
        # its own actions instead of the end state would return 0 here.
        g["confirm_leave"] = lambda: True
        g["press_next_pages"] = lambda rounds=6: True
        case("every press 'worked' but still in raid -> FAIL (1)",
             main(), FAIL)

        ui.in_raid = lambda *a, **k: (seq.pop(0) if seq else False)
        seq[:] = [True]
        case("in raid, steps work, ends at the menu -> OK (0)", main(), OK)
    finally:
        ui.roots, ui.in_raid = r_roots, r_inraid
        g.update(saved)

    print("\n%s: %d case(s) failed" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
