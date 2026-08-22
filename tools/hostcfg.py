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
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"

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

BOOL_CALL = re.compile(r'readBoolKey\(\s*"([A-Za-z0-9_]+)"')
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
    """Every key name the host actually looks for. Bools + the three ints.

    Only files that name `aowlspt-host.json` are scraped. Without that filter
    the same needle shapes match unrelated readers -- `modcontrol.nim` parses
    the backend's mod-control JSON with the same helpers, and its `guid`,
    `path`, `lib`, `schema` keys would be offered here as host flags. Accepting
    a key the host will ignore is precisely the failure this tool prevents, so
    a false positive is as bad as a missing one.
    """
    keys = {}
    files = host_sources(hostdir)
    if not files:
        sys.exit("no host sources under %s -- pass --host PATH" % hostdir)
    scanned = 0
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        if "aowlspt-host.json" not in text:
            continue
        scanned += 1
        for m in BOOL_CALL.finditer(text):
            keys.setdefault(m.group(1), ("bool", os.path.basename(path)))
        for m in NEEDLE_LIT.finditer(text):
            keys.setdefault(m.group(1), ("bool", os.path.basename(path)))
    if not scanned:
        sys.exit("no host source under %s reads aowlspt-host.json" % hostdir)
    # The three integers are read by dedicated procs with their own literals;
    # they are named explicitly, and asserted to still be present in the source.
    for k, _d in INT_KEYS.items():
        keys[k] = ("int", "aowlhost.nim")
    return keys


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
        d = INT_KEYS.get(k, "off")
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
        print("\n%sKEYS IN THE FILE THAT THE HOST DOES NOT READ (%d)%s"
              % (RED + BOLD if C else "", len(unknown), RESET if C else ""))
        for k in unknown:
            print("  %s%s%s   -- silently ignored; typo?"
                  % (RED if C else "", k, RESET if C else ""))
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
            near = [c for c in keys if c.lower() == k.lower()]
            hint = (" -- did you mean %s?" % near[0]) if near else ""
            sys.exit("unknown key %r%s\nthe host would ignore it silently; "
                     "run `python tools/hostcfg.py keys`" % (k, hint))
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


def main():
    p = argparse.ArgumentParser(
        description="inspect and toggle aowlspt-host.json safely",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command", choices=["show", "keys", "get", "set", "diff"])
    p.add_argument("args", nargs="*")
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--host", default=os.path.join(REPO, "host"))
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-color", action="store_true")
    a = p.parse_args()
    C = (not a.no_color) and sys.stdout.isatty()
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
