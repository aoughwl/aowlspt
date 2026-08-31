/* aowlspt_cursor.h -- free the mouse cursor while an aowlspt overlay panel is
 * open, and put back EXACTLY what the game had when the last one closes.
 *
 * THE PROBLEM
 * -----------
 * In a raid the client holds the cursor with
 * `UnityEngine.Cursor.lockState = CursorLockMode.Locked` and
 * `Cursor.visible = false`. Unity implements `Locked` by calling `SetCursorPos`
 * back to the window centre from inside the player loop, every frame. Our D3D11
 * overlay panels (F12 manager/settings, F6 admin menu) draw fine on top of that
 * -- they are rasterised in `Present` and owe nothing to Unity -- but the
 * pointer is pinned to the middle of the screen, so nothing can be clicked.
 *
 * Today it appears to work only by accident: if the player already has a game
 * menu open, the game has ALREADY unlocked the cursor and our panel inherits
 * that. That accident is also why guessing the restore value is wrong (below).
 *
 * WHY NOT ClipCursor / ShowCursor (the OS route)
 * ----------------------------------------------
 * It was considered and REJECTED, and the reason is mechanical rather than
 * stylistic. `CursorLockMode.Locked` is not a clip: the Unity player calls
 * `SetCursorPos(centre)` each frame. `ClipCursor` only bounds where the cursor
 * MAY go -- it does not stop somebody else from moving it, and the centre is
 * inside any clip rectangle we would set, so the recentring is unaffected.
 * `ShowCursor(TRUE)` is a REFERENCE COUNT that the player's own
 * `ShowCursor(FALSE)` decrements again on the next frame; racing it from
 * another thread is a coin flip that also leaks the count on the way out.
 * So the OS route cannot fix a cursor that is being teleported, and the managed
 * route -- turning the lock off at its source -- is the only one that can.
 *
 * That claim is DERIVED, not measured on this build: it follows from what
 * `CursorLockMode.Locked` means, not from an experiment run here. It is stated
 * as reasoning so the next reader can falsify it, and the feature's own
 * `reasserts` counter (below) is the instrument that settles the related
 * question of whether the client re-asserts the lock behind us.
 *
 * WHAT IT DOES
 * ------------
 * Calls four ordinary managed statics on `UnityEngine.Cursor`, each at a static
 * RVA byte-verified against the STARTUP PROLOGUE SNAPSHOT (`aowlspt_prologue.h`),
 * never against live memory:
 *
 *   UnityEngine.Cursor::get_visible    @0x5291AB0   arity 0
 *   UnityEngine.Cursor::set_visible    @0x5291B00   arity 1 (bool)
 *   UnityEngine.Cursor::get_lockState  @0x5291B50   arity 0
 *   UnityEngine.Cursor::set_lockState  @0x5291BA0   arity 1 (CursorLockMode)
 *
 * RESOLVED OFFLINE, 2026-08-28, with
 *   `tools/il2cpp_resolve.py <GameAssembly.dll> <metadata.dec> type UnityEngine.Cursor --shared`
 * on build 1.1.0.1.46777. All four are in the `il2cpp` section, all four are
 * real bodies (a stack frame plus the standard `mov rax,[rip+..]; test; jnz`
 * class-init check -- NOT the universal empty-body stub at 0x628110), and
 * `--shared` annotated NONE of them, so no RVA here is shared with another
 * method. Nothing here is DETOURED in any case: every one of the four is
 * CALLED, which is safe even on a shared address because it is correct code for
 * the receiver passed. There is no by-name binding anywhere in this file.
 *
 * `CursorLockMode` (resolved with `... enum CursorLockMode`):
 *   None = 0, Locked = 1, Confined = 2.
 *
 * Both setters are non-generic statics, so a NULL trailing `MethodInfo*` is
 * fine. Static + arity 0 puts the `MethodInfo*` in RCX; static + arity 1 puts
 * the value in ECX and the `MethodInfo*` in RDX.
 *
 * WHERE IT RUNS
 * -------------
 * On the `EFT.TarkovApplication::Update` drain -- the host's validated
 * main-thread bridge (RVA 0x977B10) -- as an ALIAS on a slot the bridge already
 * claimed. NO SECOND DETOUR is installed; a second detour on one function
 * overwrites the first's trampoline and silently kills it.
 *
 * `PreloaderUI::Update` would have been the obvious rider and is WRONG here:
 * it only ticks in the menu (see `abi/aowlspt_region.h`, and the live
 * inspector's `gInspSlot2` alias which exists for exactly this reason), and a
 * raid is the whole point of this feature. `TarkovApplication::Update` ticks
 * for the entire session, menu and raid alike.
 *
 * The Present hook was also rejected as the carrier: it is the RENDER thread,
 * and calling managed code off Unity's main thread is not something this host
 * does. The overlay only PUBLISHES a bitmask from there (a plain interlocked
 * store); the managed calls all happen on the main thread.
 *
 * ---------------------------------------------------------------------------
 * THE REF COUNT, AND WHY IT IS A MASK AND NOT A COUNTER
 * ---------------------------------------------------------------------------
 * F12, F6 and the F3 layout editor can be open at once. "Free on open, lock on
 * close" would strand the others: closing F6 while F12 is still up would relock
 * the cursor under an open panel.
 *
 * A hand-incremented counter is the obvious fix and it is the WRONG one here,
 * because it is a check that cannot fail: if a panel goes away without
 * releasing -- a module unloads, a fault path returns early, a scene change
 * tears a panel down -- the count never reaches zero and the player is left
 * with a freed cursor in a firefight, permanently, with nothing to notice it.
 *
 * So the count is derived, every tick, from a LEVEL rather than from EDGES.
 * Each source republishes its own bitmask of currently-open panels every frame
 * it runs; a source's publication EXPIRES after `AOWL_CUR_STALE_MS` of silence.
 * The live mask is the union of the unexpired publications and the "ref count"
 * is its popcount. A source that stops running therefore releases itself
 * within 400 ms without anyone having to remember to, and a source that keeps
 * running keeps its claim. That is the property a counter cannot have.
 *
 * Sources (bounded, `AOWL_CUR_SRC_COUNT` = 2, so every loop here is capped):
 *   [0] HOST     -- the F3 debug-overlay layout editor, Unity thread.
 *   [1] OVERLAY  -- the D3D11 overlay DLL, render thread, via the host export
 *                   `aowl_cursor_panels_x`. Publishes F12 and the F6 menu.
 *
 * Panel bits are for diagnostics and for the mask union; nothing keys behaviour
 * off WHICH panel is open, only off how many.
 *
 * ---------------------------------------------------------------------------
 * SAVE AND RESTORE -- against a captured value, never a constant
 * ---------------------------------------------------------------------------
 * On the rising edge (0 panels -> >0) the CURRENT `lockState` and `visible` are
 * READ FROM THE GAME and stored. On the falling edge (>0 -> 0) exactly those
 * two values are written back.
 *
 * Assuming "it was Locked and invisible" would be wrong in the common case,
 * which is precisely the case that works today: a player who opens a panel from
 * inside a game menu had `None`/visible, and restoring `Locked`/invisible would
 * take the cursor away from a menu that is still open. The restore is asserted
 * against the SAVED value, so the assertion can fail; asserting it against the
 * constant `Locked` could not.
 *
 * ---------------------------------------------------------------------------
 * DOES THE GAME FIGHT US? -- measured, not assumed
 * ---------------------------------------------------------------------------
 * This is written NOT to assume either answer. Every tick while a panel is open
 * it reads the live state back, and if the game has put the lock back on it
 * re-applies and increments `reasserts`. So:
 *
 *   reasserts == 0 over a long panel session  -> a one-shot set survives.
 *   reasserts ~= ticks                        -> the client re-asserts every
 *                                                frame and the hold is what
 *                                                makes the feature work.
 *
 * Either way the behaviour is correct; the counter turns the open question into
 * a number in the diag line rather than a guess in a comment. The hold is
 * bounded by construction -- it exists only while the live mask is non-empty,
 * and the live mask empties itself on silence.
 *
 * MOUSELOOK is deliberately NOT suppressed. See `cursorfree.nim` for the
 * decision and what would settle it.
 *
 * ---------------------------------------------------------------------------
 * THE EIGHT RULES
 * ---------------------------------------------------------------------------
 *  1. Prologue byte-verify (16 bytes, against the startup snapshot) before any
 *     call: `aowl_cur_fn`.
 *  2. `VirtualQuery` on the target page before the compare, and MEM_COMMIT +
 *     executable insisted on. There are no pointer HOPS in this feature at all
 *     -- it never dereferences a game object -- which is most of why it is
 *     small.
 *  3. ONE `aowl_p_p_seh`, installed by the caller in `cursorfree.nim`, around
 *     `aowl_cur_tick_body`. Nothing in this file adds a nested guard.
 *  4. Every loop is over `AOWL_CUR_SRC_COUNT` (2) or
 *     `AOWL_CUR_TARGET_COUNT` (4).
 *  5. Flag-gated `overlayCursorFree`, DEFAULT OFF.
 *  6. Self-disables after `AOWL_CUR_MAX_FAULTS` faults -- and RESTORES on the
 *     way out, so switching itself off can never be what leaves the cursor
 *     freed.
 *  7. No managed allocation anywhere; the per-tick cost when idle is two
 *     integer compares.
 *  8. Never blind-writes: every write is preceded by a read of the same state.
 *
 * ---------------------------------------------------------------------------
 * OFFLINE TESTABILITY
 * ---------------------------------------------------------------------------
 * The whole decision -- staleness, the union, the popcount, the save/restore
 * edges, the re-assert hold, the unwind-on-disable -- is pure arithmetic over
 * an `AowlCurState` with no pointer to anything and no call into the game.
 * Compile this header with `AOWL_CUR_PURE` defined and the live half is
 * omitted entirely, which is what `tests/overlayhost/cursortest.c` does.
 */

#ifndef AOWLSPT_CURSOR_H
#define AOWLSPT_CURSOR_H

#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * Panel bits and sources
 * ------------------------------------------------------------------ */

#define AOWL_CUR_P_OVERLAY  0x1u   /* F12 -- the manager / settings panel  */
#define AOWL_CUR_P_ADMIN    0x2u   /* F6  -- the admin menu (NOT ESP)      */
#define AOWL_CUR_P_DEBUGUI  0x4u   /* F3  -- the widget layout editor      */
#define AOWL_CUR_P_SETTINGS 0x8u   /* the GAME's own Settings screen       */
#define AOWL_CUR_P_ALL      0xFu

#define AOWL_CUR_SRC_HOST     0
#define AOWL_CUR_SRC_OVERLAY  1
#define AOWL_CUR_SRC_COUNT    2

/* How long a source's publication stays live without being refreshed. Long
 * enough that a 5 fps stall does not drop a claim mid-click; short enough that
 * a module which stopped running does not hold the cursor for a noticeable
 * time. Both sources republish once per frame. */
#define AOWL_CUR_STALE_MS  400u

/* CursorLockMode, from `il2cpp_resolve.py enum CursorLockMode`. */
#define AOWL_CUR_LOCK_NONE      0
#define AOWL_CUR_LOCK_LOCKED    1
#define AOWL_CUR_LOCK_CONFINED  2

#define AOWL_CUR_MAX_FAULTS  3

/* ------------------------------------------------------------------ *
 * The state, and the actions the pure decision can ask for
 * ------------------------------------------------------------------ */

typedef struct AowlCurPub {
    uint32_t mask;      /* panels this source says are open */
    uint64_t stampMs;   /* when it last said so; 0 = never  */
} AowlCurPub;

typedef struct AowlCurState {
    AowlCurPub pub[AOWL_CUR_SRC_COUNT];

    int32_t enabled;    /* the flag; 0 = feature off        */
    int32_t off;        /* self-disabled after faults       */

    int32_t haveSaved;  /* we are currently holding the game's state */
    int32_t savedLock;  /* ... exactly as it was read       */
    int32_t savedVis;

    /* diagnostics only */
    uint32_t liveMask;
    int32_t  panels;
    int32_t  faults;
    int64_t  frees;
    int64_t  restores;
    int64_t  reasserts;
    int64_t  ticks;
} AowlCurState;

#define AOWL_CUR_ACT_NONE     0
#define AOWL_CUR_ACT_FREE     1   /* save the current state, then unlock  */
#define AOWL_CUR_ACT_HOLD     2   /* already saved; the game relocked it  */
#define AOWL_CUR_ACT_RESTORE  3   /* write `lock`/`vis` back verbatim     */

typedef struct AowlCurAct {
    int32_t kind;
    int32_t lock;   /* meaningful for RESTORE */
    int32_t vis;
} AowlCurAct;

/* ------------------------------------------------------------------ *
 * The pure half -- no Windows, no game, no pointers
 * ------------------------------------------------------------------ */

static void aowl_cur_reset(AowlCurState* st) {
    if (!st) return;
    memset(st, 0, sizeof(*st));
}

/* A source republishes its whole mask. `nowMs` must be monotonic; a stamp of 0
 * is reserved for "never published" and is bumped to 1 so that a source which
 * genuinely publishes at t=0 is not treated as silent. */
static void aowl_cur_publish(AowlCurState* st, int32_t src,
                             uint32_t mask, uint64_t nowMs) {
    if (!st) return;
    if (src < 0 || src >= AOWL_CUR_SRC_COUNT) return;
    st->pub[src].mask    = mask & AOWL_CUR_P_ALL;
    st->pub[src].stampMs = nowMs ? nowMs : 1u;
}

/* The union of the publications that have not expired. Capped loop. */
static uint32_t aowl_cur_live_mask(const AowlCurState* st, uint64_t nowMs) {
    uint32_t m = 0;
    int32_t i;
    if (!st) return 0;
    for (i = 0; i < AOWL_CUR_SRC_COUNT; i++) {
        if (st->pub[i].stampMs == 0) continue;          /* never published */
        /* A clock that went BACKWARDS (stamp in the future) is treated as
         * fresh rather than as expired: refusing a claim because of a clock
         * glitch would relock the cursor under an open panel. */
        if (nowMs > st->pub[i].stampMs &&
            (nowMs - st->pub[i].stampMs) > (uint64_t)AOWL_CUR_STALE_MS)
            continue;
        m |= st->pub[i].mask;
    }
    return m;
}

static int32_t aowl_cur_popcount(uint32_t m) {
    int32_t n = 0;
    /* Capped: at most 32, and in practice 3. */
    while (m) { n += (int32_t)(m & 1u); m >>= 1; }
    return n;
}

/* How many panels currently claim the cursor. THIS is the ref count. */
static int32_t aowl_cur_panels(const AowlCurState* st, uint64_t nowMs) {
    return aowl_cur_popcount(aowl_cur_live_mask(st, nowMs));
}

/* THE DECISION. `curLock`/`curVis` are what the game reports RIGHT NOW; the
 * caller has just read them. Returns the action and, for RESTORE, the two
 * values to write.
 *
 * `liveMask`/`panels` are refreshed here so the diag line always describes the
 * same tick the decision was made on. */
static void aowl_cur_decide(AowlCurState* st, uint64_t nowMs,
                            int32_t curLock, int32_t curVis,
                            AowlCurAct* out) {
    uint32_t m;
    if (!out) return;
    out->kind = AOWL_CUR_ACT_NONE;
    out->lock = curLock;
    out->vis  = curVis;
    if (!st) return;

    m = aowl_cur_live_mask(st, nowMs);
    st->liveMask = m;
    st->panels   = aowl_cur_popcount(m);

    /* SWITCHED OFF -- by the flag or by the fault budget. If we are holding the
     * game's state we must give it back before going quiet. "Never leave the
     * cursor freed after our code stops running" is the whole reason this
     * branch comes FIRST and is not an early `return`. */
    if (!st->enabled || st->off) {
        if (st->haveSaved) {
            out->kind = AOWL_CUR_ACT_RESTORE;
            out->lock = st->savedLock;
            out->vis  = st->savedVis;
        }
        return;
    }

    if (st->panels > 0) {
        if (!st->haveSaved) {
            out->kind = AOWL_CUR_ACT_FREE;   /* caller saves curLock/curVis */
            return;
        }
        /* Already freed. Has the game put it back? A NEGATIVE test against the
         * live state, not a memory of what we wrote. */
        if (curLock != AOWL_CUR_LOCK_NONE || curVis == 0)
            out->kind = AOWL_CUR_ACT_HOLD;
        return;
    }

    /* No panel wants the cursor. */
    if (st->haveSaved) {
        out->kind = AOWL_CUR_ACT_RESTORE;
        out->lock = st->savedLock;
        out->vis  = st->savedVis;
    }
}

/* Bookkeeping the caller applies AFTER the action has actually been performed,
 * so a failed call does not record a state change that did not happen. */
static void aowl_cur_did_free(AowlCurState* st, int32_t savedLock,
                              int32_t savedVis) {
    if (!st) return;
    st->savedLock = savedLock;
    st->savedVis  = savedVis;
    st->haveSaved = 1;
    st->frees++;
}
static void aowl_cur_did_hold(AowlCurState* st) {
    if (st) st->reasserts++;
}
static void aowl_cur_did_restore(AowlCurState* st) {
    if (!st) return;
    st->haveSaved = 0;
    st->restores++;
}
static void aowl_cur_fault(AowlCurState* st) {
    if (!st) return;
    st->faults++;
    if (st->faults >= AOWL_CUR_MAX_FAULTS) st->off = 1;
}

/* ------------------------------------------------------------------ *
 * The live half -- omitted under AOWL_CUR_PURE
 * ------------------------------------------------------------------ */
#ifndef AOWL_CUR_PURE

/* The four targets. PROLOGUE BYTES ARE FROM THE SHIPPED GameAssembly.dll,
 * read offline with `il2cpp_resolve.py bytes <RVA>` -- not from live memory and
 * not from a name. */
typedef struct AowlCurTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlCurTarget;

static const AowlCurTarget aowl_cur_targets[] = {
    /* [0] UnityEngine.Cursor::get_visible   -- bool get_visible() */
    { "UnityEngine.Cursor::get_visible", 0x5291AB0u,
      { 0x48,0x83,0xEC,0x28, 0x48,0x8B,0x05,0xDD, 0x25,0xE4,0x01,0x48,
        0x85,0xC0,0x75,0x18 }, 16 },
    /* [1] UnityEngine.Cursor::set_visible   -- void set_visible(bool) */
    { "UnityEngine.Cursor::set_visible", 0x5291B00u,
      { 0x40,0x53,0x48,0x83, 0xEC,0x20,0x48,0x8B, 0x05,0x93,0x25,0xE4,
        0x01,0x0F,0xB6,0xD9 }, 16 },
    /* [2] UnityEngine.Cursor::get_lockState -- CursorLockMode get_lockState() */
    { "UnityEngine.Cursor::get_lockState", 0x5291B50u,
      { 0x48,0x83,0xEC,0x28, 0x48,0x8B,0x05,0x4D, 0x25,0xE4,0x01,0x48,
        0x85,0xC0,0x75,0x18 }, 16 },
    /* [3] UnityEngine.Cursor::set_lockState -- void set_lockState(CursorLockMode) */
    { "UnityEngine.Cursor::set_lockState", 0x5291BA0u,
      { 0x40,0x53,0x48,0x83, 0xEC,0x20,0x48,0x8B, 0x05,0x03,0x25,0xE4,
        0x01,0x8B,0xD9,0x48 }, 16 },
};

#define AOWL_CUR_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_cur_targets) / sizeof(aowl_cur_targets[0])))

#define AOWL_CUR_T_GETVIS   0
#define AOWL_CUR_T_SETVIS   1
#define AOWL_CUR_T_GETLOCK  2
#define AOWL_CUR_T_SETLOCK  3

/* So a refusal names its own reason instead of being indistinguishable from
 * "the feature was off". */
static int32_t aowl_cur_base_found = 0;
static int32_t aowl_cur_verified   = 0;
static int32_t aowl_cur_rejected   = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_cur_profull = 0;

static void* aowl_cur_fn(int32_t i) {
    HMODULE ga;
    const AowlCurTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_CUR_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_cur_base_found = 1;
    t = &aowl_cur_targets[i];
    p = (unsigned char*)ga + t->rva;
    /* Committed + executable BEFORE the compare: a stale RVA landing on an
     * uncommitted page would fault inside `memcmp` itself. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    /* Against the SNAPSHOT, never live memory. See aowlspt_prologue.h. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) { aowl_cur_profull++; return NULL; }
        aowl_cur_rejected++;
        return NULL;
    }
    aowl_cur_verified++;
    return (void*)p;
}

static const char* aowl_cur_name(int32_t i) {
    if (i < 0 || i >= AOWL_CUR_TARGET_COUNT) return "";
    return aowl_cur_targets[i].name;
}
static uint32_t aowl_cur_rva(int32_t i) {
    if (i < 0 || i >= AOWL_CUR_TARGET_COUNT) return 0u;
    return aowl_cur_targets[i].rva;
}
static int32_t aowl_cur_target_count(void) { return AOWL_CUR_TARGET_COUNT; }
static int32_t aowl_cur_base_ok(void)      { return aowl_cur_base_found; }
static int32_t aowl_cur_ok_count(void)     { return aowl_cur_verified; }
static int32_t aowl_cur_bad_count(void)    { return aowl_cur_rejected; }
static int32_t aowl_cur_profull_count(void){ return aowl_cur_profull; }

/* Static, arity 0: the hidden trailing `const MethodInfo*` is the ONLY
 * argument, so it goes in RCX. Static, arity 1: value in ECX, MethodInfo* in
 * RDX. NULL is fine for both -- neither is a shared generic. */
typedef int32_t (*AowlCur_Get)(void*);
typedef void    (*AowlCur_Set)(int32_t, void*);

static int32_t aowl_cur_get_lock(void) {
    void* fn = aowl_cur_fn(AOWL_CUR_T_GETLOCK);
    if (!fn) return -1;
    return ((AowlCur_Get)fn)(NULL);
}
static int32_t aowl_cur_get_vis(void) {
    void* fn = aowl_cur_fn(AOWL_CUR_T_GETVIS);
    if (!fn) return -1;
    /* A managed `bool` comes back in AL; the rest of EAX is not guaranteed. */
    return ((AowlCur_Get)fn)(NULL) & 1;
}
static int32_t aowl_cur_set_lock(int32_t v) {
    void* fn = aowl_cur_fn(AOWL_CUR_T_SETLOCK);
    if (!fn) return 0;
    ((AowlCur_Set)fn)(v, NULL);
    return 1;
}
static int32_t aowl_cur_set_vis(int32_t v) {
    void* fn = aowl_cur_fn(AOWL_CUR_T_SETVIS);
    if (!fn) return 0;
    ((AowlCur_Set)fn)(v ? 1 : 0, NULL);
    return 1;
}

/* ------------------------------------------------------------------ *
 * THE ONE PIECE OF SHARED STATE, AND THE CROSS-MODULE PUBLICATION
 * ------------------------------------------------------------------ */

static AowlCurState g_cur;

/* Published from the OVERLAY DLL's render thread, consumed on Unity's main
 * thread. Both halves are a single aligned 32-bit store/load, so the mask needs
 * no lock; the stamp is written by the same thread that writes the mask and a
 * torn pair could only ever cost one frame of latency on a value that is
 * republished every frame anyway. */
static volatile LONG g_curOvMask  = 0;
static volatile LONG g_curOvStamp = 0;   /* ms, truncated; 0 = never */

/* Called by the overlay (through the host export) once per Present. */
static void aowl_cursor_panels(int32_t mask, uint32_t nowMs) {
    InterlockedExchange(&g_curOvMask, (LONG)(mask & (int32_t)AOWL_CUR_P_ALL));
    InterlockedExchange(&g_curOvStamp, (LONG)(nowMs ? nowMs : 1u));
}

/* The HOST's own source, published from `cursorfree.nim` on the Unity thread
 * immediately before the tick body runs. This exists as a named wrapper rather
 * than a direct `aowl_cur_publish(&g_cur, ...)` from Nim because `g_cur` is
 * `static` to this translation unit and passing a NULL state pointer across the
 * boundary would make the publication a SILENT NO-OP -- which would look
 * exactly like "the F3 editor never claims the cursor" and would have been very
 * hard to see. */
static void aowl_cur_publish_host(uint32_t mask, uint64_t nowMs) {
    aowl_cur_publish(&g_cur, AOWL_CUR_SRC_HOST, mask, nowMs);
}

/* Diagnostics, so `cursorfree.nim` can name the state in one line. */
static int32_t aowl_cur_st_panels(void)    { return g_cur.panels; }
static int32_t aowl_cur_st_mask(void)      { return (int32_t)g_cur.liveMask; }
/* The union of the unexpired panel publications RIGHT NOW -- read by the UI
 * overlay-mask signal (aowlspt_uistate.h) to source its F6/F3 bits from the
 * same level the cursor feature already maintains. Folds in the overlay DLL's
 * cross-module publication so a caller need not run the tick body first. */
static uint32_t aowl_cur_live_mask_now(void) {
    LONG m = g_curOvMask, s = g_curOvStamp;
    if (s != 0) {
        g_cur.pub[AOWL_CUR_SRC_OVERLAY].mask    = (uint32_t)m & AOWL_CUR_P_ALL;
        g_cur.pub[AOWL_CUR_SRC_OVERLAY].stampMs = (uint64_t)(uint32_t)s;
    }
    return aowl_cur_live_mask(&g_cur, (uint64_t)GetTickCount64());
}
static int32_t aowl_cur_st_have_saved(void){ return g_cur.haveSaved; }
static int32_t aowl_cur_st_saved_lock(void){ return g_cur.savedLock; }
static int32_t aowl_cur_st_saved_vis(void) { return g_cur.savedVis; }
static int32_t aowl_cur_st_off(void)       { return g_cur.off; }
static int32_t aowl_cur_st_faults(void)    { return g_cur.faults; }
static int64_t aowl_cur_st_frees(void)     { return g_cur.frees; }
static int64_t aowl_cur_st_restores(void)  { return g_cur.restores; }
static int64_t aowl_cur_st_reasserts(void) { return g_cur.reasserts; }
static int64_t aowl_cur_st_ticks(void)     { return g_cur.ticks; }
static void    aowl_cur_st_enable(int32_t on) { g_cur.enabled = on ? 1 : 0; }
static int32_t aowl_cur_st_enabled(void)   { return g_cur.enabled; }

/* What the last tick actually did, so the Nim side logs TRANSITIONS only and
 * never allocates per frame. */
static int32_t aowl_cur_last_act  = AOWL_CUR_ACT_NONE;
static int32_t aowl_cur_last_lock = -1;
static int32_t aowl_cur_last_vis  = -1;
static int32_t aowl_cur_last_readback_ok = -1;  /* -1 = not attempted */

static int32_t aowl_cur_act(void)      { return aowl_cur_last_act; }
static int32_t aowl_cur_cur_lock(void) { return aowl_cur_last_lock; }
static int32_t aowl_cur_cur_vis(void)  { return aowl_cur_last_vis; }
static int32_t aowl_cur_readback(void) { return aowl_cur_last_readback_ok; }

/* ------------------------------------------------------------------ *
 * THE TICK BODY
 *
 * Called from `cursorfree.nim` under ONE `aowl_p_p_seh`. Nothing here installs
 * a nested guard -- that guard is not re-entrant and a nested one would DISARM
 * it. Returns non-NULL; a NULL return means the guard caught a fault.
 * ------------------------------------------------------------------ */
static void* aowl_cur_tick_body(void* a) {
    AowlCurAct act;
    uint64_t now;
    int32_t curLock, curVis;
    (void)a;

    now = (uint64_t)GetTickCount64();
    g_cur.ticks++;

    /* Fold in the overlay's publication. The host's own source is published
     * directly by `cursorfree.nim` before this runs. */
    {
        LONG m = g_curOvMask, s = g_curOvStamp;
        if (s != 0) {
            g_cur.pub[AOWL_CUR_SRC_OVERLAY].mask    = (uint32_t)m & AOWL_CUR_P_ALL;
            g_cur.pub[AOWL_CUR_SRC_OVERLAY].stampMs = (uint64_t)(uint32_t)s;
        }
    }

    aowl_cur_last_readback_ok = -1;

    /* FAST PATH. Nothing is open and nothing is held: two integer compares and
     * out, with NOT ONE call into the game. This is what keeps the feature free
     * for the 99.9% of frames where no panel is up. */
    if (!g_cur.haveSaved) {
        uint32_t m = aowl_cur_live_mask(&g_cur, now);
        g_cur.liveMask = m;
        g_cur.panels   = aowl_cur_popcount(m);
        if (m == 0 || !g_cur.enabled || g_cur.off) {
            aowl_cur_last_act = AOWL_CUR_ACT_NONE;
            return (void*)1;
        }
    }

    /* READ BEFORE WRITE, always. This is both rule 8 and the only way the
     * save can be of the game's real state rather than of our assumption. */
    curLock = aowl_cur_get_lock();
    curVis  = aowl_cur_get_vis();
    aowl_cur_last_lock = curLock;
    aowl_cur_last_vis  = curVis;
    if (curLock < 0 || curVis < 0) {
        /* A getter did not verify against the startup snapshot. REFUSE: do not
         * write a cursor state we could not read first. */
        aowl_cur_last_act = AOWL_CUR_ACT_NONE;
        return (void*)1;
    }

    aowl_cur_decide(&g_cur, now, curLock, curVis, &act);
    aowl_cur_last_act = act.kind;

    switch (act.kind) {
    case AOWL_CUR_ACT_FREE:
        if (aowl_cur_set_lock(AOWL_CUR_LOCK_NONE) && aowl_cur_set_vis(1))
            aowl_cur_did_free(&g_cur, curLock, curVis);
        else
            aowl_cur_last_act = AOWL_CUR_ACT_NONE;   /* a setter refused */
        break;
    case AOWL_CUR_ACT_HOLD:
        if (aowl_cur_set_lock(AOWL_CUR_LOCK_NONE) && aowl_cur_set_vis(1))
            aowl_cur_did_hold(&g_cur);
        break;
    case AOWL_CUR_ACT_RESTORE:
        if (aowl_cur_set_lock(act.lock) && aowl_cur_set_vis(act.vis)) {
            /* THE FALSIFIABLE ASSERTION. Read the FINISHED STATE back and
             * compare it against the value that was SAVED -- not against a
             * constant, and not against what we just wrote. Three outcomes: 1
             * pass, 0 fail, -1 inconclusive (the getters refused). */
            int32_t rl = aowl_cur_get_lock();
            int32_t rv = aowl_cur_get_vis();
            if (rl < 0 || rv < 0)
                aowl_cur_last_readback_ok = -1;
            else
                aowl_cur_last_readback_ok =
                    (rl == g_cur.savedLock && rv == g_cur.savedVis) ? 1 : 0;
            aowl_cur_last_lock = rl;
            aowl_cur_last_vis  = rv;
            aowl_cur_did_restore(&g_cur);
        }
        break;
    default:
        break;
    }
    return (void*)1;
}

#endif /* AOWL_CUR_PURE */
#endif /* AOWLSPT_CURSOR_H */
