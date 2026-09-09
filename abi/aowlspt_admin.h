/* aowlspt_admin.h -- the shared surface between the admin/cheat mod and the
 * native D3D11 HUD that draws it inside the game's Present hook.
 *
 * ## Why this file exists
 *
 * The admin cheats split across two modules and two threads, and on this client
 * build the split is forced rather than chosen:
 *
 *   * The managed Unity-thread bridge is dead on build 1.1.0.1.46777 -- the
 *     runtime `MethodInfo.methodPointer` is null/stripped for the per-frame
 *     methods an anti-cheat cares about, so calling a managed game method
 *     (`il2cpp_runtime_invoke` / a bound method pointer) is not available. What
 *     still works is **reading and writing object memory by field offset**
 *     (`il2cpp_field_get_offset` -> `*(T*)(object + offset)`), which is a plain
 *     memory access and needs no Unity thread and no method pointer.
 *
 *   * So the **producer** (`mods/admin`) reads the world by field offset -- on
 *     any thread, since a memory read is thread-agnostic -- projects every
 *     player to screen, and publishes the result here. It calls **no** managed
 *     method.
 *
 *   * The **consumer** is the D3D11 HUD in `abi/aowlspt_overlay.h`, drawn once a
 *     frame inside the game's own `IDXGISwapChain::Present` -- the same place
 *     Steam/Discord/RivaTuner draw, and the same place the overlay and the
 *     graphics post-process already draw. It reads the published frame and draws
 *     boxes/lines/text. This is a HUD draw on the game's frame, not the vetoed
 *     mod-manager UI.
 *
 * Two modules cannot share a C `static` global, so the state they share lives in
 * a named shared-memory region both map by name. It carries the toggles (the F6
 * menu writes, the mod reads), a seqlock-protected frame of pre-projected
 * entities (the mod writes, the HUD reads), a capability mask + status line so
 * the menu can say "unavailable" honestly, and the menu's own open/selection
 * state so the F6 keypress (captured in the overlay WndProc) and the draw agree.
 *
 * ## Safety
 *
 * Pure Win32 + stdint; no overlay call, no IL2CPP call. Every field the consumer
 * reads is bounded and the frame is a seqlock, so a half-written frame is
 * retried, not drawn. If the mod never maps the region, the HUD maps an empty
 * one, every capability bit is 0, and the menu draws every mode "unavailable" --
 * safe by default. Nothing here can fault the game: an absent or stale producer
 * is a HUD that draws nothing, never a crash.
 */

#ifndef AOWLSPT_ADMIN_H
#define AOWLSPT_ADMIN_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* OPT-IN PHASE INSTRUMENTATION. `mods/admin` defines AOWL_ADM_PROF before
 * including this header, so the L4 brackets inside `aowl_admin_pos_live` below
 * exist only in the mod's translation units. The OVERLAY includes this same
 * header and does NOT define it, so it gets no brackets, no extern references
 * and no link dependency on the profiler's translation unit. With the macro
 * undefined every bracket compiles to `((void)0)` -- there is no runtime test,
 * so an un-instrumented build pays nothing at all rather than paying a branch.
 * With it defined the brackets are still no-ops until `aowl_ap_set_enabled(1)`
 * is called, which is flag-gated and DEFAULT OFF (CLAUDE.md 5). */
#ifdef AOWL_ADM_PROF
#include "aowlspt_admprof.h"
#define AOWL_APB(v)       int64_t v = aowl_ap_now()
#define AOWL_APE(slot, v) aowl_ap_add((slot), (v))
#else
#define AOWL_APB(v)       ((void)0)
#define AOWL_APE(slot, v) ((void)0)
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * The toggles. One bit each in `toggles` (owned by the F6 menu) and
 * `capability` (owned by the mod: the modes it actually armed on this build).
 * The order here is the order the menu lists them.
 * ------------------------------------------------------------------ */

enum {
    AOWL_ADM_ESP        = 0,
    AOWL_ADM_GODMODE    = 1,
    AOWL_ADM_STAMINA    = 2,
    AOWL_ADM_NORECOIL   = 3,
    AOWL_ADM_NOWEIGHT   = 4,
    AOWL_ADM_INSTAHEAL  = 5,
    AOWL_ADM_AMMO       = 6,
    AOWL_ADM_THERMAL    = 7,
    AOWL_ADM_NIGHTVIS   = 8,
    AOWL_ADM_FLY        = 9,
    AOWL_ADM_TELEPORT   = 10,
    AOWL_ADM_TIMEOFDAY  = 11,
    AOWL_ADM_COUNT      = 12
};

/* EVERY cheat off. Seeded once by the mod.
 *
 * ESP and God mode used to default ON here. For a build handed to testers a
 * cheat must default OFF -- the player opts in from the F6 menu or the settings
 * screen. This is the same default the schema and config.json now carry; all
 * three have to agree or the "default" depends on which one ran last. */
#define AOWL_ADM_DEFAULTS  ((uint32_t)0)

/* The menu label for one mode. Shared so the HUD and the mod's log agree. */
static const char* aowl_admin_mode_name(int32_t bit) {
    switch (bit) {
        case AOWL_ADM_ESP:       return "ESP";
        case AOWL_ADM_GODMODE:   return "God mode";
        case AOWL_ADM_STAMINA:   return "Infinite stamina";
        case AOWL_ADM_NORECOIL:  return "No recoil / sway";
        case AOWL_ADM_NOWEIGHT:  return "No weight";
        case AOWL_ADM_INSTAHEAL: return "Instant heal";
        case AOWL_ADM_AMMO:      return "Unlimited ammo";
        case AOWL_ADM_THERMAL:   return "Thermal vision";
        case AOWL_ADM_NIGHTVIS:  return "Night vision";
        case AOWL_ADM_FLY:       return "Fly / noclip";
        case AOWL_ADM_TELEPORT:  return "Teleport to marker";
        case AOWL_ADM_TIMEOFDAY: return "Set time of day";
        default:                 return "?";
    }
}

/* ------------------------------------------------------------------ *
 * THE MENU ROWS.
 *
 * The first AOWL_ADM_COUNT rows are the toggles above, one row each. The four
 * after them are the item spawner, which is NOT a toggle: it is a query the
 * player types, two numbers, and a submit. Keeping them in the same row space
 * means the F6 menu has one selection index and one set of arrow keys, rather
 * than a mode within a mode.
 * ------------------------------------------------------------------ */

enum {
    AOWL_ADM_ROW_QUERY = AOWL_ADM_COUNT + 0,   /* typed: WM_CHAR / backspace  */
    AOWL_ADM_ROW_COUNT = AOWL_ADM_COUNT + 1,   /* left/right: 1..5000          */
    AOWL_ADM_ROW_COND  = AOWL_ADM_COUNT + 2,   /* left/right: 1..100 percent   */
    AOWL_ADM_ROW_SPAWN = AOWL_ADM_COUNT + 3,   /* Enter: submit                */
    AOWL_ADM_ROW_TOTAL = AOWL_ADM_COUNT + 4
};

static int32_t aowl_admin_row_is_toggle(int32_t row) {
    return (row >= 0 && row < AOWL_ADM_COUNT) ? 1 : 0;
}

static const char* aowl_admin_row_name(int32_t row) {
    switch (row) {
        case AOWL_ADM_ROW_QUERY: return "Item";
        case AOWL_ADM_ROW_COUNT: return "How many";
        case AOWL_ADM_ROW_COND:  return "Condition %";
        case AOWL_ADM_ROW_SPAWN: return "SPAWN  (Enter)";
        default:                 return aowl_admin_mode_name(row);
    }
}

/* Side colouring, published per entity; the HUD maps these to colours. */
enum {
    AOWL_ADM_SIDE_UNKNOWN = 0,
    AOWL_ADM_SIDE_FRIEND  = 1,   /* same side as the local player            */
    AOWL_ADM_SIDE_ENEMY   = 2,   /* a human enemy                            */
    AOWL_ADM_SIDE_SCAV    = 3,   /* an AI scav / raider                      */
    AOWL_ADM_SIDE_BOSS    = 4    /* a boss or guard                          */
};

/* Per-entity flags. */
#define AOWL_ADM_F_ISAI     0x1u
#define AOWL_ADM_F_DEAD     0x2u
#define AOWL_ADM_F_ONSCREEN 0x4u   /* projected in front of the camera        */

#include "aowlspt_keycode.h"

#define AOWL_ADM_MAX_ENTITIES 256
#define AOWL_ADM_NAME_LEN     24
#define AOWL_ADM_STATUS_LEN   192
#define AOWL_ADM_QUERY_LEN    48
#define AOWL_ADM_RESULT_LEN   192
#define AOWL_ADM_REGION_NAME  "Local\\aowlspt_admin_shared_v5"
#define AOWL_ADM_MAGIC        0x414F574C41444D35ull  /* "AOWLADM5"            */
#define AOWL_ADM_VERSION      5
/* v5 grew a hotkey block. The NAME and MAGIC change with the layout ON
 * PURPOSE: a named section is created at the size of whoever maps it FIRST,
 * so a v4 host sharing a name with a v5 mod would give the larger side a
 * mapping that is too small and its writes would run off the end. A changed
 * name makes a mixed deploy show up as "region not mapped" on one side --
 * loud, and named by adminDiag() -- instead of as a fault. */

typedef struct AowlAdminEntity {
    /* Screen box in back-buffer pixels, top-left origin, valid only when
     * AOWL_ADM_F_ONSCREEN is set. `cx` is the horizontal centre, `top`/`bottom`
     * are head and feet; the HUD draws a box of width (bottom-top)*0.42. */
    float    cx, top, bottom;
    float    health, maxHealth;        /* -1 when unknown                     */
    float    distance;                 /* metres from the local player         */
    int32_t  side;                     /* AOWL_ADM_SIDE_*                     */
    uint32_t flags;                    /* AOWL_ADM_F_*                        */
    char     name[AOWL_ADM_NAME_LEN];  /* NUL-terminated ASCII, may be empty   */
} AowlAdminEntity;

typedef struct AowlAdminShared {
    uint64_t      magic;
    uint32_t      version;
    uint32_t      armed;               /* the mod seeded the toggles once      */

    volatile LONG toggles;             /* AOWL_ADM_* bitmask, menu-owned       */
    volatile LONG capability;          /* AOWL_ADM_* bitmask, mod-owned        */

    /* Menu state: the F6 keypress (overlay WndProc) and the draw share this. */
    volatile LONG menuOpen;
    volatile LONG menuSel;             /* 0..AOWL_ADM_COUNT-1                  */

    volatile LONG inRaid;              /* the mod found a live GameWorld       */

    /* The HUD's back-buffer size, written by the overlay each frame and read by
     * the mod so it projects to the exact resolution the boxes are drawn at. */
    volatile LONG hudW, hudH;

    /* The frame seqlock. Even = a stable frame is readable; odd = mid-write. */
    volatile LONG seq;
    int32_t       count;               /* entities this frame, 0..MAX          */
    int32_t       screenW, screenH;    /* the resolution the mod projected for  */
    AowlAdminEntity ents[AOWL_ADM_MAX_ENTITIES];

    char          status[AOWL_ADM_STATUS_LEN];  /* what bound, or why not      */
    volatile LONG heartbeat;           /* bumped per publish; stale detection   */

    /* ---- The item spawner ----------------------------------------------
     * A request/ack pair, not a flag. The overlay (WndProc thread) fills the
     * query and bumps `spawnReq`; the mod (host thread) notices req != ack,
     * calls `aowl.items`, writes `spawnResult` and only THEN sets ack = req.
     * `spawnBusy` is what the overlay reads to refuse a second submit and to
     * refuse edits to the query while the first is still in flight -- which is
     * also what makes the unsynchronised `spawnQuery` buffer safe: exactly one
     * side may touch it at a time, and which side that is is `spawnBusy`.
     *
     * There is no "spawn succeeded" bit on purpose. `spawnResult` is the whole
     * answer and it is populated on success AND on refusal, so the HUD cannot
     * render a spawn that did nothing as a spawn that worked.                */
    char          spawnQuery[AOWL_ADM_QUERY_LEN];
    volatile LONG spawnQueryLen;
    volatile LONG spawnCount;          /* 1..5000, 0 means "never set"         */
    volatile LONG spawnCondition;      /* 1..100,  0 means "never set"         */
    volatile LONG spawnReq;
    volatile LONG spawnAck;
    volatile LONG spawnBusy;
    char          spawnResult[AOWL_ADM_RESULT_LEN];

    /* ---- Action hotkeys -------------------------------------------------
     * One slot per toggle. The value is a `UnityEngine.KeyCode` ORDINAL, not
     * a Win32 virtual-key: the key is read with the game's own
     * `Input::GetKeyDown(KeyCode)`, so KeyCode is the only namespace involved
     * and there is no VK<->KeyCode mapping to get wrong.
     *
     * AOWL_KC_UNBOUND (-1) means "no key". It is deliberately NOT 0, because
     * KeyCode.None IS 0 -- a real member -- and a sentinel that collides with
     * a real key turns an unparsed name into a bound one.
     *
     * `hotkeyCapture` is the rebind rendezvous: the overlay WndProc sets it to
     * the row being rebound, and the MOD (on Unity's thread, the only place
     * Input:: may legally be called) scans the KeyCode table for the first key
     * pressed, writes the slot and sets it back to -1. Capturing on the mod
     * side rather than in the WndProc is what keeps the feature inside the
     * KeyCode namespace end to end.
     *
     * `hotkeyNote` is why the last rebind was REFUSED, in words, drawn under
     * the menu. A refusal that is not shown is the same as a silent no-op.  */
    volatile LONG hotkeyKc[AOWL_ADM_COUNT];
    volatile LONG hotkeyCapture;       /* -1 idle, else the row being rebound  */
    volatile LONG hotkeyEpoch;         /* bumped on any slot change, so the    */
                                       /* mod knows to persist to config.json  */
    volatile LONG hotkeyFires;         /* total activations, for adminDiag()   */
    char          hotkeyNote[AOWL_ADM_STATUS_LEN];
} AowlAdminShared;

/* ------------------------------------------------------------------ *
 * Mapping. Both sides call this. First creates, rest open. The handle is leaked
 * on purpose -- it lives for the process. NULL only if the OS refused, which is
 * a no-HUD/no-cheat outcome rather than a crash.
 * ------------------------------------------------------------------ */

static AowlAdminShared* aowl_admin_map(void) {
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                  (DWORD)sizeof(AowlAdminShared),
                                  AOWL_ADM_REGION_NAME);
    if (!h) return NULL;
    int existed = (GetLastError() == ERROR_ALREADY_EXISTS);
    AowlAdminShared* s = (AowlAdminShared*)MapViewOfFile(
        h, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(AowlAdminShared));
    if (!s) return NULL;
    if (!existed) {
        /* OS zero-fills a new section, so an un-armed region reads magic 0 /
         * capability 0 -- the safe-by-default state. Stamp magic/version so a
         * consumer that maps first can tell a real region from garbage; do NOT
         * seed toggles here (the mod does, in one place). */
        s->magic = AOWL_ADM_MAGIC;
        s->version = AOWL_ADM_VERSION;
        /* MUST be done here rather than left to the OS zero-fill: an all-zero
         * hotkey block reads as "every action bound to KeyCode.None", which is
         * a real key with ordinal 0. Unbound is -1. */
        {
            int i;
            for (i = 0; i < AOWL_ADM_COUNT; i++) s->hotkeyKc[i] = AOWL_KC_UNBOUND;
            s->hotkeyCapture = -1;
        }
    }
    return s;
}

/* ------------------------------------------------------------------ *
 * Toggles / menu -- both sides.
 * ------------------------------------------------------------------ */

static int32_t aowl_admin_toggle_get(AowlAdminShared* s, int32_t bit) {
    if (!s || bit < 0 || bit >= AOWL_ADM_COUNT) return 0;
    return (((uint32_t)s->toggles >> bit) & 1u) ? 1 : 0;
}
static void aowl_admin_toggle_set(AowlAdminShared* s, int32_t bit, int32_t on) {
    if (!s || bit < 0 || bit >= AOWL_ADM_COUNT) return;
    for (;;) {
        LONG cur = s->toggles;
        LONG next = on ? (cur | ((LONG)1 << bit)) : (cur & ~((LONG)1 << bit));
        if (InterlockedCompareExchange(&s->toggles, next, cur) == cur) return;
    }
}
static void aowl_admin_toggle_flip(AowlAdminShared* s, int32_t bit) {
    if (s) aowl_admin_toggle_set(s, bit, !aowl_admin_toggle_get(s, bit));
}
static int32_t aowl_admin_capable(AowlAdminShared* s, int32_t bit) {
    if (!s || bit < 0 || bit >= AOWL_ADM_COUNT) return 0;
    return (((uint32_t)s->capability >> bit) & 1u) ? 1 : 0;
}
static int32_t aowl_admin_menu_open(AowlAdminShared* s) {
    return (s && s->menuOpen) ? 1 : 0;
}
/* The HUD's back-buffer size: the overlay writes it, the mod reads it. */
static void aowl_admin_set_screen(AowlAdminShared* s, int32_t w, int32_t h) {
    if (!s) return;
    InterlockedExchange(&s->hudW, w);
    InterlockedExchange(&s->hudH, h);
}
static int32_t aowl_admin_get_w(AowlAdminShared* s) { return s ? (int32_t)s->hudW : 0; }
static int32_t aowl_admin_get_h(AowlAdminShared* s) { return s ? (int32_t)s->hudH : 0; }
static void aowl_admin_menu_toggle(AowlAdminShared* s) {
    if (s) InterlockedExchange(&s->menuOpen, s->menuOpen ? 0 : 1);
}
static void aowl_admin_menu_move(AowlAdminShared* s, int32_t delta) {
    if (!s) return;
    LONG n = s->menuSel + delta;
    while (n < 0) n += AOWL_ADM_ROW_TOTAL;
    while (n >= AOWL_ADM_ROW_TOTAL) n -= AOWL_ADM_ROW_TOTAL;
    InterlockedExchange(&s->menuSel, n);
}
/* ------------------------------------------------------------------ *
 * The item spawner -- shared, because the overlay drives it and the mod
 * services it.
 *
 * Every accessor clamps rather than trusting the region: this struct lives in
 * a named section any process on the box can open, so a length longer than the
 * buffer is a thing that CAN happen and must read as a short string, never as
 * a walk off the end.
 * ------------------------------------------------------------------ */

static int32_t aowl_admin_spawn_busy(AowlAdminShared* s) {
    return (s && s->spawnBusy) ? 1 : 0;
}
static int32_t aowl_admin_spawn_count(AowlAdminShared* s) {
    LONG v;
    if (!s) return 1;
    v = s->spawnCount;
    if (v < 1) return 1;
    if (v > 5000) return 5000;
    return (int32_t)v;
}
static int32_t aowl_admin_spawn_condition(AowlAdminShared* s) {
    LONG v;
    if (!s) return 100;
    v = s->spawnCondition;
    if (v < 1) return 100;          /* 0 = never set -> the sane default      */
    if (v > 100) return 100;
    return (int32_t)v;
}
/* The typed query, always NUL-terminated inside `out`, always clamped to the
 * buffer. Returns the length written. */
static int32_t aowl_admin_spawn_query(AowlAdminShared* s, char* out, int32_t cap) {
    int32_t n = 0, i = 0;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    if (!s) return 0;
    n = (int32_t)s->spawnQueryLen;
    if (n < 0) n = 0;
    if (n > AOWL_ADM_QUERY_LEN - 1) n = AOWL_ADM_QUERY_LEN - 1;
    if (n > cap - 1) n = cap - 1;
    for (i = 0; i < n; i++) {
        char c = s->spawnQuery[i];
        if (c == 0) break;          /* short-circuit a length that overstates */
        out[i] = c;
    }
    out[i] = 0;
    return i;
}

/* ---- consumer side (the overlay's WndProc) ---- */

static void aowl_admin_query_putc(AowlAdminShared* s, int32_t ch) {
    LONG n;
    if (!s || aowl_admin_spawn_busy(s)) return;
    /* Printable ASCII only. The item search is ASCII, and a control character
     * in a shared buffer is a bug looking for somewhere to happen. */
    if (ch < 0x20 || ch > 0x7E) return;
    n = s->spawnQueryLen;
    if (n < 0) n = 0;
    if (n >= AOWL_ADM_QUERY_LEN - 1) return;   /* full: refuse, do not wrap   */
    s->spawnQuery[n] = (char)ch;
    s->spawnQuery[n + 1] = 0;
    InterlockedExchange(&s->spawnQueryLen, n + 1);
}
static void aowl_admin_query_backspace(AowlAdminShared* s) {
    LONG n;
    if (!s || aowl_admin_spawn_busy(s)) return;
    n = s->spawnQueryLen;
    if (n <= 0) { InterlockedExchange(&s->spawnQueryLen, 0); return; }
    if (n > AOWL_ADM_QUERY_LEN - 1) n = AOWL_ADM_QUERY_LEN - 1;
    s->spawnQuery[n - 1] = 0;
    InterlockedExchange(&s->spawnQueryLen, n - 1);
}
/* Left/right on the two number rows. The step grows with the value, so a
 * thousand rounds is reachable without holding an arrow key for a minute. */
static void aowl_admin_spawn_adjust(AowlAdminShared* s, int32_t row, int32_t dir) {
    LONG v, step;
    if (!s || aowl_admin_spawn_busy(s) || dir == 0) return;
    if (row == AOWL_ADM_ROW_COUNT) {
        v = (LONG)aowl_admin_spawn_count(s);
        step = (v >= 1000) ? 500 : ((v >= 100) ? 100 : ((v >= 10) ? 10 : 1));
        v += (dir > 0 ? step : -step);
        if (v < 1) v = 1;
        if (v > 5000) v = 5000;
        InterlockedExchange(&s->spawnCount, v);
    } else if (row == AOWL_ADM_ROW_COND) {
        v = (LONG)aowl_admin_spawn_condition(s);
        v += (dir > 0 ? 5 : -5);
        if (v < 1) v = 1;
        if (v > 100) v = 100;
        InterlockedExchange(&s->spawnCondition, v);
    }
}
/* Submit. Refuses -- OUT LOUD, into `spawnResult` -- rather than bumping the
 * request when there is nothing to spawn or one is already in flight. A submit
 * that appears to do nothing is exactly the outcome this surface is built to
 * avoid. */
static void aowl_admin_spawn_submit(AowlAdminShared* s) {
    int32_t i = 0;
    const char* why = 0;
    const char* working = "working...";
    if (!s) return;
    if (aowl_admin_spawn_busy(s)) {
        why = "a spawn is already in flight; wait for it";
    } else if (s->spawnQueryLen <= 0 || s->spawnQuery[0] == 0) {
        why = "type part of an item name, or a template id, first";
    }
    if (why) {
        for (; i < AOWL_ADM_RESULT_LEN - 1 && why[i]; i++) s->spawnResult[i] = why[i];
        s->spawnResult[i] = 0;
        return;
    }
    if (s->spawnCount < 1)     InterlockedExchange(&s->spawnCount, 1);
    if (s->spawnCondition < 1) InterlockedExchange(&s->spawnCondition, 100);
    for (i = 0; i < AOWL_ADM_RESULT_LEN - 1 && working[i]; i++)
        s->spawnResult[i] = working[i];
    s->spawnResult[i] = 0;
    InterlockedExchange(&s->spawnBusy, 1);
    InterlockedIncrement(&s->spawnReq);
}
static const char* aowl_admin_spawn_result(AowlAdminShared* s) {
    if (!s) return "";
    s->spawnResult[AOWL_ADM_RESULT_LEN - 1] = 0;   /* never trust the writer  */
    return s->spawnResult;
}

/* Character-at accessors. nimony has no `$` for `cstring`, so the mod side
 * cannot take the `const char*` `aowl_admin_spawn_query` returns into a string;
 * it reads the length and then the bytes, in a bounded loop. Both clamp. */
static int32_t aowl_admin_query_len(AowlAdminShared* s) {
    LONG n;
    if (!s) return 0;
    n = s->spawnQueryLen;
    if (n < 0) return 0;
    if (n > AOWL_ADM_QUERY_LEN - 1) return AOWL_ADM_QUERY_LEN - 1;
    return (int32_t)n;
}
static int32_t aowl_admin_query_at(AowlAdminShared* s, int32_t i) {
    if (!s || i < 0 || i >= AOWL_ADM_QUERY_LEN - 1) return 0;
    return (int32_t)(unsigned char)s->spawnQuery[i];
}

/* ---- producer side (the mod) ---- */

/* Is there a request to service? Returns its sequence number, or 0 for none. */
static int32_t aowl_admin_spawn_pending(AowlAdminShared* s) {
    if (!s) return 0;
    if (s->spawnReq == s->spawnAck) return 0;
    return (int32_t)s->spawnReq;
}
/* Write the result line WITHOUT acknowledging a request.
 *
 * This is the typeahead channel, and it is deliberately a separate entry point
 * from `aowl_admin_spawn_done`: a live search must not touch `spawnAck` or
 * `spawnBusy`, or the very first keystroke would ack a spawn nobody asked for.
 *
 * NO NEW FIELD, ON PURPOSE. The obvious design is a second request/ack pair
 * for searches, but `CreateFileMappingA` keeps the size the FIRST process
 * asked for, so growing `AowlAdminShared` hands whichever process started
 * second a region shorter than the struct it is about to index -- which takes
 * out the ESP and the whole F6 menu, not just the spawner. Reusing the result
 * line costs nothing and cannot resize anything.
 *
 * The producer is expected to write here only when no spawn is in flight; a
 * search landing on top of "working..." would replace a spawn's own answer
 * with a search result, which is why the mod checks `spawnBusy` first. */
static void aowl_admin_spawn_note(AowlAdminShared* s, const char* text) {
    int32_t i = 0;
    if (!s) return;
    if (text) {
        for (; i < AOWL_ADM_RESULT_LEN - 1 && text[i]; i++) s->spawnResult[i] = text[i];
    }
    s->spawnResult[i] = 0;
}

/* Is a spawn in flight? The producer asks before writing a search preview, so
 * a typeahead line can never overwrite a real spawn's result. */
static int32_t aowl_admin_spawn_inflight(AowlAdminShared* s) {
    if (!s) return 0;
    return s->spawnBusy ? 1 : 0;
}

/* Finish one. `text` is what the player is shown, and it is written BEFORE the
 * ack, so a HUD that sees the request complete can never read the previous
 * request's result. */
static void aowl_admin_spawn_done(AowlAdminShared* s, int32_t req, const char* text) {
    int32_t i = 0;
    if (!s) return;
    if (text) {
        for (; i < AOWL_ADM_RESULT_LEN - 1 && text[i]; i++) s->spawnResult[i] = text[i];
    }
    s->spawnResult[i] = 0;
    InterlockedExchange(&s->spawnAck, (LONG)req);
    InterlockedExchange(&s->spawnBusy, 0);
}

/* Activate the selected row. A toggle row flips -- but only if the mod says it
 * is capable, so a menu gesture never turns on a mode that would silently do
 * nothing. The spawn row submits; the two number rows are driven by left/right
 * rather than by Enter, and the query row is typed into. */
static void aowl_admin_menu_activate(AowlAdminShared* s) {
    if (!s) return;
    int32_t sel = (int32_t)s->menuSel;
    if (aowl_admin_row_is_toggle(sel)) {
        if (aowl_admin_capable(s, sel))
            aowl_admin_toggle_flip(s, sel);
        return;
    }
    if (sel == AOWL_ADM_ROW_SPAWN)
        aowl_admin_spawn_submit(s);
}

/* ------------------------------------------------------------------ *
 * Producer (the mod).
 * ------------------------------------------------------------------ */

static void aowl_admin_seed_defaults(AowlAdminShared* s) {
    if (!s) return;
    if (InterlockedCompareExchange((volatile LONG*)&s->armed, 1, 0) == 0)
        InterlockedExchange(&s->toggles, (LONG)AOWL_ADM_DEFAULTS);
}
static void aowl_admin_set_capability(AowlAdminShared* s, uint32_t mask) {
    if (s) InterlockedExchange(&s->capability, (LONG)mask);
}
static void aowl_admin_set_inraid(AowlAdminShared* s, int32_t v) {
    if (s) InterlockedExchange(&s->inRaid, v ? 1 : 0);
}
static void aowl_admin_set_status(AowlAdminShared* s, const char* text) {
    if (!s) return;
    if (!text) { s->status[0] = 0; return; }
    int32_t i = 0;
    for (; i < AOWL_ADM_STATUS_LEN - 1 && text[i]; i++) s->status[i] = text[i];
    s->status[i] = 0;
}
static void aowl_admin_frame_begin(AowlAdminShared* s, int32_t w, int32_t h) {
    if (!s) return;
    InterlockedIncrement(&s->seq);   /* odd: writing                          */
    s->count = 0;
    s->screenW = w;
    s->screenH = h;
}
static void aowl_admin_frame_add(AowlAdminShared* s,
                                 float cx, float top, float bottom,
                                 float health, float maxHealth, float distance,
                                 int32_t side, uint32_t flags, const char* name) {
    if (!s || s->count >= AOWL_ADM_MAX_ENTITIES) return;
    AowlAdminEntity* e = &s->ents[s->count];
    e->cx = cx; e->top = top; e->bottom = bottom;
    e->health = health; e->maxHealth = maxHealth; e->distance = distance;
    e->side = side; e->flags = flags;
    int32_t i = 0;
    if (name) for (; i < AOWL_ADM_NAME_LEN - 1 && name[i]; i++) e->name[i] = name[i];
    e->name[i] = 0;
    s->count++;
}
static void aowl_admin_frame_commit(AowlAdminShared* s) {
    if (!s) return;
    InterlockedIncrement(&s->seq);      /* even: stable                        */
    InterlockedIncrement(&s->heartbeat);
}

/* ------------------------------------------------------------------ *
 * Consumer (the HUD). A stable copy under the seqlock.
 * ------------------------------------------------------------------ */

static int32_t aowl_admin_snapshot(AowlAdminShared* s, AowlAdminShared* out) {
    if (!s || !out) return 0;
    for (int tries = 0; tries < 8; tries++) {
        LONG s0 = s->seq;
        if (s0 & 1) continue;
        MemoryBarrier();
        int32_t c = s->count;
        if (c < 0) c = 0;
        if (c > AOWL_ADM_MAX_ENTITIES) c = AOWL_ADM_MAX_ENTITIES;
        out->count = c;
        out->screenW = s->screenW;
        out->screenH = s->screenH;
        memcpy(out->ents, s->ents, sizeof(AowlAdminEntity) * (size_t)c);
        memcpy(out->status, s->status, sizeof(out->status));
        out->heartbeat = s->heartbeat;
        out->inRaid = s->inRaid;
        MemoryBarrier();
        if (s->seq == s0) return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Guarded raw field reads -- the field-offset path, no managed calls.
 *
 * On this client build the per-frame managed method pointers are stripped, so
 * the mod reaches game state by reading `*(T*)(object + offset)` -- the offset
 * resolved once by `il2cpp_field_get_offset`, then a plain memory read. These
 * are the primitives for that, each checking the address is committed and
 * readable first (VirtualQuery) so a wrong offset or a moved object is a zero
 * rather than a fault. That check is cheap next to being the difference between
 * "the ESP shows nothing" and "the game crashed".
 * ------------------------------------------------------------------ */

static int32_t aowl_admin_readable_raw(const void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    {
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

/* ------------------------------------------------------------------ *
 * THE REGION-READABILITY CACHE.
 *
 * WHY. `aowl_admin_readable_raw` above is a raw `VirtualQuery` -- a SYSCALL
 * that walks this process's very large VAD tree -- and this header issues one
 * PER FIELD HOP. `aowl_admin_pos_live` alone pays five of them per player per
 * Unity frame, on top of one per player-list slot in the sweep that drives it.
 * The identical defect in `mods/maps` was MEASURED at 4394us/tick for the
 * entity loop and fell to 645us/tick (-85%) when the region answer was cached;
 * live counters there read `hits=670100 misses=48902 (93% hit)` with
 * `pred-audit=agrees/191`, i.e. the fast path never once disagreed with the
 * real predicate. This is that fix, ported -- and ported by replicating THIS
 * header's predicate, not maps': the two are NOT the same. `aowl_is_readable`
 * in abi/aowlspt_shim.h additionally requires a READ protection bit;
 * `aowl_admin_readable_raw` only rejects PAGE_NOACCESS and PAGE_GUARD. Copying
 * maps' clause list here would have silently CHANGED admin's guard.
 *
 * THE CHECK IS NOT REMOVED AND NOT WEAKENED. The question asked is exactly the
 * one asked before -- "does [p, p+size) lie wholly inside ONE committed,
 * non-guard, non-NOACCESS region?" -- and it is answered from a
 * MEMORY_BASIC_INFORMATION describing a REGION, not an address. That answer is
 * therefore valid for every address in that region, and re-asking it per hop
 * re-derives an identical answer at syscall price. A miss falls straight
 * through to a real VirtualQuery; there is no path here that returns 1 without
 * one having said so.
 *
 * THE HAZARD, NAMED, AND WHY THE TWO TTLs DIFFER. A cached POSITIVE gone stale
 * is a read of a decommitted page, i.e. a crash. A cached NEGATIVE gone stale
 * is a refused read, i.e. a decline -- which this mod already reports as a
 * named exit code and counts. So: positives 250 ms and ONLY for regions
 * >= 64 KB (heap segments and image sections; a sub-64KB region is a transient
 * VirtualAlloc and is never cached positively, it just pays the syscall);
 * negatives 2000 ms, any size.
 *
 * IT NEVER CLAIMED LIVENESS. Unity FAKE NULL means readability is not liveness
 * and type confusion beats both guards. A region reused for a different
 * allocation is still committed and still readable, so the cached answer is
 * still TRUE -- what changed is the OBJECT, and nothing here substitutes for
 * the callers' own null, flag and plausibility checks, which are untouched.
 *
 * CAPACITY, because that is what the maps port got wrong first. A 32-slot
 * round-robin table thrashed against ~35 entities x >=3 distinct regions and
 * every FIRST touch of a region within a call missed. This is 1024 sets x 2
 * ways, hashed on the address's 64KB chunk (`a >> 16`), with an epoch-based
 * O(1) flush. Lookup cannot be hashed on the region base -- the base is not
 * known until a VirtualQuery has been made -- so a region spanning many chunks
 * installs one entry per chunk it is actually touched in; every such entry
 * carries the SAME base/end, so they cannot disagree. Every answer re-checks,
 * in order: epoch, chunk tag, containment, TTL. A stale tag or an aliased set
 * therefore cannot produce a wrong answer, only a miss.
 *
 * THE REPLICATION IS AUDITED LIVE. One miss in AOWL_ADM_RDC_AUDIT_EVERY also
 * calls `aowl_admin_readable_raw` and compares; `disagree` counts any
 * difference and MUST stay 0. A non-zero disagree means this block has drifted
 * from the predicate above and must be resynced -- it is a measurement, not a
 * claim.
 *
 * IT OPENS NO GUARD AND INSTALLS NOTHING. Fixed static storage, no allocation,
 * no detour, no name resolved, nothing of the game's dereferenced.
 * ------------------------------------------------------------------ */

#define AOWL_ADM_RDC_SETS         1024   /* 1024 sets x 2 ways = 2048 entries  */
#define AOWL_ADM_RDC_WAYS         2
#define AOWL_ADM_RDC_CHUNK_SHIFT  16     /* 64KB granule: Windows alloc unit   */
#define AOWL_ADM_RDC_POS_TTL_MS   250    /* stale positive == crash; keep short*/
#define AOWL_ADM_RDC_NEG_TTL_MS  2000    /* stale negative == a decline; cheap */
#define AOWL_ADM_RDC_MIN_POS_SIZE 0x10000
#define AOWL_ADM_RDC_AUDIT_EVERY  256

typedef struct {
    uintptr_t tag;       /* address >> CHUNK_SHIFT, +1; 0 == empty slot */
    uintptr_t base;
    uintptr_t end;
    uint64_t  stamp;     /* GetTickCount64 at the VirtualQuery */
    uint32_t  epoch;     /* != rdc.epoch => flushed, treat as empty */
    int32_t   ok;
} AowlAdmRdcEntry;

typedef struct {
    AowlAdmRdcEntry e[AOWL_ADM_RDC_SETS][AOWL_ADM_RDC_WAYS];
    uint32_t epoch;
    uint32_t auditTick;
    int64_t  hits;
    int64_t  misses;
    int64_t  flushes;
    int64_t  uncacheable;  /* answered by syscall, deliberately not stored */
    int64_t  evictLive;    /* victim was USED and INSIDE its TTL: capacity   */
    int64_t  expired;
    int64_t  auditChecks;
    int64_t  auditDisagree;/* MUST stay 0; non-zero == drift from the raw one */
} AowlAdmRdcState;

static AowlAdmRdcState aowl_adm_rdc;   /* zero-initialised; epoch 0 */

static void aowl_admin_rdc_flush(void) {
    aowl_adm_rdc.epoch++;
    if (aowl_adm_rdc.epoch == 0) aowl_adm_rdc.epoch = 1;
    aowl_adm_rdc.flushes++;
}

/* THE PREDICATE, replicated clause-for-clause from aowl_admin_readable_raw,
 * applied to an mbi WE already hold so a miss costs one syscall instead of two.
 * If you change one of these, change both -- and expect `disagree` to say so if
 * you do not. */
static int32_t aowl_admin_rdc_pred(const MEMORY_BASIC_INFORMATION* mbi,
                                   uintptr_t a, uintptr_t need) {
    if (mbi->State != MEM_COMMIT) return 0;
    if (mbi->Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    {
        uintptr_t start = (uintptr_t)mbi->BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi->RegionSize;
        if (a < start) return 0;
        return need <= end ? 1 : 0;
    }
}

static uint32_t aowl_admin_rdc_set_of(uintptr_t tag) {
    /* Mix, so regions laid out at a regular stride do not all alias into one
     * set -- the failure a plain (tag & MASK) would reintroduce. */
    uint64_t h = (uint64_t)tag * 0x9E3779B97F4A7C15ull;
    return (uint32_t)((h >> 40) & (uint64_t)(AOWL_ADM_RDC_SETS - 1));
}

/* Contract IDENTICAL to aowl_admin_readable_raw. */
static int32_t aowl_admin_readable(const void* p, int32_t size) {
    uintptr_t a, need, tag;
    uint64_t now;
    uint32_t set;
    int32_t w, ans;
    MEMORY_BASIC_INFORMATION mbi;

    if (!p || size <= 0) return 0;
    a = (uintptr_t)p;
    need = a + (uintptr_t)size;
    if (need < a) return 0;            /* overflow -- the guard's own refusal */

    now = GetTickCount64();
    /* +1, not |1: the tag must stay INJECTIVE. `| 1` would give adjacent 64KB
     * chunks the same tag, which containment would then reject -- correct, but
     * a self-inflicted conflict. */
    tag = (a >> AOWL_ADM_RDC_CHUNK_SHIFT) + 1u;
    set = aowl_admin_rdc_set_of(tag);

    for (w = 0; w < AOWL_ADM_RDC_WAYS; w++) {
        AowlAdmRdcEntry* e = &aowl_adm_rdc.e[set][w];
        uint64_t ttl;
        if (e->tag != tag) continue;
        if (e->epoch != aowl_adm_rdc.epoch) continue;    /* flushed */
        if (a < e->base || need > e->end) continue;      /* containment */
        ttl = e->ok ? (uint64_t)AOWL_ADM_RDC_POS_TTL_MS
                    : (uint64_t)AOWL_ADM_RDC_NEG_TTL_MS;
        if (now - e->stamp > ttl) { e->tag = 0; aowl_adm_rdc.expired++; continue; }
        aowl_adm_rdc.hits++;
        return e->ok;
    }

    /* MISS. ONE VirtualQuery, and the same predicate the raw guard applies. */
    aowl_adm_rdc.misses++;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    ans = aowl_admin_rdc_pred(&mbi, a, need);

    /* Live audit of the replication, on a sample of misses. One extra syscall
     * 1 time in N, and the only thing that can prove this has not drifted from
     * aowl_admin_readable_raw. */
    if (++aowl_adm_rdc.auditTick >= (uint32_t)AOWL_ADM_RDC_AUDIT_EVERY) {
        aowl_adm_rdc.auditTick = 0;
        aowl_adm_rdc.auditChecks++;
        if (aowl_admin_readable_raw(p, size) != ans) aowl_adm_rdc.auditDisagree++;
    }

    {
        uintptr_t base = (uintptr_t)mbi.BaseAddress;
        uintptr_t end  = base + (uintptr_t)mbi.RegionSize;
        if (end <= base) return ans;
        if (ans && (end - base) < (uintptr_t)AOWL_ADM_RDC_MIN_POS_SIZE) {
            aowl_adm_rdc.uncacheable++;   /* answered honestly, then forgotten */
            return ans;
        }
        {
            /* Victim: an empty/flushed way first, else the OLDER stamp. */
            AowlAdmRdcEntry* v = &aowl_adm_rdc.e[set][0];
            for (w = 0; w < AOWL_ADM_RDC_WAYS; w++) {
                AowlAdmRdcEntry* c = &aowl_adm_rdc.e[set][w];
                if (c->tag == 0 || c->epoch != aowl_adm_rdc.epoch) { v = c; break; }
                if (c->stamp < v->stamp) v = c;
            }
            /* Was this eviction forced by CAPACITY rather than by time? That is
             * the number which decides whether the table is big enough, and it
             * is the number that can FALSIFY the capacity diagnosis. */
            if (v->tag != 0 && v->tag != tag && v->epoch == aowl_adm_rdc.epoch) {
                uint64_t vttl = v->ok ? (uint64_t)AOWL_ADM_RDC_POS_TTL_MS
                                      : (uint64_t)AOWL_ADM_RDC_NEG_TTL_MS;
                if (now - v->stamp <= vttl) aowl_adm_rdc.evictLive++;
            }
            v->tag = tag; v->base = base; v->end = end; v->stamp = now;
            v->epoch = aowl_adm_rdc.epoch; v->ok = ans ? 1 : 0;
        }
    }
    return ans;
}

static int64_t aowl_admin_rdc_hits(void)        { return aowl_adm_rdc.hits; }
static int64_t aowl_admin_rdc_misses(void)      { return aowl_adm_rdc.misses; }
static int64_t aowl_admin_rdc_flushes(void)     { return aowl_adm_rdc.flushes; }
static int64_t aowl_admin_rdc_uncacheable(void) { return aowl_adm_rdc.uncacheable; }
static int64_t aowl_admin_rdc_evict_live(void)  { return aowl_adm_rdc.evictLive; }
static int64_t aowl_admin_rdc_expired(void)     { return aowl_adm_rdc.expired; }
static int64_t aowl_admin_rdc_audits(void)      { return aowl_adm_rdc.auditChecks; }
static int64_t aowl_admin_rdc_disagree(void)    { return aowl_adm_rdc.auditDisagree; }
static void* aowl_admin_rp(const void* o, int32_t off) {
    void* v = 0;
    const char* a = (const char*)o + off;
    if (!aowl_admin_readable(a, (int32_t)sizeof(void*))) return 0;
    memcpy(&v, a, sizeof(void*));
    return v;
}
static int32_t aowl_admin_ri(const void* o, int32_t off) {
    int32_t v = 0;
    const char* a = (const char*)o + off;
    if (!aowl_admin_readable(a, 4)) return 0;
    memcpy(&v, a, 4);
    return v;
}
static float aowl_admin_rf(const void* o, int32_t off) {
    float v = 0.0f;
    const char* a = (const char*)o + off;
    if (!aowl_admin_readable(a, 4)) return 0.0f;
    memcpy(&v, a, 4);
    return v;
}
static void aowl_admin_wf(void* o, int32_t off, float v) {
    char* a = (char*)o + off;
    if (aowl_admin_readable(a, 4)) memcpy(a, &v, 4);
}

/* A managed `bool` is ONE byte in il2cpp, not four. Reading one with
 * `aowl_admin_ri` pulls in the three bytes that follow -- which for
 * `PhysicalBase._encumbered` @0x11c are `_overEncumbered`, `UnsubscribeAction`'s
 * padding and whatever the compiler laid out next -- so a byte field read four
 * bytes wide is a plausible non-zero number that is not the field. These two
 * exist so a bool is read and written at its real width, and they carry the
 * same VirtualQuery guard as every other accessor here. `-1` is the unreadable
 * sentinel: it is not a legal C# bool, so a caller can tell "false" from
 * "could not look" -- the two-outcome flattening CLAUDE.md 9b is about. */
static int32_t aowl_admin_rb(const void* o, int32_t off) {
    unsigned char v = 0;
    const char* a = (const char*)o + off;
    if (!aowl_admin_readable(a, 1)) return -1;
    memcpy(&v, a, 1);
    return (int32_t)v;
}
static int32_t aowl_admin_wb(void* o, int32_t off, int32_t v) {
    unsigned char b = (unsigned char)(v ? 1 : 0);
    char* a = (char*)o + off;
    if (!aowl_admin_readable(a, 1)) return 0;
    memcpy(a, &b, 1);
    return 1;
}

/* ------------------------------------------------------------------ *
 * God mode: a revertible static byte-patch on the damage function's native
 * code, resolved by RVA (the BE-bypass technique). No managed call, no Unity
 * thread. The RVA comes from tools/il2cpp_resolve.py against this build; the
 * patch overwrites the prologue with `xor eax,eax ; ret` so the method returns
 * 0/void immediately, and restores the saved bytes when God mode is turned off.
 *
 * NOTE this is GLOBAL -- it neuters the damage applier for every player, so the
 * local player takes no damage (the point) and so do bots (a side effect). A
 * player-scoped version needs the health-controller body-part layout; this is
 * the reliable, coordinator-endorsed option that works from any thread today.
 * ------------------------------------------------------------------ */

static unsigned char aowl_admin_god_saved[3];
static int32_t       aowl_admin_god_patched = 0;

/* The EXACT prologue bytes `ApplyDamageInfo` opens with on build 1.1.0.1.46777,
 * verified against the real D:/Games/Tarkov/GameAssembly.dll:
 *   48 89 5C 24 20   mov [rsp+0x20], rbx
 * The patch overwrites the first three (48 89 5C) with `xor eax,eax; ret`; the
 * trailing 24 20 are unreachable after the ret. If the live bytes are NOT this
 * exact sequence, the RVA is wrong for this client and the patch is REFUSED --
 * writing anyway would corrupt whatever code is really there, which is exactly
 * the boot crash this guard exists to prevent. */
static const unsigned char AOWL_ADMIN_GOD_EXPECT[5] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };

/* ------------------------------------------------------------------
 * The live GameWorld, borrowed from the host.
 *
 * MEASURED, not assumed: `EFT.GameWorld` is reached in the client through
 * `Comfort.Common.Singleton<GameWorld>._instance` -- a static on a GENERIC
 * INSTANTIATION, whose storage is allocated at runtime and therefore has no
 * static address this mod could read. The old `worldSingleton()` looked up a
 * non-generic field named "Instance" that does not exist on this build, so it
 * returned NULL every frame and ESP was dark BY CONSTRUCTION.
 *
 * The host already caches the live world from its read-only detour on
 * `EFT.GameWorld::RegisterPlayer` (RCX = the GameWorld). We RIDE that detour by
 * reading its cache through an exported accessor. We deliberately do NOT bind
 * our own detour: a second detour on one function overwrites the first's
 * trampoline and silently kills the first feature (CLAUDE.md 5).
 *
 * Resolved lazily by GetProcAddress so an older host without the export is a
 * clean "unavailable", not a load failure.
 * ------------------------------------------------------------------ */

typedef void*   (*AowlAdmGwFn)(void);
typedef int32_t (*AowlAdmGwArmedFn)(void);
static AowlAdmGwFn      aowl_adm_gw_fn    = 0;
static AowlAdmGwArmedFn aowl_adm_gw_armed = 0;
static int32_t          aowl_adm_gw_tried = 0;

static void aowl_admin_gw_resolve(void) {
    HMODULE h;
    if (aowl_adm_gw_tried) return;
    aowl_adm_gw_tried = 1;
    h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
    if (!h) return;
    aowl_adm_gw_fn = (AowlAdmGwFn)(void*)
        GetProcAddress(h, "aowl_host_gameworld");
    aowl_adm_gw_armed = (AowlAdmGwArmedFn)(void*)
        GetProcAddress(h, "aowl_host_gameworld_armed");
}

/* The live GameWorld, or NULL. NULL is ambiguous on its own -- pair it with
 * aowl_admin_gw_state() before reporting anything to a human. */
static void* aowl_admin_gameworld(void) {
    aowl_admin_gw_resolve();
    if (!aowl_adm_gw_fn) return 0;
    return aowl_adm_gw_fn();
}

/* Why there is no world, so a caller can say PASS / FAIL / INCONCLUSIVE rather
 * than flattening all three into "not in a raid":
 *   0 = no host export   (old host, or the mod is not running in the client)
 *   1 = export present but NO detour armed -> nothing can ever populate the
 *       cache: INCONCLUSIVE, and the fix is a host flag, not a raid
 *   2 = armed, cache empty  -> genuinely not in a raid
 *   3 = armed, world live   -> PASS */
static int32_t aowl_admin_gw_state(void) {
    aowl_admin_gw_resolve();
    if (!aowl_adm_gw_fn) return 0;
    if (aowl_adm_gw_armed && aowl_adm_gw_armed() == 0) return 1;
    return aowl_adm_gw_fn() ? 3 : 2;
}

static int32_t aowl_admin_godmode(int32_t on, uint32_t rva) {
    HMODULE ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga || rva == 0) return 0;
    unsigned char* p = (unsigned char*)ga + rva;
    static const unsigned char patch[3] = { 0x31, 0xC0, 0xC3 }; /* xor eax,eax;ret */
    DWORD old = 0;
    if (on && !aowl_admin_god_patched) {
        /* Never dereference the target without checking the page is mapped and
         * readable first -- a wrong module base or a not-yet-mapped section is a
         * fault otherwise. */
        if (!aowl_admin_readable(p, 8)) return 0;
        /* Already patched (a previous session left it) -- treat as done. */
        if (p[0] == 0x31 && p[1] == 0xC0 && p[2] == 0xC3) {
            aowl_admin_god_patched = 1; return 1;
        }
        /* Byte-verify the EXACT prologue before writing. A mismatch means the
         * RVA is not `ApplyDamageInfo` on this build: refuse rather than corrupt. */
        if (memcmp(p, AOWL_ADMIN_GOD_EXPECT, 5) != 0) return 0;
        if (!VirtualProtect(p, 3, PAGE_EXECUTE_READWRITE, &old)) return 0;
        memcpy(aowl_admin_god_saved, p, 3);
        memcpy(p, patch, 3);
        VirtualProtect(p, 3, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, 3);
        aowl_admin_god_patched = 1;
        return 1;
    } else if (!on && aowl_admin_god_patched) {
        if (!aowl_admin_readable(p, 8)) { aowl_admin_god_patched = 0; return 0; }
        if (!VirtualProtect(p, 3, PAGE_EXECUTE_READWRITE, &old)) return 0;
        memcpy(p, aowl_admin_god_saved, 3);
        VirtualProtect(p, 3, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, 3);
        aowl_admin_god_patched = 0;
        return 1;
    }
    return aowl_admin_god_patched;
}
static int32_t aowl_admin_god_is_on(void) { return aowl_admin_god_patched; }
static int32_t aowl_admin_gameasm_present(void) {
    return GetModuleHandleA("GameAssembly.dll") ? 1 : 0;
}

/* ================================================================== *
 * THE LIVE WORLD POSITION IS NOT A MANAGED FIELD ON THIS BUILD.
 * ==================================================================
 *
 * This mod read `EFT.MovementContext.PreviousPosition` @0x370 and reported
 * `positions : FAIL no player position passed the finite/bounded check` in a
 * live raid, which was misattributed to sampler timing. It was not timing.
 * The offset is CORRECT -- metadata names the field at exactly 0x370 -- and the
 * field is also permanently ZERO on this build: measured live in a raid on
 * 2026-08-28 by `mods/maps`, 66331 readable reads, every one exactly (0,0,0)
 * from a page VirtualQuery accepted. It is declared and never written. So this
 * was never a one-wrong-offset problem; it was the wrong KIND of answer.
 *
 * Where the pose really lives, read out of the client's OWN accessor bytes and
 * corroborated field-by-field against il2cpp metadata:
 *
 *   EFT.Player::get_Position  RVA 0x6F32C0
 *     40 53 48 83 EC 30              push rbx; sub rsp,0x30
 *     48 8B 82 40 0B 00 00           mov rax,[rdx+0xB40]   Player.PlayerBones
 *     48 8B D9                       mov rbx,rcx           (sret buffer)
 *     48 85 C0 74 30                 null -> managed throw path
 *     48 8B 90 78 01 00 00           mov rdx,[rax+0x178]   PlayerBones.BodyTransform
 *     48 85 D2 74 24                 null -> managed throw path
 *     45 33 C0                       xor r8d,r8d           MethodInfo* = NULL
 *     48 8D 4C 24 20                 lea rcx,[rsp+0x20]
 *     E8 B2 0C 1E 00                 call 0x8D3FA0  BifacialTransform::get_position
 *     ... F2 0F 11 03 / 89 43 08     store 12 bytes to [rbx]; return rbx
 *
 *   EFT.BifacialTransform::get_position  RVA 0x8D3FA0
 *     80 BA A9 00 00 00 00  cmp byte [rdx+0xA9],0   _accumulatePositionAndRotation
 *     80 BA A8 00 00 00 00  cmp byte [rdx+0xA8],0   _useImitation
 *     48 8B 7A 10           mov rdi,[rdx+0x10]      Original (UnityEngine.Transform)
 *     ... FF D0             Transform::get_position_Injected(this, out Vector3)
 *
 *   metadata: EFT.Player.<PlayerBones>k__BackingField @0xB40  (PlayerBones)
 *             PlayerBones.BodyTransform              @0x178  (BifacialTransform)
 *             BifacialTransform.Original @0x10, _useImitation @0xA8,
 *             _accumulatePositionAndRotation @0xA9  -- all three match.
 *
 * The fast path bottoms out in a UNITY NATIVE ICALL. There is therefore no
 * managed offset that holds the live pose, and no amount of hunting for one
 * will produce it. A direct call at a byte-verified static RVA is the only
 * route, and it is the route CLAUDE.md 5 sanctions.
 *
 * WHY WE WALK THE CHAIN OURSELVES BEFORE CALLING. Both `get_Position` and
 * `get_position` THROW a managed NullReferenceException on their null branches.
 * A managed throw unwinding out of a raw native call, 128 times a frame, is not
 * something we survive. Every pointer the callee will dereference is validated
 * HERE first (rule 2: `a->b->c` is three checks, not one) and the call happens
 * only once the throw branches are proven unreachable. The pre-walk is not
 * redundant with the callee's checks; it is what makes them never fire.
 *
 * MIRRORED, NOT SHARED, from `mods/maps/sp/world.nim` + `mods/maps/sp/mapmath.h`.
 * Those are a sibling MOD's private translation-unit-local statics; including
 * them here would make admin's build depend on maps' internals, and two agents
 * are editing maps concurrently. The disassembly and the metadata above are the
 * shared artifact -- they are reproducible from GameAssembly.dll, and neither
 * copy is authoritative over the other.
 *
 * THREADING. `Transform::get_position_Injected` is a Unity native call and is
 * legal only on Unity's thread. The ESP data pass runs on the HOST's thread, so
 * this cannot be called from it. `aowl_admin_pos_add` is therefore driven from
 * the same `everyMain` tick the camera sampler already rides (fact #136 gate),
 * and the host-thread pass reads back the snapshot below with pure memory
 * reads. That is why a cache exists at all.
 * ================================================================== */

#define AOWL_ADM_GETPOS_RVA  0x6F32C0
#define AOWL_ADM_PL_BONES    0xB40
#define AOWL_ADM_PB_BODYXF   0x178
#define AOWL_ADM_BT_ORIGINAL 0x10
#define AOWL_ADM_BT_USEIMIT  0xA8
#define AOWL_ADM_BT_ACCUM    0xA9

/* Classification, mirrored from mm_pos_classify. UNREADABLE and ALLZERO are
 * DISTINCT answers on purpose: "a bad pointer" and "a readable page that is
 * genuinely full of zeroes" are different bugs, and collapsing them is exactly
 * what hid the PreviousPosition failure for as long as it hid. */
#define AOWL_ADM_POS_OK         0
#define AOWL_ADM_POS_UNREADABLE 1
#define AOWL_ADM_POS_NAN        2
#define AOWL_ADM_POS_RANGE      3
#define AOWL_ADM_POS_ALLZERO    4
/* Above the range above, so the five-way classification stays intact and these
 * are additive. A future wrong offset landing on a mapped, zeroed page STILL
 * comes back ALLZERO -- the report that made this bug findable at all. */
#define AOWL_ADM_POS_NILBONES   10
#define AOWL_ADM_POS_NILXFORM   11
#define AOWL_ADM_POS_IMITATED   12
#define AOWL_ADM_POS_NOCALL     13
#define AOWL_ADM_POS_CODES      14

#define AOWL_ADM_POS_LIMIT 1.0e6f

static int32_t aowl_admin_pos_classify(int32_t readable, float x, float y, float z) {
    if (!readable) return AOWL_ADM_POS_UNREADABLE;
    /* NaN is the only value that compares unequal to itself. Written this way
     * rather than with isnan() so it survives -ffast-math builds unchanged. */
    if (x != x || y != y || z != z) return AOWL_ADM_POS_NAN;
    if (x > AOWL_ADM_POS_LIMIT || x < -AOWL_ADM_POS_LIMIT) return AOWL_ADM_POS_RANGE;
    if (y > AOWL_ADM_POS_LIMIT || y < -AOWL_ADM_POS_LIMIT) return AOWL_ADM_POS_RANGE;
    if (z > AOWL_ADM_POS_LIMIT || z < -AOWL_ADM_POS_LIMIT) return AOWL_ADM_POS_RANGE;
    if (x == 0.0f && y == 0.0f && z == 0.0f) return AOWL_ADM_POS_ALLZERO;
    return AOWL_ADM_POS_OK;
}

static const unsigned char aowl_adm_getpos_sig[16] = {
    0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,
    0x82,0x40,0x0B,0x00,0x00,0x48,0x8B,0xD9
};
static void*   aowl_adm_getpos_fn    = 0;
static int32_t aowl_adm_getpos_state = 0;   /* 0 untried, 1 armed, -1 refused */

/* Arm ONCE, and refuse STICKILY: a build whose prologue does not match never
 * gets a second chance and never calls. `GetModuleHandleA` is the OS loader,
 * not an il2cpp by-name lookup -- there is no token-gated export on this path
 * and nothing here can return a plausible random value. */
static int32_t aowl_admin_pos_arm(void) {
    unsigned char* fn;
    HMODULE ga;
    if (aowl_adm_getpos_state != 0) return aowl_adm_getpos_state;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;                       /* not up YET -- retry later */
    fn = (unsigned char*)ga + AOWL_ADM_GETPOS_RVA;
    if (!aowl_admin_readable(fn, 16))                       { aowl_adm_getpos_state = -1; return -1; }
    if (memcmp(fn, aowl_adm_getpos_sig, 16) != 0)           { aowl_adm_getpos_state = -1; return -1; }
    aowl_adm_getpos_fn = (void*)fn;
    aowl_adm_getpos_state = 1;
    return 1;
}
static int32_t aowl_admin_pos_armed(void) { return aowl_adm_getpos_state; }

static int32_t aowl_adm_rd_u8(const void* o, int32_t off, unsigned char* out) {
    const unsigned char* a = (const unsigned char*)o + off;
    *out = 0;
    if (!aowl_admin_readable(a, 1)) return 0;
    *out = *a;
    return 1;
}

/* Vector3 (12 bytes) is bigger than 8, so Win64 returns it through a HIDDEN
 * BUFFER: (retbuf in RCX, this in RDX, MethodInfo* in R8). That shape is not
 * inferred from the name -- it is read off `48 8B D9` (mov rbx,rcx) at entry
 * and `F2 0F 11 03 / 89 43 08 / 48 8B C3` (store 12 bytes to [rbx], return rbx)
 * at exit. MethodInfo* NULL is safe: get_Position is not a shared generic. */
/* L4 BRACKETS. `w` brackets the WHOLE body on EVERY return path, including the
 * two that return before any hop is attempted -- that is what makes it a valid
 * parent for the per-hop rows (see the header comment in aowlspt_admprof.h on
 * why AP_E_ADD is the WRONG parent and produced 104.3%). Each `return` below
 * therefore closes it. Nothing else about the function changed. */
static int32_t aowl_admin_pos_live(void* player, float* out3) {
    void* bones; void* bt; void* orig;
    unsigned char flag = 0;
    float tmp[3];
    AOWL_APB(w);
    out3[0] = 0.0f; out3[1] = 0.0f; out3[2] = 0.0f;
    if (aowl_adm_getpos_state != 1) { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_NOCALL; }
    if (!player)                    { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_NILBONES; }
    { AOWL_APB(h);
      bones = aowl_admin_rp(player, AOWL_ADM_PL_BONES);
      AOWL_APE(AP_L_H1, h); }
    if (!bones)                     { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_NILBONES; }
    { AOWL_APB(h);
      bt = aowl_admin_rp(bones, AOWL_ADM_PB_BODYXF);
      AOWL_APE(AP_L_H2, h); }
    if (!bt)                        { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_NILXFORM; }
    /* Both imitation flags must be clear, or get_position takes a delegate path
     * we have NOT proven throw-free. Declining is an ANSWER, not a silence. */
    { int32_t r; AOWL_APB(h);
      r = aowl_adm_rd_u8(bt, AOWL_ADM_BT_ACCUM, &flag);
      AOWL_APE(AP_L_H3, h);
      if (!r || flag) { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_IMITATED; } }
    { int32_t r; AOWL_APB(h);
      r = aowl_adm_rd_u8(bt, AOWL_ADM_BT_USEIMIT, &flag);
      AOWL_APE(AP_L_H4, h);
      if (!r || flag) { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_IMITATED; } }
    { AOWL_APB(h);
      orig = aowl_admin_rp(bt, AOWL_ADM_BT_ORIGINAL);
      AOWL_APE(AP_L_H5, h); }
    if (!orig)                      { AOWL_APE(AP_L_WHOLE, w); return AOWL_ADM_POS_NILXFORM; }
    tmp[0] = 0.0f; tmp[1] = 0.0f; tmp[2] = 0.0f;
    { AOWL_APB(h);
      ((void* (*)(void*, void*, void*))aowl_adm_getpos_fn)((void*)tmp, player, (void*)0);
      AOWL_APE(AP_L_CALL, h); }
    { int32_t code; AOWL_APB(h);
      out3[0] = tmp[0]; out3[1] = tmp[1]; out3[2] = tmp[2];
      /* readable=1: the buffer is OUR stack, so readability is not in question
       * -- it was answered by the guarded walk above. The plausibility gates
       * (NaN / out-of-range / exactly-zero) still apply unchanged. */
      code = aowl_admin_pos_classify(1, tmp[0], tmp[1], tmp[2]);
      AOWL_APE(AP_L_TAIL, h);
      AOWL_APE(AP_L_WHOLE, w);
      return code; }
}

/* ------------------------------------------------------------------ *
 * The snapshot. Written on Unity's thread by the everyMain tick, read on the
 * host's thread by the ESP data pass. Fixed storage, no allocation of any kind
 * per frame (rule 7); capped at a population far above any real raid (rule 4).
 *
 * DOUBLE-BUFFERED with a seqlock-style generation, for the same reason the
 * camera snapshot is: the reader must never see half of one frame's sweep
 * spliced onto half of the next. `begin` fills the BACK buffer, `commit`
 * publishes it by flipping the index; the reader only ever looks at the
 * published side.
 * ------------------------------------------------------------------ */
#define AOWL_ADM_POS_MAX 128

typedef struct {
    void* player;
    float x, y, z;
    int32_t age;   /* sweeps since a FRESH OK sample; 0 = sampled this sweep    */
} AowlAdmPosEnt;

/* Carry-forward budget (task 2, the ESP FLASH). `posSample()` rebuilds this
 * snapshot every Unity frame; a SINGLE-frame classification miss (IMITATED
 * during an animation blend, a transient NILXFORM/NILBONES) or cadence skew
 * against the host-thread draw drops a player from ONE sweep -- so `posGet()`
 * returns 0 for that frame, the box vanishes, and it returns next sweep. That
 * is a genuine 1-frame gap in the position snapshot, NOT a wrong position, so
 * a bounded hold-last-N is the right fix (CLAUDE.md 9b sanctions it only for a
 * true 1-frame gap). An entry the current sweep did not freshly sample is
 * carried into the new buffer with age+1 for up to this many sweeps, then aged
 * out. The draw loop only ever draws players still in the live GameWorld list,
 * so a carried entry for a player who genuinely left is never drawn -- it just
 * ages out silently. */
#define AOWL_ADM_POS_HOLD 6

static AowlAdmPosEnt aowl_adm_pos_buf[2][AOWL_ADM_POS_MAX];
static int32_t aowl_adm_pos_n[2]  = { 0, 0 };
static int32_t aowl_adm_pos_pub   = 0;   /* index of the PUBLISHED buffer */
static int32_t aowl_adm_pos_back  = 1;
static int32_t aowl_adm_pos_fill  = 0;   /* entries written into the back one */
static int32_t aowl_adm_pos_gen   = 0;
static int32_t aowl_adm_pos_stat[AOWL_ADM_POS_CODES];

static void aowl_admin_pos_begin(void) { aowl_adm_pos_fill = 0; }

/* Sample ONE player and record it. Returns the classification so the caller can
 * report WHICH exit reason it took rather than "it did not work". Entries that
 * did not classify OK are deliberately NOT stored: a rejected read must not
 * reach the draw loop as a plausible coordinate. */
static int32_t aowl_admin_pos_add(void* player) {
    float p[3];
    int32_t code = aowl_admin_pos_live(player, p);
    if (code >= 0 && code < AOWL_ADM_POS_CODES) {
        if (aowl_adm_pos_stat[code] < 0x40000000) aowl_adm_pos_stat[code]++;
    }
    if (code != AOWL_ADM_POS_OK) return code;
    if (aowl_adm_pos_fill >= AOWL_ADM_POS_MAX) return code;   /* capped */
    aowl_adm_pos_buf[aowl_adm_pos_back][aowl_adm_pos_fill].player = player;
    aowl_adm_pos_buf[aowl_adm_pos_back][aowl_adm_pos_fill].x = p[0];
    aowl_adm_pos_buf[aowl_adm_pos_back][aowl_adm_pos_fill].y = p[1];
    aowl_adm_pos_buf[aowl_adm_pos_back][aowl_adm_pos_fill].z = p[2];
    aowl_adm_pos_buf[aowl_adm_pos_back][aowl_adm_pos_fill].age = 0;  /* fresh */
    aowl_adm_pos_fill++;
    return code;
}

static void aowl_admin_pos_commit(void) {
    int32_t t, i, j;
    int32_t pub = aowl_adm_pos_pub;      /* the sweep we are about to replace */
    int32_t back = aowl_adm_pos_back;    /* this sweep's fresh entries live here */
    int32_t pn = aowl_adm_pos_n[pub];
    /* CARRY-FORWARD, bridging the 1-frame gap that makes the ESP FLASH. Any
     * player in the PUBLISHED buffer that this sweep did not freshly sample is
     * copied into the back buffer with age+1, up to AOWL_ADM_POS_HOLD, then
     * dropped. Bounded by the 128-entry cap the sweep already carries. */
    if (pn < 0) pn = 0;
    if (pn > AOWL_ADM_POS_MAX) pn = AOWL_ADM_POS_MAX;
    for (i = 0; i < pn && aowl_adm_pos_fill < AOWL_ADM_POS_MAX; i++) {
        AowlAdmPosEnt* pe = &aowl_adm_pos_buf[pub][i];
        int32_t found = 0;
        for (j = 0; j < aowl_adm_pos_fill; j++) {
            if (aowl_adm_pos_buf[back][j].player == pe->player) { found = 1; break; }
        }
        if (found) continue;                        /* freshly sampled already */
        if (pe->age + 1 >= AOWL_ADM_POS_HOLD) continue;   /* aged out */
        {
            AowlAdmPosEnt* ne = &aowl_adm_pos_buf[back][aowl_adm_pos_fill];
            ne->player = pe->player;
            ne->x = pe->x; ne->y = pe->y; ne->z = pe->z;
            ne->age = pe->age + 1;
            aowl_adm_pos_fill++;
        }
    }
    aowl_adm_pos_n[back] = aowl_adm_pos_fill;
    t = aowl_adm_pos_pub; aowl_adm_pos_pub = aowl_adm_pos_back; aowl_adm_pos_back = t;
    aowl_adm_pos_gen++;
}

static int32_t aowl_admin_pos_count(void) { return aowl_adm_pos_n[aowl_adm_pos_pub]; }
static int32_t aowl_admin_pos_gen_get(void) { return aowl_adm_pos_gen; }
static int32_t aowl_admin_pos_stat_at(int32_t code) {
    if (code < 0 || code >= AOWL_ADM_POS_CODES) return 0;
    return aowl_adm_pos_stat[code];
}

/* Look a player up in the PUBLISHED snapshot. Linear over at most 128 entries,
 * which is the same bound the sweep already carries. Returns 1 and fills
 * x/y/z, or 0 -- and 0 means "this player was not in the last good sweep",
 * never "its position is the origin". */
static int32_t aowl_admin_pos_get(void* player, float* x, float* y, float* z) {
    int32_t i;
    const AowlAdmPosEnt* b = aowl_adm_pos_buf[aowl_adm_pos_pub];
    int32_t n = aowl_adm_pos_n[aowl_adm_pos_pub];
    *x = 0.0f; *y = 0.0f; *z = 0.0f;
    if (!player) return 0;
    if (n < 0 || n > AOWL_ADM_POS_MAX) return 0;
    for (i = 0; i < n; i++) {
        if (b[i].player == player) {
            *x = b[i].x; *y = b[i].y; *z = b[i].z;
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Projection helpers, runnable either side. `m` is a Unity Matrix4x4 product
 * (projection * worldToCamera) in column-major order: element (row r, col c) is
 * m[c*4 + r]. clip = M*(x,y,z,1); in front of the camera when clip.w > 0.
 * ------------------------------------------------------------------ */

static int32_t aowl_admin_project(const float* m, float x, float y, float z,
                                  int32_t w, int32_t h, float* sx, float* sy) {
    if (!m || w <= 0 || h <= 0) return 0;
    float cx = m[0]*x + m[4]*y + m[8]*z  + m[12];
    float cy = m[1]*x + m[5]*y + m[9]*z  + m[13];
    float cw = m[3]*x + m[7]*y + m[11]*z + m[15];
    if (cw <= 0.0001f) return 0;
    float ndcX = cx / cw;
    float ndcY = cy / cw;
    if (sx) *sx = (ndcX * 0.5f + 0.5f) * (float)w;
    if (sy) *sy = (1.0f - (ndcY * 0.5f + 0.5f)) * (float)h;
    return 1;
}

/* out = a * b, both Unity column-major. out must not alias a or b. */
static void aowl_admin_mat_mul(const float* a, const float* b, float* out) {
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) {
            float s = 0.0f;
            for (int k = 0; k < 4; k++) s += a[k*4 + r] * b[c*4 + k];
            out[c*4 + r] = s;
        }
}


/* ------------------------------------------------------------------ *
 * WORLD -> SCREEN: the camera view-projection snapshot.
 *
 * ESP had real world positions and no way to turn one into a pixel. This is
 * that last mile, and it is deliberately SPLIT ACROSS TWO THREADS:
 *
 *   * `aowl_admin_cam_sample()` CALLS Unity code and therefore may only run on
 *     Unity's own thread. The mod drives it from `everyMain`, gated on the
 *     host's `aowlspt.host::main_thread` answer reporting the drain has already
 *     FIRED there (fact #136: arming il2cpp work before the drain is live kills
 *     the client ~1.2s in). It writes 16 floats plus a generation counter.
 *
 *   * `aowl_admin_project()` above is pure arithmetic over those 16 floats and
 *     runs on the mod's own thread, per entity, per frame. No Unity call, no
 *     allocation, so the ESP data pass does not move threads.
 *
 * The three RVAs, MEASURED offline against D:/Games/Tarkov/GameAssembly.dll
 * (build 1.1.0.1.46777) with `tools/il2cpp_resolve.py type 22882` +
 * `bytes <rva> 32`, and each one DISASSEMBLED to establish its argument shape
 * rather than inferred from its name:
 *
 *   UnityEngine.Camera::get_main @ 0x5260400 -- STATIC, 0 args -> Camera.
 *     5260400: sub rsp,0x28 ; mov rax,[rip+0x1E727D5] ; test rax,rax ; jne ..
 *     RCX carries only the hidden MethodInfo* and the body never reads it.
 *     Byte-identical to the entry `abi/aowlspt_debugui.h` already ships, which
 *     is an independent confirmation of the RVA rather than a copy of a guess.
 *
 *   UnityEngine.Camera::get_worldToCameraMatrix @ 0x525F2A0
 *   UnityEngine.Camera::get_projectionMatrix    @ 0x525F380
 *     Both return a Matrix4x4 -- 64 bytes, far larger than 8 -- so Win64 uses a
 *     HIDDEN RETURN BUFFER (sret) and every argument shifts right by one:
 *       48 89 5C 24 08   mov [rsp+8],rbx
 *       57               push rdi
 *       48 83 EC 20      sub rsp,0x20
 *       48 8B 05 ..      mov rax,[rip+..]        <- the icall slot
 *       0F 57 C0         xorps xmm0,xmm0
 *       48 8B FA         mov rdi,rdx             <- RDX = this   (the Camera)
 *       48 8B D9         mov rbx,rcx             <- RCX = retbuf (sret)
 *       0F 11 01         movups [rcx],xmm0       <- zeroes the retbuf
 *     so the call is (retbuf, this, MethodInfo*). This is the same shape
 *     CLAUDE.md records for `RectTransform::get_rect`, and the OPPOSITE of the
 *     Vector2 getters, which pack into RAX -- passing `this` in RCX here would
 *     have written 64 bytes of matrix over the Camera object.
 *
 * The two matrix prologues differ ONLY in the RIP displacement (2F 3A E7 01 vs
 * 5F 39 E7 01), so the 16-byte signatures below include it: they cannot match
 * each other, and they cannot match this build's universal empty-body stub.
 * ------------------------------------------------------------------ */

#define AOWL_ADM_RVA_CAM_MAIN 0x5260400u
#define AOWL_ADM_RVA_CAM_W2C  0x525F2A0u
#define AOWL_ADM_RVA_CAM_PROJ 0x525F380u

/* ------------------------------------------------------------------ *
 * MEASURED DEFECT, 2026-08-28: `Camera::get_main` RETURNS NULL IN A RAID.
 *
 * The evidence, from the mod's own diagnostic in a live Woods raid at
 * [0:08:09.172]:
 *
 *     esp sampler  : INCONCLUSIVE  armed on everyMain, ... 24604 firings but
 *                    NO good sample yet
 *     esp project  : INCONCLUSIVE  bound, but the Unity-thread sampler has
 *                    never produced a matrix
 *
 * Read that against the code below. `aowl_adm_cam_bind` was 3, so all three
 * prologues byte-matched and every target was callable -- a bind failure would
 * have printed the PROLOGUE MISMATCH text instead. The only other way out of
 * `aowl_admin_cam_sample` without bumping `gen` and without burning the fault
 * budget is the `!cam` branch, and the diag confirms the budget was untouched
 * (`faults: 0 of 8`). So `get_main` returned NULL on all 24604 firings, in a
 * raid, with the player spawned.
 *
 * That is not a bug in `get_main`. `UnityEngine.Camera.main` is defined as the
 * first ENABLED camera whose GameObject carries the tag "MainCamera", and
 * Tarkov's FPS camera does not carry it -- the game reaches its camera through
 * `EFT.CameraControl.CameraManager` instead, which is why that type exists and
 * why it holds the camera in a backing field. `mods/fov` has been taking that
 * route successfully all along; the same session logged "a live CameraManager
 * and Camera are in hand, from the static verified get_Instance".
 *
 * So the fix is not a new mechanism, it is the ROUTE mods/fov already proves.
 * `get_main` is KEPT and tried first -- it costs one call, it is correct
 * wherever it works (the hideout and menu scenes do tag a camera), and dropping
 * a working path to add a fallback would be trading one blind spot for another.
 *
 *   EFT.CameraControl.CameraManager::get_Instance @ 0x1263BD0 -- STATIC,
 *     0 args -> CameraManager. Byte-verified against the INSTALLED
 *     D:/Games/Tarkov/GameAssembly.dll, section `il2cpp`:
 *       48 83 EC 28 80 3D E6 8B E5 05 00 75 18 48 8D 0D
 *     which is `sub rsp,0x28 ; cmp byte [rip+0x5E58BE6],0 ; jne .. ; lea rcx,..`
 *     -- the il2cpp class-init guard then the static-field load. A real body:
 *     it is not this build's universal empty-body stub (`C2 00 00`) and not a
 *     thunk. These are the SAME bytes `mods/fov/fov.nim` records as
 *     `ProCamInstance` for the same RVA, arrived at independently here by
 *     reading the PE, so the two agree without one copying the other.
 *
 *   CameraManager.<Camera>k__BackingField @ 0x70 -- a FIELD READ, not a call.
 *     From `python tools/fldoff.py fields EFT.CameraControl.CameraManager`:
 *       0x70  <Camera>k__BackingField  Camera  private
 *     `get_Camera` is deliberately NOT called: mods/fov measured that it folds
 *     to 0x65ED10, `48 8B 41 70 C3` (`mov rax,[rcx+0x70]; ret`), a body SHARED
 *     with every other `+0x70` reference getter in the build. The getter IS the
 *     field read, so reading the field gives the identical answer with no
 *     shared-RVA exposure and no call at all.
 *
 * NOT MORE AGGRESSIVE. This adds at most one static call and one guarded field
 * read to a tick that already ran 24604 times, and it changes nothing about
 * WHEN the tick runs. The whole sampler is still gated on the ESP toggle, which
 * ships OFF, so with default flags this code is not reached at all.
 * ------------------------------------------------------------------ */
#define AOWL_ADM_RVA_CAM_MGR  0x1263BD0u
#define AOWL_ADM_OFF_MGR_CAM  0x70

static const unsigned char AOWL_ADM_SIG_CAM_MAIN[16] = {
    0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0xD5,0x27,0xE7,0x01,0x48,0x85,0xC0,0x75,0x18 };
static const unsigned char AOWL_ADM_SIG_CAM_W2C[16] = {
    0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x2F,0x3A,0xE7 };
static const unsigned char AOWL_ADM_SIG_CAM_PROJ[16] = {
    0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x5F,0x39,0xE7 };
static const unsigned char AOWL_ADM_SIG_CAM_MGR[16] = {
    0x48,0x83,0xEC,0x28,0x80,0x3D,0xE6,0x8B,0xE5,0x05,0x00,0x75,0x18,0x48,0x8D,0x0D };

typedef void* (*AowlAdmCamMainFn)(void* methodInfo);
typedef void  (*AowlAdmCamMatFn)(void* retbuf, void* self, void* methodInfo);

static AowlAdmCamMainFn aowl_adm_cam_main_fn = 0;
static AowlAdmCamMatFn  aowl_adm_cam_w2c_fn  = 0;
static AowlAdmCamMatFn  aowl_adm_cam_proj_fn = 0;
static AowlAdmCamMainFn aowl_adm_cam_mgr_fn  = 0;   /* CameraManager::get_Instance */

/* WHICH ROUTE produced the camera, and how often each was TRIED and came back
 * empty. These exist so the next reader does not have to re-derive what took a
 * live raid to find: a diagnostic that only says "no matrix" cannot distinguish
 * "Camera.main is null" from "CameraManager is null" from "the field is null",
 * and those have three different fixes.
 *   0 = nothing yet | 1 = Camera::get_main | 2 = CameraManager.Instance.Camera */
static int32_t aowl_adm_cam_route     = 0;
static int32_t aowl_adm_cam_main_null = 0;  /* get_main returned NULL          */
static int32_t aowl_adm_cam_mgr_null  = 0;  /* get_Instance returned NULL      */
static int32_t aowl_adm_cam_fld_null  = 0;  /* Instance live, +0x70 read NULL  */
static int32_t aowl_adm_cam_selftest_fail = 0;  /* finite, but not centre-projecting */

/* 0 = not attempted yet | 1 = GameAssembly.dll not loaded (transient) |
 * 2 = a prologue did NOT byte-match, i.e. a Tarkov update moved these RVAs |
 * 3 = all three bound. Never collapse 1 or 2 into "not in a raid". */
static int32_t aowl_adm_cam_bind = 0;

/* The published snapshot. `gen` is bumped only by a sample that produced a
 * plausible matrix, so a consumer can tell "never sampled" from "sampled and
 * refused". `stale` counts drains since the last good sample. */
static float   aowl_adm_cam_vp[16];
static int32_t aowl_adm_cam_gen   = 0;
static int32_t aowl_adm_cam_stale = 0;
static int32_t aowl_adm_cam_fail  = 0;   /* consecutive refusals: self-disable */
#define AOWL_ADM_CAM_MAXFAIL 240         /* ~4s at 60fps before giving up      */

/* Byte-verify one RVA and hand back a callable pointer, or NULL. The page is
 * checked with the same VirtualQuery guard every other hop in this header uses,
 * so a not-yet-mapped section is a refusal rather than a fault. */
static void* aowl_admin_bind_rva(unsigned char* base, uint32_t rva,
                                 const unsigned char* sig) {
    unsigned char* p = base + rva;
    if (!aowl_admin_readable(p, 16)) return 0;
    if (memcmp(p, sig, 16) != 0) return 0;
    return (void*)p;
}

static void aowl_admin_cam_resolve(void) {
    HMODULE ga;
    unsigned char* base;
    if (aowl_adm_cam_bind != 0) return;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_adm_cam_bind = 1; return; }
    base = (unsigned char*)ga;
    aowl_adm_cam_main_fn = (AowlAdmCamMainFn)
        aowl_admin_bind_rva(base, AOWL_ADM_RVA_CAM_MAIN, AOWL_ADM_SIG_CAM_MAIN);
    aowl_adm_cam_w2c_fn = (AowlAdmCamMatFn)
        aowl_admin_bind_rva(base, AOWL_ADM_RVA_CAM_W2C, AOWL_ADM_SIG_CAM_W2C);
    aowl_adm_cam_proj_fn = (AowlAdmCamMatFn)
        aowl_admin_bind_rva(base, AOWL_ADM_RVA_CAM_PROJ, AOWL_ADM_SIG_CAM_PROJ);
    /* The CameraManager route is OPTIONAL: a build where only this prologue
     * moved should lose the fallback, not the whole sampler. So its failure is
     * a NULL fn (reported through aowl_admin_cam_route_text) and never bind
     * state 2 -- collapsing it into the hard refusal below would turn a partial
     * regression into a total one. */
    aowl_adm_cam_mgr_fn = (AowlAdmCamMainFn)
        aowl_admin_bind_rva(base, AOWL_ADM_RVA_CAM_MGR, AOWL_ADM_SIG_CAM_MGR);
    if (!aowl_adm_cam_main_fn || !aowl_adm_cam_w2c_fn || !aowl_adm_cam_proj_fn) {
        aowl_adm_cam_bind = 2;                   /* prologue mismatch: refuse */
        aowl_adm_cam_main_fn = 0;
        aowl_adm_cam_w2c_fn  = 0;
        aowl_adm_cam_proj_fn = 0;
        aowl_adm_cam_mgr_fn  = 0;
        return;
    }
    aowl_adm_cam_bind = 3;
}

/* UNITY THREAD ONLY. The live Camera, or NULL, by whichever route works --
 * `Camera.main` first, then `CameraManager.Instance.<Camera>k__BackingField`.
 * Every hop is VirtualQuery-guarded (rule 2: `a->b` is two checks, not one) and
 * the route that succeeded is recorded so the diagnostic can say which. */
static void* aowl_admin_cam_object(void) {
    void* cam;
    void* mgr;

    cam = aowl_adm_cam_main_fn(0);       /* static: a NULL MethodInfo* is fine */
    if (cam && aowl_admin_readable(cam, 16)) { aowl_adm_cam_route = 1; return cam; }
    if (aowl_adm_cam_main_null < 1000000) aowl_adm_cam_main_null++;

    /* Tarkov's FPS camera carries no "MainCamera" tag, so the above is NULL for
     * the whole raid. This is the route the game itself uses. */
    if (!aowl_adm_cam_mgr_fn) return 0;
    mgr = aowl_adm_cam_mgr_fn(0);
    if (!mgr || !aowl_admin_readable(mgr, AOWL_ADM_OFF_MGR_CAM + 8)) {
        if (aowl_adm_cam_mgr_null < 1000000) aowl_adm_cam_mgr_null++;
        return 0;
    }
    /* A FIELD READ, not `get_Camera` -- that getter folds to a body SHARED with
     * every other `+0x70` reference getter in the build. Measured null on this
     * exact field 16ms before it became live in the same session that produced
     * the FOV log line, so a null here is EXPECTED during camera construction
     * and must not burn the fault budget. */
    cam = *(void**)((unsigned char*)mgr + AOWL_ADM_OFF_MGR_CAM);
    if (!cam || !aowl_admin_readable(cam, 16)) {
        if (aowl_adm_cam_fld_null < 1000000) aowl_adm_cam_fld_null++;
        return 0;
    }
    aowl_adm_cam_route = 2;
    return cam;
}

static int32_t aowl_admin_cam_route_get(void)     { return aowl_adm_cam_route; }
static int32_t aowl_admin_cam_mgr_bound(void)     { return aowl_adm_cam_mgr_fn ? 1 : 0; }
static int32_t aowl_admin_cam_main_nulls(void)    { return aowl_adm_cam_main_null; }
static int32_t aowl_admin_cam_mgr_nulls(void)     { return aowl_adm_cam_mgr_null; }
static int32_t aowl_admin_cam_fld_nulls(void)     { return aowl_adm_cam_fld_null; }
static int32_t aowl_admin_cam_selftest_fails(void) { return aowl_adm_cam_selftest_fail; }

/* State 1 must NOT latch -- GameAssembly.dll is simply not mapped yet when the
 * mod loads, and latching it would report "unavailable" for the whole session
 * over a condition that clears a second later. */
static int32_t aowl_admin_cam_state(void) {
    if (aowl_adm_cam_bind == 1) aowl_adm_cam_bind = 0;
    aowl_admin_cam_resolve();
    return aowl_adm_cam_bind;
}

/* A finite matrix that actually projects. This is a property of the FINISHED
 * matrix, not a restatement of the call: an all-zero retbuf -- which is exactly
 * what these getters leave behind if the icall slot is not filled in, since
 * they zero the buffer before dispatching -- fails it, as does any NaN. */
static int32_t aowl_admin_mat_sane(const float* m) {
    int i;
    float acc = 0.0f;
    for (i = 0; i < 16; i++) {
        float v = m[i];
        if (v != v) return 0;                       /* NaN                    */
        if (v > 1.0e12f || v < -1.0e12f) return 0;  /* infinity / absurd      */
        acc += (v < 0.0f ? -v : v);
    }
    return acc > 1.0e-3f ? 1 : 0;                   /* not the zeroed retbuf  */
}

/* THE FINISHED-STATE CHECK (CLAUDE.md 9b).
 *
 * `aowl_admin_mat_sane` is necessary and NOT sufficient: it only says the 16
 * floats are finite and not all zero. A view-projection that is transposed, or
 * multiplied in the wrong order (V*P instead of P*V), or built from a
 * row-major reading of a column-major buffer, is finite and non-zero too -- it
 * passes `mat_sane` and then projects every entity off-screen. That is exactly
 * the failure the ESP status line already warns reads like success, and it is
 * the shape a check that cannot fail would let through.
 *
 * So assert a property of the FINISHED matrix instead, and one that CANNOT be
 * satisfied by restating our own arithmetic: a point ten metres DIRECTLY IN
 * FRONT of the camera must project to the middle of the screen.
 *
 * The point is derived from the VIEW matrix, independently of `vp`. `view` is
 * worldToCamera, a rigid transform c = R*w + t with R the upper-left 3x3 and t
 * the translation column, so the inverse is w = R^T * (c - t) -- no general
 * matrix inverse needed. Feed it camera-space (0, 0, -10): Unity's view space
 * is right-handed and looks down -Z, so that is "ten metres ahead". Push the
 * resulting WORLD point back through `vp` and it must
 *
 *   * be in FRONT of the camera (cw > 0), and
 *   * land within the middle fifth of the frame in both axes.
 *
 * Falsifiable, and each listed defect fails it: a transposed VP rotates the
 * point away from centre; the wrong multiplication order puts cw <= 0 or throws
 * it to the edge; a stale or mismatched view/proj pair disagrees about where
 * forward is. It is checked against a NOMINAL 1000x1000 frame because the
 * property is about normalised device coordinates, not about the back buffer --
 * making it depend on the real resolution would add a second thing to get wrong
 * without making the test stronger. */
static int32_t aowl_admin_vp_projects(const float* view, const float* vp) {
    float c[3];
    float w[3];
    float sx = 0.0f, sy = 0.0f;
    int j, r;
    const float kAhead = 10.0f;
    c[0] = 0.0f; c[1] = 0.0f; c[2] = -kAhead;
    for (j = 0; j < 3; j++) {
        float s = 0.0f;
        for (r = 0; r < 3; r++) s += view[j*4 + r] * (c[r] - view[12 + r]);
        w[j] = s;
        if (s != s || s > 1.0e9f || s < -1.0e9f) return 0;
    }
    /* aowl_admin_project already refuses cw <= 0.0001f, i.e. behind the camera. */
    if (!aowl_admin_project(vp, w[0], w[1], w[2], 1000, 1000, &sx, &sy)) return 0;
    if (sx != sx || sy != sy) return 0;
    if (sx < 400.0f || sx > 600.0f) return 0;
    if (sy < 400.0f || sy > 600.0f) return 0;
    return 1;
}

/* UNITY THREAD ONLY. Returns 1 when the snapshot was refreshed by this call.
 *
 * Returning 0 is never silent: the REASON is readable through
 * aowl_admin_cam_state() / _gen() / _stale() / _disabled(), and the mod's
 * status line and adminDiag() print it. Nothing here writes game memory. */
static int32_t aowl_admin_cam_sample(void) {
    void* cam;
    float view[16];
    float proj[16];
    float vp[16];
    int i;

    if (aowl_adm_cam_fail >= AOWL_ADM_CAM_MAXFAIL) return 0;  /* self-disabled */
    if (aowl_admin_cam_state() != 3) { aowl_adm_cam_fail++; return 0; }

    cam = aowl_admin_cam_object();
    if (!cam) {
        /* No camera by EITHER route. Normal in the menu and during camera
         * construction, and NOT a bind failure -- so it does not burn the fault
         * budget, it only ages the snapshot. Which route came up empty, and how
         * often, is in aowl_admin_cam_*_nulls(). */
        if (aowl_adm_cam_stale < 1000000) aowl_adm_cam_stale++;
        return 0;
    }
    for (i = 0; i < 16; i++) { view[i] = 0.0f; proj[i] = 0.0f; }
    aowl_adm_cam_w2c_fn(view, cam, 0);
    aowl_adm_cam_proj_fn(proj, cam, 0);
    if (!aowl_admin_mat_sane(view) || !aowl_admin_mat_sane(proj)) {
        aowl_adm_cam_fail++;
        if (aowl_adm_cam_stale < 1000000) aowl_adm_cam_stale++;
        return 0;
    }
    aowl_admin_mat_mul(proj, view, vp);  /* VP = P * V, Unity column-major */
    if (!aowl_admin_mat_sane(vp)) { aowl_adm_cam_fail++; return 0; }
    if (!aowl_admin_vp_projects(view, vp)) {
        /* Counted SEPARATELY from every other refusal. If this is the number
         * that climbs, the matrices were finite and the self-test above is what
         * rejected them -- i.e. either the view/proj pair really is unusable,
         * or the -Z forward convention in aowl_admin_vp_projects is wrong for
         * this build. Those need opposite fixes, and a single fault counter
         * cannot tell them apart. */
        if (aowl_adm_cam_selftest_fail < 1000000) aowl_adm_cam_selftest_fail++;
        aowl_adm_cam_fail++;
        return 0;
    }
    for (i = 0; i < 16; i++) aowl_adm_cam_vp[i] = vp[i];
    aowl_adm_cam_gen++;
    aowl_adm_cam_stale = 0;
    aowl_adm_cam_fail  = 0;
    return 1;
}

static int32_t aowl_admin_cam_gen(void)   { return aowl_adm_cam_gen; }
static int32_t aowl_admin_cam_stale(void) { return aowl_adm_cam_stale; }
static int32_t aowl_admin_cam_disabled(void) {
    return aowl_adm_cam_fail >= AOWL_ADM_CAM_MAXFAIL ? 1 : 0;
}

/* The projectable predicate that the ESP capability bit, the draw loop and
 * adminDiag() all read, so the three cannot drift apart: bound, sampled at
 * least once, sampled RECENTLY, and not self-disabled. */
static int32_t aowl_admin_cam_ready(void) {
    return (aowl_adm_cam_bind == 3 && aowl_adm_cam_gen > 0 &&
            aowl_adm_cam_stale < 120 && aowl_adm_cam_fail < AOWL_ADM_CAM_MAXFAIL)
           ? 1 : 0;
}

/* ANY thread. Project one world point through the published snapshot. */
static int32_t aowl_admin_w2s(float x, float y, float z, int32_t w, int32_t h,
                              float* sx, float* sy) {
    if (!aowl_admin_cam_ready()) return 0;
    return aowl_admin_project(aowl_adm_cam_vp, x, y, z, w, h, sx, sy);
}


/* ================================================================== *
 * Action hotkeys
 * ==================================================================
 *
 * A key that toggles an admin action, user-assignable, read through the
 * GAME'S OWN INPUT rather than through Windows.
 *
 * WHY Input::GetKeyDown AND NOT THE WNDPROC. Two delivery paths already exist
 * in this codebase and both work:
 *   * `GetAsyncKeyState` (the F3 overlay). Global, not a window message, so
 *     the WM_KEYDOWN-vs-WM_SYSKEYDOWN routing that once hid F10 from the D3D
 *     overlay's wndproc cannot affect it -- but for the same reason it fires
 *     while the game is in the BACKGROUND and while the player is typing into
 *     another application. For a key that turns God mode on, that is wrong.
 *   * the overlay wndproc (F6; the F12 panel additionally reads typed
 *     characters from WM_CHAR). Correct about focus, but it speaks Win32
 *     virtual-keys, so a user-assignable bind would need a VK<->KeyCode
 *     mapping -- 328 entries of exactly the hand-typed constants that are
 *     forbidden here.
 * `UnityEngine.Input::GetKeyDown(KeyCode)` is neither: it is the same input
 * the game itself reads, it is already false when the window is not focused,
 * it is edge-triggered by construction, and its argument is a KeyCode -- the
 * one namespace config.json, the settings page and the F6 menu all use.
 * Nothing here is tested with a synthetic message, because nothing here reads
 * a message.
 *
 * THREAD. `Input::` is Unity's, so `aowl_admin_hotkey_poll()` is UNITY THREAD
 * ONLY and is driven from the same `everyMain` tick that drives the camera
 * sampler. Off that thread it is never called.
 *
 * MEASURED, build 1.1.0.1.46777:
 *   UnityEngine.Input::GetKeyDown(KeyCode) -> bool  rid=45, STATIC, arity 1
 *   RVA 0x531EB80, section `il2cpp`,
 *   bytes 40 53 48 83 EC 20 48 8B 05 9B 71 DB 01 8B D9 48
 *   -- `il2cpp_resolve.py bytes 0x531eb80 16` against the installed
 *   D:/Games/Tarkov/GameAssembly.dll. It is NOT the universal empty-body stub
 *   at 0x628110 (`C2 00 00`). It SHARES its RVA with `GetKeyDownInt(KeyCode)`,
 *   the same body under its internal name; sharing is a hazard for a DETOUR,
 *   which has unbounded blast radius, and this only ever CALLS it, with the
 *   argument it is correct for. A KeyCode is an enum over Int32, so the
 *   argument is one integer register; the trailing hidden `const MethodInfo*`
 *   is NULL, which is legal because the method is not generic.
 */

#define AOWL_ADM_RVA_GETKEYDOWN 0x531EB80u
static const unsigned char AOWL_ADM_SIG_GETKEYDOWN[16] = {
    0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x9B,0x71,0xDB,0x01,0x8B,0xD9,0x48 };

typedef int32_t (*AowlAdmGetKeyDownFn)(int32_t keyCode, void* methodInfo);
static AowlAdmGetKeyDownFn aowl_adm_getkeydown_fn = 0;

/* 0 not attempted | 1 GameAssembly.dll not mapped yet (TRANSIENT, must not
 * latch) | 2 PROLOGUE MISMATCH -- refused, nothing called | 3 bound. */
static int32_t aowl_adm_hk_bind = 0;
static int32_t aowl_adm_hk_fail = 0;
#define AOWL_ADM_HK_MAXFAIL 240

static int32_t aowl_admin_hotkey_state(void) {
    HMODULE ga;
    if (aowl_adm_hk_bind == 1) aowl_adm_hk_bind = 0;
    if (aowl_adm_hk_bind != 0) return aowl_adm_hk_bind;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_adm_hk_bind = 1; return 1; }
    aowl_adm_getkeydown_fn = (AowlAdmGetKeyDownFn)aowl_admin_bind_rva(
        (unsigned char*)ga, AOWL_ADM_RVA_GETKEYDOWN, AOWL_ADM_SIG_GETKEYDOWN);
    aowl_adm_hk_bind = aowl_adm_getkeydown_fn ? 3 : 2;
    return aowl_adm_hk_bind;
}

static int32_t aowl_admin_hotkey_disabled(void) {
    return aowl_adm_hk_fail >= AOWL_ADM_HK_MAXFAIL ? 1 : 0;
}

static void aowl_admin_hotkey_note(AowlAdminShared* s, const char* text) {
    size_t n;
    if (!s || !text) return;
    n = strlen(text);
    if (n >= AOWL_ADM_STATUS_LEN) n = AOWL_ADM_STATUS_LEN - 1;
    memcpy(s->hotkeyNote, text, n);
    s->hotkeyNote[n] = 0;
}

static void aowl_adm_note_cat(char* msg, const char* add) {
    size_t used = strlen(msg);
    if (used >= (size_t)(AOWL_ADM_STATUS_LEN - 1)) return;
    strncat(msg, add, (size_t)(AOWL_ADM_STATUS_LEN - 1) - used);
}

static int32_t aowl_admin_hotkey_get(AowlAdminShared* s, int32_t row) {
    if (!s || row < 0 || row >= AOWL_ADM_COUNT) return AOWL_KC_UNBOUND;
    return (int32_t)s->hotkeyKc[row];
}

/* The ONE place a slot is written, so every caller gets the same rules.
 * Returns 1 on success, 0 on a REFUSAL -- and a refusal always leaves a reason
 * in `hotkeyNote`, naming the key, never folding it onto anything. */
static int32_t aowl_admin_hotkey_set(AowlAdminShared* s, int32_t row, int32_t kc) {
    int i;
    char msg[AOWL_ADM_STATUS_LEN];
    const char* kn;
    if (!s || row < 0 || row >= AOWL_ADM_COUNT) return 0;
    if (kc == AOWL_KC_UNBOUND) {                     /* clearing is always ok */
        s->hotkeyKc[row] = AOWL_KC_UNBOUND;
        InterlockedIncrement(&s->hotkeyEpoch);
        return 1;
    }
    kn = aowl_keycode_name(kc);
    if (!kn) {
        aowl_admin_hotkey_note(s, "REFUSED: that ordinal is not a "
                                  "UnityEngine.KeyCode member");
        return 0;
    }
    /* An action whose WRITE is not bound on this build must not get a key. A
     * hotkey that does nothing is worse than no hotkey: it teaches the player
     * that the KEY is broken rather than that the FEATURE is absent. */
    if (!aowl_admin_capable(s, row)) {
        msg[0] = 0;
        aowl_adm_note_cat(msg, "REFUSED: ");
        aowl_adm_note_cat(msg, aowl_admin_mode_name(row));
        aowl_adm_note_cat(msg, " is not bound on this build, so a key on it "
                               "would do nothing");
        aowl_admin_hotkey_note(s, msg);
        return 0;
    }
    /* One key, one action. A duplicate would fire two toggles from one press. */
    for (i = 0; i < AOWL_ADM_COUNT; i++) {
        if (i != row && (int32_t)s->hotkeyKc[i] == kc) {
            msg[0] = 0;
            aowl_adm_note_cat(msg, "REFUSED: ");
            aowl_adm_note_cat(msg, kn);
            aowl_adm_note_cat(msg, " is already bound to ");
            aowl_adm_note_cat(msg, aowl_admin_mode_name(i));
            aowl_admin_hotkey_note(s, msg);
            return 0;
        }
    }
    s->hotkeyKc[row] = kc;
    InterlockedIncrement(&s->hotkeyEpoch);
    return 1;
}

/* Set from a NAME, which is what config.json and the settings page carry.
 * An unknown name is REFUSED WITH THE NAME PRINTED. It is never resolved to
 * KeyCode.None, which is a real key with ordinal 0. The empty string (and
 * "-") is the one spelling that means "unbound", and it means only that. */
static int32_t aowl_admin_hotkey_set_name(AowlAdminShared* s, int32_t row,
                                          const char* name) {
    int32_t kc;
    char msg[AOWL_ADM_STATUS_LEN];
    if (!s || row < 0 || row >= AOWL_ADM_COUNT) return 0;
    if (!name || !name[0] || strcmp(name, "-") == 0)
        return aowl_admin_hotkey_set(s, row, AOWL_KC_UNBOUND);
    kc = aowl_keycode_of(name);
    if (kc == AOWL_KC_UNKNOWN) {
        msg[0] = 0;
        aowl_adm_note_cat(msg, "REFUSED: \"");
        aowl_adm_note_cat(msg, name);
        aowl_adm_note_cat(msg, "\" is not a UnityEngine.KeyCode member -- left "
                               "UNBOUND, not read as KeyCode.None");
        aowl_admin_hotkey_note(s, msg);
        s->hotkeyKc[row] = AOWL_KC_UNBOUND;
        InterlockedIncrement(&s->hotkeyEpoch);
        return 0;
    }
    return aowl_admin_hotkey_set(s, row, kc);
}

/* The name of the key on a row, or "" for unbound. Never a bare number. */
static const char* aowl_admin_hotkey_name(AowlAdminShared* s, int32_t row) {
    const char* n;
    if (!s || row < 0 || row >= AOWL_ADM_COUNT) return "";
    n = aowl_keycode_name((int32_t)s->hotkeyKc[row]);
    return n ? n : "";
}

static const char* aowl_admin_hotkey_note_text(AowlAdminShared* s) {
    return s ? s->hotkeyNote : "";
}

/* Rebind capture: the overlay asks, the mod answers on Unity's thread. */
static void aowl_admin_hotkey_capture_begin(AowlAdminShared* s, int32_t row) {
    if (!s || row < 0 || row >= AOWL_ADM_COUNT) return;
    aowl_admin_hotkey_note(s, "");
    InterlockedExchange(&s->hotkeyCapture, row);
}
static void aowl_admin_hotkey_capture_cancel(AowlAdminShared* s) {
    if (s) InterlockedExchange(&s->hotkeyCapture, -1);
}
static int32_t aowl_admin_hotkey_capturing(AowlAdminShared* s) {
    return (s && s->hotkeyCapture >= 0) ? 1 : 0;
}

/* Keys a bind may not take, because taking them would make the menu itself
 * unusable or the bind unreachable: F6 opens this menu, Escape cancels a
 * capture, and None is a KeyCode member that no key produces.
 *
 * Every one is looked up BY NAME in the generated table -- there is not a
 * single key ordinal typed anywhere in this file. `aowl_keycode_of` returns
 * -1 for a name it does not have, and -1 matches no live KeyCode, so a table
 * that somehow lost a member degrades to "not reserved" rather than to a
 * wrong reservation. */
static int32_t aowl_admin_hotkey_reserved(int32_t kc) {
    if (kc == AOWL_KC_UNBOUND) return 1;
    return (kc == aowl_keycode_of("F6") ||
            kc == aowl_keycode_of("Escape") ||
            kc == aowl_keycode_of("None")) ? 1 : 0;
}

/* ------------------------------------------------------------------
 * UNITY THREAD ONLY. One call per frame. Returns row+1 for the action it
 * toggled this frame, or 0.
 *
 * DEFAULT OFF, twice over: `enabled` is the mod's flag (config.json,
 * default false), and with every slot at AOWL_KC_UNBOUND -- which is the
 * shipped state -- the loop below makes ZERO calls into the game.
 *
 * Capped: at most AOWL_ADM_COUNT (12) calls per frame when polling, and at
 * most AOWL_KC_COUNT (328) on the one frame a capture resolves. Both are
 * compile-time bounds over fixed-size tables; neither reads a count out of
 * game memory. Nothing here allocates.
 * ------------------------------------------------------------------ */
static int32_t aowl_admin_hotkey_poll(AowlAdminShared* s, int32_t enabled) {
    int i;
    int32_t cap;
    if (!s || !enabled) return 0;
    if (aowl_adm_hk_fail >= AOWL_ADM_HK_MAXFAIL) return 0;   /* self-disabled */

    cap = (int32_t)s->hotkeyCapture;

    /* Nothing to do at all in the shipped state: no capture in flight and no
     * key assigned. This is the branch that makes "flag on, nothing bound"
     * cost nothing and call nothing. */
    if (cap < 0) {
        int any = 0;
        for (i = 0; i < AOWL_ADM_COUNT; i++)
            if ((int32_t)s->hotkeyKc[i] != AOWL_KC_UNBOUND) { any = 1; break; }
        if (!any) return 0;
    }

    if (aowl_admin_hotkey_state() != 3) { aowl_adm_hk_fail++; return 0; }
    aowl_adm_hk_fail = 0;

    if (cap >= 0 && cap < AOWL_ADM_COUNT) {
        /* Capture frame. Escape is tested FIRST, so a cancel can never be
         * mistaken for a bind to Escape. */
        if (aowl_adm_getkeydown_fn(aowl_keycode_of("Escape"), 0)) {
            aowl_admin_hotkey_capture_cancel(s);
            aowl_admin_hotkey_note(s, "rebind cancelled");
            return 0;
        }
        if (aowl_adm_getkeydown_fn(aowl_keycode_of("Delete"), 0)) {  /* unbind */
            aowl_admin_hotkey_set(s, cap, AOWL_KC_UNBOUND);
            aowl_admin_hotkey_capture_cancel(s);
            aowl_admin_hotkey_note(s, "unbound");
            return 0;
        }
        for (i = 0; i < AOWL_KC_COUNT; i++) {
            int32_t kc = AOWL_KEYCODES[i].ordinal;
            if (aowl_admin_hotkey_reserved(kc)) continue;
            if (aowl_adm_getkeydown_fn(kc, 0)) {
                char msg[AOWL_ADM_STATUS_LEN];
                if (aowl_admin_hotkey_set(s, cap, kc)) {
                    msg[0] = 0;
                    aowl_adm_note_cat(msg, "bound ");
                    aowl_adm_note_cat(msg, AOWL_KEYCODES[i].name);
                    aowl_adm_note_cat(msg, " -> ");
                    aowl_adm_note_cat(msg, aowl_admin_mode_name(cap));
                    aowl_admin_hotkey_note(s, msg);
                }
                /* On a refusal the slot is untouched and `hotkeyNote` already
                 * says why; either way the capture ENDS, so the player is
                 * never left in a capture whose outcome they cannot see. */
                aowl_admin_hotkey_capture_cancel(s);
                return 0;
            }
        }
        return 0;                                  /* still waiting for a key */
    }

    /* Ordinary poll. At most one action per frame -- two toggles from one
     * frame would be two state changes the player cannot attribute. */
    for (i = 0; i < AOWL_ADM_COUNT; i++) {
        int32_t kc = (int32_t)s->hotkeyKc[i];
        if (kc == AOWL_KC_UNBOUND) continue;
        if (!aowl_admin_capable(s, i)) continue;    /* not bound: never fires */
        if (aowl_adm_getkeydown_fn(kc, 0)) {
            aowl_admin_toggle_flip(s, i);
            InterlockedIncrement(&s->hotkeyFires);
            return i + 1;
        }
    }
    return 0;
}

static const char* aowl_admin_hotkey_state_text_c(void);

/* Byte-at accessors. nimony has no `$` for `cstring`, so the mod cannot read
 * a `const char*` return at all -- the same reason `spawnQueryAt` exists. A
 * one-byte-at-a-time read is also bounded by construction: it cannot walk off
 * the end of an unterminated buffer, because the caller supplies the cap. */
static int32_t aowl_admin_hotkey_name_at(AowlAdminShared* s, int32_t row, int32_t i) {
    const char* n = aowl_admin_hotkey_name(s, row);
    if (!n || i < 0 || i >= AOWL_ADM_STATUS_LEN) return 0;
    { int32_t k = 0; while (k < i) { if (!n[k]) return 0; k++; } }
    return (int32_t)(unsigned char)n[i];
}
static int32_t aowl_admin_hotkey_note_at(AowlAdminShared* s, int32_t i) {
    if (!s || i < 0 || i >= AOWL_ADM_STATUS_LEN) return 0;
    return (int32_t)(unsigned char)s->hotkeyNote[i];
}
static int32_t aowl_admin_hotkey_state_at(int32_t i) {
    const char* n = aowl_admin_hotkey_state_text_c();
    if (!n || i < 0 || i >= 512) return 0;
    { int32_t k = 0; while (k < i) { if (!n[k]) return 0; k++; } }
    return (int32_t)(unsigned char)n[i];
}

static int32_t aowl_admin_hotkey_fires(AowlAdminShared* s) {
    return s ? (int32_t)s->hotkeyFires : 0;
}
static int32_t aowl_admin_hotkey_epoch(AowlAdminShared* s) {
    return s ? (int32_t)s->hotkeyEpoch : 0;
}

/* Why a hotkey did not fire, in words. Never collapses "not bound on this
 * build" into "no key assigned" or into "the poll is off". */
static const char* aowl_admin_hotkey_state_text_c(void) {
    switch (aowl_adm_hk_bind) {
        case 0: return "not attempted";
        case 1: return "GameAssembly.dll is not mapped yet (transient)";
        case 2: return "PROLOGUE MISMATCH at Input::GetKeyDown 0x531EB80 -- "
                       "REFUSED, nothing was called. Either a Tarkov update "
                       "moved this RVA or something else detoured it";
        default: return "Input::GetKeyDown bound and byte-verified";
    }
}

#ifdef __cplusplus
}
#endif

#endif /* AOWLSPT_ADMIN_H */
