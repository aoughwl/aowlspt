"""Area -> diagnostic hue mapping, and the tint operation itself."""
import re
from PIL import Image

# top-level area -> (name, rgb)
AREA_HUES = {
    '00_hideout':        ('Hideout',            (255, 0, 170)),   # magenta
    '02_custom':         ('Customs',            (255, 40, 40)),   # red
    'city_old':          ('City / Streets',     (40, 220, 60)),   # green
    'lootable':          ('Lootable props',     (60, 110, 255)),  # blue
    'rock and boulders3': ('Rocks / boulders',  (255, 150, 0)),   # orange
    '01_factory_rework': ('Factory',            (0, 225, 225)),   # cyan
    'standard assets':   ('Standard assets',    (245, 230, 0)),   # yellow
    'assetsandplugins':  ('Standard assets',    (245, 230, 0)),   # yellow
    'systems':           ('Standard assets',    (245, 230, 0)),   # yellow
}
FALLBACK = ('Other', (150, 60, 255))  # purple

BLEND = 0.5  # 50% toward the hue

NORMAL_RE = re.compile(r'(^|[_\-])(n|nrm|nm|norm|normal|normals|bump)([_\-0-9]*)$')


def area_of(key: str) -> str:
    p = key.split('/')
    if 'location_objects' in p:
        i = p.index('location_objects')
        if i + 1 < len(p):
            return p[i + 1]
    if p[:2] == ['assets', 'content'] and len(p) > 2:
        return p[2]
    return p[1] if len(p) > 1 else key


def hue_for(key: str):
    return AREA_HUES.get(area_of(key), FALLBACK)


def is_normal_map(lname: str) -> bool:
    return bool(NORMAL_RE.search(lname))


def tint(img: Image.Image, rgb) -> Image.Image:
    """50% blend of RGB toward `rgb`. Alpha is copied through EXACTLY."""
    src = img.convert('RGBA')
    r, g, b, a = src.split()
    solid = Image.new('RGB', src.size, tuple(rgb))
    blended = Image.blend(Image.merge('RGB', (r, g, b)), solid, BLEND)
    br, bg, bb = blended.split()
    return Image.merge('RGBA', (br, bg, bb, a))
