import UnityPy, os, collections
from scope import load
GAME = 'D:/SPT/EscapeFromTarkov_Data/StreamingAssets/Windows'
ts = load()
by = collections.defaultdict(list)
for t in ts:
    by[t['key']].append(t)
k = [x for x in by if len(by[x]) > 1][0]
print(k, len(by[k]))
src = os.path.join(GAME, by[k][0]['file'].split('StreamingAssets/',1)[1].replace('/', os.sep))
print(src, os.path.exists(src), os.path.getsize(src))
env = UnityPy.load(src)
print('files', list(env.files.keys())[:5])
c = collections.Counter()
for o in env.objects:
    c[o.type.name] += 1
print(c)
for o in env.objects:
    if o.type.name == 'Texture2D':
        d = o.read()
        sd = getattr(d, 'm_StreamData', None)
        print(repr(d.m_Name), d.m_Width, d.m_Height, int(d.m_TextureFormat), d.m_MipCount,
              len(d.image_data) if d.image_data else 0, getattr(sd, 'path', None), getattr(sd, 'size', None))
