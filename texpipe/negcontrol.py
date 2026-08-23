"""Negative control for verify.py: prove the byte-comparison is not vacuous.

Builds a one-bundle pack, then deliberately mutates a NON-Texture2D object in the
built bundle and re-runs the verifier's comparison. It must report the change.
"""
import json, os, shutil, subprocess, sys, collections
import UnityPy
from scope import load as load_scope
from build import game_path, patch_bundle
from verify import census

OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'out', '_negcontrol'))
KEY = 'assets/content/location_objects/00_hideout/prefabs/customization/floors/floor_concrete.bundle'

shutil.rmtree(OUT, ignore_errors=True)
texs = [t for t in load_scope() if t['key'] == KEY]
targets = {t['lname']: t for t in texs}
src = game_path(texs[0]['file'])
dst = os.path.join(OUT, 'bundles', KEY.replace('/', os.sep))
report = []
patch_bundle(KEY, src, targets, dst, report)
json.dump({'manifest': [{'key': KEY, 'dependencyKeys': []}]}, open(os.path.join(OUT, 'bundles.json'), 'w'))

r = subprocess.run([sys.executable, 'verify.py', '--out', OUT], capture_output=True, text=True)
print('clean run ->', r.returncode, r.stdout.strip().splitlines()[-1])
assert r.returncode == 0, r.stdout + r.stderr

# now corrupt one non-Texture2D object's raw data
env = UnityPy.load(dst)
victim = None
for o in env.objects:
    if o.type.name not in ('Texture2D', 'AssetBundle'):
        victim = o
        break
raw = bytearray(victim.get_raw_data())
raw[0] ^= 0xFF
victim.set_raw_data(bytes(raw))
open(dst, 'wb').write(env.file.save(packer='lz4'))
print('corrupted a', victim.type.name)

r = subprocess.run([sys.executable, 'verify.py', '--out', OUT], capture_output=True, text=True)
print('dirty run ->', r.returncode)
print(r.stdout.strip())
sys.exit(0 if r.returncode == 1 else 1)
