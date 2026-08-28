#!/usr/bin/env python3
"""Every declared setting must resolve to a path in its mod's config.json.

WHY THIS EXISTS
---------------
Measured 2026-08-28 against the live install: the F3 per-mod profiler toggle
was pressed four times. Each time the backend logged "queued a client settings
edit for aowl.debug (key=profiler)" and the host logged "config set profiler on
aowl.debug did not persist: no config.json for aowl.debug". The setting
rendered, the edit was accepted, and it had nowhere to land.

The repo was fine -- mods/debug/config.json exists and contains "profiler":
false. What was missing was any mechanism that SHIPPED it: no entry in
tools/deploy.json copied a config.json for any mod, ever. The mods that had one
in the live install got it from an earlier hand-copy, and the three newest
(debug, textures, waypoints) never did.

So there are two separate assertions, and this file makes both of them, because
either alone passes while the feature is broken:

  A. REPO   -- every setting a mod declares has a key in that mod's
               config.json (this file).
  B. INSTALL-- every mod that declares settings HAS a config.json in the live
               install (tools/deploy.py, the `seed` rules).

WHAT MAKES THIS FALSIFIABLE
---------------------------
It asserts a property of the FINISHED STATE -- the union of what the schema
declares versus what the file holds -- not a property of anything this script
wrote. Delete one key from any config.json, or delete a config.json outright,
and it goes red naming the key and the mod. That is the input that makes it
fail, which per CLAUDE.md 9b is what distinguishes a check from a ritual.

Three verdicts, never two. A mod whose schema this cannot parse is
INCONCLUSIVE, not a pass: "I could not look" is not "it is fine".

  python tools/settingscheck.py            # all mods
  python tools/settingscheck.py --mod debug
"""
import argparse
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `boolSetting("key", ...)`, `floatSetting("key", ...)`, `keybindSetting(...)`,
# `selectSetting(...)`, `enumSetting(...)`, `intSetting(...)`,
# `stringSetting(...)`. The first string literal is always the config key.
DECL = re.compile(r'\b(?:bool|float|int|string|enum|select|keybind)Setting\s*\(\s*"([^"]+)"')

# A row the mod itself declares as not backed by anything. These are allowed to
# have no config key ONLY if they also have no config key today -- see below.
IMPLEMENTED_FALSE = re.compile(r'implemented\s*=\s*false')

OK, FAIL, INCONCLUSIVE = "ok", "FAIL", "INCONCLUSIVE"


def mod_dirs(only):
    roots = []
    for base in ("mods", "examples"):
        d = os.path.join(REPO, base)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if os.path.isdir(p):
                if only and name != only:
                    continue
                roots.append((name, p))
    return roots


def declared_keys(path):
    """Every setting key declared in the .nim sources under `path`.

    Returns (keys, note). `note` is non-empty when nothing could be parsed,
    which is INCONCLUSIVE rather than an empty pass.
    """
    keys = []
    seen_any_nim = False
    for root, _dirs, files in os.walk(path):
        for f in files:
            if not f.endswith(".nim"):
                continue
            seen_any_nim = True
            fp = os.path.join(root, f)
            try:
                text = open(fp, "rb").read().decode("utf-8", "replace")
            except OSError as e:
                return [], "could not read %s: %s" % (fp, e)
            for m in DECL.finditer(text):
                k = m.group(1)
                if k not in keys:
                    keys.append(k)
    if not seen_any_nim:
        return [], "no .nim sources under %s" % path
    return keys, ""


def resolves(cfg, key):
    """Does `key` name a real value in `cfg`?

    A setting key is a DOTTED PATH, not a top-level name -- `sain` declares
    `roles.pmc.engageDistance` and `morebots` declares `population.capFloor`,
    both of which live nested. The first version of this walked only the top
    level and reported 32 of sain's 38 settings unbacked, which is the exact
    "audit walked only the top level, where none of the bugs were" shape this
    repo already has a commit for (dtotype, f0ae3f3). A check that reports 32
    false positives gets ignored, and then it reports the one true positive to
    nobody.
    """
    node = cfg
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return False
        node = node[part]
    return True


def check_mod(name, path):
    keys, note = declared_keys(path)
    if note:
        return INCONCLUSIVE, [note], 0
    if not keys:
        # A mod that declares no settings needs no config.json. waypoints
        # declares none today and that is a real state, not a failure.
        return OK, ["declares no settings"], 0

    cfg_path = os.path.join(path, "config.json")
    if not os.path.isfile(cfg_path):
        return FAIL, [
            "declares %d setting(s) and has NO config.json. Every one of them "
            "will read at its schema default, and every edit the settings UI "
            "accepts will be discarded by the host with ErrNotFound."
            % len(keys)], len(keys)
    try:
        raw = open(cfg_path, "rb").read().decode("utf-8")
        cfg = json.loads(raw)
    except (OSError, ValueError) as e:
        return FAIL, ["config.json does not parse (%s) -- so NO setting this "
                      "mod declares is real, not just one" % e], len(keys)
    if not isinstance(cfg, dict):
        return FAIL, ["config.json is not a JSON object"], len(keys)

    missing = [k for k in keys if not resolves(cfg, k)]
    if missing:
        probs = ["%d of %d declared setting(s) have NO path in config.json -- "
                 "each renders a control that reads a schema default:"
                 % (len(missing), len(keys))]
        for k in missing:
            probs.append("    UNBACKED  %s" % k)
        return FAIL, probs, len(keys)
    return OK, [], len(keys)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mod", help="check only this mod directory name")
    args = ap.parse_args()

    bad = unknown = 0
    for name, path in mod_dirs(args.mod):
        verdict, probs, n = check_mod(name, path)
        if verdict == OK:
            detail = probs[0] if probs else "%d setting(s) all backed" % n
            print("ok   %-12s %s" % (name, detail))
            continue
        if verdict == INCONCLUSIVE:
            unknown += 1
            print("INCONCLUSIVE %-12s" % name)
        else:
            bad += 1
            print("FAIL %-12s" % name)
        for p in probs:
            print("       %s" % p)

    if bad:
        print("\n%d mod(s) FAILED. A declared setting with no config.json key "
              "is a control that renders and resolves to nothing." % bad)
        return 1
    if unknown:
        print("\n%d mod(s) INCONCLUSIVE -- nothing was verified for them. "
              "This is not a pass." % unknown)
        return 2
    print("\nevery declared setting on every mod has a path in its config.json")
    return 0


sys.exit(main())
