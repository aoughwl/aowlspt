#!/usr/bin/env python3
r"""mapextract_mono.py -- extract game MonoBehaviour components, with their
serialised FIELD VALUES, out of Tarkov scene files.

## The gap this fills

`tools/mapextract.py` walks the transform hierarchy and records components from
a fixed whitelist of Unity built-ins (MeshFilter, MeshRenderer, MeshCollider,
LODGroup, BoxCollider, SphereCollider, ...).  Everything else is dropped before
it is ever read -- see the `elif tn in (...)` filter in `extract_scene`.  Across
four Factory scenes that whitelist matched 82,380 components and ZERO of BSG's
own scripts, so the hierarchy sidecars carry no spawn points, no exfils, no AI
markers and no location metadata.  Node names survive and hint at meaning
(`ai_coverplace (80)`), but no field value does.

This tool reads them.  `tools/monotree.py` reconstructs each script's Unity
serialisation layout from the decrypted il2cpp metadata (the level files ship
with type trees STRIPPED, so UnityPy cannot), and every decode is accepted only
if it round-trips to the source bytes exactly.

## Output

A sibling sidecar `<scene>.mono.json`, NOT an edit to `<scene>.hierarchy.json`.
Reasons: the hierarchy sidecar is produced by the glTF/mesh pipeline, which is
slow and already verified byte-stable, and this extraction needs neither meshes
nor textures; keeping them separate means running one never risks the other's
output.  Each component records the GameObject path, so the two join on `path`.

## Three outcomes, never two

Every MonoBehaviour in the scene appears in the output.  A component that could
not be decoded is recorded with `"status": "UNRESOLVED"`, its full type name,
its assembly, its raw payload length and the REASON -- never dropped and never
guessed.  Statuses:

    DECODED     layout round-tripped this instance's bytes exactly
    UNRESOLVED  no layout could be built, the round trip failed, the script
                reference is null (stripped from the build), or the type is
                not in the metadata

## Running it

UnityPy imports ONLY under the Store Python (fact #163):

    %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe tools/mapextract_mono.py \
        extract --scene 534 --out D:\MapExtract\tt\factory_day_preset

This tool NEVER writes to the game directory. It opens level files read-only.
"""

import argparse
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import monotree                                     # noqa: E402

GAME_DIR = r"D:\Games\Tarkov\EscapeFromTarkov_Data"
GAME_ASM = r"D:\Games\Tarkov\GameAssembly.dll"
METADEC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       ".cache", "global-metadata.dec.dat")


def _require_unitypy():
    try:
        import UnityPy  # noqa: F401
    except Exception as exc:
        sys.stderr.write(
            "UnityPy is not importable under this interpreter (%s).\n"
            "Fact #163: only the Store Python can import it. Re-run with\n"
            "  %%LOCALAPPDATA%%\\Microsoft\\WindowsApps\\python.exe\n"
            "underlying error: %r\n" % (sys.executable, exc))
        raise SystemExit(2)


# ---------------------------------------------------------------------------
# scene file plumbing


def externals_of(path):
    import UnityPy
    env = UnityPy.load(path)
    out = []
    for f in env.files.values():
        for ext in getattr(f, "externals", []) or []:
            out.append(ext.path)
    return out


def open_scene_env(ddir, level_path):
    """Open a level file plus every external it names that exists on disk.

    Loading the whole data directory is not an option (~33 GB); the externals
    are what make cross-file PPtrs -- notably the MonoScript objects -- resolve.
    """
    import UnityPy
    wanted, missing = [level_path], []
    for name in externals_of(level_path):
        base = os.path.basename(name.replace("\\", "/"))
        cand = os.path.join(ddir, base)
        if os.path.exists(cand):
            if cand not in wanted:
                wanted.append(cand)
        else:
            missing.append(name)
    return UnityPy.load(*wanted), wanted, missing


def deref(env, from_file, fid, pid):
    """Resolve a raw (fileID, pathID) against from_file's external list."""
    if pid == 0:
        return None
    target = from_file
    if fid != 0:
        exts = getattr(from_file, "externals", []) or []
        if fid - 1 >= len(exts):
            return None
        want = os.path.basename(exts[fid - 1].path.replace("\\", "/")).lower()
        target = None
        for k, v in env.files.items():
            if os.path.basename(str(k).replace("\\", "/")).lower() == want:
                target = v
                break
        if target is None:
            return None
    objs = getattr(target, "objects", None)
    return None if objs is None else objs.get(pid)


def read_mb_header(data):
    """Parse the fixed MonoBehaviour base header.

    UnityPy cannot do this for us: with type trees stripped it falls back to a
    generic node and raises as soon as a derived field appears
    (`ValueError('Expected to read 68 bytes, but only read 32 bytes')`).
    The BASE is version-stable and hand-parsable:

        m_GameObject  PPtr   int32 fileID + int64 pathID   12
        m_Enabled     uint8 + 3 pad                         4
        m_Script      PPtr   int32 fileID + int64 pathID   12
        m_Name        string int32 len + bytes + align4

    Returns a dict, or None if the bytes cannot be that shape."""
    if len(data) < 32:
        return None
    go_fid, go_pid = struct.unpack_from("<iq", data, 0)
    enabled = data[12]
    sc_fid, sc_pid = struct.unpack_from("<iq", data, 16)
    (nlen,) = struct.unpack_from("<i", data, 28)
    if nlen < 0 or nlen > 4096 or 32 + nlen > len(data):
        return None
    off = 32 + nlen
    off += (-off) % 4
    if off > len(data):
        return None
    return {"go": (go_fid, go_pid), "enabled": bool(enabled),
            "script": (sc_fid, sc_pid),
            "name": data[32:32 + nlen].decode("utf-8", "replace"),
            "payload_off": off}


# ---------------------------------------------------------------------------


def scene_index_map(ddir):
    import UnityPy
    env = UnityPy.load(os.path.join(ddir, "globalgamemanagers"))
    for obj in env.objects:
        if obj.type.name == "BuildSettings":
            return list(obj.read_typetree().get("scenes", []))
    raise SystemExit("BuildSettings not found in globalgamemanagers")


def build_paths(env, main_file):
    """pathID(GameObject) -> '/A/B/C' scene path, via the Transform graph."""
    gonames, tr_of_go, father, go_of_tr = {}, {}, {}, {}
    for obj in env.objects:
        if obj.assets_file is not main_file:
            continue
        tn = obj.type.name
        if tn == "GameObject":
            try:
                gonames[obj.path_id] = obj.read_typetree().get("m_Name") or ""
            except Exception:
                gonames[obj.path_id] = ""
        elif tn in ("Transform", "RectTransform"):
            try:
                t = obj.read_typetree()
            except Exception:
                continue
            g = (t.get("m_GameObject") or {}).get("m_PathID", 0)
            f = (t.get("m_Father") or {}).get("m_PathID", 0)
            tr_of_go[g] = obj.path_id
            go_of_tr[obj.path_id] = g
            father[obj.path_id] = f

    paths, guard = {}, {}

    def path_of_tr(tid, depth=0):
        if tid in paths:
            return paths[tid]
        if depth > 200 or tid not in go_of_tr:
            return ""
        if guard.get(tid):
            return ""                       # cycle: refuse rather than loop
        guard[tid] = True
        g = go_of_tr[tid]
        f = father.get(tid, 0)
        parent = path_of_tr(f, depth + 1) if f else ""
        p = parent + "/" + (gonames.get(g) or "GameObject")
        paths[tid] = p
        guard[tid] = False
        return p

    out = {}
    for g, tid in tr_of_go.items():
        out[g] = path_of_tr(tid)
    return out, gonames


def script_identity(env, main_file, fid, pid, cache):
    """(assembly, namespace, class) from the MonoScript a m_Script PPtr names.

    This is the identity Unity itself matches on at load; see PART 2 of the
    report. A null PPtr means the script was stripped from the build."""
    key = (fid, pid)
    if key in cache:
        return cache[key]
    if pid == 0 and fid == 0:
        res = (None, None, None, "m_Script is null (0:0) -- the script "
                                 "reference was stripped from the build")
    else:
        o = deref(env, main_file, fid, pid)
        if o is None:
            res = (None, None, None,
                   "MonoScript %d:%d is not in any opened file" % (fid, pid))
        else:
            try:
                t = o.read_typetree()
                res = (t.get("m_AssemblyName") or "", t.get("m_Namespace") or "",
                       t.get("m_ClassName") or "", None)
            except Exception as exc:
                res = (None, None, None, "MonoScript unreadable: %r" % (exc,))
    cache[key] = res
    return res


def extract_scene(layouts, ddir, index, out_dir, scene_label, keep_raw=False,
                  verbose=True):
    env, opened, missing = open_scene_env(ddir, os.path.join(ddir,
                                                             "level%d" % index))
    byname = {os.path.basename(str(k).replace("\\", "/")).lower(): v
              for k, v in env.files.items()}
    main_file = byname["level%d" % index]

    paths, _gonames = build_paths(env, main_file)
    scache = {}
    comps = []
    per_type = collections.OrderedDict()

    # Pass 1: identity + payload for every MonoBehaviour.
    raw = []
    for obj in env.objects:
        if obj.assets_file is not main_file or obj.type.name != "MonoBehaviour":
            continue
        data = obj.get_raw_data()
        hdr = read_mb_header(data)
        if hdr is None:
            raw.append((obj.path_id, None, None, b"",
                        "MonoBehaviour base header did not parse"))
            continue
        asm, ns, cls, why = script_identity(env, main_file, hdr["script"][0],
                                            hdr["script"][1], scache)
        full = None if cls is None else ((ns + "." + cls) if ns else cls)
        raw.append((obj.path_id, hdr, (asm, full), data[hdr["payload_off"]:],
                    why))

    # Pass 2: resolve one layout per (assembly, type) and decode.
    layout_cache = {}

    def layout_for(asm, full):
        key = (asm, full)
        if key in layout_cache:
            return layout_cache[key]
        t = layouts.type_index(full, assembly=asm)
        if t is None:
            t = layouts.type_index(full)
        if t is None:
            res = (None, "type %r is not in the metadata (assembly %r)"
                   % (full, asm))
        else:
            root, why = layouts.behaviour_layout(t)
            res = (root, why)
        layout_cache[key] = res
        return res

    for path_id, hdr, ident, payload, why in raw:
        entry = {"pathId": path_id, "payloadBytes": len(payload)}
        if hdr is not None:
            entry["gameObject"] = hdr["go"][1]
            entry["path"] = paths.get(hdr["go"][1], "")
            entry["enabled"] = hdr["enabled"]
            if hdr["name"]:
                entry["m_Name"] = hdr["name"]
        if ident is None or ident[1] is None:
            entry["type"] = "UNKNOWN"
            entry["status"] = "UNRESOLVED"
            entry["reason"] = why or "script identity unavailable"
            comps.append(entry)
            per_type.setdefault(("", "UNKNOWN"), {"count": 0, "decoded": 0,
                                                  "status": "UNRESOLVED",
                                                  "reason": entry["reason"]})
            per_type[("", "UNKNOWN")]["count"] += 1
            continue
        asm, full = ident
        entry["type"] = full
        entry["assembly"] = asm
        slot = per_type.setdefault((asm, full), {"count": 0, "decoded": 0,
                                                 "status": None, "reason": None})
        slot["count"] += 1

        root, lwhy = layout_for(asm, full)
        if root is None:
            entry["status"] = "UNRESOLVED"
            entry["reason"] = lwhy
            slot["status"] = "UNRESOLVED"
            slot["reason"] = lwhy
        else:
            val, dwhy = monotree.decode_verified(root, payload)
            if val is None:
                entry["status"] = "UNRESOLVED"
                entry["reason"] = dwhy
                slot["status"] = "UNRESOLVED"
                slot["reason"] = dwhy
                if keep_raw:
                    entry["rawHex"] = payload.hex()
            else:
                entry["status"] = "DECODED"
                entry["fields"] = val
                slot["decoded"] += 1
                if slot["status"] is None:
                    slot["status"] = "DECODED"
        comps.append(entry)

    for slot in per_type.values():
        if slot["status"] is None:
            slot["status"] = "UNRESOLVED"

    total = len(comps)
    decoded = sum(1 for c in comps if c["status"] == "DECODED")
    doc = {
        "scene": scene_label,
        "source": "level%d" % index,
        "openedFiles": [os.path.basename(p) for p in opened],
        "missingExternals": missing,
        "counts": {
            "monoBehaviours": total,
            "decoded": decoded,
            "unresolved": total - decoded,
            "distinctTypes": len(per_type),
        },
        "types": [
            {"assembly": asm, "type": full, "count": v["count"],
             "decoded": v["decoded"], "status": v["status"],
             "reason": v["reason"]}
            for (asm, full), v in sorted(per_type.items(),
                                         key=lambda kv: -kv[1]["count"])
        ],
        "components": comps,
    }
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, scene_label + ".mono.json")
    with open(dest, "w", newline="\n", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    if verbose:
        sys.stderr.write("%s: %d MonoBehaviours, %d DECODED, %d UNRESOLVED, "
                         "%d types -> %s\n"
                         % (scene_label, total, decoded, total - decoded,
                            len(per_type), dest))
    return doc


# ---------------------------------------------------------------------------


def cmd_extract(args):
    _require_unitypy()
    layouts = monotree.Layouts(args.game_asm, args.metadec)
    scenes = scene_index_map(args.game_dir)
    summary = []
    for index in args.scene:
        label = args.label
        if label is None:
            p = scenes[index] if index < len(scenes) else "level%d" % index
            label = os.path.splitext(os.path.basename(p))[0]
        doc = extract_scene(layouts, args.game_dir, index, args.out, label,
                            keep_raw=args.keep_raw)
        summary.append({"scene": index, "label": label,
                        "counts": doc["counts"]})
        args.label = None
    print(json.dumps(summary, indent=1))


def cmd_census(args):
    """Type census across scenes, with decode status -- no files written."""
    _require_unitypy()
    layouts = monotree.Layouts(args.game_asm, args.metadec)
    scenes = scene_index_map(args.game_dir)
    tally = collections.OrderedDict()
    grand = [0, 0]
    for index in args.scene:
        p = scenes[index] if index < len(scenes) else "level%d" % index
        label = os.path.splitext(os.path.basename(p))[0]
        doc = extract_scene(layouts, args.game_dir, index, args.out, label,
                            verbose=True) if args.out else None
        if doc is None:
            doc = _census_only(layouts, args.game_dir, index, label)
        for row in doc["types"]:
            k = (row["assembly"], row["type"])
            t = tally.setdefault(k, {"count": 0, "decoded": 0, "status": set(),
                                     "reason": row["reason"]})
            t["count"] += row["count"]
            t["decoded"] += row["decoded"]
            t["status"].add(row["status"])
            if row["reason"]:
                t["reason"] = row["reason"]
        grand[0] += doc["counts"]["monoBehaviours"]
        grand[1] += doc["counts"]["decoded"]
    print("%-8s %-8s %-58s %s" % ("COUNT", "DECODED", "TYPE", "STATUS"))
    for (asm, full), v in sorted(tally.items(), key=lambda kv: -kv[1]["count"]):
        st = "DECODED" if v["decoded"] == v["count"] else (
            "UNRESOLVED" if v["decoded"] == 0 else "PARTIAL")
        print("%-8d %-8d %-58s %s%s"
              % (v["count"], v["decoded"], full, st,
                 ("  -- " + v["reason"]) if st != "DECODED" and v["reason"]
                 else ""))
    print("\nTOTAL %d MonoBehaviours, %d DECODED byte-exactly, %d UNRESOLVED "
          "(%.1f%% decoded)"
          % (grand[0], grand[1], grand[0] - grand[1],
             100.0 * grand[1] / grand[0] if grand[0] else 0.0))


def _census_only(layouts, ddir, index, label):
    import tempfile
    tmp = tempfile.mkdtemp(prefix="monocensus")
    try:
        return extract_scene(layouts, ddir, index, tmp, label, verbose=True)
    finally:
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--game-dir", default=GAME_DIR)
    ap.add_argument("--game-asm", default=GAME_ASM)
    ap.add_argument("--metadec", default=METADEC)
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("extract", help="write <scene>.mono.json sidecars")
    e.add_argument("--scene", type=int, nargs="+", required=True)
    e.add_argument("--out", required=True)
    e.add_argument("--label", default=None)
    e.add_argument("--keep-raw", action="store_true",
                   help="include the hex payload of UNRESOLVED components")
    e.set_defaults(func=cmd_extract)

    c = sub.add_parser("census", help="type census with decode status")
    c.add_argument("--scene", type=int, nargs="+", required=True)
    c.add_argument("--out", default=None)
    c.set_defaults(func=cmd_census)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
