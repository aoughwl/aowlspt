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

SELECT THE CARD THAT SHOWS THE PLAYER'S PROFILE, NOT THE ONE WITH THE TITLE
--------------------------------------------------------------------------
This script used to choose by the DISPLAYED TITLE, on the reasoning that the
object names lie (they do). Measured 2026-09-02, so does the title. The three
cards on this build are:

    CharacterSlotView_pve       title "PvE Zone"    -- EMPTY
    CharacterSlotView_pvp       title "PvE"         -- InfoPart: Savant | 3
    CharacterSlotView_seasonal  title "New Text"    -- placeholder

The tool printed `selecting 'PvE Zone' (CharacterSlotView_pve ...)`, pressed
the EMPTY card, and exited 4 with the screen unchanged. Both keys available on
screen -- the object name AND the title -- name a MODE. Neither says which card
carries a profile you can actually enter the game with, and there is nothing in
either that could have made the wrong pick fail loudly.

What DOES identify the right card is the player's nickname, which the card
renders in its InfoPart. The host log states that nickname for this launch:

    skip mode screen: slot 2 gameMode=0 profileId=00000000000a00000000004f
                      nickname="Savant" status=2 side=1
    skip mode screen: slot for profile 00000000000a00000000004f ("Savant",
                      gameMode=0) matches launchProfileId; ...

So: read the launch profile's nickname out of the host log, ask the LIVE screen
which card displays it (`findtext`, which searches the text a control shows),
and press that one. The title is a fallback used only when the host log cannot
name a nickname at all, and it says loudly that it is guessing. If a nickname
is known and no card shows it, this REFUSES (exit 2) and names every card it
saw -- an empty card pressed by mistake looks exactly like a success from the
call's point of view, and the finished-state check afterwards is 25 seconds
later.

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

MEASURED on the 4,851,200 build, the census under the screen is
`CharacterSlotView_* -> BgGlow/BgImage/BgSide/View/InfoPart` and there is **no
active `Apply` node** -- the CARD itself is the control. So the `Apply` press
is tried first (older builds have it) and the CARD is pressed when it is
absent; the script says which path it took, and the finished-state check is the
same either way.

  python tools/entergame.py                  # the card showing this profile
  python tools/entergame.py --mode "PvE"     # force a title (fallback path)
  python tools/entergame.py --list           # show the slots, press nothing
  python tools/entergame.py --selftest       # offline; presses nothing

Exit codes: 0 selected (or already past it), 2 the selector was not found or
the right card could not be identified, 3 no title matched (fallback path),
4 pressed but the selector did not close.
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspector import run_batch, Timeout  # noqa: E402
import ichannel as ch  # noqa: E402 -- the SHARED find/findtext parsers

HIT = re.compile(r"HIT (0x[0-9a-fA-F]+) name=\"([^\"]*)\"")
TEXT = re.compile(r'text = "(.*)"')
ROOT = re.compile(r"\[\$r(\d+)\] transform=(0x[0-9a-fA-F]+).*name=\"([^\"]*)\"")
I32 = re.compile(r"-> i32 (-?\d+)")

HOST_LOG = os.path.join("D:\\", "Aowlspt", "aowlspt", "aowlspt-host.log")

# The host's first line of a boot. Everything above the LAST one belongs to a
# previous run of the client -- a nickname from that run would name a profile
# this launch never selected.
HOST_BANNER_PREFIX = "aowlspt-host-il2cpp "

# modeskip.nim's two shapes. The first is authoritative: the host has already
# matched that slot against the launchProfileId it was given. The second is the
# per-slot census, used only when the first is absent.
LAUNCH_NICK = re.compile(
    r'skip mode screen: slot for profile \S+ \("([^"]*)"[^)]*\)'
    r'\s*matches launchProfileId')
SLOT_NICK = re.compile(r'skip mode screen: slot \d+ .*nickname="([^"]*)"')


def launch_nickname(text):
    """The launch profile's nickname, from host-log TEXT. -> (nick, how).

    `nick` is None when the log cannot name one, and `how` always says why --
    a caller that silently fell back to titles here is how the empty card got
    pressed in the first place.

    Restarts at the LAST host banner: a nickname from an earlier boot of the
    client describes a profile this launch may not have been given.
    """
    lines = text.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith(HOST_BANNER_PREFIX):
            lines = lines[i:]
            break
    matched = None
    census = []
    for line in lines:
        m = LAUNCH_NICK.search(line)
        if m:
            matched = m.group(1)          # last wins: the most recent showing
            continue
        m = SLOT_NICK.search(line)
        if m and m.group(1).strip():
            if m.group(1) not in census:
                census.append(m.group(1))
    if matched:
        return matched, ("the host matched it against launchProfileId "
                         "(`slot for profile ... matches launchProfileId`)")
    if len(census) == 1:
        return census[0], ("exactly one slot in the host's own census carries "
                           "a nickname (`skip mode screen: slot N ... "
                           "nickname=`)")
    if len(census) > 1:
        return None, ("the host's slot census names %d nicknames (%s) and no "
                      "`matches launchProfileId` line says which one this "
                      "launch asked for" % (len(census), ", ".join(census)))
    return None, ("the host log names no profile nickname at all -- no `skip "
                  "mode screen: slot N ... nickname=` line since the last host "
                  "banner")


def read_host_log(path=HOST_LOG, max_bytes=8 * 1024 * 1024):
    """The host log as text, bounded. It is a measured token bomb; this is
    never printed, only regex-scanned."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(max_bytes)
    except OSError:
        return ""


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


def card_shows(slot, nick, timeout=90):
    """Does THIS card display `nick`? True / False / None -- never two-state.

    `findtext` searches the text a control renders, rooted at this card, ACTIVE
    nodes only (an inactive hit is not pressable -- fact #72). Parsed with the
    SHARED parser in ichannel, because a private HIT regex here was already the
    documented cause of every findtext answer reading as zero hits elsewhere.

    None means the search could not settle the question -- STOPPED EARLY, hit
    cap, nothing examined, or a channel timeout. A card that could not be read
    must never be indistinguishable from a card that does not carry the name.
    """
    if '"' in nick:
        return None
    try:
        raw = run_batch(['findtext "%s" %s 20000' % (nick, slot)], timeout=timeout)
    except Timeout:
        return None
    f = ch.parse_findtext(raw)
    if f["hits"]:
        return True
    if f["can_trust_absence"]:
        return False
    return None


def choose_card(titled, nick, shows, want_title):
    """Which card to press. PURE -- no inspector, no host log, so it is testable.

    `titled`  [(ptr, name, title), ...] as printed by --list
    `nick`    the launch profile's nickname, or None
    `shows`   {ptr: True/False/None} from card_shows, empty when nick is None
    `want_title` the --mode fallback title, or None

    -> (chosen_or_None, exit_code, message). exit_code is meaningful only when
    `chosen` is None; message is always printed.
    """
    def desc(t):
        return "%s %-28s title=%s%s" % (
            t[0], t[1], ("%r" % t[2]) if t[2] else "<unreadable>",
            "" if not shows else "  shows-profile=%s" % (
                {True: "yes", False: "no", None: "UNREADABLE"}[shows.get(t[0])]))

    census = "\n".join("    " + desc(t) for t in titled)

    if nick:
        yes = [t for t in titled if shows.get(t[0]) is True]
        unknown = [t for t in titled if shows.get(t[0]) is None]
        if len(yes) == 1:
            return (yes[0], 0,
                    "selecting the card that DISPLAYS %r: %s (%s), title %r"
                    % (nick, yes[0][1], yes[0][0], yes[0][2]))
        if len(yes) > 1:
            return (None, 2,
                    "REFUSED: %d cards display %r, so the profile does not "
                    "identify one card. Nothing was pressed.\n%s"
                    % (len(yes), nick, census))
        if unknown:
            return (None, 2,
                    "REFUSED: no card was found to display %r, and %d card(s) "
                    "could not be read at all -- that is INCONCLUSIVE, not a "
                    "negative. Nothing was pressed.\n%s"
                    % (nick, len(unknown), census))
        return (None, 2,
                "REFUSED: the launch profile is %r and NO card on screen "
                "displays it. Pressing a card by its title would press an "
                "EMPTY slot (measured: CharacterSlotView_pve is titled 'PvE "
                "Zone' and holds no profile). Nothing was pressed.\n%s"
                % (nick, census))

    # NO NICKNAME KNOWN. Fall back to the title -- and say that this cannot
    # tell a profile card from an empty one.
    if not want_title:
        return (None, 2,
                "REFUSED: no launch nickname could be read from the host log, "
                "and no --mode title was given, so there is nothing that "
                "identifies a card. Nothing was pressed.\n%s" % census)
    want = want_title.strip().lower()
    hits = [t for t in titled if t[2] and t[2].strip().lower() == want]
    if len(hits) == 1:
        return (hits[0], 0,
                "FALLBACK (no profile nickname known): selecting by TITLE "
                "%r: %s (%s). This cannot tell a profile card from an empty "
                "one -- on this build 'PvE Zone' IS the empty card."
                % (hits[0][2], hits[0][1], hits[0][0]))
    if len(hits) > 1:
        return (None, 3,
                "REFUSED: %d cards are titled %r. Nothing was pressed.\n%s"
                % (len(hits), want_title, census))
    return (None, 3,
            "REFUSED: no card is titled %r. Object NAMES are not titles on "
            "this build (CharacterSlotView_pvp is labelled \"PvE\"). Nothing "
            "was pressed.\n%s" % (want_title, census))


def press_card(ptr):
    """Press the slot. Returns (ok, how).

    `Apply` first, for builds that have it; the CARD itself otherwise, which is
    what the 4,851,200 build needs (its census under the screen has no Apply
    node at all, and hunting that name could only ever refuse). Neither of
    these is PROOF -- `press` returning without faulting says only that a
    handler ran. The caller's finished-state poll is the check.
    """
    attempts = (
        ("its `Apply` DefaultUIButton",
         ["find Apply %s 5000" % ptr,
          "component $f1 DefaultUIButton",
          "press $comp",
          "wait 300"]),
        ("the CARD itself (no pressable `Apply` under it -- expected on this "
         "build)",
         ["component %s DefaultUIButton" % ptr,
          "press $comp",
          "wait 300"]),
    )
    tried = []
    for how, batch in attempts:
        try:
            out = run_batch(batch, timeout=90, write=True)
        except Timeout as e:
            tried.append("%s: %s" % (how, e))
            continue
        # BOTH markers, not just the press one. A `component` that finds
        # nothing prints an `!` line, and pressing whatever `$comp` happens to
        # hold is how this tool once printed a complete field map of a Button
        # that does not exist. "FOUND DefaultUIButton" is inspect.nim's own
        # success prose for the lookup.
        if "FOUND DefaultUIButton" in out and "returned without faulting" in out:
            return True, how
        tried.append("%s:\n%s" % (how, out))
    return False, ("no press path worked -- neither `Apply` nor the card "
                   "itself:\n" + "\n--- next attempt ---\n".join(tried))


# ---------------------------------------------------------------------------
# selftest -- offline. Every fixture is SHAPED from lines this tool or the
# host actually printed, and each case can fail.
# ---------------------------------------------------------------------------

# The measured slot list, 2026-09-02, build 4,851,200. The profile is on the
# card whose object name says pvp and whose title says "PvE".
MEASURED_SLOTS = [
    ("0x2183a1c0100", "CharacterSlotView_pve", "PvE Zone"),
    ("0x2183a1c0200", "CharacterSlotView_pvp", "PvE"),
    ("0x2183a1c0300", "CharacterSlotView_seasonal", "New Text"),
]

MEASURED_HOSTLOG = """aowlspt-host-il2cpp 0.1.0
directory D:\\Aowlspt\\aowlspt
[0:00:28.235] ok     skip mode screen: CharacterSelectionScreen.ShowSlot first fired
[0:00:28.235] info   skip mode screen: slot 1 gameMode=1 profileId=<none> nickname="" status=1 side=0
[0:00:28.250] info   skip mode screen: slot 2 gameMode=0 profileId=00000000000a00000000004f nickname="Savant" status=2 side=1
[0:00:28.250] ok     skip mode screen: slot for profile 00000000000a00000000004f ("Savant", gameMode=0) matches launchProfileId; Submit is QUEUED, not sent
"""


def selftest():
    fails = []

    def check(name, cond, detail=""):
        if not cond:
            fails.append((name, detail))
        print("  %-5s %s%s" % ("ok" if cond else "FAIL", name,
                               ("  -- " + detail) if detail and not cond else ""))

    # 1. THE MEASURED BUG. The profile is on _pvp; the tool used to press _pve.
    nick, how = launch_nickname(MEASURED_HOSTLOG)
    check("nick/from-launchprofile", nick == "Savant", "got %r (%s)" % (nick, how))
    shows = {"0x2183a1c0100": False, "0x2183a1c0200": True,
             "0x2183a1c0300": False}
    got, rc, msg = choose_card(MEASURED_SLOTS, nick, shows, "PvE Zone")
    check("choose/picks-the-profile-card",
          got is not None and got[1] == "CharacterSlotView_pvp",
          "picked %r: %s" % (got, msg))
    check("choose/ignores-a-wrong---mode",
          got is not None and got[2] == "PvE" and rc == 0,
          "--mode 'PvE Zone' names the EMPTY card and must not win: %s" % msg)

    # 2. FALSIFYING CONTROL: move the profile to the OTHER card and the answer
    # must move with it. Without this, case 1 would also pass for a tool that
    # simply always picked _pvp.
    shows2 = {"0x2183a1c0100": True, "0x2183a1c0200": False,
              "0x2183a1c0300": False}
    got2, _rc2, msg2 = choose_card(MEASURED_SLOTS, nick, shows2, None)
    check("choose/follows-the-profile",
          got2 is not None and got2[1] == "CharacterSlotView_pve", msg2)

    # 3. NO card shows the nickname -> refuse, naming the cards.
    shows3 = dict((p, False) for p, _n, _t in MEASURED_SLOTS)
    got3, rc3, msg3 = choose_card(MEASURED_SLOTS, nick, shows3, "PvE Zone")
    check("choose/none-matches-refuses", got3 is None and rc3 == 2, msg3)
    check("choose/refusal-names-the-cards",
          all(n in msg3 for _p, n, _t in MEASURED_SLOTS)
          and "'PvE Zone'" in msg3,
          "a refusal must print the census it saw")

    # 4. INCONCLUSIVE is not a negative: one card unreadable, none positive.
    shows4 = {"0x2183a1c0100": False, "0x2183a1c0200": None,
              "0x2183a1c0300": False}
    got4, rc4, msg4 = choose_card(MEASURED_SLOTS, nick, shows4, None)
    check("choose/unreadable-is-inconclusive",
          got4 is None and rc4 == 2 and "INCONCLUSIVE" in msg4, msg4)

    # 5. TWO cards show the same nickname -> refuse rather than guess.
    shows5 = {"0x2183a1c0100": True, "0x2183a1c0200": True,
              "0x2183a1c0300": False}
    got5, rc5, msg5 = choose_card(MEASURED_SLOTS, nick, shows5, "PvE")
    check("choose/ambiguous-refuses", got5 is None and rc5 == 2, msg5)

    # 6. NO nickname at all -> the title fallback, and it SAYS it is a fallback.
    got6, rc6, msg6 = choose_card(MEASURED_SLOTS, None, {}, "PvE")
    check("choose/title-fallback-works",
          got6 is not None and got6[1] == "CharacterSlotView_pvp" and rc6 == 0,
          msg6)
    check("choose/title-fallback-announces-itself", "FALLBACK" in msg6, msg6)
    got7, rc7, msg7 = choose_card(MEASURED_SLOTS, None, {}, "Nonesuch")
    check("choose/title-fallback-can-miss", got7 is None and rc7 == 3, msg7)
    got8, rc8, msg8 = choose_card(MEASURED_SLOTS, None, {}, None)
    check("choose/no-nick-no-title-refuses", got8 is None and rc8 == 2, msg8)

    # 7. HOST-LOG parsing: the census fallback, the ambiguous census, silence,
    # and the banner restart. Each shaped from real modeskip lines.
    census_only = "\n".join(l for l in MEASURED_HOSTLOG.splitlines()
                            if "matches launchProfileId" not in l)
    n2, how2 = launch_nickname(census_only)
    check("nick/census-fallback", n2 == "Savant", "%r (%s)" % (n2, how2))
    two = census_only + ('\n[0:00:28.260] info   skip mode screen: slot 3 '
                         'gameMode=0 profileId=deadbeef nickname="Other" '
                         'status=2 side=1')
    n3, how3 = launch_nickname(two)
    check("nick/ambiguous-census-refuses", n3 is None and "Other" in how3, how3)
    n4, how4 = launch_nickname("aowlspt-host-il2cpp 0.1.0\n[0:00:01] ok x\n")
    check("nick/silent-log-is-none", n4 is None and "no profile nickname" in how4,
          how4)
    stale = MEASURED_HOSTLOG + "aowlspt-host-il2cpp 0.1.0\n[0:00:01] ok x\n"
    n5, _how5 = launch_nickname(stale)
    check("nick/restarts-at-the-last-banner", n5 is None,
          "a nickname from a PREVIOUS boot must not name this launch; got %r"
          % (n5,))

    print("\n%s -- %d check(s) failed" % ("PASS" if not fails else "FAIL",
                                          len(fails)))
    return 0 if not fails else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default=None,
                    help="displayed title to select -- FALLBACK ONLY, used "
                         "when the host log names no launch nickname")
    ap.add_argument("--list", action="store_true",
                    help="print the slots and their titles, press nothing")
    ap.add_argument("--selftest", action="store_true",
                    help="offline checks of the choice logic; presses nothing")
    ap.add_argument("--host-log", default=HOST_LOG,
                    help="where to read the launch profile's nickname from")
    ap.add_argument("--timeout", type=float, default=90.0,
                    help="seconds to wait for the selector to appear")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

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

    # WHICH PROFILE is this launch for? Read before anything is pressed, so a
    # --list run reports it too.
    nick, how = launch_nickname(read_host_log(a.host_log))
    if nick:
        print("launch profile nickname %r -- %s" % (nick, how))
    else:
        print("no launch profile nickname: %s" % how)

    shows = {}
    if nick:
        for ptr, _name, _title in titled:
            shows[ptr] = card_shows(ptr, nick)

    for ptr, name, title in titled:
        print("  %s  %-28s title=%s%s"
              % (ptr, name, ("%r" % title) if title else "<unreadable>",
                 "" if not shows else "  shows-profile=%s"
                 % {True: "yes", False: "no",
                    None: "UNREADABLE"}[shows.get(ptr)]))
    if a.list:
        return 0

    chosen, rc, msg = choose_card(titled, nick, shows, a.mode)
    if chosen is None:
        print("!! " + msg, file=sys.stderr)
        return rc
    print(msg)
    if a.mode and chosen[2] and chosen[2].strip().lower() != a.mode.strip().lower():
        print("   (--mode %r was NOT used: the profile on the card decides, "
              "and a title can name an empty card.)" % a.mode)

    ok, howpressed = press_card(chosen[0])
    if not ok:
        print("!! the press did not go through: %s" % howpressed, file=sys.stderr)
        return 4
    print("pressed via %s" % howpressed)

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
    print("!! pressed %s (%s), but CharacterSelectionScreen is still active "
          "(%s) after 25s -- the click handler ran and did not advance the "
          "screen." % (chosen[1], howpressed, last), file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
