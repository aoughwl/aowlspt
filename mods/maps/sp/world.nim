## The entity feed -- the ONE place this mod touches game memory.
##
## Three features (map, radar, indicators) all want the same thing: where the
## player is, where everything else is, and which way the player is facing. So
## there is one collector, not three. Everything downstream -- the browser map,
## the radar ring, the direction indicators -- is arithmetic on the snapshot
## this file publishes and touches no game memory at all.
##
## ---------------------------------------------------------------------------
## WHAT THIS FILE IS ALLOWED TO DO, AND WHY IT IS SO LITTLE
## ---------------------------------------------------------------------------
##
## Fact #145: on this build EVERY by-NAME IL2CPP route is fatal the moment it
## is USED. Not when it is resolved -- when it is used. `il2cpp_class_from_name`
## and `il2cpp_class_get_method_from_name` return NON-NIL pointers into
## UNMAPPED memory (fact #35), so a `if cls == nil` guard is a check that
## CANNOT FAIL and the process dies at the first dereference through the
## handle. So this file resolves NOTHING by name. It has no bindings, installs
## no detour, and calls no game method.
##
## What is left is exactly two things, and they are enough:
##
##   1. **A borrowed world pointer.** `aowl_host_gameworld` is a host export
##      populated by the host's OWN, ALREADY-ARMED `RegisterPlayer` detour. We
##      do not add a second detour: a second detour on one function overwrites
##      the first's trampoline and silently kills the first feature. We read the
##      cache the existing one fills.
##
##   2. **Raw reads at MEASURED static field offsets**, each one guarded by
##      `aowl_is_readable` (VirtualQuery) so a stale offset or a moved object is
##      a zero rather than a fault.
##
## ---------------------------------------------------------------------------
## PROVENANCE OF EVERY OFFSET BELOW
## ---------------------------------------------------------------------------
##
## Measured with `python tools/fldoff.py field <Type> <Field>` against
## `.cache/global-metadata.dec.dat`, which runs a mandatory self-check
## (System.String._stringLength@0x10 / _firstChar@0x14) and prints nothing else
## if that fails -- so a metadata layout change announces itself instead of
## being silently misread. Re-run those commands to falsify any line here.
##
##   EFT.GameWorld     AllAlivePlayersList              0x1c8
##   EFT.GameWorld     RegisteredPlayers                0x1d0
##   EFT.GameWorld     MainPlayer                       0x230
##   EFT.Player        <MovementContext>k__BackingField 0x60
##   EFT.Player        <Profile>k__BackingField         0x9c0
##   EFT.Player        <AIData>k__BackingField          0xa00
##   EFT.MovementContext PreviousPosition               0x370   (Vector3)
##   EFT.Profile       Id                               0x10    (System.String)
##
## They are constants, not runtime lookups, precisely because the runtime
## lookup needs the faulting API. The cost is that a Tarkov update invalidates
## them -- which is why `feedDefect()` names the FIRST hop that did not
## validate, and `feedStateText()` never reports "could not look" as "no raid".
##
## ---------------------------------------------------------------------------
## WHAT IS NOT HERE, STATED PLAINLY
## ---------------------------------------------------------------------------
##
## **Player HEADING is not read.** The radar and the indicators both want which
## way the player faces. `MovementContext` carries rotation, but no field on it
## resolved to a name this file could measure with confidence, and a heading
## read from a guessed offset would be a plausible wrong number pointing every
## marker in the wrong direction -- the worst failure this project produces.
## So `heading` is published as `hasHeading:false` and every consumer draws
## NORTH-UP and says so. See README for what would unblock it.
##
## **There is no world->screen projection here.** That belongs to the in-game
## ESP path and is deliberately out of scope; this feed is top-down only, which
## is all a map and a radar need.

import aowlspt
import aowlspt/il2cpp

# --------------------------------------------------------------------------
# The host export, resolved through the OS loader rather than through anything
# il2cpp. `GetModuleHandleA`/`GetProcAddress` on our own already-loaded host
# DLL cannot fault: if the host is older than the export, or this library was
# loaded server-side where there is no host at all, the lookup returns NULL and
# that is a THIRD answer, kept distinct from "no raid" below.
# --------------------------------------------------------------------------

proc wGetModuleHandleA(name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc wGetProcAddress(module: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

# Thunks. nimony refuses `cast[proc(...)](pointer)` outright, so a raw address
# has to be called through C. The int32 form is a REAL int32 thunk and not a
# pointer-shaped read of the low half: an int32 return leaves the upper 32 bits
# of RAX undefined, so reading it as a pointer would make "returned 0" look
# like a plausible non-zero answer -- a check that cannot fail, in exactly the
# place that decides whether a human is told "not in a raid" or "nothing is
# watching".
#
# The guarded readers are here too rather than in a shared ABI header: adding
# to a shared header drops every build cache and forces a full rebuild, and
# `abi/aowlspt_admin.h` (which has equivalents) belongs to another feature.
# Each read VirtualQueries the exact address first, so a wrong offset is a
# zero, never a fault.
{.emit: """
#include <stdint.h>
#include <string.h>
#include "aowlspt_shim.h"
#include "sp/mapmath.h"

static void*   sp_p_v  (void* f) { return ((void*  (*)(void))f)(); }
static int32_t sp_i32_v(void* f) { return ((int32_t(*)(void))f)(); }

static void* sp_rd_ptr(void* o, int32_t off) {
  unsigned char* a = (unsigned char*)o + off;
  void* v = 0;
  if (!aowl_is_readable(a, (int32_t)sizeof(void*))) return 0;
  memcpy(&v, a, sizeof(void*));
  return v;
}
static int32_t sp_rd_i32(void* o, int32_t off) {
  unsigned char* a = (unsigned char*)o + off;
  int32_t v = 0;
  if (!aowl_is_readable(a, 4)) return 0;
  memcpy(&v, a, 4);
  return v;
}
static float sp_rd_f32(void* o, int32_t off) {
  unsigned char* a = (unsigned char*)o + off;
  float v = 0.0f;
  if (!aowl_is_readable(a, 4)) return 0.0f;
  memcpy(&v, a, 4);
  return v;
}
/* THE WHOLE Vector3 IN ONE READ, WITH THE READABILITY ANSWERED SEPARATELY.
 *
 * `sp_rd_f32` returns 0.0f both for "this page is not mapped" and for "the
 * float really is zero". `posOf` then rejects (0,0,0) -- so an unmapped page
 * and a player standing on the origin produce the IDENTICAL, unreported
 * outcome, and the mod cannot say which happened. That ambiguity is why the
 * radar drew nothing and explained nothing.
 *
 * Returns 1 when all 12 bytes were readable, 0 when they were not. The caller
 * must NOT infer the position from the return value alone: 1 only means the
 * bytes were there, and the plausibility tests still apply. */
static int32_t sp_rd_vec3(void* o, int32_t off, float* out3) {
  unsigned char* a = (unsigned char*)o + off;
  out3[0] = 0.0f; out3[1] = 0.0f; out3[2] = 0.0f;
  if (!aowl_is_readable(a, 12)) return 0;
  memcpy(out3, a, 12);
  return 1;
}
/* Read the Vector3 AND classify it in one call, so the readability answer and
 * the plausibility answer cannot drift apart. Returns an MM_POS_* code; the
 * thresholds live in sp/mapmath.h and are covered by
 * tests/overlayhost/mapstest.c, so this is not a second implementation. */
static int32_t sp_pos_read(void* o, int32_t off, float* out3) {
  int32_t r = sp_rd_vec3(o, off, out3);
  return (int32_t)mm_pos_classify((int)r, out3[0], out3[1], out3[2]);
}
/* A System.String's last 8 hex characters, as ASCII, into `out` (>=9 bytes).
 * The tail rather than the head because a Tarkov profile id is a 24-char
 * MongoDB ObjectId whose tail is the distinguishing part. UTF-16 chars are
 * narrowed and anything outside printable ASCII becomes '?', so a wrong
 * offset yields visible junk rather than smuggling bytes into JSON. Capped by
 * construction: at most 8 iterations whatever the length field says. */
static int32_t sp_rd_idtail(void* s, int32_t lenOff, int32_t chOff, char* out) {
  int32_t n, take, i;
  out[0] = 0;
  if (!s) return 0;
  if (!aowl_is_readable((unsigned char*)s + lenOff, 4)) return 0;
  memcpy(&n, (unsigned char*)s + lenOff, 4);
  if (n <= 0 || n > 4096) return 0;
  take = n > 8 ? 8 : n;
  for (i = 0; i < take; i++) {
    unsigned short c = 0;
    unsigned char* a = (unsigned char*)s + chOff + (n - take + i) * 2;
    if (!aowl_is_readable(a, 2)) { out[i] = 0; return i; }
    memcpy(&c, a, 2);
    out[i] = (c >= 32 && c < 127) ? (char)c : '?';
  }
  out[take] = 0;
  return take;
}
""".}

proc spPV(f: Il2CppPtr): Il2CppPtr {.importc: "sp_p_v", nodecl.}
proc spI32V(f: Il2CppPtr): int32 {.importc: "sp_i32_v", nodecl.}
proc cRdPtr(o: pointer; off: int32): pointer {.importc: "sp_rd_ptr", nodecl.}
proc cRdI32(o: pointer; off: int32): int32 {.importc: "sp_rd_i32", nodecl.}
proc cRdF32(o: pointer; off: int32): cfloat {.importc: "sp_rd_f32", nodecl.}
proc cRdVec3(o: pointer; off: int32; out3: ptr cfloat): int32 {.
  importc: "sp_rd_vec3", nodecl.}
proc cPosRead(o: pointer; off: int32; out3: ptr cfloat): int32 {.
  importc: "sp_pos_read", nodecl.}

const
  # Mirrors MM_POS_* in sp/mapmath.h. Kept as named constants so a `case` over
  # them is exhaustive and a new code cannot be silently ignored.
  MmPosOk*         = 0
  MmPosUnreadable* = 1
  MmPosNan*        = 2
  MmPosRange*      = 3
  MmPosAllZero*    = 4
proc cRdIdTail(s: pointer; lenOff, chOff: int32; outBuf: cstring): int32 {.
  importc: "sp_rd_idtail", nodecl.}

proc rdPtr(o: pointer; off: int): pointer =
  if o == nil: return nil
  result = cRdPtr(o, int32(off))
proc rdI32(o: pointer; off: int): int32 =
  if o == nil: return 0'i32
  result = cRdI32(o, int32(off))
proc rdF32(o: pointer; off: int): float =
  if o == nil: return 0.0
  result = float(cRdF32(o, int32(off)))

# --------------------------------------------------------------------------
# Offsets
# --------------------------------------------------------------------------

const
  # il2cpp x64 object layout -- ABI constants, stable across builds.
  ListItemsOff = 0x10   ## List<T>._items (the T[] backing array)
  ListSizeOff  = 0x18   ## List<T>._size  (int)
  ArrDataOff   = 0x20   ## first element of an il2cpp array on x64
  StrLenOff    = 0x10   ## System.String._stringLength
  StrCharOff   = 0x14   ## System.String._firstChar

  # MEASURED, see the provenance block at the top of this file.
  GwAllAlive   = 0x1C8
  GwRegistered = 0x1D0
  GwMainPlayer = 0x230
  PlMoveCtx    = 0x60
  PlProfile    = 0x9C0
  PlAIData     = 0xA00
  McPrevPos    = 0x370
  PrId         = 0x10

const
  MaxEntities* = 128
    ## Capped iteration. A raid is well under this; a corrupt count must not
    ## become an unbounded loop.
  MaxListLen = 1024
    ## Anything above this is a corrupt size field, not a big raid.
  MaxFaults* = 8
    ## Self-disable budget. After this many failed collections the feed stops
    ## touching game memory for the rest of the session and says so.

type
  Ent* = object
    x*, y*, z*: float
    bot*: bool
    me*: bool
    id*: string        ## last 8 chars of the profile id, or "" -- a label,
                       ## never used as an identity key

var gFn: Il2CppPtr = cast[Il2CppPtr](0)
var gArmedFn: Il2CppPtr = cast[Il2CppPtr](0)
var gTried = false

proc resolveHost() =
  if gTried: return
  gTried = true
  var hostName = "aowlspt-host-il2cpp.dll"
  let h = wGetModuleHandleA(toCString(hostName))
  if h == nil: return
  var n1 = "aowl_host_gameworld"
  var n2 = "aowl_host_gameworld_armed"
  gFn = wGetProcAddress(h, toCString(n1))
  gArmedFn = wGetProcAddress(h, toCString(n2))

proc gwState*(): int =
  ## FOUR answers, never flattened to a bool. CLAUDE.md 9b: "I could not look"
  ## is not "no raid", and a UI that shows an empty map for both is lying about
  ## one of them.
  ##   0 no host export -- host too old, or this is not the client process
  ##   1 export present but NO detour armed -- INCONCLUSIVE
  ##   2 armed, cache empty -- genuinely not in a raid
  ##   3 world live
  resolveHost()
  if gFn == nil: return 0
  if gArmedFn != nil and spI32V(gArmedFn) == 0'i32: return 1
  if spPV(gFn) == nil: return 2
  result = 3

proc gwStateText*(): string =
  case gwState()
  of 0: "no host export aowl_host_gameworld -- this host predates it, or this " &
        "mod is not running in the client. There is no fallback: " &
        "EFT.GameWorld::get_Instance does not exist on this build and calling " &
        "an invented name is fatal (fact #145), so none is invented"
  of 1: "the host exports the world but NO detour is armed to populate it -- " &
        "set the host flag debugEsp or botDiag. INCONCLUSIVE, not 'no raid'"
  of 2: "armed; no GameWorld cached yet, which is exactly what the menu looks like"
  else: "GameWorld live, borrowed from the host's already-armed RegisterPlayer cache"

# --------------------------------------------------------------------------
# The snapshot
# --------------------------------------------------------------------------

type
  Snapshot* = object
    ok*: bool            ## a world was live AND at least the local player read
    inRaid*: bool
    n*: int
    ents*: array[MaxEntities, Ent]
    localIdx*: int       ## index into ents of the local player, or -1
    hasHeading*: bool    ## always false today -- see the header block
    heading*: float
    state*: int          ## gwState() at collection time
    seq*: int64

var gDefect = ""
var gFaults = 0
var gSeq = 0'i64

proc note(msg: string) =
  ## FIRST failing hop wins. A later failure is a consequence, not the cause,
  ## and reporting the consequence sends the next reader the wrong way.
  if gDefect.len == 0: gDefect = msg

proc feedDefect*(): string =
  if gDefect.len == 0: "none" else: gDefect
proc feedFaults*(): int = gFaults
proc feedDisabled*(): bool = gFaults >= MaxFaults

proc feedStateText*(): string =
  if feedDisabled():
    return "self-disabled after " & $gFaults & " faults; first was: " & feedDefect()
  gwStateText()

# ---------------------------------------------------------------------------
# WHY A POSITION READ FAILED. Counters, not a bool.
# ---------------------------------------------------------------------------
#
# `posOf` had SIX distinct ways to return false and reported none of them: it
# set `ok = false` and returned, spending no fault budget and writing no
# defect. That is what made the radar silent. A snapshot captured from the
# live client on 2026-08-28 (seq 12109, in a raid) read
#
#   state:"live" inRaid:true ok:false localIdx:-1 ents:[] faults:0 defect:"none"
#
# -- the world was live, the player list was walked, and EVERY entry was
# discarded with nothing recorded anywhere. `defect:"none"` is a lie of
# omission: nothing was wrong that the code was willing to name.
#
# These counters are the whole point. They are per-collection (reset each
# `collect`) AND cumulative, because "no player passed on THIS frame" and
# "no player has EVER passed" are different bugs.
type
  PosReason* = object
    nilPlayer*, nilCtx*, unreadable*, nan*, outOfRange*, allZero*, good*: int

var gPosNow: PosReason
var gPosEver: PosReason

proc posAdd(a: var PosReason; b: PosReason) =
  a.nilPlayer  = a.nilPlayer  + b.nilPlayer
  a.nilCtx     = a.nilCtx     + b.nilCtx
  a.unreadable = a.unreadable + b.unreadable
  a.nan        = a.nan        + b.nan
  a.outOfRange = a.outOfRange + b.outOfRange
  a.allZero    = a.allZero    + b.allZero
  a.good       = a.good       + b.good

proc posReasonText(r: PosReason): string =
  "good=" & $r.good & " nilPlayer=" & $r.nilPlayer & " nilMoveCtx=" & $r.nilCtx &
  " unreadable=" & $r.unreadable & " NaN=" & $r.nan &
  " outOfRange=" & $r.outOfRange & " allZero=" & $r.allZero

proc posEverText*(): string = posReasonText(gPosEver)
proc posNowText*(): string = posReasonText(gPosNow)
proc posEverGood*(): int = gPosEver.good
proc posEverTried*(): int =
  gPosEver.good + gPosEver.nilPlayer + gPosEver.nilCtx + gPosEver.unreadable +
  gPosEver.nan + gPosEver.outOfRange + gPosEver.allZero

proc posVerdict*(): string =
  ## The single sentence a human needs. It names the DOMINANT reason, because
  ## "all of them failed" and "one of them failed" want different next moves.
  let tried = posEverTried()
  if tried == 0:
    return "no position read has been ATTEMPTED yet -- either no raid, or the " &
           "collector is not running. INCONCLUSIVE, not 'the offsets are wrong'"
  if gPosEver.good > 0:
    return "positions ARE being read (" & $gPosEver.good & " of " & $tried & ")"
  # Nothing has ever passed. Say which gate ate them, by name and offset.
  if gPosEver.unreadable > 0:
    return "EVERY position read failed and " & $gPosEver.unreadable &
           " were UNREADABLE -- MovementContext+0x370 is not mapped, so the " &
           "object is not a MovementContext (a wrong Player+0x60, or a freed " &
           "object). This is a POINTER problem, not an offset-value problem"
  if gPosEver.allZero > 0:
    return "EVERY position read failed and " & $gPosEver.allZero &
           " came back exactly (0,0,0) from a READABLE page -- the bytes at " &
           "MovementContext+0x370 are really zero, so that field is not the " &
           "live pose on this build, or the object is a fresh/unspawned Player"
  if gPosEver.nan > 0 or gPosEver.outOfRange > 0:
    return "EVERY position read failed plausibility (NaN=" & $gPosEver.nan &
           " outOfRange=" & $gPosEver.outOfRange & ") -- the page is mapped " &
           "and holds non-position bytes, which means Player+0x60 or " &
           "MovementContext+0x370 is pointing at the wrong thing"
  if gPosEver.nilCtx > 0:
    return "EVERY position read failed because Player+0x60 " &
           "<MovementContext>k__BackingField was NULL for all " &
           $gPosEver.nilCtx & " players"
  "EVERY position read failed and no reason was recorded -- this is a BUG in " &
  "posOf's own accounting, not a measurement"

proc posOf(p: pointer; ok: var bool; x, y, z: var float) =
  ## Player +0x60 -> MovementContext +0x370 (Vector3). This is the pose the
  ## client itself reads, not a transform we chose.
  ##
  ## Offsets re-verified offline 2026-08-28 against
  ## `.cache/global-metadata.dec.dat` (fldoff self-check passed):
  ##   EFT.Player.<MovementContext>k__BackingField  0x60
  ##   EFT.MovementContext.PreviousPosition Vector3 0x370
  ## Both are CORRECT, so a failure here is about the POINTER or the live
  ## bytes, never about the constants. Every exit below is counted.
  ok = false
  x = 0.0; y = 0.0; z = 0.0
  if p == nil:
    gPosNow.nilPlayer = gPosNow.nilPlayer + 1
    return
  let mc = rdPtr(p, PlMoveCtx)
  if mc == nil:
    gPosNow.nilCtx = gPosNow.nilCtx + 1
    note("Player+0x60 <MovementContext>k__BackingField read null")
    return
  # One 12-byte read whose READABILITY is answered separately from its
  # PLAUSIBILITY, so "the page is not mapped" stops masquerading as "the
  # player is at the origin". The thresholds are mm_pos_classify's, in
  # sp/mapmath.h, tested offline -- they are not restated here.
  # Explicitly zeroed: nimony cannot prove an array written only through a
  # `ptr` passed to C is initialised, and it is right to refuse -- if the C
  # side ever returned without writing, these would be whatever was on the
  # stack, which is the "plausible wrong number" failure this file exists to
  # avoid. `sp_rd_vec3` zeroes them too; agreeing costs nothing.
  var v: array[3, cfloat] = [0.0'f32, 0.0'f32, 0.0'f32]
  let code = cPosRead(mc, int32(McPrevPos), addr v[0])
  x = float(v[0]); y = float(v[1]); z = float(v[2])
  case int(code)
  of MmPosUnreadable:
    gPosNow.unreadable = gPosNow.unreadable + 1
    note("MovementContext+0x370 PreviousPosition is NOT READABLE (12 bytes) " &
         "-- a VirtualQuery refusal, not a zero position")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosNan:
    gPosNow.nan = gPosNow.nan + 1
    note("MovementContext+0x370 read NaN")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosRange:
    gPosNow.outOfRange = gPosNow.outOfRange + 1
    note("MovementContext+0x370 read out of range (|component| > 1e6)")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosAllZero:
    gPosNow.allZero = gPosNow.allZero + 1
    note("MovementContext+0x370 read exactly (0,0,0) from a READABLE page")
    x = 0.0; y = 0.0; z = 0.0
    return
  else:
    gPosNow.good = gPosNow.good + 1
    ok = true

proc idTailOf(p: pointer): string =
  ## Player +0x9c0 -> Profile +0x10 -> System.String, last 8 chars. Purely a
  ## human-readable label for a marker tooltip. It is NOT used to key anything,
  ## so a truncated or wrong read degrades a label and nothing else.
  result = ""
  if p == nil: return
  let prof = rdPtr(p, PlProfile)
  if prof == nil: return
  let s = rdPtr(prof, PrId)
  if s == nil: return
  var buf = "         "   # 9 bytes: 8 chars + NUL, written by the C helper
  let n = cRdIdTail(s, int32(StrLenOff), int32(StrCharOff), toCString(buf))
  if n <= 0: return
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc collectInner(snap: var Snapshot) =
  ## Fill `snap`. Runs on Unity's thread (the caller drives it from everyMain),
  ## so it does raw reads into a caller-owned buffer and allocates nothing per
  ## frame except the id label strings, which are bounded at 8 chars each and
  ## only built for entities that already validated.
  snap.ok = false
  snap.inRaid = false
  snap.n = 0
  snap.localIdx = -1
  snap.hasHeading = false
  snap.heading = 0.0
  inc gSeq
  snap.seq = gSeq
  # Per-collection reason tally starts empty; the cumulative one never resets.
  # Both are kept because "nobody passed THIS frame" and "nobody has EVER
  # passed" are different faults with different fixes.
  gPosNow = PosReason(nilPlayer: 0, nilCtx: 0, unreadable: 0, nan: 0,
                      outOfRange: 0, allZero: 0, good: 0)

  if feedDisabled():
    snap.state = -1
    return

  let st = gwState()
  snap.state = st
  if st != 3:
    return

  let world = spPV(gFn)
  if world == nil:
    # gwState said 3 and the very next read said nil. That is a race with the
    # host clearing its cache, not a fault -- do not spend fault budget on it.
    snap.state = 2
    return
  snap.inRaid = true

  var localPtr = 0'u64
  let me = rdPtr(world, GwMainPlayer)
  var lok = false
  var lx = 0.0
  var ly = 0.0
  var lz = 0.0
  if me != nil:
    localPtr = cast[uint64](me)
    posOf(me, lok, lx, ly, lz)
  else:
    note("GameWorld+0x230 MainPlayer read null")

  if lok:
    snap.ents[0] = Ent(x: lx, y: ly, z: lz, bot: false, me: true, id: idTailOf(me))
    snap.localIdx = 0
    snap.n = 1
    snap.ok = true

  # AllAlivePlayersList (List<Player>, concrete) first; RegisteredPlayers
  # (List<IPlayer>) only as a fallback.
  var list = rdPtr(world, GwAllAlive)
  if list == nil: list = rdPtr(world, GwRegistered)
  if list == nil:
    note("GameWorld player list (+0x1C8 / +0x1D0) read null")
    inc gFaults
    return

  let items = rdPtr(list, ListItemsOff)
  let n = int(rdI32(list, ListSizeOff))
  if items == nil or n < 0 or n > MaxListLen:
    note("player list size out of range (" & $n & ")")
    inc gFaults
    return

  var i = 0
  while i < n and snap.n < MaxEntities:
    let p = rdPtr(items, ArrDataOff + i * 8)
    inc i
    if p == nil: continue
    if cast[uint64](p) == localPtr: continue     # already emitted as ents[0]
    var pok = false
    var px = 0.0
    var py = 0.0
    var pz = 0.0
    posOf(p, pok, px, py, pz)
    if not pok: continue
    # AIData non-null => this player is a bot. A null read here is "not a bot",
    # which is the safe way round: a human mislabelled as a bot is a worse lie
    # on a radar than the reverse.
    let bot = rdPtr(p, PlAIData) != nil
    snap.ents[snap.n] = Ent(x: px, y: py, z: pz, bot: bot, me: false,
                            id: idTailOf(p))
    inc snap.n
    snap.ok = true

proc collect*(snap: var Snapshot) =
  ## Wrapper over `collectInner` whose ONLY job is that the reason tally is
  ## accumulated on EVERY exit path -- `collectInner` has six `return`s, and a
  ## tally that is only summed on the success path is exactly the check that
  ## cannot fail (CLAUDE.md 9b).
  collectInner(snap)
  posAdd(gPosEver, gPosNow)
