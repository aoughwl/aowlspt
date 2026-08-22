# Decrypting `global-metadata.dat`

How to produce a decrypted IL2CPP `global-metadata.dat` for the installed
Escape from Tarkov build, for use with `tools/il2cpp_resolve.py`.

## Prerequisites

* **Windows** with `python` on PATH (stdlib only, no packages).
* The real game install (here `D:\Aowlspt`). Never copy
  `EscapeFromTarkov_Data\il2cpp_data\Metadata\global-metadata.dat` before
  running -- copying changes its creation time, which changes the derived
  subKey. (Decryption itself is subKey-independent, but `derive`/`status`
  output is not.)
* An installed layout blob at `mods/tarkov/data/metadata/<version>.json`.
  Check with `status`; if missing, obtain it with
  `python tools/metablob.py extract-capture <gamedir> <capture.txt>`
  (see `tools/METABLOB.md`).

## Commands

From the repo root:

```powershell
python tools/metablob.py status D:\Aowlspt
```

Expected (build 1.1.0.1.46777):

```
install version   1.1.0.1.46777
internalKey       0x876F9333
blob installed    YES  ...\mods\tarkov\data\metadata\1.1.0.1.46777.json
                  valueHex 288 hex chars, internalKey 0x876F9333
```

Then decrypt (`metablob.py` exposes `parse_layout` / `decrypt_with_layout` as
importable functions; there is no decrypt subcommand):

```powershell
python -c @'
import sys, json, pathlib, struct
ROOT = pathlib.Path.cwd()
sys.path.insert(0, str(ROOT / "tools"))
from metablob import find_metadata_file, parse_layout, decrypt_with_layout, verify_decrypt
meta = find_metadata_file(r"D:\Aowlspt")
blob = json.loads((ROOT / "mods/tarkov/data/metadata/1.1.0.1.46777.json").read_text())
props = parse_layout(blob["valueHex"])
data = meta.read_bytes()
out = decrypt_with_layout(data, props)
print("magic:", " ".join(f"{b:02X}" for b in out[:8]))
print("version:", struct.unpack_from("<I", out, 4)[0])
print("verify:", verify_decrypt(data, props))
dst = ROOT / ".cache" / "global-metadata.dec.dat"
dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_bytes(out)
print("wrote", dst, dst.stat().st_size)
'@
```

(If your shell mangles the here-string, put the same body in a `.py` file and
run `python thatfile.py`.)

## Expected verification output

```
magic: AF 1B B1 FA 1F 00 00 00
version: 31
verify: (True, 'magic AF 1B B1 FA, version 31, contains System.Object')
wrote ...\.cache\global-metadata.dec.dat 27776072
```

Magic must be `AF 1B B1 FA` and version `31` (`1F 00 00 00`). Anything else
means the layout blob is wrong for this build.

## Where the cached file lives

    .cache/global-metadata.dec.dat     (27,776,072 bytes for 1.1.0.1.46777)

`.cache/` is a local build artefact directory -- **do not commit** the file
(it is ~26 MiB and rederivable from the game install in seconds).

## Using it

```powershell
python tools/il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll .cache\global-metadata.dec.dat find UnityEngine.Canvas
python tools/il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll .cache\global-metadata.dec.dat type 30443
python tools/il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll .cache\global-metadata.dec.dat fields UnityEngine.UI.Button
```

Note `find` matches **type** names, not method names; use `type <idx>` to list
a type's methods with their RVAs. Generated method bodies live in the PE
section named `il2cpp`, not `.text`.
