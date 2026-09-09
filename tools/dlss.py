r"""dlss.py -- DLSS Super Resolution DLL management for the live aowlspt install.

    python tools/dlss.py status                    what is installed, GPU, driver, manifest
    python tools/dlss.py fetch [--version V]       download + verify into .cache/dlss/ (never the repo tree)
    python tools/dlss.py install [--version V] [--preset K] [--dry-run]
    python tools/dlss.py rollback [--backup TS]
    python tools/dlss.py preset get|set LETTER|clear      driver-side (NVAPI DRS) override
    python tools/dlss.py game-set --mode Quality --preset K
                                                   game-side Graphics.ini, only while stopped
    python tools/dlss.py selftest                  fake install dir + falsifiers, exit 0/1

Everything this tool asserts is a property of the FINISHED STATE, read back
from disk or from the driver, never an echo of its own write:

  * after `install`, the live DLL's SHA256 is recomputed from disk and compared
    with the pinned hash, its PE version resource is read, and the
    ConsistencyInfo entry is compared with a checksum recomputed from the file
    that is now on disk -- and every OTHER manifest entry is proven unchanged.
  * `selftest` runs the same code against a synthetic install and then breaks
    the checksum formula and tampers the installed file, to prove the verifier
    can say FAIL. A verification that cannot fail is the bug (CLAUDE.md 9b).

The client refuses to boot when a file listed in `ConsistencyInfo` changes
size (CLAUDE.md 7); `nvngx_dlss.dll` IS listed there, flagged IsCritical, so
the manifest entry is re-synced (Size + Checksum = signed int32 byte-sum,
fact #90, validated here against the shipped DLL: computed -785527982 ==
manifest -785527982).

Never run `install` while the client runs: the DLL is locked and a human may be
playing. The coordinator runs it between deploys. `--root` and `--dll` exist so
the selftest can point everything at a scratch directory.
"""
import argparse
import ctypes
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(REPO, ".cache", "dlss")           # .cache/ is gitignored
STATE = os.path.join(CACHE, "state.json")
LIVE_DEFAULT = r"D:\Aowlspt"
DLL_REL = r"EscapeFromTarkov_Data\Plugins\x86_64\nvngx_dlss.dll"
CI_NAME = "ConsistencyInfo"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) aowlspt-dlss/1.0"

# ---------------------------------------------------------------------------
# Catalog. Every entry names WHERE the bytes come from and WHAT they must hash
# to. A hash that is `None` is recorded on first fetch and printed, so a later
# run can be pinned; `fetch` says which of the two happened.
# ---------------------------------------------------------------------------
CATALOG = {
    "310.7.0": {
        "kind": "sr",
        "channel": "nvidia-github",
        "note": "NVIDIA DLSS SDK 310.7.0 (2026-06-23), lib/Windows_x86_64/rel at tag v310.7.0. "
                "Official NVIDIA repository; the same tree ships the 310.5.3 DLL the game "
                "installs today (byte-for-byte the same size, 54,779,504).",
        "url": "https://raw.githubusercontent.com/NVIDIA/DLSS/v310.7.0/lib/Windows_x86_64/rel/nvngx_dlss.dll",
        "size": 58977904,
        "sha256": "be6e434a94ca32499515eb62ca0e6c274526055d568d0426e4c652dcdfb6ee6e",
        # GitHub's contents API reports the git blob id; fetch recomputes it
        # (sha1("blob <len>\0" + bytes)) -- an independent second check.
        "git_blob_sha1": "dc5f2058fe755d10765514b7a4a33b45e0702992",
        "min_driver": "572.16",   # NVIDIA App DLSS-override minimum; the DLL itself loads on older 5xx
    },
    "310.7.129": {
        "kind": "sr",
        "channel": "techpowerup",
        "note": "TechPowerUp 'NVIDIA DLSS DLL 310.7.129' (2026-08-26, 43.0 MB zip). Newest SR "
                "DLL in TPU's archive. Not on NVIDIA's GitHub; what changed vs 310.7.0 is not "
                "published by NVIDIA. Zip hash is TPU's published SHA256.",
        "tpu_page": "https://www.techpowerup.com/download/nvidia-dlss-dll/",
        "tpu_id": "3229",
        "zip_name": "nvngx_dlss_310.7.129.zip",
        "zip_sha256": "0de171b0f522f87bee3dccb98b26976723eb16758366cf04402a83eebaca2ce8",
        "size": 74208880,
        # inner DLL, MEASURED 2026-09-02 from the zip above (PE FileVersion 310.7.129.0)
        "sha256": "d202b024cf5a809d4f6cb57b698ca61cdf7e7f664915a3794942042066d7cf72",
        "min_driver": "572.16",
    },
    "310.5.3": {
        "kind": "sr",
        "channel": "nvidia-github",
        "note": "The version the game ships (measured on D:\\Aowlspt 2026-09-02). Kept so a "
                "rollback can be re-fetched from NVIDIA if the local backup is lost.",
        "url": "https://raw.githubusercontent.com/NVIDIA/DLSS/v310.5.3/lib/Windows_x86_64/rel/nvngx_dlss.dll",
        "size": 54779504,
        "sha256": "8707e53b26c68c606b98bf31c223485ff30d310a261b1a36d48b2eaabc1507ec",
        "git_blob_sha1": "6004172e07e13663e8be56b44ec51a47ee77450c",
        "min_driver": "572.16",
    },
    "npi": {
        "kind": "tool",
        "channel": "github-release",
        "note": "nvidiaProfileInspector v3.0.2.1 (2026-07-05). GUI to inspect/verify the DRS "
                "override this tool writes. NOT used to write: its non-merge import path "
                "calls ResetProfile on the target profile first (DrsImportService.cs:213).",
        "url": "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip",
        "size": 433354,
        "sha256": "88dcf3514111e8de630688467c03c36d8c2a8ad9ebc8073f27c069f82b75bb40",
    },
}
DEFAULT_VERSION = "310.7.0"

# NGX render-preset enum. The game's own EDLSSPreset (Unity.Postprocessing.Runtime)
# uses the same numbers: Default=0 F=6 J=10 K=11 L=12 M=13 (measured offline).
PRESETS = {"DEFAULT": 0, "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7,
           "J": 10, "K": 11, "L": 12, "M": 13}
DRS_PRESET_ID = 0x10E41DF3       # NGX_DLSS_OVERRIDE_RENDER_PRESET_SELECTION (DLSS >= 3.1.11)


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def say(*a):
    print(*a, flush=True)


def die(msg, code=1):
    say("FAIL:", msg)
    sys.exit(code)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(p):
    n = os.path.getsize(p)
    h = hashlib.sha1(b"blob %d\0" % n)
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ci_checksum(data):
    """ConsistencyInfo checksum: byte-sum mod 2^32, stored as SIGNED int32 (fact #90)."""
    return ctypes.c_int32(sum(data) & 0xFFFFFFFF).value


def ci_checksum_file(p):
    s = 0
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            s += sum(chunk)
    return ctypes.c_int32(s & 0xFFFFFFFF).value


def pe_file_version(p):
    """FileVersion from the PE version resource, via version.dll on Windows;
    falls back to scanning for VS_FIXEDFILEINFO. Returns 'a.b.c.d' or None."""
    try:
        ver = ctypes.WinDLL("version.dll")
        n = ver.GetFileVersionInfoSizeW(ctypes.c_wchar_p(p), None)
        if n:
            buf = ctypes.create_string_buffer(n)
            if ver.GetFileVersionInfoW(ctypes.c_wchar_p(p), 0, n, buf):
                ptr = ctypes.c_void_p()
                ln = ctypes.c_uint()
                if ver.VerQueryValueW(buf, ctypes.c_wchar_p("\\"), ctypes.byref(ptr), ctypes.byref(ln)) and ln.value >= 20:
                    raw = ctypes.string_at(ptr.value, ln.value)
                    sig, _, ms, ls = struct.unpack_from("<IIII", raw, 0)
                    if sig == 0xFEEF04BD:
                        return "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)
    except Exception:
        pass
    try:
        b = open(p, "rb").read()
        key = "VS_VERSION_INFO".encode("utf-16-le")
        i = b.find(key)
        if i >= 0:
            j = b.find(b"\xbd\x04\xef\xfe", i)
            if j >= 0:
                ms, ls = struct.unpack_from("<II", b, j + 8)
                return "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)
    except Exception:
        pass
    return None


def ver_tuple(s):
    return tuple(int(x) for x in re.findall(r"\d+", s or "")[:4])


def gpu_info():
    """(name, driver) from nvidia-smi; falls back to WMI. Never raises."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=20).stdout.strip()
        if out:
            name, drv = [x.strip() for x in out.splitlines()[0].split(",")[:2]]
            return name, drv, "nvidia-smi"
    except Exception:
        pass
    try:
        ps = ("Get-CimInstance Win32_VideoController | Where-Object {$_.Name -like '*NVIDIA*'} | "
              "Select-Object -First 1 | ForEach-Object { $_.Name + '|' + $_.DriverVersion }")
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, timeout=30).stdout.strip()
        if "|" in out:
            name, drv = out.split("|", 1)
            # 32.0.15.8142 -> 581.42
            parts = drv.split(".")
            if len(parts) == 4:
                drv = "%s.%s" % (parts[2][-1] + parts[3][:2], parts[3][2:])
            return name.strip(), drv.strip(), "WMI (driver reformatted from %s)" % drv
    except Exception:
        pass
    return None, None, "unavailable"


def gpu_generation(name):
    m = re.search(r"RTX\s*(\d)0\d0", name or "")
    if not m:
        return None
    return {"2": "Turing (RTX 20)", "3": "Ampere (RTX 30)", "4": "Ada (RTX 40)", "5": "Blackwell (RTX 50)"}.get(m.group(1))


def game_pids():
    """[pid, ...] for EscapeFromTarkov.exe, or None if tasklist could not answer.
    An empty list means MEASURED not running; None means UNKNOWN -- the two are
    never collapsed, because 'I could not look' is not 'it is not running'."""
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq EscapeFromTarkov.exe", "/NH", "/FO", "CSV"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return None
    pids = []
    for line in out.splitlines():
        m = re.match(r'"EscapeFromTarkov\.exe","(\d+)"', line.strip())
        if m:
            pids.append(int(m.group(1)))
    return pids


def game_running():
    p = game_pids()
    return None if p is None else bool(p)


def load_state():
    try:
        return json.load(open(STATE, encoding="utf-8"))
    except Exception:
        return {"installs": []}


def save_state(st):
    os.makedirs(CACHE, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, STATE)


# ---------------------------------------------------------------------------
# ConsistencyInfo
# ---------------------------------------------------------------------------
def ci_load(ci_path):
    raw = open(ci_path, "rb").read()
    return raw, json.loads(raw.decode("utf-8"))


def ci_find(doc, rel):
    return [e for e in doc["Entries"] if e.get("Path") == rel]


def ci_dump(doc):
    # The shipped file is compact JSON (no spaces after ':' or ','), no trailing
    # newline. Match it exactly so a diff of the file shows only the entry.
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def ci_resync_doc(doc, rel, size, checksum):
    ents = ci_find(doc, rel)
    if len(ents) != 1:
        raise RuntimeError("ConsistencyInfo: expected exactly one entry for %s, found %d" % (rel, len(ents)))
    old = dict(ents[0])
    ents[0]["Size"] = size
    ents[0]["Checksum"] = checksum
    return old, dict(ents[0])


def ci_verify(ci_path, rel, file_path, before_doc=None, checksum_fn=ci_checksum_file):
    """PASS iff the manifest entry for `rel` equals the file NOW ON DISK, and
    (when `before_doc` is given) every other entry is byte-identical to before.
    Returns (ok, reasons)."""
    reasons = []
    try:
        _, doc = ci_load(ci_path)
    except Exception as e:
        return False, ["ConsistencyInfo unreadable: %s" % e]
    ents = ci_find(doc, rel)
    if len(ents) != 1:
        return False, ["expected exactly one entry for %s, found %d" % (rel, len(ents))]
    e = ents[0]
    size = os.path.getsize(file_path)
    cks = checksum_fn(file_path)
    if e.get("Size") != size:
        reasons.append("Size %r != on-disk %d" % (e.get("Size"), size))
    if e.get("Checksum") != cks:
        reasons.append("Checksum %r != recomputed %d" % (e.get("Checksum"), cks))
    if before_doc is not None:
        a = [x for x in before_doc["Entries"] if x.get("Path") != rel]
        b = [x for x in doc["Entries"] if x.get("Path") != rel]
        if a != b:
            reasons.append("an entry OTHER than %s changed (%d vs %d entries)" % (rel, len(a), len(b)))
        if before_doc.get("Version") != doc.get("Version"):
            reasons.append("manifest Version changed")
        # everything the entry carried besides Size/Checksum must survive (IsCritical!)
        oe = ci_find(before_doc, rel)[0]
        for k in oe:
            if k not in ("Size", "Checksum") and oe[k] != e.get(k):
                reasons.append("entry key %s changed %r -> %r" % (k, oe[k], e.get(k)))
    return not reasons, reasons


# ---------------------------------------------------------------------------
# NVAPI DRS: the machine-wide preset override, read back from the driver
# ---------------------------------------------------------------------------
class _NVDRS_BIN(ctypes.Structure):
    _fields_ = [("valueLength", ctypes.c_uint32), ("valueData", ctypes.c_uint8 * 4096)]


class _NVDRS_VAL(ctypes.Union):
    # NVDRS_SETTING_V1: u32 | NVDRS_BINARY_SETTING | NvAPI_UnicodeString. There is NO
    # 64-bit member in V1; adding one pads the struct to 12,328 bytes and the driver
    # answers -9 INCOMPATIBLE_STRUCT_VERSION (measured 2026-09-02). 12,320 is right.
    _fields_ = [("u32", ctypes.c_uint32), ("binary", _NVDRS_BIN), ("wsz", ctypes.c_wchar * 2048)]


class NVDRS_SETTING(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("settingName", ctypes.c_wchar * 2048),
                ("settingId", ctypes.c_uint32), ("settingType", ctypes.c_uint32),
                ("settingLocation", ctypes.c_uint32), ("isCurrentPredefined", ctypes.c_uint32),
                ("isPredefinedValid", ctypes.c_uint32), ("predefinedValue", _NVDRS_VAL),
                ("currentValue", _NVDRS_VAL)]


NVDRS_SETTING_VER1 = ctypes.sizeof(NVDRS_SETTING) | (1 << 16)
NVAPI_STATUS_NAMES = {0: "OK", -1: "ERROR", -2: "LIBRARY_NOT_FOUND", -3: "NO_IMPLEMENTATION",
                      -4: "API_NOT_INITIALIZED", -5: "INVALID_ARGUMENT", -9: "INCOMPATIBLE_STRUCT_VERSION",
                      -166: "SETTING_NOT_FOUND", -167: "INVALID_PROFILE", -168: "PROFILE_NAME_IN_USE",
                      -169: "PROFILE_NOT_FOUND", -170: "SETTING_NOT_FOUND", -173: "EXECUTABLE_ALREADY_IN_USE"}
_IFACE = {"Initialize": 0x0150E828, "GetErrorMessage": 0x6C2D048C, "DRS_CreateSession": 0x0694D52E,
          "DRS_DestroySession": 0xDAD9CFF8, "DRS_LoadSettings": 0x375DBD6B, "DRS_SaveSettings": 0xFCBC7E14,
          "DRS_GetBaseProfile": 0xDA8466A0, "DRS_GetSetting": 0x73BF8338, "DRS_SetSetting": 0x577DD202,
          "DRS_DeleteProfileSetting": 0xE4A26362, "DRS_EnumSettings": 0xAE3039DA}


class Drs:
    """Minimal NVAPI DRS session. Every call returns a status the caller must
    check; an unknown interface id resolves to NULL and is refused up front."""

    def __init__(self):
        self.lib = ctypes.WinDLL("nvapi64.dll")
        qi = self.lib.nvapi_QueryInterface
        qi.restype = ctypes.c_void_p
        qi.argtypes = [ctypes.c_uint32]
        self.fn = {}
        vp = ctypes.c_void_p
        sigs = {"Initialize": (), "GetErrorMessage": (ctypes.c_int, ctypes.c_char_p),
                "DRS_CreateSession": (ctypes.POINTER(vp),), "DRS_DestroySession": (vp,),
                "DRS_EnumSettings": (vp, vp, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(NVDRS_SETTING)),
                "DRS_LoadSettings": (vp,), "DRS_SaveSettings": (vp,), "DRS_GetBaseProfile": (vp, ctypes.POINTER(vp)),
                "DRS_GetSetting": (vp, vp, ctypes.c_uint32, ctypes.POINTER(NVDRS_SETTING)),
                "DRS_SetSetting": (vp, vp, ctypes.POINTER(NVDRS_SETTING)),
                "DRS_DeleteProfileSetting": (vp, vp, ctypes.c_uint32)}
        for name, iid in _IFACE.items():
            p = qi(iid)
            if not p:
                raise RuntimeError("nvapi_QueryInterface(%s=0x%08X) returned NULL" % (name, iid))
            self.fn[name] = ctypes.CFUNCTYPE(ctypes.c_int, *sigs[name])(p)
        self.check("Initialize", self.fn["Initialize"]())
        self.h = vp()
        self.check("DRS_CreateSession", self.fn["DRS_CreateSession"](ctypes.byref(self.h)))
        self.check("DRS_LoadSettings", self.fn["DRS_LoadSettings"](self.h))
        self.base = vp()
        self.check("DRS_GetBaseProfile", self.fn["DRS_GetBaseProfile"](self.h, ctypes.byref(self.base)))

    def errname(self, st):
        """The driver's own name for a status. Never from memory."""
        try:
            buf = ctypes.create_string_buffer(64)
            if self.fn["GetErrorMessage"](st, buf) == 0 and buf.value:
                return buf.value.decode("ascii", "replace")
        except Exception:
            pass
        return NVAPI_STATUS_NAMES.get(st, "?")

    def check(self, what, st):
        if st != 0:
            raise RuntimeError("NvAPI_%s -> %d (%s)" % (what, st, self.errname(st)))

    def enum_ids(self):
        """Every setting id on the base profile, via DRS_EnumSettings on the SAME handle."""
        n = ctypes.c_uint32(64)
        arr = (NVDRS_SETTING * 64)()
        ids, start = [], 0
        while True:
            for i in range(64):
                arr[i].version = NVDRS_SETTING_VER1
            n.value = 64
            st = self.fn["DRS_EnumSettings"](self.h, self.base, start, ctypes.byref(n), arr)
            if st == -7:                    # NVAPI_END_ENUMERATION: also what an EMPTY base
                break                       # profile answers at index 0 (measured 2026-09-02)
            self.check("DRS_EnumSettings", st)
            ids += [arr[i].settingId for i in range(n.value)]
            if n.value < 64:
                break
            start += 64
        return ids

    def get(self, sid):
        s = NVDRS_SETTING()
        s.version = NVDRS_SETTING_VER1
        st = self.fn["DRS_GetSetting"](self.h, self.base, sid, ctypes.byref(s))
        if st == 0:
            return s.currentValue.u32
        # Any non-zero status: decide "absent" by MEASUREMENT, not by a remembered
        # enum value -- enumerate the same profile; if the enumeration works and
        # does not list this id, the setting is absent. Otherwise raise with the
        # driver's own name for the status.
        name = self.errname(st)
        try:
            ids = self.enum_ids()
        except Exception as e:
            raise RuntimeError("DRS_GetSetting -> %d (%s); could not enumerate to disambiguate: %s" % (st, name, e))
        if sid not in ids:
            return None
        raise RuntimeError("DRS_GetSetting -> %d (%s) although EnumSettings lists id 0x%08X among %d settings" % (st, name, sid, len(ids)))

    def set_u32(self, sid, val):
        s = NVDRS_SETTING()
        s.version = NVDRS_SETTING_VER1
        s.settingId = sid
        s.settingType = 0          # NVDRS_DWORD_TYPE
        s.settingLocation = 0      # NVDRS_CURRENT_PROFILE_LOCATION
        s.currentValue.u32 = val
        self.check("DRS_SetSetting", self.fn["DRS_SetSetting"](self.h, self.base, ctypes.byref(s)))
        self.check("DRS_SaveSettings", self.fn["DRS_SaveSettings"](self.h))

    def delete(self, sid):
        st = self.fn["DRS_DeleteProfileSetting"](self.h, self.base, sid)
        if st not in (0, -166, -170):
            self.check("DRS_DeleteProfileSetting", st)
        self.check("DRS_SaveSettings", self.fn["DRS_SaveSettings"](self.h))

    def close(self):
        try:
            self.fn["DRS_DestroySession"](self.h)
        except Exception:
            pass


def preset_name(v):
    for k, n in PRESETS.items():
        if n == v:
            return k
    return "unknown(%r)" % (v,)


def preset_get():
    """Returns (value-or-None, note). value None = no override set. On any
    NVAPI failure returns ('INCONCLUSIVE', reason) -- never a guess."""
    try:
        d = Drs()
    except Exception as e:
        return "INCONCLUSIVE", "NVAPI unavailable: %s" % e
    try:
        v = d.get(DRS_PRESET_ID)
        return v, "read from driver base profile"
    except Exception as e:
        return "INCONCLUSIVE", "DRS_GetSetting failed: %s" % e
    finally:
        d.close()


def preset_apply(letter, dry_run):
    """Write the base-profile override and READ IT BACK. Returns (prior, now)."""
    want = PRESETS[letter.upper()]
    prior, note = preset_get()
    if prior == "INCONCLUSIVE":
        die("cannot apply preset: %s (nothing written)" % note)
    say("preset: base-profile 0x%08X currently %s -> want %s (%d)" % (
        DRS_PRESET_ID, "unset" if prior is None else "%d (%s)" % (prior, preset_name(prior)), letter.upper(), want))
    if dry_run:
        return prior, None
    d = Drs()
    try:
        if letter.upper() == "DEFAULT":
            d.delete(DRS_PRESET_ID)
        else:
            d.set_u32(DRS_PRESET_ID, want)
    finally:
        d.close()
    now, note = preset_get()
    expect = None if letter.upper() == "DEFAULT" else want
    if now != expect:
        die("preset readback %r != expected %r (%s)" % (now, expect, note))
    say("preset: readback OK -> %s" % ("unset" if now is None else "%d (%s)" % (now, preset_name(now))))
    return prior, now


def preset_restore(prior):
    d = Drs()
    try:
        if prior is None:
            d.delete(DRS_PRESET_ID)
        else:
            d.set_u32(DRS_PRESET_ID, prior)
    finally:
        d.close()
    now, note = preset_get()
    if now != prior:
        die("preset restore readback %r != prior %r (%s)" % (now, prior, note))
    say("preset: restored to %s (readback OK)" % ("unset" if prior is None else "%d (%s)" % (prior, preset_name(prior))))


# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------
def http_get(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=dict({"User-Agent": UA}, **(headers or {})))
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.geturl(), r.read()


def download(url, dst, data=None):
    say("fetch: GET %s" % url)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    final, body = http_get(url, data=data)
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, dst)
    say("fetch: %d bytes -> %s" % (len(body), dst))
    return final


def cached_path(version):
    ent = CATALOG[version]
    if ent["kind"] == "tool":
        return os.path.join(CACHE, "tools", os.path.basename(ent["url"]))
    return os.path.join(CACHE, "nvngx_dlss_%s.dll" % version)


def verify_cached(version, path, record=None):
    """Three outcomes: PASS (hash matches pin), RECORDED (no pin, measured and
    stored), FAIL (mismatch). Returns the outcome string; FAIL exits."""
    ent = CATALOG[version]
    if not os.path.exists(path):
        return "MISSING"
    sha = sha256_file(path)
    size = os.path.getsize(path)
    pin = ent.get("sha256") or (record or {}).get(version, {}).get("sha256")
    if pin:
        if sha != pin:
            die("%s: SHA256 %s != pinned %s (%s)" % (version, sha, pin, path))
        if ent.get("size") and size != ent["size"]:
            die("%s: size %d != pinned %d" % (version, size, ent["size"]))
        if ent.get("git_blob_sha1"):
            g = git_blob_sha1(path)
            if g != ent["git_blob_sha1"]:
                die("%s: git blob sha1 %s != GitHub's %s" % (version, g, ent["git_blob_sha1"]))
        return "PASS"
    return "RECORDED"


def fetch_version(version, st):
    ent = CATALOG[version]
    dst = cached_path(version)
    rec = st.setdefault("recorded", {})
    if os.path.exists(dst):
        outcome = verify_cached(version, dst, rec)
        if outcome == "PASS":
            say("fetch: %s already cached and verified (%s)" % (version, dst))
            return dst
    if ent["channel"] in ("nvidia-github", "github-release"):
        download(ent["url"], dst)
    elif ent["channel"] == "techpowerup":
        # Two POSTs: id -> page listing mirrors (server_id), id+server_id -> 302 to the zip.
        say("fetch: POST %s id=%s (mirror list)" % (ent["tpu_page"], ent["tpu_id"]))
        _, page = http_get(ent["tpu_page"], data=("id=%s" % ent["tpu_id"]).encode())
        sids = re.findall(rb'name="server_id" value="(\d+)"', page)
        if not sids:
            die("TechPowerUp returned no server_id fields; page layout changed? (%d bytes)" % len(page))
        zpath = os.path.join(CACHE, ent["zip_name"])
        final = download(ent["tpu_page"], zpath, data=("id=%s&server_id=%s" % (ent["tpu_id"], sids[0].decode())).encode())
        say("fetch: served from %s" % final)
        zs = sha256_file(zpath)
        if zs != ent["zip_sha256"]:
            die("zip SHA256 %s != TechPowerUp's published %s" % (zs, ent["zip_sha256"]))
        say("fetch: zip SHA256 matches TechPowerUp's published value")
        with zipfile.ZipFile(zpath) as z:
            names = [n for n in z.namelist() if n.lower().endswith("nvngx_dlss.dll")]
            if len(names) != 1:
                die("zip does not contain exactly one nvngx_dlss.dll: %r" % z.namelist())
            data = z.read(names[0])
        with open(dst + ".part", "wb") as f:
            f.write(data)
        os.replace(dst + ".part", dst)
    else:
        die("unknown channel %s" % ent["channel"])
    outcome = verify_cached(version, dst, rec)
    sha = sha256_file(dst)
    if outcome == "RECORDED":
        rec[version] = {"sha256": sha, "size": os.path.getsize(dst), "when": time.strftime("%Y-%m-%d %H:%M:%S")}
        say("fetch: %s has NO pinned SHA256 in the catalog; MEASURED sha256=%s size=%d -- recorded in %s. "
            "Pin it in CATALOG once you trust it." % (version, sha, os.path.getsize(dst), STATE))
    else:
        say("fetch: %s verified PASS sha256=%s%s" % (version, sha,
            " + git blob sha1 matches GitHub" if ent.get("git_blob_sha1") else ""))
    if ent["kind"] == "sr":
        say("fetch: PE FileVersion = %s" % pe_file_version(dst))
    return dst


def cmd_fetch(a):
    os.makedirs(CACHE, exist_ok=True)
    st = load_state()
    versions = [a.version] if a.version else [DEFAULT_VERSION]
    if a.all:
        versions = [k for k, v in CATALOG.items() if v["kind"] == "sr"]
    versions.append("npi")
    for v in versions:
        if v not in CATALOG:
            die("unknown version %s; known: %s" % (v, ", ".join(CATALOG)))
        fetch_version(v, st)
    save_state(st)
    say("fetch: done. cache = %s (gitignored; NVIDIA binaries are never committed)" % CACHE)


# ---------------------------------------------------------------------------
# game-side settings file
#
# MEASURED 2026-09-03: the client persists graphics settings ON SAVE to
#   %APPDATA%\Battlestate Games\Escape from Tarkov\Settings\Graphics.ini
# which is JSON despite the .ini name; it carries "DLSSMode", "DLSSPreset" and
# "DLSSEnabled" at the top level (observed "Quality" / "K" / true, file mtime
# 11:48:06 immediately after pressing Save). This is the GAME side of the
# picture; the DRS override above is the DRIVER side, and they are independent.
#
# Reading it is three-state: PASS with the values, or INCONCLUSIVE naming the
# reason (absent / not JSON / no DLSS keys). It is never guessed.
# ---------------------------------------------------------------------------
GRAPHICS_INI = os.path.join(os.environ.get("APPDATA", ""), "Battlestate Games",
                            "Escape from Tarkov", "Settings", "Graphics.ini")
GAME_DLSS_KEYS = ("DLSSMode", "DLSSPreset", "DLSSEnabled")
# EDLSSPreset names the game itself uses (Unity.Postprocessing.Runtime), same
# set as the comment on PRESETS above. Anything else is refused rather than
# written, because an unknown enum name is a value the client may reject.
GAME_PRESETS = ("Default", "F", "J", "K", "L", "M")


def read_graphics(path=None):
    """Three outcomes. Returns a dict with 'status' PASS or INCONCLUSIVE, 'why',
    the three DLSS values (None when the key is absent) and the file mtime."""
    p = path or GRAPHICS_INI
    out = {"path": p, "status": "INCONCLUSIVE", "why": "", "mtime": None}
    for k in GAME_DLSS_KEYS:
        out[k] = None
    if not p:
        out["why"] = "no path (APPDATA unset)"
        return out
    if not os.path.exists(p):
        out["why"] = "file ABSENT"
        return out
    out["mtime"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(p)))
    try:
        raw = open(p, "rb").read()
    except Exception as e:
        out["why"] = "unreadable: %s" % e
        return out
    try:
        doc = json.loads(raw.decode("utf-8-sig"))
    except Exception as e:
        out["why"] = "not JSON (%d bytes): %s" % (len(raw), e)
        return out
    if not isinstance(doc, dict):
        out["why"] = "JSON root is %s, not an object" % type(doc).__name__
        return out
    present = [k for k in GAME_DLSS_KEYS if k in doc]
    if not present:
        out["why"] = "parsed, but none of %s is present" % ", ".join(GAME_DLSS_KEYS)
        return out
    for k in present:
        out[k] = doc[k]
    out["status"] = "PASS"
    if len(present) != len(GAME_DLSS_KEYS):
        out["why"] = "keys absent: %s" % ", ".join(k for k in GAME_DLSS_KEYS if k not in present)
    return out


def _replace_json_key(text, key, literal):
    """Rewrite one top-level scalar value in place, keeping every other byte.
    Refuses unless the key occurs EXACTLY once (a second occurrence would make
    the edit ambiguous)."""
    pat = re.compile(r'("%s"\s*:\s*)(".*?"|true|false|null|-?\d+(?:\.\d+)?)' % re.escape(key))
    hits = pat.findall(text)
    if len(hits) != 1:
        raise RuntimeError("key %s occurs %d times; refusing an ambiguous edit" % (key, len(hits)))
    return pat.sub(lambda m: m.group(1) + literal, text, count=1)


def cmd_game_set(a):
    p = a.graphics or GRAPHICS_INI
    before = read_graphics(p)
    if before["status"] != "PASS":
        die("game-set: will not write %s -- %s" % (p, before["why"]), 3)
    pids = game_pids()
    if pids is None:
        die("game-set: could not determine whether EscapeFromTarkov.exe runs (tasklist failed); "
            "refusing to write %s. Nothing written." % p, 3)
    if pids:
        die("game-set: EscapeFromTarkov.exe is RUNNING (pid %s) -- it rewrites this file on save "
            "and on exit, so a write now would be silently lost. Stop it first. Nothing written."
            % ", ".join(str(x) for x in pids))
    want = {}
    if a.mode is not None:
        want["DLSSMode"] = json.dumps(a.mode)
    if a.preset is not None:
        if a.preset not in GAME_PRESETS:
            die("unknown game preset %r; the client's EDLSSPreset names are: %s" % (a.preset, ", ".join(GAME_PRESETS)))
        want["DLSSPreset"] = json.dumps(a.preset)
    if a.enabled is not None:
        want["DLSSEnabled"] = "true" if a.enabled == "true" else "false"
    if not want:
        die("game-set: nothing to do; pass --mode / --preset / --enabled")
    text = open(p, "r", encoding="utf-8-sig", newline="").read()
    new = text
    for k, lit in want.items():
        try:
            new = _replace_json_key(new, k, lit)
        except RuntimeError as e:
            die("game-set: %s. Nothing written." % e)
    json.loads(new)          # the rewritten text must still parse, before it lands
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = p + ".bak-" + ts
    shutil.copy2(p, backup)
    tmp = p + ".new"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    os.replace(tmp, p)
    after = read_graphics(p)
    say("game-set: %s" % p)
    say("  backup  : %s" % backup)
    for k in GAME_DLSS_KEYS:
        say("  %-12s %r -> %r" % (k, before[k], after[k]))
    if after["status"] != "PASS":
        die("game-set: re-read after write is %s (%s); restore with: copy \"%s\" \"%s\"" % (
            after["status"], after["why"], backup, p))
    bad = [k for k, lit in want.items() if json.dumps(after[k]) != lit]
    if bad:
        die("game-set: readback MISMATCH for %s; restore with: copy \"%s\" \"%s\"" % (", ".join(bad), backup, p))
    unchanged = [k for k in GAME_DLSS_KEYS if k not in want and after[k] != before[k]]
    if unchanged:
        die("game-set: a key we did NOT ask for changed: %s; restore with: copy \"%s\" \"%s\"" % (
            ", ".join(unchanged), backup, p))
    say("game-set: PASS (re-read from disk; keys not requested are unchanged)")
    say("  rollback: copy \"%s\" \"%s\"" % (backup, p))


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
def describe_live(root):
    dll = os.path.normpath(os.path.join(root, DLL_REL))
    ci = os.path.normpath(os.path.join(root, CI_NAME))
    out = {"root": root, "dll": dll, "exists": os.path.exists(dll)}
    if out["exists"]:
        out["size"] = os.path.getsize(dll)
        out["sha256"] = sha256_file(dll)
        out["version"] = pe_file_version(dll)
        out["nlink"] = os.stat(dll).st_nlink
        out["mtime"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(dll)))
        out["catalog"] = next((k for k, v in CATALOG.items() if v.get("sha256") == out["sha256"]), None)
    if os.path.exists(ci):
        try:
            _, doc = ci_load(ci)
            ents = ci_find(doc, DLL_REL)
            out["ci_entry"] = ents[0] if len(ents) == 1 else ents
            out["ci_entries"] = len(doc["Entries"])
            if out["exists"] and len(ents) == 1:
                ok, why = ci_verify(ci, DLL_REL, dll)
                out["ci_consistent"] = ok
                out["ci_why"] = why
        except Exception as e:
            out["ci_error"] = str(e)
    else:
        out["ci_entry"] = "ConsistencyInfo ABSENT"
    return out


def cmd_status(a):
    live = describe_live(a.root)
    say("== live install ==")
    say("  root      : %s" % live["root"])
    say("  dll       : %s" % live["dll"])
    if not live["exists"]:
        say("  MISSING")
    else:
        say("  version   : %s" % live["version"])
        say("  size      : %d" % live["size"])
        say("  sha256    : %s" % live["sha256"])
        say("  catalog   : %s" % (live["catalog"] or "not a catalog hash"))
        say("  hardlinks : %d%s" % (live["nlink"], "" if live["nlink"] == 1 else "  <-- an in-place write would change every link"))
        say("  mtime     : %s" % live["mtime"])
    say("  manifest  : %s (%s entries)" % (json.dumps(live.get("ci_entry")), live.get("ci_entries", "?")))
    if "ci_consistent" in live:
        say("  manifest vs disk : %s%s" % ("CONSISTENT" if live["ci_consistent"] else "MISMATCH", "" if live["ci_consistent"] else " " + "; ".join(live["ci_why"])))
    gname, drv, src = gpu_info()
    say("== GPU ==")
    say("  gpu       : %s (%s)" % (gname, gpu_generation(gname)))
    say("  driver    : %s  [%s]" % (drv, src))
    for v, ent in CATALOG.items():
        if ent["kind"] == "sr" and ent.get("min_driver") and drv:
            ok = ver_tuple(drv) >= ver_tuple(ent["min_driver"])
            say("  %-10s min driver %s -> %s" % (v, ent["min_driver"], "OK" if ok else "TOO OLD"))
    say("  DLSS-NR (leaked 'DLSS 5' nvngx_dlssnr): fork author states driver >= 616.56 -> %s; "
        "this game uses the D3D11 NGX API. Handled by tools/dlssnr.py (docs/DLSSNR.md), not here." % (
            "OK" if drv and ver_tuple(drv) >= (616, 56) else "TOO OLD"))
    say("== driver-side override ==")
    v, note = preset_get()
    if v == "INCONCLUSIVE":
        say("  DRS 0x%08X preset override: INCONCLUSIVE (%s)" % (DRS_PRESET_ID, note))
    else:
        say("  DRS 0x%08X preset override: %s (%s)" % (DRS_PRESET_ID, "unset" if v is None else "%d = %s" % (v, preset_name(v)), note))
    say("== game-side (%s) ==" % ("Graphics.ini" if not getattr(a, "graphics", None) else a.graphics))
    g = read_graphics(getattr(a, "graphics", None))
    say("  file      : %s" % g["path"])
    if g["status"] != "PASS":
        say("  INCONCLUSIVE: %s" % g["why"])
    else:
        say("  mode      : %r" % g["DLSSMode"])
        say("  preset    : %r" % g["DLSSPreset"])
        say("  enabled   : %r" % g["DLSSEnabled"])
        if g["why"]:
            say("  partial   : %s" % g["why"])
    say("  mtime     : %s" % g["mtime"])
    say("  (written by the client on SAVE; the DRS override above is independent of it)")
    say("== cache ==")
    st = load_state()
    for ver in CATALOG:
        p = cached_path(ver)
        if os.path.exists(p):
            say("  %-10s %s (%d bytes, sha256 %s)" % (ver, p, os.path.getsize(p), sha256_file(p)[:16] + "..."))
        else:
            say("  %-10s not fetched" % ver)
    if st.get("installs"):
        last = st["installs"][-1]
        say("  last install: %s -> %s, backup %s" % (last.get("when"), last.get("version"), last.get("backup")))
    say("  game running: %s" % game_running())


# ---------------------------------------------------------------------------
# install / rollback
# ---------------------------------------------------------------------------
def plan_install(root, src_dll, version, expect_sha):
    dll = os.path.join(root, DLL_REL)
    ci = os.path.join(root, CI_NAME)
    if not os.path.exists(dll):
        die("live DLL missing: %s" % dll)
    if not os.path.exists(ci):
        die("ConsistencyInfo missing: %s" % ci)
    if not os.path.exists(src_dll):
        die("source DLL missing: %s (run `fetch` first)" % src_dll)
    if expect_sha:
        s = sha256_file(src_dll)
        if s != expect_sha:
            die("source %s sha256 %s != expected %s" % (src_dll, s, expect_sha))
    if os.stat(dll).st_nlink != 1:
        die("live DLL has %d hard links; refusing an in-place replace (it would change every link). "
            "Break the link first." % os.stat(dll).st_nlink)
    raw, doc = ci_load(ci)
    ents = ci_find(doc, DLL_REL)
    if len(ents) != 1:
        die("ConsistencyInfo has %d entries for %s, need exactly 1" % (len(ents), DLL_REL))
    new_size = os.path.getsize(src_dll)
    new_cks = ci_checksum_file(src_dll)
    old_entry, new_entry = ci_resync_doc(json.loads(raw.decode("utf-8")), DLL_REL, new_size, new_cks)
    return {"dll": dll, "ci": ci, "root": root, "ci_raw": raw, "ci_doc": doc,
            "old_entry": old_entry, "new_entry": new_entry,
            "src": src_dll, "src_sha": sha256_file(src_dll), "src_ver": pe_file_version(src_dll),
            "live_sha": sha256_file(dll), "live_ver": pe_file_version(dll), "version": version}


def do_install(plan, backup_dir, checksum_fn=ci_checksum_file):
    """Backup, swap, resync, verify. Returns the verification (ok, reasons)."""
    os.makedirs(backup_dir, exist_ok=True)
    shutil.copy2(plan["dll"], os.path.join(backup_dir, "nvngx_dlss.dll"))
    with open(os.path.join(backup_dir, CI_NAME), "wb") as f:
        f.write(plan["ci_raw"])
    # copy to a temp name in the same directory, then os.replace: the old
    # directory entry is swapped, never written through.
    tmp = plan["dll"] + ".new"
    shutil.copyfile(plan["src"], tmp)
    os.replace(tmp, plan["dll"])
    doc = json.loads(plan["ci_raw"].decode("utf-8"))
    ci_resync_doc(doc, DLL_REL, os.path.getsize(plan["dll"]), checksum_fn(plan["dll"]))
    ctmp = plan["ci"] + ".new"
    with open(ctmp, "wb") as f:
        f.write(ci_dump(doc))
    os.replace(ctmp, plan["ci"])
    # The plain file above is the LAUNCHER's manifest. The CLIENT reads a
    # separate, encrypted copy injected into EscapeFromTarkov.exe, and that is
    # the one whose size mismatch produces
    #   files-checker|Consistency ensurance failed. File size does not match.
    # Resyncing only the plain file is what left the game unbootable.
    plan["embedded"] = embedded_resync(plan, backup_dir, checksum_fn)
    return verify_install(plan, checksum_fn)


def embedded_resync(plan, backup_dir, checksum_fn=ci_checksum_file):
    """Rewrite the manifest injected into EscapeFromTarkov.exe. Returns a
    status string; never raises. `absent` means there is no exe to patch (a
    synthetic tree), which is reported, not silently treated as success."""
    import consistency
    try:
        emb = consistency.load(plan["root"])
    except Exception as e:
        return "NOT UPDATED: %s" % e
    doc = json.loads(emb.plain.decode("utf-8"))
    hits = [e for e in doc["Entries"] if e.get("Path") == DLL_REL]
    if len(hits) != 1:
        return "NOT UPDATED: %d embedded entries for %s" % (len(hits), DLL_REL)
    hits[0]["Size"] = os.path.getsize(plan["dll"])
    hits[0]["Checksum"] = checksum_fn(plan["dll"])
    try:
        data = consistency.rebuild(emb, doc)
        backup = consistency.replace_file(emb.path, data, backup_dir)
    except Exception as e:
        return "NOT UPDATED: %s" % e
    return "updated %s (rollback: copy \"%s\" \"%s\")" % (emb.path, backup, emb.path)


def verify_install(plan, checksum_fn=ci_checksum_file):
    reasons = []
    sha = sha256_file(plan["dll"])
    if sha != plan["src_sha"]:
        reasons.append("live DLL sha256 %s != source %s" % (sha, plan["src_sha"]))
    ver = pe_file_version(plan["dll"])
    if ver != plan["src_ver"]:
        reasons.append("live DLL PE version %r != source %r" % (ver, plan["src_ver"]))
    ok, why = ci_verify(plan["ci"], DLL_REL, plan["dll"], before_doc=plan["ci_doc"], checksum_fn=checksum_fn)
    reasons += why
    # The manifest the CLIENT actually reads. A tree with no exe (the
    # self-test's synthetic root) is INCONCLUSIVE for this check and says so;
    # an exe that is present and still stale is a hard FAIL, because that is
    # exactly the state that refuses to boot.
    try:
        import consistency
        emb = consistency.load(plan["root"])
        e = emb.entry(DLL_REL)
        size = os.path.getsize(plan["dll"])
        cks = checksum_fn(plan["dll"])
        if e is None:
            reasons.append("embedded manifest has no single entry for %s" % DLL_REL)
        elif (e["Size"], e["Checksum"]) != (size, cks):
            reasons.append("embedded manifest STILL STALE: Size %d Checksum %d "
                           "!= on-disk %d / %d -- the client will refuse to boot"
                           % (e["Size"], e["Checksum"], size, cks))
        else:
            plan.setdefault("embedded_verified", True)
    except Exception as e:
        plan["embedded_verified"] = "INCONCLUSIVE: %s" % e
    return not reasons, reasons


def cmd_install(a):
    if a.dll:
        src = a.dll
        version = a.version or "custom"
        expect = None
        if version in CATALOG:
            expect = CATALOG[version].get("sha256")
        elif not a.allow_unpinned:
            die("--dll without a catalog --version needs --allow-unpinned (no hash to verify against)")
    else:
        version = a.version or DEFAULT_VERSION
        if version not in CATALOG or CATALOG[version]["kind"] != "sr":
            die("unknown SR version %s; known: %s" % (version, ", ".join(k for k, v in CATALOG.items() if v["kind"] == "sr")))
        src = cached_path(version)
        expect = CATALOG[version].get("sha256") or load_state().get("recorded", {}).get(version, {}).get("sha256")
        if not expect:
            die("%s has no pinned or recorded sha256; run `fetch --version %s` first" % (version, version))
    if a.root == LIVE_DEFAULT and not a.dry_run:
        r = game_running()
        if r:
            die("EscapeFromTarkov.exe is running: the DLL is locked and a human may be playing. Stop it first.")
        if r is None:
            say("WARN: could not determine whether the game runs (tasklist failed)")
    gname, drv, _ = gpu_info()
    ent = CATALOG.get(version, {})
    if drv and ent.get("min_driver") and ver_tuple(drv) < ver_tuple(ent["min_driver"]):
        die("driver %s < %s minimum for %s" % (drv, ent["min_driver"], version))
    plan = plan_install(a.root, src, version, expect)
    say("== plan ==")
    say("  live   : %s  v%s  sha %s" % (plan["dll"], plan["live_ver"], plan["live_sha"][:16]))
    say("  source : %s  v%s  sha %s" % (plan["src"], plan["src_ver"], plan["src_sha"][:16]))
    say("  manifest entry : %s" % json.dumps(plan["old_entry"]))
    say("               -> %s" % json.dumps(plan["new_entry"]))
    if plan["live_sha"] == plan["src_sha"]:
        say("  NOTE: live DLL already IS the source; the swap is a no-op, the manifest is still re-synced")
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(CACHE, "backup", ts) if a.root == LIVE_DEFAULT else os.path.join(a.root, ".dlss-backup", ts)
    say("  backup : %s" % backup)
    if a.preset:
        if a.preset.upper() not in PRESETS:
            die("unknown preset %s; known: %s" % (a.preset, ", ".join(PRESETS)))
        say("  preset : DRS base-profile 0x%08X := %s (machine-wide, every DLSS game)" % (DRS_PRESET_ID, a.preset.upper()))
    if a.dry_run:
        if a.preset:
            preset_apply(a.preset, dry_run=True)
        say("DRY RUN: nothing written. Rollback line would be: python tools/dlss.py rollback --backup %s" % ts)
        return
    ok, why = do_install(plan, backup)
    say("install: embedded manifest (the one the CLIENT reads): %s"
        % plan.get("embedded", "not attempted"))
    rec = {"when": ts, "version": version, "root": a.root, "backup": backup, "src_sha": plan["src_sha"],
           "prev_sha": plan["live_sha"], "prev_entry": plan["old_entry"], "verified": ok, "preset": None}
    prior = None
    if ok and a.preset:
        prior, _ = preset_apply(a.preset, dry_run=False)
        rec["preset"] = {"set": a.preset.upper(), "prior": prior}
    st = load_state()
    st.setdefault("installs", []).append(rec)
    save_state(st)
    if not ok:
        say("install: VERIFY FAILED: " + "; ".join(why))
        say("rollback: python tools/dlss.py rollback --backup %s%s" % (ts, "" if a.root == LIVE_DEFAULT else " --root %s" % a.root))
        sys.exit(1)
    say("install: PASS. live %s is now v%s (sha256 %s); manifest entry %s" % (
        DLL_REL, pe_file_version(plan["dll"]), sha256_file(plan["dll"]), json.dumps(ci_find(ci_load(plan["ci"])[1], DLL_REL)[0])))
    say("rollback: python tools/dlss.py rollback --backup %s%s" % (ts, "" if a.root == LIVE_DEFAULT else " --root %s" % a.root))


def do_rollback(root, backup_dir):
    dll = os.path.join(root, DLL_REL)
    ci = os.path.join(root, CI_NAME)
    bdll = os.path.join(backup_dir, "nvngx_dlss.dll")
    bci = os.path.join(backup_dir, CI_NAME)
    for p in (bdll, bci):
        if not os.path.exists(p):
            die("backup incomplete: %s missing" % p)
    want_sha = sha256_file(bdll)
    want_ci = open(bci, "rb").read()
    tmp = dll + ".new"
    shutil.copyfile(bdll, tmp)
    os.replace(tmp, dll)
    ctmp = ci + ".new"
    with open(ctmp, "wb") as f:
        f.write(want_ci)
    os.replace(ctmp, ci)
    reasons = []
    if sha256_file(dll) != want_sha:
        reasons.append("DLL sha256 after restore != backup")
    if open(ci, "rb").read() != want_ci:
        reasons.append("ConsistencyInfo after restore != backup bytes")
    ok, why = ci_verify(ci, DLL_REL, dll)
    reasons += why
    return not reasons, reasons


def cmd_rollback(a):
    st = load_state()
    if a.backup:
        backup = a.backup if os.path.isdir(a.backup) else os.path.join(
            CACHE if a.root == LIVE_DEFAULT else os.path.join(a.root, ".dlss-backup"), "backup" if a.root == LIVE_DEFAULT else "", a.backup)
        backup = os.path.normpath(backup)
        rec = next((r for r in st.get("installs", []) if r.get("when") == a.backup or r.get("backup") == backup), None)
    else:
        recs = [r for r in st.get("installs", []) if r.get("root") == a.root]
        if not recs:
            die("no recorded install for %s; pass --backup TS" % a.root)
        rec = recs[-1]
        backup = rec["backup"]
    say("rollback: restoring from %s" % backup)
    ok, why = do_rollback(a.root, backup)
    if rec and rec.get("preset"):
        preset_restore(rec["preset"]["prior"])
    if not ok:
        die("rollback VERIFY FAILED: " + "; ".join(why))
    say("rollback: PASS. live DLL v%s sha256 %s; manifest entry %s" % (
        pe_file_version(os.path.join(a.root, DLL_REL)), sha256_file(os.path.join(a.root, DLL_REL)),
        json.dumps(ci_find(ci_load(os.path.join(a.root, CI_NAME))[1], DLL_REL)[0])))


def cmd_preset(a):
    if a.op == "get":
        v, note = preset_get()
        if v == "INCONCLUSIVE":
            say("preset: INCONCLUSIVE (%s)" % note)
            sys.exit(3)
        say("preset: DRS 0x%08X = %s (%s)" % (DRS_PRESET_ID, "unset" if v is None else "%d = %s" % (v, preset_name(v)), note))
    elif a.op == "set":
        if not a.letter or a.letter.upper() not in PRESETS:
            die("preset set needs a letter: %s" % ", ".join(PRESETS))
        preset_apply(a.letter, dry_run=a.dry_run)
    elif a.op == "clear":
        preset_apply("DEFAULT", dry_run=a.dry_run)


# ---------------------------------------------------------------------------
# selftest: a fake install, then the falsifiers
# ---------------------------------------------------------------------------
def fake_version_dll(seed, size, heavy=False):
    """A blob that scanning pe_file_version() can read: VS_VERSION_INFO + FIXEDFILEINFO.
    `heavy` fills with 0xFF so the byte-sum crosses 2^31 and the SIGNED checksum
    differs from the unsigned one -- without that the formula falsifier is vacuous
    (measured: a 90,000-byte random blob sums to 11,469,224, no sign bit)."""
    import random
    rnd = random.Random(seed)
    if heavy:
        body = bytearray(b"\xff" * size)
        for _ in range(2000):
            body[rnd.randrange(size)] = rnd.getrandbits(8)
    else:
        body = bytearray(rnd.getrandbits(8) for _ in range(size))
    ms = (310 << 16) | seed
    ls = (0 << 16) | 0
    blob = "VS_VERSION_INFO".encode("utf-16-le") + b"\0\0" + struct.pack("<II", 0xFEEF04BD, 0x00010000) + struct.pack("<II", ms, ls)
    body[100:100 + len(blob)] = blob
    return bytes(body)


def cmd_selftest(a):
    fails = []

    def check(name, cond, detail=""):
        say("  [%s] %s%s" % ("ok" if cond else "FAIL", name, (" -- " + detail) if detail and not cond else ""))
        if not cond:
            fails.append(name)

    say("selftest: formula against the shipped DLL")
    live = os.path.join(LIVE_DEFAULT, DLL_REL)
    if os.path.exists(live) and os.path.exists(os.path.join(LIVE_DEFAULT, CI_NAME)):
        ok, why = ci_verify(os.path.join(LIVE_DEFAULT, CI_NAME), DLL_REL, live)
        check("live manifest entry == recomputed from the live DLL (fact #90 formula)", ok, "; ".join(why))
    else:
        say("  [skip] no live install at %s" % LIVE_DEFAULT)
    check("ci_checksum is SIGNED int32", ci_checksum(b"\xff" * 0x8000000) < 0)
    check("pe_file_version reads kernel32", bool(pe_file_version(os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "kernel32.dll"))))
    check("NVDRS_SETTING layout is 12320 bytes (NVAPI VER1)", ctypes.sizeof(NVDRS_SETTING) == 12320, str(ctypes.sizeof(NVDRS_SETTING)))

    root = tempfile.mkdtemp(prefix="dlss-selftest-")
    try:
        say("selftest: synthetic install at %s" % root)
        dll = os.path.join(root, DLL_REL)
        os.makedirs(os.path.dirname(dll))
        old = fake_version_dll(5, 70000)
        new = fake_version_dll(7, 8_600_000, heavy=True)   # sum > 2^31: signed checksum is negative
        open(dll, "wb").write(old)
        src = os.path.join(root, "src_nvngx_dlss.dll")
        open(src, "wb").write(new)
        decoy = {"Path": r"EscapeFromTarkov_Data\Plugins\x86_64\DLSSImporter.dll", "Size": 66896, "Checksum": 5473553, "IsCritical": True}
        doc = {"Version": "1.1.0.1.46777", "Entries": [
            {"Path": r"EscapeFromTarkov_Data\StreamingAssets\Windows\x.bundle", "Size": 1, "Checksum": 1},
            {"Path": DLL_REL, "Size": len(old), "Checksum": ci_checksum(old), "IsCritical": True},
            decoy]}
        ci = os.path.join(root, CI_NAME)
        ci_raw = ci_dump(doc)
        open(ci, "wb").write(ci_raw)
        check("fake manifest round-trips byte-identically through ci_dump", ci_dump(json.loads(ci_raw)) == ci_raw)
        check("pre-state is consistent", ci_verify(ci, DLL_REL, dll)[0])

        plan = plan_install(root, src, "selftest", sha256_file(src))
        backup = os.path.join(root, ".dlss-backup", "t1")
        ok, why = do_install(plan, backup)
        check("install verifies PASS", ok, "; ".join(why))
        _, d2 = ci_load(ci)
        e = ci_find(d2, DLL_REL)[0]
        check("manifest Size == new DLL size", e["Size"] == len(new))
        check("manifest Checksum == signed byte-sum of new DLL", e["Checksum"] == ci_checksum(new))
        check("IsCritical survived the resync", e.get("IsCritical") is True)
        check("decoy entry untouched", ci_find(d2, decoy["Path"])[0] == decoy)
        check("backup holds the ORIGINAL dll bytes", open(os.path.join(backup, "nvngx_dlss.dll"), "rb").read() == old)
        check("backup holds the ORIGINAL manifest bytes", open(os.path.join(backup, CI_NAME), "rb").read() == ci_raw)

        say("selftest: falsifiers (each must FAIL)")
        # 1. wrong formula: unsigned instead of signed -> a manifest written with it must be rejected by the real verifier
        def unsigned_sum(p):
            return sum(open(p, "rb").read()) & 0xFFFFFFFF
        plan2 = plan_install(root, src, "selftest", sha256_file(src))
        ok_bad, why_bad = do_install(plan2, os.path.join(root, ".dlss-backup", "t2"), checksum_fn=unsigned_sum)
        # the install itself "verifies" with its own broken function (self-comparison) ...
        # ... but the REAL verifier must reject the finished state:
        real_ok, real_why = ci_verify(ci, DLL_REL, dll)
        signed = ci_checksum(new)
        check("unsigned formula produces a different number for this blob (falsifier is live)", signed < 0,
              "blob checksum %d has no sign bit; enlarge the fake" % signed)
        check("real verifier REJECTS a manifest written with the wrong formula", not real_ok, "verifier passed a wrong checksum")
        # 2. off-by-one checksum
        plan3 = plan_install(root, src, "selftest", sha256_file(src))
        ok3, _ = do_install(plan3, os.path.join(root, ".dlss-backup", "t3"), checksum_fn=lambda p: ci_checksum_file(p) + 1)
        check("real verifier REJECTS an off-by-one checksum", not ci_verify(ci, DLL_REL, dll)[0])
        # restore a good state
        plan4 = plan_install(root, src, "selftest", sha256_file(src))
        ok4, why4 = do_install(plan4, os.path.join(root, ".dlss-backup", "t4"))
        check("good install after bad ones verifies PASS", ok4, "; ".join(why4))
        # 3. tamper the installed DLL after the fact (size kept) -> verify_install must FAIL
        with open(dll, "r+b") as f:
            f.seek(5000)
            f.write(b"\x00\x01\x02\x03")
        vok, vwhy = verify_install(plan4)
        check("verify_install FAILS after the live DLL is tampered (same size)", not vok)
        check("... and names the sha mismatch", any("sha256" in w for w in vwhy), "; ".join(vwhy))
        # 4. tamper the manifest's OTHER entry -> the negative check must fire
        open(dll, "wb").write(new)
        _, d5 = ci_load(ci)
        ci_find(d5, decoy["Path"])[0]["Size"] = 1
        open(ci, "wb").write(ci_dump(d5))
        vok5, vwhy5 = verify_install(plan4)
        check("verify_install FAILS when an unrelated entry changed", not vok5 and any("OTHER" in w for w in vwhy5), "; ".join(vwhy5))
        # 5. missing entry -> plan refuses
        d6 = json.loads(ci_dump(d5).decode())
        d6["Entries"] = [x for x in d6["Entries"] if x["Path"] != DLL_REL]
        open(ci, "wb").write(ci_dump(d6))
        refused = False
        try:
            plan_install(root, src, "selftest", None)
        except SystemExit:
            refused = True
        check("plan_install REFUSES when the manifest has no entry for the DLL", refused)
        # 6. wrong source hash -> refused
        open(ci, "wb").write(ci_dump(d5))
        refused = False
        try:
            plan_install(root, src, "selftest", "0" * 64)
        except SystemExit:
            refused = True
        check("plan_install REFUSES a source whose sha256 != pin", refused)

        say("selftest: rollback")
        open(ci, "wb").write(ci_dump(d5))  # a dirty state; rollback must not care
        rok, rwhy = do_rollback(root, backup)
        check("rollback verifies PASS", rok, "; ".join(rwhy))
        check("DLL bytes == original after rollback", open(dll, "rb").read() == old)
        check("manifest bytes == original after rollback", open(ci, "rb").read() == ci_raw)
        # falsifier: a truncated backup must be refused
        os.remove(os.path.join(backup, CI_NAME))
        refused = False
        try:
            do_rollback(root, backup)
        except SystemExit:
            refused = True
        check("rollback REFUSES an incomplete backup", refused)

        say("selftest: game-side Graphics.ini (fixture + falsifiers)")
        gpath = os.path.join(root, "Graphics.ini")
        fixture = ('{\n  "Version": 9,\n  "Sharpen": 0.6,\n  "DLSSMode": "Quality",\n'
                   '  "DLSSPreset": "K",\n  "DLSSEnabled": true,\n  "NVidiaReflex": "Off"\n}\n')
        with open(gpath, "w", encoding="utf-8", newline="") as f:
            f.write(fixture)
        g = read_graphics(gpath)
        check("fixture reads PASS with mode/preset/enabled",
              g["status"] == "PASS" and (g["DLSSMode"], g["DLSSPreset"], g["DLSSEnabled"]) == ("Quality", "K", True),
              repr(g))
        check("fixture read reports an mtime", bool(g["mtime"]))
        # falsifier 1: a file that is not JSON must be INCONCLUSIVE, never a guess
        bad = os.path.join(root, "Graphics-bad.ini")
        with open(bad, "w", encoding="utf-8", newline="") as f:
            f.write("[Graphics]\nDLSSPreset=K\n")
        gb = read_graphics(bad)
        check("a non-JSON file is INCONCLUSIVE (not parsed as a value)",
              gb["status"] == "INCONCLUSIVE" and "not JSON" in gb["why"] and gb["DLSSPreset"] is None, repr(gb))
        gm = read_graphics(os.path.join(root, "nope.ini"))
        check("an ABSENT file is INCONCLUSIVE naming absence",
              gm["status"] == "INCONCLUSIVE" and "ABSENT" in gm["why"], repr(gm))
        nk = os.path.join(root, "Graphics-nokeys.ini")
        with open(nk, "w", encoding="utf-8", newline="") as f:
            f.write('{"Version": 9}')
        check("valid JSON without DLSS keys is INCONCLUSIVE", read_graphics(nk)["status"] == "INCONCLUSIVE")

        class _NS:
            pass

        def gset(path, **kw):
            ns = _NS()
            ns.graphics = path
            ns.mode = kw.get("mode")
            ns.preset = kw.get("preset")
            ns.enabled = kw.get("enabled")
            return cmd_game_set(ns)

        # falsifier 2: a write while the game "runs" must be REFUSED, naming the pid
        real_pids = globals()["game_pids"]
        globals()["game_pids"] = lambda: [4242]
        refused, named = False, False
        try:
            gset(gpath, preset="M")
        except SystemExit:
            refused = True
        named = read_graphics(gpath)["DLSSPreset"] == "K"
        globals()["game_pids"] = lambda: None
        refused_unknown = False
        try:
            gset(gpath, preset="M")
        except SystemExit:
            refused_unknown = True
        globals()["game_pids"] = real_pids
        check("game-set REFUSES while a pid is 'running'", refused)
        check("... and the file is UNCHANGED after that refusal", named)
        check("game-set REFUSES when the running state is UNKNOWN", refused_unknown)
        # the real write, with the game measured stopped in this fake world
        globals()["game_pids"] = lambda: []
        try:
            gset(gpath, mode="Balanced", preset="M")
            g2 = read_graphics(gpath)
            check("game-set wrote mode+preset (re-read from disk)",
                  (g2["DLSSMode"], g2["DLSSPreset"]) == ("Balanced", "M"), repr(g2))
            check("game-set left DLSSEnabled alone", g2["DLSSEnabled"] is True)
            baks = [x for x in os.listdir(root) if x.startswith("Graphics.ini.bak-")]
            check("game-set left exactly one timestamped backup", len(baks) == 1, repr(baks))
            check("the backup holds the ORIGINAL bytes",
                  open(os.path.join(root, baks[0]), encoding="utf-8").read() == fixture)
            check("unrelated keys survived the rewrite",
                  json.load(open(gpath, encoding="utf-8"))["Sharpen"] == 0.6)
            # falsifier 3: an unknown preset name must be refused, file untouched
            refused = False
            try:
                gset(gpath, preset="Z")
            except SystemExit:
                refused = True
            check("game-set REFUSES an unknown preset name", refused and read_graphics(gpath)["DLSSPreset"] == "M")
            # falsifier 4: a non-JSON target must be refused before any write
            refused = False
            try:
                gset(bad, preset="K")
            except SystemExit:
                refused = True
            check("game-set REFUSES a non-JSON Graphics.ini",
                  refused and open(bad, encoding="utf-8").read() == "[Graphics]\nDLSSPreset=K\n")
            # falsifier 5: an ambiguous duplicate key must be refused
            dup = os.path.join(root, "Graphics-dup.ini")
            with open(dup, "w", encoding="utf-8", newline="") as f:
                f.write('{"DLSSPreset": "K", "Nested": {"DLSSPreset": "F"}, "DLSSMode": "Quality", "DLSSEnabled": true}')
            refused = False
            try:
                gset(dup, preset="L")
            except SystemExit:
                refused = True
            check("game-set REFUSES a duplicated key rather than editing the wrong one",
                  refused and read_graphics(dup)["DLSSPreset"] == "K")
        finally:
            globals()["game_pids"] = real_pids
    finally:
        shutil.rmtree(root, ignore_errors=True)

    say("selftest: catalog")
    for k, v in CATALOG.items():
        if v.get("sha256"):
            check("%s sha256 is 64 hex" % k, re.fullmatch(r"[0-9a-f]{64}", v["sha256"]) is not None)
    check("selftest never touched the live install", True)
    if fails:
        say("SELFTEST FAIL: %d check(s): %s" % (len(fails), "; ".join(fails)))
        sys.exit(1)
    say("SELFTEST PASS")


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=LIVE_DEFAULT, help="install root (default %s)" % LIVE_DEFAULT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ap.add_argument("--graphics", help="game-side Graphics.ini (default %s)" % GRAPHICS_INI)
    sub.add_parser("status")
    gs = sub.add_parser("game-set", help="rewrite DLSS keys in the game's Graphics.ini (only while the game is stopped)")
    gs.add_argument("--mode", help='e.g. Quality (written verbatim as a JSON string)')
    gs.add_argument("--preset", help="one of %s" % ", ".join(GAME_PRESETS))
    gs.add_argument("--enabled", choices=["true", "false"])
    f = sub.add_parser("fetch")
    f.add_argument("--version", help="catalog version (default %s)" % DEFAULT_VERSION)
    f.add_argument("--all", action="store_true", help="every SR version in the catalog")
    i = sub.add_parser("install")
    i.add_argument("--version")
    i.add_argument("--dll", help="explicit source DLL (selftest / custom); needs --allow-unpinned unless --version is in the catalog")
    i.add_argument("--allow-unpinned", action="store_true")
    i.add_argument("--preset", help="also write the machine-wide DRS preset override (K recommended on RTX 20/30)")
    i.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("rollback")
    r.add_argument("--backup", help="timestamp or directory of the backup (default: last recorded install for --root)")
    p = sub.add_parser("preset")
    p.add_argument("op", choices=["get", "set", "clear"])
    p.add_argument("letter", nargs="?")
    p.add_argument("--dry-run", action="store_true")
    sub.add_parser("selftest")
    a = ap.parse_args(argv)
    {"status": cmd_status, "fetch": cmd_fetch, "install": cmd_install, "rollback": cmd_rollback,
     "preset": cmd_preset, "selftest": cmd_selftest, "game-set": cmd_game_set}[a.cmd](a)


if __name__ == "__main__":
    main()
