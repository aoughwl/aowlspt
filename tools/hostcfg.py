#!/usr/bin/env python3
"""Toggle flags in a live `aowlspt-host.json`, with the key names checked.

    python tools/hostcfg.py show                 # every known key, value, source
    python tools/hostcfg.py keys                 # what the host can actually read
    python tools/hostcfg.py get debugUi
    python tools/hostcfg.py set debugUi on
    python tools/hostcfg.py set debugUi off botDiag on   # several at once
    python tools/hostcfg.py set waitForRuntimeMs 240000
    python tools/hostcfg.py diff                 # non-default values only

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

BOOL_CALL = re.compile(r'readBoolKey(?:Def)?\(\s*"([A-Za-z0-9_]+)"')
# String-valued flags go through `readStrKey`, a shape `scrape_keys` did not
# know about at all, so every string key was invisible to this tool -- measured
# missing: `launchProfileId` (aowlhost.nim) and `uxBetaOverlayPos`
# (betanotice.nim). A key this tool cannot see is a key `set` refuses to write.
STR_CALL = re.compile(r'readStrKey\(\s*"([A-Za-z0-9_]+)"')
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
    files = host_sources(hostdir)
    if not files:
        sys.exit("no host sources under %s -- pass --host PATH" % hostdir)
    scanned = 0
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        hit = False
        for m in BOOL_CALL.finditer(text):
            keys.setdefault(m.group(1), ("bool", os.path.basename(path)))
            hit = True
        for m in NEEDLE_LIT.finditer(text):
            keys.setdefault(m.group(1), ("bool", os.path.basename(path)))
            hit = True
        for m in STR_CALL.finditer(text):
            keys.setdefault(m.group(1), ("str", os.path.basename(path)))
            hit = True
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
    for k in sorted(keys):
        kind, where = keys[k]
        d = INT_KEYS.get(k, '""' if kind == "str" else "off")
        print("  %-24s %-5s default %-8s %s%s%s"
              % (k, kind, d, DIM if C else "", where, RESET if C else ""))
    print("\n%d key(s). Anything not on this list is IGNORED by the host, "
          "silently." % len(keys))
    return 0


def cmd_show(args, keys, C, only_diff=False):
    p, text = read_cfg(args.root)
    print("%s%s%s\n" % (BOLD if C else "", p, RESET if C else ""))
    unknown = []
    for m in re.finditer(r'"([A-Za-z0-9_]+)"\s*:', text):
        k = m.group(1)
        if k not in keys and not k.startswith("//"):
            unknown.append(k)

    for k in sorted(keys):
        kind, _where = keys[k]
        present, raw, truthy = value_of(text, k)
        default = INT_KEYS.get(k, False)
        if kind == "bool":
            effective = truthy
            is_default = (effective is False)
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
        note = "" if present else ("%s(absent -> default)%s"
                                   % (DIM if C else "", RESET if C else ""))
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
        print("%s: absent -> default %s" % (k, INT_KEYS.get(k, "off")))
        return 0
    print("%s: %s   (host reads this as %s)"
          % (k, raw, ("on" if truthy else "off") if kind == "bool" else raw))
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
