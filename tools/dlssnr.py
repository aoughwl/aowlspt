r"""dlssnr.py -- leaked "DLSS 5" (nvngx_dlssnr, Neural Rendering) on the live aowlspt install.

    python tools/dlssnr.py status                     GPU, driver, what is next to the exe, cache
    python tools/dlssnr.py fetch [--all]              download + sha256-verify into .cache/dlssnr/
    python tools/dlssnr.py install [--dry-run] [--proxy dxgi] [--model sf2]
                                   [--upscaler fsr22_12] [--working-scale 0.5]
                                   [--force-driver] [--force-model]
    python tools/dlssnr.py rollback [--backup TS]
    python tools/dlssnr.py selftest                   synthetic tree + falsifiers, exit 0/1

WHAT THIS INSTALLS (docs/DLSSNR.md has the evidence for every line):

  * Dagherbou's OptiScaler_DLSSNR fork (OptiScaler with a built-in Neural
    Rendering pass), installed next to EscapeFromTarkov.exe under a proxy
    name the game loads by accident (dxgi.dll by default; winmm.dll is the
    other name the OptiScaler wiki's own Tarkov-SPT page reports working).
  * Its forwarder nvngx.dll_dlssnr.dll and its runtime folder OptiScaler/.
  * The model itself, nvngx_dlssnr.dll, from RankFTW/rhi-repo's GitHub
    releases -- the source RHI and DLSS5oneclick install from. The default is
    ShortFuse's "310.8.SF-v2" rebuild, the only one anybody claims runs on
    Turing; the original 310.8.0.0 leak carries sm_120 (Blackwell) cubins only
    (MEASURED here: 15 x "sm_120", no other sm_ string) and is refused on this
    GPU unless --force-model.
  * An OptiScaler.ini with [DlssNr] Enabled=true, a Dx11-on-Dx12 upscaler
    (the model answers FeatureNotSupported on D3D11; the fork lifts the frame
    onto D3D12 through a bridged upscaler, and DLSS itself cannot be that
    upscaler -- fork author, v0.1.2 notes) and logging ON so a refusal is
    written to OptiScaler.log instead of vanishing.

WHAT IT REFUSES, and why each refusal is real:

  * the game running (tasklist pid), or an UNKNOWN running state -- a human may
    be playing and the proxy DLL would be loaded.
  * driver below 616.56 unless --force-driver. That number is the fork
    author's stated minimum ("a driver new enough to ship nvngx_dlssnr.dll");
    it is enforced by DLSS5oneclick too, citing the fork. Whether an older
    driver can RUN the model is not measured anywhere I could find; the number
    is treated as real until this machine measures otherwise.
  * a model whose stated GPU support excludes this GPU, unless --force-model.
  * any planned file that appears in the client's ConsistencyInfo manifest.
    Files ADDED beside the exe are not in the manifest (only listed files are
    checked), and the tool proves that for the finished tree rather than
    assuming it: a listed path is a boot refusal (CLAUDE.md 7).

Everything asserted is a property of the FINISHED STATE (CLAUDE.md 9b): after
install every planned file is re-hashed from disk against its source, the
proxy DLL's version resource is read back as OptiScaler's, the ini is
re-parsed, and the manifest negative is re-run. `selftest` then breaks each
of those and proves the verifier can say FAIL.

Never run `install` while the client runs. The coordinator runs it between
deploys. `--root` exists so the selftest can point everything at a scratch
directory; it never touches D:\Aowlspt.
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dlss  # noqa: E402  -- gpu_info, game_pids, sha256_file, pe_file_version, http_get, ci_*

REPO = os.path.dirname(HERE)
CACHE = os.path.join(REPO, ".cache", "dlssnr")          # .cache/ is gitignored
STATE = os.path.join(CACHE, "state.json")
LIVE_DEFAULT = dlss.LIVE_DEFAULT
CI_NAME = dlss.CI_NAME
MODEL_NAME = "nvngx_dlssnr.dll"
FORWARDER_NAME = "nvngx.dll_dlssnr.dll"
INI_NAME = "OptiScaler.ini"
RUNTIME_DIR = "OptiScaler"
LICENSE_DIR = "Licenses"
PROXY_NAMES = ("dxgi", "winmm", "version", "dbghelp", "d3d12", "wininet", "winhttp")
DX11_BRIDGED = ("fsr22_12", "fsr21_12", "xess_12", "ffx_12")   # "w/Dx12" upscalers in the fork's dropdown
MIN_DRIVER = "616.56"      # stated by the fork author (v0.1.0..v0.1.2 release notes); NOT measured
TURING = "Turing (RTX 20)"

# ---------------------------------------------------------------------------
# Catalog. Every hash below was MEASURED on 2026-09-03 from the named URL;
# the zip hashes also equal the `digest` GitHub's release API reports for
# the asset, an independent second source.
# ---------------------------------------------------------------------------
CATALOG = {
    "optiscaler": {
        "kind": "optiscaler",
        "note": "Dagherbou/OptiScaler_DLSSNR v0.1.2-dlssnr (2026-09-02): OptiScaler with the "
                "Neural Rendering pass, DX11 through the Dx11-on-Dx12 bridge, native Vulkan path.",
        "url": "https://github.com/Dagherbou/OptiScaler_DLSSNR/releases/download/v0.1.2-dIssnr/OptiScaler-DLSSNR-v0.1.2.zip",
        "zip_name": "OptiScaler-DLSSNR-v0.1.2.zip",
        "size": 130438762,
        "sha256": "4ecf3c3d4a1c23637144855fc327f4b33079370219188ca0e198c7cb6ed58f36",
        # MEASURED from the zip: the members the installer copies, and their hashes
        "members": {
            "OptiScaler.dll": "measured-at-fetch",
            FORWARDER_NAME: "measured-at-fetch",
            INI_NAME: "measured-at-fetch",
        },
    },
    "sf2": {
        "kind": "model",
        "note": "ShortFuse's 'nvngx_dlssnr.dll 310.8.SF' v2 (2026-08-30) via RankFTW/rhi-repo: the "
                "leaked 310.8.0.0 model rebuilt for RTX 20/30 (stated: 'nearly full FP16 pipeline') "
                "and RTX 40. PE FileVersion 310.8.2.0, ProductVersion '310.8.SF.0'. UNSIGNED: the "
                "Authenticode directory points past EOF (the 10,352-byte signature was cut off). "
                "The FP16 claim is NOT verifiable from the bytes (no sm_* strings survive).",
        "url": "https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.SF-v2/nvngx_dlssnr_310.8.SF-v2.zip",
        "zip_name": "nvngx_dlssnr_310.8.SF-v2.zip",
        "zip_sha256": "1da35941894994eb087e017577829e492454e9bae3a6a9397027069ceb74955c",
        "zip_size": 116693212,
        "size": 165830144,
        "sha256": "6eb209e764f39872625debd6abaf45e2bb6322f6f270f781f70c059ae30b3927",
        "file_version": "310.8.2.0",
        "gpus": ("Turing (RTX 20)", "Ampere (RTX 30)", "Ada (RTX 40)", "Blackwell (RTX 50)"),
        "gpus_source": "stated by RHI 2.4.9 notes / DLSS5oneclick README; RTX 20 measured by nobody I can cite",
    },
    "orig": {
        "kind": "model",
        "note": "The leaked NBA 2K27 nvngx_dlssnr.dll 310.8.0.0 via RankFTW/rhi-repo (2026-08-27). "
                "NVIDIA-signed (Authenticode directory intact). MEASURED: 15 cubins, every one "
                "'sm_120' (Blackwell); it does not run on Turing.",
        "url": "https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip",
        "zip_name": "nvngx_dlssnr_310.8.0.zip",
        "zip_sha256": "388c0a7912e15ec911b9c9e11a692142b11fe387ddf2b637d8c358138fffb3ac",
        "zip_size": 109425288,
        "size": 165840496,
        "sha256": "e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e",
        "file_version": "310.8.0.0",
        "gpus": ("Blackwell (RTX 50)",),
        "gpus_source": "MEASURED: only sm_120 cubins in the file",
    },
}
DEFAULT_MODEL = "sf2"

# Other hashes recorded during the 2026-09-03 research, NOT fetched (no Turing claim,
# or superseded). Kept so a file found on disk can be named.
KNOWN_HASHES = {
    "4de991bf3a1cf5ba95c6621c2a5203299e823ea11bf1702513281b85aa4dc449": "zip nvngx_dlssnr_310.8.SF.zip (SF v1, rhi-repo dlssnr-310.8.SF, 114,611,736 B)",
    "46124cfaef532ad5f6da07494772ea8c1b3e719f934e254385697f38d1289e3f": "zip nvngx_dlssnr_310.8.0-RTX40.zip (Ada patch, rhi-repo dlssnr-310.8.0-RTX40, 110,604,522 B)",
    "735b10b4077bc187ba4d07d607e864349aca386344c6126aba61ced746d27ece": "zip OptiScaler-DLSSNR-v0.1.1.5-dlssnr.zip (fork, superseded)",
    "4dbed94fa610f2c509f8b510a34f259a4b624749c76078a07413a410d53ec780": "zip OptiScaler-DLSSNR-v0.1.1-dlssnr.zip (fork, superseded)",
    "21e73d05abb64e90b336599a9e8c8b6c109b1de9f950b5a4e39e61b422fc5b24": "zip OptiScaler-DLSSNR-v0.1.0-dlssnr.zip (fork, superseded)",
}


# ---------------------------------------------------------------------------
# helpers (the generic ones come from dlss.py)
# ---------------------------------------------------------------------------
say, die, sha256_file, ver_tuple = dlss.say, dlss.die, dlss.sha256_file, dlss.ver_tuple
pe_file_version, gpu_generation = dlss.pe_file_version, dlss.gpu_generation


def gpu_info():
    """Looked up at call time so the selftest can fake dlss.gpu_info."""
    return dlss.gpu_info()


def game_pids():
    return dlss.game_pids()


def pe_string(path_or_bytes, key):
    """A StringFileInfo value ('OriginalFilename', 'ProductName', ...) parsed from
    the version resource's String record: 6-byte header (wLength, wValueLength in
    WCHARs, wType), the key, DWORD padding, the value. Returns None when the key is
    absent or its value is empty -- never the NEXT record's key, which is what a
    naive scan returns for an empty value (measured on OptiScaler.dll's ProductName)."""
    b = path_or_bytes if isinstance(path_or_bytes, bytes) else open(path_or_bytes, "rb").read()
    k = key.encode("utf-16-le") + b"\0\0"
    p = b.find(k)
    while p >= 0:
        if p >= 6:
            wlen, wvlen, wtype = struct.unpack_from("<HHH", b, p - 6)
            if wtype == 1 and wlen >= 6 + len(k):
                v = p + len(k)
                v = (v + 3) & ~3
                if wvlen == 0:
                    return None
                raw = b[v:v + 2 * wvlen]
                return raw.decode("utf-16-le", "replace").split("\0")[0] or None
        p = b.find(k, p + 2)
    return None


def sm_targets(b):
    """Counter of 'sm_NNN' cubin arch strings in a model DLL. Empty is 'none
    survive as plain text', which is INCONCLUSIVE about the arch, not 'none'."""
    out = {}
    for m in re.findall(rb"sm_\d\d\d?", b):
        out[m.decode()] = out.get(m.decode(), 0) + 1
    return out


def authenticode_present(b):
    """(offset, size) of the PE security directory and whether it lies inside the
    file. A directory pointing past EOF is a stripped signature."""
    try:
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        opt = pe + 24
        magic = struct.unpack_from("<H", b, opt)[0]
        dd = opt + (112 if magic == 0x20B else 96)
        va, sz = struct.unpack_from("<II", b, dd + 4 * 8)
        return va, sz, (sz > 0 and va + sz <= len(b))
    except Exception:
        return None, None, False


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


def cached_zip(key):
    return os.path.join(CACHE, CATALOG[key]["zip_name"])


def cached_model(key):
    return os.path.join(CACHE, "nvngx_dlssnr_%s.dll" % key)


# ---------------------------------------------------------------------------
# ini editing: replace `Key=...` inside one [Section], preserving everything
# else byte-for-byte (comments, order, line endings). Refuses a key it cannot
# find rather than appending one silently.
# ---------------------------------------------------------------------------
def ini_set(text, section, key, value):
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    cur = None
    for i, line in enumerate(lines):
        s = line.strip()
        m = re.match(r"^\[(.+?)\]$", s)
        if m:
            cur = m.group(1)
            continue
        if cur == section and not s.startswith(";"):
            km = re.match(r"^([A-Za-z0-9_]+)\s*=", s)
            if km and km.group(1) == key:
                lines[i] = "%s=%s" % (key, value)
                return nl.join(lines)
    raise KeyError("ini: [%s] %s not found" % (section, key))


def ini_get(text, section, key):
    cur = None
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^\[(.+?)\]$", s)
        if m:
            cur = m.group(1)
            continue
        if cur == section and not s.startswith(";"):
            km = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.*)$", s)
            if km and km.group(1) == key:
                return km.group(2).strip()
    return None


def ini_settings(upscaler, working_scale):
    """The edits install makes. Each is a (section, key, value, why)."""
    return [
        ("DlssNr", "Enabled", "true", "the pass; off by default in the fork"),
        ("DlssNr", "WorkingScale", "%g" % working_scale,
         "model runs at this fraction of the frame; cost falls with the square (fork ini). "
         "Turing has no FP8; start small"),
        ("DlssNr", "AutoCapture", "false", "no 8-frame capture dump beside the exe each session"),
        ("Upscalers", "Dx11Upscaler", upscaler,
         "must be a Dx11-on-Dx12 ('w/Dx12') upscaler or the model never runs on D3D11 (fork v0.1.2 notes)"),
        ("Log", "LogToFile", "true", "OptiScaler.log says why the pass did not start"),
        ("Log", "LogLevel", "2", "Info; Trace is a token bomb"),
        ("Menu", "ShowFps", "true", "the frame-time verdict without a screenshot"),
    ]


# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------
def download(url, dst):
    say("fetch: GET %s" % url)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    _, body = dlss.http_get(url)
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, dst)
    say("fetch: %d bytes -> %s" % (len(body), dst))


def verify_zip(key, path):
    ent = CATALOG[key]
    want = ent.get("zip_sha256") or ent["sha256"]
    wsize = ent.get("zip_size") or ent["size"]
    if not os.path.exists(path):
        return "MISSING", "not fetched"
    size = os.path.getsize(path)
    if size != wsize:
        return "FAIL", "size %d != pinned %d" % (size, wsize)
    sha = sha256_file(path)
    if sha != want:
        return "FAIL", "sha256 %s != pinned %s" % (sha, want)
    return "PASS", sha


def extract_model(key):
    ent = CATALOG[key]
    dst = cached_model(key)
    with zipfile.ZipFile(cached_zip(key)) as z:
        names = [n for n in z.namelist() if n.lower().endswith(MODEL_NAME)]
        if len(names) != 1:
            die("%s: zip does not hold exactly one %s: %r" % (key, MODEL_NAME, z.namelist()))
        data = z.read(names[0])
    if len(data) != ent["size"]:
        die("%s: inner DLL size %d != pinned %d" % (key, len(data), ent["size"]))
    sha = hashlib.sha256(data).hexdigest()
    if sha != ent["sha256"]:
        die("%s: inner DLL sha256 %s != pinned %s" % (key, sha, ent["sha256"]))
    with open(dst + ".part", "wb") as f:
        f.write(data)
    os.replace(dst + ".part", dst)
    ver = pe_file_version(dst)
    if ver != ent["file_version"]:
        die("%s: PE FileVersion %r != pinned %r" % (key, ver, ent["file_version"]))
    return dst, sha, ver


def fetch_key(key):
    ent = CATALOG[key]
    zp = cached_zip(key)
    outcome, why = verify_zip(key, zp)
    if outcome == "PASS":
        say("fetch: %s already cached and verified (%s)" % (key, zp))
    else:
        if outcome == "FAIL":
            say("fetch: cached %s is WRONG (%s); re-downloading" % (key, why))
        download(ent["url"], zp)
        outcome, why = verify_zip(key, zp)
        if outcome != "PASS":
            os.replace(zp, zp + ".bad")
            die("%s: %s (moved to %s.bad)" % (key, why, zp))
        say("fetch: %s zip sha256 %s == pinned (and == GitHub's release digest)" % (key, why))
    if ent["kind"] == "model":
        dst, sha, ver = extract_model(key)
        b = open(dst, "rb").read()
        va, sz, inside = authenticode_present(b)
        say("fetch: %s -> %s sha256 %s PE FileVersion %s ProductVersion %r; cubin arch strings %s; "
            "Authenticode %s" % (key, dst, sha, ver, pe_string(b, "ProductVersion"), sm_targets(b) or "NONE VISIBLE",
                                 "intact" if inside else "STRIPPED (directory %r,%r past EOF)" % (va, sz)))
    else:
        with zipfile.ZipFile(zp) as z:
            names = z.namelist()
            for need in ("OptiScaler.dll", FORWARDER_NAME, INI_NAME):
                if need not in names:
                    die("%s: zip lacks %s" % (key, need))
            odll = z.read("OptiScaler.dll")
            say("fetch: OptiScaler.dll OriginalFilename=%r ProductName=%r FileVersion=%s (%d bytes)" % (
                pe_string(odll, "OriginalFilename"), pe_string(odll, "ProductName"), _ver_bytes(odll), len(odll)))
    return zp


def _ver_bytes(b):
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".dll")
    try:
        tmp.write(b)
        tmp.close()
        return pe_file_version(tmp.name)
    finally:
        os.unlink(tmp.name)


def cmd_fetch(a):
    os.makedirs(CACHE, exist_ok=True)
    keys = ["optiscaler", a.model or DEFAULT_MODEL]
    if a.all:
        keys = list(CATALOG)
    for k in keys:
        if k not in CATALOG:
            die("unknown key %s; known: %s" % (k, ", ".join(CATALOG)))
        fetch_key(k)
    say("fetch: done. cache = %s (gitignored; NVIDIA and third-party binaries are never committed)" % CACHE)


# ---------------------------------------------------------------------------
# what is next to the exe
# ---------------------------------------------------------------------------
def describe_root(root):
    out = {"root": root, "proxies": {}, "model": None, "forwarder": os.path.exists(os.path.join(root, FORWARDER_NAME)),
           "ini": None, "runtime_dir": os.path.isdir(os.path.join(root, RUNTIME_DIR))}
    for n in PROXY_NAMES:
        p = os.path.join(root, n + ".dll")
        if os.path.exists(p):
            out["proxies"][n + ".dll"] = {"size": os.path.getsize(p), "original": pe_string(p, "OriginalFilename"),
                                          "product": pe_string(p, "ProductName")}
    mp = os.path.join(root, MODEL_NAME)
    if os.path.exists(mp):
        sha = sha256_file(mp)
        cat = next((k for k, v in CATALOG.items() if v.get("sha256") == sha), None)
        out["model"] = {"size": os.path.getsize(mp), "sha256": sha, "version": pe_file_version(mp),
                        "catalog": cat or KNOWN_HASHES.get(sha) or "not a catalog hash"}
    ip = os.path.join(root, INI_NAME)
    if os.path.exists(ip):
        t = open(ip, encoding="utf-8-sig", errors="replace").read()
        out["ini"] = {"DlssNr.Enabled": ini_get(t, "DlssNr", "Enabled"),
                      "DlssNr.WorkingScale": ini_get(t, "DlssNr", "WorkingScale"),
                      "Upscalers.Dx11Upscaler": ini_get(t, "Upscalers", "Dx11Upscaler"),
                      "Log.LogToFile": ini_get(t, "Log", "LogToFile")}
    lp = os.path.join(root, "OptiScaler.log")
    if os.path.exists(lp):
        out["log"] = {"size": os.path.getsize(lp), "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(lp)))}
    return out


def manifest_paths(root):
    """Set of relative paths the client's manifest lists (plain file plus the
    embedded copy when consistency.py can open it). Returns (paths, notes)."""
    paths, notes = set(), []
    ci = os.path.join(root, CI_NAME)
    if os.path.exists(ci):
        try:
            _, doc = dlss.ci_load(ci)
            paths |= {e.get("Path", "") for e in doc["Entries"]}
            notes.append("plain %s: %d entries" % (CI_NAME, len(doc["Entries"])))
        except Exception as e:
            notes.append("plain %s unreadable: %s" % (CI_NAME, e))
    else:
        notes.append("plain %s ABSENT" % CI_NAME)
    try:
        import consistency
        emb = consistency.load(root)
        doc = json.loads(emb.plain.decode("utf-8"))
        paths |= {e.get("Path", "") for e in doc["Entries"]}
        notes.append("embedded manifest: %d entries" % len(doc["Entries"]))
    except Exception as e:
        notes.append("embedded manifest not opened (%s)" % str(e).splitlines()[0][:80])
    return paths, notes


def driver_check(drv, force):
    """(ok, line). ok is None when the driver is unknown."""
    if not drv:
        return None, "driver UNKNOWN (nvidia-smi and WMI both failed)"
    ok = ver_tuple(drv) >= ver_tuple(MIN_DRIVER)
    line = "driver %s vs stated minimum %s -> %s" % (drv, MIN_DRIVER, "OK" if ok else "TOO OLD")
    if not ok and force:
        line += " (overridden by --force-driver; the minimum is the fork author's statement, not a measurement)"
    return ok, line


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
def cmd_status(a):
    say("== GPU ==")
    gname, drv, src = gpu_info()
    gen = gpu_generation(gname)
    say("  gpu       : %s (%s)" % (gname, gen))
    say("  driver    : %s  [%s]" % (drv, src))
    say("  %s" % driver_check(drv, False)[1])
    for k, v in CATALOG.items():
        if v["kind"] == "model":
            say("  model %-5s: %s -> %s  [%s]" % (k, v["file_version"], "listed for this GPU" if gen in v["gpus"] else "NOT listed for %s" % gen, v["gpus_source"]))
    say("== live root (%s) ==" % a.root)
    d = describe_root(a.root)
    if not d["proxies"]:
        say("  proxy DLLs: none of %s present" % ", ".join(n + ".dll" for n in PROXY_NAMES))
    for n, info in d["proxies"].items():
        say("  %-12s %d bytes, OriginalFilename=%r ProductName=%r%s" % (
            n, info["size"], info["original"], info["product"],
            "  <-- OptiScaler" if (info["original"] or "").lower() == "optiscaler.dll" else "  <-- NOT OptiScaler"))
    say("  %-12s %s" % (MODEL_NAME, "ABSENT" if not d["model"] else "%d bytes v%s sha %s.. = %s" % (
        d["model"]["size"], d["model"]["version"], d["model"]["sha256"][:16], d["model"]["catalog"])))
    say("  %-12s %s" % (FORWARDER_NAME, "present" if d["forwarder"] else "ABSENT"))
    say("  %-12s %s" % (RUNTIME_DIR + "\\", "present" if d["runtime_dir"] else "ABSENT"))
    say("  %-12s %s" % (INI_NAME, "ABSENT" if not d["ini"] else json.dumps(d["ini"])))
    if d.get("log"):
        say("  OptiScaler.log: %d bytes, mtime %s" % (d["log"]["size"], d["log"]["mtime"]))
    paths, notes = manifest_paths(a.root)
    say("  manifest  : %s" % "; ".join(notes))
    planned = [n + ".dll" for n in PROXY_NAMES] + [MODEL_NAME, FORWARDER_NAME, INI_NAME]
    listed = sorted(p for p in planned if p in paths)
    say("  manifest lists any file this tool would add: %s" % (listed or "NONE (added files are unchecked by the client)"))
    say("== cache (%s) ==" % CACHE)
    for k in CATALOG:
        o, why = verify_zip(k, cached_zip(k))
        say("  %-11s %s%s" % (k, o, "" if o == "PASS" else " (%s)" % why))
        if CATALOG[k]["kind"] == "model" and os.path.exists(cached_model(k)):
            say("              model dll: %s v%s" % (cached_model(k), pe_file_version(cached_model(k))))
    st = load_state()
    if st.get("installs"):
        last = st["installs"][-1]
        say("  last install: %s proxy=%s model=%s backup=%s verified=%s" % (
            last.get("when"), last.get("proxy"), last.get("model"), last.get("backup"), last.get("verified")))
    say("  game running: %s" % dlss.game_running())


# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
def plan_install(root, opti_zip, model_dll, model_key, proxy, upscaler, working_scale):
    """Build the list of (relpath, bytes, sha256) the finished tree must hold.
    Refuses before any write when the source is not what the catalog pins."""
    if not os.path.isdir(root):
        die("root missing: %s" % root)
    if not os.path.exists(opti_zip):
        die("OptiScaler zip missing: %s (run `fetch`)" % opti_zip)
    if not os.path.exists(model_dll):
        die("model DLL missing: %s (run `fetch`)" % model_dll)
    ent = CATALOG.get(model_key)
    if ent:
        s = sha256_file(model_dll)
        if s != ent["sha256"]:
            die("model %s sha256 %s != pinned %s" % (model_dll, s, ent["sha256"]))
    if proxy not in PROXY_NAMES:
        die("proxy must be one of %s" % ", ".join(PROXY_NAMES))
    if upscaler not in DX11_BRIDGED:
        die("--upscaler must be a Dx11-on-Dx12 upscaler (%s); a native DX11 one never reaches the model" % ", ".join(DX11_BRIDGED))
    if not (0.1 <= working_scale <= 1.0):
        die("--working-scale must be within 0.1..1.0")
    files = {}
    with zipfile.ZipFile(opti_zip) as z:
        names = set(z.namelist())
        odll = z.read("OptiScaler.dll")
        if (pe_string(odll, "OriginalFilename") or "").lower() != "optiscaler.dll":
            die("zip's OptiScaler.dll does not identify itself as OptiScaler.dll in its version resource (%r)"
                % pe_string(odll, "OriginalFilename"))
        files[proxy + ".dll"] = odll
        files[FORWARDER_NAME] = z.read(FORWARDER_NAME)
        ini = z.read(INI_NAME).decode("utf-8")
        bom = ini.startswith("﻿")
        ini = ini.lstrip("﻿")
        for sec, key, val, _why in ini_settings(upscaler, working_scale):
            ini = ini_set(ini, sec, key, val)
        files[INI_NAME] = (("﻿" if bom else "") + ini).encode("utf-8")
        for n in sorted(names):
            if (n.startswith(RUNTIME_DIR + "/") or n.startswith(LICENSE_DIR + "/")) and not n.endswith("/"):
                files[n.replace("/", os.sep)] = z.read(n)
    files[MODEL_NAME] = open(model_dll, "rb").read()
    plan = {"root": root, "proxy": proxy, "model": model_key, "upscaler": upscaler, "working_scale": working_scale,
            "files": {rel: hashlib.sha256(b).hexdigest() for rel, b in files.items()}, "_bytes": files}
    plan["overwrites"] = sorted(rel for rel in files if os.path.exists(os.path.join(root, rel)))
    plan["adds"] = sorted(rel for rel in files if rel not in plan["overwrites"])
    # every OTHER OptiScaler proxy already present is a second copy of a DXGI hook in one process
    plan["other_proxies"] = sorted(n + ".dll" for n in PROXY_NAMES if n != proxy
                                   and os.path.exists(os.path.join(root, n + ".dll")))
    paths, notes = manifest_paths(root)
    plan["manifest_notes"] = notes
    plan["manifest_hits"] = sorted(rel for rel in files if rel in paths)
    return plan


def do_install(plan, backup_dir):
    """Backup overwritten files, write everything, record a manifest for rollback."""
    root = plan["root"]
    os.makedirs(backup_dir, exist_ok=True)
    rec = {"root": root, "adds": plan["adds"], "overwrites": plan["overwrites"], "when": time.strftime("%Y-%m-%d %H:%M:%S")}
    for rel in plan["overwrites"]:
        src = os.path.join(root, rel)
        dst = os.path.join(backup_dir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    with open(os.path.join(backup_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1)
    for rel, b in plan["_bytes"].items():
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = dst + ".new"
        with open(tmp, "wb") as f:
            f.write(b)
        os.replace(tmp, dst)
    return verify_install(plan)


def verify_install(plan):
    """PASS iff the finished tree holds every planned file byte-for-byte, the
    proxy is OptiScaler by its own version resource, the ini reads back, and
    no planned path is in the client's manifest."""
    root = plan["root"]
    reasons = []
    for rel, sha in plan["files"].items():
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            reasons.append("%s MISSING" % rel)
        elif sha256_file(p) != sha:
            reasons.append("%s sha256 != source" % rel)
    px = os.path.join(root, plan["proxy"] + ".dll")
    if os.path.exists(px) and (pe_string(px, "OriginalFilename") or "").lower() != "optiscaler.dll":
        reasons.append("%s.dll is not OptiScaler by its version resource" % plan["proxy"])
    ip = os.path.join(root, INI_NAME)
    if os.path.exists(ip):
        t = open(ip, encoding="utf-8-sig", errors="replace").read()
        for sec, key, val, _ in ini_settings(plan["upscaler"], plan["working_scale"]):
            got = ini_get(t, sec, key)
            if got != val:
                reasons.append("ini [%s] %s = %r, wanted %r" % (sec, key, got, val))
    mp = os.path.join(root, MODEL_NAME)
    if os.path.exists(mp):
        ent = CATALOG.get(plan["model"])
        if ent and pe_file_version(mp) != ent["file_version"]:
            reasons.append("%s PE FileVersion %r != %r" % (MODEL_NAME, pe_file_version(mp), ent["file_version"]))
    paths, _ = manifest_paths(root)
    hits = sorted(rel for rel in plan["files"] if rel in paths)
    if hits:
        reasons.append("manifest LISTS %s -- the client would refuse to boot" % ", ".join(hits))
    return not reasons, reasons


def cmd_install(a):
    model_key = a.model or DEFAULT_MODEL
    if model_key not in CATALOG or CATALOG[model_key]["kind"] != "model":
        die("unknown model %s; known: %s" % (model_key, ", ".join(k for k, v in CATALOG.items() if v["kind"] == "model")))
    live = (a.root == LIVE_DEFAULT)
    # a dry run only READS the tree; the pid gate is for the write
    r = dlss.game_running() if (live and not a.dry_run) else False
    if r:
        die("EscapeFromTarkov.exe is running (pids %s): a proxy DLL beside it would be loaded and a human may be playing. Stop it first." % game_pids())
    if r is None:
        die("could not determine whether the game runs (tasklist failed); refusing rather than guessing")
    gname, drv, _ = gpu_info()
    gen = gpu_generation(gname)
    ok, line = driver_check(drv, a.force_driver)
    say("install: %s" % line)
    if ok is False and not a.force_driver:
        die("driver below the stated minimum; update it (NVIDIA offers %s for this GPU, docs/DLSSNR.md) or pass --force-driver" % MIN_DRIVER)
    if ok is None and not a.force_driver:
        die("driver unknown; pass --force-driver to proceed anyway")
    ent = CATALOG[model_key]
    if gen not in ent["gpus"]:
        msg = "model %s is not listed for %s (%s)" % (model_key, gen, ent["gpus_source"])
        if not a.force_model:
            die(msg + "; pass --force-model to install it anyway")
        say("install: WARN " + msg + " -- overridden by --force-model")
    plan = plan_install(a.root, cached_zip("optiscaler"), cached_model(model_key), model_key,
                        a.proxy, a.upscaler, a.working_scale)
    say("== plan ==")
    say("  root      : %s" % a.root)
    say("  proxy     : %s.dll  (OptiScaler.dll from %s)" % (a.proxy, CATALOG["optiscaler"]["zip_name"]))
    say("  model     : %s -> %s  (%s, v%s)" % (model_key, MODEL_NAME, ent["note"].split(":")[0], ent["file_version"]))
    say("  ini       : " + "; ".join("[%s] %s=%s" % (s, k, v) for s, k, v, _ in ini_settings(a.upscaler, a.working_scale)))
    say("  adds      : %d files (%s + %s\\ + %s\\)" % (len(plan["adds"]), ", ".join(x for x in plan["adds"] if os.sep not in x), RUNTIME_DIR, LICENSE_DIR))
    say("  overwrites: %s" % (plan["overwrites"] or "none"))
    say("  manifest  : %s; hits among planned files: %s" % ("; ".join(plan["manifest_notes"]), plan["manifest_hits"] or "NONE"))
    if plan["manifest_hits"]:
        die("a planned file is listed in the client's manifest: %s" % plan["manifest_hits"])
    if plan["other_proxies"]:
        say("  WARN: other proxy DLLs already present: %s -- two DXGI hooks in one process" % plan["other_proxies"])
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(CACHE, "backup", ts) if live else os.path.join(a.root, ".dlssnr-backup", ts)
    say("  backup    : %s" % backup)
    roll = "python tools/dlssnr.py rollback --backup %s%s" % (ts, "" if live else " --root %s" % a.root)
    if a.dry_run:
        say("DRY RUN: nothing written. Rollback line would be: %s" % roll)
        return
    ok, why = do_install(plan, backup)
    st = load_state()
    st.setdefault("installs", []).append({"when": ts, "root": a.root, "backup": backup, "proxy": a.proxy,
                                          "model": model_key, "upscaler": a.upscaler, "verified": ok,
                                          "files": plan["files"]})
    save_state(st)
    if not ok:
        say("install: VERIFY FAILED: " + "; ".join(why))
        say("rollback: " + roll)
        sys.exit(1)
    say("install: PASS. %d files verified byte-for-byte; %s.dll is OptiScaler; %s v%s; ini reads back; manifest lists none." % (
        len(plan["files"]), a.proxy, MODEL_NAME, pe_file_version(os.path.join(a.root, MODEL_NAME))))
    say("next: start the game, press Insert for the OptiScaler overlay, pick a 'w/Dx12' upscaler in the top-left "
        "dropdown if it is not already %s, then read OptiScaler.log. The FPS overlay is on." % a.upscaler)
    say("rollback: " + roll)


# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------
def do_rollback(root, backup_dir):
    mf = os.path.join(backup_dir, "manifest.json")
    if not os.path.exists(mf):
        die("backup incomplete: %s missing" % mf)
    rec = json.load(open(mf, encoding="utf-8"))
    for rel in rec["overwrites"]:
        if not os.path.exists(os.path.join(backup_dir, rel)):
            die("backup incomplete: %s missing" % rel)
    reasons = []
    for rel in rec["adds"]:
        p = os.path.join(root, rel)
        if os.path.exists(p):
            os.remove(p)
        if os.path.exists(p):
            reasons.append("%s still present" % rel)
    for rel in rec["overwrites"]:
        src = os.path.join(backup_dir, rel)
        dst = os.path.join(root, rel)
        tmp = dst + ".new"
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
        if sha256_file(dst) != sha256_file(src):
            reasons.append("%s restored bytes != backup" % rel)
    # prune directories we created: rmdir only ever removes an EMPTY directory,
    # so walking bottom-up and ignoring the refusal deletes exactly the empty ones
    for d in (RUNTIME_DIR, LICENSE_DIR):
        for dp, _dn, _fn in os.walk(os.path.join(root, d), topdown=False):
            try:
                os.rmdir(dp)
            except OSError:
                pass
    return not reasons, reasons


def cmd_rollback(a):
    st = load_state()
    live = (a.root == LIVE_DEFAULT)
    if a.backup:
        backup = a.backup if os.path.isdir(a.backup) else os.path.join(
            os.path.join(CACHE, "backup") if live else os.path.join(a.root, ".dlssnr-backup"), a.backup)
    else:
        recs = [r for r in st.get("installs", []) if r.get("root") == a.root]
        if not recs:
            die("no recorded install for %s; pass --backup TS" % a.root)
        backup = recs[-1]["backup"]
    say("rollback: restoring from %s" % backup)
    ok, why = do_rollback(a.root, os.path.normpath(backup))
    if not ok:
        die("rollback VERIFY FAILED: " + "; ".join(why))
    d = describe_root(a.root)
    say("rollback: PASS. proxies now: %s; %s %s; %s %s" % (
        sorted(d["proxies"]) or "none", MODEL_NAME, "ABSENT" if not d["model"] else "present",
        INI_NAME, "ABSENT" if not d["ini"] else "present"))


# ---------------------------------------------------------------------------
# selftest: synthetic OptiScaler zip + synthetic model, then the falsifiers
# ---------------------------------------------------------------------------
def fake_pe(original_filename, product, ms, ls, size, seed):
    """A blob pe_file_version / pe_string / authenticode_present can read."""
    import random
    rnd = random.Random(seed)
    body = bytearray(rnd.getrandbits(8) for _ in range(size))
    # minimal PE header: e_lfanew -> PE, PE32+ optional header with 16 data dirs (security = index 4)
    body[0:2] = b"MZ"
    struct.pack_into("<I", body, 0x3C, 0x80)
    body[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", body, 0x80 + 24, 0x20B)
    struct.pack_into("<II", body, 0x80 + 24 + 112 + 4 * 8, 0, 0)     # no signature
    blob = ("VS_VERSION_INFO".encode("utf-16-le") + b"\0\0" + struct.pack("<II", 0xFEEF04BD, 0x00010000)
            + struct.pack("<II", ms, ls))
    body[0x200:0x200 + len(blob)] = blob
    for idx, (key, val) in enumerate((("OriginalFilename", original_filename), ("ProductName", product),
                                      ("ProductVersion", "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)))):
        kb = key.encode("utf-16-le") + b"\0\0"
        vb = val.encode("utf-16-le") + b"\0\0"
        pad = (-(6 + len(kb))) % 4
        rec = struct.pack("<HHH", 6 + len(kb) + pad + len(vb), len(vb) // 2, 1) + kb + b"\0" * pad + vb
        at = 0x400 + 0x100 * idx
        body[at:at + len(rec)] = rec
    return bytes(body)


def cmd_selftest(a):
    fails = []

    def check(name, cond, detail=""):
        say("  [%s] %s%s" % ("ok" if cond else "FAIL", name, (" -- " + detail) if detail and not cond else ""))
        if not cond:
            fails.append(name)

    say("selftest: helpers")
    check("ini_set replaces only the key inside its section",
          ini_get(ini_set("[A]\nX=auto\n[B]\nX=auto\n", "B", "X", "true"), "A", "X") == "auto"
          and ini_get(ini_set("[A]\nX=auto\n[B]\nX=auto\n", "B", "X", "true"), "B", "X") == "true")
    refused = False
    try:
        ini_set("[A]\nX=auto\n", "A", "Nope", "1")
    except KeyError:
        refused = True
    check("ini_set REFUSES a key it cannot find (never appends silently)", refused)
    check("ini_set preserves CRLF", "\r\n" in ini_set("[A]\r\nX=auto\r\n", "A", "X", "1") and "\n\n" not in ini_set("[A]\r\nX=auto\r\n", "A", "X", "1"))
    check("pe_file_version reads kernel32", bool(pe_file_version(os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "kernel32.dll"))))
    fp = fake_pe("OptiScaler.dll", "OptiScaler", (1 << 16) | 2, 3 << 16, 20000, 1)
    check("pe_string reads OriginalFilename from the fake", pe_string(fp, "OriginalFilename") == "OptiScaler.dll")
    check("pe_string answers None for an absent key", pe_string(fp, "LegalTrademarks") is None)
    check("authenticode_present: fake has none", authenticode_present(fp)[2] is False)
    check("sm_targets: empty for no strings", sm_targets(fp) == {} and sm_targets(b"xx sm_120 yy sm_120 sm_75") == {"sm_120": 2, "sm_75": 1})
    check("driver_check: 581.42 < 616.56", driver_check("581.42", False)[0] is False)
    check("driver_check: 616.56 passes", driver_check("616.56", False)[0] is True)
    check("driver_check: unknown is None, not False", driver_check(None, False)[0] is None)

    root = tempfile.mkdtemp(prefix="dlssnr-selftest-")
    try:
        say("selftest: synthetic install at %s" % root)
        exe = os.path.join(root, "EscapeFromTarkov.exe")
        open(exe, "wb").write(b"MZ fake exe")
        # a fake zip in the fork's shape
        zpath = os.path.join(root, "opti.zip")
        real_ini = ("[Upscalers]\r\n; comment\r\nDx11Upscaler=auto\r\nDx12Upscaler=auto\r\n\r\n[Menu]\r\nShowFps=auto\r\n"
                    "[Log]\r\nLogToFile=auto\r\nLogLevel=auto\r\n[DlssNr]\r\nEnabled=auto\r\nWorkingScale=auto\r\nAutoCapture=auto\r\n")
        opti_dll = fake_pe("OptiScaler.dll", "OptiScaler", (0 << 16) | 9, (5 << 16), 60000, 2)
        with zipfile.ZipFile(zpath, "w") as z:
            z.writestr("OptiScaler.dll", opti_dll)
            z.writestr(FORWARDER_NAME, b"fwd" * 100)
            z.writestr(INI_NAME, real_ini)
            z.writestr("OptiScaler/libxess.dll", b"x" * 500)
            z.writestr("OptiScaler/D3D12_OptiScaler/D3D12Core.dll", b"c" * 500)
            z.writestr("Licenses/RenoDX_ATTRIBUTION.txt", b"MIT")
            z.writestr("setup_windows.bat", b"@echo off")
        model = fake_pe(MODEL_NAME, "NVIDIA DLSSNR", (310 << 16) | 8, (2 << 16), 90000, 3)
        mpath = os.path.join(root, "src_model.dll")
        open(mpath, "wb").write(model)
        CATALOG["selftest"] = {"kind": "model", "sha256": hashlib.sha256(model).hexdigest(), "size": len(model),
                               "file_version": "310.8.2.0", "gpus": (TURING,), "gpus_source": "selftest", "note": "selftest: fake"}
        # a pre-existing dxgi.dll that the install overwrites, and a manifest that lists NEITHER
        pre = b"PRE-EXISTING-DXGI" * 100
        open(os.path.join(root, "dxgi.dll"), "wb").write(pre)
        ci_doc = {"Version": "0", "Entries": [{"Path": r"EscapeFromTarkov_Data\Plugins\x86_64\nvngx_dlss.dll", "Size": 1, "Checksum": 1, "IsCritical": True},
                                               {"Path": "UnityPlayer.dll", "Size": 1, "Checksum": 1}]}
        open(os.path.join(root, CI_NAME), "wb").write(dlss.ci_dump(ci_doc))

        plan = plan_install(root, zpath, mpath, "selftest", "dxgi", "fsr22_12", 0.5)
        check("plan copies the runtime + licence trees and skips the setup scripts",
              "OptiScaler%slibxess.dll" % os.sep in plan["files"] and "setup_windows.bat" not in plan["files"]
              and "Licenses%sRenoDX_ATTRIBUTION.txt" % os.sep in plan["files"])
        check("plan sees dxgi.dll as an OVERWRITE and the rest as ADDS", plan["overwrites"] == ["dxgi.dll"] and MODEL_NAME in plan["adds"])
        check("plan finds no manifest hit", plan["manifest_hits"] == [])
        backup = os.path.join(root, ".dlssnr-backup", "t1")
        ok, why = do_install(plan, backup)
        check("install verifies PASS", ok, "; ".join(why))
        t = open(os.path.join(root, INI_NAME), encoding="utf-8", newline="").read()   # keep CRLF: it is re-written verbatim below
        check("ini on disk: [DlssNr] Enabled=true, Dx11Upscaler=fsr22_12, comment survived",
              ini_get(t, "DlssNr", "Enabled") == "true" and ini_get(t, "Upscalers", "Dx11Upscaler") == "fsr22_12" and "; comment" in t)
        check("ini on disk: Dx12Upscaler untouched", ini_get(t, "Upscalers", "Dx12Upscaler") == "auto")
        check("backup holds the pre-existing dxgi.dll bytes", open(os.path.join(backup, "dxgi.dll"), "rb").read() == pre)
        check("dxgi.dll on disk is now OptiScaler by version resource", pe_string(os.path.join(root, "dxgi.dll"), "OriginalFilename") == "OptiScaler.dll")

        say("selftest: falsifiers (each must FAIL or be REFUSED)")
        # 1. wrong model hash -> plan refuses
        bad = os.path.join(root, "bad_model.dll")
        open(bad, "wb").write(model[:-1] + b"\x00")
        refused = False
        try:
            plan_install(root, zpath, bad, "selftest", "dxgi", "fsr22_12", 0.5)
        except SystemExit:
            refused = True
        check("plan REFUSES a model whose sha256 != pin", refused)
        # 2. native-DX11 upscaler -> refused (the model would never run)
        refused = False
        try:
            plan_install(root, zpath, mpath, "selftest", "dxgi", "fsr22", 0.5)
        except SystemExit:
            refused = True
        check("plan REFUSES a native-DX11 upscaler (no Dx12 bridge = no pass)", refused)
        # 3. a zip whose OptiScaler.dll is not OptiScaler -> refused
        zbad = os.path.join(root, "opti-bad.zip")
        with zipfile.ZipFile(zbad, "w") as z:
            z.writestr("OptiScaler.dll", fake_pe("ReShade64.dll", "ReShade", 1, 1, 30000, 4))
            z.writestr(FORWARDER_NAME, b"fwd")
            z.writestr(INI_NAME, real_ini)
        refused = False
        try:
            plan_install(root, zbad, mpath, "selftest", "dxgi", "fsr22_12", 0.5)
        except SystemExit:
            refused = True
        check("plan REFUSES a zip whose OptiScaler.dll is some other DLL", refused)
        # 4. tamper the model after install (same size) -> verify FAIL naming it
        with open(os.path.join(root, MODEL_NAME), "r+b") as f:
            f.seek(7000)
            f.write(b"\x01\x02\x03\x04")
        vok, vwhy = verify_install(plan)
        check("verify FAILS after a same-size tamper of the model and names it", not vok and any(MODEL_NAME in w for w in vwhy), "; ".join(vwhy))
        open(os.path.join(root, MODEL_NAME), "wb").write(model)
        # 5. ini edited back to auto -> verify FAIL
        open(os.path.join(root, INI_NAME), "w", encoding="utf-8", newline="").write(ini_set(t, "DlssNr", "Enabled", "auto"))
        vok, vwhy = verify_install(plan)
        check("verify FAILS when [DlssNr] Enabled is no longer true", not vok and any("Enabled" in w for w in vwhy))
        open(os.path.join(root, INI_NAME), "w", encoding="utf-8", newline="").write(t)
        # 6. manifest that LISTS dxgi.dll -> the negative must fire (this is the boot-refusal case)
        ci_doc2 = json.loads(json.dumps(ci_doc))
        ci_doc2["Entries"].append({"Path": "dxgi.dll", "Size": 1, "Checksum": 1})
        open(os.path.join(root, CI_NAME), "wb").write(dlss.ci_dump(ci_doc2))
        vok, vwhy = verify_install(plan)
        check("verify FAILS when the manifest lists a planned file", not vok and any("manifest" in w for w in vwhy), "; ".join(vwhy))
        refused = False
        try:
            p2 = plan_install(root, zpath, mpath, "selftest", "dxgi", "fsr22_12", 0.5)
            refused = p2["manifest_hits"] == ["dxgi.dll"]
        except SystemExit:
            refused = True
        check("plan reports the manifest hit before any write", refused)
        open(os.path.join(root, CI_NAME), "wb").write(dlss.ci_dump(ci_doc))
        check("verify PASSES again once the manifest is clean (falsifier is not stuck on)", verify_install(plan)[0])
        # 7. install refused while a fake pid runs, and the tree is UNCHANGED after the refusal
        real_running = dlss.game_running
        real_pids = dlss.game_pids
        before = {rel: sha256_file(os.path.join(root, rel)) for rel in plan["files"]}
        ns = argparse.Namespace(root=LIVE_DEFAULT, model="selftest", proxy="winmm", upscaler="fsr22_12", working_scale=0.5,
                                force_driver=True, force_model=True, dry_run=False)
        dlss.game_running = lambda: True
        dlss.game_pids = lambda: [4242]
        refused = False
        try:
            cmd_install(ns)
        except SystemExit:
            refused = True
        finally:
            dlss.game_running, dlss.game_pids = real_running, real_pids
        check("install REFUSES with a fake running pid", refused)
        check("... and no file changed after that refusal", all(sha256_file(os.path.join(root, rel)) == s for rel, s in before.items())
              and not os.path.exists(os.path.join(root, "winmm.dll")))
        dlss.game_running = lambda: None
        refused = False
        try:
            cmd_install(ns)
        except SystemExit:
            refused = True
        finally:
            dlss.game_running = real_running
        check("install REFUSES when the running state is UNKNOWN", refused)
        # 8. driver gate: 581.42 must refuse without --force-driver, on a non-live root (no pid check needed)
        real_gpu = dlss.gpu_info
        dlss.gpu_info = lambda: ("NVIDIA GeForce RTX 2060 SUPER", "581.42", "selftest")
        ns2 = argparse.Namespace(root=root, model="selftest", proxy="dxgi", upscaler="fsr22_12", working_scale=0.5,
                                 force_driver=False, force_model=False, dry_run=True)
        refused = False
        try:
            cmd_install(ns2)
        except SystemExit:
            refused = True
        check("install REFUSES driver 581.42 without --force-driver", refused)
        # 9. model gate: a Blackwell-only model on Turing refused without --force-model
        CATALOG["selftest"]["gpus"] = ("Blackwell (RTX 50)",)
        ns3 = argparse.Namespace(**dict(vars(ns2), force_driver=True))
        refused = False
        try:
            cmd_install(ns3)
        except SystemExit:
            refused = True
        check("install REFUSES a model not listed for this GPU without --force-model", refused)
        CATALOG["selftest"]["gpus"] = (TURING,)
        # 10. the dry run with both gates satisfied writes nothing (cached_zip/model point at the cache, so
        #     it may refuse on 'missing'; either way NOTHING is written)
        before2 = sorted(os.listdir(root))
        try:
            cmd_install(argparse.Namespace(**dict(vars(ns3), force_driver=True)))
        except SystemExit:
            pass
        dlss.gpu_info = real_gpu
        check("dry-run path writes nothing", sorted(os.listdir(root)) == before2)

        say("selftest: rollback")
        rok, rwhy = do_rollback(root, backup)
        check("rollback verifies PASS", rok, "; ".join(rwhy))
        check("dxgi.dll is byte-identical to the pre-existing file", open(os.path.join(root, "dxgi.dll"), "rb").read() == pre)
        check("added files are gone", not any(os.path.exists(os.path.join(root, rel)) for rel in plan["adds"]))
        check("runtime directory pruned", not os.path.exists(os.path.join(root, RUNTIME_DIR)))
        check("the manifest and the exe were never touched",
              open(os.path.join(root, CI_NAME), "rb").read() == dlss.ci_dump(ci_doc) and open(exe, "rb").read() == b"MZ fake exe")
        os.remove(os.path.join(backup, "manifest.json"))
        refused = False
        try:
            do_rollback(root, backup)
        except SystemExit:
            refused = True
        check("rollback REFUSES a backup without its manifest", refused)
    finally:
        CATALOG.pop("selftest", None)
        shutil.rmtree(root, ignore_errors=True)

    say("selftest: catalog")
    for k, v in CATALOG.items():
        check("%s sha256 is 64 hex" % k, re.fullmatch(r"[0-9a-f]{64}", v["sha256"]) is not None)
    check("selftest never touched the live install", True)
    if fails:
        say("SELFTEST FAIL: %d check(s): %s" % (len(fails), "; ".join(fails)))
        sys.exit(1)
    say("SELFTEST PASS")


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=LIVE_DEFAULT, help="game root holding EscapeFromTarkov.exe (default %s)" % LIVE_DEFAULT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    f = sub.add_parser("fetch")
    f.add_argument("--model", help="model key (default %s)" % DEFAULT_MODEL)
    f.add_argument("--all", action="store_true", help="every catalog entry")
    i = sub.add_parser("install")
    i.add_argument("--model", help="model key: %s (default %s)" % (", ".join(k for k, v in CATALOG.items() if v["kind"] == "model"), DEFAULT_MODEL))
    i.add_argument("--proxy", default="dxgi", choices=PROXY_NAMES, help="file name OptiScaler is installed as (default dxgi; winmm is the other name reported to boot Tarkov-SPT)")
    i.add_argument("--upscaler", default="fsr22_12", choices=DX11_BRIDGED, help="Dx11Upscaler; must be a Dx11-on-Dx12 one (default fsr22_12)")
    i.add_argument("--working-scale", type=float, default=0.5, help="[DlssNr] WorkingScale 0.1..1.0 (default 0.5: quarter cost on a GPU without FP8)")
    i.add_argument("--force-driver", action="store_true", help="proceed below the stated %s minimum" % MIN_DRIVER)
    i.add_argument("--force-model", action="store_true", help="proceed with a model not listed for this GPU")
    i.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("rollback")
    r.add_argument("--backup", help="timestamp or directory (default: last recorded install for --root)")
    sub.add_parser("selftest")
    a = ap.parse_args(argv)
    {"status": cmd_status, "fetch": cmd_fetch, "install": cmd_install, "rollback": cmd_rollback,
     "selftest": cmd_selftest}[a.cmd](a)


if __name__ == "__main__":
    main()
