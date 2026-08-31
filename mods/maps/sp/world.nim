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
## handle. So this file resolves NOTHING by name. It has no bindings and
## installs no detour.
##
## It does make ONE game call, and only one: a direct call at the STATIC,
## BYTE-VERIFIED RVA 0x6F32C0. That is a different mechanism from a by-name
## lookup and is unaffected by fact #145 or by the export gates -- it never
## touches the il2cpp export ABI at all. It exists because the live world
## position is not a managed field on this build and cannot be read as one;
## see `posOf`.
##
## What is left is exactly three things, and they are enough:
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
##   3. **One direct call at a byte-verified static RVA**, armed once, and
##      preceded by a guarded walk of every pointer the callee will
##      dereference, so the callee's managed-throw branches are provably
##      unreachable before the call is made.
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
##       -- CORRECT, AND PERMANENTLY ZERO ON THIS BUILD. Kept named here only
##          so nobody re-derives it and thinks they have found the answer.
##   EFT.Player        <PlayerBones>k__BackingField      0xb40   (PlayerBones)
##   PlayerBones       BodyTransform                    0x178   (BifacialTransform)
##   EFT.BifacialTransform Original                     0x10    (Transform)
##   EFT.BifacialTransform _useImitation                0xa8    (bool)
##   EFT.BifacialTransform _accumulatePositionAndRotation 0xa9  (bool)
##   EFT.Profile       Id                               0x10    (System.String)
##
## Each of the five position-path offsets above is corroborated by a SECOND,
## independent source: the instruction bytes of the client's own accessors,
## `EFT.Player::get_Position` @0x6F32C0 and
## `EFT.BifacialTransform::get_position` @0x8D3FA0. Neither offset was taken
## from metadata alone. The decode is in the C block below.
##
## THIS FILE NOW MAKES EXACTLY ONE GAME CALL: a direct call at the static,
## byte-verified RVA 0x6F32C0. That is not a by-name route and is not a
## detour -- it is the one thing fact #145 leaves standing, and it is
## necessary because the live pose exists ONLY on Unity's native side.
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
## **Player HEADING is now read** -- this paragraph used to say it was not.
## The field was found the same way the position was: by reading the client's
## own accessor. `EFT.Player::get_LookDirection` @0x6F8060 is, in its entirety,
## `mov rax,[rdx+0x60]` then a 12-byte load from `[rax+0x3D0]`, and metadata
## independently names `EFT.MovementContext._lookDirection` a Vector3 at
## exactly 0x3D0. So the offset is not guessed and it is not inferred from the
## method's name; it is read off the instruction bytes and corroborated.
##
## Unlike the POSITION, which bottoms out in a Unity native icall and therefore
## needs a direct RVA call, the heading IS a managed field -- so no call is
## made at all, only a guarded two-hop walk. `hasHeading` is published FALSE
## for anything the classifier does not call OK, so a dead field (the
## PreviousPosition@0x370 failure) still leaves both surfaces north-up and
## says why, rather than rotating by a fake zero.
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
/* ===================================================================
 * THE LIVE WORLD POSITION IS NOT A MANAGED FIELD ON THIS BUILD.
 * ===================================================================
 *
 * `EFT.MovementContext.PreviousPosition` @0x370 EXISTS (metadata confirms the
 * name and the offset) and is genuinely, permanently zero -- 66331 readable
 * reads, all (0,0,0), measured live in a raid on 2026-08-28. It is declared
 * and never written on this build.
 *
 * Where the pose really lives, read out of the client's OWN accessor bytes,
 * corroborated field-by-field against metadata:
 *
 *   EFT.Player::get_Position  RVA 0x6F32C0
 *     40 53 48 83 EC 30              push rbx; sub rsp,0x30
 *     48 8B 82 40 0B 00 00           mov rax,[rdx+0xB40]   Player.PlayerBones
 *     48 8B D9                       mov rbx,rcx           (sret buffer)
 *     48 85 C0 74 30                 null -> throw path
 *     48 8B 90 78 01 00 00           mov rdx,[rax+0x178]   PlayerBones.BodyTransform
 *     48 85 D2 74 24                 null -> throw path
 *     45 33 C0                       xor r8d,r8d           MethodInfo* = NULL
 *     48 8D 4C 24 20                 lea rcx,[rsp+0x20]
 *     E8 B2 0C 1E 00                 call 0x8D3FA0  BifacialTransform::get_position
 *     ... F2 0F 11 03 / 89 43 08     store 12 bytes to [rbx]; return rbx
 *
 *   metadata: EFT.Player.<PlayerBones>k__BackingField @0xB40  (PlayerBones)
 *   metadata: PlayerBones.BodyTransform              @0x178  (BifacialTransform)
 *
 *   EFT.BifacialTransform::get_position  RVA 0x8D3FA0
 *     80 BA A9 00 00 00 00  cmp byte [rdx+0xA9],0   _accumulatePositionAndRotation
 *     80 BA A8 00 00 00 00  cmp byte [rdx+0xA8],0   _useImitation
 *     48 8B 7A 10           mov rdi,[rdx+0x10]      Original (UnityEngine.Transform)
 *     ... FF D0             Transform::get_position_Injected(this, out Vector3)
 *
 *   metadata: BifacialTransform.Original @0x10, _useImitation @0xA8,
 *             _accumulatePositionAndRotation @0xA9   -- all three match.
 *
 * The fast path bottoms out in a UNITY NATIVE ICall. There is therefore NO
 * managed offset that holds the live pose, and no amount of hunting for one
 * will produce it. A direct call at a byte-verified static RVA is the only
 * route, and it is the route CLAUDE.md sanctions.
 *
 * WHY WE WALK THE CHAIN OURSELVES BEFORE CALLING. Both `get_Position` and
 * `get_position` THROW a managed NullReferenceException on their null
 * branches (`E8 26 F2 ED FF` at the tail of 0x6F32C0). A managed throw
 * unwinding out of a raw native call, 128 times a frame, is not something we
 * survive. So every pointer the callee will dereference is validated HERE
 * first, and the call only happens once the throw branches are proven
 * unreachable. The pre-walk is not redundant with the callee's checks; it is
 * what makes the callee's checks never fire.
 * =================================================================== */
#define SP_GETPOS_RVA  0x6F32C0
#define SP_PL_BONES    0xB40
#define SP_PB_BODYXF   0x178
#define SP_BT_ORIGINAL 0x10
#define SP_BT_USEIMIT  0xA8
#define SP_BT_ACCUM    0xA9

/* Exit codes ABOVE the MM_POS_* range, so the six-way classification the
 * diagnostic already reports survives intact and these are additive. A future
 * wrong offset that lands on a mapped, zeroed page STILL comes back as
 * MM_POS_ALLZERO -- "readable page, all zeros" -- which is the report that
 * made this bug findable at all. */
#define SP_POS_NILBONES 10
#define SP_POS_NILXFORM 11
#define SP_POS_IMITATED 12
#define SP_POS_NOCALL   13

static const unsigned char sp_getpos_prologue[16] = {
  0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,
  0x82,0x40,0x0B,0x00,0x00,0x48,0x8B,0xD9
};
static void*   sp_getpos_fn    = 0;
static int32_t sp_getpos_state = 0;   /* 0 untried, 1 armed, -1 refused */

/* Arm ONCE. `base` is GameAssembly.dll's module handle, obtained on the Nim
 * side through the OS loader (GetModuleHandleA), which cannot fault and is
 * not an il2cpp by-name lookup. Refusal is sticky: a build whose prologue
 * does not match never gets a second chance, and never calls. */
static int32_t sp_getpos_arm(void* base) {
  unsigned char* fn;
  if (sp_getpos_state != 0) return sp_getpos_state;
  if (!base) { sp_getpos_state = -1; return -1; }
  fn = (unsigned char*)base + SP_GETPOS_RVA;
  if (!aowl_is_readable(fn, 16))                        { sp_getpos_state = -1; return -1; }
  if (memcmp(fn, sp_getpos_prologue, 16) != 0)          { sp_getpos_state = -1; return -1; }
  sp_getpos_fn = (void*)fn;
  sp_getpos_state = 1;
  return 1;
}
static int32_t sp_getpos_armed(void) { return sp_getpos_state; }

static int32_t sp_rd_u8(void* o, int32_t off, unsigned char* out) {
  unsigned char* a = (unsigned char*)o + off;
  *out = 0;
  if (!aowl_is_readable(a, 1)) return 0;
  *out = *a;
  return 1;
}

/* Vector3 (12 bytes) is bigger than 8, so Win64 returns it through a HIDDEN
 * BUFFER: (retbuf in RCX, this in RDX, MethodInfo* in R8). That shape is not
 * inferred from the name -- it is read off `48 8B D9` (mov rbx,rcx) at entry
 * and `F2 0F 11 03 / 89 43 08 / 48 8B C3` (store 12 bytes to [rbx], return
 * rbx) at exit. MethodInfo* NULL is safe: get_Position is not generic. */
static int32_t sp_pos_live(void* player, float* out3) {
  void* bones; void* bt; void* orig;
  unsigned char flag = 0;
  float tmp[3];
  out3[0] = 0.0f; out3[1] = 0.0f; out3[2] = 0.0f;
  if (sp_getpos_state != 1) return SP_POS_NOCALL;
  if (!player)              return SP_POS_NILBONES;
  bones = sp_rd_ptr(player, SP_PL_BONES);
  if (!bones)               return SP_POS_NILBONES;
  bt = sp_rd_ptr(bones, SP_PB_BODYXF);
  if (!bt)                  return SP_POS_NILXFORM;
  /* Both imitation flags must be clear, or get_position takes a delegate path
   * we have NOT proven throw-free. Declining is an ANSWER, not a silence. */
  if (!sp_rd_u8(bt, SP_BT_ACCUM, &flag)   || flag) return SP_POS_IMITATED;
  if (!sp_rd_u8(bt, SP_BT_USEIMIT, &flag) || flag) return SP_POS_IMITATED;
  orig = sp_rd_ptr(bt, SP_BT_ORIGINAL);
  if (!orig)                return SP_POS_NILXFORM;
  tmp[0] = 0.0f; tmp[1] = 0.0f; tmp[2] = 0.0f;
  ((void* (*)(void*, void*, void*))sp_getpos_fn)((void*)tmp, player, (void*)0);
  out3[0] = tmp[0]; out3[1] = tmp[1]; out3[2] = tmp[2];
  /* readable=1: the buffer is OUR stack, so readability is not in question
   * here -- it was answered by the guarded walk above. The plausibility gates
   * (NaN / out-of-range / exactly-zero) still apply unchanged. */
  return (int32_t)mm_pos_classify(1, tmp[0], tmp[1], tmp[2]);
}

/* ===================================================================
 * THE LIVE HEADING *IS* A MANAGED FIELD -- unlike the position.
 * ===================================================================
 *
 * `EFT.Player::get_LookDirection` RVA 0x6F8060, in its own bytes:
 *
 *     48 83 EC 28                sub rsp,0x28
 *     48 8B 42 60                mov rax,[rdx+0x60]      Player.MovementContext
 *     48 85 C0 74 1D             null -> throw
 *     F2 0F 10 80 D0 03 00 00    movsd xmm0,[rax+0x3D0]  _lookDirection .x,.y
 *     8B 80 D8 03 00 00          mov  eax,[rax+0x3D8]    _lookDirection .z
 *     F2 0F 11 01                movsd [rcx],xmm0        (sret buffer)
 *     89 41 08                   mov  [rcx+8],eax
 *     48 8B C1 48 83 C4 28 C3    mov rax,rcx; ret
 *
 *   metadata: EFT.Player.<MovementContext>k__BackingField @0x60
 *   metadata: EFT.MovementContext._lookDirection @0x3D0  (Vector3)
 *
 * Both corroborate the accessor field-for-field. THE WHOLE BODY IS A FIELD
 * READ -- there is no icall, no delegate, no property chain. That is the
 * difference from the position, which bottoms out in
 * `Transform::get_position_Injected` and therefore HAS no managed home.
 *
 * So the heading needs NO CALL AT ALL. A guarded two-hop walk and a 12-byte
 * read is strictly less machinery than a direct RVA call, and less machinery
 * is less blast radius: nothing to byte-verify at runtime, no throw branch to
 * prove unreachable, no ABI shape to get wrong. The RVA above is quoted as
 * PROVENANCE for the two offsets, not as something this code jumps to.
 *
 * WHAT THIS MUST NOT DO is assume the field is live. `PreviousPosition` @0x370
 * is also correctly named by metadata and is permanently (0,0,0). So the read
 * is classified by `mm_heading_from_look`, which answers ALLZERO separately
 * from UNREADABLE and from OK, and world.nim publishes hasHeading:false for
 * anything that is not OK. A dead field must name itself here, not silently
 * become a yaw of zero that looks exactly like "facing north".
 * =================================================================== */
#define SP_MC_LOOKDIR 0x3D0

static int32_t sp_look_dir(void* player, int32_t mcOff, float* yaw) {
  void* mc;
  float v[3];
  int32_t readable;
  *yaw = 0.0f;
  if (!player) return MM_HDG_UNREADABLE;
  mc = sp_rd_ptr(player, mcOff);
  if (!mc) return MM_HDG_UNREADABLE;
  v[0] = 0.0f; v[1] = 0.0f; v[2] = 0.0f;
  readable = sp_rd_vec3(mc, SP_MC_LOOKDIR, v);
  return (int32_t)mm_heading_from_look(readable, v[0], v[1], v[2], yaw);
}

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

/* A System.String's HEAD, narrowed to ASCII, into `out` (>= cap bytes). Used
 * for EFT.GameWorld.LocationId -- the raid's map key ("Woods", "bigmap",
 * "factory4_day") -- which is a short identifier, not a MongoID tail, so the
 * head is what matters and the whole thing must fit. Every read is
 * VirtualQuery-guarded, the length is bounds-checked, and iteration is capped
 * at `cap-1` whatever the length field claims. A wrong offset yields visible
 * junk or an empty string, never a smuggled pointer. */
static int32_t sp_rd_str(void* s, int32_t lenOff, int32_t chOff,
                         char* out, int32_t cap) {
  int32_t n, take, i;
  if (!out || cap <= 0) return 0;
  out[0] = 0;
  if (!s) return 0;
  if (!aowl_is_readable((unsigned char*)s + lenOff, 4)) return 0;
  memcpy(&n, (unsigned char*)s + lenOff, 4);
  if (n <= 0 || n > 4096) return 0;
  take = n > (cap - 1) ? (cap - 1) : n;
  for (i = 0; i < take; i++) {
    unsigned short c = 0;
    unsigned char* a = (unsigned char*)s + chOff + i * 2;
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
  # Above the MM_POS_* range; see the C block for why these are additive.
  SpPosNilBones*   = 10
  SpPosNilXform*   = 11
  SpPosImitated*   = 12
  SpPosNoCall*     = 13
proc cRdIdTail(s: pointer; lenOff, chOff: int32; outBuf: cstring): int32 {.
  importc: "sp_rd_idtail", nodecl.}
proc cRdStr(s: pointer; lenOff, chOff: int32; outBuf: cstring; cap: int32): int32 {.
  importc: "sp_rd_str", nodecl.}
proc cGetPosArm(base: pointer): int32 {.importc: "sp_getpos_arm", nodecl.}
proc cGetPosArmed(): int32 {.importc: "sp_getpos_armed", nodecl.}
proc cPosLive(player: pointer; out3: ptr cfloat): int32 {.
  importc: "sp_pos_live", nodecl.}
proc cLookDir(player: pointer; mcOff: int32; yaw: ptr cfloat): int32 {.
  importc: "sp_look_dir", nodecl.}

const
  # Mirrors MM_HDG_* in sp/mapmath.h.
  MmHdgOk*         = 0
  MmHdgUnreadable* = 1
  MmHdgNan*        = 2
  MmHdgAllZero*    = 3
  MmHdgFlat*       = 4

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
  GwLocationId = 0xE8   ## EFT.GameWorld.<LocationId>k__BackingField (string).
                        ## Resolved 2026-08-28 by `python tools/fldoff.py
                        ## fields EFT.GameWorld`, corroborated in the same dump
                        ## by the three offsets above matching this file's
                        ## constants exactly. This is the raid's map KEY
                        ## ("Woods", "bigmap", "factory4_day"), used to pick the
                        ## calibrated map by name instead of by a bounds guess.
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
    key*: uint64       ## the Player pointer, as an opaque identity. NEVER
                       ## dereferenced by any consumer: it exists so a contact
                       ## can be followed across collections while the list's
                       ## ORDER changes. The profile-id tail above is the wrong
                       ## thing for that -- it is truncated to 8 chars and can
                       ## collide, and it is empty whenever the string read
                       ## declines, which would silently merge every contact
                       ## whose id could not be read into one track.

var gFn: Il2CppPtr = cast[Il2CppPtr](0)
var gArmedFn: Il2CppPtr = cast[Il2CppPtr](0)
var gPhaseFn: Il2CppPtr = cast[Il2CppPtr](0)
var gTried = false

proc resolveHost() =
  if gTried: return
  gTried = true
  var hostName = "aowlspt-host-il2cpp.dll"
  let h = wGetModuleHandleA(toCString(hostName))
  if h == nil: return
  var n1 = "aowl_host_gameworld"
  var n2 = "aowl_host_gameworld_armed"
  var n3 = "aowl_host_raid_phase"
  gFn = wGetProcAddress(h, toCString(n1))
  gArmedFn = wGetProcAddress(h, toCString(n2))
  gPhaseFn = wGetProcAddress(h, toCString(n3))
  # Arm the position accessor at the same time, and by the same OS-loader
  # route. GameAssembly.dll is already loaded in the client; GetModuleHandleA
  # does NOT load it, so this returns NULL server-side and the call is simply
  # never armed there. No il2cpp name is involved at any point.
  var gaName = "GameAssembly.dll"
  discard cGetPosArm(cast[pointer](wGetModuleHandleA(toCString(gaName))))

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

const
  # Mirrors RpPhase* in host/Aowlspt.Host.Il2Cpp/raidphase.nim. Kept as named
  # constants so a `case` over them is exhaustive.
  RpNoExport* = -1  ## the host does not export it -- host too old, or server side
  RpUnknown*  = 0   ## the host could not look. NOT "no raid".
  RpMenu*     = 1
  RpLoading*  = 2   ## world exists (bots registering) but the player is NOT in
  RpDeployed* = 3
  RpResults*  = 4   ## post-raid results screen

proc hostPhase*(): int =
  ## THE lifecycle answer, computed once per frame INSIDE the host under its own
  ## guard and merely READ here. It is not recomputed on this side: the host's
  ## guard is not re-entrant and this is called from inside the mod's own tick.
  ##
  ## `RpNoExport` is a distinct outcome from `RpUnknown` on purpose. A host that
  ## predates this export must keep the OLD behaviour rather than have every
  ## surface go dark, and a host that looked and could not tell must not be
  ## reported as "you are not in a raid".
  resolveHost()
  if gPhaseFn == nil: return RpNoExport
  result = int(spI32V(gPhaseFn))

proc hostPhaseName*(p: int): string =
  case p
  of RpNoExport: "NO-EXPORT"
  of RpMenu: "MENU"
  of RpLoading: "LOADING"
  of RpDeployed: "DEPLOYED"
  of RpResults: "RESULTS"
  else: "UNKNOWN"

proc raidOverOrNotYet*(): bool =
  ## TRUE only on a POSITIVE observation that the overlays must be dark: the
  ## post-raid results screen, the menu, or the pre-deploy loading window. It is
  ## deliberately FALSE for `RpUnknown` and `RpNoExport`, because "I could not
  ## look" must not blank a live raid -- that failure mode (blanking on an
  ## intermittent read) is the flicker bug this mod already paid for once.
  let p = hostPhase()
  p == RpResults or p == RpMenu or p == RpLoading

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
    inRaid*: bool        ## GameWorld was live (borrowed cache) -- NOT proof of
                         ## an active, spawned raid; see `localAlive`/`activeRaid`
    localAlive*: bool    ## the local player pointer was found in the LIVE
                         ## AllAlivePlayersList this collection -- i.e. spawned
                         ## and in-world. False in the menu, on the deploy screen
                         ## before spawn, and after extract/death, even while the
                         ## borrowed GameWorld cache still answers non-null.
    locationId*: string  ## GameWorld.LocationId -- the raid's map KEY, or "" when
                         ## unreadable/absent. Never dereferenced downstream.
    n*: int
    ents*: array[MaxEntities, Ent]
    localIdx*: int       ## index into ents of the local player, or -1
    hasHeading*: bool    ## the yaw below was classified OK this collection
    heading*: float      ## radians, 0 = +Z (north), increasing toward +X
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
    nilBones*, nilXform*, imitated*, noCall*: int

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
  a.nilBones   = a.nilBones   + b.nilBones
  a.nilXform   = a.nilXform   + b.nilXform
  a.imitated   = a.imitated   + b.imitated
  a.noCall     = a.noCall     + b.noCall

proc posReasonText(r: PosReason): string =
  "good=" & $r.good & " nilPlayer=" & $r.nilPlayer & " nilMoveCtx=" & $r.nilCtx &
  " unreadable=" & $r.unreadable & " NaN=" & $r.nan &
  " outOfRange=" & $r.outOfRange & " allZero=" & $r.allZero &
  " nilBones=" & $r.nilBones & " nilBodyTransform=" & $r.nilXform &
  " imitatedTransform=" & $r.imitated & " getPosNotArmed=" & $r.noCall

proc posEverText*(): string = posReasonText(gPosEver)
proc posNowText*(): string = posReasonText(gPosNow)
proc posEverGood*(): int = gPosEver.good
proc posEverTried*(): int =
  gPosEver.good + gPosEver.nilPlayer + gPosEver.nilCtx + gPosEver.unreadable +
  gPosEver.nan + gPosEver.outOfRange + gPosEver.allZero + gPosEver.nilBones +
  gPosEver.nilXform + gPosEver.imitated + gPosEver.noCall

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
  if gPosEver.noCall > 0:
    return "EVERY position read was DECLINED for all " & $gPosEver.noCall &
           " players because EFT.Player::get_Position @0x6F32C0 is NOT ARMED " &
           "-- either GameAssembly.dll was not in this process, or its first " &
           "16 bytes did not match the recorded prologue " &
           "(40 53 48 83 EC 30 48 8B 82 40 0B 00 00 48 8B D9). A Tarkov " &
           "update moves that RVA; re-derive it, do not widen the check"
  if gPosEver.nilBones > 0:
    return "EVERY position read failed and " & $gPosEver.nilBones &
           " had a NULL Player+0xB40 <PlayerBones>k__BackingField -- the " &
           "player object is real but its bones are not built yet, or " &
           "Player+0xB40 is wrong on this build. A POINTER problem"
  if gPosEver.nilXform > 0:
    return "EVERY position read failed and " & $gPosEver.nilXform &
           " had a NULL PlayerBones+0x178 BodyTransform (or a NULL " &
           "BifacialTransform+0x10 Original). The call was correctly NOT " &
           "made -- get_Position throws on exactly this branch"
  if gPosEver.imitated > 0:
    return "EVERY position read was DECLINED for all " & $gPosEver.imitated &
           " players because BifacialTransform+0xA8 _useImitation or +0xA9 " &
           "_accumulatePositionAndRotation was SET, so get_position would " &
           "take a delegate path this code has not proven throw-free. This " &
           "is a deliberate refusal, not a failure to read"
  if gPosEver.unreadable > 0:
    return "EVERY position read failed and " & $gPosEver.unreadable &
           " were UNREADABLE -- a VirtualQuery refusal partway down " &
           "Player+0xB40 -> PlayerBones+0x178 -> BifacialTransform. This is " &
           "a POINTER problem, not an offset-value problem"
  if gPosEver.allZero > 0:
    return "EVERY position read failed and " & $gPosEver.allZero &
           " came back exactly (0,0,0) from a READABLE page -- " &
           "EFT.Player::get_Position @0x6F32C0 returned the origin for every " &
           "player, so the object we passed is not a live Player, or the " &
           "walk reached a BifacialTransform that is not the body. THIS IS " &
           "THE EXACT SHAPE THE OLD MovementContext+0x370 BUG PRODUCED -- " &
           "treat it as 'the source of the pose is wrong', not as a fault"
  if gPosEver.nan > 0 or gPosEver.outOfRange > 0:
    return "EVERY position read failed plausibility (NaN=" & $gPosEver.nan &
           " outOfRange=" & $gPosEver.outOfRange & ") -- get_Position " &
           "returned non-position bytes, which means Player+0xB40 or " &
           "PlayerBones+0x178 is pointing at the wrong thing on this build"
  if gPosEver.nilCtx > 0:
    return "EVERY position read failed because Player+0x60 " &
           "<MovementContext>k__BackingField was NULL for all " &
           $gPosEver.nilCtx & " players"
  "EVERY position read failed and no reason was recorded -- this is a BUG in " &
  "posOf's own accounting, not a measurement"

# ---------------------------------------------------------------------------
# WHY A HEADING READ FAILED -- and, harder, whether it is actually MOVING.
# ---------------------------------------------------------------------------
#
# Defect 1 as the user reported it: "the player rotation does not rotate
# either map." The position bug immediately before it was found by counters
# that could say `allZero`, so the heading gets the same treatment.
#
# But a heading has a failure mode a position does not: it can be READ
# SUCCESSFULLY, pass every plausibility gate, and be a CONSTANT. That draws a
# smooth heading-up map that never turns -- exactly the symptom -- while every
# counter here reads healthy. `good > 0` therefore CANNOT be the pass
# condition. `changed` is: the number of collections on which the yaw differed
# from the previous one by more than a mouse-jitter threshold. A player who has
# turned at all makes it non-zero; a dead constant leaves it at zero forever,
# and the diagnostic reports that as FAIL rather than as PASS.
type
  HdgReason* = object
    good*, unreadable*, nan*, allZero*, flat*, nilPlayer*: int
    changed*: int          ## collections on which the yaw actually MOVED
    spread*: float         ## the largest |delta| ever seen between collections

var gHdg: HdgReason
var gHdgLast = 0.0
var gHdgHave = false

const HdgMoved = 1.0e-3
  ## radians. Below this is float noise on a stationary player, not a turn.
  ## 1e-3 rad is about 0.057 degrees -- far below any real mouse movement and
  ## far above the jitter of a value that is genuinely not changing.

proc yawDelta(a, b: float): float =
  ## The signed shortest difference, wrapped into (-pi, pi]. Mirrors
  ## `mm_yaw_delta` in sp/mapmath.h, which the offline test pins; a player who
  ## turns THROUGH north must not register as a 6.28 rad jump, and one who
  ## stands still must not register as anything.
  const Tau = 6.283185307179586
  const Pi2 = 3.141592653589793
  result = a - b
  while result > Pi2: result = result - Tau
  while result <= -Pi2: result = result + Tau

proc hdgEverTried*(): int =
  gHdg.good + gHdg.unreadable + gHdg.nan + gHdg.allZero + gHdg.flat +
  gHdg.nilPlayer

proc hdgEverText*(): string =
  "good=" & $gHdg.good & " changed=" & $gHdg.changed &
  " unreadable=" & $gHdg.unreadable & " NaN=" & $gHdg.nan &
  " allZero=" & $gHdg.allZero & " lookingStraightUpDown=" & $gHdg.flat &
  " nilPlayer=" & $gHdg.nilPlayer

proc hdgVerdict*(): string =
  ## Three outcomes, never two (CLAUDE.md 9b). "I read a heading" is NOT
  ## "the map rotates" -- that was the whole shape of this defect.
  let tried = hdgEverTried()
  if tried == 0:
    return "INCONCLUSIVE  no heading has been read yet (no raid, or the feed " &
           "has not run). This is not 'the heading is broken'"
  if gHdg.good == 0:
    if gHdg.allZero > 0:
      return "FAIL  every one of " & $gHdg.allZero & " reads of " &
             "MovementContext+0x3D0 _lookDirection came back EXACTLY (0,0,0) " &
             "from a READABLE page. That is the PreviousPosition@0x370 failure " &
             "again: the offset is right and the field is dead on this build. " &
             "Both surfaces stay north-up rather than rotate by a fake zero"
    if gHdg.unreadable > 0:
      return "FAIL  every read failed readability -- Player+0x60 " &
             "<MovementContext>k__BackingField was null, or " &
             "MovementContext+0x3D0 is not a mapped page. A POINTER problem, " &
             "not a zero heading"
    if gHdg.nan > 0:
      return "FAIL  _lookDirection read NaN on all " & $gHdg.nan & " attempts"
    if gHdg.flat > 0:
      return "INCONCLUSIVE  every read found the look vector within " &
             "1e-4 of vertical (straight up or straight down), which carries " &
             "no bearing. Refused rather than rotated by atan2(0,0)"
    return "FAIL  " & hdgEverText()
  if gHdg.changed == 0:
    return "FAIL  the heading READS fine (" & $gHdg.good & " of " & $tried &
           ") but has NEVER CHANGED -- the largest yaw delta between any two " &
           "collections is " & $gHdg.spread & " rad, below the " &
           "1e-3 turn threshold. A constant heading draws a map that never " &
           "rotates, which is exactly the reported defect, and it is NOT a " &
           "pass just because the value is non-zero"
  return "PASS  the heading is live AND MOVING (" & $gHdg.good & " of " &
         $tried & " read, " & $gHdg.changed & " turns seen, largest delta " &
         $gHdg.spread & " rad)"

proc headingOf(p: pointer; ok: var bool; yaw: var float) =
  ## The live VIEW heading, from `MovementContext._lookDirection` @0x3D0.
  ##
  ## BODY YAW vs CAMERA YAW -- a decision, not an accident. This reads the LOOK
  ## direction, so both surfaces are view-relative. Two reasons, both about
  ## what the player experiences rather than about what is easiest to read:
  ##
  ##  * a minimap the player reads WHILE AIMING has to agree with the screen.
  ##    Up on the radar must be the middle of the monitor. Body yaw and view
  ##    yaw differ by the whole lean/turn-in-place range in Tarkov, so a
  ##    body-yaw radar is visibly wrong exactly when it is being used.
  ##  * the directional indicators are, by definition, camera-relative -- they
  ##    clamp a projected screen point to the screen edge. Driving the radar
  ##    off a different rotation than the indicators would put a contact on the
  ##    left of the radar and the right of the screen, simultaneously, and both
  ##    would look right in isolation.
  ##
  ## The map PANE takes the same rotation, because it is the same
  ## player-centred top-down view at a different scale; hud.nim reads `rot`
  ## from one place precisely so the two can never disagree.
  ##
  ## No call is made. See the C block for the accessor bytes that establish
  ## both offsets, and for why a field read is the smaller instrument here.
  ok = false
  yaw = 0.0
  if p == nil:
    gHdg.nilPlayer = gHdg.nilPlayer + 1
    return
  var v: cfloat = 0.0'f32
  let code = cLookDir(p, int32(PlMoveCtx), addr v)
  case int(code)
  of MmHdgUnreadable:
    gHdg.unreadable = gHdg.unreadable + 1
    note("Player+0x60 <MovementContext>k__BackingField or " &
         "MovementContext+0x3D0 _lookDirection was NOT READABLE -- a " &
         "VirtualQuery refusal, not a heading of zero")
    return
  of MmHdgNan:
    gHdg.nan = gHdg.nan + 1
    note("MovementContext+0x3D0 _lookDirection read NaN")
    return
  of MmHdgAllZero:
    gHdg.allZero = gHdg.allZero + 1
    note("MovementContext+0x3D0 _lookDirection read EXACTLY (0,0,0) from a " &
         "readable page -- the field is declared and dead on this build, " &
         "exactly like PreviousPosition@0x370. Reported rather than drawn")
    return
  of MmHdgFlat:
    gHdg.flat = gHdg.flat + 1
    # NOT a fault and NOT a defect: looking straight down is a thing players
    # do. It simply carries no bearing, so this frame keeps the last heading
    # by publishing none, and the surfaces hold their previous rotation.
    return
  else:
    yaw = float(v)
    gHdg.good = gHdg.good + 1
    if gHdgHave:
      let d = yawDelta(yaw, gHdgLast)
      let m = if d < 0.0: -d else: d
      if m > gHdg.spread: gHdg.spread = m
      if m > HdgMoved: gHdg.changed = gHdg.changed + 1
    gHdgLast = yaw
    gHdgHave = true
    ok = true

proc posOf(p: pointer; ok: var bool; x, y, z: var float) =
  ## The live world pose, via `EFT.Player::get_Position` @0x6F32C0.
  ##
  ## WHAT CHANGED AND WHY. This used to read Player+0x60 -> MovementContext
  ## +0x370 `PreviousPosition`. That offset is CORRECT -- metadata names the
  ## field at exactly 0x370 -- and it is also permanently ZERO: measured live
  ## in a raid on 2026-08-28, 66331 readable reads, every one (0,0,0). The
  ## field is declared and never written on this build. No other offset holds
  ## the pose either: the client's own accessor bottoms out in the Unity
  ## native ICall `Transform::get_position_Injected`, so there IS no managed
  ## field to point at. The C block above shows the instruction bytes that
  ## establish that, hop by hop, each corroborated against metadata.
  ##
  ## So this now walks Player+0xB40 (PlayerBones) -> +0x178 (BodyTransform)
  ## -> BifacialTransform, validating and null-checking every hop precisely so
  ## the callee's throw branches are unreachable, then makes ONE direct call
  ## at a byte-verified static RVA. No name is resolved; no detour is bound.
  ##
  ## Every exit is still counted and named. `allZero` in particular is kept as
  ## a first-class outcome rather than folded into a generic failure -- it is
  ## the report that found this bug, and it must still be able to find the
  ## next one.
  ok = false
  x = 0.0; y = 0.0; z = 0.0
  if p == nil:
    gPosNow.nilPlayer = gPosNow.nilPlayer + 1
    return
  # Explicitly zeroed: nimony cannot prove an array written only through a
  # `ptr` passed to C is initialised, and it is right to refuse -- if the C
  # side ever returned without writing, these would be whatever was on the
  # stack, which is the "plausible wrong number" failure this file exists to
  # avoid. `sp_pos_live` zeroes them too; agreeing costs nothing.
  var v: array[3, cfloat] = [0.0'f32, 0.0'f32, 0.0'f32]
  let code = cPosLive(p, addr v[0])
  x = float(v[0]); y = float(v[1]); z = float(v[2])
  case int(code)
  of SpPosNoCall:
    gPosNow.noCall = gPosNow.noCall + 1
    note("EFT.Player::get_Position @0x6F32C0 is NOT ARMED -- GameAssembly.dll " &
         "absent, or its prologue did not byte-verify. No call was made")
    x = 0.0; y = 0.0; z = 0.0
    return
  of SpPosNilBones:
    gPosNow.nilBones = gPosNow.nilBones + 1
    note("Player+0xB40 <PlayerBones>k__BackingField read null")
    x = 0.0; y = 0.0; z = 0.0
    return
  of SpPosNilXform:
    gPosNow.nilXform = gPosNow.nilXform + 1
    note("PlayerBones+0x178 BodyTransform (or BifacialTransform+0x10 " &
         "Original) read null -- get_Position would have THROWN here, so it " &
         "was deliberately not called")
    x = 0.0; y = 0.0; z = 0.0
    return
  of SpPosImitated:
    gPosNow.imitated = gPosNow.imitated + 1
    note("BifacialTransform+0xA8 _useImitation / +0xA9 " &
         "_accumulatePositionAndRotation is SET -- declined rather than take " &
         "an unproven delegate path")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosUnreadable:
    gPosNow.unreadable = gPosNow.unreadable + 1
    note("a hop on Player+0xB40 -> PlayerBones+0x178 was NOT READABLE -- a " &
         "VirtualQuery refusal, not a zero position")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosNan:
    gPosNow.nan = gPosNow.nan + 1
    note("get_Position @0x6F32C0 returned NaN")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosRange:
    gPosNow.outOfRange = gPosNow.outOfRange + 1
    note("get_Position @0x6F32C0 returned out of range (|component| > 1e6)")
    x = 0.0; y = 0.0; z = 0.0
    return
  of MmPosAllZero:
    gPosNow.allZero = gPosNow.allZero + 1
    note("get_Position @0x6F32C0 returned exactly (0,0,0) from a READABLE " &
         "page -- the walk succeeded but the pose source is wrong")
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
  snap.localAlive = false
  snap.locationId = ""
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

  # The raid's map key, read from the live world. Guarded, capped, narrowed to
  # ASCII. A stale borrowed cache may still answer here, so this is used to
  # SELECT the map (bug: Woods was drawing Lighthouse art via a bounds guess),
  # NOT as the active-raid gate -- that is `localAlive` below.
  block:
    let loc = rdPtr(world, GwLocationId)
    if loc != nil:
      var lbuf = "                                "   # 32 bytes
      let ln = cRdStr(loc, int32(StrLenOff), int32(StrCharOff),
                      toCString(lbuf), int32(lbuf.len))
      if ln > 0:
        var s = ""
        var k = 0
        while k < int(ln) and k < lbuf.len:
          s.add lbuf[k]
          inc k
        snap.locationId = s

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

  # The heading, from the SAME already-validated local player pointer. It is
  # read whether or not the position read succeeded, because the two failures
  # are independent and folding them together would hide one behind the other.
  if me != nil:
    var hok = false
    var hyaw = 0.0
    headingOf(me, hok, hyaw)
    snap.hasHeading = hok
    snap.heading = hyaw

  if lok:
    snap.ents[0] = Ent(x: lx, y: ly, z: lz, bot: false, me: true,
                       id: idTailOf(me), key: localPtr)
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
    if cast[uint64](p) == localPtr:
      # The local player is present in the LIVE alive-players list: this is the
      # game's own "spawned and in-world" set, and its membership is the
      # active-raid signal (bug 1). Already emitted as ents[0], so just record it.
      if localPtr != 0'u64: snap.localAlive = true
      continue
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
                            id: idTailOf(p), key: cast[uint64](p))
    inc snap.n
    snap.ok = true

proc collect*(snap: var Snapshot) =
  ## Wrapper over `collectInner` whose ONLY job is that the reason tally is
  ## accumulated on EVERY exit path -- `collectInner` has six `return`s, and a
  ## tally that is only summed on the success path is exactly the check that
  ## cannot fail (CLAUDE.md 9b).
  collectInner(snap)
  posAdd(gPosEver, gPosNow)

proc activeRaid*(snap: Snapshot): bool =
  ## THE lifecycle gate (bug 1). Three signals must ALL hold, and each can
  ## independently be false, so this is not a check that cannot fail:
  ##   * state == 3      -- the host has a live GameWorld (not menu state 2)
  ##   * ok              -- a real local pose validated this collection
  ##   * localAlive      -- the local player is in the LIVE alive-players list,
  ##                        i.e. spawned and in-world THIS frame
  ## The borrowed RegisterPlayer cache can make the first two true in the menu,
  ## during loading before spawn, and after extract (fact #141). `localAlive` is
  ## the one that goes false the instant the player is not a spawned participant,
  ## which is exactly when the HUD must idle.
  snap.state == 3 and snap.ok and snap.localAlive

proc activeRaidWhy*(snap: Snapshot): string =
  ## Why the gate is closed, for the diag. Never "I could not look" == "no raid".
  if snap.state != 3:
    return "world not live (state " & $snap.state & "): " & gwStateText()
  if not snap.ok:
    return "world live but no local pose validated this collection -- see positions"
  if not snap.localAlive:
    return "world live and a pose read, but the local player is NOT in the live " &
           "AllAlivePlayersList -- menu, deploy-before-spawn, or post-extract, " &
           "not an active raid"
  "active raid"
