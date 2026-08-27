#!/usr/bin/env python3
"""Assert what `.claude/hooks/no-context-bombs.py` blocks and what it does not.

A hook that fires wrongly is worse than no hook, so the ALLOW cases below are
the important half of this file. Run after any edit to the hook:

    python tools/hooktest.py
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(HERE, ".claude", "hooks", "no-context-bombs.py")

BLOCK, ALLOW = "BLOCK", "ALLOW"

CASES = [
    # --- must BLOCK -------------------------------------------------------- #
    (BLOCK, "Bash", {"command": "cat /d/Aowlspt/aowlspt/db.json"}, "cat the 41 MB db"),
    (BLOCK, "Bash", {"command": "head -1 mods/tarkov/data/post1/locale_en.json"}, "head -1 of a one-line file"),
    (BLOCK, "Bash", {"command": "grep -n 'PROBE RES' /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "uncapped grep of backend log"),
    (BLOCK, "Bash", {"command": "rg Nickname mods/tarkov/data/capture/raid1/responses/large/045.json"}, "uncapped rg of an 18 MB capture"),
    (BLOCK, "Bash", {"command": "grep Chances mods/tarkov/data/post1/locations.json"}, "uncapped grep of locations.json"),
    (BLOCK, "PowerShell", {"command": "Get-Content D:\\Aowlspt\\aowlspt\\db.json"}, "Get-Content the db"),
    (BLOCK, "PowerShell", {"command": "Select-String -Pattern err -Path D:\\Aowlspt\\aowlspt\\nettrace.log"}, "uncapped Select-String"),
    (BLOCK, "Bash", {"command": "cat /d/Aowlspt/aowlspt/aowlspt-host.log"}, "whole-file cat of host log"),
    (BLOCK, "Bash", {"command": "cat ~/AppData/Local/Temp/claude/x/tasks/a28697f2f3cd466e3.output"}, "subagent transcript"),
    (BLOCK, "Read", {"file_path": "D:\\Aowlspt\\aowlspt\\db.json"}, "Read the db, no window"),
    (BLOCK, "Read", {"file_path": "C:/Users/savant/Projects/aowlspt/mods/tarkov/data/post1/locale_en.json", "offset": 0, "limit": 50}, "Read one-line file WITH a window"),
    (BLOCK, "Read", {"file_path": "/tmp/claude/s/tasks/abc123.output"}, "Read a transcript"),
    (BLOCK, "Bash", {"command": "ls -la && cat mods/tarkov/data/capture/raid1/responses/large/076.json"}, "reader after a separator"),

    # --- must ALLOW -------------------------------------------------------- #
    (ALLOW, "Bash", {"command": "python tools/bigjson.py keys /d/Aowlspt/aowlspt/db.json"}, "the accessor itself"),
    (ALLOW, "Bash", {"command": "python tools/wirelog.py nettrace --grep quest"}, "wirelog on nettrace"),
    (ALLOW, "Bash", {"command": "python tools/hostlog.py summary"}, "hostlog"),
    (ALLOW, "Bash", {"command": "ls -la /d/Aowlspt/aowlspt/db.json"}, "sizing a huge file"),
    (ALLOW, "Bash", {"command": "wc -c mods/tarkov/data/post1/locale_en.json"}, "wc on a huge file"),
    (ALLOW, "Bash", {"command": "stat -c%s /d/Aowlspt/aowlspt/nettrace.log"}, "stat"),
    (ALLOW, "Bash", {"command": "cp db.json db.json.bak"}, "copying the db"),
    (ALLOW, "Bash", {"command": "rm -f /d/Aowlspt/aowlspt/nettrace.log"}, "deleting a log"),
    (ALLOW, "Bash", {"command": "grep -c PROBE /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "grep -c is capped"),
    (ALLOW, "Bash", {"command": "grep -o 'PROBE RES [^ ]*' /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "grep -o is capped"),
    (ALLOW, "Bash", {"command": "grep -l Nickname mods/tarkov/data/capture/raid1/responses/large/045.json"}, "grep -l is capped"),
    (ALLOW, "Bash", {"command": "rg --max-columns 200 err D:/Aowlspt/aowlspt/nettrace.log"}, "rg with --max-columns"),
    (ALLOW, "Bash", {"command": "tail -30 /d/Aowlspt/aowlspt/aowlspt-host.log"}, "bounded tail of the 14 KB host log"),
    (ALLOW, "Bash", {"command": "grep -n FAULTED /d/Aowlspt/aowlspt/aowlspt-host.log"}, "grep of the host log"),
    (ALLOW, "Bash", {"command": "cat README.md"}, "cat an ordinary file"),
    (ALLOW, "Bash", {"command": "grep -rn il2cpp host/"}, "ordinary source grep"),
    (ALLOW, "Bash", {"command": "git status && git diff --stat"}, "git"),
    (ALLOW, "Read", {"file_path": "C:/Users/savant/Projects/aowlspt/README.md"}, "Read an ordinary file"),
    (ALLOW, "Read", {"file_path": "C:/Users/savant/Projects/aowlspt/tools/hostlog.py", "offset": 100, "limit": 50}, "windowed Read"),
    (ALLOW, "PowerShell", {"command": "Get-Content D:\\Aowlspt\\aowlspt\\aowlspt-host.log -Tail 40"}, "bounded Get-Content of host log"),
    (ALLOW, "PowerShell", {"command": "Get-Item D:\\Aowlspt\\aowlspt\\db.json | Select-Object Length"}, "Get-Item sizing"),
    (ALLOW, "Bash", {"command": "echo 'do not cat db.json'"}, "merely mentioning it"),
    (ALLOW, "Edit", {"file_path": "D:/Aowlspt/aowlspt/db.json"}, "a non-read tool"),

    # --- bounded reads: the direction this guard used to get WRONG ---------- #
    #
    # `tail -40 aowlspt-backend.log` -- forty lines -- was BLOCKED, and an
    # agent got past it by assembling the path from a shell variable. A guard
    # cheaper to evade than to obey teaches evasion, so the rule is now the
    # READ INTENT: an unbounded reader is blocked, a reader that states its own
    # bound is not. Both directions are asserted here on purpose; a fix seen to
    # succeed only one way is not verified.
    (ALLOW, "Bash", {"command": "tail -40 /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "tail -40 of the backend log"),
    (ALLOW, "Bash", {"command": "tail -n 40 D:/Aowlspt/aowlspt/aowlspt-backend.log"}, "tail -n 40 of the backend log"),
    (ALLOW, "Bash", {"command": "head -n 20 D:/Aowlspt/aowlspt/nettrace.log"}, "head -n 20 of nettrace"),
    (ALLOW, "Bash", {"command": "tail --lines=30 /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "tail --lines=30"),
    (ALLOW, "Bash", {"command": "tail -c 2000 D:/Aowlspt/aowlspt/nettrace.log"}, "a 2 KB byte bound"),
    (ALLOW, "Bash", {"command": "head -c 4096 D:/Aowlspt/aowlspt/db.json"}, "a byte bound is honest even on a one-line file"),
    (ALLOW, "PowerShell", {"command": "Get-Content D:/Aowlspt/aowlspt/nettrace.log -Tail 50"}, "bounded Get-Content of nettrace"),
    (ALLOW, "Bash", {"command": "mv D:/Aowlspt/aowlspt/db.json /tmp/x"}, "moving the db"),

    # ...and the bounds that are not bounds. These MUST still block.
    (BLOCK, "Bash", {"command": "tail -n 5 D:/Aowlspt/aowlspt/db.json"}, "a line bound on a ONE-LINE file is a lie"),
    (BLOCK, "Bash", {"command": "head -n 1 mods/tarkov/data/post1/locale_en.json"}, "one line of a one-line file"),
    (BLOCK, "Bash", {"command": "head -c D:/Aowlspt/aowlspt/db.json"}, "-c with no number is not a cap"),
    (BLOCK, "Bash", {"command": "head -c 900000 D:/Aowlspt/aowlspt/db.json"}, "900 KB is not a cap"),
    (BLOCK, "Bash", {"command": "tail -n 5000 /d/Aowlspt/aowlspt/aowlspt-backend.log"}, "5000 PROBE lines is not a bound"),
    (BLOCK, "Bash", {"command": "less D:/Aowlspt/aowlspt/nettrace.log"}, "an unbounded pager"),
]


def run(tool, tool_input):
    payload = {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}
    p = subprocess.run(
        [sys.executable, HOOK], input=json.dumps(payload),
        capture_output=True, text=True,
    )
    blocked = p.returncode == 2
    if p.stdout.strip():
        try:
            d = json.loads(p.stdout)
            if d["hookSpecificOutput"]["permissionDecision"] == "deny":
                blocked = True
        except Exception:
            pass
    return blocked, (p.stderr or "").strip()


def main():
    fails = 0
    for want, tool, ti, label in CASES:
        blocked, msg = run(tool, ti)
        got = BLOCK if blocked else ALLOW
        ok = got == want
        fails += not ok
        print("%s  %-5s %-8s %s" % ("PASS" if ok else "FAIL", got, tool, label))
        if ok and want == BLOCK:
            assert "INSTEAD" in msg, "block message must name the replacement: %s" % label
    print("\n%d case(s), %d failure(s)." % (len(CASES), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
