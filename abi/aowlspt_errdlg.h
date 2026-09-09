/* aowlspt_errdlg.h -- CATCH THE IN-GAME ERROR DIALOG for the post-1.0 EFT host.
 *
 * ## Why this exists
 *
 * The client has a failure mode that neither of our two watchers could see. It
 * does not exit, it does not write an Error-level log record, and the host log
 * keeps ticking over: it puts a MODAL ERROR WINDOW on screen and waits forever
 * for a human to click it. From outside, that is byte-for-byte indistinguishable
 * from the game sitting idle at profile-select -- which is the normal, healthy
 * end state of every scripted launch we do (harness.py reports it as IDLE, and
 * IDLE is usually correct).
 *
 * So an error dialog during an unattended `autoraid` run reads as "still going"
 * for the entire timeout. Measured cost of exactly that, recorded in the fact
 * store: a raid-load break put up an in-game error dialog and the session sat
 * stuck for ~12 minutes before anyone realised.
 *
 * A dialog is not a hang. It is a CRASH that happens to have a button on it, and
 * this header is what lets the outside world find out about it in the same second
 * the client decides to show one.
 *
 * ## The approach: catch it where it is RAISED, not where it is rendered
 *
 * The alternative -- polling the scene graph for an active error window -- costs
 * a Unity-thread walk every poll, and can only ever say "a dialog is up now",
 * never "here is what it said". Every error window in this client is raised
 * through one of three `EFT.UI.PreloaderUI` entry points, and two of the three
 * take the header AND the message as plain `System.String` arguments, in
 * registers, at the moment of the call. Detour those and the text is free.
 *
 * ## The targets (resolved offline against build 1.1.0.1.46777, all UNIQUE)
 *
 * Every RVA below was resolved with `tools/il2cpp_resolve.py methods ErrorScreen`
 * and each was independently checked with the `shared` verb -- all three report
 * `sharedness=UNIQUE owners=1`, so detouring them by RVA has no blast radius
 * beyond the method named. (CLAUDE.md section 5: 28.3% of by-name lookups land
 * on a SHARED RVA and detouring one of those fires for every method that shares
 * it. These are not those.) Prologue bytes are from the `bytes` verb; the `shape`
 * check reported "no known thunk shape matched" for all three, i.e. none of them
 * is this build's universal 6,438-method empty-body stub.
 *
 *   [0] EFT.UI.PreloaderUI::ShowErrorScreen(string header, string message,
 *                                           Action acceptCallback)  @0x156B930
 *       48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41
 *       RCX=this  RDX=header  R8=message  R9=callback
 *       The ordinary in-game error dialog. Both strings are right there.
 *
 *   [1] EFT.UI.PreloaderUI::ShowErrorScreen(string header, Exception exception,
 *                                           Action acceptCallback)  @0x156B7E0
 *       48 89 5C 24 10 48 89 6C 24 18 48 89 74 24 20 41
 *       RCX=this  RDX=header  R8=Exception  R9=callback
 *       The overload the raid-load cascade comes through. R8 is an object, so the
 *       text is read out of System.Exception's fields instead (offsets below).
 *
 *   [2] EFT.UI.PreloaderUI::ShowCriticalErrorScreen(string header, string message,
 *                                    EButtonType buttonType, float waitingTime)
 *                                                              @0x156BC20
 *       40 53 56 41 54 41 56 41 57 48 83 EC 40 80 3D A8
 *       RCX=this  RDX=header  R8=message  R9=EButtonType (enum, by value)
 *       The unrecoverable one -- "quit to desktop" class.
 *
 * ## READ-ONLY. The dialog is never suppressed.
 *
 * All three are POSTFIX detours that log and return 0, so the original always
 * runs and the window still appears exactly as it would have. We are adding an
 * observer, not changing behaviour: a human at the keyboard sees no difference.
 * That matters because suppressing the window would hide the error from the
 * person as well as reveal it to the tooling, which is a strictly worse trade.
 *
 * ## System.Exception field offsets (resolved offline, same build)
 *
 *   _className        string  @0x10
 *   _message          string  @0x18
 *   _stackTraceString string  @0x40
 *
 * `_className` is frequently NULL on this runtime (the CLR fills it lazily, and
 * usually only during serialisation). That is why an empty class name is reported
 * as absent rather than papered over -- an invented type name in a crash report
 * is worse than no type name.
 *
 * ## Safety
 *
 * Same discipline as `aowlspt_botcap.h`, which this is modelled on, minus the one
 * thing that file does that this one does not: THIS HEADER NEVER WRITES. It
 * locates and verifies code pointers against the startup prologue snapshot, and
 * it reads strings through `VirtualQuery`-guarded hops that refuse an
 * uncommitted or non-readable slot instead of dereferencing it. The Nim body that
 * calls into it runs under the VEH/SEH guard, so even a valid-looking pointer
 * into an unmapped page cannot reach the game.
 */

#ifndef AOWLSPT_ERRDLG_H
#define AOWLSPT_ERRDLG_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- System.String layout. Self-checked everywhere in this repo:
 * _stringLength @0x10 (int32), _firstChar @0x14 (UTF-16). ---- */
#define AOWL_ED_STR_LEN_OFF    0x10
#define AOWL_ED_STR_CHARS_OFF  0x14

/* ---- System.Exception field offsets (offline-resolved, see the header note) ---- */
#define AOWL_ED_EXC_CLASSNAME_OFF  0x10
#define AOWL_ED_EXC_MESSAGE_OFF    0x18
#define AOWL_ED_EXC_STACK_OFF      0x40

static int32_t aowl_ed_off_exc_message(void)   { return AOWL_ED_EXC_MESSAGE_OFF; }
static int32_t aowl_ed_off_exc_classname(void) { return AOWL_ED_EXC_CLASSNAME_OFF; }
static int32_t aowl_ed_off_exc_stack(void)     { return AOWL_ED_EXC_STACK_OFF; }

/* A pointer that could plausibly be a live IL2CPP object: canonical user-space,
 * above the null page, below the non-canonical hole. Rejects a small integer or
 * a kernel address handed to us by a register we misread. */
static int32_t aowl_ed_sane(void* p) {
    uint64_t v = (uint64_t)(uintptr_t)p;
    return (v >= 0x10000ull && v < 0x00007FFFFFFFFFFFull) ? 1 : 0;
}

/* Is [at, at+len) inside ONE committed, readable region? Never dereferences. */
static int32_t aowl_ed_slot_readable(void* at, size_t len) {
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t start, end, need;
    if (!at || len == 0) return 0;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    start = (uintptr_t)mbi.BaseAddress;
    end   = start + (uintptr_t)mbi.RegionSize;
    need  = (uintptr_t)at + (uintptr_t)len;
    if (need < (uintptr_t)at) return 0;      /* wrapped */
    if (need > end) return 0;
    return 1;
}

static int32_t aowl_ed_read_i32(void* p, int32_t off, int32_t* ok) {
    int32_t v = 0;
    char* at;
    if (ok) *ok = 0;
    if (!aowl_ed_sane(p)) return 0;
    at = (char*)p + off;
    if (!aowl_ed_slot_readable(at, 4)) return 0;
    memcpy(&v, at, 4);
    if (ok) *ok = 1;
    return v;
}

static void* aowl_ed_read_ptr(void* p, int32_t off, int32_t* ok) {
    void* v = NULL;
    char* at;
    if (ok) *ok = 0;
    if (!aowl_ed_sane(p)) return NULL;
    at = (char*)p + off;
    if (!aowl_ed_slot_readable(at, sizeof(void*))) return NULL;
    memcpy(&v, at, sizeof(void*));
    if (ok) *ok = 1;
    return v;
}

/* Copy up to cap-1 chars of the System.String AT `s` (not at s+off) into `out`
 * as ASCII; non-ASCII and control characters become '?' so one line of host log
 * stays one line of host log. Returns chars written; 0 means "could not read",
 * which the caller must report as unknown rather than as an empty message. */
static int32_t aowl_ed_str_at(void* s, char* out, int32_t cap) {
    int32_t ok = 0, n, i;
    unsigned short* chars;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    if (!aowl_ed_sane(s)) return 0;
    n = aowl_ed_read_i32(s, AOWL_ED_STR_LEN_OFF, &ok);
    if (!ok || n <= 0) return 0;
    if (n > cap - 1) n = cap - 1;
    chars = (unsigned short*)((char*)s + AOWL_ED_STR_CHARS_OFF);
    if (!aowl_ed_slot_readable((void*)chars, (size_t)n * 2u)) return 0;
    for (i = 0; i < n; i++) {
        unsigned short c = chars[i];
        /* Collapse newlines/tabs too: a multi-line .NET message must not break
         * the one-line-per-event contract the log readers depend on. */
        out[i] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
    }
    out[n] = 0;
    return n;
}

/* Read a System.String FIELD at obj+off. Same contract as above. */
static int32_t aowl_ed_str_field(void* obj, int32_t off, char* out, int32_t cap) {
    int32_t ok = 0;
    void* s;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    s = aowl_ed_read_ptr(obj, off, &ok);
    if (!ok) return 0;
    return aowl_ed_str_at(s, out, cap);
}

/* ------------------------------------------------------------------ *
 * The three hook targets. Same self-checking shape as aowlspt_botcap.h:
 * locate GameAssembly, VirtualQuery the RVA for committed executable memory,
 * memcmp the recorded prologue against the STARTUP SNAPSHOT (aowlspt_prologue.h)
 * rather than against live memory -- so a target another feature has already
 * patched still verifies against what it originally was, instead of the
 * trampoline. NULL on any mismatch: a missed bind, never a corrupted game.
 */
/* How the detour body must READ R8 for this row. This is a PROPERTY OF THE ROW,
 * carried in the row, deliberately NOT derived from the row's index.
 *
 * The Nim side sweeps this table and claims a detour `kind` per row, so the row
 * ORDER decides which slot a target lands in -- that part is harmless plumbing,
 * any row can have any slot. What is NOT harmless is the argument shape: on two
 * of these rows R8 is a `System.String` and on the third it is a
 * `System.Exception`, and reading one as the other means walking an object
 * header as if it were a UTF-16 length. If the shape were computed as
 * `index - base`, inserting a row above would silently repoint it (fact #187:
 * an inserted row shifts every index below it and nothing else notices). Storing
 * it here means the shape moves WITH the row when the table is reordered.
 */
#define AOWL_ED_SHAPE_STRING     0   /* R8 is System.String  -- read directly  */
#define AOWL_ED_SHAPE_EXCEPTION  1   /* R8 is System.Exception -- read fields  */

/* Stable identifiers for the reported `kind=` in the log line. Also row data,
 * for the same reason. */
#define AOWL_ED_SEV_ERROR     0
#define AOWL_ED_SEV_CRITICAL  1

typedef struct AowlEdTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
    int32_t             shape;   /* AOWL_ED_SHAPE_* -- how to read R8         */
    int32_t             severity;/* AOWL_ED_SEV_*                             */
    const char*         kind;    /* the literal that appears as kind= in the log */
} AowlEdTarget;

static const AowlEdTarget aowl_ed_targets[] = {
    /* [0] ShowErrorScreen(string header, string message, Action cb) @0x156B930 */
    { "EFT.UI.PreloaderUI::ShowErrorScreen(string,string,Action)", 0x156B930u,
      { 0x48,0x89,0x6C,0x24,0x10, 0x48,0x89,0x74,0x24,0x18,
        0x48,0x89,0x7C,0x24,0x20, 0x41 }, 16,
      AOWL_ED_SHAPE_STRING, AOWL_ED_SEV_ERROR, "message" },
    /* [1] ShowErrorScreen(string header, Exception ex, Action cb) @0x156B7E0 */
    { "EFT.UI.PreloaderUI::ShowErrorScreen(string,Exception,Action)", 0x156B7E0u,
      { 0x48,0x89,0x5C,0x24,0x10, 0x48,0x89,0x6C,0x24,0x18,
        0x48,0x89,0x74,0x24,0x20, 0x41 }, 16,
      AOWL_ED_SHAPE_EXCEPTION, AOWL_ED_SEV_ERROR, "exception" },
    /* [2] ShowCriticalErrorScreen(string,string,EButtonType,float) @0x156BC20 */
    { "EFT.UI.PreloaderUI::ShowCriticalErrorScreen", 0x156BC20u,
      { 0x40,0x53,0x56,0x41,0x54,0x41,0x56,0x41,0x57,
        0x48,0x83,0xEC,0x40, 0x80,0x3D,0xA8 }, 16,
      AOWL_ED_SHAPE_STRING, AOWL_ED_SEV_CRITICAL, "critical" },
};

#define AOWL_ED_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_ed_targets) / sizeof(aowl_ed_targets[0])))

static int32_t aowl_ed_ok_count  = 0;
static int32_t aowl_ed_bad_count = 0;

static void* aowl_ed_target_at(int32_t i) {
    HMODULE ga;
    const AowlEdTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_ED_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;

    t = &aowl_ed_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { aowl_ed_bad_count++; return NULL; }
    if (mbi.State != MEM_COMMIT)                 { aowl_ed_bad_count++; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_ed_bad_count++; return NULL;
    }
    /* Against the SNAPSHOT, not live memory -- see aowlspt_prologue.h. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        aowl_ed_bad_count++; return NULL;
    }
    aowl_ed_ok_count++;
    return (void*)p;
}

static const char* aowl_ed_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_ED_TARGET_COUNT) return "";
    return aowl_ed_targets[i].name;
}

/* The row's own argument shape and reported kind. Read at BIND time and carried
 * alongside the slot, so a reordered table moves them with the row instead of
 * repointing them (see the AOWL_ED_SHAPE_* note above). An out-of-range index
 * returns the EXCEPTION shape, which is the conservative direction: it reads R8
 * through the guarded field readers rather than treating an arbitrary object as
 * a System.String and trusting its +0x10 as a character count. */
static int32_t aowl_ed_target_shape(int32_t i) {
    if (i < 0 || i >= AOWL_ED_TARGET_COUNT) return AOWL_ED_SHAPE_EXCEPTION;
    return aowl_ed_targets[i].shape;
}

static const char* aowl_ed_target_kind(int32_t i) {
    if (i < 0 || i >= AOWL_ED_TARGET_COUNT) return "unknown";
    return aowl_ed_targets[i].kind;
}

static int32_t aowl_ed_target_severity(int32_t i) {
    if (i < 0 || i >= AOWL_ED_TARGET_COUNT) return AOWL_ED_SEV_ERROR;
    return aowl_ed_targets[i].severity;
}

static int32_t aowl_ed_target_count(void) { return AOWL_ED_TARGET_COUNT; }
static int32_t aowl_ed_verified_count(void) { return aowl_ed_ok_count; }
static int32_t aowl_ed_rejected_count(void) { return aowl_ed_bad_count; }

/* Prime the prologue snapshot for all three targets at host startup, before any
 * feature has patched anything. Returns how many were captured. Calling this is
 * belt-and-braces: aowl_pro_verify captures lazily on first use and that is
 * still correct, because a target's first verify precedes its first patch. */
static int32_t aowl_ed_prime_all(void) {
    int32_t i, n = 0;
    for (i = 0; i < AOWL_ED_TARGET_COUNT; i++)
        if (aowl_pro_prime(aowl_ed_targets[i].rva)) n++;
    return n;
}

#endif /* AOWLSPT_ERRDLG_H */
