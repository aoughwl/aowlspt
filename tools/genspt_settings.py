#!/usr/bin/env python3
"""Generate the SPT server config surface as declared settings.

Reads reference/spt-4.1-surface.json (a full type dump of the SPT 4.1 server)
and emits reference/spt-config-settings.json: one page per top-level config
file (the classes deriving from BaseConfig, i.e. the configs/*.json SPT loads),
with each scalar property turned into a declared Setting.

Every value is marked implemented=false: aowlspt is a from-scratch emulator
with no SPT ConfigServer, so it does not consume any configs/*.json. The F12
settings UI still shows them all, greyed, with the reason — which is exactly
what the feature asks for ("still show them but mark them clearly not
implemented yet"). Flip entries in IMPLEMENTED below as aowlspt grows a backing
feature for one.
"""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repowrite  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SURFACE = os.path.join(HERE, "..", "reference", "spt-4.1-surface.json")
OUT = os.path.join(HERE, "..", "reference", "spt-config-settings.json")

# config-file class -> the configs/<file>.json it maps to, plus a friendly page.
FILE_OF = {
    "AirdropConfig": "airdrop", "BackupConfig": "backup", "BotConfig": "bot",
    "BtrDeliveryConfig": "btr", "CoreConfig": "core", "GiftsConfig": "gifts",
    "HealthConfig": "health", "HideoutConfig": "hideout", "HttpConfig": "http",
    "InRaidConfig": "inraid", "InsuranceConfig": "insurance",
    "InventoryConfig": "inventory", "ItemConfig": "item",
    "LocaleConfig": "locale", "LocationConfig": "location", "LootConfig": "loot",
    "LostOnDeathConfig": "lostondeath", "MatchConfig": "match",
    "PlayerScavConfig": "playerscav", "PmcChatResponseConfig": "pmcchatresponse",
    "PmcConfig": "pmc", "QuestConfig": "quest", "RagfairConfig": "ragfair",
    "RepairConfig": "repair", "ScavCaseConfig": "scavcase",
    "SeasonalEventConfig": "seasonalevents", "TraderConfig": "trader",
    "WeatherConfig": "weather",
}

# Allowlist of SPT keys aowlspt actually honours today (namespaced key -> True).
# Empty for now: aowlspt has its own emulator config, not SPT's ConfigServer.
IMPLEMENTED = set()

SCALAR = {
    "Boolean": "bool",
    "Int32": "int", "Int64": "int", "UInt32": "int", "Int16": "int",
    "Double": "float", "Single": "float", "Decimal": "float",
    "String": "string",
}

def load():
    with open(SURFACE, encoding="utf-8") as f:
        return json.load(f)

def short(name):
    return name.split(".")[-1]

def unwrap_nullable(t):
    m = re.match(r"^Nullable<(.+)>$", t)
    return m.group(1) if m else t

def main():
    types = load()
    byshort = {short(t["Name"]): t for t in types}
    enums = {short(t["Name"]) for t in types if "enum" in t.get("Kind", "")}

    top = sorted([t for t in types if "BaseConfig" in t.get("Bases", [])],
                 key=lambda x: short(x["Name"]))

    pages = []
    n_settings = 0
    n_nested = 0
    for t in top:
        cn = short(t["Name"])
        cfile = FILE_OF.get(cn, cn.lower())
        page = {"id": "spt." + cfile,
                "label": "SPT / " + cfile,
                "configFile": "configs/" + cfile + ".json",
                "className": cn,
                "settings": [],
                "nested": []}
        def enum_opts(base):
            opts, et = [], byshort.get(base)
            if et:
                for em in et["Members"]:
                    # enum members look like "field <EnumType> <Name>"; take the name
                    nm = em.split("=")[0].strip().rsplit(" ", 1)[-1].strip()
                    if nm and nm[0].isalpha() and nm not in (
                            "value__", "Equals", "GetHashCode", "ToString",
                            "CompareTo", "HasFlag", "GetTypeCode"):
                        opts.append(nm)
            return opts

        def walk(cls, keyprefix, catpath, depth, seen):
            """Flatten cls's scalar props into page['settings'], recursing one
            level into nested config classes. Collections/unknowns become
            `nested` json-edit leaves so the page stays complete."""
            nonlocal n_settings, n_nested
            node = byshort.get(cls)
            if not node:
                return
            for m in node["Members"]:
                if not m.startswith("prop "):
                    continue
                body = m[len("prop "):]
                parts = body.rsplit(" ", 1)
                if len(parts) != 2:
                    continue
                ptype, pname = parts[0].strip(), parts[1].strip()
                if pname in ("ExtensionData", "Kind"):
                    continue
                base = unwrap_nullable(ptype)
                key = keyprefix + "." + pname
                cat = catpath
                impl = key in IMPLEMENTED
                note = ("Honoured by aowlspt." if impl
                        else "SPT " + cfile + ".json value — not implemented in aowlspt yet.")
                if base in SCALAR:
                    page["settings"].append({
                        "key": key, "label": pname, "type": SCALAR[base],
                        "implemented": impl, "category": cat, "description": note})
                    n_settings += 1
                elif base in enums:
                    page["settings"].append({
                        "key": key, "label": pname, "type": "enum",
                        "options": enum_opts(base), "implemented": impl,
                        "category": cat, "description": note})
                    n_settings += 1
                elif base in byshort and not base.startswith(("List<", "Dictionary<",
                        "HashSet<", "Nullable<")) and "<" not in base \
                        and depth < 3 and base not in seen:
                    # A nested config object: recurse, grouping under Parent/Child.
                    walk(base, key, cat + " / " + pname, depth + 1, seen | {base})
                else:
                    page["nested"].append({"key": key, "label": pname,
                                           "type": base, "implemented": impl})
                    n_nested += 1

        walk(cn, "spt." + cfile, cn, 0, {cn})
        pages.append(page)

    doc = {
        "source": "reference/spt-4.1-surface.json (SPT 4.1 server)",
        "note": ("The full SPT server config surface. Every scalar is a declared "
                 "setting; nested objects/lists are listed under `nested` for "
                 "completeness. All implemented=false until aowlspt grows a "
                 "backing feature (see tools/genspt_settings.py IMPLEMENTED)."),
        "configFiles": len(pages),
        "settingCount": n_settings,
        "nestedCount": n_nested,
        "pages": pages,
    }
    # Text-mode "w" translates every newline to os.linesep, so this file's
    # endings depended on which OS ran the tool -- and a run that flipped a
    # CRLF tree to LF once turned a 100-line patch into a 21,000-line diff.
    # repowrite preserves what the file already has. (.gitattributes says
    # `* -text` deliberately; do not "fix" this there.)
    # No trailing newline: the tracked file does not have one, and adding it
    # would put a spurious hunk in every regenerate.
    nl = repowrite.write_text(OUT, json.dumps(doc, indent=2))
    print("line endings preserved: %s"
          % ("CRLF" if nl == "\r\n" else "LF"))
    print("wrote", OUT)
    print("config files (pages):", len(pages))
    print("scalar settings:", n_settings)
    print("nested (json-edit) fields:", n_nested)

if __name__ == "__main__":
    main()
