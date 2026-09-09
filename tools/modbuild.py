#!/usr/bin/env python3
r"""modbuild.py -- compile a mods folder from SOURCE, with a content cache.

    python tools/modbuild.py --mods D:\Aowlspt\aowlspt\mods
    python tools/modbuild.py --mods ... --check      say what WOULD build, build nothing
    python tools/modbuild.py --mods ... --force      ignore the cache
    python tools/modbuild.py --mods ... --json       one line, machine-readable
    python tools/modbuild.py --audit-imports         scan only: which mods
                                                     import a file OUTSIDE
                                                     themselves (exit 1 if any)
    python tools/modbuild.py --clean-verify          --force + delete every
                                                     selected mod's nimcache

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

## Failures are cached too, and why that is not hiding them

A failed mod has no `.dll` and no `.cachekey` (by the rule just above), so
until 2026-09-01 it was recompiled in full on EVERY run -- plus the retry with
`nimcache` cleared, i.e. roughly two whole compiles per launch, for ever.
Measured: three broken mods turned a 0.45s all-cached startup into 60.5s, every
boot, silently.

So a diagnosed failure is recorded in `bin/<stem>.failkey` under the SAME cache
key as a success. Change the mod's sources, `abi/`, `aowl/src`, a compile flag
or the compiler, and it is retried; change nothing and the same verdict is
reported in about a millisecond.

Two rules keep this from becoming a lie:

  * it still reports **`failed`**, never a quieter fourth state. `FAILED` is
    the control word the in-game loading step keys on and the player must see
    it -- a mod that does not build is exactly as broken on the tenth boot as
    on the first. The report says the verdict came from cache so that a 0.0s
    failure cannot be misread as a tool that did not try.
  * **only a DIAGNOSED failure is cached.** If the compiler said nothing this
    tool recognises, the cause is probably environmental (wrong gcc on PATH, no
    ucrt64, a full disk, antivirus on the output) -- the kind of failure that
    fixes itself. Caching one would freeze a transient into a permanent verdict
    clearable only with `--force`. A slow retry is the right answer to a
    failure we cannot explain.
"""

from __future__ import annotations

import argparse
import hashlib
import json as jsonmod
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modloadfmt  # noqa: E402 -- the ONE renderer for the loading step

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
        # Vendored mimalloc with its debug machinery OFF -- identical to
        # `mimallocFlags` in tools/aowl.nim, which carries the measurement.
        # Short version: MI_DEBUG defaults to 2, and `mi_error_default`
        # (mimalloc src/options.c:543) calls abort() on EFAULT only under
        # `#if (MI_DEBUG>0)`. That abort killed the client on 2026-09-03 with
        # "corrupted thread-free list." (src/page.c:205).
        "--passC:-DMI_BUILD_RELEASE", "--passC:-DMI_DEBUG=0",
        "--passC:-I" + abi_dir,
        "--passC:-I" + mod_dir,
        "-p:" + aowl_src,
        # `abi/` as a NIM path too: `abi/aowlspt_symtab.nim` is the Nim view of
        # the generated symbol table and `mods/sain` imports it. Without this
        # the only way to reach it was a checkout-relative path that resolves
        # in the repo and nowhere else -- see the matching comment in
        # `tools/aowl.nim`'s buildMod, which must stay identical to this.
        "-p:" + abi_dir,
        "-p:" + os.path.join(nimony_root, "src", "lib"),
        "-o:" + out,
        source,
    ]


# ---------------------------------------------------------------------------
# THE ESCAPING-IMPORT AUDIT, and why a clean rebuild is NOT the check that
# catches this class.
#
# MEASURED 2026-09-02. `mods/manager` failed to compile from a public payload
# with `nifcursors.nim(149, 3) c.p != nil and c.rem > 0 [AssertionDefect]` --
# nimony crashing inside its own error renderer, so the actual semantic error
# was never printed. The cause was ONE line, `mgr/refresh.nim`'s
# `import "../../../registry/validate"`: a path that resolves in this checkout
# and nowhere else. `aowl payload` stages only `mods/`, `tools/`, `abi/` and
# `aowl/src`, so in an install that file is simply absent.
#
# The obvious guard -- "rebuild every mod from a clean nimcache" -- CANNOT
# catch it, and this was measured, not assumed: with `mods/manager/nimcache`
# deleted, both `aowl build-mod mods\manager` and `modbuild.py --only manager
# --force` built the broken source successfully in 30s, because the escaping
# import resolves fine when the compile happens inside the repo. A check whose
# input never varies in the dimension that breaks is a check that cannot fail.
#
# What CAN fail is the payload-shape property, stated as a negative: **no file
# a mod ships may resolve outside that mod's own folder.** That is what this
# scans for, and it is cheap enough (a regex over the mod's .nim files) to run
# on every build, cached or not -- so a `cached` verdict can no longer hide it
# either.
#
# Intra-mod `..` is legitimate and common (`mods/sain/client/driver.nim` says
# `import ".." / core / vec`), so the test is not "contains ..": it resolves
# the literal against the importing file and asks whether the result is still
# under the mod root.
IMPORT_RE = re.compile(
    r"^\s*(?:from\s+(?P<from>\S.*?)\s+import\b|(?P<kw>import|include)\b"
    r"(?P<rest>.*)$)")


def _import_specs(line):
    """The module path literals on one import/include line, un-quoted and with
    nimony's `".." / core / vec` spelling folded back to `../core/vec`."""
    line = line.split("#")[0]
    m = IMPORT_RE.match(line)
    if not m:
        return []
    body = m.group("from") if m.group("from") else (m.group("rest") or "")
    out = []
    for part in body.split(","):
        part = part.strip()
        if not part or "[" in part:      # `std/[syncio, dirs]` never escapes
            continue
        # Fold `".." / core / vec` and `"../a/b"` into one plain path.
        part = part.replace('"', "").replace("'", "")
        part = re.sub(r"\s*/\s*", "/", part).strip()
        if part:
            out.append(part)
    return out


def escaping_imports(mod_dir):
    """Every (file, spec) in `mod_dir` whose import resolves OUTSIDE it.

    Returns a list of `(relative source path, line number, spec, resolved)`.
    An empty list is the property holding; it is deliberately the NEGATIVE
    ("nothing escapes"), because a positive self-comparison here could not
    fail."""
    root = os.path.abspath(mod_dir)
    bad = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            if not fn.endswith(".nim"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            for i, line in enumerate(lines, 1):
                for spec in _import_specs(line):
                    if ".." not in spec.split("/"):
                        continue        # a search-path import; not a file path
                    resolved = os.path.normpath(os.path.join(dirpath, spec))
                    if os.path.commonpath([root, resolved]) != root:
                        bad.append((os.path.relpath(path, root), i, spec,
                                    resolved))
    return bad


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

    # ---- the in-game loading step --------------------------------------
    #
    # A SECOND file, plain text, rewritten in full on every event. The host
    # renders it VERBATIM.
    #
    # THE FORMAT IS EXACTLY THREE LINES. Anything past the third is dropped by
    # the host, which says so once. Keep this in step with the header comment
    # of host/Aowlspt.Host.Il2Cpp/modload.nim -- this function is the ONLY
    # writer, and the host deliberately parses nothing but the two control
    # words on line 0.
    #
    #     line 0   WHAT IT IS DOING NOW -- and the control line.
    #              starts with "MODS READY"  = the build is finished
    #              contains  "FAILED"        = it finished badly
    #     line 1   OVERALL progress
    #     line 2   the CURRENT STEP's progress
    #
    #     Loading mods: maps
    #     Mods 7 of 15
    #     maps  building
    #
    # It used to be a title plus one row PER MOD, i.e. the whole history. Seen
    # live that reads as a debug ledger, not as a loading caption: the game's
    # own captions say one thing at a time. The per-mod history did not go
    # anywhere -- it is still in the JSON-lines stream above, which is the
    # right place for a record nobody is watching in real time.
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
    # The FORMAT itself lives in `tools/modloadfmt.py`, shared with
    # `tools/modloadsim.py`. It was copied into both, and the copies had
    # already drifted -- this one wrote CRLF (Python text mode on Windows),
    # the simulator wrote LF. The host tolerated it; the next difference
    # might not have. There is now one renderer, and neither file may grow
    # its own.

    def render(self):
        if not self.screen:
            return
        cur = self.order[-1] if self.order else ""
        if getattr(self, "done_all", False):
            bad = [n for n, r in self.rows.items() if r[0] == "failed"]
            lines = modloadfmt.ready(len(self.rows), self.total, bad)
        elif not cur:
            lines = modloadfmt.queued(self.total)
        else:
            st, extra = self.rows.get(cur, ("", ""))
            lines = modloadfmt.building(cur, self.i, self.total, st, extra)
        try:
            modloadfmt.write(self.screen, lines)
        except OSError:
            pass


ERROR_MARKS = ("error:", "warning: ", "cannot open", "undeclared identifier",
               "ambiguous identifier", "file not found")
DIAG_AFTER = 3
DIAG_MAX = 12


def diagnostics(stderr, stdout):
    """The lines that say WHY, not the last lines printed.

    This used to be `splitlines()[-6:]` -- the TAIL. nimony ends a failed build
    with a `FAILURE: <the entire nifmake command line>` banner that is itself
    several hundred characters, and the caller then truncates each line to 160
    characters. The result was that three mods reported nothing but
    `nimony exited 1` and half a path, and every real diagnostic -- a missing
    import, an unresolved include, an ambiguous identifier -- had been pushed
    off the top by the banner announcing that a failure had occurred. Finding
    the actual cause meant re-running each compile by hand.

    So: keep the lines that carry a diagnostic marker, plus the `DIAG_AFTER`
    lines after each (nimony puts the offending expression and the type
    mismatch detail underneath its `Error:` line), de-duplicated and in source
    order. The FAILURE banner is dropped unless nothing else matched.

    Falls back to the tail when no line carries a marker -- a build that failed
    with no recognisable diagnostic still has to show SOMETHING, and silently
    returning an empty list would read as "it failed and said nothing", which
    is a different and much rarer fact than "we did not recognise its output".
    """
    text = ((stderr or "") + "\n" + (stdout or "")).strip()
    lines = [l.rstrip() for l in text.splitlines() if l.strip()]
    if not lines:
        return []
    keep = set()
    for i, l in enumerate(lines):
        low = l.lower()
        if low.startswith("failure:"):
            # The banner. It names the command, never the cause.
            continue
        if any(m in low for m in ERROR_MARKS):
            for j in range(i, min(i + 1 + DIAG_AFTER, len(lines))):
                if not lines[j].lower().startswith("failure:"):
                    keep.add(j)
    if not keep:
        return lines[-6:]
    return [lines[i] for i in sorted(keep)][:DIAG_MAX]


def write_failure(failfile, key, why, diag, stderr, stdout):
    """Record a failure so an unchanged broken mod is not recompiled every boot.

    ONLY A DIAGNOSED FAILURE IS CACHED. If `diagnostics` recognised nothing --
    no `Error:`, no `cannot open`, no `file not found` -- the compile failed for
    a reason the compiler did not articulate, and the overwhelmingly likely
    causes are environmental: the wrong gcc on PATH, a missing ucrt64, a full
    disk, an antivirus holding the output. Those are exactly the failures that
    fix themselves, and caching one would turn a transient into a permanent
    verdict that only `--force` could clear. A slow retry is the right answer
    for a failure we cannot explain; an instant wrong answer is not.
    """
    if not diag:
        return False
    raw = ((stderr or "") + "\n" + (stdout or "")).strip()
    try:
        os.makedirs(os.path.dirname(failfile), exist_ok=True)
        with open(failfile, "w", encoding="utf-8", newline="\n") as f:
            jsonmod.dump({"key": key, "why": why, "output": diag,
                          "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                          # The full text, so a cached verdict can still be
                          # investigated without reproducing the build.
                          "raw": raw[-8000:]}, f, indent=1)
    except OSError:
        return False
    return True


def read_failure(failfile, key):
    """The recorded failure IF it was recorded for this exact key, else None.

    A key mismatch is not an error and not a stale-file warning: it means the
    inputs changed, which is precisely when the mod must be retried.
    """
    try:
        with open(failfile, "r", encoding="utf-8") as f:
            rec = jsonmod.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(rec, dict) or rec.get("key") != key:
        return None
    return rec


def build_one(mod_dir, abi_dir, aowl_src, nimony_exe, nimony_root,
              force, check, verbose, env):
    name = os.path.basename(mod_dir.rstrip("\\/"))
    source = mod_source(mod_dir)
    if not source:
        return {"mod": name, "status": "skipped",
                "why": "no single top-level .nim source"}

    # BEFORE the cache is consulted, so a `cached` verdict cannot hide it, and
    # before the compiler runs, because nimony crashes in its own error
    # renderer on this input and never names the file (see IMPORT_RE above).
    escapes = escaping_imports(mod_dir)
    if escapes:
        why = ("%d import(s) resolve OUTSIDE the mod folder, so this mod "
               "compiles only inside the aowlspt checkout and not in any "
               "install" % len(escapes))
        return {"mod": name, "status": "failed", "why": why,
                "escapes": [{"file": f, "line": ln, "spec": s,
                             "resolves_to": r} for f, ln, s, r in escapes],
                "output": ["%s(%d) import %s -> %s" % (f, ln, s, r)
                           for f, ln, s, r in escapes]}

    stem = os.path.splitext(os.path.basename(source))[0]
    bin_dir = os.path.join(mod_dir, "bin")
    out = os.path.join(bin_dir, stem + ".dll")
    keyfile = os.path.join(bin_dir, stem + ".cachekey")
    failfile = os.path.join(bin_dir, stem + ".failkey")

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

        # THE FAILURE IS CACHED TOO, under the same key.
        #
        # Measured 2026-09-01: three mods that cannot compile turned a 0.45s
        # all-cached startup into 60.5s, on EVERY launch, for ever. A failed
        # mod deliberately has no `.dll` and no `.cachekey` (so a stale binary
        # can never masquerade as a fresh one), and the consequence was that it
        # was rebuilt in full every single time -- plus modbuild's own retry
        # with `nimcache` cleared, so roughly two full compiles per boot. The
        # player pays a silent minute per launch and nothing says why.
        #
        # The key is the SAME cache key as a success, so it already covers the
        # mod's sources, `abi/`, `aowl/src`, the compile flags and the compiler
        # binary. Change any of those and the mod is retried; change none and
        # the verdict is reported instantly from disk.
        #
        # It still reports `failed`, NOT a third state. `FAILED` is the host's
        # control word for the loading step and the player must see it: a mod
        # that does not build is exactly as broken on the tenth boot as on the
        # first, and hiding that because we already knew would be the worst
        # kind of caching.
        fail = read_failure(failfile, key)
        if fail is not None:
            return {"mod": name, "status": "failed",
                    "why": fail.get("why", "the previous build failed"),
                    "output": fail.get("output", []),
                    "from_cache": True}

    if check:
        return {"mod": name, "status": "would-build"}

    # Remove the previous output AND its key BEFORE compiling. If the compile
    # fails we must not be left holding a stale dll that the next run would
    # accept as current -- a failure that looks like a success is the single
    # worst outcome this repo produces. The failure record goes too: we are
    # about to find out afresh, and a leftover one could otherwise outlive the
    # compile that disproved it.
    for p in (out, keyfile, failfile):
        try:
            os.remove(p)
        except OSError:
            pass
    os.makedirs(bin_dir, exist_ok=True)

    t0 = time.time()

    def run_compile():
        """The compile, with the compiler failing to START treated as a mod
        failure rather than as an exception.

        `subprocess.run` RAISES if the executable cannot be launched at all --
        it is missing, it is not a valid PE, it is the wrong architecture, or a
        virus scanner has it locked. Unhandled, that traceback aborts the whole
        run: every mod after this one is silently never attempted, and the
        summary the caller prints never appears. One unusable compiler must
        cost one mod, not the batch.

        These are also precisely the failures that must NOT be cached, and they
        are not: the returned diagnostic list is empty, and `write_failure`
        refuses an empty list.
        """
        try:
            return subprocess.run(cmd, cwd=mod_dir, capture_output=True,
                                  text=True, env=env), None
        except OSError as e:
            return None, ("the compiler could not be started: %s. This is an "
                          "environment problem, not a problem with the mod -- "
                          "%s" % (e, cmd[0]))

    r, launch_err = run_compile()
    if launch_err:
        return {"mod": name, "status": "failed", "why": launch_err,
                "output": []}
    if r.returncode != 0:
        # One retry with the cache cleared. nimony's incremental cache does not
        # always survive a source file being ADDED to a mod: it fails at link
        # with an undefined string literal, which reads like a code error and is
        # not one. aowl.nim does exactly this; a second failure is real.
        cache = os.path.join(mod_dir, "nimcache")
        if os.path.isdir(cache):
            shutil.rmtree(cache, ignore_errors=True)
            r2, launch_err = run_compile()
            if launch_err:
                return {"mod": name, "status": "failed", "why": launch_err,
                        "output": []}
            r = r2
    if r.returncode != 0:
        why = "nimony exited %d" % r.returncode
        diag = diagnostics(r.stderr, r.stdout)
        write_failure(failfile, key, why, diag, r.stderr, r.stdout)
        return {"mod": name, "status": "failed", "why": why, "output": diag}

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
    p.add_argument("--clean-verify", action="store_true",
                   help="implies --force AND deletes each selected mod's "
                        "nimcache first, so no incremental state can carry a "
                        "verdict. This is what the nightly/payload path runs. "
                        "NOTE: on its own it does NOT catch a checkout-only "
                        "import -- that is what the escaping-import audit is "
                        "for, and the audit runs on every build.")
    p.add_argument("--audit-imports", action="store_true",
                   help="scan only: list every import in the selected mods "
                        "that resolves outside its own mod folder, compile "
                        "nothing. Exit 1 if any is found.")
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

    # ABSOLUTISE the mods root before anything derives from it. Every compile
    # runs with cwd=<mod dir>, so a RELATIVE --mods makes the source path
    # relative to the wrong directory and nimony reports `cannot open file:
    # examples/reactivedemo/reactivedemo.nim` -- which reads as a missing file
    # rather than as a resolved-from-the-wrong-place one. It only ever worked
    # because the DEFAULT is repo-absolute.
    args.mods = os.path.abspath(args.mods)
    args.abi = os.path.abspath(args.abi)
    args.aowl_src = os.path.abspath(args.aowl_src)

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

    if args.audit_imports:
        findings = []
        for d in dirs:
            for f, ln, s, r in escaping_imports(d):
                findings.append({"mod": os.path.basename(d.rstrip("\\/")),
                                 "file": f, "line": ln, "spec": s,
                                 "resolves_to": r})
        if args.json:
            print(jsonmod.dumps({"escaping_imports": findings},
                                separators=(",", ":")))
        elif not findings:
            print("no import in %d mod(s) resolves outside its own mod folder"
                  % len(dirs))
        else:
            for f in findings:
                print("  %s: %s(%d) import %s -> %s"
                      % (f["mod"], f["file"], f["line"], f["spec"],
                         f["resolves_to"]))
            print("\n%d escaping import(s). These compile in this checkout "
                  "and in NO install." % len(findings))
        return 1 if findings else 0

    if args.clean_verify:
        args.force = True
        for d in dirs:
            shutil.rmtree(os.path.join(d, "nimcache"), ignore_errors=True)

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
                if res.get("from_cache"):
                    # Said out loud. A failure reported in 0.0s looks like a
                    # tool that did not try, and the difference between "it
                    # failed again" and "it has not changed since it failed"
                    # is the whole point of caching it.
                    line += "  (unchanged since it last failed; not recompiled)"
            print(line)
            for extra in res.get("output", []):
                print("      | " + extra[:240])

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
