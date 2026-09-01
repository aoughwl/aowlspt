#!/usr/bin/env python3
r"""toolchain.py -- put a working C/Nim toolchain inside the aowlspt install.

    python tools/toolchain.py status                 is one installed and usable?
    python tools/toolchain.py pack   --out DIR       build a redistributable bundle
    python tools/toolchain.py install --from DIR     install a bundle into the install
    python tools/toolchain.py bootstrap              install one if missing
    python tools/toolchain.py verify                 PROVE it can compile a mod

## Why this exists

aowlspt ships its mods as SOURCE, and compiles what changed at startup
(`tools/modbuild.py`). That is what makes it a modding SDK rather than a bag of
binaries, and it is what makes an in-game "reload this mod" meaningful at all.

But it only works if the machine has a compiler, and a player's machine has
neither msys2 nor a Nim checkout. So the toolchain has to travel with the
install. It belongs to **aowlspt**, the thing the player installs -- never to
`aowlsptcode`, the editor plugin, which is public, tiny, and compiles nothing.

Layout, which `modbuild.py` already looks for first:

    <install>/toolchain/nimony/         the Nim compiler (bin + lib + src/lib)
    <install>/toolchain/ucrt64/bin/     gcc, lld and their runtime DLLs

## The file list is MEASURED, not guessed

msys2's ucrt64 is ~1.2GB and almost none of it is reachable from a mod compile.
Hand-picking a subset is exactly the kind of guess that produces a bundle which
works on the machine that built it and fails on a clean one -- and fails LATE,
at someone else's link step, with a message about a missing DLL that names
nothing useful.

So `pack` starts from the executables a compile actually invokes and walks the
PE import table transitively, resolving each import inside the source tree. What
ships is the closure, plus the data directories gcc genuinely reads (its own
`lib/gcc` spec and header dirs, and the mingw sysroot). `pack` reports what it
could NOT resolve rather than dropping it silently.

Then `verify` compiles a real mod against ONLY the packed copy, with the host
machine's msys2 removed from PATH. That is the check that can fail: a bundle
that is missing something is caught here, on the machine that built it, instead
of on a stranger's.

## `bootstrap` and the network

`bootstrap` installs from `--from` (a directory or a .zip), or from a URL in
`<install>/toolchain-source.json`, verifying every file against the manifest's
SHA-256 before it is used. With neither configured it REFUSES and says so --
it never silently leaves the install without a compiler while reporting success,
because the next thing that happens would be a mods folder full of source and
nothing to build it with.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

DEFAULT_INSTALL = r"D:\Aowlspt\aowlspt"
DEV_UCRT64 = r"C:\msys64\ucrt64"

MANIFEST = "aowlspt-toolchain.json"

# The programs a mod compile actually invokes. nimony's `nifmake` drives the C
# compile and `niflink` links with lld (it passes -fuse-ld=lld on Windows
# deliberately: ld.bfd lays out PE TLS in a way the loader mishandles and
# nimony's runtime uses native TLS).
ROOT_EXES = [
    "bin/gcc.exe",
    "bin/g++.exe",
    "bin/ld.lld.exe",
    "bin/ar.exe",
    "bin/as.exe",
    "bin/ld.exe",
]

# Directories gcc reads as DATA, not as imports -- a PE walk can never find
# these. `lib/gcc` holds cc1.exe and the spec files; the sysroot holds the CRT
# objects and the Windows headers.
DATA_DIRS = ["lib/gcc", "x86_64-w64-mingw32", "include", "lib/clang"]

# The LINK set: import libraries and CRT objects. These live as loose files at
# the TOP LEVEL of `ucrt64/lib`, alongside ~675MB of static libs belonging to
# unrelated msys2 packages (python, LLVM, openssl) in subdirectories. Only the
# top level is taken, and only these extensions.
#
# Without them the bundle compiles fine and then dies at the link with
# `lld: error: unable to find library -lkernel32` -- which is why `verify`
# drives a real compile all the way through a link rather than stopping at
# "the compiler ran".
LIB_FLAT_DIR = "lib"
LIB_FLAT_EXTS = (".a", ".o", ".spec")


# ---------------------------------------------------------------------------
# PE import walking -- how the closure is measured.
# ---------------------------------------------------------------------------

def pe_imports(path):
    """The DLL names in a PE file's import directory. [] on anything unreadable
    or not a PE -- a file we cannot parse contributes nothing rather than
    aborting the pack, and `pack` reports the count either way."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return []
    if len(data) < 0x40 or data[:2] != b"MZ":
        return []
    try:
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            return []
        magic = struct.unpack_from("<H", data, pe + 24)[0]
        is64 = magic == 0x20B
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        opt = struct.unpack_from("<H", data, pe + 20)[0]
        # The DataDirectory starts at 112 (PE32+) / 96 (PE32) into the optional
        # header. IMPORTS ARE INDEX 1; index 0 is the EXPORT table, and reading
        # index 0 here made this walk follow the export directory and emit
        # decoded machine code as "DLL names" -- visibly garbage in the
        # unresolved list, which is the only reason it was caught. Each entry is
        # 8 bytes (RVA, size), so imports are at +8.
        dd = pe + 24 + (112 if is64 else 96)
        imp_rva, imp_sz = struct.unpack_from("<II", data, dd + 8)
        if not imp_rva:
            return []
        secs = []
        so = pe + 24 + opt
        for i in range(nsec):
            b = so + i * 40
            va, rs, pr = struct.unpack_from("<I", data, b + 12)[0], \
                struct.unpack_from("<I", data, b + 16)[0], \
                struct.unpack_from("<I", data, b + 20)[0]
            secs.append((va, rs, pr))

        def off(rva):
            for va, rs, pr in secs:
                if va <= rva < va + rs:
                    return pr + (rva - va)
            return None

        out, i = [], 0
        while True:
            e = off(imp_rva + i * 20)
            if e is None or e + 20 > len(data):
                break
            name_rva = struct.unpack_from("<I", data, e + 12)[0]
            if name_rva == 0:
                break
            n = off(name_rva)
            if n is None:
                break
            end = data.find(b"\0", n)
            out.append(data[n:end].decode("ascii", "replace"))
            i += 1
        return out
    except Exception:
        return []


def closure(src_root, roots):
    """Every file under `src_root` transitively imported by `roots`.

    Returns (kept, unresolved). `unresolved` is DLL names that were imported and
    not found in the source tree -- normally Windows system DLLs, which must NOT
    be shipped. It is returned rather than swallowed so `pack` can print it and
    a human can see whether something surprising is in there.
    """
    kept, unresolved, queue = set(), set(), list(roots)
    bindir = os.path.join(src_root, "bin")
    while queue:
        rel = queue.pop()
        full = rel if os.path.isabs(rel) else os.path.join(src_root, rel)
        if not os.path.isfile(full):
            continue
        key = os.path.normcase(os.path.abspath(full))
        if key in kept:
            continue
        kept.add(key)
        for dll in pe_imports(full):
            cand = os.path.join(bindir, dll)
            if os.path.isfile(cand):
                queue.append(cand)
            else:
                unresolved.add(dll)
    return kept, unresolved


# ---------------------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 16), b""):
            h.update(c)
    return h.hexdigest()


def copy_into(src_root, rel_files, dst_root, manifest, bundle_root):
    """Copy files preserving their layout under `dst_root`, recording each in
    `manifest` by its path RELATIVE TO THE BUNDLE ROOT.

    The manifest path must be what `install` will look for. Recording it
    relative to `src_root` instead dropped the `ucrt64/`/`nimony/` prefix, so
    every entry read as `bin/gcc.exe` when the file is really at
    `ucrt64/bin/gcc.exe` -- and `install` then reported all 6038 files as
    mismatched. It refused rather than installing a broken tree, which is the
    behaviour we want, but it was refusing for the wrong reason."""
    n = 0
    for full in sorted(rel_files):
        rel = os.path.relpath(full, src_root)
        d = os.path.join(dst_root, rel)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(full, d)
        manifest.append({"path": os.path.relpath(d, bundle_root).replace("\\", "/"),
                         "sha256": sha256(d),
                         "bytes": os.path.getsize(d)})
        n += 1
    return n


def walk_files(root):
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            yield os.path.join(dp, f)


def cmd_pack(args):
    ucrt = args.ucrt64
    nim = args.nimony
    if not os.path.isdir(ucrt):
        print("no ucrt64 at %s" % ucrt); return 3
    if not os.path.isdir(nim):
        print("no nimony at %s" % nim); return 3
    out = os.path.abspath(args.out)
    if os.path.isdir(out):
        shutil.rmtree(out, ignore_errors=True)

    print("packing from:\n  ucrt64  %s\n  nimony  %s" % (ucrt, nim))

    # -- ucrt64: the measured import closure of the compile drivers ----------
    roots = [os.path.join(ucrt, r.replace("/", os.sep)) for r in ROOT_EXES]
    have = [r for r in roots if os.path.isfile(r)]
    missing = [r for r in roots if not os.path.isfile(r)]
    if missing:
        print("  NOTE: not present in this msys2 (skipped): %s"
              % ", ".join(os.path.basename(m) for m in missing))
    kept, unresolved = closure(ucrt, have)

    # cc1.exe and friends live under lib/gcc and are EXECUTED, not imported, so
    # they need their own closure or the bundle links but cannot compile.
    extra_roots = []
    for d in DATA_DIRS:
        p = os.path.join(ucrt, d.replace("/", os.sep))
        if os.path.isdir(p):
            extra_roots += [f for f in walk_files(p) if f.lower().endswith(".exe")]
    k2, u2 = closure(ucrt, extra_roots)
    kept |= k2
    unresolved |= u2

    manifest = []
    ucrt_dst = os.path.join(out, "ucrt64")
    n = copy_into(ucrt, kept, ucrt_dst, manifest, out)
    print("  ucrt64 binary closure: %d file(s)" % n)

    for d in DATA_DIRS:
        p = os.path.join(ucrt, d.replace("/", os.sep))
        if not os.path.isdir(p):
            continue
        files = set(os.path.normcase(os.path.abspath(f)) for f in walk_files(p))
        n = copy_into(ucrt, files - kept, ucrt_dst, manifest, out)
        kept |= files
        print("  ucrt64 %-22s %d file(s)" % (d, n))

    flat = os.path.join(ucrt, LIB_FLAT_DIR)
    if os.path.isdir(flat):
        files = set()
        for n in os.listdir(flat):
            f = os.path.join(flat, n)
            if os.path.isfile(f) and n.lower().endswith(LIB_FLAT_EXTS):
                files.add(os.path.normcase(os.path.abspath(f)))
        n = copy_into(ucrt, files - kept, ucrt_dst, manifest, out)
        kept |= files
        print("  ucrt64 %-22s %d file(s)  (link set: import libs + CRT objects)"
              % (LIB_FLAT_DIR + "/*", n))

    # -- nimony: bin + the library sources a mod compiles against -----------
    nim_dst = os.path.join(out, "nimony")
    # `vendor` is not optional: nimony's own stdlib compiles vendored C in
    # (std/system/mimalloc.nim includes vendor/mimalloc/src/static.c), so a
    # bundle without it gets all the way to the C stage and then fails with
    # "cannot find ...static.c". Found by `verify`, which is the entire reason
    # `verify` compiles a real mod instead of checking that files exist.
    for d in ("bin", "lib", "vendor", os.path.join("src", "lib")):
        p = os.path.join(nim, d)
        if not os.path.isdir(p):
            continue
        files = set(os.path.normcase(os.path.abspath(f)) for f in walk_files(p))
        n = copy_into(nim, files, nim_dst, manifest, out)
        print("  nimony %-22s %d file(s)" % (d, n))

    total = sum(m["bytes"] for m in manifest)
    doc = {
        "version": 1,
        "note": ("Every path is relative to this file's directory. Verify with "
                 "`toolchain.py install`, which refuses on any hash mismatch."),
        "files": manifest,
        "total_bytes": total,
    }
    with open(os.path.join(out, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)

    print("\n  %d file(s), %.1f MB -> %s" % (len(manifest), total / 1e6, out))
    if unresolved:
        print("  imported but NOT found in the source tree (expected to be "
              "Windows system DLLs, which must not ship):")
        for d in sorted(unresolved)[:20]:
            print("    %s" % d)
    print("\n  NOW RUN `toolchain.py verify --from %s` -- a bundle is not known "
          "good until it has compiled a mod with the host msys2 off PATH." % out)
    return 0


def toolchain_dir(install):
    return os.path.join(install, "toolchain")


def cmd_install(args):
    src = os.path.abspath(args.frm)
    dst = toolchain_dir(args.install)
    if src.lower().endswith(".zip"):
        tmp = dst + ".unpack"
        shutil.rmtree(tmp, ignore_errors=True)
        with zipfile.ZipFile(src) as z:
            z.extractall(tmp)
        src = tmp
    man = os.path.join(src, MANIFEST)
    if not os.path.isfile(man):
        print("no %s in %s -- refusing to install an unverified toolchain, "
              "because a half-copied compiler fails later and confusingly"
              % (MANIFEST, src))
        return 3
    doc = json.load(open(man, encoding="utf-8"))
    bad = []
    for e in doc["files"]:
        p = os.path.join(src, e["path"].replace("/", os.sep))
        if not os.path.isfile(p) or sha256(p) != e["sha256"]:
            bad.append(e["path"])
    if bad:
        print("REFUSING: %d file(s) do not match the manifest, e.g. %s"
              % (len(bad), ", ".join(bad[:5])))
        return 1
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    print("installed %d verified file(s) -> %s" % (len(doc["files"]), dst))
    return 0


def cmd_status(args):
    d = toolchain_dir(args.install)
    nim = os.path.join(d, "nimony", "bin", "nimony.exe")
    gcc = os.path.join(d, "ucrt64", "bin", "gcc.exe")
    have = os.path.isfile(nim) and os.path.isfile(gcc)
    print("install    %s" % args.install)
    print("toolchain  %s" % d)
    print("nimony.exe %s" % ("present" if os.path.isfile(nim) else "MISSING"))
    print("gcc.exe    %s" % ("present" if os.path.isfile(gcc) else "MISSING"))
    if have:
        print("\nPRESENT -- but presence is not proof. `verify` compiles a real "
              "mod against it; only that can fail.")
        return 0
    print("\nABSENT -- the install cannot build its mods folder. Mods ship as "
          "source, so without this there is nothing to compile them with.")
    return 1


def cmd_verify(args):
    """The check that can fail: compile a real mod using ONLY the bundle."""
    base = os.path.abspath(args.frm) if args.frm else toolchain_dir(args.install)
    nim = os.path.join(base, "nimony")
    ucrt = os.path.join(base, "ucrt64", "bin")
    if not os.path.isfile(os.path.join(nim, "bin", "nimony.exe")):
        print("no nimony.exe under %s -- nothing to verify" % nim); return 3

    mod = args.mod or os.path.join(REPO, "mods", "fov")
    import modbuild

    # A PATH with the host's msys2 REMOVED. Leaving it on would let the bundle
    # borrow a DLL from the machine that built it and pass -- the exact false
    # pass this whole verify exists to prevent.
    clean = [p for p in os.environ.get("PATH", "").split(os.pathsep)
             if "msys64" not in p.lower() and "nimony" not in p.lower()]
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([ucrt, os.path.join(nim, "bin")] + clean)

    print("verifying by compiling %s" % mod)
    print("  host msys2 and ~/nimony REMOVED from PATH for this compile")
    res = modbuild.build_one(
        mod, os.path.join(REPO, "abi"), os.path.join(REPO, "aowl", "src"),
        os.path.join(nim, "bin", "nimony.exe"), nim,
        force=True, check=False, verbose=False, env=env)
    print("  -> %s %s" % (res["status"], res.get("why", "")))
    for line in res.get("output", []):
        print("     | " + line[:160])
    if res["status"] == "built":
        print("\nPASS -- the bundle compiled a real mod with the host toolchain "
              "off PATH. It is self-contained.")
        return 0
    print("\nFAIL -- the bundle is missing something. The error above names it; "
          "add it and re-pack. Do NOT ship this.")
    return 1


def cmd_bootstrap(args):
    d = toolchain_dir(args.install)
    nim = os.path.join(d, "nimony", "bin", "nimony.exe")
    if os.path.isfile(nim) and not args.force:
        print("toolchain already present at %s (use --force to reinstall)" % d)
        return 0
    if args.frm:
        return cmd_install(args)
    cfg = os.path.join(args.install, "toolchain-source.json")
    if os.path.isfile(cfg):
        src = json.load(open(cfg, encoding="utf-8")).get("url")
        print("a source is configured (%s) but downloading is not implemented "
              "here yet; fetch it and pass --from" % src)
        return 3
    print("NO TOOLCHAIN AND NO SOURCE FOR ONE.\n"
          "  This install ships its mods as SOURCE, so without a compiler the "
          "mods folder cannot be built and nothing will load.\n"
          "  Provide one with `--from <dir-or-zip>`, or write a URL into %s.\n"
          "  Refusing rather than reporting success with no compiler installed."
          % cfg)
    return 3


def main():
    p = argparse.ArgumentParser(
        description="install and verify the aowlspt install's own toolchain",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("cmd", choices=["status", "pack", "install", "verify",
                                   "bootstrap"])
    p.add_argument("--install", default=DEFAULT_INSTALL)
    p.add_argument("--ucrt64", default=DEV_UCRT64)
    p.add_argument("--nimony", default=os.environ.get(
        "NIMONY_HOME", os.path.expanduser("~/nimony")))
    p.add_argument("--out", default=os.path.join(REPO, "build", "toolchain"))
    p.add_argument("--from", dest="frm", default=None)
    p.add_argument("--mod", default=None)
    p.add_argument("--force", action="store_true")
    a = p.parse_args()
    return {"status": cmd_status, "pack": cmd_pack, "install": cmd_install,
            "verify": cmd_verify, "bootstrap": cmd_bootstrap}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
