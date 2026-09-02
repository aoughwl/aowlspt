#!/usr/bin/env python3
r"""modharness.py -- run a mod's LOAD PATH offline, with no game and no client.

    python tools/modharness.py mods/sain/bin/sain.dll
    python tools/modharness.py --all
    python tools/modharness.py --all --side server
    python tools/modharness.py mods/fov/bin/fov.dll --trace-host -v

Exit codes: 0 PASS, 1 FAIL, 3 INCONCLUSIVE.  Three outcomes, never two.

## Why this exists

`mods/sain/sain.nim`'s `declareSainSettings` is a publish-once selftest guarding
a measured use-after-free: `gDeclared` is written by the thread that loads the
mod and walked by whatever thread delivers `aowlspt.settings.pageQuery`, and a
second `declareSettings` frees the seq under that reader.  The selftest shipped
compiled and had **never executed**, because the only way to run a mod's
`on_load` was a full client boot -- ~3 minutes, the build slot, and a human
watching the screen.

This harness runs the same code path in about a second, from a shell, against
the DLL that is already built.  It implements the host side of
`abi/aowlspt_abi.h` in ctypes: it loads the DLL, checks the three exported
symbols, calls `aowlspt_init` with a STUB `AowlHostApi` where every entry point
answers deterministically, calls `on_load` exactly as the host does, and then
delivers the three settings events the host would -- **twice** -- asserting that
what comes back is strict JSON and is byte-identical between the two
deliveries.  The use-after-free makes the second delivery differ or fault.

## The isolation, and why it is a process and not a try/except

A mod that faults is the case this tool exists to catch, so the fault must
become a verdict rather than a traceback.  Each mod runs in a child process
(`--worker`) that appends a phase name to a progress file before every step and
flushes.  If the child dies without writing its result -- access violation,
`abort()`, a stack overflow ctypes cannot intercept -- the parent reads the last
phase and reports `FAIL <mod>: faulted during <phase>`.  A hang is a timeout,
also FAIL, also naming the phase.  The harness itself never dies with the mod.

## WHAT THE STUB CANNOT EMULATE -- so a PASS is never overclaimed

There is no IL2CPP runtime, no Unity, no `GameAssembly.dll`, no SPT database and
no HTTP listener in this process.  Every host export that would reach one of
those is answered with a documented refusal, and every refusal is COUNTED and
printed under `not emulated` for the run, so the report says which parts of the
mod's load path were never really exercised:

    call, resolve            -> ERR_UNSUPPORTED  (no managed runtime)
    patch, patch_typed       -> ERR_UNSUPPORTED  (nothing to detour)
    handle_pointer/_pin      -> ERR_UNSUPPORTED  (no managed heap)
    invoke_main, invoke_render -> ERR_UNSUPPORTED (no Unity thread, no frame)
    db_get, db_patch         -> ERR_UNSUPPORTED  (db.json is not loaded)
    notify_push              -> ERR_NOT_FOUND    (no websocket for any session)
    schedule                 -> ERR_UNSUPPORTED  (deliberate: see below)

`schedule` refuses rather than returning OK, because returning OK for a callback
that will never fire is precisely the check-that-cannot-fail this repo keeps
being bitten by -- a mod would record "armed" and wait forever.  `ERR_UNSUPPORTED`
is a state real mods already handle.

What IS emulated for real, because it is pure data:

    config_get   reads the mod's own config.json off disk (dotted paths too)
    config_set   an in-memory overlay -- NOTHING IS WRITTEN TO DISK, so an
                 applyQuery cannot mutate the repo's config.json
    store_*      an in-memory key/value map
    log          printed, with the level, prefixed by the mod
    alloc/free   msvcrt malloc/free, used by both sides consistently
    event_*      a real subscriber table and a real synchronous broadcast
    route_register  recorded (the URL is reported), never served

So a PASS here means: *this mod's load path and its settings transport are
correct in the absence of the game.*  It does not and cannot mean the mod works
in a raid.

## What it asserts (CLAUDE.md 9b: assert the finished state, prefer negatives)

* `aowlspt_abi_version()` matches the header the harness parsed, not a constant
  typed in here -- so bumping the ABI cannot make this pass vacuously.
* `on_load` returns OK.
* A **second** `on_load` is REFUSED rather than publishing a second
  schema: the page the mod serves must be byte-identical across it.  The
  client host ran init+on_load twice per mod for a whole session
  (2026-09-02) because two load paths reached one directory, so this is
  not hypothetical -- and the loader-side guard is one process's worth of
  protection, while the mod's own guard is what stops its rows being
  freed under a live reader.
* Every payload emitted on an announce event `json.loads` under STRICT JSON.
  Not `contains`, not "it looked like a list" -- the backend selftest passed for
  months on a substring check against something that was not JSON at all.
* Delivery 2 is byte-identical to delivery 1.  A negative can be falsified.
* If nothing at all came back, that is INCONCLUSIVE.  "I could not look" is not
  a pass, and a mod that subscribed to nothing is not a mod that answered.

## The negative control

`tests/modharness_bad/` is a mod that declares settings normally and then
dereferences a null pointer on the SECOND `pageQuery`.  It must FAIL, naming the
phase.  A harness whose failing case has never fired is a harness that cannot
fail.
"""

from __future__ import annotations

import argparse
import ctypes as ct
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ABI_HEADER = REPO / "abi" / "aowlspt_abi.h"

OK = 0
ERR_GENERIC = -1
ERR_ABI = -2
ERR_NOT_FOUND = -3
ERR_BAD_ARG = -4
ERR_DECODE = -5
ERR_UNSUPPORTED = -6

SIDE_SERVER, SIDE_CLIENT, SIDE_SIM = 1, 2, 3
SIDE_NAMES = {"server": SIDE_SERVER, "client": SIDE_CLIENT, "sim": SIDE_SIM}
LEVELS = ["trace", "debug", "info", "ok", "warn", "error"]

EV_INDEX_QUERY = "aowlspt.settings.indexQuery"
EV_INDEX_ANNOUNCE = "aowlspt.settings.indexAnnounce"
EV_PAGE_QUERY = "aowlspt.settings.pageQuery"
EV_PAGE_ANNOUNCE = "aowlspt.settings.pageAnnounce"
EV_APPLY_QUERY = "aowlspt.settings.applyQuery"
EV_APPLY_ANNOUNCE = "aowlspt.settings.applyAnnounce"
ANNOUNCES = (EV_INDEX_ANNOUNCE, EV_PAGE_ANNOUNCE, EV_APPLY_ANNOUNCE)


def header_abi_version() -> "tuple[int|None,int|None]":
    """(version, revision) read from abi/aowlspt_abi.h.

    Read, never typed in: a harness carrying its own copy of the number it is
    checking is a check that cannot fail when the ABI moves.
    """
    try:
        text = ABI_HEADER.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return (None, None)
    v = re.search(r"#define\s+AOWLSPT_ABI_VERSION\s+(\d+)", text)
    r = re.search(r"#define\s+AOWLSPT_ABI_REVISION\s+(\d+)", text)
    return (int(v.group(1)) if v else None, int(r.group(1)) if r else None)


# ---------------------------------------------------------------------------
# The ABI, in ctypes.  Field order is abi/aowlspt_abi.h's, verbatim.
# ---------------------------------------------------------------------------

class Slice(ct.Structure):
    _fields_ = [("ptr", ct.POINTER(ct.c_ubyte)), ("len", ct.c_int32)]


class Buffer(ct.Structure):
    _fields_ = [("ptr", ct.POINTER(ct.c_ubyte)), ("len", ct.c_int32)]


class HostInfo(ct.Structure):
    _fields_ = [
        ("size", ct.c_int32),
        ("abi_version", ct.c_uint32),
        ("abi_revision", ct.c_uint32),
        ("side", ct.c_int32),
        ("host_name", Slice),
        ("host_version", Slice),
        ("spt_version", Slice),
        ("game_version", Slice),
        ("encodings", ct.c_uint32),
        ("mod_dir", Slice),
        ("data_dir", Slice),
    ]


class ModInfo(ct.Structure):
    _fields_ = [
        ("size", ct.c_int32),
        ("abi_version", ct.c_uint32),
        ("abi_revision", ct.c_uint32),
        ("guid", Slice),
        ("name", Slice),
        ("author", Slice),
        ("version", Slice),
        ("spt_range", Slice),
        ("sides", ct.c_uint32),
        ("flags", ct.c_uint32),
    ]


CB = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.POINTER(Buffer))
ROUTE = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, Slice, Slice, ct.POINTER(Buffer))
PATCH = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, Slice, ct.POINTER(Buffer))
TPATCH = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.c_void_p)

F_ALLOC = ct.CFUNCTYPE(ct.c_void_p, ct.c_void_p, ct.c_int32)
F_FREE = ct.CFUNCTYPE(None, ct.c_void_p, ct.c_void_p)
F_LOG = ct.CFUNCTYPE(None, ct.c_void_p, ct.c_int32, Slice)
F_LASTERR = ct.CFUNCTYPE(None, ct.c_void_p, ct.POINTER(Slice))
F_SB = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.POINTER(Buffer))
F_SS = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, Slice)
F_ROUTEREG = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.c_int32, ROUTE, ct.c_void_p)
F_SUB = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, CB, ct.c_void_p)
F_EMIT = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, Slice)
F_CALL = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, Slice, ct.POINTER(Buffer))
F_RESOLVE = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.POINTER(ct.c_uint64))
F_HREL = ct.CFUNCTYPE(None, ct.c_void_p, ct.c_uint64)
F_PATCH = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.c_int32, PATCH, ct.c_void_p)
F_SCHED = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.c_int32, CB, ct.c_void_p)
F_INVOKE = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, CB, ct.c_void_p)
F_NOW = ct.CFUNCTYPE(ct.c_int64, ct.c_void_p)
F_HPTR = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.c_uint64, ct.POINTER(ct.c_uint64))
F_HPIN = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.c_uint64, ct.POINTER(ct.c_uint64))
F_TPATCH = ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice, ct.c_int32, TPATCH, ct.c_void_p)


class HostApi(ct.Structure):
    _fields_ = [
        ("size", ct.c_int32),
        ("ctx", ct.c_void_p),
        ("info", ct.POINTER(HostInfo)),
        ("alloc", F_ALLOC),
        ("free", F_FREE),
        ("log", F_LOG),
        ("last_error", F_LASTERR),
        ("config_get", F_SB),
        ("config_set", F_SS),
        ("db_get", F_SB),
        ("db_patch", F_SS),
        ("route_register", F_ROUTEREG),
        ("event_subscribe", F_SUB),
        ("event_emit", F_EMIT),
        ("call", F_CALL),
        ("resolve", F_RESOLVE),
        ("handle_release", F_HREL),
        ("patch", F_PATCH),
        ("schedule", F_SCHED),
        ("invoke_main", F_INVOKE),
        ("now_ms", F_NOW),
        ("store_get", F_SB),
        ("store_set", F_SS),
        ("store_list", F_SB),
        ("handle_pointer", F_HPTR),
        ("handle_pin", F_HPIN),
        ("patch_typed", F_TPATCH),
        ("notify_push", F_SS),
        ("invoke_render", F_INVOKE),
    ]


class ModApi(ct.Structure):
    _fields_ = [
        ("size", ct.c_int32),
        ("self", ct.c_void_p),
        ("on_load", ct.CFUNCTYPE(ct.c_int32, ct.c_void_p)),
        ("on_update", ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.c_int64)),
        ("on_unload", ct.CFUNCTYPE(ct.c_int32, ct.c_void_p)),
        ("state_save", ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, ct.POINTER(Buffer))),
        ("state_load", ct.CFUNCTYPE(ct.c_int32, ct.c_void_p, Slice)),
    ]


# ---------------------------------------------------------------------------
# The stub host
# ---------------------------------------------------------------------------

_msvcrt = ct.cdll.msvcrt
_msvcrt.malloc.restype = ct.c_void_p
_msvcrt.malloc.argtypes = [ct.c_size_t]
_msvcrt.free.restype = None
_msvcrt.free.argtypes = [ct.c_void_p]


def sl(b: bytes, keep: list) -> Slice:
    if not b:
        return Slice(None, 0)
    buf = ct.create_string_buffer(b, len(b))
    keep.append(buf)
    return Slice(ct.cast(buf, ct.POINTER(ct.c_ubyte)), len(b))


def rd(s: Slice) -> bytes:
    if not s.ptr or s.len <= 0:
        return b""
    return ct.string_at(ct.cast(s.ptr, ct.c_void_p), s.len)


class StubHost:
    """Every host export the mod can resolve, answering deterministically.

    `calls` counts by export name; `refusals` counts the ones that refused
    because there is no game in this process.  Both are reported, so the run
    says what it did NOT exercise instead of implying it exercised everything.
    """

    def __init__(self, mod_dir: Path, data_dir: Path, side: int, log_min: int,
                 trace: bool, out=sys.stdout):
        self.mod_dir = mod_dir
        self.data_dir = data_dir
        self.side = side
        self.log_min = log_min
        self.trace = trace
        self.out = out
        self.keep: list = []
        self.logs: list[tuple[int, str]] = []
        self.calls: dict[str, int] = {}
        self.refusals: dict[str, int] = {}
        self.subs: list[tuple[str, object, int]] = []
        self.routes: list[str] = []
        self.patches: list[str] = []
        self.emitted: list[tuple[str, str]] = []
        self.capture: "list[tuple[str,str]] | None" = None
        self.store: dict[str, bytes] = {}
        self.cfg_overlay: dict[str, bytes] = {}
        self.last_err = b""
        self.config = self._load_config()
        self._build()

    # -- config.json, read for real (it is small, and it is pure data) ------
    def _load_config(self) -> dict:
        p = self.mod_dir / "config.json"
        if not p.is_file():
            return {}
        try:
            raw = p.read_bytes()
            if raw[:3] == b"\xef\xbb\xbf":
                raw = raw[3:]
            v = json.loads(raw.decode("utf-8"))
            return v if isinstance(v, dict) else {}
        except Exception:
            return {}

    def _cfg_lookup(self, key: str):
        if key in self.config:
            return True, self.config[key]
        cur = self.config
        for part in key.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                return False, None
        return True, cur

    # -- bookkeeping --------------------------------------------------------
    def _hit(self, name: str, refused: bool = False):
        self.calls[name] = self.calls.get(name, 0) + 1
        if refused:
            self.refusals[name] = self.refusals.get(name, 0) + 1
        if self.trace:
            print(f"      host.{name}{' -> REFUSED' if refused else ''}",
                  file=self.out)

    def _give(self, out_ptr, payload: bytes) -> int:
        """Hand an owned buffer back through an AowlBuffer*, host-allocated."""
        if not out_ptr:
            return OK
        if not payload:
            out_ptr[0] = Buffer(None, 0)
            return OK
        p = _msvcrt.malloc(len(payload))
        if not p:
            return ERR_GENERIC
        ct.memmove(p, payload, len(payload))
        out_ptr[0] = Buffer(ct.cast(p, ct.POINTER(ct.c_ubyte)), len(payload))
        return OK

    def _refuse(self, name: str, msg: str, code: int = ERR_UNSUPPORTED) -> int:
        self._hit(name, refused=True)
        self.last_err = msg.encode("utf-8")
        return code

    # -- the table ----------------------------------------------------------
    def _build(self):
        k = self.keep

        def f_alloc(ctx, n):
            self._hit("alloc")
            return _msvcrt.malloc(max(1, n)) if n > 0 else None

        def f_free(ctx, p):
            self._hit("free")
            if p:
                _msvcrt.free(p)

        def f_log(ctx, level, msg):
            self._hit("log")
            text = rd(msg).decode("utf-8", "replace")
            self.logs.append((level, text))
            if level >= self.log_min:
                tag = LEVELS[level] if 0 <= level < len(LEVELS) else str(level)
                print(f"      [{tag:5}] {text}", file=self.out)

        def f_lasterr(ctx, out):
            self._hit("last_error")
            if out:
                out[0] = sl(self.last_err, k)

        def f_config_get(ctx, key, out):
            self._hit("config_get")
            name = rd(key).decode("utf-8", "replace")
            if name in self.cfg_overlay:
                return self._give(out, self.cfg_overlay[name])
            found, val = self._cfg_lookup(name)
            if not found:
                self.last_err = b"no such key in config.json"
                return ERR_NOT_FOUND
            return self._give(out, json.dumps(val).encode("utf-8"))

        def f_config_set(ctx, key, value):
            self._hit("config_set")
            # IN MEMORY ONLY.  The harness must never mutate the repo's
            # config.json -- an applyQuery under test would otherwise leave an
            # edit behind and the next run would not be the same run.
            self.cfg_overlay[rd(key).decode("utf-8", "replace")] = rd(value)
            return OK

        def f_db_get(ctx, path, out):
            return self._refuse("db_get", "the SPT database is not loaded in the harness")

        def f_db_patch(ctx, path, patch):
            return self._refuse("db_patch", "the SPT database is not loaded in the harness")

        def f_route(ctx, url, kind, handler, user):
            self._hit("route_register")
            self.routes.append(rd(url).decode("utf-8", "replace"))
            return OK

        def f_sub(ctx, name, handler, user):
            self._hit("event_subscribe")
            self.subs.append((rd(name).decode("utf-8", "replace"), handler,
                              int(user or 0)))
            return OK

        def f_emit(ctx, name, payload):
            self._hit("event_emit")
            nm = rd(name).decode("utf-8", "replace")
            pl = rd(payload).decode("utf-8", "replace")
            self.emitted.append((nm, pl))
            if self.capture is not None:
                self.capture.append((nm, pl))
            return OK

        def f_call(ctx, target, args, out):
            return self._refuse(
                "call", "no managed runtime in the harness: " +
                rd(target).decode("utf-8", "replace"))

        def f_resolve(ctx, tn, out):
            return self._refuse("resolve", "no DI container / no components offline")

        def f_hrel(ctx, h):
            self._hit("handle_release")

        def f_patch(ctx, target, kind, handler, user):
            self.patches.append(rd(target).decode("utf-8", "replace"))
            return self._refuse("patch", "nothing to detour: GameAssembly is not loaded")

        def f_sched(ctx, delay, cb, user):
            # Deliberately a refusal, not OK.  See the module docstring.
            return self._refuse("schedule", "the harness has no timer loop; "
                                "a scheduled callback would never fire")

        def f_invoke_main(ctx, cb, user):
            return self._refuse("invoke_main", "there is no Unity main thread offline")

        def f_now(ctx):
            self._hit("now_ms")
            return int(time.time() * 1000)

        def f_store_get(ctx, key, out):
            self._hit("store_get")
            kk = rd(key).decode("utf-8", "replace")
            if kk not in self.store:
                self.last_err = b"no such stored key"
                return ERR_NOT_FOUND
            return self._give(out, self.store[kk])

        def f_store_set(ctx, key, value):
            self._hit("store_set")
            self.store[rd(key).decode("utf-8", "replace")] = rd(value)
            return OK

        def f_store_list(ctx, prefix, out):
            self._hit("store_list")
            pre = rd(prefix).decode("utf-8", "replace")
            keys = sorted(x for x in self.store if x.startswith(pre))
            return self._give(out, json.dumps(keys).encode("utf-8"))

        def f_hptr(ctx, h, out):
            return self._refuse("handle_pointer", "no managed heap offline")

        def f_hpin(ctx, h, out):
            return self._refuse("handle_pin", "no managed heap offline")

        def f_tpatch(ctx, target, kind, handler, user):
            self.patches.append(rd(target).decode("utf-8", "replace"))
            return self._refuse("patch_typed", "nothing to detour offline")

        def f_notify(ctx, session, payload):
            return self._refuse("notify_push", "no websocket for any session",
                                ERR_NOT_FOUND)

        def f_invoke_render(ctx, cb, user):
            return self._refuse("invoke_render", "there is no render phase offline")

        self._thunks = [
            F_ALLOC(f_alloc), F_FREE(f_free), F_LOG(f_log), F_LASTERR(f_lasterr),
            F_SB(f_config_get), F_SS(f_config_set), F_SB(f_db_get), F_SS(f_db_patch),
            F_ROUTEREG(f_route), F_SUB(f_sub), F_EMIT(f_emit), F_CALL(f_call),
            F_RESOLVE(f_resolve), F_HREL(f_hrel), F_PATCH(f_patch), F_SCHED(f_sched),
            F_INVOKE(f_invoke_main), F_NOW(f_now), F_SB(f_store_get),
            F_SS(f_store_set), F_SB(f_store_list), F_HPTR(f_hptr), F_HPIN(f_hpin),
            F_TPATCH(f_tpatch), F_SS(f_notify), F_INVOKE(f_invoke_render),
        ]

        ver, rev = header_abi_version()
        self.info = HostInfo(
            size=ct.sizeof(HostInfo),
            abi_version=ver or 1, abi_revision=rev or 0, side=self.side,
            host_name=sl(b"aowlspt-modharness", k),
            host_version=sl(b"0.0.0-harness", k),
            spt_version=sl(b"", k), game_version=sl(b"", k),
            encodings=1,  # JSON only, which every host must support
            mod_dir=sl(str(self.mod_dir).encode("utf-8"), k),
            data_dir=sl(str(self.data_dir).encode("utf-8"), k))

        t = self._thunks
        self.api = HostApi(
            size=ct.sizeof(HostApi), ctx=None, info=ct.pointer(self.info),
            alloc=t[0], free=t[1], log=t[2], last_error=t[3],
            config_get=t[4], config_set=t[5], db_get=t[6], db_patch=t[7],
            route_register=t[8], event_subscribe=t[9], event_emit=t[10],
            call=t[11], resolve=t[12], handle_release=t[13], patch=t[14],
            schedule=t[15], invoke_main=t[16], now_ms=t[17],
            store_get=t[18], store_set=t[19], store_list=t[20],
            handle_pointer=t[21], handle_pin=t[22], patch_typed=t[23],
            notify_push=t[24], invoke_render=t[25])

    # -- the broadcast, shaped exactly like the host's ----------------------
    def deliver(self, name: str, payload: bytes) -> list[tuple[str, str]]:
        """Synchronous broadcast: every subscriber runs before this returns.

        That is the host's own shape (`deliverEvent` calls every subscriber
        before returning), and it is what makes the announce reply observable
        without a second round trip.
        """
        self.capture = []
        pl_buf = ct.create_string_buffer(payload, len(payload)) if payload else None
        s = Slice(ct.cast(pl_buf, ct.POINTER(ct.c_ubyte)), len(payload)) if payload \
            else Slice(None, 0)
        for nm, handler, user in list(self.subs):
            if nm != name:
                continue
            out = Buffer(None, 0)
            handler(ct.c_void_p(user), s, ct.byref(out))
            if out.ptr and out.len > 0:
                _msvcrt.free(ct.cast(out.ptr, ct.c_void_p))
        got, self.capture = self.capture, None
        return got


# ---------------------------------------------------------------------------
# The worker: one mod, one process
# ---------------------------------------------------------------------------

class Phase:
    def __init__(self, path: Path):
        self.path = path

    def set(self, name: str):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(name)
            f.flush()
            os.fsync(f.fileno())


def run_worker(dll: Path, side: int, phase: Phase, log_min: int, trace: bool,
               apply_test: bool) -> dict:
    res: dict = {"dll": str(dll), "checks": [], "logs": [], "notes": []}

    def check(name, verdict, detail=""):
        res["checks"].append({"name": name, "verdict": verdict, "detail": detail})

    mod_dir = dll.parent.parent
    res["mod_dir"] = str(mod_dir)

    phase.set("LoadLibrary")
    os.add_dll_directory(str(dll.parent))
    for cand in (r"C:\msys64\ucrt64\bin", r"C:\msys64\mingw64\bin"):
        if os.path.isdir(cand):
            try:
                os.add_dll_directory(cand)
            except OSError:
                pass
    try:
        lib = ct.CDLL(str(dll), winmode=8)  # LOAD_WITH_ALTERED_SEARCH_PATH
    except OSError as e:
        check("load", "FAIL", f"LoadLibrary refused: {e}")
        return res

    phase.set("aowlspt_abi_version")
    hv, hr = header_abi_version()
    try:
        fn_ver = lib.aowlspt_abi_version
        fn_ver.restype = ct.c_uint32
        fn_ver.argtypes = []
        got = int(fn_ver())
    except AttributeError:
        check("exports", "FAIL", "no aowlspt_abi_version export -- not an aowlspt mod")
        return res
    if hv is None:
        check("abi", "INCONCLUSIVE", "could not read AOWLSPT_ABI_VERSION from the header")
    elif got != hv:
        check("abi", "FAIL", f"mod reports ABI v{got}, header says v{hv}")
        return res
    else:
        check("abi", "PASS", f"v{got}")

    phase.set("aowlspt_describe")
    info = ModInfo()
    try:
        fn_desc = lib.aowlspt_describe
    except AttributeError:
        check("exports", "FAIL", "no aowlspt_describe export")
        return res
    fn_desc.restype = ct.c_int32
    fn_desc.argtypes = [ct.POINTER(ModInfo)]
    st = int(fn_desc(ct.byref(info)))
    if st != OK:
        check("describe", "FAIL", f"aowlspt_describe returned {st}")
        return res
    guid = rd(info.guid).decode("utf-8", "replace")
    name = rd(info.name).decode("utf-8", "replace")
    res["guid"], res["name"] = guid, name
    res["version"] = rd(info.version).decode("utf-8", "replace")
    res["sides"] = int(info.sides)
    check("describe", "PASS", f"{guid} \"{name}\" sides=0x{info.sides:x}")

    if not (info.sides & (1 << side)):
        want = {v: k for k, v in SIDE_NAMES.items()}[side]
        has = ",".join(n for n, v in sorted(SIDE_NAMES.items())
                       if info.sides & (1 << v)) or "none"
        check("side", "INCONCLUSIVE",
              f"this mod declares sides [{has}], not '{want}'. Its load path "
              f"for '{want}' does not exist, so nothing here was exercised -- "
              f"re-run with --side {has.split(',')[0]}")
        return res

    phase.set("aowlspt_init")
    data_dir = Path(tempfile.mkdtemp(prefix="modharness-data-"))
    host = StubHost(mod_dir, data_dir, side, log_min, trace)
    modapi = ModApi()
    try:
        fn_init = lib.aowlspt_init
    except AttributeError:
        check("exports", "FAIL", "no aowlspt_init export")
        return res
    fn_init.restype = ct.c_int32
    fn_init.argtypes = [ct.POINTER(HostApi), ct.POINTER(ModApi)]
    st = int(fn_init(ct.byref(host.api), ct.byref(modapi)))
    if st != OK:
        check("init", "FAIL", f"aowlspt_init returned {st}")
        return res
    check("init", "PASS", "")

    phase.set("on_load")
    if not modapi.on_load:
        check("on_load", "INCONCLUSIVE", "the mod supplied no on_load")
    else:
        st = int(modapi.on_load(modapi.self))
        if st != OK:
            check("on_load", "FAIL", f"on_load returned {st}")
        else:
            check("on_load", "PASS", "")

    # -- the settings transport -------------------------------------------
    subscribed = sorted({n for n, _, _ in host.subs})
    res["subscriptions"] = subscribed
    res["routes"] = host.routes
    settings_subs = [n for n in subscribed if n.startswith("aowlspt.settings.")]
    if not settings_subs:
        check("settings", "INCONCLUSIVE",
              "the mod subscribed to no aowlspt.settings.* event, so it "
              "declared no settings; there is no schema to exercise")
    else:
        deliveries = [(EV_INDEX_QUERY, b""), (EV_PAGE_QUERY, guid.encode())]
        first_page = None
        delivered = 0
        for ev, pl in deliveries:
            if ev == EV_PAGE_QUERY and EV_PAGE_QUERY not in subscribed:
                continue
            if ev == EV_INDEX_QUERY and EV_INDEX_QUERY not in subscribed:
                continue
            short = ev.rsplit(".", 1)[-1]
            phase.set(f"deliver {short} #1")
            a = host.deliver(ev, pl)
            phase.set(f"deliver {short} #2")
            b = host.deliver(ev, pl)
            _judge(check, short, a, b)
            delivered += 1
            if ev == EV_PAGE_QUERY:
                first_page = a
        if delivered == 0:
            # A mod subscribed to some settings event but to neither query the
            # harness can originate. Saying nothing here would let it collect a
            # PASS for a transport that was never touched.
            check("settings", "INCONCLUSIVE",
                  "subscribed to " + ",".join(settings_subs) +
                  " but to neither indexQuery nor pageQuery, so nothing in the "
                  "settings transport was delivered")

        if apply_test and EV_APPLY_QUERY in subscribed:
            key = _first_key(first_page)
            if key is None:
                check("applyQuery", "INCONCLUSIVE",
                      "no pageAnnounce row to take a key from")
            else:
                body = json.dumps({"guid": guid, "key": key[0],
                                   "value": key[1]}).encode()
                phase.set("deliver applyQuery #1")
                a = host.deliver(EV_APPLY_QUERY, body)
                phase.set("deliver applyQuery #2")
                b = host.deliver(EV_APPLY_QUERY, body)
                _judge(check, "applyQuery", a, b)

    # -- init/on_load runs ONCE per session ---------------------------------
    #
    # MEASURED 2026-09-02 (aowlspt-host.log): the client host ran init +
    # on_load TWICE for six mods in one session -- the backend's mod-set poll
    # loaded them at 4.5s and the deferred mod release loaded that same
    # directory again at 40.7s.  sain's publish-once selftest PASSED on run
    # one and FAILED on run two, reporting the schema already published before
    # it had declared anything.
    #
    # The assertion is on the FINISHED STATE and it is a NEGATIVE: after a
    # second on_load, the page this mod serves must be byte-identical to the
    # one it served before.  A mod that re-declared answers a different -- or
    # freed -- schema, and "identical" is not something a self-comparison can
    # fake.  Silence is INCONCLUSIVE, not a pass: unchanged bytes cannot tell
    # a publish-once guard apart from an on_load that declares nothing.
    phase.set("on_load #2")
    if not modapi.on_load:
        check("on_load#2", "INCONCLUSIVE", "the mod supplied no on_load")
    elif EV_PAGE_QUERY not in subscribed:
        check("on_load#2", "INCONCLUSIVE",
              "the mod does not answer pageQuery, so there is no schema to "
              "read back and nothing here would notice a second declaration")
    else:
        before = host.deliver(EV_PAGE_QUERY, guid.encode())
        mark = len(host.logs)
        st2 = int(modapi.on_load(modapi.self))
        after = host.deliver(EV_PAGE_QUERY, guid.encode())
        said = [t for _, t in host.logs[mark:]]
        verdict, detail = judge_on_load2(before, after, said, st2)
        check("on_load#2", verdict, detail)

    phase.set("done")
    res["logs"] = [{"level": l, "text": t} for l, t in host.logs]
    res["calls"] = host.calls
    res["refusals"] = host.refusals
    return res


def _judge(check, short: str, a: list, b: list):
    """PASS/FAIL/INCONCLUSIVE for one query, from the FINISHED replies."""
    ann_a = [(n, p) for n, p in a if n in ANNOUNCES]
    ann_b = [(n, p) for n, p in b if n in ANNOUNCES]
    if not ann_a and not ann_b:
        check(short, "INCONCLUSIVE",
              "the mod is subscribed but announced nothing on EITHER delivery. "
              "That is silence, not a failure and not a pass: an unpublished "
              "schema refuses with a reason (look for a 'settings: ...REFUSED' "
              "log line), and a mod that opted out of the index "
              "(declareSettings inIndex=false) answers nothing here by design")
        return
    bad = []
    for n, p in ann_a + ann_b:
        try:
            json.loads(p)
        except Exception as e:
            bad.append(f"{n}: {e}")
    if bad:
        check(short, "FAIL", "reply is not strict JSON -- " + "; ".join(bad[:2]))
        return
    if ann_a != ann_b:
        check(short, "FAIL",
              f"delivery 2 differs from delivery 1 ({len(ann_a)} vs "
              f"{len(ann_b)} announces, or the bytes changed) -- this is the "
              f"shape a schema freed under a reader produces")
        return
    check(short, "PASS", f"{len(ann_a)} announce(s), strict JSON, identical twice")


def judge_on_load2(before, after, said, status=0):
    """PASS/FAIL/INCONCLUSIVE for a SECOND `on_load`, from the finished state.

    Split out of the caller so `--selftest` can drive it with synthetic inputs.
    The FAIL branch is the whole point of this check and, unlike the fault the
    negative-control mod produces, no mod in the tree currently reaches it -- so
    without that it would be a branch nobody has ever seen taken, which is
    section 9b's definition of the bug rather than the check.
    """
    refused = any("REFUS" in t.upper() for t in said)
    if before != after:
        return ("FAIL",
                f"a SECOND on_load CHANGED the schema this mod serves "
                f"({len(before)} announce(s) before, {len(after)} after, or "
                f"the bytes differ). That is a re-declaration -- the free "
                f"under a live reader this guard exists to stop")
    if not refused:
        return ("INCONCLUSIVE",
                "the schema is unchanged after a second on_load, but the mod "
                "said nothing about refusing one, so this cannot tell a "
                "publish-once guard apart from an on_load that declares no "
                "settings at all. Make the refusal say so and this becomes a "
                "PASS")
    return ("PASS",
            f"a second on_load returned {status}, was REFUSED with a reason, "
            f"and the page served is byte-identical")


def _first_key(page_replies):
    if not page_replies:
        return None
    for n, p in page_replies:
        if n != EV_PAGE_ANNOUNCE:
            continue
        try:
            rows = json.loads(p).get("rows", [])
        except Exception:
            return None
        for r in rows:
            if isinstance(r, dict) and "key" in r and "value" in r:
                # Re-apply the CURRENT value: exercise the write path without
                # changing what the mod thinks its configuration is.
                return (r["key"], r["value"])
    return None


# ---------------------------------------------------------------------------
# The parent
# ---------------------------------------------------------------------------

def run_one(dll: Path, side_name: str, timeout: float, log_min: int, trace: bool,
            apply_test: bool) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix="modharness-"))
    phase_f, res_f = tmp / "phase.txt", tmp / "result.json"
    phase_f.write_text("spawn", encoding="utf-8")
    argv = [sys.executable, str(Path(__file__).resolve()), "--worker", str(dll),
            "--side", side_name, "--phase-file", str(phase_f),
            "--result-file", str(res_f), "--log-min", str(log_min),
            "--timeout", str(timeout)]
    if trace:
        argv.append("--trace-host")
    if apply_test:
        argv.append("--apply")
    t0 = time.time()
    try:
        p = subprocess.run(argv, timeout=timeout, cwd=str(REPO))
        rc = p.returncode
    except subprocess.TimeoutExpired:
        last = phase_f.read_text(encoding="utf-8", errors="replace")
        return {"dll": str(dll), "verdict": "FAIL", "elapsed": time.time() - t0,
                "checks": [{"name": "run", "verdict": "FAIL",
                            "detail": f"HUNG for {timeout:.0f}s in phase "
                                      f"'{last}' -- killed"}]}
    elapsed = time.time() - t0
    if res_f.is_file():
        res = json.loads(res_f.read_text(encoding="utf-8"))
        res["elapsed"] = elapsed
        res["verdict"] = worst(res.get("checks", []))
        return res
    last = phase_f.read_text(encoding="utf-8", errors="replace")
    # A worker that produced no result did not merely fail a check -- it died.
    return {"dll": str(dll), "verdict": "FAIL", "elapsed": elapsed,
            "checks": [{"name": "run", "verdict": "FAIL",
                        "detail": f"the mod FAULTED: worker exited "
                                  f"{rc} (0x{rc & 0xffffffff:08x}) during "
                                  f"phase '{last}' without answering"}]}


def worst(checks) -> str:
    v = [c["verdict"] for c in checks]
    if not v:
        return "INCONCLUSIVE"
    if "FAIL" in v:
        return "FAIL"
    if "INCONCLUSIVE" in v:
        return "INCONCLUSIVE"
    return "PASS"


def discover() -> list:
    """Every REAL mod. The negative control is deliberately NOT here.

    `--all` is meant to be runnable in a loop and to mean "is anything broken",
    so a mod that is required to fail would make its exit code useless. The
    control is reached by `--selftest`, or by naming its DLL.
    """
    return sorted((REPO / "mods").glob("*/bin/*.dll"))


def selftest(a, log_min: int) -> int:
    """A positive and a NEGATIVE control, in one command.

    Section 9b: a check that cannot fail is the bug. This asserts both
    directions -- that a healthy mod reaches PASS, and that the deliberately
    faulting mod reaches FAIL naming the phase. If the negative control has not
    been built, that is INCONCLUSIVE, never a pass: a harness whose failing case
    was skipped has proved nothing about its ability to fail.
    """
    good = REPO / "mods" / "sain" / "bin" / "sain.dll"
    bad = REPO / "tests" / "modharness_bad" / "bin" / "modharness_bad.dll"
    verdicts = []

    print("-- positive control: mods/sain must PASS", flush=True)
    if not good.is_file():
        print("   INCONCLUSIVE: sain.dll is not built")
        verdicts.append("INCONCLUSIVE")
    else:
        r = run_one(good, "client", a.timeout, log_min, False, False)
        ok = r["verdict"] == "PASS"
        sel = [l["text"] for l in r.get("logs", [])
               if "publish-once selftest" in l["text"]]
        if ok and not sel:
            ok, why = False, "sain PASSed but never logged its publish-once selftest"
        else:
            why = sel[0] if sel else r["verdict"]
        print(f"   {'PASS' if ok else 'FAIL'}: {why[:160]}")
        verdicts.append("PASS" if ok else "FAIL")

    print("-- negative control: tests/modharness_bad must FAIL", flush=True)
    if not bad.is_file():
        print("   INCONCLUSIVE: the negative control is not built -- "
              "python tools/buildlock.py build-mod tests/modharness_bad")
        verdicts.append("INCONCLUSIVE")
    else:
        r = run_one(bad, "client", a.timeout, log_min, False, False)
        detail = "; ".join(c["detail"] for c in r.get("checks", [])
                           if c["verdict"] == "FAIL")
        ok = r["verdict"] == "FAIL"
        print(f"   {'PASS' if ok else 'FAIL'}: got {r['verdict']} -- "
              f"{detail[:200] or 'no FAIL check was recorded'}")
        verdicts.append("PASS" if ok else "FAIL")

    # -- third control: the on_load#2 JUDGEMENT, driven directly ------------
    #
    # sain exercises only its PASS branch, and the faulting fixture dies two
    # phases earlier, so nothing in the tree takes the FAIL branch. Driving the
    # function with synthetic replies is what stops "a second on_load changed
    # the schema" from being a sentence that has never once been produced.
    print("-- third control: judge_on_load2 must reach all three verdicts",
          flush=True)
    same = [("aowlspt.settings.pageAnnounce", b'{"rows":[1]}')]
    diff = [("aowlspt.settings.pageAnnounce", b'{"rows":[1,2]}')]
    cases = [("FAIL", same, diff, ["settings: ...REFUSED..."]),
             ("INCONCLUSIVE", same, list(same), ["nothing to say"]),
             ("PASS", same, list(same), ["settings: declareSettings ... REFUSED"])]
    bad3 = []
    for want, b, a2, said in cases:
        got, _ = judge_on_load2(b, a2, said)
        if got != want:
            bad3.append(f"wanted {want}, got {got}")
    if bad3:
        print("   FAIL: " + "; ".join(bad3))
        verdicts.append("FAIL")
    else:
        print("   PASS: FAIL, INCONCLUSIVE and PASS are all reachable")
        verdicts.append("PASS")

    if "FAIL" in verdicts:
        print("selftest FAIL")
        return 1
    if "INCONCLUSIVE" in verdicts:
        print("selftest INCONCLUSIVE -- one control could not be run")
        return 3
    print("selftest PASS -- this harness can both pass and fail")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Run a mod's load path and settings transport offline.")
    ap.add_argument("dll", nargs="*", help="path to a built mod DLL")
    ap.add_argument("--all", action="store_true",
                    help="every built mod under mods/*/bin plus the negative control")
    ap.add_argument("--side", default="client", choices=sorted(SIDE_NAMES))
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--apply", action="store_true",
                    help="also deliver applyQuery (writes go to an in-memory "
                         "overlay; config.json on disk is never touched)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="show trace/debug mod log lines too")
    ap.add_argument("--trace-host", action="store_true",
                    help="print every host export the mod calls, as it calls it")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument("--selftest", action="store_true",
                    help="prove this harness can BOTH pass and fail: a known-good "
                         "mod must PASS and the negative control must FAIL")
    # worker-only
    ap.add_argument("--worker", help=argparse.SUPPRESS)
    ap.add_argument("--phase-file", help=argparse.SUPPRESS)
    ap.add_argument("--result-file", help=argparse.SUPPRESS)
    ap.add_argument("--log-min", type=int, default=2, help=argparse.SUPPRESS)
    a = ap.parse_args()

    log_min = 0 if a.verbose else a.log_min
    side = SIDE_NAMES[a.side]

    if a.worker:
        ph = Phase(Path(a.phase_file))
        res = run_worker(Path(a.worker), side, ph, log_min, a.trace_host, a.apply)
        Path(a.result_file).write_text(json.dumps(res), encoding="utf-8")
        return 0

    if a.selftest:
        return selftest(a, log_min)

    targets = [Path(x) for x in a.dll]
    if a.all:
        targets = discover()
    if not targets:
        print("nothing to run: give a DLL path or --all", file=sys.stderr)
        return 3
    missing = [t for t in targets if not t.is_file()]
    if missing:
        for m in missing:
            print(f"not built: {m}", file=sys.stderr)
        targets = [t for t in targets if t.is_file()]
        if not targets:
            return 3

    results = []
    for t in targets:
        tr = t.resolve()
        try:
            shown = tr.relative_to(REPO)
        except ValueError:
            shown = tr
        print(f"\n== {shown}", flush=True)
        r = run_one(tr, a.side, a.timeout, log_min, a.trace_host, a.apply)
        results.append(r)
        for c in r.get("checks", []):
            d = f" -- {c['detail']}" if c["detail"] else ""
            print(f"   {c['verdict']:12} {c['name']}{d}")
        ref = r.get("refusals") or {}
        if ref:
            print("   not emulated (called, refused): " +
                  ", ".join(f"{k}x{v}" for k, v in sorted(ref.items())))
        print(f"   {r['verdict']}  ({r.get('elapsed', 0):.1f}s)")

    print("\n---- summary ----")
    tally = {"PASS": 0, "FAIL": 0, "INCONCLUSIVE": 0}
    for r in results:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
        nm = r.get("guid") or Path(r["dll"]).stem
        print(f"  {r['verdict']:12} {nm}")
    print(f"  {tally['PASS']} pass, {tally['FAIL']} fail, "
          f"{tally['INCONCLUSIVE']} inconclusive")
    print("  the stub has no IL2CPP runtime, no Unity, no db.json and no HTTP "
          "listener; a PASS is about the load path and the settings transport, "
          "not about behaviour in a raid.")

    if a.json:
        print(json.dumps(results, indent=1))

    if tally["FAIL"]:
        return 1
    if tally["INCONCLUSIVE"] and not tally["PASS"]:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
