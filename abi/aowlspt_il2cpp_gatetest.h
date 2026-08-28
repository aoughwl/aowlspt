/* aowlspt_il2cpp_gatetest.h -- the LIVE self-test for the token-gate layer.
 *
 * WHAT THIS IS FOR
 * ================
 * `aowlspt_il2cpp_gates.h` was proven in a SCRATCH PROCESS that mapped
 * GameAssembly.dll by hand. That is not the same claim as "it works inside
 * EscapeFromTarkov.exe". This header reproduces the scratch proof IN THE
 * CLIENT and reports a verdict to the host log.
 *
 * THE CONTROL, AND WHY "IT RETURNED SOMETHING" IS NOT A TEST
 * ==========================================================
 * On a token mismatch the export does not return NULL and does not abort: it
 * tail-calls a trap that returns MT19937-64 output. So a call that "worked"
 * and a call that was rejected are BOTH non-zero, and any check of the shape
 * `if (ret) pass;` CANNOT FAIL (CLAUDE.md 9b). The only falsifiable check is
 * the PAIR:
 *
 *   WITH the correct token   -> N calls, all IDENTICAL, and equal to a value
 *                               we know independently because WE WROTE IT into
 *                               a staged receiver we allocated ourselves;
 *   WITHOUT a token (NULL)   -> N calls, at least two DIFFERENT results, which
 *                               is the MT19937-64 stream and nothing else;
 *   WITH a CORRUPTED token   -> N calls, at least two DIFFERENT results. This
 *                               is the leg that proves THIS TEST CAN FAIL: if
 *                               a deliberately wrong token still produced the
 *                               right answer, the gate is not what gates the
 *                               export and the whole verdict is INCONCLUSIVE.
 *
 * Three outcomes, never two: PASS / FAIL / INCONCLUSIVE. "The gate refused to
 * arm" is INCONCLUSIVE, not a pass and not a failure.
 *
 * WHY THIS IS SAFE TO RUN AT HOST BOOT, WITHOUT A RAID
 * ====================================================
 * 1. The receiver is a STATIC BUFFER IN OUR OWN DLL, zeroed, with the known
 *    answer written at the offset the export reads. No live game object is
 *    touched, so the test cannot be wrong about a MethodInfo layout and cannot
 *    corrupt one. The correct answer is known because we wrote it.
 * 2. Both exports under test return a SMALL INTEGER, not a pointer. The random
 *    trap value is compared and discarded. NOTHING RETURNED BY A GATED EXPORT
 *    IS EVER DEREFERENCED HERE -- which is the rule that the no-token and
 *    corrupt-token legs would otherwise violate by construction.
 * 3. Every leg runs under exactly ONE `aowl_p_p_seh`, never nested.
 *
 * MEASURED OFFLINE FROM D:\Games\Tarkov\GameAssembly.dll (disassembly of the
 * export bytes themselves, not from any prose):
 *
 *   il2cpp_method_get_param_count @0x5B42A0
 *     48 8B C2              mov  rax, rdx          ; RDX is the token (argidx 1)
 *     48 8B D9              mov  rbx, rcx          ; RCX is the receiver
 *     48 85 D2 / 74 23      test rdx,rdx / jz ->   ; NULL token jumps STRAIGHT
 *                                                  ; to the trap tail-call
 *     41 B8 20 00 00 00     mov  r8d, 0x20         ; 32 token bytes
 *     48 8D 15 F2 05 FB 05  lea  rdx, [rip+..]     ; -> RVA 0x65648B0, which is
 *                                                  ; exactly the token_rva the
 *                                                  ; generated row records
 *     E8 .. call memcmp / 85 C0 / 75 0A            ; mismatch -> trap
 *     0F B6 43 52           movzx eax, [rbx+0x52]  ; THE READ. One byte. It is
 *     48 83 C4 20 / 5B / C3                        ; the last thing it does.
 *
 *   il2cpp_field_get_offset @0x5B3310  (NONCE flavour)
 *     41 BF 98 01 00 00     mov  r15d, 0x198       ; == the row's tls_slot
 *     49 83 3C 07 00 / 74 7E                       ; slot EMPTY -> trap
 *     48 8B CD / E8 DA 5F 00 00                    ; deriv(nonce), and
 *                                                  ; 0x5B33D6+0x5FDA = 0x5B93B0
 *                                                  ; == the row's deriv_rva
 *     41 B8 20 00 00 00 / 48 8B D0 / 48 8B CF      ; memcmp(ours, deriv, 32)
 *     85 C0 / 75 09
 *     48 63 46 18           movsxd rax, [rsi+0x18] ; THE READ. dword, signed.
 *
 * So the two staged offsets below (+0x52 byte, +0x18 dword) are MEASURED, and
 * three fields of the generated map (token_rva, tls_slot, deriv_rva) were
 * independently re-derived from the instruction stream while doing it.
 */
#ifndef AOWLSPT_IL2CPP_GATETEST_H
#define AOWLSPT_IL2CPP_GATETEST_H

#include <windows.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

#include "aowlspt_shim.h"
#include "aowlspt_il2cpp_gates.h"

#define AOWL_GT_REPS 5      /* rule 4: capped, and the scratch proof used 5   */
#define AOWL_GT_CASES 2

/* Verdicts. Deliberately NOT booleans. */
#define AOWL_GT_INCONCLUSIVE 0
#define AOWL_GT_PASS         1
#define AOWL_GT_FAIL         2

/* ---- staged receivers ---------------------------------------------------- */
/* Our own DLL's .data. Never a game pointer. 256 bytes covers both reads with
 * room to spare, and it is committed and readable for the process lifetime. */
static unsigned char aowl_gt_staged_method[256];
static unsigned char aowl_gt_staged_field[256];
static int32_t       aowl_gt_staged_ready = 0;

#define AOWL_GT_METHOD_PARAMCOUNT_OFF 0x52   /* measured: movzx eax,[rbx+0x52] */
#define AOWL_GT_FIELD_OFFSET_OFF      0x18   /* measured: movsxd rax,[rsi+0x18]*/
#define AOWL_GT_EXPECT_PARAMCOUNT     7      /* what the scratch proof staged  */
#define AOWL_GT_EXPECT_FIELDOFFSET    42

static void aowl_gt_stage(void) {
    if (aowl_gt_staged_ready) return;
    memset(aowl_gt_staged_method, 0, sizeof(aowl_gt_staged_method));
    memset(aowl_gt_staged_field,  0, sizeof(aowl_gt_staged_field));
    aowl_gt_staged_method[AOWL_GT_METHOD_PARAMCOUNT_OFF] =
        (unsigned char)AOWL_GT_EXPECT_PARAMCOUNT;
    *(int32_t*)(aowl_gt_staged_field + AOWL_GT_FIELD_OFFSET_OFF) =
        (int32_t)AOWL_GT_EXPECT_FIELDOFFSET;
    aowl_gt_staged_ready = 1;
}

/* ---- the raw (UNGATED) call, for the two negative legs ------------------- */
/* This is the call we have been making WRONG for months, made deliberately.
 * It is only ever used with an integer-returning export and a staged receiver,
 * and its result is only ever COMPARED, never dereferenced. */
typedef struct {
    void*    fn;
    void*    recv;
    void*    tok;
    int32_t  argidx;
    uint64_t ret;
    int32_t  done;     /* 0 => the call faulted and the guard caught it       */
} aowl_gt_raw_t;

static void* aowl_gt_raw_thunk(void* p) {
    aowl_gt_raw_t* c = (aowl_gt_raw_t*)p;
    typedef uint64_t (*f2)(void*, void*);
    f2 f = (f2)c->fn;
    /* Both exports under test take (receiver, token) with argidx == 1, which
     * was read off their prologues above. Anything else is refused by the
     * caller rather than guessed at here. */
    c->ret  = f(c->recv, c->tok);
    c->done = 1;
    return 0;
}

static int32_t aowl_gt_raw_call(void* fn, void* recv, void* tok, uint64_t* out) {
    aowl_gt_raw_t c;
    memset(&c, 0, sizeof(c));
    c.fn = fn; c.recv = recv; c.tok = tok;
    /* rule 3: ONE guard, and this function is never called from inside one. */
    (void)aowl_p_p_seh((void*)aowl_gt_raw_thunk, &c);
    if (!c.done) return 0;
    *out = c.ret;
    return 1;
}

/* ---- one case ------------------------------------------------------------ */
typedef struct {
    const char* name;
    int32_t     verdict;          /* AOWL_GT_*                                */
    int32_t     why;              /* the gate's AOWL_GATE_* for the good leg  */
    uint64_t    good[AOWL_GT_REPS];
    int32_t     good_n;
    uint64_t    none[AOWL_GT_REPS];
    int32_t     none_n;
    uint64_t    bad[AOWL_GT_REPS];
    int32_t     bad_n;
    uint64_t    expect;
    int32_t     good_identical;
    int32_t     good_correct;
    int32_t     none_varies;
    int32_t     bad_varies;
    char        note[192];
} aowl_gt_case_t;

static int32_t aowl_gt_all_same(const uint64_t* v, int32_t n) {
    int32_t i;
    if (n < 2) return 0;                       /* cannot conclude from one     */
    for (i = 1; i < n; i++) if (v[i] != v[0]) return 0;
    return 1;
}
static int32_t aowl_gt_any_differ(const uint64_t* v, int32_t n) {
    int32_t i;
    if (n < 2) return 0;
    for (i = 1; i < n; i++) if (v[i] != v[0]) return 1;
    return 0;
}

/* Build a token that is CORRECT except for one flipped bit. Only meaningful
 * for a STATIC row; a nonce row's negative leg is the NULL leg. */
static int32_t aowl_gt_corrupt_token(int32_t row, unsigned char* out32) {
    const aowl_gate_row_t* r;
    unsigned char* t;
    if (row < 0 || row >= AOWL_GATE_ROWS) return 0;
    r = &aowl_gate_rows[row];
    if (r->kind != AOWL_GATE_KIND_STATIC) return 0;
    if (r->token_rva == 0 || r->token_rva >= aowl_gate_size) return 0;
    t = aowl_gate_base + r->token_rva;
    if (!aowl_is_readable(t, AOWL_GATE_TOKEN_BYTES)) return 0;
    memcpy(out32, t, AOWL_GATE_TOKEN_BYTES);
    out32[0] ^= 0x01;                          /* one bit. Nothing else.       */
    return 1;
}

static void aowl_gt_run_case(aowl_gt_case_t* c, void* recv, uint64_t expect) {
    int32_t row, i;
    unsigned char* fp;
    unsigned char corrupt[AOWL_GATE_TOKEN_BYTES];
    int32_t have_corrupt = 0;

    c->verdict = AOWL_GT_INCONCLUSIVE;
    c->expect  = expect;
    c->why     = AOWL_GATE_OK;
    c->note[0] = 0;

    row = aowl_gate_find(c->name);
    if (row < 0) {
        c->why = AOWL_GATE_UNKNOWN;
        strcpy(c->note, "not in the generated gate map");
        return;
    }
    if (aowl_gate_rows[row].argidx != 1) {
        /* The raw legs hard-code (receiver, token). Refuse rather than guess. */
        c->why = AOWL_GATE_ARITY;
        strcpy(c->note, "argidx is not 1; this test only drives (recv, token)");
        return;
    }
    if (!aowl_gate_bind_module()) {
        c->why = AOWL_GATE_NO_MODULE;
        return;
    }
    fp = aowl_gate_base + aowl_gate_rows[row].export_rva;

    /* LEG 1 -- with the correct token, through the gate layer. */
    for (i = 0; i < AOWL_GT_REPS; i++) {          /* rule 4: capped */
        aowl_gate_call_t gc;
        void* argv[1];
        argv[0] = recv;
        if (!aowl_gate_call(c->name, argv, 1, &gc)) { c->why = gc.why; break; }
        c->good[c->good_n++] = (uint64_t)(uintptr_t)gc.ret;
    }
    /* LEG 2 -- no token at all: exactly the call this project made for months. */
    for (i = 0; i < AOWL_GT_REPS; i++) {          /* rule 4: capped */
        uint64_t v;
        if (!aowl_gt_raw_call(fp, recv, 0, &v)) break;
        c->none[c->none_n++] = v;
    }
    /* LEG 3 -- a deliberately CORRUPTED token. This is the leg that proves the
     * test can fail: it must NOT reproduce the correct answer. */
    have_corrupt = aowl_gt_corrupt_token(row, corrupt);
    if (have_corrupt) {
        for (i = 0; i < AOWL_GT_REPS; i++) {      /* rule 4: capped */
            uint64_t v;
            if (!aowl_gt_raw_call(fp, recv, corrupt, &v)) break;
            c->bad[c->bad_n++] = v;
        }
    }

    c->good_identical = aowl_gt_all_same(c->good, c->good_n);
    c->good_correct   = (c->good_n > 0 && c->good[0] == expect);
    c->none_varies    = aowl_gt_any_differ(c->none, c->none_n);
    c->bad_varies     = aowl_gt_any_differ(c->bad,  c->bad_n);

    /* --- the verdict. Note what is INCONCLUSIVE rather than FAIL. --- */
    if (c->good_n < 2) {
        c->verdict = AOWL_GT_INCONCLUSIVE;
        strcpy(c->note, "the gate never armed, so the good leg was not run");
        return;
    }
    if (c->none_n < 2) {
        c->verdict = AOWL_GT_INCONCLUSIVE;
        strcpy(c->note, "the no-token control leg faulted, so nothing is proven");
        return;
    }
    if (!c->none_varies) {
        /* The control did not discriminate. Either there is no trap on this
         * build, or the export is deterministic without a token -- either way
         * this test cannot distinguish a working gate from a no-op. */
        c->verdict = AOWL_GT_INCONCLUSIVE;
        strcpy(c->note, "the NO-TOKEN leg returned the SAME value every time: "
                        "the control does not discriminate, so a matching good "
                        "leg would prove nothing");
        return;
    }
    if (have_corrupt && c->bad_n >= 2 && !c->bad_varies &&
        c->bad[0] == expect) {
        c->verdict = AOWL_GT_INCONCLUSIVE;
        strcpy(c->note, "a DELIBERATELY CORRUPTED token still produced the "
                        "correct answer -- the token is not what gates this "
                        "export and the model is wrong");
        return;
    }
    if (c->good_identical && c->good_correct) {
        c->verdict = AOWL_GT_PASS;
        return;
    }
    c->verdict = AOWL_GT_FAIL;
    if (!c->good_identical)
        strcpy(c->note, "the WITH-TOKEN calls disagreed with each other, which "
                        "is trap output: the token was not accepted");
    else
        strcpy(c->note, "the WITH-TOKEN calls agreed but did not match the "
                        "value staged into the receiver");
}

/* ---- the survey: which of the 40 rows can produce a token at all --------- */
static int32_t aowl_gt_armed_static = 0;
static int32_t aowl_gt_armed_nonce  = 0;
static int32_t aowl_gt_refused      = 0;
static int32_t aowl_gt_prologue_bad = 0;
static char    aowl_gt_refusal[256];

static void aowl_gt_survey(void) {
    int32_t i, nrefused = 0;
    aowl_gt_armed_static = aowl_gt_armed_nonce = aowl_gt_refused = 0;
    aowl_gt_prologue_bad = 0;
    aowl_gt_refusal[0] = 0;
    if (!aowl_gate_bind_module()) return;
    aowl_gate_snapshot();
    for (i = 0; i < AOWL_GATE_ROWS; i++) {        /* rule 4: capped at 40 */
        int32_t why = AOWL_GATE_OK;
        void* tok;
        unsigned char* fp = aowl_gate_base + aowl_gate_rows[i].export_rva;
        if (!aowl_gate_snap_ok[i] ||
            !aowl_is_readable(fp, AOWL_GATE_SIG_BYTES) ||
            memcmp(fp, aowl_gate_snap[i], AOWL_GATE_SIG_BYTES) != 0) {
            aowl_gt_prologue_bad++;
            aowl_gt_refused++;
            continue;
        }
        /* `aowl_gate_can_arm`, NOT `aowl_gate_token`. The earlier version of
         * this loop called `aowl_gate_token`, which for a nonce row calls
         * `il2cpp_nonce` and ARMS a single-use TLS slot that only the export
         * can consume. Surveying 17 nonce rows therefore left 17 slots armed
         * on the host thread, which disabled the zero-slot early-out that had
         * been silently protecting every stock-signature by-name call in the
         * codebase, and the next such call died in memcmp at +0x6206E0 about a
         * second later. The comment that used to sit here said leaving a slot
         * armed "affects nothing else in the process". It killed the client.
         *
         * A survey must never change the state it is surveying. */
        tok = aowl_gate_can_arm(i, &why) ? (void*)1 : (void*)0;
        if (tok) {
            if (aowl_gate_rows[i].kind == AOWL_GATE_KIND_STATIC)
                aowl_gt_armed_static++;
            else
                aowl_gt_armed_nonce++;
        } else {
            aowl_gt_refused++;
            if (nrefused == 0) {
                _snprintf(aowl_gt_refusal, sizeof(aowl_gt_refusal) - 1,
                          "%s: %s", aowl_gate_rows[i].name, aowl_gate_why(why));
                aowl_gt_refusal[sizeof(aowl_gt_refusal) - 1] = 0;
            }
            nrefused++;
        }
    }
}

/* ---- the driver ---------------------------------------------------------- */
static aowl_gt_case_t aowl_gt_cases[AOWL_GT_CASES];
static int32_t        aowl_gt_ran = 0;
static int32_t        aowl_gt_pass = 0, aowl_gt_fail = 0, aowl_gt_inconc = 0;

static void aowl_gt_run(void) {
    int32_t i;
    aowl_gt_ran = 0; aowl_gt_pass = aowl_gt_fail = aowl_gt_inconc = 0;
    memset(aowl_gt_cases, 0, sizeof(aowl_gt_cases));
    aowl_gt_stage();
    aowl_gt_survey();

    aowl_gt_cases[0].name = "il2cpp_method_get_param_count";   /* STATIC gate */
    aowl_gt_run_case(&aowl_gt_cases[0], aowl_gt_staged_method,
                     (uint64_t)AOWL_GT_EXPECT_PARAMCOUNT);
    aowl_gt_cases[1].name = "il2cpp_field_get_offset";         /* NONCE gate  */
    aowl_gt_run_case(&aowl_gt_cases[1], aowl_gt_staged_field,
                     (uint64_t)AOWL_GT_EXPECT_FIELDOFFSET);

    for (i = 0; i < AOWL_GT_CASES; i++) {         /* rule 4: capped */
        aowl_gt_ran++;
        if      (aowl_gt_cases[i].verdict == AOWL_GT_PASS) aowl_gt_pass++;
        else if (aowl_gt_cases[i].verdict == AOWL_GT_FAIL) aowl_gt_fail++;
        else                                              aowl_gt_inconc++;
    }

    /* THE CHECK THAT DID NOT FIRE THE FIRST TIME, and the only one that would
     * have caught what actually killed the client. It is a property of the
     * FINISHED STATE and it is a NEGATIVE, so it can be falsified: when this
     * self-test is over, NO nonce slot may be left armed on this thread.
     *
     * The fault counter could never have caught it: the crash happened in a
     * caller that does not go through `aowl_gate_call` at all, which is why
     * the first live run logged "0 faulted" and died anyway. */
    if (aowl_gate_nonce_outstanding_count() != 0) {
        aowl_gt_pass = 0;
        aowl_gt_fail = 0;
        aowl_gt_inconc = aowl_gt_ran;
        for (i = 0; i < AOWL_GT_CASES; i++)
            aowl_gt_cases[i].verdict = AOWL_GT_INCONCLUSIVE;
    }
}

/* ---- read-out for the Nim side (no allocation, caller-owned buffer) ------ */
static int32_t aowl_gt_case_count(void)          { return AOWL_GT_CASES; }
static int32_t aowl_gt_verdict(int32_t i)        { return (i>=0 && i<AOWL_GT_CASES) ? aowl_gt_cases[i].verdict : AOWL_GT_INCONCLUSIVE; }
static int32_t aowl_gt_pass_count(void)          { return aowl_gt_pass; }
static int32_t aowl_gt_fail_count(void)          { return aowl_gt_fail; }
static int32_t aowl_gt_inconc_count(void)        { return aowl_gt_inconc; }
static int32_t aowl_gt_static_armed(void)        { return aowl_gt_armed_static; }
/* ARMABLE, not ARMED: for a nonce row this is a structural claim from the
 * generated map, because MEASURING it would mean arming a slot. */
static int32_t aowl_gt_nonce_armable(void)       { return aowl_gt_armed_nonce; }
/* Non-zero means this thread has a nonce slot armed that no export consumed,
 * i.e. the next stock-signature by-name call on it will fault in memcmp. */
static int32_t aowl_gt_leaked_arms(void)         { return aowl_gate_nonce_outstanding_count(); }
static int32_t aowl_gt_refused_count(void)       { return aowl_gt_refused; }
static int32_t aowl_gt_prologue_bad_count(void)  { return aowl_gt_prologue_bad; }
static int32_t aowl_gt_fault_count(void)         { return aowl_gate_faults; }
static const char* aowl_gt_first_refusal(void)   { return aowl_gt_refusal; }

/* One human-readable line per case, written into a caller-owned buffer. It
 * states the three legs verbatim so the log can be re-read later without the
 * reader having to trust this file's own summary. */
/* Hex by hand, NOT via `_snprintf("%llX")`: the Microsoft CRT this DLL links
 * against does not reliably honour the `ll` length modifier, and a log line
 * that is silently wrong about the very numbers the verdict rests on is worse
 * than no log line at all. */
static int32_t aowl_gt_hex(char* out, int32_t cap, uint64_t v) {
    char tmp[17];
    int32_t n = 0, i;
    if (cap < 2) { if (cap > 0) out[0] = 0; return 0; }
    if (v == 0) { tmp[n++] = '0'; }
    while (v && n < 16) { tmp[n++] = "0123456789ABCDEF"[v & 0xF]; v >>= 4; }
    if (n > cap - 1) n = cap - 1;
    for (i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    out[n] = 0;
    return n;
}

static void aowl_gt_joinhex(char* out, int32_t cap, const uint64_t* v, int32_t n) {
    int32_t k, off = 0;
    out[0] = 0;
    for (k = 0; k < n && off < cap - 20; k++) {   /* rule 4: capped */
        if (k) out[off++] = ',';
        off += aowl_gt_hex(out + off, cap - off, v[k]);
    }
    out[cap - 1] = 0;
}

/* The buffer is OURS, static, and reused: the Nim caller reads the line and
 * copies it into the log before asking for the next one. That keeps the whole
 * read-out free of per-call allocation (rule 7) and free of any Nim-string ->
 * cstring conversion, which Nimony refuses for anything but a literal. */
static char aowl_gt_linebuf[512];

static const char* aowl_gt_line(int32_t i) {
    const aowl_gt_case_t* c;
    char g[128], n[128], b[128], e[24];
    char* buf = aowl_gt_linebuf;
    const int32_t cap = (int32_t)sizeof(aowl_gt_linebuf);
    buf[0] = 0;
    if (i < 0 || i >= AOWL_GT_CASES) return buf;
    c = &aowl_gt_cases[i];

    aowl_gt_joinhex(g, (int32_t)sizeof(g), c->good, c->good_n);
    aowl_gt_joinhex(n, (int32_t)sizeof(n), c->none, c->none_n);
    aowl_gt_joinhex(b, (int32_t)sizeof(b), c->bad,  c->bad_n);
    aowl_gt_hex(e, (int32_t)sizeof(e), c->expect);

    _snprintf(buf, (size_t)(cap - 1),
              "%s: %s -- with token [%s] (expected %s); no token [%s]; "
              "corrupted token [%s]%s%s",
              c->name,
              c->verdict == AOWL_GT_PASS ? "PASS" :
              c->verdict == AOWL_GT_FAIL ? "FAIL" : "INCONCLUSIVE",
              c->good_n ? g : "not run",
              e,
              c->none_n ? n : "not run",
              c->bad_n ? b : "n/a (nonce-gated: the no-token leg IS the control)",
              c->note[0] ? " -- " : "",
              c->note[0] ? c->note : (c->why != AOWL_GATE_OK ? aowl_gate_why(c->why) : ""));
    buf[cap-1] = 0;
    return buf;
}

#endif /* AOWLSPT_IL2CPP_GATETEST_H */
