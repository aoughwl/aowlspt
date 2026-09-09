#!/usr/bin/env python3
r"""selftests.py -- run every self-test in this repo, and prove every verifier
can fail.

    python tools/selftests.py              # --fast (default), ~45 s
    python tools/selftests.py --all        # everything, including the slow set
    python tools/selftests.py --list       # the registry, run nothing
    python tools/selftests.py --falsifiers # the falsifier audit only

## Why this exists

On 2026-09-01 six separate verifiers reported PASS on state that was visibly
wrong, because none of their checks could fail:

  * `nativetabs_check` accepted a FAIL verdict as "geometry unchanged";
  * `acceptance.py` read an `echo` as geometry and `activeInHierarchy` as `isOn`;
  * the maps draw check FAILed at the menu, which only meant "not in a raid";
  * a row relabel re-read its own write and called that a readback;
  * the backend selftest asserted with substring `contains`, so a payload that
    was not JSON at all passed;
  * `--phase-max` bounded nothing.

Each of those got a self-test AFTER the fact. Nothing ran them all, and nothing
gated a deploy on them -- so when this runner was first pointed at the tree it
found SIX self-tests already red that no one knew about. A self-test nobody runs
is documentation.

## Three outcomes, never two

PASS / FAIL / INCONCLUSIVE. INCONCLUSIVE means the item COULD NOT RUN -- a
missing input, a missing build, a timeout. It is never folded into PASS, and it
is never folded into FAIL either, because "I could not look" is a different
fact from "I looked and it was wrong" (CLAUDE.md 9b).

`--fast` exits 0 only if every fast item PASSED. An INCONCLUSIVE fast item is a
non-zero exit, with one exception that is stated in the table: an item whose
declared `needs` are absent is reported SKIP(needs) and excluded, because the
input genuinely is not on this machine and that is not the runner's finding to
make. Every skip is printed with the path that was missing.

## The falsifier registry

A verifier ships with its falsifier or this runner fails. `VERIFIERS` below
lists every tool in `tools/` that emits a verdict, each with the negative
control that makes its FAIL fire and a `proof` string saying where that control
lives. Three states:

  * `falsifier` names a registry item  -> audited, and that item is run
  * `gap` gives a reason               -> KNOWN DEBT: printed every single run,
                                          counted as a runner FAIL under
                                          `--strict` and `--all`, a loud NOTE
                                          under `--fast`
  * neither, or not in the registry    -> UNTRIAGED: a hard FAIL in every mode

That asymmetry is deliberate and is the only judgement call in this file. Debt
that already exists is enumerated so it cannot hide; debt that is NEW cannot be
added at all, because a tool that starts printing verdicts and is not in this
registry fails the runner immediately. A gate that refused every deploy on day
one would simply be routed around with `--no-selftest`, which is the outcome
this whole file exists to prevent.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CACHE = os.path.join(REPO, ".aowl-selftests.json")

PASS, FAIL, INCONCLUSIVE, SKIP = "PASS", "FAIL", "INCONCLUSIVE", "SKIP"

# Inputs that several items need and that are NOT in the repo. An item that
# declares one of these and does not find it is SKIP(needs), never PASS.
import gamepaths as _gp  # noqa: E402  (the binary the host runs against)
GAMEASM = _gp.gameasm()
METADEC = os.path.join(REPO, ".cache", "global-metadata.dec.dat")


# --------------------------------------------------------------------------
# The item registry.
#
# `speed` is a MEASURED class, not an aspiration -- the seconds in the comments
# were timed in this checkout on 2026-09-02. fast: the whole fast set is under
# ~60 s serial. slow: anything above ~10 s, plus anything that blocks.
#
# `args` are the arguments the item genuinely requires. Three tests here were
# reported red for months by anyone who ran them bare; they were not red, they
# were being run without the two paths every resolver verb takes first.
# --------------------------------------------------------------------------

def T(name, speed, args=(), needs=(), note=""):
    """A `tools/test_*.py` item."""
    return {"name": name, "kind": "test", "cmd": [sys.executable,
            os.path.join(HERE, name)] + list(args), "speed": speed,
            "needs": list(needs), "note": note}


def S(name, speed, args=("--selftest",), needs=(), note="", label=None):
    """A tool exposing a self-test."""
    return {"name": label or ("%s %s" % (name, " ".join(args))).strip(),
            "kind": "selftest",
            "cmd": [sys.executable, os.path.join(HERE, name)] + list(args),
            "speed": speed, "needs": list(needs), "note": note}


ITEMS = [
    # ---- fast tests -------------------------------------------------------
    # NOT fast, however fast it looks. It runs `aowl` through
    # `buildlock.py --wait 1800`, so it is 2.2 s when the build slot is free
    # and up to THIRTY MINUTES when another agent holds it. Measured on
    # 2026-09-02: it queued behind a `build host` that had been running 725 s.
    # An item in the deploy gate that blocks on the one genuinely serial
    # resource in this repo would make the gate the reason deploys hang.
    T("test_aowlbuild.py", "slow",
      note="waits on the build lock: 2s free, up to 30 min contended"),
    T("test_autoenter.py", "fast"),                    # 0.8s
    T("test_crashwatch.py", "fast"),                   # 12.1s
    T("test_cmdargs.py", "fast"),                      # 2s with a built launcher
    T("test_deploy_contains.py", "fast"),              # 1.5s
    T("test_hostlog.py", "fast"),                      # 6.4s
    T("test_inspect_silence.py", "fast"),              # 0.1s
    T("test_modbuild_diag.py", "fast"),                # 0.1s
    T("test_modbuild_failcache.py", "fast"),           # 0.1s
    T("test_modloadfmt.py", "fast"),                   # 0.1s
    T("test_popups_classify.py", "fast"),              # 0.1s
    T("test_raidprof.py", "fast"),                     # 0.6s
    T("test_startup_race.py", "fast"),                 # 4.2s
    T("test_supervise.py", "fast"),                    # 5.7s
    T("test_deploy.py", "fast"),                       # the gate's own tests
    T("test_drainaudit.py", "fast"),                   # 3.9s with metadata
    # Compiles abi/aowlspt_mqpolicy.h with gcc and EXECUTES it, so the rule
    # that no main-thread work runs off the drain thread is tested rather
    # than asserted. INCONCLUSIVE, never PASS, without a C compiler.
    T("test_mqpolicy.py", "fast"),                     # 1.5s, needs gcc
    # Same shape, for abi/aowlspt_handle.h: compiles and EXECUTES the filter
    # that stops a TOKEN-GATED il2cpp export's MT19937-64 return being used as
    # a handle -- the measured Crash_2026-09-02_224920325. Its own negative
    # control is 200,000 uniform random 64-bit values.
    T("test_handleshape.py", "fast"),                  # 1.5s, needs gcc
    # Resolves the compiler for the two items above. Its own falsifier builds
    # a real gcc.exe that exits 1 with no output -- the measured Git Bash
    # shape -- and asserts find_cc REFUSES it.
    T("test_cctool.py", "fast"),                       # 2s, needs gcc

    # ---- fast self-tests --------------------------------------------------
    S("botaudit.py", "fast"),                          # 0.1s
    S("crashwatch.py", "fast"),                        # 0.9s
    S("entergame.py", "fast"),                         # 0.1s
    S("exitraid.py", "fast"),                          # 3.1s
    S("hostcfg.py", "fast"),                           # 0.2s
    S("inspector.py", "fast"),                         # 0.9s
    S("irepl.py", "fast"),                             # 0.5s
    S("markers.py", "fast"),                           # 0.5s
    S("modharness.py", "fast"),                        # 0.6s
    S("offscreen.py", "fast"),                         # 1.7s
    S("gamepaths.py", "fast",
      note="the one answer to 'which GameAssembly': env override, the "
           "aowlspt install's copy, then the retail copy -- measured "
           "2026-09-05: the retail game updated under the tools"),   # 0.1s
    S("pfxstress.py", "fast",
      note="parsers on captured inspector fixtures; the live loop itself "
           "needs a client at Settings and is never run from here"),      # 0.1s
    S("shapeaudit.py", "fast"),                        # 0.1s
    # The three offline invariant gates from docs/INTERACTION-LAYER-MAP.md 7.2.
    # Each --selftest builds fixture trees and asserts PASS, FAIL and
    # INCONCLUSIVE are all reachable, including the negative controls (a log
    # message that merely NAMES a gated export; two unrelated guards that are
    # not nested; an allowlist entry whose site is gone).
    S("gateaudit.py", "fast"),                         # 0.6s  X1
    S("sehnest.py", "fast"),                           # 0.2s  D8
    S("flagaudit.py", "fast"),                         # 0.1s  D10
    S("nimlint.py", "fast"),                           # 0.1s
    S("acceptance.py", "fast", args=("selftest",)),    # 0.2s -- positional
    S("dlss.py", "fast", args=("selftest",)),          # fake install + manifest falsifiers
    S("dlssnr.py", "fast", args=("selftest",)),
    S("dlssapply.py", "fast", args=("selftest",)),  # ini key writer + tampered-key falsifiers        # OptiScaler-DLSSNR install tree + falsifiers
    S("abilint.py", "fast", args=("--selftest",)),      # ABI ownership lint + falsifier
    S("test_hostwrite_gate.py", "fast"),
    S("test_hotreload_ledger.py", "fast"),
    # M3/M6: no raw store into game-owned memory outside the typed FieldRef
    # path. `--falsify` asserts the lint FIRES on a synthetic raw store, stays
    # SILENT on the annotated one, and exempts the gate file itself.
    S("storelint.py", "fast", args=("--falsify",)),
    # The generated FieldRef header must still agree with the metadata.
    # INCONCLUSIVE-by-absence is handled by `needs`: with no GameAssembly.dll
    # or decrypted metadata this cannot run, and "I could not look" is not a
    # pass.
    S("fieldrefs.py", "fast", args=("check",),
      needs=(GAMEASM, METADEC),
      note="regenerates abi/aowlspt_fieldrefs.h and diffs it; exit 5 = drift"),
    S("consistency.py", "fast", args=("selftest",)),   # injected-manifest container + falsifiers
    # The allocator must not be a crash source. Its own --selftest builds four
    # synthetic binaries and asserts FAIL / PASS / INCONCLUSIVE all fire.
    S("allocasserts.py", "fast"),                      # mimalloc MI_DEBUG sentinels
    S("nativetabs_check.py", "fast", args=("selftest",)),
    S("uihooks_check.py", "fast", args=("selftest",)),

    # ---- falsifiers (negative controls) that are themselves items ---------
    S("irepl_mutation.py", "fast", args=(),
      note="proves irepl.py --selftest CAN fail"),
    T("test_markers_falsifier.py", "fast",
      note="proves markers.py cannot answer PRESENT to everything"),
    T("test_hostcfg_falsifier.py", "fast",
      note="proves hostcfg.py --selftest CAN fail"),
    # MEASURED 2026-09-04: `hostcfg.py keys` printed `default off` for every
    # boolean, including the three readBoolKeyDef(..., true) flags that
    # flagaudit.py listed as DEFAULT ON in the same second. This asserts the
    # default column against a PLAIN GREP of host/*.nim -- not against either
    # tool -- and that a non-literal default reads INCONCLUSIVE, never off.
    T("test_hostcfg.py", "fast",
      note="hostcfg's default column vs an independent grep of host/*.nim"),
    T("test_uihooks_falsifier.py", "fast",
      note="proves uihooks_check selftest CAN fail"),
    T("test_symtab.py", "fast",
      note="proves il2cpp_symtab.py's consumer scan matches DECLARED symbol "
           "names exactly (AOWL_SYM_OBJ_GET_NAME is not a use of OBJ_GET) and "
           "does not read comments; its falsifiers re-run the old "
           "unconditional-strip logic and assert it gives the WRONG answer"),
    T("test_il2cpp_flags.py", "fast",
      note="proves il2cpp_resolve.py REFUSES an unknown flag instead of "
           "ignoring it (--count on disasm was dropped silently, so a "
           "DEFAULT-sized window read as a whole function); its own "
           "falsifiers register --bogus and watch the same argv pass"),

    # ---- slow -------------------------------------------------------------
    T("test_buildlock.py", "slow", note="spawns real lock contenders; >90s"),
    T("test_il2cpp_callers.py", "slow"),               # 18.0s
    T("test_il2cpp_disasm.py", "slow"),                # 12.6s
    T("test_il2cpp_symbolize.py", "slow"),             # 12.4s
    T("test_fldoff_generics.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 28s
    T("test_resolver_flags.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 22s
    T("test_resolver_shared.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 16s
    S("enterraid.py", "slow",
      note="blocks past 90s in this checkout -- see the findings"),
    S("dtotype.py", "slow", args=("--selftest", "--manifest"),
      needs=("<dtotype manifest>",),
      note="refuses without --manifest; no manifest is checked in"),

    # ---- items that are NOT python, and cannot run without a build --------
    {"name": "mods/tarkov/emu/seasoncheck.nim", "kind": "nim", "cmd": None,
     "speed": "slow", "needs": ("a built emutest binary",),
     "note": "Nim; reachable only via `aowl build emutest`. Always "
             "INCONCLUSIVE from this runner -- never PASS."},
    {"name": "mods/tarkov/emu/raidloadout.nim", "kind": "nim", "cmd": None,
     "speed": "slow", "needs": ("a built tarkov.dll + a running backend",),
     "note": "Nim; `selfCheckRaidLoadout` runs at tarkov.dll LOAD and a "
             "failure refuses the load, so the gate is the backend starting "
             "at all -- and it is readable at /aowlspt/tarkov/selfcheck. Its "
             "falsifiers are in-module and each names the mutation that turns "
             "it red: drop the descendantsOf walk (a minted magazine "
             "survives), count absent roots as stripped, or make findSpace "
             "optimistic (the no-room refusal cannot fire). Always "
             "INCONCLUSIVE from this runner -- never PASS."},
]

# `--selftest` appears in these files only as prose, or as a flag the tool does
# not actually define. Listed so discovery does not report them as drift every
# run, and so the reason survives.
NOT_ITEMS = {
    "bc1.py": "mentions maptiles.py --selftest in a comment; defines none",
    "headless.py": "documents `aowlspt-backend --selftest`, a Nim binary; the "
                   "python wrapper defines no such flag (argparse rejects it)",
    "deploylock.py": "names `--selftest` only in the list of markers.py "
                     "options that read no artifact (so `deploylock markers "
                     "--selftest` takes no build lock); it defines no flag of "
                     "its own. Its `markers` mode is covered by "
                     "test_markers_under_lock in tools/test_buildlock.py, "
                     "which is slow and therefore not in the fast gate.",
}


# --------------------------------------------------------------------------
# The falsifier registry.
#
# Every tool in tools/ that emits a verdict must appear here. `proof` says
# WHERE the negative control lives, in words rather than line numbers, because
# line numbers rot and a rotted proof reads as a valid one.
# --------------------------------------------------------------------------

def V(tool, falsifier=None, proof="", gap="", reason=""):
    return {"tool": tool, "falsifier": falsifier, "proof": proof,
            "gap": gap, "reason": reason}


VERIFIERS = [
    # ---- audited: a registered negative control exists ---------------------
    V("cctool.py", "test_cctool.py",
      "case 2 builds a REAL gcc.exe that exits 1 with no output -- the exact "
      "observable shape of the measured 0xC0000139 loader death -- and asserts "
      "find_cc refuses it rather than returning it; case 4 poisons PATH with "
      "Git's mingw64\\bin, asserts the plain compile FAILS with zero bytes of "
      "diagnostic, and only then credits cc_env with rescuing it (if the "
      "unfixed compile also passes, the case reports INCONCLUSIVE, not PASS)"),
    V("irepl.py", "irepl_mutation.py",
      "injects the 3-state->2-state collapse into modctl.classify and asserts "
      "irepl.selftest() goes red"),
    V("modctl.py", "irepl_mutation.py",
      "the mutation is applied to modctl.classify itself"),
    V("deploy.py", "test_deploy_contains.py",
      "case 4 (--absent must FAIL when the literal is still present), case 6 "
      "(a failing --contains must make an otherwise-ok artifact FAIL), and the "
      "new ARTIFACT REPLACED / selftest-gate refusals in test_deploy.py"),
    V("run.py", "test_supervise.py",
      "drives the real Supervisor against synthetic logs; three NEGATIVE cases "
      "assert STALLED does NOT fire on changing phases and that heartbeats do "
      "not refresh the progress clock"),
    V("crashwatch.py", "test_crashwatch.py",
      "replays measured Crash_* reports and asserts the attribution line is "
      "absent when the module cannot be named"),
    V("il2cpp_resolve.py", "test_resolver_shared.py",
      "asserts sharedness answers unknown (not 'unique') for an address that "
      "is not in the methodPointers histogram -- the .get(rva,1) bug; and "
      "test_il2cpp_flags.py covers the CLI half: it registers a --bogus flag "
      "in VERB_FLAGS and asserts the SAME argv then passes, so the refusal is "
      "the registry's and not the message's"),
    V("test_cmdargs.py", "test_cmdargs.py",
      "every case carries its negative control IN THE SAME RUN: --force (an "
      "option the launcher owns) must produce no -aowl. token, so a launcher "
      "that forwarded everything cannot pass; a fabricated option name must be "
      "reported as a difference by the LauncherOptions drift comparison; and a "
      "fabricated verb name must be found ABSENT in aowlhost.nim. MEASURED "
      "2026-09-04: run against the launcher exe built BEFORE the forwarding "
      "change, it reported 3 FAIL and exit 1"),
    V("markers.py", "test_markers_falsifier.py",
      "asserts MISSING for an absent literal and INCONCLUSIVE for a truncated "
      "read, so PRESENT is not the only reachable answer"),
    V("hostcfg.py", "test_hostcfg_falsifier.py",
      "breaks the key table and asserts hostcfg's own --selftest goes red"),
    V("test_hostcfg.py", "test_hostcfg.py --falsify",
      "restores the pre-2026-09-04 `keys` column (the default hardcoded to "
      "`off`) and asserts test_hostcfg.py then reports FAIL and exit 1 -- "
      "measured 13 of 30 cases red. Its ground truth is a grep of the host "
      "sources, so hostcfg and flagaudit sharing one parser cannot make it "
      "pass vacuously"),
    V("test_mqpolicy.py", "test_mqpolicy.py",
      "case F recompiles the SAME header with -DAOWL_MQ_FALSIFY, restoring the "
      "pre-2026-09-02 'a stalled drain may run its work here' policy, and "
      "asserts the stalled-on-host case then answers 1. A green run whose "
      "negative control is also green reports INCONCLUSIVE, not PASS"),
    V("test_handleshape.py", "test_handleshape.py",
      "case 0 is a POSITIVE control -- four real handles, one of them the live "
      "RDX out of the crash dump itself -- so a predicate that rejected "
      "everything could not pass; case 5 is the negative control that decides "
      "whether the filter is worth anything, 200,000 uniform random 64-bit "
      "values of which essentially none may be accepted; and cases 3 and 4 "
      "show the two filters are INDEPENDENT, by feeding a value that satisfies "
      "each one alone"),
    V("drainaudit.py", "test_drainaudit.py",
      "a fixture tree whose POSTFIX site declares SEVEN register slots -- the "
      "measured EFT.UI.MenuScreen::Show(5-arg) crash shape -- must come back "
      "FAIL, and a 4-slot one must not, so the limit is shown to bite at "
      "exactly one stack argument rather than always. It also asserts a "
      "declared column that DISAGREES with the metadata fails, and that an "
      "accessor whose table the parser cannot see fails instead of passing "
      "vacuously -- which is the hole that really existed"),
    V("storelint.py", "storelint.py --falsify",
      "the falsifier asserts THREE things, because the lint has three ways to "
      "be worthless: a synthetic raw `cUxWritePtr` store MUST be flagged (so "
      "CLEAN is not the only reachable verdict); the same line carrying the "
      "`# storelint: allow HOST-OWNED --` annotation MUST NOT be (an exemption "
      "that does not work turns every legitimate site into a permanent finding "
      "and the lint gets switched off); and the gate file itself MUST NOT be "
      "flagged, since the raw store has to live somewhere. The BASELINE is "
      "additionally self-falsifying: an entry that no longer matches anything "
      "in the tree FAILS, so a routed site cannot leave a permanent hole"),
    V("fieldrefs.py", "fieldrefs.py check",
      "two self-checks gate every emission and both can fail: fldoff's "
      "System.String._stringLength@0x10 / _firstChar@0x14 (the OFFSET scan), "
      "and this tool's own `fieldref_self_check`, which re-derives "
      "UnityEngine.UI.Toggle.m_Group as width 8 / IS_REFERENCE. That last row "
      "is the one that matters: if the type-byte decoder were wrong a CLASS "
      "field would decode as a primitive and M4 (no narrow store into a "
      "reference slot) would silently stop applying to the whole table. "
      "`check` regenerates and diffs, so a hand-edited header exits 5"),
    V("uihooks_check.py", "test_uihooks_falsifier.py",
      "feeds a per-frame action trail and asserts FAIL, so PASS is not the "
      "only reachable verdict"),
    V("consistency.py", "consistency.py selftest",
      "a wrong AES key, a corrupted cipherLen, a removed signature, a build id "
      "that does not open the blob, a manifest too large for the record, and a "
      "serialiser that cannot reproduce the shipped bytes must EACH be refused; "
      "the last is the anti-vacuous gate -- without it `inject` would happily "
      "rewrite the payload in a serialisation the client cannot read"),
    V("allocasserts.py", "allocasserts.py --selftest",
      "four synthetic binaries: one carrying mimalloc's control string AND an "
      "MI_DEBUG-only assertion literal must come back FAIL (the measured shape "
      "of every DLL shipped before 2026-09-03); one carrying only the control "
      "must PASS; one carrying NEITHER must be INCONCLUSIVE, because with no "
      "proof mimalloc is even in the file, 'no assertions found' is 'we could "
      "not look'; and a fourth shows one surviving sentinel of five is enough. "
      "The runner also refuses if the case set does not exercise all three "
      "verdicts"),
    V("abilint.py", "abilint.py --selftest",
      "negative controls: a threadvar global, a mention inside a comment and a "
      "non-exported writer must all read CLEAN, so HAZARD is not the only answer"),
    V("dlss.py", "dlss.py selftest",
      "synthetic install tree; the wrong (unsigned) checksum formula, an "
      "off-by-one checksum, a same-size DLL tamper and a truncated backup "
      "must each make install/rollback FAIL, so PASS is not the only answer"),
    V("dlssapply.py", "dlssapply.py selftest",
      "a synthetic OptiScaler.ini: the four keys are written and read back, "
      "every OTHER key and every comment must survive, a missing file must "
      "read INCONCLUSIVE rather than PASS, a commented-out key must never "
      "match, a tampered key must read as a mismatch, and the version/upscaler "
      "names must still appear in mods/dlss/dlss.nim -- so PASS is not the "
      "only answer"),
    V("dlssnr.py", "dlssnr.py selftest",
      "synthetic game root and a synthetic OptiScaler zip: a model whose sha256 "
      "!= pin, a native-DX11 upscaler, a zip whose OptiScaler.dll is another "
      "DLL, a same-size model tamper, an ini edited back to auto, a manifest "
      "that LISTS a planned file, a fake running pid, an UNKNOWN running state, "
      "driver 581.42 without --force-driver, a Blackwell-only model on Turing, "
      "and a backup without its manifest must EACH be refused or FAIL; the "
      "manifest negative is re-armed and shown to PASS again so it is not "
      "stuck on"),
    V("nativetabs_check.py", "nativetabs_check.py selftest",
      "self-test case 4 is the negative control: changed geometry must make "
      "the comparison FAIL. This is the check that once accepted a FAIL "
      "verdict string as 'geometry unchanged'"),
    V("acceptance.py", "acceptance.py selftest",
      "offline replay of measured inspector prose; the falsifying inputs are "
      "an echo standing in for geometry and activeInHierarchy standing in for "
      "isOn -- the two 2026-09-01 vacuous passes"),
    V("modharness.py", "modharness.py --selftest",
      "tests/modharness_bad is a mod built to fault; the harness FAILs naming "
      "the phase, and reports INCONCLUSIVE rather than PASS when that control "
      "is not built"),
    V("botaudit.py", "botaudit.py --selftest",
      "drives the audit against a synthetic memory image with the bad case "
      "planted"),
    V("offscreen.py", "offscreen.py --selftest",
      "creates a real window and checks the detector against it; states "
      "explicitly that it says nothing about the client"),
    V("gamepaths.py", "gamepaths.py --selftest",
      "override honoured, retail fallback when the install has no DLL, "
      "install preferred when it does, sha16 empty on a missing file and "
      "16 hex on a real one"),
    V("pfxstress.py", "pfxstress.py --selftest",
      "parsers on captured inspector fixtures with a negative per parser "
      "(a wrong parent name, a wrong component type) and the stall regex "
      "refusing the boot-time 'has not called the method yet' line; the "
      "live loop confirms a freeze with a second probe, never a lone timeout"),
    V("entergame.py", "entergame.py --selftest",
      "offline; presses nothing and asserts the refusal paths"),
    V("exitraid.py", "exitraid.py --selftest"),
    V("shapeaudit.py", "shapeaudit.py --selftest"),

    # ---- KNOWN DEBT: a verifier with no negative control yet ---------------
    # Each of these needs a fixture the runner cannot synthesise in <30 lines.
    V("buildlock.py", gap="under active edit by another agent as of "
      "2026-09-02; tools/test_buildlock.py exercises it but is SLOW (>90 s, "
      "it spawns real lock contenders) so it is not in the fast gate. Wire "
      "its negative controls in once that work lands."),
    V("nimlint.py", gap="under active edit by another agent as of 2026-09-02; "
      "no test_nimlint.py exists yet"),
    V("headless.py", gap="a wrapper around the Nim backend's own --selftest; "
      "falsifying it needs a built aowlspt-backend.exe, which this runner "
      "must not build"),
    V("enterraid.py", gap="its --selftest blocks past 90 s in this checkout "
      "(see findings); falsifying it needs the hang diagnosed first"),
    V("betacheck.py", gap="needs a synthetic db.json + locale fixture pair"),
    V("bossalive.py", gap="reads live raid state; needs an inspector fixture"),
    V("botdigest.py", gap="needs a captured bot-log fixture"),
    V("catchcaption.py", gap="needs a live caption stream fixture"),
    V("dtotype.py", gap="its --selftest refuses without --manifest and no "
      "manifest is checked in -- so today it cannot even PASS, let alone fail"),
    V("dtogap.py", gap="needs a DTO corpus fixture"),
    V("emptygap.py", gap="needs a DTO corpus fixture"),
    V("factimport.py", gap="needs a facts.db fixture"),
    V("fieldshape.py", gap="needs GameAssembly + metadata; belongs with the "
      "resolver suite"),
    V("harness.py", gap="drives the live client end to end"),
    V("idxbind.py", gap="needs a live index"),
    V("il2cpp_gatevalidate.py", gap="needs GameAssembly; probe-driven"),
    V("il2cpp_symtab.py", "test_symtab.py",
      "`selftest` needs GameAssembly.dll, but the CONSUMER SCAN is pure text "
      "and is where the tool was measurably wrong (2026-09-04): "
      "test_symtab.py falsifies both defects by re-running the old logic and "
      "asserting the wrong answer, so the proofs CAN fail."),
    V("itemrefs.py", gap="needs db.json (41 MB, one line)"),
    V("litscan.py", gap="covered indirectly by test_deploy_contains.py, but "
      "has no direct negative control of its own"),
    V("lootscene.py", gap="needs a Unity scene fixture"),
    V("mapextract.py", gap="needs a Unity bundle fixture"),
    V("mapextract_terrain.py", gap="needs a Unity bundle fixture"),
    V("maptiles.py", gap="documents a measured max/mean error self-test that "
      "is not wired to a flag here"),
    V("oursample.py", gap="needs a wire capture fixture"),
    V("profiledupcheck.py", gap="needs a profile fixture"),
    V("routeproof.py", gap="needs a running backend"),
    V("settingsdump.py", gap="needs a live client"),
    V("settingstree.py", gap="needs a live client"),
    V("skillstill.py", gap="needs a live client"),
    V("sptsettings_check.py", gap="needs a running backend"),
    V("xferproof.py", gap="needs a running backend"),
    V("acceptance_admintrader.py", gap="needs a running backend + live client"),
    V("basement_check.py", gap="needs a built mods/basement DLL + aowlspt-sim"),
    V("basement_twomod.py", gap="needs built backend + tarkov + basement DLLs; stages a real two-mod backend"),
    V("inspectfixtures.py", reason="a fixture LIBRARY, not a verifier -- it "
      "carries the measured inspector prose the other self-tests replay. It "
      "is exercised by every fixture-driven item above."),
    V("gateaudit.py", "gateaudit.py --selftest",
      "case 2 puts a raw GetProcAddress bind and a raw call of two gated "
      "exports in a fixture tree and asserts FAIL; case 1 asserts the measured "
      "false positive -- a LOG MESSAGE naming a gated export followed by '(' "
      "-- is not reported; case 4 asserts a NEW site still FAILs while the "
      "baseline waives only the two keys it lists; case 5 asserts a missing "
      "export table is INCONCLUSIVE, never PASS"),
    V("sehnest.py", "sehnest.py --selftest",
      "case 3 makes a guarded body reach a second aowl_p_p_seh three hops "
      "down and asserts FAIL; case 2 (two UNRELATED guards) and case 7 (a "
      "guard body plus the emitted C wrapper that guards it -- the measured "
      "false positive that named five real files) assert it does NOT fire; "
      "case 6 asserts a tree with no guard at all is INCONCLUSIVE, because a "
      "graph with nothing to search cannot fail"),
    V("flagaudit.py", "flagaudit.py --selftest",
      "case 2 asserts a readBoolKeyDef defaulting true FAILs, case 4 that an "
      "allowlist entry with no real reason FAILs, case 5 that a STALE entry "
      "FAILs, case 6 that a non-literal default FAILs, and case 7 that a tree "
      "with no call site is INCONCLUSIVE"),
    V("inspector.py", "inspector.py --selftest",
      "replays measured inspector prose including the silence case; "
      "test_inspect_silence.py additionally asserts the suite can DISTINGUISH "
      "a broken HEAD from a fixed one and goes red when it cannot"),
]


# --------------------------------------------------------------------------
# Discovery -- so the registry cannot silently drift from the tree.
# --------------------------------------------------------------------------

def discover_selftest_tools():
    """Tools whose source mentions `--selftest`, by grep, as the task asks."""
    found = []
    for p in sorted(glob.glob(os.path.join(HERE, "*.py"))):
        base = os.path.basename(p)
        if base.startswith("test_"):
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        # `--selftest` ONLY. An earlier version also matched the bare string
        # "selftest" anywhere in the source, which reported eight tools as
        # registry drift every run for merely mentioning the word -- drift
        # noise that is always on trains the reader to ignore it, which is the
        # same failure as a check that never fires.
        if "--selftest" in src:
            found.append(base)
    return found


# Tools whose self-test is a POSITIONAL command rather than a flag, so the
# `--selftest` grep cannot see them. They are registry items; this set stops
# the drift check from also demanding a flag they do not have.
POSITIONAL_SELFTEST = {"acceptance.py", "nativetabs_check.py",
                       "uihooks_check.py"}


def discover_tests():
    return sorted(os.path.basename(p)
                  for p in glob.glob(os.path.join(HERE, "test_*.py")))


VERDICT_RE = re.compile(r"VERDICT")


def discover_verifiers():
    """Every tool that emits a verdict.

    The signature is deliberately mechanical: it says VERDICT, or it can say
    both INCONCLUSIVE and PASS. A tool that starts printing verdicts is
    therefore picked up WITHOUT anyone remembering to add it here.
    """
    found = []
    for p in sorted(glob.glob(os.path.join(HERE, "*.py"))):
        base = os.path.basename(p)
        if base.startswith("test_") or base == "selftests.py":
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        if VERDICT_RE.search(src) or ("INCONCLUSIVE" in src
                                      and re.search(r"\bPASS\b", src)):
            found.append(base)
    return found


# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------

TIMEOUT = {"fast": 120, "slow": 900}


def missing_needs(item):
    out = []
    for n in item["needs"]:
        if n.startswith("<") or not os.path.isabs(n):
            # A described need, not a path -- e.g. "a built emutest binary".
            if not os.path.exists(os.path.join(REPO, n)):
                out.append(n)
        elif not os.path.exists(n):
            out.append(n)
    return out


def run_item(item, verbose=False):
    """-> (status, seconds, detail). Never returns PASS for something unrun."""
    miss = missing_needs(item)
    if miss:
        return SKIP, 0.0, "needs " + ", ".join(miss)
    if item["cmd"] is None:
        return INCONCLUSIVE, 0.0, item.get("note") or "no runnable command"
    if not os.path.exists(item["cmd"][1]):
        return INCONCLUSIVE, 0.0, "not present: %s" % item["cmd"][1]
    t0 = time.time()
    try:
        r = subprocess.run(item["cmd"], capture_output=True, text=True,
                           timeout=TIMEOUT[item["speed"]], cwd=REPO)
    except subprocess.TimeoutExpired:
        return INCONCLUSIVE, time.time() - t0, ("TIMED OUT after %ds -- it did "
                                                "not answer, which is not a "
                                                "pass" % TIMEOUT[item["speed"]])
    except OSError as e:
        return INCONCLUSIVE, time.time() - t0, "could not launch: %s" % e
    dt = time.time() - t0
    text = (r.stdout or "") + (r.stderr or "")
    if verbose:
        sys.stdout.write(text)
    last = ""
    for line in reversed(text.strip().splitlines()):
        if line.strip():
            last = line.strip()[:100]
            break
    rc = r.returncode
    if rc == 0:
        return PASS, dt, last
    # A tool that answers 3 is saying INCONCLUSIVE in this repo's convention.
    if rc == 3 or "INCONCLUSIVE" in text.upper()[:0]:
        return INCONCLUSIVE, dt, last or "exit 3"
    if rc == 2 and "unrecognized arguments" in text:
        return INCONCLUSIVE, dt, "the flag this registry passes does not exist"
    return FAIL, dt, last or ("exit %s" % rc)


# --------------------------------------------------------------------------
# Falsifier audit
# --------------------------------------------------------------------------

def audit_falsifiers():
    """-> (untriaged, gaps, audited). `untriaged` is always a hard FAIL."""
    known = {v["tool"]: v for v in VERIFIERS}
    untriaged, gaps, audited = [], [], []
    for tool in discover_verifiers():
        v = known.get(tool)
        if v is None:
            untriaged.append(tool)
        elif v["falsifier"]:
            audited.append(v)
        elif v["reason"]:
            continue                       # explicitly not a verifier, with why
        elif v["gap"]:
            gaps.append(v)
        else:
            untriaged.append(tool)
    # A registered falsifier that names an item nobody runs is decorative.
    names = {i["name"] for i in ITEMS}
    for v in audited:
        if v["falsifier"] not in names:
            untriaged.append("%s -> falsifier %r is not a registry item"
                             % (v["tool"], v["falsifier"]))
    return untriaged, gaps, audited


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

def _git(*a):
    try:
        r = subprocess.run(["git"] + list(a), capture_output=True, text=True,
                           cwd=REPO, timeout=60)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def tree_key():
    """(head, dirty_hash). The dirty hash covers the CONTENT of every dirty
    source file, not just its name -- an edit that does not change the porcelain
    listing must still invalidate the cache."""
    head = _git("rev-parse", "HEAD").strip() or "no-head"
    status = _git("status", "--porcelain=v1", "-uall")
    h = hashlib.sha256(status.encode("utf-8", "replace"))
    for line in status.splitlines():
        rel = line[3:].strip().strip('"')
        if " -> " in rel:
            rel = rel.split(" -> ", 1)[1]
        if os.path.splitext(rel)[1] not in (".py", ".nim", ".json", ".md"):
            continue
        p = os.path.join(REPO, rel.replace("/", os.sep))
        try:
            if os.path.getsize(p) > 4 << 20:
                continue
            with open(p, "rb") as f:
                h.update(rel.encode("utf-8", "replace"))
                h.update(f.read())
        except OSError:
            h.update(b"<unreadable>" + rel.encode("utf-8", "replace"))
    return head, h.hexdigest()


def read_cache():
    try:
        with open(CACHE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def cache_is_green(max_age_s=1800):
    """-> (ok, why). Used by deploy.py. Only a GREEN, MATCHING, YOUNG cache
    counts; every other case is a reason to re-run, never a pass."""
    doc = read_cache()
    if not doc:
        return False, "no cached self-test result"
    head, dirty = tree_key()
    if doc.get("git_head") != head:
        return False, "cache is for a different HEAD"
    if doc.get("dirty_hash") != dirty:
        return False, "the working tree changed since the cached run"
    age = time.time() - doc.get("timestamp", 0)
    if age > max_age_s:
        return False, "cache is %.0f min old (limit %.0f)" % (age / 60.0,
                                                              max_age_s / 60.0)
    if doc.get("exit") != 0:
        return False, "the cached run was RED"
    if doc.get("mode") != "fast" and doc.get("mode") != "all":
        return False, "the cached run was not a full fast run"
    return True, "cached green run %.0f min ago" % (age / 60.0)


def write_cache(mode, code, rows, untriaged, gaps):
    head, dirty = tree_key()
    doc = {"git_head": head, "dirty_hash": dirty, "timestamp": time.time(),
           "timestamp_h": time.strftime("%Y-%m-%d %H:%M:%S"),
           "mode": mode, "exit": code,
           "untriaged_verifiers": untriaged,
           "falsifier_gaps": [v["tool"] for v in gaps],
           "items": [{"name": n, "status": s, "sec": round(d, 2),
                      "detail": t} for n, s, d, t in rows]}
    try:
        with open(CACHE, "w", encoding="utf-8", newline="\n") as f:
            json.dump(doc, f, indent=1)
    except OSError as e:
        print("  (could not write %s: %s -- the next run will not be able to "
              "reuse this result, which is the safe direction)" % (CACHE, e))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

MARK = {PASS: "PASS", FAIL: "FAIL", INCONCLUSIVE: "INCONC", SKIP: "SKIP"}


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="run every self-test; audit every verifier's falsifier")
    ap.add_argument("--fast", action="store_true",
                    help="fast items only (default)")
    ap.add_argument("--all", action="store_true", help="fast + slow")
    ap.add_argument("--list", action="store_true", help="print the registry")
    ap.add_argument("--falsifiers", action="store_true",
                    help="run the falsifier audit only")
    ap.add_argument("--strict", action="store_true",
                    help="count KNOWN-DEBT falsifier gaps as failures too "
                         "(implied by --all)")
    ap.add_argument("--only", default=None,
                    help="substring filter on item names")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="stream each item's output")
    ap.add_argument("--no-cache-write", action="store_true")
    args = ap.parse_args(argv)

    mode = "all" if args.all else "fast"
    strict = args.strict or args.all

    untriaged, gaps, audited = audit_falsifiers()

    if args.list:
        for it in ITEMS:
            print("%-6s %-42s %s" % (it["speed"], it["name"],
                                     it.get("note", "")))
        print("\n%d items; %d verifiers audited, %d gaps, %d untriaged"
              % (len(ITEMS), len(audited), len(gaps), len(untriaged)))
        return 0

    if args.falsifiers:
        report_falsifiers(untriaged, gaps, audited)
        return 1 if untriaged or (strict and gaps) else 0

    items = [i for i in ITEMS if args.all or i["speed"] == "fast"]
    if args.only:
        items = [i for i in items if args.only in i["name"]]

    # Drift: something in the tree that the registry has never heard of.
    reg_files = set()
    for i in ITEMS:
        if i["cmd"]:
            reg_files.add(os.path.basename(i["cmd"][1]))
    reg_files |= POSITIONAL_SELFTEST | {"selftests.py"}
    drift = [t for t in discover_tests() if t not in reg_files]
    drift += [t for t in discover_selftest_tools()
              if t not in reg_files and t not in NOT_ITEMS]

    print("aowlspt self-tests -- %s (%d items)" % (mode, len(items)))
    print("=" * 78)
    rows = []
    t_all = time.time()
    for it in items:
        sys.stdout.write("%-44s " % it["name"][:44])
        sys.stdout.flush()
        st, dt, detail = run_item(it, args.verbose)
        rows.append((it["name"], st, dt, detail))
        print("%-6s %6.1fs  %s" % (MARK[st], dt, detail[:60]))
    total = time.time() - t_all

    print("=" * 78)
    n = {k: sum(1 for r in rows if r[1] == k) for k in (PASS, FAIL,
                                                        INCONCLUSIVE, SKIP)}
    print("%d PASS  %d FAIL  %d INCONCLUSIVE (could not run)  %d SKIP (needs "
          "absent)   %.1fs" % (n[PASS], n[FAIL], n[INCONCLUSIVE], n[SKIP],
                               total))

    bad = [r for r in rows if r[1] == FAIL]
    unrun = [r for r in rows if r[1] == INCONCLUSIVE]
    if bad:
        print("\nFAILED:")
        for name, _s, _d, detail in bad:
            print("  %-42s %s" % (name, detail))
    if unrun:
        print("\nCOULD NOT RUN (this is NOT a pass):")
        for name, _s, _d, detail in unrun:
            print("  %-42s %s" % (name, detail))
    skipped = [r for r in rows if r[1] == SKIP]
    if skipped:
        print("\nSKIPPED, input absent on this machine:")
        for name, _s, _d, detail in skipped:
            print("  %-42s %s" % (name, detail))

    report_falsifiers(untriaged, gaps, audited)

    if drift:
        print("\nREGISTRY DRIFT -- in the tree, not in ITEMS:")
        for d in sorted(set(drift)):
            print("  %s" % d)

    code = 0
    if bad or unrun:
        code = 1 if bad else 3
    if untriaged or drift:
        code = 1
    if strict and gaps:
        code = 1

    print("\nexit %d" % code)
    if not args.no_cache_write:
        write_cache(mode, code, rows, untriaged, gaps)
    return code


def report_falsifiers(untriaged, gaps, audited):
    print("\nfalsifier audit: %d verifiers with a registered negative control, "
          "%d KNOWN-DEBT gaps, %d untriaged" % (len(audited), len(gaps),
                                                len(untriaged)))
    for v in gaps:
        print("  VERIFIER WITHOUT FALSIFIER: %-26s %s" % (v["tool"], v["gap"]))
    for t in untriaged:
        print("  VERIFIER NOT TRIAGED (hard fail): %s" % t)
    if untriaged:
        print("  -- a tool that prints verdicts must be added to VERIFIERS in "
              "tools/selftests.py with a falsifier or a stated gap.")


if __name__ == "__main__":
    sys.exit(main())
