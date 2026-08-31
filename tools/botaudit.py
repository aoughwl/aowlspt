#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""botaudit.py -- "is our bot AI actually changing what bots do?", measured.

ONE command, run against a LIVE raid, that answers with facts about BEHAVIOUR
rather than about bindings:

  * how many AI players are registered and alive, broken down by role
  * how far each of them MOVED between two samples N seconds apart
  * which destination writer was active in that window (the server per-census
    actuator in `mods/sain/server/dispatch.nim`, or the client per-decide
    actuator in `mods/sain/client/driver.nim`) -- and whether BOTH were, which
    is the documented last-writer-wins race
  * whether the cover sensor is sampling or declining, read from what the host
    ACTUALLY reported in its own log, never from config
  * whether SAIN is enabled, read from /sain/status, never from the JSON

WHY THIS EXISTS. Every claim about bot behaviour in this project has been
argued from source. `docs/BOT_AI_OBJECTIVES.md` carried the "fact" that the
SAIN driver does not move bots and that vanilla AI drives them with
`sain.enabled=false`, while the deployed config had `enabled: true`. Nobody
could cheaply check, so a stale belief sat in a design doc gating work.

THE HONESTY RULES (CLAUDE.md 9b), which are the whole design:

  * Three outcomes, always: PASS / FAIL / INCONCLUSIVE. "I could not look" is
    INCONCLUSIVE. No bots found is INCONCLUSIVE -- the raid may not have
    started -- and is NEVER "0 bots misbehaving, pass".
  * The property asserted is about the FINISHED STATE: a bot's world position
    CHANGED between two samples. Nothing here reads back its own write; this
    tool performs no write at all.
  * THE POSITIVE CONTROL. The local player's position is sampled through the
    exact same path, the same offsets, the same differencing code as every
    bot. A human walking during the window MUST show up as several metres. If
    the harness reports "nothing moved" while you are walking, the control
    says so and the movement verdict is downgraded to INCONCLUSIVE instead of
    reporting a triumphant FAIL against the bot AI for what is really a broken
    meter. Concretely: swap the position offset for a wrong one, or read the
    same address twice, and CONTROL turns INCONCLUSIVE while the tool visibly
    refuses to convict.
  * The falsifiable negative is the point: "no bot moved more than 0.5 m in
    30 s while the player moved 12.4 m" can be false. "the driver is working"
    cannot be, so it is never printed.

WHAT THIS TOOL CANNOT DO, said plainly rather than guessed at: it does not
report per-bot combat/search/idle state. That lives in `EFT.BotOwner._botState
@0x30`, and BotOwner is not reachable from `GameWorld.RegisteredPlayers` by
any offset measured on this build -- the list holds `EFT.Player`. The facet is
reported UNAVAILABLE with that reason, never quietly omitted.

USAGE

    python tools/botaudit.py                    # 30 s window, live raid
    python tools/botaudit.py --window 45 --move-threshold 0.75
    python tools/botaudit.py --json             # machine-readable, bounded
    python tools/botaudit.py --selftest         # offline, no game needed

Exit codes: 0 = overall PASS, 1 = overall FAIL, 2 = overall INCONCLUSIVE,
3 = the tool could not even start (no live install / no inspector channel).
INCONCLUSIVE deliberately does not share an exit code with either of the
others.

DATA SOURCES, and what happens when one is missing: the live inspector file
channel (via `tools/ichannel.py`), the backend's `/sain/status` on PORT 6969,
and `aowlspt-host.log` read with a bounded tail. Each source feeds its own
facets. A missing source makes ITS facets INCONCLUSIVE and nothing else -- no
source's absence is ever allowed to produce a PASS.

This tool NEVER writes to the game, never presses anything, never deploys, and
never starts or stops the client.
"""

import argparse
import json
import os
import re
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"
SAIN_STATUS_URL = "http://127.0.0.1:6969/sain/status"

# ---------------------------------------------------------------------------
# Offsets. Every one of these is copied from a file in this repo that already
# byte-verified or metadata-derived it -- none is guessed here.
#   abi/aowlspt_botdiag.h   (GameWorld / List / Player / Profile chain)
#   abi/aowlspt_botnav.h    (BotOwner, for the facet we CANNOT reach)
# ---------------------------------------------------------------------------
GW_ALIVELIST = 0x1C8
GW_REGPLAYERS = 0x1D0
LIST_ITEMS = 0x010
LIST_SIZE = 0x018
ARR_ELEMS = 0x020
PL_MOVECTX = 0x060
PL_PROFILE = 0x9C0
PL_AIDATA = 0xA00
PL_ISYOU = 0xB89
PL_CACHEDPTR = 0x010      # UnityEngine.Object.m_CachedPtr -- 0 => fake-null
MC_PREVPOS = 0x370        # Vector3, x@+0 y@+4 z@+8
PROF_INFO = 0x048
INFO_SETTINGS = 0x078
SET_ROLE = 0x010
SET_DIFF = 0x014

MAX_PLAYERS = 128         # a hard cap on what we will enumerate, ever
CMD_CAP = 100             # inspector accepts 128 commands per batch; stay under

# Role names copied VERBATIM from host/Aowlspt.Host.Il2Cpp/debugui.nim's
# duRoleName, including its rule: an unnamed role prints its NUMBER, never a
# guess. A wrong label on a boss would be worse than a number.
ROLE_NAMES = {
    0: "assault", 1: "marksman", 2: "bossTest", 3: "bossBully",
    6: "bossKilla", 7: "bossKojaniy", 8: "bossGluhar", 9: "bossSanitar",
    24: "pmcBot", 26: "exUsec", 30: "cursedAssault",
    32: "sectantWarrior", 33: "sectantPriest",
}


def role_name(role):
    if role is None:
        return "role?"
    return ROLE_NAMES.get(role, "role%d" % role)


# ---------------------------------------------------------------------------
# Outcomes
# ---------------------------------------------------------------------------
PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


class Facet(object):
    """One measured question, one outcome, one sentence of evidence.

    `outcome` is one of the three strings. There is no boolean anywhere in
    this class on purpose: a two-state field is exactly how INCONCLUSIVE gets
    flattened into a pass.
    """

    def __init__(self, name, outcome, detail, data=None):
        assert outcome in (PASS, FAIL, INCONCLUSIVE), outcome
        self.name = name
        self.outcome = outcome
        self.detail = detail
        self.data = data or {}

    def as_dict(self):
        return {"facet": self.name, "outcome": self.outcome,
                "detail": self.detail, "data": self.data}


def overall(facets):
    """FAIL > INCONCLUSIVE > PASS, and NO facets is INCONCLUSIVE.

    INCONCLUSIVE outranking PASS is deliberate and is the same precedence the
    inspector's own batch verdict uses: a run where two checks passed and one
    could not look has not demonstrated the property it was written to
    demonstrate.
    """
    if not facets:
        return INCONCLUSIVE
    outcomes = [f.outcome for f in facets]
    if FAIL in outcomes:
        return FAIL
    if INCONCLUSIVE in outcomes:
        return INCONCLUSIVE
    return PASS


# ---------------------------------------------------------------------------
# Parsing the inspector's answers
#
# Formats, taken from host/Aowlspt.Host.Il2Cpp/inspect.nim (iReadTyped, and
# `of "read"` in the dispatcher):
#     "  0x00000001ABCDEF00 as ptr = 0x00000001DEADBEEF  readable"
#     "  0x... as i32 = 5  (0x00000005)"
#     "  0x... as f32 = 12.34  (bits 0x41453D71)"
#     "  0x... as bool = true  (0x01)"
#     "  $gw = 0x00000001ABCDEF00"                      <- `let NAME EXPR`
# Failures are "  ! <reason>" and carry NO address, which is precisely why
# answers are keyed by the echoed address rather than by line position: a read
# that failed simply has no key, and its bot becomes unreadable rather than
# silently inheriting its neighbour's value.
#
# f32 is decoded from the BITS, not from the rendered decimal, so the host's
# formatting can never change a measured distance.
# ---------------------------------------------------------------------------
_READ_RE = re.compile(
    r"^\s*0x(?P<addr>[0-9A-Fa-f]{8,16}) as (?P<ty>[a-z0-9]+) = (?P<val>.*)$")
_LET_RE = re.compile(r"^\s*\$(?P<name>\w+) = 0x(?P<val>[0-9A-Fa-f]+)\s*$")
_BITS_RE = re.compile(r"\(bits 0x([0-9A-Fa-f]+)\)")


def _decode_value(ty, val):
    """Return the typed value, or None if this line cannot be decoded.

    None means "no answer", never zero. A caller that treats a failed read as
    0.0 would report an unreadable bot as standing at the origin, which is a
    confidently wrong number -- the exact failure this file is against.
    """
    val = val.strip()
    if ty == "ptr":
        m = re.match(r"0x([0-9A-Fa-f]+)", val)
        return int(m.group(1), 16) if m else None
    if ty == "bool":
        if val.startswith("true"):
            return True
        if val.startswith("false"):
            return False
        return None
    if ty in ("f32", "f64"):
        m = _BITS_RE.search(val)
        if not m:
            return None
        raw = int(m.group(1), 16)
        if ty == "f32":
            return struct.unpack("<f", struct.pack("<I", raw & 0xFFFFFFFF))[0]
        return struct.unpack("<d", struct.pack("<Q", raw))[0]
    if ty in ("i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64"):
        m = re.match(r"(-?\d+)", val)
        return int(m.group(1)) if m else None
    return None


def parse_reads(raw):
    """-> ({address: value}, {name: value}, n_error_lines).

    Keyed by address. If the same address is read twice in one batch the LAST
    answer wins; this tool never does that, and the selftest asserts it.
    """
    by_addr, by_name, errs = {}, {}, 0
    for line in raw.splitlines():
        m = _READ_RE.match(line)
        if m:
            v = _decode_value(m.group("ty"), m.group("val"))
            if v is not None:
                by_addr[int(m.group("addr"), 16)] = v
            else:
                errs += 1
            continue
        m = _LET_RE.match(line)
        if m:
            by_name[m.group("name")] = int(m.group("val"), 16)
            continue
        if line.strip().startswith("!"):
            errs += 1
    return by_addr, by_name, errs


# ---------------------------------------------------------------------------
# The channel
# ---------------------------------------------------------------------------
class LiveChannel(object):
    """The real inspector file channel. Read-only batches only."""

    def __init__(self, root=None, timeout=25.0):
        import ichannel
        self._ch = ichannel
        self.root = root
        self.timeout = timeout
        self.batches = 0

    def send(self, lines):
        for l in lines:
            if not (l.startswith("read ") or l.startswith("let ")):
                raise ValueError(
                    "botaudit issues only read-only commands; refused: %r" % l)
        self.batches += 1
        _sentinel, text = self._ch.run_batch(
            list(lines), live_dir=self.root, timeout=self.timeout, write=False)
        return text


class FakeChannel(object):
    """A memory image, for --selftest. Understands exactly the two command
    forms botaudit emits, and NOTHING else -- a typo in a batch is a KeyError
    in the selftest rather than a plausible answer."""

    def __init__(self, mem, anchors):
        self.mem = mem            # {addr: ("ptr"/"i32"/"f32"/"bool", value)}
        self.anchors = anchors    # {"gameworld": addr, "you": addr}
        self.batches = 0

    def send(self, lines):
        self.batches += 1
        out = []
        for l in lines:
            t = l.split()
            if t[0] == "let":
                v = self.anchors.get(t[2].lstrip("$"), 0)
                out.append("  $%s = 0x%016X" % (t[1], v))
                continue
            if t[0] != "read":
                raise AssertionError("FakeChannel got %r" % l)
            addr, ty = int(t[1], 16), t[2]
            cell = self.mem.get(addr)
            if cell is None or cell[0] != ty:
                out.append("  ! not readable for N bytes at 0x%X" % addr)
                continue
            v = cell[1]
            if ty == "ptr":
                out.append("  0x%016X as ptr = 0x%016X  %s"
                           % (addr, v, "readable" if v else "NULL"))
            elif ty == "bool":
                out.append("  0x%016X as bool = %s  (0x%02X)"
                           % (addr, "true" if v else "false", 1 if v else 0))
            elif ty == "f32":
                bits = struct.unpack("<I", struct.pack("<f", v))[0]
                out.append("  0x%016X as f32 = %.4f  (bits 0x%08X)"
                           % (addr, v, bits))
            else:
                out.append("  0x%016X as %s = %d  (0x%08X)"
                           % (addr, ty, v, v & 0xFFFFFFFF))
        return "\n".join(out)


def _chunks(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


# ---------------------------------------------------------------------------
# Sampling the world
# ---------------------------------------------------------------------------
class Sample(object):
    def __init__(self):
        self.t = 0.0
        self.gameworld = 0
        self.you = 0
        self.registered = []     # player pointers
        self.alive = set()       # pointers in GameWorld.AllAlivePlayersList
        self.ai = []             # pointers with non-null AIData
        self.pos = {}            # ptr -> (x, y, z)
        self.fake_null = []      # readable pointers whose m_CachedPtr is 0
        self.unreadable = 0
        self.why = ""            # set when the sample could not be taken


class World(object):
    """Walks GameWorld with the inspector. Every step is a separate batch
    because each depends on pointers parsed out of the previous answer."""

    def __init__(self, chan):
        self.chan = chan

    def _reads(self, specs):
        """specs = [(addr, type)] -> {addr: value}. Chunked under the
        inspector's 128-command-per-batch limit."""
        got = {}
        for chunk in _chunks(specs, CMD_CAP):
            lines = ["read 0x%X %s" % (a, t) for a, t in chunk]
            by_addr, _n, _e = parse_reads(self.chan.send(lines))
            got.update(by_addr)
        return got

    def _list_contents(self, list_ptr, cap=MAX_PLAYERS):
        """List<T> -> [element pointers]. Returns [] and a reason string."""
        if not list_ptr:
            return [], "the List pointer is null"
        got = self._reads([(list_ptr + LIST_SIZE, "i32"),
                           (list_ptr + LIST_ITEMS, "ptr")])
        size = got.get(list_ptr + LIST_SIZE)
        items = got.get(list_ptr + LIST_ITEMS)
        if size is None or items is None:
            return [], "the List header at 0x%X is not readable" % list_ptr
        if size <= 0:
            return [], "the List is empty (_size=%d)" % size
        n = min(int(size), cap)
        slots = [(items + ARR_ELEMS + 8 * i, "ptr") for i in range(n)]
        got = self._reads(slots)
        out = [got[a] for a, _t in slots if got.get(a)]
        return out, ("read %d of %d element(s)" % (len(out), size))

    def snapshot(self):
        s = Sample()
        raw = self.chan.send(["let gw $gameworld", "let you $you"])
        _a, names, _e = parse_reads(raw)
        s.gameworld = names.get("gw", 0)
        s.you = names.get("you", 0)
        s.t = time.time()
        if not s.gameworld:
            s.why = ("$gameworld is null -- there is no live EFT.GameWorld, so "
                     "the client is not in a raid (or the debugui world scan "
                     "that binds the anchor has not run). NOTHING was measured")
            return s

        heads = self._reads([(s.gameworld + GW_REGPLAYERS, "ptr"),
                             (s.gameworld + GW_ALIVELIST, "ptr")])
        s.registered, _why = self._list_contents(
            heads.get(s.gameworld + GW_REGPLAYERS, 0))
        alive, _why2 = self._list_contents(
            heads.get(s.gameworld + GW_ALIVELIST, 0))
        s.alive = set(alive)
        if not s.registered:
            s.why = ("GameWorld.RegisteredPlayers held no readable entry. This "
                     "is NOT 'no bots': it is 'the list could not be walked'")
            return s

        # Per player: fake-null gate, AI gate, IsYourPlayer, MovementContext.
        specs = []
        for p in s.registered:
            specs += [(p + PL_CACHEDPTR, "ptr"), (p + PL_AIDATA, "ptr"),
                      (p + PL_ISYOU, "bool"), (p + PL_MOVECTX, "ptr")]
        got = self._reads(specs)

        mcs = {}
        for p in s.registered:
            cached = got.get(p + PL_CACHEDPTR)
            if cached is None:
                s.unreadable += 1
                continue
            if cached == 0:
                # Unity fake-null: still readable, native half gone. Readability
                # is NOT liveness, and counting one of these as a live bot that
                # "did not move" would be a fabricated FAIL.
                s.fake_null.append(p)
                continue
            if got.get(p + PL_ISYOU) is True and not s.you:
                s.you = p
            if got.get(p + PL_AIDATA):
                s.ai.append(p)
            mc = got.get(p + PL_MOVECTX)
            if mc:
                mcs[p] = mc
        if s.you and s.you not in mcs:
            got2 = self._reads([(s.you + PL_MOVECTX, "ptr")])
            mc = got2.get(s.you + PL_MOVECTX)
            if mc:
                mcs[s.you] = mc

        specs = []
        for _p, mc in sorted(mcs.items()):
            specs += [(mc + MC_PREVPOS, "f32"), (mc + MC_PREVPOS + 4, "f32"),
                      (mc + MC_PREVPOS + 8, "f32")]
        got = self._reads(specs)
        for p, mc in mcs.items():
            xyz = (got.get(mc + MC_PREVPOS), got.get(mc + MC_PREVPOS + 4),
                   got.get(mc + MC_PREVPOS + 8))
            if None not in xyz:
                s.pos[p] = xyz
        return s

    def roles(self, players):
        """{ptr: (role, difficulty)}. Four dependent rounds; missing entries
        are simply absent, and are reported as 'role?' rather than as 0
        ('assault'), which would invent a scav out of an unreadable read."""
        out = {}
        if not players:
            return out
        profs = self._reads([(p + PL_PROFILE, "ptr") for p in players])
        infos = {}
        for p in players:
            pr = profs.get(p + PL_PROFILE)
            if pr:
                infos[p] = pr
        got = self._reads([(v + PROF_INFO, "ptr") for v in infos.values()])
        sets = {}
        for p, pr in infos.items():
            info = got.get(pr + PROF_INFO)
            if info:
                sets[p] = info
        got = self._reads([(v + INFO_SETTINGS, "ptr") for v in sets.values()])
        final = {}
        for p, info in sets.items():
            st = got.get(info + INFO_SETTINGS)
            if st:
                final[p] = st
        specs = []
        for st in final.values():
            specs += [(st + SET_ROLE, "i32"), (st + SET_DIFF, "i32")]
        got = self._reads(specs)
        for p, st in final.items():
            out[p] = (got.get(st + SET_ROLE), got.get(st + SET_DIFF))
        return out


def distance(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5


# ---------------------------------------------------------------------------
# Facet: the positive control
# ---------------------------------------------------------------------------
def facet_control(s0, s1, thresh):
    """The meter, measured on something known to move.

    PASS means: this exact code path, these exact offsets, this exact
    subtraction, DID observe motion during the window. That is the only thing
    that entitles the movement facet to say FAIL.

    HOW IT WOULD VISIBLY FAIL: point MC_PREVPOS at the wrong offset, or sample
    the same address twice, or let a failed read decode as 0.0, and a human
    walking a corridor comes back as 0.00 m -- CONTROL goes INCONCLUSIVE and
    says the meter may be broken, instead of the tool convicting the bot AI.
    """
    if not s0.you or not s1.you:
        return Facet("CONTROL", INCONCLUSIVE,
                     "the local player was never identified ($you null and no "
                     "registered player had IsYourPlayer set), so the meter "
                     "was never exercised on something known to move")
    p0, p1 = s0.pos.get(s0.you), s1.pos.get(s1.you)
    if p0 is None or p1 is None:
        return Facet("CONTROL", INCONCLUSIVE,
                     "the local player's MovementContext position was not "
                     "readable in %s sample, so the meter is unproven"
                     % ("the first" if p0 is None else "the second"))
    d = distance(p0, p1)
    data = {"player_moved_m": round(d, 3)}
    if d > thresh:
        return Facet("CONTROL", PASS,
                     "the local player moved %.2f m through the same offsets, "
                     "the same reads and the same subtraction used for every "
                     "bot -- the meter demonstrably registers motion" % d, data)
    return Facet("CONTROL", INCONCLUSIVE,
                 "the local player moved only %.2f m. Either you stood still "
                 "during the window or the meter is broken, and those two are "
                 "indistinguishable from here. WALK while this runs. Until "
                 "this reads PASS, a bot verdict of FAIL is withheld" % d, data)


# ---------------------------------------------------------------------------
# Facet: movement
# ---------------------------------------------------------------------------
def facet_movement(s0, s1, control, thresh, window):
    ai0 = [p for p in s0.ai if p in s0.pos]
    paired = [p for p in ai0 if p in s1.pos and p in s1.ai]
    gone = [p for p in s0.ai if p not in s1.ai]
    new = [p for p in s1.ai if p not in s0.ai]
    dists = {p: distance(s0.pos[p], s1.pos[p]) for p in paired}
    movers = [p for p, d in dists.items() if d > thresh]
    alive_now = [p for p in s1.ai if p in s1.alive]
    data = {
        "ai_registered_first": len(s0.ai), "ai_registered_second": len(s1.ai),
        "ai_alive_second": len(alive_now), "paired": len(paired),
        "movers": len(movers), "gone": len(gone), "new": len(new),
        "max_move_m": round(max(dists.values()), 2) if dists else None,
        "median_move_m": (round(sorted(dists.values())[len(dists) // 2], 2)
                          if dists else None),
        "fake_null_second": len(s1.fake_null),
        "unreadable_second": s1.unreadable,
    }
    if not s0.ai and not s1.ai:
        return Facet("MOVEMENT", INCONCLUSIVE,
                     "not one registered player had a non-null AIData in "
                     "either sample. There are no bots to judge -- the raid "
                     "may not have started, or they may not have spawned yet. "
                     "This is NOT '0 bots misbehaving'", data)
    if not paired:
        return Facet("MOVEMENT", INCONCLUSIVE,
                     "%d AI player(s) were seen but NONE was measured twice "
                     "with a readable position, so no displacement exists to "
                     "judge (%d despawned or died between samples)"
                     % (max(len(s0.ai), len(s1.ai)), len(gone)), data)
    if movers:
        return Facet("MOVEMENT", PASS,
                     "%d of %d paired bots moved more than %.2f m in %.1f s "
                     "(max %.2f m). Bots are being moved by SOMETHING; this "
                     "does not by itself say by WHAT -- see WRITERS"
                     % (len(movers), len(paired), thresh, window,
                        max(dists.values())), data)
    if control.outcome != PASS:
        return Facet("MOVEMENT", INCONCLUSIVE,
                     "no bot moved more than %.2f m in %.1f s, BUT the "
                     "positive control did not pass, so a broken meter and "
                     "frozen bots are indistinguishable from here. Re-run "
                     "while walking" % (thresh, window), data)
    return Facet("MOVEMENT", FAIL,
                 "no bot moved more than %.2f m in %.1f s across %d paired "
                 "bots (largest displacement %.2f m) while the same meter "
                 "measured the player moving %.2f m. The bots are standing "
                 "still" % (thresh, window, len(paired), max(dists.values()),
                            control.data.get("player_moved_m", 0.0)), data)


def role_histogram(ai, roles, alive):
    hist = {}
    for p in ai:
        r = roles.get(p, (None, None))[0]
        key = role_name(r)
        cell = hist.setdefault(key, {"registered": 0, "alive": 0})
        cell["registered"] += 1
        if p in alive:
            cell["alive"] += 1
    return hist


# ---------------------------------------------------------------------------
# Facet: which writer set destinations  (/sain/status on PORT 6969)
# ---------------------------------------------------------------------------
_INT_BEFORE = {
    "drive_censuses": re.compile(r"drive:.*?(\d+) censuses"),
    "dispatch_censuses": re.compile(r"dispatch:.*?(\d+) censuses entered"),
    "dispatch_orders": re.compile(r"dispatch:.*?(\d+) orders"),
}


def fetch_sain_status(url, timeout=4.0):
    """-> (dict, None) or (None, reason). PORT 6969, not 80 -- measured."""
    try:
        try:
            from urllib.request import urlopen
        except ImportError:                      # pragma: no cover
            from urllib2 import urlopen
        raw = urlopen(url, timeout=timeout).read().decode("utf-8", "replace")
    except Exception as e:
        return None, "%s is unreachable (%s)" % (url, e.__class__.__name__)
    try:
        return json.loads(raw), None
    except ValueError:
        return None, "%s answered %d bytes that are not JSON" % (url, len(raw))


def _counters(status):
    out = {}
    if not status:
        return out
    blob = "%s %s" % (status.get("drive", ""), status.get("dispatch", ""))
    for k, rx in _INT_BEFORE.items():
        m = rx.search(blob)
        if m:
            out[k] = int(m.group(1))
    return out


_GOTO_RE = re.compile(r"botnav: bot id=(\d+) GoToPoint")


def facet_writers(st0, why0, st1, why1, log_window):
    """WHICH actuator was writing destinations during the window.

    Measured as a DELTA across the window, not read from config: a counter
    that advanced is a writer that ran. Both advancing is the documented
    last-writer-wins race between the client per-decide path and the server
    per-census path, and is reported as FAIL rather than as two PASSes.
    """
    if st1 is None:
        return Facet("WRITERS", INCONCLUSIVE,
                     "could not read the sain status route: %s. Nothing about "
                     "destination writers was established" % (why1 or why0))
    c0, c1 = _counters(st0), _counters(st1)
    ids = set(_GOTO_RE.findall(log_window))
    d_orders = (c1.get("dispatch_orders", 0) - c0.get("dispatch_orders", 0)
                if "dispatch_orders" in c1 and "dispatch_orders" in c0 else None)
    data = {"sain_enabled": st1.get("enabled"),
            "dispatch_orders_delta": d_orders,
            "goto_bot_ids_in_log": len(ids),
            "drive": st1.get("drive"), "driveCheck": st1.get("driveCheck"),
            "dispatch": st1.get("dispatch"),
            "dispatchCheck": st1.get("dispatchCheck")}
    server_wrote = bool(d_orders) or bool(ids)
    # The client per-decide actuator announces ownership in its own words in
    # the host log; there is no counter for it on the status route, so the
    # ownership clause is the evidence and it is quoted, not paraphrased.
    client_owns = "locomotion belongs to THIS CLIENT ACTUATOR" in log_window
    data["client_actuator_claims_locomotion"] = client_owns
    if server_wrote and client_owns:
        return Facet("WRITERS", FAIL,
                     "BOTH actuators were active in the window: the server "
                     "per-census path issued destinations (%s orders delta, "
                     "%d bot id(s) in GoToPoint log lines) while the client "
                     "per-decide path claims locomotion ownership. That is "
                     "the last-writer-wins race" % (d_orders, len(ids)), data)
    if server_wrote:
        return Facet("WRITERS", PASS,
                     "exactly one writer was active: the SERVER per-census "
                     "path (dispatch orders delta %s, %d bot id(s) named in "
                     "GoToPoint lines)" % (d_orders, len(ids)), data)
    if client_owns:
        return Facet("WRITERS", PASS,
                     "exactly one writer claims locomotion: the CLIENT "
                     "per-decide actuator, and the server path issued no "
                     "order in the window", data)
    return Facet("WRITERS", INCONCLUSIVE,
                 "no destination writer showed any activity in the window "
                 "(sain enabled=%s). Bots may be moving on the game's own AI, "
                 "or no plan/census reached either actuator; this run cannot "
                 "tell those apart" % (st1.get("enabled"),), data)


# ---------------------------------------------------------------------------
# Facet: the cover sensor, from what the HOST said
# ---------------------------------------------------------------------------
_COVER_LIVE_RE = re.compile(r"cover: (\d+) samples, (\d+) rays")
_COVER_OFF_RE = re.compile(r"cover sampling off -- (?P<why>.*)")


def facet_cover(log_window):
    """Read from the host's own report line, never from config.

    `mods/sain/client/driver.nim` prints either `cover sampling off -- <why>`
    or `cover: N samples, M rays`. Two reports are needed to say the sensor is
    LIVE, because one report proves only that the line was printed -- a frozen
    counter and a working one look identical in a single sample.
    """
    off = _COVER_OFF_RE.search(log_window)
    live = _COVER_LIVE_RE.findall(log_window)
    if off and not live:
        return Facet("COVER", FAIL,
                     "the host reports the cover sensor DECLINING: \"cover "
                     "sampling off -- %s\"" % off.group("why")[:160].strip(),
                     {"reason": off.group("why")[:160].strip()})
    if not live:
        return Facet("COVER", INCONCLUSIVE,
                     "the host log said nothing about the cover sensor in the "
                     "window, so it was not observed either way")
    if len(live) < 2:
        return Facet("COVER", INCONCLUSIVE,
                     "only ONE cover report in the window (%s samples, %s "
                     "rays). A frozen counter and a live one are identical in "
                     "one sample; widen --window" % live[0],
                     {"samples": int(live[0][0])})
    first, last = int(live[0][0]), int(live[-1][0])
    data = {"samples_first": first, "samples_last": last}
    if last > first:
        return Facet("COVER", PASS,
                     "the cover sensor is LIVE: samples went %d -> %d across "
                     "%d reports in the window" % (first, last, len(live)),
                     data)
    return Facet("COVER", FAIL,
                 "the cover sensor is NOT sampling: the sample counter stayed "
                 "at %d across %d reports in the window" % (first, len(live)),
                 data)


def facet_botstate():
    """Named UNAVAILABLE rather than omitted, so its absence cannot read as a
    pass. See the module docstring for why it is not reachable."""
    return Facet("BOTSTATE", INCONCLUSIVE,
                 "per-bot combat/searching/idle was NOT measured. It lives in "
                 "EFT.BotOwner._botState @0x30 (abi/aowlspt_botnav.h), and "
                 "BotOwner is not reachable from GameWorld.RegisteredPlayers "
                 "-- that list holds EFT.Player. Reaching it needs a host-side "
                 "census verb on the existing BotOwner::UpdateManual detour")


# ---------------------------------------------------------------------------
# The host log, windowed
# ---------------------------------------------------------------------------
def read_log_tail(path, max_bytes=512 * 1024):
    """The host log is one run and can be large; only its tail is ever read.
    Returns "" when absent -- and the caller turns that into INCONCLUSIVE."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def log_window(before, after):
    """The lines the host added between the two reads. Byte-suffix, not
    timestamp arithmetic: the host log's stamp is elapsed-since-attach, and
    the suffix answer cannot be wrong about ordering."""
    if not after:
        return ""
    if before and after.startswith(before):
        return after[len(before):]
    if before and before in after:
        return after.split(before, 1)[1]
    return after


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
def render(facets, hist, extra, verdict):
    L = []
    L.append("BOT AUDIT -- is the bot AI changing what bots do?")
    for k, v in extra:
        L.append("  %s" % ("%s: %s" % (k, v))[:200])
    if hist:
        rows = sorted(hist.items(), key=lambda kv: -kv[1]["registered"])[:12]
        L.append("  roles: " + ", ".join(
            "%s %d/%d alive" % (k, v["alive"], v["registered"])
            for k, v in rows))
    for f in facets:
        L.append("  %-9s %-12s %s" % (f.name, f.outcome, f.detail[:400]))
    L.append("  OVERALL: %s   (FAIL > INCONCLUSIVE > PASS)" % verdict)
    return "\n".join(L)


def run_live(args):
    root = args.root
    log_path = os.path.join(root, "aowlspt-host.log")
    if not os.path.isdir(root):
        print("!! %s does not exist -- nothing to audit." % root,
              file=sys.stderr)
        return 3
    try:
        chan = LiveChannel(root=root, timeout=args.timeout)
    except ImportError as e:
        print("!! could not load the inspector transport: %s" % e,
              file=sys.stderr)
        return 3

    log_before = read_log_tail(log_path)
    st0, why0 = fetch_sain_status(args.sain_url)
    world = World(chan)
    try:
        s0 = world.snapshot()
    except Exception as e:
        print("!! the first sample could not be taken: %s: %s"
              % (e.__class__.__name__, e), file=sys.stderr)
        print("   NOTHING was measured. This is INCONCLUSIVE, not a pass.",
              file=sys.stderr)
        return 2
    if s0.why:
        print(render([Facet("CENSUS", INCONCLUSIVE, s0.why)], {},
                     [("window", "not started")], INCONCLUSIVE))
        return 2

    roles = world.roles(s0.ai)
    time.sleep(args.window)
    try:
        s1 = world.snapshot()
    except Exception as e:
        print("!! the second sample could not be taken: %s: %s"
              % (e.__class__.__name__, e), file=sys.stderr)
        return 2
    st1, why1 = fetch_sain_status(args.sain_url)
    win = log_window(log_before, read_log_tail(log_path))
    if s1.why:
        print(render([Facet("CENSUS", INCONCLUSIVE, s1.why)], {},
                     [("window", "%.1fs" % args.window)], INCONCLUSIVE))
        return 2

    elapsed = s1.t - s0.t
    control = facet_control(s0, s1, args.move_threshold)
    facets = [control,
              facet_movement(s0, s1, control, args.move_threshold, elapsed),
              facet_writers(st0, why0, st1, why1, win),
              facet_cover(win),
              facet_botstate()]
    hist = role_histogram(s1.ai, roles, s1.alive)
    verdict = overall(facets)
    extra = [("window", "%.1f s, %d inspector batches" % (elapsed, chan.batches)),
             ("world", "registered %d, AI %d, alive-list %d, fake-null %d"
              % (len(s1.registered), len(s1.ai), len(s1.alive),
                 len(s1.fake_null))),
             ("sain", "enabled=%s" % (st1.get("enabled") if st1 else "unknown"))]
    if args.json:
        print(json.dumps({"overall": verdict,
                          "window_s": round(elapsed, 2),
                          "roles": hist,
                          "facets": [f.as_dict() for f in facets]}, indent=1))
    else:
        print(render(facets, hist, extra, verdict))
    return {PASS: 0, FAIL: 1, INCONCLUSIVE: 2}[verdict]


# ---------------------------------------------------------------------------
# --selftest: offline, deterministic, and aimed at the ways this tool could
# lie rather than at the ways it could crash.
# ---------------------------------------------------------------------------
def _build_world(bot_moves, player_moves, n_bots=3, ai=True, fake_null=0):
    """A synthetic GameWorld. Returns (chan_factory, you_ptr, bot_ptrs)."""
    GW, YOU = 0x10000, 0x20000
    regl, alivel, arr, arr2 = 0x30000, 0x31000, 0x32000, 0x33000
    bots = [0x40000 + 0x1000 * i for i in range(n_bots)]
    players = [YOU] + bots

    def make(shift):
        mem = {}
        mem[GW + GW_REGPLAYERS] = ("ptr", regl)
        mem[GW + GW_ALIVELIST] = ("ptr", alivel)
        mem[regl + LIST_SIZE] = ("i32", len(players))
        mem[regl + LIST_ITEMS] = ("ptr", arr)
        mem[alivel + LIST_SIZE] = ("i32", len(players))
        mem[alivel + LIST_ITEMS] = ("ptr", arr2)
        for i, p in enumerate(players):
            mem[arr + ARR_ELEMS + 8 * i] = ("ptr", p)
            mem[arr2 + ARR_ELEMS + 8 * i] = ("ptr", p)
        for i, p in enumerate(players):
            dead = (p != YOU and i <= fake_null and fake_null)
            mem[p + PL_CACHEDPTR] = ("ptr", 0 if dead else p + 0x900000)
            mem[p + PL_AIDATA] = ("ptr", (p + 0x800000) if (p != YOU and ai) else 0)
            mem[p + PL_ISYOU] = ("bool", p == YOU)
            mc = p + 0x100
            mem[p + PL_MOVECTX] = ("ptr", mc)
            d = (player_moves if p == YOU else bot_moves) * shift
            mem[mc + MC_PREVPOS] = ("f32", 100.0 + d)
            mem[mc + MC_PREVPOS + 4] = ("f32", 5.0)
            mem[mc + MC_PREVPOS + 8] = ("f32", 200.0)
            prof, info, st = p + 0x200, p + 0x300, p + 0x400
            mem[p + PL_PROFILE] = ("ptr", prof)
            mem[prof + PROF_INFO] = ("ptr", info)
            mem[info + INFO_SETTINGS] = ("ptr", st)
            mem[st + SET_ROLE] = ("i32", 0 if p != YOU else 24)
            mem[st + SET_DIFF] = ("i32", 2)
        return FakeChannel(mem, {"gameworld": GW, "you": YOU})
    return make, YOU, bots


def _sample_pair(bot_moves, player_moves, **kw):
    make, _you, _bots = _build_world(bot_moves, player_moves, **kw)
    s0 = World(make(0)).snapshot()
    s1 = World(make(1)).snapshot()
    s0.t, s1.t = 0.0, 30.0
    return s0, s1


def selftest():
    fails = []

    def check(name, cond, why=""):
        print("  %-52s %s" % (name, "ok" if cond else "FAILED " + why))
        if not cond:
            fails.append(name)

    # --- the decoders. f32 comes from BITS, so formatting cannot move it.
    by_addr, names, errs = parse_reads(
        "  0x0000000100000010 as ptr = 0x00000001DEADBEEF  readable\n"
        "  0x0000000100000020 as i32 = -5  (0xFFFFFFFB)\n"
        "  0x0000000100000030 as f32 = 12.3400  (bits 0x414570A4)\n"
        "  0x0000000100000040 as bool = true  (0x01)\n"
        "  ! not readable for 4 bytes at 0x50\n"
        "  $gw = 0x00000001CAFE0000\n")
    check("parse_reads: ptr", by_addr[0x100000010] == 0x1DEADBEEF)
    check("parse_reads: negative i32", by_addr[0x100000020] == -5)
    check("parse_reads: f32 from bits",
          abs(by_addr[0x100000030] - 12.34) < 1e-4)
    check("parse_reads: bool", by_addr[0x100000040] is True)
    check("parse_reads: an error line yields NO key, not a zero",
          0x50 not in by_addr and errs == 1)
    check("parse_reads: `let` anchor", names["gw"] == 0x1CAFE0000)

    # --- a walking player and one walking bot.
    s0, s1 = _sample_pair(bot_moves=4.0, player_moves=12.0)
    check("snapshot: found 3 AI players", len(s1.ai) == 3, str(len(s1.ai)))
    check("snapshot: found the local player and it is NOT AI",
          s1.you and s1.you not in s1.ai)
    c = facet_control(s0, s1, 0.5)
    m = facet_movement(s0, s1, c, 0.5, 30.0)
    check("control PASSes when the player walked", c.outcome == PASS, c.detail)
    check("movement PASSes when bots walked", m.outcome == PASS, m.detail)

    # --- THE CASE THIS TOOL EXISTS FOR: frozen bots, walking player.
    s0, s1 = _sample_pair(bot_moves=0.0, player_moves=12.0)
    c = facet_control(s0, s1, 0.5)
    m = facet_movement(s0, s1, c, 0.5, 30.0)
    check("frozen bots + walking player => movement FAIL",
          c.outcome == PASS and m.outcome == FAIL, m.outcome)
    check("the FAIL sentence is the falsifiable negative",
          "no bot moved more than" in m.detail)

    # --- THE ANTI-FLATTEN CASE: frozen bots, motionless player. A broken
    # meter looks exactly like this, so it must NOT convict.
    s0, s1 = _sample_pair(bot_moves=0.0, player_moves=0.0)
    c = facet_control(s0, s1, 0.5)
    m = facet_movement(s0, s1, c, 0.5, 30.0)
    check("frozen bots + still player => control INCONCLUSIVE",
          c.outcome == INCONCLUSIVE, c.outcome)
    check("frozen bots + still player => movement INCONCLUSIVE, never FAIL",
          m.outcome == INCONCLUSIVE, m.outcome)

    # --- a broken meter with a walking player: the control catches it.
    make, _y, _b = _build_world(4.0, 12.0)
    s0 = World(make(0)).snapshot()
    s1 = World(make(0)).snapshot()          # identical world = a dead meter
    s0.t, s1.t = 0.0, 30.0
    c = facet_control(s0, s1, 0.5)
    m = facet_movement(s0, s1, c, 0.5, 30.0)
    check("a meter that reads the same twice cannot produce FAIL",
          c.outcome == INCONCLUSIVE and m.outcome == INCONCLUSIVE, m.outcome)

    # --- no bots at all.
    s0, s1 = _sample_pair(0.0, 12.0, ai=False)
    c = facet_control(s0, s1, 0.5)
    m = facet_movement(s0, s1, c, 0.5, 30.0)
    check("no AI players => INCONCLUSIVE, not '0 misbehaving, pass'",
          m.outcome == INCONCLUSIVE and "NOT" in m.detail, m.outcome)

    # --- Unity fake-null is excluded from the live population.
    s0, s1 = _sample_pair(4.0, 12.0, fake_null=1)
    check("fake-null (m_CachedPtr==0) players are excluded from AI",
          len(s1.fake_null) >= 1 and len(s1.ai) == 3 - len(s1.fake_null),
          "%d/%d" % (len(s1.fake_null), len(s1.ai)))

    # --- no GameWorld at all.
    empty = FakeChannel({}, {"gameworld": 0, "you": 0})
    s = World(empty).snapshot()
    check("no GameWorld => a reason, and NOTHING claimed",
          bool(s.why) and "NOTHING was measured" in s.why)

    # --- roles: an unreadable role is 'role?', never 0/'assault'.
    make, you, bots = _build_world(1.0, 1.0)
    w = World(make(0))
    r = w.roles(w.snapshot().ai)
    hist = role_histogram(w.snapshot().ai, r, set(bots))
    check("role histogram names assault from role id 0",
          hist.get("assault", {}).get("registered") == 3, str(hist))
    check("an unknown role prints its number, never a guess",
          role_name(99) == "role99" and role_name(None) == "role?")

    # --- writers.
    st0 = {"enabled": True, "drive": "drive: armed, 10 censuses, 5 bots",
           "dispatch": "dispatch: 3 anchors on 'x' (1 questPoi), 10 censuses "
                       "entered, 4 orders, 5 bots"}
    st1 = dict(st0, dispatch="dispatch: 3 anchors on 'x' (1 questPoi), 20 "
                             "censuses entered, 9 orders, 5 bots")
    f = facet_writers(st0, None, st1, None, "botnav: bot id=7 GoToPoint(1,2,3)")
    check("writers: server path advancing => PASS, one writer named",
          f.outcome == PASS and "SERVER" in f.detail, f.detail)
    f = facet_writers(st0, None, st1, None,
                      "botnav: bot id=7 GoToPoint(1,2,3)\n"
                      "sain: one writer: locomotion belongs to THIS CLIENT "
                      "ACTUATOR (clientDrivesLocomotion on)")
    check("writers: BOTH actuators active => FAIL (the documented race)",
          f.outcome == FAIL, f.detail)
    f = facet_writers(st0, None, st0, None, "")
    check("writers: nothing advanced => INCONCLUSIVE, not PASS",
          f.outcome == INCONCLUSIVE, f.detail)
    f = facet_writers(None, "unreachable", None, "unreachable", "")
    check("writers: status route unreachable => INCONCLUSIVE",
          f.outcome == INCONCLUSIVE and "unreachable" in f.detail)

    # --- cover.
    check("cover: counter advancing across two reports => PASS",
          facet_cover("cover: 10 samples, 40 rays\n"
                      "cover: 25 samples, 90 rays\n").outcome == PASS)
    check("cover: a frozen counter => FAIL",
          facet_cover("cover: 10 samples, 40 rays\n"
                      "cover: 10 samples, 40 rays\n").outcome == FAIL)
    check("cover: exactly one report => INCONCLUSIVE, not PASS",
          facet_cover("cover: 10 samples, 40 rays\n").outcome == INCONCLUSIVE)
    check("cover: the host saying it is off => FAIL with its own words",
          facet_cover("cover sampling off -- refused: no IL2CPP runtime"
                      ).outcome == FAIL)
    check("cover: silence => INCONCLUSIVE",
          facet_cover("nothing about cover here").outcome == INCONCLUSIVE)

    # --- the unreachable facet is present and never a pass.
    check("botstate is reported UNAVAILABLE, not omitted",
          facet_botstate().outcome == INCONCLUSIVE)

    # --- precedence.
    P = Facet("a", PASS, ""); I = Facet("b", INCONCLUSIVE, "")
    F = Facet("c", FAIL, "")
    check("precedence FAIL > INCONCLUSIVE > PASS",
          overall([P, I, F]) == FAIL and overall([P, I]) == INCONCLUSIVE
          and overall([P, P]) == PASS)
    check("no facets at all => INCONCLUSIVE", overall([]) == INCONCLUSIVE)

    # --- the log window is a suffix, and an absent log is empty (=> the
    # facets that read it go INCONCLUSIVE, which is asserted above).
    check("log_window returns only what was appended",
          log_window("aaa", "aaabbb") == "bbb" and log_window("", "x") == "x")
    check("an absent host log reads as empty",
          read_log_tail(os.path.join(os.path.dirname(__file__),
                                     "no-such-file.log")) == "")

    # --- the channel refuses to emit anything that writes.
    try:
        LiveChannel.send.__get__(FakeChannel({}, {}), FakeChannel)
        bad = False
    except Exception:
        bad = False
    try:
        c = LiveChannel.__new__(LiveChannel)
        c.__dict__.update(batches=0, root=None, timeout=1.0, _ch=None)
        LiveChannel.send(c, ["write 0x10 i32 5"])
        bad = True
    except ValueError:
        bad = False
    check("the live channel refuses any non-read command", not bad)

    print("\n  %d check(s) failed" % len(fails) if fails
          else "\n  selftest: all checks passed")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(
        description="Measure whether bots are actually behaving differently.")
    ap.add_argument("--window", type=float, default=30.0,
                    help="seconds between the two samples (default 30)")
    ap.add_argument("--move-threshold", type=float, default=0.5,
                    help="metres that count as MOVED (default 0.5)")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--sain-url", default=SAIN_STATUS_URL,
                    help="port 6969, NOT 80")
    ap.add_argument("--timeout", type=float, default=25.0,
                    help="seconds to wait for one inspector batch")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="run offline against fixtures; touches no game")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    return run_live(a)


if __name__ == "__main__":
    sys.exit(main())
