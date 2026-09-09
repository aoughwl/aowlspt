## ar/native.nim -- THE MOD'S ONE NATIVE TRANSLATION UNIT.
##
## Everything in this mod that has to be C lives here, and nothing that does
## not. There are exactly three reasons a line of C exists in this mod:
##
##   1. **Guarded pointer reads.** Rule 2 of the host discipline is
##      `VirtualQuery` on EVERY hop. A managed field read is a dereference of a
##      pointer the game owns and may have freed, so every one goes through
##      `aowl_ar_readable` first. Nimony cannot express that check.
##   2. **`UnityEngine.Input::GetKeyDown`, called at a byte-verified RVA.** The
##      pattern, the RVA, the prologue, the one-byte return type and the
##      indiscriminate-read control are all `mods/maps/sp/hud.nim`'s, re-derived
##      here rather than borrowed, because a second copy of a measurement that
##      can be re-checked is safer than a dependency on another mod's private
##      header (which is what `abi/aowlspt_admin.h` would be).
##   3. **The region draw callback.** `abi/aowlspt_region.h` enters the callback
##      inside the host's own `aowl_p_p_seh`, and that guard is NOT re-entrant.
##      A Nim callback would drag the runtime -- and on any allocating path a
##      lock -- into a frame that must do neither. So the callback is C over a
##      fixed POD mirror: it holds no game pointer, so it cannot fault on one,
##      and it allocates nothing, so it cannot allocate inside the guard.
##
## WHAT IS DELIBERATELY *NOT* HERE
## -------------------------------
## Calls into game code. Those go through `aowlspt/callrva` (`ar/calls.nim`),
## which is the supported mod-facing path: it byte-verifies the declared
## prologue against a capture-once snapshot, refuses a target whose first bytes
## are a JUMP (somebody else's trampoline -- a hook-ORDER problem, named as
## such), and wraps each call in its own vectored guard. A second copy of that
## machinery here would be a second answer to a question the SDK answers.
##
## THE GUARD SHAPE, STATED PLAINLY BECAUSE IT DIFFERS FROM THE HOST'S
## -----------------------------------------------------------------
## The host's `autoraid.nim` puts ONE `aowl_p_p_seh` around its whole tick body.
## This mod cannot: `aowl_crva_invoke` REFUSES TO ARM inside another guard
## (`AOWL_CRVA_GUARD_BUSY`, and it checks the shim's flag as well as its own),
## precisely because nesting disarms the outer one. So the shape here is
##
##   * every CALL into the game is individually guarded, by callrva;
##   * every READ of game memory is `VirtualQuery`-gated, here;
##   * the tick body itself opens NO guard, so nothing is ever nested.
##
## That satisfies the intent of rule 3 -- never nest -- by a different
## construction, and it is written down rather than left to be discovered.

{.emit: """
#include <windows.h>
#include <stdint.h>
#include <string.h>

#include "aowlspt_region.h"
#include "aowlspt_keycode.h"

/* ==================================================================== *
 * 1. THE GUARDED READ
 *
 * `aowl_ar_readable` answers "is [p, p+n) inside ONE committed, readable,
 * non-guard region", which is the only question a dereference needs answered
 * and the only one a single VirtualQuery can answer honestly. Straddling two
 * regions returns 0 rather than being papered over with a second query: a
 * managed object never straddles, so a straddle means the pointer is not what
 * we think it is.
 * ==================================================================== */
static int32_t aowl_ar_readable(const void* p, int32_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || n <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) != sizeof(mbi)) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    {
        const unsigned char* base = (const unsigned char*)mbi.BaseAddress;
        const unsigned char* q    = (const unsigned char*)p;
        SIZE_T avail = mbi.RegionSize - (SIZE_T)(q - base);
        if (avail < (SIZE_T)n) return 0;
    }
    return 1;
}

/* A pointer field. NULL both for "unreadable" and for "the field is null" --
 * no caller here needs to tell those apart, because both mean the same thing:
 * do not walk through it. */
static void* aowl_ar_readptr(const void* obj, int32_t off) {
    const unsigned char* p;
    if (!obj || off < 0) return 0;
    p = (const unsigned char*)obj + off;
    if (!aowl_ar_readable(p, 8)) return 0;
    return *(void* const*)p;
}

/* Four bytes AT a field, with the read reported separately from the value.
 * `ok` is not politeness: a caller that ignores it reads "the toggle is off"
 * out of a failure to look, which is the exact defect CLAUDE.md 9b names. */
static int32_t aowl_ar_readi32(const void* obj, int32_t off, void* ok) {
    const unsigned char* p;
    if (ok) *(int32_t*)ok = 0;
    if (!obj || off < 0) return 0;
    p = (const unsigned char*)obj + off;
    if (!aowl_ar_readable(p, 4)) return 0;
    if (ok) *(int32_t*)ok = 1;
    return *(const int32_t*)p;
}

/* UNITY'S OWN DESTROYED-OBJECT MARKER, and the reason `readable` is not
 * liveness. `UnityEngine.Object.m_CachedPtr` @0x10 is what every `== null` in
 * C# tests; a destroyed object stays perfectly READABLE with that field zeroed
 * (fact #182), so a walk that only checks readability hands back a corpse and
 * the next managed call faults inside Unity. This is the check that stops it,
 * and it is the game's own marker, not our invention. */
static int32_t aowl_ar_alive(const void* obj) {
    void* cached;
    if (!aowl_ar_readable(obj, 0x20)) return 0;
    cached = aowl_ar_readptr(obj, 0x10);
    return cached ? 1 : 0;
}

/* ==================================================================== *
 * 2. THE MANAGED STRING
 *
 * `System.String` on this build: `_stringLength` @0x10 (int32),
 * `_firstChar` @0x14 (the UTF-16 run, inline). That layout is the mandatory
 * self-check every offset tool in this repo must pass before any offset from
 * it is trusted (`tools/fldoff.py`, `tools/il2cpp_resolve.py fields`), so it is
 * the one layout here that is not merely measured but continuously re-asserted
 * somewhere else.
 *
 * Non-ASCII units become '?', deliberately: this text is compared against map
 * labels and control names, all ASCII, and a decoder here would be a second
 * UTF-8 encoder nobody tests. A '?' can never accidentally EQUAL a wanted
 * label, so the substitution cannot manufacture a match -- only fail to make
 * one, which is the safe direction.
 * ==================================================================== */
#define AOWL_AR_STR_MAX 128

static int32_t aowl_ar_readstr(const void* s, char* out, int32_t cap) {
    int32_t len = 0, i = 0, ok = 0;
    const unsigned short* c;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    if (!aowl_ar_readable(s, 0x18)) return 0;
    len = aowl_ar_readi32(s, 0x10, &ok);
    if (!ok || len <= 0) return 0;
    if (len > AOWL_AR_STR_MAX) len = AOWL_AR_STR_MAX;
    if (len > cap - 1) len = cap - 1;
    c = (const unsigned short*)((const unsigned char*)s + 0x14);
    if (!aowl_ar_readable(c, len * 2)) return 0;
    for (i = 0; i < len; i++)
        out[i] = (c[i] >= 32u && c[i] < 127u) ? (char)c[i] : '?';
    out[i] = 0;
    return i;
}

/* ==================================================================== *
 * 3. THE HOTKEY
 *
 * `UnityEngine.Input::GetKeyDown(KeyCode) -> bool`, STATIC, arity 1,
 * RVA 0x531EB80, section `il2cpp`, prologue
 *   40 53 48 83 EC 20 48 8B 05 9B 71 DB 01 8B D9 48
 * -- build 1.1.0.1.46777. MEASURED, and measured TWICE independently: once for
 * `abi/aowlspt_admin.h` on 2026-08-31 and again for `mods/maps/sp/hud.nim` on
 * 2026-09-01, with
 *   python tools/il2cpp_resolve.py <GameAssembly.dll> <metadata> bytes 0x531eb80
 * The agreement between those two runs is the self-check, and it is why these
 * bytes are trusted rather than guessed.
 *
 * It is CALLED, never detoured. The RVA is SHARED with `GetKeyDownInt(KeyCode)`
 * -- the same body under its internal name. Sharedness is an unbounded blast
 * radius for a DETOUR and is harmless for a CALL made with the argument the
 * body is correct for, which is what this is.
 *
 * THE RETURN TYPE IS ONE BYTE, NOT FOUR, and that is the single most expensive
 * mistake available here. The managed method TAIL-JUMPS into Unity's native
 * icall, whose C++ return type is `bool` -- AL only, EAX bits 8..31 UNDEFINED
 * by the Win64 ABI. Declaring the pointer as returning `int32_t` made maps'
 * overlay open on ANY keypress (41 toggles in a raid where M was pressed a
 * handful of times). `unsigned char` makes the compiler read AL and nothing
 * else; the `& 1u` at the call site is the second belt.
 *
 * WHY NOT `GetAsyncKeyState` OR A WNDPROC: async key state fires while the game
 * is in the BACKGROUND and while the player is typing somewhere else, and a
 * wndproc speaks Win32 virtual-keys rather than KeyCodes, so a user-assignable
 * bind would need a hand-typed 328-entry mapping. `Input::GetKeyDown` is the
 * input the game itself reads, is already false when the window is unfocused,
 * and is edge-triggered by construction.
 * ==================================================================== */
#define AOWL_AR_RVA_GETKEYDOWN 0x531EB80u
static const unsigned char AOWL_AR_SIG_GETKEYDOWN[16] = {
    0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x9B,0x71,0xDB,0x01,0x8B,0xD9,0x48 };
#define AOWL_AR_HK_MAXFAIL 240

typedef unsigned char (*AowlArKeyFn)(int32_t keyCode, void* methodInfo);
static AowlArKeyFn g_ar_keyFn   = 0;
/* 0 not attempted | 1 GameAssembly.dll not mapped yet (TRANSIENT, must not
 * latch) | 2 PROLOGUE MISMATCH -- refused, nothing is ever called | 3 bound. */
static int32_t     g_ar_keyBind = 0;
static int32_t     g_ar_keyFail = 0;
static int64_t     g_ar_keyDowns   = 0;  /* ticks a bound key read DOWN       */
static int64_t     g_ar_keyRefused = 0;  /* ...on which the CONTROL also did  */

static int32_t aowl_ar_key_state(void) {
    HMODULE ga;
    unsigned char* p;
    if (g_ar_keyBind == 1) g_ar_keyBind = 0;      /* transient, retry */
    if (g_ar_keyBind != 0) return g_ar_keyBind;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { g_ar_keyBind = 1; return 1; }
    p = (unsigned char*)ga + AOWL_AR_RVA_GETKEYDOWN;
    if (!aowl_ar_readable(p, 16) ||
        memcmp(p, AOWL_AR_SIG_GETKEYDOWN, 16) != 0) {
        g_ar_keyFn = 0;
        g_ar_keyBind = 2;                          /* refuse; call nothing */
        return 2;
    }
    g_ar_keyFn = (AowlArKeyFn)(void*)p;
    g_ar_keyBind = 3;
    return 3;
}

/* THE INDISCRIMINATE-READ CONTROL. `Joystick8Button19` (ordinal 509) is the
 * last member of UnityEngine.KeyCode's eighth virtual gamepad -- a key the
 * player provably is not holding. On every tick where the WANTED key reads
 * down, this one is asked too; if it also reads down, the read is not honouring
 * its argument, and the honest response is to REFUSE the keypress and count the
 * refusal rather than open a menu over the player's game.
 *
 * A count of the thing you want cannot falsify itself: `toggles=41` could not
 * distinguish "the player pressed M 41 times" from "any key toggles". This can.
 * Cost is zero on a normal tick -- the control is asked only on ticks where the
 * wanted key already said yes. */
#define AOWL_AR_KC_CONTROL 509

static int32_t aowl_ar_key_raw(int32_t kc) {
    return (int32_t)(g_ar_keyFn(kc, 0) & 1u);   /* AL only -- see the typedef */
}

/* 1 when `kc` went down THIS tick AND the control agrees the read is honouring
 * its argument. `kc == AOWL_KC_UNBOUND` calls NOTHING -- not GetModuleHandle,
 * not the game method -- so an unbound key costs one compare per tick. */
static int32_t aowl_ar_key_down(int32_t kc) {
    if (kc == AOWL_KC_UNBOUND) return 0;
    if (g_ar_keyFail >= AOWL_AR_HK_MAXFAIL) return 0;   /* self-disabled */
    if (aowl_ar_key_state() != 3) { g_ar_keyFail++; return 0; }
    g_ar_keyFail = 0;
    if (!aowl_ar_key_raw(kc)) return 0;
    g_ar_keyDowns++;
    if (kc != AOWL_AR_KC_CONTROL && aowl_ar_key_raw(AOWL_AR_KC_CONTROL)) {
        g_ar_keyRefused++;
        return 0;
    }
    return 1;
}

static int32_t aowl_ar_key_bind_state(void) { return g_ar_keyBind; }
static int32_t aowl_ar_key_disabled(void) {
    return g_ar_keyFail >= AOWL_AR_HK_MAXFAIL ? 1 : 0;
}
static int64_t aowl_ar_key_downs(void)   { return g_ar_keyDowns; }
static int64_t aowl_ar_key_refused(void) { return g_ar_keyRefused; }

/* ==================================================================== *
 * 4. THE MENU SURFACE
 *
 * A fixed POD mirror plus a DRAW callback over it. The callback holds no
 * pointer into the game and calls nothing but the region's own submit
 * functions, so it can neither fault nor allocate inside the region's guard.
 *
 * ONE WRITER, ONE READER, SAME THREAD: the Nim side fills this from `everyMain`
 * (Unity's thread, once per host drain) and the region dispatches the draw on
 * that same thread. No lock is needed and no torn read is possible.
 * ==================================================================== */
#define AOWL_AR_MENU_ROWS   16
#define AOWL_AR_MENU_TEXT   40
#define AOWL_AR_BANNER_TEXT 120

typedef struct {
    int32_t handle;                 /* region handle, or -1                   */
    int32_t open;                   /* the menu is showing                    */
    int32_t rows;                   /* how many map rows are filled           */
    int32_t sel;                    /* the highlighted row                    */
    char    title[AOWL_AR_MENU_TEXT];
    char    row[AOWL_AR_MENU_ROWS][AOWL_AR_MENU_TEXT];
    char    banner[AOWL_AR_BANNER_TEXT];   /* the last answer, shown for 5 s  */
    char    status[AOWL_AR_BANNER_TEXT];   /* the machine's current stage     */
    int64_t frames;                 /* draw callbacks that RETURNED           */
    int64_t drawn;                  /* ...of which actually painted a menu    */
    int32_t prims;                  /* primitives submitted on the last draw  */
} AowlArMenu;

static AowlArMenu g_ar_menu;

/* Colours are 0xAABBGGRR, matching the overlay's vertex colour. */
#define AOWL_AR_COL_BACK  0xE0101010u
#define AOWL_AR_COL_EDGE  0xFF9A6E3Au
#define AOWL_AR_COL_TEXT  0xFFE8E8E8u
#define AOWL_AR_COL_SEL   0xFF9A6E3Au
#define AOWL_AR_COL_SELTX 0xFFFFFFFFu
#define AOWL_AR_COL_NOTE  0xFFFFC89Au

static void aowl_ar_draw(void* user, int64_t frame) {
    float x, y, w, h, rowH;
    int32_t i;
    (void)user; (void)frame;
    g_ar_menu.frames++;
    g_ar_menu.prims = 0;
    if (!g_ar_menu.open || g_ar_menu.rows <= 0) return;

    /* THE BACK-BUFFER SIZE HAS THREE ANSWERS, and 0 is not a width. When the
     * host has published no size (`screen_known() == 0`) the menu is drawn at a
     * fixed top-left offset rather than snapped to a centre computed from a
     * zero canvas -- which would drag it to the origin and read as a bug in the
     * menu rather than in the measurement. */
    rowH = 22.0f;
    w    = 320.0f;
    h    = rowH * (float)(g_ar_menu.rows + 3) + 16.0f;
    if (aowl_region_screen_known()) {
        x = ((float)aowl_region_screen_w() - w) * 0.5f;
        y = ((float)aowl_region_screen_h() - h) * 0.5f;
        if (x < 0.0f) x = 0.0f;
        if (y < 0.0f) y = 0.0f;
    } else {
        x = 64.0f;
        y = 64.0f;
    }

    aowl_region_fill(x, y, w, h, AOWL_AR_COL_BACK);          g_ar_menu.prims++;
    aowl_region_box(x, y, w, h, 2.0f, AOWL_AR_COL_EDGE);     g_ar_menu.prims++;
    aowl_region_text(x + 10.0f, y + 8.0f, g_ar_menu.title, AOWL_AR_COL_NOTE);
    g_ar_menu.prims++;

    for (i = 0; i < g_ar_menu.rows && i < AOWL_AR_MENU_ROWS; i++) {
        float ry = y + 8.0f + rowH * (float)(i + 1);
        if (i == g_ar_menu.sel) {
            aowl_region_fill(x + 6.0f, ry - 3.0f, w - 12.0f, rowH,
                             AOWL_AR_COL_SEL);
            g_ar_menu.prims++;
        }
        aowl_region_text(x + 12.0f, ry, g_ar_menu.row[i],
                         (i == g_ar_menu.sel) ? AOWL_AR_COL_SELTX
                                              : AOWL_AR_COL_TEXT);
        g_ar_menu.prims++;
    }
    aowl_region_text(x + 10.0f, y + 8.0f + rowH * (float)(g_ar_menu.rows + 1),
                     g_ar_menu.status, AOWL_AR_COL_NOTE);
    g_ar_menu.prims++;
    if (g_ar_menu.banner[0]) {
        aowl_region_text(x + 10.0f,
                         y + 8.0f + rowH * (float)(g_ar_menu.rows + 2),
                         g_ar_menu.banner, AOWL_AR_COL_NOTE);
        g_ar_menu.prims++;
    }
    g_ar_menu.drawn++;
}

static void aowl_ar_menu_init(void) {
    memset(&g_ar_menu, 0, sizeof(g_ar_menu));
    g_ar_menu.handle = -1;
    strncpy(g_ar_menu.title, "AutoRaid -- choose a map",
            AOWL_AR_MENU_TEXT - 1);
    strncpy(g_ar_menu.status, "idle", AOWL_AR_BANNER_TEXT - 1);
}

/* Registration returns the region's own code. NEVER print the number: the Nim
 * side passes it to `aowl_ar_menu_refusal` and logs the sentence. */
static int32_t aowl_ar_menu_register(int32_t order, int32_t budgetUs) {
    AowlRegionDesc d;
    int32_t r;
    if (g_ar_menu.handle >= 0) return AOWL_REGION_OK;
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    strncpy(d.name, "autoraid.menu", AOWL_REGION_NAME_LEN - 1);
    d.fn       = aowl_ar_draw;
    d.user     = 0;
    d.mask     = AOWL_REGION_DRAW;
    d.order    = order;
    d.budgetUs = budgetUs;
    r = aowl_region_register(&d);
    if (r >= 0) { g_ar_menu.handle = r; return AOWL_REGION_OK; }
    return r;
}

static int32_t aowl_ar_menu_unregister(void) {
    int32_t r;
    if (g_ar_menu.handle < 0) return AOWL_REGION_OK;
    r = aowl_region_unregister(g_ar_menu.handle);
    g_ar_menu.handle = -1;
    return r;
}

/* Copied into a caller-owned buffer rather than returned as a `const char*`:
 * nimony has no cstring -> string conversion, and inventing one here would be a
 * second answer to a question `mods/maps/sp/hud.nim` already answers this way. */
static int32_t aowl_ar_copy(const char* src, char* out, int32_t cap) {
    int32_t i = 0;
    if (!out || cap <= 0) return 0;
    if (!src) { out[0] = 0; return 0; }
    while (src[i] && i < cap - 1) { out[i] = src[i]; i++; }
    out[i] = 0;
    return i;
}
static int32_t aowl_ar_menu_refusal(int32_t code, char* out, int32_t cap) {
    return aowl_ar_copy(aowl_region_refusal_text(code), out, cap);
}

/* The mirror's setters. Every one bounds-checks and truncates; none can grow
 * the mirror, so the draw callback's iteration is bounded by a compile-time
 * constant no matter what the Nim side does. */
static void aowl_ar_menu_set_open(int32_t on) { g_ar_menu.open = on ? 1 : 0; }
static int32_t aowl_ar_menu_is_open(void)     { return g_ar_menu.open; }
static void aowl_ar_menu_set_rows(int32_t n) {
    if (n < 0) n = 0;
    if (n > AOWL_AR_MENU_ROWS) n = AOWL_AR_MENU_ROWS;
    g_ar_menu.rows = n;
    if (g_ar_menu.sel >= n) g_ar_menu.sel = (n > 0) ? n - 1 : 0;
}
static int32_t aowl_ar_menu_rows(void) { return g_ar_menu.rows; }
static int32_t aowl_ar_menu_cap(void)  { return AOWL_AR_MENU_ROWS; }
static void aowl_ar_menu_set_row(int32_t i, const char* s) {
    if (i < 0 || i >= AOWL_AR_MENU_ROWS) return;
    aowl_ar_copy(s, g_ar_menu.row[i], AOWL_AR_MENU_TEXT);
}
static void aowl_ar_menu_set_sel(int32_t i) {
    if (g_ar_menu.rows <= 0) { g_ar_menu.sel = 0; return; }
    if (i < 0) i = g_ar_menu.rows - 1;                 /* wrap, both ways */
    if (i >= g_ar_menu.rows) i = 0;
    g_ar_menu.sel = i;
}
static int32_t aowl_ar_menu_sel(void) { return g_ar_menu.sel; }
static void aowl_ar_menu_set_banner(const char* s) {
    aowl_ar_copy(s, g_ar_menu.banner, AOWL_AR_BANNER_TEXT);
}
static void aowl_ar_menu_set_status(const char* s) {
    aowl_ar_copy(s, g_ar_menu.status, AOWL_AR_BANNER_TEXT);
}

/* THE MIRROR, READ BACK. The verdict must be able to compare what the mod
 * BELIEVES against what the draw callback is ACTUALLY holding, because those
 * two disagreeing IS the bug this exists to catch. Reading our own struct back
 * is the only way that disagreement is observable; without it the verdict can
 * only re-report the value it just wrote, which is a check that cannot fail. */
static int32_t aowl_ar_menu_armed(void)  { return aowl_region_is_armed(); }
static int32_t aowl_ar_menu_handle(void) { return g_ar_menu.handle; }
static int64_t aowl_ar_menu_frames(void) { return g_ar_menu.frames; }
static int64_t aowl_ar_menu_drawn(void)  { return g_ar_menu.drawn; }
static int32_t aowl_ar_menu_prims(void)  { return g_ar_menu.prims; }
static int32_t aowl_ar_abi(void)         { return AOWL_REGION_ABI; }

/* ==================================================================== *
 * 5. A STATIC DATA ADDRESS
 *
 * `aowlspt/callrva` deliberately REFUSES an RVA outside the `il2cpp` section,
 * because generated CODE lives there and nowhere else. The `Il2CppType`
 * descriptors this mod needs are DATA, so they are outside it by construction
 * and that refusal is correct rather than something to work around inside
 * callrva. They are resolved here instead, and the resolution is weaker in an
 * honest way: there is no prologue to compare data against, so the only checks
 * available are the image bound and readability. What makes it safe is that the
 * address is never CALLED -- it is handed to `System.Type::GetTypeFromHandle`,
 * which is itself a byte-verified call, and its answer is re-checked for
 * readability before anything is done with it.
 * ==================================================================== */
static void* aowl_ar_data_at(uint32_t rva) {
    HMODULE h = GetModuleHandleA("GameAssembly.dll");
    unsigned char* p;
    if (!h || rva == 0u) return 0;
    p = (unsigned char*)h + rva;
    if (!aowl_ar_readable(p, 16)) return 0;
    return (void*)p;
}

/* The keycode table lives in abi/aowlspt_keycode.h and returns
 * AOWL_KC_UNKNOWN (-1) for a name it does not know -- NEVER 0, which is
 * KeyCode.None and would be a silent "poll a key that can never be down". */
static int32_t aowl_ar_keycode_of(const char* name) {
    return aowl_keycode_of(name);
}
static int32_t aowl_ar_kc_unbound(void) { return AOWL_KC_UNBOUND; }
/* ==================================================================== *
 * 5. THE PLAYER'S OWN ESC.
 *
 * MEASURED 2026-09-05 in a live Woods raid: a real ESC makes the game call
 * `MenuScreen::Show(5-arg)` (uihooks site 2, profile=NULL) on the
 * DontDestroyOnLoad MenuScreen, and nothing else we tried does --
 * `ShowInRaid()` only touches the EnvironmentUI, and `Show(controller)` needs
 * a controller the hidden menu no longer holds (+0x90 read NULL at exit).
 * So the exit half presses the key the player would press and then WAITS
 * for site 2 to fire: the readback is the game's own Show event, never the
 * fact that a key was injected.
 *
 * DELIVERY, MEASURED 2026-09-05 in the same raid, two ways:
 *   keybd_event (the OS input queue) reaches only the FOREGROUND window --
 *     it opened the menu when the game was foreground, and cycle 5 had to
 *     REFUSE when the user was in another window, because the ESC would
 *     have gone there.
 *   PostMessageW(WM_KEYDOWN / WM_KEYUP, VK_ESCAPE) straight to the
 *     `UnityWndClass` window opened the menu with the game NOT foreground
 *     (`uihooks: MenuScreen::Show #2 profile=NULL` 4 s after the post).
 * So this posts. Nothing else on the machine sees the key, and a human in
 * another window is not interrupted. The only refusal left is "no window".
 * -------------------------------------------------------------------- */
static int32_t aowl_ar_game_window(void) {
    return FindWindowW(L"UnityWndClass", NULL) ? 1 : 0;
}
static int32_t aowl_ar_key_escape(int32_t down) {
    HWND h = FindWindowW(L"UnityWndClass", NULL);
    LPARAM lp;
    if (!h) return 0;
    if (down) lp = (LPARAM)(1 | (0x01 << 16));
    else      lp = (LPARAM)(1 | (0x01 << 16) | (1 << 30)) | ((LPARAM)1 << 31);
    return PostMessageW(h, down ? WM_KEYDOWN : WM_KEYUP, (WPARAM)VK_ESCAPE, lp) ? 1 : 0;
}
/* THE FALLBACK. MEASURED 2026-09-05 14:02, DEPLOYED on Woods with the maps HUD
 * on: the posted WM_KEYDOWN/WM_KEYUP pair (which had opened the menu on four
 * exits and from outside the process) opened NOTHING -- site 2 never fired --
 * while a keybd_event ESC opened it at once, with the game NOT the foreground
 * window (Unity takes the key through raw input). Something on the game's UI
 * thread eats posted key messages in that state (the host installs
 * WH_GETMESSAGE/WH_CALLWNDPROC hooks for its overlays; which one is a host
 * question). keybd_event also reaches whatever IS foreground, so it is the
 * second try, announced, never the first. */
static void aowl_ar_key_escape_raw(int32_t down) {
    keybd_event(VK_ESCAPE, 0x01, down ? 0 : KEYEVENTF_KEYUP, 0);
}
""".}

import aowlspt/il2cpp

# ---------------------------------------------------------------------------
# The Nim face. Every one of these names a `static` C function in the {.emit.}
# block above, which is why they are `nodecl`: those names are invisible outside
# this translation unit, and that invisibility is exactly the property that
# makes this file the ONE place the mod's C lives.
# ---------------------------------------------------------------------------

proc cReadable(p: Il2CppPtr; n: int32): int32 {.
  importc: "aowl_ar_readable", nodecl.}
proc cReadPtr(obj: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_ar_readptr", nodecl.}
proc cReadI32(obj: Il2CppPtr; off: int32; ok: Il2CppPtr): int32 {.
  importc: "aowl_ar_readi32", nodecl.}
proc cAlive(obj: Il2CppPtr): int32 {.importc: "aowl_ar_alive", nodecl.}
proc cReadStr(s: Il2CppPtr; outp: Il2CppPtr; cap: int32): int32 {.
  importc: "aowl_ar_readstr", nodecl.}

proc cKeyDown(kc: int32): int32 {.importc: "aowl_ar_key_down", nodecl.}
proc cKeyBindState(): int32 {.importc: "aowl_ar_key_bind_state", nodecl.}
proc cKeyDisabled(): int32 {.importc: "aowl_ar_key_disabled", nodecl.}
proc cKeyDowns(): int64 {.importc: "aowl_ar_key_downs", nodecl.}
proc cKeyRefused(): int64 {.importc: "aowl_ar_key_refused", nodecl.}
proc cGameWindow(): int32 {.importc: "aowl_ar_game_window", nodecl.}
proc cKeyEscape(down: int32): int32 {.importc: "aowl_ar_key_escape", nodecl.}
proc cKeyEscapeRaw(down: int32) {.importc: "aowl_ar_key_escape_raw", nodecl.}

proc gameWindowExists*(): bool =
  cGameWindow() != 0'i32

proc keyEscapeRaw*(down: bool) =
  ## ONE half of an ESC keystroke through the OS input queue (`keybd_event`).
  ## Reaches the game through raw input whether or not it is foreground --
  ## and ALSO whatever is foreground, so the exit machine tries the posted
  ## message first and only falls back to this, saying so.
  cKeyEscapeRaw(if down: 1'i32 else: 0'i32)

proc keyEscape*(down: bool): bool =
  ## ONE half of an ESC keystroke, POSTED to the game window (see the C note:
  ## measured to open the in-raid menu whether or not the game is foreground).
  ## Down on one tick and up on the next, so the game sees a real press across
  ## a frame edge. False = there was no window to post to, or the post failed.
  cKeyEscape(if down: 1'i32 else: 0'i32) != 0'i32
proc cDataAt(rva: uint32): Il2CppPtr {.importc: "aowl_ar_data_at", nodecl.}
proc cKeycodeOf(name: Il2CppPtr): int32 {.importc: "aowl_ar_keycode_of", nodecl.}
proc cKcUnbound(): int32 {.importc: "aowl_ar_kc_unbound", nodecl.}

proc cMenuInit() {.importc: "aowl_ar_menu_init", nodecl.}
proc cMenuRegister(order, budgetUs: int32): int32 {.
  importc: "aowl_ar_menu_register", nodecl.}
proc cMenuUnregister(): int32 {.importc: "aowl_ar_menu_unregister", nodecl.}
proc cMenuRefusal(code: int32; outp: Il2CppPtr; cap: int32): int32 {.
  importc: "aowl_ar_menu_refusal", nodecl.}
proc cMenuSetOpen(on: int32) {.importc: "aowl_ar_menu_set_open", nodecl.}
proc cMenuIsOpen(): int32 {.importc: "aowl_ar_menu_is_open", nodecl.}
proc cMenuSetRows(n: int32) {.importc: "aowl_ar_menu_set_rows", nodecl.}
proc cMenuRows(): int32 {.importc: "aowl_ar_menu_rows", nodecl.}
proc cMenuCap(): int32 {.importc: "aowl_ar_menu_cap", nodecl.}
proc cMenuSetRow(i: int32; s: Il2CppPtr) {.importc: "aowl_ar_menu_set_row", nodecl.}
proc cMenuSetSel(i: int32) {.importc: "aowl_ar_menu_set_sel", nodecl.}
proc cMenuSel(): int32 {.importc: "aowl_ar_menu_sel", nodecl.}
proc cMenuSetBanner(s: Il2CppPtr) {.importc: "aowl_ar_menu_set_banner", nodecl.}
proc cMenuSetStatus(s: Il2CppPtr) {.importc: "aowl_ar_menu_set_status", nodecl.}
proc cMenuArmed(): int32 {.importc: "aowl_ar_menu_armed", nodecl.}
proc cMenuHandle(): int32 {.importc: "aowl_ar_menu_handle", nodecl.}
proc cMenuFrames(): int64 {.importc: "aowl_ar_menu_frames", nodecl.}
proc cMenuDrawn(): int64 {.importc: "aowl_ar_menu_drawn", nodecl.}
proc cMenuPrims(): int32 {.importc: "aowl_ar_menu_prims", nodecl.}
proc cRegionAbi(): int32 {.importc: "aowl_ar_abi", nodecl.}

# ---------------------------------------------------------------------------
# The public, Nim-shaped surface. Nothing outside this file touches a raw
# pointer offset or an `importc` name.
# ---------------------------------------------------------------------------

proc readable*(p: Il2CppPtr; n: int): bool =
  ## Is `[p, p+n)` committed, readable and inside ONE region? The gate every
  ## pointer hop in this mod goes through (rule 2).
  cReadable(p, int32(n)) != 0'i32

proc alive*(obj: Il2CppPtr): bool =
  ## Unity's own liveness: `m_CachedPtr` @0x10 is non-null. READABLE IS NOT
  ## ALIVE -- a destroyed object stays readable with that field zeroed (fact
  ## #182), and a managed call on the corpse faults inside Unity.
  cAlive(obj) != 0'i32

proc readPtr*(obj: Il2CppPtr; off: int): Il2CppPtr =
  ## A pointer field, guarded. nil for "unreadable" and for "null" alike --
  ## both mean the same thing to every caller here: do not walk through it.
  cReadPtr(obj, int32(off))

proc readI32*(obj: Il2CppPtr; off: int; ok: var bool): int =
  ## Four bytes at a field. `ok` reports whether the READ happened, separately
  ## from the value, so no caller can read "false" out of a failure to look.
  var k = 0'i32
  let v = cReadI32(obj, int32(off), cast[Il2CppPtr](addr k))
  ok = k != 0'i32
  result = int(v)

proc readBoolField*(obj: Il2CppPtr; off: int; ok: var bool): bool =
  ## A 1-byte managed `bool`. The four bytes AT the field are read and only the
  ## low one tested: the three bytes after a bool are padding, and a second
  ## one-byte read primitive would be a second code path for no gain.
  let v = readI32(obj, off, ok)
  result = ok and ((v and 0xFF) != 0)

proc readString*(s: Il2CppPtr): string =
  ## A `System.String` as ASCII. "" is NOT READABLE **or** genuinely empty, and
  ## no caller here may treat "" as a match -- an empty string compares equal to
  ## nothing useful, which is how a check that cannot fail gets written.
  result = ""
  if s == nil: return
  var buf = ""
  while buf.len < 160: buf.add ' '
  let n = cReadStr(s, cast[Il2CppPtr](toCString(buf)), int32(buf.len))
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc dataAt*(rva: uint32): Il2CppPtr =
  ## `GameAssembly.dll` base + `rva`, when that address is readable. nil says
  ## either the module is not mapped or the address is not readable HERE, and
  ## the caller must say which it could not tell apart rather than proceeding.
  cDataAt(rva)

proc keycodeOf*(name: string): int =
  ## Name -> `UnityEngine.KeyCode` ordinal, or `unboundKey()` for a name the
  ## table does not know. It is never 0: 0 is `KeyCode.None`, and a mistyped
  ## bind that resolved to None would poll every frame for a key that can never
  ## be down -- silent, and indistinguishable from a broken poll.
  var n = name
  result = int(cKeycodeOf(cast[Il2CppPtr](toCString(n))))

proc unboundKey*(): int =
  ## The sentinel that means "no hotkey". Polling it calls NOTHING.
  int(cKcUnbound())

proc keyDown*(kc: int): bool =
  ## Did `kc` go down this tick? UNITY'S THREAD ONLY -- this calls into the
  ## game, and `Input::GetKey*` off Unity's thread is a MEASURED access
  ## violation (`abi/aowlspt_mqpolicy.h`; Unity's own input manager pointer is
  ## null on any other thread and the body dereferences it with no null test).
  ## Every call site here is inside an `everyMain` tick that has already proved
  ## the host's drain is bound.
  ##
  ## Returns false -- never true -- when the indiscriminate-read control also
  ## reads down, when the prologue did not verify, and when the poll has
  ## self-disabled. A refusal can only ever fail to act; it can never act.
  cKeyDown(int32(kc)) != 0'i32

proc keyBindState*(): int =
  ## 0 not attempted | 1 GameAssembly.dll not mapped yet | 2 PROLOGUE MISMATCH,
  ## nothing will ever be called | 3 bound.
  int(cKeyBindState())

proc keyBindWhy*(): string =
  case keyBindState()
  of 0: "not attempted (no key is bound, so nothing was looked up)"
  of 1: "GameAssembly.dll is not mapped yet -- TRANSIENT, it retries"
  of 2: "PROLOGUE MISMATCH at Input::GetKeyDown 0x531EB80 -- REFUSED. The " &
        "hotkey is dead for this session and NOTHING was called. Either this " &
        "is a different game build, or something detoured that address first " &
        "(a hook-ORDER problem, not a bad RVA)."
  of 3: "bound and byte-verified against 40 53 48 83 EC 20 48 8B 05 9B 71 DB " &
        "01 8B D9 48"
  else: "unknown"

proc keySelfDisabled*(): bool = cKeyDisabled() != 0'i32
proc keyDownCount*(): int64 = cKeyDowns()
proc keyRefusedCount*(): int64 = cKeyRefused()

proc menuInit*() = cMenuInit()

proc menuRegister*(order, budgetUs: int; why: var string): bool =
  ## Register the DRAW participant. `why` carries the region's own refusal
  ## SENTENCE -- never the number, which means nothing to a reader.
  ##
  ## REGISTRATION AND ARMING ARE DIFFERENT FACTS and are reported separately by
  ## the caller: registration nearly always succeeds, and a registered
  ## participant on an UNARMED region simply never fires. Flattening the two
  ## into "the menu is on" would be a claim this mod cannot support.
  why = ""
  let r = cMenuRegister(int32(order), int32(budgetUs))
  if r >= 0'i32: return true
  var buf = ""
  while buf.len < 240: buf.add ' '
  let n = cMenuRefusal(r, cast[Il2CppPtr](toCString(buf)), int32(buf.len))
  var i = 0
  while i < int(n) and i < buf.len:
    why.add buf[i]
    inc i
  result = false

proc menuUnregister*() = discard cMenuUnregister()
proc menuArmed*(): bool = cMenuArmed() != 0'i32
proc menuHandle*(): int = int(cMenuHandle())
proc menuFrames*(): int64 = cMenuFrames()
proc menuDrawn*(): int64 = cMenuDrawn()
proc menuPrims*(): int = int(cMenuPrims())
proc regionAbi*(): int = int(cRegionAbi())

proc menuOpen*(): bool = cMenuIsOpen() != 0'i32
proc menuSetOpen*(on: bool) = cMenuSetOpen(if on: 1'i32 else: 0'i32)
proc menuRowCap*(): int = int(cMenuCap())
proc menuRowCount*(): int = int(cMenuRows())
proc menuSetRowCount*(n: int) = cMenuSetRows(int32(n))
proc menuSelected*(): int = int(cMenuSel())
proc menuSelect*(i: int) = cMenuSetSel(int32(i))

proc menuSetRow*(i: int; s: string) =
  var t = s
  cMenuSetRow(int32(i), cast[Il2CppPtr](toCString(t)))

proc menuSetBanner*(s: string) =
  var t = s
  cMenuSetBanner(cast[Il2CppPtr](toCString(t)))

proc menuSetStatus*(s: string) =
  var t = s
  cMenuSetStatus(cast[Il2CppPtr](toCString(t)))
