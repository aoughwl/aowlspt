#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""irepl.py -- the interactive shell for the live inspector, plus mod control.

    python tools\\irepl.py                 interactive
    python tools\\irepl.py --selftest      offline, no live client
    python tools\\irepl.py -c "mods" -c "roots"    non-interactive, same engine

## Why this is not a fifth parallel path

There were already several front-ends onto the one file channel and the python
side had FORKED three ways:

  * `plugins/aowlsptcode/mcp/channel.py`  -- unique sentinel + prose parsers,
    unit tested. The good one. The `aowlinspect` MCP server sits on it.
  * `tools/ichannel.py`  -- a verbatim COPY of it, vendored for acceptance.py.
  * `tools/inspector.py` -- an INDEPENDENT sentinel/poll loop (with a sentinel
    that wraps every 17 minutes), under `tools/ui.py` and `tools/enterraid.py`.
  * `tools/inspect.ps1`  -- a fourth, in PowerShell.
  * `tools/aowlui.nim`'s `Ui` -- the Nim side, correctly shared already by
    `aowl ui`, `aowl raid`, `aowllayout` and `autoscript`.

This REPL adds NO transport. It imports `ichannel`, which is now a re-export of
`channel.py`, and `tools/inspector.py` now delegates to the same. So the python
side is one implementation where it was three, and a human at this prompt, an
agent through the MCP server, and `tools/acceptance.py` all see the same parse
of the same prose -- which is the point, because two parsers of one answer is
how one of them ends up silently wrong.

## What is preserved, deliberately

  * **Three outcomes, never two.** PASS / FAIL / INCONCLUSIVE. "I could not
    look" is not a pass. `find`'s EXHAUSTIVELY vs STOPPED EARLY comes through
    `channel.parse_find`, and STOPPED EARLY is surfaced as an explicit
    "absence NOT provable" line rather than folded into an empty hit list.
  * **The batch/verdict model.** Each Enter is one batch (so per-batch anchors
    keep their real semantics -- `$f1`/`$comp`/`$r0` do NOT survive to the next
    line, and this shell says so rather than faking persistence it cannot
    provide). `.batch` ... `.end` composes several lines into ONE batch when
    you need anchors to carry. The host's own `BATCH VERDICT` line is captured;
    `.verdict` rolls every verdict seen this session up with the same
    precedence, FAIL > INCONCLUSIVE > PASS, and prints NO verdict at all when
    no assertion ran.
  * **Writes stay gated.** `.write on` is required before any batch that
    contains a writing verb, and it only adds `allow write`; the host's
    `liveInspectorWrite` flag is still the other half and this shell cannot
    and does not bypass it. `modenable`/`moddisable` are writes too -- they
    persist a user override -- and are gated the same way.
  * **Readiness.** Running reads immediately after a raid-entry marker STALLS a
    still-loading client into a stuck load screen (measured). A REPL invites
    rapid-fire lines, so a batch that times out flips this shell into NOT READY
    and every later line refuses by name until `.ready` gets an answer back.
    It never decides the client is dead; it says it could not get an answer,
    which is INCONCLUSIVE.

Nothing here runs on the Unity main thread. No new host code, no detour, no
RVA -- the mod verbs are HTTP against the backend, which is where mod state
actually lives (see `tools/modctl.py`).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ichannel as ch  # noqa: E402
import modctl  # noqa: E402

PASS, FAIL, INCONCLUSIVE = modctl.PASS, modctl.FAIL, modctl.INCONCLUSIVE

# Verbs taken from docs/INSPECTOR-VERBS.md. Used for tab completion and for
# deciding whether a line needs `allow write`; an UNKNOWN verb is passed
# through to the host untouched, because this shell is not the authority on
# what the host understands and must not refuse a verb the host has and it
# has not heard of.
READ_VERBS = """read dump fields scan component components rect canvas label
visible screenrect canvasorder whydidntitdraw state anchors targets where help
echo roots children parent tree path siblings find findtext findcomp let wait
until watch verdict whyread image assert assert-active assert-inactive
assert-null assert-nonnull assert-readable assert-name""".split()
WRITE_VERBS = """write settext click invoke press pressname open tab call
record""".split()
MOD_VERBS = "mods modinfo modenable moddisable modreload".split()
MOD_WRITE_VERBS = "modenable moddisable modreload".split()
META = """.help .write .timeout .batch .end .verdict .ready .reset .quit
.exit""".split()
ALL_VERBS = READ_VERBS + WRITE_VERBS + MOD_VERBS + META


class Repl(object):
    def __init__(self, timeout=25.0, live_dir=None, run_batch=None, out=None):
        self.timeout = timeout
        self.live_dir = live_dir
        self.write = False
        self.ready = True          # optimistic; a timeout flips it
        self.why_not_ready = ""
        self.verdicts = []         # every PASS/FAIL/INCONCLUSIVE seen
        self.pending = None        # collecting a .batch
        self._run = run_batch or (lambda lines, wr, to: ch.run_batch(
            lines, live_dir=self.live_dir, timeout=to, write=wr))
        self._out = out or (lambda s: sys.stdout.write(s + "\n"))

    # -- plumbing ----------------------------------------------------------
    def say(self, s):
        self._out(s)

    def record(self, outcome):
        if outcome in (PASS, FAIL, INCONCLUSIVE):
            self.verdicts.append(outcome)
        return outcome

    def session_verdict(self):
        """None when nothing asserted anything. Never PASS-by-default."""
        return modctl.roll_up(self.verdicts)

    # -- readiness ---------------------------------------------------------
    def probe(self):
        """Cheapest possible question: does the channel answer at all? Uses a
        short timeout on purpose -- a loading client will not answer and we
        want to know that in seconds, not in half a minute."""
        try:
            self._run(["echo irepl-ready-probe"], False, 6.0)
        except ch.InspectorError as e:
            self.ready = False
            self.why_not_ready = "%s: %s" % (getattr(e, "kind", "error"), e)
            return INCONCLUSIVE
        self.ready = True
        self.why_not_ready = ""
        return PASS

    # -- one line ----------------------------------------------------------
    def feed(self, line):
        """Handle one typed line. Returns the outcome recorded for it, or None
        for lines that assert nothing (a plain `read`, a meta command)."""
        line = line.strip()
        if not line or line.startswith("#"):
            return None
        if line.startswith("."):
            return self.meta(line)
        if self.pending is not None:
            self.pending.append(line)
            return None
        return self.send([line])

    def meta(self, line):
        parts = line.split()
        cmd = parts[0]
        if cmd in (".quit", ".exit"):
            raise EOFError
        if cmd == ".help":
            self.say(HELP)
            return None
        if cmd == ".write":
            if len(parts) < 2 or parts[1] not in ("on", "off"):
                self.say("REFUSED: `.write on` or `.write off`. Currently %s. "
                         "This only adds `allow write` to the batch; the host's "
                         "liveInspectorWrite flag is the other half and this "
                         "shell cannot set it."
                         % ("ON" if self.write else "OFF"))
                return None
            self.write = parts[1] == "on"
            self.say("writes %s for this session." % ("ALLOWED" if self.write else "REFUSED"))
            return None
        if cmd == ".timeout":
            try:
                self.timeout = float(parts[1])
            except (IndexError, ValueError):
                self.say("REFUSED: `.timeout SECONDS`. Currently %g." % self.timeout)
                return None
            self.say("batch timeout is now %gs." % self.timeout)
            return None
        if cmd == ".batch":
            self.pending = []
            self.say("collecting ONE batch -- anchors ($f1/$comp/$r0) will "
                     "carry across these lines. `.end` to send.")
            return None
        if cmd == ".end":
            if self.pending is None:
                self.say("REFUSED: not collecting a batch. `.batch` first.")
                return None
            lines, self.pending = self.pending, None
            if not lines:
                self.say("INCONCLUSIVE: the batch was empty; nothing was sent.")
                return self.record(INCONCLUSIVE)
            return self.send(lines)
        if cmd == ".ready":
            r = self.probe()
            self.say("client READY -- the channel answered." if r == PASS else
                     "INCONCLUSIVE: the client did not answer. %s\n"
                     "  This is NOT proof it crashed. An idle game at "
                     "profile-select and a hung one look identical; a client "
                     "loading a raid does not answer either, and reading it "
                     "while it loads is what stalls it. Wait, then `.ready` "
                     "again." % self.why_not_ready)
            return self.record(r)
        if cmd == ".verdict":
            v = self.session_verdict()
            if v is None:
                self.say("no verdict: nothing in this session asserted "
                         "anything. That is not a PASS.")
            else:
                self.say("SESSION VERDICT: %s  (from %d outcome(s): %s)" %
                         (v, len(self.verdicts), ", ".join(sorted(set(self.verdicts)))))
            return None
        if cmd == ".reset":
            n = len(self.verdicts)
            self.verdicts = []
            self.say("cleared %d recorded outcome(s)." % n)
            return None
        self.say("REFUSED: unknown meta command %r. `.help` lists them." % cmd)
        return None

    # -- dispatch ----------------------------------------------------------
    def send(self, lines):
        verbs = [l.split()[0] for l in lines if l.split()]
        if any(v in MOD_VERBS for v in verbs):
            if len(lines) != 1:
                self.say("REFUSED: mod verbs are not inspector batch commands "
                         "-- they are HTTP against the backend, not the game "
                         "thread -- so they cannot be mixed into a `.batch`. "
                         "Run them on their own line.")
                return self.record(INCONCLUSIVE)
            return self.mod_verb(lines[0])

        needs_write = [v for v in verbs if v in WRITE_VERBS]
        if needs_write and not self.write:
            self.say("REFUSED (WRITE_NOT_ALLOWED): %r writes or calls into "
                     "game code. `.write on` first. The host's "
                     "liveInspectorWrite flag must also be on -- this shell "
                     "cannot set it and will not pretend it did."
                     % needs_write[0])
            return self.record(INCONCLUSIVE)

        if not self.ready:
            self.say("REFUSED (CLIENT_NOT_READY): the last batch got no "
                     "answer (%s), so this shell is not sending more. "
                     "Rapid-fire reads into a client that is LOADING are what "
                     "stall it into a stuck load screen. `.ready` to re-probe."
                     % self.why_not_ready)
            return self.record(INCONCLUSIVE)

        try:
            _s, text = self._run(list(lines), self.write and bool(needs_write), self.timeout)
        except ch.InspectorError as e:
            self.ready = False
            self.why_not_ready = "%s: %s" % (getattr(e, "kind", "error"), e)
            self.say("INCONCLUSIVE (%s): %s" % (getattr(e, "kind", "error"), e))
            return self.record(INCONCLUSIVE)

        self.say(text.rstrip())
        return self.record(self.annotate(text, verbs))

    def annotate(self, text, verbs):
        """Add what the prose implies but does not say in one word, and return
        the outcome to record. Nothing here invents a result -- every branch
        is driven by `channel.py`'s own parsers."""
        outcome = None

        for v in verbs:
            if v in ("find", "findtext", "findcomp"):
                p = ch.parse_findtext(text) if v == "findtext" else ch.parse_find(text)
                if not p["can_trust_absence"] and not p["hits"]:
                    self.say("  -> INCONCLUSIVE: %s and found nothing. Absence "
                             "is NOT proven; %s" %
                             (p["completeness"],
                              "resume with `%s more`." % v if p["resumable"]
                              else "nothing was examined."))
                    outcome = INCONCLUSIVE
                elif p["completeness"] == "EXHAUSTIVE" and not p["hits"]:
                    self.say("  -> the search was EXHAUSTIVE, so this absence "
                             "IS trustworthy.")
                if v == "findtext" and p.get("inactive_skipped"):
                    self.say("  -> %d INACTIVE node(s) were skipped (scope %s). "
                             "An inactive hit is not pressable."
                             % (p["inactive_skipped"], p["scope"]))

        # The host's own BATCH VERDICT is authoritative when present.
        for l in text.splitlines():
            s = l.strip().upper()
            if s.startswith("BATCH VERDICT"):
                for o in (FAIL, INCONCLUSIVE, PASS):
                    if o in s:
                        return o
        return outcome

    # -- mod verbs ---------------------------------------------------------
    def mod_verb(self, line):
        parts = line.split()
        verb, arg = parts[0], (parts[1] if len(parts) > 1 else None)
        if verb in MOD_WRITE_VERBS and not self.write:
            self.say("REFUSED (WRITE_NOT_ALLOWED): `%s` persists a user "
                     "override on the backend (or restarts a live mod). "
                     "`.write on` first." % verb)
            return self.record(INCONCLUSIVE)
        try:
            return self.record(self._mod_verb(verb, arg))
        except modctl.Refusal as e:
            self.say("REFUSED (%s): %s" % (e.name, e))
            return self.record(INCONCLUSIVE)

    def _mod_verb(self, verb, arg):
        if verb == "mods":
            rows, outcome = modctl.list_mods(arg, live_dir=self.live_dir)
            for r in rows:
                self.say(fmt_row(r))
            self.say("  %d mod(s). BATCH VERDICT: %s" % (len(rows), outcome))
            return outcome
        if verb == "modinfo":
            if not arg:
                self.say("REFUSED: `modinfo <mod-id>`.")
                return INCONCLUSIVE
            rows, _ = modctl.list_mods(arg, live_dir=self.live_dir)
            exact = [r for r in rows if r["id"] == arg] or rows
            for r in exact:
                self.say(fmt_row(r))
                self.say("      want=%s  on_disk=%s  live=%s  verdict=%s\n"
                         "      %s" % (r["want"], _tri(r["on_disk"]),
                                       _tri(r["live"]), r["verdict"],
                                       r["detail"]))
                if r["reason"]:
                    self.say("      the manager's own words: %s" % r["reason"])
            return modctl.roll_up([r["outcome"] for r in exact])
        if verb in ("modenable", "moddisable"):
            if not arg:
                self.say("REFUSED: `%s <mod-id>`." % verb)
                return INCONCLUSIVE
            outcome, msg = modctl.set_enabled(arg, verb == "modenable")
            self.say("  %s: %s" % (outcome, msg))
            return outcome
        if verb == "modreload":
            if not arg:
                self.say("REFUSED: `modreload <mod-id>`.")
                return INCONCLUSIVE
            # Look the row up first so the refusal can name the RIGHT cause:
            # "this mod has not declared it can come out live" and "no reload
            # driver exists here" are different problems with different fixes.
            # If we cannot reach the backend the lookup refuses on its own
            # (BACKEND_UNREACHABLE) -- we do not fall through and guess.
            rows, _ = modctl.list_mods(arg, live_dir=self.live_dir)
            exact = [r for r in rows if r["id"] == arg]
            res = modctl.reload(arg, row=exact[0] if exact else None)
            self.say("  %s" % (res,))
            return PASS
        self.say("REFUSED: unknown mod verb %r." % verb)
        return INCONCLUSIVE


def _tri(v):
    return "UNKNOWN (nobody who could answer has)" if v is None else str(bool(v))


_MARK = {PASS: "[LIVE]", FAIL: "[OFF ]", INCONCLUSIVE: "[ ?  ]"}


def fmt_row(r):
    tail = r.get("refusal")
    return "  %s %-26s %-16s %s" % (
        _MARK.get(r["outcome"], "[    ]"), r["id"], r["verdict"],
        ("gate %s: %s" % (r["gate"], tail)) if r.get("gate") else (tail or "live"))


HELP = """\
inspector verbs go straight to the host, one line = one batch (anchors do NOT
carry between lines -- use .batch/.end when they must). See
docs/INSPECTOR-VERBS.md for the full list.

mod control (HTTP to the backend, NOT the game thread -- tools/modctl.py):
  mods [FILTER]        every mod, with WHICH GATE is blocking it, not just off
  modinfo <id>         one mod in full: the four gates, the manager's reason
  modenable <id>       write a persistent user override ON   (needs .write on)
  moddisable <id>      write a persistent user override OFF  (needs .write on)
  modreload <id>       live restart -- REFUSES BY NAME until the reload entry
                       point exists; it will not substitute the registry
                       re-read route and call that a reload

meta:
  .write on|off  .timeout SEC  .batch/.end  .ready  .verdict  .reset  .quit"""


# ---------------------------------------------------------------------------
# selftest -- offline, no live client, no backend
# ---------------------------------------------------------------------------

_REG = """{"mods":[
 {"id":"aowl.good","name":"Good","sides":["client"],
  "artifact":{"dir":"good","library":"good.dll"}},
 {"id":"aowl.notsel","name":"NotSel","sides":["client"],
  "artifact":{"dir":"notsel","library":"notsel.dll"}},
 {"id":"aowl.silent","name":"Silent","sides":["client"],
  "artifact":{"dir":"silent","library":"silent.dll"}}]}"""

_ROWS = {"ok": True, "mods": [
    {"id": "aowl.good", "name": "Good", "verdict": "loaded", "enabled": True,
     "reason": "enabled by aowl.list.beta", "clientLive": True,
     "clientOutcome": "loaded"},
    {"id": "aowl.notsel", "name": "NotSel", "verdict": "not-selected",
     "enabled": False, "reason": "no active list mentions it"},
    {"id": "aowl.silent", "name": "Silent", "verdict": "loaded",
     "enabled": True, "reason": "enabled by aowl.list.beta"},
]}


def selftest():
    """Demonstrates PASS, FAIL and INCONCLUSIVE for the mod-control verbs, and
    that 'not selected' and 'cannot be reloaded' are DISTINCT NAMED refusals.
    A check that cannot fail is the bug (CLAUDE.md 9b), so each case below
    names the input that produces it."""
    import json
    reg = modctl.load_registry(text=_REG)
    ok = [0]

    def case(name, got, want):
        good = got == want
        ok[0] += 0 if good else 1
        print("  %-4s %-46s got %s" % ("ok" if good else "FAIL", name, got))

    print("== classify: one row per outcome ==")
    live = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    rows = [modctl.classify(r, reg.get(r["id"]), live_dir=live)
            for r in _ROWS["mods"]]
    # live_dir points at the repo, which has no mods\<dir>\<lib>, so gate 1
    # would fire for all three -- that is itself a real FAIL case, so it is
    # tested separately below and suppressed here by passing no artifact dirs.
    bare = {k: dict(v, dir=None, library=None) for k, v in reg.items()}
    rows = [modctl.classify(r, bare.get(r["id"])) for r in _ROWS["mods"]]

    case("aowl.good  (selected + client says LIVE)", rows[0]["outcome"], PASS)
    case("aowl.notsel(gate 3, nothing selects it)", rows[1]["outcome"], FAIL)
    case("  ... and the refusal is named", rows[1]["refusal"], "NOT_SELECTED")
    case("  ... and it names the gate", rows[1]["gate"], 3)
    case("aowl.silent(clientLive ABSENT, not false)", rows[2]["outcome"], INCONCLUSIVE)
    case("  ... and the refusal is named", rows[2]["refusal"], "NO_CLIENT_ANSWER")

    print("== gate 1: the DLL is not on disk ==")
    g1 = modctl.classify(_ROWS["mods"][0], reg["aowl.good"], live_dir=live)
    case("aowl.good with no DLL under the install", g1["outcome"], FAIL)
    case("  ... named DLL_MISSING, gate 1", (g1["refusal"], g1["gate"]),
         ("DLL_MISSING", 1))

    print("== gate 2 / reload: distinct named refusals ==")
    try:
        modctl.reload("aowl.nosuch", registry=reg)
        case("modreload on an unknown id", "no refusal", "Refusal")
    except modctl.Refusal as e:
        case("modreload on an unknown id", e.name, "NOT_IN_REGISTRY")
    try:
        modctl.reload("aowl.good", registry=reg)
        case("modreload, no driver anywhere", "no refusal", "Refusal")
    except modctl.Refusal as e:
        case("modreload, no driver anywhere", e.name, "RELOAD_UNSUPPORTED")
    # ... and the DIFFERENT refusal, for a mod the host would refuse to unload
    try:
        modctl.reload("aowl.good", registry=reg,
                      row={"id": "aowl.good", "hot_reloadable": False})
        case("modreload, mod never declared it", "no refusal", "Refusal")
    except modctl.Refusal as e:
        case("modreload, mod never declared it", e.name, "RELOAD_NOT_DECLARED")

    print("== could not look at all ==")
    def dead(_p, **_k):
        raise modctl.Refusal("BACKEND_UNREACHABLE", "synthetic: nothing listening")
    try:
        modctl.list_mods(None, get=dead, registry=reg)
        case("mods with no backend", "no refusal", "Refusal")
    except modctl.Refusal as e:
        case("mods with no backend", (e.name, e.outcome),
             ("BACKEND_UNREACHABLE", INCONCLUSIVE))

    print("== the REPL's own verdict model ==")
    out = []
    r = Repl(out=out.append, run_batch=lambda l, w, t: (_ for _ in ()).throw(
        ch.TimeoutErr("synthetic: no answer")))
    case("no assertions -> NO verdict, not PASS", r.session_verdict(), None)
    r.feed("read 0x0 i32")
    case("a timeout is INCONCLUSIVE", r.session_verdict(), INCONCLUSIVE)
    case("  ... and the shell goes NOT READY", r.ready, False)
    r.feed("read 0x0 i32")
    case("  ... and refuses by name after that",
         any("CLIENT_NOT_READY" in s for s in out), True)

    out2 = []
    fake = {"n": 0}
    def answers(lines, wr, to):
        fake["n"] += 1
        return "s", ("assert 0x10 i32 == 5\n  ok\nBATCH VERDICT: FAIL"
                     if fake["n"] == 1 else
                     "0 hit(s); searched EXHAUSTIVELY, visited 900 nodes")
    r2 = Repl(out=out2.append, run_batch=answers)
    case("host BATCH VERDICT: FAIL is adopted", r2.feed("assert 0x10 i32 == 5"), FAIL)
    r2.feed("find Nothing")
    case("EXHAUSTIVE + 0 hits -> absence IS trustworthy",
         any("IS trustworthy" in s for s in out2), True)

    out3 = []
    r3 = Repl(out=out3.append,
              run_batch=lambda l, w, t: ("s", "0 hit(s); STOPPED EARLY"))
    case("STOPPED EARLY + 0 hits -> INCONCLUSIVE", r3.feed("find Thing"), INCONCLUSIVE)

    out4 = []
    r4 = Repl(out=out4.append, run_batch=lambda l, w, t: ("s", ""))
    case("a write verb without .write on is refused",
         r4.feed("settext $f1 hi"), INCONCLUSIVE)
    case("  ... named WRITE_NOT_ALLOWED",
         any("WRITE_NOT_ALLOWED" in s for s in out4), True)
    case("modenable without .write on is refused too",
         r4.feed("modenable aowl.good"), INCONCLUSIVE)

    print("\n%s: %d failing case(s)" % ("FAIL" if ok[0] else "PASS", ok[0]))
    json.dumps({})  # keep the import honest
    return 1 if ok[0] else 0


def interactive(repl):
    try:
        import readline
        readline.parse_and_bind("tab: complete")
        def comp(text, state):
            hits = [v + " " for v in ALL_VERBS if v.startswith(text)]
            return hits[state] if state < len(hits) else None
        readline.set_completer(comp)
        hist = os.path.expanduser("~/.aowl/irepl_history")
        try:
            os.makedirs(os.path.dirname(hist), exist_ok=True)
            readline.read_history_file(hist)
        except OSError:
            hist = None
    except ImportError:
        hist = None
        print("(no readline on this python: no history, no completion)")

    print("aowlspt inspector REPL. `.help`, `.quit`. One line = one batch.")
    repl.probe()
    if not repl.ready:
        print("NOT READY: %s\n  `.ready` to re-probe. Nothing is being sent "
              "until it answers." % repl.why_not_ready)
    while True:
        try:
            line = input(("w" if repl.write else "") +
                         ("+" if repl.pending is not None else "") + "aowl> ")
        except (EOFError, KeyboardInterrupt):
            print()
            break
        try:
            repl.feed(line)
        except EOFError:
            break
        except Exception as e:  # noqa: BLE001 -- a REPL must not die on one line
            print("INCONCLUSIVE (%s): %s" % (e.__class__.__name__, e))
    if hist:
        try:
            readline.write_history_file(hist)
        except OSError:
            pass
    v = repl.session_verdict()
    print("SESSION VERDICT: %s" % v if v else
          "no verdict: nothing this session asserted anything.")
    return 1 if v == FAIL else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true",
                    help="offline self-test; no live client, no backend")
    ap.add_argument("-c", "--command", action="append", default=[],
                    help="run one line and exit (repeatable)")
    ap.add_argument("--write", action="store_true", help="start with .write on")
    ap.add_argument("--timeout", type=float, default=25.0)
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    r = Repl(timeout=a.timeout)
    r.write = a.write
    if a.command:
        for line in a.command:
            r.feed(line)
        v = r.session_verdict()
        print("BATCH VERDICT: %s" % v if v else "no verdict: nothing asserted.")
        return 1 if v == FAIL else 0
    return interactive(r)


if __name__ == "__main__":
    sys.exit(main())
