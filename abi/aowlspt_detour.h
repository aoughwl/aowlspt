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
 * **Why the process stops while the bytes move.** Fourteen bytes is not an
 * atomic store, so a thread entering the function mid-write executes half of
 * one instruction and half of another. Every other thread in the process is
 * therefore suspended across the write and checked for standing in the bytes;
 * see the long note above `aowl_hook_arm`, which is mostly about what may and
 * may not be called while they are stopped.
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
#include <tlhelp32.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AOWL_JMP_SIZE 14   /* jmp [rip+0] ; qword dest */
#define AOWL_MAX_STOLEN 32

typedef struct AowlHook {
    void*   target;                       /* the function that was patched   */
    void*   detour;                       /* what it now jumps to            */
    void*   trampoline;                   /* stolen bytes + jump back        */
    void*   site;                         /* AowlSite: this hook's own record*/
    void*   stub;                         /* the 24 bytes the target jumps to*/
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

/* There is deliberately no code here for "a RIP-relative displacement no
 * longer reaches". That is the one refusal a decode cannot produce: whether a
 * disp32 still fits depends on where the trampoline was allocated, which is
 * not known until `aowl_tramp_alloc` has run and the bytes are being copied.
 * `aowl_copy_relocated` is where it is discovered and `aowl_hook_prepare_ex`
 * turns it straight into -8. An `AOWL_INSN_FAR` did sit here, wired into
 * `aowl_why_to_rc` and assigned by nothing, so the only way to reach -8 was
 * the path that never consulted it -- a refusal reason that could not be
 * reported is one nobody can act on. */

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

/* Defined by the assembly at the bottom of this file. Declared here because
 * `aowl_write_stub` needs its address and the stubs are written from the
 * install path, which is a long way above it. */
extern void aowl_thunk_common(void);

/* The per-hook stub: the two instructions that turn "a firing arrived" into
 * "a firing arrived *for this hook*".
 *
 *     mov r11, <site>
 *     jmp [rip+0] ; aowl_thunk_common
 *
 * This is the fix for the only race the generation could not close. A firing
 * used to be told nothing but a **slot number**, baked into one of sixteen
 * fixed thunks, and had to look the rest up in slot-indexed tables. A thread
 * preempted between the jump landing on the thunk and those loads read them
 * after the slot had been released *and re-claimed*: trampoline and generation
 * both belonged to the new occupant, agreed with each other, passed the
 * generation check, and ran the wrong hook's handler with the wrong method's
 * arguments. `tests/detour_race.c` saw exactly `decoy(x)` come back, which is
 * the other function's body and nothing else.
 *
 * With the site pointer carried in a register from the stub, there is no
 * lookup and therefore no window: the record is allocated with the hook, never
 * reclaimed, never written after the hook is armed, and reached only from a
 * stub that only this hook's target jumps to. The generation stays, but its
 * job is now narrow and exact -- it says whether the *host's* row for this slot
 * is still ours, since that table is indexed by slot and the slot does come
 * back.
 *
 * R11 rather than RAX or R10: it is volatile under the Windows x64 ABI, it is
 * not an argument register, and it is not the varargs vector count that RAX
 * carries. Nothing that can arrive at a patched method is in it. */
static void aowl_write_stub(uint8_t* at, void* site) {
    at[0] = 0x49; at[1] = 0xBB;              /* mov r11, imm64 */
    memcpy(at + 2, &site, 8);
    aowl_write_jmp_abs(at + 10, (void*)(uintptr_t)&aowl_thunk_common);
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

/* ------------------------------------------------------------------ *
 * A trampoline is never given back
 *
 * `aowl_hook_remove` used to `VirtualFree` the trampoline it allocated, and
 * that is a use-after-free with a thread already running in it. The thunk
 * reaches the original by jumping into the trampoline; a removal that unmaps
 * those pages while a thread's RIP is inside them is an access violation in
 * the middle of a game method, from a thread that never asked to be patched.
 * `tests/detour_race.c` counts them: six threads calling a patched function
 * while another installs and removes the patch faulted on essentially every
 * cycle -- 1878 faults in a three-second run, which is not a rare window, it
 * is the ordinary case.
 *
 * The obvious fix is to make the removal wait for the threads, and the obvious
 * fix is wrong here. Waiting means either instrumenting the firing -- a
 * refcount taken and released around every call into a trampoline, which is
 * two locked instructions on a path that costs 23 ns end to end and would be
 * the largest single item in it -- or suspending every thread in the game and
 * inspecting it, from a mod-manager click, with the render thread among them.
 * The first makes every patched method in the game slower for ever to make one
 * click safe; the second is a stall a player sees.
 *
 * So the trampoline is simply never freed. That costs nothing at all on the
 * firing path and nothing on the removal path, and it is *correct* rather than
 * merely unlikely to fault: the retired bytes are the stolen prologue followed
 * by a jump to `target + stolen`, and the removal has just put the original
 * bytes back at `target` -- so a firing that arrives late runs the original
 * function's own prologue and continues into the original function's body.
 * The right answer, from memory nobody will unmap.
 *
 * What it costs is address space, and that is why the pool slots are
 * suballocated rather than each given a `VirtualAlloc` of its own. A
 * `VirtualAlloc` reserves a whole allocation granularity -- 64 KB for a
 * hundred-odd bytes -- so never freeing one per install would burn 64 KB per
 * mod toggle and, far more sharply, would use up the +/-2 GB window the stolen
 * RIP-relative displacements need after 32768 of them. Suballocated, one 64 KB
 * block holds 512 slots and the whole pool is bounded at `AOWL_TRAMP_BLOCKS`
 * blocks: 8 MB, 65536 installs, and a refusal rather than a silent wrap when
 * that runs out. Only the blocks actually reached are ever allocated.
 *
 * Bounded rather than growable on purpose. A pool that grows without limit
 * turns a mod stuck in a load/unload loop into a slow exhaustion of the near
 * window, which surfaces as patches that stop working for reasons no log
 * explains. A pool that ends says "the trampoline could not be allocated" --
 * error -3, which the host already prints.
 *
 * Not thread-safe, and neither is anything else here: `g_hookFree`,
 * `g_hookCount` and `g_hookSlots` assume one installer at a time. This used to
 * add "and both hosts install and remove from a single control thread", which
 * is no longer the reason it holds. A mod may call `AowlHostApi.patch` from any
 * thread it likes, and the client host's own tick thread may be taking another
 * mod's detours out at the same moment; what keeps the assumption true is that
 * the *caller* serialises -- `installPatch` in
 * `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` wraps every `aowl_hook_claim` /
 * `aowl_hook_attach_at` / `aowl_hook_release` in `tablesLock`, because the
 * engine's free list, its generation table and the host's own row for the slot
 * are three structures that have to move together. The overlay installs its two
 * hooks from its start path and takes no slot at all. An engine caller that
 * does neither is the one this sentence is a warning to.
 * ------------------------------------------------------------------ */

/* One pool slot per hook, holding the three things that share the hook's
 * lifetime and must outlive its removal:
 *
 *   +0x00  the trampoline -- stolen prologue plus the jump back
 *   +0x40  `AowlSite`, the record a firing reads everything out of
 *   +0x60  the stub, which is what the patched method actually jumps to
 *
 * They are together because they are retired together and never reclaimed
 * (see below), so binding them to one allocation is what makes "this firing
 * belongs to this hook" a fact about an address rather than about timing.
 *
 * 128 bytes rather than 64: the trampoline needs 46 at most, the site 24 and
 * the stub 24. The site and the stub share the second 64-byte line and the
 * trampoline has the first to itself, so the stores that fill the site at
 * install time never land in a line something is executing out of. */
#define AOWL_TRAMP_TRAMP  0x00
#define AOWL_TRAMP_SITE   0x40
#define AOWL_TRAMP_STUB   0x60
#define AOWL_TRAMP_SLOT   128       /* >= AOWL_TRAMP_STUB + AOWL_STUB_SIZE */
#define AOWL_TRAMP_BLOCK  0x10000   /* one allocation granularity          */
#define AOWL_TRAMP_BLOCKS 128       /* 8 MB and 65536 hooks, at most        */

/* The per-hook record. A firing loads **everything** it needs out of one of
 * these -- the trampoline to run, the slot to report, the generation it was
 * installed under, and whether it is a postfix -- so the four can never be
 * read from different occupants of a reused slot. See `aowl_write_stub` and
 * the thunk.
 *
 * The layout is the thunk's, not the compiler's: the assembly reads +0x00,
 * +0x08, +0x0C and +0x10 literally. `_Static_assert` below pins the two
 * together. */
typedef struct AowlSite {
    void*    tramp;     /* +0x00  the retired-but-mapped original prologue  */
    uint32_t gen;       /* +0x08  the slot generation this hook was born in */
    int32_t  slot;      /* +0x0C  which row the host should look at         */
    uint64_t post;      /* +0x10  non-zero: call the original and come back */
} AowlSite;

#define AOWL_STUB_SIZE 24   /* mov r11, imm64 (10) + jmp [rip+0] (14) */

typedef struct AowlTrampBlock {
    uint8_t* base;
    int32_t  used;      /* trampolines handed out of this block */
} AowlTrampBlock;

static AowlTrampBlock g_trampBlocks[AOWL_TRAMP_BLOCKS];
static int32_t g_trampBlockCount = 0;
static int32_t g_trampHandedOut = 0;

/* Whether every byte of a block is close enough to `anchor` for a 32-bit
 * displacement copied out of the prologue to still reach. The whole block is
 * checked, not the one slot, so a block accepted here stays usable for this
 * anchor until it is full. */
static int aowl_tramp_block_reaches(const uint8_t* base, const void* anchor) {
    const int64_t lo = (int64_t)(intptr_t)base - (int64_t)(intptr_t)anchor;
    const int64_t hi = lo + AOWL_TRAMP_BLOCK;
    const int64_t limit = 0x7F000000LL;   /* inside 2 GB, with room to spare */
    return lo > -limit && hi < limit;
}

/* A pool slot within reach of `anchor`, or NULL when the pool is spent. */
static uint8_t* aowl_tramp_alloc(void* anchor) {
    for (int32_t i = 0; i < g_trampBlockCount; i++) {
        AowlTrampBlock* b = &g_trampBlocks[i];
        if (b->used >= AOWL_TRAMP_BLOCK / AOWL_TRAMP_SLOT) continue;
        if (!aowl_tramp_block_reaches(b->base, anchor)) continue;
        uint8_t* p = b->base + (size_t)b->used * AOWL_TRAMP_SLOT;
        b->used++;
        g_trampHandedOut++;
        return p;
    }
    if (g_trampBlockCount >= AOWL_TRAMP_BLOCKS) return NULL;
    uint8_t* base = (uint8_t*)aowl_alloc_near(anchor, AOWL_TRAMP_BLOCK);
    if (!base) return NULL;
    /* `aowl_alloc_near` searches out to just under 2 GB and a block is 64 KB
     * wide, so its far end can sit outside the range a copied displacement can
     * still reach. Refused here rather than accepted and then discovered by
     * `aowl_copy_relocated`, which would spend a block of the bounded pool on
     * a trampoline nothing can use and leave it in the table refusing every
     * anchor after it. The caller gets -3, which says the trampoline could not
     * be allocated -- which is exactly what happened. */
    if (!aowl_tramp_block_reaches(base, anchor)) {
        VirtualFree(base, 0, MEM_RELEASE);
        return NULL;
    }
    g_trampBlocks[g_trampBlockCount].base = base;
    g_trampBlocks[g_trampBlockCount].used = 1;
    g_trampBlockCount++;
    g_trampHandedOut++;
    return base;
}

/* For a harness that wants the pool as a number rather than an impression:
 * how many trampolines have been handed out, and how many blocks that took. */
static int32_t aowl_tramp_count(void)  { return g_trampHandedOut; }
static int32_t aowl_tramp_blocks(void) { return g_trampBlockCount; }

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
 *   -9  the target already starts with one of our jumps
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
        case -9: return "that method is already patched -- something else "
                        "detoured it first";
        default: return "unknown detour error";
    }
}

/* The AOWL_INSN_* refusal a decode produced, as the install code for it. */
static int32_t aowl_why_to_rc(int32_t why) {
    switch (why) {
        case AOWL_INSN_RELATIVE: return -6;
        case AOWL_INSN_SHORT:    return -7;
        /* No case for -8: see the note by the AOWL_INSN_* codes -- a decode
         * cannot know how far away the trampoline will land. */
        default:                 return -2;
    }
}

/* Installing is two halves, and the seam is not a tidy-up.
 *
 * `aowl_hook_prepare` decodes the prologue and builds the trampoline; nothing
 * it does is visible to a running thread. `aowl_hook_arm` writes the jump, and
 * from the instruction after it the thunk can fire.
 *
 * A caller with anything a firing will read has to write it *between* the two.
 * The slot-based path has all of it: the site record and the stub that names
 * it, filled in by `aowl_hook_attach_at`. When the equivalent went in after the
 * jump there was a window -- short, and hit constantly under load -- in which a
 * firing read the NULL still sitting there and jumped through it. One call in a
 * few thousand, in `tests/detour_race.c`, before the split. */

/* `wantStub` distinguishes the two callers. The overlay's own Present and
 * ResizeBuffers hooks name a plain C function as their detour and take no slot,
 * so they get no stub and no site; a slot-based patch passes NULL and has its
 * detour filled in by `aowl_hook_attach_at`, which is the only place that knows
 * the slot number the site has to carry. */
static int32_t aowl_hook_prepare_ex(void* handle, void* target, void* detour,
                                    int32_t wantStub) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !target || (!detour && !wantStub)) return -1;

    uint8_t* t = (uint8_t*)target;

    /* Already ours.
     *
     * Patching a patched method decodes the jump we wrote last time, sees the
     * RIP-relative operand and refuses it as "the prologue holds a relative
     * branch" -- which is true of the bytes and useless to the reader, who goes
     * looking at the game's code for a branch the game did not write. Two mods
     * hooking the same method is an ordinary thing to happen, so it gets a
     * sentence that says so. (The check is for *our* encoding specifically:
     * `ff 25 00000000`, jump through the qword immediately after it.) */
    if (t[0] == 0xFF && t[1] == 0x25 &&
        t[2] == 0x00 && t[3] == 0x00 && t[4] == 0x00 && t[5] == 0x00) {
        return -9;
    }

    int32_t why = AOWL_INSN_UNKNOWN;
    int32_t stolen = aowl_stolen_len_why(t, AOWL_JMP_SIZE, &why);
    if (stolen == 0) return aowl_why_to_rc(why);

    uint8_t* pool = aowl_tramp_alloc(target);
    if (!pool) return -3;
    uint8_t* tramp = pool + AOWL_TRAMP_TRAMP;

    if (aowl_copy_relocated(tramp, t, stolen) != 0) {
        /* The prologue decoded -- `aowl_stolen_len_why` already proved that --
         * so the only way the copy fails is a displacement that no longer
         * reaches. Reporting that as a decoder gap sent the last reader
         * looking for a missing opcode.
         *
         * The trampoline is not given back. It cannot be: the pool hands out
         * fixed slots that are never reclaimed, which is the whole point of it
         * (see `aowl_tramp_alloc`). One slot of 128 bytes is lost per refused
         * install, out of 65536 -- the slot was 64 bytes when this was
         * written, and grew when the site and the stub moved into it. */
        return -8;
    }
    aowl_write_jmp_abs(tramp + stolen, t + stolen);

    memcpy(h->original, t, (size_t)stolen);
    h->target = target;
    h->detour = detour;          /* NULL until the stub exists, when wanted */
    h->trampoline = tramp;
    h->site  = wantStub ? (void*)(pool + AOWL_TRAMP_SITE) : NULL;
    h->stub  = wantStub ? (void*)(pool + AOWL_TRAMP_STUB) : NULL;
    h->stolen = stolen;
    h->installed = 0;   /* not until it is armed */
    return 0;
}

static int32_t aowl_hook_prepare(void* handle, void* target, void* detour) {
    return aowl_hook_prepare_ex(handle, target, detour, 0);
}

/* ------------------------------------------------------------------ *
 * The prologue is rewritten with the rest of the process standing still
 *
 * The jump is fourteen bytes and no store is fourteen bytes wide, so the
 * rewrite is not atomic: a thread that enters the function while it is going in
 * executes the head of the new jump followed by the tail of an instruction that
 * is no longer there, or the head of an old instruction followed by half a
 * pointer. It faults, or worse it does not. `tests/detour_race.c` counted this
 * separately from the trampoline races -- `g_faultsPatch` -- and with six
 * threads calling the target it is not a rare window either: over a thousand
 * faults in a three-second run, which is why that test parks the workers itself
 * in its default mode, just to be able to see the race it was actually about.
 * It still does: the default is the test's own park with the engine's switched
 * off, `--engine-park` is the reverse, and `--no-park` is the control.
 *
 * There are two ways to close it. One is to make the patch atomic: five bytes
 * (`jmp rel32`) written with a single `lock cmpxchg`-width store, reaching an
 * island near the target that holds the real fourteen. That needs an island
 * within +/-2 GB, needs the prologue to hold five stealable bytes rather than
 * fourteen, and quietly changes the decoder's contract. The other is to stop
 * the threads while the bytes move, which is what this does -- it is the same
 * thing every shipping detour engine on Windows does, and it costs nothing at
 * all on the firing path.
 *
 * **Suspending is two steps and the second is not optional.** `SuspendThread`
 * *requests* a suspension and returns; the thread is not off the processor
 * until something makes the kernel wait for it. `GetThreadContext` is that
 * something, and it is also the only way to ask where the thread stopped --
 * which is the other half, because a thread parked *inside* the bytes resumes
 * into the middle of the jump that replaced them and executes exactly the
 * half-instruction the park exists to prevent. So: suspend everybody, look, and
 * if anyone is standing in `[target, target + stolen)` let them all go and try
 * again. The real stolen length, not `AOWL_MAX_STOLEN` -- the window is what
 * decides how often somebody is standing in it, and a window twice the true
 * size turns this loop into the bottleneck.
 *
 * **Nothing in the park window may take a user-mode lock, and that is the whole
 * design constraint.** A suspended thread keeps whatever it held. If it held
 * the process heap lock, or the loader lock, or a CRT lock, and the arming
 * thread then called something that wants the same lock, the arming thread
 * waits for a thread that cannot run -- a hard hang of the game with no thread
 * to blame it on and no way to debug it, because the debugger's own threads are
 * suspended too. So everything that can block is done *before* anybody is
 * stopped: the trampoline, the site and the stub are built in
 * `aowl_hook_prepare_ex`, and resolving `NtGetNextThread`, walking the thread
 * list and opening every handle all happen in `aowl_park_begin` before the
 * first `SuspendThread`. `CreateToolhelp32Snapshot`, the fallback enumeration,
 * allocates and takes locks all over the place; taking it with the process
 * already frozen would be the deadlock, and the same is true of
 * `GetProcAddress` if the resolve were left until the handles were in hand.
 *
 * What is left inside the window is the suspend sweep itself -- `SuspendThread`
 * and `GetThreadContext` per thread -- and then `VirtualProtect`, the byte
 * stores, and `VirtualProtect` back.
 *
 * **Is `VirtualProtect` safe there?** Yes, and the reason is worth writing
 * down rather than assuming. It is a thin wrapper over `NtProtectVirtualMemory`
 * -- it takes no CRT lock, no heap lock and no loader lock, so there is no
 * user-mode lock for a suspended thread to be holding against it. The locks it
 * does take are the kernel's address-space locks, and a user-mode thread cannot
 * be suspended while holding one: a suspend is delivered at a kernel APC
 * boundary, so a thread inside a memory syscall finishes that syscall and
 * releases the lock before it stops. The one caveat is instrumentation --
 * Application Verifier, some anti-cheat and some profilers hook the Win32 layer
 * and can put a user-mode lock underneath it -- and there is nothing this file
 * can do about that beyond keeping the call count in the window at two.
 * `FlushInstructionCache` is a syscall too, but it is done *after* the resume
 * because it does not need to be inside; x86 instruction caches are coherent
 * with stores, so the flush is a formality and its position is free.
 *
 * **What one install costs, because live mod control pays it.** A park happens
 * on every arm and every disarm, and both are reached from a mod-manager click
 * while the game is running -- so this is a product number, not a test artifact.
 * Measured on this machine (`--engine-park` in `tests/detour_race.c`, and a
 * scratch harness at fixed thread counts):
 *
 *     enumeration, NtGetNextThread     ~0.8 us per thread   (outside the freeze)
 *     enumeration, Toolhelp fallback   ~2 ms flat           (outside the freeze)
 *     suspend + context + resume       ~11 us per thread    (inside the freeze)
 *
 * So on a process with 65 threads, one park is ~0.9 ms of which ~0.7 ms is the
 * freeze, and one arm-plus-disarm is ~1.8 ms. A Unity client runs somewhere
 * around fifty to a hundred threads, so a mod toggling ten patches off and on
 * costs tens of milliseconds and freezes the world for under a millisecond at a
 * time. That is a hitch, not a hang, and it is the price of the write being
 * safe. On the Toolhelp fallback the same toggle costs an extra ~4 ms per
 * patch, all of it outside the freeze: slower to click, not jerkier to play.
 *
 * The per-thread constant is why the enumeration was worth changing and the
 * suspend sweep is not: 11 us per thread is three syscalls that have to happen,
 * where the 2 ms was a machine-wide snapshot of ten thousand threads to find
 * sixty. Under `tests/detour_race.c` -- six threads saturating the CPU -- the
 * change took the run from 50 install/remove cycles in three seconds to
 * thirteen or fourteen thousand, which is what makes the zero it reports mean
 * anything.
 *
 * **It must never hang the game.** The retry loop is bounded at
 * `AOWL_PARK_RETRIES`. On exhaustion every thread is resumed and the write goes
 * ahead unparked -- today's behaviour, with today's small chance of a torn
 * prologue -- rather than spinning forever or refusing the hook. That is a
 * deliberate ranking: a mod that will not arm, or a client that freezes on a
 * mod-manager click, is a worse outcome than a race that is now rare rather
 * than constant, and the giveup is counted (`aowl_hook_park_giveups`) so it is
 * a number somebody can look at rather than a silent downgrade.
 *
 * Every thread that was suspended is resumed on every path out, including the
 * error paths -- `aowl_park_close` is called even when `VirtualProtect` fails.
 * A leaked suspend count is a permanently frozen game thread, which presents as
 * a hung client rather than as a bug in this file.
 *
 * Two things this does not cover, on purpose. A thread created *after* the
 * enumeration is not parked; the window for one to be spawned and reach this
 * exact function inside the microseconds the write takes is not worth a second
 * enumeration with the process already frozen. And a process with more than
 * `AOWL_PARK_MAX` threads is not parked at all -- the handle array is a stack
 * local because it must not be a heap allocation, and overflowing it falls back
 * to the unparked write the same way exhaustion does.
 * ------------------------------------------------------------------ */

#define AOWL_PARK_MAX     512   /* threads; 4 KB of stack for the handles   */
#define AOWL_PARK_RETRIES 64    /* then write unparked rather than hang      */

/* What a park needs on every thread it stops: suspend it, read where it
 * stopped, and -- because the ntdll enumeration hands back handles rather than
 * thread ids -- ask a handle which thread it is, so the caller's own can be
 * dropped from the list. */
#define AOWL_PARK_ACCESS (THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | \
                          THREAD_QUERY_LIMITED_INFORMATION)

#define AOWL_PARK_ENUM_NONE     0
#define AOWL_PARK_ENUM_NT       1   /* ntdll!NtGetNextThread                  */
#define AOWL_PARK_ENUM_TOOLHELP 2   /* CreateToolhelp32Snapshot, the fallback */

typedef struct AowlPark {
    HANDLE  threads[AOWL_PARK_MAX];
    uint8_t stopped[AOWL_PARK_MAX];  /* this park suspended it, so this park
                                        resumes it -- and nothing it did not */
    int32_t count;
} AowlPark;

/* Off only for the harness that has to show the race is real; see
 * `tests/detour_race.c --no-park`. Nothing in the host touches it. */
static int32_t g_parkEnabled = 1;
static void    aowl_hook_set_park(int32_t on) { g_parkEnabled = on ? 1 : 0; }
static int32_t aowl_hook_park_enabled(void) { return g_parkEnabled; }

/* Counted rather than assumed: "the park never had to retry" and "the park
 * never ran" answer identically from outside, and a giveup is the one case
 * where the engine knowingly writes into running threads. */
static volatile LONG aowl_park_retries = 0;
static volatile LONG aowl_park_giveups = 0;
static int32_t aowl_hook_park_retries(void) { return (int32_t)aowl_park_retries; }
static int32_t aowl_hook_park_giveups(void) { return (int32_t)aowl_park_giveups; }

/* Which enumeration actually ran. Reported rather than assumed for the same
 * reason as everything else here: the fallback costs milliseconds where the
 * fast path costs tens of microseconds, so a machine that silently took it is a
 * machine whose mod toggles feel different, and "which one ran" should never be
 * a guess. */
static int32_t g_parkEnum = AOWL_PARK_ENUM_NONE;
static int32_t aowl_hook_park_enum(void) { return g_parkEnum; }
static const char* aowl_hook_park_enum_text(void) {
    switch (g_parkEnum) {
        case AOWL_PARK_ENUM_NT:       return "ntdll!NtGetNextThread";
        case AOWL_PARK_ENUM_TOOLHELP: return "CreateToolhelp32Snapshot";
        default:                      return "none";
    }
}

static void aowl_park_resume(AowlPark* p) {
    for (int32_t i = 0; i < p->count; i++) {
        if (!p->stopped[i]) continue;
        ResumeThread(p->threads[i]);
        p->stopped[i] = 0;
    }
}

/* Resume anything still stopped, then give the handles back. Safe to call on a
 * park that never started, which is what makes it the single exit path. */
static void aowl_park_close(AowlPark* p) {
    aowl_park_resume(p);
    for (int32_t i = 0; i < p->count; i++) CloseHandle(p->threads[i]);
    p->count = 0;
}

/* ntdll!NtGetNextThread -- undocumented, present since Windows 8.1, and the
 * reason a park is affordable on a live game.
 *
 *   NTSTATUS NtGetNextThread(HANDLE process, HANDLE thread, ACCESS_MASK access,
 *                            ULONG attributes, ULONG flags, HANDLE* next)
 *
 * Pass NULL for the first call and the previous handle after that, and it walks
 * this process's thread list, opening each one at the access asked for. It is
 * resolved once and cached, with `GetModuleHandleW` rather than `LoadLibrary`:
 * ntdll is mapped into every process before any of our code runs, so there is
 * nothing to load and no loader work to do. The resolve happens on the
 * enumeration path, which is before any thread is suspended -- like everything
 * else here that could block.
 *
 * Undocumented means it can be absent, which is why the Toolhelp path below
 * stays. It does not mean unstable: the signature has not moved in a decade and
 * every debugger on Windows walks threads this way. A wrong guess about it
 * fails at `GetProcAddress` or returns an error status, and both land on the
 * fallback rather than on a wrong list. */
typedef LONG (NTAPI *AowlNtGetNextThread)(HANDLE, HANDLE, ACCESS_MASK,
                                          ULONG, ULONG, HANDLE*);
static AowlNtGetNextThread g_ntGetNextThread = NULL;
static int32_t g_ntGetNextThreadResolved = 0;

static AowlNtGetNextThread aowl_nt_get_next_thread(void) {
    if (!g_ntGetNextThreadResolved) {
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (ntdll)
            g_ntGetNextThread = (AowlNtGetNextThread)(void*)
                GetProcAddress(ntdll, "NtGetNextThread");
        g_ntGetNextThreadResolved = 1;
    }
    return g_ntGetNextThread;
}

/* Opens every thread of this process except the caller's, the fast way. 1 when
 * the array holds them, 0 when the export is missing or the walk produced
 * nothing -- in which case the caller tries Toolhelp. */
static int32_t aowl_park_collect_nt(AowlPark* p) {
    AowlNtGetNextThread getNext = aowl_nt_get_next_thread();
    if (!getNext) return 0;

    const HANDLE self = GetCurrentProcess();
    const DWORD  me   = GetCurrentThreadId();
    HANDLE prev = NULL;
    for (;;) {
        HANDLE h = NULL;
        /* Every NTSTATUS that is not success is negative, STATUS_NO_MORE_ENTRIES
         * among them, so the ordinary end of the walk and a real failure end it
         * the same way. That is deliberate: what follows uses the list only to
         * hold threads out of the bytes, and a list that is short by one thread
         * is not a smaller version of the right answer, it is the wrong one. A
         * walk that ends early with some threads collected still parks those --
         * the alternative is not parking at all -- but a walk that collected
         * none falls through to the fallback below. */
        if (getNext(self, prev, AOWL_PARK_ACCESS, 0, 0, &h) < 0) break;
        if (p->count >= AOWL_PARK_MAX) {
            CloseHandle(h);
            aowl_park_close(p);
            return 0;
        }
        p->stopped[p->count] = 0;
        p->threads[p->count++] = h;
        /* The next call needs this handle open; it stays open in the array
         * until `aowl_park_close`, so there is nothing extra to track. */
        prev = h;
    }
    if (p->count == 0) return 0;

    /* The caller is one of this process's threads, so it is in the list, and a
     * handle is not an id -- `GetThreadId` is the question, and asking it is
     * why `AOWL_PARK_ACCESS` includes QUERY_LIMITED_INFORMATION. Suspending
     * ourselves would be a hang with no thread left able to undo it. */
    for (int32_t i = 0; i < p->count; i++) {
        if (GetThreadId(p->threads[i]) != me) continue;
        CloseHandle(p->threads[i]);
        p->threads[i] = p->threads[p->count - 1];
        p->count--;
        break;
    }
    return 1;
}

/* The same list, the documented way, for a system without the export.
 *
 * Kept because "undocumented" and "always present" are not the same claim, and
 * the cost of being wrong about it is that no install parks at all. It is a
 * real fallback and not a rehearsal: it fills the same array, and the suspend
 * loop below cannot tell which of the two filled it.
 *
 * What it costs is why it is second. `CreateToolhelp32Snapshot` snapshots the
 * threads of **every process on the machine** -- some ten thousand of them on
 * an ordinary desktop -- and this walk then throws all but ours away. Measured
 * on this machine that is ~2 ms per park, flat, against ~50 us for the walk
 * above at 65 threads, and a park happens on every arm and on every disarm.
 * Both costs are outside the freeze; see the note above `aowl_hook_arm`. */
static int32_t aowl_park_collect_toolhelp(AowlPark* p) {
    const DWORD me  = GetCurrentThreadId();
    const DWORD pid = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    THREADENTRY32 te;
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) {
        do {
            /* The snapshot is machine-wide however it is asked for, so the
             * owner has to be checked on every entry -- suspending another
             * process's threads is not a bug this file would survive. */
            if (te.dwSize < FIELD_OFFSET(THREADENTRY32, th32OwnerProcessID) +
                            sizeof(te.th32OwnerProcessID)) continue;
            if (te.th32OwnerProcessID != pid) continue;
            if (te.th32ThreadID == me) continue;
            if (p->count >= AOWL_PARK_MAX) {
                CloseHandle(snap);
                aowl_park_close(p);
                return 0;
            }
            HANDLE h = OpenThread(AOWL_PARK_ACCESS, FALSE, te.th32ThreadID);
            /* A thread that exited between the snapshot and here, or one this
             * process may not open, is simply not parked. */
            if (h) { p->stopped[p->count] = 0; p->threads[p->count++] = h; }
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return 1;
}

/* Stops every other thread in the process outside `[target, target + stolen)`.
 * Returns 1 when the process is frozen and clear of the bytes, 0 when it is
 * not -- and 0 is not an error: the caller writes anyway. Either way the caller
 * must call `aowl_park_close`. */
static int32_t aowl_park_begin(AowlPark* p, void* target, int32_t stolen) {
    p->count = 0;
    if (!g_parkEnabled) return 0;

    /* --- Everything that can allocate or block happens here, before the first
     * SuspendThread below: the export resolve, the enumeration, and every
     * handle open. --- */
    if (aowl_park_collect_nt(p)) {
        g_parkEnum = AOWL_PARK_ENUM_NT;
    } else if (aowl_park_collect_toolhelp(p)) {
        g_parkEnum = AOWL_PARK_ENUM_TOOLHELP;
    } else {
        return 0;
    }
    if (p->count == 0) return 0;   /* single-threaded: the write is alone */

    const uintptr_t lo = (uintptr_t)target;
    const uintptr_t hi = lo + (uintptr_t)(stolen > 0 ? stolen : AOWL_JMP_SIZE);
    CONTEXT c;
    for (int32_t attempt = 0; attempt < AOWL_PARK_RETRIES; attempt++) {
        int32_t clear = 1;
        for (int32_t i = 0; i < p->count; i++) {
            if (SuspendThread(p->threads[i]) == (DWORD)-1) continue;
            p->stopped[i] = 1;
            memset(&c, 0, sizeof(c));
            c.ContextFlags = CONTEXT_CONTROL;
            /* The context is what actually makes the kernel wait, so it is
             * fetched for every thread even when one has already been found in
             * the way -- skipping the rest would leave them requested but not
             * stopped. */
            if (GetThreadContext(p->threads[i], &c) &&
                (uintptr_t)c.Rip >= lo && (uintptr_t)c.Rip < hi) clear = 0;
        }
        if (clear) return 1;
        aowl_park_resume(p);
        InterlockedIncrement(&aowl_park_retries);
        /* Outside the suspension, always: a yield with the process frozen is a
         * yield to nobody. */
        Sleep(0);
    }
    InterlockedIncrement(&aowl_park_giveups);
    aowl_park_close(p);
    return 0;
}

/* The second half: the jump goes in, and the patch is live from here. */
static int32_t aowl_hook_arm(void* handle) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !h->target || !h->trampoline || !h->detour) return -1;
    uint8_t* t = (uint8_t*)h->target;
    int32_t stolen = h->stolen;
    void* detour = h->detour;

    /* Nothing below this line until `aowl_park_close` may allocate, lock or
     * block; see the note above. */
    AowlPark park;
    aowl_park_begin(&park, t, stolen);

    DWORD old = 0;
    if (!VirtualProtect(t, (SIZE_T)stolen, PAGE_EXECUTE_READWRITE, &old)) {
        aowl_park_close(&park);
        return -4;
    }

    aowl_write_jmp_abs(t, detour);
    /* Bytes between the jump and the end of the last stolen instruction are
     * filled with int3 rather than left as the tail of a half-overwritten
     * instruction. Unreachable either way; this traps instead of executing if
     * that ever turns out to be wrong. */
    for (int32_t k = AOWL_JMP_SIZE; k < stolen; k++) t[k] = 0xCC;

    VirtualProtect(t, (SIZE_T)stolen, old, &old);
    aowl_park_close(&park);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)stolen);

    h->installed = 1;
    return 0;
}

/* Both halves, for a caller with nothing to write down in between -- the
 * overlay's own Present and ResizeBuffers hooks, which take no pool slot and
 * so have no table for a firing to read. */
static int32_t aowl_hook_install(void* handle, void* target, void* detour) {
    int32_t rc = aowl_hook_prepare(handle, target, detour);
    if (rc != 0) return rc;
    return aowl_hook_arm(handle);
}

static int32_t aowl_hook_remove(void* handle) {
    AowlHook* h = (AowlHook*)handle;
    if (!h || !h->installed) return -1;

    DWORD old = 0;
    uint8_t* t = (uint8_t*)h->target;
    /* The same park as the arm, and for the same reason: putting the original
     * bytes back is the identical non-atomic fourteen-byte write in the other
     * direction. Same rule below the line -- nothing that allocates, locks or
     * blocks until `aowl_park_close`. */
    AowlPark park;
    aowl_park_begin(&park, t, h->stolen);
    if (!VirtualProtect(t, (SIZE_T)h->stolen, PAGE_EXECUTE_READWRITE, &old)) {
        aowl_park_close(&park);
        return -4;
    }
    memcpy(t, h->original, (size_t)h->stolen);
    VirtualProtect(t, (SIZE_T)h->stolen, old, &old);
    aowl_park_close(&park);
    FlushInstructionCache(GetCurrentProcess(), t, (SIZE_T)h->stolen);

    /* The trampoline is *retired*, not freed -- see `aowl_tramp_alloc`. A
     * thread is very likely inside it right now; the original bytes are back
     * at `target` above, so the retired copy still runs the stolen prologue
     * and still jumps to `target + stolen`, which is now the original function
     * from beginning to end. Unmapping it here is what
     * `tests/detour_race.c` counted as 1878 access violations in three
     * seconds. */
    h->trampoline = NULL;
    h->installed = 0;
    return 0;
}

/* ------------------------------------------------------------------ *
 * The detour body
 *
 * A patched method must land somewhere with the same calling convention as the
 * original. There used to be a fixed pool of thunks here, one per slot, each
 * knowing its own slot number. There is now exactly one -- `aowl_thunk_common`
 * -- reached through a 24-byte stub written per hook by `aowl_write_stub`,
 * which loads that hook's `AowlSite` into R11 and jumps. The thunk reads the
 * slot, the generation and the trampoline out of the site rather than knowing
 * any of them, and every hook funnels into the one dispatcher. See the note
 * above `aowl_thunk_common` for why the pool of typed-out thunks ended.
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
 *   2. Call the dispatcher with the slot, a pointer to that frame, and the
 *      generation the hook was born in -- all three read out of the site
 *      record R11 already points at, which is why this step names no table.
 *      The generation is not decoration: it is what catches a firing that
 *      arrived through a slot since released and re-claimed. The host decodes
 *      the arguments from the frame against the method's declared parameter
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
 *
 * ------------------------------------------------------------------
 * The postfix path, and why it is a second path rather than a change
 * ------------------------------------------------------------------
 *
 * A postfix has to see what the original returned, so it cannot tail-jump: a
 * tail jump gives the original *our* return address and it never comes back.
 * The thunk has to `call` the trampoline instead and regain control -- and
 * everything the tail jump was making correct for free then becomes this file's
 * problem. Three things, in the order they bite:
 *
 * **The return registers.** After the call, RAX holds an integer or reference
 * return and XMM0 holds a float or double one, and nothing says which. Both are
 * saved, both are handed to the host (which knows the declared return type and
 * reads the right one), and both are restored on the way out -- so a postfix
 * that changes nothing is bit-for-bit transparent, including on a method whose
 * return type this file could not classify.
 *
 * **The hidden struct-return pointer.** A value type larger than eight bytes is
 * returned through a caller-allocated buffer whose address arrives in RCX and
 * comes back in RAX. Saving and restoring RAX keeps that ABI intact -- but the
 * *value* lives in memory this file cannot read the layout of, so a postfix
 * there could neither report the result nor replace it. The host refuses such a
 * patch at registration rather than installing one that silently observes
 * nothing. See `hostPatch`.
 *
 * **Stack arguments.** Arguments past the fourth register slot sit above the
 * caller's home space, at a fixed offset from the rsp the original was entered
 * with. A tail jump preserves that rsp; a `call` from inside this frame does
 * not, so the original would read our frame where its fifth argument should be.
 * They could be copied down -- the count is known to the host at attach time and
 * could be published in a side table for the assembly to `rep movsq` -- but that
 * is a second thing to get wrong on a path where being wrong means a corrupted
 * argument rather than a crash. The host counts the compiled call's slots
 * (`this`, the declared arguments, and IL2CPP's trailing `MethodInfo*`) and
 * **refuses a postfix that would need more than four**.
 *
 * **SEH.** The `call` happens inside the same `.seh_proc` with the same
 * `.seh_stackalloc 0x98` prologue, so the frame is describable and an exception
 * thrown out of the original unwinds through it exactly as it unwinds through
 * any other frame. What it does *not* do is run the postfix handler: an unwind
 * skips the rest of this function by definition. A postfix therefore means
 * "after the original returned", not "after the original finished", and a mod
 * that needs the exception case wants a finalizer, which does not cross this
 * ABI at all.
 *
 * Which path a hook takes is a load and a branch off `site->post`, read at the
 * top of the thunk out of the record R11 already points at. (This used to name
 * `aowl_post_table`, which is where the bit is *kept*; it is copied into the
 * site at attach and by `aowl_hook_set_postfix`, and the firing path never
 * reads the table.) A prefix hook's instruction sequence is otherwise
 * unchanged, so the hot path -- the drain hook, which fires every frame -- pays
 * one predictable load for the postfix path's existence.
 * ------------------------------------------------------------------ */

/* Sixteen was not a budget, it was the number of thunks that had been typed
 * out: each slot needed its own `aowl_thunk_N`, written by hand as a macro
 * expansion, and sixteen expansions is what fitted on a screen. Two example
 * mods exhausted it -- `hostharness --churn 120` stopped with thirteen slots
 * live and three more to install -- and a real install is eight or ten mods,
 * not two.
 *
 * The thunks are gone (see `aowl_write_stub`), so nothing is enumerated per
 * slot any more and the constant costs only tables. Per slot that is a hook
 * pointer, a taken flag, a generation, a postfix word and a free-list entry:
 * 25 bytes, so 256 slots is 6.4 KB of BSS and nothing on the firing path,
 * which reaches none of these tables. The per-hook trampoline pool slot is 128
 * bytes and is allocated on demand, so an install that uses twenty slots pays
 * for twenty.
 *
 * 256 rather than "unbounded": the host preallocates its patch table to this
 * capacity precisely so that a `seq` cannot move under a firing thread, and a
 * bound is what makes a mod stuck in an install loop report "no free patch
 * slots" instead of quietly eating address space. */
#define AOWL_MAX_HOOKS 256

/* `AowlRegs` and its accessors live in `aowlspt_shim.h`.
 *
 * They are used from two translation units -- this one, which writes the frame
 * from assembly, and the host's `invoke`, which decodes it against a method
 * signature -- and only the shim is included by both. Defining them here left
 * the decoder calling functions it had no declaration for, which C accepts with
 * a warning and then miscompiles on the return type.
 *
 * The offsets the assembly below uses are, however, this file's own: the thunk
 * stores RCX/RDX/R8/R9 at +0x00/0x08/0x10/0x18, XMM0-3 at +0x20/0x28/0x30/0x38,
 * reads the replacement return value from +0x40, and -- on the postfix path --
 * publishes the original's float return at +0x48, which is exactly the layout of
 * `AowlRegs`. The size is named here so anything that mirrors the frame can be
 * pinned to the assembly that writes it rather than to a copy of the struct that
 * can drift from both. */
#define AOWL_REGS_BYTES 0x50

/* Returns 0 to run the original, 1 to suppress it. */
extern int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs);

/* Called only on the postfix path, after the original has returned. `regs`
 * still holds the argument registers saved on entry, plus the original's
 * integer return at +0x40 and its float return at +0x48. Returns 0 to hand the
 * caller what the original produced, 1 to hand it whatever was left at +0x40
 * instead. */
extern int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs);

static AowlHook* g_hookSlots[AOWL_MAX_HOOKS];
/* Whether a slot is spoken for. A slot may be claimed and not yet attached --
 * the host fills its own table between the two, because the thunk can fire the
 * instant the jump lands -- so "has a hook" is not the same question.
 *
 * Declared up here rather than beside the free list it belongs to because the
 * dispatcher reads it; see `aowl_patch_dispatch`. */
static uint8_t g_hookTaken[AOWL_MAX_HOOKS];
/* Which occupant of a slot the **host's** row belongs to.
 *
 * The slot number is the one thing a firing carries that is not private to its
 * hook: `aowlspt_nim_patch_fired(slot, regs)` is how the host finds the patch
 * row, and the host indexes that table by slot because the alternative is a
 * lookup on the hot path. Slots come back (see `aowl_hook_claim`), so a firing
 * left over from a removed patch could otherwise be delivered to whichever
 * patch claimed the slot next -- a plausible handler called with the arguments
 * of a method it was not written for, which is worse than a crash because it
 * looks like it worked.
 *
 * So every slot carries a generation, bumped on release. A hook records the
 * generation it was installed under **in its own site record**, the firing
 * carries that record's contents up from the stub, and the dispatcher compares
 * the two. A firing whose generation has moved on is dropped rather than
 * delivered.
 *
 * This used to have a window and no longer does, and the difference is where
 * the generation is read from. It used to be loaded out of *this table*, by a
 * thunk that knew only its slot -- so a thread preempted between the jump
 * landing on the thunk and that load read the generation and the trampoline
 * after the slot had turned over, got a self-consistent pair belonging to the
 * new occupant, passed this check, and ran the other hook. Now both come out of
 * one record that belongs to one hook for ever, so the pair cannot disagree and
 * cannot describe anybody else. See `aowl_write_stub`.
 *
 * `used` is no longer needed for the assembly's sake -- the thunk reads the
 * site, not this -- but the table is still read by the dispatchers below. */
static uint32_t aowl_gen_table[AOWL_MAX_HOOKS];
/* Firings dropped because their slot had turned over. Zero is the number this
 * should be; it is counted rather than assumed, because a reuse race that is
 * being caught and a reuse race that is not happening answer identically from
 * outside. */
static volatile LONG aowl_stale_fires = 0;
static int32_t aowl_hook_stale_fires(void) { return (int32_t)aowl_stale_fires; }
/* Non-zero for a slot whose thunk must call the original and come back.
 *
 * Written by the host *before* the hook is attached -- the thunk can fire the
 * instant the jump lands, and a slot that is armed as a postfix a moment later
 * would spend its first firings silently behaving like a prefix -- and copied
 * into the site record at attach, which is what the firing actually reads.
 * This table remains the place the host states its intent, because it does so
 * before there is a hook to state it on. */
static uint64_t aowl_post_table[AOWL_MAX_HOOKS];
static int32_t   g_hookCount = 0;

/* Likewise: called only from assembly, so it needs `used` to survive -- and
 * `static`, so a second translation unit including this header does not clash. */
__attribute__((used)) static int32_t aowl_patch_dispatch(int32_t slot, void* regs,
                                                         uint32_t gen) {
    /* Two loads and two never-taken branches. See `aowl_gen_table` for what
     * they prove.
     *
     * Both answer **0**, which is "let the original run", and the trampoline
     * the thunk will run is the one out of this firing's own site record --
     * retired, not freed, so still mapped and still the prologue of the method
     * this firing was for. The original runs and the caller gets a true
     * answer, whatever has happened to the slot in the meantime.
     *
     * It used to answer 1 -- suppress the method, hand the caller the zero in
     * the frame -- because with the trampoline read at the point of use there
     * was nothing else it could safely do. That is a wrong answer given to a
     * caller whose only misfortune was to be inside a method at the moment a
     * player switched a mod off, and there were 1048 of them in a three-second
     * run of `tests/detour_race.c`. 1 is still what a *handler* returns to
     * suppress a method deliberately; it is no longer what the engine returns
     * because it lost track.
     *
     * The two conditions are different windows and neither implies the other.
     * The generation catches a slot that turned over *while* this firing was
     * in flight. `g_hookTaken` catches a firing that arrived entirely after
     * the release -- the generation cannot see that one at all, because it is
     * read on entry and an entry after the bump reads the bumped value and
     * matches it. That is not a rare case: it is what every thread mid-jump at
     * the moment of removal does. */
    if (gen != aowl_gen_table[slot] || !g_hookTaken[slot]) {
        InterlockedIncrement(&aowl_stale_fires);
        return 0;
    }
    return aowlspt_nim_patch_fired(slot, regs);
}

__attribute__((used)) static int32_t aowl_patch_return_dispatch(int32_t slot,
                                                                void* regs,
                                                                uint32_t gen) {
    /* The same two conditions, and here both answers were 0 already: the
     * original has run and its result is in the frame, so handing the caller
     * what it produced is the only true thing to do. The window the generation
     * covers is much wider on this path -- a postfix firing spends the whole
     * of the original method between reading the generation and getting here.
     */
    if (gen != aowl_gen_table[slot] || !g_hookTaken[slot]) {
        InterlockedIncrement(&aowl_stale_fires);
        return 0;
    }
    return aowlspt_nim_patch_returned(slot, regs);
}

/* Arms or disarms the postfix path for a slot. Separate from `aowl_hook_attach`
 * because it has to happen first; see the table's comment. */
static void aowl_hook_set_postfix(int32_t slot, int32_t on) {
    if (slot < 0 || slot >= AOWL_MAX_HOOKS) return;
    aowl_post_table[slot] = on ? 1u : 0u;
    /* If the slot is already attached, the firing path is reading the site and
     * not this table, so both have to move. A host that arms the postfix flag
     * before attaching -- which is the documented order -- never reaches here. */
    AowlHook* live = g_hookSlots[slot];
    if (live && live->site)
        ((AowlSite*)live->site)->post = aowl_post_table[slot];
}
static int32_t aowl_hook_is_postfix(int32_t slot) {
    if (slot < 0 || slot >= AOWL_MAX_HOOKS) return 0;
    return aowl_post_table[slot] != 0u;
}

#if defined(__x86_64__)

_Static_assert(sizeof(AowlSite) == 24, "the thunk reads AowlSite by offset");

/* One thunk, entered with R11 holding the firing's own `AowlSite`.
 *
 * There used to be sixteen of these, one per slot, each with its slot number
 * baked into its instructions and each looking the rest up in slot-indexed
 * tables -- which is the race described in `aowl_write_stub`, and also the
 * reason `AOWL_MAX_HOOKS` was sixteen. One thunk reading one record fixes both
 * at once.
 *
 * The frame is unchanged: 0x98 bytes, RCX/RDX/R8/R9 at 0x40-0x58, XMM0-3 at
 * 0x60-0x78, the replacement return at 0x80 and the original's float return at
 * 0x88 -- which is `AowlRegs` from 0x40. 0x30 and 0x34 hold the generation and
 * the slot across the postfix path's call into the original, and 0x38 holds
 * the trampoline. The prefix path never spills either of the first two: R11 is
 * still live where they are wanted, so it loads them straight into the
 * argument registers.
 *
 * The order the site's fields are read in no longer matters, and that is the
 * whole point. It mattered a great deal when they came from two tables. */
__asm__(
    ".text\n"
    ".def aowl_thunk_common; .scl 3; .type 32; .endef\n"
    ".seh_proc aowl_thunk_common\n"
    "aowl_thunk_common:\n"
    "  subq $0x98, %rsp\n"
    "  .seh_stackalloc 0x98\n"
    "  .seh_endprologue\n"
    /* site->tramp. Spilled because R11 does not survive the dispatcher call
     * and both paths need it afterwards. */
    "  movq 0(%r11), %rax\n"
    "  movq %rax, 0x38(%rsp)\n"
    "  movq 16(%r11), %rax\n"           /* site->post */
    "  testq %rax, %rax\n"
    "  jne .Laowl_post\n"
    "  movq %rcx, 0x40(%rsp)\n"
    "  movq %rdx, 0x48(%rsp)\n"
    "  movq %r8,  0x50(%rsp)\n"
    "  movq %r9,  0x58(%rsp)\n"
    "  movsd %xmm0, 0x60(%rsp)\n"
    "  movsd %xmm1, 0x68(%rsp)\n"
    "  movsd %xmm2, 0x70(%rsp)\n"
    "  movsd %xmm3, 0x78(%rsp)\n"
    "  movq $0, 0x80(%rsp)\n"
    "  movl 12(%r11), %ecx\n"           /* site->slot, straight to the arg */
    "  movl 8(%r11), %r8d\n"            /* site->gen, likewise */
    "  leaq 0x40(%rsp), %rdx\n"
    "  call aowl_patch_dispatch\n"
    "  testl %eax, %eax\n"
    "  jne .Laowl_skip\n"
    "  movq 0x40(%rsp), %rcx\n"
    "  movq 0x48(%rsp), %rdx\n"
    "  movq 0x50(%rsp), %r8\n"
    "  movq 0x58(%rsp), %r9\n"
    "  movsd 0x60(%rsp), %xmm0\n"
    "  movsd 0x68(%rsp), %xmm1\n"
    "  movsd 0x70(%rsp), %xmm2\n"
    "  movsd 0x78(%rsp), %xmm3\n"
    "  movq 0x38(%rsp), %rax\n"
    "  addq $0x98, %rsp\n"
    "  jmp *%rax\n"
    ".Laowl_skip:\n"
    "  movq 0x80(%rsp), %rax\n"
    "  movq %rax, %xmm0\n"
    "  addq $0x98, %rsp\n"
    "  ret\n"
    /* ---- the postfix path --------------------------------------------
     * The argument registers are saved for the same reason as above -- the
     * handler is told what the method was called with -- and this time they
     * are saved rather than restored, because the frame outlives the
     * original's execution and the registers do not.
     *
     * `call` the trampoline rather than `jmp` to it: the trampoline runs the
     * stolen prologue and jumps back into the body, the body's own `ret`
     * returns here, and control comes back with the result in RAX and XMM0.
     * 0x20 and 0x28 hold those across the dispatcher call -- both are above
     * the 32 bytes of home space the callee may write, which is why the save
     * slots are there and not lower.
     *
     * The slot and the generation are spilled here and not on the prefix path:
     * R11 is dead once the original has been called, and the original is what
     * this path exists to run. */
    ".Laowl_post:\n"
    "  movq %rcx, 0x40(%rsp)\n"
    "  movq %rdx, 0x48(%rsp)\n"
    "  movq %r8,  0x50(%rsp)\n"
    "  movq %r9,  0x58(%rsp)\n"
    "  movsd %xmm0, 0x60(%rsp)\n"
    "  movsd %xmm1, 0x68(%rsp)\n"
    "  movsd %xmm2, 0x70(%rsp)\n"
    "  movsd %xmm3, 0x78(%rsp)\n"
    "  movl 8(%r11), %eax\n"
    "  movl %eax, 0x30(%rsp)\n"
    "  movl 12(%r11), %eax\n"
    "  movl %eax, 0x34(%rsp)\n"
    "  movq 0x38(%rsp), %rax\n"
    "  call *%rax\n"
    "  movq %rax, 0x20(%rsp)\n"
    "  movsd %xmm0, 0x28(%rsp)\n"
    /* Publish both halves of the return into the frame the host reads: the
     * integer one where a replacement would go, so an unchanged postfix and
     * a replacing one write the same slot, and the float one beside it. Only
     * the declared return type says which is the value, and only the host
     * has that. */
    "  movq %rax, 0x80(%rsp)\n"
    "  movsd %xmm0, 0x88(%rsp)\n"
    "  movl 0x34(%rsp), %ecx\n"
    "  leaq 0x40(%rsp), %rdx\n"
    "  movl 0x30(%rsp), %r8d\n"
    "  call aowl_patch_return_dispatch\n"
    "  testl %eax, %eax\n"
    "  jne .Laowl_repl\n"
    "  movq 0x20(%rsp), %rax\n"
    "  movsd 0x28(%rsp), %xmm0\n"
    "  addq $0x98, %rsp\n"
    "  ret\n"
    ".Laowl_repl:\n"
    "  movq 0x80(%rsp), %rax\n"
    "  movq %rax, %xmm0\n"
    "  addq $0x98, %rsp\n"
    "  ret\n"
    ".seh_endproc\n");

#else
#  error "the aowlspt detour thunks are x86-64 only"
#endif

static int32_t aowl_hook_capacity(void) { return AOWL_MAX_HOOKS; }

/* ------------------------------------------------------------------ *
 * Slots come back
 *
 * `g_hookCount` used to be the whole allocator: the next slot was the next
 * number, and `aowl_hook_remove` put the method's bytes back and freed the
 * trampoline but never said the slot was spare again. Sixteen patches into a
 * session that was the end of patching -- and a session reaches sixteen
 * quickly, because a mod that is switched off and on again spends a slot each
 * time. The seventeenth `patch()` answered "no free patch slots" with fifteen
 * of them holding nothing, which is the worst shape a limit can have: it is not
 * the limit the documentation states and it moves with the player's clicking.
 *
 * So a slot is now claimed and released, and `g_hookCount` is a high-water mark
 * rather than a count.
 *
 * Reuse is put off as long as it can be: an unused slot before a recycled one,
 * and the free list a **queue and not a stack** once every slot has been used
 * once. Removing a detour restores the method's bytes, but a thread that is
 * already inside the thunk keeps running it, and reusing that slot immediately
 * would hand its number -- which is the index of the *host's* patch row -- to
 * whichever patch took it next. See `aowl_hook_claim` for why the queue alone
 * was doing none of this.
 *
 * That is a mitigation and not a proof, and the proof is beside it in two
 * parts. Every slot carries a **generation**, bumped here on release and
 * recorded in each hook's own site record at install; and the record is what a
 * firing reads, so the generation and the trampoline it is being checked
 * alongside cannot come from different occupants of the slot. See
 * `aowl_gen_table` and `aowl_write_stub`. The measured cost of the compare was
 * nothing: a register compare and a branch that is never taken, on a path that
 * has already loaded the record it came out of.
 * ------------------------------------------------------------------ */
static int32_t g_hookFree[AOWL_MAX_HOOKS];
static int32_t g_hookFreeHead  = 0;
static int32_t g_hookFreeTail  = 0;
static int32_t g_hookFreeCount = 0;

/* Live hooks. Equal to the next slot `aowl_hook_attach` will hand out whenever
 * nothing has been released, which is every caller that only ever installs. */
static int32_t aowl_hook_used(void) { return g_hookCount - g_hookFreeCount; }
static int32_t aowl_hook_free_count(void) { return g_hookFreeCount; }

/* Reserves a slot without installing anything.
 *
 * Split out from `aowl_hook_attach` for the host's sake: it indexes its own
 * patch table by slot and the thunk can fire on the next instruction after the
 * jump lands, so the row has to exist *before* the install -- which means the
 * slot number has to exist before it too. -5 when the pool is exhausted. */
static int32_t aowl_hook_claim(void) {
    int32_t slot;
    /* A slot that has never been used first, and the free queue only once the
     * high-water mark has reached the end of the pool.
     *
     * The queue was doing nothing it was meant to do. With two live hooks --
     * which is what two example mods amount to, and what `detour_race.c`
     * models -- a claim/release cycle oscillates over slots 0 and 1, so "the
     * oldest freed slot has every other free slot between it and the newest"
     * described a queue that never held more than one entry. Reaching for an
     * unused slot first makes the queue actually hold 254 of them before
     * anything is reused, which is the separation the comment above claims.
     *
     * This is a mitigation and not the proof; the proof is that a firing now
     * carries its own site record and cannot be handed another hook's (see
     * `aowl_write_stub`). It is kept because it costs one comparison on the
     * install path and nothing at all on the firing path, and because
     * "unlikely" and "impossible" failing together is what a second layer is
     * for. */
    if (g_hookCount < AOWL_MAX_HOOKS) {
        slot = g_hookCount++;
        g_hookTaken[slot] = 1;
        return slot;
    }
    if (g_hookFreeCount > 0) {
        slot = g_hookFree[g_hookFreeHead];
        g_hookFreeHead = (g_hookFreeHead + 1) % AOWL_MAX_HOOKS;
        g_hookFreeCount--;
        g_hookTaken[slot] = 1;
        return slot;
    }
    return -5;
}

/* Hands a claimed slot back. The caller must have removed and freed its hook
 * first: this clears the tables the thunk reads and nothing else. */
static void aowl_hook_release(int32_t slot) {
    if (slot < 0 || slot >= AOWL_MAX_HOOKS) return;
    if (!g_hookTaken[slot]) return;
    /* Before the tables the thunk reads, not after: a firing that is in flight
     * right now should see the new generation as early as possible, and the
     * ones it would otherwise chase -- the trampoline, the postfix flag -- are
     * cleared underneath it. The counter wraps at 2^32 releases of one slot,
     * which is not a session. */
    aowl_gen_table[slot]++;
    g_hookTaken[slot] = 0;
    g_hookSlots[slot] = NULL;
    /* Nothing here touches the released hook's **site**, and nothing may.
     * A thread can be anywhere between the stub's `mov r11` and the dispatcher
     * right now, and the site is where it is about to read the trampoline it
     * will run. Clearing it would put a NULL in the one place a firing jumps
     * through -- which is what clearing the old slot-indexed trampoline table
     * here used to do, and in `tests/detour_race.c` that was every worker's
     * first call.
     *
     * Leaving it is safe because the site and the trampoline it names are
     * never freed and never handed out twice -- see `aowl_tramp_alloc`. The
     * retired copy stays mapped, stays the stolen prologue of the method this
     * hook patched, and still jumps to `target + stolen`, where
     * `aowl_hook_remove` has just put the original bytes back. A late firing
     * runs the original. */
    aowl_post_table[slot] = 0;
    g_hookFree[g_hookFreeTail] = slot;
    g_hookFreeTail = (g_hookFreeTail + 1) % AOWL_MAX_HOOKS;
    g_hookFreeCount++;
}

/* Installs into a slot already claimed. 0 on success, or one of the install
 * errors above; the slot stays claimed either way, so a caller that fails here
 * releases it itself -- which is what the host does, after taking its own row
 * back out. */
static int32_t aowl_hook_attach_at(void* handle, void* target, int32_t slot) {
    if (slot < 0 || slot >= AOWL_MAX_HOOKS) return -1;
    if (!g_hookTaken[slot]) return -1;
    AowlHook* h = (AowlHook*)handle;
    g_hookSlots[slot] = h;
    int32_t rc = aowl_hook_prepare_ex(handle, target, NULL, 1);
    if (rc != 0) {
        g_hookSlots[slot] = NULL;
        return rc;
    }
    /* The site is filled and the stub written **before** the jump goes in, and
     * that order is the whole reason `aowl_hook_prepare` and `aowl_hook_arm`
     * are separate: the stub can be entered on the instruction after the jump
     * lands, and a firing that arrives to find a half-built record jumps
     * through whatever is in it. When the equivalent assignment came after the
     * arm, `tests/detour_race.c` hit it on the first call of every worker it
     * started.
     *
     * Everything a firing will ever read about this hook is written here, once,
     * and never again -- which is what makes the record a fact about the hook
     * rather than about the moment. */
    AowlSite* site = (AowlSite*)h->site;
    site->tramp = h->trampoline;
    site->gen   = aowl_gen_table[slot];
    site->slot  = slot;
    site->post  = aowl_post_table[slot];
    aowl_write_stub((uint8_t*)h->stub, site);
    FlushInstructionCache(GetCurrentProcess(), h->stub, AOWL_STUB_SIZE);
    h->detour = h->stub;

    rc = aowl_hook_arm(handle);
    if (rc != 0) {
        /* The site and the stub are left as they are. Nothing jumps to them --
         * the arm failed, so no jump was written -- and they are this hook's
         * own memory, retired with it rather than handed to anybody else. */
        g_hookSlots[slot] = NULL;
        return rc;
    }
    return 0;
}

/* Claims a slot, installs the hook, and returns the slot index -- which is what
 * `aowlspt_nim_patch_fired` receives, so the host knows which patch fired with
 * no lookup on the hot path. Negative values are the install errors above, or
 * -5 when the pool is exhausted.
 *
 * The one-call form, for a caller that has nothing to write down between the
 * two halves. The host uses `aowl_hook_claim` and `aowl_hook_attach_at`
 * instead, because it does. */
static int32_t aowl_hook_attach(void* handle, void* target) {
    int32_t slot = aowl_hook_claim();
    if (slot < 0) return -5;
    int32_t rc = aowl_hook_attach_at(handle, target, slot);
    if (rc != 0) {
        aowl_hook_release(slot);
        return rc;
    }
    return slot;
}

#endif /* AOWLSPT_DETOUR_H */
