/* aowlspt_botnav.h -- NATIVE BOT NAVIGATION API for the post-1.0 EFT host.
 *
 * A live bot registry plus ONE proven movement command, built on the same
 * reflection-free discipline as `aowlspt_botai.h` / `aowlspt_botcap.h`:
 * static-RVA target, 16-byte prologue byte-verify, VirtualQuery-guarded raw
 * hops, whole body under the single VEH/SEH guard, flag-gated, fail-safe.
 * No runtime_invoke, no reflection, no il2cpp_class_* -- all DEAD on this build.
 *
 * The full recon that produced every number here, with disassembly, is in
 * `docs/BOTNAV.md`.
 *
 * ============================================================================
 * 1. THE TICK / REGISTRY POINT:  EFT.BotOwner::UpdateManual @ RVA 0x81B7C0
 * ============================================================================
 *
 *   BotsList::UpdateByUnity 0x1BD6510 -> EFT.BotOwner::UpdateManual 0x81B7C0
 *   is the ONLY caller (E8 @0x1BD6656). It runs once per live bot per frame, on
 *   the Unity main thread, only inside a raid, with RCX = the BotOwner.
 *
 *   That makes it the ideal single hook for this feature: it is simultaneously
 *   the census (every live bot announces itself every frame, no enumeration and
 *   no GameWorld walk needed) and the service tick (each bot's own pending nav
 *   command is issued while its own UpdateManual runs). It is also, as of kind
 *   14, hooked by NOTHING else -- so there is zero hook contention. Anything
 *   that later wants UpdateManual must ride kind 14, not re-detour it.
 *
 *   Prologue (byte-verified, 16 bytes of whole instructions; the engine needs
 *   14 for its `jmp [rip+0]`):
 *     40 53                push rbx                 (2)
 *     48 81 EC A0 00 00 00 sub  rsp, 0xA0           (7)
 *     80 3D 08 CF 89 06 00 cmp  byte [rip+..], 0    (7; disp32 pins the build)
 *   On any other build the bytes differ, the verify fails, NULL comes back, and
 *   we simply do not bind. A missed feature, never a corrupted game.
 *
 * ============================================================================
 * 2. THE MOVEMENT COMMAND:  EFT.BotOwner::GoToPoint @ RVA 0x81CB40
 * ============================================================================
 *
 *   NavMeshPathStatus GoToPoint(Vector3 position, bool slowAtTheEnd,
 *                               float reachDist, bool getUpWithCheck,
 *                               bool mustHaveWay, bool mustGetUp,
 *                               bool onlyShortTrie, bool force)
 *
 *   The whole function is a thin forwarder to BotMover::GoToPoint (0x1A2EE00),
 *   and disassembling it settles every ABI question outright:
 *
 *     18081CB40  sub  rsp, 0x68
 *     18081CB44  xorps xmm0, xmm0
 *     18081CB47  comiss xmm0, xmm3        ; 0 vs reachDist  ->  reachDist IS XMM3
 *     18081CB4A  jbe  18081CB6C           ; reachDist >= 0 SKIPS the Settings chain
 *     18081CB4C  mov  rax, [rcx + 0x68]   ; this->Settings   (only if reachDist < 0)
 *     18081CB55  mov  rax, [rax + 0x68]
 *     18081CB5E  mov  rax, [rax + 0x30]
 *     18081CB67  movss xmm3, [rax + 0x14] ; the default reach distance
 *     18081CB6C  mov  rcx, [rcx + 0x3d0]  ; this->Mover
 *     18081CB73  test rcx, rcx / je throw
 *     18081CB78  mov  eax, [rdx + 8]      ; pos.z   <-- Vector3 arrives BY POINTER
 *     18081CB7B  movsd xmm0, [rdx]        ; pos.x, pos.y      in RDX
 *     18081CB7F  lea  rdx, [rsp + 0x50]
 *     18081CB90  mov  qword [rsp+0x40], 0 ; <== MethodInfo* = NULL, by the GAME
 *     18081CBB5  mov  byte  [rsp+0x20], 1 ; getUpWithCheck := true (hardcoded)
 *     18081CBC0  call 181A2EE00           ; BotMover::GoToPoint
 *     18081CBC9  ret
 *     18081CBCA  call 1805D2530 / int3    ; managed NullReference throw helper
 *
 *   What that proves, and why we can call it safely:
 *
 *   (a) `Vector3` is 12 bytes, so Win64 passes it BY POINTER -- RDX is a
 *       `Vector3*` to a copy the CALLER owns. We pass a pointer to our own
 *       stack, so that operand can never be a bad game pointer.
 *   (b) `float` args land in the XMM register of their positional slot;
 *       `reachDist` is arg index 3, hence XMM3. Independently corroborated by
 *       `BotMover::SetTargetMoveSpeed` @0x1A2B4D0, whose entire body is
 *       `F3 0F 11 89 5C 01 00 00 C3` = `movss [rcx+0x15C], xmm1; ret` -- arg
 *       index 1 in XMM1, `this` in RCX. That two-instruction function is pure,
 *       unambiguous ABI ground truth.
 *   (c) `MethodInfo* = NULL` is CORRECT for this call chain -- the game itself
 *       stores a literal 0 into that stack slot before calling BotMover.
 *   (d) Passing `reachDist >= 0` skips the `Settings` pointer chain ENTIRELY, so
 *       with reachDist = 1.0f the ONLY game pointer this function dereferences
 *       before forwarding is `[this + 0x3D0]`. A one-hop attack surface.
 *
 *   Return is `NavMeshPathStatus`: 0 = Complete, 1 = Partial, 2 = Invalid.
 *   That gives us path validation for free -- we never need NavMesh.CalculatePath
 *   or NavMesh.SamplePosition interop to know whether a point was reachable.
 *
 *   ## Pre-flighting the callee, because every bail is a MANAGED THROW
 *
 *   `BotMover::GoToPoint` @0x1A2EE00 dereferences, in order:
 *       [mover + 0x80]  _moverStateMachine          -> null: throw
 *       [msm   + 0x20]  _states (Dictionary)        -> null: throw
 *       Dictionary::get_Item(_states, EBotMoverState 1) -> null: throw
 *       [state + 0x20]                              -> null: throw
 *   and every one of those bails to `call 0x1805D2530; int3`, the managed
 *   NullReferenceException throw helper. An IL2CPP managed throw unwinding out
 *   through our native frame is precisely what must not happen, so
 *   `aowl_botnav_can_command()` walks and VirtualQuery-checks that entire chain
 *   BEFORE the call is made. The dictionary lookup alone cannot be proven
 *   statically, so the Nim side additionally requires the bot to have been
 *   observed already MOVING at least once (its position changed between ticks),
 *   which empirically proves the mover state machine is populated. Make the
 *   client tell you.
 *
 * ============================================================================
 * 3. FIELD OFFSETS (all resolved via Il2CppMetadataRegistration.fieldOffsets,
 *    never guessed; see docs/BOTNAV.md for the cross-checks)
 * ============================================================================
 *
 *   EFT.BotOwner:  _botState +0x30, Settings +0x68, Mover +0x3D0,
 *                  ProfileId +0x400, Id +0x408, GetPlayer +0x418, IsDead +0x431
 *   BotSettings:   _difficulty +0x10, _role (WildSpawnType,int32) +0x14
 *   BotMover:      _moverStateMachine +0x80, <IsMoving> +0x138,
 *                  <SDistDestination> +0x148, <MoveSpeed> +0x15C
 *   BotMoverStateMachine: _states +0x20
 *   EFT.Player:    MovementContext +0x60
 *   MovementContext: PreviousPosition (Vector3) +0x370
 *
 *   NOTE on Player -> BotOwner: we deliberately do NOT use it. `Player.AIData`
 *   (+0xA00) is typed `IAIData` and has two implementations with DIFFERENT
 *   layouts (`AIData._botOwner` @+0x28 vs `StubAIData.BotOwner` @+0x30), and
 *   reflection cannot tell them apart. UpdateManual hands us the BotOwner
 *   directly in RCX, so the ambiguity never arises. Where the reverse hop is
 *   unavoidable, the round-trip test `[cand + 0x418] == player` disambiguates it
 *   without reflection.
 */

#ifndef AOWLSPT_BOTNAV_H
#define AOWLSPT_BOTNAV_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- field offsets: single source of truth ---- */
#define AOWL_BN_BOTSTATE_OFF   0x30    /* EFT.BotOwner._botState        int32   */
#define AOWL_BN_SETTINGS_OFF   0x68    /* EFT.BotOwner.Settings         ptr     */
#define AOWL_BN_MOVER_OFF      0x3D0   /* EFT.BotOwner.Mover            ptr     */
#define AOWL_BN_PROFILEID_OFF  0x400   /* EFT.BotOwner.ProfileId        string  */
#define AOWL_BN_ID_OFF         0x408   /* EFT.BotOwner.Id               int32   */
#define AOWL_BN_PLAYER_OFF     0x418   /* EFT.BotOwner.GetPlayer        ptr     */
#define AOWL_BN_ISDEAD_OFF     0x431   /* EFT.BotOwner.IsDead           bool    */

#define AOWL_BN_SET_DIFF_OFF   0x10    /* BotSettings._difficulty       int32   */
#define AOWL_BN_SET_ROLE_OFF   0x14    /* BotSettings._role             int32   */

#define AOWL_BN_MV_MSM_OFF     0x80    /* BotMover._moverStateMachine   ptr     */
#define AOWL_BN_MV_MOVING_OFF  0x138   /* BotMover.IsMoving             bool    */
#define AOWL_BN_MV_SDIST_OFF   0x148   /* BotMover.SDistDestination     float   */
#define AOWL_BN_MV_SPEED_OFF   0x15C   /* BotMover.MoveSpeed            float   */

#define AOWL_BN_MSM_STATES_OFF 0x20    /* BotMoverStateMachine._states  ptr     */

#define AOWL_BN_PL_MOVECTX_OFF 0x60    /* EFT.Player.MovementContext    ptr     */
#define AOWL_BN_MC_PREVPOS_OFF 0x370   /* MovementContext.PreviousPosition V3   */

#define AOWL_BN_STR_LEN_OFF    0x10    /* System.String._stringLength   int32   */
#define AOWL_BN_STR_CHARS_OFF  0x14    /* System.String._firstChar      utf16   */

static int32_t aowl_bn_off_botstate(void)  { return AOWL_BN_BOTSTATE_OFF;  }
static int32_t aowl_bn_off_mover(void)     { return AOWL_BN_MOVER_OFF;     }
static int32_t aowl_bn_off_settings(void)  { return AOWL_BN_SETTINGS_OFF;  }
static int32_t aowl_bn_off_profileid(void) { return AOWL_BN_PROFILEID_OFF; }
static int32_t aowl_bn_off_id(void)        { return AOWL_BN_ID_OFF;        }
static int32_t aowl_bn_off_player(void)    { return AOWL_BN_PLAYER_OFF;    }
static int32_t aowl_bn_off_isdead(void)    { return AOWL_BN_ISDEAD_OFF;    }
static int32_t aowl_bn_off_role(void)      { return AOWL_BN_SET_ROLE_OFF;  }
static int32_t aowl_bn_off_diff(void)      { return AOWL_BN_SET_DIFF_OFF;  }
static int32_t aowl_bn_off_sdist(void)     { return AOWL_BN_MV_SDIST_OFF;  }
static int32_t aowl_bn_off_moving(void)    { return AOWL_BN_MV_MOVING_OFF; }
static int32_t aowl_bn_off_movectx(void)   { return AOWL_BN_PL_MOVECTX_OFF;}
static int32_t aowl_bn_off_prevpos(void)   { return AOWL_BN_MC_PREVPOS_OFF;}

/* ============================ hook target table ============================ */

typedef struct AowlBotNavTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[24];
    int32_t             siglen;
} AowlBotNavTarget;

static int32_t aowl_botnav_base_found = 0;
static int32_t aowl_botnav_sig_ok     = 0;

/* Refusals, kept apart so a capacity failure is never read as a build change. */
static int32_t aowl_botnav_profull  = 0;
static int32_t aowl_botnav_mismatch = 0;

static const AowlBotNavTarget aowl_botnav_targets[] = {
    /* EFT.BotOwner::UpdateManual @ 0x81B7C0 -- per bot, per frame, RCX=BotOwner */
    { "EFT.BotOwner::UpdateManual", 0x81B7C0u,
      { 0x40,0x53,
        0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,
        0x80,0x3D,0x08,0xCF,0x89,0x06,0x00 }, 16 },
};

#define AOWL_BOTNAV_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_botnav_targets) / sizeof(aowl_botnav_targets[0])))

static void* aowl_botnav_verify(uint32_t rva, const unsigned char* sig,
                                int32_t siglen) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_botnav_base_found = 1;
    p = (unsigned char*)ga + rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    /* THE SIGNATURE COMPARE IS AGAINST THE SNAPSHOT, NOT LIVE MEMORY.
     * `UpdateManual` is uncontended today, but "uncontended today" is exactly
     * the assumption that produced the PreloaderUI::Update self-reject bug: the
     * moment a second feature detours a target, whichever binds second reads a
     * trampoline and rejects a perfectly correct RVA while blaming the game
     * build. Routing through `aowl_pro_verify` (aowlspt_prologue.h) removes the
     * assumption entirely -- the compare is still an exact 16-byte match against
     * the baked-in expectation, it is just fed the bytes the function ACTUALLY
     * started with. The VirtualQuery gate above is unchanged and still runs
     * first, so a stale RVA on an uncommitted page is refused before any read.
     * The GoToPoint / StopMove / SetTargetMoveSpeed call targets go through the
     * same path for the same reason. */
    if (siglen > 0 && !aowl_pro_verify(rva, sig, siglen)) {
        /* Refusing is right either way, but WHY differs: a full snapshot
         * table is our own capacity limit, not evidence about the client. */
        if (aowl_pro_last_was_table_full()) aowl_botnav_profull++;
        else aowl_botnav_mismatch++;
        return NULL;
    }
    return (void*)p;
}

static void* aowl_botnav_target_at(int32_t i) {
    const AowlBotNavTarget* t;
    void* p;
    if (i < 0 || i >= AOWL_BOTNAV_TARGET_COUNT) return NULL;
    t = &aowl_botnav_targets[i];
    p = aowl_botnav_verify(t->rva, t->sig, t->siglen);
    if (p) aowl_botnav_sig_ok = 1;
    return p;
}

static const char* aowl_botnav_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BOTNAV_TARGET_COUNT) return "";
    return aowl_botnav_targets[i].name;
}

static int32_t aowl_botnav_target_count(void) { return AOWL_BOTNAV_TARGET_COUNT; }
static int32_t aowl_botnav_profull_count(void){ return aowl_botnav_profull; }
static int32_t aowl_botnav_mismatch_count(void){ return aowl_botnav_mismatch; }

/* ===================== guarded raw primitives (read-only) ================== */

static int32_t aowl_bn_slot_readable(void* at, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!at) return 0;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)at + (uintptr_t)n;
        if (need < (uintptr_t)at) return 0;
        if ((uintptr_t)at < start) return 0;
        if (need > end) return 0;
    }
    return 1;
}

/* A real IL2CPP object pointer: canonical user space, above the null page. */
static int32_t aowl_bn_sane(void* p) {
    uintptr_t v = (uintptr_t)p;
    return (v >= 0x10000u && v < 0x00007FFFFFFFFFFFull) ? 1 : 0;
}

static int32_t aowl_botnav_read_i32(void* p, int32_t off, int32_t* ok) {
    char* at; int32_t v = 0;
    if (ok) *ok = 0;
    if (!aowl_bn_sane(p)) return 0;
    at = (char*)p + off;
    if (!aowl_bn_slot_readable(at, 4)) return 0;
    memcpy(&v, at, 4);
    if (ok) *ok = 1;
    return v;
}

static void* aowl_botnav_read_ptr(void* p, int32_t off, int32_t* ok) {
    char* at; void* v = NULL;
    if (ok) *ok = 0;
    if (!aowl_bn_sane(p)) return NULL;
    at = (char*)p + off;
    if (!aowl_bn_slot_readable(at, sizeof(void*))) return NULL;
    memcpy(&v, at, sizeof(void*));
    if (ok) *ok = 1;
    return v;
}

static int32_t aowl_botnav_read_u8(void* p, int32_t off, int32_t* ok) {
    char* at; unsigned char v = 0;
    if (ok) *ok = 0;
    if (!aowl_bn_sane(p)) return 0;
    at = (char*)p + off;
    if (!aowl_bn_slot_readable(at, 1)) return 0;
    memcpy(&v, at, 1);
    if (ok) *ok = 1;
    return (int32_t)v;
}

/* float read, widened to double for Nim's sake (matches aowl_read_f32). */
static double aowl_botnav_read_f32(void* p, int32_t off, int32_t* ok) {
    char* at; float v = 0.0f;
    if (ok) *ok = 0;
    if (!aowl_bn_sane(p)) return 0.0;
    at = (char*)p + off;
    if (!aowl_bn_slot_readable(at, 4)) return 0.0;
    memcpy(&v, at, 4);
    if (ok) *ok = 1;
    return (double)v;
}

/* Read a Vector3 (3 floats) at p+off into out[3]. 1 on success. */
static int32_t aowl_botnav_read_v3(void* p, int32_t off, double* out) {
    char* at; float v[3];
    if (!out) return 0;
    out[0] = out[1] = out[2] = 0.0;
    if (!aowl_bn_sane(p)) return 0;
    at = (char*)p + off;
    if (!aowl_bn_slot_readable(at, 12)) return 0;
    memcpy(v, at, 12);
    out[0] = (double)v[0]; out[1] = (double)v[1]; out[2] = (double)v[2];
    return 1;
}

/* Copy up to `cap-1` UTF-16 chars of a System.String at p+off into `out` as
 * ASCII (non-ASCII -> '?'). Returns the number of chars written. */
static int32_t aowl_botnav_read_str(void* p, int32_t off, char* out, int32_t cap) {
    int32_t ok = 0, n, i;
    void* s;
    unsigned short* chars;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    s = aowl_botnav_read_ptr(p, off, &ok);
    if (!ok || !aowl_bn_sane(s)) return 0;
    n = aowl_botnav_read_i32(s, AOWL_BN_STR_LEN_OFF, &ok);
    if (!ok || n <= 0) return 0;
    if (n > cap - 1) n = cap - 1;
    chars = (unsigned short*)((char*)s + AOWL_BN_STR_CHARS_OFF);
    if (!aowl_bn_slot_readable((void*)chars, (size_t)n * 2u)) return 0;
    for (i = 0; i < n; i++) {
        unsigned short c = chars[i];
        out[i] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
    }
    out[n] = 0;
    return n;
}

/* ===================== the movement command (a DIRECT CALL) ================ */

#define AOWL_BN_GOTOPOINT_RVA 0x81CB40u
#define AOWL_BN_STOPMOVE_RVA  0x81C970u
#define AOWL_BN_SETSPEED_RVA  0x81C9C0u

static const unsigned char aowl_bn_sig_gotopoint[16] = {
    0x48,0x83,0xEC,0x68, 0x0F,0x57,0xC0, 0x0F,0x2F,0xC3,
    0x76,0x20, 0x48,0x8B,0x41,0x68 };
static const unsigned char aowl_bn_sig_stopmove[16] = {
    0x48,0x83,0xEC,0x28, 0x48,0x8B,0x81,0xD0,0x03,0x00,0x00,
    0x48,0x85,0xC0, 0x74,0x30 };
static const unsigned char aowl_bn_sig_setspeed[16] = {
    0x48,0x83,0xEC,0x28, 0x48,0x8B,0x81,0xD0,0x03,0x00,0x00,
    0x48,0x85,0xC0, 0x74,0x0D };

typedef struct AowlBnV3 { float x, y, z; } AowlBnV3;

/* The exact native shape proven by the disassembly above. */
typedef int32_t (*AowlBnGoToPointFn)(void* botOwner, AowlBnV3* pos,
                                     uint8_t slowAtTheEnd, float reachDist,
                                     uint8_t getUpWithCheck, uint8_t mustHaveWay,
                                     uint8_t mustGetUp, uint8_t onlyShortTrie,
                                     uint8_t force, void* methodInfo);
typedef void (*AowlBnStopMoveFn)(void* botOwner, void* methodInfo);
typedef void (*AowlBnSetSpeedFn)(void* botOwner, float speed, void* methodInfo);

static void* aowl_bn_gotopoint_fn(void) {
    return aowl_botnav_verify(AOWL_BN_GOTOPOINT_RVA, aowl_bn_sig_gotopoint, 16);
}
static void* aowl_bn_stopmove_fn(void) {
    return aowl_botnav_verify(AOWL_BN_STOPMOVE_RVA, aowl_bn_sig_stopmove, 16);
}
static void* aowl_bn_setspeed_fn(void) {
    return aowl_botnav_verify(AOWL_BN_SETSPEED_RVA, aowl_bn_sig_setspeed, 16);
}

/* Every pointer BotMover::GoToPoint will dereference before its first possible
 * bail, walked and VirtualQuery-checked here so the managed NullReference throw
 * helper at 0x1805D2530 can never be reached. 1 = safe to command, 0 = do not.
 *
 * Chain: BotOwner -> Mover(+0x3D0) -> _moverStateMachine(+0x80)
 *                 -> _states(+0x20).  Plus: not dead, and Mover is an object.
 * The Dictionary lookup inside GoToPoint cannot be proven statically -- the Nim
 * side covers that by requiring the bot to have been seen moving already. */
static int32_t aowl_botnav_can_command(void* botOwner) {
    int32_t ok = 0;
    void* mover; void* msm; void* states;
    int32_t dead;

    if (!aowl_bn_sane(botOwner)) return 0;

    dead = aowl_botnav_read_u8(botOwner, AOWL_BN_ISDEAD_OFF, &ok);
    if (!ok || dead) return 0;

    mover = aowl_botnav_read_ptr(botOwner, AOWL_BN_MOVER_OFF, &ok);
    if (!ok || !aowl_bn_sane(mover)) return 0;

    msm = aowl_botnav_read_ptr(mover, AOWL_BN_MV_MSM_OFF, &ok);
    if (!ok || !aowl_bn_sane(msm)) return 0;

    states = aowl_botnav_read_ptr(msm, AOWL_BN_MSM_STATES_OFF, &ok);
    if (!ok || !aowl_bn_sane(states)) return 0;

    return 1;
}

/* Issue the command. Returns the NavMeshPathStatus (0 Complete / 1 Partial /
 * 2 Invalid), or -1 if the target did not byte-verify, -2 if the pre-flight
 * refused. `reachDist` is FORCED to be >= 0 so the Settings pointer chain is
 * never walked -- see (d) above. MethodInfo* is NULL, exactly as the game
 * itself passes it.
 *
 * The CALLER must already hold the outer aowl_p_p_seh guard; this adds none
 * (that guard is not re-entrant -- a nested one would disarm the outer). */
static int32_t aowl_botnav_goto(void* botOwner, double x, double y, double z,
                                double reachDist, int32_t slowAtTheEnd,
                                int32_t force) {
    AowlBnGoToPointFn fn;
    AowlBnV3 pos;
    float rd;

    fn = (AowlBnGoToPointFn)aowl_bn_gotopoint_fn();
    if (!fn) return -1;
    if (!aowl_botnav_can_command(botOwner)) return -2;

    pos.x = (float)x; pos.y = (float)y; pos.z = (float)z;
    rd = (float)reachDist;
    if (!(rd >= 0.0f)) rd = 1.0f;      /* also catches NaN */
    if (rd < 0.25f) rd = 0.25f;

    return fn(botOwner, &pos,
              (uint8_t)(slowAtTheEnd ? 1 : 0),
              rd,
              (uint8_t)1,   /* getUpWithCheck -- the game hardcodes this true  */
              (uint8_t)0,   /* mustHaveWay -- false: accept a partial path     */
              (uint8_t)0,   /* mustGetUp                                       */
              (uint8_t)0,   /* onlyShortTrie                                   */
              (uint8_t)(force ? 1 : 0),
              NULL);        /* MethodInfo* -- proven NULL-safe                 */
}

/* Stop a bot where it stands. Derefs only [this+0x3D0]. 1 = issued. */
static int32_t aowl_botnav_stop(void* botOwner) {
    AowlBnStopMoveFn fn;
    int32_t ok = 0;
    void* mover;
    if (!aowl_bn_sane(botOwner)) return 0;
    fn = (AowlBnStopMoveFn)aowl_bn_stopmove_fn();
    if (!fn) return 0;
    mover = aowl_botnav_read_ptr(botOwner, AOWL_BN_MOVER_OFF, &ok);
    if (!ok || !aowl_bn_sane(mover)) return 0;
    fn(botOwner, NULL);
    return 1;
}

/* Set a bot's target move speed (0..1). Derefs only [this+0x3D0], then writes
 * BotMover.MoveSpeed. 1 = issued. */
static int32_t aowl_botnav_set_speed(void* botOwner, double speed) {
    AowlBnSetSpeedFn fn;
    int32_t ok = 0;
    void* mover;
    float s = (float)speed;
    if (!aowl_bn_sane(botOwner)) return 0;
    if (!(s >= 0.0f)) s = 0.0f;
    if (s > 1.0f) s = 1.0f;
    fn = (AowlBnSetSpeedFn)aowl_bn_setspeed_fn();
    if (!fn) return 0;
    mover = aowl_botnav_read_ptr(botOwner, AOWL_BN_MOVER_OFF, &ok);
    if (!ok || !aowl_bn_sane(mover)) return 0;
    fn(botOwner, s, NULL);
    return 1;
}

/* Did all three call targets byte-verify on this build? Reported once at bind
 * so a build mismatch is visible in the log rather than silent. */
static int32_t aowl_botnav_calls_ok(void) {
    return (aowl_bn_gotopoint_fn() && aowl_bn_stopmove_fn() &&
            aowl_bn_setspeed_fn()) ? 1 : 0;
}

#endif /* AOWLSPT_BOTNAV_H */
