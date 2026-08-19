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
 * Hand-encoded rather than compiler-produced on purpose: a check written as
 * "whatever gcc emitted here decodes to something" passes whether or not the
 * decoder is right, and stops testing the day the compiler changes its mind.
 * The bytes below are the instruction; the number beside them is the answer.
 *
 * Then the whole thing is exercised for real: functions are hooked, called,
 * and unhooked, and the observable behaviour is checked at each step -- with
 * an SSE prologue, with arguments, and with the original suppressed.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stddef.h>

#include "aowlspt_detour.h"
/* The mod-facing view of the same saved frame. See the assertions below
 * for why it is included here and not merely trusted. */
#include "aowlspt_frame.h"

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

static void check_why(const char* name, const uint8_t* bytes, int32_t want) {
    AowlInsn in = aowl_insn(bytes);
    if (in.len == 0 && in.why == want) { passed++; printf("ok    %s\n", name); }
    else {
        failed++;
        printf("FAIL  %s: len %d, why %d, want refusal %d\n",
               name, in.len, in.why, want);
    }
}

/* ------------------------------------------------------------------ *
 * The saved argument frame
 *
 * A mirror of `AowlRegs`, which lives in `aowlspt_shim.h` and is not included
 * here: at -O0 the shim emits the whole host vtable and this test would then
 * need the nimony side to link.
 *
 * What these checks are actually about is not the shim's struct but the frame
 * *the thunk writes*, whose offsets are hard-coded in the assembly in
 * `aowlspt_detour.h`. So the mirror is pinned to `AOWL_REGS_BYTES`, which that
 * same file declares: a thunk that grows a slot without this following it
 * fails to compile rather than reading the wrong one at run time.
 * ------------------------------------------------------------------ */

typedef struct TestRegs {
    uint64_t rcx, rdx, r8, r9;   /* 0x00 0x08 0x10 0x18 */
    /* The low 64 bits of XMM0-3, held as raw bits rather than as `double`.
     * A `float` argument occupies only the low *32* of them and the rest is
     * whatever the register happened to contain, so reading one of these
     * slots as a `double` yields a number unrelated to the argument. Keeping
     * them untyped here makes that impossible to do by accident. */
    uint64_t x0, x1, x2, x3;     /* 0x20 0x28 0x30 0x38 */
    uint64_t ret;                /* 0x40 -- a replacement, either way round  */
    /* 0x48 -- XMM0 as the *original* left it, written only on the postfix
     * path. Raw bits for the same reason the argument slots are: a `float`
     * return occupies the low 32 and the rest is register residue. */
    uint64_t retf;
} TestRegs;

_Static_assert(sizeof(TestRegs) == AOWL_REGS_BYTES,
               "the saved frame and the thunk that writes it disagree");
_Static_assert(offsetof(TestRegs, x0) == 0x20, "XMM slots moved");
_Static_assert(offsetof(TestRegs, ret) == 0x40, "the return slot moved");
_Static_assert(offsetof(TestRegs, retf) == 0x48,
               "the postfix float-return slot moved");

/* Argument *position*, which is the rule this ABI uses: position 0 is RCX or
 * XMM0, position 1 is RDX or XMM1, and which of the two it is depends on the
 * declared type of that parameter -- not on how many floats came before it. */
static uint64_t int_arg(const TestRegs* r, int pos) {
    switch (pos) {
        case 0: return r->rcx;
        case 1: return r->rdx;
        case 2: return r->r8;
        case 3: return r->r9;
        default: return 0;
    }
}
static float float_arg(const TestRegs* r, int pos) {
    uint64_t bits;
    float f;
    switch (pos) {
        case 0: bits = r->x0; break;
        case 1: bits = r->x1; break;
        case 2: bits = r->x2; break;
        case 3: bits = r->x3; break;
        default: return 0.0f;
    }
    memcpy(&f, &bits, sizeof(f));
    return f;
}

/* ------------------------------------------------------------------ *
 * The functions under test
 * ------------------------------------------------------------------ */

static volatile int g_originalCalls = 0;
static volatile int g_detourCalls = 0;

/* Deliberately not static-inlined away: it must exist as a real function with
 * a real prologue to be patchable. */
__attribute__((noinline))
void victim(void) {
    g_originalCalls++;
}

typedef struct TestObj {
    float   health;
    int32_t level;
} TestObj;

static TestObj g_obj;
static volatile int g_sseCalls = 0;

/* An SSE prologue, and the signature a compiled IL2CPP instance method has:
 * `this` in RCX, the float in XMM1 *because it is the second parameter*, the
 * int in R8, and the trailing MethodInfo* in R9.
 *
 * Compiled at -O2 while the rest of the file is at -O0, because -O0 spells
 * this out through the stack in `mov`s and the point is to get the compiler to
 * emit `pxor`/`cvtsi2ss`/`mulss` -- the two-byte opcodes that a decoder
 * covering only one-byte forms refuses, and which most of a real game method
 * is made of. `noinline` so it exists as a function to patch. */
__attribute__((noinline, optimize("O2")))
float sse_victim(void* self, float amount, int32_t kind, void* methodInfo) {
    (void)methodInfo;
    g_sseCalls++;
    TestObj* o = (TestObj*)self;
    o->health -= amount * (float)kind;
    return o->health;
}

static volatile int g_intCalls = 0;

/* The integer counterpart: four integer arguments by position, an integer
 * return, and no floating point anywhere. */
__attribute__((noinline, optimize("O2")))
int64_t int_victim(int64_t a, int64_t b, int64_t c, int64_t d) {
    g_intCalls++;
    return a * 1000 + b * 100 + c * 10 + d;
}

/* ------------------------------------------------------------------ *
 * The typed frame
 *
 * `aowlspt_frame.h` is the mod-facing view of the very frame the thunk above
 * writes, and it reads that frame by byte offset rather than through
 * `AowlRegs` -- because it is included by a *mod*, which has no business
 * pulling in the host shim to read four machine words.
 *
 * A copy of an offset is only safe while something pins it. This is that
 * something: the offsets the mod compiles against are asserted here against
 * the mirror this file already keeps of the assembly, so a slot that moves in
 * the thunk without both following it fails to compile rather than handing a
 * mod a register it did not ask for.
 * ------------------------------------------------------------------ */

_Static_assert(AOWL_FRAME_OFF_GPR == offsetof(TestRegs, rcx),
               "the frame's GPR offset and the thunk's disagree");
_Static_assert(AOWL_FRAME_OFF_XMM == offsetof(TestRegs, x0),
               "the frame's XMM offset and the thunk's disagree");
_Static_assert(AOWL_FRAME_OFF_RET == offsetof(TestRegs, ret),
               "the frame's return offset and the thunk's disagree");
_Static_assert(AOWL_FRAME_OFF_RETF == offsetof(TestRegs, retf),
               "the frame's float-return offset and the thunk's disagree");
_Static_assert(AOWL_FRAME_SLOTS == 4,
               "Win64 passes four arguments in registers");

/* What the host does per firing, in the same order and with the same pooled
 * frame: arm, call, disarm. Written out here rather than described, because a
 * test of the accessors that armed the frame differently from the host would
 * be testing something nothing runs. */

#define TYPED_OFF     0
#define TYPED_WATCH   1
#define TYPED_REPLACE 2

static int             g_typed[AOWL_MAX_HOOKS];
static const uint8_t*  g_typedKinds[AOWL_MAX_HOOKS];
static int32_t         g_typedArgc[AOWL_MAX_HOOKS];
static int32_t         g_typedRet[AOWL_MAX_HOOKS];
static uint32_t        g_typedFlags[AOWL_MAX_HOOKS];
static double          g_typedReplF[AOWL_MAX_HOOKS];
static int64_t         g_typedReplI[AOWL_MAX_HOOKS];

/* What the last typed firing read out of the frame. */
static volatile int g_typedFired[AOWL_MAX_HOOKS];
static uint64_t g_tSelf;
static double   g_tArgF;
static int64_t  g_tArgI;
static int      g_tArgFOk, g_tArgIOk;
static int64_t  g_tArgs[4];
static int      g_tArgsOk[4];
static double   g_tRetF;
static int64_t  g_tRetI;
static int      g_tRetFOk, g_tRetIOk;
static int      g_tRetIWhy;
static int      g_tPostfix;
static int      g_tSetOk;
/* Kept on purpose. Reading a frame after its handler returned is the mistake
 * this path is built to refuse, so the test has to make it. */
static void*    g_tKeptFrame;
static int32_t  g_tKeptArgc;

static int32_t typed_fire(int32_t slot, void* regs, int postfix) {
    void* f = aowl_frame_slot(0);
    uint32_t flags = g_typedFlags[slot];
    uint64_t self = 0;
    int32_t st = 0;
    int32_t i;
    if (!f) return 0;
    if (postfix) flags |= AOWL_FRAME_F_POSTFIX;
    if (!(flags & AOWL_FRAME_F_STATIC)) {
        memcpy(&self, (const unsigned char*)regs + AOWL_FRAME_OFF_GPR, 8);
    }
    aowl_frame_arm(f, regs, g_typedKinds[slot], g_typedArgc[slot],
                   g_typedRet[slot], flags, self);

    /* --- the handler ------------------------------------------------- */
    g_typedFired[slot]++;
    g_tKeptFrame = f;
    g_tKeptArgc = aowl_frame_argc(f);
    g_tSelf = aowl_frame_self(f);
    g_tPostfix = aowl_frame_is_postfix(f);
    for (i = 0; i < 4; i++) {
        g_tArgs[i] = aowl_frame_int(f, i, &g_tArgsOk[i]);
    }
    g_tArgF = aowl_frame_flt(f, 0, &g_tArgFOk);
    g_tArgI = aowl_frame_int(f, 1, &g_tArgIOk);
    if (postfix) {
        g_tRetF = aowl_frame_ret_flt(f, &g_tRetFOk);
        g_tRetI = aowl_frame_ret_int(f, &g_tRetIOk);
        g_tRetIWhy = aowl_frame_why();
    } else {
        /* On a prefix frame there is no result, and asking must be a refusal
           rather than a zero: the original has not run. */
        g_tRetF = aowl_frame_ret_flt(f, &g_tRetFOk);
        g_tRetIWhy = aowl_frame_why();
    }
    if (g_typed[slot] == TYPED_REPLACE) {
        if (g_typedRet[slot] == AOWLSPT_ARG_FLOAT ||
            g_typedRet[slot] == AOWLSPT_ARG_DOUBLE) {
            g_tSetOk = aowl_frame_set_ret_flt(f, g_typedReplF[slot]);
        } else {
            g_tSetOk = aowl_frame_set_ret_int(f, g_typedReplI[slot]);
        }
        st = g_tSetOk ? 1 : 0;
    }
    /* --- end of the handler ------------------------------------------ */

    aowl_frame_disarm(f);
    return st;
}

/* ------------------------------------------------------------------ *
 * The handler
 *
 * The nimony side normally provides this. Here the test does, keyed by slot so
 * several hooks can be live at once with different behaviour -- which is also
 * a check in itself, since the slot is the only thing the thunk passes and a
 * mix-up would show as the wrong function being suppressed.
 * ------------------------------------------------------------------ */

#define MODE_PASS 0
#define MODE_SKIP 1

static int      g_mode[AOWL_MAX_HOOKS];
static uint64_t g_replacement[AOWL_MAX_HOOKS];
static TestRegs g_seen[AOWL_MAX_HOOKS];
static volatile int g_fired[AOWL_MAX_HOOKS];

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    g_detourCalls++;
    if (slot < 0 || slot >= AOWL_MAX_HOOKS || regs == NULL) return 0;
    if (g_typed[slot]) return typed_fire(slot, regs, 0);
    g_fired[slot]++;
    memcpy(&g_seen[slot], regs, sizeof(TestRegs));
    if (g_mode[slot] == MODE_SKIP) {
        ((TestRegs*)regs)->ret = g_replacement[slot];
        return 1;
    }
    return 0;
}

/* The postfix half of the handler.
 *
 * Deliberately a *second* function rather than a flag on the first: the thunk
 * calls a different dispatcher on the postfix path, and a test that shared one
 * would pass even if the thunk called the wrong one. `g_postFired` rising while
 * `g_fired` does not is the assertion that the branch went where it should. */
static int      g_postMode[AOWL_MAX_HOOKS];
static uint64_t g_postReplacement[AOWL_MAX_HOOKS];
static TestRegs g_postSeen[AOWL_MAX_HOOKS];
static volatile int g_postFired[AOWL_MAX_HOOKS];

int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    if (slot < 0 || slot >= AOWL_MAX_HOOKS || regs == NULL) return 0;
    if (g_typed[slot]) return typed_fire(slot, regs, 1);
    g_postFired[slot]++;
    memcpy(&g_postSeen[slot], regs, sizeof(TestRegs));
    if (g_postMode[slot] == MODE_SKIP) {
        ((TestRegs*)regs)->ret = g_postReplacement[slot];
        return 1;
    }
    return 0;
}

static uint64_t float_bits(float f) {
    uint32_t b;
    uint64_t out = 0;
    memcpy(&b, &f, sizeof(b));
    out = b;
    return out;
}

static void show_prologue(const char* name, const void* fn) {
    const uint8_t* p = (const uint8_t*)fn;
    int32_t why = AOWL_INSN_OK;
    int32_t n = aowl_stolen_len_why(p, AOWL_JMP_SIZE, &why);
    printf("      %s prologue:", name);
    for (int32_t i = 0; i < (n > 0 ? n : 16); i++) printf(" %02x", p[i]);
    if (n > 0) printf("   (%d bytes stolen)\n", n);
    else printf("   (refused: %s)\n", aowl_hook_error_text(aowl_why_to_rc(why)));
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
    /* leave */
    { uint8_t b[] = {0xC9}; check_len("leave", b, 1); }
    /* cdqe -> 48 98 */
    { uint8_t b[] = {0x48,0x98}; check_len("cdqe", b, 2); }

    /* The two-byte map, which is where SSE lives.
     *
     * Every one of these was refused before, and between them they are the
     * whole body of an ordinary float method -- `mock_native_hurt` opens with
     * the first four. A decoder that refuses these refuses most of Tarkov, so
     * "conservative" stopped being a virtue and became the bug. */
    printf("\nSSE and the two-byte opcode map\n");
    /* pxor %xmm0,%xmm0 -- 66 is a mandatory prefix here, not an operand size */
    { uint8_t b[] = {0x66,0x0F,0xEF,0xC0}; check_len("pxor xmm0,xmm0", b, 4); }
    /* cvtsi2ss %r8d,%xmm0 -- F3 mandatory prefix *and* a REX between it and
       the 0F, which is the order the manual requires and the easy one to get
       backwards */
    { uint8_t b[] = {0xF3,0x41,0x0F,0x2A,0xC0};
      check_len("cvtsi2ss r8d,xmm0 (REX after F3)", b, 5); }
    { uint8_t b[] = {0xF3,0x0F,0x59,0xC8}; check_len("mulss xmm0,xmm1", b, 4); }
    { uint8_t b[] = {0xF3,0x0F,0x10,0x41,0x10};
      check_len("movss 0x10(%rcx),%xmm0", b, 5); }
    { uint8_t b[] = {0xF3,0x0F,0x11,0x41,0x10};
      check_len("movss %xmm0,0x10(%rcx)", b, 5); }
    { uint8_t b[] = {0xF3,0x0F,0x5C,0xC1}; check_len("subss", b, 4); }
    { uint8_t b[] = {0x0F,0x28,0xC1};      check_len("movaps xmm1,xmm0", b, 3); }
    { uint8_t b[] = {0x0F,0x57,0xC0};      check_len("xorps xmm0,xmm0", b, 3); }
    { uint8_t b[] = {0x0F,0x2E,0xC1};      check_len("ucomiss", b, 3); }
    { uint8_t b[] = {0xF3,0x0F,0x2C,0xC0}; check_len("cvttss2si", b, 4); }
    { uint8_t b[] = {0xF2,0x48,0x0F,0x2A,0xC1};
      check_len("cvtsi2sd rcx,xmm0 (REX.W)", b, 5); }
    { uint8_t b[] = {0xF3,0x0F,0x51,0xC0}; check_len("sqrtss", b, 4); }
    { uint8_t b[] = {0x66,0x0F,0x6F,0x01}; check_len("movdqa (%rcx),%xmm0", b, 4); }
    { uint8_t b[] = {0x66,0x0F,0x7E,0xC0}; check_len("movd %xmm0,%eax", b, 4); }
    { uint8_t b[] = {0x0F,0x11,0x44,0x24,0x20};
      check_len("movups %xmm0,0x20(%rsp)", b, 5); }
    /* The two-byte forms that carry an immediate. Sizing these as if they did
       not is a four-byte-short trampoline, and they are common: `cmpltss` is
       how a float comparison compiles and `shufps` is how a vector swizzle
       does. */
    { uint8_t b[] = {0xF3,0x0F,0xC2,0xC1,0x01};
      check_len("cmpss xmm1,xmm0,imm8", b, 5); }
    { uint8_t b[] = {0x0F,0xC6,0xC1,0x1B};
      check_len("shufps xmm1,xmm0,imm8", b, 4); }
    { uint8_t b[] = {0x66,0x0F,0x70,0xC1,0xE4};
      check_len("pshufd xmm1,xmm0,imm8", b, 5); }
    /* The three-byte escapes: 0F 38 has no immediate, 0F 3A always has one. */
    { uint8_t b[] = {0x66,0x0F,0x38,0x00,0xC1};
      check_len("pshufb (0F 38, no imm)", b, 5); }
    { uint8_t b[] = {0x66,0x0F,0x3A,0x0A,0xC0,0x04};
      check_len("roundss (0F 3A, imm8)", b, 6); }
    /* RIP-relative in the two-byte map. Loading a float constant compiles to
       exactly this, so the displacement offset has to be right or every
       relocated constant load reads the wrong four bytes of .rdata. */
    { uint8_t b[] = {0xF3,0x0F,0x59,0x05,1,2,3,4};
      check_len("mulss disp32(%rip),%xmm0", b, 8); }
    {
        uint8_t b[] = {0xF3,0x0F,0x59,0x05,1,2,3,4};
        AowlInsn in = aowl_insn(b);
        check("its RIP displacement is at offset 4", in.ripDisp == 4);
    }

    /* One-byte forms whose length is not a function of the opcode alone. */
    printf("\none-byte forms that are easy to mis-size\n");
    /* The group-3 trap. Same opcode, same ModRM byte position, four bytes of
       difference -- decided by the /reg field alone. */
    { uint8_t b[] = {0xF7,0xC0,0x01,0x00,0x00,0x00};
      check_len("test eax,imm32 (F7 /0)", b, 6); }
    { uint8_t b[] = {0xF7,0xD8}; check_len("neg eax (F7 /3)", b, 2); }
    { uint8_t b[] = {0x48,0xF7,0xD1}; check_len("not rcx (REX.W F7 /2)", b, 3); }
    { uint8_t b[] = {0xF6,0xC0,0x01}; check_len("test al,imm8 (F6 /0)", b, 3); }
    /* The accumulator forms: no ModRM at all, which is why a decoder that
       assumes one steals a byte too many. */
    { uint8_t b[] = {0x3D,0x00,0x10,0x00,0x00};
      check_len("cmp eax,imm32 (no ModRM)", b, 5); }
    { uint8_t b[] = {0x04,0x02}; check_len("add al,imm8 (no ModRM)", b, 2); }
    { uint8_t b[] = {0xA9,0x01,0x00,0x00,0x00}; check_len("test eax,imm32", b, 5); }
    { uint8_t b[] = {0x6B,0xC0,0x07}; check_len("imul eax,eax,imm8", b, 3); }
    { uint8_t b[] = {0x69,0xC0,0x00,0x01,0x00,0x00};
      check_len("imul eax,eax,imm32", b, 6); }
    { uint8_t b[] = {0xC1,0xE0,0x02}; check_len("shl eax,imm8", b, 3); }
    { uint8_t b[] = {0xD1,0xF8}; check_len("sar eax,1", b, 2); }

    printf("\ninstructions that must be refused\n");
    /* Relative branches move if relocated, so their displacement would be
       wrong in the trampoline. Refusing is the whole point. */
    { uint8_t b[] = {0xE8,1,2,3,4}; check_len("call rel32 refused", b, 0); }
    { uint8_t b[] = {0xE9,1,2,3,4}; check_len("jmp rel32 refused", b, 0); }
    { uint8_t b[] = {0xEB,0x10};    check_len("jmp rel8 refused", b, 0); }
    { uint8_t b[] = {0x74,0x10};    check_len("je rel8 refused", b, 0); }
    { uint8_t b[] = {0x0F,0x84,1,2,3,4}; check_len("je rel32 refused", b, 0); }

    /* ...and the refusal has to say *which*. "I do not know this instruction"
       is a gap in this file that someone can close; "this instruction cannot
       move" is a property of the code being patched that no amount of decoder
       work will change. Reporting both as one message sent the last reader
       looking for a missing opcode that was never missing. */
    { uint8_t b[] = {0xE8,1,2,3,4};
      check_why("call rel32 refused as relative", b, AOWL_INSN_RELATIVE); }
    { uint8_t b[] = {0x0F,0x84,1,2,3,4};
      check_why("je rel32 refused as relative", b, AOWL_INSN_RELATIVE); }
    { uint8_t b[] = {0xE2,0x10};
      check_why("loop rel8 refused as relative", b, AOWL_INSN_RELATIVE); }
    /* vaddps %xmm1,%xmm0,%xmm0 -- a VEX prefix, which encodes the opcode map
       and operand size in the prefix itself. Guessing at its length would give
       a plausible wrong answer, so it is refused as unknown rather than sized
       as if the C5 were LDS. */
    { uint8_t b[] = {0xC5,0xF8,0x58,0xC1};
      check_why("AVX (VEX) refused as unknown", b, AOWL_INSN_UNKNOWN); }
    { uint8_t b[] = {0x0F,0x0F,0xC1,0xB4};
      check_why("3DNow! refused as unknown", b, AOWL_INSN_UNKNOWN); }

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
    {
        /* mock_native_hurt's real prologue, byte for byte: pxor, cvtsi2ss,
           mulss, movss. 4+5+4+5 = 18. This is the sequence the engine used to
           refuse outright, and it is what an ordinary float method looks
           like -- so the check is that it is now *accepted*, at a length that
           is a whole number of these instructions. */
        uint8_t b[] = {0x66,0x0F,0xEF,0xC0,
                       0xF3,0x41,0x0F,0x2A,0xC0,
                       0xF3,0x0F,0x59,0xC8,
                       0xF3,0x0F,0x10,0x41,0x10,
                       0xC3};
        int32_t n = aowl_stolen_len(b, AOWL_JMP_SIZE);
        check("accepts a real SSE prologue", n == 18);
    }

    printf("\nwhich refusal it was\n");
    {
        uint8_t b[] = {0x55, 0xE8,1,2,3,4, 0x90,0x90,0x90,0x90,0x90,0x90};
        int32_t why = AOWL_INSN_OK;
        check("a relative branch is reported as one",
              aowl_stolen_len_why(b, AOWL_JMP_SIZE, &why) == 0 &&
              why == AOWL_INSN_RELATIVE);
    }
    {
        uint8_t b[] = {0x55, 0xC5,0xF8,0x58,0xC1, 0x90,0x90,0x90,0x90,0x90};
        int32_t why = AOWL_INSN_OK;
        check("an unknown instruction is reported as one",
              aowl_stolen_len_why(b, AOWL_JMP_SIZE, &why) == 0 &&
              why == AOWL_INSN_UNKNOWN);
    }
    {
        uint8_t b[] = {0x31,0xC0, 0xC3, 0x90,0x90,0x90,0x90,0x90,0x90};
        int32_t why = AOWL_INSN_OK;
        check("a function shorter than the jump is reported as one",
              aowl_stolen_len_why(b, AOWL_JMP_SIZE, &why) == 0 &&
              why == AOWL_INSN_SHORT);
    }
    {
        /* The three refusals must not collapse back into one message. */
        const char* unknown  = aowl_hook_error_text(-2);
        const char* relative = aowl_hook_error_text(-6);
        const char* tooShort = aowl_hook_error_text(-7);
        check("each refusal has its own sentence",
              strcmp(unknown, relative) != 0 &&
              strcmp(relative, tooShort) != 0 &&
              strcmp(unknown, tooShort) != 0);
        check("the relative-branch refusal says so",
              strstr(relative, "relative branch") != NULL);
        check("the unknown-instruction refusal says so",
              strstr(unknown, "does not know") != NULL);
    }

    printf("\nfunctions too short to patch\n");
    {
        /* Shorter than the 14-byte jump. Stealing enough bytes would run past
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
    {
        /* The same, for a two-byte SSE opcode: `mulss disp32(%rip),%xmm0`.
           Loading a float constant is precisely this instruction, so getting
           the displacement offset wrong in the two-byte map would corrupt
           every relocated constant rather than fail. */
        uint8_t src[16] = {0xF3,0x0F,0x59,0x05,0x00,0x01,0x00,0x00};
        uint8_t dst[16];
        memset(dst, 0, sizeof(dst));
        check("an SSE RIP-relative load relocates",
              aowl_copy_relocated(dst, src, 8) == 0);
        int32_t got;
        memcpy(&got, dst + 4, 4);
        int64_t expect = 0x100 + ((int64_t)(intptr_t)src - (int64_t)(intptr_t)dst);
        check("its displacement adjusted by the distance moved",
              (int64_t)got == expect);
    }

    printf("\nhooking a live function\n");
    victim();
    check("the function works before hooking", g_originalCalls == 1);

    void* h = aowl_hook_new();
    check("hook allocated", h != NULL);

    int32_t slot = aowl_hook_attach(h, (void*)victim);
    if (slot < 0) {
        printf("FAIL  attach returned %d (%s)\n", slot, aowl_hook_error_text(slot));
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

    /* ------------------------------------------------------------------ *
     * An SSE prologue, hooked for real
     * ------------------------------------------------------------------ */
    printf("\nhooking a function with an SSE prologue\n");
    show_prologue("sse_victim", (void*)sse_victim);

    uint8_t sseBefore[AOWL_MAX_STOLEN];
    memcpy(sseBefore, (void*)sse_victim, sizeof(sseBefore));

    void* sseHook = aowl_hook_new();
    int32_t sseSlot = aowl_hook_attach(sseHook, (void*)sse_victim);
    if (sseSlot < 0) {
        printf("FAIL  SSE attach refused: %s\n", aowl_hook_error_text(sseSlot));
        failed++;
    } else {
        passed++;
        printf("ok    SSE prologue attached in slot %d (%d bytes stolen)\n",
               sseSlot, aowl_hook_stolen(sseHook));

        /* The original must still run, and run *correctly*: the trampoline
           holds SSE instructions and a relocated constant load, so a decoder
           that got a length wrong would leave the arithmetic subtly off rather
           than crash. The value is what proves the relocation. */
        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_mode[sseSlot] = MODE_PASS;
        g_fired[sseSlot] = 0;
        /* XMM0 is loaded with a value that is not any argument, immediately
           before the call. `sse_victim`'s first parameter is a pointer, so
           position 0 uses RCX and XMM0 is left alone by the call -- which
           makes it a witness. A dispatcher that counted float registers
           separately would look in XMM0 for the first float parameter and
           report 7.25 as `amount`; asserting the *poison* is there rather
           than merely "not 12.5" turns that from a coincidence the test might
           miss into one it cannot. */
        float poison = 7.25f;
        __asm__ volatile ("movss %0, %%xmm0" :: "m"(poison) : "xmm0");
        float left = sse_victim(&g_obj, 12.5f, 2, NULL);
        check("the SSE detour fired", g_fired[sseSlot] == 1);
        check("the original still ran", g_sseCalls == 1);
        check("the original's arithmetic survived relocation",
              left == 75.0f && g_obj.health == 75.0f);

        /* ---------------------------------------------------------------- *
         * Arguments, by position
         *
         * This is the rule the ABI actually uses and the one most likely to
         * be got wrong: position 0 is RCX *or* XMM0, position 1 is RDX *or*
         * XMM1, and which file a position uses is decided by that parameter's
         * declared type -- not by counting integers and floats separately.
         * A decoder that kept two counters would look for `amount` in XMM0,
         * find whatever `this` left there, and report a number that is not
         * any argument at all.
         * ---------------------------------------------------------------- */
        const TestRegs* r = &g_seen[sseSlot];
        check("argument 0 (this) is in RCX",
              int_arg(r, 0) == (uint64_t)(uintptr_t)&g_obj);
        check("argument 1 (a float) is in XMM1, not XMM0",
              float_arg(r, 1) == 12.5f);
        check("argument 2 (an int) is in R8",
              (int32_t)(int_arg(r, 2) & 0xFFFFFFFFu) == 2);
        check("argument 3 (MethodInfo*) is in R9", int_arg(r, 3) == 0);
        /* The negative half of the same fact, and the one that fails if the
           registers are counted per file rather than per position: XMM0 still
           holds what the caller left in it, because position 0 was a pointer
           and went to RCX. */
        check("XMM0 holds the caller's value, not the float argument",
              float_arg(r, 0) == 7.25f);

        /* ---------------------------------------------------------------- *
         * Suppression, float return
         * ---------------------------------------------------------------- */
        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_fired[sseSlot] = 0;
        g_mode[sseSlot] = MODE_SKIP;
        g_replacement[sseSlot] = float_bits(42.5f);
        float replaced = sse_victim(&g_obj, 12.5f, 2, NULL);
        check("the suppressed detour still fired", g_fired[sseSlot] == 1);
        /* Not "ran and had its result overwritten" -- the two are very
           different, and only the side effect can tell them apart. */
        check("the original did not run", g_sseCalls == 0);
        check("nothing the original would have changed changed",
              g_obj.health == 100.0f);
        check("the caller got the replacement in XMM0", replaced == 42.5f);

        check("SSE hook removed", aowl_hook_remove(sseHook) == 0);
        check("the function is byte-identical after unhooking",
              memcmp(sseBefore, (void*)sse_victim, sizeof(sseBefore)) == 0);

        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_fired[sseSlot] = 0;
        float after = sse_victim(&g_obj, 12.5f, 2, NULL);
        check("and behaves exactly as it did before it was ever hooked",
              g_fired[sseSlot] == 0 && g_sseCalls == 1 && after == 75.0f);
    }
    aowl_hook_free(sseHook);

    /* ------------------------------------------------------------------ *
     * Suppression with an integer return
     * ------------------------------------------------------------------ */
    printf("\nsuppressing a function that returns an integer\n");
    show_prologue("int_victim", (void*)int_victim);

    uint8_t intBefore[AOWL_MAX_STOLEN];
    memcpy(intBefore, (void*)int_victim, sizeof(intBefore));

    void* intHook = aowl_hook_new();
    int32_t intSlot = aowl_hook_attach(intHook, (void*)int_victim);
    if (intSlot < 0) {
        printf("FAIL  int attach refused: %s\n", aowl_hook_error_text(intSlot));
        failed++;
    } else {
        passed++;
        printf("ok    attached in slot %d (%d bytes stolen)\n",
               intSlot, aowl_hook_stolen(intHook));

        g_intCalls = 0;
        g_fired[intSlot] = 0;
        g_mode[intSlot] = MODE_PASS;
        int64_t got = int_victim(1, 2, 3, 4);
        check("the detour fired", g_fired[intSlot] == 1);
        check("the original still ran and returned its own answer",
              g_intCalls == 1 && got == 1234);

        /* Four integer arguments, all four positions, all in the integer
           file -- the mirror image of the float case above. */
        const TestRegs* ri = &g_seen[intSlot];
        check("four integer arguments arrive in RCX/RDX/R8/R9 by position",
              int_arg(ri, 0) == 1 && int_arg(ri, 1) == 2 &&
              int_arg(ri, 2) == 3 && int_arg(ri, 3) == 4);

        g_intCalls = 0;
        g_fired[intSlot] = 0;
        g_mode[intSlot] = MODE_SKIP;
        g_replacement[intSlot] = 9999;
        int64_t replaced = int_victim(1, 2, 3, 4);
        check("the suppressed detour fired", g_fired[intSlot] == 1);
        check("the original did not run", g_intCalls == 0);
        check("the caller got the replacement in RAX", replaced == 9999);

        check("int hook removed", aowl_hook_remove(intHook) == 0);
        check("the function is byte-identical after unhooking",
              memcmp(intBefore, (void*)int_victim, sizeof(intBefore)) == 0);

        g_intCalls = 0;
        g_fired[intSlot] = 0;
        check("and runs unhooked exactly as before",
              int_victim(1, 2, 3, 4) == 1234 &&
              g_intCalls == 1 && g_fired[intSlot] == 0);
    }
    aowl_hook_free(intHook);

    /* ------------------------------------------------------------------ *
     * The postfix path
     *
     * Everything above tests a thunk that tail-jumps into the original and
     * never comes back. This tests the other path: the thunk *calls* the
     * original, regains control, and hands the handler what it returned.
     *
     * Three things are checked and each has its own way of being wrong. That
     * the original ran and its own answer reached the caller unchanged -- a
     * postfix that observes nothing must still be bit-for-bit transparent.
     * That the handler was given the return value in the right register: RAX
     * for an integer, XMM0 for a float, two separate slots because reading one
     * as the other yields a number rather than an error. And that a
     * replacement reaches the caller.
     * ------------------------------------------------------------------ */
    printf("\nthe postfix path: calling the original and coming back\n");

    void* postHook = aowl_hook_new();
    /* Armed before attaching, exactly as the host does it: the thunk reads the
       table on entry and the very next call would otherwise take the prefix
       path. */
    aowl_hook_set_postfix(aowl_hook_used(), 1);
    int32_t postSlot = aowl_hook_attach(postHook, (void*)int_victim);
    if (postSlot < 0) {
        printf("FAIL  postfix attach refused: %s\n",
               aowl_hook_error_text(postSlot));
        failed++;
    } else {
        passed++;
        printf("ok    attached in slot %d (%d bytes stolen)\n",
               postSlot, aowl_hook_stolen(postHook));
        check("the slot reports itself as a postfix",
              aowl_hook_is_postfix(postSlot) == 1);

        g_intCalls = 0;
        g_fired[postSlot] = 0;
        g_postFired[postSlot] = 0;
        g_postMode[postSlot] = MODE_PASS;
        int64_t got = int_victim(1, 2, 3, 4);
        check("the postfix dispatcher fired, and the prefix one did not",
              g_postFired[postSlot] == 1 && g_fired[postSlot] == 0);
        check("the original ran", g_intCalls == 1);
        check("an untouched postfix is transparent: the caller got 1234",
              got == 1234);
        check("the handler was given the original's integer return",
              g_postSeen[postSlot].ret == 1234);
        check("and still the arguments the method was entered with",
              int_arg(&g_postSeen[postSlot], 0) == 1 &&
              int_arg(&g_postSeen[postSlot], 3) == 4);

        g_intCalls = 0;
        g_postFired[postSlot] = 0;
        g_postMode[postSlot] = MODE_SKIP;
        g_postReplacement[postSlot] = 4321;
        int64_t replaced = int_victim(1, 2, 3, 4);
        check("a replacing postfix still let the original run",
              g_intCalls == 1 && g_postFired[postSlot] == 1);
        check("and the caller got the replacement instead", replaced == 4321);

        check("postfix hook removed", aowl_hook_remove(postHook) == 0);
        aowl_hook_set_postfix(postSlot, 0);
        check("the function is byte-identical after unhooking",
              memcmp(intBefore, (void*)int_victim, sizeof(intBefore)) == 0);
    }
    aowl_hook_free(postHook);

    /* The float half. `sse_victim` returns in XMM0, so the postfix frame has to
       carry that separately from RAX -- one return slot would have made the
       integer test above pass and this one report register residue. */
    printf("\na postfix on a function that returns in XMM0\n");
    void* postF = aowl_hook_new();
    aowl_hook_set_postfix(aowl_hook_used(), 1);
    int32_t postFSlot = aowl_hook_attach(postF, (void*)sse_victim);
    if (postFSlot < 0) {
        printf("FAIL  postfix attach refused: %s\n",
               aowl_hook_error_text(postFSlot));
        failed++;
    } else {
        passed++;
        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_postFired[postFSlot] = 0;
        g_postMode[postFSlot] = MODE_PASS;
        float got = sse_victim(&g_obj, 10.0f, 2, NULL);
        check("the original ran and its float return reached the caller",
              g_sseCalls == 1 && got == 80.0f);
        {
            uint32_t low = (uint32_t)g_postSeen[postFSlot].retf;
            float seen;
            memcpy(&seen, &low, sizeof(seen));
            check("the handler was given that float out of XMM0, not RAX",
                  seen == 80.0f);
        }

        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_postMode[postFSlot] = MODE_SKIP;
        g_postReplacement[postFSlot] = float_bits(1.5f);
        float replaced = sse_victim(&g_obj, 10.0f, 2, NULL);
        check("the original still ran and its side effect stands",
              g_sseCalls == 1 && g_obj.health == 80.0f);
        check("but the caller got the replacement in XMM0", replaced == 1.5f);

        check("postfix hook removed", aowl_hook_remove(postF) == 0);
        aowl_hook_set_postfix(postFSlot, 0);
    }
    aowl_hook_free(postF);

    /* ------------------------------------------------------------------ *
     * The typed frame, over the same two victims
     *
     * Everything above is the JSON path's plumbing: the thunk saves registers
     * and the dispatcher is handed a `void*`. The typed path hands that same
     * pointer to a *mod*, wrapped in a frame that says which slot is which,
     * and the question is whether a mod reading it gets the arguments the
     * method was called with -- and nothing else.
     *
     * Four things are checked and each fails differently: that an untouched
     * typed hook is bit-for-bit transparent, that arguments come back by index
     * and by declared kind with the instance shift applied, that the integer
     * and the float return are two separate slots, and that a frame read after
     * its handler returned is refused rather than answered.
     * ------------------------------------------------------------------ */
    printf("\nthe typed frame: a prefix\n");

    /* `sse_victim` as IL2CPP would declare it: an instance method taking
       (float, int32). `this` is not a declared parameter -- it is position 0 --
       and the trailing MethodInfo* is not one either. */
    static const uint8_t sseKinds[2] = { AOWLSPT_ARG_FLOAT, AOWLSPT_ARG_INT };
    /* `int_victim` as a static taking four integers: positions 0-3, all in the
       integer file, which is the mirror image. */
    static const uint8_t intKinds[4] = { AOWLSPT_ARG_INT, AOWLSPT_ARG_INT,
                                         AOWLSPT_ARG_INT, AOWLSPT_ARG_INT };

    void* tHook = aowl_hook_new();
    int32_t tSlot = aowl_hook_attach(tHook, (void*)sse_victim);
    if (tSlot < 0) {
        printf("FAIL  typed attach refused: %s\n", aowl_hook_error_text(tSlot));
        failed++;
    } else {
        passed++;
        g_typed[tSlot] = TYPED_WATCH;
        g_typedKinds[tSlot] = sseKinds;
        g_typedArgc[tSlot] = 2;
        g_typedRet[tSlot] = AOWLSPT_ARG_FLOAT;
        g_typedFlags[tSlot] = 0;   /* an instance method */

        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_typedFired[tSlot] = 0;
        g_tSetOk = 0;
        float got = sse_victim(&g_obj, 12.5f, 2, NULL);
        check("the typed handler fired", g_typedFired[tSlot] == 1);
        check("an untouched typed prefix is bit-for-bit transparent",
              g_sseCalls == 1 && got == 75.0f && g_obj.health == 75.0f);
        check("`this` came through as the object's own address",
              g_tSelf == (uint64_t)(uintptr_t)&g_obj);
        /* The instance shift: declared parameter 0 is register position 1, so
           a frame that forgot `this` would read the caller's XMM0 -- 7.25f in
           the JSON test above -- rather than 12.5f. */
        check("declared argument 0 is the float, out of XMM1",
              g_tArgFOk == 1 && g_tArgF == 12.5);
        check("declared argument 1 is the int, out of R8",
              g_tArgIOk == 1 && g_tArgI == 2);
        /* And the kind check, which is the whole reason the shapes travel with
           the frame: reading the float slot as an integer must be refused,
           because it would answer a number. */
        check("reading the float argument as an integer is refused",
              g_tArgsOk[0] == 0);
        check("and reading past the declared parameters is refused",
              g_tArgsOk[2] == 0 && g_tArgsOk[3] == 0);
        check("a prefix frame has no result, and says so rather than zeroing",
              g_tRetFOk == 0 && g_tRetIWhy == AOWL_FRAME_NOTPOST);

        /* The refusal that matters most: the frame outliving its handler. */
        {
            int okAfter = 1;
            int32_t argcAfter = aowl_frame_argc(g_tKeptFrame);
            uint64_t selfAfter = aowl_frame_self(g_tKeptFrame);
            double fAfter = aowl_frame_flt(g_tKeptFrame, 0, &okAfter);
            int32_t why = aowl_frame_why();
            check("the frame was live inside the handler", g_tKeptArgc == 2);
            check("and reading it afterwards is refused, not answered",
                  argcAfter == 0 && selfAfter == 0 && okAfter == 0 &&
                  fAfter == 0.0);
            check("with the reason naming that specific mistake",
                  why == AOWL_FRAME_EXPIRED &&
                  strstr(aowl_frame_why_text(why), "must not be stored") != NULL);
            check("and a replacement written to a dead frame is refused too",
                  aowl_frame_set_ret_flt(g_tKeptFrame, 1.0) == 0);
        }

        /* Suppression through the typed setter. `set_ret_flt` writes the low
           32 bits, because the declared return is `System.Single` -- writing
           64 would leave XMM0 holding a denormal rather than 42.5f. */
        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_typed[tSlot] = TYPED_REPLACE;
        g_typedReplF[tSlot] = 42.5;
        float replaced = sse_victim(&g_obj, 12.5f, 2, NULL);
        check("the typed setter reported that it had written", g_tSetOk == 1);
        check("the original did not run", g_sseCalls == 0);
        check("and the caller got the replacement in XMM0", replaced == 42.5f);

        /* A kind the return is not. The setter must refuse rather than write
           an integer where a float will be read: a handler that claims a
           replacement it could not make suppresses the original and hands back
           register residue, which is the worst outcome on this path. */
        g_typed[tSlot] = TYPED_OFF;
        check("int hook removed", aowl_hook_remove(tHook) == 0);
        check("the function is byte-identical after unhooking",
              memcmp(sseBefore, (void*)sse_victim, sizeof(sseBefore)) == 0);
    }
    aowl_hook_free(tHook);

    printf("\nthe typed frame: a postfix, and two separate return slots\n");
    void* tPost = aowl_hook_new();
    aowl_hook_set_postfix(aowl_hook_used(), 1);
    int32_t tpSlot = aowl_hook_attach(tPost, (void*)int_victim);
    if (tpSlot < 0) {
        printf("FAIL  typed postfix attach refused: %s\n",
               aowl_hook_error_text(tpSlot));
        failed++;
    } else {
        passed++;
        g_typed[tpSlot] = TYPED_WATCH;
        g_typedKinds[tpSlot] = intKinds;
        g_typedArgc[tpSlot] = 4;
        g_typedRet[tpSlot] = AOWLSPT_ARG_INT;
        g_typedFlags[tpSlot] = AOWL_FRAME_F_STATIC;

        g_intCalls = 0;
        g_typedFired[tpSlot] = 0;
        int64_t got = int_victim(1, 2, 3, 4);
        check("the typed postfix fired after the original",
              g_typedFired[tpSlot] == 1 && g_intCalls == 1);
        check("an untouched typed postfix is bit-for-bit transparent",
              got == 1234);
        check("the frame said it was a postfix", g_tPostfix == 1);
        check("a static method's four arguments are positions 0-3",
              g_tArgsOk[0] && g_tArgsOk[1] && g_tArgsOk[2] && g_tArgsOk[3] &&
              g_tArgs[0] == 1 && g_tArgs[1] == 2 &&
              g_tArgs[2] == 3 && g_tArgs[3] == 4);
        check("and a static method has no `this`", g_tSelf == 0);
        /* The two return slots. RAX carries 1234; XMM0 carries whatever the
           original left, which is not it -- so a frame with one return slot
           would have this pass and the float case below report residue. */
        check("the integer return came out of RAX",
              g_tRetIOk == 1 && g_tRetI == 1234);
        check("and reading it as a float is refused, not reinterpreted",
              g_tRetFOk == 0);

        g_intCalls = 0;
        g_typed[tpSlot] = TYPED_REPLACE;
        g_typedReplI[tpSlot] = 4321;
        int64_t replaced = int_victim(1, 2, 3, 4);
        check("a replacing typed postfix still let the original run",
              g_intCalls == 1);
        check("and the caller got the replacement in RAX", replaced == 4321);

        g_typed[tpSlot] = TYPED_OFF;
        check("typed postfix hook removed", aowl_hook_remove(tPost) == 0);
        aowl_hook_set_postfix(tpSlot, 0);
        check("the function is byte-identical after unhooking",
              memcmp(intBefore, (void*)int_victim, sizeof(intBefore)) == 0);
    }
    aowl_hook_free(tPost);

    /* The float return, on the same postfix machinery. This is the half that
       fails if the frame carries one return slot instead of two. */
    printf("\na typed postfix on a function that returns in XMM0\n");
    void* tPostF = aowl_hook_new();
    aowl_hook_set_postfix(aowl_hook_used(), 1);
    int32_t tpfSlot = aowl_hook_attach(tPostF, (void*)sse_victim);
    if (tpfSlot < 0) {
        printf("FAIL  typed float postfix refused: %s\n",
               aowl_hook_error_text(tpfSlot));
        failed++;
    } else {
        passed++;
        g_typed[tpfSlot] = TYPED_WATCH;
        g_typedKinds[tpfSlot] = sseKinds;
        g_typedArgc[tpfSlot] = 2;
        g_typedRet[tpfSlot] = AOWLSPT_ARG_FLOAT;
        g_typedFlags[tpfSlot] = 0;

        g_obj.health = 100.0f;
        g_sseCalls = 0;
        float got = sse_victim(&g_obj, 10.0f, 2, NULL);
        check("the original ran and its float return reached the caller",
              g_sseCalls == 1 && got == 80.0f);
        check("the handler was given that float out of XMM0, not RAX",
              g_tRetFOk == 1 && g_tRetF == 80.0);
        check("and reading the float return as an integer is refused",
              g_tRetIOk == 0);
        /* Still the entry arguments, after the original has had its way with
           everything else. */
        check("and still the arguments the method was entered with",
              g_tArgFOk == 1 && g_tArgF == 10.0 && g_tArgI == 2);

        g_obj.health = 100.0f;
        g_sseCalls = 0;
        g_typed[tpfSlot] = TYPED_REPLACE;
        g_typedReplF[tpfSlot] = 1.5;
        float replaced = sse_victim(&g_obj, 10.0f, 2, NULL);
        check("the original still ran and its side effect stands",
              g_sseCalls == 1 && g_obj.health == 80.0f);
        check("but the caller got the typed replacement in XMM0",
              replaced == 1.5f);

        g_typed[tpfSlot] = TYPED_OFF;
        check("typed float postfix removed", aowl_hook_remove(tPostF) == 0);
        aowl_hook_set_postfix(tpfSlot, 0);
    }
    aowl_hook_free(tPostF);

    printf("\n%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
