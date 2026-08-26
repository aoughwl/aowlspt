#!/usr/bin/env python3
"""Regenerate the argument-dispatch block of abi/aowlspt_fast.h.

WHY A GENERATOR
===============
The block it emits is ~480 near-identical `case` lines. Hand-maintaining that
is how a single slot ends up passed as `a[3].g` where the mask said float --
a call with an argument in the wrong register, which does not crash: it
returns a plausible number. Generating removes that failure mode entirely:
one rule, applied 477 times, by a program.

THE RULE, AND WHERE IT WAS MEASURED
===================================
Win64 gives argument POSITIONS 0..3 a register (RCX/RDX/R8/R9 for the
integer class, XMM0..3 for float; the POSITION picks the register, not the
running count of same-class arguments). Position 4 and up go on the STACK,
each in its own 8-byte slot, above a 32-byte shadow ("home") area that the
CALLER reserves for positions 0..3 even though it never writes it.

That is not quoted from the ABI document here; it is READ OFF a callee on
this build. `UnityEngine.Matrix4x4::Ortho(l,r,b,t,zNear,zFar) -> Matrix4x4`
@0x5294C30 returns a 64-byte aggregate, so its shape is
(retbuf=pos0, l=pos1, r=pos2, b=pos3, t=pos4, zNear=pos5, zFar=pos6,
MethodInfo*=pos7). Its own prologue is `push rbx; sub rsp,0x70`, which puts
the return address at rsp+0x78, and it then reads:

    movss xmm3, [rsp+0xa0]      <- t      = pos4
    movss xmm1, [rsp+0xa8]      <- zNear  = pos5
    movss xmm0, [rsp+0xb0]      <- zFar   = pos6

rsp+0x78 being the return address makes rsp+0x80..0x9f the 32-byte shadow
area and rsp+0xa0 the first stack argument. Shadow SIZE, slot STRIDE and
position ORDER are therefore all three measured from one function, on this
build, rather than assumed.

WHY THIS DOES NOT WRITE ASSEMBLY
================================
Every case below is an ordinary C call through a fully-typed function
pointer. gcc reserves the shadow space, keeps RSP 16-byte aligned at the
call site and cleans up afterwards -- so the two things that corrupt a stack
silently are the compiler's job and not ours. This generator's only job is to
make the PROTOTYPE match what the callee expects.

THE ONE THING THAT IS DERIVED RATHER THAN MEASURED, and how it is checked
========================================================================
A float in a SPILLED position (>=4) is declared here as `int64_t` and passed
as `a[i].g`, not as `float`. Both produce an 8-byte stack slot whose low four
bytes are the float's bit pattern, so a callee doing `movss xmm,[slot]` reads
the same value either way -- but that is a derivation, so it is not left
unchecked. `Ortho`'s `top` argument is a float in position 4, and the live
proof in `aowl/src/aowlspt/callproof.nim` asserts the resulting m11 is
EXACTLY 0.25, which no other value of `top` produces.

Because of that, the float mask only ever has to describe positions 0..3, and
`AOWL_FAST_CODE` masks it to four bits. The case count is therefore
1+2+4+8+16 + 16 per further slot -- 159 per return form -- rather than 2**n,
which is what made 12 slots affordable at all.

Usage:  python tools/gen_fast_table.py            # rewrite abi/aowlspt_fast.h
        python tools/gen_fast_table.py --stdout   # print the block only
"""
import sys
import os

MAXSLOTS = 12
REGPOS = 4          # positions 0..3 take registers; 4 and up spill

FORMS = [
    ("aowl_fast_g", "int64_t", "int64_t", "return ", "0"),
    ("aowl_fast_f", "double",  "float",   "return (double)", "0.0"),
    ("aowl_fast_d", "double",  "double",  "return ", "0.0"),
]


def masks_for(n):
    return range(1 << min(n, REGPOS))


def ptype(i, m):
    return "float" if (i < REGPOS and (m >> i) & 1) else "int64_t"


def pexpr(i, m):
    return "a[%d].f" % i if (i < REGPOS and (m >> i) & 1) else "a[%d].g" % i


def code(n, m):
    return (n << 4) | (m & 0xF)


def emit_form(fname, retc, callret, retpfx, zero):
    out = []
    out.append("static %s %s(void* fn, const void* mi, int32_t n," % (retc, fname))
    pad = " " * len("static %s %s(" % (retc, fname))
    out.append("%suint32_t mask, const AowlFastSlot* a) {" % pad)
    out.append("    switch (AOWL_FAST_CODE(n, mask)) {")
    for n in range(MAXSLOTS + 1):
        for m in masks_for(n):
            types = [ptype(i, m) for i in range(n)] + ["const void*"]
            args = [pexpr(i, m) for i in range(n)] + ["mi"]
            out.append("    case %3d: %s((%s(*)(%s))fn)(%s);"
                       % (code(n, m), retpfx, callret,
                          ",".join(types), ", ".join(args)))
    out.append("    default: return %s;" % zero)
    out.append("    }")
    out.append("}")
    return out


HEAD = '''/* Filling a slot.
 *
 * `set_f` takes a double because that is what nimony calls a float; the
 * narrowing to the 32-bit value the callee will read happens here, once,
 * rather than being left to whatever the call site did.
 *
 * It writes the WHOLE eight bytes, zeroing the high half first. That is not
 * tidiness: a float in a SPILLED position travels as an 8-byte stack slot
 * carrying the float bits in its low half (see tools/gen_fast_table.py), so
 * the high half is a real part of what gets stored and must be defined rather
 * than inherited from whatever the slot happened to hold before. */
static void aowl_fast_set_g(void* a, int32_t i, int64_t v) { ((AowlFastSlot*)a)[i].g = v; }
static void aowl_fast_set_p(void* a, int32_t i, void* v)   { ((AowlFastSlot*)a)[i].p = v; }
static void aowl_fast_set_f(void* a, int32_t i, double v)  {
    AowlFastSlot s; s.g = 0; s.f = (float)v; ((AowlFastSlot*)a)[i] = s;
}

/* The packed signature code: slot count in the high bits, one bit per
 * REGISTER slot saying "this one is a float".
 *
 * Four bits, not one per slot. Only positions 0..3 get a register at all;
 * from position 4 up every argument is an 8-byte stack slot whatever its
 * type, so a float bit there would describe nothing. The mask is narrowed to
 * four bits HERE rather than at the call sites, so a caller that still sets a
 * bit for slot 4 -- as `aowl/src/aowlspt/callrva.nim` did before spill
 * existed -- lands on the same case rather than on no case at all.
 *
 * Kept in one place because the nimony side computes `mask` and the switches
 * below consume it, and a disagreement between the two is a call with the
 * arguments in the wrong registers.
 *
 * MAX_SLOTS is 12 because the widest real caller so far is an sret aggregate
 * return plus `this` plus eight arguments plus the trailing MethodInfo*, and
 * because at 16 cases per extra slot the table costs nothing to widen. A
 * shape past it is REFUSED by `aowl_crva_invoke`, never truncated. */
#define AOWL_FAST_CODE(n, mask) (((n) << 4) | ((int32_t)(mask) & 0xF))
#define AOWL_FAST_MAX_SLOTS 12

/* Three dispatchers, one per return *form*.
 *
 * `_g` covers void, bool, every integer and every pointer/reference return:
 * they all come back in RAX and the caller narrows. Calling a `void` method
 * through an `int64_t`-returning type reads RAX when the callee never wrote
 * it -- harmless, because the result is discarded, and it saves a fourth copy
 * of the table.
 *
 * `_f` and `_d` cannot be merged: a `float` return leaves 32 bits in XMM0 and
 * a `double` leaves 64, and reading one as the other produces a number rather
 * than an error.
 *
 * An aggregate return WIDER than 8 bytes does not use any of these three as a
 * separate form: it comes back through a hidden buffer the caller passes as
 * position 0, so it is a `_g` call with one extra leading pointer slot. An
 * aggregate return of exactly 8 bytes comes back packed in RAX, so it is a
 * plain `_g` call.
 *
 * A code with no case is a signature the caller should have refused. It
 * returns zero rather than calling something arbitrary.
 *
 * EVERYTHING FROM HERE TO THE END OF `aowl_fast_d` IS GENERATED by
 * `tools/gen_fast_table.py`. Edit that, re-run it, and commit both. */
'''


def build_block():
    parts = [HEAD]
    for fname, retc, callret, retpfx, zero in FORMS:
        parts.append("\n".join(emit_form(fname, retc, callret, retpfx, zero)))
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def main():
    block = build_block()
    if "--stdout" in sys.argv:
        sys.stdout.write(block)
        return
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "abi", "aowlspt_fast.h")
    src = open(path, "r", encoding="utf-8", newline="\n").read()
    start = src.index("/* Filling a slot.")
    endmark = ("\n\n/* ==================================================================== *"
               "\n * Fields")
    end = src.index(endmark, start)
    out = src[:start] + block + src[end + 1:]
    open(path, "w", encoding="utf-8", newline="\n").write(out)
    print("wrote %s -- %d cases, MAX_SLOTS=%d"
          % (path, out.count("    case "), MAXSLOTS))


main()
