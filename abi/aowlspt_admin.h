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

/* ESP and godmode on, everything else off. Seeded once by the mod. */
#define AOWL_ADM_DEFAULTS \
    (((uint32_t)1 << AOWL_ADM_ESP) | ((uint32_t)1 << AOWL_ADM_GODMODE))

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

#define AOWL_ADM_MAX_ENTITIES 256
#define AOWL_ADM_NAME_LEN     24
#define AOWL_ADM_STATUS_LEN   192
#define AOWL_ADM_REGION_NAME  "Local\\aowlspt_admin_shared_v3"
#define AOWL_ADM_MAGIC        0x414F574C41444D33ull  /* "AOWLADM3"            */
#define AOWL_ADM_VERSION      3

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
    while (n < 0) n += AOWL_ADM_COUNT;
    while (n >= AOWL_ADM_COUNT) n -= AOWL_ADM_COUNT;
    InterlockedExchange(&s->menuSel, n);
}
/* Flip the selected mode -- but only if the mod says it is capable, so a menu
 * gesture never turns on a mode that would silently do nothing. */
static void aowl_admin_menu_activate(AowlAdminShared* s) {
    if (!s) return;
    int32_t sel = (int32_t)s->menuSel;
    if (aowl_admin_capable(s, sel))
        aowl_admin_toggle_flip(s, sel);
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

static int32_t aowl_admin_readable(const void* p, int32_t size) {
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

#ifdef __cplusplus
}
#endif

#endif /* AOWLSPT_ADMIN_H */
