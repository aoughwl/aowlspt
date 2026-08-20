/* aowlspt_beclient.h -- neuter the post-1.0 BattlEye anti-cheat validation gate.
 *
 * Once the menu is up the client runs `EFT.AnticheatValidationOperation.
 * RunValidation`, which (a) calls `BattlEye.BEClient.IsInstanceSuccessfully`
 * and errors if it is false, and (b) fails if the BE client calls the game's
 * RequestRestart callback within its ten-frame probe. Running the raw
 * `EscapeFromTarkov.exe` with an injected DLL -- rather than the BE-wrapped
 * `EscapeFromTarkov_BE.exe` -- fails both, and the client shows "Anticheat
 * loading failed. Game restart required" and quits.
 *
 * This is NOT the service-status check `aowlspt_beguard.h` already answers (that
 * one is a WinAPI IAT patch on UnityPlayer); this is the managed BE *client*
 * gate inside `GameAssembly.dll`. It is defeated with two byte patches to the
 * IL2CPP AOT code -- static `.text`-class patches, not runtime method-pointer
 * detours (which crash this client from the host thread):
 *
 *   1. `BattlEye.BEClient.IsInstanceSuccessfully` @ RVA 0x6699C0: overwrite the
 *      prologue with `mov al,1 ; ret` (B0 01 C3) so it always returns true and
 *      `BEClient.Start` reports no error. The native BE never actually inits, so
 *      its `Run`/`Update` forwarders stay self-gated (status != 2) and inert.
 *   2. `EFT.AnticheatValidationOperation.OnRequestRestart` @ RVA 0x9E9E62 is
 *      `mov byte [rsp+0x30], 1` (C6 44 24 30 01) -- the "a restart was asked
 *      for" flag. Flip the immediate 01 -> 00 (byte at RVA 0x9E9E66) so a
 *      restart request never marks the operation failed.
 *
 * RVAs are for imagebase 0x180000000 and this exact client build
 * (1.1.0.1.46777); resolved from the decrypted metadata's per-module
 * methodPointers and verified byte-for-byte against GameAssembly.dll. Each
 * patch checks the bytes it expects before writing, so a wrong offset is a
 * skipped patch rather than corrupted code. Apply after GameAssembly.dll is
 * mapped (i.e. after il2cpp is up) and before the menu reaches online play.
 */

#ifndef AOWLSPT_BECLIENT_H
#define AOWLSPT_BECLIENT_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* Diagnostics, read by the host after arming. */
static int32_t aowl_bec_base_found = 0;  /* GameAssembly.dll was located       */
static int32_t aowl_bec_isinst_ok  = 0;  /* IsInstanceSuccessfully patched      */
static int32_t aowl_bec_restart_ok = 0;  /* OnRequestRestart flag neutered      */
static int32_t aowl_bec_isinst_seen = 0; /* prologue matched what we expected   */
static int32_t aowl_bec_restart_seen = 0;/* restart imm matched (01 or already 0)*/

/* RVAs from imagebase 0x180000000. */
#define AOWL_BEC_ISINST_RVA   0x6699C0u
#define AOWL_BEC_RESTART_RVA  0x9E9E62u   /* the C6 44 24 30 01 instruction     */
/* The native BE forwarders. Forcing IsInstanceSuccessfully -> true makes
 * BEClient.Start report success, so RunValidation then pumps BEClient.Update()
 * ten frames and calls Stop() -- but the NATIVE client never initialised, so
 * those forwarders dereference a null client-data/delegate and throw a
 * NullReferenceException inside the anti-cheat validation. Neutering each to
 * `xor eax,eax ; ret` makes the whole BE path inert while the wrapper still
 * believes it succeeded, so validation completes cleanly. */
#define AOWL_BEC_UPDATE_RVA   0x669390u   /* prologue 48 89 5c ...              */
#define AOWL_BEC_STOP_RVA     0x668E80u   /* prologue 48 83 ec ...              */
#define AOWL_BEC_RUN_RVA      0x667700u   /* prologue 40 53 48 ...              */

static int32_t aowl_bec_stub_ok = 0;      /* forwarders neutered (0..3)         */

static int aowl_bec_write(unsigned char* at, const unsigned char* bytes, int n) {
    DWORD old = 0;
    if (!VirtualProtect(at, (SIZE_T)n, PAGE_EXECUTE_READWRITE, &old)) return 0;
    memcpy(at, bytes, (size_t)n);
    DWORD tmp = 0;
    VirtualProtect(at, (SIZE_T)n, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), at, (SIZE_T)n);
    return 1;
}

/* Apply both patches. Returns the number of patches that landed (0..2). Safe to
 * call more than once: an already-patched site is counted as done. */
static int32_t aowl_beclient_neuter(void) {
    HMODULE ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;
    aowl_bec_base_found = 1;
    unsigned char* base = (unsigned char*)ga;
    int landed = 0;

    /* 1. IsInstanceSuccessfully -> mov al,1 ; ret. Expected prologue:
     *    48 83 EC 28  (sub rsp, 0x28). If already B0 01 C3, treat as done. */
    {
        unsigned char* p = base + AOWL_BEC_ISINST_RVA;
        static const unsigned char proL[4] = {0x48, 0x83, 0xEC, 0x28};
        static const unsigned char patch[3] = {0xB0, 0x01, 0xC3};
        if (p[0] == 0xB0 && p[1] == 0x01 && p[2] == 0xC3) {
            aowl_bec_isinst_seen = 1; aowl_bec_isinst_ok = 1; landed++;
        } else if (memcmp(p, proL, 4) == 0) {
            aowl_bec_isinst_seen = 1;
            if (aowl_bec_write(p, patch, 3)) { aowl_bec_isinst_ok = 1; landed++; }
        }
    }

    /* 2. OnRequestRestart flag: instruction C6 44 24 30 01, flip imm 01 -> 00.
     *    The imm is the 5th byte of the instruction. */
    {
        unsigned char* insn = base + AOWL_BEC_RESTART_RVA;
        static const unsigned char pfx[4] = {0xC6, 0x44, 0x24, 0x30};
        if (memcmp(insn, pfx, 4) == 0) {
            aowl_bec_restart_seen = 1;
            unsigned char* imm = insn + 4;
            if (*imm == 0x00) { aowl_bec_restart_ok = 1; landed++; }
            else if (*imm == 0x01) {
                unsigned char z = 0x00;
                if (aowl_bec_write(imm, &z, 1)) { aowl_bec_restart_ok = 1; landed++; }
            }
        }
    }

    /* 3. Neuter the native forwarders Update/Stop/Run -> xor eax,eax ; ret, so
     *    the validation never dereferences the uninitialised native BE. Each is
     *    patched only if its first byte still looks like a real prologue (not
     *    already 0x31). */
    {
        static const unsigned char noop[3] = {0x31, 0xC0, 0xC3}; /* xor eax,eax;ret */
        static const uint32_t sites[3] = {
            AOWL_BEC_UPDATE_RVA, AOWL_BEC_STOP_RVA, AOWL_BEC_RUN_RVA };
        int stub = 0;
        for (int i = 0; i < 3; i++) {
            unsigned char* p = base + sites[i];
            if (p[0] == 0x31 && p[1] == 0xC0 && p[2] == 0xC3) { stub++; continue; }
            /* real prologues here all start 0x40/0x48 (REX) or 0x53/0x57 */
            if (p[0] == 0x40 || p[0] == 0x48 || p[0] == 0x53 || p[0] == 0x57) {
                if (aowl_bec_write(p, noop, 3)) stub++;
            }
        }
        aowl_bec_stub_ok = stub;
        if (stub >= 3) landed++;   /* count the forwarder set as one more win  */
    }
    return landed;
}

#endif /* AOWLSPT_BECLIENT_H */
