#!/usr/bin/env python3
"""Generate mods/tarkov/emu/globaltunedata.nim from a live db.json.

Every row this emits is BOTH a declared setting and an override applied to the
`globals` document the client fetches from `/client/globals` -- one list drives
both, so a row cannot exist in the schema without being wired (CLAUDE.md 9b).

The table is emitted as a `const` STRING, one record per line, rather than a
`seq` of object literals: several hundred object constructors in one seq literal
is a nimony compile-time cost for no runtime benefit, and the parse is six
`indexOf` calls per line at load.

Record layout, '|'-separated:
    key | path | kind | default | lo | hi | category | label

  key      the config.json key. Flat -- the backend's config_set refuses a
           dotted key, and it refuses it because a half-created nested path in
           a config file is worse than not writing.
  path     the dotted path INSIDE the served globals document.
  kind     i(nt) f(loat) b(ool)
  default  the value db.json actually holds today, as a JSON literal.
  lo/hi    a suggested range for the control; empty when unbounded.

Usage:  python tools/gen_globaltunes.py D:\\Aowlspt\\aowlspt\\db.json
"""
import json
import re
import sys

# Subtrees worth exposing. Everything else under globals.config is either
# per-item cosmetic data (Customization, 602 leaves), per-trader Fence internals
# (409), or physics collider geometry (BodyPartColliderSettings, 78) -- volume
# without control. Judgement call, stated here so it can be revisited.
SUBTREES = [
    ("Stamina", "Player / Stamina"),
    ("StaminaDrain", "Player / Stamina"),
    ("StaminaRestoration", "Player / Stamina"),
    ("Health.Falling", "Player / Health"),
    ("Health.ProfileHealthSettings", "Player / Health"),
    ("Health.HealPrice", "Player / Health"),
    ("Insurance", "Insurance"),
    ("RagFair", "Flea Market"),
    ("RepairSettings", "Repair"),
    ("Malfunction", "Weapons / Malfunction"),
    ("Overheat", "Weapons / Overheat"),
    ("Aiming", "Weapons / Aiming"),
    ("Inertia", "Player / Inertia"),
    ("Airdrop", "Raid / Airdrop"),
    ("exp", "Experience"),
    ("KarmaCalculationSettings", "Scav"),
    ("ArmorMaterials", "Ballistics / Armour"),
    ("SprintSpeed", "Player / Movement"),
    ("WalkSpeed", "Player / Movement"),
    ("VaultingSettings", "Player / Movement"),
    ("MountingSettings", "Weapons / Mounting"),
    ("WeaponFastDrawSettings", "Weapons / Handling"),
    ("TransitSettings", "Raid / Transit"),
    ("QuestSettings", "Quests"),
    ("ItemsCommonSettings", "Items"),
    ("TradingSettings", "Traders"),
    ("FavoriteItemsSettings", "Items"),
    ("BufferZone", "Raid"),
    ("FractureCausedByBulletHit", "Player / Health"),
    ("FractureCausedByFalling", "Player / Health"),
    ("WallContusionAbsorption", "Player / Health"),
    ("SkillsSettings", "Skills"),
    ("SquadSettings", "Raid"),
    ("rating", "Profile"),
    ("TripwiresSettings", "Raid"),
]

# Depth limit per subtree. SkillsSettings and Health.* fan out hard; one level
# of scalars from them is the useful part.
SHALLOW = {"SkillsSettings", "Health.ProfileHealthSettings", "ArmorMaterials",
           "Health.HealPrice"}

TOPLEVEL_CATEGORY = "Globals"

# Rows nothing should be able to edit from a settings page.
SKIP = {"TODSkyDate", "TestValue", "RagfairTurnOnTimestamp"}


def label_of(name):
    """`MaxBotsAliveOnMap` -> `Max bots alive on map`."""
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", s)
    s = s.replace("_", " ").strip()
    return s[:1].upper() + s[1:]


def range_of(value, is_int):
    """A suggested control range. Wide enough to be useful, bounded enough that
    a slider is not useless -- and EMPTY rather than invented when the default
    is zero, because 0..0 is not a range and 0..100 would be a guess."""
    if isinstance(value, bool):
        return "", ""
    v = abs(float(value))
    if v == 0.0:
        return "", ""
    hi = v * 10.0
    lo = 0.0 if float(value) >= 0 else -hi
    if is_int:
        return str(int(lo)), str(max(1, int(hi)))
    return ("%g" % lo), ("%g" % hi)


def emit(node, prefix, category, depth, maxdepth, out):
    for k, v in node.items():
        pp = prefix + "." + k if prefix else k
        if k in SKIP:
            continue
        # A leaf reached below the subtree root gets its parent in the label.
        # Without it a Vector3's three components all render as "X" / "Y" / "Z"
        # in the same category -- three identical-looking rows that change
        # different things is worse than no label at all.
        parts = pp.split(".")
        if depth > 0 and len(parts) >= 2:
            name = label_of(parts[-2]) + " " + label_of(parts[-1])
        else:
            name = label_of(k)
        if isinstance(v, bool):
            out.append((pp, "b", "true" if v else "false", "", "", category, name))
        elif isinstance(v, int):
            lo, hi = range_of(v, True)
            out.append((pp, "i", str(v), lo, hi, category, name))
        elif isinstance(v, float):
            lo, hi = range_of(v, False)
            out.append((pp, "f", repr(v), lo, hi, category, name))
        elif isinstance(v, dict) and depth < maxdepth:
            emit(v, pp, category, depth + 1, maxdepth, out)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else r"D:\Aowlspt\aowlspt\db.json"
    dst = sys.argv[2] if len(sys.argv) > 2 else (
        "mods/tarkov/emu/globaltunedata.nim")
    cfg = json.load(open(src, encoding="utf-8"))["globals"]["config"]

    rows = []
    for k, v in cfg.items():
        if k in SKIP:
            continue
        if isinstance(v, bool):
            rows.append((k, "b", "true" if v else "false", "", "",
                         TOPLEVEL_CATEGORY, label_of(k)))
        elif isinstance(v, (int, float)):
            lo, hi = range_of(v, isinstance(v, int))
            rows.append((k, "i" if isinstance(v, int) else "f",
                         str(v) if isinstance(v, int) else repr(v),
                         lo, hi, TOPLEVEL_CATEGORY, label_of(k)))
    for sub, cat in SUBTREES:
        node = cfg
        for part in sub.split("."):
            node = node.get(part, {})
        if not isinstance(node, dict):
            continue
        emit(node, sub, cat, 0, 1 if sub in SHALLOW else 2, rows)

    # A duplicate key would make one row shadow another and the second would be
    # dead -- a decorative setting by accident. Fail loudly instead.
    seen = {}
    lines = []
    for path, kind, dflt, lo, hi, cat, label in rows:
        key = "g_" + path.replace(".", "_")
        if key in seen:
            raise SystemExit("duplicate generated key %s (%s and %s)"
                             % (key, seen[key], path))
        seen[key] = path
        for f in (key, path, dflt, lo, hi, cat, label):
            if "|" in f or "\n" in f:
                raise SystemExit("separator in field: %r" % f)
        lines.append("|".join((key, "config." + path, kind, dflt, lo, hi,
                               cat, label)))

    body = "\n".join(lines)
    with open(dst, "w", encoding="utf-8", newline="\n") as fh:
        fh.write('''## GENERATED by tools/gen_globaltunes.py -- do not hand-edit.
##
## Every record is one row of the singleplayer settings page AND one override
## applied to the `globals` document served at `/client/globals`. `emu/tuning`
## reads this table for both, so a row here cannot be decorative: it is either
## in the schema and in the patcher, or in neither.
##
## These reach the CLIENT. `globals.config` is what the client's own
## ballistics, stamina, malfunction, skill and flea-market code reads at
## session start, so a change here takes effect on the next `/client/globals`
## fetch with no host patching at all -- which is exactly how SPT's
## ServerValueModifier worked.
##
## Fields, '|'-separated: key|path|kind|default|lo|hi|category|label

const GlobalTuneTable* = """''')
        fh.write(body)
        fh.write('"""\n')
    print("%d rows -> %s" % (len(lines), dst))


if __name__ == "__main__":
    main()
