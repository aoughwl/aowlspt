#!/usr/bin/env python3
r"""modbuild.py -- compile a mods folder from SOURCE, with a content cache.

    python tools/modbuild.py --mods D:\Aowlspt\aowlspt\mods
    python tools/modbuild.py --mods ... --check      say what WOULD build, build nothing
    python tools/modbuild.py --mods ... --force      ignore the cache
    python tools/modbuild.py --mods ... --json       one line, machine-readable

## What this is for

aowlspt ships mods as prebuilt `.dll`s. That is fine for us and wrong for
everyone else: a person who installs aowlspt and wants to CHANGE a mod has no
path from "edit the .nim" to "the game loads my change" -- they would need our
repo, our `aowl` driver, our `abi/` headers and our exact nimony checkout.

The intended shape is the opposite: **the user's mods folder holds SOURCE**, and
the thing that runs it compiles what changed at startup. That is what makes
aowlspt a modding SDK rather than a bag of binaries, and it is what makes an
in-game "reload this mod" button possible at all -- reload is meaningless if the
user has no way to produce a new binary.

This is the compile-and-cache half of that. It is deliberately a separate,
callable tool rather than logic buried in the launcher, so that the same code
serves `aowl build mods`, a first-run install step, a hot-reload triggered from
inside the game, and a person typing it by hand.

## The cache, and why it is a CONTENT hash and not a timestamp

A mod rebuilds if and only if its **cache key** changed. The key hashes:

  * every source file in the mod directory (`.nim`, `.h`, `.c`, `.json`),
    by content -- not mtime. Timestamps lie: a checkout, a copy, a restore
    from backup, or an editor that preserves mtime all produce "unchanged"
    for a file whose bytes differ, and the failure mode is a stale DLL that
    reports a successful build. This project has already been bitten by that
    exact shape (`placeLibrary`: an existing output satisfied the "did the
    compiler honour -o:" check, so a stale binary shipped and the compile
    reported success).
  * the shared `abi/` headers, because every mod compiles against them and a
    header change invalidates all of them at once.
  * the aowlspt Nim library under `aowl/src`, for the same reason.
  * the exact compile command line, so changing a flag rebuilds.
  * the toolchain identity (the nimony binary's own content hash), so
    upgrading the compiler rebuilds rather than mixing objects.

The key is written to `bin/<stem>.cachekey` NEXT TO the output, and a mod is
considered up to date only when that file exists AND matches AND the `.dll` is
actually present. All three, because any one of them alone can be true while
the build is stale.

## Honest outcomes

Per mod: `built`, `cached`, `failed`, or `skipped` (no single .nim source).
The summary states counts for each and the exit code is non-zero if anything
failed. A mod that failed to compile is NEVER left with its previous `.dll` in
place pretending to be the new one -- the output and its cache key are removed
first, so a failure cannot masquerade as a success on the next run.
"""

from __future__ import annotations

import argparse
import hashlib
import json as jsonmod
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Files whose bytes participate in a mod's cache key. Anything a compile can
# read should be here; adding an extension is cheap, missing one means a stale
# build that reports success.
SOURCE_EXTS = (".nim", ".h", ".c", ".cpp", ".json", ".cfg")

# Directories never hashed and never scanned: build output, not input.
SKIP_DIRS = {"nimcache", "bin", ".git", "__pycache__"}

# msys2's ucrt64 bin directory. This is not optional and it is not a nicety.
DEV_UCRT64 = r"C:\msys64\ucrt64\bin"

# WHERE THE TOOLCHAIN LIVES, and why it is here rather than in the plugin.
#
# The compiler belongs to **aowlspt**, the thing the player installs -- not to
# `aowlsptcode`, the Claude Code plugin. The plugin is agent-facing tooling
# (inspector, RVA discovery, launch verdicts); it never compiles anything and
# must not carry a 200MB toolchain. aowlspt is what ships mods as SOURCE, so
# aowlspt is what must be able to build them, on a machine that has never seen
# this repo, msys2, or a Nim checkout.
#
# So the search order is: the INSTALL's own bundled toolchain first, then the
# developer's environment, and a refusal if neither is there. An install that
# cannot find a compiler must SAY SO -- silently leaving whatever .dll happens
# to be on disk and reporting success is the failure this whole design exists
# to remove.
TOOLCHAIN_SUBDIR = "toolchain"          # <install>/toolchain/{nimony,ucrt64}


def find_toolchain(install_dir, nimony_arg, ucrt64_arg):
    """Resolve (nimony_root, ucrt64_bin, source) with the install winning.

    `source` is reported so the log can state WHICH toolchain compiled the
    mods. Two machines producing different binaries because they silently
    picked up different compilers is exactly the class of problem that is
    impossible to debug after the fact.
    """
    # An explicit flag always wins -- that is what a flag is for.
    if nimony_arg and ucrt64_arg:
        return nimony_arg, ucrt64_arg, "explicit --nimony/--ucrt64"

    if install_dir:
        tc = os.path.join(install_dir, TOOLCHAIN_SUBDIR)
        nim = nimony_arg or os.path.join(tc, "nimony")
        ucrt = ucrt64_arg or os.path.join(tc, "ucrt64", "bin")
        if os.path.isdir(nim) and os.path.isdir(ucrt):
            return nim, ucrt, "the install's bundled toolchain (%s)" % tc

    nim = nimony_arg or os.environ.get("NIMONY_HOME") or \
        os.path.expanduser("~/nimony")
    ucrt = ucrt64_arg or DEV_UCRT64
    return nim, ucrt, "the developer environment on this machine"


def build_env(ucrt64, nimony_root):
    r"""PATH for every child compile, with ucrt64 and nimony's bin FIRST.

    Two environment facts, both documented in `tools/aowl.nim` and both
    miserable to rediscover -- this file exists to not rediscover them:

      * msys2's ucrt64 bin must precede Git-for-Windows' /mingw64/bin. Otherwise
        gcc's cc1 loads libgcc/libgmp/zlib/zstd out of Git's mingw64 and dies
        **with no diagnostic whatsoever**.
      * the linker must be lld (nimony's niflink passes -fuse-ld=lld on Windows
        deliberately; ld.bfd lays out PE TLS in a way the loader mishandles).

    A first version of this tool inherited PATH unchanged and every mod failed
    at the link step with a bare `FAILURE: ... nifmake.exe ...` and nothing
    else -- which reads as "the mod does not compile" and is really "the wrong
    gcc was on PATH". If ucrt64 is missing this SAYS SO rather than proceeding
    into that failure and letting it be misread as a code error.
    """
    env = dict(os.environ)
    head = []
    missing = None
    if os.path.isdir(ucrt64):
        head.append(ucrt64)
    else:
        missing = ucrt64
    nb = os.path.join(nimony_root, "bin")
    if os.path.isdir(nb):
        head.append(nb)
    if head:
        env["PATH"] = os.pathsep.join(head) + os.pathsep + env.get("PATH", "")
    return env, missing


def sha_file(path, h):
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 16), b""):
                h.update(chunk)
    except OSError:
        # An unreadable input must CHANGE the key, not silently drop out of it.
        # Dropping it would make an unreadable file look identical to no file.
        h.update(b"<unreadable:%s>" % path.encode("utf-8", "replace"))


def hash_tree(root, exts, h, label):
    """Hash every matching file under `root`, in a stable order."""
    h.update(("|tree:%s|" % label).encode())
    if not os.path.isdir(root):
        h.update(b"<absent>")
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if exts and not name.lower().endswith(exts):
                continue
            p = os.path.join(dirpath, name)
            # Path relative to root, so the key does not change when the whole
            # install is moved to another drive.
            h.update(os.path.relpath(p, root).replace("\\", "/").encode())
            sha_file(p, h)


def mod_source(mod_dir):
    """The mod's entry-point .nim, or None. Mirrors `aowl.nim`'s `sourceOf`
    EXACTLY, and the order is the whole point:

      1. `<dirname>/<dirname>.nim` if it exists;
      2. otherwise, the single top-level `.nim` if there is exactly one.

    Getting this wrong is not a cosmetic difference. A first version implemented
    only rule 2, and `mods/settingshub` (2 top-level .nim) and `mods/textures`
    (5) were both reported as "skipped -- no single top-level .nim source". They
    build fine; the tool was simply refusing to see them, and the summary line
    made that look like a property of the mods rather than a bug here."""
    mod_dir = mod_dir.rstrip("\\/")
    if os.path.isfile(mod_dir) and mod_dir.lower().endswith(".nim"):
        return mod_dir
    if not os.path.isdir(mod_dir):
        return None
    stem = os.path.basename(mod_dir)
    guess = os.path.join(mod_dir, stem + ".nim")
    if os.path.isfile(guess):
        return guess
    try:
        names = [n for n in os.listdir(mod_dir)
                 if n.lower().endswith(".nim")
                 and os.path.isfile(os.path.join(mod_dir, n))]
    except OSError:
        return None
    if len(names) != 1:
        return None
    return os.path.join(mod_dir, names[0])


def compile_cmd(nimony_exe, nimony_root, abi_dir, aowl_src, mod_dir, source, out):
    """The EXACT command `aowl.nim`'s buildMod uses. Kept identical on purpose:
    two compile paths that drift produce binaries that differ for reasons nobody
    can see."""
    return [
        nimony_exe, "c", "--app:lib",
        "--passC:-I" + abi_dir,
        "--passC:-I" + mod_dir,
        "-p:" + aowl_src,
        "-p:" + os.path.join(nimony_root, "src", "lib"),
        "-o:" + out,
        source,
    ]


def cache_key(mod_dir, abi_dir, aowl_src, nimony_exe, cmd):
    h = hashlib.sha256()
    h.update(b"aowlspt-modbuild-v1")
    hash_tree(mod_dir, SOURCE_EXTS, h, "mod")
    hash_tree(abi_dir, (".h",), h, "abi")
    hash_tree(aowl_src, (".nim",), h, "aowl")
    # The toolchain itself. An upgraded compiler must rebuild, not mix objects.
    h.update(b"|toolchain|")
    sha_file(nimony_exe, h)
    # The command line, so a flag change rebuilds. Paths are stripped to
    # basenames so moving the install does not invalidate every mod.
    h.update(b"|cmd|")
    h.update(" ".join(os.path.basename(c) if os.path.sep in c else c
                      for c in cmd).encode())
    return h.hexdigest()


def place_library(mod_dir, stem, out_path):
    """`-o:` does not reach a `--app:lib` build -- nimony leaves the shared
    library inside `nimcache/<hash>/`. Without this the compile reports success
    and the library is simply absent, which is far worse than a compile error.
    Same recovery `aowl.nim`'s placeLibrary performs, for the same reason."""
    if os.path.isfile(out_path):
        return True
    cache = os.path.join(mod_dir, "nimcache")
    best, best_size = None, -1
    for dirpath, _dirs, files in os.walk(cache):
        for n in files:
            if n != stem + ".dll":
                continue
            p = os.path.join(dirpath, n)
            try:
                sz = os.path.getsize(p)
            except OSError:
                continue
            if sz > best_size:
                best, best_size = p, sz
    if not best:
        return False
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    shutil.copy2(best, out_path)
    return True


class Progress(object):
    """Append-only JSON-lines progress, for the in-game mod-loading screen.

    The host renders this while the client boots, so it has to be readable by
    something that is NOT this process and may start reading half way through.
    Hence JSON LINES, flushed per event: a reader that opens the file mid-write
    sees a whole number of complete records plus at most one partial trailing
    line, which it drops. A single JSON document would be unparseable for the
    entire duration of the build -- exactly when the screen most wants to show
    something.

    Every record carries `i`/`n`, so the screen can show real progress rather
    than a spinner that conveys nothing. `n` is known up front because the mod
    list is enumerated before any compiling starts.
    """

    def __init__(self, path, total, screen=None):
        self.path = path
        self.screen = screen
        self.total = total
        self.i = 0
        self.rows = {}
        self.order = []
        self.done_all = False
        if path:
            try:
                os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
                # Truncate: this is THIS run's progress. A stale file left by a
                # previous boot would otherwise be rendered as if it were live,
                # which is the same class of bug as reading a stale log.
                with open(path, "w", encoding="utf-8") as f:
                    f.write(jsonmod.dumps({"event": "start", "n": total}) + "\n")
            except OSError:
                self.path = None

    def emit(self, **kw):
        if not self.path:
            return
        kw.setdefault("n", self.total)
        kw.setdefault("i", self.i)
        try:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(jsonmod.dumps(kw) + "\n")
                f.flush()
        except OSError:
            pass

    def starting(self, mod):
        self.i += 1
        if mod not in self.rows:
            self.order.append(mod)
        self.rows[mod] = ("building", "")
        self.emit(event="mod", mod=mod, status="building", i=self.i)
        self.render()

    def done(self, res):
        extra = ""
        if res["status"] == "built" and res.get("seconds") is not None:
            extra = "%.1fs" % res["seconds"]
        elif res["status"] in ("failed", "skipped"):
            extra = (res.get("why") or "")[:48]
        self.rows[res["mod"]] = (res["status"], extra)
        self.emit(event="mod", mod=res["mod"], status=res["status"],
                  seconds=res.get("seconds"), why=res.get("why"), i=self.i)
        self.render()

    def finished(self, counts, failed):
        self.emit(event="done", counts=counts, failed=failed, i=self.i)
        self.done_all = True
        self.render()

    # ---- the in-game screen -------------------------------------------
    #
    # A SECOND file, plain text, rewritten in full on every event. The host
    # renders it VERBATIM, one label per line.
    #
    # Why not have the host read the JSON above: it would then be parsing JSON
    # on the Unity main thread, every frame, inside the guard, allocating as it
    # goes -- against the host's own rule of no per-frame managed allocation.
    # A whole-file rewrite of ~15 short lines costs nothing here and turns the
    # in-game side into "read a small file when its size or mtime changed, and
    # set N label texts". The host does no parsing at all.
    #
    # It is rewritten rather than appended so the file is always the COMPLETE
    # current state: a reader that arrives late still sees every mod, and there
    # is no replay to reconstruct.
    STATUS_W = 9

    def render(self):
        if not self.screen:
            return
        lines = []
        if getattr(self, "done_all", False):
            bad = sum(1 for r in self.rows.values() if r[0] == "failed")
            lines.append("MODS READY  %d of %d%s"
                         % (len(self.rows), self.total,
                            ("  -- %d FAILED" % bad) if bad else ""))
        else:
            lines.append("BUILDING MODS  %d of %d" % (self.i, self.total))
        for name in self.order:
            st, extra = self.rows[name]
            lines.append("  %-14s %-*s %s" % (name, self.STATUS_W, st, extra))
        try:
            # Whole-file replace via a temp + os.replace so a reader never sees
            # a half-written file -- the host reads this from another process.
            tmp = self.screen + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(tmp, self.screen)
        except OSError:
            pass


def build_one(mod_dir, abi_dir, aowl_src, nimony_exe, nimony_root,
              force, check, verbose, env):
    name = os.path.basename(mod_dir.rstrip("\\/"))
    source = mod_source(mod_dir)
    if not source:
        return {"mod": name, "status": "skipped",
                "why": "no single top-level .nim source"}

    stem = os.path.splitext(os.path.basename(source))[0]
    bin_dir = os.path.join(mod_dir, "bin")
    out = os.path.join(bin_dir, stem + ".dll")
    keyfile = os.path.join(bin_dir, stem + ".cachekey")

    cmd = compile_cmd(nimony_exe, nimony_root, abi_dir, aowl_src,
                      mod_dir, source, out)
    key = cache_key(mod_dir, abi_dir, aowl_src, nimony_exe, cmd)

    if not force:
        # All THREE conditions. Any one alone can hold while the build is stale:
        # the key file can survive a deleted dll, and the dll can survive a
        # source edit.
        try:
            have = open(keyfile).read().strip()
        except OSError:
            have = ""
        if have == key and os.path.isfile(out):
            return {"mod": name, "status": "cached", "out": out}

    if check:
        return {"mod": name, "status": "would-build"}

    # Remove the previous output AND its key BEFORE compiling. If the compile
    # fails we must not be left holding a stale dll that the next run would
    # accept as current -- a failure that looks like a success is the single
    # worst outcome this repo produces.
    for p in (out, keyfile):
        try:
            os.remove(p)
        except OSError:
            pass
    os.makedirs(bin_dir, exist_ok=True)

    t0 = time.time()
    r = subprocess.run(cmd, cwd=mod_dir, capture_output=True, text=True,
                       env=env)
    if r.returncode != 0:
        # One retry with the cache cleared. nimony's incremental cache does not
        # always survive a source file being ADDED to a mod: it fails at link
        # with an undefined string literal, which reads like a code error and is
        # not one. aowl.nim does exactly this; a second failure is real.
        cache = os.path.join(mod_dir, "nimcache")
        if os.path.isdir(cache):
            shutil.rmtree(cache, ignore_errors=True)
            r = subprocess.run(cmd, cwd=mod_dir, capture_output=True,
                               text=True, env=env)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip().splitlines()[-6:]
        return {"mod": name, "status": "failed",
                "why": "nimony exited %d" % r.returncode, "output": tail}

    if not place_library(mod_dir, stem, out):
        return {"mod": name, "status": "failed",
                "why": ("nimony reported success but no %s.dll was produced, "
                        "and none was found in nimcache either. The build did "
                        "not fail -- it produced nothing." % stem)}

    with open(keyfile, "w") as f:
        f.write(key)
    return {"mod": name, "status": "built", "out": out,
            "seconds": round(time.time() - t0, 1)}


def main():
    p = argparse.ArgumentParser(
        description="compile a mods folder from source, with a content cache",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--mods", default=os.path.join(REPO, "mods"),
                   help="the mods folder to compile (default: the repo's)")
    p.add_argument("--abi", default=os.path.join(REPO, "abi"))
    p.add_argument("--aowl-src", default=os.path.join(REPO, "aowl", "src"))
    p.add_argument("--install", default=None,
                   help=r"the aowlspt install (e.g. D:\Aowlsptowlspt). Its "
                        r"toolchain\ is searched FIRST -- that is where the "
                        "shipped compiler lives; the plugin never carries one.")
    p.add_argument("--nimony", default=None,
                   help="override the nimony checkout")
    p.add_argument("--only", nargs="*", default=None,
                   help="build only these mod directory names")
    p.add_argument("--force", action="store_true", help="ignore the cache")
    p.add_argument("--check", action="store_true",
                   help="report what would build; build nothing")
    p.add_argument("--json", action="store_true")
    p.add_argument("--progress", default=None,
                   help="write JSON-lines build progress to this file, for "
                        "the in-game mod-loading screen to render live")
    p.add_argument("--screen", default=None,
                   help="plain-text file the in-game loading screen renders "
                        "VERBATIM, rewritten in full on every event")
    p.add_argument("--ucrt64", default=None,
                   help="override msys2's ucrt64 bin; must precede Git's "
                        "mingw64 on PATH")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    install = args.install
    if install is None and args.mods:
        # `--mods <install>\mods` implies the install one level up. Convenient,
        # and it means the shipped startup path needs one argument, not three.
        parent = os.path.dirname(os.path.abspath(args.mods.rstrip("\\/")))
        if os.path.isdir(os.path.join(parent, TOOLCHAIN_SUBDIR)):
            install = parent
    nimony_root, ucrt64, tc_source = find_toolchain(install, args.nimony,
                                                    args.ucrt64)
    args.nimony, args.ucrt64 = nimony_root, ucrt64
    if not args.json:
        print("toolchain: %s" % tc_source)

    nimony_exe = os.path.join(args.nimony, "bin", "nimony.exe")
    if not os.path.isfile(nimony_exe):
        alt = os.path.join(args.nimony, "bin", "nimony")
        nimony_exe = alt if os.path.isfile(alt) else nimony_exe
    if not os.path.isfile(nimony_exe):
        msg = ("no nimony compiler at %s. A mods folder that ships SOURCE "
               "cannot be built without one, so this refuses rather than "
               "leaving whatever .dll happens to be on disk in place and "
               "reporting success." % nimony_exe)
        print(jsonmod.dumps({"error": msg}) if args.json else msg)
        return 3

    if not os.path.isdir(args.mods):
        msg = "no mods folder at %s" % args.mods
        print(jsonmod.dumps({"error": msg}) if args.json else msg)
        return 3

    dirs = sorted(
        os.path.join(args.mods, n) for n in os.listdir(args.mods)
        if os.path.isdir(os.path.join(args.mods, n)) and n not in SKIP_DIRS)
    if args.only:
        want = set(args.only)
        dirs = [d for d in dirs if os.path.basename(d) in want]

    cenv, missing_ucrt = build_env(args.ucrt64, args.nimony)
    if missing_ucrt:
        msg = ("no msys2 ucrt64 bin at %s. Without it gcc resolves to Git for "
               "Windows' mingw64, cc1 loads the wrong libgcc/libgmp/zlib and "
               "dies WITH NO DIAGNOSTIC -- every mod would report a bare link "
               "failure that reads like a code error and is not one. Refusing "
               "rather than producing that." % missing_ucrt)
        print(jsonmod.dumps({"error": msg}) if args.json else msg)
        return 3

    results = []
    prog = Progress(args.progress, len(dirs), args.screen)
    for d in dirs:
        prog.starting(os.path.basename(d.rstrip("\\/")))
        res = build_one(d, args.abi, args.aowl_src, nimony_exe, args.nimony,
                        args.force, args.check, args.verbose, cenv)
        prog.done(res)
        results.append(res)
        if not args.json:
            s = res["status"]
            line = "  %-9s %s" % (s, res["mod"])
            if s == "built":
                line += "  (%.1fs)" % res.get("seconds", 0)
            elif s in ("failed", "skipped"):
                line += "  -- " + res.get("why", "")
            print(line)
            for extra in res.get("output", []):
                print("      | " + extra[:160])

    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    failed = counts.get("failed", 0)
    prog.finished(counts, failed)

    if args.json:
        print(jsonmod.dumps({"counts": counts, "mods": results},
                            separators=(",", ":")))
    else:
        print("\n" + "  ".join("%s=%d" % kv for kv in sorted(counts.items())))
        if failed:
            print("%d mod(s) FAILED to compile. Their previous .dll and cache "
                  "key were removed, so nothing stale is left behind claiming "
                  "to be the new build." % failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
