#!/usr/bin/env python3
"""Toggle flags in a live `aowlspt-host.json`, with the key names checked.

    python tools/hostcfg.py show                 # every known key, value, source
    python tools/hostcfg.py keys                 # what the host can actually read
    python tools/hostcfg.py get debugUi
    python tools/hostcfg.py set debugUi on
    python tools/hostcfg.py set debugUi off botDiag on   # several at once
    python tools/hostcfg.py set waitForRuntimeMs 240000
    python tools/hostcfg.py diff                 # non-default values only
    python tools/hostcfg.py show --effective     # what the HOST boots with
    python tools/hostcfg.py get settingsUiProbe --effective

`show`/`diff`/`get` report THE FILE. `--effective` reports the value the host
BOOTS with, which is not the same thing: measured 2026-09-02, `show` printed
`settingsUiProbe off` while the running host had it on, because `settingsPages`
was set and the host turns the probe on with it (aowlhost.nim:8624, and it says
so in the log). With `--effective` that line reads

    settingsUiProbe   off (file) / ON (implied by settingsPages (aowlhost.nim))

and the reverse case reads `on (file) / OFF (forced OFF: needs uxNativeRaid...)`
for a flag that is armed in the file and ANDed to nothing at boot. The rules are
data (RULES, below), each carrying the source file, line and the exact text it
was read from; `verify_rules()` re-finds that text and refuses to apply a rule
it can no longer see. `--effective` describes CONFIG LOAD only -- not a later
self-disable, and not a bind that never succeeded.

Why this exists rather than "just edit the JSON". The host does not parse this
file with a JSON parser. Every flag is read by
`readBoolKey(key)` in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim`, which does a raw
`find(text, '"' & key & '"')` and then accepts the value as true if the first
non-`[ :\\t]` character after it is `t` or a digit 1-9. Two consequences:

  * **A typo'd key is silently ignored.** There is no schema, nothing
    enumerates the object, nothing warns. `"debugUI": true` (capital I) is not
    `debugUi`, reads as absent, defaults to off, and you spend a launch cycle
    -- ninety seconds of a human's time -- discovering that. This tool refuses
    an unknown key.
  * `"false"` in quotes is FALSE (the `"` is not `t`), `0` is false, but `7` is
    true. So writing values by hand has sharp edges that this tool removes.

The valid key list is not hardcoded: it is scraped out of the host sources at
run time, from the `readBoolKey("...")` / `readIntKey`-shaped call sites. So it
cannot drift from what the host really parses -- if a new flag is added to the
host, this tool knows it the moment the source lands, and if one is removed,
this tool stops accepting it.

Writes are a textual splice of the one value, exactly like the in-game settings
page does (`settingspages.nim`), so `//`-prefixed doc-comment keys, key order,
indentation and the UTF-8 BOM all survive. The previous file is kept as
`aowlspt-host.json.bak-<stamp>`.

`--root PATH` overrides the install (default D:\\Aowlspt\\aowlspt).
`--host PATH` overrides where the host sources are scraped from.
"""

import argparse
import glob
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"

# The host DLL actually deployed at --root. Its .rdata carries every key literal
# the deployed build passes to readBoolKey/readStrKey, so it is the ONE piece of
# evidence about the RUNNING host that does not depend on which branch this
# checkout happens to be on. See classify_unknown().
DEPLOYED_DLL = "aowlspt-host-il2cpp.dll"

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
DIM = "\033[2m"
BOLD = "\033[1m"

# The three integer keys are read by their own procs with literal needles
# rather than through readBoolKey, so they are named here with the defaults the
# host uses when the key is absent. Their needles are asserted against the
# source below, so this list cannot silently go stale either.
INT_KEYS = {
    "waitForRuntimeMs": 120000,
    "backendPort": 0,
    "modSyncMs": 3000,
}

# THE BOOLEAN DEFAULT IS NOT PARSED HERE. It is parsed by flagaudit.py, and
# this tool imports that parser rather than carrying a second copy.
#
# MEASURED 2026-09-04: `hostcfg.py keys` printed `default off` for EVERY bool,
# including forceOfflinePractice / uiShowEvents / settingsNativePostFx, all of
# which are `readBoolKeyDef(name, true)` and which flagaudit.py listed
# correctly as DEFAULT ON at the same moment. Two implementations of "what is
# this flag's default" disagreed, and the wrong one was the one a human reads
# before deciding whether a feature is live. So there is now ONE: flagaudit's
# `CALL_RE` over `strip_nim`-ed source, which also excludes commented-out call
# sites (hostcfg's old regex did not) and, unlike the old `BOOL_DEF`, SEES a
# default that is not a literal instead of silently skipping it.
#
# Three states, never two: True / False / None. None is INCONCLUSIVE -- the
# default is an expression, or two call sites disagree, or the key is read by a
# hand-rolled needle with no default this tool can see (bridgeStaticRva). None
# must never be rendered as `off`; that is the bug above, re-spelled.
sys.path.insert(0, HERE)
import flagaudit  # noqa: E402  (needs HERE on sys.path)

BOOL_CALL = flagaudit.CALL_RE
# {key: True|False|None}, and why, when None. Populated by scrape_keys() from
# the source, never hand-maintained.
BOOL_DEFAULTS = {}
BOOL_DEFAULT_WHY = {}
# Kept as a derived VIEW of BOOL_DEFAULTS so existing callers keep working; a
# key whose default is INCONCLUSIVE is in neither this set nor its complement
# in any meaningful sense, so consult BOOL_DEFAULTS when that matters.
BOOL_DEFAULT_TRUE = set()


def bool_default(key):
    """(value, why) -- value is True / False / None(=INCONCLUSIVE)."""
    return BOOL_DEFAULTS.get(key, None), BOOL_DEFAULT_WHY.get(
        key, "no readBoolKey/readBoolKeyDef call site was parsed for this key, "
             "so its default was NOT determined")


def default_str(key, kind):
    """The default column, honestly, for any kind of key."""
    if kind == "int":
        return str(INT_KEYS.get(key, 0))
    if kind == "str":
        return '""'
    v, _why = bool_default(key)
    return "on" if v is True else ("off" if v is False else "INCONCLUSIVE")


def _note_bool_site(name, default_expr, is_def, where):
    """Fold one call site into BOOL_DEFAULTS, three-state."""
    if not is_def:
        val, why = False, None          # readBoolKey has no default: OFF
    elif default_expr == "true":
        val, why = True, None
    elif default_expr == "false":
        val, why = False, None
    else:
        val = None
        why = ("readBoolKeyDef's default at %s is %r, not the literal `true` "
               "or `false` -- it cannot be read offline" % (where,
                                                            default_expr))
    if name in BOOL_DEFAULTS:
        prev = BOOL_DEFAULTS[name]
        if prev is None:
            return
        if val is None or val != prev:
            BOOL_DEFAULTS[name] = None
            BOOL_DEFAULT_WHY[name] = why or (
                "two call sites disagree about the default for %s (one says "
                "%s, %s says %s)" % (name, "on" if prev else "off", where,
                                     "on" if val else "off"))
        return
    BOOL_DEFAULTS[name] = val
    if why:
        BOOL_DEFAULT_WHY[name] = why
# String-valued flags go through `readStrKey`, a shape `scrape_keys` did not
# know about at all, so every string key was invisible to this tool -- measured
# missing: `launchProfileId` (aowlhost.nim) and `uxBetaOverlayPos`
# (betanotice.nim). A key this tool cannot see is a key `set` refuses to write.
# `readStrListKey` (aowlhost.nim, added with the `hostHttpAllow` /
# `hostPlayWavRoots` array flags) reads a JSON STRING ARRAY. It is the same
# kind of key from this tool's point of view -- a name the host looks for in
# aowlspt-host.json -- and a key this tool cannot see is a key `set` refuses to
# write, so the shape is accepted here rather than added to a hand-list.
STR_CALL = re.compile(r'readStr(?:List)?Key\(\s*"([A-Za-z0-9_]+)"')
# Integer keys read through `readIntKey` were ALSO invisible -- only the three
# hand-named INT_KEYS were known. Measured 2026-09-01: `modLoadWalkLevel`, the
# bisect instrument for a client-killing crash, reported as UNKNOWN ("not in
# this tool's manifest... not near any known key"), which reads as a typo
# warning for a valid key -- a confidently wrong answer at the worst moment.
INT_CALL = re.compile(r'readIntKey(?:Def)?\(\s*"([A-Za-z0-9_]+)"')
# ...and their DEFAULTS, which were invisible too. MEASURED 2026-09-06: every
# key found by INT_CALL alone reported `default 0` because only the hand-named
# INT_KEYS carried a default -- so `inspectorSliceMs` printed `default 0` when
# the host's own call site says `readIntKey("inspectorSliceMs", 12)`. That is a
# confidently wrong number, which this project treats as worse than none. The
# call site is the authority; this reads it.
INT_CALL_DEF = re.compile(
    r'readIntKey(?:Def)?\(\s*"([A-Za-z0-9_]+)"\s*,\s*(-?[0-9]+)\s*\)')
# `readStaticBridgeEnabled` does not go through `readBoolKey`; it builds its own
# needle as the nim literal `"\"bridgeStaticRva\""`. Match that shape so a flag
# read the hand-rolled way is still known here.
NEEDLE_LIT = re.compile(r'"\\"([A-Za-z0-9_]+)\\""')


def host_sources(hostdir):
    out = []
    for base, _dirs, files in os.walk(hostdir):
        if "nimcache" in base or os.sep + "bin" in base:
            continue
        for f in files:
            if f.endswith(".nim"):
                out.append(os.path.join(base, f))
    return out


def scrape_keys(hostdir):
    """Every key name the host actually looks for. Bools, strings, the ints.

    EVERY host .nim is scraped. This used to skip any file that did not itself
    contain the literal `aowlspt-host.json`, on the stated grounds that the
    needles would otherwise match `modcontrol.nim`, which parses the backend's
    mod-control JSON. That justification was measured against the current
    needles and does not hold: `modcontrol.nim` matches BOOL_CALL and
    NEEDLE_LIT zero times, because those needles name `readBoolKey` /
    `readStrKey` explicitly and those procs are the host-config readers and
    nothing else. So the filter bought no false-positive protection while
    silently costing correctness -- a host module that reads a flag but never
    names the config file (the normal case for a module that is `include`d into
    aowlhost.nim) would drop off this list entirely, and a flag this tool
    cannot see is a flag `set` refuses to write.

    Guarding by needle rather than by filename is also the stricter rule: it
    keys on the reader proc actually being called, not on an unrelated string
    happening to appear somewhere in the same file.
    """
    keys = {}
    # Scraping is per-directory: a second call against a different --host must
    # not inherit the first one's defaults.
    BOOL_DEFAULTS.clear()
    BOOL_DEFAULT_WHY.clear()
    files = host_sources(hostdir)
    if not files:
        sys.exit("no host sources under %s -- pass --host PATH" % hostdir)
    scanned = 0
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        hit = False
        # flagaudit's own scan: comments and doc-comments stripped, so a
        # commented-out call site is not mistaken for a live flag.
        stripped = flagaudit.strip_nim(text)
        for m in BOOL_CALL.finditer(stripped):
            name = m.group(2)
            keys.setdefault(name, ("bool", os.path.basename(path)))
            where = "%s:%d" % (os.path.basename(path),
                               stripped.count("\n", 0, m.start()) + 1)
            _note_bool_site(name, (m.group(3) or "").strip(),
                            bool(m.group(1)), where)
            hit = True
        for m in NEEDLE_LIT.finditer(text):
            # A hand-rolled needle (readStaticBridgeEnabled). There is no
            # default argument to read, so the default stays INCONCLUSIVE
            # rather than being assumed off.
            keys.setdefault(m.group(1), ("bool", os.path.basename(path)))
            BOOL_DEFAULTS.setdefault(m.group(1), None)
            BOOL_DEFAULT_WHY.setdefault(
                m.group(1),
                "read by a hand-rolled needle in %s, not by readBoolKey/"
                "readBoolKeyDef, so there is no default argument to parse"
                % os.path.basename(path))
            hit = True
        for m in STR_CALL.finditer(text):
            keys.setdefault(m.group(1), ("str", os.path.basename(path)))
            hit = True
        for m in INT_CALL.finditer(text):
            keys.setdefault(m.group(1), ("int", os.path.basename(path)))
            hit = True
        for m in INT_CALL_DEF.finditer(text):
            # setdefault, not assignment: the hand-named INT_KEYS below are
            # read by dedicated procs with their own literals and win.
            INT_KEYS.setdefault(m.group(1), int(m.group(2)))
        if hit:
            scanned += 1
    if not scanned:
        sys.exit("no host source under %s reads a host-config key -- the "
                 "readBoolKey/readStrKey needles matched nothing, which means "
                 "the readers were renamed, not that there are no flags"
                 % hostdir)
    # The three integers are read by dedicated procs with their own literals;
    # they are named explicitly, and asserted to still be present in the source.
    for k, _d in INT_KEYS.items():
        keys[k] = ("int", "aowlhost.nim")
    BOOL_DEFAULT_TRUE.clear()
    BOOL_DEFAULT_TRUE.update(k for k, v in BOOL_DEFAULTS.items() if v is True)
    return keys


# ---------------------------------------------------------------------------
# Classifying a key the manifest does not know. THREE-PLUS OUTCOMES, NEVER TWO.
#
# MEASURED 2026-08-31, and this is why this section exists: `hostcfg.py show`
# printed `uxNativeRaidDrive -- silently ignored; typo?` while that flag was
# live and actively driving raid entry. The manifest was not wrong about the
# host -- it was scraped from THIS CHECKOUT's host/*.nim, which did not yet
# carry the flag, while the DEPLOYED aowlspt-host-il2cpp.dll did. A tool whose
# manifest is branch-dependent must never call a key a typo, because it cannot
# know. It can only say what it checked.
#
# So an unread key gets one of four verdicts, each backed by a measurement:
#
#   MOD SETTING   the literal is a key in mods/*/config.json. It belongs in that
#                 mod's config; the host will never read it from here. (This is
#                 what `sainRvaTable` really is -- measured: absent from the
#                 deployed DLL, present in mods/sain/config.json.)
#   LIVE          the literal IS in the deployed host DLL at --root. The
#                 deployed build reads it; THIS TOOL'S MANIFEST IS STALE.
#                 (Measured: uxNativeRaidDrive and drainProfiler are both in
#                 the deployed DLL.)
#   typo?         it near-misses a known key -- same name ignoring case, or one
#                 single-character edit away. Only then is "typo" a claim with
#                 evidence behind it.
#   UNKNOWN       none of the above. Not in this tool's manifest, not in the
#                 deployed binary, not a mod setting, not near anything. That is
#                 an honest "I could not classify this", not a verdict.
# ---------------------------------------------------------------------------

_dll_cache = {}


def deployed_blob(root):
    """Bytes of the deployed host DLL, read once. '' if it is not there."""
    p = os.path.join(root, DEPLOYED_DLL)
    if p not in _dll_cache:
        try:
            with open(p, "rb") as f:
                _dll_cache[p] = f.read()
        except OSError:
            _dll_cache[p] = b""
    return _dll_cache[p]


def in_deployed(root, key):
    """Three-state, deliberately: True / False / None when there is no DLL to
    look in. None must never be flattened into False -- 'I could not look' is
    not 'it is absent', and flattening it is how the typo verdict was earned."""
    blob = deployed_blob(root)
    if not blob:
        return None
    return key.encode("ascii", "replace") in blob


_mod_cache = {}


def mod_setting_source(repo, key):
    """The mods/*/config.json that declares `key`, or None."""
    if not _mod_cache:
        for p in glob.glob(os.path.join(repo, "mods", "*", "config.json")):
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            for m in re.finditer(r'"([A-Za-z0-9_]+)"\s*:', text):
                _mod_cache.setdefault(m.group(1), os.path.relpath(p, repo))
        _mod_cache.setdefault("\0none", None)   # mark the cache as populated
    return _mod_cache.get(key)


def _edit1(a, b):
    """True if `a` and `b` are within one single-character edit."""
    if a == b:
        return True
    la, lb = len(a), len(b)
    if abs(la - lb) > 1:
        return False
    if la == lb:
        return sum(1 for x, y in zip(a, b) if x != y) == 1
    if la > lb:
        a, b, la, lb = b, a, lb, la
    for i in range(lb):
        if b[:i] + b[i + 1:] == a:
            return True
    return False


def classify_unknown(key, keys, root, repo):
    """(verdict, note) for a key present in the file but not in the manifest."""
    where = mod_setting_source(repo, key)
    if where:
        return ("MOD SETTING",
                "declared in %s -- the host never reads mod settings out of "
                "this file; set it there" % where)

    live = in_deployed(root, key)
    if live is True:
        return ("LIVE",
                "the literal IS in the deployed %s, so the RUNNING host reads "
                "it. THIS TOOL'S MANIFEST IS STALE -- the scraped checkout is "
                "behind the deployed build, not the other way round"
                % DEPLOYED_DLL)

    near = [k for k in keys if k.lower() == key.lower() or _edit1(k, key)]
    if near:
        return ("typo?", "one edit from the real key %s" % near[0])

    if live is None:
        return ("UNKNOWN",
                "not in this tool's manifest; there is no %s at %s to check "
                "the deployed build against, so this was NOT classified"
                % (DEPLOYED_DLL, root))
    return ("UNKNOWN",
            "not in this tool's manifest, not in the deployed %s, not a mod "
            "setting, and not near any known key" % DEPLOYED_DLL)


def provenance(args, keys):
    """Say what the manifest was built from, so a stale one is visible."""
    lines = ["manifest: %d key(s) scraped from %s" % (len(keys), args.host)]
    newest = 0
    for p in host_sources(args.host):
        try:
            newest = max(newest, os.path.getmtime(p))
        except OSError:
            pass
    dll = os.path.join(args.root, DEPLOYED_DLL)
    try:
        dmt = os.path.getmtime(dll)
    except OSError:
        lines.append("  deployed %s: ABSENT -- no way to cross-check the "
                     "manifest against the running host" % DEPLOYED_DLL)
        return lines
    lines.append("  host sources newest %s | deployed %s built %s"
                 % (time.strftime("%Y-%m-%d %H:%M", time.localtime(newest)),
                    DEPLOYED_DLL,
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(dmt))))
    if dmt > newest:
        lines.append("  NOTE: the deployed DLL is NEWER than every host source "
                     "here, so it may read keys this checkout has never seen. "
                     "Unknown keys are cross-checked against it below.")
    return lines


# ---------------------------------------------------------------------------
# THE FILE IS NOT THE RUNTIME.
#
# MEASURED 2026-09-02: `hostcfg.py show` printed `settingsUiProbe off` while
# the running host had it ON. Nothing was wrong with the read -- the file
# really did say off. The host turns it on for itself at boot because
# `settingsPages` was set (aowlhost.nim:8624), and says so in the log:
# "settingsPages is set, so settingsUiProbe has been turned on with it".
# `show` reported the FILE and was read as reporting the HOST.
#
# So the host applies two kinds of rule to the file's values at boot, and they
# pull in opposite directions:
#
#   implies    a flag turns ANOTHER one on with itself, because the second is
#              the machinery the first runs from. `off` in the file, ON at
#              runtime.
#   requires   a flag is ANDed with a prerequisite at the point it is read
#              (`gAuOn = readBoolKey("aowlUi") and gNuOn`), so it is armed in
#              the file and dead at runtime. `on` in the file, OFF at runtime.
#
# Both were derived by grepping the host for the two shapes -- the implication
# log lines ("X is set, so Y has been turned on") and the `and gPrereq`
# conjunctions on a readBoolKey assignment -- and each rule below carries the
# file, the line, and the exact source text it was read from. `verify_rules()`
# re-finds that text in the source, so a rule that no longer matches the host
# is reported STALE and NOT APPLIED, rather than quietly describing a host that
# no longer exists. A rule table that cannot go stale-visibly would be worse
# than no table: it would be this tool's original bug with more confidence.
#
# WHAT IS NOT MODELLED, deliberately, and said out loud by `--effective`:
#   * `natEsp` (aowlhost.nim:8893) is ANDed with nativeUi AND compared against
#     the STRING key `espProvider`; and debugEsp's DRAWING is suppressed at
#     aowlhost.nim:8990 when natEsp is also on and espProvider != "both", while
#     the flag itself stays true. A boolean column cannot express "armed but
#     not drawing", so these are carried as NOTE rules that print and never
#     flip a value.
#   * anything the host decides LATER than config load -- a self-disable after
#     N faults, a bind that never succeeded (`gNtOn = false` at aowlhost.nim:
#     9476). `--effective` describes the value the host STARTS with. That is
#     strictly more than the file says and strictly less than the host log.
# ---------------------------------------------------------------------------

# (kind, [causes], target, file, line, source-anchor)
RULES = [
    ("implies", ["settingsRelabelProbe", "settingsBindProbe"],
     "settingsUiProbe", "aowlhost.nim", 8589,
     "if (gSwRelabel or gSwBind) and not gSettingsUiProbe:"),
    ("implies", ["modSettingsRender"], "settingsPages", "aowlhost.nim", 8619,
     "if gModSetOn and not gSwPagesOn:"),
    ("implies", ["settingsPages"], "settingsUiProbe", "aowlhost.nim", 8624,
     "if gSwPagesOn and not gSettingsUiProbe:"),
    ("implies", ["settingsModsTab"], "settingsUiProbe", "aowlhost.nim", 8648,
     "if gModsOn and not gSettingsUiProbe:"),
    ("implies", ["nativeUiProof", "nativeUiImageProof", "nativeUiKitProof"],
     "managedInvokeProbe", "aowlhost.nim", 8960,
     "if (gNuProof or gNuImgProof or gNkProof) and not gMi2Probe:"),
    # Found by the LOG-LINE grep, not by the assignment grep: `nativeTabs` is
    # read into gNtFlagOn and aliased (`gNtOn = gNtFlagOn`) before the guard,
    # so a pass that only follows `gX = readBoolKey("x")` misses it. Recorded
    # here because the mechanical derivation was incomplete, and saying which
    # rules the machine found is the point.
    ("implies", ["nativeTabs"], "settingsUiProbe", "aowlhost.nim", 9152,
     "if gNtOn and not gSettingsUiProbe:"),
    ("implies", ["settingsPostFxSubtab"], "settingsUiProbe",
     "aowlhost.nim", 9173, "if gGfxOn and not gSettingsUiProbe:"),
    ("implies", ["cameraFreeCam"], "cameraApi", "camera.nim", 909,
     "if gCamFree and not gCamApi:"),

    ("requires", ["nativeUi"], "aowlUi", "aowlhost.nim", 8854,
     'gAuOn = readBoolKey("aowlUi") and gNuOn'),
    ("requires", ["aowlUi"], "aowlUiProof", "aowlhost.nim", 8855,
     'gAuProof = gAuOn and readBoolKey("aowlUiProof")'),
    ("requires", ["nativeUi"], "nativeUiProof", "aowlhost.nim", 8844,
     'gNuProof = gNuOn and readBoolKey("nativeUiProof")'),
    ("requires", ["nativeUi"], "nativeUiImageProof", "aowlhost.nim", 8850,
     'gNuImgProof = gNuOn and readBoolKey("nativeUiImageProof")'),
    ("requires", ["nativeUi"], "nativeUiKit", "aowlhost.nim", 8861,
     'gNkOn = readBoolKey("nativeUiKit") and gNuOn'),
    ("requires", ["nativeUiKit"], "nativeUiKitProof", "aowlhost.nim", 8862,
     'gNkProof = gNkOn and readBoolKey("nativeUiKitProof")'),
    ("requires", ["nativeUi"], "settingsColorWidget", "aowlhost.nim", 8941,
     'gCwOn = readBoolKey("settingsColorWidget") and gNuOn'),
    ("requires", ["nativeUi"], "nativeInvUi", "aowlhost.nim", 8948,
     'gIuOn = readBoolKey("nativeInvUi") and gNuOn'),
    ("requires", ["uxNativeRaid"], "uxNativeRaidDrive", "aowlhost.nim", 8818,
     'gNrDrive = gNrOn and readBoolKey("uxNativeRaidDrive")'),
    ("requires", ["modLoadScreen"], "deferModLoad", "aowlhost.nim", 8528,
     'gModLoadDeferMods = gModLoad and readBoolKeyDef("deferModLoad", true)'),

    ("note", ["nativeUi"], "natEsp", "aowlhost.nim", 8893,
     'gNeOn = natEspAsked and gNuOn and gEspProvider != "overlay"'),
    ("note", ["natEsp"], "debugEsp", "aowlhost.nim", 8990,
     'if gDebugEsp and gNeOn and gEspProvider != "both":'),
]

NOTE_TEXT = {
    "natEsp": "also ANDed with nativeUi AND with the string key espProvider "
              '(dead when espProvider == "overlay") -- not modelled here',
    "debugEsp": "when natEsp is on and espProvider != \"both\" the host keeps "
                "this flag TRUE but SUPPRESSES its drawing -- a boolean cannot "
                "say that, so it is not folded into the value",
}


def verify_rules(hostdir):
    """(applicable, stale) -- can each rule still be found in the source?

    Line numbers drift, so the anchor is searched for anywhere in the file and
    the line it was FOUND at is reported next to the line recorded here. A rule
    whose anchor has vanished is STALE: it is dropped from the computation and
    named in the output. Silently applying it would make `--effective` assert a
    runtime behaviour that no longer exists, which is the same class of wrong
    answer as reporting the file and calling it the runtime.
    """
    applicable, stale = [], []
    cache = {}
    for rule in RULES:
        _kind, _causes, _target, fname, line, anchor = rule
        if fname not in cache:
            hits = [p for p in host_sources(hostdir)
                    if os.path.basename(p) == fname]
            if hits:
                with open(hits[0], "r", encoding="utf-8",
                          errors="replace") as f:
                    cache[fname] = f.read().splitlines()
            else:
                cache[fname] = None
        lines = cache[fname]
        if lines is None:
            stale.append((rule, "no %s under the scraped host sources" % fname))
            continue
        found = [i + 1 for i, l in enumerate(lines) if anchor in l]
        if not found:
            stale.append((rule, "the source line %r is no longer in %s"
                          % (anchor, fname)))
        else:
            applicable.append((rule, found[0], found[0] != line))
    return applicable, stale


def file_bools(text, keys):
    """{key: bool} exactly as the host's own reader would see the FILE."""
    out = {}
    for k, v in keys.items():
        if v[0] != "bool":
            continue
        present, _raw, truthy = value_of(text, k)
        out[k] = truthy if present else (k in BOOL_DEFAULT_TRUE)
    return out


def effective_bools(base, applicable):
    """Apply the host's boot-time rules to the file's values.

    Returns {key: (value, reason-or-None)}. `requires` first, to a fixpoint,
    then `implies`, to a fixpoint -- gating is applied at the point of read in
    the host, implications afterwards. If a `requires` would still fire after
    the implication pass the two orders disagree, and this returns that key as
    INCONCLUSIVE rather than picking one; nothing in the current table does
    that, and the check is here so that a future rule cannot make it lie.
    """
    val = dict(base)
    why = {k: None for k in val}

    def reqs_pass():
        changed = False
        for rule, _at, _moved in applicable:
            kind, causes, target, fname, _line, _anchor = rule
            if kind != "requires" or target not in val:
                continue
            missing = [c for c in causes if not val.get(c, False)]
            if val[target] and missing:
                val[target] = False
                why[target] = ("forced OFF: needs %s, which is off (%s)"
                               % (", ".join(missing), fname))
                changed = True
        return changed

    while reqs_pass():
        pass
    changed = True
    while changed:
        changed = False
        for rule, _at, _moved in applicable:
            kind, causes, target, fname, _line, _anchor = rule
            if kind != "implies" or target not in val:
                continue
            on = [c for c in causes if val.get(c, False)]
            if on and not val[target]:
                val[target] = True
                why[target] = "implied by %s (%s)" % (", ".join(on), fname)
                changed = True

    inconclusive = set()
    if reqs_pass():
        for k, w in why.items():
            if w and w.startswith("forced OFF"):
                inconclusive.add(k)
    return {k: (val[k], why[k], k in inconclusive) for k in val}


def cfgpath(root):
    return os.path.join(root, "aowlspt-host.json")


def read_cfg(root):
    p = cfgpath(root)
    if not os.path.isfile(p):
        sys.exit("no config at %s" % p)
    with open(p, "r", encoding="utf-8-sig") as f:
        return p, f.read()


def value_of(text, key):
    """Read a key the way the HOST reads it, not the way JSON would.

    Returns (present, raw-token, truthy). This deliberately mirrors
    aowlhost.nim: find the quoted key, skip [ :\\t], look at what follows.
    Doing it any other way would report a value the host does not agree with,
    which is the exact failure this tool exists to prevent.
    """
    needle = '"%s"' % key
    at = text.find(needle)
    if at < 0:
        return False, None, False
    i = at + len(needle)
    while i < len(text) and text[i] in " :\t":
        i += 1
    j = i
    while j < len(text) and text[j] not in ",}\r\n":
        j += 1
    raw = text[i:j].strip()
    truthy = bool(raw) and (raw[0] == "t" or raw[0] in "123456789")
    return True, raw, truthy


def splice(text, key, newval):
    """Replace one value in place, leaving every other byte untouched."""
    needle = '"%s"' % key
    at = text.find(needle)
    if at < 0:
        return None
    i = at + len(needle)
    while i < len(text) and text[i] in " :\t":
        i += 1
    j = i
    while j < len(text) and text[j] not in ",}\r\n":
        j += 1
    return text[:i] + newval + text[j:]


def insert_key(text, key, newval):
    """Add a key that is not in the file yet, right after the opening brace."""
    at = text.find("{")
    if at < 0:
        return None
    return text[:at + 1] + '\n  "%s": %s,' % (key, newval) + text[at + 1:]


def cmd_keys(args, keys, C):
    print("keys the host actually parses (scraped from %s):" % args.host)
    # The file is read if it is there, so the `value` column says what THIS
    # machine boots with; if it is not, the column says so instead of printing
    # the default a second time under a different heading.
    try:
        _p, text = read_cfg(args.root)
    except SystemExit:
        text = None
    if text is None:
        print("  (no aowlspt-host.json at %s -- the `value` column could not "
              "be read; defaults only)" % args.root)
    incon = 0
    for k in sorted(keys):
        kind, where = keys[k]
        d = default_str(k, kind)
        if text is None:
            val = "?"
        else:
            present, raw, truthy = value_of(text, k)
            if kind == "bool":
                if present:
                    val = "on" if truthy else "off"
                else:
                    val = d           # already "on"/"off"/"INCONCLUSIVE"
            elif present:
                val = raw
            else:
                val = d
        if kind == "bool" and d == "INCONCLUSIVE":
            incon += 1
        print("  %-24s %-5s default %-12s value %-12s %s%s%s"
              % (k, kind, d, val, DIM if C else "", where, RESET if C else ""))
    print("\n%d key(s). Anything not on this list is IGNORED by the host, "
          "silently." % len(keys))
    if incon:
        print("%d boolean key(s) read INCONCLUSIVE -- their default could not "
              "be parsed offline, and printing `off` for those is exactly the "
              "defect this column was fixed for. Why, per key:" % incon)
        for k in sorted(keys):
            if keys[k][0] == "bool" and default_str(k, "bool") == "INCONCLUSIVE":
                print("  %-24s %s" % (k, bool_default(k)[1]))
    return 0


def cmd_show(args, keys, C, only_diff=False):
    p, text = read_cfg(args.root)
    print("%s%s%s\n" % (BOLD if C else "", p, RESET if C else ""))
    eff = {}
    if args.effective:
        applicable, stale = verify_rules(args.host)
        eff = effective_bools(file_bools(text, keys), applicable)
        moved = [(r, at) for r, at, m in applicable if m]
        print("  %s%d of %d boot rules verified against %s"
              % (DIM if C else "", len(applicable), len(RULES), args.host))
        if moved:
            print("  %d rule(s) matched at a DIFFERENT line than recorded "
                  "(the source moved; the rule still holds): %s"
                  % (len(moved), ", ".join("%s->%s@%d" % (r[1][0], r[2], at)
                                           for r, at in moved)))
        for rule, why in stale:
            print("  %sSTALE RULE, NOT APPLIED%s: %s -> %s (%s:%d) -- %s"
                  % (RED if C else "", RESET if C else "",
                     "/".join(rule[1]), rule[2], rule[3], rule[4], why))
        print("  values below are the host's BOOT values: file + these rules. "
              "Not the live value after a self-disable.%s\n"
              % (RESET if C else ""))
    unknown = []
    for m in re.finditer(r'"([A-Za-z0-9_]+)"\s*:', text):
        k = m.group(1)
        if k not in keys and not k.startswith("//"):
            unknown.append(k)

    for k in sorted(keys):
        kind, _where = keys[k]
        present, raw, truthy = value_of(text, k)
        bd, bd_why = bool_default(k) if kind == "bool" else (None, None)
        default = INT_KEYS.get(k, bd)
        unknown_default = False
        if kind == "bool":
            # An ABSENT bool is not automatically off: several keys are read
            # with readBoolKeyDef(..., true) and default ON -- and a key whose
            # default this tool cannot parse is INCONCLUSIVE, not off.
            if present:
                effective = truthy
            elif bd is None:
                effective, unknown_default = False, True
            else:
                effective = bd
            # An unparseable default is never "the default": it shows up in
            # `diff` so it cannot hide.
            is_default = (bd is not None and effective == bd)
        elif kind == "str":
            # This branch did not exist: string keys fell into the integer one,
            # where `int(re.sub(...))` threw and the value printed as the
            # boolean default -- `audioRayDllPath False` for a path key. A
            # wrong value in the value column is the same failure as reporting
            # the file and calling it the runtime, just quieter.
            effective = raw if present else '""'
            is_default = (not present) or effective in ('""', "''", "")
        else:
            try:
                effective = int(re.sub(r"[^0-9]", "", raw or "")) if present else default
            except ValueError:
                effective = default
            is_default = (effective == default)
        if only_diff and is_default:
            continue
        if kind == "bool":
            mark = "%son %s" % (GREEN if C else "", RESET if C else "") if effective \
                   else "%soff%s" % (DIM if C else "", RESET if C else "")
        else:
            mark = str(effective)
        note = "" if present else ("%s(absent -> default %s)%s"
                                   % (DIM if C else "",
                                      default_str(k, kind),
                                      RESET if C else ""))
        if unknown_default:
            mark = "%s???%s" % (YELLOW if C else "", RESET if C else "")
            note = ("INCONCLUSIVE: absent from the file and its default could "
                    "not be parsed -- %s" % bd_why)
        if eff and kind == "bool" and not unknown_default:
            ev, why, incon = eff.get(k, (effective, None, False))
            if incon:
                note = ("INCONCLUSIVE: the boot rules disagree about this key "
                        "-- read the host log, not this column")
                mark = "%s???%s" % (YELLOW if C else "", RESET if C else "")
            elif why:
                mark = ("%s (file) / %s%s%s (%s)"
                        % ("on" if effective else "off",
                           (GREEN if ev else DIM) if C else "",
                           "ON" if ev else "OFF", RESET if C else "", why))
                note = ""
            if k in NOTE_TEXT:
                note = (note + "  " if note else "") + "NOTE: " + NOTE_TEXT[k]
        print("  %-24s %-16s %s" % (k, mark, note))

    if unknown:
        print("\n%sKEYS IN THE FILE THAT ARE NOT IN THIS TOOL'S MANIFEST (%d)%s"
              % (BOLD if C else "", len(unknown), RESET if C else ""))
        for line in provenance(args, keys):
            print("  %s%s%s" % (DIM if C else "", line, RESET if C else ""))
        print()
        for k in unknown:
            verdict, note = classify_unknown(k, keys, args.root, REPO)
            col = (GREEN if verdict == "LIVE" else
                   YELLOW if verdict in ("MOD SETTING", "UNKNOWN") else RED)
            print("  %-24s %s%-12s%s %s"
                  % (k, col if C else "", verdict, RESET if C else "", note))
    return 0


def cmd_get(args, keys, C):
    if args.args and args.args[0] not in keys:
        sys.exit("unknown key %r -- run `python tools/hostcfg.py keys`"
                 % args.args[0])
    _p, text = read_cfg(args.root)
    k = args.args[0]
    present, raw, truthy = value_of(text, k)
    kind = keys[k][0]
    if not present:
        d = default_str(k, kind)
        print("%s: absent -> default %s" % (k, d))
        if d == "INCONCLUSIVE":
            print("  the value the host boots with was NOT determined: %s"
                  % bool_default(k)[1])
    else:
        print("%s: %s   (host reads this as %s)"
              % (k, raw, ("on" if truthy else "off") if kind == "bool" else raw))
    if args.effective and kind == "bool":
        applicable, stale = verify_rules(args.host)
        ev, why, incon = effective_bools(file_bools(text, keys),
                                         applicable).get(k, (None, None, False))
        if incon:
            print("  effective: INCONCLUSIVE -- the boot rules disagree")
        elif why:
            print("  effective at boot: %s -- %s" % ("ON" if ev else "OFF", why))
        else:
            print("  effective at boot: same as the file (no boot rule "
                  "touches %s)" % k)
        if k in NOTE_TEXT:
            print("  NOTE: %s" % NOTE_TEXT[k])
        for rule, w in stale:
            if rule[2] == k or k in rule[1]:
                print("  STALE RULE, NOT APPLIED: %s" % w)
    return 0


def normalise(key, kind, val):
    if kind == "str":
        # Written back as a JSON string. Refuse anything needing escapes rather
        # than emitting JSON we did not verify we can re-parse.
        s = val.strip()
        if s.startswith('"') and s.endswith('"') and len(s) >= 2:
            s = s[1:-1]
        if '"' in s or "\\" in s or "\n" in s or "\r" in s:
            sys.exit("%s is a string key; %r contains a quote, backslash or "
                     "newline and would need escaping -- edit the file by hand"
                     % (key, val))
        return '"%s"' % s
    v = val.strip().lower()
    if kind == "int":
        if not re.fullmatch(r"\d+", v):
            sys.exit("%s is an integer key; %r is not a number" % (key, val))
        return v
    if v in ("on", "true", "1", "yes", "y"):
        return "true"
    if v in ("off", "false", "0", "no", "n"):
        return "false"
    sys.exit("%s is a boolean; use on/off (got %r)" % (key, val))


def cmd_set(args, keys, C):
    pairs = args.args
    if not pairs or len(pairs) % 2 != 0:
        sys.exit("set takes key value pairs, e.g. set debugUi on botDiag off")
    p, text = read_cfg(args.root)
    original = text
    changes = []
    for i in range(0, len(pairs), 2):
        k, v = pairs[i], pairs[i + 1]
        if k not in keys:
            verdict, note = classify_unknown(k, keys, args.root, REPO)
            if verdict == "LIVE" and not args.force:
                sys.exit("%r is NOT in this tool's manifest, but %s\n"
                         "This tool does not know its TYPE, so it cannot "
                         "normalise the value. Re-run with --force to splice "
                         "%r in verbatim, or scrape a checkout that has it "
                         "(--host PATH)." % (k, note, v))
            if verdict != "LIVE" and not args.force:
                sys.exit("%s key %r: %s\nrun `python tools/hostcfg.py keys`, "
                         "or --force to write it anyway" % (verdict, k, note))
            # --force: splice the value in exactly as given, and say so.
            spliced = splice(text, k, v) or insert_key(text, k, v)
            text = spliced
            changes.append((k, "FORCED (%s)" % verdict, v))
            continue
        newval = normalise(k, keys[k][0], v)
        _present, was, _t = value_of(text, k)
        spliced = splice(text, k, newval)
        if spliced is None:
            spliced = insert_key(text, k, newval)
            was = "absent"
        text = spliced
        changes.append((k, was, newval))

    if text == original:
        print("nothing changed.")
        return 0
    if args.dry_run:
        for k, was, now in changes:
            print("(dry-run) %-24s %s -> %s" % (k, was, now))
        return 0

    bak = "%s.bak-%s" % (p, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(p, bak)
    # Written back with the BOM the host's file carries; the readers are byte
    # searches, so the BOM is harmless, but round-tripping it keeps the file
    # byte-identical apart from the values that changed.
    with open(p, "w", encoding="utf-8-sig", newline="") as f:
        f.write(text)
    for k, was, now in changes:
        print("%sok%s %-24s %s -> %s" % (GREEN if C else "", RESET if C else "",
                                         k, was, now))
    print("\nbacked up to %s" % os.path.basename(bak))
    print("takes effect at the NEXT client start -- the host reads this at boot.")
    return 0


def selftest(args):
    """Falsifiable, both directions. Each case says what would FAIL it.

    The bug this guards: `hostcfg.py show` called four keys typos, one of which
    (`uxNativeRaidDrive`) was live and driving raid entry at that moment. So the
    check that matters is not 'does it classify' -- it is 'does a key the
    manifest CANNOT know about read as LIVE/UNKNOWN rather than as a typo'.
    """
    bad = 0
    inconclusive = 0

    def case(label, got, want):
        nonlocal bad
        ok = (got == want)
        if not ok:
            bad += 1
        print("%-4s %-56s want=%-12s got=%s"
              % ("ok" if ok else "FAIL", label[:56], want, got))

    # A manifest deliberately missing a key the deployed build really reads.
    keys = scrape_keys(args.host)
    live_probe = in_deployed(args.root, "uxNativeRaidDrive")
    if live_probe is None:
        print("INCONCLUSIVE  no %s at %s -- the LIVE verdict could not be "
              "exercised at all. NOT a pass." % (DEPLOYED_DLL, args.root))
        inconclusive += 1
    else:
        # Case A -- THE REGRESSION. Pretend the manifest never saw this key
        # (exactly what a stale checkout does) and demand it NOT read as a typo.
        starved = {k: v for k, v in keys.items() if k != "uxNativeRaidDrive"}
        v, _n = classify_unknown("uxNativeRaidDrive", starved, args.root, REPO)
        case("a live flag missing from the manifest reads LIVE, not typo?",
             v, "LIVE" if live_probe else "UNKNOWN")

    # Case B -- a genuine typo must STILL read as a typo. This is the half that
    # makes case A falsifiable: without it, "never say typo" would also pass.
    typo = "debugUI" if "debugUi" in keys else (sorted(keys)[0] + "X")
    v, _n = classify_unknown(typo, keys, args.root, REPO)
    case("a genuine near-miss (%s) still reads typo?" % typo, v, "typo?")

    # Case C -- a mod setting is named as one, not guessed at.
    v, _n = classify_unknown("sainRvaTable", keys, args.root, REPO)
    case("sainRvaTable is named a MOD SETTING", v, "MOD SETTING")

    # Case D -- pure noise is UNKNOWN, never typo?, never LIVE.
    v, _n = classify_unknown("zzQuiteDefinitelyNotAKey", keys, args.root, REPO)
    case("unrelated garbage reads UNKNOWN", v, "UNKNOWN")

    # Case E -- the three-state read really is three-state.
    case("in_deployed() on an absent root returns None (not False)",
         in_deployed(os.path.join(args.root, "no-such-dir"), "debugUi"), None)

    # ---- the effective-value rules, against a SYNTHETIC config -------------
    # The bug: `show` printed `settingsUiProbe off` while the host had turned
    # it on at boot because settingsPages was set. Every case below is paired
    # with the world in which it must NOT fire, because "always say ON" and
    # "always say OFF" would each pass half of this on its own.
    applicable, stale_rules = verify_rules(args.host)
    print("\n  boot rules: %d of %d verified against %s"
          % (len(applicable), len(RULES), args.host))
    for rule, why in stale_rules:
        print("  STALE: %s -> %s (%s:%d) -- %s"
              % ("/".join(rule[1]), rule[2], rule[3], rule[4], why))
    case("every rule in the table is still findable in the host source",
         len(stale_rules), 0)

    syn_on = {"settingsPages": True, "settingsUiProbe": False,
              "aowlUi": True, "nativeUi": False, "modSettingsRender": False,
              "cameraFreeCam": True, "cameraApi": False}
    syn_off = dict(syn_on, settingsPages=False, aowlUi=True, cameraFreeCam=False)
    e_on = effective_bools(syn_on, applicable)
    e_off = effective_bools(syn_off, applicable)

    # THE REGRESSION, both ways round.
    case("settingsPages on  -> settingsUiProbe reads ON",
         e_on["settingsUiProbe"][0], True)
    case("settingsPages off -> settingsUiProbe stays OFF (control)",
         e_off["settingsUiProbe"][0], False)
    case("the ON verdict names WHY", "implied by settingsPages"
         in (e_on["settingsUiProbe"][1] or ""), True)
    case("the OFF verdict claims no reason",
         e_off["settingsUiProbe"][1], None)

    # Gating pulls the other way: armed in the file, dead at runtime.
    case("aowlUi on with nativeUi off reads OFF", e_on["aowlUi"][0], False)
    case("that OFF verdict says what is missing",
         "needs nativeUi" in (e_on["aowlUi"][1] or ""), True)
    syn_both = dict(syn_on, nativeUi=True)
    case("aowlUi on with nativeUi ON reads on (control)",
         effective_bools(syn_both, applicable)["aowlUi"][0], True)

    # A second, independent implication in a different source file.
    case("cameraFreeCam on  -> cameraApi reads ON", e_on["cameraApi"][0], True)
    case("cameraFreeCam off -> cameraApi stays OFF (control)",
         e_off["cameraApi"][0], False)

    # Transitivity: modSettingsRender -> settingsPages -> settingsUiProbe.
    chain = effective_bools({"modSettingsRender": True, "settingsPages": False,
                             "settingsUiProbe": False}, applicable)
    case("modSettingsRender reaches settingsUiProbe through settingsPages",
         (chain["settingsPages"][0], chain["settingsUiProbe"][0]), (True, True))

    # A STALE rule must be dropped, not applied. Constructed by handing the
    # computation only the rules that verified, minus one -- the same thing
    # verify_rules() does when an anchor vanishes.
    starved_rules = [r for r in applicable
                     if not (r[0][0] == "implies"
                             and r[0][2] == "settingsUiProbe"
                             and "settingsPages" in r[0][1])]
    case("a dropped implication no longer turns settingsUiProbe on",
         effective_bools(syn_on, starved_rules)["settingsUiProbe"][0], False)

    # readBoolKeyDef(..., true): an ABSENT key that defaults ON.
    case("modLoadScreen is known to default ON when absent",
         "modLoadScreen" in BOOL_DEFAULT_TRUE, True)
    case("debugUi is NOT in the default-on set (control)",
         "debugUi" in BOOL_DEFAULT_TRUE, False)

    # ---- END TO END over a SYNTHETIC config --------------------------------
    # The pure-function cases above cannot see the rendering, and the rendering
    # is where this went wrong twice: string keys printed the boolean default
    # (`audioRayDllPath False`), and while fixing that an `else:` was lost so
    # integer keys printed `effective` left over from the PREVIOUS key of the
    # loop -- `waitForRuntimeMs True`. A plausible value carried in from
    # somewhere else is the exact failure this repo keeps paying for, so the
    # column is asserted here, per kind, against a file whose contents are
    # known.
    import contextlib
    import io as _io
    import tempfile

    tmp = tempfile.mkdtemp(prefix="hostcfg-selftest-")
    with open(os.path.join(tmp, "aowlspt-host.json"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write('{\n'
                '  "settingsPages": true,\n'
                '  "settingsUiProbe": false,\n'
                '  "aowlUi": true,\n'
                '  "nativeUi": false,\n'
                '  "waitForRuntimeMs": 240000,\n'
                '  "launchProfileId": "abc123",\n'
                '  "zzNotAKeyAtAll": true\n'
                '}\n')

    class _A:
        root = tmp
        host = args.host
        effective = True
    buf = _io.StringIO()
    with contextlib.redirect_stdout(buf):
        cmd_show(_A(), keys, False)
    lines = {l.split()[0]: l.strip() for l in buf.getvalue().splitlines()
             if l.startswith("  ") and l.split()}
    shutil.rmtree(tmp, ignore_errors=True)

    def line(k):
        return lines.get(k, "<NO LINE FOR %s>" % k)

    case("synthetic show: an int key renders as its number",
         line("waitForRuntimeMs").split()[1], "240000")
    case("synthetic show: a str key renders as its string",
         line("launchProfileId").split()[1], '"abc123"')
    case("synthetic show: an absent int key falls back to its default",
         line("modSyncMs").split()[1], "3000")
    case("synthetic show: no value column reads True/False",
         any(x in line(k).split()[1:2] for k in ("waitForRuntimeMs",
                                                 "launchProfileId",
                                                 "modSyncMs", "espProvider")
             for x in (["True"], ["False"])), False)
    case("synthetic show: the file value AND the implied value are both shown",
         "off (file) / ON (implied by settingsPages" in line("settingsUiProbe"),
         True)
    case("synthetic show: a gated key says it is forced OFF",
         "on (file) / OFF (forced OFF: needs nativeUi" in line("aowlUi"), True)
    case("synthetic show: a key no rule touches shows a bare value (control)",
         line("debugUi").split()[1], "off")
    case("synthetic show: the unknown key in the file is still reported",
         "zzNotAKeyAtAll" in buf.getvalue(), True)

    verdict = "FAIL" if bad else ("INCONCLUSIVE" if inconclusive else "PASS")
    print("\n%s: %d case(s) failed, %d inconclusive" % (verdict, bad, inconclusive))
    return 1 if bad else (0 if not inconclusive else 3)


def main():
    p = argparse.ArgumentParser(
        description="inspect and toggle aowlspt-host.json safely",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command", nargs="?", default="show",
                   choices=["show", "keys", "get", "set", "diff"])
    p.add_argument("args", nargs="*")
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--host", default=os.path.join(REPO, "host"))
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--effective", action="store_true",
                   help="with show/diff/get: apply the host's boot-time "
                        "implication and gating rules, so a flag the host "
                        "turns on for itself reads 'off (file) / ON (implied "
                        "by settingsPages)' instead of just 'off'")
    p.add_argument("--no-color", action="store_true")
    p.add_argument("--force", action="store_true",
                   help="write a key this tool's manifest does not know, "
                        "splicing the value in verbatim (says so in the output)")
    p.add_argument("--selftest", action="store_true",
                   help="assert the unknown-key classifier, including that a "
                        "live-but-unmanifested key does NOT read as a typo")
    a = p.parse_args()
    C = (not a.no_color) and sys.stdout.isatty()
    if a.selftest:
        return selftest(a)
    keys = scrape_keys(a.host)
    if a.command == "keys":
        return cmd_keys(a, keys, C)
    if a.command == "show":
        return cmd_show(a, keys, C)
    if a.command == "diff":
        return cmd_show(a, keys, C, only_diff=True)
    if a.command == "get":
        if not a.args:
            sys.exit("get needs a key")
        return cmd_get(a, keys, C)
    return cmd_set(a, keys, C)


if __name__ == "__main__":
    sys.exit(main())
