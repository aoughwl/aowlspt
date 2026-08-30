/* aowlspt_deploygate.h -- READ-ONLY "raid deployed" edge detector for the
 * post-1.0 EFT host. Two one-pointer POSTFIX detours, no game state ever
 * written, nothing walked. Its sole job: flip a host-side boolean at the two
 * real raid-lifecycle edges so features that must not draw during the ~2 minute
 * scene LOAD (the ESP overlay, in-world markers, "in raid" read-outs) stay dark
 * until the player is actually deployed.
 *
 * ## Why not RegisterPlayer
 *
 * `EFT.GameWorld::RegisterPlayer` (the botdiag/overlay cache target) fires once
 * per bot DURING scene load, long before deploy -- so gating "in raid" on it (or
 * on `GameWorld.MainPlayer` being non-null, which is also set during load) lights
 * the overlay up ~2 minutes early. The correct deploy edge is
 * `EFT.GameWorld::OnGameStarted`, which raises the AfterGameStarted event exactly
 * once, at deploy.
 *
 * ## The relocation blocker on OnGameStarted (MEASURED, build 1.1.0.1.46777)
 *
 * `EFT.GameWorld::OnGameStarted` @ RVA 0x2508000 has this prologue (verified with
 * tools/il2cpp_resolve.py `bytes 0x2508000` and disassembled with capstone):
 *
 *   +0   48 8B 89 30 01 00 00   mov  rcx, [rcx+0x130]   ; the event delegate
 *   +7   48 85 C9               test rcx, rcx
 *   +a   74 0F                  je   +0xF               ; RELATIVE BRANCH
 *   +c   48 8B 41 18            mov  rax, [rcx+0x18]
 *   +10  ...                    (tail-call the delegate's Invoke)
 *
 * A 14-byte `jmp [rip+0]` steal (AOWL_JMP_SIZE) must cover whole instructions to
 * offset >=14; that crosses the `je` at +0xa. aowlspt_detour.h's length decoder
 * (`aowl_insn`) returns AOWL_INSN_RELATIVE for a `74` short jump -- it cannot be
 * relocated into a trampoline -- so `aowl_stolen_len` returns 0 and the attach
 * fails. This is the same rejection aowlspt_botdiag.h already records for this
 * exact RVA. OnGameStarted is therefore NOT bindable by the current detour
 * engine, and the ON edge below WILL fail to arm on this build until either the
 * engine gains conditional-branch relocation (5-byte rel32 + near island, see
 * aowl_hook_prepare's comment) or a different clean-prologue deploy method is
 * measured. The target is kept here so the attempt is made, byte-verified, and
 * its failure is logged loudly rather than assumed.
 *
 * OnGameStarted sets NO boolean field on GameWorld (it only raises the event and
 * tail-calls), so there is also no field to poll each frame as a fallback.
 *
 * ## The OFF edge is clean and binds
 *
 * `EFT.GameWorld::Dispose` @ RVA 0x2501050, arity-0 instance (RCX = GameWorld
 * this), fires once at raid teardown. Prologue (verified `bytes 0x2501050`):
 *
 *   48 89 4C 24 08   mov [rsp+8], rcx
 *   53               push rbx
 *   56               push rsi
 *   57               push rdi
 *   41 54            push r12
 *   41 55            push r13
 *   41 56            push r14        ; total 14 bytes, no branch, no RIP-relative
 *
 * Fourteen bytes of whole, relocatable instructions: it steals cleanly. A postfix
 * here clears the deployed flag so the next raid's load does not inherit it.
 *
 * Same reflection-free discipline as aowlspt_botdiag.h: locate GameAssembly,
 * VirtualQuery the RVA for committed executable memory, memcmp the recorded
 * prologue, NULL on any mismatch. Read-only: only locates + verifies a function
 * pointer; nothing here writes to the game.
 */

#ifndef AOWLSPT_DEPLOYGATE_H
#define AOWLSPT_DEPLOYGATE_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

typedef struct AowlDeployTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlDeployTarget;

/* Index 0 = the ON edge (OnGameStarted), index 1 = the OFF edge (Dispose).
 * The Nim side arms each by index so a failed ON bind cannot disable the OFF
 * bind. */
#define AOWL_DEPLOY_ON   0
#define AOWL_DEPLOY_OFF  1

static const AowlDeployTarget aowl_deploy_targets[] = {
    /* EFT.GameWorld::OnGameStarted @ 0x2508000 -- ON edge.
     * 48 8B 89 30 01 00 00  mov rcx,[rcx+0x130]
     * 48 85 C9              test rcx,rcx
     * 74 0F                 je +0xF        (RELATIVE -- see header note; the
     * 48 8B 41 18           mov rax,[rcx+0x18]   engine cannot relocate this) */
    { "EFT.GameWorld::OnGameStarted", 0x2508000u,
      { 0x48,0x8B,0x89,0x30,0x01,0x00,0x00, 0x48,0x85,0xC9,
        0x74,0x0F, 0x48,0x8B,0x41,0x18 }, 16 },
    /* EFT.GameWorld::Dispose @ 0x2501050 -- OFF edge, clean prologue.
     * 48 89 4C 24 08  mov [rsp+8],rcx
     * 53 56 57 41 54 41 55 41 56 41 57  push rbx/rsi/rdi/r12/r13/r14/r15 */
    { "EFT.GameWorld::Dispose", 0x2501050u,
      { 0x48,0x89,0x4C,0x24,0x08, 0x53,0x56,0x57,0x41,0x54,
        0x41,0x55,0x41,0x56,0x41,0x57 }, 16 },
};

#define AOWL_DEPLOY_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_deploy_targets) / sizeof(aowl_deploy_targets[0])))

static int32_t aowl_deploy_base_found = 0;
static int32_t aowl_deploy_sig_ok     = 0;

static void* aowl_deploy_target_at(int32_t i) {
    HMODULE ga;
    const AowlDeployTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_DEPLOY_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_deploy_base_found = 1;

    t = &aowl_deploy_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) return NULL;

    aowl_deploy_sig_ok = 1;
    return (void*)p;
}

static const char* aowl_deploy_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_DEPLOY_TARGET_COUNT) return "";
    return aowl_deploy_targets[i].name;
}

static int32_t aowl_deploy_target_count(void) { return AOWL_DEPLOY_TARGET_COUNT; }

#endif /* AOWLSPT_DEPLOYGATE_H */
