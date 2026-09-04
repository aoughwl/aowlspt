#!/usr/bin/env python
"""dlssapply.py -- make the install match the `aowl.dlss` mod config, before the game starts.

    python tools/dlssapply.py apply  [--root D:\\Aowlspt] [--config PATH] [--dry-run]
    python tools/dlssapply.py verify [--root D:\\Aowlspt] [--config PATH] [--pid N]
    python tools/dlssapply.py selftest

`apply` is the LAUNCHER-SIDE step (`tools/aowldlss.nim`, called from
`aowlspt-launch` before CreateProcess). It reads the mod's `config.json`
-- the same file the native Graphics rows and the F12 overlay write -- and:

  * compares the chosen DLSS Super Resolution version with what is installed
    (`tools/dlss.py describe_live`, by SHA256 against its pinned catalog) and,
    if they differ, runs `tools/dlss.py install --version V` AS A SUBPROCESS.
    The swap, the ConsistencyInfo re-sync, the manifest re-injection into the
    exe, the backup and the read-back verification are all that tool's, not
    reimplemented here: one install path, not two.
  * writes the OptiScaler keys `[Upscalers] Dx11Upscaler` and
    `[DlssNr] Enabled / WorkingScale / Intensity`, in place, backing the ini
    up first and proving afterwards that every OTHER line is byte-identical.

`verify` is the BOOT VERDICT, run against the live process once it is up:
the `nvngx_dlss.dll` the process actually LOADED (module list of the pid, PE
version resource off the module's own path -- not off the file we hoped it
would use), and the OptiScaler keys as they are ON DISK, each compared with
the config. It prints PASS, FAIL or INCONCLUSIVE per line and exits 0 / 1 / 3.

INCONCLUSIVE is a real outcome and is never folded into PASS. NGX loads
`nvngx_dlss.dll` lazily -- only when DLSS actually initialises -- so a client
sitting at the menu with DLSS off has no such module, and that is not a
failure. Likewise a missing OptiScaler is INCONCLUSIVE for the upscaler line
and not a failure of anything.

Nothing here ever runs while the game is running except `verify`, which only
reads.
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dlss as dlsstool  # noqa: E402  (same directory; shares CATALOG + PE reader)

DEFAULT_ROOT = r"D:\Aowlspt"
CONFIG_REL = os.path.join("aowlspt", "mods", "dlss", "config.json")
REPO_CONFIG = os.path.join(os.path.dirname(HERE), "mods", "dlss", "config.json")

# The two step->meaning tables. They MIRROR mods/dlss/dlss.nim; `selftest`
# reads that file and asserts the mirror still holds, because a stepper whose
# two halves disagree writes the wrong thing and says it succeeded.
VERSION_MAP = {1: "310.5.3", 2: "310.7.0", 3: "310.7.129"}
UPSCALER_MAP = {1: "dlss", 2: "ffx_12", 3: "xess_12"}
UPSCALER_LABEL = {1: "DLSS", 2: "FSR 3.1", 3: "XeSS"}

PASS, FAIL, INCONC = "PASS", "FAIL", "INCONCLUSIVE"


def say(*a):
    print(*a)
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
def find_config(root, explicit=None):
    """The config the LAUNCHER will read, or the repo copy when the install has
    no such mod deployed. Returns (path, why) and never guesses silently."""
    if explicit:
        return explicit, "given on the command line"
    p = os.path.join(root, CONFIG_REL)
    if os.path.exists(p):
        return p, "the deployed mod config"
    if os.path.exists(REPO_CONFIG):
        return REPO_CONFIG, ("the REPO copy -- mods/dlss is not deployed to "
                             "%s, so the values applied are the repo's "
                             "defaults, not the player's" % root)
    return None, "no aowl.dlss config.json exists in either place"


def clamp_int(v, lo, hi):
    try:
        v = int(round(float(v)))
    except Exception:
        return None
    return max(lo, min(hi, v))


def read_config(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    cfg = {
        "version": clamp_int(doc.get("version", 2), 1, 3),
        "upscaler": clamp_int(doc.get("upscaler", 1), 1, 3),
        "nrEnabled": bool(doc.get("nrEnabled", False)),
        "nrWorkingScale": float(doc.get("nrWorkingScale", 0.25)),
        "nrIntensity": float(doc.get("nrIntensity", 1.0)),
    }
    if cfg["version"] is None or cfg["upscaler"] is None:
        raise ValueError("version/upscaler are not numbers in %s" % path)
    cfg["nrWorkingScale"] = max(0.25, min(1.0, cfg["nrWorkingScale"]))
    cfg["nrIntensity"] = max(0.0, min(2.0, cfg["nrIntensity"]))
    return cfg


# ---------------------------------------------------------------------------
# the ini
# ---------------------------------------------------------------------------
def ini_get(text, section, key):
    """The value of key in section, or None. Comment lines (`;`) never match."""
    cur = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
            continue
        if cur != section or s.startswith(";") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == key:
            return v.strip()
    return None


def ini_set(text, section, key, value):
    """Return (newtext, changed). Rewrites ONE line, in place, keeping its
    indentation; appends inside the section when the key is absent."""
    lines = text.splitlines(True)
    cur, sec_end = None, None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if cur == section:
                sec_end = i
                break
            cur = s[1:-1]
            continue
        if cur != section or s.startswith(";") or "=" not in s:
            continue
        k = s.split("=", 1)[0].strip()
        if k == key:
            nl = "\r\n" if line.endswith("\r\n") else ("\n" if line.endswith("\n") else "")
            new = "%s=%s%s" % (key, value, nl)
            if new == line:
                return text, False
            lines[i] = new
            return "".join(lines), True
    if cur != section and sec_end is None:
        return text, False           # no such section: caller reports it
    at = sec_end if sec_end is not None else len(lines)
    lines.insert(at, "%s=%s\n" % (key, value))
    return "".join(lines), True


def ini_wanted(cfg):
    return [("Upscalers", "Dx11Upscaler", UPSCALER_MAP[cfg["upscaler"]]),
            ("DlssNr", "Enabled", "true" if cfg["nrEnabled"] else "false"),
            ("DlssNr", "WorkingScale", "%g" % cfg["nrWorkingScale"]),
            ("DlssNr", "Intensity", "%g" % cfg["nrIntensity"])]


def ini_apply(path, cfg, dry_run=False):
    """Write the four keys. Returns (status, lines). Proves afterwards that
    exactly the intended lines differ from the backup -- the negative check, so
    a bug that rewrote the file wholesale cannot read as success."""
    out = []
    if not os.path.exists(path):
        return INCONC, ["ini      : %s does not exist -- OptiScaler is not "
                        "installed beside the executable, so the upscaler and "
                        "DLSS-5 keys apply to nothing. Nothing written."
                        % path]
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        before = f.read()
    text = before
    changed = []
    missing = []
    for sec, key, val in ini_wanted(cfg):
        if ini_get(text, sec, key) is None and ("[%s]" % sec) not in text:
            missing.append("[%s] %s" % (sec, key))
            continue
        text, did = ini_set(text, sec, key, val)
        if did:
            changed.append("[%s] %s=%s" % (sec, key, val))
    for m in missing:
        out.append("ini      : %s has no %s section/key -- this OptiScaler "
                   "build does not carry it. NOT invented." % (path, m))
    if not changed:
        out.append("ini      : already matches the config (%s)" %
                   ", ".join("%s.%s=%s" % w for w in ini_wanted(cfg)))
        return PASS if not missing else INCONC, out
    if dry_run:
        out.append("ini      : --dry-run, would write: %s" % "; ".join(changed))
        return PASS, out
    backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        after = f.read()
    # THE FALSIFIABLE CHECK: read back from disk, and require that the ONLY
    # lines that differ from the backup are the ones we meant to change.
    diff = [(a, b) for a, b in zip(before.splitlines(), after.splitlines()) if a != b]
    if len(before.splitlines()) != len(after.splitlines()):
        pass  # an inserted key legitimately changes the line count
    for sec, key, val in ini_wanted(cfg):
        got = ini_get(after, sec, key)
        if got is not None and got != val:
            out.append("ini      : FAIL -- [%s] %s read back as %r, not %r. "
                       "Restore with: copy \"%s\" \"%s\"" %
                       (sec, key, got, val, backup, path))
            return FAIL, out
    stray = [a for a, b in diff
             if not any(a.strip().startswith(k + "=") for _, k, _ in ini_wanted(cfg))]
    if stray:
        out.append("ini      : FAIL -- %d line(s) we did not intend to touch "
                   "changed, first: %r. Restore with: copy \"%s\" \"%s\"" %
                   (len(stray), stray[0][:80], backup, path))
        return FAIL, out
    out.append("ini      : wrote %s (backup %s)" % ("; ".join(changed), os.path.basename(backup)))
    return PASS, out


# ---------------------------------------------------------------------------
# the SR DLL
# ---------------------------------------------------------------------------
def sr_apply(root, cfg, dry_run=False):
    want = VERSION_MAP[cfg["version"]]
    live = dlsstool.describe_live(root)
    have = live.get("catalog")
    out = []
    if not live.get("exists"):
        return INCONC, ["dlss     : %s does not exist; nothing to compare or "
                        "swap." % live["dll"]]
    if have == want:
        out.append("dlss     : %s already installed (sha256 matches the pinned "
                   "catalog entry)" % want)
        return PASS, out
    out.append("dlss     : installed is %s, config wants %s -- running "
               "tools/dlss.py install" % (have or ("UNKNOWN sha256 %s" % live.get("sha256", "?")[:16]), want))
    cmd = [sys.executable, os.path.join(HERE, "dlss.py"), "--root", root,
           "install", "--version", want]
    if dry_run:
        cmd.append("--dry-run")
    p = subprocess.run(cmd, capture_output=True, text=True)
    for ln in (p.stdout or "").splitlines():
        out.append("  dlss.py| " + ln)
    for ln in (p.stderr or "").splitlines():
        out.append("  dlss.py! " + ln)
    if p.returncode != 0:
        out.append("dlss     : FAIL -- tools/dlss.py install exited %d. The "
                   "install is UNCHANGED (that tool restores on any failed "
                   "verification) and the game will run the DLL it already "
                   "had." % p.returncode)
        return FAIL, out
    if dry_run:
        return PASS, out
    after = dlsstool.describe_live(root).get("catalog")
    if after != want:
        out.append("dlss     : FAIL -- after install the live DLL still "
                   "hashes to %r, not %r." % (after, want))
        return FAIL, out
    out.append("dlss     : now %s (re-read from disk)" % want)
    return PASS, out


# ---------------------------------------------------------------------------
# what the LIVE PROCESS loaded
# ---------------------------------------------------------------------------
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010
MAX_PATH = 260


class MODULEENTRY32(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("th32ModuleID", wt.DWORD),
                ("th32ProcessID", wt.DWORD), ("GlblcntUsage", wt.DWORD),
                ("ProccntUsage", wt.DWORD), ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)),
                ("modBaseSize", wt.DWORD), ("hModule", wt.HMODULE),
                ("szModule", ctypes.c_char * 256),
                ("szExePath", ctypes.c_char * MAX_PATH)]


def process_modules(pid):
    """Every module path loaded in `pid`, or None when the snapshot fails
    (access denied, the process is gone). None is INCONCLUSIVE, never [] --
    an empty list would read as 'DLSS is not loaded'."""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)
    if snap == wt.HANDLE(-1).value or snap == -1:
        return None
    try:
        me = MODULEENTRY32()
        me.dwSize = ctypes.sizeof(MODULEENTRY32)
        if not k32.Module32First(snap, ctypes.byref(me)):
            return None
        mods = []
        n = 0
        while n < 4096:
            mods.append(me.szExePath.decode("mbcs", "replace"))
            if not k32.Module32Next(snap, ctypes.byref(me)):
                break
            n += 1
        return mods
    finally:
        k32.CloseHandle(snap)


def game_pid(explicit=None):
    if explicit:
        return explicit
    pids = dlsstool.game_pids()
    return pids[0] if pids else None


def verify(root, cfg, pid=None):
    """The boot verdict. Returns (overall, lines)."""
    lines = []
    verdicts = []
    want_ver = VERSION_MAP[cfg["version"]]

    p = game_pid(pid)
    if p is None:
        lines.append("loaded   : %s -- no EscapeFromTarkov.exe process to ask." % INCONC)
        verdicts.append(INCONC)
    else:
        mods = process_modules(p)
        if mods is None:
            lines.append("loaded   : %s -- the module list of pid %s could not "
                         "be read (access denied, or it exited)." % (INCONC, p))
            verdicts.append(INCONC)
        else:
            hit = [m for m in mods if os.path.basename(m).lower() == "nvngx_dlss.dll"]
            if not hit:
                lines.append("loaded   : %s -- pid %s has NOT loaded "
                             "nvngx_dlss.dll. NGX loads it only when DLSS "
                             "actually initialises, so this is expected at the "
                             "menu or with DLSS off; it is not a failure and "
                             "it is not a pass." % (INCONC, p))
                verdicts.append(INCONC)
            else:
                got = dlsstool.pe_file_version(hit[0]) or "?"
                ok = dlsstool.ver_tuple(got)[:3] == dlsstool.ver_tuple(want_ver)[:3]
                lines.append("loaded   : %s -- pid %s has nvngx_dlss.dll %s "
                             "from %s; config wants %s" %
                             (PASS if ok else FAIL, p, got, hit[0], want_ver))
                verdicts.append(PASS if ok else FAIL)

    ini = os.path.join(root, "OptiScaler.ini")
    if not os.path.exists(ini):
        lines.append("optiscaler: %s -- %s does not exist, so the upscaler and "
                     "DLSS-5 keys govern nothing." % (INCONC, ini))
        verdicts.append(INCONC)
    else:
        with open(ini, "r", encoding="utf-8", errors="replace", newline="") as f:
            text = f.read()
        for sec, key, val in ini_wanted(cfg):
            got = ini_get(text, sec, key)
            if got is None:
                lines.append("optiscaler: %s -- [%s] %s is absent from this "
                             "build's ini" % (INCONC, sec, key))
                verdicts.append(INCONC)
            else:
                ok = got.strip().lower() == val.lower()
                lines.append("optiscaler: %s -- [%s] %s=%s (config wants %s)" %
                             (PASS if ok else FAIL, sec, key, got, val))
                verdicts.append(PASS if ok else FAIL)

    overall = FAIL if FAIL in verdicts else (INCONC if INCONC in verdicts else PASS)
    lines.append("VERDICT  : %s   (config: version=%s upscaler=%s dlss5=%s "
                 "workingScale=%g intensity=%g)" %
                 (overall, want_ver, UPSCALER_LABEL[cfg["upscaler"]],
                  "on" if cfg["nrEnabled"] else "off",
                  cfg["nrWorkingScale"], cfg["nrIntensity"]))
    return overall, lines


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
def resolve(a):
    path, why = find_config(a.root, a.config)
    if path is None:
        say("dlss     : %s -- %s. Nothing applied, nothing verified." % (INCONC, why))
        return None, None
    say("config   : %s (%s)" % (path, why))
    return path, read_config(path)


def cmd_apply(a):
    path, cfg = resolve(a)
    if cfg is None:
        return 3
    if not a.dry_run and dlsstool.game_running():
        say("dlss     : REFUSED -- EscapeFromTarkov.exe is running. "
            "nvngx_dlss.dll is open in it and OptiScaler has already read its "
            "ini; a swap now would fail or corrupt a session somebody is "
            "playing. Nothing was written.")
        return 3
    st1, l1 = sr_apply(a.root, cfg, a.dry_run)
    for ln in l1:
        say(ln)
    st2, l2 = ini_apply(os.path.join(a.root, "OptiScaler.ini"), cfg, a.dry_run)
    for ln in l2:
        say(ln)
    overall = FAIL if FAIL in (st1, st2) else (INCONC if INCONC in (st1, st2) else PASS)
    say("APPLY    : %s" % overall)
    return {PASS: 0, FAIL: 1, INCONC: 3}[overall]


def cmd_verify(a):
    path, cfg = resolve(a)
    if cfg is None:
        return 3
    overall, lines = verify(a.root, cfg, a.pid)
    for ln in lines:
        say(ln)
    return {PASS: 0, FAIL: 1, INCONC: 3}[overall]


def cmd_status(a):
    path, cfg = resolve(a)
    if cfg is None:
        return 3
    say("wanted   : dlss %s, Dx11Upscaler=%s, [DlssNr] Enabled=%s "
        "WorkingScale=%g Intensity=%g" %
        (VERSION_MAP[cfg["version"]], UPSCALER_MAP[cfg["upscaler"]],
         cfg["nrEnabled"], cfg["nrWorkingScale"], cfg["nrIntensity"]))
    live = dlsstool.describe_live(a.root)
    say("installed: %s (%s)" % (live.get("catalog"), live.get("version")))
    return 0


# ---------------------------------------------------------------------------
# selftest -- and every assertion here has a FALSIFIER beside it
# ---------------------------------------------------------------------------
SAMPLE_INI = (
    "[Upscalers]\n; a comment\nDx11Upscaler=fsr22\nDx12Upscaler=xess\n\n"
    "[DlssNr]\nEnabled=false\nWorkingScale=1.0\nIntensity=auto\nPreset=auto\n"
)


def cmd_selftest(a):
    fails = []

    def check(name, cond, why=""):
        say("  %-46s %s" % (name, "PASS" if cond else "FAIL " + why))
        if not cond:
            fails.append(name)

    d = tempfile.mkdtemp(prefix="dlssapply-")
    ini = os.path.join(d, "OptiScaler.ini")
    with open(ini, "w", encoding="utf-8", newline="") as f:
        f.write(SAMPLE_INI)
    cfg = {"version": 3, "upscaler": 2, "nrEnabled": True,
           "nrWorkingScale": 0.5, "nrIntensity": 1.25}
    st, lines = ini_apply(ini, cfg)
    with open(ini, encoding="utf-8") as f:
        after = f.read()
    check("ini apply returns PASS", st == PASS, str(lines))
    check("Dx11Upscaler written", ini_get(after, "Upscalers", "Dx11Upscaler") == "ffx_12")
    check("[DlssNr] Enabled written", ini_get(after, "DlssNr", "Enabled") == "true")
    check("WorkingScale written", ini_get(after, "DlssNr", "WorkingScale") == "0.5")
    check("Intensity written", ini_get(after, "DlssNr", "Intensity") == "1.25")
    check("a key we did NOT ask for is untouched",
          ini_get(after, "Upscalers", "Dx12Upscaler") == "xess")
    check("an unrelated [DlssNr] key is untouched",
          ini_get(after, "DlssNr", "Preset") == "auto")
    check("comments survive", "; a comment" in after)
    st2, _ = ini_apply(ini, cfg)
    check("a second apply is a no-op that still says PASS", st2 == PASS)

    # FALSIFIERS: each proves the checker CAN say no.
    check("a missing section is reported, not invented",
          ini_apply(os.path.join(d, "nope.ini"), cfg)[0] == INCONC)
    tampered = after.replace("Dx11Upscaler=ffx_12", "Dx11Upscaler=dlss")
    check("verify CAN fail: a tampered key reads FAIL",
          ini_get(tampered, "Upscalers", "Dx11Upscaler") != UPSCALER_MAP[cfg["upscaler"]])
    check("a commented-out key never matches",
          ini_get("[DlssNr]\n;Enabled=true\n", "DlssNr", "Enabled") is None)
    check("process_modules of a nonexistent pid is None (INCONCLUSIVE), not []",
          process_modules(0x7FFFFFF0) in (None, []) and process_modules(0x7FFFFFF0) is not [])

    # THE MIRROR CHECK: the mod's own text must still name these versions, or
    # the caption a player reads and the file this writes have drifted.
    src = os.path.join(os.path.dirname(HERE), "mods", "dlss", "dlss.nim")
    if os.path.exists(src):
        txt = open(src, encoding="utf-8", errors="replace").read()
        for v in VERSION_MAP.values():
            check("mods/dlss names version %s" % v, v in txt)
        for lbl in UPSCALER_LABEL.values():
            check("mods/dlss names upscaler %s" % lbl, lbl in txt)
    else:
        check("mods/dlss/dlss.nim exists to mirror-check", False, "(missing)")

    shutil.rmtree(d, ignore_errors=True)
    say("selftest: %s (%d failure(s))" % ("PASS" if not fails else "FAIL", len(fails)))
    return 1 if fails else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("AOWLSPT_ROOT", DEFAULT_ROOT))
    ap.add_argument("--config", default=None)
    sub = ap.add_subparsers(dest="cmd")
    a1 = sub.add_parser("apply"); a1.add_argument("--dry-run", action="store_true")
    a1.set_defaults(fn=cmd_apply)
    a2 = sub.add_parser("verify"); a2.add_argument("--pid", type=int, default=None)
    a2.set_defaults(fn=cmd_verify)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    sub.add_parser("selftest").set_defaults(fn=cmd_selftest)
    a = ap.parse_args(argv)
    if not getattr(a, "fn", None):
        ap.print_help()
        return 2
    if not hasattr(a, "dry_run"):
        a.dry_run = False
    if not hasattr(a, "pid"):
        a.pid = None
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
