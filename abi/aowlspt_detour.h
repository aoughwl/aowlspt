/* aowlspt_detour.h — x64 inline hooks, for `AowlHostApi.patch`.
 *
 * Harmony patches a managed method by rewriting IL. There is no IL in an
 * IL2CPP build, so the equivalent here is a code detour: overwrite the first
 * instructions of the compiled function with a jump to our own, and keep the
 * instructions we overwrote in a trampoline so the original can still run.
 *
 * Two notes before the mechanism, because both are easy to get wrong in ways
 * that only show up as a crash somewhere else.
 *
 * **Why not just swap `MethodInfo.methodPointer`.** It is a field, and writing
 * it is trivial. But only reflective dispatch reads it — IL2CPP compiles a
 * direct call site into a direct `call`, so a pointer swap intercepts
 * `il2cpp_runtime_invoke` and nothing the game itself does. That is worse than
 * useless: it would appear to work in a test and never fire in a raid. So the
 * code gets patched and `methodPointer` is left alone.
 *
 * **Why there is a length decoder below.** The jump needs `AOWL_JMP_SIZE`
 * bytes, and x64 instructions are variable length, so the bytes being
 * overwritten have to be decoded to find a whole number of them. Copying a
 * partial instruction into the trampoline produces garbage that then executes.
 *
 * The decoder refuses anything it does not recognise rather than guessing a
 * length. A refused patch is an error a mod author can read. A guessed length
 * is a corrupted game.
 *
 * "Conservative" is not the same as "small", though, and it was small for a
 * while in a way that made it useless. It covered the one-byte map and a
 * handful of two-byte opcodes, which is the prologue of a function that does
 * integer work -- and almost nothing in a Unity game does integer work. An
 * ordinary method opens `pxor`/`cvtsi2ss`/`mulss`/`movss`, all of it in the
 * two-byte map, and every one of those was refused. So the two-byte map is
 * covered properly: the mandatory prefixes, the three-byte escapes, and the
 * opcodes that carry an immediate, which is the one fact a length decoder
 * cannot get from the ModRM byte.
 *
 * RIP-relative instructions encode a displacement from their own address, so
 * copying one into a trampoline silently changes where it points. They are
 * also extremely common in a prologue — `mov eax, [rip+off]` is how any access
 * to a global compiles — so refusing them would refuse most real functions.
 * They are relocated instead: the displacement is adjusted by the distance the
 * instruction moved, and the patch is refused if the result no longer fits in
 * 32 bits.
 *
 * Relative branches (`call rel32`, `jmp rel8/32`, `jcc`, `loop`) are still
 * refused. They could be rewritten too, but they are rare this early in a
 * function, and a refusal a mod author can read beats a rewrite nobody has
 * checked.
 *
 * The refusals are kept apart from each other on purpose. "I do not know this
 * instruction", "I know it and it cannot move", and "the function is shorter
 * than the jump" are three different problems -- the first is a gap in this
 * file, the second is a fact about the target that will never change, and the
 * third is neither -- and a single message listing all three tells the reader
 * only that something went wrong. See `aowl_hook_error_text`.
 */

#ifndef AOWLSPT_DETOUR_H
#define AOWLSPT_DETOUR_H

#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AOWL_JMP_SIZE 14   /* jmp [rip+0] ; qword dest */
#define AOWL_MAX_STOLEN 32

typedef struct AowlHook {
    void*   target;                       /* the function that was patched   */
    void*   detour;                       /* what it now jumps to            */
    void*   trampoline;                   /* stolen bytes + jump back        */
    uint8_t original[AOWL_MAX_STOLEN];    /* for unpatching                  */
    int32_t stolen;                       /* how many bytes were replaced    */
    int32_t installed;
} AowlHook;

/* ------------------------------------------------------------------ *
 * Instruction length
 * ------------------------------------------------------------------ */

/* Why a decode produced no length.
 *
 * "I do not know this instruction" and "I know it and it cannot move" are
 * different failures with different answers -- the first is a decoder gap to
 * be filled, the second is a property of the code being patched that no amount
 * of decoder work will change -- so they are reported apart. A single "could
 * not be relocated" message sent every report of both down the wrong path. */
#define AOWL_INSN_OK        0
#define AOWL_INSN_UNKNOWN   1   /* not in this decoder's tables            */
#define AOWL_INSN_RELATIVE  2   /* decoded, but its operand is a relative
                                   displacement, so moving it moves where it
                                   goes                                    */
#define AOWL_INSN_SHORT     3   /* not an instruction property: the function
                                   ends before the jump would fit           */
#define AOWL_INSN_FAR       4   /* a RIP-relative disp32 no longer reaches   */

/* The result of decoding one instruction. `len` is 0 when this decoder does
 * not recognise the instruction or cannot relocate it, and `why` says which.
 * `ripDisp` is the offset within the instruction of a RIP-relative disp32, or
 * -1 when there is none. */
typedef struct AowlInsn {
    int32_t len;
    int32_t ripDisp;
    int32_t terminal;   /* the instruction ends the function (ret) */
    int32_t why;        /* AOWL_INSN_* -- meaningful only when len == 0 */
} AowlInsn;

static AowlInsn aowl_insn(const uint8_t* p) {
    AowlInsn out;
    out.len = 0;
    out.ripDisp = -1;
    out.terminal = 0;
    out.why = AOWL_INSN_UNKNOWN;

    int32_t i = 0;
    int32_t opsize = 4;       /* operand size, which is also the size of an
                                 immediate for the forms that take a full one */
    int32_t immBytes = 0;     /* immediate trailing the ModRM operand         */
    int rexW = 0;

    /* Legacy prefixes.
     *
     * 66/F2/F3 are counted here as prefixes because that is what they cost in
     * bytes, which is all this loop is for. In the two-byte map they are also
     * *mandatory prefixes* -- they select which instruction `0F 58` is, rather
     * than modifying one -- but they never change its length, so the two-byte
     * decoder below can ignore them. 66 does change the length of a one-byte
     * form that carries a full immediate, which is why it sets `opsize`. */
    for (;;) {
        uint8_t b = p[i];
        if (b == 0x66) { opsize = 2; i++; continue; }
        if (b == 0x67 || b == 0x2E || b == 0x3E || b == 0x26 ||
            b == 0x36 || b == 0x64 || b == 0x65 || b == 0xF0 ||
            b == 0xF2 || b == 0xF3) { i++; continue; }
        break;
    }

    /* REX, which must be the last prefix before the opcode. */
    if ((p[i] & 0xF0) == 0x40) {
        rexW = (p[i] & 0x08) != 0;
        i++;
    }

    /* VEX (C4/C5) and EVEX (62) introduce a different encoding entirely: the
     * prefix carries the opcode map and the operand size, and guessing at one
     * would produce a plausible-looking wrong length. Refused by name so the
     * report says "AVX", not "unknown byte". A prologue built by MSVC for
     * IL2CPP is SSE2, so this is a gap rather than a wall -- but it is a gap
     * that must be visible. */
    if (p[i] == 0xC4 || p[i] == 0xC5 || p[i] == 0x62) {
        /* C4/C5 are also LES/LDS, which do not exist in 64-bit mode, and 62 is
         * BOUND, likewise. So in 64-bit code these bytes can only be VEX/EVEX
         * and there is nothing to disambiguate. */
        return out;
    }

    uint8_t op = p[i++];

    /* ------------------------------------------------------------------
     * The two-byte map.
     *
     * This is where SSE lives, and SSE is most of what a real IL2CPP method
     * does: `pxor`, `cvtsi2ss`, `mulss`, `movss` -- an ordinary float method's
     * whole prologue. The map is covered by shape (ModRM? immediate?) rather
     * than opcode by opcode, because the shape is what the length depends on
     * and enumerating four hundred mnemonics to recover four facts is how a
     * table acquires a hole. ------------------------------------------------ */
    if (op == 0x0F) {
        uint8_t op2 = p[i++];

        /* jcc rel32. Knowable length, unmovable operand. */
        if (op2 >= 0x80 && op2 <= 0x8F) {
            out.why = AOWL_INSN_RELATIVE;
            return out;
        }

        /* Three-byte escapes. `0F 38 xx` (pshufb, pcmpeqq, the SSSE3/SSE4.1
         * bulk) is ModRM with no immediate; `0F 3A xx` (roundss, pblendw,
         * palignr) is ModRM plus an imm8. Two whole maps, two facts. */
        if (op2 == 0x38) { i++; immBytes = 0; goto modrm; }
        if (op2 == 0x3A) { i++; immBytes = 1; goto modrm; }

        /* Forms whose length is not a function of the opcode alone.
         *   0F 0F -- 3DNow!, where the trailing imm8 *is* the opcode.
         *   0F 78/79 -- vmread/vmwrite normally, but extrq/insertq under a 66
         *               or F2 prefix, and those carry two imm8s.
         * Neither is anything a compiler emits into a method prologue; both
         * are refused rather than sized by a rule that is right most of the
         * time. */
        if (op2 == 0x0F || op2 == 0x78 || op2 == 0x79) return out;

        /* No ModRM byte: nullary or fixed-register forms. */
        if (op2 == 0x05 || op2 == 0x06 || op2 == 0x07 ||   /* syscall/clts/sysret */
            op2 == 0x08 || op2 == 0x09 || op2 == 0x0B ||   /* invd/wbinvd/ud2     */
            op2 == 0x0E ||                                  /* femms               */
            (op2 >= 0x30 && op2 <= 0x37) ||                 /* rdtsc & friends     */
            op2 == 0x77 ||                                  /* emms                */
            (op2 >= 0xA0 && op2 <= 0xA2) ||                 /* push/pop fs, cpuid  */
            (op2 >= 0xA8 && op2 <= 0xAA) ||                 /* push/pop gs, rsm    */
            (op2 >= 0xC8 && op2 <= 0xCF)) {                 /* bswap               */
            out.len = i;
            out.why = AOWL_INSN_OK;
            return out;
        }

        /* ModRM plus an imm8. In the two-byte map an immediate is always one
         * byte -- there is no `66`-sized immediate here, which is why `opsize`
         * plays no part below. */
        if ((op2 >= 0x70 && op2 <= 0x73) ||                 /* pshufd/psrlw group  */
            op2 == 0xA4 || op2 == 0xAC ||                   /* shld/shrd imm8      */
            op2 == 0xBA ||                                  /* bt/bts/btr/btc imm8 */
            op2 == 0xC2 ||                                  /* cmpps/cmpss         */
            op2 == 0xC4 || op2 == 0xC5 ||                   /* pinsrw/pextrw       */
            op2 == 0xC6) {                                  /* shufps/shufpd       */
            immBytes = 1;
            goto modrm;
        }

        /* Everything else that is defined: ModRM, no immediate. Written as
         * ranges over the map rather than as a default, so a byte that is not
         * a defined two-byte opcode is refused instead of being handed a
         * length -- an undefined opcode inside a prologue means the decoder
         * has already lost its place, and continuing from there is how a
         * trampoline ends up holding half an instruction. */
        if (op2 <= 0x03 ||                                  /* sldt/lar/lsl        */
            op2 == 0x0D ||                                  /* prefetch            */
            (op2 >= 0x10 && op2 <= 0x23) ||                 /* movups..endbr64..mov cr */
            (op2 >= 0x28 && op2 <= 0x2F) ||                 /* movaps, cvt*, comiss */
            (op2 >= 0x40 && op2 <= 0x6F) ||                 /* cmovcc, the SSE bulk */
            (op2 >= 0x74 && op2 <= 0x76) ||                 /* pcmpeq              */
            (op2 >= 0x7C && op2 <= 0x7F) ||                 /* haddps/movd/movdqa  */
            (op2 >= 0x90 && op2 <= 0x9F) ||                 /* setcc               */
            op2 == 0xA3 || op2 == 0xA5 || op2 == 0xAB ||    /* bt/shld cl/bts      */
            (op2 >= 0xAD && op2 <= 0xB9) ||                 /* shrd cl..popcnt     */
            (op2 >= 0xBB && op2 <= 0xC1) ||                 /* btc..movsx..xadd    */
            op2 == 0xC3 || op2 == 0xC7 ||                   /* movnti/cmpxchg16b   */
            op2 >= 0xD0) {                                  /* the packed-integer bulk */
            immBytes = 0;
            goto modrm;
        }
        return out;
    }

    /* ------------------------------------------------------------------
     * The one-byte map.
     * ------------------------------------------------------------------ */

    /* Relative branches: the length is knowable, but relocating one would
     * change where it goes, so no length is reported. */
    if (op == 0xE8 || op == 0xE9 || op == 0xEB ||          /* call/jmp rel   */
        (op >= 0x70 && op <= 0x7F) ||                      /* jcc rel8       */
        op == 0xE0 || op == 0xE1 || op == 0xE2 ||          /* loopcc         */
        op == 0xE3) {                                      /* jrcxz          */
        out.why = AOWL_INSN_RELATIVE;
        return out;
    }

    /* No ModRM, no immediate. */
    if ((op >= 0x50 && op <= 0x5F) ||                      /* push/pop r64   */
        op == 0x90 || op == 0x99 || op == 0x98 ||          /* nop/cqo/cdqe   */
        op == 0x9C || op == 0x9D ||                        /* pushf/popf     */
        op == 0xC9 || op == 0xCC || op == 0xF4 ||          /* leave/int3/hlt */
        (op >= 0xF8 && op <= 0xFD)) {                      /* clc..std       */
        out.len = i;
        out.why = AOWL_INSN_OK;
        return out;
    }
    if (op == 0xC3) { out.terminal = 1; out.len = i; out.why = AOWL_INSN_OK; return out; }
    if (op == 0xC2) { out.terminal = 1; out.len = i + 2; out.why = AOWL_INSN_OK; return out; }

    /* No ModRM, immediate. */
    if (op >= 0xB8 && op <= 0xBF) {                        /* mov r, imm     */
        out.len = i + (rexW ? 8 : (opsize == 2 ? 2 : 4));
        out.why = AOWL_INSN_OK;
        return out;
    }
    if (op >= 0xB0 && op <= 0xB7) { out.len = i + 1; out.why = AOWL_INSN_OK; return out; }
    if (op == 0x68) { out.len = i + 4; out.why = AOWL_INSN_OK; return out; }  /* push imm32 */
    if (op == 0x6A) { out.len = i + 1; out.why = AOWL_INSN_OK; return out; }  /* push imm8  */
    if (op == 0xA8) { out.len = i + 1; out.why = AOWL_INSN_OK; return out; }  /* test al,imm8 */
    if (op == 0xA9) { out.len = i + (opsize == 2 ? 2 : 4); out.why = AOWL_INSN_OK; return out; }
    /* The accumulator forms of the ALU group: `add al, imm8` (op&7 == 4) and
     * `add eax, imm32` (op&7 == 5). No ModRM, which is exactly why they are
     * easy to leave out and then mis-size as if they had one. */
    if (op <= 0x3D && (op & 0x07) == 0x04) { out.len = i + 1; out.why = AOWL_INSN_OK; return out; }
    if (op <= 0x3D && (op & 0x07) == 0x05) {
        out.len = i + (opsize == 2 ? 2 : 4);
        out.why = AOWL_INSN_OK;
        return out;
    }

    /* ModRM. */
    if ((op <= 0x3B && (op & 0x07) <= 0x03) ||             /* alu r/m, r     */
        op == 0x63 ||                                      /* movsxd         */
        (op >= 0x84 && op <= 0x8B) ||                      /* test/xchg/mov  */
        op == 0x8D || op == 0x8F ||                        /* lea / pop r/m  */
        (op >= 0xD0 && op <= 0xD3) ||                      /* shift by 1/cl  */
        op == 0xFE || op == 0xFF) {                        /* inc/dec/call/jmp r/m */
        immBytes = 0;
        goto modrm;
    }
    if (op == 0x80 || op == 0x83 || op == 0x6B ||          /* alu/imul imm8  */
        op == 0xC0 || op == 0xC1 || op == 0xC6) {          /* shift/mov imm8 */
        immBytes = 1;
        goto modrm;
    }
    if (op == 0x81 || op == 0x69 || op == 0xC7) {          /* alu/imul/mov imm */
        immBytes = (opsize == 2 ? 2 : 4);
        goto modrm;
    }
    /* The group-3 trap: `F7 /0` and `F7 /1` are `test r/m, imm32` and carry a
     * full immediate, while `/2` through `/7` (not, neg, mul, imul, div, idiv)
     * carry none. A decoder that sizes the whole opcode the same way is wrong
     * by four bytes on one of the commonest instructions in existence, and the
     * error is silent -- it just steals four bytes too many or too few. */
    if (op == 0xF6 || op == 0xF7) {
        uint8_t reg = (uint8_t)((p[i] >> 3) & 0x07);
        if (reg <= 1) immBytes = (op == 0xF6) ? 1 : (opsize == 2 ? 2 : 4);
        else immBytes = 0;
        goto modrm;
    }

    return out;

modrm: {
        uint8_t modrm = p[i++];
        uint8_t mod = modrm >> 6;
        uint8_t rm  = modrm & 0x07;
        uint8_t sibBase = 0xFF;

        if (mod != 3 && rm == 4) {                     /* SIB */
            sibBase = p[i] & 0x07;
            i++;
        }

        if (mod == 1) {
            i += 1;
        } else if (mod == 2) {
            i += 4;
        } else if (mod == 0) {
            if (rm == 5) {
                /* RIP-relative. Note where the displacement is so the copier
                 * can fix it up, then keep going for the length. */
                out.ripDisp = i;
                i += 4;
            } else if (rm == 4 && sibBase == 5) {
                i += 4;                                /* disp32, no base */
            }
        }

        /* The immediate comes last, after any displacement. A RIP-relative
         * displacement is measured from the end of the *whole* instruction,
         * immediate included -- which is why `ripDisp` is an offset and not a
         * value, and why the copier corrects it by the distance moved rather
         * than by anything derived from the length. */
        i += immBytes;

        out.len = i;
        out.why = AOWL_INSN_OK;
        return out;
    }
}

/* Length only. The tests check lengths; the copier needs the whole record. */
static int32_t aowl_insn_len(const uint8_t* p) {
    return aowl_insn(p).len;
}

/* How many whole instructions must be taken to cover `need` bytes.
 *
 * Returns 0 if a `ret` is reached first. That is not a decoder limitation but
 * the most dangerous case there is: the function is shorter than the jump, so
 * stealing enough bytes would run off its end into whatever the linker put
 * next. The hook would then overwrite an unrelated function and the trampoline
 * would jump into the middle of one. It presents as a crash a long way from
 * the patch, which is exactly why it is checked here.
 *
 * `why` receives an AOWL_INSN_* code on refusal, so the report can say which
 * of the three refusals this was rather than offering the caller all of them
 * and leaving them to guess. It is untouched on success.
 */
static int32_t aowl_stolen_len_why(const uint8_t* p, int32_t need, int32_t* why) {
    int32_t total = 0;
    while (total < need) {
        AowlInsn in = aowl_insn(p + total);
        if (in.len <= 0) {
            if (why) *why = in.why;
            return 0;
        }
        if (total + in.len > AOWL_MAX_STOLEN) {
            /* Not a decode failure: the prologue decodes fine, it is simply
             * longer than the trampoline is willing to hold. Reported as
             * "unknown" would be a lie, so it gets the length refusal. */
            if (why) *why = AOWL_INSN_SHORT;
            return 0;
        }
        total += in.len;
        if (in.terminal && total < need) {
            if (why) *why = AOWL_INSN_SHORT;
            return 0;
        }
    }
    return total;
}

static int32_t aowl_stolen_len(const uint8_t* p, int32_t need) {
    int32_t why = AOWL_INSN_OK;
    return aowl_stolen_len_why(p, need, &why);
}

/* Copies instructions from `src` to `dst`, rewriting the displacement of every
 * RIP-relative one so it still points where it did. Returns 0, or -1 if a
 * displacement no longer fits in 32 bits — which happens when the trampoline
 * lands more than 2 GB from the function the bytes came from. */
static int32_t aowl_copy_relocated(uint8_t* dst, const uint8_t* src, int32_t bytes) {
    int32_t at = 0;
    while (at < bytes) {
        AowlInsn in = aowl_insn(src + at);
        if (in.len <= 0) return -1;
        memcpy(dst + at, src + at, (size_t)in.len);
        if (in.ripDisp >= 0) {
            int32_t oldDisp;
            memcpy(&oldDisp, src + at + in.ripDisp, 4);
            /* The displacement is measured from the end of the instruction.
             * Both the instruction and its end moved by the same distance, so
             * the correction is exactly that distance. */
            int64_t delta = (int64_t)(intptr_t)(src + at) -
                            (int64_t)(intptr_t)(dst + at);
            int64_t newDisp = (int64_t)oldDisp + delta;
            if (newDisp > 2147483647LL || newDisp < -2147483648LL) return -1;
            int32_t nd = (int32_t)newDisp;
            memcpy(dst + at + in.ripDisp, &nd, 4);
        }
        at += in.len;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Installing
 * ------------------------------------------------------------------ */

static void aowl_write_jmp_abs(uint8_t* at, void* dest) {
    /* jmp qword ptr [rip+0] ; <dest>  -- 14 bytes, and **clobbers nothing**.
     *
     * The obvious encoding is `mov rax, imm64 ; jmp rax`, which is two bytes
     * shorter and wrong in a way that is invisible until it is not. The
     * trampoline ends with this jump, immediately after the stolen instructions
     * -- and a stolen prologue very often leaves a value in RAX that the rest
     * of the function still needs. `void f(void) { counter++; }` compiles to
     * `mov eax,[rip+x] ; add eax,1 ; mov [rip+x],eax`, the first twelve bytes
     * of which get stolen, so the jump back would overwrite the incremented
     * value with its own jump target and the store would write a pointer
     * fragment into the counter.
     *
     * The rel32 form (`e9`) is smaller still and only reaches +/-2 GB, which a
     * DLL loaded far from the game image cannot rely on. This form reaches
     * anywhere, touches no register, and costs two bytes. */
    at[0] = 0xFF; at[1] = 0x25;
    at[2] = 0x00; at[3] = 0x00; at[4] = 0x00; at[5] = 0x00;
    memcpy(at + 6, &dest, 8);
}

/* Executable memory within +/-2 GB of `near`.
 *
 * This is not an optimisation. The stolen instructions can be RIP-relative,
 * and their displacements are 32-bit — so if the trampoline lands further than
 * 2 GB from the function the bytes came from, no correction fits and the patch
 * has to be refused. A plain `VirtualAlloc(NULL, ...)` puts it wherever it
 * likes, which on a 64-bit process is usually far too far.
 *
 * So the address space is walked outward from the target in allocation-
 * granularity steps, trying to reserve at each free region until one takes.
 */
static void* aowl_alloc_near(void* anchor, size_t size) {
    /* `near` would be the obvious name; windef.h still defines it as a macro
     * for 16-bit compatibility, so it cannot be a parameter. */
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const uintptr_t gran = si.dwAllocationGranularity ?
                           si.dwAllocationGranularity : 0x10000;
    const uintptr_t base = (uintptr_t)anchor;
    const uintptr_t limit = 0x7FFF0000u;   /* stay comfortably inside 2 GB */

    for (uintptr_t delta = gran; delta < limit; delta += gran) {
        /* Above first: the region after a function is more often free than the
         * one before it, which tends to hold the rest of the module. */
        uintptr_t up = (base + delta) & ~(gran - 1);
        void* p = VirtualAlloc((void*)up, size, MEM_COMMIT | MEM_RESERVE,
                               PAGE_EXECUTE_READWRITE);
        if (p) return p;

        if (base > delta) {
            uintptr_t down = (base - delta) & ~(gran - 1);
            p = VirtualAlloc((void*)down, size, MEM_COMMIT | MEM_RESERVE,
                             PAGE_EXECUTE_READWRITE);
            if (p) return p;
        }
    }
    return NULL;
}

static void* aowl_hook_new(void) { return calloc(1, sizeof(AowlHook)); }
static void  aowl_hook_free(void* p) { free(p); }
static void* aowl_hook_trampoline(void* p) {
    return p ? ((AowlHook*)p)->trampoline : NULL;
}
static int32_t aowl_hook_installed(void* p) {
    return p ? ((AowlHook*)p)->installed : 0;
}
static int32_t aowl_hook_stolen(void* p) {
    return p ? ((AowlHook*)p)->stolen : 0;
}

/* 0 on success; negative codes describe the refusal so the host can report it.
 *
 * The three ways a prologue can be unpatchable used to share one code, and the
 * message the host printed had to list all three and let the reader pick. They
 * are different problems with different answers -- a decoder gap is ours to
 * close, a relative branch is the target's and never will be, and a function
 * shorter than the jump is neither -- so they get their own codes and
 * `aowl_hook_error_text` turns each into a sentence that is true on its own.
 *
 *   -1  no target or detour
 *   -2  the prologue holds an instruction this decoder does not know
 *   -3  the trampoline could not be allocated
 *   -4  the target pages could not be made writable
 *   -5  no free patch slots (from `aowl_hook_attach`)
 *   -6  the prologue holds a relative branch, which cannot be moved
 *   -7  the function is shorter than the jump that would replace its start
 *   -8  the trampoline landed too far away for a RIP-relative displacement
 */
static const char* aowl_hook_error_text(int32_t rc) {
    switch (rc) {
        case  0: return "ok";
        case -1: return "no target or detour";
        case -2: return "the prologue holds an instruction this decoder does "
                        "not know";
        case -3: return "no executable memory within reach of the target";
        case -4: return "the target's pages could not be made writable";
        case -5: return "no free patch slots";
        case -6: return "the prologue holds a relative branch, which cannot "
                        "be moved into a trampoline";
        case -7: return "the function is shorter than the jump that would "
                        "replace its start";
        case -8: return "the trampoline landed more than 2 GB from the "
                        "target, so a RIP-relative displacement in the "
                        "stolen bytes no longer reaches";
        default: return "unknown detour error";
    }
}

/* The AOWL_INSN_* refusal a decode produced, as the install code for it. */
static int32_t aowl_why_to_rc(int32_t why) {
    switch (why) {
        case AOWL_INSN_RELATIVE: return -6;
        case AOWL_INSN_SHORT:    return -7;
        case AOWL_INSN_FAR:      return -8;
        default:                 return -2;
    }
}

static int32_t aowl_hook_install(void* handle, void* target, void* detour) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !target || !detour) return -1;

    uint8_t* t = (uint8_t*)target;
    int32_t why = AOWL_INSN_UNKNOWN;
    int32_t stolen = aowl_stolen_len_why(t, AOWL_JMP_SIZE, &why);
    if (stolen == 0) return aowl_why_to_rc(why);

    uint8_t* tramp = (uint8_t*)aowl_alloc_near(target,
                                               (size_t)(stolen + AOWL_JMP_SIZE));
    if (!tramp) return -3;

    if (aowl_copy_relocated(tramp, t, stolen) != 0) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        /* The prologue decoded -- `aowl_stolen_len_why` already proved that --
         * so the only way the copy fails is a displacement that no longer
         * reaches. Reporting that as a decoder gap sent the last reader
         * looking for a missing opcode. */
        return -8;
    }
    aowl_write_jmp_abs(tramp + stolen, t + stolen);

    DWORD old = 0;
    if (!VirtualProtect(t, (SIZE_T)stolen, PAGE_EXECUTE_READWRITE, &old)) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        return -4;
    }

    memcpy(h->original, t, (size_t)stolen);
    aowl_write_jmp_abs(t, detour);
    /* Bytes between the jump and the end of the last stolen instruction are
     * filled with int3 rather than left as the tail of a half-overwritten
     * instruction. Unreachable either way; this traps instead of executing if
     * that ever turns out to be wrong. */
    for (int32_t k = AOWL_JMP_SIZE; k < stolen; k++) t[k] = 0xCC;

    VirtualProtect(t, (SIZE_T)stolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)stolen);

    h->target = target;
    h->detour = detour;
    h->trampoline = tramp;
    h->stolen = stolen;
    h->installed = 1;
    return 0;
}

static int32_t aowl_hook_remove(void* handle) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !h->installed) return -1;

    DWORD old = 0;
    uint8_t* t = (uint8_t*)h->target;
    if (!VirtualProtect(t, (SIZE_T)h->stolen, PAGE_EXECUTE_READWRITE, &old))
        return -4;
    memcpy(t, h->original, (size_t)h->stolen);
    VirtualProtect(t, (SIZE_T)h->stolen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)h->stolen);

    if (h->trampoline) VirtualFree(h->trampoline, 0, MEM_RELEASE);
    h->trampoline = NULL;
    h->installed = 0;
    return 0;
}

/* ------------------------------------------------------------------ *
 * The detour body
 *
 * A patched method must land somewhere with the same calling convention as the
 * original. Rather than generate code per hook, a fixed pool of thunks is used:
 * each knows its own slot, and they all funnel into one dispatcher.
 *
 * The thunks are **assembly**, and they have to be. The C version of this was
 * wrong in a way that only showed up on a method with arguments:
 *
 *     static void aowl_thunk_0(void) {
 *         aowlspt_nim_patch_fired(0);       // passes 0 in ECX
 *         ((void(*)(void))trampoline)();    // ...RCX is now 0
 *     }
 *
 * On Windows x64 the first four arguments arrive in RCX/RDX/R8/R9 (or XMM0-3),
 * and calling anything at all clobbers them. So the dispatcher call destroyed
 * `this` and every argument before the original ran, and the original then ran
 * with garbage. It survived only because the one method the tests hooked took
 * no arguments. It also *called* the trampoline instead of tail-jumping, so the
 * original's return value in RAX survived by luck rather than by design.
 *
 * What the assembly does, in order:
 *
 *   1. Save RCX, RDX, R8, R9 and XMM0-3 -- every register an argument can
 *      arrive in -- into its own frame.
 *   2. Call the dispatcher with the slot and a pointer to that frame. The host
 *      decodes the arguments from it against the method's declared parameter
 *      types, the same way `call` binds them in the other direction.
 *   3. If the dispatcher says continue: restore all of them and **tail-jump**
 *      to the trampoline. Tail-jumping rather than calling is what makes the
 *      original's return value, its stack arguments and its return address
 *      correct by construction rather than by accident.
 *   4. If the dispatcher says skip: load the return value it left behind into
 *      both RAX and XMM0 and return, without the original running at all.
 *
 * The frames carry SEH unwind directives. A managed exception thrown through a
 * patched method unwinds through this thunk, and a frame with no unwind
 * information does not merely fail that unwind -- it terminates the process.
 *
 * What is still not covered, and is reported rather than guessed: arguments
 * past the fourth, which arrive on the stack, and value types larger than
 * eight bytes, which arrive by hidden reference.
 * ------------------------------------------------------------------ */

#define AOWL_MAX_HOOKS 16

/* `AowlRegs` and its accessors live in `aowlspt_shim.h`.
 *
 * They are used from two translation units -- this one, which writes the frame
 * from assembly, and the host's `invoke`, which decodes it against a method
 * signature -- and only the shim is included by both. Defining them here left
 * the decoder calling functions it had no declaration for, which C accepts with
 * a warning and then miscompiles on the return type.
 *
 * The offsets the assembly below uses are, however, this file's own: the thunk
 * stores RCX/RDX/R8/R9 at +0x00/0x08/0x10/0x18, XMM0-3 at +0x20/0x28/0x30/0x38
 * and reads the replacement return value from +0x40, which is exactly the
 * layout of `AowlRegs`. The size is named here so anything that mirrors the
 * frame can be pinned to the assembly that writes it rather than to a copy of
 * the struct that can drift from both. */
#define AOWL_REGS_BYTES 0x48

/* Returns 0 to run the original, 1 to suppress it. */
extern int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs);

static AowlHook* g_hookSlots[AOWL_MAX_HOOKS];
/* `used` because the only reader is the assembly below, and the compiler cannot
 * see that. Without it the table is dropped at -O1 and the link fails on a
 * symbol that is right there in the file. */
__attribute__((used)) static void* aowl_tramp_table[AOWL_MAX_HOOKS];
static int32_t   g_hookCount = 0;

/* Likewise: called only from assembly, so it needs `used` to survive -- and
 * `static`, so a second translation unit including this header does not clash. */
__attribute__((used)) static int32_t aowl_patch_dispatch(int32_t slot, void* regs) {
    return aowlspt_nim_patch_fired(slot, regs);
}

#if defined(__x86_64__)

#define AOWL_ASM_THUNK(n) __asm__(                                            \
    ".text\n"                                                                 \
    ".def aowl_thunk_" #n "; .scl 3; .type 32; .endef\n"                      \
    ".seh_proc aowl_thunk_" #n "\n"                                           \
    "aowl_thunk_" #n ":\n"                                                    \
    "  subq $0x98, %rsp\n"                                                    \
    "  .seh_stackalloc 0x98\n"                                                \
    "  .seh_endprologue\n"                                                    \
    "  movq %rcx, 0x40(%rsp)\n"                                               \
    "  movq %rdx, 0x48(%rsp)\n"                                               \
    "  movq %r8,  0x50(%rsp)\n"                                               \
    "  movq %r9,  0x58(%rsp)\n"                                               \
    "  movsd %xmm0, 0x60(%rsp)\n"                                             \
    "  movsd %xmm1, 0x68(%rsp)\n"                                             \
    "  movsd %xmm2, 0x70(%rsp)\n"                                             \
    "  movsd %xmm3, 0x78(%rsp)\n"                                             \
    "  movq $0, 0x80(%rsp)\n"                                                 \
    "  movl $" #n ", %ecx\n"                                                  \
    "  leaq 0x40(%rsp), %rdx\n"                                               \
    "  call aowl_patch_dispatch\n"                                            \
    "  testl %eax, %eax\n"                                                    \
    "  jne .Laowl_skip_" #n "\n"                                              \
    "  movq 0x40(%rsp), %rcx\n"                                               \
    "  movq 0x48(%rsp), %rdx\n"                                               \
    "  movq 0x50(%rsp), %r8\n"                                                \
    "  movq 0x58(%rsp), %r9\n"                                                \
    "  movsd 0x60(%rsp), %xmm0\n"                                             \
    "  movsd 0x68(%rsp), %xmm1\n"                                             \
    "  movsd 0x70(%rsp), %xmm2\n"                                             \
    "  movsd 0x78(%rsp), %xmm3\n"                                             \
    "  movq aowl_tramp_table+" #n "*8(%rip), %rax\n"                          \
    "  addq $0x98, %rsp\n"                                                    \
    "  jmp *%rax\n"                                                           \
    ".Laowl_skip_" #n ":\n"                                                   \
    "  movq 0x80(%rsp), %rax\n"                                               \
    "  movq %rax, %xmm0\n"                                                    \
    "  addq $0x98, %rsp\n"                                                    \
    "  ret\n"                                                                 \
    ".seh_endproc\n");                                                        \
    extern void aowl_thunk_##n(void);

AOWL_ASM_THUNK(0)  AOWL_ASM_THUNK(1)  AOWL_ASM_THUNK(2)  AOWL_ASM_THUNK(3)
AOWL_ASM_THUNK(4)  AOWL_ASM_THUNK(5)  AOWL_ASM_THUNK(6)  AOWL_ASM_THUNK(7)
AOWL_ASM_THUNK(8)  AOWL_ASM_THUNK(9)  AOWL_ASM_THUNK(10) AOWL_ASM_THUNK(11)
AOWL_ASM_THUNK(12) AOWL_ASM_THUNK(13) AOWL_ASM_THUNK(14) AOWL_ASM_THUNK(15)

#else
#  error "the aowlspt detour thunks are x86-64 only"
#endif

typedef void (*AowlThunk)(void);

static AowlThunk g_thunks[AOWL_MAX_HOOKS] = {
    aowl_thunk_0,  aowl_thunk_1,  aowl_thunk_2,  aowl_thunk_3,
    aowl_thunk_4,  aowl_thunk_5,  aowl_thunk_6,  aowl_thunk_7,
    aowl_thunk_8,  aowl_thunk_9,  aowl_thunk_10, aowl_thunk_11,
    aowl_thunk_12, aowl_thunk_13, aowl_thunk_14, aowl_thunk_15
};

static int32_t aowl_hook_capacity(void) { return AOWL_MAX_HOOKS; }
static int32_t aowl_hook_used(void) { return g_hookCount; }

/* Claims a slot, installs the hook, and returns the slot index -- which is what
 * `aowlspt_nim_patch_fired` receives, so the host knows which patch fired with
 * no lookup on the hot path. Negative values are the install errors above, or
 * -5 when the pool is exhausted. */
static int32_t aowl_hook_attach(void* handle, void* target) {
    if (g_hookCount >= AOWL_MAX_HOOKS) return -5;
    int32_t slot = g_hookCount;
    g_hookSlots[slot] = (AowlHook*)handle;
    int32_t rc = aowl_hook_install(handle, target, (void*)g_thunks[slot]);
    if (rc != 0) {
        g_hookSlots[slot] = NULL;
        return rc;
    }
    /* The thunk reads the trampoline out of this table rather than walking the
     * hook struct, so the hot path is one load rather than two. */
    aowl_tramp_table[slot] = ((AowlHook*)handle)->trampoline;
    g_hookCount++;
    return slot;
}

#endif /* AOWLSPT_DETOUR_H */
