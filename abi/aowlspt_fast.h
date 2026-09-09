/* aowlspt_fast.h - calling a game method without boxing anything.
 *
 * The ordinary client path is `il2cpp_runtime_invoke`: look the method up by
 * name, allocate a `void**`, box every argument into it, dispatch generically,
 * and unbox a heap-allocated return. That is the right shape for "call
 * anything, named at run time by a mod's config file", and it is the wrong
 * shape for something a mod does ten thousand times a second.
 *
 * IL2CPP compiles every managed method to an ordinary C function. `MethodInfo`
 * holds its address in `methodPointer` (first field -- see `methodPointer` in
 * `aowl/src/aowlspt/il2cpp.nim` for why that is read by offset and why the
 * result is checked). Its signature is the declared one, plus two conventions:
 *
 *   * an instance method takes `this` as the first argument;
 *   * every method takes a trailing `const MethodInfo*`.
 *
 * So calling one directly is just a function-pointer call with the right type.
 * The problem is "the right type": nimony will not `cast` between a `pointer`
 * and a `proc`, so the call has to happen in C -- and C needs the signature at
 * compile time, while a mod only knows it at bind time.
 *
 * WHAT THIS HEADER DOES ABOUT THAT
 *
 * It enumerates the signatures. On Win64 the only thing a parameter's type
 * changes about the call is which register file it lands in and how wide it is:
 *
 *   * `int32`, `int64`, `bool`, `char`, every pointer and every reference --
 *     one general-purpose register (RCX, RDX, R8, R9, then the stack). A
 *     callee that declared `int32_t` reads ECX; passing a 64-bit value is
 *     therefore indistinguishable from passing the 32-bit one it wanted.
 *   * `float` -- one SSE register (XMM0..3), as a 32-bit float.
 *
 * That collapses the whole space to a two-valued kind per slot -- and only
 * for the first FOUR positions, because from position 4 up every argument is
 * an 8-byte stack slot whatever its type. So the shape count is 31 for the
 * register positions times one per further slot, not 2**n: 159 shapes, times
 * three return forms (`int64_t`, `float`, `double`), is 477 cases, GENERATED
 * by `tools/gen_fast_table.py` and dispatched by a switch on a packed code --
 * a jump table and a call, with no allocation and nothing touched on the heap.
 *
 * WHAT IT DELIBERATELY DOES NOT COVER, and why refusing beats guessing:
 *
 *   * `double` arguments. A `double` and a `float` both arrive in XMM, but the
 *     callee reads different widths out of it, so they are not interchangeable
 *     and adding a third kind would take 63 shapes to 364. Unity's own surface
 *     is `float` throughout; a `double` parameter is refused at bind time.
 *   * value-type arguments and returns larger than 8 bytes (`Vector3`,
 *     `Quaternion`). Win64 passes those by hidden pointer, which is a
 *     different call shape rather than a different register class, so
 *     `bindMethod` refuses them and says why. That refusal is no longer the
 *     end of the road: a hidden pointer is a plain pointer slot, and the table
 *     below already passes those, so `bindRaw` in `aowl/src/aowlspt/fast.nim`
 *     lets a mod state the shape outright -- four pointer slots for a method
 *     whose signature says one argument -- and reach `get_Position` and its
 *     kind at fast-path cost. `blackdivision`, `fov`, `morebots` and `sain`
 *     all do. Nothing in this header had to change for it; the shapes were
 *     already here. This paragraph used to end "a mod that needs them keeps
 *     using the boxed path, and is told so", which was true when written.
 *   * NOTHING to do with argument COUNT any more. Arguments past the fourth
 *     spill to the stack, and this header now emits those cases: twelve slots,
 *     which is an sret buffer plus `this` plus eight arguments plus the
 *     trailing MethodInfo*. `EFT.BotOwner`-shaped calls needing 8-9 slots were
 *     the blocked case and are not blocked. Shadow space and alignment are
 *     gcc's, because every case is a real C call through a real prototype;
 *     what was measured, and from which callee, is in the generator's header.
 *
 * In every one of those cases `bindMethod` fails with a reason. The one thing
 * this must never do is fall back quietly: a call that got the register
 * classes wrong does not crash, it reads a float out of a general register and
 * hands the game a number.
 *
 * Everything here is `static`, like `aowlspt_shim.h`: it is included into the
 * single translation unit nimony emits.
 */

#ifndef AOWLSPT_FAST_H
#define AOWLSPT_FAST_H

#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* One argument slot.
 *
 * A union rather than a cast through `int64_t*`, because reading a float out
 * of storage declared as an integer through a pointer cast is exactly the
 * aliasing case a compiler is allowed to reorder. The nimony side never reads
 * or writes these bytes itself -- it declares the storage (8-byte aligned) and
 * hands over the address, and both the writes (`aowl_fast_set_*`) and the
 * reads (the dispatchers) go through this union in this translation unit. */
typedef union AowlFastSlot {
    int64_t  g;
    float    f;
    double   d;
    void*    p;
} AowlFastSlot;

/* Filling a slot.
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

static int64_t aowl_fast_g(void* fn, const void* mi, int32_t n,
                           uint32_t mask, const AowlFastSlot* a) {
    switch (AOWL_FAST_CODE(n, mask)) {
    case   0: return ((int64_t(*)(const void*))fn)(mi);
    case  16: return ((int64_t(*)(int64_t,const void*))fn)(a[0].g, mi);
    case  17: return ((int64_t(*)(float,const void*))fn)(a[0].f, mi);
    case  32: return ((int64_t(*)(int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, mi);
    case  33: return ((int64_t(*)(float,int64_t,const void*))fn)(a[0].f, a[1].g, mi);
    case  34: return ((int64_t(*)(int64_t,float,const void*))fn)(a[0].g, a[1].f, mi);
    case  35: return ((int64_t(*)(float,float,const void*))fn)(a[0].f, a[1].f, mi);
    case  48: return ((int64_t(*)(int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, mi);
    case  49: return ((int64_t(*)(float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, mi);
    case  50: return ((int64_t(*)(int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, mi);
    case  51: return ((int64_t(*)(float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, mi);
    case  52: return ((int64_t(*)(int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].f, mi);
    case  53: return ((int64_t(*)(float,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].f, mi);
    case  54: return ((int64_t(*)(int64_t,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, mi);
    case  55: return ((int64_t(*)(float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, mi);
    case  64: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, mi);
    case  65: return ((int64_t(*)(float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, mi);
    case  66: return ((int64_t(*)(int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, mi);
    case  67: return ((int64_t(*)(float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, mi);
    case  68: return ((int64_t(*)(int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, mi);
    case  69: return ((int64_t(*)(float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, mi);
    case  70: return ((int64_t(*)(int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, mi);
    case  71: return ((int64_t(*)(float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, mi);
    case  72: return ((int64_t(*)(int64_t,int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, mi);
    case  73: return ((int64_t(*)(float,int64_t,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, mi);
    case  74: return ((int64_t(*)(int64_t,float,int64_t,float,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, mi);
    case  75: return ((int64_t(*)(float,float,int64_t,float,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, mi);
    case  76: return ((int64_t(*)(int64_t,int64_t,float,float,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, mi);
    case  77: return ((int64_t(*)(float,int64_t,float,float,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, mi);
    case  78: return ((int64_t(*)(int64_t,float,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, mi);
    case  79: return ((int64_t(*)(float,float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, mi);
    case  80: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  81: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  82: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  83: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  84: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  85: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  86: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  87: return ((int64_t(*)(float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  88: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  89: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  90: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  91: return ((int64_t(*)(float,float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  92: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  93: return ((int64_t(*)(float,int64_t,float,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  94: return ((int64_t(*)(int64_t,float,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  95: return ((int64_t(*)(float,float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  96: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  97: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  98: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  99: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case 100: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 101: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 102: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 103: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 104: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 105: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 106: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 107: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 108: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 109: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 110: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 111: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 112: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 113: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 114: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 115: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 116: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 117: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 118: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 119: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 120: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 121: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 122: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 123: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 124: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 125: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 126: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 127: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 128: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 129: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 130: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 131: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 132: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 133: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 134: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 135: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 136: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 137: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 138: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 139: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 140: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 141: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 142: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 143: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 144: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 145: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 146: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 147: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 148: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 149: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 150: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 151: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 152: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 153: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 154: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 155: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 156: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 157: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 158: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 159: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 160: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 161: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 162: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 163: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 164: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 165: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 166: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 167: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 168: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 169: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 170: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 171: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 172: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 173: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 174: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 175: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 176: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 177: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 178: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 179: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 180: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 181: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 182: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 183: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 184: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 185: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 186: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 187: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 188: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 189: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 190: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 191: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 192: return ((int64_t(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 193: return ((int64_t(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 194: return ((int64_t(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 195: return ((int64_t(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 196: return ((int64_t(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 197: return ((int64_t(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 198: return ((int64_t(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 199: return ((int64_t(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 200: return ((int64_t(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 201: return ((int64_t(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 202: return ((int64_t(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 203: return ((int64_t(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 204: return ((int64_t(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 205: return ((int64_t(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 206: return ((int64_t(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 207: return ((int64_t(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    default: return 0;
    }
}

static double aowl_fast_f(void* fn, const void* mi, int32_t n,
                          uint32_t mask, const AowlFastSlot* a) {
    switch (AOWL_FAST_CODE(n, mask)) {
    case   0: return (double)((float(*)(const void*))fn)(mi);
    case  16: return (double)((float(*)(int64_t,const void*))fn)(a[0].g, mi);
    case  17: return (double)((float(*)(float,const void*))fn)(a[0].f, mi);
    case  32: return (double)((float(*)(int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, mi);
    case  33: return (double)((float(*)(float,int64_t,const void*))fn)(a[0].f, a[1].g, mi);
    case  34: return (double)((float(*)(int64_t,float,const void*))fn)(a[0].g, a[1].f, mi);
    case  35: return (double)((float(*)(float,float,const void*))fn)(a[0].f, a[1].f, mi);
    case  48: return (double)((float(*)(int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, mi);
    case  49: return (double)((float(*)(float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, mi);
    case  50: return (double)((float(*)(int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, mi);
    case  51: return (double)((float(*)(float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, mi);
    case  52: return (double)((float(*)(int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].f, mi);
    case  53: return (double)((float(*)(float,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].f, mi);
    case  54: return (double)((float(*)(int64_t,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, mi);
    case  55: return (double)((float(*)(float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, mi);
    case  64: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, mi);
    case  65: return (double)((float(*)(float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, mi);
    case  66: return (double)((float(*)(int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, mi);
    case  67: return (double)((float(*)(float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, mi);
    case  68: return (double)((float(*)(int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, mi);
    case  69: return (double)((float(*)(float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, mi);
    case  70: return (double)((float(*)(int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, mi);
    case  71: return (double)((float(*)(float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, mi);
    case  72: return (double)((float(*)(int64_t,int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, mi);
    case  73: return (double)((float(*)(float,int64_t,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, mi);
    case  74: return (double)((float(*)(int64_t,float,int64_t,float,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, mi);
    case  75: return (double)((float(*)(float,float,int64_t,float,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, mi);
    case  76: return (double)((float(*)(int64_t,int64_t,float,float,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, mi);
    case  77: return (double)((float(*)(float,int64_t,float,float,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, mi);
    case  78: return (double)((float(*)(int64_t,float,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, mi);
    case  79: return (double)((float(*)(float,float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, mi);
    case  80: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  81: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  82: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  83: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  84: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  85: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  86: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  87: return (double)((float(*)(float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  88: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  89: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  90: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  91: return (double)((float(*)(float,float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  92: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  93: return (double)((float(*)(float,int64_t,float,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  94: return (double)((float(*)(int64_t,float,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  95: return (double)((float(*)(float,float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  96: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  97: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  98: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  99: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case 100: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 101: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 102: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 103: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 104: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 105: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 106: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 107: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 108: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 109: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 110: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 111: return (double)((float(*)(float,float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 112: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 113: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 114: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 115: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 116: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 117: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 118: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 119: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 120: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 121: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 122: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 123: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 124: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 125: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 126: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 127: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 128: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 129: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 130: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 131: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 132: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 133: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 134: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 135: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 136: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 137: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 138: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 139: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 140: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 141: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 142: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 143: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 144: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 145: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 146: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 147: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 148: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 149: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 150: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 151: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 152: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 153: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 154: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 155: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 156: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 157: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 158: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 159: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 160: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 161: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 162: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 163: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 164: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 165: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 166: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 167: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 168: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 169: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 170: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 171: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 172: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 173: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 174: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 175: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 176: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 177: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 178: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 179: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 180: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 181: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 182: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 183: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 184: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 185: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 186: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 187: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 188: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 189: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 190: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 191: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 192: return (double)((float(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 193: return (double)((float(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 194: return (double)((float(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 195: return (double)((float(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 196: return (double)((float(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 197: return (double)((float(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 198: return (double)((float(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 199: return (double)((float(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 200: return (double)((float(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 201: return (double)((float(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 202: return (double)((float(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 203: return (double)((float(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 204: return (double)((float(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 205: return (double)((float(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 206: return (double)((float(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 207: return (double)((float(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    default: return 0.0;
    }
}

static double aowl_fast_d(void* fn, const void* mi, int32_t n,
                          uint32_t mask, const AowlFastSlot* a) {
    switch (AOWL_FAST_CODE(n, mask)) {
    case   0: return ((double(*)(const void*))fn)(mi);
    case  16: return ((double(*)(int64_t,const void*))fn)(a[0].g, mi);
    case  17: return ((double(*)(float,const void*))fn)(a[0].f, mi);
    case  32: return ((double(*)(int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, mi);
    case  33: return ((double(*)(float,int64_t,const void*))fn)(a[0].f, a[1].g, mi);
    case  34: return ((double(*)(int64_t,float,const void*))fn)(a[0].g, a[1].f, mi);
    case  35: return ((double(*)(float,float,const void*))fn)(a[0].f, a[1].f, mi);
    case  48: return ((double(*)(int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, mi);
    case  49: return ((double(*)(float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, mi);
    case  50: return ((double(*)(int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, mi);
    case  51: return ((double(*)(float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, mi);
    case  52: return ((double(*)(int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].f, mi);
    case  53: return ((double(*)(float,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].f, mi);
    case  54: return ((double(*)(int64_t,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, mi);
    case  55: return ((double(*)(float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, mi);
    case  64: return ((double(*)(int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, mi);
    case  65: return ((double(*)(float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, mi);
    case  66: return ((double(*)(int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, mi);
    case  67: return ((double(*)(float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, mi);
    case  68: return ((double(*)(int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, mi);
    case  69: return ((double(*)(float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, mi);
    case  70: return ((double(*)(int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, mi);
    case  71: return ((double(*)(float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, mi);
    case  72: return ((double(*)(int64_t,int64_t,int64_t,float,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, mi);
    case  73: return ((double(*)(float,int64_t,int64_t,float,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, mi);
    case  74: return ((double(*)(int64_t,float,int64_t,float,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, mi);
    case  75: return ((double(*)(float,float,int64_t,float,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, mi);
    case  76: return ((double(*)(int64_t,int64_t,float,float,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, mi);
    case  77: return ((double(*)(float,int64_t,float,float,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, mi);
    case  78: return ((double(*)(int64_t,float,float,float,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, mi);
    case  79: return ((double(*)(float,float,float,float,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, mi);
    case  80: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  81: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, mi);
    case  82: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  83: return ((double(*)(float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, mi);
    case  84: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  85: return ((double(*)(float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, mi);
    case  86: return ((double(*)(int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  87: return ((double(*)(float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, mi);
    case  88: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  89: return ((double(*)(float,int64_t,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, mi);
    case  90: return ((double(*)(int64_t,float,int64_t,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  91: return ((double(*)(float,float,int64_t,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, mi);
    case  92: return ((double(*)(int64_t,int64_t,float,float,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  93: return ((double(*)(float,int64_t,float,float,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, mi);
    case  94: return ((double(*)(int64_t,float,float,float,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  95: return ((double(*)(float,float,float,float,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, mi);
    case  96: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  97: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  98: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case  99: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, mi);
    case 100: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 101: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 102: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 103: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, mi);
    case 104: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 105: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 106: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 107: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, mi);
    case 108: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 109: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 110: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 111: return ((double(*)(float,float,float,float,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, mi);
    case 112: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 113: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 114: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 115: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 116: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 117: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 118: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 119: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, mi);
    case 120: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 121: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 122: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 123: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 124: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 125: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 126: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 127: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, mi);
    case 128: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 129: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 130: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 131: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 132: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 133: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 134: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 135: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 136: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 137: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 138: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 139: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 140: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 141: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 142: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 143: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, mi);
    case 144: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 145: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 146: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 147: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 148: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 149: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 150: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 151: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 152: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 153: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 154: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 155: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 156: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 157: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 158: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 159: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, mi);
    case 160: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 161: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 162: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 163: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 164: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 165: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 166: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 167: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 168: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 169: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 170: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 171: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 172: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 173: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 174: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 175: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, mi);
    case 176: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 177: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 178: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 179: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 180: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 181: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 182: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 183: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 184: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 185: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 186: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 187: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 188: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 189: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 190: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 191: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, mi);
    case 192: return ((double(*)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 193: return ((double(*)(float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 194: return ((double(*)(int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 195: return ((double(*)(float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 196: return ((double(*)(int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 197: return ((double(*)(float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 198: return ((double(*)(int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 199: return ((double(*)(float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].g, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 200: return ((double(*)(int64_t,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 201: return ((double(*)(float,int64_t,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 202: return ((double(*)(int64_t,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 203: return ((double(*)(float,float,int64_t,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].g, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 204: return ((double(*)(int64_t,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 205: return ((double(*)(float,int64_t,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].g, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 206: return ((double(*)(int64_t,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].g, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    case 207: return ((double(*)(float,float,float,float,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,const void*))fn)(a[0].f, a[1].f, a[2].f, a[3].f, a[4].g, a[5].g, a[6].g, a[7].g, a[8].g, a[9].g, a[10].g, a[11].g, mi);
    default: return 0.0;
    }
}

/* ==================================================================== *
 * Fields
 *
 * `il2cpp_field_get_offset` once at bind time, then this. A field read on the
 * boxed path is: find the FieldInfo by name, ask for its type, ask for the
 * type's *name* (which the runtime allocates and the caller frees), branch on
 * the string, call `il2cpp_field_get_value` into a scratch cell, and format
 * the result. Here it is a load.
 *
 * `obj` is the object pointer, not a GC handle: the caller is responsible for
 * having resolved one and for it still being live. That is the trade -- a GC
 * handle costs a call to dereference, which is the thing being removed.
 *
 * `memcpy` rather than `*(float*)((char*)o + off)`, for the same aliasing
 * reason the slot is a union, and because a field offset is only guaranteed to
 * be aligned for its own type. Every compiler this builds with turns a
 * fixed-size memcpy into the single load it is.
 * ==================================================================== */

static int32_t aowl_fld_i32(void* o, int32_t off) { int32_t v; memcpy(&v, (const char*)o + off, 4); return v; }
static int64_t aowl_fld_i64(void* o, int32_t off) { int64_t v; memcpy(&v, (const char*)o + off, 8); return v; }
static double  aowl_fld_f32(void* o, int32_t off) { float   v; memcpy(&v, (const char*)o + off, 4); return (double)v; }
static double  aowl_fld_f64(void* o, int32_t off) { double  v; memcpy(&v, (const char*)o + off, 8); return v; }
static int32_t aowl_fld_u8 (void* o, int32_t off) { uint8_t v; memcpy(&v, (const char*)o + off, 1); return (int32_t)v; }
static void*   aowl_fld_ptr(void* o, int32_t off) { void*   v; memcpy(&v, (const char*)o + off, sizeof(void*)); return v; }

static void aowl_fld_set_i32(void* o, int32_t off, int32_t v) { memcpy((char*)o + off, &v, 4); }
static void aowl_fld_set_i64(void* o, int32_t off, int64_t v) { memcpy((char*)o + off, &v, 8); }
static void aowl_fld_set_f32(void* o, int32_t off, double v)  { float f = (float)v; memcpy((char*)o + off, &f, 4); }
static void aowl_fld_set_f64(void* o, int32_t off, double v)  { memcpy((char*)o + off, &v, 8); }
static void aowl_fld_set_u8 (void* o, int32_t off, int32_t v) { uint8_t b = (uint8_t)(v != 0); memcpy((char*)o + off, &b, 1); }
static void aowl_fld_set_ptr(void* o, int32_t off, void* v)   { memcpy((char*)o + off, &v, sizeof(void*)); }

/* The same store, routed through the collector.
 *
 * `il2cpp_gc_wbarrier_set_field(object, void** field, value)` wants the
 * *address* of the field, not its offset, which is the only reason this is a
 * helper rather than a call made directly from nimony. `fn` is the runtime's
 * entry, already resolved -- passing it in keeps this file free of any
 * knowledge of how entries are looked up.
 *
 * Why it exists at all: a generational collector has to be told when an old
 * object starts referring to a young one. A plain store does not tell it, the
 * young object is collected while still referenced, and the crash arrives at
 * the next collection with nothing on the stack to connect it to the write. */
static void aowl_fld_set_ptr_wb(void* fn, void* o, int32_t off, void* v)
{ ((void(*)(void*, void**, void*))fn)(o, (void**)((char*)o + off), v); }

/* ==================================================================== *
 * Timing
 *
 * A binding reports what it cost, and the benchmark reports what a call costs.
 * QueryPerformanceCounter rather than GetTickCount64: the thing being measured
 * is tens of nanoseconds and the tick counter's resolution is 15 milliseconds.
 * ==================================================================== */

static int64_t aowl_perf_counter(void) {
    LARGE_INTEGER v;
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}
static int64_t aowl_perf_freq(void) {
    LARGE_INTEGER v;
    QueryPerformanceFrequency(&v);
    return (int64_t)v.QuadPart;
}

/* ==================================================================== *
 * Bench fixture -- only compiled for tools/perfbench.nim
 *
 * `tests/mockil2cpp` is faithful about almost everything, but not about this
 * one thing: its `methodPointer` is the *generic invoker* -- a
 * `void*(void*, void**)` that reads a boxed argument array -- where the real
 * runtime's is the compiled method with the declared signature. That is fine
 * for the boxed path (which is all the mock existed to test) and it makes the
 * mock useless for measuring the fast path: a typed trampoline aimed at it
 * would read a `float` out of a register holding a `void**`.
 *
 * So the benchmark brings its own compiled methods. They are shaped exactly as
 * IL2CPP compiles one -- `this` first, `const MethodInfo*` last -- and reached
 * through a `MethodInfo` whose first field is the function pointer, so the
 * measured path is the whole mechanism: read `methodPointer` by offset, check
 * it lands in an executable page, pack the slots, dispatch.
 *
 * `aowl_bench_damage` writes the mock player's `health` at offset 16, which is
 * where the mock's own metadata says that field is, so the benchmark can read
 * the result back through the *boxed* path and prove the two agree.
 *
 * What this does not establish is stated plainly in docs/PERF.md: it measures
 * the mechanism, against a stand-in, on this machine.
 * ==================================================================== */

#ifdef AOWLSPT_FAST_BENCH

typedef struct AowlBenchMethod { void* methodPointer; } AowlBenchMethod;

/* EFT.Player::Damage(System.Single) -> System.Single, instance. */
static float aowl_bench_damage(void* self, float amount, const void* mi) {
    float h;
    (void)mi;
    memcpy(&h, (const char*)self + 16, 4);
    h -= amount;
    memcpy((char*)self + 16, &h, 4);
    return h;
}
/* EFT.Player::get_Health() -> System.Single, instance. */
static float aowl_bench_get_health(void* self, const void* mi) {
    float h;
    (void)mi;
    memcpy(&h, (const char*)self + 16, 4);
    return h;
}
/* EFT.Player::Add(System.Int32, System.Int32) -> System.Int32, static.
 * Declared `int64_t` because that is what lands in RCX/RDX either way; the
 * narrowing is the callee's, exactly as it is for a real compiled method. */
static int32_t aowl_bench_add(int64_t a, int64_t b, const void* mi) {
    (void)mi;
    return (int32_t)a + (int32_t)b;
}
/* EFT.Player::Tick() -> void, instance. The cheapest possible call, so the
 * number is the dispatch cost and nothing else. */
static int32_t g_aowl_bench_ticks = 0;
static void aowl_bench_tick(void* self, const void* mi) {
    (void)self; (void)mi;
    g_aowl_bench_ticks++;
}
static int32_t aowl_bench_tick_count(void) { return g_aowl_bench_ticks; }

static AowlBenchMethod g_aowl_bench_methods[4];
static void* aowl_bench_method(int32_t which) {
    g_aowl_bench_methods[0].methodPointer = (void*)aowl_bench_damage;
    g_aowl_bench_methods[1].methodPointer = (void*)aowl_bench_get_health;
    g_aowl_bench_methods[2].methodPointer = (void*)aowl_bench_add;
    g_aowl_bench_methods[3].methodPointer = (void*)aowl_bench_tick;
    if (which < 0 || which > 3) return NULL;
    return &g_aowl_bench_methods[which];
}

#endif /* AOWLSPT_FAST_BENCH */

#endif /* AOWLSPT_FAST_H */
