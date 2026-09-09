#!/usr/bin/env python3
r"""ailog.py -- raise the EFT client's AI/spawn log verbosity, from the install's
own `Logging.config`.

## Why this exists

Every `AILogger` diagnostic on the offline scav-spawn path -- the ones that say
which rung of the wave -> zone -> spawn-point -> place chain gave up -- is
emitted at level **Information**. The stock install ships `aiData` (AILogger's
category) at **Error**, so all of them are dropped before they ever reach a
file. That is the whole reason `Logs\<ts>\* aiData_000.log` contains one line
and none of the interesting ones.

## The mechanism, as verified against GameAssembly.dll 1.1.0.1.46777

`LogConfiguration::.ctor` (0x27cb0a0) calls `LoadRulesWithCache` (0x27cb6d0),
which does `File.Exists(configPath)` -> `FileInfo.LastWriteTime` compared against
`_lastFileWriteTime` -> `File.ReadAllText` -> JSON -> `ValidateAndFilterRules`
(0x27cc8e0) -> `loggingRules`. `WriteRules` (0x27cbec0) only runs when the file
is missing or unparseable, so an edited file is read, not clobbered -- and the
`LastWriteTime` check means touching the file is what makes it re-read.

Each `AbstractLogger` subclass passes its category name to
`AbstractLogger::.ctor` (0x27c7c30), which stores the matching rule's level in
`_minLogLevel` at **+0x24**. Gating is then just:

    AbstractLogger::IsEnabled(this, lvl)   ; 0x27c8140
        cmp edx, dword ptr [rcx + 0x24]
        setge al

and `AbstractLogger::LogInfo` (0x27c8f60) passes `edx = 2`. So the levels are
Trace=0, Debug=1, Information=2, Warning=3, Error=4, Critical=5 -- exactly the
order the config file's own `info` field lists. `aiData` at Error(4) drops
every Info(2) row. Setting it to Trace(0) lets them all through.

The AI logger classes map 1:1 onto the config's `fileName` keys:
`AILogger`->aiData, `AIDecisionLogger`->ai_decision, `AIVision`->aiVision,
`AILooting`->aiLooting, `AIMoveLogger`->aiMoveData, `AICoversLogger`->
aiCoversData, `AIMapSettingsLogger`->aiMapSettingsData, `BotProfilesLogger`->
botProfiles.

## Usage

    python tools/ailog.py on   [--root D:\\Aowlspt]
    python tools/ailog.py off  [--root D:\\Aowlspt]
    python tools/ailog.py show [--root D:\\Aowlspt]

`on` rewrites only the `minLevel` of the spawn-relevant categories and leaves
every other rule byte-identical, so it stays correct if BSG reshuffles the
defaults. The previous levels are saved to `Logging.config.aowlbak` and `off`
restores them (falling back to the stock defaults if the backup is gone).

Deliberately NOT raised: `aiVision`, `aiMoveData`, `aiCoversData`, `aiLooting`.
Those fire per-bot-per-frame and at Trace they bury the spawn rows in gigabytes.
"""

import argparse
import json
import os
import sys

DEFAULT_ROOT = r"D:\Aowlspt"
CONFIG_NAME = "Logging.config"
BACKUP_NAME = "Logging.config.aowlbak"

# category -> level to use while diagnosing spawns.
VERBOSE = {
    "aiData": "Trace",        # AILogger: the whole wave/zone/spawn-point chain
    "spawns": "Trace",        # "Look to spawn log" points here
    "spawn-system": "Trace",  # SpawnPointParams selection
    "botProfiles": "Information",  # "Can't SpawnBot cause bad profile"
}

# What the stock install ships, used only if the backup file is missing.
STOCK = {
    "aiData": "Error",
    "spawns": "Error",
    "spawn-system": "Error",
    "botProfiles": "Error",
}


def load(path):
    with open(path, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


def save(path, doc):
    # The client parses this with a plain JSON reader; 2-space indent and a
    # trailing newline match what WriteRules itself produces closely enough
    # that a diff against a game-written file stays readable.
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


def rules_of(doc):
    rules = doc.get("rules")
    if not isinstance(rules, list):
        sys.exit("%s has no 'rules' array -- is this really the client's "
                 "Logging.config?" % CONFIG_NAME)
    return rules


def apply(path, wanted, backup_path, write_backup):
    doc = load(path)
    rules = rules_of(doc)
    have = {}
    changed = []
    for rule in rules:
        name = rule.get("fileName")
        if name in wanted:
            have[name] = rule.get("minLevel")
            if rule.get("minLevel") != wanted[name]:
                changed.append((name, rule.get("minLevel"), wanted[name]))
                rule["minLevel"] = wanted[name]

    missing = [n for n in wanted if n not in have]
    if missing:
        # ValidateAndFilterRules drops names the client does not know, so
        # inventing entries is useless -- say so rather than silently adding.
        print("note: no rule for %s in this config; the client only honours "
              "categories it already ships." % ", ".join(sorted(missing)))

    if write_backup and not os.path.exists(backup_path):
        with open(backup_path, "w", encoding="utf-8") as fh:
            json.dump(have, fh, indent=2)
            fh.write("\n")

    save(path, doc)
    return changed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("action", choices=("on", "off", "show"))
    ap.add_argument("--root", default=DEFAULT_ROOT,
                    help="game install directory (default %s)" % DEFAULT_ROOT)
    args = ap.parse_args()

    path = os.path.join(args.root, CONFIG_NAME)
    backup_path = os.path.join(args.root, BACKUP_NAME)
    if not os.path.exists(path):
        sys.exit("no %s -- launch the client once and it will write one, or "
                 "pass --root" % path)

    if args.action == "show":
        rules = rules_of(load(path))
        for rule in rules:
            if rule.get("fileName") in VERBOSE:
                print("%-14s %s" % (rule.get("fileName"), rule.get("minLevel")))
        return

    if args.action == "on":
        changed = apply(path, VERBOSE, backup_path, write_backup=True)
    else:
        restore = STOCK.copy()
        if os.path.exists(backup_path):
            saved = load(backup_path)
            restore.update({k: v for k, v in saved.items() if v})
        changed = apply(path, restore, backup_path, write_backup=False)
        if os.path.exists(backup_path):
            os.remove(backup_path)

    if not changed:
        print("already %s -- nothing to change." % args.action)
    else:
        for name, was, now in changed:
            print("%-14s %s -> %s" % (name, was, now))
    print("\n%s updated. The client reads it in LogConfiguration's ctor, so "
          "this takes effect on the next client start." % path)


if __name__ == "__main__":
    main()
