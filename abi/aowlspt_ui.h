/* aowlspt_ui.h -- the BACKEND-AGNOSTIC, RETAINED-MODE widget core.
 *
 * This header is the SHARED CORE the unified UI framework is built on. It is
 * deliberately POINTER-FREE of any game type and touches neither IL2CPP nor
 * D3D: it is pure arithmetic and pure state, so every line here is offline-
 * testable and none of it can fault the client. The two backends live ABOVE
 * it:
 *
 *   * OVERLAY (bkOverlay) -- our own D3D11 pixels via `aowl_region_*`
 *     (aowlspt_region.h). A retained widget tree is walked ONCE PER FRAME by
 *     `aowl_ui_overlay_emit`, which turns each widget into FILL/BOX/TEXT draw
 *     ops; the host's region DRAW callback replays those ops through
 *     `aowl_region_fill/box/text`. Immediate-mode rasteriser, retained-mode
 *     model.
 *
 *   * NATIVE (bkNative) -- real Tarkov GameObjects via nativeui.nim
 *     (fact #225). The Nim surface owns the il2cpp construction; this core
 *     only holds the widget record, its computed rect, and its state, and
 *     stores the opaque native handles the Nim side fills in.
 *
 * THE UNIFICATION. `uiPanel/uiLabel/uiToggle/uiButton/uiTabStrip/uiRow` build
 * the SAME widget records regardless of backend; the `backend` field on each
 * record decides how it is realised. Layout, the tab-selection state machine,
 * hit-testing and config binding are computed here, ONCE, above the split --
 * which is most of the value and all of the offline-testable surface.
 *
 * SAFETY. Fixed-size tables, capped iteration, no allocation, every index
 * bounds-checked, every builder returns a handle or a NAMED refusal code
 * (never a silent -1). Three outcomes: a widget is BUILT, REFUSED (with a
 * reason), or INCONCLUSIVE (its backend could not prove it -- e.g. native
 * Image). A check that cannot fail is the bug (CLAUDE.md 9b), so the hit-test
 * and layout predicates are written to be falsifiable and the test suite feeds
 * them wrong values on purpose.
 */
#ifndef AOWLSPT_UI_H
#define AOWLSPT_UI_H

#include <stdint.h>
#include <string.h>
#include <math.h>

/* ------------------------------------------------------------------ *
 * Limits -- all capped, none grows.
 * ------------------------------------------------------------------ */
enum {
    AOWL_UI_MAX      = 128,   /* widgets in the retained tree            */
    AOWL_UI_TEXT     = 96,    /* per-widget caption bytes                */
    AOWL_UI_KEY      = 80,    /* modGuid|key binding identity bytes      */
    AOWL_UI_TABS     = 12,    /* tabs per strip                          */
    AOWL_UI_BINDS    = 128,   /* config bindings                         */
    AOWL_UI_DRAWOPS  = 1024   /* overlay draw ops emitted per frame      */
};

/* Backends. NONE is the unset default so a widget built before a backend is
 * chosen is a loud refusal, not a silent overlay. */
enum {
    AOWL_UI_BK_NONE    = 0,
    AOWL_UI_BK_OVERLAY = 1,
    AOWL_UI_BK_NATIVE  = 2
};

/* Widget kinds. */
enum {
    AOWL_UI_PANEL    = 1,
    AOWL_UI_LABEL    = 2,
    AOWL_UI_TOGGLE   = 3,
    AOWL_UI_BUTTON   = 4,
    AOWL_UI_TABSTRIP = 5,
    AOWL_UI_ROW      = 6
};

/* Config binding value types. */
enum {
    AOWL_UI_BIND_NONE  = 0,
    AOWL_UI_BIND_BOOL  = 1,
    AOWL_UI_BIND_FLOAT = 2,
    AOWL_UI_BIND_INT   = 3
};

/* Refusal codes -- a builder returns one of these NEGATED as its handle when it
 * cannot build, so a caller never gets a bare -1 with no reason. */
enum {
    AOWL_UI_OK            =  0,
    AOWL_UI_REFUSE_FULL   =  1,  /* widget table full                        */
    AOWL_UI_REFUSE_BACKEND=  2,  /* no/invalid backend selected              */
    AOWL_UI_REFUSE_KIND   =  3,  /* bad kind                                 */
    AOWL_UI_REFUSE_PARENT =  4,  /* parent handle out of range               */
    AOWL_UI_REFUSE_RECT   =  5,  /* zero-area / non-finite rect              */
    AOWL_UI_REFUSE_TABS   =  6,  /* too many tabs                            */
    AOWL_UI_REFUSE_BINDS  =  7,  /* binding table full                       */
    AOWL_UI_REFUSE_ARGS   =  8,  /* null/empty required argument             */
    /* --- handle-identity refusals (generational handles, see below) --- */
    AOWL_UI_REFUSE_RANGE  =  9,  /* malformed handle / index out of range    */
    AOWL_UI_REFUSE_RELEASED = 10,/* slot in range but not allocated          */
    AOWL_UI_REFUSE_STALE  = 11,  /* right slot, WRONG generation             */
    AOWL_UI_REFUSE_DISABLED = 12 /* core self-disabled after too many faults */
};

/* How many hard handle refusals (RANGE/RELEASED/STALE) before the core stops
 * building and mutating altogether. Matches nuikit's budget. Re-armed only by
 * an explicit aowl_ui_reset(). */
enum { AOWL_UI_FAULT_BUDGET = 8 };

static const char* aowl_ui_refusal_text(int32_t code) {
    switch (code) {
        case AOWL_UI_OK:             return "ok";
        case AOWL_UI_REFUSE_FULL:    return "widget table full (AOWL_UI_MAX)";
        case AOWL_UI_REFUSE_BACKEND: return "no backend selected (call before "
                                            "aowl_ui_begin, or bkNone)";
        case AOWL_UI_REFUSE_KIND:    return "unknown widget kind";
        case AOWL_UI_REFUSE_PARENT:  return "parent handle out of range";
        case AOWL_UI_REFUSE_RECT:    return "zero-area or non-finite rect -- "
                                            "would render nothing while every "
                                            "call reports success";
        case AOWL_UI_REFUSE_TABS:    return "too many tabs (AOWL_UI_TABS)";
        case AOWL_UI_REFUSE_BINDS:   return "config binding table full";
        case AOWL_UI_REFUSE_ARGS:    return "a required argument was null/empty";
        case AOWL_UI_REFUSE_RANGE:   return "RANGE -- malformed handle or slot "
                                            "index out of range";
        case AOWL_UI_REFUSE_RELEASED:return "RELEASED -- that slot holds no "
                                            "widget";
        case AOWL_UI_REFUSE_STALE:   return "STALE-GENERATION -- this handle "
                                            "outlived its widget; uiBegin/reset "
                                            "recycled the slot and it now holds "
                                            "a DIFFERENT element";
        case AOWL_UI_REFUSE_DISABLED:return "core self-disabled after "
                                            "AOWL_UI_FAULT_BUDGET handle faults";
        default:                     return "unknown refusal";
    }
}

/* ------------------------------------------------------------------ *
 * The widget record.
 * ------------------------------------------------------------------ */
typedef struct {
    int32_t  used;
    int32_t  kind;
    int32_t  backend;
    int32_t  parent;        /* handle, or -1 for a root                   */
    float    x, y, w, h;    /* SCREEN-space rect (top-left origin, y down)*/
    uint32_t col;           /* fill (panel/row bg) or text color, ARGB    */
    uint32_t accent;        /* toggle-on fill / box outline color, ARGB   */
    char     text[AOWL_UI_TEXT];
    int32_t  interactive;   /* participates in the polled hit-test        */
    int32_t  visible;       /* honored by both backends (tab hide/show)   */
    int32_t  toggleOn;      /* toggle state, read back to prove a click   */
    int32_t  bindId;        /* index into the binding table, or -1        */
    int32_t  cbId;          /* button callback id (opaque to core), or -1 */
    /* tab strip */
    int32_t  tabCount;
    int32_t  tabSel;
    int32_t  tabContent[AOWL_UI_TABS]; /* content widget handle per tab   */
    /* hit state, per widget */
    int32_t  hovered;
    int32_t  clicked;       /* set on the frame a press EDGE lands on it  */
    /* native backend handles (opaque uint64; 0 = not built) */
    uint64_t nativeGo, nativeRt, nativeComp, nativeTmp;
    int32_t  built;         /* backend realised this widget               */
    int32_t  refusal;       /* per-widget realise refusal, 0 = ok         */
} AowlUiWidget;

/* A single overlay draw op, produced by the tree walk and replayed by the host
 * against aowl_region_*. Kept POD and self-contained (copied text, not a
 * pointer) exactly like AowlRegionCmd. */
enum { AOWL_UI_OP_FILL = 1, AOWL_UI_OP_BOX = 2, AOWL_UI_OP_TEXT = 3 };
typedef struct {
    int32_t  op;
    float    x, y, w, h;
    float    thickness;     /* BOX only                                   */
    uint32_t col;
    char     text[AOWL_UI_TEXT]; /* TEXT only                             */
} AowlUiDrawOp;

/* ------------------------------------------------------------------ *
 * Config binding table -- (modGuid|key) -> a cached value + dirty flag.
 * The Nim/host side flushes dirty bindings to the real config store; this
 * core only owns the identity, the last value, and the dirty edge, so binding
 * resolution is testable with no config store present.
 * ------------------------------------------------------------------ */
typedef struct {
    int32_t used;
    int32_t type;           /* AOWL_UI_BIND_*                             */
    char    id[AOWL_UI_KEY]; /* "modGuid\0key" joined                     */
    double  value;          /* bool 0/1, float, or int all live here      */
    int32_t dirty;          /* set when a widget wrote it, cleared on flush*/
} AowlUiBind;

typedef struct {
    AowlUiWidget w[AOWL_UI_MAX];
    int32_t      count;
    int32_t      backend;   /* current backend for new widgets            */
    AowlUiBind   binds[AOWL_UI_BINDS];
    int32_t      bindCount;
    AowlUiDrawOp ops[AOWL_UI_DRAWOPS];
    int32_t      opCount;
    int32_t      prevDown;  /* pointer button state last pump             */
    /* --- generational handle identity ------------------------------- *
     * gen[i] is the generation CURRENTLY living in slot i. It is bumped
     * for every slot by aowl_ui_reset(), and it SURVIVES the memset --
     * that is the whole point: a handle minted before a reset carries an
     * older generation and is refused STALE instead of silently
     * addressing whatever now occupies the recycled index.              */
    int32_t      gen[AOWL_UI_MAX];
    int32_t      handleFaults;   /* RANGE + RELEASED + STALE so far      */
    int32_t      lastHandleRefusal;
    int32_t      disabled;       /* budget spent; only reset() re-arms   */
} AowlUiState;

#ifdef AOWL_UI_HOST
AowlUiState g_ui;
#else
extern AowlUiState g_ui;
#endif

/* ------------------------------------------------------------------ *
 * Finiteness / renderability -- the same predicate that ended the
 * invoke2 invisible-success bug, restated for screen rects.
 * ------------------------------------------------------------------ */
static int32_t aowl_ui_finite(float v) {
    /* NaN != NaN; Inf fails the magnitude bound. */
    return (v == v) && (v < 1.0e6f) && (v > -1.0e6f);
}
static int32_t aowl_ui_rect_ok(float x, float y, float w, float h) {
    if (!aowl_ui_finite(x) || !aowl_ui_finite(y) ||
        !aowl_ui_finite(w) || !aowl_ui_finite(h)) return 0;
    if (w <= 0.5f || h <= 0.5f) return 0;   /* sub-pixel area renders nothing */
    return 1;
}

/* ------------------------------------------------------------------ *
 * Lifecycle.
 * ------------------------------------------------------------------ */
/* ------------------------------------------------------------------ *
 * GENERATIONAL HANDLES.
 *
 *   handle = (gen << 16) | (index + 1)
 *
 * so a live handle is always > 0 (never 0, never negative -- refusals are
 * negative and -1 stays the "no parent" sentinel), the index nibble is
 * 1..AOWL_UI_MAX, and gen is 1..0x7FFF (bit 31 stays clear so the handle is
 * a positive int32 on every compiler). This is the same encoding nuikit.nim
 * uses for native widget handles, deliberately, so the two do not drift.
 * ------------------------------------------------------------------ */
enum { AOWL_UI_GEN_MAX = 0x7FFF };

/* The CURRENT handle for a slot index, or 0 if that slot holds no widget.
 * Enumeration (0..aowl_ui_count) goes through this, so walking the table never
 * spends the fault budget on empty slots. */
static int32_t aowl_ui_handle_at(int32_t index) {
    if (index < 0 || index >= AOWL_UI_MAX) return 0;
    if (!g_ui.w[index].used || g_ui.gen[index] <= 0) return 0;
    return (g_ui.gen[index] << 16) | (index + 1);
}

/* The ONE decoder. Returns AOWL_UI_OK and writes *outIndex, or a POSITIVE
 * refusal code naming exactly why the handle is not usable. Every hard
 * refusal is counted against the fault budget. */
static int32_t aowl_ui_handle_check(int32_t h, int32_t* outIndex) {
    int32_t idx, gen, code;
    idx = (h & 0xFFFF) - 1;
    gen = (h >> 16) & 0xFFFF;
    if (h <= 0 || idx < 0 || idx >= AOWL_UI_MAX || gen <= 0)
        code = AOWL_UI_REFUSE_RANGE;
    else if (gen != g_ui.gen[idx])
        code = AOWL_UI_REFUSE_STALE;
    else if (!g_ui.w[idx].used)
        code = AOWL_UI_REFUSE_RELEASED;
    else {
        if (outIndex) *outIndex = idx;
        return AOWL_UI_OK;
    }
    g_ui.lastHandleRefusal = code;
    if (g_ui.handleFaults < AOWL_UI_FAULT_BUDGET) {
        g_ui.handleFaults++;
        if (g_ui.handleFaults >= AOWL_UI_FAULT_BUDGET) g_ui.disabled = 1;
    }
    return code;
}

/* The slot index behind a live handle, or -1. For callers that keep a
 * per-slot side table (e.g. the Nim callback array) -- NEVER use a handle
 * itself as an array subscript, it is not an index any more. */
static int32_t aowl_ui_index_of(int32_t h) {
    int32_t idx = 0;
    return aowl_ui_handle_check(h, &idx) == AOWL_UI_OK ? idx : -1;
}

/* Why the last bad handle was refused (a positive AOWL_UI_REFUSE_* code). */
static int32_t aowl_ui_last_handle_refusal(void) { return g_ui.lastHandleRefusal; }
static int32_t aowl_ui_handle_faults(void)       { return g_ui.handleFaults; }
static int32_t aowl_ui_disabled(void)            { return g_ui.disabled; }

static void aowl_ui_reset(void) {
    int32_t saved[AOWL_UI_MAX];
    int32_t i;
    /* Bump EVERY slot's generation across the wipe. Bumping only the `used`
     * slots would leave a handle to a never-yet-allocated index validating
     * after that index is later filled -- the same silent-wrong-element bug
     * one step removed. */
    for (i = 0; i < AOWL_UI_MAX; i++) {
        int32_t g = g_ui.gen[i] + 1;
        if (g > AOWL_UI_GEN_MAX || g <= 0) g = 1;   /* wraps after 32767 resets */
        saved[i] = g;
    }
    memset(&g_ui, 0, sizeof(g_ui));
    for (i = 0; i < AOWL_UI_MAX; i++) g_ui.gen[i] = saved[i];
    g_ui.backend = AOWL_UI_BK_NONE;
}

static int32_t aowl_ui_begin(int32_t backend) {
    if (backend != AOWL_UI_BK_OVERLAY && backend != AOWL_UI_BK_NATIVE)
        return -AOWL_UI_REFUSE_BACKEND;
    g_ui.backend = backend;
    return AOWL_UI_OK;
}

static int32_t aowl_ui_valid(int32_t h) {
    int32_t idx = 0;
    return aowl_ui_handle_check(h, &idx) == AOWL_UI_OK;
}
static AowlUiWidget* aowl_ui_at(int32_t h) {
    int32_t idx = 0;
    if (aowl_ui_handle_check(h, &idx) != AOWL_UI_OK) return (AowlUiWidget*)0;
    return &g_ui.w[idx];
}

/* The one allocator. Returns a handle >= 0, or a NEGATED refusal code. */
static int32_t aowl_ui_new(int32_t kind, int32_t parent,
                           float x, float y, float w, float h) {
    int32_t i;
    if (g_ui.disabled) return -AOWL_UI_REFUSE_DISABLED;
    if (g_ui.backend != AOWL_UI_BK_OVERLAY && g_ui.backend != AOWL_UI_BK_NATIVE)
        return -AOWL_UI_REFUSE_BACKEND;
    if (kind < AOWL_UI_PANEL || kind > AOWL_UI_ROW)
        return -AOWL_UI_REFUSE_KIND;
    if (parent != -1 && !aowl_ui_valid(parent))
        return -AOWL_UI_REFUSE_PARENT;
    if (!aowl_ui_rect_ok(x, y, w, h))
        return -AOWL_UI_REFUSE_RECT;
    for (i = 0; i < AOWL_UI_MAX; i++) {
        if (!g_ui.w[i].used) {
            AowlUiWidget* p = &g_ui.w[i];
            memset(p, 0, sizeof(*p));
            p->used = 1;
            p->kind = kind;
            p->backend = g_ui.backend;
            p->parent = parent;
            p->x = x; p->y = y; p->w = w; p->h = h;
            p->col = 0xFFFFFFFFu;
            p->accent = 0xFF3A7BD5u;
            p->visible = 1;
            p->bindId = -1;
            p->cbId = -1;
            p->tabSel = 0;
            if (i + 1 > g_ui.count) g_ui.count = i + 1;
            /* A never-reset global starts at gen 0, which decodes as RANGE.
             * Claiming a slot mints generation 1 at the latest. */
            if (g_ui.gen[i] <= 0) g_ui.gen[i] = 1;
            return aowl_ui_handle_at(i);
        }
    }
    return -AOWL_UI_REFUSE_FULL;
}

static void aowl_ui_set_text(int32_t h, const char* s) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (!p || !s) return;
    strncpy(p->text, s, AOWL_UI_TEXT - 1);
    p->text[AOWL_UI_TEXT - 1] = 0;
}
static void aowl_ui_set_colors(int32_t h, uint32_t col, uint32_t accent) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (!p) return;
    p->col = col; p->accent = accent;
}
static void aowl_ui_set_interactive(int32_t h, int32_t on) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (p) p->interactive = on ? 1 : 0;
}
static void aowl_ui_set_visible(int32_t h, int32_t on) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (p) p->visible = on ? 1 : 0;
}
static void aowl_ui_set_native(int32_t h, uint64_t go, uint64_t rt,
                               uint64_t comp, uint64_t tmp) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (!p) return;
    p->nativeGo = go; p->nativeRt = rt; p->nativeComp = comp; p->nativeTmp = tmp;
    p->built = (go || comp) ? 1 : 0;
}
static void aowl_ui_set_refusal(int32_t h, int32_t code) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (p) p->refusal = code;
}

/* ------------------------------------------------------------------ *
 * LAYOUT ARITHMETIC -- stack packing, computed once, above the backends.
 * A caller lays out N children of a container without computing any rect by
 * hand; the backend then places each child at its computed rect.
 * ------------------------------------------------------------------ */
/* Slot `index` of `count` items packed into a container rect (cx,cy,cw,ch),
 * with `pad` around the group and `spacing` between items. `horizontal`
 * chooses a row; otherwise a column. Cross-axis fills (minus padding).
 * Returns 1 and writes the slot rect, or 0 if the geometry is degenerate. */
static int32_t aowl_ui_stack_slot(float cx, float cy, float cw, float ch,
                                  int32_t index, int32_t count,
                                  float pad, float spacing, int32_t horizontal,
                                  float* ox, float* oy, float* ow, float* oh) {
    float inx, iny, inw, inh, cell;
    if (count <= 0 || index < 0 || index >= count) return 0;
    if (!aowl_ui_rect_ok(cx, cy, cw, ch)) return 0;
    inx = cx + pad; iny = cy + pad;
    inw = cw - 2.0f * pad; inh = ch - 2.0f * pad;
    if (inw <= 0.5f || inh <= 0.5f) return 0;
    if (horizontal) {
        cell = (inw - spacing * (float)(count - 1)) / (float)count;
        if (cell <= 0.5f) return 0;
        *ox = inx + (cell + spacing) * (float)index;
        *oy = iny; *ow = cell; *oh = inh;
    } else {
        cell = (inh - spacing * (float)(count - 1)) / (float)count;
        if (cell <= 0.5f) return 0;
        *ox = inx; *oy = iny + (cell + spacing) * (float)index;
        *ow = inw; *oh = cell;
    }
    return aowl_ui_rect_ok(*ox, *oy, *ow, *oh);
}

/* A labeled-row split: the row rect divided into a LEFT label area and a RIGHT
 * control area, `labelFrac` of the width to the label. This is what uiRow uses
 * so a settings screen is `for each setting: uiRow(...)`. */
static int32_t aowl_ui_row_split(float rx, float ry, float rw, float rh,
                                 float labelFrac, float gap,
                                 float* lx, float* ly, float* lw, float* lh,
                                 float* kx, float* ky, float* kw, float* kh) {
    float lwid, kwid;
    if (!aowl_ui_rect_ok(rx, ry, rw, rh)) return 0;
    if (labelFrac < 0.05f || labelFrac > 0.95f) return 0;
    lwid = rw * labelFrac - gap * 0.5f;
    kwid = rw * (1.0f - labelFrac) - gap * 0.5f;
    if (lwid <= 0.5f || kwid <= 0.5f) return 0;
    *lx = rx; *ly = ry; *lw = lwid; *lh = rh;
    *kx = rx + rw * labelFrac + gap * 0.5f; *ky = ry; *kw = kwid; *kh = rh;
    return 1;
}

/* ------------------------------------------------------------------ *
 * TAB-SELECTION STATE MACHINE. Selection is host state; clicking a tab sets
 * which content widget is visible, sidestepping the game's ToggleGroup (fact
 * #117: cloned game toggles are dead). Backend-independent.
 * ------------------------------------------------------------------ */
static int32_t aowl_ui_tab_add(int32_t strip, int32_t contentHandle) {
    AowlUiWidget* p = aowl_ui_at(strip);
    if (!p || p->kind != AOWL_UI_TABSTRIP) return -AOWL_UI_REFUSE_KIND;
    if (p->tabCount >= AOWL_UI_TABS) return -AOWL_UI_REFUSE_TABS;
    p->tabContent[p->tabCount] = contentHandle;
    p->tabCount++;
    return p->tabCount - 1;
}

/* Apply the current selection: exactly one content is visible, the rest hidden.
 * Returns the selected tab index, or -1 if the strip is empty/invalid. The
 * negative property this asserts -- "no OTHER content is visible" -- is what
 * the test checks, because a positive "the selected one is visible" cannot
 * fail. */
static int32_t aowl_ui_tab_apply(int32_t strip) {
    int32_t i;
    AowlUiWidget* p = aowl_ui_at(strip);
    if (!p || p->kind != AOWL_UI_TABSTRIP || p->tabCount <= 0) return -1;
    if (p->tabSel < 0) p->tabSel = 0;
    if (p->tabSel >= p->tabCount) p->tabSel = p->tabCount - 1;
    for (i = 0; i < p->tabCount; i++) {
        AowlUiWidget* c = aowl_ui_at(p->tabContent[i]);
        if (c) c->visible = (i == p->tabSel) ? 1 : 0;
    }
    return p->tabSel;
}

static int32_t aowl_ui_tab_select(int32_t strip, int32_t idx) {
    AowlUiWidget* p = aowl_ui_at(strip);
    if (!p || p->kind != AOWL_UI_TABSTRIP) return -1;
    if (idx < 0 || idx >= p->tabCount) return -1;
    p->tabSel = idx;
    return aowl_ui_tab_apply(strip);
}
static int32_t aowl_ui_tab_selected(int32_t strip) {
    AowlUiWidget* p = aowl_ui_at(strip);
    if (!p || p->kind != AOWL_UI_TABSTRIP) return -1;
    return p->tabSel;
}
/* Is `contentHandle` the currently-active content of `strip`? */
static int32_t aowl_ui_tab_content_active(int32_t strip, int32_t contentHandle) {
    AowlUiWidget* p = aowl_ui_at(strip);
    if (!p || p->kind != AOWL_UI_TABSTRIP || p->tabCount <= 0) return 0;
    if (p->tabSel < 0 || p->tabSel >= p->tabCount) return 0;
    return p->tabContent[p->tabSel] == contentHandle;
}
/* Which tab sub-rect does a local x fall in? Tabs divide the strip width
 * evenly. Returns tab index or -1. */
static int32_t aowl_ui_tab_hit(int32_t strip, float px) {
    AowlUiWidget* p = aowl_ui_at(strip);
    int32_t idx;
    float cell;
    if (!p || p->kind != AOWL_UI_TABSTRIP || p->tabCount <= 0) return -1;
    if (px < p->x || px >= p->x + p->w) return -1;
    cell = p->w / (float)p->tabCount;
    if (cell <= 0.0f) return -1;
    idx = (int32_t)((px - p->x) / cell);
    if (idx < 0) idx = 0;
    if (idx >= p->tabCount) idx = p->tabCount - 1;
    return idx;
}

/* ------------------------------------------------------------------ *
 * CONFIG BINDING. `(modGuid, key)` -> a cached value + dirty edge.
 * ------------------------------------------------------------------ */
static void aowl_ui_bind_join(const char* modGuid, const char* key,
                              char* out, int32_t cap) {
    int32_t n = 0, i;
    out[0] = 0;
    if (!modGuid) modGuid = "";
    if (!key) key = "";
    for (i = 0; modGuid[i] && n < cap - 1; i++) out[n++] = modGuid[i];
    if (n < cap - 1) out[n++] = '\x1f';   /* unit separator, unambiguous join */
    for (i = 0; key[i] && n < cap - 1; i++) out[n++] = key[i];
    out[n] = 0;
}

/* Intern a binding identity, returning its id (>=0) or a negated refusal.
 * `type` is the value type; an existing binding keeps its stored value. */
static int32_t aowl_ui_bind_intern(const char* modGuid, const char* key,
                                   int32_t type) {
    char id[AOWL_UI_KEY];
    int32_t i;
    if ((!modGuid || !modGuid[0]) && (!key || !key[0]))
        return -AOWL_UI_REFUSE_ARGS;
    aowl_ui_bind_join(modGuid, key, id, AOWL_UI_KEY);
    for (i = 0; i < AOWL_UI_BINDS; i++)
        if (g_ui.binds[i].used && strcmp(g_ui.binds[i].id, id) == 0)
            return i;
    for (i = 0; i < AOWL_UI_BINDS; i++) {
        if (!g_ui.binds[i].used) {
            g_ui.binds[i].used = 1;
            g_ui.binds[i].type = type;
            /* `id` came from aowl_ui_bind_join with cap AOWL_UI_KEY, so it is
             * already NUL-terminated within the buffer -- copy it whole. */
            memcpy(g_ui.binds[i].id, id, AOWL_UI_KEY);
            g_ui.binds[i].id[AOWL_UI_KEY - 1] = 0;
            g_ui.binds[i].value = 0.0;
            g_ui.binds[i].dirty = 0;
            if (i + 1 > g_ui.bindCount) g_ui.bindCount = i + 1;
            return i;
        }
    }
    return -AOWL_UI_REFUSE_BINDS;
}

/* Attach a binding to a widget. The widget's control state and the binding's
 * value are synced: for a toggle, toggleOn <- value on bind, value <- toggleOn
 * on write. */
static int32_t aowl_ui_bind_widget(int32_t h, const char* modGuid,
                                   const char* key, int32_t type) {
    AowlUiWidget* p = aowl_ui_at(h);
    int32_t b;
    if (!p) return -AOWL_UI_REFUSE_PARENT;
    b = aowl_ui_bind_intern(modGuid, key, type);
    if (b < 0) return b;
    p->bindId = b;
    if (type == AOWL_UI_BIND_BOOL)
        p->toggleOn = (g_ui.binds[b].value != 0.0) ? 1 : 0;
    return b;
}
static int32_t aowl_ui_bind_valid(int32_t b) {
    return b >= 0 && b < AOWL_UI_BINDS && g_ui.binds[b].used;
}
static double aowl_ui_bind_get(int32_t b) {
    return aowl_ui_bind_valid(b) ? g_ui.binds[b].value : 0.0;
}
static void aowl_ui_bind_set(int32_t b, double v) {
    if (!aowl_ui_bind_valid(b)) return;
    if (g_ui.binds[b].value != v) {
        g_ui.binds[b].value = v;
        g_ui.binds[b].dirty = 1;
    }
}
static int32_t aowl_ui_bind_dirty(int32_t b) {
    return aowl_ui_bind_valid(b) ? g_ui.binds[b].dirty : 0;
}
static void aowl_ui_bind_clear_dirty(int32_t b) {
    if (aowl_ui_bind_valid(b)) g_ui.binds[b].dirty = 0;
}
static int32_t aowl_ui_bind_dirty_count(void) {
    int32_t i, n = 0;
    for (i = 0; i < AOWL_UI_BINDS; i++)
        if (g_ui.binds[i].used && g_ui.binds[i].dirty) n++;
    return n;
}

/* ------------------------------------------------------------------ *
 * HIT GEOMETRY + POLLED DISPATCH. One code path drives interaction on BOTH
 * backends: the caller supplies the pointer position and button state it
 * already has (overlay reads it from its own input; native reads it from the
 * frame). A press EDGE (down this frame, up last frame) inside an interactive
 * widget's rect is a click. Toggles flip and write their binding; tab strips
 * change selection; buttons set `clicked` for the caller to read.
 *
 * For NATIVE widgets whose live rect differs from the stored one (the Unity
 * layout may move them), the Nim side passes the live rect in via
 * aowl_ui_set_rect before pumping; the geometry here is identical.
 * ------------------------------------------------------------------ */
static int32_t aowl_ui_point_in(const AowlUiWidget* p, float px, float py) {
    if (!p) return 0;
    if (p->w <= 0.5f || p->h <= 0.5f) return 0;   /* a failed-layout rect
                                                     cannot be clicked either */
    return px >= p->x && px < p->x + p->w &&
           py >= p->y && py < p->y + p->h;
}
static void aowl_ui_set_rect(int32_t h, float x, float y, float w, float hh) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (!p) return;
    p->x = x; p->y = y; p->w = w; p->h = hh;
}

/* Run one pump. `down` is the pointer button state now. Returns the number of
 * widgets that received a click edge this frame. Sets each interactive
 * widget's `hovered` and `clicked`. Capped by AOWL_UI_MAX. */
static int32_t aowl_ui_pump(float px, float py, int32_t down) {
    int32_t i, clicks = 0;
    int32_t edge = (down && !g_ui.prevDown) ? 1 : 0;
    for (i = 0; i < g_ui.count; i++) {
        AowlUiWidget* p = &g_ui.w[i];
        int32_t inside;
        if (!p->used) continue;
        p->clicked = 0;
        if (!p->interactive || !p->visible) { p->hovered = 0; continue; }
        inside = aowl_ui_point_in(p, px, py);
        p->hovered = inside;
        if (inside && edge) {
            p->clicked = 1;
            clicks++;
            if (p->kind == AOWL_UI_TOGGLE) {
                p->toggleOn = p->toggleOn ? 0 : 1;
                if (p->bindId >= 0)
                    aowl_ui_bind_set(p->bindId, p->toggleOn ? 1.0 : 0.0);
            } else if (p->kind == AOWL_UI_TABSTRIP) {
                /* i is a SLOT INDEX; the tab API takes a HANDLE. */
                int32_t sh = aowl_ui_handle_at(i);
                int32_t t = aowl_ui_tab_hit(sh, px);
                if (t >= 0) aowl_ui_tab_select(sh, t);
            }
        }
    }
    g_ui.prevDown = down ? 1 : 0;
    return clicks;
}

/* Consume a widget's click edge (read-and-clear), for a caller that dispatches
 * button callbacks itself. */
static int32_t aowl_ui_take_click(int32_t h) {
    AowlUiWidget* p = aowl_ui_at(h);
    int32_t c;
    if (!p) return 0;
    c = p->clicked;
    p->clicked = 0;
    return c;
}
static int32_t aowl_ui_toggle_state(int32_t h) {
    AowlUiWidget* p = aowl_ui_at(h);
    return p ? p->toggleOn : 0;
}
/* Force a toggle's state (an initial value), writing its binding if bound. */
static void aowl_ui_toggle_force(int32_t h, int32_t on) {
    AowlUiWidget* p = aowl_ui_at(h);
    if (!p) return;
    p->toggleOn = on ? 1 : 0;
    if (p->bindId >= 0) aowl_ui_bind_set(p->bindId, p->toggleOn ? 1.0 : 0.0);
}

/* ------------------------------------------------------------------ *
 * OVERLAY EMIT. Walk the retained tree, produce draw ops for every VISIBLE
 * overlay-backend widget. The host replays g_ui.ops through aowl_region_*.
 * Called from inside the region DRAW callback ONLY. Returns op count.
 *
 * The mapping is deliberately simple and total:
 *   PANEL/ROW  -> FILL (bg)              + BOX (1px border)
 *   LABEL      -> TEXT
 *   TOGGLE     -> BOX (check frame) + FILL if on + TEXT (caption)
 *   BUTTON     -> FILL (bg) + BOX + TEXT
 *   TABSTRIP   -> per tab: FILL(selected)/BOX + TEXT(index marker)
 * ------------------------------------------------------------------ */
static void aowl_ui_op(int32_t op, float x, float y, float w, float h,
                       float thickness, uint32_t col, const char* text) {
    AowlUiDrawOp* o;
    if (g_ui.opCount >= AOWL_UI_DRAWOPS) return;   /* capped, refuses past end */
    o = &g_ui.ops[g_ui.opCount++];
    o->op = op; o->x = x; o->y = y; o->w = w; o->h = h;
    o->thickness = thickness; o->col = col;
    o->text[0] = 0;
    if (text) { strncpy(o->text, text, AOWL_UI_TEXT - 1);
                o->text[AOWL_UI_TEXT - 1] = 0; }
}

static int32_t aowl_ui_overlay_emit(void) {
    int32_t i;
    g_ui.opCount = 0;
    for (i = 0; i < g_ui.count; i++) {
        AowlUiWidget* p = &g_ui.w[i];
        if (!p->used || p->backend != AOWL_UI_BK_OVERLAY || !p->visible)
            continue;
        if (!aowl_ui_rect_ok(p->x, p->y, p->w, p->h)) continue;
        switch (p->kind) {
        case AOWL_UI_PANEL:
        case AOWL_UI_ROW:
            aowl_ui_op(AOWL_UI_OP_FILL, p->x, p->y, p->w, p->h, 0, p->col, 0);
            aowl_ui_op(AOWL_UI_OP_BOX,  p->x, p->y, p->w, p->h, 1.0f,
                       p->accent, 0);
            if (p->text[0])
                aowl_ui_op(AOWL_UI_OP_TEXT, p->x + 6.0f, p->y + 4.0f,
                           0, 0, 0, 0xFFFFFFFFu, p->text);
            break;
        case AOWL_UI_LABEL:
            aowl_ui_op(AOWL_UI_OP_TEXT, p->x, p->y, 0, 0, 0, p->col, p->text);
            break;
        case AOWL_UI_TOGGLE: {
            float box = p->h < p->w ? p->h : p->w;
            aowl_ui_op(AOWL_UI_OP_BOX, p->x, p->y, box, box, 1.5f,
                       p->accent, 0);
            if (p->toggleOn)
                aowl_ui_op(AOWL_UI_OP_FILL, p->x + 3.0f, p->y + 3.0f,
                           box - 6.0f, box - 6.0f, 0, p->accent, 0);
            if (p->text[0])
                aowl_ui_op(AOWL_UI_OP_TEXT, p->x + box + 6.0f, p->y + 2.0f,
                           0, 0, 0, p->col, p->text);
            break;
        }
        case AOWL_UI_BUTTON:
            aowl_ui_op(AOWL_UI_OP_FILL, p->x, p->y, p->w, p->h, 0,
                       p->hovered ? p->accent : p->col, 0);
            aowl_ui_op(AOWL_UI_OP_BOX, p->x, p->y, p->w, p->h, 1.0f,
                       0xFFFFFFFFu, 0);
            if (p->text[0])
                aowl_ui_op(AOWL_UI_OP_TEXT, p->x + 6.0f, p->y + 4.0f,
                           0, 0, 0, 0xFFFFFFFFu, p->text);
            break;
        case AOWL_UI_TABSTRIP: {
            int32_t t;
            float cell = p->tabCount > 0 ? p->w / (float)p->tabCount : p->w;
            for (t = 0; t < p->tabCount; t++) {
                float tx = p->x + cell * (float)t;
                if (t == p->tabSel)
                    aowl_ui_op(AOWL_UI_OP_FILL, tx, p->y, cell, p->h, 0,
                               p->accent, 0);
                aowl_ui_op(AOWL_UI_OP_BOX, tx, p->y, cell, p->h, 1.0f,
                           0xFFFFFFFFu, 0);
            }
            if (p->text[0])
                aowl_ui_op(AOWL_UI_OP_TEXT, p->x + 4.0f, p->y + 4.0f,
                           0, 0, 0, 0xFFFFFFFFu, p->text);
            break;
        }
        default: break;
        }
    }
    return g_ui.opCount;
}

/* Accessors for the Nim/host side to replay ops. */
static int32_t             aowl_ui_op_count(void) { return g_ui.opCount; }
static const AowlUiDrawOp* aowl_ui_op_at(int32_t i) {
    return (i >= 0 && i < g_ui.opCount) ? &g_ui.ops[i] : (const AowlUiDrawOp*)0;
}
static int32_t aowl_ui_count(void)       { return g_ui.count; }
static int32_t aowl_ui_backend(void)     { return g_ui.backend; }

/* REPLAY BRIDGE. `aowl_region_fill/box/text` are host-static in region.nim's
 * translation unit, which is NOT the TU aowlui.nim is compiled in. Rather than
 * plumb those symbols across TUs (and risk the double-hook trap), the region
 * side hands us its three draw functions as pointers and we replay the ops
 * already emitted by aowl_ui_overlay_emit. This keeps the whole overlay path
 * offline-testable: the test passes stub sinks and asserts the calls.
 *
 * Signatures mirror aowlspt_region.h exactly:
 *   aowl_region_fill(x,y,w,h,col) ; box(x,y,w,h,thickness,col) ; text(x,y,s,col)
 * The return int32 (a refusal code) is ignored here; the region layer logs it. */
typedef int32_t (*AowlUiFillFn)(float, float, float, float, uint32_t);
typedef int32_t (*AowlUiBoxFn )(float, float, float, float, float, uint32_t);
typedef int32_t (*AowlUiTextFn)(float, float, const char*, uint32_t);

static int32_t aowl_ui_overlay_replay(AowlUiFillFn fill, AowlUiBoxFn box,
                                      AowlUiTextFn text) {
    int32_t i, drawn = 0;
    for (i = 0; i < g_ui.opCount; i++) {           /* capped by opCount */
        const AowlUiDrawOp* o = &g_ui.ops[i];
        switch (o->op) {
        case AOWL_UI_OP_FILL:
            if (fill) { fill(o->x, o->y, o->w, o->h, o->col); drawn++; }
            break;
        case AOWL_UI_OP_BOX:
            if (box)  { box(o->x, o->y, o->w, o->h, o->thickness, o->col);
                        drawn++; }
            break;
        case AOWL_UI_OP_TEXT:
            if (text) { text(o->x, o->y, o->text, o->col); drawn++; }
            break;
        default: break;
        }
    }
    return drawn;
}

#endif /* AOWLSPT_UI_H */
