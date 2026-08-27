
"""Repoint the SPARE, DISABLED location factory4_night at our authored preset.

factory4_day (the map the user actually plays) is NOT touched.
  python tools/patch_greybox_location.py --apply
"""
import json, sys, shutil, time, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repowrite  # noqa: E402

F = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "mods", "tarkov", "data", "post1", "locations.json")
ID = "59fc81d786f774390775787e"          # Factory / factory4_night, Enabled=false
d = json.load(open(F))
loc = d["locations"][ID]
assert loc["Id"] == "factory4_night", loc["Id"]
print("before:", loc["Enabled"], loc["Scene"])
loc["Enabled"] = True
loc["Scene"] = {"path": "maps/aowl_greybox_preset.bundle",
                "rcid": "aowl_greybox.ScenesPreset.asset"}
print("after :", loc["Enabled"], loc["Scene"])
if "--apply" not in sys.argv:
    print("DRY RUN"); sys.exit(0)
shutil.copy2(F, F + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
# Written through repowrite so text-mode newline translation can never
# rewrite this file's line endings (measured: locations.json has NONE, and a
# text-mode write is how a tree silently flips CRLF -> LF).
repowrite.write_text(F, json.dumps(d, separators=(",", ":")))
chk = json.load(open(F))["locations"][ID]
assert chk["Scene"]["path"] == "maps/aowl_greybox_preset.bundle" and chk["Enabled"] is True
assert json.load(open(F))["locations"]["55f2d3fd4bdc2d5f408b4567"]["Scene"]["path"] == "maps/factory_day_preset.bundle", "factory4_day was disturbed"
print("PASS")
