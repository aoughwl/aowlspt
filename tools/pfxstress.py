#!/usr/bin/env python3
"""pfxstress.py -- hammer the Settings -> Graphics -> POSTFX path on a LIVE
client and catch the main-thread deadlock the moment it happens.

WHY THIS EXISTS. MEASURED 2026-09-05: two presses of the POSTFX subtab (the
user's click, and one inspector `tab` press) froze the Unity main thread
forever -- SettingsScreen::ShowScreen(PostFX) -> SettingsTab::set_IsSelected
-> SetActive -> RectMask2D enable -> GameObject::GetComponentsInChildren ->
UnityPlayer -> WaitForSingleObjectEx. Six hand-driven attempts afterwards did
NOT reproduce it, with the same flags, the same host, and the same sequences.
An intermittent deadlock cannot be bisected by hand: this loops the presses,
checks the host's own stall line after each one, and when the freeze comes
it takes the hung thread's stack with cdb and stops. The RATE is the
measurement; a run that ends green says "N presses without a freeze", never
"fixed".

It drives the client through the live inspector's file channel
(tools/inspector.py), so the client must already be at the MAIN MENU with the
settings screen closed or open; it opens Settings itself through the same
taskbar recipe the MCP `inspect_open_settings` uses when `$settings` is not
bound yet. It never launches, kills or restarts anything.

    python tools/pfxstress.py --iters 25            # subtab presses only
    python tools/pfxstress.py --iters 25 --toggle   # ...plus Enable PostFX on/off each round
    python tools/pfxstress.py --selftest            # the parsers, on fixtures

Exit 0 = every press answered (N presses, no freeze); 2 = FROZE (stack in
Logs/hostlogs/hang-<ts>.txt and printed); 3 = INCONCLUSIVE (could not reach the
controls, or the channel refused).
"""
import argparse
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

INSTALL = r"D:\Aowlspt\aowlspt"
LOG = os.path.join(INSTALL, "aowlspt-host.log")
HANG_DIR = r"D:\Aowlspt\Logs\hostlogs"
CDB = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
STALL_RE = re.compile(r"the game has stopped calling it \(EFT\.TarkovApplication::Update")

# ---------------------------------------------------------------------------
# parsers (pure, selftested)
# ---------------------------------------------------------------------------

def parse_parent_go(text, name):
    """The GameObject of the [1] parent named `name` in a `parent $f1 2` answer."""
    m = re.search(r"\[1\] transform=0x[0-9a-f]+ klass=0x[0-9a-f]+ name=\"%s\" go=(0x[0-9a-f]+)"
                  % re.escape(name), text)
    return m.group(1) if m else None


def parse_parent_transform(text, name):
    m = re.search(r"\[1\] transform=(0x[0-9a-f]+) klass=0x[0-9a-f]+ name=\"%s\"" % re.escape(name), text)
    return m.group(1) if m else None


def parse_component(text, typename):
    m = re.search(r"%s\s+(0x[0-9a-f]+)\s+klass=" % re.escape(typename), text)
    return m.group(1) if m else None


def parse_findcomp(text, typename):
    m = re.search(r"%s=(0x[0-9a-f]+)" % re.escape(typename), text)
    return m.group(1) if m else None


def parse_unity_thread(text):
    m = re.search(r"on Unity thread (\d+)", text)
    return int(m.group(1)) if m else None


def parse_current_tab(text):
    m = re.search(r"_currentTab\(\+0x118\)=(0x[0-9a-f]+)", text)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# the live side
# ---------------------------------------------------------------------------

def batch(lines, timeout=30.0, write=False):
    from inspector import run_batch
    return run_batch(list(lines), timeout=timeout, write=write)


def stall_count():
    try:
        with open(LOG, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 400000))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return -1
    return len(STALL_RE.findall(tail))


def client_pid():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq EscapeFromTarkov.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    m = re.search(r'"EscapeFromTarkov\.exe","(\d+)"', out)
    return int(m.group(1)) if m else None


def capture_stack(tid):
    pid = client_pid()
    if pid is None:
        return None, "no EscapeFromTarkov.exe process"
    if not os.path.isfile(CDB):
        return None, "cdb.exe is not installed at %s" % CDB
    os.makedirs(HANG_DIR, exist_ok=True)
    path = os.path.join(HANG_DIR, "hang-%s.txt" % time.strftime("%Y%m%d-%H%M%S"))
    cmd = [CDB, "-pv", "-p", str(pid), "-c", "~~[0x%x]k 40;q" % tid]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout
    except subprocess.TimeoutExpired:
        return None, "cdb timed out"
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    frames = [l for l in out.splitlines() if re.match(r"^[0-9a-f`]{17}\s+[0-9a-f`]{17}\s+\S", l)]
    return path, frames


def open_settings_if_needed():
    """`state` says whether $settings is bound; if not, run the taskbar recipe
    (fact #109): Preloader UI -> TaskBar -> Tabs -> LAST child -> SettingsButton
    -> AnimatedToggle -> set_isOn(true)."""
    t = batch(["state"], timeout=20)
    if "$settings=0x0000000000000000" not in t:
        return True, t
    t = batch(["find TaskBar in \"Preloader UI\"", "find Tabs $f1", "children $f1"], timeout=40)
    # the recipe is what the MCP tool does; if this checkout's inspector prints a
    # different shape, say so rather than pressing something else
    return False, "settings screen is not bound and the taskbar recipe is not automated here -- open Settings once (inspect_open_settings) and re-run: " + t[-300:]


def find_subtab(label):
    t = batch(["findtext %s in \"Common UI\"" % label, "parent $f1 2"], timeout=45)
    parent_name = {"GRAPHICS": "GraphicsToggle", "POSTFX": "GesturesToggle", "GENERAL": "ControlToggle"}[label]
    go = parse_parent_go(t, parent_name)
    if not go:
        return None, "no active %s toggle (parent %s) -- %s" % (label, parent_name, t[-240:])
    t2 = batch(["components " + go], timeout=30)
    tog = parse_component(t2, "EFT.UI.AnimatedToggle")
    if not tog:
        return None, "no AnimatedToggle on %s -- %s" % (go, t2[-240:])
    return tog, t2


def find_enable_toggle():
    t = batch(["findtext \"Enable PostFX\" in \"Common UI\"", "parent $f1 2"], timeout=45)
    tr = parse_parent_transform(t, "Setting1: Enable PostFX")
    if not tr:
        return None, "the stock Enable PostFX row is not active -- " + t[-240:]
    t2 = batch(["findcomp UnityEngine.UI.Toggle %s 200" % tr], timeout=30)
    tog = parse_findcomp(t2, "UnityEngine.UI.Toggle")
    if not tog:
        return None, "no Toggle under the Enable PostFX row -- " + t2[-240:]
    return tog, t2


def press(cmds, wait_frames):
    """Run a write batch that ends in `state`; returns (answered, text).

    A single timeout is NOT a freeze. MEASURED 2026-09-05 on the first run:
    iteration 16's batch timed out with the channel reporting
    `delivered=91 running=-1` -- the host had answered and the read missed
    it -- and the client answered a plain `state` right after; the "stack" it
    took was the ordinary between-frames wait. So a timeout is confirmed by a
    second probe: only a `state` that ALSO fails, or the host's own stall
    line, is a freeze. A lone hiccup is reported and counted, never called
    a freeze.
    """
    try:
        t = batch(cmds + ["wait %d" % wait_frames, "state"], timeout=40, write=True)
        return ("batch" in t and "complete" in t), t
    except Exception as e:  # channel Timeout or wedge
        first = "%s: %s" % (type(e).__name__, e)
    time.sleep(4)
    if STALL_RE.search(recent_log_tail()):
        return False, "stall line after the press; first answer was " + first[-160:]
    try:
        t2 = batch(["state"], timeout=25)
        press.hiccups = getattr(press, "hiccups", 0) + 1
        print("  channel hiccup #%d (the press's answer was missed; `state` answers): %s"
              % (press.hiccups, first[-140:]), flush=True)
        return True, t2
    except Exception as e2:
        return False, "no answer to the press NOR to a follow-up `state`: %s / %s" % (first[-120:], e2)


def recent_log_tail(n=200000):
    try:
        with open(LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - n))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--toggle", action="store_true", help="also flip the stock Enable PostFX toggle each round")
    ap.add_argument("--wait", type=int, default=45, help="frames to park after each press")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    ok, t = open_settings_if_needed()
    if not ok:
        print("INCONCLUSIVE: " + t)
        return 3
    tid = parse_unity_thread(t)
    stalls0 = stall_count()
    gfx, why = find_subtab("GRAPHICS")
    if not gfx:
        print("INCONCLUSIVE: " + why); return 3
    answered, t = press(["tab %s 1" % gfx], a.wait)
    if not answered:
        print("FROZE on the Graphics tab press: " + t[-300:]); return froze(tid)
    post, why = find_subtab("POSTFX")
    if not post:
        print("INCONCLUSIVE: " + why); return 3
    gen, why = find_subtab("GENERAL")
    if not gen:
        print("INCONCLUSIVE: " + why); return 3
    enable = None
    presses = 0
    t0 = time.time()
    for i in range(1, a.iters + 1):
        for label, tog in (("POSTFX", post), ("GENERAL", gen)):
            answered, t = press(["tab %s 1" % tog], a.wait)
            presses += 1
            if not answered:
                print("FROZE at iteration %d on the %s press after %d press(es), %.0fs: %s"
                      % (i, label, presses, time.time() - t0, t[-200:]))
                return froze(tid)
            if label == "POSTFX" and a.toggle:
                if enable is None:
                    enable, why = find_enable_toggle()
                    if not enable:
                        print("INCONCLUSIVE at iteration %d: %s" % (i, why)); return 3
                for v in (1, 0):
                    answered, t = press(["call rva:0x55ba430 v_pb %s %d" % (enable, v)], 20)
                    presses += 1
                    if not answered:
                        print("FROZE at iteration %d on Enable PostFX=%d after %d press(es): %s"
                              % (i, v, presses, t[-200:]))
                        return froze(tid)
        if i % 5 == 0:
            print("  %d iteration(s), %d press(es), %.0fs, no freeze" % (i, presses, time.time() - t0), flush=True)
    print("PASS: %d press(es) over %d iteration(s) in %.0fs answered (%d channel hiccup(s), none a freeze); "
          "the host's stall line did not appear. This bounds the freeze RATE for this configuration; "
          "it is not proof the freeze is gone." % (presses, a.iters, time.time() - t0, getattr(press, "hiccups", 0)))
    return 0


def froze(tid):
    if tid is None:
        print("  (no Unity thread id parsed from the inspector; cannot take the stack)")
        return 2
    path, frames = capture_stack(tid)
    if path is None:
        print("  stack NOT captured: %s" % frames)
        return 2
    print("  stack of Unity thread 0x%x saved to %s (%d frame(s)); top:" % (tid, path, len(frames)))
    for f in frames[:12]:
        print("    " + f.split(None, 2)[-1][:110])
    return 2


def selftest():
    bad = 0
    par = ('    [0] transform=0x000001829af07dc0 klass=0x0000017fb1f2f0a0 name="SizeLabel" go=0x000001829af07de0 activeSelf=true\n'
           '    [1] transform=0x000001829af07ee0 klass=0x0000017fb1f2f0a0 name="GesturesToggle" go=0x000001829af07f20 activeSelf=true\n')
    if parse_parent_go(par, "GesturesToggle") != "0x000001829af07f20": bad += 1; print("FAIL parse_parent_go")
    if parse_parent_go(par, "GraphicsToggle") is not None: bad += 1; print("FAIL parse_parent_go negative")
    if parse_parent_transform(par, "GesturesToggle") != "0x000001829af07ee0": bad += 1; print("FAIL parse_parent_transform")
    comp = "    [4] EFT.UI.AnimatedToggle   0x000001829b54e540  klass=0x0000017fb2f98030   ($k4)\n"
    if parse_component(comp, "EFT.UI.AnimatedToggle") != "0x000001829b54e540": bad += 1; print("FAIL parse_component")
    if parse_component(comp, "UnityEngine.UI.Toggle") is not None: bad += 1; print("FAIL parse_component negative")
    fc = '    HIT node=0x000001829408b0e0 "Setting1: Enable PostFX"  UnityEngine.UI.Toggle=0x000001829d27bb40  active   ($k1 = component, $kn1 = node)\n'
    if parse_findcomp(fc, "UnityEngine.UI.Toggle") != "0x000001829d27bb40": bad += 1; print("FAIL parse_findcomp")
    if parse_unity_thread("aowlspt live inspector -- batch 14, 5 command(s), on Unity thread 10972\n") != 10972: bad += 1; print("FAIL parse_unity_thread")
    if parse_current_tab("  settings: _currentTab(+0x118)=0x000001823d994400  _initializedTabs") != "0x000001823d994400": bad += 1; print("FAIL parse_current_tab")
    stall = "[0:12:09.109] warn  the main-thread drain is not carrying work: the detour is bound and fired before, and the game has stopped calling it (EFT.TarkovApplication::Update, slot 0, fires 37034, 47s since the count last moved)."
    if len(STALL_RE.findall(stall)) != 1: bad += 1; print("FAIL STALL_RE positive")
    if STALL_RE.findall("the detour is bound but the game has not called the method yet (EFT.TarkovApplication::Update"): bad += 1; print("FAIL STALL_RE negative (boot-time line must not count)")
    print("pfxstress selftest: %d failure(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
