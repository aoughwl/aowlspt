/* aowlspt_botdiag.h -- READ-ONLY GameWorld bot/player census for the post-1.0
 * EFT host. A DIAGNOSTIC instrument, nothing more.
 *
 * The one question it answers, during an offline raid: are AI bots actually
 * spawned into the live `EFT.GameWorld` (registered, positioned) or truly
 * absent? It is a logger. It never writes game state, never renders, never
 * changes gameplay -- it locates one method, reads a list of players by fixed
 * IL2CPP field offsets, and prints counts + positions to the host log. Same
 * reflection-free discipline as the version brand and the Phase 1 settings probe
 * (static-RVA detour, `cIsReadable`-guarded raw hops, decode strings by raw
 * layout, log). Reflection (`il2cpp_*` class/name/box/field iteration) is DEAD
 * on this build; only raw static offsets are used here.
 *
 * ## What it hooks
 *
 *   `EFT.GameWorld::RegisterPlayer` @ RVA 0x25038C0 (imagebase 0x180000000,
 *   build 1.1.0.1.46777). Called once per player/bot as it is registered into
 *   the world -- so a detour here is definitive per-spawn evidence: RCX = the
 *   live `GameWorld` (`this`), RDX = the `IPlayer` being registered. Each fire
 *   logs the incoming player, and (throttled) enumerates the whole registered
 *   list so the running census is visible. GameWorld exists only inside a raid,
 *   so this fires only in-raid, exactly where the question is asked.
 *
 * `OnGameStarted` @ 0x2508000 was rejected as a second one-shot target: its
 * compiled prologue has a conditional branch (`je`) within the first 16 bytes
 * (`48 8B 89 30 01 00 00  48 85 C9  74 0F ...`), which the detour engine's
 * length decoder cannot relocate. The whole-list enumerate is therefore driven
 * from inside the RegisterPlayer detour instead, which is strictly more
 * informative (a census after every registration, not just once).
 *
 * The RegisterPlayer prologue relocates cleanly:
 *   40 56               push rsi
 *   41 57               push r15
 *   48 81 EC 88 00 00 00  sub rsp, 0x88
 *   80 3D 42 F6 BB ..   cmp byte [rip+0xBBF642], 0
 * The first three instructions (11 bytes, no RIP-relative operand, no branch)
 * are a clean whole-instruction steal for the trampoline; the `cmp`'s disp32 is
 * included in the signature only to pin the build, not stolen. On any other
 * build the bytes differ, the guard fails, and NULL is returned -- a missed
 * bind, never a corrupted game.
 *
 * ## The offsets (from tools/il2cpp_resolve.py `fields`, build 1.1.0.1.46777,
 *    Il2CppMetadataRegistration.fieldOffsets @ 0x186B61E70, imagebase 0x180000000)
 *
 *   EFT.GameWorld
 *     + 0x1C8  AllAlivePlayersList   List<Player>    (alive players)
 *     + 0x1D0  RegisteredPlayers     List<IPlayer>   (every registered player)
 *     + 0x230  MainPlayer            Player          (the local player)
 *
 *   List<T>  (fixed IL2CPP layout, same as every generic List)
 *     + 0x10   _items -> T[]        + 0x18   _size (int32);  T[] elems @ +0x20
 *
 *   EFT.Player
 *     + 0x60   MovementContext       MovementContext
 *     + 0x9C0  Profile               Profile
 *     + 0xA00  AIData                IAIData     (non-null => AI-controlled bot)
 *     + 0xB89  IsYourPlayer          bool        (the local player)
 *   EFT.MovementContext
 *     + 0x370  PreviousPosition      Vector3     (3x float32 -- raw-readable
 *              world position; BifacialTransform.position is a delegate, not a
 *              field, so this cached Vector3 is the reflection-free source)
 *   EFT.Profile          + 0x48   Info -> ProfileInfo
 *   EFT.ProfileInfo      + 0x10   Nickname (System.String) + 0x48 Side
 *                                  (EPlayerSide int32) + 0x78 Settings
 *   EFT.ProfileSettings  + 0x10   Role (WildSpawnType int32) + 0x14 BotDifficulty
 *
 * All of these are CANDIDATES until the live read-only log shows a sane census
 * (a known nickname, a plausible position); the log is their validation. No
 * write is ever performed regardless.
 */

#ifndef AOWLSPT_BOTDIAG_H
#define AOWLSPT_BOTDIAG_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- EFT.GameWorld player collections + local-player field ---- */
#define AOWL_BD_GW_ALIVELIST   0x1C8
#define AOWL_BD_GW_REGPLAYERS  0x1D0
#define AOWL_BD_GW_MAINPLAYER  0x230

/* ---- List<T> raw layout + array element base (shared IL2CPP shape) ---- */
#define AOWL_BD_LIST_ITEMS     0x010
#define AOWL_BD_LIST_SIZE      0x018
#define AOWL_BD_ARR_ELEMS      0x020

/* ---- EFT.Player ---- */
#define AOWL_BD_PL_MOVECTX     0x060
#define AOWL_BD_PL_PROFILE     0x9C0
#define AOWL_BD_PL_AIDATA      0xA00
#define AOWL_BD_PL_ISYOU       0xB89

/* ---- EFT.MovementContext ---- */
#define AOWL_BD_MC_PREVPOS     0x370   /* Vector3: x@+0, y@+4, z@+8 */

/* ---- EFT.Profile -> ProfileInfo -> ProfileSettings ---- */
#define AOWL_BD_PROF_INFO      0x048
#define AOWL_BD_INFO_NICKNAME  0x010
#define AOWL_BD_INFO_SIDE      0x048
#define AOWL_BD_INFO_SETTINGS  0x078
#define AOWL_BD_SET_ROLE       0x010

/* Accessors (importc'd by the Nim probe) -- one per hop so a fault names it. */
static int32_t aowl_bd_off_gw_alivelist(void)  { return AOWL_BD_GW_ALIVELIST; }
static int32_t aowl_bd_off_gw_regplayers(void) { return AOWL_BD_GW_REGPLAYERS; }
static int32_t aowl_bd_off_gw_mainplayer(void) { return AOWL_BD_GW_MAINPLAYER; }
static int32_t aowl_bd_off_list_items(void)    { return AOWL_BD_LIST_ITEMS; }
static int32_t aowl_bd_off_list_size(void)     { return AOWL_BD_LIST_SIZE; }
static int32_t aowl_bd_off_arr_elems(void)     { return AOWL_BD_ARR_ELEMS; }
static int32_t aowl_bd_off_pl_movectx(void)    { return AOWL_BD_PL_MOVECTX; }
static int32_t aowl_bd_off_pl_profile(void)    { return AOWL_BD_PL_PROFILE; }
static int32_t aowl_bd_off_pl_aidata(void)     { return AOWL_BD_PL_AIDATA; }
static int32_t aowl_bd_off_pl_isyou(void)      { return AOWL_BD_PL_ISYOU; }
static int32_t aowl_bd_off_mc_prevpos(void)    { return AOWL_BD_MC_PREVPOS; }
static int32_t aowl_bd_off_prof_info(void)     { return AOWL_BD_PROF_INFO; }
static int32_t aowl_bd_off_info_nickname(void) { return AOWL_BD_INFO_NICKNAME; }
static int32_t aowl_bd_off_info_side(void)     { return AOWL_BD_INFO_SIDE; }
static int32_t aowl_bd_off_info_settings(void) { return AOWL_BD_INFO_SETTINGS; }
static int32_t aowl_bd_off_set_role(void)      { return AOWL_BD_SET_ROLE; }

/* ------------------------------------------------------------------ *
 * The hook target: EFT.GameWorld::RegisterPlayer @ RVA 0x25038C0.
 *
 * Same self-checking shape as aowlspt_bridge.h's targets: locate GameAssembly,
 * VirtualQuery the RVA for committed executable memory, memcmp the recorded
 * prologue. NULL on any mismatch. Read-only: it only *locates and verifies* a
 * function pointer; nothing here writes to the game.
 */
typedef struct AowlBotDiagTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlBotDiagTarget;

static int32_t aowl_botdiag_base_found = 0;
static int32_t aowl_botdiag_sig_ok     = 0;
static int32_t aowl_botdiag_last_rva   = 0;

static const AowlBotDiagTarget aowl_botdiag_targets[] = {
    /* EFT.GameWorld::RegisterPlayer @ 0x25038C0
     * 40 56                push rsi
     * 41 57                push r15
     * 48 81 EC 88 00 00 00 sub  rsp, 0x88
     * 80 3D 42 F6 BB       cmp  byte [rip+0xBBF642], .. (disp32 pins the build) */
    { "EFT.GameWorld::RegisterPlayer", 0x25038C0u,
      { 0x40,0x56, 0x41,0x57, 0x48,0x81,0xEC,0x88,0x00,0x00,0x00,
        0x80,0x3D,0x42,0xF6,0xBB }, 16 },
};

#define AOWL_BOTDIAG_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_botdiag_targets) / sizeof(aowl_botdiag_targets[0])))

static void* aowl_botdiag_target_at(int32_t i) {
    HMODULE ga;
    const AowlBotDiagTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_BOTDIAG_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_botdiag_base_found = 1;

    t = &aowl_botdiag_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_botdiag_sig_ok = 1;
    aowl_botdiag_last_rva = (int32_t)t->rva;
    return (void*)p;
}

static const char* aowl_botdiag_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BOTDIAG_TARGET_COUNT) return "";
    return aowl_botdiag_targets[i].name;
}

static int32_t aowl_botdiag_target_count(void) { return AOWL_BOTDIAG_TARGET_COUNT; }

#endif /* AOWLSPT_BOTDIAG_H */
