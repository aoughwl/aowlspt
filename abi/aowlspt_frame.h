/* aowlspt_frame.h — the typed, allocation-free view of a patch firing.
 *
 * `AowlHostApi.patch` hands a mod its arguments as JSON. That was the right
 * first answer -- it is self-describing, it crosses the C ABI as one string,
 * and it is what made reading a hook's arguments possible at all. It is the
 * wrong answer for a method the game runs per entity per frame. Measured
 * against the stand-in runtime: an unpatched bound call is 3 ns, a postfix that
 * only watches the return value is 443 ns, and a postfix that reads the
 * arguments and replaces the result is 2320 ns. At forty bots and 60 fps that
 * last figure is 5.6 ms a frame, which is a third of the budget for one mod's
 * hooks. (Those two figures read 418 and 2245 here for a while, from an older
 * run; the live ones are the `examples/highlevel` rows in `docs/PERF.md`,
 * which `aowl test` re-measures.)
 *
 * The thunk is not the cost. Building the payload is: a JSON string per firing
 * on the host side, a GC handle per reference argument, a copy into a mod-side
 * string, and a parse. Every one of those is an allocation, and all of them
 * exist to describe a handful of machine words the thunk already saved.
 *
 * This header is the other path. It does not replace the JSON one -- a mod that
 * wants convenience keeps `hookArgs` -- it sits beside it for the mod that has
 * measured a per-frame hook and needs the machine words.
 *
 * **The mechanism, in one sentence.** The detour thunk already saves RCX, RDX,
 * R8, R9 and XMM0-3 into a frame on its own stack; the host already knows,
 * from the method's declared signature, which of those registers holds what.
 * So the host hands the mod a *borrowed view* of that frame plus the declared
 * shapes, and the mod reads a slot by index and by kind. Nothing is built,
 * nothing is copied, nothing is freed.
 *
 * **Shapes are computed once.** `kinds` points at an array the host built at
 * registration, out of `il2cpp_method_get_param` and `shapeOfType`. Per firing
 * the host stores six words into a pooled frame and calls the handler. That is
 * where the JSON path's cost really went: not the encoding, but asking the
 * runtime what everything is, every time.
 *
 * **The view must not outlive the handler**, and that is a refusal rather than
 * a comment. A frame comes from a fixed pool the host owns, and the host clears
 * `live` when the handler returns. Every accessor below checks it, refuses, and
 * records `AOWL_FRAME_EXPIRED` -- which `aowl_frame_why_text` turns into a
 * sentence naming that specific mistake. This is the same standard
 * `handle_pointer` already holds a stored patch handle to: not "do not do
 * that", but "that is refused and here is what you did".
 *
 * **What was rejected.** The obvious cheaper JSON is CBOR -- the ABI already
 * names `AOWLSPT_ENC_CBOR`, it is the same data model, and the encoder is
 * maybe five times faster. It was rejected because the shape of the cost does
 * not change: it is still an encode and a decode proportional to the argument
 * count, still a buffer somebody owns, and still a GC handle per reference. A
 * five-fold cut on 2320 ns is 464 ns, which is the *cheap* postfix's price for
 * the expensive postfix's work -- an improvement that would have to be
 * re-litigated the next time a mod put a hook on a per-bot method. Reading the
 * register the argument is already in costs nothing and cannot be made to cost
 * something later.
 *
 * Include it on its own; it needs nothing but stdint/stddef/string.
 */

#ifndef AOWLSPT_FRAME_H
#define AOWLSPT_FRAME_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * The saved register frame, by byte offset
 *
 * These are the offsets the thunk assembly in `aowlspt_detour.h` hard-codes
 * and `AowlRegs` in `aowlspt_shim.h` mirrors. They are repeated here rather
 * than taken from either, because this header is included by a *mod*, which
 * has no business pulling in the host shim or the detour engine to read four
 * machine words.
 *
 * Repetition is only safe if it is pinned, so it is: `tests/detour_test.c`
 * asserts these against the thunk's own `AOWL_REGS_BYTES` and against the
 * mirror it already keeps of the assembly. A slot that moves without this
 * following it fails to compile there.
 * ------------------------------------------------------------------ */

#define AOWL_FRAME_OFF_GPR   0x00   /* RCX, RDX, R8, R9    -- 8 bytes each */
#define AOWL_FRAME_OFF_XMM   0x20   /* XMM0-3, low 64 bits -- 8 bytes each */
#define AOWL_FRAME_OFF_RET   0x40   /* a replacement return value          */
#define AOWL_FRAME_OFF_RETF  0x48   /* XMM0 as the original left it        */
#define AOWL_FRAME_SLOTS     4      /* register positions Win64 passes in  */

/* ------------------------------------------------------------------ *
 * Declared kinds
 *
 * What one slot *is*, decided once at registration by asking the runtime.
 * A mod reads a slot by index and by kind, and a kind mismatch is refused
 * rather than reinterpreted: reading a `System.Single` argument as an integer
 * yields a number, not an error, and a number is the failure mode this whole
 * path exists to avoid.
 * ------------------------------------------------------------------ */

typedef enum AowlArgKind {
    AOWLSPT_ARG_NONE     = 0,  /* no such slot                              */
    AOWLSPT_ARG_INT      = 1,  /* integer, bool, char, IntPtr: a GPR        */
    AOWLSPT_ARG_FLOAT    = 2,  /* System.Single: the low 32 bits of an XMM  */
    AOWLSPT_ARG_DOUBLE   = 3,  /* System.Double: 64 bits of an XMM          */
    AOWLSPT_ARG_OBJECT   = 4,  /* a reference: the GPR holds its address    */
    AOWLSPT_ARG_VALUE    = 5,  /* an enum or a small struct, in a GPR       */
    AOWLSPT_ARG_BIGVALUE = 6,  /* wider than a register: the GPR holds a
                                  pointer to a copy whose layout the host
                                  cannot read. Readable as an address, and
                                  nothing more.                             */
    AOWLSPT_ARG_VOID     = 7,  /* a return only: there is no value          */
    AOWLSPT_ARG_STACK    = 8,  /* declared, but past the fourth register
                                  position, so it arrived on the stack and
                                  the thunk did not save it. Named rather
                                  than omitted, so that argument *n* is
                                  always declared parameter *n*.            */
    AOWLSPT_ARG_UNKNOWN  = 9   /* the runtime would not name a class for it */
} AowlArgKind;

/* Why the last accessor call refused. */
#define AOWL_FRAME_OK       0
#define AOWL_FRAME_EXPIRED  1   /* the handler has already returned         */
#define AOWL_FRAME_RANGE    2   /* no slot at that index                    */
#define AOWL_FRAME_KIND     3   /* that slot is not of the kind asked for    */
#define AOWL_FRAME_NOTPOST  4   /* a prefix frame has no result yet          */
#define AOWL_FRAME_NOFRAME  5   /* a null frame                              */

/* Flags on a frame. */
#define AOWL_FRAME_F_POSTFIX 0x1u  /* the original has run; `result` is real */
#define AOWL_FRAME_F_STATIC  0x2u  /* no `this`; argument 0 is register 0    */

/* ------------------------------------------------------------------ *
 * The frame
 *
 * A borrowed view. The mod is handed a `const AowlPatchFrame*` and must not
 * store it -- see `live` and the refusal machinery below.
 *
 * `size` first, as everywhere else in this ABI: a mod checks it before reading
 * anything appended in a later revision. It is a struct rather than a bag of
 * accessor calls because every read on this path has to fold into a load: an
 * accessor reached through a function pointer in `AowlHostApi` would be an
 * indirect cross-module call per argument, which is a handful of nanoseconds
 * each and a barrier the optimiser cannot see through. The layout is fixed and
 * pinned by `tests/abi_layout.c`, which is what makes reading it directly safe.
 * ------------------------------------------------------------------ */

typedef struct AowlPatchFrame {
    int32_t        size;     /* sizeof(AowlPatchFrame)                      */
    int32_t        argc;     /* declared parameters; `kinds` has this many   */
    uint32_t       flags;    /* AOWL_FRAME_F_*                               */
    uint32_t       live;     /* non-zero only while the handler is running   */
    const uint8_t* kinds;    /* AowlArgKind per declared parameter, built at
                                registration and never per firing            */
    void*          regs;     /* the thunk's saved registers, borrowed        */
    uint64_t       self;     /* `this`, or 0 for a static method             */
    uint32_t       retKind;  /* AowlArgKind of the declared return type      */
    uint32_t       serial;   /* which firing this is; for diagnostics        */
} AowlPatchFrame;

/* Why the last refusal on this translation unit's accessors.
 *
 * Per-thread where the compiler offers it, because two threads may both be
 * inside a hook on the same mod and a shared cell would hand one of them the
 * other's explanation. Per translation unit either way, which is why the
 * accessors and the reader are all `static` in this header: whoever asks gets
 * the answer their own reads produced. */
#if defined(__GNUC__)
#  define AOWL_FRAME_TLS __thread
#else
#  define AOWL_FRAME_TLS
#endif
static AOWL_FRAME_TLS int32_t g_aowlFrameWhy = AOWL_FRAME_OK;

static int32_t aowl_frame_why(void) { return g_aowlFrameWhy; }

/* The sentence for a refusal. Kept here rather than fetched from the host,
 * because the host is exactly what the fast path exists not to call -- and
 * because the most important of these describes a mistake the host would have
 * no way to see: a mod that stored the frame and read it a frame later. */
static const char* aowl_frame_why_text(int32_t why) {
    switch (why) {
        case AOWL_FRAME_OK:
            return "ok";
        case AOWL_FRAME_EXPIRED:
            return "this patch frame belongs to a firing whose handler has "
                   "already returned. A frame is borrowed for the length of "
                   "the handler and must not be stored: the registers it "
                   "views are gone, and the next firing reuses the frame. "
                   "Read what you need inside the handler, or take an address "
                   "and pin it";
        case AOWL_FRAME_RANGE:
            return "no argument at that index; the method has fewer declared "
                   "parameters than that";
        case AOWL_FRAME_KIND:
            return "that argument is not of the kind asked for. The declared "
                   "kind is fixed at registration and is what `kindOf` "
                   "reports; reading a float slot as an integer would answer "
                   "a number rather than fail";
        case AOWL_FRAME_NOTPOST:
            return "this is a prefix frame, and the original has not run yet, "
                   "so there is no result to read. A postfix frame has one";
        case AOWL_FRAME_NOFRAME:
            return "no frame";
        default:
            return "unknown";
    }
}

/* ------------------------------------------------------------------ *
 * Reading the frame
 *
 * Every accessor takes `void*` rather than `AowlPatchFrame*` because that is
 * what nimony emits for an opaque pointer, and a mismatched extern is a
 * compile error rather than a corruption to find later. Each writes `ok`
 * (optional) and leaves `g_aowlFrameWhy` set.
 * ------------------------------------------------------------------ */

static const AowlPatchFrame* aowl_frame_of(void* p) {
    const AowlPatchFrame* f = (const AowlPatchFrame*)p;
    if (!f) { g_aowlFrameWhy = AOWL_FRAME_NOFRAME; return NULL; }
    if (!f->live) { g_aowlFrameWhy = AOWL_FRAME_EXPIRED; return NULL; }
    g_aowlFrameWhy = AOWL_FRAME_OK;
    return f;
}

static int32_t aowl_frame_live(void* p) {
    const AowlPatchFrame* f = (const AowlPatchFrame*)p;
    return (f && f->live) ? 1 : 0;
}
static int32_t aowl_frame_size(void* p) {
    const AowlPatchFrame* f = (const AowlPatchFrame*)p;
    return f ? f->size : 0;
}
static int32_t aowl_frame_argc(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return f ? f->argc : 0;
}
static uint32_t aowl_frame_flags(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return f ? f->flags : 0u;
}
static uint32_t aowl_frame_serial(void* p) {
    const AowlPatchFrame* f = (const AowlPatchFrame*)p;
    return f ? f->serial : 0u;
}
static int32_t aowl_frame_is_postfix(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return (f && (f->flags & AOWL_FRAME_F_POSTFIX)) ? 1 : 0;
}
static int32_t aowl_frame_is_static(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return (f && (f->flags & AOWL_FRAME_F_STATIC)) ? 1 : 0;
}

/* The declared kind of one argument. `AOWLSPT_ARG_NONE` for an index the
 * method does not have, which is also what a dead frame answers -- so a mod
 * that branches on the kind is safe without a separate liveness test, and a
 * mod that wants to tell the two apart has `aowl_frame_why`. */
static int32_t aowl_frame_kind(void* p, int32_t i) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (!f) return AOWLSPT_ARG_NONE;
    if (i < 0 || i >= f->argc || !f->kinds) {
        g_aowlFrameWhy = AOWL_FRAME_RANGE;
        return AOWLSPT_ARG_NONE;
    }
    return (int32_t)f->kinds[i];
}

static int32_t aowl_frame_ret_kind(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return f ? (int32_t)f->retKind : AOWLSPT_ARG_NONE;
}

/* `this`, as an address. Zero for a static method and zero for a dead frame;
 * the difference is `aowl_frame_why`.
 *
 * This is the same address `handle_pointer` would give for the handle the JSON
 * payload carries, at none of the cost: the register already holds it, and no
 * GC handle was taken out to describe it. The lifetime rule is identical --
 * it is an address, the collector moves objects, use it in the handler. */
static uint64_t aowl_frame_self(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    return f ? f->self : 0u;
}

/* Which register position a declared argument landed in: an instance method's
 * `this` occupies position 0 and pushes every parameter along by one. On this
 * ABI a position picks the register *file* by the parameter's declared type,
 * rather than each file having its own counter -- so parameter 1 of an
 * instance method is RDX if it is an integer and XMM1 if it is a float. */
static int32_t aowl_frame_pos(const AowlPatchFrame* f, int32_t i) {
    return (f->flags & AOWL_FRAME_F_STATIC) ? i : i + 1;
}

static uint64_t aowl_frame_gpr(const AowlPatchFrame* f, int32_t pos) {
    uint64_t v = 0;
    memcpy(&v, (const unsigned char*)f->regs + AOWL_FRAME_OFF_GPR + pos * 8, 8);
    return v;
}
static uint64_t aowl_frame_xmm(const AowlPatchFrame* f, int32_t pos) {
    uint64_t v = 0;
    memcpy(&v, (const unsigned char*)f->regs + AOWL_FRAME_OFF_XMM + pos * 8, 8);
    return v;
}

/* An integer, enum or small value-type argument. */
static int64_t aowl_frame_int(void* p, int32_t i, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (ok) *ok = 0;
    if (!f) return 0;
    if (i < 0 || i >= f->argc || !f->kinds) {
        g_aowlFrameWhy = AOWL_FRAME_RANGE;
        return 0;
    }
    {
        uint8_t k = f->kinds[i];
        int32_t pos = aowl_frame_pos(f, i);
        if ((k != AOWLSPT_ARG_INT && k != AOWLSPT_ARG_VALUE) ||
            pos >= AOWL_FRAME_SLOTS) {
            g_aowlFrameWhy = (pos >= AOWL_FRAME_SLOTS) ? AOWL_FRAME_RANGE
                                                       : AOWL_FRAME_KIND;
            return 0;
        }
        if (ok) *ok = 1;
        return (int64_t)aowl_frame_gpr(f, pos);
    }
}

/* A `System.Single` or a `System.Double` argument, as a double.
 *
 * Two declared kinds and one reader, because the caller wants the number and
 * the *frame* knows which half of the register it is in. A `Single` occupies
 * the low 32 bits of the XMM slot and the rest is whatever the register held,
 * so reading it as a double gives a value with no relationship to the
 * argument -- which is exactly the bug this kind table exists to make
 * impossible. */
static double aowl_frame_flt(void* p, int32_t i, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (ok) *ok = 0;
    if (!f) return 0.0;
    if (i < 0 || i >= f->argc || !f->kinds) {
        g_aowlFrameWhy = AOWL_FRAME_RANGE;
        return 0.0;
    }
    {
        uint8_t k = f->kinds[i];
        int32_t pos = aowl_frame_pos(f, i);
        uint64_t bits;
        if ((k != AOWLSPT_ARG_FLOAT && k != AOWLSPT_ARG_DOUBLE) ||
            pos >= AOWL_FRAME_SLOTS) {
            g_aowlFrameWhy = (pos >= AOWL_FRAME_SLOTS) ? AOWL_FRAME_RANGE
                                                       : AOWL_FRAME_KIND;
            return 0.0;
        }
        bits = aowl_frame_xmm(f, pos);
        if (ok) *ok = 1;
        if (k == AOWLSPT_ARG_FLOAT) {
            float fv;
            uint32_t low = (uint32_t)bits;
            memcpy(&fv, &low, sizeof(fv));
            return (double)fv;
        }
        {
            double dv;
            memcpy(&dv, &bits, sizeof(dv));
            return dv;
        }
    }
}

/* A reference argument, as an address -- the thing a mod's own binding of
 * `GameAssembly.dll` takes. No GC handle is registered for it, which is the
 * single largest saving on this path: the JSON form takes one out per
 * reference and gives it back when the handler returns, and on a per-bot
 * per-frame method that is a GC handle churned per bot per frame.
 *
 * The same rule as everywhere else: it is an address, nothing keeps the object
 * still, use it inside the handler. `AOWLSPT_ARG_BIGVALUE` is readable here
 * too, because a value type wider than a register also arrives as a pointer --
 * to a copy whose layout the host cannot read, which is the mod's problem to
 * know or to leave alone. */
static uint64_t aowl_frame_ptr(void* p, int32_t i, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (ok) *ok = 0;
    if (!f) return 0;
    if (i < 0 || i >= f->argc || !f->kinds) {
        g_aowlFrameWhy = AOWL_FRAME_RANGE;
        return 0;
    }
    {
        uint8_t k = f->kinds[i];
        int32_t pos = aowl_frame_pos(f, i);
        if ((k != AOWLSPT_ARG_OBJECT && k != AOWLSPT_ARG_BIGVALUE) ||
            pos >= AOWL_FRAME_SLOTS) {
            g_aowlFrameWhy = (pos >= AOWL_FRAME_SLOTS) ? AOWL_FRAME_RANGE
                                                       : AOWL_FRAME_KIND;
            return 0;
        }
        if (ok) *ok = 1;
        return aowl_frame_gpr(f, pos);
    }
}

/* ------------------------------------------------------------------ *
 * The return value
 *
 * Readable only on a postfix frame, because on a prefix one the original has
 * not run. That is a refusal rather than a zero: a prefix handler reading
 * `result` is a mod that registered the wrong kind of patch, and finding out
 * here beats scaling a number that has not been produced yet.
 *
 * Written on either: on a prefix it is the value the caller gets instead of
 * running the original, on a postfix it is the value the caller gets instead
 * of what the original produced. One decision, one slot -- exactly as
 * `AOWLSPT_PATCH_SKIP` means "suppress" before and "replace" after.
 * ------------------------------------------------------------------ */

static const AowlPatchFrame* aowl_frame_post(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (!f) return NULL;
    if (!(f->flags & AOWL_FRAME_F_POSTFIX)) {
        g_aowlFrameWhy = AOWL_FRAME_NOTPOST;
        return NULL;
    }
    return f;
}

static int64_t aowl_frame_ret_int(void* p, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_post(p);
    if (ok) *ok = 0;
    if (!f) return 0;
    if (f->retKind != AOWLSPT_ARG_INT && f->retKind != AOWLSPT_ARG_VALUE) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    if (ok) *ok = 1;
    {
        uint64_t v = 0;
        memcpy(&v, (const unsigned char*)f->regs + AOWL_FRAME_OFF_RET, 8);
        return (int64_t)v;
    }
}

/* The float half, out of XMM0 rather than RAX. Two slots and two readers for
 * the reason the argument side has two: the thunk saved both because it has no
 * signature to consult, and only the declared return type says which is the
 * value. Reading the wrong one produces a number rather than an error. */
static double aowl_frame_ret_flt(void* p, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_post(p);
    if (ok) *ok = 0;
    if (!f) return 0.0;
    if (f->retKind != AOWLSPT_ARG_FLOAT && f->retKind != AOWLSPT_ARG_DOUBLE) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0.0;
    }
    {
        uint64_t bits = 0;
        memcpy(&bits, (const unsigned char*)f->regs + AOWL_FRAME_OFF_RETF, 8);
        if (ok) *ok = 1;
        if (f->retKind == AOWLSPT_ARG_FLOAT) {
            float fv;
            uint32_t low = (uint32_t)bits;
            memcpy(&fv, &low, sizeof(fv));
            return (double)fv;
        }
        {
            double dv;
            memcpy(&dv, &bits, sizeof(dv));
            return dv;
        }
    }
}

static uint64_t aowl_frame_ret_ptr(void* p, void* okRaw) {
    int32_t* ok = (int32_t*)okRaw;
    const AowlPatchFrame* f = aowl_frame_post(p);
    if (ok) *ok = 0;
    if (!f) return 0;
    if (f->retKind != AOWLSPT_ARG_OBJECT) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    if (ok) *ok = 1;
    {
        uint64_t v = 0;
        memcpy(&v, (const unsigned char*)f->regs + AOWL_FRAME_OFF_RET, 8);
        return v;
    }
}

/* Writing a replacement. Returns 1 when it was written and 0 when it was
 * refused, so a handler can decide not to claim a replacement it could not
 * make -- a `SKIP` with nothing written is the original suppressed and
 * whatever happened to be in RAX handed back, which is the worst outcome
 * available on this path. */
static int32_t aowl_frame_set_ret_int(void* p, int64_t v) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (!f) return 0;
    if (f->retKind != AOWLSPT_ARG_INT && f->retKind != AOWLSPT_ARG_VALUE) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    {
        uint64_t bits = (uint64_t)v;
        memcpy((unsigned char*)f->regs + AOWL_FRAME_OFF_RET, &bits, 8);
    }
    return 1;
}

/* A `Single` replacement occupies the low 32 bits of the slot; a `Double`
 * fills it. The thunk moves that slot into both RAX and XMM0 on the way out,
 * so what matters is that the bits are laid out the way the declared type
 * expects to find them. */
static int32_t aowl_frame_set_ret_flt(void* p, double v) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    uint64_t bits = 0;
    if (!f) return 0;
    if (f->retKind == AOWLSPT_ARG_FLOAT) {
        float fv = (float)v;
        uint32_t low = 0;
        memcpy(&low, &fv, sizeof(fv));
        bits = low;
    } else if (f->retKind == AOWLSPT_ARG_DOUBLE) {
        memcpy(&bits, &v, sizeof(v));
    } else {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    memcpy((unsigned char*)f->regs + AOWL_FRAME_OFF_RET, &bits, 8);
    return 1;
}

static int32_t aowl_frame_set_ret_ptr(void* p, uint64_t v) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    if (!f) return 0;
    if (f->retKind != AOWLSPT_ARG_OBJECT) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    memcpy((unsigned char*)f->regs + AOWL_FRAME_OFF_RET, &v, 8);
    return 1;
}

/* Suppressing a `void` method. There is nothing to write, and saying so
 * explicitly is what distinguishes "I mean to suppress this" from "I forgot to
 * produce a value". */
static int32_t aowl_frame_set_ret_void(void* p) {
    const AowlPatchFrame* f = aowl_frame_of(p);
    uint64_t zero = 0;
    if (!f) return 0;
    if (f->retKind != AOWLSPT_ARG_VOID) {
        g_aowlFrameWhy = AOWL_FRAME_KIND;
        return 0;
    }
    memcpy((unsigned char*)f->regs + AOWL_FRAME_OFF_RET, &zero, 8);
    return 1;
}

/* ------------------------------------------------------------------ *
 * The pool
 *
 * The host arms a frame, calls the handler, and disarms it. The frames come
 * from a fixed array rather than the stack or the heap, and both of those
 * choices are the point:
 *
 *  - Not the heap, because this path exists to allocate nothing.
 *  - Not the host's stack, because the refusal has to be a *refusal*. A mod
 *    that stored the pointer and read it next frame would be reading a stack
 *    slot some other call has since used, which is undefined behaviour rather
 *    than an error message. A pooled frame is still there, with `live` clear,
 *    and every accessor above says so.
 *
 * Indexed by patch depth, because a handler is free to call something the host
 * has also patched. Eight is far more nesting than a detour on a game method
 * has ever produced; past it the typed handler is not fired at all: the host
 * counts the firing and lets the original run, because reusing a live frame
 * would hand the inner handler the outer firing's registers -- a plausible set
 * of arguments rather than an error. This used to say the host fell back to
 * the JSON path there; it does not, and the host has no payload built at that
 * point to fall back to.
 *
 * `static` here means each translation unit gets its own array. Only the host
 * ever arms one; a mod links the pool as dead weight and never touches it,
 * which is a few hundred bytes of BSS against not needing a second header.
 * ------------------------------------------------------------------ */

#define AOWL_FRAME_DEPTH 8

static AowlPatchFrame g_aowlFramePool[AOWL_FRAME_DEPTH];
static uint32_t g_aowlFrameSerial = 0;

static int32_t aowl_frame_depth_max(void) { return AOWL_FRAME_DEPTH; }
static int32_t aowl_frame_sizeof(void) { return (int32_t)sizeof(AowlPatchFrame); }

/* The frame for one nesting depth, or NULL past the pool. */
static void* aowl_frame_slot(int32_t depth) {
    if (depth < 0 || depth >= AOWL_FRAME_DEPTH) return NULL;
    return (void*)&g_aowlFramePool[depth];
}

/* Arms a frame over the thunk's saved registers and the shapes the host
 * computed at registration. Every field is a store; nothing is asked of the
 * runtime and nothing is allocated. */
static void aowl_frame_arm(void* p, void* regs, const void* kinds,
                           int32_t argc, int32_t retKind, uint32_t flags,
                           uint64_t self) {
    AowlPatchFrame* f = (AowlPatchFrame*)p;
    if (!f) return;
    f->size    = (int32_t)sizeof(AowlPatchFrame);
    f->argc    = argc;
    f->flags   = flags;
    f->kinds   = (const uint8_t*)kinds;
    f->regs    = regs;
    f->self    = self;
    f->retKind = (uint32_t)retKind;
    f->serial  = ++g_aowlFrameSerial;
    /* Last, and that order is load-bearing: `live` is the one thing a mod is
     * told it may trust before reading anything else, so it must never be set
     * while `regs` or `kinds` is still the previous firing's. */
    f->live    = 1u;
}

/* Disarms it. `live` first, for the mirror image of the reason above, and then
 * the pointers are cleared so that a mod which stored the frame and ignored
 * every refusal reads a null rather than a stale register frame. */
static void aowl_frame_disarm(void* p) {
    AowlPatchFrame* f = (AowlPatchFrame*)p;
    if (!f) return;
    f->live  = 0u;
    f->regs  = NULL;
    f->kinds = NULL;
    f->self  = 0u;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* AOWLSPT_FRAME_H */
