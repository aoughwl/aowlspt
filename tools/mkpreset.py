"""Author a ScenesPreset bundle by cloning an existing one and renaming it.

Proof-of-pipeline step 1: no Unity editor. Clone factory_day_preset.bundle,
rename the bundle, its container key and the root ScenesPreset asset, leaving
the scene keys pointing at scenes the client ALREADY has. If the client renders
Factory when the player picks the repointed location, the manifest + preset +
locations.json half of the custom-map pipeline is proven.
"""
import UnityPy, sys, os

SRC = r"D:\Aowlspt\EscapeFromTarkov_Data\StreamingAssets\Windows\maps\factory_day_preset.bundle"
NAME = "aowl_greybox"
OUT  = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\savant\Projects\aowlspt\build\maps\aowl_greybox_preset.bundle"
BUNDLE = "maps/%s_preset.bundle" % NAME
CONTAINER = "Assets/Content/Locations/_Presets/%s.ScenesPreset.asset" % NAME

env = UnityPy.load(SRC)
root_pid = None
for o in env.objects:
    if o.type.name == "AssetBundle":
        d = o.read_typetree()
        d["m_Name"] = BUNDLE
        d["m_AssetBundleName"] = BUNDLE
        assert len(d["m_Container"]) == 1, d["m_Container"]
        ent = list(d["m_Container"][0])
        root_pid = ent[1]["asset"]["m_PathID"]
        ent[0] = CONTAINER
        d["m_Container"] = [tuple(ent)]
        o.save_typetree(d)
for o in env.objects:
    if o.type.name == "MonoBehaviour":
        d = o.read_typetree()
        if o.path_id == root_pid:
            d["m_Name"] = "%s.ScenesPreset" % NAME
            o.save_typetree(d)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "wb").write(env.file.save())
print("wrote", OUT, os.path.getsize(OUT))
