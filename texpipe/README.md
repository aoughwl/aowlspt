# EFT / SPT 4.1.2 texture replacement pipeline

## Why this is a *patch* pipeline, not a Unity re-authoring pipeline

The brief asked for Unity 2022.3.43f1 batch mode to extract a bundle's contents and
repack everything untouched alongside replaced textures. **That approach is unsound
for this game and I did not ship it**, for one concrete reason:

Unity's `BuildPipeline` can only build assets that exist in an *editor project*.
The bundles here do not contain importable source assets — they contain compiled
runtime objects. `wall_loft.bundle` alone holds **341 objects**: `Mesh`,
`MeshCollider`, `Material`, `Shader`, `GameObject`/`Transform` hierarchies,
`MonoBehaviour`s whose scripts live in the game's `Assembly-CSharp`, and the
`AssetBundle` manifest object itself. Round-tripping those through the editor means
*recreating* them, which changes their PathIDs, drops MonoBehaviour data whose script
type the editor does not have, and rewrites materials/shaders. Other bundles reference
these objects across bundle boundaries. A Unity rebuild would therefore silently
mutate or lose exactly the things the brief said must survive.

So the pipeline **patches the original archive in place**: it deserialises only the
`Texture2D` objects it is replacing, writes them back, and re-serialises the bundle.
Every other object is carried across with its original bytes and its original PathID.
That is a strictly stronger guarantee than "repack everything untouched", and it is
mechanically verifiable — see `verify.py`.

Unity batch mode is still used, for what it is actually good at here: an **acceptance
test** that the real 2022.3.43f1 runtime loader accepts the rebuilt bundles
(`../unity/BundleCheck`).

## Layout

| file | what it does |
|---|---|
| `scope.py` | picks the in-scope textures from the verified inventory and resolves each to a real `Windows.json` bundle key + on-disk path |
| `tint.py` | area → hue map, normal-map detection, the tint operation (RGB only; alpha copied through) |
| `build.py` | the builder: patch each bundle, write the pack + `bundles.json` + `build-report.json` |
| `verify.py` | proves nothing was lost: object census + byte-compare of untouched objects + texture identity |
| `negcontrol.py` | negative control proving `verify.py` is not vacuous |
| `probe.py` | scratch inspector for a single bundle |
| `../unity/BundleCheck` | headless Unity acceptance test |
| `../modsrc/TextureDiagnosticPack` | minimal `IModMetadata` mod so the SPT server loads the folder |

## Run it

```bash
cd texpipe
uv venv --python 3.12 .venv
VIRTUAL_ENV=$PWD/.venv uv pip install UnityPy==1.25.3 Pillow etcpak

.venv/Scripts/python.exe build.py  --out ../out/diagnostic-pack     # ~2m20s, 292 keys
.venv/Scripts/python.exe verify.py --out ../out/diagnostic-pack     # ~8s
.venv/Scripts/python.exe negcontrol.py                              # sanity check the verifier
```

Headless Unity acceptance (≈85 s for 278 bundles):

```bash
"C:/Program Files/Unity/Hub/Editor/2022.3.43f1/Editor/Unity.exe" \
  -batchmode -quit -nographics \
  -projectPath  .../aowlspt-textures/unity/BundleCheck \
  -executeMethod BundleCheck.Run \
  -logFile      .../out/unity-check.log \
  -packRoot     .../out/diagnostic-pack/bundles \
  -resultFile   .../out/bundlecheck.json
```

Rebuild the metadata DLL (needs the .NET 10 SDK; references `D:\SPT\SPT_Runtime`
read-only):

```bash
cd modsrc/TextureDiagnosticPack && dotnet build -c Release -o build
```

## Generalising beyond the diagnostic pass

`build.py` is one function away from a general (bundle key, texture name, image)
pipeline: replace the `T.tint(img, rgb)` call in `patch_bundle` with a lookup of the
replacement image for `(key, lname)`. Everything else — format/mip/dimension
preservation, mip-chain encoding, archive re-serialisation, verification — is
already generic. Note the encoder constraints:

* DXT1/DXT5/BC4/BC5/BC7 are encoded via `etcpak`. BC6H (HDR) has **no** encoder;
  a BC6H target would have to be re-authored in a different format.
* Source bundles use LZ4HC; UnityPy cannot emit LZ4HC, so the pack is written with
  plain LZ4 (identical wire format, ~30% larger). `--packer original` is available
  but falls back to *uncompressed* data blocks on these files.
* Textures that were streamed from the bundle's `.resS` are inlined into the object.
  Individual bundles therefore grow (e.g. `wall_loft` 45 MB → 58 MB); the pack as a
  whole is 792 MB for 278 bundles against 806 MB of in-scope sources.

## Bundle file naming (easy to get wrong)

`bundles.json` carries only `key` + `dependencyKeys`; the file on disk is located at
`<mod>/bundles/<key>` **verbatim**. 214 of the 292 in-scope keys in the game's
`Windows.json` have **no `.bundle` extension** (e.g.
`assets/content/location_objects/02_custom/fbx/_outdoor/_nature/grass/field_grass_d`).
The output file must be named exactly like the key — do not normalise an extension
onto it, or the server will not find it.
