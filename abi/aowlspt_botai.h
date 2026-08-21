/* aowlspt_botai.h -- BOT AI ACTIVATION RESCUE for the post-1.0 EFT host.
 *
 * One Unity-thread bool field poke that releases the gate which keeps our
 * offline scavs standing still at their spawn with a knife in their hands and
 * their primary slung on their back. Same proven, reflection-free shape as
 * `aowlspt_botcap.h` (static-RVA detour, prologue byte-verified, VirtualQuery
 * guarded raw hops, guarded write, flag-gated, fail-safe, whole body under the
 * VEH/SEH guard). No runtime_invoke, no reflection -- both are DEAD on this
 * build.
 *
 * ## The activation chain (RE, byte-verified against build 1.1.0.1.46777)
 *
 *   BotSpawner::ActivateBots            0x2565970
 *     -> IBotCreator.ActivateBot        0x1E0F6E0 / 0x1E0FA60  (tail-jumps to
 *        BotCreatorClient::SpawnBot     0x1E0EFE0, with a Comfort Callback)
 *     -> <>c__DisplayClass1{6,7}_0::<ActivateBot>b__0  (the callback)
 *     -> BotCreatorClient::ActivationFaze          0x1E0FDB0
 *          (the ONLY caller of PreActivate: E8 at +0x1E0FFFD)
 *     -> EFT.BotOwner::PreActivate                 0x813F60
 *          ... builds BotMover / BotWeaponPresetCollection / BotMemory ...
 *          calls BotWeaponSelector::TakeMainWeapon 0xD40100  (at +0x8142DE)
 *          and FINALLY, at +0x8145C4:  mov dword ptr [BotOwner+0x30], 1
 *                                      i.e. `_botState = 1` (PreActivated)
 *
 *   Then, EVERY FRAME:
 *     BotsList::UpdateByUnity           0x1BD6510
 *       -> EFT.BotOwner::UpdateManual   0x81B7C0   (the ONLY caller, E8 @0x1BD6656)
 *
 *   `BotOwner::UpdateManual` is a three-way switch on `_botState`:
 *     +0x81B82A  cmp dword ptr [rbx+0x30], 2 ; jne 0x81C440   <- 2 = ACTIVE: the
 *                whole brain runs (BotStandBy::Update, CalcGoal, ShootData,
 *                BotDogFight, BotHeadData, ... the bot thinks and moves)
 *     +0x81C440  cmp dword ptr [rbx+0x30], 1 ; jne <return>   <- 1 = PreActivated
 *     +0x81C44A  mov rax, [rbx+0x308]                         <- WeaponManager
 *     +0x81C45A  cmp byte ptr [rax+0x80], 0 ; je <return>     <- **THE GATE**
 *                (then a NavMesh.SamplePosition; on failure it waits out a
 *                 cooldown and teleports the bot to a BotZone spawn point)
 *     +0x81C65F  call 0x818F50                                <- BotOwner::Activate
 *                which at +0x81A855 does `mov dword ptr [rsi+0x30], 2`.
 *
 *   So a bot only ever leaves state 1 for state 2 -- only ever starts thinking --
 *   if `BotOwner.WeaponManager.IsReady` is true.
 *
 * ## The gate field (byte-verified accessors)
 *
 *   EFT.BotOwner.WeaponManager    = pointer at offset **+0x308**
 *     get_WeaponManager @0x80F040 = `48 8B 81 08 03 00 00 C3`
 *                                   (mov rax,[rcx+0x308]; ret)
 *     set_WeaponManager @0x80F057 writes the same slot; the only other writer is
 *     EFT.BotOwner::Create @0x812825 -- which runs BEFORE PreActivate, so the
 *     slot is already populated at our hook point.
 *   BotWeaponManager.IsReady      = bool at offset **+0x80**
 *     get_IsReady @0xA003D0 = `0F B6 81 80 00 00 00 C3` (movzx eax,byte[rcx+0x80])
 *     set_IsReady @0xA003E0 = `88 91 80 00 00 00 C3`    (mov byte[rcx+0x80],dl)
 *   EFT.BotOwner._botState        = int32 at offset **+0x30**
 *     get_BotState @0x6D2DD0 = `8B 41 30 C3`
 *     set_BotState @0x80FD40 = `... 89 51 30 ...`
 *
 * ## Who sets IsReady, and why ours never do
 *
 *   The ONLY writer of `IsReady = true` in the image is inside
 *   `BotWeaponManager::UpdateFirearmsController` @0xD3CFE0, at +0xD3D45F
 *   (`mov byte ptr [rbp+0x80], r15b`, r15b == 1, immediately after
 *   `LookSensor::Init`). Its callers are, exhaustively:
 *     BotWeaponManager::CheckCurMainWeapon    0xD3C939
 *     BotWeaponManager::UpdateHandsController 0xD3CF48
 *     BotStationaryWeaponData::ImplementStationary
 *   and `UpdateHandsController` is reached ONLY from
 *     BotWeaponSelector::OnWeaponTaken        0xD41073
 *   -- the completion callback of the weapon change that PreActivate kicks off
 *   with `TakeMainWeapon`. If that weapon change never completes, `OnWeaponTaken`
 *   never fires, `IsReady` stays false, and the bot is pinned in state 1 forever:
 *   it stands at its spawn, it never thinks, and its hands still hold the default
 *   Scabbard item (the knife) while the primary stays slung. That is EXACTLY the
 *   reported symptom, and it is one gate, not two.
 *
 * ## What this does
 *
 *   Hooks `EFT.BotOwner::PreActivate` (once per bot, on the Unity thread, RCX =
 *   the BotOwner) and sets `WeaponManager.IsReady = 1`. It does NOT call
 *   Activate, does NOT touch `_botState`, and does NOT skip the original: the
 *   game's own `UpdateManual` still runs its NavMesh check and its own
 *   `Activate()` on its own schedule. All this removes is the weapon-readiness
 *   veto. For a bot whose weapon change would have completed normally the poke
 *   is a no-op in effect (OnWeaponTaken sets the same byte to the same value a
 *   frame or two later); for a bot whose weapon change never completes it is the
 *   difference between a statue and a working scav.
 *
 * ## Hook target: EFT.BotOwner::PreActivate @ RVA 0x813F60
 *
 *   Prologue (byte-verified) -- 16 bytes of clean, whole instructions, no
 *   RIP-relative operand and no branch in the stolen region, comfortably more
 *   than the engine's 14-byte `jmp [rip+0]`:
 *     48 89 5C 24 10    mov [rsp+0x10], rbx   (5)
 *     48 89 6C 24 18    mov [rsp+0x18], rbp   (5)
 *     48 89 74 24 20    mov [rsp+0x20], rsi   (5)
 *     57                push rdi              (1)
 *     48 83 EC 40       sub  rsp, 0x40        (4)
 *     80 3D 4D 47 ..    cmp  byte [rip+..],0  (disp32 pins the build; NOT stolen)
 *   On any other build the bytes differ, the guard fails, NULL is returned -- a
 *   missed bind, never a corrupted game.
 */

#ifndef AOWLSPT_BOTAI_H
#define AOWLSPT_BOTAI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- field offsets (single source of truth; see the accessors quoted above) ---- */
#define AOWL_BA_BOTSTATE_OFF     0x30    /* EFT.BotOwner._botState      int32   */
#define AOWL_BA_WEAPONMGR_OFF    0x308   /* EFT.BotOwner.WeaponManager  ptr     */
#define AOWL_BA_ISREADY_OFF      0x80    /* BotWeaponManager.IsReady    bool    */

static int32_t aowl_ba_off_botstate(void)  { return AOWL_BA_BOTSTATE_OFF;  }
static int32_t aowl_ba_off_weaponmgr(void) { return AOWL_BA_WEAPONMGR_OFF; }
static int32_t aowl_ba_off_isready(void)   { return AOWL_BA_ISREADY_OFF;   }

typedef struct AowlBotAiTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[24];
    int32_t             siglen;
} AowlBotAiTarget;

static int32_t aowl_botai_base_found = 0;
static int32_t aowl_botai_sig_ok     = 0;
static int32_t aowl_botai_last_rva   = 0;

static const AowlBotAiTarget aowl_botai_targets[] = {
    /* EFT.BotOwner::PreActivate @ 0x813F60 (once per bot, RCX = BotOwner) */
    { "EFT.BotOwner::PreActivate", 0x813F60u,
      { 0x48,0x89,0x5C,0x24,0x10,
        0x48,0x89,0x6C,0x24,0x18,
        0x48,0x89,0x74,0x24,0x20,
        0x57,
        0x48,0x83,0xEC,0x40,
        0x80,0x3D,0x4D,0x47 }, 24 },
};

#define AOWL_BOTAI_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_botai_targets) / sizeof(aowl_botai_targets[0])))

static void* aowl_botai_target_at(int32_t i) {
    HMODULE ga;
    const AowlBotAiTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_BOTAI_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_botai_base_found = 1;

    t = &aowl_botai_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_botai_sig_ok = 1;
    aowl_botai_last_rva = (int32_t)t->rva;
    return (void*)p;
}

static const char* aowl_botai_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BOTAI_TARGET_COUNT) return "";
    return aowl_botai_targets[i].name;
}

static int32_t aowl_botai_target_count(void) { return AOWL_BOTAI_TARGET_COUNT; }

/* ---- guarded raw primitives (never a faulting deref; VirtualQuery first) ---- */

static int32_t aowl_ba_slot_readable(void* at, size_t n) {
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
        if (need > end) return 0;
        if ((uintptr_t)at < start) return 0;
    }
    return 1;
}

static int32_t aowl_ba_slot_writable(void* at, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!at) return 0;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)at + (uintptr_t)n;
        if (need < (uintptr_t)at) return 0;
        if (need > end) return 0;
        if ((uintptr_t)at < start) return 0;
    }
    return 1;
}

/* One int32 read at p+off. *ok = 1 on success, else 0 (value 0). */
static int32_t aowl_botai_read_i32(void* p, int32_t off, int32_t* ok) {
    char* at;
    int32_t v = 0;
    if (ok) *ok = 0;
    if (!p) return 0;
    at = (char*)p + off;
    if (!aowl_ba_slot_readable(at, 4)) return 0;
    memcpy(&v, at, 4);
    if (ok) *ok = 1;
    return v;
}

/* One pointer read at p+off. *ok = 1 on success, else 0 (value NULL). */
static void* aowl_botai_read_ptr(void* p, int32_t off, int32_t* ok) {
    char* at;
    void* v = NULL;
    if (ok) *ok = 0;
    if (!p) return NULL;
    at = (char*)p + off;
    if (!aowl_ba_slot_readable(at, sizeof(void*))) return NULL;
    memcpy(&v, at, sizeof(void*));
    if (ok) *ok = 1;
    return v;
}

/* One byte read at p+off. *ok = 1 on success, else 0 (value 0). */
static int32_t aowl_botai_read_u8(void* p, int32_t off, int32_t* ok) {
    char* at;
    unsigned char v = 0;
    if (ok) *ok = 0;
    if (!p) return 0;
    at = (char*)p + off;
    if (!aowl_ba_slot_readable(at, 1)) return 0;
    memcpy(&v, at, 1);
    if (ok) *ok = 1;
    return (int32_t)v;
}

/* The ONLY thing here that touches game state: exactly one byte, and only if
 * that byte lies inside one committed, writable region. 1 on success, 0 if the
 * slot is not safely writable (nothing written). */
static int32_t aowl_botai_write_u8(void* p, int32_t off, int32_t value) {
    char* at;
    unsigned char v = (unsigned char)(value ? 1 : 0);
    if (!p) return 0;
    at = (char*)p + off;
    if (!aowl_ba_slot_writable(at, 1)) return 0;
    memcpy(at, &v, 1);
    return 1;
}

#endif /* AOWLSPT_BOTAI_H */
