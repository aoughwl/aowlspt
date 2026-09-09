/* aowlspt_botcap.h -- OFFLINE SCAV-CAP LIFT for the post-1.0 EFT host.
 *
 * One Unity-thread int32 field poke that neutralises the offline bot cap so the
 * generated scav wave pool actually places. It applies the SAME proven,
 * reflection-free raw-field-write capability as the version brand and the
 * settings/botdiag probes (static-RVA detour, `aowl_is_readable`-guarded raw
 * hops, VirtualQuery-guarded write, flag-gated, fail-safe) -- no runtime_invoke,
 * no reflection (both are DEAD on this build).
 *
 * ## The gate (RE, byte-verified against build 1.1.0.1.46777)
 *
 *   `EFT.BotSpawner.MaxBots` = int32 at offset **+0xC0** on the live BotSpawner.
 *   Verified by the property accessors:
 *     get_MaxBots @0x698410 = `8B 81 C0 00 00 00`  (mov eax,[rcx+0xC0])
 *     set_MaxBots @0x698420 = `89 91 C0 00 00 00`  (mov [rcx+0xC0],edx)
 *   `BotSpawner::CheckOnMax` computes room = MaxBots - (alive@+0x7C + loading@+0x70);
 *   room<=0 defers the bot forever. **MaxBots==0 means UNLIMITED** (CheckOnMax's
 *   first test short-circuits to allow-all). Bosses carry IgnoreMaxBots and bypass
 *   the cap; scav waves do NOT, so Tagilla+escort consume the small offline
 *   MaxBots and the 24 assault never place. Writing MaxBots=0 lifts the cap.
 *
 * ## What it hooks -- primary: `EFT.BotSpawner::AddPlayer` @ RVA 0x2563AE0
 *
 *   Called EXACTLY ONCE from `<LocalBotsSpawnInitialization>d__12::MoveNext`
 *   (+0xad3fad) at raid init, with RCX = the live BotSpawner (`this`). One-shot,
 *   minimal hot-path work: set `[BotSpawner+0xC0] = 0` once, before the waves
 *   fire. That BotSpawner is the same object CheckOnMax reads, so RCX=BotSpawner
 *   here is confirmed by the accessor form ([rcx+0xC0]).
 *
 *   Prologue @ 0x2563AE0 (byte-verified) -- clean whole-instruction steal, no
 *   RIP-relative operand and no branch in the stolen region:
 *     48 89 5C 24 18       mov  [rsp+0x18], rbx      (5)
 *     57                   push rdi                  (1)
 *     48 83 EC 20          sub  rsp, 0x20            (4)
 *     80 3D 99 F6 B5 04 .. cmp  byte [rip+0x4B5F699], 0   (disp32 pins the build)
 *   The first three instructions (10 bytes) relocate cleanly; the `cmp`'s disp32
 *   is included in the signature only to pin the build, not stolen. On any other
 *   build the bytes differ, the guard fails, and NULL is returned -- a missed
 *   bind, never a corrupted game. (CheckOnMax @0x2560940 is the belt-and-suspenders
 *   alternative -- runs before every check -- but fires very frequently; AddPlayer
 *   is preferred for the one-shot minimal write.)
 *
 * Fail-safe throughout: prologue verified before the pointer is handed out, the
 * BotSpawner pointer and the +0xC0 slot are guarded before the write, only an
 * int32 is written, and the whole detour body runs under the VEH/SEH guard so a
 * fault can never reach the game. A low-risk write (it only relaxes an int
 * compare the game already performs) but guarded anyway -- it runs during raid
 * entry, a fragile path.
 */

#ifndef AOWLSPT_BOTCAP_H
#define AOWLSPT_BOTCAP_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- EFT.BotSpawner.MaxBots int32 field offset ---- */
#define AOWL_BC_MAXBOTS_OFF  0xC0

static int32_t aowl_bc_off_maxbots(void) { return AOWL_BC_MAXBOTS_OFF; }

/* ------------------------------------------------------------------ *
 * The hook target: EFT.BotSpawner::AddPlayer @ RVA 0x2563AE0.
 *
 * Same self-checking shape as aowlspt_botdiag.h: locate GameAssembly, VirtualQuery
 * the RVA for committed executable memory, memcmp the recorded prologue. NULL on
 * any mismatch. This only locates+verifies a code pointer; the actual field poke
 * is done by the Nim detour body via `aowl_botcap_write_i32`.
 */
typedef struct AowlBotCapTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlBotCapTarget;

static int32_t aowl_botcap_base_found = 0;
static int32_t aowl_botcap_sig_ok     = 0;
static int32_t aowl_botcap_last_rva   = 0;

static const AowlBotCapTarget aowl_botcap_targets[] = {
    /* EFT.BotSpawner::AddPlayer @ 0x2563AE0 (one-shot, RCX = BotSpawner)
     * 48 89 5C 24 18       mov  [rsp+0x18], rbx
     * 57                   push rdi
     * 48 83 EC 20          sub  rsp, 0x20
     * 80 3D 99 F6 B5 04    cmp  byte [rip+0x4B5F699], .. (disp32 pins the build) */
    { "EFT.BotSpawner::AddPlayer", 0x2563AE0u,
      { 0x48,0x89,0x5C,0x24,0x18, 0x57, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x99,0xF6,0xB5,0x04 }, 16 },
};

#define AOWL_BOTCAP_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_botcap_targets) / sizeof(aowl_botcap_targets[0])))

static void* aowl_botcap_target_at(int32_t i) {
    HMODULE ga;
    const AowlBotCapTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_BOTCAP_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_botcap_base_found = 1;

    t = &aowl_botcap_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_botcap_sig_ok = 1;
    aowl_botcap_last_rva = (int32_t)t->rva;
    return (void*)p;
}

static const char* aowl_botcap_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_BOTCAP_TARGET_COUNT) return "";
    return aowl_botcap_targets[i].name;
}

static int32_t aowl_botcap_target_count(void) { return AOWL_BOTCAP_TARGET_COUNT; }

/* Read a single int32 at p+off, guarded (VirtualQuery, never a faulting deref).
 * `*ok` is set to 1 on a readable slot, 0 otherwise (value then 0). The mirror of
 * the version brand's read discipline, for the "was N" log line. */
static int32_t aowl_botcap_read_i32(void* p, int32_t off, int32_t* ok) {
    MEMORY_BASIC_INFORMATION mbi;
    char* at;
    int32_t v = 0;
    if (ok) *ok = 0;
    if (!p) return 0;
    at = (char*)p + off;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)at + 4u;
        if (need < (uintptr_t)at) return 0;
        if (need > end) return 0;
    }
    memcpy(&v, at, 4);
    if (ok) *ok = 1;
    return v;
}

/* An int32 field write at p+off, but only if that 4-byte slot lies inside one
 * committed, writable region -- the int32 mirror of aowl_uxpatch_write_ptr.
 * Returns 1 on success, 0 if the slot is not safely writable (nothing written).
 * This is the ONLY thing here that touches game state, and it writes exactly one
 * int32. */
static int32_t aowl_botcap_write_i32(void* p, int32_t off, int32_t value) {
    MEMORY_BASIC_INFORMATION mbi;
    char* at;
    if (!p) return 0;
    at = (char*)p + off;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)at + 4u;
        if (need < (uintptr_t)at) return 0;
        if (need > end) return 0;
    }
    memcpy(at, &value, 4);
    return 1;
}

#endif /* AOWLSPT_BOTCAP_H */
