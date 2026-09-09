#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The launcher must not drive the live inspector unless it was ASKED to.

WHY THIS EXISTS
---------------
MEASURED 2026-09-02: a normal boot of `aowlspt-launch.exe` wrote nine batches
into `aowlspt-inspect.txt` in its first 22 seconds -- eight `roots` polls and
then a 58-command batch carrying `allow write` and 29
`call name:get_activeInHierarchy` -- with nobody having asked for any of them.
That was the launcher's auto-enter, and it was redundant: the HOST answers the
character/mode screen natively on every boot (`modeskip.nim`, flag
`uxSkipModeScreen`; host log `skip mode screen: Submit called for profile ...`
at ~26s). The channel is single-writer and single-batch, so that traffic also
delayed every other tool's batch and left its own probe batch on disk for the
next boot to run.

So auto-enter is now OFF unless `--auto-enter` is passed, `--no-auto-enter` is
accepted and ignored, and this file is the check on that.

WHAT IS ASSERTED, AND WHAT IS NOT -- read this before trusting a green run.

  1. DEFAULT PLAN. The launcher's own `--dry-run` plan, which is produced from
     the same `o.autoEnter` the real run branches on, says it would enter
     nothing and write nothing to the channel.
  2. POSITIVE CONTROL ON THAT LINE. With `--auto-enter` the SAME plan says the
     opposite. Without this, check 1 could be passing because the string moved
     or the run died before printing it.
  3. `--no-auto-enter` is still accepted and reaches the same decision, so
     existing scripts and shortcuts are not broken by the flip.
  4. NO CHANNEL WRITE. A real (non-dry) default-flag run against a scratch
     install leaves no `aowlspt-inspect.txt` behind.
  5. POSITIVE CONTROL ON THE DETECTOR. `channel.py` -- the transport the MCP
     server, `inspector.py` and `acceptance.py` all use -- is pointed at the
     SAME scratch directory and DOES create that file. Without this, check 4
     passes vacuously for any wrong path, wrong flag or wrong temp dir.

  NOT ASSERTED, and this is the honest gap: nothing here boots a client, so
  the `--auto-enter` side of check 4 -- "with --auto-enter it writes" -- is
  NOT exercised. The auto-enter block only runs after a successful process
  start AND a successful host injection into a real IL2CPP client, neither of
  which a scratch install can provide, so a subprocess test can reach the
  decision but never the traffic. Proving the write side needs a live boot with
  `--auto-enter` and a grep of `aowlspt-inspect.txt` for a
  `aowl-batch-launch<pid>-` sentinel. Until that is run, treat "with
  --auto-enter it still works" as UNVERIFIED, not as passing.

Run:  python tools/test_autoenter.py

Three outcomes, never two: PASS / FAIL / SKIP (inconclusive). Exit 0 only if
nothing FAILED and nothing was SKIPped.
"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCH = os.path.join(REPO, "installer", "build", "aowlspt-launch.exe")
MCP = os.path.join(REPO, "plugins", "aowlsptcode", "mcp")

results = []


def record(name, verdict, detail):
    results.append((name, verdict, detail))
    print("%-5s %-52s %s" % (verdict, name, detail))


def make_install(tmp):
    """An install-shaped scratch tree.

    Only existence is checked by the launcher before the dry-run plan, so the
    files are empty -- except that an empty exe identifies as a non-IL2CPP
    client, which is why every run below passes --force. That refusal is real
    and is not what this file is testing.
    """
    inner = os.path.join(tmp, "aowlspt")
    os.makedirs(inner, exist_ok=True)
    for p in (os.path.join(tmp, "EscapeFromTarkov.exe"),
              os.path.join(inner, "aowlspt-host-il2cpp.dll")):
        with open(p, "wb") as f:
            f.write(b"")
    with open(os.path.join(inner, "backend.json"), "w", newline="\n") as f:
        f.write('{"url":"http://127.0.0.1:6969/"}\n')
    return tmp


def cmd_path(root):
    return os.path.join(root, "aowlspt", "aowlspt-inspect.txt")


def run(root, extra, timeout=90):
    args = [LAUNCH, "--root", root, "--plain", "--force", "--no-backend",
            "--no-mod-build"] + list(extra)
    return subprocess.run(args, capture_output=True, text=True,
                          timeout=timeout, cwd=REPO)


def main():
    if not os.path.exists(LAUNCH):
        record("launcher binary present", "SKIP",
               "no %s -- build it with `python tools/buildlock.py build "
               "launch`; NOTHING was tested" % LAUNCH)
        return 1

    tmp = make_install(tempfile.mkdtemp(prefix="aowl-autoenter-"))
    try:
        # 1 + 2 + 3: the decision, both ways, plus the compatibility flag.
        r = run(tmp, ["--dry-run"])
        out = (r.stdout or "") + (r.stderr or "")
        if "would enter   nothing" in out and "uxSkipModeScreen" in out:
            record("default: plan says it enters nothing", "PASS",
                   "and names the host path that replaces it")
        elif "would enter" in out:
            record("default: plan says it enters nothing", "FAIL",
                   "the plan line is present but says: %s"
                   % _line(out, "would enter"))
        else:
            record("default: plan says it enters nothing", "FAIL",
                   "no auto-enter line in the plan at all (exit %d) -- the "
                   "run may not have reached it" % r.returncode)

        r2 = run(tmp, ["--dry-run", "--auto-enter"])
        out2 = (r2.stdout or "") + (r2.stderr or "")
        if "would enter   character-select itself" in out2:
            record("--auto-enter: plan says it DOES enter", "PASS",
                   "so the check above can distinguish the two")
        else:
            record("--auto-enter: plan says it DOES enter", "FAIL",
                   "exit %d -- the check above proves nothing, because the "
                   "plan cannot say the opposite" % r2.returncode)

        r3 = run(tmp, ["--dry-run", "--no-auto-enter"])
        out3 = (r3.stdout or "") + (r3.stderr or "")
        if r3.returncode == 0 and "would enter   nothing" in out3:
            record("--no-auto-enter still accepted (no-op)", "PASS",
                   "exit 0, same decision as the default")
        else:
            record("--no-auto-enter still accepted (no-op)", "FAIL",
                   "exit %d -- an existing script passing this flag would "
                   "now break" % r3.returncode)

        # 4: a REAL run, no --dry-run. It fails at starting the empty exe,
        # which is the point: nothing on the way there may touch the channel.
        if os.path.exists(cmd_path(tmp)):
            os.remove(cmd_path(tmp))
        r4 = run(tmp, [])
        wrote = os.path.exists(cmd_path(tmp))
        if not wrote:
            record("default: writes no aowlspt-inspect.txt", "PASS",
                   "real run, exit %d, command file absent" % r4.returncode)
        else:
            with open(cmd_path(tmp), "r", errors="replace") as f:
                body = f.read()
            record("default: writes no aowlspt-inspect.txt", "FAIL",
                   "the launcher wrote %d bytes to the channel unasked: %r"
                   % (len(body), body[:120]))

        # 5: the detector's own positive control.
        sys.path.insert(0, MCP)
        try:
            import channel
        except ImportError as e:
            record("a real writer DOES create that file (control)", "SKIP",
                   "channel.py could not be imported (%s), so check 4 is "
                   "unproven -- it may be watching the wrong path" % e)
        else:
            try:
                channel.run_batch(["state"], live_dir=os.path.join(
                    tmp, "aowlspt"), timeout=0.6)
            except Exception:
                pass          # nothing answers a scratch dir; the WRITE is the point
            if os.path.exists(cmd_path(tmp)):
                record("a real writer DOES create that file (control)", "PASS",
                       "channel.py's batch landed where check 4 was looking")
            else:
                record("a real writer DOES create that file (control)", "FAIL",
                       "even a deliberate write did not appear at %s -- "
                       "check 4 cannot fail and proves nothing"
                       % cmd_path(tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    bad = sum(1 for _, v, _ in results if v == "FAIL")
    skipped = sum(1 for _, v, _ in results if v == "SKIP")
    print("\n%d passed, %d failed, %d skipped (a skip is not a pass)"
          % (len(results) - bad - skipped, bad, skipped))
    return 1 if (bad or skipped) else 0


def _line(text, needle):
    for l in text.splitlines():
        if needle in l:
            return l.strip()
    return "(not found)"


if __name__ == "__main__":
    sys.exit(main())
