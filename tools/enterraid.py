#!/usr/bin/env python
"""enterraid.py -- drive the main menu into an offline raid on a chosen map,
hands-off, via the live inspector (ui.py).

Why not findtext / the recipe: EFT menu buttons are DefaultUIButtons whose
captions live in DefaultUIButton._text (+0xB8), NOT TMP nodes -- findtext finds
ZERO of them (fact #240/#242). So we navigate by GameObject NAME + a `visible`
filter (exactly one on-screen) + actuate. We use ui.actuate() (component +
`press $comp`, OnClick +0x120); we do NOT use the `pressname` verb -- it reads
OnClick at +0x100 and refuses to fire (fact #243).

Menu-ready is a FAST poll for a visible PlayButton -- enter the instant it
exists, never a blind fixed sleep.

Usage:  python tools/enterraid.py [MapName]   (default Woods)

EXIT CODES -- three outcomes, never two (CLAUDE.md 9b).

    0   IN RAID.
    1   FAIL   -- a step ran and did not do what it was supposed to.
    2   INCONCLUSIVE -- we could not look. The menu never came up, or the
        inspector channel is wedged/busy, so NOTHING about the raid was
        established. "I could not look" is not a failure of the raid and it is
        certainly not a pass.
    3   FAIL   -- a specific navigation step refused (kept distinct from 1 for
        callers that already branch on it).

MEASURED 2026-08-31, and this is why the codes are spelled out: this script
printed `[enterraid] FAIL: menu never became ready` and returned EXIT 0. Every
caller read a failed raid entry as a success. Its stdout was also fully
buffered, so when it was wrapped, the entire progress log vanished and there
was no record of how far it got. Both are fixed here; `log()` flushes per line
and `main()`'s return value is asserted by --selftest.
"""
import os
import re
import subprocess
import sys
import time

import ui

OK, FAIL, INCONCLUSIVE = 0, 1, 2
REFUSED = 3

# Line-buffer stdout even when it is a pipe. Python fully buffers a redirected
# stdout, so a wrapped run that is killed or times out loses EVERYTHING it
# printed -- which is what happened, leaving no record of how far it got.
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

_pos = [a for a in sys.argv[1:] if not a.startswith("-")]
MAP = _pos[0] if _pos else "Woods"
HIT = re.compile(r'HIT (0x[0-9a-fA-F]+)\s+name="([^"]+)"')

# The host log is the ONLY safe way to watch the raid load: reading this file is
# off the Unity main thread. Issuing an inspector command (find/visible/roots)
# during the load stalls the main thread and TIMES OUT matchmaking (fact #245),
# which is exactly the "one or more errors (a task was cancelled)" crash. So
# after READY we go inspector-silent and watch the log instead.
LIVE = os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt")
HOSTLOG = os.path.join(LIVE, "aowlspt-host.log")
RAID_MARKERS = ("RegisterPlayer", "botdiag", "GwMainPlayer", "draw stable")
PHASE_RE = re.compile(r"raid phase = ([A-Z]+)")


def hostlog_size():
    try:
        return os.path.getsize(HOSTLOG)
    except OSError:
        return 0


def raid_marker_since(pos):
    """True once the host log (past byte <pos>) shows a raid is live. Cheap,
    off-thread -- never touches the inspector."""
    try:
        with open(HOSTLOG, "r", errors="replace") as f:
            f.seek(pos)
            data = f.read()
    except OSError:
        return False
    return any(m in data for m in RAID_MARKERS)


def wait_phase(pos, want, timeout):
    """Wait until the host PUBLISHES raid phase <want>. Three outcomes.

    Returns "DEPLOYED" / "TIMEOUT" / "SILENT".

    `raidphase.nim` has published the phase every 5s all along and nothing has
    ever consumed it. The alternative in use here was `time.sleep(60.0)`, which
    asserts a DURATION: it cannot tell a raid that deployed in 20s from one
    that never deployed at all, and it reported success either way. That is the
    exact shape CLAUDE.md 9b forbids -- a check that cannot fail.

    This stays INSPECTOR-SILENT on purpose (fact #261: an inspector read during
    the scene load stalls the still-loading main thread and errors the load).
    Reading the host log is passive, off the game thread, and costs nothing.

    "SILENT" is the third outcome and is NOT a pass: the host published no
    phase line at all in the window, which means the feature is off or the host
    is wedged -- either way we do not know where the client is, and saying so
    is the whole point.
    """
    deadline = time.time() + timeout
    seen_any = False
    while time.time() < deadline:
        try:
            with open(HOSTLOG, "r", errors="replace") as f:
                f.seek(pos)
                data = f.read()
        except OSError:
            data = ""
        for m in PHASE_RE.finditer(data):
            seen_any = True
            if m.group(1) == want:
                return "DEPLOYED"
        time.sleep(2.0)
    return "TIMEOUT" if seen_any else "SILENT"


def log(m):
    print("[enterraid] " + m, flush=True)


def find_named(name, root_ptr):
    """Every node named <name> under <root_ptr> (by NAME, not text). Single-word
    names only -- the inspector parser splits on spaces."""
    out = ui._run(["find %s %s" % (name, root_ptr)])
    return [m.group(1) for m in HIT.finditer(out)]


def is_visible(ptr):
    out = ui._run(["visible %s" % ptr])
    return "VERDICT: VISIBLE" in out


def label_of(ptr):
    out = ui._run(["component %s TextMeshProUGUI" % ptr, "label $comp"])
    m = re.search(r'text = "([^"]*)"', out)
    return m.group(1) if m else None


def roots_ptrs():
    rs = ui.roots()
    return (rs.get("Common UI", {}).get("t"),
            rs.get("Menu UI", {}).get("t"))


HERE = os.path.dirname(os.path.abspath(__file__))


def inspector_up():
    """True once the live inspector answers and the Menu UI scene root exists.
    On a cold launch the client boots for ~30-60s before the inspector answers at
    all; running entergame.py before then just times out (exit 2)."""
    try:
        _, mu = roots_ptrs()
        return bool(mu)
    except Exception:
        return False


def clear_mode_selector():
    """Dismiss the PvE/PvP mode selector if it is up, so PlayButton is reachable.
    entergame.py selects by the DISPLAYED title, waits for Menu UI, and verifies
    the screen actually closed. It shares the inspector file channel, so it must
    run sequentially (finish before we touch ui.py).

    Wait for the inspector to be RESPONSIVE first: on a cold launch entergame runs
    too early and times out at the boot screen (exit 2) otherwise. This is
    best-effort -- if it fails we still try PlayButton, because MenuScreen-scoped
    menu_ready handles the common case where no selector is blocking (the real
    cold-launch blocker was the RewardInfo double-PlayButton, now scoped out)."""
    log("waiting for the inspector to come up before clearing the selector ...")
    if not ui.wait_until(inspector_up, timeout=150.0, poll=3.0):
        log("  inspector never came up in 150s; skipping entergame, trying PlayButton")
        return
    log("clearing the mode selector (entergame.py) ...")
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "entergame.py")],
                           cwd=HERE, timeout=180)
        log("  entergame.py exit %d" % r.returncode)
    except Exception as e:
        log("  entergame.py failed to run: %s (continuing to PlayButton)" % e)


def menuscreen_ptr(cu):
    """The real PlayButton lives under MenuScreen; a SECOND PlayButton lives under
    RewardInfo (a daily-reward popup) and can be visible at the same time, which
    made the old 'exactly one visible globally' rule wait forever. Scope every
    PlayButton lookup to MenuScreen so the popup can never be mistaken for PLAY."""
    if not cu:
        return None
    hits = find_named("MenuScreen", cu)
    return hits[0] if hits else None


def visible_map(ptrs):
    """{ptr: bool} for many nodes in ONE inspector round-trip (batched `visible`).
    Sequential per-node round-trips are the whole slowness -- 11 NextButtons was
    ~12 trips per step; this makes it 2."""
    if not ptrs:
        return {}
    out = ui._run(["visible %s" % p for p in ptrs])
    res = {}
    parts = re.split(r'>\s*visible\s+(0x[0-9a-fA-F]+)', out)
    for i in range(1, len(parts) - 1, 2):
        res[parts[i]] = "VERDICT: VISIBLE" in parts[i + 1]
    return res


def visible_named(name, root_ptr):
    hits = find_named(name, root_ptr)
    vm = visible_map(hits)
    return [p for p in hits if vm.get(p)]


def press_named(name, root_ptr, ctype="DefaultUIButton", timeout=20.0):
    """Wait until exactly one <name> is VISIBLE under <root_ptr>, then actuate it.
    Returns True on a fired press. Refuses (False) on 0 or >1 visible."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        vis = visible_named(name, root_ptr)
        if len(vis) == 1:
            ok, _ = ui.actuate(vis[0], ctype=ctype)
            log("  pressed %s (%s) -> fired=%s" % (name, vis[0], ok))
            return ok
        if len(vis) > 1:
            log("  %s AMBIGUOUS: %d visible -- refusing" % (name, len(vis)))
            return False
        time.sleep(1.0)
    log("  %s never became visible in %.0fs" % (name, timeout))
    return False


def select_map(menu_ptr, name):
    """The SELECT LOCATION map: each tile is an AnimatedToggle whose descendant
    'Label' TMP holds the map name. Match by name, then actuate the toggle."""
    toggles = find_named("AnimatedToggle", menu_ptr)
    log("  %d AnimatedToggle(s) to scan for map '%s'" % (len(toggles), name))
    for t in toggles:
        for lp in find_named("Label", t):
            txt = label_of(lp)
            if txt and txt.strip().lower() == name.lower():
                ok, _ = ui.actuate(t, ctype="AnimatedToggle")
                log("  selected map '%s' via toggle %s -> fired=%s"
                    % (name, t, ok))
                return ok
    log("  map '%s' NOT found among the toggles" % name)
    return False


def enable_practice(menu_ptr):
    """On the Matchmaker Offline Raid Screen, enable 'practice mode' -- the
    EFT.UI.UpdatableToggle under SoloModeCheckmarkBlocker -- via set_isOn(1)
    (rva 0x55ba430, fact #71). WITHOUT this the client runs ONLINE
    NetworkGameMatching, waits ~34s for a server and aborts the load with
    "one or more errors (a task was cancelled)" (fact #246). This is the whole
    reason automated entry crashed while manual entry worked."""
    hits = find_named("SoloModeCheckmarkBlocker", menu_ptr)
    if not hits:
        log("  practice: SoloModeCheckmarkBlocker not found "
            "(singleplayerRebrand may already force it)")
        return False
    for t in hits:
        out = ui._run(["component %s UpdatableToggle" % t,
                       "call rva:0x55ba430 v_pb $comp 1", "wait 200"],
                      write=True)
        if "FAULTED" not in out and "not found" not in out.lower():
            log("  practice mode ENABLED via %s" % t)
            return True
    log("  practice: could not toggle the UpdatableToggle")
    return False


def menu_ready():
    # The inspector does not answer for ~15s after a restart; treat any error
    # (timeout, no roots yet) as "not ready" rather than crashing the poll.
    # Scope PlayButton to MenuScreen so the RewardInfo popup's PlayButton is not
    # counted (fact: two PlayButtons can be visible at once on the main menu).
    try:
        cu, _ = roots_ptrs()
        if not cu:
            return False
        ms = menuscreen_ptr(cu)
        if not ms:
            return False
        return len(visible_named("PlayButton", ms)) == 1
    except Exception:
        return False


def main():
    log("map = %s" % MAP)
    # NOTE: no mode-selector step. uxSkipModeScreen (host flag, default ON here)
    # auto-skips the PvE/PvP character-selection screen on launch, so the client
    # boots straight to the main menu. Running entergame.py here just polled for a
    # screen that no longer appears -- pure wasted time. Go straight to the menu.
    log("waiting for menu (fast poll for a visible PlayButton under MenuScreen)...")
    ready = ui.wait_until(menu_ready, timeout=25.0, poll=1.0)
    if not ready:
        # A screen OVER the menu (Settings, Credits, a results page) hides the
        # PlayButton while the menu is otherwise perfectly ready. Measured
        # 2026-09-01: the coordinator left the client on the Settings screen,
        # and this poll waited its full 180s and reported INCONCLUSIVE for a
        # menu that was one BACK press away. Try that press ONCE -- `pressname`
        # refuses unless exactly one BackButton is VISIBLE, so on a bare menu
        # it does nothing and says so.
        try:
            out = ui._run(["allow write", "pressname BackButton", "wait 30"])
            fired = "OnClick" in out and "refus" not in out.lower()
            log("menu not ready after 25s; tried to dismiss an overlaying screen "
                "with `pressname BackButton` -> %s"
                % ("pressed" if fired else "nothing visible to press"))
        except Exception as e:
            log("menu not ready after 25s; BackButton dismiss attempt failed: %s" % e)
        ready = ui.wait_until(menu_ready, timeout=155.0, poll=1.0)
    if not ready:
        # INCONCLUSIVE, not FAIL: the menu never appearing tells us nothing
        # about whether a raid can be entered. Name the likelier cause if the
        # host's own counters say the channel is wedged.
        state, note = ui.channel_verdict()
        log("INCONCLUSIVE: menu never became ready in 180s -- nothing about "
            "raid entry was established.")
        if state == "WEDGED":
            log("  " + note)
        elif state == "UNKNOWN":
            log("  the inspector channel was NOT CHECKED for a wedge: %s"
                % (note or "the host log has no watchdog line to read."))
        else:
            log("  the channel is HEALTHY, so this is a UI state, not a "
                "transport fault: no visible PlayButton appeared under "
                "MenuScreen and the client may still be booting.")
        return INCONCLUSIVE
    cu, mu = roots_ptrs()
    ms = menuscreen_ptr(cu)
    log("menu ready. CommonUI=%s MenuUI=%s MenuScreen=%s" % (cu, mu, ms))

    if not press_named("PlayButton", ms or cu):
        log("FAIL: PlayButton did not fire"); return REFUSED
    time.sleep(0.8)
    if not press_named("NextButton", mu):        # -> Matchmaker Location Selection
        log("FAIL: NEXT after PLAY did not fire"); return REFUSED
    time.sleep(0.8)
    press_named("MapButton", mu, timeout=4.0)    # opens the map if this flow uses it
    time.sleep(0.5)
    if not select_map(mu, MAP):
        log("FAIL: map select"); return FAIL
    time.sleep(0.8)

    # location -> NEXT -> Matchmaker Offline Raid Screen. Do NOT press the
    # location screen's READY -- that starts ONLINE matchmaking (fact #246).
    if not press_named("NextButton", mu):
        log("FAIL: NEXT to Offline Raid Screen"); return FAIL
    time.sleep(0.8)
    enable_practice(mu)                          # CRUCIAL for an OFFLINE raid
    time.sleep(0.5)
    # Offline Raid Screen -> NEXT (Insurance) -> NEXT (MatchMaker AcceptScreen)
    press_named("NextButton", mu, timeout=10.0); time.sleep(0.8)
    press_named("NextButton", mu, timeout=10.0); time.sleep(0.8)

    # On the AcceptScreen the "READY" control is ITSELF a NextButton (it actuates
    # a NextButton -> Final Countdown -> raid), NOT a ReadyButton (verified live).
    # Press it, then go INSPECTOR-SILENT and watch the host log off-thread.
    base = hostlog_size()
    if not press_named("NextButton", mu, timeout=10.0):
        log("FAIL: no READY (NextButton) on the AcceptScreen"); return FAIL
    log("READY pressed -- inspector-silent; watching host log for the raid...")

    deadline = time.time() + 300.0
    while time.time() < deadline:
        if raid_marker_since(base):
            # The marker fires during scene LOAD, not at actual DEPLOY (fact #258).
            # Running any inspector command now stalls the still-loading main thread
            # and errors the load (fact #261). So STAY inspector-silent and give the
            # load ~60s more to actually deploy the player before declaring success.
            log("raid marker seen (loading); waiting for the host to publish "
                "raid phase = DEPLOYED (inspector-silent)...")
            got = wait_phase(base, "DEPLOYED", 180.0)
            if got == "DEPLOYED":
                log("IN RAID (host published DEPLOYED). Do NOT issue inspector "
                    "reads until a camera is confirmed.")
                return OK
            if got == "TIMEOUT":
                log("FAIL: the host kept publishing the raid phase for 180s "
                    "and it never became DEPLOYED -- the load is wedged, not "
                    "slow. This used to be a 60s sleep that returned OK here.")
                return FAIL
            log("INCONCLUSIVE: the raid marker fired but the host published NO "
                "raid phase line in 180s, so where the client got to is "
                "UNKNOWN -- not a pass. Check that raidphase is enabled in "
                "aowlspt-host.json.")
            return FAIL
        time.sleep(3.0)
    log("FAIL: no raid marker in the host log within 300s"); return FAIL


def selftest():
    """Prove a FAILED run exits NON-ZERO -- by RUNNING main() and reading its
    exit code, not by reading the source.

    Falsifiable in the exact way the bug was not: the failure is simulated by
    forcing `ui.wait_until` to return False (the menu never becomes ready),
    which is precisely the path that printed `FAIL: menu never became ready`
    and returned 0. If the return value ever goes back to 0, this fails.

    A second case forces a mid-navigation refusal (PlayButton never fires) and
    demands a DIFFERENT non-zero code, so "always return 1" cannot pass either.
    """
    bad = 0

    def case(label, got, want):
        nonlocal bad
        ok = (got == want)
        if not ok:
            bad += 1
        print("%-4s %-58s want=%-14s got=%s"
              % ("ok" if ok else "FAIL", label[:58], want, got))

    real_wait, real_roots, real_ms, real_press = (
        ui.wait_until, roots_ptrs, menuscreen_ptr, press_named)
    g = globals()
    try:
        # Case 1 -- the exact 2026-08-31 failure: menu never ready.
        ui.wait_until = lambda *a, **k: False
        case("menu never ready -> INCONCLUSIVE (2), NOT 0", main(), INCONCLUSIVE)

        # Case 2 -- the menu comes up, but PlayButton never fires.
        ui.wait_until = lambda *a, **k: True
        g["roots_ptrs"] = lambda: ("0x1", "0x2")
        g["menuscreen_ptr"] = lambda cu: "0x3"
        g["press_named"] = lambda *a, **k: False
        case("PlayButton refuses -> REFUSED (3), NOT 0", main(), REFUSED)
    finally:
        ui.wait_until = real_wait
        g["roots_ptrs"], g["menuscreen_ptr"], g["press_named"] = (
            real_roots, real_ms, real_press)

    # And the negative that keeps the two above honest: OK really is 0, so
    # "never return 0" is not what is being asserted.
    case("the success constant is 0", OK, 0)
    case("FAIL/INCONCLUSIVE/REFUSED are all non-zero",
         all(c != 0 for c in (FAIL, INCONCLUSIVE, REFUSED)), True)

    print("\n%s: %d case(s) failed" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
