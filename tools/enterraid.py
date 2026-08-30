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
Exit 0 = in raid.
"""
import os
import re
import subprocess
import sys
import time

import ui

MAP = sys.argv[1] if len(sys.argv) > 1 else "Woods"
HIT = re.compile(r'HIT (0x[0-9a-fA-F]+)\s+name="([^"]+)"')

# The host log is the ONLY safe way to watch the raid load: reading this file is
# off the Unity main thread. Issuing an inspector command (find/visible/roots)
# during the load stalls the main thread and TIMES OUT matchmaking (fact #245),
# which is exactly the "one or more errors (a task was cancelled)" crash. So
# after READY we go inspector-silent and watch the log instead.
LIVE = os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt")
HOSTLOG = os.path.join(LIVE, "aowlspt-host.log")
RAID_MARKERS = ("RegisterPlayer", "botdiag", "GwMainPlayer", "draw stable")


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
    clear_mode_selector()
    log("waiting for menu (fast poll for a visible PlayButton under MenuScreen)...")
    if not ui.wait_until(menu_ready, timeout=180.0, poll=1.0):
        log("FAIL: menu never became ready"); return 2
    cu, mu = roots_ptrs()
    ms = menuscreen_ptr(cu)
    log("menu ready. CommonUI=%s MenuUI=%s MenuScreen=%s" % (cu, mu, ms))

    if not press_named("PlayButton", ms or cu):
        log("FAIL: PlayButton"); return 3
    time.sleep(0.8)
    if not press_named("NextButton", mu):        # -> Matchmaker Location Selection
        log("FAIL: NEXT after PLAY"); return 3
    time.sleep(0.8)
    press_named("MapButton", mu, timeout=4.0)    # opens the map if this flow uses it
    time.sleep(0.5)
    if not select_map(mu, MAP):
        log("FAIL: map select"); return 4
    time.sleep(0.8)

    # location -> NEXT -> Matchmaker Offline Raid Screen. Do NOT press the
    # location screen's READY -- that starts ONLINE matchmaking (fact #246).
    if not press_named("NextButton", mu):
        log("FAIL: NEXT to Offline Raid Screen"); return 4
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
        log("FAIL: no READY (NextButton) on the AcceptScreen"); return 5
    log("READY pressed -- inspector-silent; watching host log for the raid...")

    deadline = time.time() + 300.0
    while time.time() < deadline:
        if raid_marker_since(base):
            # The marker fires during scene LOAD, not at actual DEPLOY (fact #258).
            # Running any inspector command now stalls the still-loading main thread
            # and errors the load (fact #261). So STAY inspector-silent and give the
            # load ~60s more to actually deploy the player before declaring success.
            log("raid marker seen (loading); settling 60s to actual deploy (inspector-silent)...")
            time.sleep(60.0)
            log("IN RAID (loaded + settled). Do NOT issue inspector reads until a camera is confirmed."); return 0
        time.sleep(3.0)
    log("FAIL: no raid marker in the host log within 300s"); return 6


if __name__ == "__main__":
    sys.exit(main())
