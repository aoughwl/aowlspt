#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""inspectfixtures.py -- ONE corpus of measured live-inspector prose, and the
offline Replay that serves it.

    python tools/inspectfixtures.py list
    python tools/inspectfixtures.py show find-stopped-early
    python tools/inspectfixtures.py lint
    python tools/inspectfixtures.py selftest      # lint + every consumer's own

WHY THIS FILE EXISTS (measured 2026-09-01/02)
---------------------------------------------
Three tools parse the inspector's prose -- `tools/acceptance.py`,
`tools/nativetabs_check.py`, `tools/uihooks_check.py` -- and each had grown its
own private idea of what that prose looks like. Two of them then passed
VACUOUSLY, on input the host never printed as an answer:

  * acceptance.py classified walk completeness over the WHOLE reply, so it
    matched the batch HEADER (`... on Unity thread 1192`) and reported
    `walk was UNKNOWN -- n Unity thread 1192`;
  * nativetabs_check.py's baseline matched any line containing `rect`, and the
    inspector ECHOES every command, so it recorded the string `> rect $_` as
    the stock geometry and `verify` then compared that echo to itself. A check
    that compares its own input cannot fail.

Both were fixed one at a time, against fixtures each tool wrote for itself.
That is the shape of the next bug, not its end: a second private corpus can
drift from the host exactly as a second parser can. So there is one corpus,
under `tools/fixtures/inspector/`, holding VERBATIM host output for real
commands, including the refusals -- and a Replay that REFUSES any command it
has no recording for.

THE RULE THIS ENFORCES
----------------------
An unrecorded command raises. It never returns "" and never returns None.
An empty answer is how a check that cannot fail gets built: every parser in
this repo maps empty input to "found nothing", and "found nothing" is one
sloppy line away from being reported as a pass. If a test needs a command, it
records the command.

`lint` is the second half of that: every fixture file must carry a batch
header, a batch trailer and at least one `>` echo, so an ECHO-TRAP test --
feed a parser only the command echoes and assert it extracts nothing -- is
always constructible for every verb. A corpus that made the echo trap
impossible to write would have hidden the exact bug above.
"""

import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXDIR = os.path.join(HERE, "fixtures", "inspector")

HDR_RE = re.compile(r"^\s*aowlspt live inspector -- batch \d+, \d+ command\(s\)")
TRL_RE = re.compile(r"^\s*aowlspt live inspector -- batch \d+ complete")
ECHO_RE = re.compile(r"^\s*>\s?(.*)$")


class FixtureError(Exception):
    """A corpus problem. Named and raised, never swallowed into a default."""


class Entry(object):
    __slots__ = ("eid", "path", "source", "shape", "command", "output")

    def __init__(self, eid, path, source, shape, command, output):
        self.eid = eid
        self.path = path
        self.source = source
        self.shape = shape
        self.command = command
        self.output = output

    @property
    def verb(self):
        """The fixture FILE stem -- `find`, `rect`, `_hostlog`, ..."""
        return os.path.splitext(os.path.basename(self.path))[0]

    @property
    def is_hostlog(self):
        """`_`-prefixed files hold host-log lines, not inspector batches, and
        are exempt from the batch-shape lint BY NAME rather than by a special
        case that could quietly be widened."""
        return os.path.basename(self.path).startswith("_")

    def __repr__(self):
        return "<Entry %s from %s>" % (self.eid, self.verb)


def _parse_file(path):
    entries = []
    cur = None
    body = None
    with io.open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip("\r")
            if body is not None:
                if line == "--- END":
                    cur["output"] = "\n".join(body)
                    entries.append(Entry(cur["eid"], path, cur["source"],
                                         cur["shape"], cur["command"],
                                         cur["output"]))
                    cur, body = None, None
                else:
                    body.append(line)
                continue
            if line.startswith("=== ENTRY "):
                if cur is not None:
                    raise FixtureError("%s:%d: `=== ENTRY` while %r was still "
                                       "open (missing `--- END`)"
                                       % (path, lineno, cur["eid"]))
                cur = {"eid": line[len("=== ENTRY "):].strip(),
                       "source": "", "shape": "", "command": ""}
                continue
            if cur is None:
                if line.startswith("#") or not line.strip():
                    continue
                raise FixtureError("%s:%d: text outside any entry: %r"
                                   % (path, lineno, line[:60]))
            for tag in ("SOURCE", "SHAPE", "COMMAND"):
                pre = "--- %s " % tag
                if line.startswith(pre):
                    key = tag.lower()
                    val = line[len(pre):].strip()
                    cur[key] = (cur[key] + " " + val).strip() if cur[key] else val
                    break
            else:
                if line == "--- OUTPUT":
                    body = []
                elif line.strip():
                    raise FixtureError("%s:%d: unknown directive %r"
                                       % (path, lineno, line[:60]))
    if cur is not None:
        raise FixtureError("%s: entry %r was never closed with `--- END`"
                           % (path, cur["eid"]))
    return entries


class Corpus(object):
    def __init__(self, entries):
        self.entries = entries
        self.by_id = {}
        for e in entries:
            if e.eid in self.by_id:
                raise FixtureError(
                    "duplicate fixture id %r (in %s and %s). Ids are how tests "
                    "name evidence; two entries with one name means a test can "
                    "silently be handed the other one."
                    % (e.eid, self.by_id[e.eid].path, e.path))
            self.by_id[e.eid] = e

    def get(self, eid):
        try:
            return self.by_id[eid]
        except KeyError:
            near = sorted(k for k in self.by_id if k.split("-")[0] ==
                          eid.split("-")[0])
            raise FixtureError(
                "no fixture %r. This is a REFUSAL, not an empty answer: a test "
                "that got '' here would go on to report 'nothing found' as a "
                "result. Same-verb entries: %s" % (eid, near or "(none)"))

    def output(self, eid):
        return self.get(eid).output

    def ids(self):
        return sorted(self.by_id)


_CORPUS = None


def load(fixdir=None, force=False):
    """The corpus. Cached; `force=True` re-reads (the lint does)."""
    global _CORPUS
    if _CORPUS is not None and not force and fixdir is None:
        return _CORPUS
    d = fixdir or FIXDIR
    if not os.path.isdir(d):
        raise FixtureError("no fixture directory at %s -- the corpus IS the "
                           "evidence; without it these tests prove nothing "
                           "and must not be reported as passing." % d)
    entries = []
    for name in sorted(os.listdir(d)):
        if name.endswith(".txt"):
            entries.extend(_parse_file(os.path.join(d, name)))
    if not entries:
        raise FixtureError("fixture directory %s holds no entries" % d)
    c = Corpus(entries)
    if fixdir is None:
        _CORPUS = c
    return c


def fx(eid):
    """The VERBATIM host text recorded under `eid`. Raises if unknown."""
    return load().output(eid)


# --------------------------------------------------------------------------
# derived views -- used to BUILD the traps, so a trap is always measured text
# --------------------------------------------------------------------------

def echo_only(text):
    """Just the `>` command echoes of `text`, nothing the host answered.

    This is the ECHO TRAP input. Feed it to a parser and the parser must
    extract NOTHING: every line in it is text WE sent, not text the client
    answered. nativetabs_check's baseline once matched exactly this and
    recorded `> rect $_` as the stock geometry."""
    return "\n".join(l for l in text.splitlines() if ECHO_RE.match(l))


def header_only(text):
    """Just the batch header and trailer. The other vacuous-pass input:
    acceptance.py's completeness classifier matched `... on Unity thread 1192`
    out of the HEADER and reported it as a walk verdict."""
    return "\n".join(l for l in text.splitlines()
                     if HDR_RE.match(l) or TRL_RE.match(l))


# --------------------------------------------------------------------------
# Replay
# --------------------------------------------------------------------------

class Replay(object):
    """Offline stand-in for `channel.run_batch`.

    `script` is a list of (batch-prefix, [answer, ...]), where the prefix is
    matched against the WHOLE batch newline-joined -- so "state" still matches
    a one-command batch, and "state
find SettingsList" distinguishes two
    batches that share a first command. Answers are consumed
    in order and the LAST one repeats, because a poll loop asks the same
    question many times. Each answer is either verbatim host text or a fixture
    id -- ids are resolved through the corpus, and an id that is neither a
    known fixture nor multi-line text is an error rather than being passed
    through as if it were an answer.

    AN UNRECORDED COMMAND RAISES AssertionError. It does not return ''. That is
    the whole point of the class: an empty answer reads to every parser here as
    "nothing found", and "nothing found" is one careless line away from being
    printed as a pass.
    """

    def __init__(self, script, corpus=None):
        self.corpus = corpus or load()
        self.script = [(p, [self._resolve(a) for a in answers])
                       for p, answers in script]
        self.sent = []            # first command of each batch
        self.sent_batches = []    # the whole batch, newline-joined
        self._hit = set()

    def _resolve(self, answer):
        if "\n" in answer:
            return answer                      # verbatim text
        if answer in self.corpus.by_id:
            return self.corpus.output(answer)  # fixture id
        raise FixtureError(
            "replay answer %r is neither a known fixture id nor multi-line "
            "host text. A one-line 'answer' is almost always a mistake and "
            "would be handed to a parser as if the client had said it." % answer)

    # channel.run_batch shape: returns (sentinel, text)
    def __call__(self, lines, live_dir=None, timeout=25.0, write=False, **kw):
        # KEYED ON THE WHOLE BATCH, not just its first command. Measured while
        # writing nativetabs_check's selftest: both of its batches begin with
        # `state` (`state / find SettingsList / rect $f1` and `state / find
        # Toggles / children $f1`), so a first-line key silently served the
        # `state` reply to the batch that wanted geometry -- and the geometry
        # parser then correctly found none, which read as "the case passed"
        # for the refusal case and "the tool is broken" for the real one. A
        # prefix may therefore span lines: "state\nfind SettingsList".
        key = "\n".join(lines)
        self.sent.append(lines[0] if lines else "")
        self.sent_batches.append(key)
        for i, (prefix, answers) in enumerate(self.script):
            if key.startswith(prefix):
                self._hit.add(i)
                return "SENTINEL", (answers.pop(0) if len(answers) > 1
                                    else answers[0])
        raise AssertionError(
            "replay has no recording for batch %r. Record it in "
            "tools/fixtures/inspector/ from a real capture -- do NOT relax this "
            "into an empty answer." % key)

    def text_only(self, lines, timeout=25.0, **kw):
        """nativetabs_check.run() shape: returns the text alone."""
        return self(lines, timeout=timeout)[1]

    def unused(self):
        """Scripted prefixes never asked for. A test that scripts an answer it
        never consumes is usually asserting less than it thinks."""
        return [p for i, (p, _a) in enumerate(self.script) if i not in self._hit]


# --------------------------------------------------------------------------
# lint
# --------------------------------------------------------------------------

def lint(fixdir=None):
    """Returns a list of problem strings; empty means clean."""
    problems = []
    try:
        corpus = load(fixdir, force=True)
    except FixtureError as e:
        return [str(e)]

    per_file = {}
    for e in corpus.entries:
        per_file.setdefault(e.path, []).append(e)

    for path, entries in sorted(per_file.items()):
        name = os.path.basename(path)
        for e in entries:
            if not e.source:
                problems.append("%s/%s: no --- SOURCE. An unattributed fixture "
                                "is not evidence." % (name, e.eid))
            if not e.shape:
                problems.append("%s/%s: no --- SHAPE." % (name, e.eid))
            if not e.output.strip():
                problems.append("%s/%s: empty OUTPUT." % (name, e.eid))
            if e.is_hostlog:
                continue
            lines = e.output.splitlines()
            if not any(HDR_RE.match(l) for l in lines):
                problems.append("%s/%s: no batch HEADER line. Without it the "
                                "header-trap test cannot be written for this "
                                "verb." % (name, e.eid))
            if not any(TRL_RE.match(l) for l in lines):
                problems.append("%s/%s: no batch TRAILER line ('batch N "
                                "complete')." % (name, e.eid))
            echoes = [ECHO_RE.match(l).group(1) for l in lines
                      if ECHO_RE.match(l)]
            if not echoes:
                problems.append("%s/%s: no `>` command echo. The ECHO TRAP -- "
                                "feed a parser only the echoes and assert it "
                                "extracts nothing -- is then impossible to "
                                "write, and that trap is the one that caught "
                                "the `> rect $_` baseline bug."
                                % (name, e.eid))
            elif echoes[0].strip() != e.command.strip():
                problems.append("%s/%s: --- COMMAND is %r but the first echo "
                                "in the recorded output is %r. Replay keys on "
                                "COMMAND, so this drift would serve the wrong "
                                "answer." % (name, e.eid, e.command,
                                             echoes[0].strip()))
    return problems


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

CONSUMERS = [
    ("acceptance.py selftest", [sys.executable,
                                os.path.join(HERE, "acceptance.py"),
                                "selftest"]),
    ("nativetabs_check.py selftest", [sys.executable,
                                      os.path.join(HERE, "nativetabs_check.py"),
                                      "selftest"]),
    ("uihooks_check.py selftest", [sys.executable,
                                   os.path.join(HERE, "uihooks_check.py"),
                                   "selftest"]),
]


_BAD_NO_ECHO = """\
=== ENTRY bad-no-echo
--- SOURCE synthetic, built by cmd_selftest
--- SHAPE a batch with a header and a trailer but NO `>` echo
--- COMMAND find Nothing
--- OUTPUT
aowlspt live inspector -- batch 1, 1 command(s), on Unity thread 1
  visited 1 node(s) over 1 frame(s), 0 match(es), frontier 0 node(s)
aowlspt live inspector -- batch 1 complete, 3 line(s)
--- END
"""

_BAD_COMMAND_DRIFT = """\
=== ENTRY bad-command-drift
--- SOURCE synthetic, built by cmd_selftest
--- SHAPE COMMAND says one thing, the recorded echo says another
--- COMMAND find Something
--- OUTPUT
aowlspt live inspector -- batch 1, 1 command(s), on Unity thread 1
> find SomethingElse
  visited 1 node(s) over 1 frame(s), 0 match(es), frontier 0 node(s)
aowlspt live inspector -- batch 1 complete, 4 line(s)
--- END
"""


def _controls():
    """NEGATIVE CONTROLS. A lint that cannot fail is worth nothing, and a
    Replay that quietly answers an unrecorded command is the bug this file
    exists to prevent -- so both are made to fail here, on purpose.

    Returns a list of problem strings; empty means the controls held."""
    import shutil
    import tempfile
    bad = []
    tmp = tempfile.mkdtemp(prefix="inspectfixtures-controls-")
    try:
        for fname, text, want in (("noecho.txt", _BAD_NO_ECHO, "no `>` command echo"),
                                  ("drift.txt", _BAD_COMMAND_DRIFT,
                                   "--- COMMAND is")):
            d = os.path.join(tmp, fname[:-4])
            os.makedirs(d)
            with io.open(os.path.join(d, fname), "w", encoding="utf-8",
                         newline="\n") as fh:
                fh.write(text)
            got = lint(d)
            if not any(want in p for p in got):
                bad.append("lint did NOT flag %s -- it reported %s. A lint "
                           "that cannot fail is not a lint." % (fname, got))
        # the corpus must still lint clean after those forced re-reads
        load(force=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # Replay must RAISE, not answer, for an unrecorded batch.
    rp = Replay([("state", ["state-settings-bound"])])
    try:
        rp(["find NothingRecorded"])
        bad.append("Replay ANSWERED an unrecorded command instead of raising. "
                   "Whatever it returned would be parsed as a real reply.")
    except AssertionError:
        pass
    # and it must refuse a one-line 'answer' that is not a known fixture id
    try:
        Replay([("state", ["definitely-not-a-fixture"])])
        bad.append("Replay accepted a one-line string as an answer")
    except FixtureError:
        pass
    return bad


def cmd_selftest():
    print("---- negative controls (lint and Replay must be able to fail)")
    ctl = _controls()
    for c in ctl:
        print("  ** CONTROL FAILED: " + c)
    if not ctl:
        print("  controls ok: lint flags a missing echo and a COMMAND/echo "
              "drift; Replay raises on an unrecorded batch and on a one-line "
              "answer.")

    problems = lint() + ctl
    if problems:
        print("LINT FAILED (%d problem(s)):" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    corpus = load()
    print("lint ok: %d entr(y|ies) across %d file(s)"
          % (len(corpus.entries),
             len(set(e.path for e in corpus.entries))))

    rc = 0
    for label, argv in CONSUMERS:
        print("\n======== %s" % label)
        try:
            out = subprocess.run(argv, capture_output=True, text=True,
                                 timeout=300)
        except (OSError, subprocess.SubprocessError) as exc:
            print("  COULD NOT RUN (%s) -- that is not a pass." % exc)
            rc = 1
            continue
        sys.stdout.write(out.stdout)
        if out.stderr.strip():
            sys.stdout.write(out.stderr)
        print("-------- %s exited %d" % (label, out.returncode))
        if out.returncode != 0:
            rc = 1
    print("\n==== inspectfixtures selftest: %s" % ("OK" if rc == 0 else "FAILED"))
    return rc


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "lint"
    if cmd == "lint":
        problems = lint()
        for p in problems:
            print("FAIL: " + p)
        if problems:
            return 1
        c = load()
        print("PASS: %d fixture(s), %d file(s); every batch fixture has a "
              "header, a trailer and a `>` echo."
              % (len(c.entries), len(set(e.path for e in c.entries))))
        return 0
    if cmd == "list":
        for e in load().entries:
            print("%-32s %-12s %s" % (e.eid, e.verb, e.shape[:90]))
        return 0
    if cmd == "show":
        if len(argv) < 3:
            print("show needs a fixture id")
            return 2
        e = load().get(argv[2])
        print("# %s  (%s)\n# source: %s\n# shape: %s\n# command: %s\n"
              % (e.eid, e.verb, e.source, e.shape, e.command))
        print(e.output)
        return 0
    if cmd == "selftest":
        return cmd_selftest()
    print(__doc__)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except FixtureError as _e:
        print("FIXTURE ERROR: %s" % _e)
        sys.exit(1)
