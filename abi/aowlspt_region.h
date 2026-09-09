/* aowlspt_region.h -- THE SHARED PER-FRAME REGION.
 *
 * A first-class, mod-facing per-frame DRAW + TICK facility. Any number of
 * participants register a callback; the region owns the ONE dispatch point and
 * calls them. Nobody needs a second detour, and nobody needs to borrow another
 * mod's private header to get a pixel on screen.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS FILE EXISTS
 * ---------------------------------------------------------------------------
 *
 * Two detours on one function have the second overwrite the first's trampoline
 * and silently kill the first feature. The consequence, on this build, is that
 * there is effectively ONE main-thread hook in this project: the rider chain on
 * `EFT.UI.PreloaderUI::Update`. It already carries the debug overlay, the menu
 * mode text, the live inspector, the mods tab and the version brand, and each
 * of those rides it by hard-coding a slot global into `patchFired` in
 * `aowlhost.nim`. That works, and it does not scale: it means every new
 * per-frame feature is a source edit to the host, in a file five other agents
 * are also editing, and a mod that is not part of the host cannot participate
 * at all.
 *
 * Measured today: the maps/radar/indicators mod reported its in-game draw
 * BLOCKED because "the only generic region is `abi/aowlspt_admin.h`" -- another
 * mod's private surface. Five features (maps, radar, accessibility indicators,
 * admin ESP, the F3 debug overlay) all want the same thing and cannot share it.
 *
 * So this header is the thing they were all reaching for. It is deliberately
 * ONE more rider on the existing chain -- not a new detour -- and everything
 * else registers with it.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS FILE DOES NOT DO, ON PURPOSE
 * ---------------------------------------------------------------------------
 *
 * **It resolves no IL2CPP name, calls no game method and patches no byte.**
 * Fact #145, which is an OBSERVATION and is not restated here as a mechanism:
 * on this build a by-NAME IL2CPP route is fatal the moment it is USED, not when
 * it is resolved, and the client log of a death by that route is byte-identical
 * to a healthy run. (For what is actually going on underneath -- a token-gated
 * export ABI, not an absent one -- see `docs/IL2CPP_EXPORTS.md`; that work is
 * another agent's and this file deliberately does not encode a guess about it.)
 * The safest answer to an observation with that failure signature is to have no
 * such route in the file at all, and that is the answer taken here. This header is a registry, a QPC pair, a dispatch loop and a POD
 * command buffer. It cannot be fatal in the way #145 describes, because there
 * is nothing in it to be fatal.
 *
 * Everything that DOES need the game -- the camera projection, the actual
 * rasterisation -- arrives as a function pointer INSTALLED BY THE HOST, from
 * code that has already byte-verified its own target against the startup
 * prologue snapshot. See `aowl_region_set_projector` / `aowl_region_set_sink`.
 * If nothing is installed, projection REFUSES and drawing is a no-op; it never
 * guesses.
 *
 * It also does not resolve a name to an RVA, and does not implement a
 * byte-verified call-by-RVA path. Two other agents are building exactly those
 * (an offline name -> unique-RVA symbol table that fails the BUILD on a shared
 * or prologue-mismatched target, and a general byte-verified call-by-RVA path
 * for mods). Duplicating either would give this project two answers to one
 * question. ASSUMED, and stated so it can be corrected: when they land, the
 * host's projector installation is the single place that changes -- it becomes
 * "look the symbol up in the table, take the verified RVA, install the thunk"
 * instead of "take debugui's already-verified thunk". No mod-facing API in this
 * file changes, because no mod-facing API in this file names a symbol.
 *
 * ---------------------------------------------------------------------------
 * THE GUARD, AND WHY IT CANNOT NEST
 * ---------------------------------------------------------------------------
 *
 * `aowl_p_p_seh` (abi/aowlspt_shim.h) is a VEH + setjmp guard with exactly ONE
 * thread-local `jmp_buf` and ONE thread-local `active` flag. It is NOT
 * re-entrant: a nested guard clobbers the buffer, and worse, restores
 * `active = 0` when the INNER call returns, silently disarming the outer one.
 * A "guard per callback" placed inside a "guard around the loop" is therefore
 * not extra safety -- it is the removal of all safety, plus a false sense of it.
 *
 * But a single guard AROUND the loop gives no isolation either: the first
 * callback to fault longjmps out of the whole dispatch, and every participant
 * after it in the ordering silently loses its frame. That is precisely the
 * failure this facility exists to prevent.
 *
 * The structure that satisfies both:
 *
 *   * `aowl_region_frame()` -- the dispatcher -- opens NO guard at all. Its
 *     entire body touches only this header's own fixed arrays and integers.
 *     There is no game pointer, no dereference of anything a participant
 *     supplied, and no allocation. It has nothing to be guarded from.
 *
 *   * Each participant is invoked through ONE `aowl_p_p_seh`, entered and
 *     EXITED before the next participant is entered. The guards are SIBLINGS
 *     in sequence, never parent and child. N callbacks means N guards, and the
 *     maximum guard depth at any instant is 1.
 *
 * Two things enforce that rather than merely asserting it:
 *
 *   1. `aowl_region_frame()` REFUSES to run if a guard is already active on
 *      this thread (`aowl_region_guard_active()`, which reads the shim's own
 *      `aowl_seh_active`). If some future caller wraps us in a guard, we
 *      decline loudly and set `AOWL_REGION_REFUSE_NESTED` instead of quietly
 *      building a nest. This is the check that would catch the mistake.
 *
 *   2. A re-entrancy flag refuses a second `aowl_region_frame()` while one is
 *      in progress, so a participant that (wrongly) drives the region from
 *      inside its own callback gets a refusal, not recursion.
 *
 * The fault DETECTOR has the property CLAUDE.md 9b asks for: it cannot be made
 * to say "fine" by the thing it is checking. `aowl_p_p_seh` returns whatever
 * the body returned, or 0 if it longjmped. The body returns the constant 1
 * AFTER the callback returns normally. A callback cannot cause a 1; only
 * surviving can. So `result == 0` is a fault, always, and a callback that dies
 * cannot report success.
 *
 * ---------------------------------------------------------------------------
 * BUDGET, ORDER, ALLOCATION
 * ---------------------------------------------------------------------------
 *
 * Ordering is deterministic: ascending `order`, ties broken by registration
 * sequence, both fixed at registration. The dispatch order does not depend on
 * load order, hash order, or which mod happened to register first within an
 * order class.
 *
 * Every participant declares a per-frame budget in microseconds. The dispatcher
 * times each call with QueryPerformanceCounter and, on an overrun, increments
 * `overruns`, records the worst, and RAISES it -- once immediately and then at
 * a decaying rate, always naming the participant. Silent tolerance is how a
 * frame-time regression hides for a month; a busy log line is cheaper than that.
 * A participant that overruns `AOWL_REGION_OVERRUN_LIMIT` frames in a row is
 * additionally THROTTLED to one frame in `AOWL_REGION_THROTTLE_EVERY` -- and
 * `throttled` is published, so the state is visible rather than mysterious.
 *
 * Iteration is capped everywhere: `AOWL_REGION_MAX` participants, and the draw
 * buffer is a fixed `AOWL_REGION_MAX_CMDS` POD array that REFUSES past its end
 * and counts the refusals (`dropped`) rather than growing.
 *
 * There is no allocation on the frame path, managed or native. The registry is
 * a fixed array, names are write-once `char[32]`, the command buffers are two
 * fixed arrays swapped by index, and text commands carry an inline
 * `char[AOWL_REGION_TEXT_LEN]` rather than a pointer to memory whose lifetime
 * nobody owns.
 *
 * ---------------------------------------------------------------------------
 * WHO COMPILES WHAT
 * ---------------------------------------------------------------------------
 *
 * Two C modules cannot share a header `static`, so there is exactly ONE owner:
 *
 *   * The host DLL defines `AOWL_REGION_HOST` before including this file. That
 *     TU gets the state, the dispatcher, and the `aowl_region_*` exports.
 *   * Everybody else -- a mod DLL, the overlay -- includes it plainly and gets
 *     a thin client that resolves those exports by `GetProcAddress` on
 *     `aowlspt-host-il2cpp.dll`, lazily. An older host without the exports is a
 *     clean, reported "unavailable", never a load failure and never a crash.
 *
 * Registration is legal FROM ANY THREAD AND AT ANY TIME, including before the
 * Unity thread exists. It simply does not fire until the host arms the region
 * from the rider. That is requirement 1 and it falls out of the design: the
 * registry is guarded by a critical section, the frame path takes it only to
 * snapshot the order, and `armed` starts 0.
 *
 * ---------------------------------------------------------------------------
 * WHAT A MOD WRITES
 * ---------------------------------------------------------------------------
 *
 *     static void my_draw(void* user, int64_t frame) {
 *         float sx, sy;
 *         if (aowl_region_project(wx, wy, wz, &sx, &sy))
 *             aowl_region_box(sx - 20, sy - 40, 40, 80, 2.0f, 0xFF00FF00u);
 *         aowl_region_text(8, 8, "maps: 3 extracts", 0xFFFFFFFFu);
 *     }
 *
 *     AowlRegionDesc d;  memset(&d, 0, sizeof(d));
 *     d.size = (int32_t)sizeof(d);
 *     strcpy(d.name, "maps");         // shows up in every log line and in
 *     d.mask     = AOWL_REGION_DRAW;  // the profiler as this exact string
 *     d.order    = 100;
 *     d.budgetUs = 400;
 *     d.fn       = my_draw;
 *     int32_t h = aowl_region_register(&d);
 *     if (h < 0) log(aowl_region_refusal_text(h));   // never print the number
 *
 * That is the whole API. There is no detour to install, no prologue to verify,
 * no slot to add to `patchFired`, and no other mod's header to include.
 *
 * ---------------------------------------------------------------------------
 * MIGRATION NOTES, PER EXISTING CONSUMER
 * ---------------------------------------------------------------------------
 *
 * NONE of these migrations were performed. Their owners are mid-flight and a
 * migration done TO somebody rather than BY them is how a working feature dies
 * quietly. Each is what that owner would have to change, and each is optional:
 * the five hand-written riders keep working untouched, because the region was
 * added as a SIXTH rider after them rather than in place of them.
 *
 *   maps / radar / indicators (mods/maps, not yet landed)
 *       The one with nothing to lose. It has no rider today and was blocked on
 *       having no generic region. It registers with `AOWL_REGION_DRAW`, submits
 *       screen-space commands, and deletes whatever it was going to borrow from
 *       `aowlspt_admin.h`. No host edit at all.
 *
 *   admin ESP (mods/admin + the HUD in aowlspt_overlay.h)
 *       The largest change and the least urgent. Today the mod publishes a
 *       seqlocked frame of PRE-PROJECTED entities into its own named shared
 *       region and the overlay's `aowl_ov_admin_append` reads it. That is a
 *       sound design and it is not broken. Migrating means: register a DRAW
 *       participant, move the body of `aowl_ov_admin_append`'s ESP half into
 *       it, and emit `aowl_region_box`/`_text` instead of writing entities. It
 *       gains per-mod budget accounting and fault isolation and loses its
 *       private shared-memory hop. The F6 MENU half should NOT migrate: it is
 *       input-driven overlay chrome, not a per-frame world draw.
 *
 *   the F3 debug overlay (host/.../debugui.nim)
 *       It does not draw through the D3D overlay at all -- it clones Unity UI
 *       objects and writes into them, which is a different mechanism and the
 *       right one for menu-space text. What it WOULD gain by migrating is the
 *       dispatch, not the drawing: `debugUiFired` becomes a registered TICK
 *       participant and `gDebugUiSlot` disappears from `patchFired`. Its own
 *       `aowl_du_body_guarded` thunk must then be DELETED, not kept -- keeping
 *       it would nest a guard inside the region's per-participant guard, which
 *       is the exact bug this facility is built around. That deletion is the
 *       whole risk of this migration and it is why it is not being done here.
 *
 *   the live inspector (host/.../inspect.nim)
 *       Should probably NOT migrate. It already runs one guard per COMMAND
 *       rather than one per frame, it must keep ticking inside a raid via its
 *       second slot alias (`gInspSlot2`) where `PreloaderUI::Update` does not
 *       run, and it is the instrument used to debug everything else -- putting
 *       it behind a budget that can throttle it would mean the tool goes quiet
 *       exactly when a frame is slow. If it ever does migrate, it wants a
 *       budget of 0 meaning "unbudgeted", which this header does not offer
 *       today and would have to grow.
 *
 *   the version brand (host/.../modstab.nim, polling half)
 *       A one-line migration and a good first one: it is a throttled poll with
 *       no drawing. Register TICK, order early, budget ~200us. Its Awake-postfix
 *       half is a different detour on a different function and is unaffected.
 *
 *   the mods tab (host/.../modstab.nim)
 *       Register TICK. It builds and refreshes cloned settings rows, which is
 *       bursty rather than steady, so it wants a generous budget (2000us+) or
 *       it will report overruns on the frames it actually builds on. That is
 *       the honest reading of its cost, not a false alarm -- but a caller that
 *       has not thought about it will read the log as a regression.
 *
 * ---------------------------------------------------------------------------
 * PROFILER
 * ---------------------------------------------------------------------------
 *
 * If `abi/aowlspt_profile.h` is present (another agent owns it; it is not
 * required), each participant gets a profiler slot named after it and its
 * dispatch is wrapped in `aowl_prof_begin`/`aowl_prof_end`, so per-mod frame
 * cost is attributable there as well as here. ASSUMED about that header, from
 * reading it: `aowl_prof_slot(name, kind)` is called ONCE at registration and
 * returns a slot index or negative; `aowl_prof_begin`/`_end` take that index
 * and are safe to call when the profiler is disabled or unmapped. If any of
 * that is wrong, `AOWL_REGION_NO_PROFILE` compiles it out and nothing else
 * changes.
 */

#ifndef AOWLSPT_REGION_H
#define AOWLSPT_REGION_H

#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ABI 3. Bumped, not extended-in-place, and deliberately so.
 *
 * `AowlRegionCmd` grew five fields at ABI 2 (the UV rect and the texture key) so
 * that a TEXTURED QUAD could be submitted at all, and grew eight more at ABI 3
 * (`rcos,rsin,rpx,rpy` and the `rclip*` rect) so that a ROTATED textured quad --
 * `AOWL_REGION_CMD_QUADR`, the heading-up map's rotating art -- could be too.
 * That struct is the wire format of a buffer written by the host DLL and read by
 * a SEPARATELY COMPILED module (the D3D11 overlay, and any mod that drains it),
 * so its `sizeof` is the stride both sides index with. There is no `size` field
 * on it to negotiate with -- unlike `AowlRegionDesc`, which has one -- so a
 * silent change would have the reader stride past the writer's records and
 * decode garbage that still looks like plausible coordinates. That is the exact
 * failure mode this project refuses to ship.
 *
 * So the number moves and `AOWL_REGION_REFUSE_ABI` becomes a LOUD refusal for
 * every module not rebuilt against this header. Every consumer must be
 * recompiled; none needs a source change for the bump itself. */
#define AOWL_REGION_ABI            3
#define AOWL_REGION_MAX            32     /* participants                     */
#define AOWL_REGION_NAME_LEN       32
#define AOWL_REGION_TEXT_LEN       64
#define AOWL_REGION_MAX_CMDS       2048   /* draw commands per frame          */
#define AOWL_REGION_FAULT_LIMIT    3      /* faults before permanent disable  */
#define AOWL_REGION_OVERRUN_LIMIT  8      /* consecutive overruns -> throttle */
#define AOWL_REGION_THROTTLE_EVERY 8      /* run 1 frame in N while throttled */
#define AOWL_REGION_REASON_LEN     192
#define AOWL_REGION_DEFAULT_BUDGET 500    /* microseconds, if a mod gives 0   */

/* ---- the texture cache's EXPLICIT BOUNDS -------------------------- *
 *
 * These two numbers are the whole eviction policy's input, and they are stated
 * here rather than buried so that "how much memory does this cost" has an
 * answer that does not require reading the implementation.
 *
 *   AOWL_REGION_TEX_MAX          32 slots
 *   AOWL_REGION_TEX_SLOT_BYTES   1 MiB per slot
 *   ---------------------------------------------
 *   arena                        32 MiB, static .bss, allocated ONCE
 *
 * 1 MiB is one 1024x1024 BC7 tile (1 byte/texel) or one 512x512 BGRA8 tile.
 * A definition larger than a slot is REFUSED with a named code, never
 * truncated -- a half-uploaded tile renders as plausible garbage.
 *
 * WHY A BOUND AT ALL. The in-game pocket map on this build is 731 MB of
 * zoom-tiled artwork (MEASURED: 41 files under
 * `StreamingAssets/Windows/assets/content/pocketmap`, every one of them a
 * `UnityFS` bundle, NOT an image file -- see the decode note on
 * `aowl_region_texture_define`). Nothing may hold a working set proportional
 * to that. 32 tiles is roughly a 4K screen's worth of one zoom level plus a
 * ring of neighbours, which is what a pan actually touches.
 *
 * EVICTION IS LRU BY FRAME. Every QUAD that names a key stamps that slot with
 * the region's current frame number; a `define` that needs room takes the slot
 * with the OLDEST stamp. A slot referenced this frame is never evicted -- if
 * every slot is that fresh, the define is refused rather than made to evict a
 * texture the caller is about to draw. LRU rather than "clear it all when
 * full", because a map pan touches a moving window of neighbours and a flush
 * would re-upload the entire window on the frame after every flush. */
#define AOWL_REGION_TEX_MAX        32
#define AOWL_REGION_TEX_SLOT_BYTES (1u << 20)

/* ------------------------------------------------------------------ *
 * What a participant asks to be called for.
 * ------------------------------------------------------------------ */
enum {
    AOWL_REGION_TICK = 1,   /* per-frame logic on the Unity main thread      */
    AOWL_REGION_DRAW = 2    /* per-frame draw: may submit draw commands      */
};

/* Refusal codes. Negative returns from `aowl_region_register`, and the value
 * of `lastRefusal`. Named rather than folded into one -1, because "the host is
 * too old" and "you passed a NULL callback" are different bugs. */
enum {
    AOWL_REGION_OK              =  0,
    AOWL_REGION_REFUSE_NOHOST   = -1,  /* no host export: old host, or not in
                                          the client at all                  */
    AOWL_REGION_REFUSE_ABI      = -2,  /* host speaks a different ABI         */
    AOWL_REGION_REFUSE_ARGS     = -3,  /* NULL fn, empty name, bad mask       */
    AOWL_REGION_REFUSE_FULL     = -4,  /* AOWL_REGION_MAX already registered  */
    AOWL_REGION_REFUSE_DUP      = -5,  /* that name is already registered     */
    AOWL_REGION_REFUSE_NESTED   = -6,  /* dispatch called inside a live guard */
    AOWL_REGION_REFUSE_REENTER  = -7,  /* dispatch called inside dispatch     */
    AOWL_REGION_REFUSE_CLOSED   = -8,  /* draw submitted outside a draw call  */
    AOWL_REGION_REFUSE_NOPROJ   = -9,  /* projection asked for, none installed*/
    AOWL_REGION_REFUSE_TEXBIG   = -10, /* a texture larger than one slot      */
    AOWL_REGION_REFUSE_TEXFULL  = -11, /* every slot is in use THIS frame     */
    AOWL_REGION_REFUSE_TEXARGS  = -12, /* bad key/dims/format/NULL bytes      */
    AOWL_REGION_REFUSE_NOTEX    = -13  /* a QUAD named a key nothing defined  */
};

static const char* aowl_region_refusal_text(int32_t r) {
    switch (r) {
        case AOWL_REGION_OK:            return "ok";
        case AOWL_REGION_REFUSE_NOHOST: return
            "no host export aowl_region_register -- this host predates the "
            "shared region, or this module is not running inside the client";
        case AOWL_REGION_REFUSE_ABI:    return
            "the host's shared-region ABI differs from the one this module "
            "was compiled against";
        case AOWL_REGION_REFUSE_ARGS:   return
            "a NULL callback, an empty name, or a mask that is neither TICK "
            "nor DRAW";
        case AOWL_REGION_REFUSE_FULL:   return
            "the shared region is full: AOWL_REGION_MAX participants already";
        case AOWL_REGION_REFUSE_DUP:    return
            "a participant with that name is already registered";
        case AOWL_REGION_REFUSE_NESTED: return
            "REFUSED: dispatch was entered while an aowl_p_p_seh guard is "
            "already active on this thread. That guard is not re-entrant; "
            "running here would disarm the caller's guard. The caller must "
            "dispatch OUTSIDE its guard, not inside it";
        case AOWL_REGION_REFUSE_REENTER:return
            "REFUSED: dispatch re-entered from inside a participant callback";
        case AOWL_REGION_REFUSE_CLOSED: return
            "a draw command was submitted outside a DRAW callback";
        case AOWL_REGION_REFUSE_NOPROJ: return
            "world-to-screen projection was asked for, but the host has not "
            "installed a projector -- refused rather than guessed";
        case AOWL_REGION_REFUSE_TEXBIG: return
            "the texture definition is larger than AOWL_REGION_TEX_SLOT_BYTES "
            "-- refused whole, never truncated, because a partially uploaded "
            "tile renders as plausible garbage rather than as an error";
        case AOWL_REGION_REFUSE_TEXFULL:return
            "every texture slot was referenced by a draw command THIS frame, "
            "so there is nothing to evict that is not about to be drawn";
        case AOWL_REGION_REFUSE_TEXARGS:return
            "a zero key, a non-positive width/height, an unknown format, a "
            "NULL pointer, or a byte count that does not match the format";
        case AOWL_REGION_REFUSE_NOTEX:  return
            "a textured quad named a texture key that was never defined -- "
            "refused, because drawing it with the font atlas bound would put "
            "recognisable glyph soup on screen where map artwork belongs";
        default:                        return "unknown refusal";
    }
}

/* The callback. `user` is the cookie handed at registration; `frame` is the
 * host's monotonic frame counter, so a participant can do its own throttling
 * without keeping a clock. */
typedef void (*AowlRegionFn)(void* user, int64_t frame);

/* What a participant registers. Zero-initialise and fill; `size` lets the host
 * accept a struct from a module compiled against an earlier field set. */
typedef struct AowlRegionDesc {
    int32_t      size;                        /* sizeof(AowlRegionDesc)      */
    char         name[AOWL_REGION_NAME_LEN];  /* for logs and the profiler   */
    int32_t      mask;                        /* TICK | DRAW                 */
    int32_t      order;                       /* ascending; ties by seq      */
    int32_t      budgetUs;                    /* 0 -> DEFAULT_BUDGET         */
    AowlRegionFn fn;
    void*        user;
} AowlRegionDesc;

/* What a participant (or a diagnostic) can read back about itself. This is the
 * FINISHED STATE, which is the only thing worth asserting on. */
typedef struct AowlRegionStatus {
    int32_t size;
    char    name[AOWL_REGION_NAME_LEN];
    int32_t live;            /* registered at all                            */
    int32_t enabled;         /* the participant's own on/off                 */
    int32_t disabled;        /* the REGION turned it off after faults        */
    int32_t throttled;       /* overrunning, so being run 1 frame in N       */
    int32_t faults;
    int32_t overruns;
    int32_t budgetUs;
    int64_t calls;           /* callbacks that RETURNED                      */
    int64_t skipped;         /* frames it did not get, for any reason        */
    int64_t lastUs;
    int64_t maxUs;
    char    reason[AOWL_REGION_REASON_LEN];  /* why it is disabled/throttled */
} AowlRegionStatus;

/* ------------------------------------------------------------------ *
 * Draw commands
 *
 * Screen space, pixels, origin top-left, which is what the D3D11 overlay in
 * `abi/aowlspt_overlay.h` already draws in and what
 * `Camera::WorldToScreenPoint` is converted into by the host's projector.
 * Colour is 0xAABBGGRR, matching the overlay's vertex colour.
 * ------------------------------------------------------------------ */
enum {
    AOWL_REGION_CMD_LINE = 1,
    AOWL_REGION_CMD_BOX  = 2,   /* outline; `t` is the stroke width          */
    AOWL_REGION_CMD_FILL = 3,   /* filled rect                               */
    AOWL_REGION_CMD_TEXT = 4,
    AOWL_REGION_CMD_QUAD = 5,   /* textured: dest rect + UV rect + tex key   */
    AOWL_REGION_CMD_QUADR = 6   /* textured + ROTATED about a pivot, clipped */
};

/* ---- texture formats ---------------------------------------------- *
 * A deliberately tiny set. Each maps 1:1 onto a DXGI format the renderer
 * hands straight to `CreateTexture2D`; there is no conversion step anywhere,
 * on any thread. */
enum {
    AOWL_REGION_TEXFMT_BGRA8 = 1,  /* DXGI_FORMAT_B8G8R8A8_UNORM, 4 B/texel  */
    AOWL_REGION_TEXFMT_BC7   = 2,  /* DXGI_FORMAT_BC7_UNORM,  16 B / 4x4 blk */
    AOWL_REGION_TEXFMT_BC3   = 3,  /* DXGI_FORMAT_BC3_UNORM,  16 B / 4x4 blk */
    AOWL_REGION_TEXFMT_BC1   = 4   /* DXGI_FORMAT_BC1_UNORM,   8 B / 4x4 blk */
};

/* The exact byte count a definition must supply, or 0 if the format/dims are
 * not ones we accept. This is what makes `bytes` a CHECK rather than a hint:
 * a caller that gets it wrong is refused with TEXARGS instead of having the
 * renderer read off the end of its buffer. */
static uint32_t aowl_region_tex_bytes(int32_t fmt, int32_t w, int32_t h) {
    uint32_t bw, bh;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return 0;
    if (fmt == AOWL_REGION_TEXFMT_BGRA8)
        return (uint32_t)w * (uint32_t)h * 4u;
    /* Block formats: 4x4 blocks, rounded up. */
    bw = ((uint32_t)w + 3u) / 4u;
    bh = ((uint32_t)h + 3u) / 4u;
    if (fmt == AOWL_REGION_TEXFMT_BC7 || fmt == AOWL_REGION_TEXFMT_BC3)
        return bw * bh * 16u;
    if (fmt == AOWL_REGION_TEXFMT_BC1)
        return bw * bh * 8u;
    return 0;
}

/* One cache slot. `AOWL_REGION_TEX_SLOT_BYTES` of storage INLINE -- the whole
 * table is one flat static object, so a `define` is a bounds check and a
 * memcpy and there is no allocator on any path, ever.
 *
 * `gen` is what makes the GPU-side cache correct. The renderer keeps its own
 * SRV per key and remembers the `gen` it built that SRV from; when a slot is
 * redefined or evicted-and-reused, `gen` moves and the renderer rebuilds. A
 * key alone is not enough -- a recycled key with stale pixels is a silent
 * wrong picture, which is exactly the class of bug this project keeps
 * finding. */
typedef struct AowlRegionTexSlot {
    uint64_t key;         /* 0 = empty                                      */
    int32_t  fmt;
    int32_t  w, h;
    uint32_t bytes;
    int32_t  gen;         /* bumped whenever `data` changes meaning         */
    int64_t  lastFrame;   /* last frame a QUAD named this key (LRU input)   */
    uint8_t  data[AOWL_REGION_TEX_SLOT_BYTES];
} AowlRegionTexSlot;

/* `t` ON A TEXT COMMAND IS AN INTEGER FONT SCALE (1..8); 0 means 1. It has no
 * other meaning for TEXT, every submitter that predates this leaves it 0, and
 * the renderer treats <1 as 1 -- so this is additive and no module had to be
 * rebuilt. x/y stay TRUE BACK-BUFFER PIXELS at every scale; the renderer
 * divides the position out before applying the scale, so a submitter never has
 * a second coordinate system to get wrong. An 8x16 cell is unreadable at 4K,
 * which is the whole reason this exists. */
/* FOR `AOWL_REGION_CMD_QUAD`: `x,y,w,h` are the DEST RECT in back-buffer
 * pixels, `u0,v0,u1,v1` are the SOURCE UV rect in 0..1 of the named texture,
 * `col` is a MULTIPLICATIVE TINT (0xFFFFFFFF = untinted, and the alpha byte is
 * the quad's opacity), `tex` is the key passed to `aowl_region_texture_define`,
 * and `t` is unused. Every other command kind leaves `tex` 0 and the UVs 0. */
typedef struct AowlRegionCmd {
    int32_t  kind;
    int32_t  owner;                        /* participant index, for blame   */
    float    x, y, w, h, t;
    uint32_t col;
    char     text[AOWL_REGION_TEXT_LEN];   /* inline: no lifetime question   */
    float    u0, v0, u1, v1;               /* QUAD/QUADR: source UV rect     */
    uint64_t tex;                          /* QUAD/QUADR: texture key        */
    /* AOWL_REGION_CMD_QUADR ONLY (all zero for every other kind). The dest
     * rect x,y,w,h and the UV rect above are the UNROTATED (north-up) layout;
     * the renderer takes the four dest corners, rotates each about the pivot
     * (rpx,rpy) in back-buffer pixels using the caller-supplied cos/sin --
     *     x' = rpx + (X-rpx)*rcos - (Y-rpy)*rsin
     *     y' = rpy + (X-rpx)*rsin + (Y-rpy)*rcos
     * -- and emits triangles; the UVs ride the corners unchanged. cos/sin are
     * passed rather than an angle so the renderer needs no math.h and the trig
     * is done ONCE per frame by the submitter, not per tile. When
     * rclipW>0 && rclipH>0 the rotated quad is clipped to the axis-aligned rect
     * (rclipX,rclipY,rclipW,rclipH) so a heading-up pane cannot bleed past its
     * own square; a zero clip rect means no clip. */
    float    rcos, rsin;                   /* QUADR: cos/sin of the rotation */
    float    rpx, rpy;                     /* QUADR: pivot, back-buffer px   */
    float    rclipX, rclipY, rclipW, rclipH; /* QUADR: clip rect (0=none)    */
} AowlRegionCmd;

/* ---- projection outcome ------------------------------------------- *
 *
 * THE DEFECT THIS FIXES. `Camera::WorldToScreenPoint` on a point BEHIND the
 * camera returns a fully-formed, entirely plausible screen position -- it is
 * the MIRRORED one, because the perspective divide by a negative depth flips
 * both axes. The old five-argument `aowl_region_project` had exactly two
 * outcomes: 1 with pixels, or 0. It could not say WHY it said 0, and worse, it
 * had no way to say "here are pixels, and they are a lie". A caller drawing a
 * direction indicator therefore pointed confidently backwards for every target
 * behind the player, and there was no way for it to know.
 *
 * The out-parameter is not optional politeness. It is the difference between
 * a two-outcome check that cannot express doubt and a three-outcome one that
 * can. Callers MUST branch on it; `AOWL_REGION_PROJ_BEHIND` means the written
 * sx/sy are mirrored and must be used only as a BEARING (mirror them back, or
 * clamp to a screen edge), never as a position.
 * ------------------------------------------------------------------- */
enum {
    AOWL_REGION_PROJ_INFRONT   = 0x01, /* real depth > 0: sx/sy are truth    */
    AOWL_REGION_PROJ_BEHIND    = 0x02, /* depth <= 0: sx/sy are MIRRORED     */
    AOWL_REGION_PROJ_OFFSCREEN = 0x04, /* outside 0..screenW / 0..screenH    */
    AOWL_REGION_PROJ_NOCAM     = 0x08  /* no projector/camera: sx/sy UNSET   */
};

/* The projector the host installs.
 *
 * Writes screen pixels into sx/sy and the outcome bits above into `flags`,
 * which is NEVER NULL when the host calls it. Returns 1 when sx/sy were
 * written at all (in front OR behind -- behind still writes the mirrored
 * position, because a bearing is useful), 0 only when there is no camera.
 *
 * `depth` receives the camera-space z the projector actually measured, so a
 * caller can sort by distance and so a test can assert on the sign rather than
 * on a flag the projector could have set by accident. Never NULL either.
 *
 * It is the host's job to have byte-verified whatever it is calling; this
 * header never resolves it. */
typedef int32_t (*AowlRegionProjFn)(float wx, float wy, float wz,
                                    float* sx, float* sy,
                                    int32_t* flags, float* depth);

/* ================================================================== *
 * THE HOST SIDE
 * ================================================================== */
#ifdef AOWL_REGION_HOST

typedef struct AowlRegionPart {
    int32_t      live;
    int32_t      enabled;
    int32_t      disabled;
    int32_t      throttled;
    int32_t      seq;
    char         name[AOWL_REGION_NAME_LEN];
    int32_t      mask;
    int32_t      order;
    int32_t      budgetUs;
    AowlRegionFn fn;
    void*        user;
    int32_t      faults;
    int32_t      overruns;
    int32_t      overrunStreak;
    int32_t      reported;      /* overrun reports emitted (rate limiter)    */
    int32_t      profSlot;
    int64_t      calls;
    int64_t      skipped;
    int64_t      lastUs;
    int64_t      maxUs;
    char         reason[AOWL_REGION_REASON_LEN];
} AowlRegionPart;

typedef struct AowlRegionState {
    int32_t          ready;
    int32_t          armed;      /* the Unity-thread rider is live           */
    int32_t          dispatching;
    int32_t          drawOpen;   /* a DRAW callback is on the stack          */
    int32_t          drawOwner;
    int32_t          count;
    int32_t          nextSeq;
    int32_t          lastRefusal;
    int64_t          frame;
    int64_t          qpf;
    int32_t          screenW, screenH;
    AowlRegionProjFn proj;
    void           (*sink)(const char* line);   /* the host's logger         */
    CRITICAL_SECTION lock;
    AowlRegionPart   p[AOWL_REGION_MAX];
    int32_t          order[AOWL_REGION_MAX];    /* dispatch order, rebuilt
                                                   on registration only      */
    int32_t          orderN;
    /* Two command buffers: participants fill `buf[cur]`, a reader takes
     * `buf[cur ^ 1]` under the seqlock. No allocation, ever. */
    AowlRegionCmd    buf[2][AOWL_REGION_MAX_CMDS];
    int32_t          n[2];
    volatile LONG    cur;
    volatile LONG    seqlock;
    int64_t          dropped;    /* commands refused for want of room        */
    int64_t          frameUs;    /* the whole dispatch, last frame           */
    /* The texture table. CPU side only: this header never touches D3D11. See
     * the long note above `aowl_region_texture_define`. */
    AowlRegionTexSlot tex[AOWL_REGION_TEX_MAX];
    int32_t           texGen;    /* bumped on every define/evict             */
    int64_t           texDefines;
    int64_t           texEvictions;
    int64_t           texRedefines; /* define of a key already resident      */
} AowlRegionState;

static AowlRegionState g_region;

/* ---- the log sink ------------------------------------------------- */

static void aowl_region_say(const char* line) {
    if (g_region.sink) g_region.sink(line);
}

static void aowl_region_sayf(const char* fmt, ...) {
    char b[320];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(b, sizeof(b) - 1, fmt, ap);
    va_end(ap);
    b[sizeof(b) - 1] = 0;
    aowl_region_say(b);
}

/* ---- the nesting check -------------------------------------------- *
 * `aowl_seh_active` is the shim's own thread-local "a guard is armed on this
 * thread" flag. Reading it is how the refusal below becomes a real check
 * rather than a comment. A TU that does not include the shim (the standalone
 * test) defines AOWL_REGION_NO_SHIM and supplies its own.
 * ------------------------------------------------------------------- */
/* `aowlspt_shim.h` MUST be included before this header in the host TU: it owns
 * `aowl_p_p_seh` and the thread-local `aowl_seh_active` this reads. Both are
 * file-`static` there, so they cannot be re-declared here -- they are used
 * directly, and a TU that forgot the include fails to compile rather than
 * silently losing the nesting check. */
static int32_t aowl_region_guard_active(void) { return aowl_seh_active ? 1 : 0; }

static void aowl_region_init(void (*sink)(const char*)) {
    LARGE_INTEGER f;
    if (g_region.ready) { if (sink) g_region.sink = sink; return; }
    memset(&g_region, 0, sizeof(g_region));
    InitializeCriticalSection(&g_region.lock);
    QueryPerformanceFrequency(&f);
    g_region.qpf   = f.QuadPart ? f.QuadPart : 1;
    g_region.sink  = sink;
    g_region.ready = 1;
}

static int64_t aowl_region_now(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return c.QuadPart;
}

static int64_t aowl_region_us(int64_t ticks) {
    return (int64_t)((ticks * 1000000ll) / (g_region.qpf ? g_region.qpf : 1));
}

/* ---- ordering ------------------------------------------------------ *
 * Rebuilt ONLY when the registry changes, never per frame. Insertion sort
 * over at most AOWL_REGION_MAX entries, under the lock, on a registration
 * path that runs a handful of times in a process lifetime.
 * ------------------------------------------------------------------- */
static void aowl_region_reorder(void) {
    int32_t i, j, n = 0;
    for (i = 0; i < AOWL_REGION_MAX; i++)
        if (g_region.p[i].live) g_region.order[n++] = i;
    for (i = 1; i < n; i++) {
        int32_t k = g_region.order[i];
        for (j = i - 1; j >= 0; j--) {
            AowlRegionPart* a = &g_region.p[g_region.order[j]];
            AowlRegionPart* b = &g_region.p[k];
            if (a->order < b->order ||
                (a->order == b->order && a->seq < b->seq)) break;
            g_region.order[j + 1] = g_region.order[j];
        }
        g_region.order[j + 1] = k;
    }
    g_region.orderN = n;
}

/* ---- registration -------------------------------------------------- */

static int32_t aowl_region_abi(void) { return AOWL_REGION_ABI; }

static int32_t aowl_region_register(const AowlRegionDesc* d) {
    int32_t i, slot = -1;
    char nm[AOWL_REGION_NAME_LEN];
    if (!g_region.ready) aowl_region_init(g_region.sink);
    if (!d || (int32_t)d->size < (int32_t)sizeof(AowlRegionDesc) || !d->fn)
        return AOWL_REGION_REFUSE_ARGS;
    if (!(d->mask & (AOWL_REGION_TICK | AOWL_REGION_DRAW)))
        return AOWL_REGION_REFUSE_ARGS;
    memset(nm, 0, sizeof(nm));
    strncpy(nm, d->name, AOWL_REGION_NAME_LEN - 1);
    if (!nm[0]) return AOWL_REGION_REFUSE_ARGS;

    EnterCriticalSection(&g_region.lock);
    for (i = 0; i < AOWL_REGION_MAX; i++) {
        if (g_region.p[i].live && strcmp(g_region.p[i].name, nm) == 0) {
            LeaveCriticalSection(&g_region.lock);
            return AOWL_REGION_REFUSE_DUP;
        }
        if (!g_region.p[i].live && slot < 0) slot = i;
    }
    if (slot < 0) {
        LeaveCriticalSection(&g_region.lock);
        return AOWL_REGION_REFUSE_FULL;
    }
    {
        AowlRegionPart* p = &g_region.p[slot];
        memset(p, 0, sizeof(*p));
        memcpy(p->name, nm, sizeof(nm));
        p->live     = 1;
        p->enabled  = 1;
        p->mask     = d->mask;
        p->order    = d->order;
        p->budgetUs = d->budgetUs > 0 ? d->budgetUs : AOWL_REGION_DEFAULT_BUDGET;
        p->fn       = d->fn;
        p->user     = d->user;
        p->seq      = g_region.nextSeq++;
        p->profSlot = -1;
#if !defined(AOWL_REGION_NO_PROFILE) && defined(AOWL_PROF_VERSION)
        p->profSlot = aowl_prof_slot(p->name, AOWL_PROF_KIND_MOD);
#endif
        g_region.count++;
    }
    aowl_region_reorder();
    LeaveCriticalSection(&g_region.lock);
    aowl_region_sayf(
        "region: registered '%s' (%s%s, order %d, budget %d us) -- %d "
        "participant(s); %s", nm,
        (d->mask & AOWL_REGION_TICK) ? "tick" : "",
        (d->mask & AOWL_REGION_DRAW) ? (
            (d->mask & AOWL_REGION_TICK) ? "+draw" : "draw") : "",
        d->order, g_region.p[slot].budgetUs, g_region.count,
        g_region.armed ? "the region is armed, it will fire next frame"
                       : "the region is NOT armed yet, so it will not fire "
                         "until the Unity-thread rider comes up");
    return slot;
}

static int32_t aowl_region_unregister(int32_t h) {
    if (h < 0 || h >= AOWL_REGION_MAX || !g_region.ready)
        return AOWL_REGION_REFUSE_ARGS;
    EnterCriticalSection(&g_region.lock);
    if (g_region.p[h].live) {
        aowl_region_sayf("region: unregistered '%s'", g_region.p[h].name);
        memset(&g_region.p[h], 0, sizeof(g_region.p[h]));
        g_region.count--;
        aowl_region_reorder();
    }
    LeaveCriticalSection(&g_region.lock);
    return AOWL_REGION_OK;
}

static int32_t aowl_region_set_enabled(int32_t h, int32_t on) {
    if (h < 0 || h >= AOWL_REGION_MAX || !g_region.p[h].live)
        return AOWL_REGION_REFUSE_ARGS;
    g_region.p[h].enabled = on ? 1 : 0;
    return AOWL_REGION_OK;
}

static int32_t aowl_region_status(int32_t h, AowlRegionStatus* out) {
    AowlRegionPart* p;
    if (!out || (int32_t)out->size < (int32_t)sizeof(AowlRegionStatus))
        return AOWL_REGION_REFUSE_ARGS;
    if (h < 0 || h >= AOWL_REGION_MAX) return AOWL_REGION_REFUSE_ARGS;
    p = &g_region.p[h];
    memset(out->name, 0, sizeof(out->name));
    memcpy(out->name, p->name, sizeof(out->name));
    out->live      = p->live;
    out->enabled   = p->enabled;
    out->disabled  = p->disabled;
    out->throttled = p->throttled;
    out->faults    = p->faults;
    out->overruns  = p->overruns;
    out->budgetUs  = p->budgetUs;
    out->calls     = p->calls;
    out->skipped   = p->skipped;
    out->lastUs    = p->lastUs;
    out->maxUs     = p->maxUs;
    memset(out->reason, 0, sizeof(out->reason));
    memcpy(out->reason, p->reason, sizeof(out->reason));
    return AOWL_REGION_OK;
}

static void aowl_region_set_projector(AowlRegionProjFn f) {
    g_region.proj = f;
    aowl_region_sayf("region: projector %s", f ? "installed by the host -- "
        "world-space draw is available" : "cleared -- world-space draw will "
        "refuse");
}
/* THE BACK-BUFFER SIZE.
 *
 * MEASURED DEFECT, fixed here: `screenW`/`screenH` existed and this setter
 * existed, but NOTHING IN THE HOST EVER CALLED IT and no getter was exported.
 * A participant asking how big the screen is therefore read a field that was
 * provably always 0 -- and 0 is not a refusal, it is a plausible number that
 * collapses any edge/corner layout into the top-left. A maps participant hit
 * exactly this and had to route around it with a config key.
 *
 * Two halves to the fix. This one adds a getter and, crucially, a KNOWN flag:
 * a reader can now tell "nobody has told the region the size yet" apart from
 * "the size is zero", which a bare getter cannot express. The other half is the
 * caller -- the F3 overlay publishes its `GetClientRect` measurement here on
 * every refresh, so the value is a live measurement of the real window and
 * never a constant anybody typed.
 *
 * A zero or negative size is REFUSED rather than stored, so one bad frame
 * during a device reset cannot poison a value everything else lays out
 * against. */
static void aowl_region_set_screen(int32_t w, int32_t h) {
    if (w <= 0 || h <= 0) return;
    g_region.screenW = w; g_region.screenH = h;
}
static int32_t aowl_region_screen_w(void) { return g_region.screenW; }
static int32_t aowl_region_screen_h(void) { return g_region.screenH; }
/* 1 once a real size has been published. Check this BEFORE using either
 * dimension: the getters return 0 until then, and 0 is a trap, not an answer. */
static int32_t aowl_region_screen_known(void) {
    return (g_region.screenW > 0 && g_region.screenH > 0) ? 1 : 0;
}
static void aowl_region_set_armed(int32_t on) {
    if (!g_region.ready) aowl_region_init(g_region.sink);
    if (g_region.armed == (on ? 1 : 0)) return;
    g_region.armed = on ? 1 : 0;
    aowl_region_sayf("region: %s (%d participant(s) registered)",
        g_region.armed
            ? "ARMED on the shared PreloaderUI::Update rider chain"
            : "disarmed", g_region.count);
}

/* ---- draw submission ---------------------------------------------- *
 * Legal ONLY from inside a DRAW callback. Outside one, `drawOpen` is 0 and the
 * submission is refused and counted -- a mod that draws from its own worker
 * thread finds out, rather than racing the buffer.
 * ------------------------------------------------------------------- */
static int32_t aowl_region_push(int32_t kind, float x, float y, float w,
                                float h, float t, uint32_t col,
                                const char* text) {
    AowlRegionCmd* c;
    int32_t ix = (int32_t)g_region.cur;
    if (!g_region.drawOpen) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_CLOSED;
        return AOWL_REGION_REFUSE_CLOSED;
    }
    if (g_region.n[ix] >= AOWL_REGION_MAX_CMDS) {
        g_region.dropped++;
        return AOWL_REGION_REFUSE_FULL;
    }
    c = &g_region.buf[ix][g_region.n[ix]++];
    /* Cleared WHOLE, not field by field. A command record is reused every
     * other frame; a slot that held a QUAD last time would otherwise hand the
     * renderer a stale `tex` key on a FILL, and the renderer would find a
     * live texture for it. That is a wrong picture with no error anywhere. */
    memset(c, 0, sizeof(*c));
    c->kind = kind; c->owner = g_region.drawOwner;
    c->x = x; c->y = y; c->w = w; c->h = h; c->t = t; c->col = col;
    if (text) { strncpy(c->text, text, AOWL_REGION_TEXT_LEN - 1);
                c->text[AOWL_REGION_TEXT_LEN - 1] = 0; }
    return AOWL_REGION_OK;
}

/* ---- the texture table -------------------------------------------- *
 *
 * WHAT THIS IS AND IS NOT. This is the CPU half. It owns bytes and keys and
 * nothing else; it never sees a D3D11 device, because the device belongs to
 * the overlay DLL and lives on the render thread, and the whole point of the
 * existing region contract is that the Unity thread PUBLISHES and the render
 * thread DRAINS. A texture follows the same road as a draw command -- there is
 * no second submission path here.
 *
 * THE DECODE PATH, AND WHY IT IS "NONE".
 *
 * MEASURED, and it contradicts the assumption the map work started from: the
 * pocket-map artwork on this build is NOT a directory of image files. It is 41
 * files under `StreamingAssets/Windows/assets/content/pocketmap`, 731 MB in
 * total, and every one of them begins `55 6E 69 74 79 46 53` -- `UnityFS`,
 * Unity 2022.3.43f2 asset bundles. The `map_tile_<col>x<row>_<scale>` names are
 * ASSET names INSIDE those bundles, not file names; on disk the tiles are
 * grouped by row range (`map_tile_scale_1_0-6.bundle`, 71 MB). There is no PNG
 * anywhere in that tree, so "prefer an existing decoder over adding one" turns
 * out not to be the question that needed answering.
 *
 * What is inside a Unity Texture2D asset for a PC build is already GPU block
 * data -- BC7 or BC3 -- because that is what Unity ships to a D3D11 target. So
 * the correct decode path is NO DECODER AT ALL: the block data goes to
 * `CreateTexture2D` byte-for-byte, which is both the fastest possible path and
 * the only one with no third-party dependency, no allocation, and no code that
 * can be fed a malformed image. `AOWL_REGION_TEXFMT_BC7`/`BC3`/`BC1` exist for
 * exactly that, and `BGRA8` exists for the things a mod generates itself.
 *
 * That leaves ONE job, and it is deliberately NOT in this header: getting the
 * block data out of a `UnityFS` bundle (an LZ4 block table plus a
 * SerializedFile parse). That is bulk I/O over 71 MB files. It must not happen
 * on the Unity thread and it must not happen inside `Present`, so it belongs
 * to the mod, off-thread, at load time -- and the mod then calls `define` once
 * per tile with the bytes it extracted. A one-line summary for the maps agent:
 * the ABI takes BLOCKS, you supply the bundle reader, and nothing about this
 * contract changes if you decide to pre-extract to files instead.
 *
 * IDEMPOTENCE IS THE NO-RE-UPLOAD PROPERTY. `define` with a key already
 * resident and the same dimensions/format is a no-op that returns OK without
 * copying a byte. That is what makes a per-frame `define` of the visible tile
 * set correct AND free, which is the shape the map draw actually wants -- it
 * does not have to remember what it uploaded.
 * ------------------------------------------------------------------- */

static AowlRegionTexSlot* aowl_region_tex_find(uint64_t key) {
    int32_t i;
    if (!key) return 0;
    for (i = 0; i < AOWL_REGION_TEX_MAX; i++)
        if (g_region.tex[i].key == key) return &g_region.tex[i];
    return 0;
}

/* 1 if the key is resident. A caller uses this to decide whether it needs to
 * go and read a bundle at all. */
static int32_t aowl_region_texture_have(uint64_t key) {
    return aowl_region_tex_find(key) ? 1 : 0;
}

static int32_t aowl_region_texture_define(uint64_t key, int32_t fmt,
                                          int32_t w, int32_t h,
                                          const void* data, uint32_t bytes) {
    AowlRegionTexSlot* s;
    uint32_t need;
    int32_t i, victim = -1;
    int64_t oldest = 0;

    if (!g_region.ready) aowl_region_init(g_region.sink);

    /* Every argument is CHECKED, not trusted. `need` is derived from the
     * format and the dimensions, so a caller whose `bytes` disagrees is
     * refused rather than having the renderer read past its buffer. */
    need = aowl_region_tex_bytes(fmt, w, h);
    if (!key || !data || !need || need != bytes) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_TEXARGS;
        return AOWL_REGION_REFUSE_TEXARGS;
    }
    if (need > AOWL_REGION_TEX_SLOT_BYTES) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_TEXBIG;
        return AOWL_REGION_REFUSE_TEXBIG;
    }

    s = aowl_region_tex_find(key);
    if (s) {
        /* Resident. Identical shape -> no-op, and NO memcpy: this is the
         * property that lets a submitter call `define` every frame. */
        if (s->fmt == fmt && s->w == w && s->h == h && s->bytes == bytes) {
            g_region.texRedefines++;
            return AOWL_REGION_OK;
        }
        /* Same key, different shape: replace in place and move `gen` so the
         * renderer's SRV for this key is known stale. */
        s->fmt = fmt; s->w = w; s->h = h; s->bytes = bytes;
        memcpy(s->data, data, need);
        s->gen = ++g_region.texGen;
        g_region.texDefines++;
        return AOWL_REGION_OK;
    }

    /* Free slot first; otherwise LRU. A slot stamped with the CURRENT frame is
     * never a victim -- it is about to be drawn. */
    for (i = 0; i < AOWL_REGION_TEX_MAX; i++) {
        if (!g_region.tex[i].key) { victim = i; break; }
        if (g_region.tex[i].lastFrame >= g_region.frame) continue;
        if (victim < 0 || g_region.tex[i].lastFrame < oldest) {
            victim = i; oldest = g_region.tex[i].lastFrame;
        }
    }
    if (victim < 0) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_TEXFULL;
        return AOWL_REGION_REFUSE_TEXFULL;
    }

    s = &g_region.tex[victim];
    if (s->key) g_region.texEvictions++;
    s->key = key; s->fmt = fmt; s->w = w; s->h = h; s->bytes = bytes;
    /* -1, NOT the current frame. `lastFrame` means "a QUAD referenced this
     * key", and only `aowl_region_quad` may stamp it. Stamping it here made
     * every freshly-defined slot un-evictable for the rest of the frame it was
     * defined in -- and on frame 0, which is every slot, that made the table
     * fill to 32 and then refuse everything for ever with the eviction counter
     * still reading zero. MEASURED by the eviction check in
     * `tests/overlayhost/texprojtest.c`, which failed on exactly this. */
    s->lastFrame = -1;
    memcpy(s->data, data, need);
    s->gen = ++g_region.texGen;   /* a recycled slot NEVER reuses a gen */
    g_region.texDefines++;
    return AOWL_REGION_OK;
}

/* Drop a key. Returns OK if it was there, NOTEX if it was not -- so a caller
 * unloading a map can tell "I released it" from "it was already gone". */
static int32_t aowl_region_texture_forget(uint64_t key) {
    AowlRegionTexSlot* s = aowl_region_tex_find(key);
    if (!s) return AOWL_REGION_REFUSE_NOTEX;
    s->key = 0; s->bytes = 0; s->w = 0; s->h = 0; s->fmt = 0;
    s->lastFrame = -1;
    s->gen = ++g_region.texGen;
    return AOWL_REGION_OK;
}

/* The RENDERER's read side, by index. Returns 0 for an empty slot. The
 * renderer walks 0..AOWL_REGION_TEX_MAX-1 once and matches on `key`/`gen`. */
static const AowlRegionTexSlot* aowl_region_texture_slot(int32_t i) {
    if (i < 0 || i >= AOWL_REGION_TEX_MAX) return 0;
    if (!g_region.tex[i].key) return 0;
    return &g_region.tex[i];
}
static int32_t aowl_region_texture_count(void) {
    int32_t i, n = 0;
    for (i = 0; i < AOWL_REGION_TEX_MAX; i++) if (g_region.tex[i].key) n++;
    return n;
}
static int64_t aowl_region_texture_evictions(void) { return g_region.texEvictions; }

/* The textured quad. REFUSED when the key is not resident -- see the refusal
 * text: falling through to an untextured quad would paint the font atlas into
 * the map's footprint, which looks like a rendering bug and is actually a
 * cache miss, and those two must not be confusable. */
static int32_t aowl_region_quad(float x, float y, float w, float h,
                                float u0, float v0, float u1, float v1,
                                uint64_t key, uint32_t tint) {
    AowlRegionTexSlot* s;
    AowlRegionCmd* c;
    int32_t ix = (int32_t)g_region.cur;
    if (!g_region.drawOpen) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_CLOSED;
        return AOWL_REGION_REFUSE_CLOSED;
    }
    s = aowl_region_tex_find(key);
    if (!s) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_NOTEX;
        return AOWL_REGION_REFUSE_NOTEX;
    }
    if (g_region.n[ix] >= AOWL_REGION_MAX_CMDS) {
        g_region.dropped++;
        return AOWL_REGION_REFUSE_FULL;
    }
    s->lastFrame = g_region.frame;      /* the LRU stamp */
    c = &g_region.buf[ix][g_region.n[ix]++];
    memset(c, 0, sizeof(*c));
    c->kind = AOWL_REGION_CMD_QUAD; c->owner = g_region.drawOwner;
    c->x = x; c->y = y; c->w = w; c->h = h; c->col = tint;
    c->u0 = u0; c->v0 = v0; c->u1 = u1; c->v1 = v1;
    c->tex = key;
    return AOWL_REGION_OK;
}

/* The ROTATED textured quad. Identical residency/liveness rules as the
 * axis-aligned quad above -- REFUSED, not silently degraded, when the key is
 * not resident -- with a rotation carried as pre-computed cos/sin about the
 * pivot (rpx,rpy) and an optional clip rect. See the note on AowlRegionCmd for
 * the exact corner transform; the renderer, not this function, applies it. */
static int32_t aowl_region_quadr(float x, float y, float w, float h,
                                 float u0, float v0, float u1, float v1,
                                 uint64_t key, uint32_t tint,
                                 float rcos, float rsin, float rpx, float rpy,
                                 float clipX, float clipY,
                                 float clipW, float clipH) {
    AowlRegionTexSlot* s;
    AowlRegionCmd* c;
    int32_t ix = (int32_t)g_region.cur;
    if (!g_region.drawOpen) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_CLOSED;
        return AOWL_REGION_REFUSE_CLOSED;
    }
    s = aowl_region_tex_find(key);
    if (!s) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_NOTEX;
        return AOWL_REGION_REFUSE_NOTEX;
    }
    if (g_region.n[ix] >= AOWL_REGION_MAX_CMDS) {
        g_region.dropped++;
        return AOWL_REGION_REFUSE_FULL;
    }
    s->lastFrame = g_region.frame;      /* the LRU stamp */
    c = &g_region.buf[ix][g_region.n[ix]++];
    memset(c, 0, sizeof(*c));
    c->kind = AOWL_REGION_CMD_QUADR; c->owner = g_region.drawOwner;
    c->x = x; c->y = y; c->w = w; c->h = h; c->col = tint;
    c->u0 = u0; c->v0 = v0; c->u1 = u1; c->v1 = v1;
    c->tex = key;
    c->rcos = rcos; c->rsin = rsin; c->rpx = rpx; c->rpy = rpy;
    c->rclipX = clipX; c->rclipY = clipY; c->rclipW = clipW; c->rclipH = clipH;
    return AOWL_REGION_OK;
}

static int32_t aowl_region_line(float x0, float y0, float x1, float y1,
                                float t, uint32_t col) {
    return aowl_region_push(AOWL_REGION_CMD_LINE, x0, y0, x1, y1, t, col, 0);
}
static int32_t aowl_region_box(float x, float y, float w, float h,
                               float t, uint32_t col) {
    return aowl_region_push(AOWL_REGION_CMD_BOX, x, y, w, h, t, col, 0);
}
static int32_t aowl_region_fill(float x, float y, float w, float h,
                                uint32_t col) {
    return aowl_region_push(AOWL_REGION_CMD_FILL, x, y, w, h, 0.0f, col, 0);
}
static int32_t aowl_region_text(float x, float y, const char* s, uint32_t col) {
    return aowl_region_push(AOWL_REGION_CMD_TEXT, x, y, 0, 0, 0, col, s);
}
/* The same command with an explicit integer font scale. See the note on
 * `AowlRegionCmd`: this writes the scale into `t`, which is unused for TEXT.
 * A scale below 1 is stored as 0 so the wire value stays exactly what an old
 * submitter would have produced. */
static int32_t aowl_region_text_scaled(float x, float y, const char* s,
                                       uint32_t col, int32_t scale) {
    if (scale < 1) scale = 0;
    if (scale > 8) scale = 8;
    return aowl_region_push(AOWL_REGION_CMD_TEXT, x, y, 0, 0,
                            (float)scale, col, s);
}

/* World space, via the projector the host installed. Returns 0 -- and records
 * REFUSE_NOPROJ -- when there is no projector, rather than inventing pixels. */
static int32_t aowl_region_project_ex(float wx, float wy, float wz,
                                      float* sx, float* sy,
                                      int32_t* flags, float* depth) {
    float lx = 0.0f, ly = 0.0f, ld = 0.0f;
    int32_t lf = 0, r;
    if (!sx) sx = &lx;
    if (!sy) sy = &ly;
    if (!depth) depth = &ld;
    if (!flags) flags = &lf;
    *sx = 0.0f; *sy = 0.0f; *depth = 0.0f; *flags = 0;

    if (!g_region.proj) {
        g_region.lastRefusal = AOWL_REGION_REFUSE_NOPROJ;
        *flags = AOWL_REGION_PROJ_NOCAM;
        return 0;
    }
    r = g_region.proj(wx, wy, wz, sx, sy, flags, depth);
    if (!r) { *flags = AOWL_REGION_PROJ_NOCAM; return 0; }

    /* BELT AND BRACES, and it is not redundant. The projector is supposed to
     * set the direction bit; if it set neither -- an older or buggy projector,
     * or one that faulted past the assignment -- we DERIVE it from the depth
     * it reported rather than leaving `flags` at 0. A zero `flags` reads as
     * "no information" to a caller that tests bits, and would be treated by a
     * sloppy one as "not behind", which is the very lie being fixed. */
    if (!(*flags & (AOWL_REGION_PROJ_INFRONT | AOWL_REGION_PROJ_BEHIND)))
        *flags |= (*depth > 0.0f) ? AOWL_REGION_PROJ_INFRONT
                                  : AOWL_REGION_PROJ_BEHIND;

    /* Off-screen is only decidable once a real back-buffer size is published;
     * `aowl_region_screen_known()` being 0 means we do not know, and we say
     * nothing rather than declaring everything on-screen against a 0x0 rect. */
    if (aowl_region_screen_known()) {
        if (*sx < 0.0f || *sy < 0.0f ||
            *sx > (float)g_region.screenW || *sy > (float)g_region.screenH)
            *flags |= AOWL_REGION_PROJ_OFFSCREEN;
    }
    return 1;
}

/* THE COMPATIBILITY WRAPPER, and the reason the old shape stays safe.
 *
 * The five-argument call returns 1 ONLY for a point that is genuinely in
 * front. A behind-camera point returns 0 -- which is precisely what every
 * existing caller already treats as "do not draw this". So a caller that is
 * never updated becomes CORRECT rather than merely unchanged: it stops drawing
 * the mirrored indicator it used to draw. A caller that wants the bearing must
 * ask for it explicitly through `_ex`, which is the right way round. */
static int32_t aowl_region_project(float wx, float wy, float wz,
                                   float* sx, float* sy) {
    int32_t flags = 0;
    float d = 0.0f;
    if (!aowl_region_project_ex(wx, wy, wz, sx, sy, &flags, &d)) return 0;
    return (flags & AOWL_REGION_PROJ_BEHIND) ? 0 : 1;
}

/* ---- the guarded single-callback invocation ------------------------ *
 * ONE guard, entered here and exited here. `aowl_region_body` returns the
 * constant 1 only after the callback has RETURNED, and aowl_p_p_seh returns 0
 * when it longjmps -- so a faulting callback cannot report success. That is
 * the property that makes the mutation proof a real proof.
 * ------------------------------------------------------------------- */
typedef struct AowlRegionCall {
    AowlRegionFn fn;
    void*        user;
    int64_t      frame;
} AowlRegionCall;

static void* aowl_region_body(void* a) {
    AowlRegionCall* c = (AowlRegionCall*)a;
    c->fn(c->user, c->frame);
    return (void*)(size_t)1;
}

/* ---- the dispatcher ------------------------------------------------ *
 * OPENS NO GUARD. Every line below touches only this header's own arrays and
 * integers; the only foreign code reached is each participant's callback, and
 * each of those is entered through its own guard and left before the next.
 * ------------------------------------------------------------------- */
static int32_t aowl_region_frame(void) {
    int32_t i, ord[AOWL_REGION_MAX], n;
    int32_t nextIx;
    int64_t t0;

    if (!g_region.ready || !g_region.armed) return AOWL_REGION_OK;

    /* The two structural refusals. Both are checks that CAN fail, and both
     * name the mistake rather than hiding it. */
    if (aowl_region_guard_active()) {
        if (g_region.lastRefusal != AOWL_REGION_REFUSE_NESTED)
            aowl_region_say(aowl_region_refusal_text(AOWL_REGION_REFUSE_NESTED));
        g_region.lastRefusal = AOWL_REGION_REFUSE_NESTED;
        return AOWL_REGION_REFUSE_NESTED;
    }
    if (g_region.dispatching) {
        if (g_region.lastRefusal != AOWL_REGION_REFUSE_REENTER)
            aowl_region_say(aowl_region_refusal_text(AOWL_REGION_REFUSE_REENTER));
        g_region.lastRefusal = AOWL_REGION_REFUSE_REENTER;
        return AOWL_REGION_REFUSE_REENTER;
    }

    /* Snapshot the order under the lock so a registration arriving on another
     * thread mid-frame neither is skipped forever nor moves the array we are
     * walking. This is the only lock the frame path takes, it is uncontended
     * in the normal case, and it does not span a callback. */
    EnterCriticalSection(&g_region.lock);
    n = g_region.orderN;
    if (n > AOWL_REGION_MAX) n = AOWL_REGION_MAX;
    for (i = 0; i < n; i++) ord[i] = g_region.order[i];
    LeaveCriticalSection(&g_region.lock);

    g_region.dispatching = 1;
    g_region.frame++;
    t0 = aowl_region_now();

    /* Start a fresh command buffer for this frame in the back slot. */
    nextIx = (int32_t)g_region.cur ^ 1;
    g_region.n[nextIx] = 0;
    InterlockedExchange(&g_region.cur, nextIx);

    for (i = 0; i < n; i++) {
        AowlRegionPart* p = &g_region.p[ord[i]];
        AowlRegionCall  call;
        int64_t a, b, us;
        void*   ok;

        if (!p->live || !p->enabled || p->disabled) { p->skipped++; continue; }
        if (p->throttled && (g_region.frame % AOWL_REGION_THROTTLE_EVERY) != 0) {
            p->skipped++;
            continue;
        }

        g_region.drawOpen  = (p->mask & AOWL_REGION_DRAW) ? 1 : 0;
        g_region.drawOwner = ord[i];

        call.fn = p->fn; call.user = p->user; call.frame = g_region.frame;

#if !defined(AOWL_REGION_NO_PROFILE) && defined(AOWL_PROF_VERSION)
        if (p->profSlot >= 0) aowl_prof_begin(p->profSlot);
#endif
        a  = aowl_region_now();
        ok = aowl_p_p_seh((void*)aowl_region_body, (void*)&call);  /* THE guard */
        b  = aowl_region_now();
#if !defined(AOWL_REGION_NO_PROFILE) && defined(AOWL_PROF_VERSION)
        if (p->profSlot >= 0) aowl_prof_end(p->profSlot);
#endif
        g_region.drawOpen = 0;

        us = aowl_region_us(b - a);
        p->lastUs = us;
        if (us > p->maxUs) p->maxUs = us;

        if (ok == 0) {
            /* FAULTED. The guard longjmped; the callback never returned. */
            p->faults++;
            p->overrunStreak = 0;
            aowl_region_sayf(
                "region: participant '%s' FAULTED in its %s callback "
                "(fault %d of %d allowed). The other %d participant(s) were "
                "NOT affected -- each runs under its own guard.",
                p->name,
                (p->mask & AOWL_REGION_DRAW) ? "draw" : "tick",
                p->faults, AOWL_REGION_FAULT_LIMIT, n - 1);
            if (p->faults >= AOWL_REGION_FAULT_LIMIT) {
                p->disabled = 1;
                _snprintf(p->reason, AOWL_REGION_REASON_LEN - 1,
                    "DISABLED after %d faults in its callback", p->faults);
                p->reason[AOWL_REGION_REASON_LEN - 1] = 0;
                aowl_region_sayf(
                    "region: participant '%s' is now DISABLED after %d faults "
                    "and will not be called again this run. Every other "
                    "participant continues.", p->name, p->faults);
            }
            continue;
        }

        p->calls++;
        if (us > (int64_t)p->budgetUs) {
            p->overruns++;
            p->overrunStreak++;
            /* Reported, never silently tolerated -- but rate-limited so a
             * permanently slow participant does not become the log. First
             * overrun, then powers of two. */
            if ((p->overrunStreak & (p->overrunStreak - 1)) == 0) {
                aowl_region_sayf(
                    "region: participant '%s' OVERRAN its frame budget: "
                    "%lld us against %d us (%lld consecutive, %d total, worst "
                    "%lld us)", p->name, (long long)us, p->budgetUs,
                    (long long)p->overrunStreak, p->overruns,
                    (long long)p->maxUs);
            }
            if (!p->throttled && p->overrunStreak >= AOWL_REGION_OVERRUN_LIMIT) {
                p->throttled = 1;
                _snprintf(p->reason, AOWL_REGION_REASON_LEN - 1,
                    "THROTTLED to 1 frame in %d after %d consecutive budget "
                    "overruns (worst %lld us against %d us)",
                    AOWL_REGION_THROTTLE_EVERY, p->overrunStreak,
                    (long long)p->maxUs, p->budgetUs);
                p->reason[AOWL_REGION_REASON_LEN - 1] = 0;
                aowl_region_sayf("region: participant '%s' -- %s", p->name,
                                 p->reason);
            }
        } else {
            if (p->overrunStreak > 0 && p->throttled) {
                p->throttled = 0;
                aowl_region_sayf("region: participant '%s' is back inside its "
                    "%d us budget; throttle lifted", p->name, p->budgetUs);
                p->reason[0] = 0;
            }
            p->overrunStreak = 0;
        }
    }

    /* Publish the finished command buffer. Odd seqlock while writing the
     * count, even when it is consistent. */
    InterlockedIncrement(&g_region.seqlock);
    InterlockedIncrement(&g_region.seqlock);

    g_region.frameUs     = aowl_region_us(aowl_region_now() - t0);
    g_region.dispatching = 0;
    return AOWL_REGION_OK;
}

/* ---- the reader (the overlay's Present hook) ----------------------- *
 * Returns the number of commands and points `out` at the published buffer.
 * The reader must copy or consume promptly; the buffer is overwritten two
 * frames later at the earliest, and the seqlock lets a reader notice.
 * ------------------------------------------------------------------- */
static int32_t aowl_region_commands(const AowlRegionCmd** out) {
    int32_t ix = (int32_t)g_region.cur;
    if (!g_region.ready || !out) return 0;
    *out = g_region.buf[ix];
    return g_region.n[ix];
}

static int64_t aowl_region_frames(void)      { return g_region.frame; }
static int64_t aowl_region_dropped(void)     { return g_region.dropped; }
static int64_t aowl_region_frame_us(void)    { return g_region.frameUs; }
static int32_t aowl_region_count(void)       { return g_region.count; }
static int32_t aowl_region_is_armed(void)    { return g_region.armed; }
static int32_t aowl_region_last_refusal(void){ return g_region.lastRefusal; }
static const char* aowl_region_name_of(int32_t h) {
    if (h < 0 || h >= AOWL_REGION_MAX || !g_region.p[h].live) return "";
    return g_region.p[h].name;
}

#else  /* ================= THE CLIENT SIDE (a mod, the overlay) ========= */

typedef int32_t (*AowlRegionRegFn)(const AowlRegionDesc*);
typedef int32_t (*AowlRegionUnregFn)(int32_t);
typedef int32_t (*AowlRegionStatFn)(int32_t, AowlRegionStatus*);
typedef int32_t (*AowlRegionAbiFn)(void);
typedef int32_t (*AowlRegionDraw4Fn)(float, float, float, float, float, uint32_t);
typedef int32_t (*AowlRegionFillFn)(float, float, float, float, uint32_t);
typedef int32_t (*AowlRegionTextFn)(float, float, const char*, uint32_t);
typedef int32_t (*AowlRegionProjectFn)(float, float, float, float*, float*);

static AowlRegionAbiFn     aowl_rg_abi_fn   = 0;
static AowlRegionRegFn     aowl_rg_reg_fn   = 0;
static AowlRegionUnregFn   aowl_rg_unreg_fn = 0;
static AowlRegionStatFn    aowl_rg_stat_fn  = 0;
static AowlRegionDraw4Fn   aowl_rg_line_fn  = 0;
static AowlRegionDraw4Fn   aowl_rg_box_fn   = 0;
static AowlRegionFillFn    aowl_rg_fill_fn  = 0;
static AowlRegionTextFn    aowl_rg_text_fn  = 0;
static AowlRegionProjectFn aowl_rg_proj_fn  = 0;
static int32_t             aowl_rg_tried    = 0;

static void aowl_region_resolve(void) {
    HMODULE h;
    if (aowl_rg_tried) return;
    aowl_rg_tried = 1;
    h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
    if (!h) return;
    aowl_rg_abi_fn   = (AowlRegionAbiFn)(void*)     GetProcAddress(h, "aowl_region_abi_x");
    aowl_rg_reg_fn   = (AowlRegionRegFn)(void*)     GetProcAddress(h, "aowl_region_register_x");
    aowl_rg_unreg_fn = (AowlRegionUnregFn)(void*)   GetProcAddress(h, "aowl_region_unregister_x");
    aowl_rg_stat_fn  = (AowlRegionStatFn)(void*)    GetProcAddress(h, "aowl_region_status_x");
    aowl_rg_line_fn  = (AowlRegionDraw4Fn)(void*)   GetProcAddress(h, "aowl_region_line_x");
    aowl_rg_box_fn   = (AowlRegionDraw4Fn)(void*)   GetProcAddress(h, "aowl_region_box_x");
    aowl_rg_fill_fn  = (AowlRegionFillFn)(void*)    GetProcAddress(h, "aowl_region_fill_x");
    aowl_rg_text_fn  = (AowlRegionTextFn)(void*)    GetProcAddress(h, "aowl_region_text_x");
    aowl_rg_proj_fn  = (AowlRegionProjectFn)(void*) GetProcAddress(h, "aowl_region_project_x");
}

/* The one call a mod makes. Negative is a refusal; pass it to
 * `aowl_region_refusal_text` and log that, do not print the number. */
static int32_t aowl_region_register(const AowlRegionDesc* d) {
    aowl_region_resolve();
    if (!aowl_rg_reg_fn) return AOWL_REGION_REFUSE_NOHOST;
    if (!aowl_rg_abi_fn || aowl_rg_abi_fn() != AOWL_REGION_ABI)
        return AOWL_REGION_REFUSE_ABI;
    return aowl_rg_reg_fn(d);
}
static int32_t aowl_region_unregister(int32_t h) {
    aowl_region_resolve();
    return aowl_rg_unreg_fn ? aowl_rg_unreg_fn(h) : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_status(int32_t h, AowlRegionStatus* o) {
    aowl_region_resolve();
    return aowl_rg_stat_fn ? aowl_rg_stat_fn(h, o) : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_line(float x0, float y0, float x1, float y1,
                                float t, uint32_t c) {
    return aowl_rg_line_fn ? aowl_rg_line_fn(x0, y0, x1, y1, t, c)
                           : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_box(float x, float y, float w, float h,
                               float t, uint32_t c) {
    return aowl_rg_box_fn ? aowl_rg_box_fn(x, y, w, h, t, c)
                          : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_fill(float x, float y, float w, float h, uint32_t c) {
    return aowl_rg_fill_fn ? aowl_rg_fill_fn(x, y, w, h, c)
                           : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_text(float x, float y, const char* s, uint32_t c) {
    return aowl_rg_text_fn ? aowl_rg_text_fn(x, y, s, c)
                           : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_project(float wx, float wy, float wz,
                                   float* sx, float* sy) {
    return aowl_rg_proj_fn ? aowl_rg_proj_fn(wx, wy, wz, sx, sy) : 0;
}

/* ---- the three-outcome projection, from the client side ------------ *
 * Returns 0 AND sets AOWL_REGION_PROJ_NOCAM when the host is too old to export
 * it. That is deliberately the same shape as "there is no camera": in both
 * cases the caller has no position and must not invent one. `flags` is written
 * on every path, so a caller may branch on it unconditionally. */
typedef int32_t (*AowlRegionProjectExFn)(float, float, float,
                                         float*, float*, int32_t*, float*);
static AowlRegionProjectExFn aowl_rg_projex_fn = 0;
static int32_t               aowl_rg_projex_try = 0;

static int32_t aowl_region_project_ex(float wx, float wy, float wz,
                                      float* sx, float* sy,
                                      int32_t* flags, float* depth) {
    float lx, ly, ld; int32_t lf;
    if (!sx) sx = &lx;
    if (!sy) sy = &ly;
    if (!depth) depth = &ld;
    if (!flags) flags = &lf;
    *sx = 0.0f; *sy = 0.0f; *depth = 0.0f;
    *flags = AOWL_REGION_PROJ_NOCAM;
    if (!aowl_rg_projex_try) {
        HMODULE h;
        aowl_rg_projex_try = 1;
        h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
        if (h) aowl_rg_projex_fn = (AowlRegionProjectExFn)(void*)
            GetProcAddress(h, "aowl_region_project_ex_x");
    }
    if (!aowl_rg_projex_fn) return 0;
    return aowl_rg_projex_fn(wx, wy, wz, sx, sy, flags, depth);
}

/* ---- the texture cache, from the client side ---------------------- */
typedef int32_t (*AowlRegionTexDefFn)(uint64_t, int32_t, int32_t, int32_t,
                                      const void*, uint32_t);
typedef int32_t (*AowlRegionTexKeyFn)(uint64_t);
typedef int32_t (*AowlRegionQuadFn)(float, float, float, float,
                                    float, float, float, float,
                                    uint64_t, uint32_t);
typedef int32_t (*AowlRegionQuadRFn)(float, float, float, float,
                                     float, float, float, float,
                                     uint64_t, uint32_t,
                                     float, float, float, float,
                                     float, float, float, float);
static AowlRegionTexDefFn aowl_rg_texdef_fn  = 0;
static AowlRegionTexKeyFn aowl_rg_texhave_fn = 0;
static AowlRegionTexKeyFn aowl_rg_texforget_fn = 0;
static AowlRegionQuadFn   aowl_rg_quad_fn    = 0;
static AowlRegionQuadRFn  aowl_rg_quadr_fn   = 0;
static int32_t            aowl_rg_tex_try    = 0;

static void aowl_region_resolve_tex(void) {
    HMODULE h;
    if (aowl_rg_tex_try) return;
    aowl_rg_tex_try = 1;
    h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
    if (!h) return;
    aowl_rg_texdef_fn    = (AowlRegionTexDefFn)(void*)
        GetProcAddress(h, "aowl_region_texture_define_x");
    aowl_rg_texhave_fn   = (AowlRegionTexKeyFn)(void*)
        GetProcAddress(h, "aowl_region_texture_have_x");
    aowl_rg_texforget_fn = (AowlRegionTexKeyFn)(void*)
        GetProcAddress(h, "aowl_region_texture_forget_x");
    aowl_rg_quad_fn      = (AowlRegionQuadFn)(void*)
        GetProcAddress(h, "aowl_region_quad_x");
    aowl_rg_quadr_fn     = (AowlRegionQuadRFn)(void*)
        GetProcAddress(h, "aowl_region_quadr_x");
}
static int32_t aowl_region_texture_define(uint64_t key, int32_t fmt,
                                          int32_t w, int32_t h,
                                          const void* data, uint32_t bytes) {
    aowl_region_resolve_tex();
    return aowl_rg_texdef_fn ? aowl_rg_texdef_fn(key, fmt, w, h, data, bytes)
                             : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_texture_have(uint64_t key) {
    aowl_region_resolve_tex();
    return aowl_rg_texhave_fn ? aowl_rg_texhave_fn(key) : 0;
}
static int32_t aowl_region_texture_forget(uint64_t key) {
    aowl_region_resolve_tex();
    return aowl_rg_texforget_fn ? aowl_rg_texforget_fn(key)
                                : AOWL_REGION_REFUSE_NOHOST;
}
static int32_t aowl_region_quad(float x, float y, float w, float h,
                                float u0, float v0, float u1, float v1,
                                uint64_t key, uint32_t tint) {
    aowl_region_resolve_tex();
    return aowl_rg_quad_fn
        ? aowl_rg_quad_fn(x, y, w, h, u0, v0, u1, v1, key, tint)
        : AOWL_REGION_REFUSE_NOHOST;
}
/* The rotated quad, client side. AOWL_REGION_REFUSE_NOHOST when the host
 * predates ABI 3 and never exported `aowl_region_quadr_x`, so a mod can fall
 * back to the axis-aligned QUAD (north-up) rather than draw nothing. */
static int32_t aowl_region_quadr(float x, float y, float w, float h,
                                 float u0, float v0, float u1, float v1,
                                 uint64_t key, uint32_t tint,
                                 float rcos, float rsin, float rpx, float rpy,
                                 float clipX, float clipY,
                                 float clipW, float clipH) {
    aowl_region_resolve_tex();
    return aowl_rg_quadr_fn
        ? aowl_rg_quadr_fn(x, y, w, h, u0, v0, u1, v1, key, tint,
                           rcos, rsin, rpx, rpy, clipX, clipY, clipW, clipH)
        : AOWL_REGION_REFUSE_NOHOST;
}

/* The RENDERER's side. `aowlspt_overlay.h` is a separate DLL from the host, so
 * it is a client of the region like any mod: it drains the published command
 * buffer once a frame inside Present and rasterises it. Returns 0 when the
 * host is too old or the region has never dispatched -- which is a frame with
 * nothing to draw, not an error. */
typedef int32_t (*AowlRegionCmdsFn)(const AowlRegionCmd**);
typedef int32_t (*AowlRegionFlagFn)(void);
static AowlRegionCmdsFn aowl_rg_cmds_fn  = 0;
static AowlRegionFlagFn aowl_rg_armed_fn = 0;
static int32_t          aowl_rg_cmds_try = 0;

static int32_t aowl_region_commands(const AowlRegionCmd** out) {
    if (!aowl_rg_cmds_try) {
        HMODULE h;
        aowl_rg_cmds_try = 1;
        h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
        if (h) {
            aowl_rg_cmds_fn  = (AowlRegionCmdsFn)(void*)
                GetProcAddress(h, "aowl_region_commands_x");
            aowl_rg_armed_fn = (AowlRegionFlagFn)(void*)
                GetProcAddress(h, "aowl_region_is_armed_x");
        }
    }
    if (!aowl_rg_cmds_fn || !out) return 0;
    return aowl_rg_cmds_fn(out);
}
static int32_t aowl_region_is_armed(void) {
    const AowlRegionCmd* ignore = 0;
    aowl_region_commands(&ignore);
    return aowl_rg_armed_fn ? aowl_rg_armed_fn() : 0;
}

/* The region's monotonic frame counter, from the client side. The renderer
 * uses it as the LRU stamp on its own texture cache, so that the CPU table and
 * the GPU cache age on the SAME clock -- two clocks would let the GPU evict a
 * tile the host still considers hot. 0 when the host is too old, which makes
 * every entry equally old and the cache degrade to FIFO rather than misbehave. */
typedef int64_t (*AowlRegionFramesFn)(void);
static AowlRegionFramesFn aowl_rg_frames_fn = 0;
static int32_t            aowl_rg_frames_try = 0;
static int64_t aowl_region_frames(void) {
    if (!aowl_rg_frames_try) {
        HMODULE h;
        aowl_rg_frames_try = 1;
        h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
        if (h) aowl_rg_frames_fn = (AowlRegionFramesFn)(void*)
            GetProcAddress(h, "aowl_region_frames_x");
    }
    return aowl_rg_frames_fn ? aowl_rg_frames_fn() : 0;
}

/* The renderer's view of the texture table. A const pointer into the host's
 * static arena, valid until the slot is redefined -- which the renderer
 * detects by `gen`, never by assuming the pointer went stale. NULL for an
 * empty slot or an old host. */
typedef const AowlRegionTexSlot* (*AowlRegionTexSlotFn)(int32_t);
static AowlRegionTexSlotFn aowl_rg_texslot_fn = 0;
static int32_t             aowl_rg_texslot_try = 0;
static const AowlRegionTexSlot* aowl_region_texture_slot(int32_t i) {
    if (!aowl_rg_texslot_try) {
        HMODULE h;
        aowl_rg_texslot_try = 1;
        h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
        if (h) aowl_rg_texslot_fn = (AowlRegionTexSlotFn)(void*)
            GetProcAddress(h, "aowl_region_texture_slot_x");
    }
    if (!aowl_rg_texslot_fn) return 0;
    return aowl_rg_texslot_fn(i);
}

/* The back-buffer size, from the client side. `aowl_region_screen_known()` is
 * the one to test first: it is 0 both when the host is too old to export these
 * and when nothing has published a size yet, and in BOTH of those cases the
 * dimensions are 0 -- which a layout must treat as "I do not know", never as a
 * screen that is zero pixels wide. */
static AowlRegionAbiFn aowl_rg_scrw_fn = 0;
static AowlRegionAbiFn aowl_rg_scrh_fn = 0;
static AowlRegionAbiFn aowl_rg_scrk_fn = 0;
static int32_t         aowl_rg_scr_tried = 0;
static void aowl_region_resolve_screen(void) {
    HMODULE h;
    if (aowl_rg_scr_tried) return;
    aowl_rg_scr_tried = 1;
    h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
    if (!h) return;
    aowl_rg_scrw_fn = (AowlRegionAbiFn)(void*)GetProcAddress(h, "aowl_region_screen_w_x");
    aowl_rg_scrh_fn = (AowlRegionAbiFn)(void*)GetProcAddress(h, "aowl_region_screen_h_x");
    aowl_rg_scrk_fn = (AowlRegionAbiFn)(void*)GetProcAddress(h, "aowl_region_screen_known_x");
}
static int32_t aowl_region_screen_known(void) {
    aowl_region_resolve_screen();
    return aowl_rg_scrk_fn ? aowl_rg_scrk_fn() : 0;
}
static int32_t aowl_region_screen_w(void) {
    aowl_region_resolve_screen();
    return aowl_rg_scrw_fn ? aowl_rg_scrw_fn() : 0;
}
static int32_t aowl_region_screen_h(void) {
    aowl_region_resolve_screen();
    return aowl_rg_scrh_fn ? aowl_rg_scrh_fn() : 0;
}

#endif /* AOWL_REGION_HOST */

#ifdef __cplusplus
}
#endif
#endif /* AOWLSPT_REGION_H */
