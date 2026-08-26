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
#include <setjmp.h>

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
    /* was AOWL_ADM_FLY ("Fly / noclip"), which was never bound to anything.
     * Re-used for MOVE SPEED, which IS bound: two measured MovementContext
     * floats with a captured base and a clamped multiplier. A bit that reads
     * "Fly" and does nothing is worse than no bit. */
    AOWL_ADM_SPEED      = 9,
    AOWL_ADM_TELEPORT   = 10,
    AOWL_ADM_TIMEOFDAY  = 11,
    /* --- added: independently flag-gated ESP LAYERS and extra modes. Each is
     * a separate bit so a layer can be off while the master ESP bit is on;
     * every layer is enforced PRODUCER-side (the mod publishes nothing for a
     * layer that is off), so the HUD needed no change to honour them. --- */
    AOWL_ADM_LOOTESP    = 12,  /* loose loot / dropped items, own layer       */
    AOWL_ADM_ESPNAMES   = 13,  /* nicknames on the player boxes               */
    AOWL_ADM_ESPDIST    = 14,  /* metres under the player boxes               */
    AOWL_ADM_ESPBOX     = 15,  /* the box itself (off => labels only)         */
    /* --- THE ITEM SPAWNER. These four are MOMENTARY ACTIONS, not modes. ---
     *
     * They live in `toggles` because that is the only thing the F6 menu can
     * write, and the menu needed NO change to gain four more rows: it draws
     * `AOWL_ADM_COUNT` of them and activates whichever is selected. The mod
     * clears the bit again on the very next tick after acting, so the row
     * flashes ON and returns to OFF -- which is the honest rendering of an
     * action, since a stuck-ON action row would read as a mode that is running
     * and none of these keeps running.
     *
     * `capability` is published for them exactly like a mode: the mod sets the
     * bit only once it can actually reach a spawner (see AowlSpawnShared
     * below), so pressing one when the emulator is not there is refused by the
     * menu itself rather than appearing to work.
     *
     * The struct is UNCHANGED by this addition -- `toggles` and `capability`
     * are 32-bit masks with room to spare and `ents[]` is fixed -- so a binary
     * built against the older header maps the SAME region at the same size and
     * simply draws sixteen rows instead of twenty. That was the whole reason
     * for reusing the toggle mask rather than growing the struct: growing it
     * would change the mapping size, and the second mapper of a named section
     * with a different size fails, which would have silently killed the ESP and
     * the menu in whichever process rebuilt last. */
    AOWL_ADM_SPAWNPREV  = 16,  /* select the previous inventory preset        */
    AOWL_ADM_SPAWNNEXT  = 17,  /* select the next inventory preset            */
    AOWL_ADM_SPAWNKIT   = 18,  /* apply the selected preset into the stash    */
    AOWL_ADM_SPAWNITEM  = 19,  /* spawn the current search query              */
    AOWL_ADM_COUNT      = 20
};

/* The four action bits as a mask, so a consumer can ask "is this row an action
 * rather than a mode" in one test instead of four comparisons. */
#define AOWL_ADM_ACTION_MASK ((uint32_t)((1u << AOWL_ADM_SPAWNPREV) | \
                                         (1u << AOWL_ADM_SPAWNNEXT) | \
                                         (1u << AOWL_ADM_SPAWNKIT)  | \
                                         (1u << AOWL_ADM_SPAWNITEM)))
static int32_t aowl_admin_is_action(int32_t bit) {
    if (bit < 0 || bit >= 32) return 0;
    return ((AOWL_ADM_ACTION_MASK >> bit) & 1u) ? 1 : 0;
}

/* EVERY cheat off. Seeded once by the mod.
 *
 * ESP and God mode used to default ON here. For a build handed to testers a
 * cheat must default OFF -- the player opts in from the F6 menu or the settings
 * screen. This is the same default the schema and config.json now carry; all
 * three have to agree or the "default" depends on which one ran last. */
/* The CHEAT bits are all 0. The three ESP PRESENTATION bits (names, distance,
 * boxes) default ON -- they are not cheats on their own: with the master
 * AOWL_ADM_ESP bit off they publish and draw nothing at all, and with it on a
 * user who opted into ESP wants boxes rather than an empty screen and three
 * more menu presses. AOWL_ADM_LOOTESP is a separate opt-in and stays 0. */
#define AOWL_ADM_DEFAULTS  ((uint32_t)((1u << AOWL_ADM_ESPNAMES) |                                        (1u << AOWL_ADM_ESPDIST)  |                                        (1u << AOWL_ADM_ESPBOX)))

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
        case AOWL_ADM_SPEED:     return "Move speed x";
        case AOWL_ADM_TELEPORT:  return "Teleport to marker";
        case AOWL_ADM_TIMEOFDAY: return "Time flow / freeze";
        case AOWL_ADM_LOOTESP:   return "Loot ESP";
        case AOWL_ADM_ESPNAMES:  return "ESP: names";
        case AOWL_ADM_ESPDIST:   return "ESP: distance";
        case AOWL_ADM_ESPBOX:    return "ESP: boxes";
        case AOWL_ADM_SPAWNPREV: return "Spawn: prev preset";
        case AOWL_ADM_SPAWNNEXT: return "Spawn: next preset";
        case AOWL_ADM_SPAWNKIT:  return "Spawn: apply preset";
        case AOWL_ADM_SPAWNITEM: return "Spawn: search query";
        default:                 return "?";
    }
}

/* Side colouring, published per entity; the HUD maps these to colours. */
enum {
    AOWL_ADM_SIDE_UNKNOWN = 0,
    AOWL_ADM_SIDE_FRIEND  = 1,   /* same side as the local player            */
    AOWL_ADM_SIDE_ENEMY   = 2,   /* a human enemy                            */
    AOWL_ADM_SIDE_SCAV    = 3,   /* an AI scav / raider                      */
    AOWL_ADM_SIDE_BOSS    = 4,   /* a boss or guard                          */
    AOWL_ADM_SIDE_LOOT    = 5    /* a dropped item / loose loot marker        */
};

/* Per-entity flags. */
#define AOWL_ADM_F_ISAI     0x1u
#define AOWL_ADM_F_DEAD     0x2u
#define AOWL_ADM_F_ONSCREEN 0x4u   /* projected in front of the camera        */
#define AOWL_ADM_F_LOOT     0x8u   /* a loot marker, not a player             */

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

/* ================================================================== *
 * THE ITEM-SPAWNER MAILBOX -- a SECOND, SEPARATE named region.
 * ================================================================== *
 *
 * Why a second region rather than four more fields on AowlAdminShared: the
 * admin region is mapped by two binaries that are not rebuilt together in
 * every situation (the host DLL carries the HUD, the mod DLL carries the
 * producer). `CreateFileMappingA` on an existing name keeps the ORIGINAL
 * section's size, and a `MapViewOfFile` for more bytes than the section holds
 * FAILS -- so growing the struct would make whichever process started second
 * get a NULL region and lose the ESP and the F6 menu entirely, with no error
 * anyone would connect to a struct change. A separate region cannot do that:
 * the worst case is that the spawner is unavailable and says so.
 *
 * WHO TALKS TO IT. Three processes may map it, and the split is the point:
 *
 *   * the game client (mods/admin, side=client) is the REQUESTER. It has no
 *     HTTP client and no route to another mod -- `provide()` is refused on the
 *     client outright -- so it cannot spawn anything itself and must not try.
 *   * the backend (mods/admin, side=sim) is the DISPATCHER. It runs in the
 *     same process as the emulator mod, so `invoke("aowl.items.spawn", ...)`
 *     from there reaches a real provider. It polls this mailbox and answers.
 *   * the overlay (the HUD) is a READER, for drawing the last answer.
 *
 * That is the whole reason this file gained a mailbox instead of the mod
 * gaining an HTTP client: the SEARCH and the SPAWN both stay server-side,
 * where the 41 MB database already is. Nothing here ever parses an item list
 * on the Unity thread; the client's entire per-frame cost is one LONG compare.
 *
 * PROTOCOL. One requester, one dispatcher, no locks:
 *   requester: if reqSeq != ackSeq the mailbox is BUSY -- refuse, do not queue.
 *              otherwise write kind/count/presetIdx/query, THEN bump reqSeq.
 *   dispatcher: while ackSeq != reqSeq, copy the request out, do the work,
 *              write outcome/matched/shown/message/lines, THEN store ackSeq.
 * The two `THEN`s are the ordering that makes this safe: the sequence number
 * is always the last write on each side, so a reader that sees the new number
 * sees the payload that goes with it.
 * ------------------------------------------------------------------ */

#define AOWL_SPW_REGION_NAME "Local\\aowlspt_spawn_v1"
#define AOWL_SPW_MAGIC       0x414F574C53505701ull   /* "AOWLSPW" + 1        */
#define AOWL_SPW_VERSION     1
#define AOWL_SPW_QUERY_LEN   96
#define AOWL_SPW_MSG_LEN     256
#define AOWL_SPW_LINES       10
#define AOWL_SPW_LINE_LEN    72

enum {
    AOWL_SPW_KIND_NONE   = 0,
    AOWL_SPW_KIND_SEARCH = 1,   /* look up `query`, spawn nothing            */
    AOWL_SPW_KIND_ITEM   = 2,   /* spawn `count` of what `query` names       */
    AOWL_SPW_KIND_PRESET = 3    /* apply preset `presetIdx`                  */
};

/* Outcomes. 0 is "never answered", which is DIFFERENT from a refusal and is
 * rendered as INCONCLUSIVE -- a mailbox nobody is listening to must not read
 * as "no such item". The refusal codes mirror `CapOutcome` in the SDK's
 * capability module one for one, so the taxonomy the SDK worked out is not
 * flattened on its way to the screen. */
enum {
    AOWL_SPW_OUT_NONE              = 0,
    AOWL_SPW_OUT_OK                = 1,
    AOWL_SPW_OUT_PROVIDER_ERROR    = 2,
    AOWL_SPW_OUT_VERSION_MISMATCH  = 3,
    AOWL_SPW_OUT_PROVIDER_NOTLOADED= 4,   /* installed, switched OFF         */
    AOWL_SPW_OUT_PROVIDER_SILENT   = 5,
    AOWL_SPW_OUT_NO_PROVIDER       = 6,   /* not installed at all            */
    AOWL_SPW_OUT_ROSTER_UNKNOWN    = 7,
    AOWL_SPW_OUT_BAD_REPLY         = 8,
    AOWL_SPW_OUT_UNAVAILABLE       = 9,
    AOWL_SPW_OUT_LOCAL_REFUSED     = 10   /* the requester declined to ask   */
};

static const char* aowl_spw_outcome_name(int32_t o) {
    switch (o) {
        case AOWL_SPW_OUT_OK:                 return "ok";
        case AOWL_SPW_OUT_PROVIDER_ERROR:     return "provider-error";
        case AOWL_SPW_OUT_VERSION_MISMATCH:   return "version-mismatch";
        case AOWL_SPW_OUT_PROVIDER_NOTLOADED: return "provider-not-loaded";
        case AOWL_SPW_OUT_PROVIDER_SILENT:    return "provider-silent";
        case AOWL_SPW_OUT_NO_PROVIDER:        return "no-provider";
        case AOWL_SPW_OUT_ROSTER_UNKNOWN:     return "roster-unknown";
        case AOWL_SPW_OUT_BAD_REPLY:          return "bad-reply";
        case AOWL_SPW_OUT_UNAVAILABLE:        return "unavailable";
        case AOWL_SPW_OUT_LOCAL_REFUSED:      return "local-refused";
        default:                              return "never-answered";
    }
}

typedef struct AowlSpawnShared {
    uint64_t      magic;
    uint32_t      version;
    uint32_t      pad0;

    volatile LONG reqSeq;      /* requester bumps this LAST                  */
    volatile LONG ackSeq;      /* dispatcher stores this LAST                */
    volatile LONG kind;        /* AOWL_SPW_KIND_*                            */
    volatile LONG count;       /* how many to spawn (KIND_ITEM)              */
    volatile LONG presetIdx;   /* which kit (KIND_PRESET)                    */
    volatile LONG condition;   /* percent, 100 = pristine                    */
    char          query[AOWL_SPW_QUERY_LEN];

    volatile LONG outcome;     /* AOWL_SPW_OUT_*                             */
    volatile LONG matched;     /* how many the search really matched         */
    volatile LONG shown;       /* how many of lines[] carry text             */
    volatile LONG spawned;     /* items actually put in the stash            */
    char          message[AOWL_SPW_MSG_LEN];
    char          lines[AOWL_SPW_LINES][AOWL_SPW_LINE_LEN];

    /* Liveness, so "nothing happened" can be told apart from "nobody is
     * listening". The dispatcher bumps `polls` every time it looks, whether or
     * not there was a request. Zero polls with a pending request is the
     * INCONCLUSIVE case and the reason this counter exists. */
    volatile LONG polls;
    volatile LONG served;
} AowlSpawnShared;

static AowlSpawnShared* aowl_spawn_map(void) {
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                  (DWORD)sizeof(AowlSpawnShared),
                                  AOWL_SPW_REGION_NAME);
    if (!h) return NULL;
    int existed = (GetLastError() == ERROR_ALREADY_EXISTS);
    AowlSpawnShared* s = (AowlSpawnShared*)MapViewOfFile(
        h, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(AowlSpawnShared));
    if (!s) return NULL;
    if (!existed) { s->magic = AOWL_SPW_MAGIC; s->version = AOWL_SPW_VERSION; }
    return s;
}

static void aowl_spw_copy(char* dst, int32_t cap, const char* src) {
    int32_t i = 0;
    if (!dst || cap <= 0) return;
    if (src) for (; i < cap - 1 && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
}

static int32_t aowl_spw_valid(AowlSpawnShared* s) {
    return (s && s->magic == AOWL_SPW_MAGIC && s->version == AOWL_SPW_VERSION)
           ? 1 : 0;
}
/* BUSY: a request is outstanding. The requester must refuse rather than
 * overwrite -- overwriting would answer request N with request N+1's result. */
static int32_t aowl_spw_busy(AowlSpawnShared* s) {
    if (!aowl_spw_valid(s)) return 0;
    return (s->reqSeq != s->ackSeq) ? 1 : 0;
}

/* ---- requester side ---- */
static int32_t aowl_spw_post(AowlSpawnShared* s, int32_t kind,
                             const char* query, int32_t count,
                             int32_t presetIdx, int32_t condition) {
    if (!aowl_spw_valid(s)) return 0;
    if (aowl_spw_busy(s)) return 0;
    aowl_spw_copy(s->query, AOWL_SPW_QUERY_LEN, query);
    InterlockedExchange(&s->kind, kind);
    InterlockedExchange(&s->count, count);
    InterlockedExchange(&s->presetIdx, presetIdx);
    InterlockedExchange(&s->condition, condition);
    InterlockedExchange(&s->outcome, AOWL_SPW_OUT_NONE);
    InterlockedExchange(&s->matched, 0);
    InterlockedExchange(&s->shown, 0);
    InterlockedExchange(&s->spawned, 0);
    s->message[0] = 0;
    MemoryBarrier();
    InterlockedIncrement(&s->reqSeq);   /* LAST */
    return 1;
}

/* ---- dispatcher side ---- */
/* Poll. The query is NOT copied out here -- the Nim side reads it back
 * character by character with the two accessors below, the same way it reads
 * every other string in this project, because nimony has no `$` for a
 * `cstring` and passing a `char*` out buffer across that boundary is a wider
 * contract than this needs. */
static int32_t aowl_spw_take(AowlSpawnShared* s, int32_t* kind, int32_t* count,
                             int32_t* presetIdx, int32_t* condition) {
    if (!aowl_spw_valid(s)) return 0;
    InterlockedIncrement(&s->polls);
    if (s->reqSeq == s->ackSeq) return 0;
    MemoryBarrier();
    if (kind) *kind = (int32_t)s->kind;
    if (count) *count = (int32_t)s->count;
    if (presetIdx) *presetIdx = (int32_t)s->presetIdx;
    if (condition) *condition = (int32_t)s->condition;
    return 1;
}
static int32_t aowl_spw_query_len(AowlSpawnShared* s) {
    int32_t n = 0;
    if (!aowl_spw_valid(s)) return 0;
    while (n < AOWL_SPW_QUERY_LEN - 1 && s->query[n]) n++;
    return n;
}
static int32_t aowl_spw_query_ch(AowlSpawnShared* s, int32_t i) {
    if (!aowl_spw_valid(s) || i < 0 || i >= AOWL_SPW_QUERY_LEN) return 0;
    return (int32_t)(unsigned char)s->query[i];
}
static void aowl_spw_line(AowlSpawnShared* s, int32_t i, const char* text) {
    if (!aowl_spw_valid(s) || i < 0 || i >= AOWL_SPW_LINES) return;
    aowl_spw_copy(s->lines[i], AOWL_SPW_LINE_LEN, text);
}
static void aowl_spw_answer(AowlSpawnShared* s, int32_t outcome,
                            const char* message, int32_t matched,
                            int32_t shown, int32_t spawned) {
    if (!aowl_spw_valid(s)) return;
    aowl_spw_copy(s->message, AOWL_SPW_MSG_LEN, message);
    InterlockedExchange(&s->matched, matched);
    InterlockedExchange(&s->shown, shown);
    InterlockedExchange(&s->spawned, spawned);
    InterlockedExchange(&s->outcome, outcome);
    InterlockedIncrement(&s->served);
    MemoryBarrier();
    InterlockedExchange(&s->ackSeq, s->reqSeq);   /* LAST */
}

/* ---- reader side (the HUD, and the requester when it wants the answer) ---- */
static int32_t aowl_spw_outcome(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? (int32_t)s->outcome : AOWL_SPW_OUT_NONE;
}
static int32_t aowl_spw_polls(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? (int32_t)s->polls : 0;
}
static int32_t aowl_spw_served(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? (int32_t)s->served : 0;
}
static int32_t aowl_spw_matched(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? (int32_t)s->matched : 0;
}
static int32_t aowl_spw_spawned(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? (int32_t)s->spawned : 0;
}
static int32_t aowl_spw_shown(AowlSpawnShared* s) {
    if (!aowl_spw_valid(s)) return 0;
    { int32_t n = (int32_t)s->shown;
      if (n < 0) n = 0;
      if (n > AOWL_SPW_LINES) n = AOWL_SPW_LINES;
      return n; }
}
static const char* aowl_spw_message(AowlSpawnShared* s) {
    return aowl_spw_valid(s) ? s->message : "";
}
static const char* aowl_spw_line_at(AowlSpawnShared* s, int32_t i) {
    if (!aowl_spw_valid(s) || i < 0 || i >= AOWL_SPW_LINES) return "";
    return s->lines[i];
}
/* Character-at-a-time readers. nimony has no `$` for a `cstring`, so the Nim
 * side reads these back one byte at a time exactly as it already does for
 * il2cpp strings -- see `readString` in mods/admin/adm/shared.nim. Bounded by
 * construction: the buffers are fixed and NUL-terminated by aowl_spw_copy. */
static int32_t aowl_spw_msg_len(AowlSpawnShared* s) {
    int32_t n = 0;
    if (!aowl_spw_valid(s)) return 0;
    while (n < AOWL_SPW_MSG_LEN - 1 && s->message[n]) n++;
    return n;
}
static int32_t aowl_spw_msg_ch(AowlSpawnShared* s, int32_t i) {
    if (!aowl_spw_valid(s) || i < 0 || i >= AOWL_SPW_MSG_LEN) return 0;
    return (int32_t)(unsigned char)s->message[i];
}
static int32_t aowl_spw_line_len(AowlSpawnShared* s, int32_t li) {
    int32_t n = 0;
    if (!aowl_spw_valid(s) || li < 0 || li >= AOWL_SPW_LINES) return 0;
    while (n < AOWL_SPW_LINE_LEN - 1 && s->lines[li][n]) n++;
    return n;
}
static int32_t aowl_spw_line_ch(AowlSpawnShared* s, int32_t li, int32_t i) {
    if (!aowl_spw_valid(s) || li < 0 || li >= AOWL_SPW_LINES) return 0;
    if (i < 0 || i >= AOWL_SPW_LINE_LEN) return 0;
    return (int32_t)(unsigned char)s->lines[li][i];
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
static void aowl_admin_wi(void* o, int32_t off, int32_t v) {
    char* a = (char*)o + off;
    if (aowl_admin_readable(a, 4)) memcpy(a, &v, 4);
}
static void aowl_admin_wb(void* o, int32_t off, int32_t v) {
    unsigned char b = v ? 1u : 0u;
    char* a = (char*)o + off;
    if (aowl_admin_readable(a, 1)) memcpy(a, &b, 1);
}
static double aowl_admin_rd(const void* o, int32_t off) {
    double v = 0.0;
    const char* a = (const char*)o + off;
    if (!aowl_admin_readable(a, 8)) return 0.0;
    memcpy(&v, a, 8);
    return v;
}
static void aowl_admin_wd(void* o, int32_t off, double v) {
    char* a = (char*)o + off;
    if (aowl_admin_readable(a, 8)) memcpy(a, &v, 8);
}

/* ------------------------------------------------------------------ *
 * A System.String field -> ASCII, every hop VirtualQuery-checked.
 *
 * The il2cpp string layout is an ABI constant, not a guessed offset, and
 * `tools/fldoff.py`'s own mandatory self-check asserts it before it will print
 * anything: `System.String._stringLength@0x10`, `_firstChar@0x14` (UTF-16).
 *
 * Returns the number of bytes written (0 on any refusal). It REFUSES rather
 * than truncating garbage: a length outside 1..1024 means the pointer is not a
 * string -- a wrong offset, or a heterogeneous list -- and the caller is told
 * nothing was read instead of being handed a plausible-looking name.
 * Non-ASCII code units become '?', so a Cyrillic nickname is still a marker
 * rather than a crash in the 8x16 bitmap font.
 * ------------------------------------------------------------------ */
#define AOWL_ADM_STR_LEN_OFF   0x10
#define AOWL_ADM_STR_CHAR_OFF  0x14

static int32_t aowl_admin_rstr(const void* o, int32_t off, char* out, int32_t cap) {
    const void* sp;
    int32_t n, i, w;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    sp = aowl_admin_rp(o, off);
    if (!sp) return 0;
    if (!aowl_admin_readable(sp, AOWL_ADM_STR_CHAR_OFF)) return 0;
    n = aowl_admin_ri(sp, AOWL_ADM_STR_LEN_OFF);
    if (n < 1 || n > 1024) return 0;          /* not a string: refuse          */
    if (!aowl_admin_readable((const char*)sp + AOWL_ADM_STR_CHAR_OFF, n * 2))
        return 0;
    w = 0;
    for (i = 0; i < n && w < cap - 1; i++) {
        unsigned short c = 0;
        memcpy(&c, (const char*)sp + AOWL_ADM_STR_CHAR_OFF + i * 2, 2);
        if (c == 0) break;
        out[w++] = (c >= 0x20 && c < 0x7f) ? (char)c : '?';
    }
    out[w] = 0;
    return w;
}

/* The same read, decomposed, for a caller with no C string buffer to lend.
 * `..._len` returns the ASCII length that WOULD be produced (0 = refused);
 * `..._at` returns code point i, or 0 past the end. The producer calls the
 * first once and the second `len` times, so the bound is the caller's, not a
 * fixed buffer's. */
static int32_t aowl_admin_str_len(const void* o, int32_t off) {
    const void* sp = aowl_admin_rp(o, off);
    int32_t n;
    if (!sp) return 0;
    if (!aowl_admin_readable(sp, AOWL_ADM_STR_CHAR_OFF)) return 0;
    n = aowl_admin_ri(sp, AOWL_ADM_STR_LEN_OFF);
    if (n < 1 || n > 1024) return 0;
    if (!aowl_admin_readable((const char*)sp + AOWL_ADM_STR_CHAR_OFF, n * 2))
        return 0;
    return n;
}
static int32_t aowl_admin_str_at(const void* o, int32_t off, int32_t i) {
    const void* sp = aowl_admin_rp(o, off);
    unsigned short c = 0;
    if (!sp || i < 0) return 0;
    if (!aowl_admin_readable((const char*)sp + AOWL_ADM_STR_CHAR_OFF + i * 2, 2))
        return 0;
    memcpy(&c, (const char*)sp + AOWL_ADM_STR_CHAR_OFF + i * 2, 2);
    if (c < 0x20 || c >= 0x7f) return (int32_t)'?';
    return (int32_t)c;
}

/* ------------------------------------------------------------------ *
 * THE FAULT GUARD.
 *
 * Host rule 3 -- "whole body under ONE aowl_p_p_seh; it is NOT re-entrant" --
 * was not satisfied anywhere in this file before: prologue byte-verify and
 * VirtualQuery were the only guards, which stop a WRONG address but not a race
 * (an object freed between the VirtualQuery and the read, a page decommitted by
 * the GC mid-walk).
 *
 * This is deliberately NOT `aowl_p_p_seh` from `abi/aowlspt_shim.h`:
 *
 *   * that symbol is not visible in this translation unit -- the mod includes
 *     only this header -- and declaring it would break the mod DLL's link;
 *   * `aowlspt_overlay.h` includes THIS header inside the host, where
 *     `aowl_p_p_seh` DOES exist, so re-using the name would be a redefinition.
 *
 * It has its own thread-local `jmp_buf` and its own flag, so it cannot disarm
 * the host's guard the way a genuine nested `aowl_p_p_seh` would: the two never
 * share state. It is still used at TOP-LEVEL ENTRY POINTS ONLY -- one per body,
 * never nested inside another -- because that is the rule the rule is for.
 * ------------------------------------------------------------------ */

static __declspec(thread) jmp_buf aowl_adm_seh_jmp;
static __declspec(thread) int     aowl_adm_seh_active = 0;

static LONG CALLBACK aowl_adm_seh_veh(PEXCEPTION_POINTERS ep) {
    if (aowl_adm_seh_active &&
        ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        aowl_adm_seh_active = 0;
        longjmp(aowl_adm_seh_jmp, 1);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

/* Call `f(a)` with access violations trapped. Returns f's result, or NULL if it
 * faulted -- so a caller distinguishes "it ran" from "it died" and can count
 * the fault towards its self-disable budget. Refuses to RE-ENTER: if this
 * thread is already inside one of these guards the inner call runs UNGUARDED
 * rather than clobbering the outer jmp_buf, which is the exact failure mode
 * host rule 3 exists to prevent. */
static void* aowl_adm_seh(void* f, void* a) {
    static volatile LONG installed = 0;
    void* r = 0;
    if (!f) return 0;
    if (InterlockedCompareExchange(&installed, 1, 0) == 0)
        AddVectoredExceptionHandler(1, aowl_adm_seh_veh);
    if (aowl_adm_seh_active)          /* already guarded: do NOT nest */
        return ((void*(*)(void*))f)(a);
    aowl_adm_seh_active = 1;
    if (setjmp(aowl_adm_seh_jmp) == 0)
        r = ((void*(*)(void*))f)(a);
    else
        r = 0;
    aowl_adm_seh_active = 0;
    return r;
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

static const unsigned char AOWL_ADM_SIG_CAM_MAIN[16] = {
    0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0xD5,0x27,0xE7,0x01,0x48,0x85,0xC0,0x75,0x18 };
static const unsigned char AOWL_ADM_SIG_CAM_W2C[16] = {
    0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x2F,0x3A,0xE7 };
static const unsigned char AOWL_ADM_SIG_CAM_PROJ[16] = {
    0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x5F,0x39,0xE7 };

typedef void* (*AowlAdmCamMainFn)(void* methodInfo);
typedef void  (*AowlAdmCamMatFn)(void* retbuf, void* self, void* methodInfo);

static AowlAdmCamMainFn aowl_adm_cam_main_fn = 0;
static AowlAdmCamMatFn  aowl_adm_cam_w2c_fn  = 0;
static AowlAdmCamMatFn  aowl_adm_cam_proj_fn = 0;

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
    if (!aowl_adm_cam_main_fn || !aowl_adm_cam_w2c_fn || !aowl_adm_cam_proj_fn) {
        aowl_adm_cam_bind = 2;                   /* prologue mismatch: refuse */
        aowl_adm_cam_main_fn = 0;
        aowl_adm_cam_w2c_fn  = 0;
        aowl_adm_cam_proj_fn = 0;
        return;
    }
    aowl_adm_cam_bind = 3;
}

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

    cam = aowl_adm_cam_main_fn(0);       /* static: a NULL MethodInfo* is fine */
    if (!cam || !aowl_admin_readable(cam, 16)) {
        /* No main camera. Normal in the menu, and NOT a bind failure -- so it
         * does not burn the fault budget, it only ages the snapshot. */
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

#ifdef __cplusplus
}
#endif

#endif /* AOWLSPT_ADMIN_H */
