#!/usr/bin/env python
"""PreToolUse guard: refuse to run a compiler through the Bash (Git Bash) tool.

The single failure this exists to prevent:

  * gcc invoked from Git Bash exits 1 with NO output and no diagnostic. The
    build then "fails" in a way that points at innocent code, and hours go into
    debugging a change that was fine.
  * Hand-invoking nimony.exe directly exits 0 and produces NOTHING. A green exit
    code is taken as success and the artifact is never written.

Both are silent, both have cost real time, and both are avoided by using the
PowerShell tool instead. That is a narrow, checkable condition, which is why
this is a hook and the rest of the workflow is skills.

Contract: stdin is the PreToolUse JSON payload. Exit 2 blocks the call and shows
stderr to the model. Any other exit is non-blocking. Anything unexpected is
allowed through -- a guard that fires wrongly is worse than no guard.
"""

import json
import re
import sys

# Executed compiler invocations. Anchored to a command position (start of the
# string, or just after a shell separator) so that reading, grepping or echoing
# these words is never blocked.
COMPILERS = r"(?:gcc|g\+\+|cc1|clang|ld\.lld|lld|nimony(?:\.exe)?|aowl(?:\.exe)?)"
COMMAND_POSITION = re.compile(
    r"(?:^|[|&;]|\$\(|`|\bthen\b|\bdo\b|\belse\b)\s*"     # start or separator
    r"(?:[A-Za-z]:)?[\w./\\$%{}~+-]*[/\\]?"                # optional path prefix
    + COMPILERS
    + r"(?:\.exe)?\b",
    re.IGNORECASE,
)

ADVICE = (
    "BLOCKED: compilers must not be run through the Bash tool in this repo.\n"
    "\n"
    "  * gcc under Git Bash exits 1 with no output at all -- the build then\n"
    "    fails pointing at code you never touched.\n"
    "  * a raw nimony invocation exits 0 and writes nothing.\n"
    "\n"
    "Use the PowerShell tool instead:\n"
    "\n"
    "    & .\\installer\\build\\aowl.exe build\n"
    "\n"
    "and check for a concurrent build first (shared nimcache):\n"
    "\n"
    "    Get-Process nimony,aowl,gcc -ErrorAction SilentlyContinue\n"
    "\n"
    "See the aowlspt-build skill. Bash remains fine for reading and grepping."
)


def strip_inert(command: str) -> str:
    """Blank out regions the shell cannot execute anything in.

    A backtick is a genuine command position -- `gcc foo` runs gcc -- so it
    stays in COMMAND_POSITION. But inside a QUOTED heredoc (<<'EOF') or a
    single-quoted string, a backtick is literal text. Prose mentioning
    `aowl build` in a doc comment or a commit message is not an invocation,
    and blocking it stopped an agent from writing a source file and from
    committing with `git commit -F -`.

    Only quoted heredocs are stripped. An UNQUOTED heredoc (<<EOF) does
    perform substitution, so it is left alone and still checked.
    """
    out = command

    # Quoted heredocs: <<'WORD' ... WORD  /  <<"WORD" ... WORD
    def _drop_heredoc(m):
        return m.group(0)[: m.start(2) - m.start(0)] + " " * (m.end(2) - m.start(2))

    out = re.sub(
        r"<<-?\s*(['\"])(\w+)\1(.*?)^\s*\2",
        lambda m: m.group(0)[:m.start(3) - m.start(0)]
        + re.sub(r"\S", " ", m.group(3)),
        out,
        flags=re.S | re.M,
    )

    # Single-quoted strings: no substitution of any kind inside.
    out = re.sub(r"'[^']*'", lambda m: " " * len(m.group(0)), out)

    # Double-quoted strings DO substitute `...` and $(...), so those stay --
    # but | ; & are NOT command separators inside them. Neutralise only those,
    # so a grep pattern like "a\|aowl b" is not read as a pipeline.
    # (Measured: `grep -n "fields\|aowl bootstrap" CLAUDE.md` was blocked.)
    out = re.sub(
        r'"[^"]*"',
        lambda m: re.sub(r"[|;&]", " ", m.group(0)),
        out,
    )
    return out


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # unparseable input is not grounds for blocking

    if payload.get("tool_name") != "Bash":
        return 0

    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip():
        return 0

    if not COMMAND_POSITION.search(strip_inert(command)):
        return 0

    sys.stderr.write(ADVICE + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
