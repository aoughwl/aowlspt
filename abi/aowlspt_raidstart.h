/* aowlspt_raidstart.h -- the TRUE deploy signal for the shared raid-phase latch.
 *
 * ## The bug this exists for
 *
 * `raidphase.nim` armed its deploy latch on five READABLE signals (GameWorld
 * cached, MainPlayer Unity-alive, MainPlayer in AllAlivePlayersList,
 * SessionEndUIScene absent, Camera.main non-null). All five are satisfied at the
 * END OF SCENE LOAD -- the world is built, the local player is spawned into the
 * alive list and a camera exists -- which is roughly TEN SECONDS before the
 * player actually deploys and the raid is on screen. The user reported the ESP
 * boxes and the map HUD appearing during that window three separate times. The
 * latch mechanics were correct; the SIGNAL was early.
 *
 * ## What the true signal is, and what was measured
 *
 * All of the following are OFFLINE measurements on build 1.1.0.1.46777, from
 * `tools/il2cpp_resolve.py` (methodPointers + prologue bytes from
 * GameAssembly.dll) and `tools/fldoff.py` (Il2CppMetadataRegistration.
 * fieldOffsets). Every RVA below was checked for SHAREDNESS -- 28.3% of by-name
 * lookups on this build land on an RVA with more than one owner, and detouring
 * one of those fires for every owner.
 *
 *   EFT.GameWorld::OnGameStarted        @ 0x2508000  UNIQUE   *** NOT HOOKABLE
 *   EFT.GameWorld::Dispose              @ 0x2501050  UNIQUE   (verified, not bound)
 *   EFT.AbstractGame::get_Status        @ 0x8AD140   SHARED x60
 *   EFT.AbstractGame::set_Status        @ 0x7C9AD0   SHARED x35
 *   Audio.SpatialSystem.SpatialAudioSystem::AfterGameStarted @ 0x2194770 UNIQUE
 *   EFT.ExfiltrationTimerSoundPlayer::AfterGameStarted       @ 0xA4CAF0  UNIQUE
 *
 * ### Why OnGameStarted itself is not hooked
 *
 * Its compiled prologue is
 *      48 8B 89 30 01 00 00   mov  rcx, [rcx+0x130]   ; GameWorld.AfterGameStarted
 *      48 85 C9               test rcx, rcx
 *      74 0F                  je   +0xF
 * -- ten stealable bytes and then a RELATIVE BRANCH at offset 10. The detour
 * engine needs `AOWL_JMP_SIZE` = 14 (`jmp qword ptr [rip+0]`) and refuses to
 * relocate a relative branch (`aowl_stolen_len_why` -> -6). The five-byte
 * `jmp rel32` + island form that would fit is explicitly documented in
 * aowlspt_detour.h as the road NOT taken. So this address is a correct fact and
 * an unusable hook, and `abi/aowlspt_botdiag.h` already recorded it as such.
 *
 * ### What is hooked instead, and why it is the SAME instant
 *
 * The first two instructions of `OnGameStarted` are the proof: the method's
 * whole job is to load `GameWorld.AfterGameStarted` (+0x130, an `Action`,
 * confirmed by `fldoff.py fields EFT.GameWorld`) and invoke it. So every
 * subscriber to that Action runs INSIDE `OnGameStarted`, i.e. at exactly the
 * true deploy instant, not near it. An exhaustive method-name search of all
 * 31282 types found precisely three non-generated `AfterGameStarted()` bodies:
 *
 *   Audio.SpatialSystem.SpatialAudioSystem::AfterGameStarted @0x2194770 UNIQUE
 *        48 89 5C 24 08   mov [rsp+8], rbx
 *        48 89 74 24 10   mov [rsp+0x10], rsi
 *        57               push rdi
 *        48 83 EC 20      sub rsp, 0x20            -> 15 bytes, whole
 *                                                     instructions, NO branch,
 *                                                     NO rip-relative operand.
 *   EFT.ExfiltrationTimerSoundPlayer::AfterGameStarted @0xA4CAF0 UNIQUE
 *        40 53            push rbx
 *        48 83 EC 20      sub rsp, 0x20
 *        80 3D <disp32> 00  cmp byte [rip+..], 0   (rip-relative -- the engine
 *                                                   RELOCATES disp32; the disp
 *                                                   is in the signature only to
 *                                                   pin the build)
 *        48 8B D9         mov rbx, rcx             -> 16 bytes, no branch.
 *   EFT.RaidTimerAnnouncementController::AfterGameStarted @0xA43BC0
 *        *** SHARED with 2 owners -- REJECTED, not listed below. Hooking it
 *        would fire for a method we never identified.
 *
 * BOTH unique ones are listed and BOTH are bound, because either alone is a
 * subscription we cannot prove offline: a body existing is not a body
 * subscribed. Either firing is the same instant, and `raidphase` records which.
 * If NEITHER fires in a live raid the latch reports INCONCLUSIVE and says so --
 * it does not quietly fall back to the early proxies.
 *
 * ## AbstractGame.Status -- proven offset, no reachable instance
 *
 * `<Status>k__BackingField` is at **+0x38**, and that is not taken from metadata
 * alone: both accessors compile to a single instruction each and agree.
 *      get_Status  8B 41 38 C3        mov eax, [rcx+0x38] ; ret
 *      set_Status  89 51 38 C3        mov [rcx+0x38], edx ; ret
 * (Which is also exactly why both RVAs are shared 60 and 35 ways -- identical
 * one-instruction bodies are folded. Neither may be detoured.)
 *
 * The offset is recorded here so no future session re-derives it. It is NOT read
 * by the host, because there is no verified path to an `AbstractGame` instance:
 * the only two non-compiler-generated fields typed `AbstractGame` in the whole
 * image (`EFT.NonWavesSpawnScenario._game`, `<LateFixedUpdateWorker>d__5.<>4__this`)
 * are unreachable from anything this host holds, `EFT.TarkovApplication` has no
 * game field (its base is an instantiated generic singleton whose layout
 * CLAUDE.md 5 says is not reachable offline), and `EFT.Player` has none either.
 * Guessing a hop here would be the "offset that reads a plausible number" this
 * project keeps paying for. That leg stays INCONCLUSIVE and is reported as such.
 *
 * ## Safety
 *
 * READ-ONLY. Both targets are located by RVA, VirtualQuery'd for committed
 * executable memory, and memcmp'd against the recorded prologue; NULL on any
 * mismatch, so a different build gets a missed bind and never a corrupted game.
 * The detours read no argument and touch no game memory at all -- they set one
 * host-side flag and a timestamp. Nothing here writes to the game.
 */

#ifndef AOWLSPT_RAIDSTART_H
#define AOWLSPT_RAIDSTART_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* EFT.AbstractGame.<Status>k__BackingField -- recorded, deliberately unread.
 * EFT.GameStatus: Stopped=0 Running=1 Runned=2 Starting=3 Started=4 Stopping=5
 * SoftStopping=6 (tools/fldoff.py enum EFT.GameStatus). */
#define AOWL_RS_ABSTRACTGAME_STATUS  0x38

/* The two RVAs that are correct facts but are NOT bound, recorded so the next
 * session does not re-derive them: the true deploy method itself and the
 * definitive world teardown. */
#define AOWL_RS_RVA_ONGAMESTARTED    0x2508000u
#define AOWL_RS_RVA_GW_DISPOSE       0x2501050u

static int32_t aowl_rs_off_status(void) { return AOWL_RS_ABSTRACTGAME_STATUS; }

typedef struct AowlRaidStartTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlRaidStartTarget;

static int32_t aowl_rs_base_found = 0;
static int32_t aowl_rs_sig_ok     = 0;

static const AowlRaidStartTarget aowl_rs_targets[] = {
    /* index 0 -- the primary. See the header comment for the disassembly. */
    { "Audio.SpatialSystem.SpatialAudioSystem::AfterGameStarted", 0x2194770u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x48,0x89,0x74,0x24,0x10,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x80 }, 16 },
    /* index 1 -- the corroborator, bound as well because neither subscription
     * can be proven offline. The disp32 inside the rip-relative `cmp` is part of
     * the signature purely to pin this build. */
    { "EFT.ExfiltrationTimerSoundPlayer::AfterGameStarted", 0xA4CAF0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x26,0xC8,0x66,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_RS_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_rs_targets) / sizeof(aowl_rs_targets[0])))

static void* aowl_rs_target_at(int32_t i) {
    HMODULE ga;
    const AowlRaidStartTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_RS_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_rs_base_found = 1;

    t = &aowl_rs_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_rs_sig_ok = 1;
    return (void*)p;
}

static const char* aowl_rs_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_RS_TARGET_COUNT) return "";
    return aowl_rs_targets[i].name;
}

static int32_t aowl_rs_target_count(void) { return AOWL_RS_TARGET_COUNT; }

#endif /* AOWLSPT_RAIDSTART_H */
