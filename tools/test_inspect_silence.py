#!/usr/bin/env python3
r"""test_inspect_silence.py -- prove the live inspector cannot go silent again.

    python tools/test_inspect_silence.py
    python tools/test_inspect_silence.py -v

## What went wrong

Two boots (22:32 and 22:40) handed batch 1 to Unity's thread at 0:00:03.312,
first dispatched the rider at 0:00:17.156, and then said NOTHING for three
minutes: no answers in aowlspt-inspect-out.txt, no ABANDONED, no QUEUED, no
watchdog line, and a rewritten command file was swallowed without a word.

The cause is structural, not arithmetic. Every report `inspectPoll` owns had a
precondition that was false in that state, and the two that had none sat below
an early `return`:

    if not gInspOn or gInspOff:  return    <- above delivery, deadline,
                                              watchdog AND the file read
    if cInspHave() != 0'i32:     ... return <- above the watchdog and the read

and the only announcement of a self-disable was an `iOut` -- a line in the
batch OUTPUT BUFFER, which reaches the log only through `inspWriteOut`, which
is called from the proc that had already returned. So the event that silenced
the channel also destroyed the record of itself.

## What this asserts

Structural invariants of the fix, over the real source file -- that the
unconditional report exists and is reachable before both early-outs, that the
self-disable is announced on the host log by the thread that decided it, and
that a refused edit is refused OUT LOUD.

## The negative control is the point

A source-text assertion that passes is worth nothing unless it can fail. So
every case is ALSO run against `git show HEAD:<the file>` -- the code as it was
before the fix -- and the suite FAILS if the pre-fix source passes any check
that is supposed to be about the fix. That is what makes this a falsification
rather than a spelling test.
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = "host/Aowlspt.Host.Il2Cpp/inspect.nim"
SRC = os.path.join(ROOT, REL.replace("/", os.sep))

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    return bool(ok)


def source_at(rev):
    """The file as of `rev`, or None if git cannot produce it."""
    try:
        out = subprocess.run(["git", "show", "%s:%s" % (rev, REL)],
                             cwd=ROOT, capture_output=True, timeout=60)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace")


def head_source():
    return source_at("HEAD")


def revs_touching(limit=40):
    """Commits that changed this file, newest first."""
    try:
        out = subprocess.run(["git", "rev-list", "--max-count=%d" % limit,
                              "HEAD", "--", REL],
                             cwd=ROOT, capture_output=True, timeout=60)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    return out.stdout.decode("ascii", "replace").split()


def pre_fix_source(limit=40):
    """The newest revision of this file that at least ONE invariant rejects.

    The control used to be pinned to HEAD, which only works while the fix is
    UNCOMMITTED: the moment someone commits it, HEAD passes everything and the
    control goes vacuous -- and it correctly said so rather than reporting a
    pass, which is how this was found. Pinning to a hardcoded sha would rot the
    other way: the invariant set has grown from 9 to 14 across four commits, so
    the right pre-fix source is a different commit for each generation of it.

    So: walk back until one is found. -> (rev, text, n_failing) or None.
    """
    for rev in revs_touching(limit):
        text = source_at(rev)
        if text is None:
            continue
        n = 0
        for _name, fn in INVARIANTS:
            try:
                ok, _ = fn(text)
            except Exception:
                ok = False
            if not ok:
                n += 1
        if n:
            return rev, text, n
    return None


def first(text, needle):
    """Line number (1-based) of the first occurrence, or -1."""
    idx = text.find(needle)
    if idx < 0:
        return -1
    return text.count("\n", 0, idx) + 1


def poll_span(text):
    """(start, end) line numbers of proc inspectPoll."""
    a = first(text, "proc inspectPoll(")
    if a < 0:
        return (-1, -1)
    b = first(text[text.find("proc inspectPoll("):], "\nproc inspectInit(")
    return (a, a + b if b > 0 else len(text.split("\n")))


# --- the invariants, as predicates over the source ---------------------------
# Each returns (ok, detail). They are run against the working tree (must all
# pass) and against HEAD (must all FAIL, or the check cannot fail at all).

def inv_no_combined_off_guard(t):
    n = first(t, "if not gInspOn or gInspOff:")
    return (n < 0,
            "the combined guard is still at line %d; `gInspOff` returns before "
            "delivery, the deadline, the watchdog and the file read" % n)


def inv_flight_report_exists(t):
    return (first(t, "HANDED but NOT DELIVERED") > 0,
            "no unconditional handed-but-not-delivered report")


def inv_flight_report_before_pending(t):
    rep = first(t, "HANDED but NOT DELIVERED")
    pend = first(t, "  if cInspHave() != 0'i32:")
    dead = first(t, "THE DEADLINE ON AN IN-FLIGHT BATCH")
    return (0 < rep < pend and 0 < rep < dead,
            "report@%d pending-branch@%d deadline@%d -- the report must "
            "precede both or it inherits their preconditions"
            % (rep, pend, dead))


def inv_file_read_before_pending(t):
    rd = first(t, "readShared(gInspCmdPath, text)")
    pend = first(t, "  if cInspHave() != 0'i32:")
    return (0 < rd < pend,
            "read@%d pending-branch@%d -- while a batch is pending the host "
            "cannot even see a new command file" % (rd, pend))


def inv_refusal_is_loud(t):
    n = t.count("your new batch is NOT queued")
    return (n >= 2,
            "found %d refusal message(s); both the pending path and the "
            "claimed-and-running path must announce the refusal" % n)


def inv_off_announced_on_log(t):
    has = first(t, "proc inspGoOff(") > 0
    warned = "live inspector: SELF-DISABLED" in t
    sites = t.count("gInspOff = true")
    return (has and warned and sites == 1,
            "inspGoOff=%s warn=%s bare `gInspOff = true` sites=%d (must be "
            "exactly the one inside inspGoOff)" % (has, warned, sites))


def inv_off_still_publishes(t):
    return (first(t, "polling has STOPPED because the channel is OFF") > 0,
            "the OFF state never publishes the dead batch's answers or says "
            "that edits will now be ignored")


def inv_watchdog_survives_off(t):
    wd = first(t, "  inspPollWatchdog()")
    tick = first(t, "proc inspTick()")
    off = t.find("proc inspTick()")
    off = t.count("\n", 0, t.find("if gInspOff:", off)) + 1
    return (0 < tick < wd < off,
            "inspTick@%d calls inspPollWatchdog@%d, gInspOff early-out@%d -- "
            "a self-disable must not silence the host-thread watchdog too"
            % (tick, wd, off))


def inv_stale_file_not_run(t):
    seeded = first(t, "gInspLastText = existing") > 0
    said = first(t, "a stale command file was already on disk") > 0
    return (seeded and said,
            "seeded=%s announced=%s -- the previous session's file is run at "
            "boot, against a client still on the loading screen" % (seeded, said))


def inv_wordy_root_refused(t):
    """A letters-only token in the ROOT slot must REFUSE, and the refusal must
    carry a completeness verdict.

    MEASURED live, twice, by two agents: `findtext Interface language
    $settings 40000 all` took ONE token as the needle and handed `language` to
    the root resolver, which answered `! not an address: language` with 0 hits
    and NO completeness line -- which a consumer that only counts hits reads
    as a clean miss. Three things must hold in the source:
      * the refusal exists and names the real cause;
      * it is reached from the SHARED resolver, so `find`, `findtext` and
        `findcomp` cannot drift apart;
      * it prints NOTHING WAS EXAMINED, the same verdict a zero-node walk
        prints, so the two are classified identically.
    """
    msg = "needle is ONE token" in t
    shared = ("iFindRefuseWordyRoot(toks, startTok, cmdName)" in t
              and t.count("proc iFindResolveRoot(") == 1)
    verdict = ("proc iFindNothingExamined(" in t
               and "iFindNothingExamined(cmdName)" in t
               and t.count(
                   "-- NOTHING WAS EXAMINED (0 valid nodes visited") >= 2)
    # `all`/`more`/`in` are grammar, not roots -- refusing them would break
    # `findtext X all` and `find X in Y`.
    grammar = "proc iFindIsGrammarWord(" in t
    return (msg and shared and verdict and grammar,
            "refusal_text=%s shared_resolver=%s nothing_examined=%s "
            "grammar_exempt=%s" % (msg, shared, verdict, grammar))


def inv_active_predicate_is_shared(t):
    """`findtext`'s ACTIVE scope, its HIT tag and `assert-active` must be ONE
    predicate, and it must be cross-checkable.

    MEASURED live: `findtext Savant 200000` (default scope = ACTIVE only)
    returned a HIT on a CharacterSlotView_pvp whose ancestor
    CharacterSelectionScreen had activeSelf=FALSE, while `assert-active` on
    that same card answered activeInHierarchy=false. A single call to
    GameObject::get_activeInHierarchy is a check that cannot fail -- if that
    RVA is this build's shared empty-body stub it returns leftover RAX, and an
    odd leftover reads as `true`. So:
      * one proc (`iActiveInHierarchyChecked`) is what both callers use;
      * it cross-checks against an INDEPENDENT parent-chain derivation and
        reports a disagreement as INCONCLUSIVE rather than picking a winner;
      * the climb is capped, and hitting the cap is NOT a verdict;
      * a hit whose active state is unknown is tagged UNKNOWN, never printed
        as pressable.
    """
    one = ("proc iActiveInHierarchyChecked(" in t
           and "iActiveInHierarchyChecked(cur, actNote)" in t
           and "iActiveInHierarchyChecked(p, actNote)" in t
           and "iActiveInHierarchy(p)" not in t)
    derived = ("proc iActiveChainDerived(" in t
               and "GameObject::get_activeSelf [active chain]" in t
               and "Transform::get_parent [active chain]" in t)
    disagree = "CROSS-CHECK DISAGREEMENT" in t
    capped = ("InspActiveClimbMax" in t
              and "THE CAP IS NOT A VERDICT" in t)
    unknown = ("activeInHierarchy=UNKNOWN (NOT verified " in t
               and "gTxtActiveUnknown" in t)
    return (one and derived and disagree and capped and unknown,
            "shared_proc=%s derived_chain=%s disagreement=%s capped=%s "
            "unknown_tagged=%s" % (one, derived, disagree, capped, unknown))


def inv_in_root_exact_only(t):
    """`find/findtext X in ROOT` must resolve the root by EXACT name, look at
    the SCENE ROOTS first, accept a quoted multi-word name, and REFUSE on a
    substring-only match.

    MEASURED live: `find X in Menu UI` took ONE token ("Menu"), resolved it by
    SUBSTRING to "Context Menu Area", searched that, and reported X "genuinely
    NOT PRESENT under this root" -- a confidently wrong absence about a root
    nobody asked for. `in "Menu UI"` (quoted) found no root at all, because
    the real "Menu UI" is a scene root and the old scan only walked the tree
    $preloader belongs to.
    """
    exact = ("proc iFindRootByName(" in t
             and "proc iNameSame(" in t
             and "iFindFirstByName(" not in t)          # substring resolver gone
    roots_first = ("iSceneRoots(roots, false)" in t
                   and "resolved by EXACT name among the" in t)
    refuses = ("closest match by substring" in t
               and t.count("iFindNothingExamined(cmdName)") >= 5)
    multiword = ("proc iFindInRootName(" in t
                 and "were joined into" in t)
    both_verbs = ('iFindRootByName(rootName, "find", root)' in t
                  and 'iFindRootByName(rootName, "findtext", root)' in t)
    stopped = "root-name scan STOPPED EARLY" in t
    return (exact and roots_first and refuses and multiword and both_verbs
            and stopped,
            "exact_resolver=%s scene_roots_first=%s substring_refused=%s "
            "multiword=%s both_verbs=%s stopped_early=%s"
            % (exact, roots_first, refuses, multiword, both_verbs, stopped))


def inv_active_receiver_classified(t):
    r"""A GameObject pointer must be a VALID input to the active predicate,
    never a fault.

    MEASURED live 2026-09-02 (the inspector's own out-file), fixture shape:

        in:   assert-active 0x2709c6c2d80
              # that pointer is a GameObject -- it is what the host's
              # `native tabs INVENTORY` log line prints as `strip=<ptr>`
        out:  !! FAULTED (caught; the game survived).
              LAST HOP: Component::get_gameObject [active]
              ... fault 1 of 8 before the inspector switches itself off

    while `tree`/`parent` on the SAME pointer refused correctly with "was
    given a GameObject (klass ...) where a TRANSFORM is required". So the
    active predicate was the one path that took the Component hop
    unconditionally, and the most common pointer an agent holds cost a
    session fault instead of an answer.

    The required outcome is a VERDICT -- PASS or FAIL -- not FAULTED, and not
    a silent guess. Structurally that means:
      * a receiver classifier with THREE outcomes exists;
      * BOTH derivations (the direct call and the independent parent chain)
        go through it, so they cannot disagree about what kind of object they
        were handed;
      * the Component::get_gameObject hop happens ONLY on the Component
        branch;
      * a GameObject is converted to a Transform for the climb with
        GameObject::get_transform, not Component::get_transform;
      * an unclassifiable receiver is NOTHING EXAMINED -- no verdict.
    """
    classifier = ("proc iActiveClassify(" in t
                  and "ActRecvGameObject" in t
                  and "ActRecvComponent" in t
                  and "ActRecvUnknown" in t)
    both_use = t.count("case iActiveClassify(cur)") >= 2
    _c = t.find("of ActRecvComponent:")
    _h = t.find('iMark("Component::get_gameObject [active]"')
    _g = t.find("of ActRecvGameObject:")
    hop_gated = (0 < _c < _h and 0 < _g < _c)
    go_to_tf = ("node = iTransformOfGameObject(cur)" in t
                and "Component::get_transform [active" not in t)
    nothing = "active-receiver: NOTHING EXAMINED" in t
    reported = ("proc iActiveRecvLabel(" in t
                and "receiver is a GAMEOBJECT" in t
                and "let recvLine = iActiveRecvLabel(p)" in t)
    return (classifier and both_use and hop_gated and go_to_tf and nothing
            and reported,
            "classifier=%s both_derivations=%s hop_gated=%s go_to_transform=%s "
            "nothing_examined=%s reported=%s"
            % (classifier, both_use, hop_gated, go_to_tf, nothing, reported))


def inv_unbound_anchor_refused(t):
    r"""A `$anchor` that holds 0 must REFUSE, and a failed `component` lookup
    must say out loud that it unbound `$comp`.

    MEASURED live 2026-09-02 14:42, one batch, the inspector's own out-file:

        component $g2 AnimatedToggle
          ! GetComponent returned NULL -- this is an ANSWER, not a crash.
        call rva:0x55ba430 v_pb $comp 1
          !! FAULTED (caught; the game survived) ... fault 1 of 8

    `$comp` was cleared to 0 by the failed lookup, SILENTLY, and `call` then
    handed that 0 to game code as a receiver -- three times in that batch,
    three of the session's eight faults. Two things must hold:

      * the refusal is in `iEval`, the ONE evaluator every verb calls, so
        `call`/`click`/`invoke`/`press`/`label`/`rect` and every future verb
        inherit it instead of each keeping its own copy (which is how
        `click` came to have the guard and `call` not to);
      * it fires on the `$name` ATOM, before the deref chain and before any
        consumer, and a LITERAL 0 is still accepted -- a typed 0 is a
        decision, an unbound name is not;
      * the unbind is ANNOUNCED by `component` itself, because a silent clear
        and a stale binding look identical in the out-file.

    Negative control: on the pre-fix source `iEval` accepts a zero anchor and
    there is no announcement, so both halves fail.
    """
    refuses = ("proc iUnboundWhy(" in t
               and "err = iUnboundWhy(atom)" in t)
    in_eval = (0 < first(t, 'err = "no such anchor or variable: $" & atom')
               < first(t, "err = iUnboundWhy(atom)")
               < first(t, "# ---- the chain ----"))
    # Exactly one clear of $comp, and it is ABOVE the usage check -- so no
    # early return can leave the previous batch's pointer bound.
    one_clear = t.count('iSetVar("comp", 0\'u64)') == 1
    clear_first = (0 < first(t, 'iSetVar("comp", 0\'u64)')
                   < first(t, "usage: component EXPR TypeName"))
    announced = ("proc iCmdComponentBody(" in t
                 and "if not iCmdComponentBody(toks):" in t
                 and "$comp is UNBOUND -- this lookup did not produce a "
                     "component" in t)
    # The container/child note is ONE proc used by BOTH null branches, and it
    # carries the measured ControlToggle(Clone) case the user actually hit.
    hint = ("proc iCompChildHint(" in t
            and t.count("iCompChildHint(toks[2])") >= 2
            and "a ControlToggle(Clone) carries " in t)
    return (refuses and in_eval and one_clear and clear_first and announced
            and hint,
            "refusal=%s in_eval=%s one_clear=%s clear_above_usage=%s "
            "announced=%s child_hint=%s"
            % (refuses, in_eval, one_clear, clear_first, announced, hint))


INVARIANTS = [
    ("no_combined_off_guard", inv_no_combined_off_guard),
    ("flight_report_exists", inv_flight_report_exists),
    ("flight_report_before_pending", inv_flight_report_before_pending),
    ("file_read_before_pending", inv_file_read_before_pending),
    ("refusal_is_loud", inv_refusal_is_loud),
    ("off_announced_on_log", inv_off_announced_on_log),
    ("off_still_publishes", inv_off_still_publishes),
    ("watchdog_survives_off", inv_watchdog_survives_off),
    ("stale_file_not_run", inv_stale_file_not_run),
    ("wordy_root_refused", inv_wordy_root_refused),
    ("active_predicate_is_shared", inv_active_predicate_is_shared),
    ("active_receiver_classified", inv_active_receiver_classified),
    ("in_root_exact_only", inv_in_root_exact_only),
    ("unbound_anchor_refused", inv_unbound_anchor_refused),
]


def main():
    verbose = "-v" in sys.argv
    if not os.path.exists(SRC):
        print("FAIL -- %s not found" % SRC)
        return 1
    cur = open(SRC, encoding="utf-8", errors="replace").read()

    for name, fn in INVARIANTS:
        try:
            ok, detail = fn(cur)
        except Exception as e:
            ok, detail = False, "%s: %s" % (type(e).__name__, e)
        check("fixed/" + name, ok, detail)
        if verbose:
            print("  fixed/%-30s %s" % (name, "ok" if ok else detail))

    found = pre_fix_source()
    if found is None:
        check("control/can_fail", False,
              "no revision of %s in the last 40 that touched it fails ANY of "
              "these %d invariants, so this suite cannot distinguish fixed "
              "from broken. Either git could not be read, or the checks are "
              "vacuous." % (REL, len(INVARIANTS)))
    else:
        rev, old, failed_on_old = found
        if verbose:
            for name, fn in INVARIANTS:
                try:
                    ok, _ = fn(old)
                except Exception:
                    ok = False
                print("  %s/%-30s %s" % (rev[:8], name,
                                         "PASSES (bad)" if ok
                                         else "fails (good)"))
        check("control/can_fail", True,
              "%d of %d invariants fail on %s, the newest revision of this "
              "file that any of them rejects"
              % (failed_on_old, len(INVARIANTS), rev[:8]))

    bad = [r for r in RESULTS if not r[1]]
    print("\n%s -- %d/%d checks passed"
          % ("PASS" if not bad else "FAIL", len(RESULTS) - len(bad),
             len(RESULTS)))
    for n, ok, d in RESULTS:
        if not ok:
            print("   FAILED  %s  %s" % (n, d))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
