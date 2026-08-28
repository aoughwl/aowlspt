/* shapetest.c -- the falsifiability proof for the empty-body-stub gate.
 *
 * A guard that has never been SHOWN to fire is not a guard (CLAUDE.md 9b). So
 * this constructs the bad input by hand -- including the real first bytes of
 * this build's universal stub at 0x628110 -- and asserts the classifier FIRES;
 * then constructs good input (the real prologue of a method the host already
 * byte-verifies) and asserts it does NOT.
 *
 * Three outcomes, never two: every case prints PASS or FAIL, and a case whose
 * input could not be built prints INCONCLUSIVE.
 *
 * Build (PowerShell):
 *   gcc -I abi -o build/shapetest.exe tools/shapetest.c && build/shapetest.exe
 */
#include <stdio.h>
#include "aowlspt_prologue.h"

static int fails = 0, passes = 0;

static void expect(const char* what, const unsigned char* b, int n, int want) {
    int got = aowl_pro_classify(b, n);
    if (n <= 0) { printf("INCONCLUSIVE  %s -- no input bytes\n", what); return; }
    if (got == want) { passes++; printf("PASS  %-46s -> %s\n", what,
                                        aowl_pro_shape_name(got)); }
    else { fails++; printf("FAIL  %-46s -> got %d (%s), wanted %d (%s)\n",
                           what, got, aowl_pro_shape_name(got),
                           want, aowl_pro_shape_name(want)); }
}

int main(void) {
    /* --- THE BAD INPUTS: each must FIRE. ------------------------------- */
    /* 0x628110, verbatim: `ret 0`, padded with int3 as the linker leaves it.
     * This is the address `ForceMeshUpdate` resolves to. */
    static const unsigned char stub628110[16] = {
        0xC2,0x00,0x00, 0xCC,0xCC,0xCC,0xCC,0xCC,
        0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC };
    static const unsigned char bare_ret[16]  = { 0xC3,0xCC,0xCC,0xCC,0,0,0,0,
                                                 0,0,0,0,0,0,0,0 };
    static const unsigned char xor_ret[16]   = { 0x33,0xC0,0xC3,0xCC,0,0,0,0,
                                                 0,0,0,0,0,0,0,0 };
    static const unsigned char xor_ret64[16] = { 0x48,0x33,0xC0,0xC3,0,0,0,0,
                                                 0,0,0,0,0,0,0,0 };
    /* mov rax,[rcx+0x10]; ret -- a REAL body, but folded, so shared. */
    static const unsigned char getter[16]    = { 0x48,0x8B,0x41,0x10,0xC3,0xCC,
                                                 0,0,0,0,0,0,0,0,0,0 };
    static const unsigned char jmptab[16]    = { 0xFF,0x25,0x00,0x00,0x00,0x00,
                                                 0,0,0,0,0,0,0,0,0,0 };
    static const unsigned char tailjmp[16]   = { 0xE9,0x11,0x22,0x33,0x44,0xCC,
                                                 0,0,0,0,0,0,0,0,0,0 };

    /* --- THE GOOD INPUT: must NOT fire. --------------------------------
     * UnityEngine.GameObject::GetComponent(String) @0x52A8510, the 16 bytes
     * abi/aowlspt_navui.h already declares and byte-verifies. A real body. */
    static const unsigned char good[16] = {
        0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x17,0xC0,0xE2 };
    /* System.Type::GetTypeFromHandle @0x458B020, likewise. */
    static const unsigned char good2[16] = {
        0x40,0x53, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xC2,0x1E,0xB4,0x02,0x00, 0x48,0x8B,0xD9 };

    printf("-- the guard must FIRE on these --\n");
    expect("0x628110 universal stub (C2 00 00)", stub628110, 16, AOWL_SHAPE_RETN);
    expect("bare ret (C3)",                      bare_ret,   16, AOWL_SHAPE_RET);
    expect("xor eax,eax; ret",                   xor_ret,    16, AOWL_SHAPE_XORRET);
    expect("xor rax,rax; ret",                   xor_ret64,  16, AOWL_SHAPE_XORRET);
    expect("folded field getter",                getter,     16, AOWL_SHAPE_TRIVIAL);
    expect("jmp [rip+disp32]",                   jmptab,     16, AOWL_SHAPE_JMPTABLE);
    expect("jmp rel32 tail thunk",               tailjmp,    16, AOWL_SHAPE_TAILJUMP);

    printf("-- the guard must NOT fire on these --\n");
    expect("GameObject::GetComponent(String) @0x52A8510", good,  16, AOWL_SHAPE_BODY);
    expect("Type::GetTypeFromHandle @0x458B020",          good2, 16, AOWL_SHAPE_BODY);

    printf("-- the policy predicates --\n");
    if (aowl_pro_shape_is_stub(aowl_pro_classify(stub628110,16)) &&
        !aowl_pro_shape_is_stub(aowl_pro_classify(good,16)) &&
        aowl_pro_shape_no_detour(AOWL_SHAPE_UNKNOWN) &&
        aowl_pro_shape_no_detour(AOWL_SHAPE_TAILJUMP) &&
        !aowl_pro_shape_no_detour(AOWL_SHAPE_BODY) &&
        !aowl_pro_shape_is_stub(AOWL_SHAPE_TRIVIAL)) {
        passes++; printf("PASS  is_stub/no_detour agree with the policy\n");
    } else { fails++; printf("FAIL  is_stub/no_detour disagree with the policy\n"); }

    printf("\n%d PASS, %d FAIL\n", passes, fails);
    return fails ? 1 : 0;
}
