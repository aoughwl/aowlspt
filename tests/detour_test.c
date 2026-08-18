/* Tests for the x64 detour engine.
 *
 *   gcc -I../abi -o detour_test.exe detour_test.c && ./detour_test.exe
 *
 * The length decoder is the part worth testing hardest. It decides how many
 * bytes of a live function to overwrite, and a wrong answer does not fail --
 * it leaves half an instruction in a trampoline and executes it. So the
 * lengths are checked against hand-encoded byte sequences with known answers,
 * including the cases the decoder is supposed to *refuse*.
 *
 * Then the whole thing is exercised for real: a function is hooked, called,
 * and unhooked, and the observable behaviour is checked at each step.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "aowlspt_detour.h"

static int passed = 0;
static int failed = 0;

static void check(const char* name, int cond) {
    if (cond) { passed++; printf("ok    %s\n", name); }
    else      { failed++; printf("FAIL  %s\n", name); }
}

static void check_len(const char* name, const uint8_t* bytes, int32_t want) {
    int32_t got = aowl_insn_len(bytes);
    if (got == want) { passed++; printf("ok    %s (%d)\n", name, got); }
    else { failed++; printf("FAIL  %s: got %d, want %d\n", name, got, want); }
}

/* ------------------------------------------------------------------ *
 * The function under test
 * ------------------------------------------------------------------ */

static volatile int g_originalCalls = 0;
static volatile int g_detourCalls = 0;

/* Deliberately not static-inlined away: it must exist as a real function with
 * a real prologue to be patchable. */
__attribute__((noinline))
void victim(void) {
    g_originalCalls++;
}

/* The nimony side normally provides this; here the test does. Returning zero
 * means "run the original", which is what every check below expects. */
int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    g_detourCalls++;
    return 0;
}

int main(void) {
    printf("\ninstruction lengths\n");

    /* push rbp */
    { uint8_t b[] = {0x55}; check_len("push rbp", b, 1); }
    /* mov rbp, rsp  ->  48 89 E5 */
    { uint8_t b[] = {0x48,0x89,0xE5}; check_len("mov rbp,rsp", b, 3); }
    /* sub rsp, 0x20 ->  48 83 EC 20 */
    { uint8_t b[] = {0x48,0x83,0xEC,0x20}; check_len("sub rsp,imm8", b, 4); }
    /* sub rsp, 0x120 -> 48 81 EC 20 01 00 00 */
    { uint8_t b[] = {0x48,0x81,0xEC,0x20,0x01,0x00,0x00};
      check_len("sub rsp,imm32", b, 7); }
    /* mov rax, imm64 -> 48 B8 .. x8 */
    { uint8_t b[] = {0x48,0xB8,1,2,3,4,5,6,7,8};
      check_len("mov rax,imm64", b, 10); }
    /* mov eax, imm32 -> B8 .. x4 */
    { uint8_t b[] = {0xB8,1,2,3,4}; check_len("mov eax,imm32", b, 5); }
    /* xor eax, eax -> 31 C0 */
    { uint8_t b[] = {0x31,0xC0}; check_len("xor eax,eax", b, 2); }
    /* mov [rsp+0x8], rcx -> 48 89 4C 24 08 (mod=1, rm=4 -> SIB, disp8) */
    { uint8_t b[] = {0x48,0x89,0x4C,0x24,0x08};
      check_len("mov [rsp+8],rcx", b, 5); }
    /* movzx eax, byte [rcx] -> 0F B6 01 */
    { uint8_t b[] = {0x0F,0xB6,0x01}; check_len("movzx eax,[rcx]", b, 3); }
    /* endbr64 -> F3 0F 1E FA */
    { uint8_t b[] = {0xF3,0x0F,0x1E,0xFA}; check_len("endbr64", b, 4); }
    /* nop */
    { uint8_t b[] = {0x90}; check_len("nop", b, 1); }
    /* test eax, eax -> 85 C0 */
    { uint8_t b[] = {0x85,0xC0}; check_len("test eax,eax", b, 2); }
    /* ret */
    { uint8_t b[] = {0xC3}; check_len("ret", b, 1); }
    /* mov dword [rax+0x10], 1 -> C7 40 10 01 00 00 00 */
    { uint8_t b[] = {0xC7,0x40,0x10,0x01,0x00,0x00,0x00};
      check_len("mov [rax+16],imm32", b, 7); }

    printf("\ninstructions that must be refused\n");
    /* Relative branches move if relocated, so their displacement would be
       wrong in the trampoline. Refusing is the whole point. */
    { uint8_t b[] = {0xE8,1,2,3,4}; check_len("call rel32 refused", b, 0); }
    { uint8_t b[] = {0xE9,1,2,3,4}; check_len("jmp rel32 refused", b, 0); }
    { uint8_t b[] = {0xEB,0x10};    check_len("jmp rel8 refused", b, 0); }
    { uint8_t b[] = {0x74,0x10};    check_len("je rel8 refused", b, 0); }
    { uint8_t b[] = {0x0F,0x84,1,2,3,4}; check_len("je rel32 refused", b, 0); }
    /* lea rax, [rip+x] -> 48 8D 05 ..
       RIP-relative is decoded, not refused: it is relocated on copy, which is
       what makes real functions patchable at all. The length must still be
       exactly right, since the displacement is found by offset. */
    { uint8_t b[] = {0x48,0x8D,0x05,1,2,3,4};
      check_len("RIP-relative lea decoded", b, 7); }
    {
        uint8_t b[] = {0x48,0x8D,0x05,1,2,3,4};
        AowlInsn in = aowl_insn(b);
        check("RIP displacement located at offset 3", in.ripDisp == 3);
    }

    printf("\nstolen length\n");
    {
        /* push rbp; mov rbp,rsp; sub rsp,0x20; mov [rsp+8],rcx; mov [rsp+16],rdx
           = 1 + 3 + 4 + 5 + 5 = 18. Whole instructions only, so the answer is
           the first cumulative total that reaches the jump size -- 13 is not
           enough for a 14-byte jump, and half of the fifth instruction is not
           an option. Written against AOWL_JMP_SIZE rather than a literal,
           because this assertion is about the rule and not about today's
           encoding. */
        uint8_t b[] = {0x55, 0x48,0x89,0xE5, 0x48,0x83,0xEC,0x20,
                       0x48,0x89,0x4C,0x24,0x08,
                       0x48,0x89,0x54,0x24,0x10};
        int32_t n = aowl_stolen_len(b, AOWL_JMP_SIZE);
        check("covers the jump with whole instructions",
              n >= AOWL_JMP_SIZE && n == 18);
    }
    {
        /* A prologue whose second instruction is a relative call cannot be
           relocated, so no length is acceptable. */
        uint8_t b[] = {0x55, 0xE8,1,2,3,4, 0x90,0x90,0x90,0x90,0x90,0x90};
        int32_t n = aowl_stolen_len(b, AOWL_JMP_SIZE);
        check("refuses a prologue holding a relative call", n == 0);
    }

    printf("\nfunctions too short to patch\n");
    {
        /* Shorter than the 12-byte jump. Stealing enough bytes would run past
           its `ret` into whatever the linker put next, so the hook would
           overwrite an unrelated function and the trampoline would jump into
           the middle of one. It presents as a crash a long way from the patch,
           which is exactly why it is refused here. */
        uint8_t b[] = {0x31,0xC0,     /* xor eax,eax */
                       0xC3,          /* ret         */
                       0x90,0x90,0x90,0x90,0x90,0x90,0x90,0x90,0x90};
        check("refuses a function shorter than the jump",
              aowl_stolen_len(b, AOWL_JMP_SIZE) == 0);
    }
    {
        /* Exactly long enough: 7 + 5 + 3 = 15 >= AOWL_JMP_SIZE, with the ret
           left in place. One byte of slack, which is what "exactly long
           enough" means when instructions have length. */
        uint8_t b[] = {0x83,0x05,1,2,3,4,0x01,   /* addl $1, disp(%rip) */
                       0xB8,0,0,0,0,             /* mov  $0, %eax       */
                       0x48,0x89,0xE5,           /* mov  %rsp, %rbp     */
                       0xC3};
        check("accepts a function that is exactly long enough",
              aowl_stolen_len(b, AOWL_JMP_SIZE) == 15);
    }

    printf("\nrelocation\n");
    {
        /* mov eax, [rip+0x100]. Copied elsewhere, the displacement must be
           adjusted by exactly the distance moved or it reads a different
           global — silently, and only at run time. */
        uint8_t src[16] = {0x8B,0x05,0x00,0x01,0x00,0x00};
        uint8_t dst[16];
        memset(dst, 0, sizeof(dst));
        check("relocation succeeded", aowl_copy_relocated(dst, src, 6) == 0);
        int32_t got;
        memcpy(&got, dst + 2, 4);
        int64_t expect = 0x100 + ((int64_t)(intptr_t)src - (int64_t)(intptr_t)dst);
        check("displacement adjusted by the distance moved",
              (int64_t)got == expect);
    }

    printf("\nhooking a live function\n");
    victim();
    check("the function works before hooking", g_originalCalls == 1);

    void* h = aowl_hook_new();
    check("hook allocated", h != NULL);

    int32_t slot = aowl_hook_attach(h, (void*)victim);
    if (slot < 0) {
        printf("FAIL  attach returned %d\n", slot);
        failed++;
    } else {
        passed++;
        printf("ok    attached in slot %d (%d bytes stolen)\n",
               slot, aowl_hook_stolen(h));

        g_originalCalls = 0;
        g_detourCalls = 0;
        victim();
        check("the detour fired", g_detourCalls == 1);
        /* The trampoline runs the stolen instructions and jumps back, so the
           original body still executes. A hook that swallowed it would leave
           this at 0. */
        check("the original still ran", g_originalCalls == 1);

        check("unhooked cleanly", aowl_hook_remove(h) == 0);
        g_originalCalls = 0;
        g_detourCalls = 0;
        victim();
        check("the detour no longer fires", g_detourCalls == 0);
        check("the original is intact after unhooking", g_originalCalls == 1);
    }
    aowl_hook_free(h);

    printf("\n%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
