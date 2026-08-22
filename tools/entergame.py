#!/usr/bin/env python3
"""entergame.py -- get past the mode selector, unattended.

WHY THIS EXISTS
---------------
Reaching anything worth debugging -- the settings screen, the menu, a raid --
costs a human one click on a screen the client sits at forever. `--profile`
does not remove it: that flag only hands the client an auth token, and the
mode selector is a separate screen after it. So every single launch spent a
person's attention on the same click, and the whole point of the harness is
that nobody should have to watch a loading screen.

SELECT BY THE DISPLAYED TITLE, NEVER BY THE OBJECT NAME
-------------------------------------------------------
This is the entire trick, and it is not a stylistic preference. Measured on
this build, the three slots are named and labelled like this:

    CharacterSlotView_pve       ->  "PvE Zone"
    CharacterSlotView_pvp       ->  "PvE"
    CharacterSlotView_seasonal  ->  "PvP Season"

The names LIE. A script keyed on `_pve` would look obviously correct in review
and pick the right slot by luck; one keyed on `_pvp` would pick "PvE" while
reading as if it had picked PvP. So the slot is chosen by the text a person
actually sees, read live out of the TextMeshProUGUI on its Title node, and the
script says which title it matched before it presses anything.

There are TWO copies of these slots in the hierarchy -- one under `Login UI`
and one under `Menu UI` -- and on this build the LIVE one is under Menu UI.
The Login UI copy is inactive and pressing it does nothing while appearing to
succeed, which cost real time to discover. This searches Menu UI.

HOW THE PRESS WORKS
-------------------
EFT's buttons are `EFT.UI.DefaultUIButton`, which is NOT a
`UnityEngine.UI.Button` -- so Unity's Button path cannot press one. The real
event is `OnClick`, a UnityEvent at +0x120, which the inspector's `press` verb
fires. Calling `ButtonFeedback::OnPointerClick` instead plays the click SOUND
and does nothing else, which is a convincing false positive; don't.

  python tools/entergame.py                  # pick "PvE Zone"
  python tools/entergame.py --mode "PvE"
  python tools/entergame.py --list           # show the slots, press nothing

Exit codes: 0 selected (or already past it), 2 the selector was not found,
3 no title matched, 4 pressed but the selector did not close.
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspector import run_batch, Timeout  # noqa: E402

HIT = re.compile(r"HIT (0x[0-9a-fA-F]+) name=\"([^\"]*)\"")
TEXT = re.compile(r'text = "(.*)"')
ROOT = re.compile(r"\[\$r(\d+)\] transform=(0x[0-9a-fA-F]+).*name=\"([^\"]*)\"")
I32 = re.compile(r"-> i32 (-?\d+)")


def find_root(name):
    """The scene root whose name matches, as a TRANSFORM pointer."""
    out = run_batch(["roots"], timeout=40)
    for m in ROOT.finditer(out):
        if m.group(3) == name:
            return m.group(2)
    return None


def screen_active(menu):
    """Is the mode-selection screen on screen right now? 1 up, 0 gone, None unknown.

    THE TRANSFORM/GAMEOBJECT HOP IS THE WHOLE POINT OF THIS FUNCTION.
    `find` binds TRANSFORMS ($f1); `get_activeInHierarchy` is a GAMEOBJECT
    method. Calling it on a Transform does not fail -- `call` does not
    type-check its pointer arguments -- it returns a number read off the wrong
    object. That is exactly how this script first reported "still active (1)"
    for a press that had visibly worked. So: Component::get_gameObject first,
    then ask the GameObject.

    The slot objects stay in the hierarchy for the whole session, so their
    PRESENCE is not evidence of anything. This is the only honest signal.
    """
    out = run_batch(["find CharacterSelectionScreen %s 120000" % menu,
                     "call name:Component::get_gameObject p_p $f1",
                     "call name:get_activeInHierarchy i_p $_"],
                    timeout=120, write=True)
    if "HIT" not in out:
        return None
    hits = I32.findall(out)
    return int(hits[-1]) if hits else None


def slot_title(slot):
    """The text a PERSON sees on this slot, not what the object is called."""
    out = run_batch(["find Title %s 5000" % slot,
                     "component $f1 TextMeshProUGUI",
                     "label $comp"], timeout=40)
    m = TEXT.search(out)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="PvE Zone",
                    help='displayed title to select (default "PvE Zone")')
    ap.add_argument("--list", action="store_true",
                    help="print the slots and their titles, press nothing")
    ap.add_argument("--timeout", type=float, default=90.0,
                    help="seconds to wait for the selector to appear")
    a = ap.parse_args()

    deadline = time.time() + a.timeout
    menu = None
    while time.time() < deadline:
        try:
            menu = find_root("Menu UI")
        except Timeout as e:
            print("!! %s" % e, file=sys.stderr)
            return 2
        if menu:
            break
        time.sleep(3)
    if not menu:
        print("!! no `Menu UI` scene root after %gs -- the client has not got "
              "that far, or the host is not running." % a.timeout,
              file=sys.stderr)
        return 2

    # WAIT FOR THE SELECTOR TO COME UP, and do not confuse "gone" with
    # "not yet".
    #
    # `CharacterSelectionScreen` EXISTS in the hierarchy while the client is
    # still loading, and it is INACTIVE until the menu is ready. An earlier
    # version checked once and read 0, announced "already past it", and
    # returned success -- against a client that was still on its way to the
    # selector. Everything after that ran on the wrong screen: the settings
    # toggle was pressed, returned cleanly, and no settings page ever rendered,
    # because we were never in the menu at all. A wrong answer delivered
    # confidently, which is the exact failure this whole toolchain is built to
    # avoid.
    #
    # So: poll until it goes ACTIVE. Only conclude "already past" if it was
    # active at some point and then went away, or if we time out having never
    # seen it while the slots are present -- and say which of those happened.
    seen_up = False
    while time.time() < deadline:
        st = screen_active(menu)
        if st == 1:
            seen_up = True
            break
        if st is None and seen_up:
            break
        time.sleep(2)
    if not a.list and not seen_up:
        # Never observed active. Distinguish the two honest possibilities
        # instead of picking the flattering one.
        st = screen_active(menu)
        if st == 0:
            print("the mode selector never became active within %gs. Either "
                  "this session was already past it, or the client is still "
                  "loading -- those look identical from here, so nothing was "
                  "pressed. Re-run if the client was still starting."
                  % a.timeout)
            return 0
        print("!! could not determine the mode selector's state (screen not "
              "found). Nothing was pressed.", file=sys.stderr)
        return 2

    out = run_batch(["find CharacterSlotView %s 120000" % menu], timeout=120)
    slots = HIT.findall(out)
    if not slots:
        # Not an error: this is what "already past the selector" looks like,
        # and treating it as failure would make the script unusable as a
        # no-op step in a launch sequence.
        print("no mode slots under Menu UI -- already past the mode selector.")
        return 0

    titled = []
    for ptr, name in slots:
        titled.append((ptr, name, slot_title(ptr)))
    for ptr, name, title in titled:
        print("  %s  %-28s title=%s"
              % (ptr, name, ("%r" % title) if title else "<unreadable>"))
    if a.list:
        return 0

    want = a.mode.strip().lower()
    chosen = None
    for ptr, name, title in titled:
        if title and title.strip().lower() == want:
            chosen = (ptr, name, title)
            break
    if not chosen:
        print("!! no slot is titled %r. The titles present are listed above; "
              "match one of those. Object NAMES are not titles on this build "
              "(CharacterSlotView_pvp is labelled \"PvE\")." % a.mode,
              file=sys.stderr)
        return 3

    ptr, name, title = chosen
    print("selecting %r  (%s  %s)" % (title, name, ptr))
    out = run_batch(["find Apply %s 5000" % ptr,
                     "component $f1 DefaultUIButton",
                     "press $comp",
                     "wait 300"], timeout=90, write=True)
    if "returned without faulting" not in out:
        print("!! the press did not go through:\n%s" % out, file=sys.stderr)
        return 4

    # VERIFY THE EFFECT, not the call. `press` says so itself: a handler that
    # returns normally is not proof, because it acts on other objects.
    #
    # POLL, do not check once: selecting a mode is asynchronous. Checking
    # immediately reported failure on a press that had visibly worked, and a
    # false negative is not harmless -- it exits non-zero and would break any
    # launch sequence keyed on the exit code.
    deadline2 = time.time() + 25
    last = None
    while time.time() < deadline2:
        last = screen_active(menu)
        if last == 0:
            print("VERIFIED: the mode selector is closed. We are in.")
            return 0
        time.sleep(1.5)
    print("!! pressed %r, but CharacterSelectionScreen is still active (%s) "
          "after 25s -- the click handler ran and did not advance the screen."
          % (title, last), file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
