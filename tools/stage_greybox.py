r"""Stage the aowl_greybox proof-of-pipeline preset into the LIVE install.

Run with the Store python (UnityPy not needed here, but keep one python).
  python tools/stage_greybox.py --dry     # show what would change
  python tools/stage_greybox.py --apply   # do it (backs up both files)

Touches, under D:\Aowlspt ONLY:
  + StreamingAssets/Windows/maps/aowl_greybox_preset.bundle   (NEW file)
  ~ StreamingAssets/Windows/Windows.json                      (one new key)
  ~ ConsistencyInfo                                           (resync Windows.json Size+Checksum)
Never touches D:\Games\Tarkov.
"""
import json, os, shutil, sys, ctypes, time

LIVE = r"D:\Aowlspt"
SA   = os.path.join(LIVE, "EscapeFromTarkov_Data", "StreamingAssets", "Windows")
MAN  = os.path.join(SA, "Windows.json")
CI   = os.path.join(LIVE, "ConsistencyInfo")
SRC  = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "build", "maps", "aowl_greybox_preset.bundle")
KEY  = "maps/aowl_greybox_preset.bundle"
DST  = os.path.join(SA, "maps", "aowl_greybox_preset.bundle")
CI_MANIFEST_PATH = r"EscapeFromTarkov_Data\StreamingAssets\Windows\Windows.json"

apply = "--apply" in sys.argv

def checksum(b):                      # fact #90: byte-sum mod 2^32, SIGNED int32
    return ctypes.c_int32(sum(b) & 0xFFFFFFFF).value

man = json.load(open(MAN))
if KEY in man:
    print("manifest: key already present ->", man[KEY])
else:
    print("manifest: ADD", KEY)
man[KEY] = {"FileName": "StreamingAssets/maps/aowl_greybox_preset.bundle",
            "Crc": 0,                       # 0 = skip Unity's CRC check
            "Hash": {"isValid": True},
            "Dependencies": []}
# match the file's existing formatting exactly (compact, no spaces)
new_manifest = json.dumps(man, separators=(",", ":")).encode("utf-8")

ci = json.load(open(CI))
ent = [e for e in ci["Entries"] if e["Path"] == CI_MANIFEST_PATH]
assert len(ent) == 1, "ConsistencyInfo: expected exactly one Windows.json entry, got %d" % len(ent)
old = dict(ent[0])
ent[0]["Size"] = len(new_manifest)
ent[0]["Checksum"] = checksum(new_manifest)
print("ConsistencyInfo: %s -> %s" % (old, ent[0]))
print("bundle: %s (%d bytes) -> %s" % (SRC, os.path.getsize(SRC), DST))

if not apply:
    print("\nDRY RUN. re-run with --apply"); sys.exit(0)

ts = time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(MAN, MAN + ".bak-" + ts); shutil.copy2(CI, CI + ".bak-" + ts)
shutil.copy2(SRC, DST)
open(MAN, "wb").write(new_manifest)
open(CI, "w").write(json.dumps(ci))
# read-back: prove the finished state, not our own write
b = open(MAN, "rb").read()
e = [x for x in json.load(open(CI))["Entries"] if x["Path"] == CI_MANIFEST_PATH][0]
assert e["Size"] == len(b) and e["Checksum"] == checksum(b), "FAIL: ConsistencyInfo does not match manifest"
assert KEY in json.load(open(MAN)), "FAIL: manifest key missing after write"
assert os.path.getsize(DST) == os.path.getsize(SRC), "FAIL: bundle copy size mismatch"
print("PASS. rollback: copy %s.bak-%s -> %s ; %s.bak-%s -> %s ; del %s"
      % (MAN, ts, MAN, CI, ts, CI, DST))
